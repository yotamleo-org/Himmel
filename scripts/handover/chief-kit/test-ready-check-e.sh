#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2153,SC2154
set -uo pipefail
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

jira_db_bug_rows
# ── 16. outside-PR full review ─────────────────────────────
# The rows run a copy of ready-check in a temp anchor tree: the real lib/,
# ci/, testing/ and cr/blast-scope.cjs, plus a stub scripts/check-ci.sh, and
# a temp HOME whose allowlist lists Goomal (login and id) unless a row says
# otherwise. No PR code runs: every input is a synthetic fixture.
OUT_ANCHOR="$tmp/out-anchor"
OUT_SCRIPT="$OUT_ANCHOR/scripts/handover/chief-kit/ready-check.sh"
OUT_HOME="$tmp/out-home"
OUT_CHECKCI_LOG="$tmp/checkci.log"
export OUT_CHECKCI_LOG
GOOMAL_ID=U_kgDOBieNbw
mkdir -p "$OUT_ANCHOR/scripts/handover/chief-kit" "$OUT_ANCHOR/scripts/cr/perspectives" "$OUT_HOME/.himmel"
cp "$SCRIPT" "$OUT_SCRIPT"
cp -R "$HERE/../../lib" "$HERE/../../ci" "$HERE/../../testing" "$OUT_ANCHOR/scripts/"
[ ! -f "$HERE/../../cr/blast-scope.cjs" ] || cp "$HERE/../../cr/blast-scope.cjs" "$OUT_ANCHOR/scripts/cr/blast-scope.cjs"
# item 18 runs the anchor's clear-review-marker.sh --check-findings
cp "$HERE/../../cr/clear-review-marker.sh" "$HERE/../../cr/anchor-handoff.sh" "$HERE/../../cr/ledger-amend-auth.js" "$HERE/../../cr/review-round.sh" "$OUT_ANCHOR/scripts/cr/"
cp "$HERE/../../chokepoints.json" "$OUT_ANCHOR/scripts/chokepoints.json"
# item 19 runs the anchor's impacted-suites.sh: the same stub as the other anchor (it lists nothing)
cp "$TP_ANCHOR/scripts/cr/impacted-suites.sh" "$OUT_ANCHOR/scripts/cr/impacted-suites.sh"
# a fixture perspective: B3 has not written the real one
printf 'fixture outside-security perspective\n' > "$OUT_ANCHOR/scripts/cr/perspectives/outside-security.md"
cat > "$OUT_ANCHOR/scripts/check-ci.sh" <<'STUB'
#!/usr/bin/env bash
# stub check-ci: logs the CodeRabbit env it saw; CR_APP=0 / CR_PROFILE=none skip the findings read, as the real one does
printf 'args=%s CR_APP=%s CR_PROFILE=%s CR_BOT_USER_ID=%s\n' "$*" "${CR_APP-unset}" "${CR_PROFILE-unset}" "${CR_BOT_USER_ID-unset}" >> "$OUT_CHECKCI_LOG"
[ -z "${STUB_CHECKCI_SLEEP:-}" ] || sleep 60
[ "${CR_APP:-}" != 0 ] && [ "${CR_PROFILE:-}" != none ] || exit 0
exit "${STUB_CHECKCI_RC:-0}"
STUB
chmod +x "$OUT_ANCHOR/scripts/check-ci.sh"
out_list_goomal() { printf '[{"login":"Goomal","id":"%s"}]\n' "$GOOMAL_ID" > "$OUT_HOME/.himmel/outside-contributors.json"; }
OUT_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-04T00:00:00Z"},{"context":"legacy-ci","state":"SUCCESS"}]'
OUT_BRANCH=feat/himmel-100-thing
BASE40=2222222222222222222222222222222222222222
row_scope() {  # row_scope <scope> [head] [branch] [from] [pr] [round]
    local from_json=null pr_json=null src=panel-first-pass
    [ -z "${4:-}" ] || from_json="\"$4\""
    [ -z "${5:-}" ] || { pr_json="$5"; src="pr-diff"; }
    printf '{"kind":"round-scope","ts":"2026-11-04T00:00:01Z","branch":"%s","head":"%s","scope":"%s","base_sha":"%s","from":%s,"round":%s,"source":"%s","pr":%s,"status":"ok"}\n' \
        "${3:-$OUT_BRANCH}" "${2:-$SHA}" "$1" "$BASE40" "$from_json" "${6:-1}" "$src" "$pr_json" >> "$LEDGER"
}
row_impacted() {  # row_impacted [rc] [skip_n] [head] [branch]
    printf '{"kind":"impacted","ts":"2026-11-04T00:00:02Z","branch":"%s","head":"%s","impacted_n":3,"unverdicted_n":0,"skip_n":%s,"rc":%s,"status":"ok"}\n' \
        "${4:-$OUT_BRANCH}" "${3:-$SHA}" "${2:-0}" "${1:-0}" >> "$LEDGER"
}
# out_reset: an outside PR (a fork, by the listed Goomal) with every 16b-16g record at $SHA
out_reset() {
    reset_stubs
    out_list_goomal
    : > "$OUT_CHECKCI_LOG"
    STUB_FORK=true STUB_AUTHOR=Goomal STUB_AUTHOR_ID="$GOOMAL_ID" STUB_ROLLUP="$OUT_ROLLUP"
    row_scope full
    row_impacted
}
run_out() { RUN_SCRIPT="$OUT_SCRIPT" RUN_HOME="$OUT_HOME" run; }

# T1.1: an outside PR whose only round-scope row at the head is a delta row is refused
out_reset
seed_ledger_ok; row_scope delta "$SHA" "$OUT_BRANCH" "$BASE40" "" 2; row_impacted
rc=0; out="$(run_out)" || rc=$?
check "T1.1 outside PR with only a delta round at the head: exit 1" "$rc" "1"
contains "T1.1 outside PR with only a delta round at the head: 16b fails" "$out" "[FAIL] 16b."

