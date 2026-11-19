#!/usr/bin/env bash
# scripts/lib/test-status-marker.sh -- rows for scripts/lib/status-marker.sh:
# status_marker_parse over fixtures/status-marker-rows.tsv (shared with the JS
# and Python twins, which this suite also runs) and status_marker_is_parked.
#
# STATUS_MARKER_SCRIPT points the rows at another copy of the helper, so a
# mutant (PARKED-USAGE not accepted) can be shown to turn a row red.
#
# Platform guard: pure bash 3.2-safe.
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

# typed outcomes (rows E1 to E3): unreadable is its own outcome, never none
rcof() { bash -c 'set -euo pipefail; . "$1"; rc=0; out=$("$2" "$3") || rc=$?; printf "rc=%s out=[%s]" "$rc" "$out"' _ "$SCRIPT" "$1" "$2" 2>&1; }  # read-sink-ok: sources the script under test ($SCRIPT), not a host file
# fifo_rc FN: call FN on the FIFO $T/fifo in a child that is killed after 5 seconds
fifo_rc() {
  local out="$T/fifo.out" pid wd st
  : > "$out"
  bash -c 'set -euo pipefail; . "$1"; rc=0; "$2" "$3" >/dev/null || rc=$?; echo "rc=$rc"' _ "$SCRIPT" "$1" "$T/fifo" > "$out" 2>&1 &  # read-sink-ok: sources the script under test ($SCRIPT), not a host file
  pid=$!
  ( sleep 5; kill "$pid" 2>/dev/null ) > /dev/null 2>&1 < /dev/null &
  wd=$!
  wait "$pid" 2>/dev/null; st=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [ "$st" -gt 128 ]; then echo KILLED; else cat "$out"; fi
}
: > "$T/zero.md"; mkdir "$T/adir"; mkfifo "$T/fifo"; printf '## Results\n' > "$T/none.md"
for fn in status_marker_newest status_marker_actionable; do
  for p in "$T/absent" "$T/adir" /dev/null; do
    check "row E1 $fn unreadable: $p" "rc=3 out=[]" "$(rcof "$fn" "$p")"
  done
  check "row E1 $fn zero-byte file is none" "rc=1 out=[]" "$(rcof "$fn" "$T/zero.md")"
  check "row E3 $fn FIFO is unreadable and never blocks" "rc=3" "$(fifo_rc "$fn")"
done
check "row E2 a none doc under strict mode takes the else branch" "else:1" \
  "$(bash -c 'set -euo pipefail; . "$1"; if out=$(status_marker_newest "$2"); then echo "then:$out"; else echo "else:$?"; fi' _ "$SCRIPT" "$T/none.md" 2>&1)"  # read-sink-ok: sources the script under test ($SCRIPT), not a host file

# whole-doc rows (fixtures/status-marker-docs.tsv), rows B1 to B3 and E4
# answer FN FILE: the answer, "-" for none, "rc=<n>" for anything else
answer() {
  bash -c 'set -euo pipefail; . "$1"; rc=0; out=$("$2" "$3") || rc=$?; case "$rc" in 0) printf "%s" "$out" ;; 1) printf "%s" "-" ;; *) printf "rc=%s" "$rc" ;; esac' _ "$SCRIPT" "$1" "$2" 2>&1
}
# decode_doc ESCAPED FILE: write the doc's bytes; status 1 on an unknown escape
decode_doc() {
  local s="$1" out="" c
  while [ -n "$s" ]; do
    c="${s:0:1}"; s="${s:1}"
    if [ "$c" = "\\" ]; then
      c="${s:0:1}"; s="${s:1}"
      case "$c" in
        n) out="$out"$'\n' ;; r) out="$out"$'\r' ;; t) out="$out"$'\t' ;; f) out="$out"$'\f' ;;
        "\\") out="$out\\" ;; *) return 1 ;;
      esac
    else
      out="$out$c"
    fi
  done
  printf '%s' "$out" > "$2"
}
DOCS="$HERE/fixtures/status-marker-docs.tsv"
docs_want=$(sed -n 's/^# rows: \([0-9][0-9]*\)$/\1/p' "$DOCS")
mkdir "$T/d"; id=""; docs_n=0
while IFS=$'\t' read -r doc nw ac || [ -n "$doc" ]; do
  case "$doc" in '# '[A-Z][0-9][0-9]) id="${doc#\# }"; continue ;; ''|'#'|'# '*) continue ;; esac
  docs_n=$((docs_n + 1))
  if ! decode_doc "$doc" "$T/d/doc.md"; then check "row $id doc decodes" "yes" "no"; continue; fi
  sum=$(cksum < "$T/d/doc.md")
  check "row $id newest" "$nw" "$(answer status_marker_newest "$T/d/doc.md")"
  check "row $id actionable" "$ac" "$(answer status_marker_actionable "$T/d/doc.md")"
  check "row $id repeat call, bytes and directory unchanged" "$nw|$sum|doc.md" \
    "$(answer status_marker_newest "$T/d/doc.md")|$(cksum < "$T/d/doc.md")|$(ls -A "$T/d")"
done < "$DOCS"
check "docs fixture has at least one row" "yes" "$([ "$docs_n" -gt 0 ] && echo yes || echo no)"
check "every declared doc row was read" "$docs_want" "$docs_n"

for b in 'B1:LIVE:- 10:00 LIVE \0377' 'B2:-:- 10:00 \0377LIVE' 'B3:LIVE:- 10:00 LIVE\0205- 10:05 WRAPPED'; do
  IFS=: read -r bid bw bline <<< "$b"
  printf '## Results\n%b\n' "$bline" > "$T/d/$bid.md"
  check "row $bid newest" "$bw" "$(answer status_marker_newest "$T/d/$bid.md")"
  check "row $bid actionable" "-" "$(answer status_marker_actionable "$T/d/$bid.md")"
done

printf '## Results\n- 10:00 LIVE\n' > "$T/m000.md"; chmod 000 "$T/m000.md"
if [ "$(id -u)" = 0 ]; then e4=root; en=LIVE; ea=-; else e4=non-root; en="rc=3"; ea="rc=3"; fi
echo "row E4 branch: $e4 (the other branch is not exercised by this run)"
check "row E4 ($e4) newest" "$en" "$(answer status_marker_newest "$T/m000.md")"
check "row E4 ($e4) actionable" "$ea" "$(answer status_marker_actionable "$T/m000.md")"

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
