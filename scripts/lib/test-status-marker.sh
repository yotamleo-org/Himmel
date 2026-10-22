#!/usr/bin/env bash
# scripts/lib/test-status-marker.sh -- rows for scripts/lib/status-marker.sh:
# status_marker_parse over fixtures/status-marker-rows.tsv (shared with the JS
# and Python twins, which this suite also runs) and status_marker_is_parked.
#
# STATUS_MARKER_SCRIPT points the rows at another copy of the helper, so a
# mutant (PARKED-USAGE not accepted) can be shown to turn a row red.
#
# Platform guard (gitbash-only): pure bash 3.2-safe, no .ps1 twin needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${STATUS_MARKER_SCRIPT:-$HERE/status-marker.sh}"

FAIL=0
PASS=0
check() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label -- want '$want' got '$got'" >&2
    FAIL=$((FAIL + 1))
  fi
}

# child <snippet>: a strict child that sourced the helper.
child() {
  # read-sink-ok: sources the script under test ($SCRIPT), not a host file
  bash -c 'set -euo pipefail; . "$1"; eval "$2"' _ "$SCRIPT" "$1" 2>&1
}

check "sourced under strict mode prints nothing" "" "$(child ':')"

ROWS="$HERE/fixtures/status-marker-rows.tsv"
want_rows=$(sed -n 's/^# rows: \([0-9][0-9]*\)$/\1/p' "$ROWS")
check "fixture declares its row count" "yes" "$([ -n "$want_rows" ] && echo yes || echo no)"
# the loop reads a copy whose last row has no trailing newline
T=$(mktemp -d "${TMPDIR:-/tmp}/himmel-status-marker.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
NOEOL="$T/status-marker-rows-noeol.tsv"
printf '%s' "$(cat "$ROWS")" > "$NOEOL"
check "noeol copy really lacks the final newline" "no" \
  "$([ "$(tail -c1 "$NOEOL" | od -An -tx1 | tr -d ' ')" = 0a ] && echo yes || echo no)"

n=0
while IFS=$'\t' read -r line want || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  got=$(bash -c 'set -euo pipefail; . "$1"; if out=$(status_marker_parse "$2"); then printf "%s" "$out"; else printf "%s" "-"; fi' _ "$SCRIPT" "$line" 2>&1)
  check "row $n: $line" "$want" "$got"
  # read-sink-ok: sources the script under test ($SCRIPT), not a host file
  rc=$(bash -c 'set -euo pipefail; . "$1"; rc=0; status_marker_parse "$2" >/dev/null || rc=$?; echo "$rc"' _ "$SCRIPT" "$line" 2>&1)
  if [ "$want" = "-" ]; then check "row $n rc: no marker is 1" "1" "$rc"; else check "row $n rc: marker is 0" "0" "$rc"; fi
done < "$NOEOL"
check "fixture has at least one row" "yes" "$([ "$n" -gt 0 ] && echo yes || echo no)"
check "every declared row was read" "$want_rows" "$n"

# read-sink-ok: sources the script under test ($SCRIPT), not a host file; no allowlist applies
for line in $'- 23:47 LIVE \xe2\x80\x94 note\r' $'- LIVE \xe2\x80\x94 a\nb' $'- LIVE\r'; do
  check "CR or embedded newline after the word: $(printf %q "$line")" "LIVE" \
    "$(bash -c 'set -euo pipefail; . "$1"; status_marker_parse "$2"' _ "$SCRIPT" "$line" 2>&1)"
done

for m in PARKED-BANK PARKED-USAGE; do
  check "is_parked $m" "yes" "$(child "if status_marker_is_parked $m; then echo yes; else echo no; fi")"
done
for m in LIVE WRAPPED PARKED PARKED-BANKX parked-bank ''; do
  check "is_parked '$m' is false" "no" "$(child "if status_marker_is_parked '$m'; then echo yes; else echo no; fi")"
done
check "is_parked with no argument is false and survives set -u" "no" \
  "$(child 'if status_marker_is_parked; then echo yes; else echo no; fi')"

if command -v node >/dev/null 2>&1; then
  out=$(node --test "$HERE/status-marker.test.mjs" 2>&1) || { echo "FAIL: status-marker.test.mjs" >&2; printf '%s\n' "$out" | tail -40 >&2; FAIL=$((FAIL + 1)); }
else
  echo "FAIL: node missing, status-marker.test.mjs not run" >&2; FAIL=$((FAIL + 1))
fi
if command -v python3 >/dev/null 2>&1; then
  out=$(python3 -I "$HERE/test-status_marker.py" 2>&1) || { echo "FAIL: test-status_marker.py" >&2; printf '%s\n' "$out" | tail -40 >&2; FAIL=$((FAIL + 1)); }
else
  echo "FAIL: python3 missing, test-status_marker.py not run" >&2; FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -ne 0 ]; then
  echo "test-status-marker: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-status-marker: $PASS passed"
