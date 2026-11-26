#!/usr/bin/env bash
# selector: tree-scan
# merge-on-green.sh re-checks the static registries on the MERGE of the live
# base and the PR head. Fixture pairs of branches: each member is green alone,
# the pair is red together; the second one merged must be refused (exit 24).
# Every fixture repo lives under a mktemp dir; the real HOME is never touched.
#
# Usage: bash scripts/handover/test-merge-on-green-static-recheck.sh
# shellcheck disable=SC2016,SC2034  # fixture scripts are written literally; MOG_LIB_ONLY and MOG_SETUP_SHA are read by the sourced harness
set -uo pipefail
MOG_LIB_ONLY=1
# shellcheck source=scripts/handover/test-merge-on-green.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-merge-on-green.sh"
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../lib/portable-timeout.sh"
export MERGE_STATIC_RECHECK=1 ARMAUTOMERGE=1

SR_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SR_G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
SR_SC_VER=$(shellcheck --version 2>/dev/null | sed -n 2p | sed 's/^version: //')
SR_PIN="v${SR_SC_VER:-0.0.0}.1"

no_merge_call() {
    if [ "$(grep -c '^pr merge ' "$LAST_GH_LOG")" -eq 0 ]; then pass; else fail "$1 (expected zero merge calls)"; fi
}

