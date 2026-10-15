#!/usr/bin/env bash
# tracker-jira.sh — Jira backend for the tracker seam.
# Sourced by tracker.sh; not run directly. Every op shells out to ${JIRA_CMD},
# the general Jira test seam this file owns: default
# `node <primary checkout>/scripts/jira/dist/index.js` (an untracked build
# artifact a worktree lacks, so it is resolved from the git common dir), so
# every op is replayable from scripts/lib/fixtures/tracker/jira/.

_TRACKER_JIRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _tracker_jira_run <op> [args...] — run the CLI; stdout is the CLI's. JIRA_CMD
# is a command line and is word-split on purpose; the default path is passed as
# one quoted word so a primary checkout containing spaces still works.
_tracker_jira_run() {
    local common
    if [ -n "${JIRA_CMD:-}" ]; then
        # shellcheck disable=SC2086
        $JIRA_CMD "$@"
        return $?
    fi
    common=$(git -C "$_TRACKER_JIRA_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
        echo "tracker(jira): cannot locate the Jira CLI (set JIRA_CMD)" >&2
        return 1
    }
    node "$(dirname "$common")/scripts/jira/dist/index.js" "$@"
}

_tracker_jira_id_pattern() { project_mode_id_pattern; }

_tracker_jira_id_new() {
    local type="$1" title="$2" body="${3:-}" out key
    if [ -n "$body" ]; then
        out=$(_tracker_jira_run create --type "$type" --title "$title" --desc-file "$body") || return 1
    else
        out=$(_tracker_jira_run create --type "$type" --title "$title") || return 1
    fi
    key=$(printf '%s\n' "$out" | sed -n 's/^Created \([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$key" ] || { echo "tracker(jira): create printed no 'Created <KEY>' line" >&2; return 1; }
    printf '%s\n' "$key"
}

# _tracker_jira_get <id> — normalised JSON. rc 3 when the issue is absent, rc 1 when the CLI itself failed.
_tracker_jira_get() {
    local raw err msg line
    # ponytail: a signal mid-call leaks this temp file (a trap here would clobber the caller's INT/TERM traps), upgrade by saving and restoring the caller's traps when a consumer (WP3a/WP3b/WP9) installs its own around tracker calls
    err=$(mktemp "${TMPDIR:-/tmp}/tracker-jira-err.XXXXXX") || return 1
    if ! raw=$(_tracker_jira_run get "$1" --json 2>"$err"); then
        msg=$(cat "$err" 2>/dev/null); rm -f "$err"
        # absent only on the CLI's own `jira: get <KEY> failed: HTTP 404: <body>` line (get.ts) whose body
        # is JSON whose errorMessages array has an "Issue does not exist" entry (any case); a bare 404 or a proxy's HTML
        # "Not Found" body is a failure (rc 1), not absence
        while IFS= read -r line; do
            case "$line" in
                "jira: get $1 failed: HTTP 404: "*)
                    # parse the body: an errorMessages ENTRY must say it, not any substring of any field
                    if printf '%s' "${line#"jira: get $1 failed: HTTP 404: "}" | node -e 'let s="";process.stdin.on("data",d=>{s+=d}).on("end",()=>{try{const m=JSON.parse(s).errorMessages;process.exit(Array.isArray(m)&&m.some(x=>/issue does not exist/i.test(String(x)))?0:1)}catch{process.exit(1)}})'; then
                        return 3
                    fi ;;
            esac
        done <<EOF_MSG
$msg
EOF_MSG
        printf '%s\n' "tracker(jira): get $1 failed: $msg" >&2
        return 1
    fi
    rm -f "$err"
    printf '%s' "$raw" | node "$_TRACKER_JIRA_DIR/tracker.mjs" normalize-jira
}

_tracker_jira_title() {
    local j
    j=$(_tracker_jira_get "$1") || return $?
    printf '%s' "$j" | node "$_TRACKER_JIRA_DIR/tracker.mjs" field title
}

_tracker_jira_transition() {
    local id="$1" target="$2" back=0 j cur
    [ "${3:-}" = --allow-back ] && back=1
    j=$(_tracker_jira_get "$id") || return $?
    cur=$(printf '%s' "$j" | node "$_TRACKER_JIRA_DIR/tracker.mjs" field status)
    _tracker_should_move "$cur" "$target" "$back" || return 0
    _tracker_jira_run transition "$id" "$target" >/dev/null || return 1
}

_tracker_jira_comment() {
    _tracker_jira_run comment "$1" --comment-file "$2" >/dev/null
}

# _tracker_jira_link <id> <target> — an issue key becomes a Jira link; a URL or a
# path becomes a comment (the CLI has no remote-link op).
_tracker_jira_link() {
    local f rc
    case "$2" in
        [A-Za-z]*-[0-9]*)
            case "$2" in *[!A-Za-z0-9-]*) ;; *) _tracker_jira_run link "$1" "$2" >/dev/null; return $? ;; esac
            ;;
    esac
    f=$(mktemp "${TMPDIR:-/tmp}/tracker-link.XXXXXX") || return 1
    printf 'Link: %s\n' "$2" > "$f"
    _tracker_jira_run comment "$1" --comment-file "$f" >/dev/null; rc=$?
    rm -f "$f"
    return $rc
}

# _tracker_jira_query [field=value ...] — JQL scoped to the resolver's project
# key (never a hardcoded one), printed as <id> TAB <status> TAB <title>.
_tracker_jira_query() {
    local jql="project = ${JIRA_PROJECT_KEY:-}" a v
    for a in "$@"; do
        v="${a#*=}"
        case "$a" in
            status=*) jql="$jql AND status = \"$v\"" ;;
            fix_version=*) jql="$jql AND fixVersion = \"$v\"" ;;
            epic=*) jql="$jql AND parent = \"$v\"" ;;
        esac
    done
    local out rows
    out=$(_tracker_jira_run list --jql "$jql" --limit 100) || return 1
    rows=$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 4 { print $1 "\t" $3 "\t" $4 }')
    [ -z "$rows" ] || printf '%s\n' "$rows"
    # the CLI lists one page: say so when it is full, the local backend has no cap
    if [ "$(printf '%s' "$rows" | grep -c .)" -ge 100 ]; then
        echo "tracker(jira): query hit the 100-issue limit; the result may be truncated" >&2
    fi
}
