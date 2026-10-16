#!/usr/bin/env bash
# scripts/lib/env-alias.sh -- read-both env var helper for the identifier
# rename (docs/internals/identifier-rename-inventory.md).
# Source it; it prints nothing and is safe under `set -euo pipefail`.
#
#   alias_env NEW OLD     export NEW from OLD when NEW is empty/unset and OLD
#                         is non-empty; otherwise leave both alone.
#   env_alias_any NEW OLD true when either name is non-empty. Guards that key
#                         on an identity marker use this so they deny when
#                         EITHER spelling is set.
#
# "Set" means non-empty, matching the `[ -n "${VAR:-}" ]` marker idiom.
# Bash 3.2-safe (indirect expansion, no namerefs).

alias_env() {
  local new="$1" old="$2"
  if [ -z "${!new:-}" ] && [ -n "${!old:-}" ]; then
    export "$new=${!old}"
  fi
  return 0
}

env_alias_any() {
  local new="$1" old="$2"
  [ -n "${!new:-}" ] || [ -n "${!old:-}" ]
}