SR_DOCS="$MOG_SUITE_TMP/sr-docs"
sr_die() { echo "FATAL: $1" >&2; exit 1; }
sr_probe_env() { env -u CLAUDE_MD_MAX_BYTES -u BASH_ENV "$@"; }
sr_counted() {
    local line
    line=$(sr_probe_env CLAUDE_MD_MAX_BYTES=0 bash "$SR_ROOT/scripts/ci/check-claude-md-budget.sh" "$1" 2>&1 | grep -o 'is [0-9]* B of himmel content' | head -n 1)
    [ -n "$line" ] || sr_die "check-claude-md-budget.sh printed no 'is <n> B of himmel content' line for $1"
    line=${line#is }; echo "${line%% *}"
}
sr_line() { head -c $(($1 - 1)) /dev/zero | tr '\0' t; echo; }
mkdir -p "$SR_DOCS/probe/scripts/ci" "$SR_DOCS/probe/docs/handover" "$SR_DOCS/probe/.claude/commands" || sr_die "cannot create $SR_DOCS"
cp "$SR_ROOT/scripts/ci/check-doc-byte-budgets.sh" "$SR_DOCS/probe/scripts/ci/" || sr_die "cannot copy the table script"
for sr_f in docs/handover/worker-preface.md docs/handover/chief-template.md .claude/commands/pr-check.md; do printf 'x' > "$SR_DOCS/probe/$sr_f"; done
SR_PREFACE_MAX=$(sr_probe_env bash "$SR_DOCS/probe/scripts/ci/check-doc-byte-budgets.sh" | sed -n 's|^doc-byte-budgets: ok docs/handover/worker-preface.md [0-9]* <= \([0-9]*\)$|\1|p')
[ -n "$SR_PREFACE_MAX" ] || sr_die "the table script printed no ok line for the preface"
head -c 1048576 /dev/zero | tr '\0' x > "$SR_DOCS/probe-big.md"
printf '\n## graphify\nbody\n' >> "$SR_DOCS/probe-big.md"
SR_CMD_MAX=$(sr_probe_env bash "$SR_ROOT/scripts/ci/check-claude-md-budget.sh" "$SR_DOCS/probe-big.md" 2>&1 | sed -n 's/.*over the \([0-9]*\) B always-on budget.*/\1/p' | head -n 1)
[ -n "$SR_CMD_MAX" ] || sr_die "check-claude-md-budget.sh printed no 'over the <max> B' line"
sr_pf_total=$((SR_PREFACE_MAX - 100))
{ for ((sr_i = 0; sr_i < sr_pf_total / 99; sr_i++)); do sr_line 99; done
  sr_rem=$((sr_pf_total % 99)); [ "$sr_rem" -eq 0 ] || sr_line "$sr_rem"; } > "$SR_DOCS/worker-preface.md"
sr_pf_size=$(wc -c < "$SR_DOCS/worker-preface.md"); sr_pf_size=${sr_pf_size//[!0-9]/}
{ [ "$sr_pf_size" -gt $((SR_PREFACE_MAX - 143)) ] && [ "$sr_pf_size" -le $((SR_PREFACE_MAX - 77)) ]; } \
    || sr_die "the fixture preface is $sr_pf_size bytes, outside the window (${SR_PREFACE_MAX} - 143, ${SR_PREFACE_MAX} - 77]"
printf 'template\n' > "$SR_DOCS/chief-template.md"
printf 'pr-check\n' > "$SR_DOCS/pr-check.md"
printf '# fixture\n## graphify\nupstream text\n## Rules\n' > "$SR_DOCS/CLAUDE.md"
sr_c0=$(sr_counted "$SR_DOCS/CLAUDE.md")
sr_n=$(((SR_CMD_MAX - 150 - sr_c0) / 50))
[ "$sr_n" -gt 0 ] || sr_die "the checker's max ($SR_CMD_MAX) leaves no room for the fixture CLAUDE.md"
for ((sr_i = 0; sr_i < sr_n; sr_i++)); do sr_line 50; done >> "$SR_DOCS/CLAUDE.md"
sr_cmd_size=$(sr_counted "$SR_DOCS/CLAUDE.md")
{ [ "$sr_cmd_size" -gt $((SR_CMD_MAX - 200)) ] && [ "$sr_cmd_size" -le $((SR_CMD_MAX - 100)) ]; } \
    || sr_die "the fixture CLAUDE.md counts $sr_cmd_size B, outside the window (${SR_CMD_MAX} - 200, ${SR_CMD_MAX} - 100]"
printf 'x' > "$SR_DOCS/link-target"
printf '#!/usr/bin/env bash\nexport CLAUDE_MD_MAX_BYTES=999999\n' > "$SR_DOCS/bashenv.sh"

# sr_apply <anchor> <mode> — one side's change, left in the working tree.
#   wire     adds the hook n-hook.sh and wires it in .claude/settings.json
#   allow    adds the same hook and allowlists it (unwired) — green alone, a STALE
#            allowlist entry once the other side wires it
#   clean-a / clean-b  unrelated docs
#   sink     a newly added `cat "$1"` host-file read
#   lint     a script the pinned shellcheck rejects
#   ledgers  trips the ledgers-registry stub
#   conflict-x / conflict-y  the same file, differently
sr_apply() {
    local a="$1"
    case "$2" in
        wire)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$a/scripts/hooks/n-hook.sh"
            jq '.hooks.PreToolUse[0].hooks += [{"command":"bash scripts/hooks/n-hook.sh"}]' "$a/.claude/settings.json" > "$a/s.tmp" \
                && mv "$a/s.tmp" "$a/.claude/settings.json" ;;
        allow)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$a/scripts/hooks/n-hook.sh"
            echo 'n-hook.sh|called only from install.sh' >> "$a/scripts/testing/unwired-hooks-allowlist.txt" ;;
        clean-a) mkdir -p "$a/docs" && echo a > "$a/docs/a.txt" ;;
        clean-b) mkdir -p "$a/docs" && echo b > "$a/docs/b.txt" ;;
        sink)    printf '#!/usr/bin/env bash\ncontent=$(cat "$1")\necho "$content"\n' > "$a/scripts/read-sink.sh" ;;
        lint)    printf '#!/usr/bin/env bash\nfor f in $(ls); do echo "$f"; done\n' > "$a/scripts/bad-lint.sh" ;;
        ledgers) mkdir -p "$a/docs" && : > "$a/docs/.fail-ledgers" ;;
        conflict-x) mkdir -p "$a/docs" && echo x > "$a/docs/c.txt" ;;
        conflict-y) mkdir -p "$a/docs" && echo y > "$a/docs/c.txt" ;;
        pref-top) { sr_line 66; cat "$a/docs/handover/worker-preface.md"; } > "$a/s.tmp" && mv "$a/s.tmp" "$a/docs/handover/worker-preface.md" ;;
        pref-end) sr_line 77 >> "$a/docs/handover/worker-preface.md" ;;
        cmd-top) awk -v l="$(sr_line 100)" '{ print } /^## Rules$/ { print l }' "$a/CLAUDE.md" > "$a/s.tmp" && mv "$a/s.tmp" "$a/CLAUDE.md" ;;
        cmd-end) sr_line 100 >> "$a/CLAUDE.md" ;;
        tmpl-gone) rm -f "$a/docs/handover/chief-template.md" ;;
        cmd-nograph) grep -vx '## graphify' "$a/CLAUDE.md" > "$a/s.tmp"; mv "$a/s.tmp" "$a/CLAUDE.md" ;;
        cmd-gone) rm -f "$a/CLAUDE.md" ;;
        cmd-link) rm -f "$a/CLAUDE.md" && ln -s "$SR_DOCS/link-target" "$a/CLAUDE.md" ;;
        none) : ;;
        *) return 1 ;;
    esac
}

