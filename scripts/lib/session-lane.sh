# shellcheck shell=bash
# scripts/lib/session-lane.sh - which lane is this session? Sourced; it only
# defines functions and changes no shell option, so a `set -euo pipefail`
# caller (auto-arm-on-cap.sh) stays safe. Bash 3.2+.

# session_lane_signal: print the environment signal that names a non-Claude
# lane and return 0; return 1 when there is none.
session_lane_signal() {
    case "${ANTHROPIC_BASE_URL:-}" in
        https://api.z.ai|https://api.z.ai/*) echo "ANTHROPIC_BASE_URL=api.z.ai"; return 0 ;;
    esac
    if [ "${ANTHROPIC_BASE_URL:-}" = "${CODEX_PROXY_BASE_URL:-http://127.0.0.1:8317}" ]; then
        echo "ANTHROPIC_BASE_URL=codex proxy"; return 0
    fi
    if [ -n "${HERMES_ENGINE:-}" ]; then echo "HERMES_ENGINE set"; return 0; fi
    if [ -n "${CODEX_ADAPTER:-}" ]; then echo "CODEX_ADAPTER set"; return 0; fi
    # NOTE: CODEX_COMPANION_SESSION_ID is deliberately NOT a lane signal - the
    # codex-companion PLUGIN exports it into every Claude session where it is
    # installed (observed live in a plain Fable session), so keying on it would
    # silently disable the watchdog machine-wide. CODEX_THREAD_ID is only set
    # inside a real codex runtime.
    if [ -n "${CODEX_THREAD_ID:-}" ]; then echo "CODEX_THREAD_ID set"; return 0; fi
    return 1
}

SESSION_LANE_HEADROOM_URL=http://127.0.0.1:8787

_session_lane_walk_chain() {
    local p line pp comm n=0
    SESSION_LANE_AGENT="" SESSION_LANE_CLAUDE_PID_SEEN=0
    [ -n "${CLAUDE_PID:-}" ] || SESSION_LANE_CLAUDE_PID_SEEN=1
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
        n=$((n + 1))
        [ "$p" = "${CLAUDE_PID:-}" ] && SESSION_LANE_CLAUDE_PID_SEEN=1
        line=$(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
        line="${line#"${line%%[![:space:]]*}"}"
        pp=${line%%[[:space:]]*}
        comm=${line#"$pp"}
        comm="${comm#"${comm%%[![:space:]]*}"}"
        comm=${comm##*/}  # macOS ps prints comm as a full path
        if [ -z "$SESSION_LANE_AGENT" ]; then
            case "$comm" in
                claude|codex|copilot|agy|hermes) SESSION_LANE_AGENT=$comm ;;
            esac
        fi
        p=$pp
    done
    return 0
}

# session_lane_claude_only: return 0 when this session is Claude on every
# check; else print which check failed and return 1. Checks, all required:
#   1. CLAUDECODE=1, and the process chain meets `claude` before any other
#      agent (a Codex CLI started from a Claude Bash tool inherits CLAUDECODE),
#      and CLAUDE_PID, when set, is an ancestor;
#   2. no session_lane_signal;
#   3. ANTHROPIC_BASE_URL unset, the Anthropic API host, or the headroom proxy;
#   4. ANTHROPIC_MODEL unset or a Claude model name.
# Not a defence against a session that forges its environment or renames its
# process: it stops accidental exposure through a non-Claude lane.
session_lane_claude_only() {
    local sig
    if [ "${CLAUDECODE:-}" != 1 ]; then echo "CLAUDECODE is not 1"; return 1; fi
    if sig=$(session_lane_signal); then echo "$sig"; return 1; fi
    case "${ANTHROPIC_BASE_URL:-}" in
        ''|https://api.anthropic.com|https://api.anthropic.com/*|"$SESSION_LANE_HEADROOM_URL") ;;
        *) echo "ANTHROPIC_BASE_URL is not an Anthropic endpoint"; return 1 ;;
    esac
    case "${ANTHROPIC_MODEL:-}" in
        ''|claude-*|opus*|sonnet*|haiku*|fable*) ;;
        *) echo "ANTHROPIC_MODEL is not a Claude model"; return 1 ;;
    esac
    _session_lane_walk_chain
    case "$SESSION_LANE_AGENT" in
        claude) ;;
        '') echo "no claude process in the process chain"; return 1 ;;
        *) echo "process chain runs under $SESSION_LANE_AGENT"; return 1 ;;
    esac
    if [ "$SESSION_LANE_CLAUDE_PID_SEEN" -ne 1 ]; then echo "CLAUDE_PID is not an ancestor"; return 1; fi
    return 0
}
