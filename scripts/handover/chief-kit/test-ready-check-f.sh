#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2153,SC2154
set -uo pipefail
# shellcheck source=scripts/lib/portable-timeout.sh
. "$(cd "$(dirname "$0")" && pwd)/../../lib/portable-timeout.sh"
# shellcheck source=tests/testlib-ready-check.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/testlib-ready-check.sh"

jira_db_bug_rows
# --- 19. suite evidence. A repo whose PR head changes scripts/lib/s17-lib.sh, which
# two shell suites run, and (H_JS) scripts/lib/s17-dep.mjs, which one JS suite names.
# The anchor stub hands the range to the real impacted-suites.sh.
S17_REAL="$HERE/../../cr/impacted-suites.sh"
S17R="$tmp/s17-repo"
S17_A=scripts/test-s17-a.sh
S17_B=scripts/test-s17-b.sh
S17_JS=scripts/lib/s17.test.mjs
git init -q --bare "$tmp/s17-origin.git"
git init -q "$S17R"
git -C "$S17R" config user.email t@example.com
git -C "$S17R" config user.name tester
mkdir -p "$S17R/scripts/lib"
printf 'v1\n' > "$S17R/scripts/lib/s17-lib.sh"
printf 'v1\n' > "$S17R/scripts/lib/s17-dep.mjs"
printf '#!/usr/bin/env bash\n. scripts/lib/s17-lib.sh\n' > "$S17R/$S17_A"
printf '#!/usr/bin/env bash\n. scripts/lib/s17-lib.sh\n' > "$S17R/$S17_B"
printf "import './s17-dep.mjs';\n" > "$S17R/$S17_JS"
git -C "$S17R" add -A
git -C "$S17R" commit -q -m "chore: base"
git -C "$S17R" remote add origin "$tmp/s17-origin.git"
git -C "$S17R" push -q origin HEAD:refs/heads/main
S17_BASE=$(git -C "$S17R" rev-parse HEAD)
printf 'v2\n' > "$S17R/scripts/lib/s17-lib.sh"
git -C "$S17R" commit -q -am "feat(x): [HIMMEL-1] change the lib"
S17_H1=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_BASE"
printf 'v2\n' > "$S17R/scripts/lib/s17-dep.mjs"
git -C "$S17R" commit -q -am "build(deps): bump the dep"
S17_HJS=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q --orphan s17-orphan
git -C "$S17R" commit -q -m "chore: unrelated history"
S17_ORPHAN=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_BASE"
printf 'v2\n' > "$S17R/scripts/lib/s17-lib.sh"
printf 'v3\n' > "$S17R/scripts/lib/s17-dep.mjs"
git -C "$S17R" commit -q -am "feat(x): [HIMMEL-1] change the lib and the dep"
S17_HMIX=$(git -C "$S17R" rev-parse HEAD)
git -C "$S17R" checkout -q "$S17_H1"
s17_agg() {  # <status> <conclusion|null> <startedAt> <run id> [name]: one check-run of the aggregator
    local c="$2"
    [ "$c" = null ] || c="\"$c\""
    printf '{"name":"%s","workflowName":"CI","status":"%s","conclusion":%s,"startedAt":"%s","completedAt":"%s","detailsUrl":"https://github.com/acme/repo/actions/runs/%s/job/9%s"}' \
        "${5:-shell-unit (ubuntu-latest)}" "$1" "$c" "$3" "$3" "$4" "$4"
}
S17_GREEN="[{\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},$(s17_agg COMPLETED SUCCESS 2026-11-05T01:00:00Z 555)]"
s17_man() {  # <dir> <line>...: one shard's manifest, as the CI artifact lays it out
    local d="$1/shell-unit-manifest-ubuntu-latest-shard1"
    shift
    mkdir -p "$d"
    { printf 'head 1111111111111111111111111111111111111111\nmode impacted\nshard 1/1\n'; printf '%s\n' "$@"; } > "$d/manifest-shard1.txt"
}
S17_MAN_AB="$tmp/s17-man-ab"; s17_man "$S17_MAN_AB" "ran 0 $S17_A" "ran 0 $S17_B"
S17_MAN_ASKIPB="$tmp/s17-man-askipb"; s17_man "$S17_MAN_ASKIPB" "ran 0 $S17_A" "skip $S17_B"
S17_MAN_A="$tmp/s17-man-a"; s17_man "$S17_MAN_A" "ran 0 $S17_A"
S17_MAN_NEAR="$tmp/s17-man-near"; s17_man "$S17_MAN_NEAR" "ran 0 $S17_A" "ran 00 $S17_B" "ran 10 $S17_B" "ran 0 $S17_B.bak"
# s17_at <sha>: run in the check-19 repo. S17_LP / S17_RS (JSON arrays), when set,
# write the head's impacted row; S17_ROLLUP replaces the green rollup.
s17_at() {
    local keep_sha="$SHA" keep_repo="$REPO" keep_ledger="$LEDGER"
    SHA="$1"; REPO="$S17R"; LEDGER="$S17R/.git/cr-critic-scores.jsonl"
    seed_ledger_ok
    if [ -n "${S17_LP:-}${S17_RS:-}" ]; then
        printf '{"kind":"impacted","ts":"2026-11-05T00:00:00Z","source":"pr-check","branch":"%s","head":"%s","pr":%s,"status":"ok","impacted_n":2,"unverdicted_n":0,"skip_n":0,"rc":0,"local_pass":%s,"ruled_skip":%s}\n' \
            "${S17_ROW_BRANCH:-${STUB_PR_BRANCH:-feat/himmel-100-thing}}" "$SHA" "${S17_ROW_PR:-77}" "${S17_LP:-[]}" "${S17_RS:-[]}" >> "$LEDGER"
    fi
    # S17_RUNBOOK_CMD: the row is written by running the runbook's command in the repo, not by hand
    if [ -n "${S17_RUNBOOK_CMD:-}" ]; then
        s17_rb=$( cd "$S17R" && bash -c "$S17_RUNBOOK_CMD" 2>&1 ) || echo "s17_at: the runbook command failed: $s17_rb"
    fi
    : > "$GH_LOG"
    rc=0; out="$(STUB_IMPACTED_REAL="$S17_REAL" STUB_ROLLUP="${S17_ROLLUP-$S17_GREEN}" run)" || rc=$?
    SHA="$keep_sha"; REPO="$keep_repo"; LEDGER="$keep_ledger"
}
line17() { printf '%s\n' "$1" | grep -F '] 19. ' || true; }
s17_tier() {
    mkdir -p "$TP_ANCHOR/scripts/ci"
    printf '%s\t%s\ttest fixture\n' "$1" "$2" > "$TP_ANCHOR/scripts/ci/suite-tiers.tsv"
}
s17_clear() { rm -f "$TP_ANCHOR/scripts/ci/suite-tiers.tsv"; unset S17_RUNBOOK_CMD S17_LP S17_RS S17_ROW_BRANCH S17_ROW_PR S17_ROLLUP STUB_MANIFEST_DIR STUB_DL_FAIL STUB_DL_SLEEP STUB_RUN_SLEEP STUB_RUN_HEAD_SHA STUB_RUN_CONC READY_CHECK_ITEM19_BOUND STUB_JS_MANIFEST_DIR STUB_JS_DL_FAIL STUB_JOBS STUB_JOBS_FAIL; reset_stubs; }

# T6 / T21: every suite has a ran-0 row in the head's run; the PR touches no plugin file
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
s17_at "$S17_H1"
check "19 T6 every suite ran 0 in CI: exit 0" "$rc" "0"
contains "19 T6: PASS with the CI count and run" "$out" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 555, 0 local"
contains "19 T21: check 9 has no plugin files" "$out" "[PASS] 9. no plugin files touched"
contains "19 T6: the manifests of the head's run are downloaded" "$(gh_log)" "run download 555"
notcontains "19 T6: never lists runs" "$(gh_log)" "run list"

s17_clear; STUB_MANIFEST_DIR="$S17_MAN_ASKIPB"
s17_at "$S17_H1"
check "19 T7 CI skipped a suite: exit 0" "$rc" "0"
contains "19 T7: the CI-skipped suite is named as tier-skipped" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 1 from CI run 555, 0 local, 1 tier-skipped: $S17_B (CI skip)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" daily
s17_at "$S17_H1"
check "19 T7b daily-tier suite with no CI row: exit 0" "$rc" "0"
contains "19 T7b: the daily-tier suite is named with its tier" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 1 from CI run 555, 0 local, 1 tier-skipped: $S17_B (daily)"
for s17_t in local quarantine; do
    s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" "$s17_t"
    s17_at "$S17_H1"
    contains "19 T7b $s17_t-tier suite with no CI row: tier-skipped" "$(line17 "$out")" "1 tier-skipped: $S17_B ($s17_t)"
done
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" pr
s17_at "$S17_H1"
check "19 T7c pr-tier suite with no CI row: exit 1" "$rc" "1"
contains "19 T7c: names the suite" "$(line17 "$out")" "[FAIL] 19. suite evidence: 1 suite(s) proven nowhere: $S17_B (no ran-0 row in run 555)"
contains "19 T7c: the hint says a suite CI does not run needs no local run" "$out" "a suite CI does not run (tier daily, local or quarantine, or a CI skip) needs no local run"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" flow
s17_at "$S17_H1"
check "19 T7c2 flow-tier suite with no CI row: exit 1" "$rc" "1"
contains "19 T7c2: names the suite" "$(line17 "$out")" "[FAIL] 19. suite evidence: 1 suite(s) proven nowhere: $S17_B (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" bogus
s17_at "$S17_H1"
check "19 T7d an unknown tier fails closed: exit 1" "$rc" "1"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; s17_tier "$S17_B" daily; STUB_FILES="$S17_B"
s17_at "$S17_H1"
contains "19 T7e a changed daily-tier suite with no local PASS: FAIL" "$(line17 "$out")" "$S17_B (the PR changed it: a CI line does not count, run it locally)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_ASKIPB"; S17_LP="[\"$S17_B\"]"
s17_at "$S17_H1"
check "19 T8 that suite passed locally: exit 0" "$rc" "0"
contains "19 T8: one from CI, one local" "$out" "[PASS] 19. suite evidence: 2 impacted, 1 from CI run 555, 1 local"

# T8b: the row comes from the runbook's own default fence (spec 2.2), not a hand-written
# one: pr-check step 3.6 as written, for a PR that is not an outside PR, then item 19 reads it.
S17_MD="$HERE/../../cr/pr-check-ref/33-step3-impacted.md"
S17_FENCE=$(awk '/^   ```bash$/ { f = 1; next } /^   ```/ { f = 0 } f && /--record/ { print; exit }' "$S17_MD")
contains "19 T8b: the runbook's default fence records (not only on outside-pr: yes)" "$S17_FENCE" "--record --branch '<headRefName>' --head <head>"
notcontains "19 T8b: the runbook does not gate --record on outside-pr: yes" "$(cat "$S17_MD")" "On \`outside-pr: yes\` (step 0), record the verdicts"
S17_VERDICTS="$tmp/s17-verdicts.txt"
printf 'SUITE %s = PASS\nSUITE %s = PASS\n' "$S17_A" "$S17_B" > "$S17_VERDICTS"
S17_RUN_CMD=$(printf '%s' "$S17_FENCE" | sed -e "s#<himmel_dir>#$HERE/../../..#" -e "s#<base>#$S17_BASE#" -e "s#<head>#$S17_H1#g" -e "s#<scratch-path>#$S17_VERDICTS#" -e "s#<headRefName>#feat/himmel-100-thing#")
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_RUNBOOK_CMD="$S17_RUN_CMD"
s17_at "$S17_H1"
check "19 T8b the row the runbook fence wrote: exit 0" "$rc" "0"
contains "19 T8b: item 19 reads that row (both suites local, nothing left to CI)" "$out" "[PASS] 19. suite evidence: 2 impacted, 0 from CI run -, 2 local"

