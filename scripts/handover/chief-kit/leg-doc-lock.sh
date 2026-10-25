#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-doc-lock.sh.
# Sourced, it loads worker-doc-lock.sh and prints nothing; with legacy names off it returns 127 with one stderr line.
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "leg-doc-lock.sh was renamed to worker-doc-lock.sh; legacy names are off" >&2
    return 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) _leg_doc_lock_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_doc_lock_alias_dir=. ;; esac
# shellcheck source=scripts/handover/chief-kit/worker-doc-lock.sh
# shellcheck disable=SC1091
. "$_leg_doc_lock_alias_dir/worker-doc-lock.sh"
