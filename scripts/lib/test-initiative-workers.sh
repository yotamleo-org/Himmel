#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || C` reporting pattern is intentional here
# test-initiative-workers.sh — unit test for scripts/lib/initiative-workers.sh
# Verifies the pure worker resolver: named-arg inputs → normalized,
# canonical-ordered, deduped active worker set, across interactive + overnight
# profiles, subsets, falsy values, case/space tolerance, and selector precedence.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$here/initiative-workers.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# interactive profile (selector empty → read arg1)
check "interactive all → legacy 4"      "prcheck pr ticket handover" "$(resolve_workers all '' '')"
check "interactive 1 → legacy 4"        "prcheck pr ticket handover" "$(resolve_workers 1 '' '')"
check "interactive falsy 0 → empty"     ""                            "$(resolve_workers 0 '' '')"
check "interactive empty → empty"       ""                            "$(resolve_workers '' '' '')"
check "interactive off → empty"         ""                            "$(resolve_workers off '' '')"
check "interactive subset+order"        "prcheck pr merge"            "$(resolve_workers 'merge,prcheck,pr' '' '')"
check "interactive unknown ignored"     "pr ticket"                   "$(resolve_workers 'pr,bogus,ticket' '' '')"
check "interactive case+space"          "prcheck handover"            "$(resolve_workers '  Handover , PRCHECK ' '' '')"
check "interactive dedup"               "pr"                          "$(resolve_workers 'pr,pr' '' '')"
check "interactive plan token kept"     "plan prcheck"                "$(resolve_workers 'plan,prcheck' '' '')"

# overnight profile (selector truthy → read arg2, ignore arg1)
check "overnight all → 6 workers"          "execute prcheck pr ticket merge handover" "$(resolve_workers '' all 1)"
check "overnight bare 1 → 6 workers"       "execute prcheck pr ticket merge handover" "$(resolve_workers '' 1 1)"
check "overnight subset"                "execute merge"               "$(resolve_workers '' 'merge,execute' 1)"
check "selector wins over initiative"   "execute"                     "$(resolve_workers all execute 1)"
check "overnight falsy → empty"         ""                            "$(resolve_workers '' 0 1)"

# resolve_workers_env over the live env: afk names, old overnight names, precedence.
env_workers() { env -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_AFK -u HIMMEL_AFK \
  -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_OVERNIGHT "$@" \
  bash -c ". '$here/initiative-workers.sh'; resolve_workers_env"; }
check "env afk names → afk steps"       "execute merge"               "$(env_workers HIMMEL_AFK=1 HIMMEL_INITIATIVE_AFK='merge,execute')"
check "env old names still work"        "execute"                     "$(env_workers HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE_OVERNIGHT=execute)"
check "env afk step list wins over old" "merge"                       "$(env_workers HIMMEL_AFK=1 HIMMEL_INITIATIVE_AFK=merge HIMMEL_INITIATIVE_OVERNIGHT=execute)"
check "env afk=0 blocks overnight=1"    "prcheck"                     "$(env_workers HIMMEL_AFK=0 HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE=prcheck HIMMEL_INITIATIVE_OVERNIGHT=execute)"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
