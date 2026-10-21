#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use coderabbit-available.sh.
# Sourced, it loads coderabbit-available.sh and prints nothing; the hooks and the frozen
# red-control fixtures still source this path.
case "${BASH_SOURCE[0]}" in */*) _cr_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _cr_alias_dir=. ;; esac
# shellcheck source=scripts/lib/coderabbit-available.sh
# shellcheck disable=SC1091
. "$_cr_alias_dir/coderabbit-available.sh"
