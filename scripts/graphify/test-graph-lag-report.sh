#!/usr/bin/env bash
# Smoke test for scripts/graphify/graph-lag-report.py.
#
# Every scenario plants its own git repo and ledger under one temp dir and
# passes both by path: the report never reads the live ledger, the live
# graphify-out or the live vault, and never touches the network.
#
# Covers:
#   replays_planted_ledger       -- hourly lag, p50, p90, max from a planted ledger and repo
#   failed_fires_grow_gap        -- failed and skipped rows do not move the published graph,
#                                   so the gap grows; a later publish closes it
#   over_limit_counted           -- hours over the limit, and the breaches of 40 and 100
#   reads_limit_from_update_script -- the limit is GRAPH_MAX_BEHIND in himmel-update.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/graph-lag-report.py"
REAL_UPDATE="$SCRIPT_DIR/../himmel-update.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -z "${2:-}" ] || echo "        $2"; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "wanted '$2' in: $3" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "wanted '$2', got '$3'"; fi; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-graph-lag-report.XXXXXX")" || exit 2
trap 'rm -rf "$TMP_ROOT"' EXIT

T0=1793491200   # 2026-11-01T00:00:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# plant_repo <dir> <n> -- n empty commits on main, commit i made i hours after T0
plant_repo() {
    local dir="$1" n="$2" i t
    git init -q --initial-branch=main "$dir" 2>/dev/null || git init -q "$dir"
    git -C "$dir" config user.email t@test.com
    git -C "$dir" config user.name test
    for i in $(seq 0 $((n - 1))); do
        t=$(iso $((T0 + i * 3600)))
        GIT_AUTHOR_DATE="$t" GIT_COMMITTER_DATE="$t" git -C "$dir" commit -q --allow-empty -m "c$i"
    done
}
# commit_of <repo> <i> -- the sha of commit ci
commit_of() { git -C "$1" log --format=%H --grep="^c$2\$" -n 1 main; }
# row <ts-offset-hours> <action> <graph_head>
row() {
    local gh="null"
    [ -z "${3:-}" ] || gh="\"$3\""
    printf '{"ts":"%s","head":"x","graph_head":%s,"merges_behind":null,"action":"%s","pr":null,"duration_s":1,"error":null}\n' \
        "$(iso $((T0 + $1 * 3600)))" "$gh" "$2"
}
UPD10="$TMP_ROOT/update-10.sh"; printf '#!/usr/bin/env bash\nGRAPH_MAX_BEHIND=10\n' > "$UPD10"
UPD30="$TMP_ROOT/update-30.sh"; printf '#!/usr/bin/env bash\nGRAPH_MAX_BEHIND=30\n' > "$UPD30"

R1="$TMP_ROOT/r1"; plant_repo "$R1" 24
C0=$(commit_of "$R1" 0); C12=$(commit_of "$R1" 12)

echo "TEST: replays_planted_ledger -- hourly lag, p50, p90, max"
L1="$TMP_ROOT/l1.jsonl"
row 0 published-channel "$C0" > "$L1"
rc=0
out=$(python3 -I "$REPORT" --ledger "$L1" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD10" 2>&1) || rc=$?
assert_eq "planted ledger rc=0" "0" "$rc"
assert_contains "24 hourly samples" "hours=24" "$out"
assert_contains "p50, p90 and max of lags 0..23" "lag-commits: p50=11 p90=21 max=23" "$out"
assert_contains "no sample lacks a baseline" "no-baseline-hours=0" "$out"
assert_contains "hours over the planted limit of 10 (lags 11..23)" "hours-over-limit: 13 (limit 10" "$out"

echo "TEST: failed_fires_grow_gap -- failed and skipped rows leave the published graph where it was"
L2="$TMP_ROOT/l2.jsonl"
{ row 0 published-channel "$C0"; row 6 failed; row 10 skipped "$C0"; row 14 failed; row 18 failed; row 22 failed; } > "$L2"
out=$(python3 -I "$REPORT" --ledger "$L2" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD10" 2>&1) || true
assert_contains "failed fires: the gap keeps growing to 23" "max=23" "$out"
L2B="$TMP_ROOT/l2b.jsonl"
{ row 0 published-channel "$C0"; row 6 failed; row 12 published-channel "$C12"; row 14 failed; } > "$L2B"
out=$(python3 -I "$REPORT" --ledger "$L2B" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD10" 2>&1) || true
assert_contains "a publish at hour 12 closes the gap: max falls to 11" "max=11" "$out"

echo "TEST: unresolved_publish_unknown -- a publish whose build commit is not in the repo is unknown hours, not the older graph"
L2C="$TMP_ROOT/l2c.jsonl"
{ row 0 published-channel "$C0"; row 12 published-channel 0123456789abcdef0123456789abcdef01234567; } > "$L2C"
out=$(python3 -I "$REPORT" --ledger "$L2C" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD10" 2>&1) || true
assert_contains "the 12 hours after the unresolvable publish are unknown" "unknown-hours=12" "$out"
assert_contains "only the 12 resolvable hours enter the figures (lags 0..11)" "max=11" "$out"

echo "TEST: over_limit_counted -- hours over the limit and the breaches of 40 and 100"
R3="$TMP_ROOT/r3"; plant_repo "$R3" 130
L3="$TMP_ROOT/l3.jsonl"
row 0 published-channel "$(commit_of "$R3" 0)" > "$L3"
out=$(python3 -I "$REPORT" --ledger "$L3" --repo "$R3" --days 6 --now "$(iso $((T0 + 129 * 3600)))" --update-script "$UPD30" 2>&1) || true
assert_contains "130 baselined hours; the 14 hours before the first publish have none" "no-baseline-hours=14" "$out"
assert_contains "hours over 30 (lags 31..129)" "hours-over-limit: 99 (limit 30" "$out"
assert_contains "over 40 is lags 41..129, over 100 is 101..129" "breaches: over-40=89 over-100=29" "$out"
assert_contains "p90 above 40 and max above 100 breach the target" "target: BREACHED" "$out"
out=$(python3 -I "$REPORT" --ledger "$L1" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD10" 2>&1) || true
assert_contains "p90 21 and max 23 hold the target" "target: HOLDS" "$out"

echo "TEST: reads_limit_from_update_script -- the limit is GRAPH_MAX_BEHIND in himmel-update.sh"
out=$(python3 -I "$REPORT" --ledger "$L1" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" --update-script "$UPD30" 2>&1) || true
assert_contains "a limit of 30 is read from the script" "(limit 30" "$out"
real_limit=$(sed -n 's/^GRAPH_MAX_BEHIND=\([0-9][0-9]*\)$/\1/p' "$REAL_UPDATE" | head -n 1)
out=$(python3 -I "$REPORT" --ledger "$L1" --repo "$R1" --days 1 --now "$(iso $((T0 + 23 * 3600)))" 2>&1) || true
assert_contains "without --update-script the real himmel-update.sh is read" "(limit $real_limit" "$out"
NOLIM="$TMP_ROOT/update-none.sh"; printf '#!/usr/bin/env bash\necho hi\n' > "$NOLIM"
rc=0
out=$(python3 -I "$REPORT" --ledger "$L1" --repo "$R1" --days 1 --update-script "$NOLIM" 2>&1) || rc=$?
assert_eq "a script with no GRAPH_MAX_BEHIND refuses rc=2" "2" "$rc"
assert_contains "the refusal names the variable" "GRAPH_MAX_BEHIND" "$out"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
