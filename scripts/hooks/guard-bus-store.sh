#!/usr/bin/env bash
# guard-bus-store.sh — PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit"): [HIMMEL-4829] himmel-bus T6, the store
# guard. A SPEED BUMP, not a fence.
#
# WHY: phase 1 of himmel-bus runs every session, the server and the store as one
# uid (HIMMEL-4818 threat model T1, T3, T5, T6). The bus API cannot forge a
# sender or reach a peer's log, but a session's own Bash could `cat` another
# session's log, rewrite `peers/*.json`, or bind itself as its console by hand.
# This hook makes those tool-driven routes cost a denial and a named bypass
# instead of one command. Direct writes are DETECTED by the hash chain; prevention
# needs a second uid (spec §12, phase 2).
#
# DENIES:
#   Bash — the command text
#     (a) names the bus root: `himmel/bus` not preceded by [A-Za-z0-9_-]
#         and followed by `/`, end of word or a char outside [A-Za-z0-9_.-] (so
#         the sibling `himmel/bus.json` is not the root) (any spelling of the state home — `$XDG_STATE_
#         HOME/himmel/bus`, `~/.local/state/himmel/bus`, a relative
#         `himmel/bus/log/...`; the hyphenated plugin dir `himmel-bus` is not it).
#         Reads and writes are both denied: a log read is the T5 leak.
#     (b) calls `bus register`, `bus bind` or `bus rebind` (the identity verbs
#         the launcher owns; `bus` bounded the same way, so `bin/bus register`
#         counts).
#     (c) assigns a HIMMEL_BUS_* variable (`HIMMEL_BUS_NAME=x claude`, `export
#         ...`, `env ...`). Mentioning one (`echo $HIMMEL_BUS_NAME`,
#         `git grep HIMMEL_BUS_NAME`) is not an assignment and stays allowed.
#   Edit|Write|MultiEdit|NotebookEdit — file_path (notebook_path) names the bus
#     root textually, or resolves to it (`readlink -m`: `..` segments and
#     symlinked components).
# ALLOWS: `bus status|peers|wait|send|adopt` (the CLI stamps `f` from its own
#   process ancestry, so no role check is needed here) and everything else —
#   silently, with no output.
#
# FAIL MODE: a security-shaped fence for its one subject. A payload it cannot
# parse (missing jq, bad JSON, a non-string command) is scanned as raw text and
# DENIED when it names the bus root; with no mention of the root it is allowed.
# Failing closed on every unparseable call would lock the session out of every
# tool for a hook bug (scripts/hooks/CLAUDE.md fail-open-vs-closed rule).
#
# RESIDUAL (deliberate, plan T6, threat model T3/T5/T6): this is text matching,
# not a shell parser or a sandbox. An interpreter that assembles the path
# (`python3 -c "open(os.path.expanduser('~/.local/state/hi'+'mmel/bus/...'))"`),
# a renamed copy of the CLI, `eval`, a script file that itself does the write, a
# `$(...)`-built path, a Bash command reaching the store through a symlink alias
# (only file-tool paths are resolved), or the Read tool pointed at a log are not
# caught. The Read and Grep tools are not wired to this hook. Same-uid tampering that re-chains is
# undetected (phase 2's dedicated uid closes it).
#
# Bypass: BUS_STORE_GUARD_OK=1 in the LAUNCHING shell (session-sticky; a per-call
# prefix does not reach this hook process). Needed to register or bind by hand
# (docs/internals/retask-channel.md), since the launcher's own `bus register`
# runs inside a script and never shows up in a tool call.
#
# Platform guard (gitbash-only): env + jq + `readlink -m` where present; runs
# under Git Bash or POSIX bash 3.2+. The bus itself is Linux-only. No .ps1 twin.
#
# Exit codes: 0 allow (no output); 2 deny (JSON hookSpecificOutput with
# permissionDecision "deny" on stdout, reason starting "bus store-deny: ", and
# the same text on stderr — belt-and-braces idiom of guard-leg-wakeup.sh).
set -uo pipefail

[ "${BUS_STORE_GUARD_OK:-}" = "1" ] && exit 0

input=$(cat)

# Fast path, no fork: every Bash rule below needs one of these literals. A JSON
# \u escape could spell them past a raw scan, so it falls through too. A
# file-tool path may reach the store through a symlink alias that carries no
# literal at all, so any payload with a file_path/notebook_path is resolved.
case "$input" in
    *bus*|*BUS*|*'\u'*|*file_path*|*notebook_path*) ;;
    *) exit 0 ;;