# sr_setup <anchor> — base B0 on origin main (the four real checks, or stubs),
# the PR head (SR_PR mode) at refs/pull/77/head, then the sibling (SR_SIB mode)
# landing on main AFTER the PR branched. SR_NOPULL=1 leaves the PR ref off
# origin; SR_MOVED=1 advances it past the certified head; SR_NOCHK=1 leaves the
# ledgers check out of the base; SR_PINREV overrides the shellcheck pin.
sr_setup() {
    local a="$1" b0 f
    mkdir -p "$a/docs/handover" "$a/scripts/hooks" "$a/scripts/testing" "$a/scripts/observability" "$a/scripts/ci" "$a/scripts/lint" "$a/.claude/commands" || return 1
    for f in scripts/testing/check-unwired-hooks.sh scripts/testing/test-unwired-hooks.sh scripts/ci/check-host-file-read-sinks.sh \
             scripts/lint/shell-lint.sh scripts/lint/hook-parse-check.sh \
             scripts/ci/check-doc-byte-budgets.sh scripts/ci/check-claude-md-budget.sh; do
        cp "$SR_ROOT/$f" "$a/$f" || return 1
    done
    cp "$SR_DOCS/worker-preface.md" "$a/docs/handover/worker-preface.md" \
        && cp "$SR_DOCS/chief-template.md" "$a/docs/handover/chief-template.md" \
        && cp "$SR_DOCS/pr-check.md" "$a/.claude/commands/pr-check.md" \
        && cp "$SR_DOCS/CLAUDE.md" "$a/CLAUDE.md" || return 1
    : > "$a/scripts/lint/shell-lint-baseline.tsv"
    : > "$a/docs/.keep"
    printf '#!/usr/bin/env bash\n[ "$#" -eq 0 ] || { echo "FAIL: ledgers stub got arguments: $*"; exit 1; }\n[ ! -e docs/.fail-ledgers ] || { echo "FAIL: ledgers stub"; exit 1; }\necho "PASS ledgers stub"\n' > "$a/scripts/observability/test-ledgers-registry.sh"
    [ "${SR_NOCHK:-0}" != 1 ] || rm -f "$a/scripts/observability/test-ledgers-registry.sh"
    if [ -n "${SR_ABSENT:-}" ]; then
        local -a absent
        IFS=' ' read -r -a absent <<< "$SR_ABSENT"
        for f in "${absent[@]}"; do rm -f "$a/$f"; done
    fi
    [ -z "${SR_DANGLE:-}" ] || { rm -f "$a/$SR_DANGLE" && ln -s /nonexistent-target "$a/$SR_DANGLE" || return 1; }
    # check-commit-msg.sh is the hook mog_build_fixture already lays down.
    for f in bus-deliver-hook.sh bus-deliver-sessionstart.sh bus-deliver-run.js wired-hook.sh check-commit-msg.sh; do
        [ -e "$a/scripts/hooks/$f" ] || : > "$a/scripts/hooks/$f"
    done
    printf 'bus-deliver-run.js|HIMMEL-5030 not wired yet\n' \
        > "$a/scripts/testing/unwired-hooks-allowlist.txt"
    echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash scripts/hooks/wired-hook.sh"},{"command":"bash scripts/hooks/check-commit-msg.sh"},{"command":"bash scripts/hooks/bus-deliver-hook.sh"},{"command":"bash scripts/hooks/bus-deliver-sessionstart.sh"}]}]}}' > "$a/.claude/settings.json"
    printf 'repos:\n  - repo: https://github.com/shellcheck-py/shellcheck-py\n    rev: %s\n    hooks:\n      - id: shellcheck\n' "${SR_PINREV:-$SR_PIN}" > "$a/.pre-commit-config.yaml"
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml CLAUDE.md && $SR_G -C "$a" commit -qm base && $SR_G -C "$a" push -q origin HEAD:main || return 1
    b0="$($SR_G -C "$a" rev-parse HEAD)"
    sr_apply "$a" "${SR_PR:-none}" || return 1
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml CLAUDE.md && $SR_G -C "$a" commit -q --allow-empty -m pr || return 1
    MOG_SETUP_SHA="$($SR_G -C "$a" rev-parse HEAD)"
    if [ "${SR_NOPULL:-0}" != 1 ]; then $SR_G -C "$a" push -q origin HEAD:refs/pull/77/head || return 1; fi
    if [ "${SR_MOVED:-0}" = 1 ]; then
        $SR_G -C "$a" commit -q --allow-empty -m moved && $SR_G -C "$a" push -q -f origin HEAD:refs/pull/77/head || return 1
    fi
    $SR_G -C "$a" checkout -q -b sibling "$b0" || return 1
    sr_apply "$a" "${SR_SIB:-none}" || return 1
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml CLAUDE.md && $SR_G -C "$a" commit -q --allow-empty -m sibling && $SR_G -C "$a" push -q origin HEAD:main || return 1
    return 0
}
sr_run() {
    MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=sr_setup run_mog "$@"
}

