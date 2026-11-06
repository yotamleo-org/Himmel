#!/usr/bin/env bash
# test-empty-sector-check.sh: empty-sector-check.sh lists the open tickets with an empty Sector, exits 1 when
# there are any and 0 when there are none, and writes nothing. A stub CLI plays `jira list`.
#
# Run: bash scripts/jira/test-empty-sector-check.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/empty-sector-check.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/empty-sector-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# The stub records its arguments and prints $STUB_ROWS, or fails when $STUB_FAIL is set.
cat > "$WORK/stub.js" <<'JS'
const fs = require('fs');
fs.writeFileSync(process.env.STUB_ARGS, process.argv.slice(2).join('\n'));
if (process.env.STUB_FAIL) process.exit(1);
if (process.env.STUB_ROWS) console.log(process.env.STUB_ROWS);
JS
unset STUB_FAIL STUB_ROWS
export JIRA_CLI="$WORK/stub.js" STUB_ARGS="$WORK/args" JIRA_PROJECT_KEY=HIMMEL
rows=$'HIMMEL-1\tTask\tTo Do\tone\nHIMMEL-2\tBug\tIn Progress\ttwo'

out="$(STUB_ROWS="$rows" bash "$SUT" 2>&1)"; rc=$?
check "rows -> exit 1" 1 "$rc"
has "rows -> first ticket listed" "$out" "HIMMEL-1"
has "rows -> second ticket listed" "$out" "HIMMEL-2"
has "rows -> count line" "$out" "# empty-sector open=2"
args="$(cat "$WORK/args")"
has "query -> open tickets only" "$args" "statusCategory != Done"
has "query -> empty Sector" "$args" "Sector is EMPTY"
has "query -> this project" "$args" "project = HIMMEL"

out="$(bash "$SUT" 2>&1)"; rc=$?
check "none -> exit 0" 0 "$rc"
check "none -> only the count line" "# empty-sector open=0" "$out"

out="$(bash "$SUT" --limit 7 2>&1)"
has "--limit reaches the CLI" "$(cat "$WORK/args")" "7"

out="$(STUB_ROWS="$rows" bash "$SUT" --limit 2 2>&1)"; rc=$?
check "limit reached -> exit 1" 1 "$rc"
has "limit reached -> count marked as a lower bound" "$out" "# empty-sector open>=2"
out="$(bash "$SUT" --limit 0 2>&1)"; rc=$?
check "--limit 0 -> exit 2" 2 "$rc"

out="$(STUB_FAIL=1 bash "$SUT" 2>&1)"; rc=$?
check "CLI failure -> exit 2, not a clean pass" 2 "$rc"
out="$(JIRA_PROJECT_KEY='' bash "$SUT" 2>&1)"; rc=$?
check "no project -> exit 2" 2 "$rc"
out="$(bash "$SUT" --limit x 2>&1)"; rc=$?
check "bad --limit -> exit 2" 2 "$rc"
out="$(JIRA_CLI="$WORK/missing.js" bash "$SUT" 2>&1)"; rc=$?
check "missing CLI -> exit 2" 2 "$rc"

[ "$fails" -eq 0 ] || { printf '%d FAILED\n' "$fails"; exit 1; }
echo "all passed"
