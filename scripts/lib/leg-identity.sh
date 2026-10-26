#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-identity.sh.
# Sourced, it loads worker-identity.sh and prints nothing; with legacy names off it returns 127 with one stderr line.
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "leg-identity.sh was renamed to worker-identity.sh; legacy names are off" >&2
    return 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) _leg_identity_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_identity_alias_dir=. ;; esac
# Old function names, for a caller that still sources this path.
leg_identity() { worker_identity "$@"; }
leg_label() { worker_label "$@"; }
leg_base() { worker_base "$@"; }
leg_description_field() { worker_description_field "$@"; }
leg_description() { worker_description "$@"; }
leg_doc_has_run() { worker_doc_has_run "$@"; }
# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
. "$_leg_identity_alias_dir/worker-identity.sh"
