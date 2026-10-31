#!/usr/bin/env bash
# Platform guard: POSIX bash 3.2+ (macOS, Linux).
# Sourced by shell-test fixtures: canonicalise a fixture path so a
# path the test BUILT compares equal to the same path a tool REPORTED.
#
# The mismatch this closes is one directory spelled several ways:
#   macOS       mktemp -> /var/folders/../T/x   (TMPDIR ends in "/", so also "T//x")
#               git / node / `pwd -P` -> /private/var/folders/../T/x
#
#   canon_path <dir>          physical POSIX form (`cd && pwd -P`)
#   canon_path_native <dir>   canon_path; the name callers use when the partner
#                             is git or node
#   canon_path_partial <path> canon_path_native of the deepest EXISTING ancestor,
#                             the not-yet-created tail appended verbatim
# All three print one path and return 1 (printing nothing) when <dir> does not
# exist. Callers own the `|| exit`: this file must stay safe to source under
# `set -u` / `set -e`, so it sets no shell options and defines no globals.

canon_path() {
    [ -n "${1-}" ] || return 1
    ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

canon_path_native() {
    canon_path "${1-}"
}

canon_path_partial() {
    local p="${1-}" rest="" head
    [ -n "$p" ] || return 1
    while [ ! -d "$p" ]; do
        case "$p" in */*) ;; *) return 1 ;; esac
        rest="/${p##*/}$rest"
        p="${p%/*}"
        [ -n "$p" ] || p=/
    done
    head=$(canon_path_native "$p") || return 1
    printf '%s%s\n' "${head%/}" "$rest"
}
