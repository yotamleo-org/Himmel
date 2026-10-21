# shellcheck shell=bash
# DEPRECATED alias, kept so old callers keep sourcing: use review-default-base.sh.
# Sourced, it loads review-default-base.sh and prints nothing; the hooks and the frozen
# red-control fixtures still source this path.
case "${BASH_SOURCE[0]}" in */*) _cr_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _cr_alias_dir=. ;; esac
# shellcheck source=scripts/lib/review-default-base.sh
# shellcheck disable=SC1091
. "$_cr_alias_dir/review-default-base.sh"
