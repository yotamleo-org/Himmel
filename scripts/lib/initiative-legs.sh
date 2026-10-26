#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use initiative-workers.sh.
# Sourced, it loads initiative-workers.sh and prints nothing; with legacy names off it returns 127 with one stderr line.
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "initiative-legs.sh was renamed to initiative-workers.sh; legacy names are off" >&2
    return 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) _initiative_legs_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _initiative_legs_alias_dir=. ;; esac
# shellcheck source=scripts/lib/initiative-workers.sh
# shellcheck disable=SC1091
. "$_initiative_legs_alias_dir/initiative-workers.sh"
# Old function names, for a caller that still sources this path.
resolve_legs() { resolve_workers "$@"; }
resolve_legs_env() { resolve_workers_env "$@"; }
