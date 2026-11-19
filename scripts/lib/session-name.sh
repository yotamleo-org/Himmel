#!/usr/bin/env bash
# session-name.sh — resolve the running Claude Code session's name from inside
# a hook or tool subprocess.
#
# There is no CLAUDE_SESSION_NAME env var in this codebase (checked: no hit
# anywhere in scripts/ or docs/internals/). What DOES exist: claude exports
# CLAUDE_PID into every tool subprocess it spawns (see
# scripts/handover/headed-arm.sh). Two sources are read from it, in order:
#
#   1. argv: the launched `claude` process's own argv carries `-n <name>` when
#      the session was named. /proc/<pid>/cmdline is Linux-only, matching the
#      claudex lane, which is konsole/Linux-only today. A `-n` name is fixed
#      for the life of the process.
#   2. the session registry, only when argv carried no `-n` name: Claude Code
#      writes ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json for each
#      interactive process. T3 Code starts claude with `--session-id` and no
#      `-n`, and its thread title is that file's `.name`. A thread title can be
#      changed at any time, by the operator in the T3 UI or by an agent through
#      T3's MCP tools, so it is not a general session name: it is accepted only
#      when `.entrypoint` is `t3-code`, `.pid` is CLAUDE_PID, the name ends in
#      `-chief` or `-console` (the shapes the chief hooks treat as a chief) and
#      it passes the same validation as an argv name. guard-t3-thread-tools.sh
#      refuses an agent's T3 tool call that would set a chief-shaped title, so
#      such a title comes from the operator. When /proc/<pid>/stat is readable,
#      its process start time must equal the registry's `.procStart`, so a file
#      left behind for a reused pid is never read as the live session's.
#
# Platforms without /proc (macOS) have no argv source and skip the start-time
# comparison. Anything unresolvable prints nothing, never a wrong name —
# callers must treat that as "unresolvable" and fail open, not as an error.
#
# Usage: source this file, call `current_session_name`. Prints the resolved
# name on stdout and returns 0; prints nothing and returns 1 when
# unresolvable (no CLAUDE_PID, no name from either source, or the name fails
# validation).
#
# Validation is load-bearing, not cosmetic: callers build a filesystem path
# from this value (<handover root>/inbox/<name>.md) — a name containing '/',
# '..' or whitespace must never be allowed to traverse outside inbox/.
#
# Test seams ONLY (production never sets them): SESSION_NAME_CMDLINE_FILE,
# SESSION_NAME_REGISTRY_FILE and SESSION_NAME_PROC_STAT_FILE replace
# /proc/<pid>/cmdline, the registry file and /proc/<pid>/stat. A test cannot
# fabricate the /proc files for an arbitrary pid, so test-session-name.sh points
# these at hand-built fixtures instead.

# _session_name_ok <name> — rc 0 when <name> is safe to use as a path component.
_session_name_ok() {
    [ -n "$1" ] || return 1
    case "$1" in
        # */*|*..*: path traversal. *[[:space:]]*: whitespace. *[*?[]*:
        # glob metacharacters — resolve_chief_doc's `find -name
        # "${name}.md"` treats these as wildcards, not literal characters,
        # so an unsanitized name can cross-match a DIFFERENT session's
        # chief doc.
        */*|*..*|*[[:space:]]*|*[*?[]*) return 1 ;;
    esac
    return 0
}

# _session_name_registry <pid> — the chief-shaped T3 thread title from the
# session registry, or rc 1.
_session_name_registry() {
    local pid="$1"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    command -v jq >/dev/null 2>&1 || return 1

    local reg="${SESSION_NAME_REGISTRY_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json}"
    [ -f "$reg" ] && [ -r "$reg" ] || return 1
    local body=""
    IFS= read -r -d '' body < "$reg" 2>/dev/null || true  # swallow-ok: read -d '' returns 1 at EOF by design
    case "$body" in *t3-code*) ;; *) return 1 ;; esac

    # One line of procStart, then the name; the trailing x keeps command
    # substitution from stripping a newline the name itself ends in.
    local out
    out=$(jq -j --arg pid "$pid" '
        if type == "object" and .entrypoint == "t3-code"
            and (.pid | type) == "number" and (.pid | tostring) == $pid
            and (.name | type) == "string"
        then ((.procStart // "") | tostring) + "\n" + .name + "x"
        else empty end' <<<"$body" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    out=${out%x}
    local proc_start="${out%%$'\n'*}" name="${out#*$'\n'}"

    case "$name" in *-chief|*-console) ;; *) return 1 ;; esac
    _session_name_ok "$name" || return 1

    local stat_file="${SESSION_NAME_PROC_STAT_FILE:-/proc/$pid/stat}" stat="" rest
    if [ -r "$stat_file" ]; then
        IFS= read -r stat < "$stat_file" 2>/dev/null || [ -n "$stat" ] || return 1
        case "$stat" in *')'*) ;; *) return 1 ;; esac
        # The command name (field 2) can hold spaces and parentheses, so the
        # fields are counted from after the LAST `)`: field 3 onward.
        rest=${stat##*)}
        local -a fields
        read -r -a fields <<<"$rest"
        [ -n "${fields[19]:-}" ] && [ "${fields[19]}" = "$proc_start" ] || return 1
    fi

    printf '%s\n' "$name"
}

current_session_name() {
    local pid="${CLAUDE_PID:-}"
    [ -n "$pid" ] || return 1

    local cmdline_file="${SESSION_NAME_CMDLINE_FILE:-/proc/$pid/cmdline}"
    local name="" tok prev=""
    if [ -r "$cmdline_file" ]; then
        while IFS= read -r -d '' tok; do
            if [ "$prev" = "-n" ]; then
                name="$tok"
                break
            fi
            prev="$tok"
        done < "$cmdline_file" 2>/dev/null
    fi

    if [ -n "$name" ]; then
        _session_name_ok "$name" || return 1
        printf '%s\n' "$name"
        return 0
    fi

    _session_name_registry "$pid"
}