# shellcheck source=scripts/lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"
if [ -z "$_TIMEOUT_BIN" ]; then
echo "ok - 19 T8c and T8d killed-mid-read rows skipped: no GNU timeout on this host"
else
# T8c: a ready-check killed while item 19 reads (the chief's `timeout` TERMs it) leaves no temp dir
S17_TO_PID="$tmp/s17-term-timeout.pid"
printf '#!/usr/bin/env bash\necho $$ > %q\nexec %q 120 bash %q "$@"\n' "$S17_TO_PID" "$_TIMEOUT_BIN" "$SCRIPT" > "$tmp/s17-term-wrap.sh"
S17_SLOW="$tmp/slow-rm"; mkdir -p "$S17_SLOW"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *ready-check-19.*) : > "${0%/*}/held"; sleep "$(cat "${0%/*}/hold")" ;; esac' \
    'PATH="${PATH#"${0%/*}:"}"; exec rm "$@"' > "$S17_SLOW/rm"
chmod +x "$S17_SLOW/rm"
s17_term() {
    local label="$1"
    S17_TMP="$tmp/s17-term-tmp-$label"; mkdir -p "$S17_TMP"
    printf '%s\n' "$2" > "$S17_SLOW/hold"; rm -f "$S17_SLOW/held"
    s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_DL_SLEEP=20; STUB_DL_STARTED="$tmp/s17-term-started"
    rm -f "$STUB_DL_STARTED" "$S17_TO_PID"
    ( for _ in $(seq 1 1000); do
        [ -f "$STUB_DL_STARTED" ] && { kill -ALRM "$(cat "$S17_TO_PID")"; exit 0; }
        sleep 0.1
    done ) &
    S17_WATCH=$!
    PATH="$S17_SLOW:$PATH" RUN_SCRIPT="$tmp/s17-term-wrap.sh" TMPDIR="$S17_TMP" s17_at "$S17_H1"
    unset RUN_SCRIPT
    wait "$S17_WATCH"
    check "19 $label: the stalled item-19 read was started, so the kill had something to interrupt" "$([ -f "$STUB_DL_STARTED" ] && echo yes || echo no)" "yes"
    check "19 $label: the outer timeout is what ended the run (exit 124)" "$rc" "124"
    unset STUB_DL_STARTED
    check "19 $label: killed mid-read, no ready-check-19 temp dir is left" "0" "$(find "$S17_TMP" -name 'ready-check-19.*' | wc -l | tr -d ' ')"
    check "19 $label: and no run dir is left" "0" "$(find "$S17_TMP" -name 'ready-check-run.*' | wc -l | tr -d ' ')"
}
s17_term T8c 0
s17_term T8s 7
check "19 T8s control: the seam held the item-19 cleanup" "$([ -f "$S17_SLOW/held" ] && echo yes || echo no)" "yes"

S_KW="$tmp/kill-wrap"; mkdir -p "$S_KW"
printf '#!/usr/bin/env bash\necho started > "%s/started"\nsleep 40 &\necho $! > "%s/sleep.pid"\nwait\n' "$S_KW" "$S_KW" > "$S_KW/slow-gh"; chmod +x "$S_KW/slow-gh"
kw_sleep_alive() { local p; p=$(cat "$S_KW/sleep.pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; echo yes; else echo no; fi; }
kw_t0=$SECONDS
kw_rc=0
(cd "$REPO" && HIMMEL_REPO="$REPO" TMPDIR="$S_KW" GH_CMD="$S_KW/slow-gh" "$_TIMEOUT_BIN" 3 bash "$SCRIPT" --observe "$PR" "$SHA" > /dev/null 2>&1) || kw_rc=$?
kw_took=$((SECONDS - kw_t0))
sleep 1
check "T8d: the outer timeout is what ended the run (exit 124)" "$kw_rc" "124"
check "T8d: the stalled read was started, so the cancel had something to cancel" "$([ -f "$S_KW/started" ] && echo yes || echo no)" "yes"
check "T8d: a ready-check killed by an outer timeout returns within the bound (took ${kw_took}s)" "$([ "$kw_took" -le 12 ] && echo yes || echo no)" "yes"
check "T8d: the killed wrapper leaves none of its scratch files" "$(find "$S_KW" -maxdepth 1 -name 'ready-check-*' | wc -l | tr -d ' ')" "0"
check "T8d: the killed wrapper leaves no stalled child" "$(pgrep -f "$S_KW/slow-gh" | wc -l | tr -d ' ')" "0"
check "T8d: the stalled read's own sleep is gone too" "$(kw_sleep_alive)" "no"
rm -f "$S_KW/started" "$S_KW/sleep.pid"
kw_rc=0
(cd "$REPO" && READY_CHECK_DEADLINE=0 HIMMEL_REPO="$REPO" TMPDIR="$S_KW" GH_CMD="$S_KW/slow-gh" "$_TIMEOUT_BIN" 3 bash "$SCRIPT" --observe "$PR" "$SHA" > /dev/null 2>&1) || kw_rc=$?
sleep 1
check "T8d: unarmed, the outer timeout ended the run (exit 124)" "$kw_rc" "124"
check "T8d: unarmed, the stalled read was started" "$([ -f "$S_KW/started" ] && echo yes || echo no)" "yes"
check "T8d: unarmed, the killed wrapper leaves no stalled child" "$(pgrep -f "$S_KW/slow-gh" | wc -l | tr -d ' ')" "0"
check "T8d: unarmed, the stalled read's own sleep is gone too" "$(kw_sleep_alive)" "no"
check "T8d: unarmed, the killed wrapper leaves none of its scratch files" "$(find "$S_KW" -maxdepth 1 -name 'ready-check-*' | wc -l | tr -d ' ')" "0"
fi

# T9: a suite CI cannot run (no manifest row) needs a local PASS
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"
s17_at "$S17_H1"
contains "19 T9 a suite CI never ran, no row: FAIL" "$(line17 "$out")" "$S17_B (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_LP="[\"$S17_B\"]"
s17_at "$S17_H1"
check "19 T9 with the row listing it: exit 0" "$rc" "0"

# T10 / T10b: a Local suites line needs a local PASS even when CI proved the suite
for s17_body in "Local suites: $S17_A\n" "Local suites: $S17_A \r\n"; do
    s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_BODY="${GREEN_BODY}${s17_body}"
    s17_at "$S17_H1"
    contains "19 T10 Local suites line [$s17_body], no local PASS: FAIL" "$(line17 "$out")" "$S17_A (Local suites line, no local PASS)"
    s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_BODY="${GREEN_BODY}${s17_body}"; S17_LP="[\"$S17_A\"]"
    s17_at "$S17_H1"
    check "19 T10 Local suites line [$s17_body] with the local PASS: exit 0" "$rc" "0"
done

# T15: local proof for every suite: CI is never read
s17_clear; STUB_DL_FAIL=1; S17_LP="[\"$S17_A\",\"$S17_B\"]"
s17_at "$S17_H1"
check "19 T15 every suite local: exit 0" "$rc" "0"
contains "19 T15: all local" "$out" "[PASS] 19. suite evidence: 2 impacted, 0 from CI run -, 2 local"
notcontains "19 T15: the manifests are never downloaded" "$(gh_log)" "run download"

# T19: a Dependabot PR with a JS/TS suite and no row: FAIL, with the chief's remediation
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_AUTHOR=app/dependabot; STUB_PR_BRANCH=dependabot/npm_and_yarn/dep-2
s17_at "$S17_HJS"
contains "19 T19 Dependabot JS/TS suite, no row: FAIL" "$(line17 "$out")" "$S17_JS (no ran-0 row in run 555)"
contains "19 T19: names the chief's remediation" "$out" "no impacted row at ${S17_HJS:0:7} on dependabot/npm_and_yarn/dep-2: the chief runs pr-check step 3.6"

# T20: a ruled SKIP is counted and named apart from the local count; the same suite as a bare SKIP fails
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_RS="[\"$S17_B\"]"
s17_at "$S17_H1"
check "19 T20 ruled SKIP: exit 0" "$rc" "0"
contains "19 T20: the ruled SKIP is named and not counted as local" "$out" "1 from CI run 555, 0 local, 1 ruled SKIP: $S17_B"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_LP="[\"$S17_A\"]"; S17_RS="[]"
s17_at "$S17_H1"
contains "19 T20 a bare SKIP (in neither list): FAIL" "$(line17 "$out")" "$S17_B (no ran-0 row in run 555)"

# T5c: a row at this head on another branch, or one whose .pr names another PR, is no local proof
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_LP="[\"$S17_B\"]"; S17_ROW_BRANCH=other/branch
s17_at "$S17_H1"
contains "19 T5c a row of another branch gives no local proof" "$(line17 "$out")" "$S17_B (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_LP="[\"$S17_B\"]"; S17_ROW_PR=78
s17_at "$S17_H1"
contains "19 T5c a row whose .pr names another PR gives no local proof" "$(line17 "$out")" "$S17_B (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; S17_LP="[\"$S17_B\"]"
s17_at "$S17_H1"
check "19 T5c control: the same row on this branch and PR proves it: exit 0" "$rc" "0"

# T22: only an exact `ran 0 <path>` proves a suite
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_NEAR"
s17_at "$S17_H1"
contains "19 T22 ran 00, ran 10, a .bak path: not proof (ran 10 is a red CI run)" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_B (CI ran it and it failed)"

# T11-T14b, T16: CI evidence only from the latest SUCCESS aggregator whose run is at the head
S17_OLDOK=$(s17_agg COMPLETED SUCCESS 2026-11-05T01:00:00Z 554)
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
S17_ROLLUP="[$S17_OLDOK,$(s17_agg IN_PROGRESS null 2026-11-05T02:00:00Z 555)]"
s17_at "$S17_H1"
contains "19 T12 in progress after a SUCCESS: no settled CI run" "$(line17 "$out")" "[FAIL] 19. suite evidence: 2 suite(s) proven nowhere: $S17_A (no settled CI run"
S17_DUP_OK=$(s17_agg COMPLETED SUCCESS 2026-11-11T09:00:05Z 42975581139)
S17_DUP_CANC=$(s17_agg COMPLETED CANCELLED 2026-11-11T09:00:09Z 42975581119)
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_OK,$S17_DUP_CANC]"
s17_at "$S17_H1"
check "19 T11 a CANCELLED run newer than a SUCCESS one: exit 0" "$rc" "0"
contains "19 T11: reads the SUCCESS run" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 42975581139, 0 local"
contains "19 T11: the head check runs on the SUCCESS run" "$(gh_log)" "actions/runs/42975581139"
notcontains "19 T11: the cancelled run is never read" "$(gh_log)" "42975581119"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_CANC,$S17_DUP_OK]"
s17_at "$S17_H1"
contains "19 T11b the rollup rows in the other order: same run" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 42975581139, 0 local"
S17_DUP_OLD=$(s17_agg COMPLETED SUCCESS 2026-11-11T08:00:00Z 42975500000)
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_OLD,$S17_DUP_OK,$S17_DUP_CANC]"
s17_at "$S17_H1"
contains "19 T11c two SUCCESS runs and a CANCELLED one: the newer SUCCESS" "$(line17 "$out")" "from CI run 42975581139"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_OK,$S17_DUP_CANC]"; STUB_RUN_HEAD_SHA="$S17_BASE"
s17_at "$S17_H1"
contains "19 T11d the SUCCESS run is at another head: FAIL" "$(line17 "$out")" "(no settled CI run (run 42975581139 is not at ${S17_H1:0:7}))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_OLDOK,$(s17_agg COMPLETED FAILURE 2026-11-05T02:00:00Z 556)]"
s17_at "$S17_H1"
contains "19 T11e a real FAILURE after a SUCCESS: still no settled CI run" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 556))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$(s17_agg COMPLETED FAILURE 2026-11-05T01:00:00Z 556),$(s17_agg COMPLETED CANCELLED 2026-11-05T02:00:00Z 557)]"
s17_at "$S17_H1"
contains "19 T11f FAILURE then CANCELLED: the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 556))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_CANC,$(s17_agg COMPLETED CANCELLED 2026-11-11T09:00:04Z 42975581100)]"
s17_at "$S17_H1"
check "19 T11g every run CANCELLED: exit 1" "$rc" "1"
contains "19 T11g: no settled CI run, naming the newest cancelled one" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/CANCELLED 42975581119))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_DUP_OK,$S17_DUP_CANC,$(s17_agg IN_PROGRESS null 2026-11-11T09:10:00Z 42975600000)]"
s17_at "$S17_H1"
contains "19 T12b in progress newest after a CANCELLED duplicate: no settled CI run" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): IN_PROGRESS/null 42975600000))"
S17_LIVE_FAIL=$(s17_agg COMPLETED FAILURE 2026-11-11T06:53:36Z 42975581119)
S17_LIVE_SHARD=$(s17_agg COMPLETED CANCELLED 2026-11-11T06:53:34Z 42975581119 shell-unit-shard)
# shellcheck disable=SC2016  # the unevaluated matrix name is literal on purpose
S17_LIVE_SKIP=$(s17_agg COMPLETED SKIPPED 2026-11-11T06:59:43Z 42975581139 'shell-unit${{ x }} (${{ matrix.os }})')
S17_LIVE_CONC="42975581119=cancelled 42975581139=success"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_SHARD,$S17_LIVE_FAIL,$S17_LIVE_SKIP]"; STUB_RUN_CONC="$S17_LIVE_CONC"
s17_at "$S17_H1"
contains "19 T11h a FAILURE row of a cancelled run, the later run's shell-unit skipped: reads the later successful run" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 42975581139, 0 local"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_SKIP,$S17_LIVE_FAIL]"; STUB_RUN_CONC="$S17_LIVE_CONC"
s17_at "$S17_H1"
contains "19 T11h the rollup rows in the other order: same run" "$(line17 "$out")" "from CI run 42975581139"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL,$S17_LIVE_SKIP]"
s17_at "$S17_H1"
contains "19 T11i the same rows, the FAILURE run not cancelled: the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 42975581119))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL,$S17_LIVE_SKIP]"; STUB_RUN_CONC="42975581119=cancelled 42975581139=failure"
s17_at "$S17_H1"
contains "19 T11j the later run did not succeed: the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 42975581119))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL,$S17_LIVE_SKIP]"; STUB_RUN_CONC="$S17_LIVE_CONC"; STUB_RUN_HEAD_SHA="$S17_BASE"
s17_at "$S17_H1"
contains "19 T11k the later run is at another head: the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 42975581119))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL,$S17_LIVE_SKIP,$(s17_agg IN_PROGRESS null 2026-11-11T07:10:00Z 42975600000)]"; STUB_RUN_CONC="$S17_LIVE_CONC"
s17_at "$S17_H1"
contains "19 T11l an in-progress run newer than the cancelled one: not settled" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): IN_PROGRESS/null 42975600000))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$(s17_agg COMPLETED SUCCESS 2026-11-11T06:00:00Z 42975500000),$S17_LIVE_FAIL,$S17_LIVE_SKIP]"; STUB_RUN_CONC="$S17_LIVE_CONC"
s17_at "$S17_H1"
contains "19 T11m an older SUCCESS aggregator row is preferred to the run-level fallback" "$(line17 "$out")" "from CI run 42975500000"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL]"; STUB_RUN_CONC="42975581119=cancelled"
s17_at "$S17_H1"
contains "19 T11n a cancelled run's FAILURE and no other run at the head: the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 42975581119))"
# shellcheck disable=SC2016  # the unevaluated matrix name is literal on purpose
S17_CAP_SKIPS="$(s17_agg COMPLETED SKIPPED 2026-11-11T06:01:00Z 701 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:02:00Z 702 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:03:00Z 703 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:04:00Z 704 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:05:00Z 705 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:06:00Z 706 'shell-unit${{ x }}')"
S17_CAP_FAIL=$(s17_agg COMPLETED FAILURE 2026-11-11T06:00:00Z 700)
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_CAP_FAIL,$S17_CAP_SKIPS]"; STUB_RUN_CONC="700=cancelled 702=cancelled 703=cancelled 704=cancelled 705=cancelled 706=cancelled"
s17_at "$S17_H1"
contains "19 T11o the only successful other run is the 6th newest: not probed, the FAILURE stays the pick" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 700))"
check "19 T11o: exactly 5 other runs are probed" "$(grep -c -E 'actions/runs/70[1-6]' "$GH_LOG")" "5"
notcontains "19 T11o: the 6th newest run is never read" "$(gh_log)" "actions/runs/701"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_CAP_FAIL,$S17_CAP_SKIPS]"; STUB_RUN_CONC="700=cancelled 701=failure 703=cancelled 704=cancelled 705=cancelled 706=cancelled"
s17_at "$S17_H1"
contains "19 T11p the only successful other run is the 5th newest: read and accepted" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 702, 0 local"
S17_NC_CANC=$(s17_agg COMPLETED CANCELLED 2026-11-11T06:02:00Z 802)
# shellcheck disable=SC2016  # the unevaluated matrix name is literal on purpose
S17_NC_RUNS="$(s17_agg COMPLETED SKIPPED 2026-11-11T06:01:00Z 801 'shell-unit${{ x }}'),$(s17_agg COMPLETED SKIPPED 2026-11-11T06:00:00Z 800 'shell-unit${{ x }}')"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_NC_CANC,$S17_NC_RUNS]"; STUB_RUN_CONC="802=cancelled 801=failure 800=success"
s17_at "$S17_H1"
check "19 T11r newest cancelled, the next run failed, an older success: exit 1" "$rc" "1"
contains "19 T11r: the older success is not accepted" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/CANCELLED 802))"
notcontains "19 T11r: the older success is never read" "$(gh_log)" "actions/runs/800"
contains "19 T11r: a note names the failed run that decided" "$out" "note: the newest non-cancelled other CI run 801 is not a success at ${S17_H1:0:7} (read: failure ${S17_H1})"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_NC_CANC,$S17_NC_RUNS]"; STUB_RUN_CONC="802=cancelled 801= 800=success"
s17_at "$S17_H1"
contains "19 T11s newest cancelled, the next run still in progress, an older success: the older success is not accepted" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/CANCELLED 802))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_NC_CANC,$S17_NC_RUNS]"; STUB_RUN_CONC="802=cancelled 801=success 800=failure"
s17_at "$S17_H1"
contains "19 T11t newest cancelled, the next run succeeded: that run is accepted" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 801, 0 local"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_NC_CANC,$S17_NC_RUNS]"; STUB_RUN_CONC="802=cancelled 801=cancelled 800=success"
s17_at "$S17_H1"
contains "19 T11u two cancelled runs, then a success: the success is accepted" "$(line17 "$out")" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 800, 0 local"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; S17_ROLLUP="[$S17_LIVE_FAIL,$S17_LIVE_SKIP]"; STUB_RUN_CONC="$S17_LIVE_CONC"; STUB_RUN_SLEEP=10; READY_CHECK_ITEM19_BOUND=2
s17_at "$S17_H1"
contains "19 T11q a stalled run read on the FAILURE row: the verdict names the stalled read" "$(line17 "$out")" "gh api actions/runs/42975581119 timed out after 2s"
contains "19 T11q: it still names the FAILURE pick" "$(line17 "$out")" "latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 42975581119"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
# shellcheck disable=SC2016  # the unevaluated matrix name is literal on purpose
S17_ROLLUP="[$(s17_agg COMPLETED SUCCESS 2026-11-05T01:00:00Z 555 'shell-unit (${{ matrix.os }})')]"
s17_at "$S17_H1"
contains "19 T13 only the unevaluated matrix name: no settled CI run" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): none))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_RUN_HEAD_SHA="$S17_BASE"
s17_at "$S17_H1"
contains "19 T14 the run's head_sha is not SHA: FAIL" "$(line17 "$out")" "(no settled CI run (run 555 is not at ${S17_H1:0:7}))"
notcontains "19 T14: its manifests are never read" "$(gh_log)" "run download"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_RUN_HEAD_SHA="$S17_BASE"; S17_ROLLUP="[$S17_OLDOK]"
s17_at "$S17_H1"
contains "19 T14b the only SUCCESS run belongs to an older SHA: FAIL" "$(line17 "$out")" "(no settled CI run (run 554 is not at ${S17_H1:0:7}))"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
S17_ROLLUP="[$(s17_agg COMPLETED SUCCESS 2026-11-05T01:00:00Z 555),$(s17_agg COMPLETED SUCCESS 2026-11-05T03:00:00Z 600 'label-gate')]"
s17_at "$S17_H1"
check "19 T16 a later label run with no aggregator: exit 0" "$rc" "0"
contains "19 T16: the go run stands" "$out" "2 from CI run 555"

# T17 / T17b / T18: every read is bounded; no timeout binary FAILs
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
s17_t0=$SECONDS; s17_at "$S17_H1"; s17_base=$((SECONDS - s17_t0))
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_DL_SLEEP=10; READY_CHECK_ITEM19_BOUND=2
s17_t0=$SECONDS; s17_at "$S17_H1"; s17_dt=$((SECONDS - s17_t0))
contains "19 T17 a stalled download: names the read" "$(line17 "$out")" "[FAIL] 19. suite evidence: gh run download 555 timed out after 2s"
check "19 T17: bounded (${s17_dt}s, an unstalled run took ${s17_base}s)" "$((s17_dt < s17_base + 6))" "1"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_RUN_SLEEP=10; READY_CHECK_ITEM19_BOUND=2
s17_at "$S17_H1"
contains "19 T17b a stalled run read: names the read" "$(line17 "$out")" "[FAIL] 19. suite evidence: gh api actions/runs/555 timed out after 2s"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; READY_CHECK_ITEM19_BOUND=99
s17_at "$S17_H1"
check "19 a higher bound override is ignored: exit 0" "$rc" "0"
# a zero bound would reach timeout as "no limit": it is ignored, so the 30 s default still ends a stalled read
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_DL_SLEEP=40; READY_CHECK_ITEM19_BOUND=0
s17_at "$S17_H1"
contains "19 a zero bound override is ignored: the default bound ends a stalled read" "$(line17 "$out")" "[FAIL] 19. suite evidence: gh run download 555 timed out after 30s"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
PATH="$tmp/no-timeout:$PATH" s17_at "$S17_H1"
contains "19 T18 no timeout binary: FAIL" "$(line17 "$out")" "[FAIL] 19. suite evidence: no timeout binary"

# an impacted list the filter cannot read is a FAIL, never "0 impacted" (grep rc 2 is not grep rc 1)
mkdir -p "$tmp/bad-grep"
cat > "$tmp/bad-grep/grep" <<SH
#!/usr/bin/env bash
case "\$*" in '-v ^\$ '*imp.raw) exit 2 ;; esac
exec $(command -v grep) "\$@"
SH
chmod +x "$tmp/bad-grep/grep"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
PATH="$tmp/bad-grep:$PATH" s17_at "$S17_H1"
contains "19 an unreadable impacted list: FAIL, not 0 impacted" "$(line17 "$out")" "[FAIL] 19. suite evidence: cannot read the impacted list"

# T23: an unresolvable range FAILs, never an empty list
s17_clear
s17_at fedcba9876543210fedcba9876543210fedcba98
contains "19 T23 an unfetchable head: FAIL" "$(line17 "$out")" "[FAIL] 19. suite evidence: cannot resolve the range: cannot fetch PR head"
s17_clear
s17_at "$S17_ORPHAN"
contains "19 T23 no merge-base: FAIL" "$(line17 "$out")" "[FAIL] 19. suite evidence: cannot read the impacted list"
notcontains "19 T23: never a PASS" "$out" "[PASS] 19."
s17_clear

# T24-T25: the CI failure ledger (spec 7a). A suite left to CI that fails there at the
# head is one row; a later head of the same PR records the extra round, once.
S17_FL="$tmp/s17-ci-failures.jsonl"; rm -f "$S17_FL"
s17_fl() { jq -c "select($1)" "$S17_FL" 2>/dev/null | wc -l | tr -d ' '; }
S17_MAN_BRED="$tmp/s17-man-bred"; s17_man "$S17_MAN_BRED" "ran 0 $S17_A" "ran 1 $S17_B"
S17_RED="[$(s17_agg COMPLETED FAILURE 2026-11-05T02:00:00Z 556)]"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_BRED"; S17_ROLLUP="$S17_RED"
READY_CHECK_FAIL_LEDGER="$S17_FL" s17_at "$S17_H1"
contains "19 T24 a red CI run: still no settled CI run" "$(line17 "$out")" "(no settled CI run (latest shell-unit (ubuntu-latest): COMPLETED/FAILURE 556))"
check "19 T24: one fail row, for the suite CI failed" "$(s17_fl ".kind == \"fail\" and .repo == \"$NWO\" and .pr == 77 and .head == \"$S17_H1\" and .suite == \"$S17_B\" and .run == 556 and .rc == 1")" "1"
check "19 T24: the suite that ran 0 has no row" "$(s17_fl ".suite == \"$S17_A\"")" "0"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_BRED"; S17_ROLLUP="$S17_RED"
READY_CHECK_FAIL_LEDGER="$S17_FL" s17_at "$S17_H1"
check "19 T24b the same run read twice: still one row" "$(s17_fl '.kind == "fail"')" "1"
check "19 T24b: no round at the same head" "$(s17_fl '.kind == "round"')" "0"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_BRED"; S17_ROLLUP="$S17_RED"; S17_LP="[\"$S17_B\"]"
READY_CHECK_FAIL_LEDGER="$tmp/s17-fl-local.jsonl" s17_at "$S17_H1"
check "19 T24c a suite with a local PASS is not left to CI: no row" "$(cat "$tmp/s17-fl-local.jsonl" 2>/dev/null | wc -l | tr -d ' ')" "0"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
READY_CHECK_FAIL_LEDGER="$S17_FL" s17_at "$S17_HJS"
check "19 T25 a later head of the PR: one round row" "$(s17_fl ".kind == \"round\" and .repo == \"$NWO\" and .pr == 77 and .head == \"$S17_H1\" and .next == \"$S17_HJS\"")" "1"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
READY_CHECK_FAIL_LEDGER="$S17_FL" s17_at "$S17_HJS"
check "19 T25b read again: still one round row" "$(s17_fl '.kind == "round"')" "1"
printf '{"kind":"fail","repo":"other/x","pr":77,"head":"%s","suite":"a","run":1,"rc":1}\n' "$S17_BASE" > "$tmp/s17-fl-other.jsonl"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
READY_CHECK_FAIL_LEDGER="$tmp/s17-fl-other.jsonl" s17_at "$S17_H1"
check "19 T25c a fail row of another repo's PR 77: no round" "$(jq -c 'select(.kind == "round")' "$tmp/s17-fl-other.jsonl" | wc -l | tr -d ' ')" "0"
s17_clear

s17_man_cs() {
    local d="$1/shell-unit-manifest-ubuntu-latest-shard-claude-startup"
    shift
    mkdir -p "$d"
    { printf 'head 1111111111111111111111111111111111111111\nmode impacted\nshard claude-startup\n'; printf '%s\n' "$@"; } > "$d/manifest-shard-claude-startup.txt"
}
S17_MAN_CS_OK="$tmp/s17-man-cs-ok"; s17_man "$S17_MAN_CS_OK" "ran 0 $S17_A" "skip $S17_B"; s17_man_cs "$S17_MAN_CS_OK" "ran 0 $S17_B"
S17_MAN_CS_ONLYA="$tmp/s17-man-cs-onlya"; s17_man "$S17_MAN_CS_ONLYA" "skip $S17_A" "skip $S17_B"; s17_man_cs "$S17_MAN_CS_ONLYA" "ran 0 $S17_A"
S17_MAN_CS_77="$tmp/s17-man-cs-77"; s17_man "$S17_MAN_CS_77" "ran 0 $S17_A" "skip $S17_B"; s17_man_cs "$S17_MAN_CS_77" "ran 77 $S17_B"
S17_MAN_CS_BOTH="$tmp/s17-man-cs-both"; s17_man "$S17_MAN_CS_BOTH" "ran 0 $S17_A" "ran 0 $S17_B"; s17_man_cs "$S17_MAN_CS_BOTH" "ran 77 $S17_B"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_CS_OK"
s17_at "$S17_H1"
check "19 T26 the shard skipped B, the published file ran it: exit 0" "$rc" "0"
contains "19 T26: both suites proven from CI" "$out" "[PASS] 19. suite evidence: 2 impacted, 2 from CI run 555, 0 local"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_CS_ONLYA"
s17_at "$S17_H1"
check "19 T26b the published file proves only A, the shard skipped B: exit 0" "$rc" "0"
contains "19 T26b: B is tier-skipped as a CI skip" "$(line17 "$out")" "1 tier-skipped: $S17_B (CI skip)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_CS_77"
s17_at "$S17_H1"
check "19 T26c the published file says ran 77 for B: exit 1" "$rc" "1"
contains "19 T26c: B is the suite proven nowhere (CI ran it and it failed)" "$(line17 "$out")" "[FAIL] 19. suite evidence: 1 suite(s) proven nowhere: $S17_B (CI ran it and it failed)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_CS_BOTH"
s17_at "$S17_H1"
check "19 T26d a ran 0 row and a ran 77 row for B in two shards: exit 1" "$rc" "1"
contains "19 T26d: the green shard does not mask the red one" "$(line17 "$out")" "[FAIL] 19. suite evidence: 1 suite(s) proven nowhere: $S17_B (CI ran it and it failed)"
s17_clear

s17_js_man() {
    local d="$1/$2/js-suite-manifest-$3"
    shift 3
    mkdir -p "$d"
    printf '%s\n' "$@" > "$d/manifest-js-${d##*/js-suite-manifest-}.txt"
}
S17_JSN="note: from JS manifests: $S17_JS"
S17_JSM_OK="$tmp/s17-jsm-ok"; s17_js_man "$S17_JSM_OK" 555 bun-suites "ran 0 $S17_JS" "ran 0 scripts/lib/other.test.mjs"
S17_JSM_556="$tmp/s17-jsm-556"; s17_js_man "$S17_JSM_556" 556 bun-suites "ran 0 $S17_JS"
S17_JSM_NONE="$tmp/s17-jsm-none"; s17_js_man "$S17_JSM_NONE" 555 bun-suites "ran 0 scripts/lib/other.test.mjs"
S17_JSM_RED="$tmp/s17-jsm-red"; s17_js_man "$S17_JSM_RED" 555 bun-suites "ran 0 $S17_JS"; s17_js_man "$S17_JSM_RED" 555 lanes-and-trust-suites "ran 1 $S17_JS"
S17_JSM_SKIP="$tmp/s17-jsm-skip"; s17_js_man "$S17_JSM_SKIP" 555 bun-suites "skip $S17_JS"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"
s17_at "$S17_HJS"
check "19 T-JS1 an unchanged JS suite with ran 0 in the run's JS manifest: exit 0" "$rc" "0"
contains "19 T-JS1: PASS from the run" "$(line17 "$out")" "[PASS] 19. suite evidence: 1 impacted, 1 from CI run 555, 0 local"
contains "19 T-JS1: the JS manifests of run 555 are downloaded" "$(gh_log)" "run download 555 -R $NWO -p js-suite-manifest-*"
contains "19 T-JS1: the note names the suite proven from a JS manifest" "$out" "       $S17_JSN"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_556"
s17_at "$S17_HJS"
contains "19 T-JS1 the same artifact only under run 556: no proof" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"
s17_at "$S17_H1"
notcontains "19 T-JS1 control: suites proven by shell lines print no JS note" "$out" "note: from JS manifests"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_NONE"
s17_at "$S17_HJS"
contains "19 T-JS2 no JS line for the suite: FAIL" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (no ran-0 row in run 555)"
contains "19 T-JS2: the JS manifests were read" "$(gh_log)" "run download 555 -R $NWO -p js-suite-manifest-*"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_FILES="$S17_JS"
s17_at "$S17_HJS"
contains "19 T-JS3 a changed JS suite with a CI line and no local PASS: FAIL" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (the PR changed it: a CI line does not count, run it locally)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_FILES="$S17_JS"; S17_LP="[\"$S17_JS\"]"
s17_at "$S17_HJS"
check "19 T-JS4 control: the changed JS suite with its local PASS: exit 0" "$rc" "0"
contains "19 T-JS4: counted local" "$(line17 "$out")" "[PASS] 19. suite evidence: 1 impacted, 0 from CI run -, 1 local"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_FILES="$S17_A"
s17_at "$S17_H1"
contains "19 T-JS5 a changed shell suite with a shard ran 0 and no local PASS: FAIL" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_A (the PR changed it: a CI line does not count, run it locally)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_RED"
s17_at "$S17_HJS"
contains "19 T-JS6 ran 0 in one JS artifact, ran 1 in another: FAIL" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (CI ran it and it failed)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_SKIP"
s17_at "$S17_HJS"
contains "19 T-JS7 a JS skip line: tier-skipped" "$(line17 "$out")" "[PASS] 19. suite evidence: 1 impacted, 0 from CI run 555, 0 local, 1 tier-skipped: $S17_JS (CI skip)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_RUN_HEAD_SHA="$S17_BASE"
s17_at "$S17_HJS"
contains "19 T-JS8 control: the run is at another head: FAIL" "$(line17 "$out")" "(no settled CI run (run 555 is not at ${S17_HJS:0:7}))"
notcontains "19 T-JS8 control: no JS download" "$(gh_log)" "js-suite-manifest"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_JS_DL_FAIL=1
s17_at "$S17_HJS"
contains "19 T-JS9 a failed JS download: FAIL naming it" "$(line17 "$out")" "[FAIL] 19. suite evidence: gh run download 555 (JS manifests) failed (rc 1: HTTP 502)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"
s17_at "$S17_HJS"
contains "19 T-JS9 control: no JS artifact at all reads as no proof" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (no ran-0 row in run 555)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"
s17_at "$S17_H1"
check "19 T-JS10 control: every suite has a shell ran 0: exit 0" "$rc" "0"
notcontains "19 T-JS10 control: no JS download" "$(gh_log)" "js-suite-manifest"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_FILES_FAIL=1
s17_at "$S17_HJS"
contains "19 T-JS11 an unreadable PR file list: FAIL" "$(line17 "$out")" "[FAIL] 19. suite evidence: cannot read the PR's file list"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_FILES="$S17_JS"; S17_RS="[\"$S17_JS\"]"
s17_at "$S17_HJS"
check "19 T-JS12 control: a changed suite with a ruled SKIP: exit 0" "$rc" "0"
contains "19 T-JS12: named in the ruled list" "$(line17 "$out")" "1 ruled SKIP: $S17_JS"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_FILES="$S17_A"; STUB_BODY="${GREEN_BODY}Local suites: $S17_A\n"
s17_at "$S17_H1"
contains "19 T-JS12 control: a changed suite on a Local suites line: the Local suites reason" "$(line17 "$out")" "$S17_A (Local suites line, no local PASS)"
notcontains "19 T-JS12: not the changed reason" "$(line17 "$out")" "the PR changed it"
s17_clear; STUB_FILES_FAIL=1
s17_at "$S17_BASE"
contains "19 T-JS13 control: 0 impacted with an unreadable file list: PASS" "$(line17 "$out")" "[PASS] 19. suite evidence: 0 impacted, nothing to prove"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_A"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"
s17_at "$S17_HMIX"
contains "19 T-JS14 one shell suite unproven, the JS suite proven: FAIL on the shell suite" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_B (no ran-0 row in run 555)"
contains "19 T-JS14: the JS note prints under the FAIL" "$out" "       $S17_JSN"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_JOBS="failure|bun-suites (ubuntu-latest)
success|shell-unit (ubuntu-latest)"
s17_at "$S17_HJS"
contains "19 T-JS15 ran 0 from a job that failed: FAIL" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (CI job bun-suites did not succeed)"
notcontains "19 T-JS15: no JS note" "$out" "note: from JS manifests"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_JOBS="success|bun-suites (ubuntu-latest)
success|shell-unit (ubuntu-latest)"
s17_at "$S17_HJS"
check "19 T-JS16 the same, the job succeeded: exit 0" "$rc" "0"
contains "19 T-JS16: the jobs of the picked run are read" "$(gh_log)" "actions/runs/555/jobs"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_JOBS_FAIL=1
s17_at "$S17_HJS"
contains "19 T-JS17 an unreadable jobs list: FAIL naming the read" "$(line17 "$out")" "[FAIL] 19. suite evidence: gh api actions/runs/555/jobs failed (rc 1: HTTP 502)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_OK"; STUB_JOBS="success|shell-unit (ubuntu-latest)
success|bun-suites-extra (ubuntu-latest)"
s17_at "$S17_HJS"
contains "19 T-JS18 a manifest whose job is not in the run: no proof" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (CI job bun-suites did not succeed)"
S17_JSM_MX="$tmp/s17-jsm-mx"; s17_js_man "$S17_JSM_MX" 555 node-suites-himmel-gh "ran 0 $S17_JS"; s17_js_man "$S17_JSM_MX" 555 node-suites-jira "ran 0 scripts/lib/other.test.mjs"
S17_JSM_MXR="$tmp/s17-jsm-mxr"; s17_js_man "$S17_JSM_MXR" 555 node-suites-jira "ran 0 $S17_JS"; s17_js_man "$S17_JSM_MXR" 555 node-suites-himmel-gh "ran 0 scripts/lib/other.test.mjs"
S17_JOBS_MX="failure|node-suites (jira)
success|node-suites (himmel-gh, plugins/himmel-gh)
success|shell-unit (ubuntu-latest)"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_MX"; STUB_JOBS="$S17_JOBS_MX"
s17_at "$S17_HJS"
check "19 T-JS19 a matrix package green, another red: the green package's suite is proven" "$rc" "0"
contains "19 T-JS19: from the green package" "$out" "       $S17_JSN"
s17_clear; STUB_MANIFEST_DIR="$S17_MAN_AB"; STUB_JS_MANIFEST_DIR="$S17_JSM_MXR"; STUB_JOBS="$S17_JOBS_MX"
s17_at "$S17_HJS"
contains "19 T-JS19 the suite only in the red package: no proof" "$(line17 "$out")" "1 suite(s) proven nowhere: $S17_JS (CI job node-suites-jira did not succeed)"
s17_clear