echo "== merge-on-green static re-check =="

# R0 (RED control) — with the gate off the pair merges, which is today's behaviour:
# each member is green alone, nothing sees them together.
MERGE_STATIC_RECHECK=0 SR_SIB=wire SR_PR=allow sr_run 0 "R0: gate off, the wire/allow pair merges (the defect)"
assert_audit_has "R0: the off switch is audited" "STATIC-RECHECK off"

# R1 (RED) — the sibling wired the hook on main, this PR allowlists it unwired:
# green alone, red together → refused before any merge call.
SR_SIB=wire SR_PR=allow sr_run 24 "R1: second of a wire/allow pair → exit 24"
assert_audit_has "R1: audited as a static-recheck refusal" "REFUSED reason=static-recheck"
assert_audit_has "R1: audit names the failing check" "failed=test-unwired-hooks"
assert_err_has "R1: stderr names the failing check" "test-unwired-hooks"
assert_clear_not_invoked "R1: nothing mutated before the refusal"
no_merge_call "R1: no merge call"
# R1b — the other order of the same pair.
SR_SIB=allow SR_PR=wire sr_run 24 "R1b: second of an allow/wire pair → exit 24"
no_merge_call "R1b: no merge call"

# R2 — a clean pair still merges, and the cost is printed.
SR_SIB=clean-a SR_PR=clean-b sr_run 0 "R2: a clean pair merges"
assert_audit_has "R2: audited as a pass" "STATIC-RECHECK ok"
assert_err_has "R2: the wall cost is printed" "static re-check passed"
# R3 — the first member of the pair, alone, merges.
SR_SIB=none SR_PR=allow sr_run 0 "R3: the lone first member merges"
SR_SIB=none SR_PR=wire sr_run 0 "R3b: the lone wiring member merges"

# R4 — the one off switch.
MERGE_STATIC_RECHECK=0 SR_SIB=wire SR_PR=allow sr_run 0 "R4: MERGE_STATIC_RECHECK=0 → merged"