OUT_PERSP_SHA=$(sha256sum "$OUT_ANCHOR/scripts/cr/perspectives/outside-security.md" | awk '{print $1}')
H2=1111111111111111111111111111111111111111
OUT_REPORT="$tmp/audit-report.md"
row_blast() {  # row_blast [status] [head] [branch]
    printf '{"kind":"blast","ts":"2026-11-04T00:00:03Z","branch":"%s","head":"%s","status":"%s","duration_secs":60}\n' "${3:-$OUT_BRANCH}" "${2:-$SHA}" "${1:-ran}" >> "$LEDGER"
}
row_audit() {  # row_audit <verdict> [head] [pr] [perspective sha]
    printf 'fixture audit report\n' > "$OUT_REPORT"
    printf '{"kind":"security-audit","ts":"2026-11-04T00:00:04Z","branch":"%s","head":"%s","pr":%s,"verdict":"%s","perspective_sha256":"%s","report":"%s","report_sha256":"%s","status":"ok"}\n' \
        "$OUT_BRANCH" "${2:-$SHA}" "${3:-$PR}" "$1" "${4:-$OUT_PERSP_SHA}" "$OUT_REPORT" "$(sha256sum "$OUT_REPORT" | awk '{print $1}')" >> "$LEDGER"
}
out_unlist() { rm -f "$OUT_HOME/.himmel/outside-contributors.json"; }
OUT_CR_OK='Review completed'
# path_without <name>...: a PATH dir of links to every command on PATH but the named ones
path_without() {
    local d="$tmp/pathwo-$*" dir f
    d="${d// /-}"
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
    mkdir -p "$d"
    local IFS=:
    for dir in $PATH; do
        for f in "$dir"/*; do
            [ -x "$f" ] && [ ! -d "$f" ] || continue
            case " $* " in *" ${f##*/} "*) continue ;; esac
            [ -e "$d/${f##*/}" ] || ln -s "$f" "$d/${f##*/}"
        done
    done
    printf '%s' "$d"
}

printf "console.log('codeowner-review-gate: PASS — yotamleo has admin permission — not an outside PR');\n" > "$tmp/or-gate-owner.mjs"
export STUB_OR_GATE_FILE="$tmp/or-gate-owner.mjs"

# T1.3/T1.3b: the base ready-check's output on this fixture, captured before item 16 existed
mkdir -p "$tmp/no-handovers"
export HANDOVER_DIR="$tmp/no-handovers"
GOLD_MEMBER="[PASS] 1. head=$SHA matches, mergeStateStatus=CLEAN
[PASS] 2. statusCheckRollup: 2/2 checks completed SUCCESS/SKIPPED/NEUTRAL
[PASS] 3. unresolved review threads = 0
[PASS] 4. CR ledger: 1 row(s) for $SHA with status=ok
[PASS] 5. branch: Platforms tested (needed=1), Security reviewed (needed=1) — attested where needed
[PASS] 6. every commit subject carries a ticket ID
[PASS] 7. ticket coverage: every ask is done or deferred to an open ticket
[PASS] 9. no plugin files touched — version bump not applicable
[PASS] 10. no workflow files touched — workflow_dispatch run not applicable
[PASS] 11. the PR adds no files — added-but-unwired not applicable
[PASS] 12. trust path: none
[PASS] 13. the PR body names a RED-then-GREEN line
[WARN] 14. bug-origin not checked: type
[WARN] 17. partial-merge remainder not checked: no --contract given for HIMMEL-100 (a GO writer names it)
[PASS] 18. no blocking or undecided finding at the head the merge gates on (read as the merge reads it, with and without the GO)
[PASS] 19. suite evidence: 0 impacted, nothing to prove
[PASS] 20. conflicts resolved: no hand-resolved merge conflict in origin/main..${SHA:0:7}
[WARN] 21. ticket comments of HIMMEL-100 not checked: no worker handover doc named HIMMEL-100-N*.md under $tmp/no-handovers
---
The three-dot diff read (git diff origin/main...HEAD) stays the chief's own judgement — this script does not read it.
owner-review: not-required (rule-a: yotamleo has admin permission; check at head: none)
TRUST-PATH: no
READY-CHECK PASS
rc=0"
GOLD_BOT6="${GOLD_MEMBER/\[PASS\] 6. every commit subject carries a ticket ID/[FAIL] 6. commit subject(s) missing a ticket ID: chore: unkeyed}"
GOLD_BOT6="${GOLD_BOT6/READY-CHECK PASS/READY-CHECK FAIL}"
GOLD_BOT6="${GOLD_BOT6/rc=0/rc=1}"
reset_stubs
out="$(run; echo "rc=$?")"
check "T1.3 an org-member PR's output is byte-identical to base" "$out" "$GOLD_MEMBER"
reset_stubs
out="$(STUB_AUTHOR=app/github-actions run; echo "rc=$?")"
check "T1.3b a same-repo Bot PR's output is byte-identical to base" "$out" "$GOLD_MEMBER"
reset_stubs
out="$(STUB_AUTHOR=app/github-actions STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"chore: unkeyed","messageBody":""}]' run; echo "rc=$?")"
check "T1.3b a same-repo Bot PR's item 6 FAIL is byte-identical to base" "$out" "$GOLD_BOT6"

