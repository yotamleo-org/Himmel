#!/usr/bin/env bash
# scripts/lib/test-env-alias.sh -- rows for scripts/lib/env-alias.sh:
# alias_env (old only, new only, both, neither, empty old), env_alias_any
# (the guard predicate) and the direction-aware env_alias_restrict /
# env_alias_permit, run under set -euo pipefail with no output. The restrict
# and permit rows are fixtures/env-alias-rows.tsv, shared with the JS and
# Python twins, which this suite also runs.
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

# --- invalid names fail closed on every function (rc 2) ---
for fn in alias_env env_alias_any; do
  check "$fn invalid NEW name: rc 2" "2" \
    "$(child "rc=0; $fn 'bad-name' T_OLD || rc=\$?; echo \$rc")"
  check "$fn invalid OLD name: rc 2" "2" \
    "$(child "rc=0; $fn T_NEW 'lower' || rc=\$?; echo \$rc")"
done

# --- restrict / permit: the shared rows ---
ROWS="$HERE/fixtures/env-alias-rows.tsv"
valid_name() {
  case "$1" in
    ''|[!ABCDEFGHIJKLMNOPQRSTUVWXYZ_]*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0-9_]*) return 1 ;;
  esac
  return 0
}
n=0
while IFS=$'\t' read -r fn nn on nv ov want; do
  case "$fn" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  [ "$nn" = "<empty>" ] && nn=""
  [ "$on" = "<empty>" ] && on=""
  args=()
  if valid_name "$nn" && [ "$nv" != "-" ]; then
    [ "$nv" = "<empty>" ] && nv=""
    args+=("$nn=$nv")
  fi
  if valid_name "$on" && [ "$ov" != "-" ]; then
    [ "$ov" = "<empty>" ] && ov=""
    args+=("$on=$ov")
  fi
  got=$(env ${args[@]+"${args[@]}"} bash -c \
    'set -euo pipefail; . "$1"; rc=0; "env_alias_$2" "$3" "$4" || rc=$?; echo "$rc"' \
    _ "$SCRIPT" "$fn" "$nn" "$on" 2>&1)
  check "row $n: $fn '$nn'=$nv '$on'=$ov" "$want" "$got"
done < "$ROWS"
check "rows file was read (not vacuous)" "yes" "$([ "$n" -ge 40 ] && echo yes || echo no)"

# --- the JS and Python twins run the same rows ---
if command -v node >/dev/null 2>&1; then
  node --test "$HERE/env-alias.test.mjs" >/dev/null 2>&1 || { echo "FAIL: env-alias.test.mjs" >&2; FAIL=$((FAIL + 1)); }
else
  echo "FAIL: node missing, env-alias.test.mjs not run" >&2; FAIL=$((FAIL + 1))
fi
if command -v python3 >/dev/null 2>&1; then
  python3 -I "$HERE/test-env_alias.py" >/dev/null 2>&1 || { echo "FAIL: test-env_alias.py" >&2; FAIL=$((FAIL + 1)); }
else
  echo "FAIL: python3 missing, test-env_alias.py not run" >&2; FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -ne 0 ]; then
  echo "test-env-alias: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "test-env-alias: $PASS passed"
