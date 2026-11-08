#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# DRIFT_SUMMARY overrides the script under test (the RED control: a missing script fails every row).
#
# Run: bash scripts/handover/chief-kit/test-drift-summary-wait.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUM="${DRIFT_SUMMARY:-$HERE/drift-summary.mjs}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drift-summary-wait-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export HIMMEL_CONFIG_DIR="$WORK/conf"; mkdir -p "$HIMMEL_CONFIG_DIR"
unset JIRA_PROJECT_KEY
MIR="$WORK/mirror"; mkdir -p "$MIR"
KNOWN="$WORK/known.tsv"; : > "$KNOWN"
export DRIFT_SUMMARY_KNOWN="$KNOWN"
DRIFT="$WORK/focus-drift.txt"
NOW=1792000000

sum() { node "$SUM" --json --drift "$DRIFT" --mirror-dir "$MIR" --now "$NOW" 2>&1; }
jqv() { printf '%s' "$1" | jq -r "$2" 2>&1; }

cat > "$DRIFT" <<'EOF'
AWAITING HIMMEL-1 chief since=2026-11-08T11:00:00Z due=2026-11-09T11:00:00Z what=the chief decides source=d6n | writer=worker-jira-status.sh | fix=close it by hand | wait=chief
UNOWNED HIMMEL-2 In Progress with no open PR and no live owner | writer=worker-jira-status.sh | fix=dispatch a RESUME worker
sdrift=1:abcd1234
EOF
touch -d "@$((NOW - 600))" "$DRIFT"
out=$(sum)
eq "1: a wait row is counted as waiting" "$(jqv "$out" '.counts.waiting')" 1
eq "1: and the UNOWNED row is the one real row" "$(jqv "$out" '.counts.real')" 1
eq "1: the waiting row is the AWAITING one" "$(jqv "$out" '.waiting[0].key')" HIMMEL-1
eq "1: the real row is the UNOWNED one" "$(jqv "$out" '.real[0].key')" HIMMEL-2

cat > "$DRIFT" <<'EOF'
UNOWNED HIMMEL-3 In Progress with no open PR and no live owner | writer=a | fix=b | wait=chief
AWAITING HIMMEL-4 chief since=2026-11-08T11:00:00Z due=2026-11-09T11:00:00Z what=x source=d6n | writer=a | fix=b
AWAITING HIMMEL-5 chief since=2026-11-08T11:00:00Z due=2026-11-09T11:00:00Z what=x source=d6n | writer=a | fix=b | wait=Bad Who
sdrift=3:abcd1234
EOF
touch -d "@$((NOW - 600))" "$DRIFT"
out=$(sum)
eq "2: an UNOWNED row carrying the mark, an AWAITING row without it and one with a bad who are all real" "$(jqv "$out" '.counts.real')" 3
eq "2: and none is waiting" "$(jqv "$out" '.counts.waiting')" 0

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