# T1.5/T1.10-T1.13: --outside prints the predicate
reset_stubs
out="$(RUN_MODE=outside run)"; check "T1.5 --outside: an internal same-repo author is not outside" "$out" "outside-pr: no"
out="$(STUB_FORK=true RUN_MODE=outside run)"; check "T1.10 --outside: a fork by an internal login is outside" "$out" "outside-pr: yes"
rc=0; out="$(STUB_FORK=true run)" || rc=$?
contains "T1.10 a fork by an internal login runs item 16" "$out" "[FAIL] 16. outside-PR full review:"
out="$(STUB_AUTHOR_EMPTY=1 RUN_MODE=outside run)"; check "T1.11 --outside: a deleted (null) author is outside" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=Goomal RUN_MODE=outside run)"; check "T1.5 --outside: an unlisted same-repo author is outside" "$out" "outside-pr: yes"
mv "$OUT_ANCHOR/scripts/ci/ticket-id-internal-authors.txt" "$tmp/internal-aside.txt"
out="$(RUN_SCRIPT="$OUT_SCRIPT" RUN_MODE=outside run)"; check "T1.12 --outside: an unreadable internal-author list makes the author outside" "$out" "outside-pr: yes"
mv "$tmp/internal-aside.txt" "$OUT_ANCHOR/scripts/ci/ticket-id-internal-authors.txt"
out="$(RUN_SCRIPT="$OUT_SCRIPT" RUN_MODE=outside run)"; check "T1.12 control: the same author with the list back is not outside" "$out" "outside-pr: no"
out="$(TICKET_ID_INTERNAL_AUTHORS_FILE="$tmp/nobody.txt" RUN_MODE=outside run)"; check "T1.12 the TICKET_ID_INTERNAL_AUTHORS_FILE override is not honoured" "$out" "outside-pr: no"
out="$(STUB_AUTHOR=app/github-actions RUN_MODE=outside run)"; check "T1.13 --outside: a same-repo Bot (github-actions) is not outside" "$out" "outside-pr: no"
out="$(STUB_AUTHOR=app/github-actions STUB_FORK=true RUN_MODE=outside run)"; check "T1.13 --outside: a fork Bot is outside" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=github-actions RUN_MODE=outside run)"; check "T1.13 --outside: a User named like a bot is judged by type, not login" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=dependabot RUN_MODE=outside run)"; check "T1.13 --outside: a User named dependabot is outside" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=app/dependabot RUN_MODE=outside run)"; check "T1.13 --outside: the dependabot Bot is not outside" "$out" "outside-pr: no"
rc=0; out="$(STUB_SNAPSHOT_FAIL=1 RUN_MODE=outside run 2>&1)" || rc=$?
check "T1.5 --outside: an unreadable snapshot exits 2" "$rc" "2"
notcontains "T1.5 --outside: an unreadable snapshot prints no verdict" "$out" "outside-pr:"
rc=0; out="$(RUN_MODE=outside run 2>&1)" || rc=$?
check "T1.5 --outside: exit 0" "$rc" "0"

# 6b: scripts/cr/pr-check-outside.sh, the /pr-check step-0 question, answers as --outside does
WRAP="$HERE/../../cr/pr-check-outside.sh"
cp "$WRAP" "$OUT_ANCHOR/scripts/cr/pr-check-outside.sh"
out="$(RUN_SCRIPT="$WRAP" RUN_MODE=wrapper run)"; check "T1.14 wrapper: an internal same-repo author is not outside" "$out" "outside-pr: no"
out="$(STUB_FORK=true RUN_SCRIPT="$WRAP" RUN_MODE=wrapper run)"; check "T1.14 wrapper: a fork is outside" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=Goomal RUN_SCRIPT="$WRAP" RUN_MODE=wrapper run)"; check "T1.14 wrapper: an unlisted same-repo author is outside" "$out" "outside-pr: yes"
out="$(STUB_AUTHOR=app/github-actions RUN_SCRIPT="$WRAP" RUN_MODE=wrapper run)"; check "T1.14 wrapper: a same-repo Bot is not outside" "$out" "outside-pr: no"
mv "$OUT_ANCHOR/scripts/ci/ticket-id-internal-authors.txt" "$tmp/internal-aside.txt"
out="$(RUN_SCRIPT="$OUT_ANCHOR/scripts/cr/pr-check-outside.sh" RUN_MODE=wrapper run)"; check "T1.14 wrapper: an unreadable internal-author list makes the author outside" "$out" "outside-pr: yes"
mv "$tmp/internal-aside.txt" "$OUT_ANCHOR/scripts/ci/ticket-id-internal-authors.txt"
rc=0; out="$(STUB_SNAPSHOT_FAIL=1 RUN_SCRIPT="$WRAP" RUN_MODE=wrapper run 2>&1)" || rc=$?
check "T1.14 wrapper: an unreadable snapshot exits 2" "$rc" "2"
notcontains "T1.14 wrapper: an unreadable snapshot prints no verdict" "$out" "outside-pr:"
rc=0; out="$(RUN_SCRIPT="$WRAP" RUN_MODE=none run 2>&1)" || rc=$?
check "T1.14 wrapper: no pr-number exits 2" "$rc" "2"

# 7b: 16b, the full round at the head
out_reset; seed_ledger_ok; row_scope delta "$SHA" "$OUT_BRANCH" "$BASE40" "" 2; row_impacted
out="$(run_out)"; contains "T1.6 a delta-only head FAILs 16b naming its from" "$out" "only a delta round (from 2222222)"
out_reset; seed_ledger_ok; row_scope delta "$SHA" "$OUT_BRANCH" "$BASE40" "" 4; row_impacted
out="$(run_out)"; contains "T1.7 a post-cap delta row FAILs 16b naming the takeover" "$out" "hand it to a maintainer takeover"
out_reset; seed_ledger_ok; row_scope full "$H2"; row_impacted
out="$(run_out)"; contains "T1.8 a full row at another (parent) head FAILs 16b" "$out" "[FAIL] 16b. no full review round"
out_reset; seed_ledger_ok; row_scope full "$SHA" other/branch; row_impacted
out="$(run_out)"; contains "T1.9 a full row on another branch FAILs 16b" "$out" "[FAIL] 16b. no full review round"
out_reset; seed_ledger_ok; row_scope full "$SHA" "$OUT_BRANCH" "" 78; row_impacted
out="$(run_out)"; contains "T1.14 a full row for another PR FAILs 16b" "$out" "[FAIL] 16b."
out_reset; seed_ledger_ok; row_scope full "$SHA" "$OUT_BRANCH" "" "$PR"; row_impacted
out="$(run_out)"; contains "T1.14 control: a full row for this PR passes 16b" "$out" "[PASS] 16b."
out_reset; rm -f "$LEDGER"
out="$(run_out)"; contains "T1.15 a missing ledger FAILs 16b" "$out" "[FAIL] 16b. cannot read the CR ledger"

