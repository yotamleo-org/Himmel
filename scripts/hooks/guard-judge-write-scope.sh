#!/usr/bin/env bash
# agent_type is the subagent's name inside a subagent call (code.claude.com/docs/en/hooks, "Common input fields": "For
# subagents, the subagent's type takes precedence"; the sub-agents page: a subagent's name "is what hooks receive as
# agent_type").
# A security fence: fails closed for a judge-ro payload. Bypass (single run, launching shell): JUDGE_WRITE_SCOPE_OK=1.
set -uo pipefail

[ "${JUDGE_WRITE_SCOPE_OK:-0}" != "1" ] || exit 0

# cat reads a large Write in blocks and works on the socket the launcher passes as stdin (/dev/stdin cannot be opened
# on one); without cat, the builtin read takes the same bytes, one at a time.
if ! input=$(cat 2>/dev/null); then  # swallow-ok: a failed cat leaves stdin unread for the builtin read below
    input=""
    IFS= read -r -d '' input || true  # swallow-ok: read returns 1 at end of input with no NUL; input holds every byte read
fi

deny() {
    local pr=${2:-"<PR>"} primary here common msg reason
    here=${BASH_SOURCE[0]%/*}
    [ "$here" != "${BASH_SOURCE[0]}" ] || here=.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
        GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""  # swallow-ok: no git answer names the primary checkout as a placeholder in the deny text; the deny still happens
    primary=${common%/.git}
    [ -n "$common" ] && [ -d "$primary/scripts" ] || primary="<primary checkout>"
    msg="guard-judge-write-scope: $1. A judge-ro writes one evidence file and nothing else: make its dir with
    bash $primary/scripts/judge-dir.sh $pr
then Write <that dir>/evidence.md (one .md or .txt file directly in it), then run the write-verdict.sh line as its own
command. Report a refused write in your reply; never re-spell it. Bypass (single run, set in the launching shell):
JUDGE_WRITE_SCOPE_OK=1"
    if command -v jq >/dev/null 2>&1 && reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null); then  # swallow-ok: a failed encode falls to the fixed deny text below; the deny still happens
        :
    else
        reason='"guard-judge-write-scope: a judge-ro write outside a judge dir is refused. Bypass: JUDGE_WRITE_SCOPE_OK=1 in the launching shell"'
    fi
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

raw_names_judge() { case "$input" in *judge-ro*) return 0 ;; esac; return 1; }

command -v jq >/dev/null 2>&1 || { raw_names_judge && deny "jq is not on PATH, so a payload naming judge-ro cannot be scoped"; exit 0; }

# Each field is prefixed with x so @tsv never yields an empty field; @tsv escapes a tab, newline or backslash, so a
# path holding one carries a backslash and fails the path match below.
fields=$(printf '%s' "$input" | jq -r '
    [ "x" + (if (.agent_type | type) == "string" then .agent_type else "" end),
      "x" + (if (.agent_id | type) == "string" and .agent_id != "" then "1" else "0" end),
      "x" + (if (.tool_name | type) == "string" then .tool_name else "" end),
      "x" + ((.tool_input.file_path // .tool_input.notebook_path // "") | if type == "string" then . else "" end)
    ] | @tsv' 2>/dev/null) || fields=""
case "$fields" in
    *$'\n'*) fields="" ;;
esac
case "$fields" in
    x*$'\t'x*$'\t'x*$'\t'x*) ;;
    *) raw_names_judge && deny "the payload names judge-ro but cannot be parsed"; exit 0 ;;
esac
agent_type=${fields%%$'\t'*}; rest=${fields#*$'\t'}
has_aid=${rest%%$'\t'*}; rest=${rest#*$'\t'}
tool=${rest%%$'\t'*}
path=${rest#*$'\t'}
agent_type=${agent_type#x}; has_aid=${has_aid#x}; tool=${tool#x}; path=${path#x}

case "$agent_type" in
    judge-ro|*:judge-ro) ;;
    '')
        [ "$has_aid" != 1 ] || deny "a subagent payload (agent_id set) with no agent_type cannot be scoped, so its $tool is refused"
        exit 0
        ;;
    *) exit 0 ;;
esac

[ "$tool" = Write ] || deny "judge-ro may use Write only, for its one evidence file; $tool is refused"

uid=$(id -u 2>/dev/null) || uid=""  # swallow-ok: an empty uid is denied on the next line
case "$uid" in ''|*[!0-9]*) deny "the hook cannot read this uid" ;; esac
root="/tmp/claude-$uid"
[[ $path =~ ^/tmp/claude-$uid/(j([0-9]+)[a-z]?)/[A-Za-z0-9][A-Za-z0-9._-]*\.(md|txt)$ ]] \
    || deny "$path is not one .md or .txt file directly in a judge dir $root/j<PR>[a-z]"
jd_name=${BASH_REMATCH[1]}
pr=${BASH_REMATCH[2]}
jd="$root/$jd_name"

if [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ]; then
    deny "$root is not a directory this uid owns (or is a symlink)" "$pr"
fi
mode=$(stat -c %a "$root" 2>/dev/null) || mode=$(stat -f %Lp "$root" 2>/dev/null) || mode=""  # swallow-ok: an unread mode is not 700, so the write is denied
modestr=$(ls -ld "$root" 2>/dev/null) || modestr=""  # swallow-ok: an unread mode string fails the match below, so the write is denied
modestr=${modestr%%[[:space:]]*}
[[ $modestr =~ ^d[-rwxsStT]{9}[.@]?$ ]] || mode=unreadable
[ "$mode" = 700 ] || deny "$root is accessible to group or other users (want 0700)" "$pr"

if [ -L "$jd" ] || [ ! -d "$jd" ] || [ ! -O "$jd" ]; then
    deny "$jd is not a judge dir this uid owns (or is a symlink)" "$pr"
fi
if [ -L "$jd/.holder" ] || [ ! -f "$jd/.holder" ] || [ ! -s "$jd/.holder" ]; then
    deny "$jd has no .holder from judge-dir.sh" "$pr"
fi
if [ -e "$jd/.verdict-written" ] || [ -L "$jd/.verdict-written" ]; then
    deny "$jd is released by a written verdict; make a fresh judge dir with another suffix" "$pr"
fi
if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    deny "$path exists and is not a regular file (or is a symlink)" "$pr"
fi
exit 0
