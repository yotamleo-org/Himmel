#!/usr/bin/env bash
# scripts/lib/test-legacy-names.sh -- rows for the HIMMEL_LEGACY_NAMES switch:
# scripts/lib/legacy-names.sh (legacy_names_on) and its inline twins in
# env-alias.mjs and env_alias.py answer the same knob values; env-alias.sh
# loads the predicate; env_alias_restrict ignores OFF (a guard marker set under
# its old name stays on); every old-path forwarder that obeys the switch
# carries the same falsy pattern as legacy-names.sh.
#
# Platform guard (gitbash-only): pure bash 3.2-safe, no .ps1 twin needed.
# shellcheck disable=SC2016  # snippets are meant to expand in the child, not here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/legacy-names.sh"

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

check "legacy-names.sh exists" "yes" "$([ -f "$LIB" ] && echo yes || echo no)"

# sh_on <value|-> : on/off from the shell predicate (- = unset)
sh_on() {
  local args=()
  [ "$1" = "-" ] || args=("HIMMEL_LEGACY_NAMES=$1")
  env -i PATH="$PATH" ${args[@]+"${args[@]}"} bash -c \
    'set -euo pipefail; . "$1"; if legacy_names_on; then echo on; else echo off; fi' _ "$LIB" 2>&1
}
js_on() {
  local args=()
  [ "$1" = "-" ] || args=("HIMMEL_LEGACY_NAMES=$1")
  env -i PATH="$PATH" ${args[@]+"${args[@]}"} node --input-type=module -e \
    'const m = await import(process.argv[2]); console.log(m.legacyNamesOn() ? "on" : "off");' \
    _ "$HERE/env-alias.mjs" 2>&1
}
py_on() {
  local args=()
  [ "$1" = "-" ] || args=("HIMMEL_LEGACY_NAMES=$1")
  env -i PATH="$PATH" ${args[@]+"${args[@]}"} python3 -I -c \
    'import sys; sys.path.insert(0, sys.argv[1]); import env_alias; print("on" if env_alias.legacy_names_on() else "off")' \
    "$HERE" 2>&1
}

# knob value -> want; unset and empty are ON, the env-alias falsy set is OFF
while read -r val want; do
  check "shell knob '$val'" "$want" "$(sh_on "$val")"
  check "js knob '$val'" "$want" "$(js_on "$val")"
  check "python knob '$val'" "$want" "$(py_on "$val")"
done <<'ROWS'
- on
1 on
yes on
true on
on on
anything on
00 on
0 off
false off
FALSE off
No off
no off
off off
OFF off
ROWS
check "shell knob ''" "on" "$(sh_on '')"
check "js knob ''" "on" "$(js_on '')"
check "python knob ''" "on" "$(py_on '')"

check "legacy-names.sh sourced under strict mode prints nothing" "" \
  "$(bash -c 'set -euo pipefail; . "$1"' _ "$LIB" 2>&1)"
check "env-alias.sh loads legacy_names_on" "off" \
  "$(env -i PATH="$PATH" HIMMEL_LEGACY_NAMES=0 bash -c 'set -euo pipefail; . "$1"; if legacy_names_on; then echo on; else echo off; fi' _ "$HERE/env-alias.sh" 2>&1)"

# restrict ignores OFF in all three runtimes: an old-name guard marker stays on
check "shell restrict ignores OFF" "0" \
  "$(env -i PATH="$PATH" HIMMEL_LEGACY_NAMES=0 T_OLD=1 bash -c 'set -euo pipefail; . "$1"; rc=0; env_alias_restrict T_NEW T_OLD || rc=$?; echo $rc' _ "$HERE/env-alias.sh" 2>&1)"
check "js restrict ignores OFF" "0" \
  "$(env -i PATH="$PATH" HIMMEL_LEGACY_NAMES=0 T_OLD=1 node "$HERE/env-alias.mjs" restrict T_NEW T_OLD >/dev/null 2>&1; echo $?)"
check "python restrict ignores OFF" "0" \
  "$(env -i PATH="$PATH" HIMMEL_LEGACY_NAMES=0 T_OLD=1 python3 -I "$HERE/env_alias.py" restrict T_NEW T_OLD >/dev/null 2>&1; echo $?)"

# every forwarder that obeys the switch spells the predicate as legacy-names.sh does
PAT=$(grep -o '^ *0|\[Ff\]\[Aa\]\[Ll\]\[Ss\]\[Ee\]|\[Nn\]\[Oo\]|\[Oo\]\[Ff\]\[Ff\])' "$LIB" | tr -d ' ' || true)
check "legacy-names.sh carries the falsy pattern" "yes" "$([ -n "$PAT" ] && echo yes || echo no)"
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */test-*) continue ;; esac
  n=$((n + 1))
  check "$f spells the legacy-names pattern" "yes" \
    "$(grep -qF "$PAT" "$ROOT/$f" && grep -qF 'HIMMEL_LEGACY_NAMES' "$ROOT/$f" && echo yes || echo no)"
done < <(git -C "$ROOT" grep -l 'legacy names are off' -- 'scripts/' 'marketplace/' 2>/dev/null || true)
check "the forwarder template obeys the switch" "yes" \
  "$(grep -q 'legacy names are off' "$HERE/deprecated-forwarder.sh" && echo yes || echo no)"
check "at least one forwarder was checked" "yes" "$([ "$n" -gt 0 ] && echo yes || echo no)"

if [ "$FAIL" -ne 0 ]; then
  echo "test-legacy-names: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-legacy-names: $PASS passed"