# 7c: 16c, the lint run, and 16d, the lint surface
out_reset
out="$(STUB_ROLLUP='[{"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-04T00:00:00Z"},{"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-04T01:00:00Z"}]' run_out)"
contains "T1.16 an older lint SUCCESS under a newer FAILURE FAILs 16c" "$out" "[FAIL] 16c. the latest lint run of workflow CI at ${SHA:0:7} is COMPLETED/FAILURE"
out="$(STUB_ROLLUP='[{"name":"lint (deferred)","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]' run_out)"
contains "T1.17 only a lint (deferred) run FAILs 16c" "$out" "[FAIL] 16c. no lint run"
out="$(STUB_ROLLUP='[{"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SKIPPED"}]' run_out)"
contains "T1.17 a SKIPPED lint run FAILs 16c" "$out" "[FAIL] 16c. the latest lint run of workflow CI at ${SHA:0:7} is COMPLETED/SKIPPED"
out="$(STUB_ROLLUP='[{"name":"lint","workflowName":"Other","status":"COMPLETED","conclusion":"SUCCESS"}]' run_out)"
contains "T1.18 a lint run of another workflow FAILs 16c" "$out" "[FAIL] 16c. no lint run"
out="$(STUB_ROLLUP='[]' run_out)"
contains "T1.19 an empty rollup FAILs 16c" "$out" "[FAIL] 16c."
out="$(run_out)"; contains "T1.16 control: the fixture's lint run passes 16c" "$out" "[PASS] 16c."
surf_n=0
while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    surf_n=$((surf_n + 1))
    case "$p" in */) f="${p}x" ;; *) f="$p" ;; esac
    out="$(STUB_FILES="$f" run_out)"
    contains "T1.61 a path under the surface line '$p' FAILs 16d" "$out" "[FAIL] 16d."
done < "$HERE/../../ci/outside-lint-surface.txt"
check "T1.61 the lint surface lists eleven prefixes" "$surf_n" "11"
out="$(STUB_FILES=scripts/lanes/skill-cost.mjs run_out)"; contains "T1.61b a scripts/lanes/skill-cost.mjs change FAILs 16d" "$out" "[FAIL] 16d."
out="$(STUB_FILES=.shellcheckrc run_out)"; contains "T1.20 a .shellcheckrc change FAILs 16d" "$out" "[FAIL] 16d."
out="$(STUB_FILES=.coderabbit.yaml run_out)"; contains "T1.20 a .coderabbit.yaml change FAILs 16d" "$out" "[FAIL] 16d."
out="$(STUB_FILES=.github/ci-image/Dockerfile run_out)"; contains "T1.21 a .github/ci-image/ change FAILs 16d" "$out" "[FAIL] 16d."
out="$(STUB_FILES=scripts/x/new.sh STUB_RENAMES='scripts/x/new.sh scripts/ci/old.sh' run_out)"
contains "T1.21 a rename out of scripts/ci/ FAILs 16d" "$out" "[FAIL] 16d."
out="$(run_out)"; contains "T1.20 control: a README change passes 16d" "$out" "[PASS] 16d."
cp "$OUT_ANCHOR/scripts/ci/outside-lint-surface.txt" "$tmp/surface-aside.txt"
printf '# empty\n' > "$OUT_ANCHOR/scripts/ci/outside-lint-surface.txt"
out="$(run_out)"; contains "T1.61 an empty lint-surface file FAILs 16d" "$out" "[FAIL] 16d. cannot read scripts/ci/outside-lint-surface.txt"
cp "$tmp/surface-aside.txt" "$OUT_ANCHOR/scripts/ci/outside-lint-surface.txt"
out="$(RUN_MODE=only7 run_out)"
notcontains "T1.62 --only 7 on an outside PR prints no item 16 line" "$out" "16."
contains "T1.62 --only 7 still lints coverage" "$out" "COVERAGE-LINT PASS"
out="$(STUB_FILES16_EMPTY=1 run_out)"
contains "T1.42 an empty files list FAILs 16d" "$out" "[FAIL] 16d. cannot read the PR's files"
contains "T1.42 an empty files list FAILs 16g" "$out" "[FAIL] 16g."
rc=0; out="$(PATH="$tmp/no-timeout:$PATH" run_out)" || rc=$?
contains "T1.43 no timeout binary FAILs item 16" "$out" "[FAIL] 16. outside-PR full review: no timeout binary"
check "T1.43 no timeout binary: exit 1" "$rc" "1"
out="$(STUB_ROLLUP_NULL=1 run_out)"; contains "T1.44 an unreadable rollup FAILs 16c" "$out" "[FAIL] 16c. statusCheckRollup unreadable"
out="$(STUB_FILES16_FAIL=1 run_out)"
contains "T1.44 an unreadable files list FAILs 16d" "$out" "[FAIL] 16d. cannot read the PR's files"
contains "T1.44 an unreadable files list FAILs 16g" "$out" "[FAIL] 16g."
row_blast
chmod 000 "$LEDGER"
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"
chmod 600 "$LEDGER"
contains "T1.44 an unreadable ledger FAILs 16f" "$out" "[FAIL] 16f."
contains "T1.44 an unreadable ledger FAILs 16g" "$out" "[FAIL] 16g."
rc=0; out="$(STUB_FORK_JSON='"yes"' run_out)" || rc=$?
contains "T1.44 a non-boolean isCrossRepository fails the snapshot" "$out" "[FAIL] 1."
contains "T1.44 a non-boolean isCrossRepository FAILs item 16" "$out" "[FAIL] 16. outside-PR full review: cannot tell"
check "T1.44 a non-boolean isCrossRepository: exit 1" "$rc" "1"