# R5 — a textual conflict defers to the existing behind-main path.
SR_SIB=conflict-x SR_PR=conflict-y sr_run 0 "R5: a conflicting pair defers, not refused here"
assert_audit_has "R5: audited as skipped on a conflict" "STATIC-RECHECK skipped reason=conflict"

# R6 — each of the other checks refuses with its own name.
SR_SIB=none SR_PR=sink sr_run 24 "R6: a new host-file read sink → exit 24"
assert_err_has "R6: stderr names the sinks check" "check-host-file-read-sinks"
no_merge_call "R6: no merge call"
SR_SIB=none SR_PR=ledgers sr_run 24 "R6b: a ledgers-registry failure → exit 24"
assert_err_has "R6b: stderr names the ledgers check" "test-ledgers-registry"
if [ -n "$SR_SC_VER" ]; then
    SR_SIB=none SR_PR=lint sr_run 24 "R7: a shell-lint failure → exit 24"
    assert_err_has "R7: stderr names shell-lint" "shell-lint"
    # R9 — a shellcheck that is not the pin skips shell-lint only, loudly.
    SR_PINREV=v0.0.1.1 SR_SIB=none SR_PR=lint sr_run 0 "R9: shellcheck not the pin → shell-lint skipped"
    assert_err_has "R9: the skip is loud" "shell-lint SKIPPED"
    assert_audit_has "R9: the skip is audited" "skipped=shell-lint"
fi

# R10 — fail closed: the PR ref cannot be fetched; R11 — the fetched head is
# not the certified head; R13 — a check script missing from the merge result.
SR_NOPULL=1 sr_run 24 "R10: PR head unfetchable → exit 24"
no_merge_call "R10: no merge call"
SR_MOVED=1 sr_run 24 "R11: fetched head differs from the certified head → exit 24"
assert_audit_has "R11: audited as a head move" "phase=head-moved"
SR_NOCHK=1 sr_run 24 "R13: a missing check script fails closed → exit 24"
assert_err_has "R13: stderr names the missing check" "missing from the merge result"

# R13s — solo mode (an adopted project carries none of the harness's registries):
# a check whose script is ABSENT from the merge result is skipped and audited per
# check; one that is present still runs and still fails closed; outside solo a
# missing script is still exit 24.
SR_ALL3="scripts/testing/test-unwired-hooks.sh scripts/observability/test-ledgers-registry.sh scripts/ci/check-host-file-read-sinks.sh"
sr_solo_setup() { git -C "$1" config --local himmel.mergeMode solo && sr_setup "$1"; }
sr_solo_run() { MOG_ANCHOR_GIT=1 MOG_ANCHOR_SETUP=sr_solo_setup run_mog "$@"; }
SR_ABSENT="$SR_ALL3" SR_PR=clean-b sr_solo_run 0 "R13s-a: solo, all three checks absent → merged"
assert_audit_has "R13s-a: unwired-hooks skip audited" "STATIC-RECHECK skipped check=test-unwired-hooks reason=solo-absent"
assert_audit_has "R13s-a: ledgers skip audited" "STATIC-RECHECK skipped check=test-ledgers-registry reason=solo-absent"
assert_audit_has "R13s-a: host-file-read-sinks skip audited" "STATIC-RECHECK skipped check=check-host-file-read-sinks reason=solo-absent"
assert_audit_has "R13s-a: the merge is audited as solo" "mode=solo"
SR_ABSENT="scripts/observability/test-ledgers-registry.sh scripts/ci/check-host-file-read-sinks.sh" SR_SIB=wire SR_PR=allow \
    sr_solo_run 24 "R13s-b: solo, one check present and failing → exit 24"
