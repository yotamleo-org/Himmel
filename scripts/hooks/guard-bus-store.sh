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
# Also not caught: a separator inside a quoted option value, the verb fed on
# stdin to xargs, the verb or the store path held in a shell variable
# (`v=register; bus $v x`, `$S/bus`), and a symlinked payload cwd or a relative
# file path against it (HIMMEL-5206).
# Deliberately over-denied (the safe direction): a verb word anywhere after a
# bus-able word in one segment (`bus send ... --summary "rebind done"`, `git
# commit -m "fix(bus): register retry"`), a glob or expansion under `himmel/`
# (`himmel/*`), and any word that can expand to `bus` (`*`, `b?s`, `$x`) once
# the cwd or the command names the himmel state dir. The bypass flag covers all.
# Closed by shape, not by spelling: backslash-newline continuations are joined
# (the pair removed) before the split; quotes, backslashes and parens are
# stripped per word; a word is bus-able when a path component glob-matches `bus`
# after `${x}`, `$x`, `$'..'` and `{a,b}` become `*`; and the early exit lets any
# payload with a quote, `$`, glob character, backslash or brace expansion through
# to these rules.
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
# \u escape could spell them past a raw scan, so it falls through too, and so
# does anything that can build the word `bus` in the shell without writing it:
# a backslash (`b\<nl>us`), a quote (`b''us`; a double quote arrives as the
# JSON escape `\"`, so that pair is a trigger too), a backtick or `$` (`b${x}us`,
# `b$(true)us`), a glob
# character (`b?s`, `b[u]s`, `b*s`) or a brace expansion (`{` not followed by
# the JSON envelope's `"`). A
# file-tool path may reach the store through a symlink alias that carries no
# literal at all, so any payload with a file_path/notebook_path is resolved.
case "$input" in
    *bus*|*BUS*|*'\u'*|*\\\\*|*\\\"*|*\'*|*\$*|*\`*|*\**|*\?*|*\[*|*\{[!\"]*|*file_path*|*notebook_path*) ;;
    *) exit 0 ;;
esac

ROOT_RE='(^|[^A-Za-z0-9_-])himmel\\?/bus($|[^A-Za-z0-9_.-])'
# The identity verbs are matched word by word (verb_after_bus below), not by a
# regex: a `bus` word, then later in the SAME segment a word that is exactly
# register|bind|rebind. Options may sit between (`bus --role leg register x`),
# quotes are dropped (`bus 'register' x`, `b''us register x`), and a path such as
# /tmp/register.txt is not a verb.
ENV_RE='(^|[^A-Za-z0-9_])HIMMEL_BUS_[A-Za-z0-9_]*\+?='
# A component right under himmel/ that carries a glob or expansion character
# (`himmel/b?s`, `himmel/b[u]s`, `himmel/$x`) may spell the bus root.
GLOBROOT_RE='(^|[^A-Za-z0-9_-])himmel/[^/[:space:]]*[?*[{$]'
VERBWORD_RE='(^|[^A-Za-z0-9_./-])(register|bind|rebind)($|[^A-Za-z0-9_.-])'

