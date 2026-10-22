#!/usr/bin/env bash
# DEPRECATED alias, kept so old callers keep sourcing: use chief-context.sh.
# Sourced, it loads chief-context.sh and prints nothing.
case "${BASH_SOURCE[0]}" in */*) _console_alias_dir="${BASH_SOURCE[0]%/*}" ;; *) _console_alias_dir=. ;; esac
# shellcheck source=scripts/lib/chief-context.sh
# shellcheck disable=SC1091
. "$_console_alias_dir/chief-context.sh"