assert_audit_has "R13s-b: the present check still fails closed" "failed=test-unwired-hooks"
no_merge_call "R13s-b: no merge call"
SR_ABSENT="scripts/ci/check-host-file-read-sinks.sh" SR_PR=clean-b sr_run 24 "R13s-c: not solo, one check absent → exit 24"
assert_err_has "R13s-c: stderr names the missing check" "missing from the merge result"
no_merge_call "R13s-c: no merge call"
SR_DANGLE="scripts/ci/check-host-file-read-sinks.sh" SR_PR=clean-b sr_solo_run 24 "R13s-d: solo, a dangling symlink at the script path is present, not absent → exit 24"
assert_err_has "R13s-d: stderr names the missing check" "missing from the merge result"
no_merge_call "R13s-d: no merge call"

# R14 — a dry run reports the refusal and mutates nothing.
SR_SIB=wire SR_PR=allow sr_run 24 "R14: --dry-run reports the refusal" --dry-run
assert_clear_not_invoked "R14: nothing mutated"

# R18 — a PR on a repo other than the anchor's (the supported not-adopted path)
# is not judged by the harness registries: skipped and audited, never exit 24.
# The wire/allow pair would refuse on the anchor's own repo, so a pass proves the skip.
STUB_NWO=other/repo SR_SIB=wire SR_PR=allow sr_run 0 "R18: PR on another repo → merged, recheck skipped"
assert_audit_has "R18: audited as skipped for another repo" "STATIC-RECHECK skipped reason=other-repo"
# R18b — an origin that cannot prove another repo (SSH alias) still runs the recheck.
MOG_ANCHOR_URL=git@gh-alias:owner/repo.git STUB_NWO=other/repo SR_SIB=wire SR_PR=allow sr_run 24 "R18b: unprovable origin → recheck runs, refuses"
# R18c — the same repo with a different case is not "other".
STUB_NWO=Owner/Repo SR_SIB=wire SR_PR=allow sr_run 24 "R18c: same repo, other case → recheck runs"

SR_SIB=pref-top SR_PR=pref-end sr_run 24 "R19: a pair under the preface budget alone, over it together → exit 24"
assert_err_has "R19: stderr names the table check" "doc-byte-budgets"
assert_audit_has "R19: audit names the table check" "failed=doc-byte-budgets"
assert_audit_lacks "R19: the pair merges cleanly, so it is judged and not deferred" "reason=conflict"
no_merge_call "R19: no merge call"
SR_SIB=pref-top SR_PR=clean-b sr_run 0 "R19b: sibling-only growth, PR clean → merged"
SR_SIB=clean-a SR_PR=pref-end sr_run 0 "R19b2: PR-only growth, sibling clean → merged"
SR_SIB=cmd-top SR_PR=cmd-end sr_run 24 "R19c: a CLAUDE.md pair over its budget together → exit 24"
assert_err_has "R19c: stderr names the CLAUDE.md check" "claude-md-budget"
assert_audit_has "R19c: audit names the CLAUDE.md check" "failed=claude-md-budget"
assert_audit_lacks "R19c: the pair merges cleanly, so it is judged and not deferred" "reason=conflict"
no_merge_call "R19c: no merge call"
SR_SIB=cmd-top SR_PR=clean-b sr_run 0 "R19c2: sibling-only CLAUDE.md growth → merged"
SR_SIB=clean-a SR_PR=cmd-end sr_run 0 "R19c2b: PR-only CLAUDE.md growth → merged"
CLAUDE_MD_MAX_BYTES=999999 SR_SIB=cmd-top SR_PR=cmd-end sr_run 24 "R19d: CLAUDE_MD_MAX_BYTES in the merging environment does not lift the budget"
BASH_ENV="$SR_DOCS/bashenv.sh" SR_SIB=cmd-top SR_PR=cmd-end sr_run 24 "R19d2: a BASH_ENV file that sets CLAUDE_MD_MAX_BYTES does not lift the budget"
SR_SIB=none SR_PR=tmpl-gone sr_run 24 "R19e: a deleted budgeted doc → exit 24"
assert_err_has "R19e: stderr names the table check" "doc-byte-budgets"
SR_SIB=none SR_PR=cmd-nograph sr_run 24 "R19g: CLAUDE.md without its graphify heading → exit 24"
assert_err_has "R19g: stderr names the CLAUDE.md check" "claude-md-budget"
SR_SIB=none SR_PR=cmd-gone sr_run 24 "R19h: a deleted CLAUDE.md → exit 24"
assert_err_has "R19h: stderr names the CLAUDE.md check" "claude-md-budget"
SR_SIB=none SR_PR=cmd-link sr_run 24 "R19i: a symlinked CLAUDE.md → exit 24"
assert_err_has "R19i: stderr names the CLAUDE.md check" "claude-md-budget"
assert_err_has "R19i: the link is refused before any read" "CLAUDE.md is a symlink in the merge result"
SR_ABSENT="scripts/ci/check-doc-byte-budgets.sh scripts/ci/check-claude-md-budget.sh" SR_PR=clean-b sr_solo_run 0 "R19s: solo, both budget scripts absent → merged"
assert_audit_has "R19s: the table skip is audited" "STATIC-RECHECK skipped check=doc-byte-budgets reason=solo-absent"
assert_audit_has "R19s: the CLAUDE.md skip is audited" "STATIC-RECHECK skipped check=claude-md-budget reason=solo-absent"
SR_ABSENT="scripts/ci/check-claude-md-budget.sh" SR_PR=cmd-link sr_solo_run 0 "R19s2: solo, the checker absent and CLAUDE.md a symlink → skipped, merged"
assert_audit_has "R19s2: the skip is audited" "STATIC-RECHECK skipped check=claude-md-budget reason=solo-absent"

