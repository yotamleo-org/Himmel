# shellcheck shell=bash
# argv-has-n-name.sh — sourced, never executed. the exact-argv
# session-name check, factored out of headed-arm.sh so arm-resume's bus rebind
# helper uses the SAME decision rather than a looser copy of it.
#
# Reads two globals the caller sets: PROC (the /proc root, injectable) and NAME.

_argv_has_n_name() { # _argv_has_n_name <pid> - true iff /proc/<pid>/cmdline
                      # has an element exactly "-n" immediately followed by
                      # an element exactly equal to $NAME (positional and
                      # exact, from the real NUL-separated argv - never a
                      # substring or regex match against flattened text)
    local pid="$1" prev="" cur
    [ -r "$PROC/$pid/cmdline" ] || return 1
    while IFS= read -r -d '' cur; do
        [ "$prev" = "-n" ] && [ "$cur" = "$NAME" ] && return 0
        prev="$cur"
    done < "$PROC/$pid/cmdline"
    return 1
}
