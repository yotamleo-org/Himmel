#!/usr/bin/env bash
# file-clipper-tickets.sh already ran and is not idempotent; it must
# refuse to create tickets unless the operator opts in explicitly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/luna/file-clipper-tickets.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/file-clipper-tickets.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
printf '#!/usr/bin/env bash\necho called >>"%s/node.log"\necho LUNA-1\n' "$TMP" >"$TMP/bin/node"
chmod +x "$TMP/bin/node"

PATH="$TMP/bin:$PATH" bash "$SCRIPT" >/dev/null 2>"$TMP/err"
assert_eq "F1 refuses without the rerun opt-in" "1" "$?"
assert_eq "F1b created no ticket" "0" "$(( $(wc -l <"$TMP/node.log" 2>/dev/null || echo 0) ))"

PATH="$TMP/bin:$PATH" FILE_CLIPPER_TICKETS_RERUN=1 bash "$SCRIPT" >/dev/null 2>&1
assert_eq "F2 opt-in runs" "0" "$?"
assert_eq "F2b opt-in created all 18 tickets" "18" "$(( $(wc -l <"$TMP/node.log" 2>/dev/null || echo 0) ))"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