# R15-R17 — the per-check ceiling needs a timeout tool: gtimeout stands in for
# timeout, with neither the gate refuses, and the tool gets a kill-after grace.
# sr_path_without <dir> — links every tool on PATH except timeout and gtimeout.
sr_path_without() {
    local d="$1" p f IFS=:
    mkdir -p "$d" || return 1
    for p in $PATH; do
        [ -d "$p" ] || continue
        for f in "$p"/*; do
            { [ -f "$f" ] && [ -x "$f" ]; } || continue
            case "${f##*/}" in timeout|gtimeout) continue ;; esac
            [ -e "$d/${f##*/}" ] || ln -s "$f" "$d/${f##*/}"
        done
    done
}
# sr_timeout_stub <dir> <name> — logs its ceiling arguments, then runs the command.
sr_timeout_stub() {
    mkdir -p "$1" || return 1
    printf '#!/usr/bin/env bash\necho "$1 $2 $3" >> "$SR_TO_LOG"\nshift 3\nexec "$@"\n' > "$1/$2" && chmod +x "$1/$2"
}
SR_NT="$MOG_SUITE_TMP/sr-notimeout"
SR_TO_LOG="$MOG_SUITE_TMP/sr-timeout.log"
export SR_TO_LOG
sr_path_without "$SR_NT"
sr_timeout_stub "$MOG_SUITE_TMP/sr-gt" gtimeout
sr_timeout_stub "$MOG_SUITE_TMP/sr-to" timeout
PATH="$SR_NT" SR_SIB=none SR_PR=clean-b sr_run 24 "R15: neither timeout nor gtimeout on PATH → exit 24"
assert_err_has "R15: stderr names the missing tool" "gtimeout"
assert_audit_has "R15: audited as a missing ceiling tool" "phase=no-timeout"
no_merge_call "R15: no merge call"
: > "$SR_TO_LOG"
PATH="$MOG_SUITE_TMP/sr-gt:$SR_NT" SR_SIB=none SR_PR=clean-b sr_run 0 "R16: gtimeout stands in for timeout → merged"
if grep -q -- '^-k 10 150$' "$SR_TO_LOG"; then pass; else fail "R16: gtimeout was not run with -k 10 150"; fi
: > "$SR_TO_LOG"
PATH="$MOG_SUITE_TMP/sr-to:$SR_NT" SR_SIB=none SR_PR=clean-b sr_run 0 "R17: timeout is run with a kill-after grace → merged"
if grep -q -- '^-k 10 150$' "$SR_TO_LOG"; then pass; else fail "R17: timeout was not run with -k 10 150"; fi

echo
echo "merge-on-green static re-check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
