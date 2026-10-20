#!/usr/bin/env bash
# scripts/lib/env-alias.sh -- read-both env var helper for the identifier
# rename.
# Source it; it prints nothing and is safe under `set -euo pipefail`.
#
#   alias_env NEW OLD     export NEW from OLD when NEW is empty/unset and OLD
#                         is non-empty; otherwise leave both alone. For VALUE
#                         keys (paths, models, timeouts) only: a set NEW wins,
#                         so it must never gate a guard.
#   env_alias_any NEW OLD true when either name is non-empty.
#   env_alias_restrict NEW OLD
#                         true when either name is truthy. For markers that
#                         switch a guard ON: NEW=0 OLD=1 stays restricted.
#   env_alias_permit NEW OLD
#                         true only when at least one name is truthy and no set
#                         name is falsy. For *_OK overrides and widening
#                         switches: NEW=0 OLD=1 stays denied.
#
# "Set" means non-empty. "Truthy" means set and not 0, false, no or off (any
# case). Every function validates both names as [A-Z_][A-Z0-9_]* and returns 2
# when one is invalid, so a caller that must fail closed reads the status
# (`rc=0; env_alias_restrict A B || rc=$?`). A restrict caller treats anything but
# 1 as "on"; a permit caller treats anything but 0 as "denied".
# restrict and permit return 0 (true) or 1 (false); the JS and Python twins
# (env-alias.mjs, env_alias.py) answer the same rows, fixtures/env-alias-rows.tsv.
# Sibling rename helpers: status-marker.sh (+ status-marker.mjs, status_marker.py)
# parses PARKED-BANK / PARKED-USAGE; deprecated-forwarder.sh is the template for an
# old script path that forwards to its renamed script.
# Bash 3.2-safe (indirect expansion, no namerefs).

# _env_alias_valid NAME: [A-Z_][A-Z0-9_]*, spelled out so no locale widens A-Z.
_env_alias_valid() {
  case "$1" in
    ''|[!ABCDEFGHIJKLMNOPQRSTUVWXYZ_]*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0-9_]*) return 1 ;;
  esac
  return 0
}

_env_alias_falsy() {
  case "$1" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
  esac
  return 1
}

alias_env() {
  local new="${1-}" old="${2-}"
  _env_alias_valid "$new" && _env_alias_valid "$old" || return 2
  if [ -z "${!new:-}" ] && [ -n "${!old:-}" ]; then
    export "$new=${!old}"
  fi
  return 0
}

env_alias_any() {
  local new="${1-}" old="${2-}"
  _env_alias_valid "$new" && _env_alias_valid "$old" || return 2
  [ -n "${!new:-}" ] || [ -n "${!old:-}" ]
}

env_alias_restrict() {
  local new="${1-}" old="${2-}" v
  _env_alias_valid "$new" && _env_alias_valid "$old" || return 2
  for v in "${!new:-}" "${!old:-}"; do
    if [ -n "$v" ] && ! _env_alias_falsy "$v"; then
      return 0
    fi
  done
  return 1
}

env_alias_permit() {
  local new="${1-}" old="${2-}" v any=1
  _env_alias_valid "$new" && _env_alias_valid "$old" || return 2
  for v in "${!new:-}" "${!old:-}"; do
    [ -n "$v" ] || continue
    if _env_alias_falsy "$v"; then
      return 1
    fi
    any=0
  done
  return "$any"
}