esac

ROOT_RE='(^|[^A-Za-z0-9_-])himmel\\?/bus($|[^A-Za-z0-9_.-])'
# A bounded `bus` word, then anywhere later in the SAME command segment a bounded
# verb: options before the verb (`bus --role leg register x`) and quoted words
# (`bus 'register' x`, `"bus" register x`) match. A path component such as
# /tmp/register.txt is not a verb (a `/` or `.` before it is not a boundary).
VERB_RE='(^|[^A-Za-z0-9_-])bus($|[^A-Za-z0-9_-])(.*[^A-Za-z0-9_./-])?(register|bind|rebind)($|[^A-Za-z0-9_.-])'
ENV_RE='(^|[^A-Za-z0-9_])HIMMEL_BUS_[A-Za-z0-9_]*\+?='
BUSTOK_RE='(^|[^A-Za-z0-9_-])bus/'
STATE_RE='(^|/)state/himmel/?$'

# norm <string>: collapse repeated slashes and /./ so himmel//bus and himmel/./bus
# match like himmel/bus. Pure bash, 3.2-safe.
norm() {
    local s="$1"
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    while [[ "$s" == *"/./"* ]]; do s=${s//\/.\//\/}; done
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    printf '%s' "$s"
}

deny() {
    local msg reason
    msg="bus store-deny: $1. himmel-bus keeps its store off-limits to a session's own tool calls (speed bump, HIMMEL-4829). Allowed: bus status|peers|wait|send|adopt. Registration is the launcher's. Bypass: BUS_STORE_GUARD_OK=1 in the launching shell."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) || reason='"bus store-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

raw_scan() {
    [[ "$input" =~ $ROOT_RE ]] && deny "the call names the himmel-bus store (payload not parseable, scanned as raw text)"
    exit 0
}

command -v jq >/dev/null 2>&1 || raw_scan
tool=$(printf '%s' "$input" | jq -r '.tool_name | strings' 2>/dev/null) || raw_scan
[ -n "$tool" ] || raw_scan

case "$tool" in
    Bash)
        cmd=$(printf '%s' "$input" | jq -er '.tool_input.command | strings' 2>/dev/null) || raw_scan
        cmd_n=$(norm "$cmd")
        [[ "$cmd" =~ $ROOT_RE || "$cmd_n" =~ $ROOT_RE ]] && deny "the command names the himmel-bus store (reads and writes under the bus root are off-limits)"
        # cwd indirection: a relative path is read against the payload cwd.
        cwd=$(printf '%s' "$input" | jq -er '.cwd | strings' 2>/dev/null) || cwd=""
        if [ -n "$cwd" ]; then
            cwd_r=$(readlink -m -- "$cwd" 2>/dev/null) || cwd_r=""
            for c in "$cwd" "$cwd_r"; do
                [ -n "$c" ] || continue
                c_n=$(norm "$c")
                [[ "$c_n/" =~ $ROOT_RE ]] && deny "the working directory is under the himmel-bus store"
                if [[ "$c_n" =~ $STATE_RE ]] || { [ -n "${XDG_STATE_HOME:-}" ] && [ "$c_n" = "$(norm "$XDG_STATE_HOME")/himmel" ]; }; then
                    [[ "$cmd_n" =~ $BUSTOK_RE ]] && deny "the working directory is the himmel state dir and the command names bus/ (relative store path)"
                fi
            done
        fi
        # Identity verbs, per segment (; & | newline).
        while IFS= read -r seg; do
            [[ "$seg" =~ $VERB_RE ]] && deny "bus register|bind|rebind is the launcher's, not a session's"
        done <<< "$(printf '%s' "$cmd" | tr ';&|' '\n')"
        [[ "$cmd" =~ $ENV_RE ]] && deny "a session does not set HIMMEL_BUS_* for itself or a child"
        ;;
    Edit|Write|MultiEdit|NotebookEdit)
        path=$(printf '%s' "$input" | jq -er '(.tool_input.file_path // .tool_input.notebook_path) | strings' 2>/dev/null) || raw_scan
        path=$(norm "$path")
        [[ "$path" =~ $ROOT_RE ]] && deny "the target path is under the himmel-bus store"
        resolved=$(readlink -m -- "$path" 2>/dev/null) || resolved=""
        [ -n "$resolved" ] && [[ "$resolved" =~ $ROOT_RE ]] && deny "the target path resolves under the himmel-bus store"
        ;;
esac
exit 0