# 7d: 16e threads, 16f impacted, 16g blast
out_reset
out="$(STUB_RESOLVED_BY=Goomal run_out)"
contains "T1.22 a thread the author resolved FAILs 16e" "$out" "unresolve, then resolve as a maintainer"
out="$(STUB_RESOLVED_BY=coderabbitai run_out)"
contains "T1.22 a thread CodeRabbit resolved FAILs 16e" "$out" "[FAIL] 16e. thread(s) resolved by a non-maintainer: coderabbitai"
out="$(STUB_RESOLVED_BY=null run_out)"
contains "T1.22 a thread with no readable resolver FAILs 16e" "$out" "[FAIL] 16e."
out="$(STUB_RESOLVED_BY=yotamleo run_out)"
contains "T1.22 a thread a maintainer resolved passes 16e" "$out" "[PASS] 16e."
out="$(STUB_UNRESOLVED=1 run_out)"
contains "T1.22 an open thread FAILs 16e" "$out" "[FAIL] 16e. 1 unresolved thread(s)"
out="$(STUB_CHECKCI_RC=1 run_out)"; contains "T1.23 check-ci --threads-only exit 1 FAILs 16e" "$out" "--threads-only exited 1"
out="$(STUB_CHECKCI_RC=2 run_out)"; contains "T1.23 check-ci --threads-only exit 2 FAILs 16e" "$out" "--threads-only exited 2"
contains "T1.23 check-ci ran as --threads-only on the PR" "$(cat "$OUT_CHECKCI_LOG")" "args=77 --threads-only"
mv "$OUT_ANCHOR/scripts/check-ci.sh" "$tmp/checkci-aside.sh"
out="$(run_out)"; contains "T1.23 a missing check-ci FAILs 16e" "$out" "scripts/check-ci.sh not found"
mv "$tmp/checkci-aside.sh" "$OUT_ANCHOR/scripts/check-ci.sh"
t0=$(date +%s)
out="$(STUB_CHECKCI_SLEEP=1 run_out)"
t1=$(date +%s)
contains "T1.23 a hung check-ci FAILs 16e at the bound" "$out" "past its 20s bound"
check "T1.23 a hung check-ci is cut off within the bound" "$([ $((t1 - t0)) -lt 55 ] && echo yes || echo no)" "yes"
out_reset; row_impacted 1
out="$(run_out)"
contains "T1.24 an impacted row with rc 1 FAILs 16f" "$out" "[FAIL] 16f."
contains "T1.24 the 16f line names the takeover" "$out" "the maintainer takeover"
out_reset; row_impacted 0 2
out="$(run_out)"; contains "T1.24 an impacted row with skip_n 2 FAILs 16f" "$out" "(newest: 0 2)"
out_reset; seed_ledger_ok; row_scope full; row_impacted 0 0 "$SHA" other/branch
out="$(run_out)"; contains "T1.25 an impacted row on another branch FAILs 16f" "$out" "[FAIL] 16f."
out_reset; seed_ledger_ok; row_scope full; row_impacted 0 0 "$H2"
out="$(run_out)"; contains "T1.25 an impacted row at another head FAILs 16f" "$out" "[FAIL] 16f."
out_reset; row_blast ran "$H2"
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"; contains "T1.25 a blast row at another head FAILs 16g" "$out" "[FAIL] 16g."
out_reset; row_blast ran "$SHA" other/branch
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"; contains "T1.25 a blast row on another branch FAILs 16g" "$out" "[FAIL] 16g."
out_reset; row_blast ran
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"; contains "T1.25 a blast row keyed to headRefName (written from main) passes 16g" "$out" "[PASS] 16g. a blast run is recorded"
out_reset
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"; contains "T1.26 a blast-scope diff with no blast row FAILs 16g" "$out" "[FAIL] 16g. the diff touches the blast scope"
out_reset; row_blast off
out="$(STUB_FILES=scripts/hooks/guard-x.sh run_out)"; contains "T1.26 an off blast row FAILs 16g" "$out" "[FAIL] 16g."
out_reset
out="$(STUB_FILES=scripts/x/moved.sh STUB_RENAMES='scripts/x/moved.sh scripts/hooks/guard-x.sh' run_out)"
contains "T1.26 a rename out of scripts/hooks/ still needs the blast row" "$out" "[FAIL] 16g. the diff touches the blast scope"
out="$(run_out)"; contains "T1.27 a non-scope diff needs no blast row" "$out" "[PASS] 16g. the diff does not touch the blast scope"

# 7e
out_reset
rc=0; out="$(run_out)" || rc=$?
check "T1.28 an outside PR with every record at the head: exit 0" "$rc" "0"
contains "T1.28 every record at the head passes item 16" "$out" "[PASS] 16. outside-PR full review: every record present at ${SHA:0:7}"
SHA_KEEP="$SHA"; SHA="$H2"
rc=0; out="$(STUB_HEAD="$H2" run_out)" || rc=$?
SHA="$SHA_KEEP"
check "T1.28 the same records then a new head: exit 1" "$rc" "1"
contains "T1.28 a new head invalidates the full round" "$out" "[FAIL] 16b. no full review round at 1111111"
contains "T1.28 a new head invalidates the impacted row" "$out" "[FAIL] 16f."
out_reset; seed_ledger_ok
rc=0; out="$(STUB_BODY="## Ticket coverage\n- ask: done\nfull review done at $SHA\n" STUB_PR_TITLE="feat(x): [HIMMEL-100] full-review thing" run_out)" || rc=$?
check "T1.29 a body line and a title token change nothing: exit 1" "$rc" "1"
contains "T1.29 a body line and a title token change nothing: 16b" "$out" "[FAIL] 16b."
rc=0; out="$(PATH="$(path_without node)" run_out)" || rc=$?
contains "T1.39 a missing node FAILs item 16" "$out" "[FAIL] 16. outside-PR full review: node not found"
check "T1.39 a missing node: exit 1" "$rc" "1"
rc=0; out="$(PATH="$(path_without jq)" run_out 2>&1)" || rc=$?
check "T1.39 a missing jq: exit 2 (cannot evaluate)" "$rc" "2"
notcontains "T1.39 a missing jq prints no PASS" "$out" "READY-CHECK PASS"

