#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use coderabbit-signal.sh.
# Sourced, it loads coderabbit-signal.sh and prints nothing; the hooks and the frozen
# red-control fixtures still source this path.
case "${BASH_SOURCE[0]}" in */*) _cr_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _cr_alias_dir=. ;; esac
# shellcheck source=scripts/lib/coderabbit-signal.sh
# shellcheck disable=SC1091
. "$_cr_alias_dir/coderabbit-signal.sh"
