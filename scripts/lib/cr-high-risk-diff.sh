#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use review-high-risk-diff.sh.
# Sourced, it loads review-high-risk-diff.sh and prints nothing; the hooks and the frozen
# red-control fixtures still source this path.
case "${BASH_SOURCE[0]}" in */*) _cr_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _cr_alias_dir=. ;; esac
# shellcheck source=scripts/lib/review-high-risk-diff.sh
# shellcheck disable=SC1091
. "$_cr_alias_dir/review-high-risk-diff.sh"