# 7g: 16h, an unlisted author's CodeRabbit status
out_reset; out_unlist
out="$(run_out)"
contains "T1.46 an unlisted author with no CodeRabbit status FAILs 16h" "$out" "[FAIL] 16h."
contains "T1.46 the 16h line names @coderabbitai review" "$out" "@coderabbitai review"
out="$(STUB_CR_DESC="$OUT_CR_OK" STUB_CR_STATE=failure run_out)"; contains "T1.47 a CodeRabbit failure FAILs 16h" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is failure"
out="$(STUB_CR_DESC='Review skipped: automatic reviews are disabled' run_out)"; contains "T1.47 a Review skipped status FAILs 16h" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is skipped"
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.47 control: a completed CodeRabbit review passes 16h" "$out" "[PASS] 16h."
t0=$(date +%s)
out="$(STUB_CR_DESC="$OUT_CR_OK" STUB_CR_SLEEP=1 run_out)"
t1=$(date +%s)
contains "T1.55 a CodeRabbit read past the bound FAILs 16h" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is unreadable"
check "T1.55 a hung CodeRabbit read is cut off within the bound" "$([ $((t1 - t0)) -lt 80 ] && echo yes || echo no)" "yes"
cr_row() {  # cr_row <id> <context> <state> <description>
    printf '{"context":"%s","state":"%s","description":"%s","created_at":"2026-11-04T00:00:00Z","creator":{"id":%s,"login":"x[bot]","type":"Bot"}}' "$2" "$3" "$4" "$1"
}
out="$(CR_OK_DESC_RE=. STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit success 'Review in progress')]" run_out)"
contains "T1.59 an exported CR_OK_DESC_RE does not widen 16h" "$out" "[FAIL] 16h."
out="$(CR_BOT_USER_ID=4242 STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit pending 'Review in progress'),$(cr_row 4242 CodeRabbit success "$OUT_CR_OK")]" run_out)"
contains "T1.59 an exported CR_BOT_USER_ID does not pick a decoy status" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is pending"
out="$(CR_STATUS_CONTEXT=Decoy STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit pending 'Review in progress'),$(cr_row 136622811 Decoy success "$OUT_CR_OK")]" run_out)"
contains "T1.59 an exported CR_STATUS_CONTEXT does not pick a decoy context" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is pending"
out="$(CR_OK_DESC_RE=. CR_SKIP_DESC_RE=nomatch STUB_CR_STATUSES="[$(cr_row 136622811 CodeRabbit success 'Review skipped: automatic reviews are disabled')]" run_out)"
contains "T1.59 exported CR_OK_DESC_RE and CR_SKIP_DESC_RE do not pass a skip" "$out" "[FAIL] 16h. CodeRabbit at ${SHA:0:7} is skipped"
out="$(STUB_CHECKCI_RC=1 CR_APP=0 run_out)"; contains "T1.63 an exported CR_APP=0 does not skip 16e's findings read" "$out" "--threads-only exited 1"
out="$(STUB_CHECKCI_RC=1 CR_PROFILE=none CR_BOT_USER_ID=4242 run_out)"; contains "T1.63 an exported CR_PROFILE=none does not skip 16e's findings read" "$out" "--threads-only exited 1"
contains "T1.63 check-ci saw CR_APP, CR_PROFILE and CR_BOT_USER_ID unset" "$(tail -n 1 "$OUT_CHECKCI_LOG")" "CR_APP=unset CR_PROFILE=unset CR_BOT_USER_ID=unset"

# 7h: 16i, the outside security audit
out_reset; out_unlist
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.48 CodeRabbit OK but no audit row FAILs 16i" "$out" "[FAIL] 16i. no passed outside security audit"
out_reset; out_unlist; row_audit fail
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"
contains "T1.49 a fail row FAILs 16i naming its report" "$out" "(report $OUT_REPORT)"
contains "T1.49 a fail row names a new head as the only way out" "$out" "the only way out is a new head"
out_reset; out_unlist; row_audit pass
rc=0; out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)" || rc=$?
contains "T1.50 a pass row passes 16i" "$out" "[PASS] 16i."
check "T1.50 an unlisted author with 16b-16i at the head: exit 0" "$rc" "0"
out_reset; out_unlist; row_audit flagged
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.50 a flagged row passes 16i" "$out" "[PASS] 16i."
out_reset; out_unlist; row_audit pass "$H2"
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.51 a pass row at another (parent) head FAILs 16i" "$out" "[FAIL] 16i."
out_reset; out_unlist; row_audit pass "$SHA" 78
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.51 a pass row for another PR FAILs 16i" "$out" "[FAIL] 16i."
out_reset; out_unlist; row_audit pass "$SHA" "$PR" "$(printf '0%.0s' $(seq 64))"
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.51 a pass row under a stale perspective sha FAILs 16i" "$out" "[FAIL] 16i."
out_reset
rc=0; out="$(run_out)" || rc=$?
contains "T1.52 a listed author prints the 16h/16i SKIP line" "$out" "[SKIP] 16h/16i listed author Goomal"
notcontains "T1.52 a listed author needs no CodeRabbit status" "$out" "16h. CodeRabbit"
check "T1.52 a listed author without either record: exit 0" "$rc" "0"
out_reset; printf '[{"login":"Goomal","id":"U_other"}]\n' > "$OUT_HOME/.himmel/outside-contributors.json"
out="$(run_out)"; contains "T1.53 a listed login with another id is unlisted" "$out" "[FAIL] 16h."
out_reset; printf 'not json\n' > "$OUT_HOME/.himmel/outside-contributors.json"
out="$(run_out)"; contains "T1.54 an unreadable allowlist makes 16h/16i required" "$out" "[FAIL] 16i."
out_reset
out="$(STUB_AUTHOR_ID='' run_out)"; contains "T1.54 a null authorId makes 16h/16i required" "$out" "[FAIL] 16h."
out_reset; out_unlist; row_audit fail; row_audit pass
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.58 a fail row then a newer pass row FAILs 16i" "$out" "[FAIL] 16i. the outside security audit FAILED"
out_reset; out_unlist; row_audit pass; rm -f "$OUT_REPORT"
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.60 a pass row whose report is missing FAILs 16i" "$out" "[FAIL] 16i."
out_reset; out_unlist; row_audit pass; printf 'edited\n' >> "$OUT_REPORT"
out="$(STUB_CR_DESC="$OUT_CR_OK" run_out)"; contains "T1.60 a pass row whose report was edited FAILs 16i" "$out" "[FAIL] 16i."

