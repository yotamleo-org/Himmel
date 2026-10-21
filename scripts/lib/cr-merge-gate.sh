#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use review-merge-gate.sh.
# Sourced, it loads review-merge-gate.sh and prints nothing; the hooks and the frozen
# red-control fixtures still source this path.
case "${BASH_SOURCE[0]}" in */*) _cr_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _cr_alias_dir=. ;; esac
# shellcheck source=scripts/lib/review-merge-gate.sh
# shellcheck disable=SC1091
. "$_cr_alias_dir/review-merge-gate.sh"
