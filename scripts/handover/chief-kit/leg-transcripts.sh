#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use worker-transcripts.sh.
# Sourced, it loads worker-transcripts.sh and prints nothing.
case "${BASH_SOURCE[0]}" in */*) _leg_transcripts_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _leg_transcripts_alias_dir=. ;; esac
# shellcheck source=scripts/handover/chief-kit/worker-transcripts.sh
# shellcheck disable=SC1091
. "$_leg_transcripts_alias_dir/worker-transcripts.sh"
