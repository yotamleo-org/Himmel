#!/usr/bin/env bash
# tracker.sh — the tracker-dispatch seam.
#
# Source it, then call a tracker_* verb; each routes to the backend the resolver
# picks (scripts/lib/project-mode.sh, project_mode_tracker): jira | local | none.
# It mirrors the forge.sh + forge-<kind>.sh layout. JS twin: tracker.mjs.
#
#   tracker_id_pattern                        ERE an id matches ('' = none)
#   tracker_id_new <type> <title> [body-file] mint an id, print it
#   tracker_get <id>                          JSON {id,title,status,type,fix_version,epic}
#   tracker_title <id>
#   tracker_transition <id> <status> [--allow-back]
#   tracker_comment <id> <file>
#   tracker_link <id> <url-or-path>
#   tracker_query [field=value ...]           status= | fix_version= | epic=, ANDed;
#                                             prints "<id><TAB><status><TAB><title>"
#
# Return codes: 0 ok, 1 failure, 2 usage / resolver refusal, 3 id not found,
# 4 "this tracker has no such thing" (callers treat it as skip, never failure).
#
# Statuses, forward-only: To Do < In Progress < In Review < IN CI < Done.
# --allow-back permits a move down, a status outside the ladder (Backlog, ...) or
# an item already Done is never touched.
#
# Env seams: JIRA_CMD (jira backend; default node <primary>/scripts/jira/dist/index.js),
# TRACKER_STORE (local store dir; default <handover root>/<user>/<bucket>/tracker),
# TRACKER_LOCK_TRIES (mint lock attempts, 50 ms apart; default 200),
# HIMMEL_ADAPTER_LEDGER (when set, one JSONL line {ts,tracker,forge,op,id,rc,ms}
# per verb is appended to that file; unset = off, no default file).
# Bash 3.2-safe.

_TRACKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/project-mode.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$_TRACKER_LIB_DIR/project-mode.sh"
# shellcheck source=scripts/lib/tracker-jira.sh
# shellcheck disable=SC1091
. "$_TRACKER_LIB_DIR/tracker-jira.sh"
# shellcheck source=scripts/lib/tracker-local.sh
# shellcheck disable=SC1091
. "$_TRACKER_LIB_DIR/tracker-local.sh"
# shellcheck source=scripts/lib/tracker-none.sh
# shellcheck disable=SC1091
. "$_TRACKER_LIB_DIR/tracker-none.sh"

# _tracker_rank <status> — position on the ladder, -1 outside it.
_tracker_rank() {
    case "$1" in
        "To Do") echo 0 ;;
        "In Progress") echo 1 ;;
        "In Review") echo 2 ;;
        "IN CI") echo 3 ;;
        "Done") echo 4 ;;
        *) echo -1 ;;
    esac
}

# _tracker_should_move <current> <target> <allow-back 0|1> — rc 0 when the move
# is allowed. Shared by every backend so the forward-only rule has one owner.
_tracker_should_move() {
    local cur tgt
    cur=$(_tracker_rank "$1"); tgt=$(_tracker_rank "$2")
    [ "$cur" -ge 0 ] || return 1          # Backlog, Closed, ...: not ours to move
    [ "$cur" -ne 4 ] || return 1          # Done is terminal
    [ "$cur" -ne "$tgt" ] || return 1     # already there
    if [ "$tgt" -lt "$cur" ] && [ "$3" -ne 1 ]; then return 1; fi
    return 0
}

# _tracker_filter_value_ok <value> — a query value is spliced into JQL, so it is
# limited to plain characters; anything else is refused, never escaped.
_tracker_filter_value_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9\ ._:#-]*) return 1 ;;
    esac
    return 0
}

# _tracker_ledger <kind> <op> <id> <rc> <t0-seconds> — append one JSONL line.
_tracker_ledger() {
    [ -n "${HIMMEL_ADAPTER_LEDGER:-}" ] || return 0
    local forge ts id now
    forge=$(project_mode_forge --quiet 2>/dev/null) || forge=unknown
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    id=$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._#-')
    now=$(date +%s)
    # ponytail: whole-second resolution (bash 3.2 and BSD date have no sub-second clock), upgrade path: EPOCHREALTIME once bash 5 is the floor
    printf '{"ts":"%s","tracker":"%s","forge":"%s","op":"%s","id":"%s","rc":%s,"ms":%s}\n' \
        "$ts" "$1" "$forge" "$2" "$id" "$4" "$(( (now - $5) * 1000 ))" >> "$HIMMEL_ADAPTER_LEDGER" 2>/dev/null || true
}

# _tracker_dispatch <op> <id-for-ledger|""|-> [args...]; "" takes the id from the
# first output line (id_new), "-" records no id (id_pattern, query).
_tracker_dispatch() {
    local op="$1" id="$2" kind t0 out rc
    shift 2
    kind=$(project_mode_tracker) || return 2
    t0=$(date +%s)
    out=$("_tracker_${kind}_${op}" "$@"); rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    if [ -z "$id" ]; then id="${out%%
*}"; elif [ "$id" = - ]; then id=""; fi
    _tracker_ledger "$kind" "$op" "$id" "$rc" "$t0"
    return "$rc"
}

tracker_id_pattern() { _tracker_dispatch id_pattern -; }

tracker_id_new() {
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        echo "usage: tracker_id_new <type> <title> [body-file]" >&2
        return 2
    fi
    _tracker_dispatch id_new "" "$@"
}

tracker_get() {
    [ "$#" -eq 1 ] || { echo "usage: tracker_get <id>" >&2; return 2; }
    _tracker_dispatch get "$1" "$1"
}

tracker_title() {
    [ "$#" -eq 1 ] || { echo "usage: tracker_title <id>" >&2; return 2; }
    _tracker_dispatch title "$1" "$1"
}

tracker_transition() {
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$#" -eq 3 ] && [ "$3" != --allow-back ]; }; then
        echo "usage: tracker_transition <id> <status> [--allow-back]" >&2
        return 2
    fi
    if [ "$(_tracker_rank "$2")" -lt 0 ]; then
        echo "tracker: '$2' is not a tracker status (To Do, In Progress, In Review, IN CI, Done)" >&2
        return 2
    fi
    _tracker_dispatch transition "$1" "$@"
}

tracker_comment() {
    [ "$#" -eq 2 ] || { echo "usage: tracker_comment <id> <file>" >&2; return 2; }
    [ -f "$2" ] || { echo "tracker: comment file '$2' not found" >&2; return 2; }
    _tracker_dispatch comment "$1" "$@"
}

tracker_link() {
    [ "$#" -eq 2 ] || { echo "usage: tracker_link <id> <url-or-path>" >&2; return 2; }
    _tracker_dispatch link "$1" "$@"
}

tracker_query() {
    local a
    for a in "$@"; do
        case "$a" in
            status=*|fix_version=*|epic=*) ;;
            *) echo "tracker: unknown filter '$a' (expected status=, fix_version= or epic=)" >&2; return 2 ;;
        esac
        _tracker_filter_value_ok "${a#*=}" || { echo "tracker: unsafe filter value in '$a'" >&2; return 2; }
    done
    _tracker_dispatch query - "$@"
}
