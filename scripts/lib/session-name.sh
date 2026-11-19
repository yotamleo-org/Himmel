#!/usr/bin/env bash
# session-name.sh — the running Claude Code session's name, for a hook or tool
# subprocess.
#
# Usage: source this file, call `current_session_name`. Prints the name on
# stdout and returns 0; prints nothing and returns 1 when it cannot be resolved,
# which callers treat as unresolvable and fail open, not as an error. The name
# is validated because callers build a filesystem path from it
# (<handover root>/inbox/<name>.md).
#
# claude exports CLAUDE_PID into every tool subprocess it spawns. A named
# session carries `-n <name>` in that process's argv, read from
# /proc/<pid>/cmdline, which is Linux-only. Claude Code writes
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json for each interactive
# process; T3 Code starts claude without `-n`, and its thread title is that
# file's `.name`.

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

_session_name_registry() {
    local pid="$1"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    command -v jq >/dev/null 2>&1 || return 1

    local reg="${SESSION_NAME_REGISTRY_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json}"
    [ -f "$reg" ] && [ -r "$reg" ] || return 1
    local body=""
    IFS= read -r -d '' body < "$reg" 2>/dev/null || true  # swallow-ok: read -d '' returns 1 at EOF by design
    case "$body" in *t3-code*) ;; *) return 1 ;; esac

    local out
    out=$(jq -r --arg pid "$pid" '
        if type == "object" and .entrypoint == "t3-code"
            and (.pid | type) == "number" and (.pid | tostring) == $pid
            and (.name | type) == "string" and .name != ""
            and (.name | contains("\n") | not)
        then ((.procStart // "") | tostring), .name
        else empty end' <<<"$body" 2>/dev/null) || return 1
    case "$out" in *$'\n'*) ;; *) return 1 ;; esac
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
