#!/usr/bin/env bash
# scripts/lib/succession-bullet.sh - the one strict parser of a worker's handshake
# bullet, sourced by succession-tracker.sh and worker-token.sh. The grammar is one
# whole `- ` line, so a prose line or a mirrored relay quoting it confirms nothing:
#   - [HH:MM ][LIVE — ]SUCCESSION accepted: [`]<incoming>[`] replaces [`]<outgoing>[`]
# with backticks as a balanced pair or not at all. bash 3.2-safe.

_succession_handshakes() {
    awk '/^## Results/ { s = 1; next } s && /^- ([0-9][0-9]:[0-9][0-9] )?(LIVE — )?SUCCESSION accepted/ { print }' "$1"
}

_succession_parse() {
    # shellcheck disable=SC2016  # the backticks are literal markers in the bullet
    sed -nE \
        -e 's/^- ([0-9]{2}:[0-9]{2} )?(LIVE — )?SUCCESSION accepted: `([A-Za-z0-9_.-]+)` replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)[[:space:]]*$/\3/p' \
        -e 's/^- ([0-9]{2}:[0-9]{2} )?(LIVE — )?SUCCESSION accepted: ([A-Za-z0-9_.-]+) replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)[[:space:]]*$/\3/p'
}

succession_incoming() {
    _succession_handshakes "$1" | tail -n 1 | _succession_parse
}

succession_names() {
    local lines found
    [ -n "${2:-}" ] || return 1
    lines="$(_succession_handshakes "$1")" || return 2
    found="$(printf '%s\n' "$lines" | _succession_parse)" || return 2
    printf '%s\n' "$found" | grep -Fx -- "$2" >/dev/null
}
