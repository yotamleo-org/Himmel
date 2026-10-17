#!/usr/bin/env bash
# scripts/lib/test-env-alias.sh -- rows for scripts/lib/env-alias.sh:
# alias_env (old only, new only, both, neither, empty old) and env_alias_any
# (the guard predicate) on each, run under set -euo pipefail with no output.
#
# ENV_ALIAS_SCRIPT points the rows at another copy of the helper, so a mutant
# (alias_env overwriting a set NEW) can be shown to turn a row red.
#
# Platform guard (gitbash-only): pure bash 3.2-safe, no .ps1 twin needed.
# shellcheck disable=SC2016  # snippets are meant to expand in the child, not here
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${ENV_ALIAS_SCRIPT:-$HERE/env-alias.sh}"

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

unset T_NEW T_OLD

# child <snippet>: runs the snippet in a strict child that sourced the helper;
# prints what the snippet echoes, plus anything the helper printed by itself.
child() {
  bash -c 'set -euo pipefail; . "$1"; eval "$2"' _ "$SCRIPT" "$1" 2>&1
}

check "sourced under strict mode prints nothing" "" "$(child ':')"

check "alias_env old only: NEW takes OLD" "legacy" \
  "$(T_OLD=legacy child 'alias_env T_NEW T_OLD; echo "${T_NEW-unset}"')"
check "alias_env old only: OLD kept" "legacy" \
  "$(T_OLD=legacy child 'alias_env T_NEW T_OLD; echo "${T_OLD-unset}"')"
check "alias_env new only: NEW kept" "fresh" \
  "$(T_NEW=fresh child 'alias_env T_NEW T_OLD; echo "${T_NEW-unset}"')"
check "alias_env new only: OLD stays unset" "unset" \
  "$(T_NEW=fresh child 'alias_env T_NEW T_OLD; echo "${T_OLD-unset}"')"
check "alias_env both: NEW wins" "fresh" \
  "$(T_NEW=fresh T_OLD=legacy child 'alias_env T_NEW T_OLD; echo "${T_NEW-unset}"')"
check "alias_env both: OLD untouched" "legacy" \
  "$(T_NEW=fresh T_OLD=legacy child 'alias_env T_NEW T_OLD; echo "${T_OLD-unset}"')"
check "alias_env neither: NEW stays unset" "unset" \
  "$(child 'alias_env T_NEW T_OLD; echo "${T_NEW-unset}"')"
check "alias_env neither: OLD stays unset" "unset" \
  "$(child 'alias_env T_NEW T_OLD; echo "${T_OLD-unset}"')"
check "alias_env empty old: NEW stays unset" "unset" \
  "$(T_OLD='' child 'alias_env T_NEW T_OLD; echo "${T_NEW-unset}"')"
check "alias_env returns 0 in every state (strict mode survives)" "ok" \
  "$(child 'alias_env T_NEW T_OLD; alias_env T_NEW T_OLD; echo ok')"
check "alias_env exports NEW to children" "legacy" \
  "$(T_OLD=legacy child 'alias_env T_NEW T_OLD; bash -c "echo \${T_NEW-unset}"')"

check "env_alias_any old only: true" "yes" \
  "$(T_OLD=1 child 'if env_alias_any T_NEW T_OLD; then echo yes; else echo no; fi')"
check "env_alias_any new only: true" "yes" \
  "$(T_NEW=1 child 'if env_alias_any T_NEW T_OLD; then echo yes; else echo no; fi')"
check "env_alias_any both: true" "yes" \
  "$(T_NEW=1 T_OLD=1 child 'if env_alias_any T_NEW T_OLD; then echo yes; else echo no; fi')"
check "env_alias_any neither: false" "no" \
  "$(child 'if env_alias_any T_NEW T_OLD; then echo yes; else echo no; fi')"
check "env_alias_any empty values: false" "no" \
  "$(T_NEW='' T_OLD='' child 'if env_alias_any T_NEW T_OLD; then echo yes; else echo no; fi')"
check "env_alias_any false does not abort a strict caller" "after" \
  "$(child 'env_alias_any T_NEW T_OLD || true; echo after')"

if [ "$FAIL" -ne 0 ]; then
  echo "test-env-alias: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-env-alias: $PASS passed"