reset_stubs
rm -rf "$tmp/quota"
rc=0; out="$(STUB_GH_RL=1 run 2>&1)" || rc=$?
check    "9479 T3: every read refused -> exit 2 (it was 'cannot resolve owner/repo')" "$rc" "2"
contains "9479 T3: the line names the quota" "$out" "QUOTA-PAUSE"
check    "9479 I8: no false phrase when every read is refused" "$(grep -c 'cannot resolve owner/repo\|\[FAIL\]\|READY-CHECK FAIL' <<< "$out" | tr -d ' ')" "0"
check    "9479 I4: a refusal leaves one marker keyed <pr>.<head>" "$(find "$tmp/quota/blocked" -type f -name "$PR.$SHA" 2>/dev/null | wc -l | tr -d ' ')" "1"
contains "9479 I4: the marker names the reason" "$(cat "$tmp/quota/blocked/$PR.$SHA" 2>/dev/null)" "reason=rate-limit"
contains "9479 I4: the marker names the caller" "$(cat "$tmp/quota/blocked/$PR.$SHA" 2>/dev/null)" "caller=ready-check.sh"
first_epoch=$(sed -n 's/^first_epoch=//p' "$tmp/quota/blocked/$PR.$SHA" 2>/dev/null)
sleep 1
rc=0; out="$(STUB_GH_RL=1 run 2>&1)" || rc=$?
check    "9479 I4: a second refusal keeps first_epoch" "$(sed -n 's/^first_epoch=//p' "$tmp/quota/blocked/$PR.$SHA" 2>/dev/null)" "$first_epoch"
check    "9479 I4: a second refusal leaves still one marker" "$(find "$tmp/quota/blocked" -type f ! -name '.lock*' 2>/dev/null | wc -l | tr -d ' ')" "1"
rm -rf "$tmp/quota"
rc=0; out="$(STUB_GH_RL=late run 2>&1)" || rc=$?
check    "9479 T3: a refusal after repo view -> exit 2, not exit 1" "$rc" "2"
contains "9479 T3: the late refusal names the quota" "$out" "QUOTA-PAUSE"
check    "9479 T3: the late refusal drops the FAIL rows" "$(grep -c '\[FAIL\]' <<< "$out" | tr -d ' ')" "0"
check    "9479 I4: the late refusal leaves a marker" "$(find "$tmp/quota/blocked" -type f -name "$PR.$SHA" 2>/dev/null | wc -l | tr -d ' ')" "1"
rm -rf "$tmp/quota"
rc=0; out="$(READY_CHECK_DEADLINE=0 STUB_GH_RL=late run 2>&1)" || rc=$?
check    "9479 T3: unarmed, a refusal is still exit 2" "$rc" "2"
contains "9479 T3: unarmed, the rows print first" "$out" "[FAIL]"
contains "9479 T3: unarmed, the quota line follows them" "$out" "QUOTA-PAUSE"
rm -rf "$tmp/quota"
rc=0; out="$(STUB_MSS=BEHIND run 2>&1)" || rc=$?
check    "9479 T3: a real FAIL with no refused read is still exit 1" "$rc" "1"
contains "9479 T3: a real FAIL still prints its row" "$out" "[FAIL] 1."
contains "9479 T3: a real FAIL still ends READY-CHECK FAIL" "$out" "READY-CHECK FAIL"
check    "9479 I4: a real FAIL leaves no marker" "$(find "$tmp/quota/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$tmp/quota"
rc=0; out="$(RUN_MODE=none run 2>&1)" || rc=$?
check    "9479 I4: a usage error is exit 2" "$rc" "2"
check    "9479 I4: a usage error leaves no marker" "$(find "$tmp/quota/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
mkdir -p "$tmp/nojq"
for f_nj in /bin/* /usr/bin/*; do [ "${f_nj##*/}" = jq ] || ln -sf "$f_nj" "$tmp/nojq/${f_nj##*/}"; done
rc=0; out="$(PATH="$tmp/bin:$tmp/nojq" run 2>&1)" || rc=$?
check    "9479 I4: a missing jq is exit 2" "$rc" "2"
contains "9479 I4: a missing jq names jq" "$out" "jq not found"
check    "9479 I4: a missing jq leaves no marker" "$(find "$tmp/quota/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
reset_stubs

# --- the self-armed deadline, so no caller needs a `timeout` prefix ---
# READY_CHECK_DEADLINE (whole seconds, default 150, 0 = none): argv unchanged; a stalled gh
# read ends in a named FAIL, never a hang, and the override reaches the wrapper.
reset_stubs
r1_shared="$tmp/lock-cache-r1"; mkdir -p "$r1_shared"
r1_fails0=$fails
env GH_PR_SNAPSHOT_CACHE_DIR="$r1_shared" GH_LOG="$tmp/holder.log" STUB_HEAD="$SHA" \
    STUB_NWO="$NWO" STUB_ROLLUP="$GREEN_ROLLUP" STUB_COMMITS="$GREEN_COMMITS" \
    STUB_GH_STALL=3 bash "$HERE/../../lib/gh-pr-snapshot.sh" "$NWO" 0 "$PR" > /dev/null 2>&1 &
r1_holder=$!
r1_took=no
for _ in $(seq 1 50); do
    if compgen -G "$r1_shared/*.lock/pid" > /dev/null; then r1_took=yes; break; fi
    sleep 0.1
done
check "R1: the holder took the snapshot lock" "$r1_took" "yes"
r1_alive=no; kill -0 "$r1_holder" 2>/dev/null && r1_alive=yes
check "R1: the holder still holds the lock when the run starts" "$r1_alive" "yes"
: > "$GH_LOG"
rc=0; out="$(GH_PR_SNAPSHOT_LOCK_WAIT=30 RUN_CACHE="$r1_shared" run)" || rc=$?
check "R1: a run that meets a held lock exits 0" "$rc" "0"
contains "R1: the verdict is PASS" "$out" "READY-CHECK PASS"
for r1_item in 1 2 3 4 5 6; do
    check "R1: item $r1_item passes" "$(grep -c "^\[PASS\] $r1_item\." <<< "$out" | tr -d ' ')" "1"
done
r1_reads=$(grep -Ec '^(repo view|pr view|api graphql)' "$GH_LOG" || true)
check "R1: the wait adds no gh read (at most 2 snapshot-shaped reads, saw ${r1_reads:-0})" "$([ "${r1_reads:-0}" -le 2 ] && echo yes || echo no)" "yes"
r1_hrc=0; wait "$r1_holder" || r1_hrc=$?
check "R1: the holder finished its read" "$r1_hrc" "0"
[ "$fails" -eq "$r1_fails0" ] || grep -E '^\[(PASS|FAIL)\] (1|2|3|4|5|6|16)\.' <<< "$out"
reset_stubs
# shellcheck source=scripts/lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"  # the same GNU timeout (timeout or gtimeout) ready-check resolves
REAL_TIMEOUT="$_TIMEOUT_BIN"
if [ -z "$REAL_TIMEOUT" ]; then
  echo "ok - deadline rows skipped: no GNU timeout on this host (ready-check runs without the deadline there)"
else
mkdir -p "$tmp/dl-bin"
cat > "$tmp/dl-bin/timeout" <<STUB
#!/usr/bin/env bash
[ "\$1" = "--version" ] || echo "\$*" >> "$tmp/timeout.log"
exec "$REAL_TIMEOUT" "\$@"
STUB
chmod +x "$tmp/dl-bin/timeout"
: > "$tmp/timeout.log"
rc=0; out="$(PATH="$tmp/dl-bin:$PATH" run)" || rc=$?
check "deadline: default run still passes" "$rc" "0"
check "deadline: the default is 150 s" "$(grep -c -E '^-k 5 150 bash .*ready-check\.sh ' "$tmp/timeout.log" | tr -d ' ')" "1"
: > "$tmp/timeout.log"
rc=0; out="$(READY_CHECK_DEADLINE=7 PATH="$tmp/dl-bin:$PATH" run)" || rc=$?
check "deadline: the override reaches the wrapper" "$(grep -c -E '^-k 5 7 bash .*ready-check\.sh ' "$tmp/timeout.log" | tr -d ' ')" "1"
check "deadline: the override run passes" "$rc" "0"
: > "$tmp/timeout.log"
rc=0; out="$(READY_CHECK_DEADLINE=0 PATH="$tmp/dl-bin:$PATH" run)" || rc=$?
check "deadline: 0 means no wrapper" "$(grep -c -E '^-k 5 [0-9]+ bash [^ ]*ready-check\.sh ' "$tmp/timeout.log" | tr -d ' ')" "0"
check "deadline: 0 still passes" "$rc" "0"
rc=0; out="$(READY_CHECK_DEADLINE=2 STUB_GH_STALL=30 run 2>&1)" || rc=$?
check "deadline: a stalled gh read exits 2 (nothing was judged)" "$rc" "2"
contains "deadline: the line names the deadline and its variable" "$out" "no verdict within the 2 s deadline (READY_CHECK_DEADLINE)"
check "deadline: a cut with no refused read leaves no marker (it may be local)" "$(find "$tmp/quota/blocked" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "deadline: a cut prints no FAIL row" "$(grep -c '\[FAIL\]\|READY-CHECK FAIL' <<< "$out" | tr -d ' ')" "0"
r2_shared="$tmp/lock-cache-r2"; mkdir -p "$r2_shared"
env GH_PR_SNAPSHOT_CACHE_DIR="$r2_shared" GH_LOG="$tmp/holder2.log" STUB_HEAD="$SHA" \
    STUB_NWO="$NWO" STUB_ROLLUP="$GREEN_ROLLUP" STUB_COMMITS="$GREEN_COMMITS" \
    STUB_GH_STALL=600 "$REAL_TIMEOUT" -k 2 12 bash "$HERE/../../lib/gh-pr-snapshot.sh" "$NWO" 0 "$PR" > /dev/null 2>&1 &
r2_holder=$!
r2_took=no
for _ in $(seq 1 50); do
    if compgen -G "$r2_shared/*.lock/pid" > /dev/null; then r2_took=yes; break; fi
    sleep 0.1
done
check "R2: the holder took the snapshot lock" "$r2_took" "yes"
r2_t0=$SECONDS
rc=0; out="$(GH_PR_SNAPSHOT_LOCK_WAIT=2 RUN_CACHE="$r2_shared" run)" || rc=$?
r2_elapsed=$((SECONDS - r2_t0))
check "R2: a lock that never frees fails the run" "$rc" "1"
contains "R2: the verdict is FAIL" "$out" "READY-CHECK FAIL"
notcontains "R2: never a PASS verdict" "$out" "READY-CHECK PASS"
for r2_item in 1 2 3 5 6; do
    check "R2: item $r2_item fails closed" "$(grep -c "^\[FAIL\] $r2_item\." <<< "$out" | tr -d ' ')" "1"
done
check "R2: the run ended on the lock wait, inside the holder's life (took $r2_elapsed s)" "$([ "$r2_elapsed" -lt 12 ] && echo yes || echo no)" "yes"
contains "R2: item 1 names why the snapshot was unreadable" "$out" "still held by pid"
wait "$r2_holder" 2>/dev/null || true
r2_left=no; compgen -G "$r2_shared/*.lock" > /dev/null && r2_left=yes
check "R2: the killed holder's trap freed its lock" "$r2_left" "no"
reset_stubs
r4_shared="$tmp/lock-cache-r4"; mkdir -p "$r4_shared"
r4_mark="$tmp/r4-holder.pid"; rm -f "$r4_mark"
r4_t0=$SECONDS
rc=0; out="$(STUB_MSS=UNKNOWN STUB_HOLD_MARK="$r4_mark" STUB_HOLD_TIMEOUT="$REAL_TIMEOUT" STUB_HOLD_LIFE=90 STUB_HOLD_LIB="$HERE/../../lib/gh-pr-snapshot.sh" RUN_CACHE="$r4_shared" run)" || rc=$?
r4_elapsed=$((SECONDS - r4_t0))
check "R4: the peer read was started" "$([ -s "$r4_mark" ] && echo yes || echo no)" "yes"
check "R4: a mergeStateStatus that stays UNKNOWN fails the run" "$rc" "1"
check "R4: item 1 fails on UNKNOWN, not on an unreadable PR" "$(grep -c '^\[FAIL\] 1\. .*mergeStateStatus=UNKNOWN' <<< "$out" | tr -d ' ')" "1"
for r4_item in 2 3 5 6; do
    check "R4: item $r4_item still judges the last good read" "$(grep -c "^\[PASS\] $r4_item\." <<< "$out" | tr -d ' ')" "1"
done
notcontains "R4: no cannot read" "$out" "cannot read"
contains "R4: item 1 names the re-read's 5 s lock wait" "$out" "after 5 s"
check "R4: the re-reads ended inside the peer's life (took $r4_elapsed s)" "$([ "$r4_elapsed" -lt 90 ] && echo yes || echo no)" "yes"
r4_hpid=$(cat "$r4_mark" 2>/dev/null) || r4_hpid=""
[ -z "$r4_hpid" ] || kill "$r4_hpid" 2>/dev/null || true
for _ in $(seq 1 100); do compgen -G "$r4_shared/*.lock" > /dev/null || break; sleep 0.1; done
r4_left=no; compgen -G "$r4_shared/*.lock" > /dev/null && r4_left=yes
check "R4: the killed peer's trap freed its lock" "$r4_left" "no"
fi
reset_stubs

C20="$tmp/c20"
git init -q --bare "$tmp/c20-origin.git"
git init -q -b main "$C20"
git -C "$C20" config user.email t@example.com; git -C "$C20" config user.name t; git -C "$C20" config commit.gpgsign false
printf 'a\nkeep\n' > "$C20/f.sh"
git -C "$C20" add f.sh; git -C "$C20" commit -q -m "chore: init"
git -C "$C20" remote add origin "$tmp/c20-origin.git"
git -C "$C20" push -q origin main
git -C "$C20" checkout -q -b feat/b
printf 'branch\nkeep\n' > "$C20/f.sh"; git -C "$C20" commit -q -am "feat(x): [HIMMEL-1] branch edit"
C20_BRANCH_TIP=$(git -C "$C20" rev-parse HEAD)
git -C "$C20" checkout -q main
printf 'main\nkeep\n' > "$C20/f.sh"; git -C "$C20" commit -q -am "fix(y): [HIMMEL-2] other edit (#12)"
git -C "$C20" push -q origin main
git -C "$C20" checkout -q feat/b
git -C "$C20" merge -q main >/dev/null 2>&1
printf 'branch and main\nkeep\n' > "$C20/f.sh"; git -C "$C20" add f.sh; git -C "$C20" commit -q --no-edit
C20_MERGED=$(git -C "$C20" rev-parse HEAD)
git -C "$C20" checkout -q -b feat/ours "$C20_BRANCH_TIP"
git -C "$C20" merge -q main >/dev/null 2>&1
git -C "$C20" checkout -q --ours f.sh; git -C "$C20" add f.sh; git -C "$C20" commit -q --no-edit
C20_OURS=$(git -C "$C20" rev-parse HEAD)
C20_LINE='\n## Conflicts resolved\n- f.sh vs #12: kept both edits, the branch line and main line\n'

reset_stubs
rc=0; out="$(REPO="$C20" SHA="$C20_MERGED" run)" || rc=$?
contains "item 20: a conflicted f.sh with no body line FAILs" "$out" "[FAIL] 20."
contains "item 20: no body line: prints the line to add" "$out" "- f.sh vs #12: <what you kept and why>"

reset_stubs
rc=0; out="$(STUB_BODY="$GREEN_BODY$C20_LINE" REPO="$C20" SHA="$C20_MERGED" run)" || rc=$?
contains "item 20: the body line for f.sh PASSes" "$out" "[PASS] 20."
notcontains "item 20: with the line: no FAIL" "$out" "[FAIL] 20."

reset_stubs
rc=0; out="$(STUB_BODY="$GREEN_BODY$C20_LINE" REPO="$C20" SHA="$C20_OURS" run)" || rc=$?
c20_warn=$(grep '^\[WARN\] 20\.' <<< "$out" || true)
contains "item 20: an ours resolution WARNs" "$c20_warn" "ours"
contains "item 20: the ours WARN names #12" "$c20_warn" "#12"
notcontains "item 20: an ours resolution with its line is no FAIL" "$out" "[FAIL] 20."

C20_STUB_ANCHOR="$tmp/c20-stub-anchor"
cp -R "$TP_ANCHOR" "$C20_STUB_ANCHOR"
printf 'import sys\nsys.exit(2)\n' > "$C20_STUB_ANCHOR/scripts/eval/conflicts/conflicts.py"
reset_stubs
rc=0; out="$(READY_CHECK_ANCHOR="$C20_STUB_ANCHOR" REPO="$C20" SHA="$C20_MERGED" run)" || rc=$?
contains "item 20: a detector exiting 2 WARNs conflicts unknown" "$out" "[WARN] 20. conflicts unknown"
notcontains "item 20: a detector exiting 2 is never a FAIL" "$out" "[FAIL] 20."

reset_stubs
rc=0; out="$(STUB_HEAD="$C20_MERGED" REPO="$C20" run7)" || rc=$?
c20_fail=$(grep '^\[FAIL\] 20\.' <<< "$out" || true)
contains "item 20 under --only 7: runs on the item-7 head and FAILs" "$out" "[FAIL] 20."
contains "item 20 under --only 7: names f.sh" "$out" "- f.sh vs #12: <what you kept and why>"
contains "item 20 under --only 7: the FAIL line names the head" "$c20_fail" "${C20_MERGED:0:7}"
check "item 20 under --only 7: the lint fails" "$rc" "1"
contains "item 20 under --only 7: says COVERAGE-LINT FAIL" "$out" "COVERAGE-LINT FAIL"
reset_stubs

git -C "$REPO" config ghstub.nwo "$NWO"
NOWHERE="$tmp/nowhere"; mkdir -p "$NOWHERE"
DECOY="$tmp/decoy"; mkdir -p "$DECOY"
git -C "$DECOY" init -q
git -C "$DECOY" config ghstub.nwo other/luna
export STUB_NWO_BY_CWD=1
reset_stubs
rc=0; base_out="$(run)" || rc=$?; base_rc=$rc
check "anchor: control from the checkout passes" "$base_rc" "0"
contains "anchor: control says READY-CHECK PASS" "$base_out" "READY-CHECK PASS"

: > "$GH_LOG"
rc=0; out="$(RUN_CWD="$NOWHERE" run)" || rc=$?
check "anchor R1: from a directory outside any repo, same exit as the checkout" "$rc" "$base_rc"
check "anchor R1: from a directory outside any repo, same output as the checkout" "$out" "$base_out"
notcontains "anchor R1: no cannot-resolve refusal from nowhere" "$out" "cannot resolve owner/repo"

: > "$GH_LOG"
rc=0; out="$(RUN_CWD="$DECOY" run)" || rc=$?
check "anchor R2: from a decoy repo, same exit as the checkout" "$rc" "$base_rc"
check "anchor R2: from a decoy repo, same output as the checkout" "$out" "$base_out"
check "anchor R2: no gh call names the decoy's repo" "$(grep -c 'other/luna' "$GH_LOG")" "0"

: > "$GH_LOG"
rc=0; out="$(GIT_DIR="$DECOY/.git" GIT_WORK_TREE="$DECOY" run)" || rc=$?
check "anchor R15: an inherited GIT_DIR on a decoy gives the checkout's exit" "$rc" "$base_rc"
check "anchor R15: an inherited GIT_DIR on a decoy gives the checkout's output" "$out" "$base_out"
check "anchor R15: no gh call names the decoy's repo" "$(grep -c 'other/luna' "$GH_LOG")" "0"

mkdir -p "$tmp/empty-objects"
rc=0; out="$(GIT_OBJECT_DIRECTORY="$tmp/empty-objects" run)" || rc=$?
check "anchor: an inherited GIT_OBJECT_DIRECTORY gives the checkout's exit" "$rc" "$base_rc"
check "anchor: an inherited GIT_OBJECT_DIRECTORY gives the checkout's output" "$out" "$base_out"

: > "$GH_LOG"
rc=0; out="$(GIT_CONFIG_PARAMETERS="'ghstub.nwo=other/luna'" run)" || rc=$?
check "anchor: an inherited GIT_CONFIG_PARAMETERS gives the checkout's exit" "$rc" "$base_rc"
check "anchor: an inherited GIT_CONFIG_PARAMETERS gives the checkout's output" "$out" "$base_out"
check "anchor: an inherited GIT_CONFIG_PARAMETERS names no decoy repo to gh" "$(grep -c 'other/luna' "$GH_LOG")" "0"

mkdir -p "$tmp/nodebin"
export NODE_LOG="$tmp/node.log"; : > "$NODE_LOG"
cat > "$tmp/nodebin/node" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$NODE_LOG"
exit 1
STUB
chmod +x "$tmp/nodebin/node"
rc=0; out="$(PATH="$tmp/nodebin:$PATH" RUN_JIRA_CMD="" RUN_CWD="$NOWHERE" STUB_BODY="$BO_GOOD" STUB_PR_TITLE='fix(x): [HIMMEL-900] thing' run)" || rc=$?
check "anchor: no jira CLI call is made through a bare /scripts path" "$(grep -c '^/scripts/jira' "$NODE_LOG")" "0"
check "anchor: the jira CLI is called through the script's own primary checkout" "$([ "$(grep -c "^$test_primary/scripts/jira/dist/index.js\$" "$NODE_LOG")" -ge 1 ] && echo yes)" "yes"

RW="$tmp/rel-tree"
mkdir -p "$RW/scripts/handover/chief-kit"
cp "$SCRIPT" "$RW/scripts/handover/chief-kit/ready-check.sh"
cp -R "$REPO_ROOT/scripts/lib" "$RW/scripts/lib"
printf 'echo REL-TREE-LIB-MARKER\n' >> "$RW/scripts/lib/non-gating-contexts.sh"
rc=0; out="$(RUN_CWD="$RW" RUN_SCRIPT=scripts/handover/chief-kit/ready-check.sh run)" || rc=$?
contains "anchor R10: relative entry from the tree root reaches the checks" "$out" "[PASS] 1."
contains "anchor R10: the relative entry loads its own tree's lib" "$out" "REL-TREE-LIB-MARKER"

PRIM="$tmp/prim-repo"; LINKED="$tmp/prim-linked"
git init -q "$PRIM"
git -C "$PRIM" config user.email t@example.com
git -C "$PRIM" config user.name tester
git -C "$PRIM" commit -q --allow-empty -m "chore: init"
git -C "$PRIM" config ghstub.nwo "$NWO"
git -C "$PRIM" worktree add -q --detach "$LINKED"
mkdir -p "$LINKED/scripts/handover/chief-kit"
cp "$SCRIPT" "$LINKED/scripts/handover/chief-kit/ready-check.sh"
cp -R "$REPO_ROOT/scripts/lib" "$LINKED/scripts/lib"
export STUB_CWD_LOG="$tmp/stub-cwd.log"; : > "$STUB_CWD_LOG"
rc=0; out="$(RUN_CWD="$NOWHERE" RUN_HIMMEL_REPO="" RUN_SCRIPT="$LINKED/scripts/handover/chief-kit/ready-check.sh" run)" || rc=$?
contains "anchor: with HIMMEL_REPO empty the script reaches the checks from any cwd" "$out" "[PASS] 1."
check "anchor: with HIMMEL_REPO empty gh reads the primary checkout, not the linked worktree the script sits in" "$(sort -u "$STUB_CWD_LOG")" "$(cd "$PRIM" && pwd -P)"

rc=0; out="$(cd "$NOWHERE" && HIMMEL_REPO=rel/path bash "$SCRIPT" --observe "$PR" "$SHA" 2>&1)" || rc=$?
check "anchor: a relative HIMMEL_REPO is refused with exit 2" "$rc" "2"
contains "anchor: the refusal names HIMMEL_REPO" "$out" "HIMMEL_REPO"
contains "anchor: the relative refusal is the exact line" "$out" "ready-check: HIMMEL_REPO (rel/path) is not an absolute path - refusing to let it pick the gated checkout; nothing was judged"
rc=0; out="$(cd "$NOWHERE" && HIMMEL_REPO="$NOWHERE/gone" bash "$SCRIPT" --observe "$PR" "$SHA" 2>&1)" || rc=$?
check "anchor: a HIMMEL_REPO that is not a directory is refused with exit 2" "$rc" "2"
contains "anchor: the not-a-directory refusal is the exact line" "$out" "ready-check: the gated checkout HIMMEL_REPO ($NOWHERE/gone) is not a directory; nothing was judged"
unset STUB_NWO_BY_CWD
reset_stubs

OR_GATE="$REPO_ROOT/scripts/ci/codeowner-review-gate.mjs"
OR_BASE_SHA=0123456789abcdef0123456789abcdef01234567
OR_MOVED=fedcba9876543210fedcba9876543210fedcba98
or_rollup() { printf '[{"name":"codeowner-review-gate","workflowName":"codeowner-review-gate","status":"COMPLETED","conclusion":"%s"}]' "$1"; }
cat > "$tmp/gate-error.mjs" <<'GATE'
console.log('codeowner-review-gate: ERROR — boom');
process.exit(2);
GATE
cat > "$tmp/gate-fail.mjs" <<'GATE'
console.log('codeowner-review-gate: FAIL — o is an outside contributor; code-owner approval at the current head is required from: @alice (no review)');
process.exit(1);
GATE
or_reset() {
    unset STUB_OR_RD STUB_OR_PERM STUB_OR_AUTHOR STUB_OR_AUTHOR_TYPE STUB_OR_REVIEWS STUB_OR_FILES STUB_OR_CODEOWNERS STUB_OR_NOGATE
    unset STUB_OR_RULES_FAIL STUB_OR_RATELIMIT STUB_OR_BASE_FAIL STUB_OR_GATE_FAIL STUB_OR_MOVE_HEAD STUB_OR_MOVE_BASE STUB_OR_HANG STUB_OR_SNAP_SLEEP STUB_OR_GQL STUB_OR_GQL_RATE STUB_OR_BAD_PR OR_ARGS
    export STUB_OR_GATE_FILE="$OR_GATE" READY_CHECK_GATE_SCRIPT="$OR_GATE"
    rm -f "$STUB_OR_DIR"/*.count "$STUB_OR_DIR"/*.log "$tmp/quota/quota.tsv"
    reset_stubs
}
or_go() { rc=0; out="$(RUN_MODE=owner run 2>/dev/null)" || rc=$?; }
or_is() { check "$1: exit" "$rc" "$2"; contains "$1: the line" "$out" "$3"; }
or_outside() { STUB_OR_PERM=read STUB_OR_AUTHOR=outsider; export STUB_OR_PERM STUB_OR_AUTHOR; }

or_reset
STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR1 an owner PR with the gate required" 0 "owner-review: not-required (rule-a: yotamleo has admin permission; check at head: SKIPPED)"

or_reset; STUB_ROLLUP="$(or_rollup FAILURE)" or_go
or_is "OR1n a rule-a PASS whose head check is FAILURE" 2 "owner-review: unknown (gate-mismatch:"
or_reset; STUB_OR_RULES_FAIL=1 or_go
or_is "OR1r the required-set read fails" 2 "owner-review: unknown (required-set:"
or_reset
mkdir -p "$tmp/quota"
printf 'main\tcore\t10\t5000\t%s\t%s\tok\n' "$(( $(date +%s) + 3000 ))" "$(date +%s)" > "$tmp/quota/quota.tsv"
or_go
or_is "OR1q the fixture quota paused" 2 "owner-review: unknown (required-set: QUOTA-PAUSE"
or_reset; STUB_SNAPSHOT_FAIL=1 or_go
or_is "OR1s the snapshot fails" 2 "owner-review: unknown (snapshot:"
or_reset; READY_CHECK_GATE_SCRIPT="$tmp/gate-error.mjs" STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR1g the gate script prints ERROR" 2 "owner-review: unknown (gate: codeowner-review-gate: ERROR"
or_reset; READY_CHECK_GATE_SCRIPT="$tmp/gate-fail.mjs" STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR1x the gate script FAILs an owner whose head check is SKIPPED" 2 "owner-review: unknown (gate-mismatch:"
or_reset; STUB_OR_MOVE_HEAD="$OR_MOVED" or_go
or_is "OR1v the head moves between the snapshot and the re-read" 2 "owner-review: unknown (snapshot:"
or_reset; unset READY_CHECK_GATE_SCRIPT; STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR1f no seam: the script is fetched through the contents API" 0 "owner-review: not-required (rule-a:"
contains "OR1f: the fetch is pinned at base.sha" "$(cat "$STUB_OR_DIR/gate-fetch.log")" "?ref=$OR_BASE_SHA"
or_reset; unset READY_CHECK_GATE_SCRIPT; STUB_OR_GATE_FAIL=1 or_go
or_is "OR1fn the contents read fails" 2 "owner-review: unknown (gate: script unreadable"
or_reset; STUB_OR_BASE_FAIL=1 or_go
or_is "OR1b the pulls/<n> base read fails" 2 "owner-review: unknown (snapshot:"
or_reset; STUB_OR_MOVE_BASE="$OR_MOVED" or_go
or_is "OR1vb the base moves between the base read and the re-read" 2 "owner-review: unknown (snapshot:"

or_reset; or_outside; STUB_ROLLUP="$(or_rollup FAILURE)" or_go
or_is "OR2 an outside author with no approval" 0 "owner-review: required (owed: outsider is an outside contributor; code-owner approval at the current head is required from: @alice (no review))"
or_reset; or_outside; STUB_OR_NOGATE=1 or_go
or_is "OR2n the same author, gate not required" 0 "owner-review: not-required (no-rule:"
or_reset; STUB_OR_AUTHOR='dependabot[bot]' STUB_OR_AUTHOR_TYPE=Bot STUB_AUTHOR=app/dependabot STUB_ROLLUP="$(or_rollup FAILURE)"
export STUB_OR_AUTHOR STUB_OR_AUTHOR_TYPE
or_go
or_is "OR2b a Bot author" 0 "owner-review: required (owed:"
rc=0; out="$(RUN_MODE=outside run 2>/dev/null)" || rc=$?
contains "OR2b: --outside on the same stubs says outside-pr: no" "$out" "outside-pr: no"
unset STUB_AUTHOR STUB_OR_AUTHOR STUB_OR_AUTHOR_TYPE
or_reset; or_outside; STUB_OR_CODEOWNERS='docs/ @alice\n' STUB_ROLLUP="$(or_rollup FAILURE)" or_go
or_is "OR2x no covering owner" 0 "owner-review: required (blocked:"

or_reset; STUB_OR_RD=REVIEW_REQUIRED STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR3 REVIEW_REQUIRED" 0 "owner-review: required (owed: GitHub reviewDecision REVIEW_REQUIRED)"
or_reset; STUB_OR_RD=CHANGES_REQUESTED or_go
or_is "OR3c CHANGES_REQUESTED" 0 "owner-review: required (changes-requested:"
or_reset; or_outside; STUB_OR_RD=APPROVED STUB_ROLLUP="$(or_rollup FAILURE)" or_go
or_is "OR3a APPROVED, an outside author missing approvals" 0 "owner-review: required (owed:"
or_reset; STUB_OR_RD=APPROVED STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR3a APPROVED on an owner" 0 "owner-review: required (satisfied: GitHub reviewDecision APPROVED)"
or_reset; STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
notcontains "OR3n an empty reviewDecision is not required" "$out" "owner-review: required"

or_reset; export STUB_OR_GQL=1; OR_ARGS="77 78" STUB_ROLLUP="$(or_rollup SKIPPED)" or_go
or_is "OR4 two PRs" 0 "#77 owner-review: not-required (rule-a:"
contains "OR4: the second PR has its own prefixed line" "$out" "#78 owner-review: not-required (rule-a:"
check "OR4: one GraphQL snapshot query" "$(wc -l < "$STUB_OR_DIR/gql.count" | tr -d ' ')" "1"
or_reset; export STUB_OR_GQL=1; OR_ARGS="101 102 103 104 105 106 107 108 109 110 111 112" or_go
check "OR4c: twelve PRs, twelve lines" "$(grep -c '^#1[01][0-9] owner-review: ' <<< "$out")" "12"
check "OR4c: two GraphQL snapshot queries (chunks of 10)" "$(wc -l < "$STUB_OR_DIR/gql.count" | tr -d ' ')" "2"
or_reset; export STUB_OR_GQL=1 STUB_OR_BAD_PR=79; OR_ARGS="77 78 79" or_go
or_is "OR4r the batch fails: the PR that fails alone is unknown" 2 "#79 owner-review: unknown (snapshot:"
contains "OR4r: the others are retried alone and answer" "$out" "#77 owner-review: not-required"
contains "OR4r: the second other too" "$out" "#78 owner-review: not-required"

or_reset; STUB_OR_RATELIMIT=1 or_go
or_is "OR5r the rules read answers a rate limit" 2 "owner-review: unknown (required-set:"
notcontains "OR5r: no quota line replaces it" "$out" "QUOTA"
or_reset; export STUB_OR_GQL=1 STUB_OR_GQL_RATE=1 OR_ARGS="77 78"; : > "$tmp/or5s-refused"
GH_READ_REFUSED_FILE="$tmp/or5s-refused" or_go
or_is "OR5s a rate-limited snapshot read" 2 "#77 owner-review: unknown (snapshot:"
check "OR5s: the caller's refused-read file stays empty" "$(wc -c < "$tmp/or5s-refused" | tr -d ' ')" "0"
cat > "$tmp/gate-hang.mjs" <<'GATE'
setInterval(() => {}, 1000);
GATE
or_reset; READY_CHECK_GATE_SCRIPT="$tmp/gate-hang.mjs"; export READY_CHECK_GATE_SCRIPT
t0=$(date +%s); or_go; t1=$(date +%s)
or_is "OR5t a gate script that never ends" 2 "owner-review: unknown (gate: timeout after 30 s)"
check "OR5t: it ends inside 45 s" "$([ $((t1 - t0)) -le 45 ] && echo yes)" "yes"
or_reset; export STUB_OR_HANG=1; OR_ARGS="--deadline 3 77"
t0=$(date +%s); or_go; t1=$(date +%s)
or_is "OR5d --deadline 3 over a hung base read" 2 "owner-review: unknown (gate: deadline)"
check "OR5d: it ends inside 8 s" "$([ $((t1 - t0)) -le 8 ] && echo yes)" "yes"
or_reset; export STUB_OR_SNAP_SLEEP=4; OR_ARGS="--deadline 3 77"
t0=$(date +%s); or_go; t1=$(date +%s)
or_is "OR5e --deadline 3 over a snapshot read that outlasts it" 2 "owner-review: unknown (gate: deadline)"
check "OR5e: it ends inside 10 s" "$([ $((t1 - t0)) -le 10 ] && echo yes)" "yes"

or_reset; export STUB_OR_BASE_FAIL=1
rc=0; out="$(run 2>/dev/null)" || rc=$?
check "OR6 the full run exits 0 with an unknown line" "$rc" "0"
contains "OR6: the line is printed" "$out" "owner-review: unknown (snapshot:"
or_pos=$(grep -n '^owner-review:' <<< "$out" | cut -d: -f1)
dd_pos=$(grep -n '^The three-dot diff read' <<< "$out" | cut -d: -f1)
tp_pos=$(grep -n '^TRUST-PATH:' <<< "$out" | cut -d: -f1)
vd_pos=$(grep -n '^READY-CHECK ' <<< "$out" | cut -d: -f1)
check "OR6: after the three-dot-diff line, before TRUST-PATH and the verdict" "$((dd_pos < or_pos && or_pos < tp_pos && tp_pos < vd_pos))" "1"
or_reset; export STUB_OR_BASE_FAIL=1; STUB_FILES="scripts/lib/fixtures/anything.txt"
rc=0; out="$(run 2>/dev/null)" || rc=$?
check "OR6: with TRUST-PATH yes the full run still exits 0" "$rc" "0"
or_pos=$(grep -n '^owner-review:' <<< "$out" | cut -d: -f1)
tp_pos=$(grep -n '^TRUST-PATH: yes' <<< "$out" | cut -d: -f1)
check "OR6: the line sits before TRUST-PATH: yes" "$((or_pos < tp_pos))" "1"
or_reset; export STUB_OR_BASE_FAIL=1; STUB_MSS=BLOCKED
rc=0; out="$(run 2>/dev/null)" || rc=$?
check "OR6n another item fails: exit 1" "$rc" "1"
contains "OR6n: the line is unchanged" "$out" "owner-review: unknown (snapshot:"
or_reset; export STUB_OR_RATELIMIT=1; STUB_MSS=BLOCKED
rc=0; out="$(run 2>/dev/null)" || rc=$?
check "OR6r another item fails and the rules read is rate limited: exit 1, not 2" "$rc" "1"
contains "OR6r: the line is unknown (required-set:" "$out" "owner-review: unknown (required-set:"
check "OR6r: no blocked mark in the fixture quota dir" "$(find "$tmp/quota" -type f ! -name quota.tsv 2>/dev/null | wc -l | tr -d ' ')" "0"

or_reset
t0=$(date +%s); rc=0; out="$(run 2>/dev/null)" || rc=$?; t1=$(date +%s)
or_base_rc=$rc; or_base_s=$((t1 - t0))
or_reset; export STUB_OR_HANG=1
t0=$(date +%s); rc=0; out="$(run 2>/dev/null)" || rc=$?; t1=$(date +%s)
contains "OR6t the hung owner-review reads print the deadline line" "$out" "owner-review: unknown (gate: deadline)"
check "OR6t: the exit code equals the baseline's" "$rc" "$or_base_rc"
check "OR6t: the run ends within baseline + 22 s" "$([ $((t1 - t0)) -le $((or_base_s + 22)) ] && echo yes)" "yes"

OR7_ROOT="$tmp/or7-root"; mkdir -p "$OR7_ROOT"
printf 'himmel_github_token_vm2=or7dummytok\n' > "$OR7_ROOT/.env"
or_reset
t0=$(date +%s); rc=0; out="$(GH_READ_ENV_ROOT="$OR7_ROOT" STUB_ROLLUP="$(or_rollup SKIPPED)" RUN_MODE=owner run 2>/dev/null)" || rc=$?; t1=$(date +%s)
or_is "OR7 the real shim and gate" 0 "owner-review: not-required (rule-a:"
check "OR7: under 5 s" "$([ $((t1 - t0)) -lt 5 ] && echo yes)" "yes"
check "OR7: each gate call reaches the stub once" "$(wc -l < "$STUB_OR_DIR/gate-calls.log" | tr -d ' ')" "2"
check "OR7: every gate call carries the read token" "$(grep -c '^GH_TOKEN=or7dummytok ' "$STUB_OR_DIR/gate-calls.log")" "2"
or_reset

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