# state_view <text>: $HOME and $XDG_STATE_HOME are the state dir's own spelling,
# so they must not count as a word that could expand to `bus`.
state_view() {
    local s="$1"
    s=${s//\$\{XDG_STATE_HOME\}/XDGSTATE}
    s=${s//\$XDG_STATE_HOME/XDGSTATE}
    s=${s//\$\{HOME\}/HOMEDIR}
    s=${s//\$HOME/HOMEDIR}
    printf '%s' "$s"
}
STATE_RE='(^|/)state/himmel/?$'
# The state dir named inside the command: ~/.local/state/himmel, $XDG_STATE_HOME/himmel
# or ${XDG_STATE_HOME}/himmel (the literal XDG value is matched separately).
STATECMD_RE='(state|XDG_STATE_HOME\}?)/himmel($|[^A-Za-z0-9_-])'

# norm <string>: collapse repeated slashes and /./ so himmel//bus and himmel/./bus
# match like himmel/bus. Pure bash, 3.2-safe.
norm() {
    local s="$1"
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    while [[ "$s" == *"/./"* ]]; do s=${s//\/.\//\/}; done
    while [[ "$s" == *"//"* ]]; do s=${s//\/\//\/}; done
    printf '%s' "$s"
}

# busish <word>: could this shell word be, or contain a path component that is,
# the string `bus` once the shell has expanded it? Parens, quotes and
# backslashes are dropped; an expansion (`${x}`, `$x`, `$'..'`, `{a,b}`) is
# replaced by `*`; each path component is then matched as a glob against `bus`
# (`b?s`, `b[u]s`, `b*s`, `bus`, `$x`). A word whose component is `bus.json` or
# `himmel-bus` is not. Pure bash, 3.2-safe.
# shellcheck disable=SC2016  # regex text; nothing is meant to expand
EXP_RE='(\$'"'"'[^'"'"']*'"'"'|\$\{[^}]*\}|\$\([^)]*\)|`[^`]*`|\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)'
busish() {
    local w="$1" m p parts
    while [[ "$w" =~ $EXP_RE ]]; do
        m="${BASH_REMATCH[0]}"
        w=${w/"$m"/"*"}
    done
    # What is left of an unclosed `$(` / backtick / paren is just a prefix.
    w=${w//\$\(/}; w=${w//\`/}; w=${w//\(/}; w=${w//\)/}
    w=${w//[\'\"\\]/}
    IFS=/ read -ra parts <<< "$w"
    [ "${#parts[@]}" -gt 0 ] || return 1
    for p in "${parts[@]}"; do
        [ -n "$p" ] || continue
        # shellcheck disable=SC2053  # the glob match is the point
        [[ bus == $p ]] && return 0
    done
    return 1
}

# cmd_busish <text>: does any word of any command segment look like `bus`?
cmd_busish() {
    local seg word words
    while IFS= read -r seg; do
        read -ra words <<< "$seg"
        [ "${#words[@]}" -gt 0 ] || continue
        for word in "${words[@]}"; do
            busish "$word" && return 0
        done
    done <<< "$(printf '%s' "$1" | tr ';&|' '\n')"
    return 1
}

# verb_after_bus <text>: a segment with a busish word and, later in the same
# segment, a word that is exactly register|bind|rebind (quotes and backslashes
# dropped, so `reg''ister` counts). Options may sit between them.
verb_after_bus() {
    local seg word words v seen
    while IFS= read -r seg; do
        read -ra words <<< "$seg"
        [ "${#words[@]}" -gt 0 ] || continue
        seen=0
        for word in "${words[@]}"; do
            v=${word//[\'\"\\\(\)\`]/}
            if [ "$seen" = 1 ]; then
                case "$v" in register|bind|rebind) return 0 ;; esac
            fi
            busish "$word" && seen=1
        done
    done <<< "$(printf '%s' "$1" | tr ';&|' '\n')"
    return 1
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
        # Join backslash-newline continuations first: `bus \<nl> --role x \<nl>
        # register y` is one command to the shell and must be one segment here.
        # The pair is removed, not replaced: bash joins `reg\<nl>ister` into one word.
        bsnl=$'\\\n'
        # Guarded: a pattern substitution on a large multibyte string is
        # superlinear (HIMMEL-4729), so it only runs when there is a pair.
        if [[ "$cmd" == *"$bsnl"* ]]; then cmd=${cmd//"$bsnl"/}; fi
        cmd_n=$(norm "$cmd")
        xdg_state=""
        [ -n "${XDG_STATE_HOME:-}" ] && xdg_state=$(norm "${XDG_STATE_HOME}/himmel") && xdg_state=${xdg_state%/}
        [[ "$cmd" =~ $ROOT_RE || "$cmd_n" =~ $ROOT_RE ]] && deny "the command names the himmel-bus store (reads and writes under the bus root are off-limits)"
        # Quotes dropped: b''us, himmel/"bus" and the like name the same path.
        # (`tr`, not a substitution: linear on a large payload.)
        cmd_q=$(printf '%s' "$cmd" | tr -d "\"'\\\\")
        cmd_qn=$(norm "$cmd_q")
        [[ "$cmd_qn" =~ $ROOT_RE ]] && deny "the command names the himmel-bus store (reads and writes under the bus root are off-limits)"
        # A glob or expansion in the component right under himmel/ can spell bus.
        [[ "$cmd_qn" =~ $GLOBROOT_RE ]] && deny "the command reaches under himmel/ through a glob or expansion that can spell the bus root"
        # In-command cd: the command names the state dir and a word that can be bus.
        state_named=0
        [[ "$cmd_n" =~ $STATECMD_RE ]] && state_named=1
        [ -n "$xdg_state" ] && [[ "$cmd_n" == *"$xdg_state"* ]] && state_named=1
        if [ "$state_named" = 1 ]; then
            cmd_busish "$(state_view "$cmd_n")" && deny "the command names the himmel state dir and a word that can be bus (relative store path)"
        fi
        # cwd indirection: a relative path is read against the payload cwd.
        cwd=$(printf '%s' "$input" | jq -er '.cwd | strings' 2>/dev/null) || cwd=""
        if [ -n "$cwd" ]; then
            cwd_r=$(readlink -m -- "$cwd" 2>/dev/null) || cwd_r=""
            for c in "$cwd" "$cwd_r"; do
                [ -n "$c" ] || continue
                c_n=$(norm "$c")
                [[ "$c_n/" =~ $ROOT_RE ]] && deny "the working directory is under the himmel-bus store"
                if [[ "$c_n" =~ $STATE_RE ]] || { [ -n "$xdg_state" ] && [ "${c_n%/}" = "$xdg_state" ]; }; then
                    cmd_busish "$(state_view "$cmd_n")" && deny "the working directory is the himmel state dir and the command names a word that can be bus (relative store path)"
                fi
            done
        fi
        # Identity verbs, per segment (; & | newline).
        # Cheap gate first: the word walk only runs when a verb word is present at all.
        if [[ "$cmd_q" =~ $VERBWORD_RE ]]; then
            verb_after_bus "$cmd" && deny "bus register|bind|rebind is the launcher's, not a session's"
        fi
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
