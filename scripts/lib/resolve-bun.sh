#!/usr/bin/env bash
# Shared Bun selection for station updates, bridge launches and service units
#. Source-only; Bash 3.2 compatible.
resolve_bun() {
    if [ -x "$HOME/.bun/bin/bun" ]; then
        printf '%s\n' "$HOME/.bun/bin/bun"
    else
        command -v bun
    fi
}

# Keep child processes and bare Bun calls on the same runtime as resolve_bun.
prefer_bun_on_path() {
    if [ -x "$HOME/.bun/bin/bun" ]; then
        PATH="$HOME/.bun/bin:$PATH"
        export PATH
    fi
}

warn_bun_versions() {
    local preferred="$HOME/.bun/bin/bun" other="" dir before after save_ifs="$IFS"
    [ -x "$preferred" ] || return 0
    IFS=:
    for dir in $PATH:/usr/bin; do
        [ -n "$dir" ] || dir=.
        if [ "$dir/bun" != "$preferred" ] && [ -x "$dir/bun" ]; then
            other="$dir/bun"
            break
        fi
    done
    IFS="$save_ifs"
    [ -n "$other" ] || return 0
    before="$("$preferred" --version 2>/dev/null)" || return 0
    after="$("$other" --version 2>/dev/null)" || return 0
    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
        printf '    WARN: bun versions differ: %s (%s) vs %s (%s); using the user install.\n' \
            "$before" "$preferred" "$after" "$other" >&2
    fi
    return 0
}