# --- 17. a partial merge records what remains: the merge's exit 26, read at GO time ---
# Item 17 reads the PR body through the merge's own reader (scripts/lib/pr_remainder.py, from the anchor) for the key
# the merge's own reader (ticket_key_from_title) finds in the title. GREEN_BODY lists only `done` asks, no `Remaining:`.
reset_stubs
RUN_FLAGS="--contract no --require-contract"
R17_RC=0; R17_OUT="$(run)" || R17_RC=$?
check "17a contract no, keyed title, no Remaining line: exit 1" "$R17_RC" "1"
contains "17a: item 17 fails" "$R17_OUT" "[FAIL] 17."
contains "17a: names the missing remainder" "$R17_OUT" "Remaining:"
contains "17a: the verdict is FAIL" "$R17_OUT" "READY-CHECK FAIL"
# controls
R17_RC=0; R17_OUT="$(STUB_BODY="$GREEN_BODY"'\nRemaining: the docs follow in a later PR\n' run)" || R17_RC=$?
check "17b a Remaining line passes: exit 0" "$R17_RC" "0"
contains "17b: item 17 passes" "$R17_OUT" "[PASS] 17."
RUN_FLAGS="--contract yes --require-contract"
R17_RC=0; R17_OUT="$(run)" || R17_RC=$?
check "17c contract yes needs no remainder: exit 0" "$R17_RC" "0"
contains "17c: item 17 passes" "$R17_OUT" "[PASS] 17."
RUN_FLAGS="--contract no --require-contract"
R17_RC=0; R17_OUT="$(STUB_PR_TITLE='chore: no ticket key in this title' run)" || R17_RC=$?
check "17d a title with no key is not a partial merge: exit 0" "$R17_RC" "0"
contains "17d: item 17 passes as not applicable" "$R17_OUT" "[PASS] 17."
# the merge's key reader, not a grep of the title: a bare KEY-n without brackets is no key
R17_RC=0; R17_OUT="$(STUB_PR_TITLE='feat(x): HIMMEL-100 thing without brackets' run)" || R17_RC=$?
check "17e an unbracketed key is no key to the merge, so no remainder is read: exit 0" "$R17_RC" "0"
R17_HANDED='## Ticket coverage\n- ask one: done\n- ask two: deferred \xe2\x86\x92 HIMMEL-2\n'
R17_RC=0; R17_OUT="$(STUB_BODY="$R17_HANDED" run)" || R17_RC=$?
check "17j contract no with a wholly handed-off remainder: exit 1" "$R17_RC" "1"
contains "17j: item 17 fails" "$R17_OUT" "[FAIL] 17."
R17_LINE="$(printf '%s\n' "$R17_OUT" | grep '\] 17\.' || true)"
contains "17j: item 17's own line names the other key" "$R17_LINE" "HIMMEL-2"
contains "17j: item 17's own line names the brief line" "$R17_LINE" "Completes ticket: no"
contains "17j: item 17's own line names the contract to re-issue the GO with" "$R17_LINE" "--contract yes"
contains "17j: item 17's own line names the Remaining: line" "$R17_LINE" "Remaining:"
notcontains "17j: item 17 does not pass" "$R17_OUT" "[PASS] 17."
contains "9561 S4a 17j: item 17's own line offers an owed line too" "$R17_LINE" "or an owed → line"
R17_OWED='## Ticket coverage\n- ask one: done\n- live proof: owed \xe2\x86\x92 operator by '"$(o_day 2)"'\n'
R17_OUT="$(STUB_BODY="$R17_OWED" run || true)"
R17_LINE="$(printf '%s\n' "$R17_OUT" | grep '\] 17\.' || true)"
contains "9561 S4a 17m: an owed remainder passes item 17 as owed" "$R17_LINE" "[PASS] 17."
contains "9561 S4a 17m: the PASS line says owed" "$R17_LINE" "(owed)"
R17_RC=0; R17_OUT="$(STUB_BODY='## Ticket coverage\n- ask one: done\n- the INTAKE age (tick.sh, held): owed \xe2\x86\x92 chief by '"$(o_day 2)"'\n' run)" || R17_RC=$?
R17_LINE="$(printf '%s\n' "$R17_OUT" | grep '\] 17\.' || true)"
check "10194 17n an owed-to-chief line naming a repo file: exit 1" "$R17_RC" "1"
contains "10194 17n: item 17 fails" "$R17_LINE" "[FAIL] 17."
contains "10194 17n: item 17's line names the path" "$R17_LINE" "tick.sh"
contains "10194 17n: item 17's line names the Remaining: line" "$R17_LINE" "Remaining:"
R17_OUT="$(STUB_BODY='## Ticket coverage\n- ask one: done\n- set enabled in /etc/himmel/afk-sudo.json: owed \xe2\x86\x92 chief by '"$(o_day 2)"'\n- run scripts/lib/afk-sudo/install.sh: owed \xe2\x86\x92 operator by '"$(o_day 2)"'\n' run || true)"
R17_LINE="$(printf '%s\n' "$R17_OUT" | grep '\] 17\.' || true)"
contains "10194 17o: a station step without an explicit worker refusal is not chief-only" "$R17_LINE" "[FAIL] 17."
R17_OUT="$(STUB_BODY='## Ticket coverage\n- ask one: done\n- run the live proof on the station: owed -> chief by '"$(o_day 2)"'\n' run || true)"
contains "10220 live proof is refused with proof-owner advice" "$R17_OUT" 'owed → proof'
R17_OUT="$(STUB_BODY='## Ticket coverage\n- ask one: done\n- sign the spec: owed -> chief by '"$(o_day 2)"'\n' run || true)"
contains "10220 chief-only signature is accepted" "$R17_OUT" '[PASS] 17.'
R17_OUT="$(STUB_BODY='## Ticket coverage\n- ask one: done\n- run the live proof: owed -> proof by '"$(o_day 2)"'\n' run || true)"
contains "10220 executable proof is accepted" "$R17_OUT" '[PASS] 17.'
R17_OUT="$(STUB_BODY="$R17_HANDED"'\nRemaining: x\n' run || true)"
contains "17k a Remaining: line beside a deferred line passes item 17" "$R17_OUT" "[PASS] 17."
RUN_FLAGS="--contract yes --require-contract"
R17_OUT="$(STUB_BODY="$R17_HANDED" run || true)"
contains "17l contract yes passes a handed-off body" "$R17_OUT" "[PASS] 17."
RUN_FLAGS="--contract no --require-contract"
RUN_FLAGS="--require-contract"
R17_RC=0; R17_OUT="$(run)" || R17_RC=$?
check "17f a keyed title with no contract named, from a GO writer: exit 1" "$R17_RC" "1"
contains "17f: item 17 fails" "$R17_OUT" "[FAIL] 17."
contains "17f: says to name the contract" "$R17_OUT" "--contract yes|no"
RUN_FLAGS=""
R17_RC=0; R17_OUT="$(run)" || R17_RC=$?
check "17g a keyed title with no contract named and no flag (the plain call the chief runs before go.sh): exit 1, as go.sh refuses it" "$R17_RC" "1"
contains "17g: item 17 fails" "$R17_OUT" "[FAIL] 17."
contains "17g: says to name the contract" "$R17_OUT" "--contract yes|no"
RUN_FLAGS="--observe"
R17_RC=0; R17_OUT="$(run)" || R17_RC=$?
check "17g2 --observe (a waiter or shepherd read, no GO is written): exit 0 (a warning, not a verdict)" "$R17_RC" "0"
contains "17g2: item 17 warns" "$R17_OUT" "[WARN] 17."
# a reader the anchor lacks refuses, as the merge refuses on a broken anchor
NR_ORIGIN="$tmp/tp-origin-nr.git"; NR_ANCHOR="$tmp/tp-nr"
git init -q --bare "$NR_ORIGIN"
git clone -q "$TP_ANCHOR" "$NR_ANCHOR" 2>/dev/null
git -C "$NR_ANCHOR" rm -q scripts/lib/pr_remainder.py
git -C "$NR_ANCHOR" -c user.name=t -c user.email=t@t commit -q -m "no reader"
git -C "$NR_ANCHOR" remote set-url origin "$NR_ORIGIN"
git -C "$NR_ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$NR_ORIGIN" symbolic-ref HEAD refs/heads/main
RUN_FLAGS="--contract no --require-contract"
R17_RC=0; R17_OUT="$(STUB_BODY="$GREEN_BODY"'\nRemaining: x\n' READY_CHECK_ANCHOR="$NR_ANCHOR" run)" || R17_RC=$?
check "17h the anchor has no remainder reader: exit 1" "$R17_RC" "1"
contains "17h: item 17 fails naming the reader" "$R17_OUT" "pr_remainder.py"
# --only 7 is the worker's body lint: it never runs items 17 or 18
RUN_FLAGS=""
R17_OUT="$(run7 || true)"
notcontains "17i --only 7 does not run item 17" "$R17_OUT" "] 17."
notcontains "17i --only 7 does not run item 18" "$R17_OUT" "] 18."

