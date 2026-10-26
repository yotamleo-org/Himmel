#!/usr/bin/env bash
# scripts/lib/legacy-names.sh -- the ONE switch for the pre-rename names
# (console, leg, ...): legacy_names_on is true unless HIMMEL_LEGACY_NAMES is
# 0, false, no or off (any case). Unset or empty means on.
# Source it; it prints nothing and is safe under `set -euo pipefail`.
#
# Off only narrows what is read, never adds a path or a permission:
#   env-alias.sh  alias_env and env_alias_any drop the old name; permit takes
#                 its grant from the new name only (a falsy old name still
#                 vetoes); restrict and alias_env_cap ignore the switch.
#   forwarders    an old script path exits 127 with one stderr line. Each
#                 forwarder spells the falsy pattern below inline (it must run
#                 without this tree); test-legacy-names.sh pins every copy.
# Twins: legacyNamesOn in env-alias.mjs, legacy_names_on in env_alias.py.
# Bash 3.2-safe.

legacy_names_on() {
  case "${HIMMEL_LEGACY_NAMES:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 1 ;;
  esac
  return 0
}

# legacy_flag OLD NEW: a parser's arm for a renamed CLI flag calls this when it
# matched OLD. On: one stderr deprecation line per process, then status 0 (parse
# OLD as NEW). Off: one stderr line and status 1, so the caller treats OLD as
# the unknown option it now is.
legacy_flag() {
  if ! legacy_names_on; then
    echo "$1 was renamed to $2; legacy names are off" >&2
    return 1
  fi
  case " ${_LEGACY_FLAG_WARNED:-} " in *" $1 "*) ;; *)
    echo "$1 is deprecated: use $2" >&2
    _LEGACY_FLAG_WARNED="${_LEGACY_FLAG_WARNED:-} $1" ;;
  esac
  return 0
}
