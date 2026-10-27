#!/usr/bin/env bash
# resolve-path.sh — sourced lib: a portable `readlink -m` for the hook guards.
#
#   hook_resolve_m <path>...   one resolved line per path (rc 0), or rc 1 with no
#                              output when any path cannot be resolved
#
# GNU `readlink -m` resolves every symlink and `..` and tolerates a missing tail.
# BSD/macOS readlink has no -m: a guard that called it
# bare read an empty answer as "resolves nowhere" and let a symlink or `..` alias
# of a guarded path through. Where `readlink -m` works it is used as is, so the
# GNU answer is unchanged; elsewhere a walk over plain `readlink` (no flags) gives
# the same answer. A caller treats rc 1 as a deny: it never skips the check.
# ponytail: a path with a newline in it reads as two lines, same as readlink -m;
# the walk gives up after 40 symlink hops (rc 1), upgrade path is realpath(1) where present.
# Bash 3.2-compatible.

_hrp_walk() {
    local rest="$1" cur="/" comp cand tgt hops=0
    case "$rest" in
        /*) ;;
        *) rest="$PWD/$rest" ;;
    esac
    while :; do
        rest="${rest#"${rest%%[!/]*}"}"
        [ -n "$rest" ] || break
        comp="${rest%%/*}"
        case "$rest" in
            */*) rest="${rest#*/}" ;;
            *) rest="" ;;
        esac
        case "$comp" in
            .) continue ;;
            ..)
                cur="${cur%/*}"
                [ -n "$cur" ] || cur="/"
                continue
                ;;
        esac
        if [ "$cur" = "/" ]; then cand="/$comp"; else cand="$cur/$comp"; fi
        if [ -L "$cand" ]; then
            hops=$((hops + 1))
            [ "$hops" -le 40 ] || return 1
            tgt="$(readlink -- "$cand" 2>/dev/null)" || return 1 # swallow-ok: a failed readlink returns rc 1 and the caller denies
            [ -n "$tgt" ] || return 1
            case "$tgt" in
                /*) cur="/" ;;
            esac
            rest="$tgt/$rest"
        else
            cur="$cand"
        fi
    done
    printf '%s\n' "$cur"
}

hook_resolve_m() {
    local p
    [ "$#" -gt 0 ] || return 1
    if [ "$(readlink -m -- / 2>/dev/null)" = "/" ]; then # swallow-ok: a readlink without -m reads empty, which selects the walk below
        readlink -m -- "$@"
        return
    fi
    for p in "$@"; do
        [ -n "$p" ] || return 1
    done
    for p in "$@"; do
        _hrp_walk "$p" || return 1
    done
}
