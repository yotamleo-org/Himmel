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
export MERGE_STATIC_RECHECK=1 ARMAUTOMERGE=1

SR_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SR_G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null"
SR_SC_VER=$(shellcheck --version 2>/dev/null | sed -n 2p | sed 's/^version: //')
SR_PIN="v${SR_SC_VER:-0.0.0}.1"

no_merge_call() {
    if [ "$(grep -c '^pr merge ' "$LAST_GH_LOG")" -eq 0 ]; then pass; else fail "$1 (expected zero merge calls)"; fi
}

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
    mkdir -p "$a/docs" "$a/scripts/hooks" "$a/scripts/testing" "$a/scripts/observability" "$a/scripts/ci" "$a/scripts/lint" "$a/.claude" || return 1
    for f in scripts/testing/check-unwired-hooks.sh scripts/testing/test-unwired-hooks.sh scripts/ci/check-host-file-read-sinks.sh \
             scripts/lint/shell-lint.sh scripts/lint/hook-parse-check.sh; do
        cp "$SR_ROOT/$f" "$a/$f" || return 1
    done
    : > "$a/scripts/lint/shell-lint-baseline.tsv"
    : > "$a/docs/.keep"
    printf '#!/usr/bin/env bash\n[ "$#" -eq 0 ] || { echo "FAIL: ledgers stub got arguments: $*"; exit 1; }\n[ ! -e docs/.fail-ledgers ] || { echo "FAIL: ledgers stub"; exit 1; }\necho "PASS ledgers stub"\n' > "$a/scripts/observability/test-ledgers-registry.sh"
    [ "${SR_NOCHK:-0}" != 1 ] || rm -f "$a/scripts/observability/test-ledgers-registry.sh"
    # check-commit-msg.sh is the hook mog_build_fixture already lays down.
    for f in bus-deliver-hook.sh bus-deliver-sessionstart.sh bus-deliver-run.js wired-hook.sh check-commit-msg.sh; do
        [ -e "$a/scripts/hooks/$f" ] || : > "$a/scripts/hooks/$f"
    done
    printf 'bus-deliver-hook.sh|HIMMEL-5030 not wired yet\nbus-deliver-sessionstart.sh|HIMMEL-5030 not wired yet\nbus-deliver-run.js|HIMMEL-5030 not wired yet\n' \
        > "$a/scripts/testing/unwired-hooks-allowlist.txt"
    echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash scripts/hooks/wired-hook.sh"},{"command":"bash scripts/hooks/check-commit-msg.sh"}]}]}}' > "$a/.claude/settings.json"
    printf 'repos:\n  - repo: https://github.com/shellcheck-py/shellcheck-py\n    rev: %s\n    hooks:\n      - id: shellcheck\n' "${SR_PINREV:-$SR_PIN}" > "$a/.pre-commit-config.yaml"
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml && $SR_G -C "$a" commit -qm base && $SR_G -C "$a" push -q origin HEAD:main || return 1
    b0="$($SR_G -C "$a" rev-parse HEAD)"
    sr_apply "$a" "${SR_PR:-none}" || return 1
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml && $SR_G -C "$a" commit -q --allow-empty -m pr || return 1
    MOG_SETUP_SHA="$($SR_G -C "$a" rev-parse HEAD)"
    if [ "${SR_NOPULL:-0}" != 1 ]; then $SR_G -C "$a" push -q origin HEAD:refs/pull/77/head || return 1; fi
    if [ "${SR_MOVED:-0}" = 1 ]; then
        $SR_G -C "$a" commit -q --allow-empty -m moved && $SR_G -C "$a" push -q -f origin HEAD:refs/pull/77/head || return 1
    fi
    $SR_G -C "$a" checkout -q -b sibling "$b0" || return 1
    sr_apply "$a" "${SR_SIB:-none}" || return 1
    $SR_G -C "$a" add -A -- scripts docs .claude .pre-commit-config.yaml && $SR_G -C "$a" commit -q --allow-empty -m sibling && $SR_G -C "$a" push -q origin HEAD:main || return 1
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
