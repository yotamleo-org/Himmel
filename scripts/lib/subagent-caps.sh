#!/usr/bin/env bash
# subagent-caps.sh - the subagent caps every claude session himmel launches
# starts with, and the Agent-tool withdrawal for a Haiku session. Sourced by
# each launcher; one copy of the values, never one per launcher.
#
# On source it sets:
#   SUBAGENT_CAPS_ENV              the two NAME=VALUE pairs, an array, for an
#                                  `env NAME=VALUE ... claude` launch line
# Functions:
#   subagent_caps_export           export both into the current shell
#   subagent_caps_is_haiku <model> 0 if <model> names a Haiku model: haiku or
#                                  claude-haiku, alone or followed by a
#                                  non-alphanumeric (claude-haiku-5-5,
#                                  haiku[1m]), any case; the guard's match
#   subagent_caps_haiku_args <argv...>
#                                  set SUBAGENT_CAPS_HAIKU_ARGS to
#                                  (--disallowedTools Agent) when the argv's
#                                  --model names Haiku, else to ()
#
# Platform guard: any POSIX bash 3.2+ (macOS ships 3.2); no external commands
# beyond tr.

SUBAGENT_CAPS_ENV=(
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2"
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=20"
)

subagent_caps_export() {
    local pair
    for pair in "${SUBAGENT_CAPS_ENV[@]}"; do
        export "${pair?}"
    done
}

subagent_caps_is_haiku() {
    local m
    m=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$m" in
        haiku|haiku[!a-z0-9]*|claude-haiku|claude-haiku[!a-z0-9]*) return 0 ;;
    esac
    return 1
}

subagent_caps_haiku_args() {
    SUBAGENT_CAPS_HAIKU_ARGS=()
    local model="" expect=0 a
    for a in "$@"; do
        if [ "$expect" = 1 ]; then
            model="$a"
            expect=0
            continue
        fi
        case "$a" in
            --model) expect=1 ;;
            --model=*) model="${a#--model=}" ;;
        esac
    done
    if subagent_caps_is_haiku "$model"; then
        # shellcheck disable=SC2034  # read by the launcher that sourced this file
        SUBAGENT_CAPS_HAIKU_ARGS=(--disallowedTools Agent)
    fi
    return 0
}
