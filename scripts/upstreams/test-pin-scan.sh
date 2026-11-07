#!/usr/bin/env bash
# scripts/upstreams/test-pin-scan.sh — hermetic suite for pin-scan.py's reading
# of the optional `eligible` field of scripts/upstreams/pin-holds.json.
#
# A hold reads HELD only while its `eligible` time (UTC, YYYY-MM-DDTHH:MMZ) is
# in the future; from that time the row reads BEHIND again. A malformed time or
# an unreadable file reads BEHIND, never HELD; a row without `eligible` keeps
# the old behaviour. curl and gh are replaced by stubs on PATH (every package's
# latest is 2.0.0, every repo's latest tag is v2.0.0); DRIFT_NOW stands in for
# the clock, as in scripts/check-plugin-drift.sh.
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCAN="$SCRIPT_DIR/pin-scan.py"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

W=$(mktemp -d "${TMPDIR:-/tmp}/test-pin-scan.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/root"

printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"version\":\"2.0.0\"}'" > "$W/bin/curl"
printf '#!/usr/bin/env bash\necho v2.0.0\n' > "$W/bin/gh"
chmod +x "$W/bin/curl" "$W/bin/gh"

# Four npm pins and four gh pins, all one major behind the stubbed latest.
cat > "$W/root/package.json" <<'JSON'
{"name":"fx","dependencies":{"pkg-future":"^1.0.0","pkg-past":"^1.0.0","pkg-bad":"^1.0.0","pkg-none":"^1.0.0"}}
JSON
cat > "$W/root/package-lock.json" <<'JSON'
{"lockfileVersion":3,"packages":{"":{},
 "node_modules/pkg-future":{"version":"1.0.0"},"node_modules/pkg-past":{"version":"1.0.0"},
 "node_modules/pkg-bad":{"version":"1.0.0"},"node_modules/pkg-none":{"version":"1.0.0"}}}
JSON
: > "$W/root/.pre-commit-config.yaml"
for n in future past bad none; do
  printf -- '- repo: https://github.com/owner/gh-%s\n  rev: v1.0.0\n  hooks:\n    - id: x\n' "$n" >> "$W/root/.pre-commit-config.yaml"
done

# hold_row <eco> <key> <latest_reviewed> [<eligible-json-value>]
hold_row() {
  local extra=""
  [ $# -ge 4 ] && extra=", \"eligible\": $4"
  printf '{"eco":"%s","key":"%s","current":"%s","latest_reviewed":"%s"%s}' "$1" "$2" "$CUR" "$3" "$extra"
}
write_holds() {  # write_holds <file> <future> <past> <bad>
  local f="$1" fut="$2" past="$3" bad="$4" CUR=
  {
    printf '{"holds":['
    CUR=1.0.0; hold_row npm pkg-future 2.0.0 "$fut"; printf ','
    CUR=1.0.0; hold_row npm pkg-past 2.0.0 "$past"; printf ','
    CUR=1.0.0; hold_row npm pkg-bad 2.0.0 "$bad"; printf ','
    CUR=1.0.0; hold_row npm pkg-none 2.0.0; printf ','
    CUR=v1.0.0; hold_row gh owner/gh-future v2.0.0 "$fut"; printf ','
    CUR=v1.0.0; hold_row gh owner/gh-past v2.0.0 "$past"; printf ','
    CUR=v1.0.0; hold_row gh owner/gh-bad v2.0.0 "$bad"; printf ','
    CUR=v1.0.0; hold_row gh owner/gh-none v2.0.0
    printf ']}\n'
  } > "$f"
}

# scan <holds-file> [<DRIFT_NOW>] -> output in $out, rc in $rc
scan() {
  if [ $# -ge 2 ]; then
    out=$(PATH="$W/bin:$PATH" DRIFT_NOW="$2" python3 "$SCAN" "$W/root" "$1" 2>&1); rc=$?
  else
    out=$(PATH="$W/bin:$PATH" python3 "$SCAN" "$W/root" "$1" 2>&1); rc=$?
  fi
}

# expect <label-key> <verdict>
expect() {
  if printf '%s\n' "$out" | grep -q -- "$1 .*: $2 "; then pass "$1 reads $2"
  else fail "$1 should read $2; got: $(printf '%s\n' "$out" | grep -- "$1 " || echo '(no line)') [rc=$rc]"; fi
}

NOW="2026-11-07T12:00Z"
FUT="2026-11-08T00:00Z"
PAST="2026-11-06T00:00Z"

echo "== eligible vs a fixed clock ($NOW) =="
write_holds "$W/holds.json" "\"$FUT\"" "\"$PAST\"" '"soon"'
scan "$W/holds.json" "$NOW"
for eco_key in npm:pkg-future gh:owner/gh-future; do expect "$eco_key" HELD; done
for eco_key in npm:pkg-past gh:owner/gh-past npm:pkg-bad gh:owner/gh-bad; do expect "$eco_key" BEHIND; done
for eco_key in npm:pkg-none gh:owner/gh-none; do expect "$eco_key" HELD; done
if [ "$rc" -eq 1 ]; then pass "exit bit 1 set (BEHIND rows present)"; else fail "expected rc 1, got $rc"; fi

echo "== a non-string eligible reads BEHIND =="
write_holds "$W/holds-num.json" '12345' '12345' '12345'
scan "$W/holds-num.json" "$NOW"
expect npm:pkg-future BEHIND
expect gh:owner/gh-future BEHIND

echo "== an unreadable holds file reads BEHIND, never HELD =="
printf 'this is not json\n' > "$W/holds-bad.json"
scan "$W/holds-bad.json" "$NOW"
expect npm:pkg-none BEHIND
expect gh:owner/gh-none BEHIND
if [ "$rc" -eq 1 ] && ! printf '%s\n' "$out" | grep -q Traceback; then pass "unreadable file: scan completes without a traceback, rc 1"; else fail "unreadable file: expected a clean rc 1, got rc $rc"; fi

echo "== the real clock is used when DRIFT_NOW is unset =="
write_holds "$W/holds-real.json" '"2999-01-01T00:00Z"' '"2000-01-01T00:00Z"' '"soon"'
scan "$W/holds-real.json"
expect npm:pkg-future HELD
expect gh:owner/gh-future HELD
expect npm:pkg-past BEHIND
expect gh:owner/gh-past BEHIND

echo
if [ "$fails" -eq 0 ]; then
  echo "SUMMARY: all tests passed"
  exit 0
else
  echo "SUMMARY: $fails test(s) FAILED"
  exit 1
fi
