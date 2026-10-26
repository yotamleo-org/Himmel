#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-transcripts.sh.
# Sourced, it loads worker-transcripts.sh and prints nothing; with legacy names off it returns 127 with one stderr line.
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
    echo "leg-transcripts.sh was renamed to worker-transcripts.sh; legacy names are off" >&2
    return 127 ;;
esac
case "${BASH_SOURCE[0]}" in */*) _leg_transcripts_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_transcripts_alias_dir=. ;; esac
# Old function names, for a caller that still sources this path.
resolve_leg_transcripts() { resolve_worker_transcripts "$@"; }
# shellcheck source=scripts/handover/chief-kit/worker-transcripts.sh
# shellcheck disable=SC1091
. "$_leg_transcripts_alias_dir/worker-transcripts.sh"