# --- 18. open blocking findings: the merge's gates 4 and 4b, read at GO time ---
# Item 18 asks scripts/cr/clear-review-marker.sh --check-findings, the merge's own ledger verdict, at the head the
# merge will gate on, with and without the chief's GO assumed. The PR 4611 shape: an Important raised at the reviewed
# head A and never ruled; B (a non-test delta on top of A) carries its own ok row, so item 4 passes at B.
RUN_FLAGS="--observe"
SHA_SAVE="$SHA"
R18_A=$(git -C "$REPO" rev-parse HEAD)
printf 'b\n' > "$REPO/f18.txt"
git -C "$REPO" add f18.txt
git -C "$REPO" commit -q -m "feat: B on top of A"
R18_B=$(git -C "$REPO" rev-parse HEAD)
R18_BRANCH="feat/himmel-100-thing"
mkdir -p "$REPO/.git/cr-review-rounds/feat"
r18_ledger() { # <verdict of the finding at A>: ok rows at A and B, one Important at A
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"%s","head":"%s","model":"codex","status":"ok"}\n' "$R18_BRANCH" "$R18_A" "$R18_BRANCH" "$R18_B" > "$LEDGER"
    printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"%s","head":"%s","model":"codex","finding_id":"codex-1","severity":"imp","file":"a.sh","line":1,"verdict":"%s"}\n' "$R18_BRANCH" "$R18_A" "$1" >> "$LEDGER"
}
SHA="$R18_B"
reset_stubs
r18_ledger ""
printf '%s\n' "$R18_A" > "$REPO/.git/cr-review-rounds/feat/himmel-100-thing.head"
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18a an unruled Important at the reviewed head, tip with its own ok row: exit 1" "$R18_RC" "1"
contains "18a: item 18 fails" "$R18_OUT" "[FAIL] 18."
contains "18a: names the finding" "$R18_OUT" "codex-1"
contains "18a: item 4 passed at the tip (the 4611 shape: the old gates were green)" "$R18_OUT" "[PASS] 4."
# controls
r18_ledger "disproved"
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18b the same finding ruled disproved: exit 0" "$R18_RC" "0"
contains "18b: item 18 passes" "$R18_OUT" "[PASS] 18."
r18_ledger ""
rm -f "$REPO/.git/cr-review-rounds/feat/himmel-100-thing.head"
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18c with no recorded round head, gates 4 and 4b read the tip's own rows, but gate 4c (promote --check) still refuses the unruled Important at A: exit 1" "$R18_RC" "1"
contains "18c: item 18 fails" "$R18_OUT" "[FAIL] 18."
contains "18c: names the still-open finding gate 4c reports" "$R18_OUT" "still-open codex-1@"
# control: the same shape with the Important ruled passes, and the check leaves the ledger as it was
r18_ledger "disproved"
R18_BEFORE=$(ledger_cksum); R18_LINES=$(ledger_lines)
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18c2 with no recorded round head and the Important ruled: exit 0" "$R18_RC" "0"
contains "18c2: item 18 passes" "$R18_OUT" "[PASS] 18."
check "18c2 the check leaves the ledger byte-identical" "$(ledger_cksum)" "$R18_BEFORE"
check "18c2 the check adds no ledger line" "$(ledger_lines)" "$R18_LINES"
printf '%s\n' "$R18_A" > "$REPO/.git/cr-review-rounds/feat/himmel-100-thing.head"
r18_ledger "disproved"
printf 'not json\n' >> "$LEDGER"
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18d a malformed ledger line is an unknown verdict: exit 1" "$R18_RC" "1"
contains "18d: item 18 fails" "$R18_OUT" "[FAIL] 18."
r18_ledger "disproved"
R18_RC=0; R18_OUT="$(STUB_PR_BRANCH="" run)" || R18_RC=$?
contains "18e an unreadable head branch cannot be judged: item 18 fails" "$R18_OUT" "[FAIL] 18."
r18_ledger ""
R18_BEFORE=$(ledger_cksum)
run >/dev/null 2>&1 || true
check "18f the check writes nothing to the ledger" "$(ledger_cksum)" "$R18_BEFORE"
# the marker reads findings by head, not by branch: an unruled Important at the tip filed under ANOTHER branch still blocks
rm -f "$REPO/.git/cr-review-rounds/feat/himmel-100-thing.head"
printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"%s","head":"%s","model":"codex","status":"ok"}\n' "$R18_BRANCH" "$R18_B" > "$LEDGER"
printf '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"other/branch","head":"%s","model":"codex","finding_id":"codex-9","severity":"imp","file":"a.sh","line":1}\n' "$R18_B" >> "$LEDGER"
R18_RC=0; R18_OUT="$(run)" || R18_RC=$?
check "18g an unruled Important at the tip under another branch: exit 1" "$R18_RC" "1"
contains "18g: item 18 fails" "$R18_OUT" "[FAIL] 18."
SHA="$SHA_SAVE"
reset_stubs

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
