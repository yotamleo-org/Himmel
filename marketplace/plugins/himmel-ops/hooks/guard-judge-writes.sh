#!/usr/bin/env bash
# guard-judge-writes.sh — PreToolUse hook (matcher
# "Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*").
#
# A chief judge only advises: it reads, writes its verdict, appends Results
# bullets to its own doc, and reports by SendMessage. headed-arm-worker.sh --judge
# exports HIMMEL_CONSOLE_JUDGE=1 into the judge session; this guard denies that
# session every outward or mutating transition a judge has no business making.
#
# Delivered by the himmel-ops PLUGIN lane, not the project lane: a judge's cwd
# is its resume_cwd under ~/.cache/himmel/verdicts/<qid>/scratch, outside any
# checkout, so project settings (and a $CLAUDE_PROJECT_DIR-anchored hook) never
# load there. The plugin copy is byte-identical to this file and sources
# nothing, for the same reason.
#
# Platform guard: any POSIX bash 3.2+. The judge lane
# (headed-arm-worker.sh --judge) is Linux-only.
#
# TRIP CONDITION: HIMMEL_CONSOLE_JUDGE=1 in this process's environment AND one
# of:
#   Bash (a command word matches bare or as a path's last component, so
#     /usr/bin/git is git) — the command text names HIMMEL_CONSOLE_JUDGE (an
#     override or unset of the marker); or names worker-pr-open, merge-on-green, chief-kit/go.sh,
#     inbox-send or worker-jira-status; or has the word "git" and a mutating git
#     verb (push, commit, merge, rebase, reset, cherry-pick, revert); or the
#     word "gh" and a write verb (create, comment, review, merge, edit, close,
#     reopen, ready, delete, lock, unlock, transfer); or "gh api" with a
#     method or body flag (-X, --method, -f, -F, --field, --raw-field,
#     --input); or the Jira CLI (a word ending in "jira" or naming
#     scripts/jira/) with a write op (create, comment, transition, update,
#     edit, assign, link, delete, worklog, attach); or a package fetch (below).
#   Package fetch, ALSO with the marker unset when the payload's agent_type is
#     judge or judge-ro (bare or plugin-namespaced: an in-process judge
#     subagent) — Bash only, and only this check: the word bunx, npx or uvx;
#     an "npm" or "bun" word whose next word (past -v, --version, -h, --help)
#     is off its read-only list in first_off_list's callers; "uv" with tool,
#     or with run and a --with flag or a single-dash flag group holding w;
#     "pip"/"pip3" with install or download; "cargo" with install.
#   mcp__* — any MCP tool other than qmd (mcp__qmd__*, mcp__plugin_qmd_qmd__*).
#   Write|Edit|MultiEdit|NotebookEdit — the path is relative or has a ".."
#     segment; or it cannot be resolved (readlink -f, then parent + missing
#     leaf); or the RESOLVED path is outside every allowed place:
#       - $HOME/.cache/himmel/verdicts/ (the judge's scratch),
#       - /tmp/claude-<uid>/ (judge-dir.sh's j<PR> scratch, the session scratchpad),
#       - under $HANDOVER_DIR but not inside any inbox/ there: only
#         verdicts/$HIMMEL_CONSOLE_JUDGE_QID/ and the one file
#         $HIMMEL_CONSOLE_JUDGE_DOC (headed-arm-worker.sh --judge exports
#         both). An unset or malformed binding allows nothing under the root.
#     With HANDOVER_DIR unset only the cache and /tmp scratch are allowed.
#     A symlink that does not resolve is denied, never judged by its own path.
#
# DEFAULT ACTION: with the marker unset this hook allows silently unless the
# raw payload text contains "judge"; such a payload is parsed for agent_type.
# With the marker set, or for that payload, it is a SECURITY FENCE and fails
# CLOSED: missing jq, an unparseable payload or a field of the wrong type all
# DENY.
#
# RESIDUAL (deliberate): the Bash checks are textual, over whitespace and
# shell-separator words, not a shell parser — eval, a wrapper script that does
# the write itself, curl to an API, or a write verb this vocabulary does not
# list still pass, and Bash file writes (a redirect, rm/mv/tee/sed -i, an
# interpreter -c) are not screened at all: the structural fix is a
# judge-lane sandbox or permission profile.
#
# BYPASS: launch the session without --judge (the marker is then unset); a
# judge subagent has no bypass. There is no per-call bypass.
#
# Bash 3.2-compatible. Exit codes: 0 allow (no output); 2 deny (JSON
# hookSpecificOutput with permissionDecision "deny" on stdout,
# permissionDecisionReason starting "judge write-deny: ").
# git-env-ok: no git invocation; "git" is only a word matched in the screened command text
set -uo pipefail

input=$(cat 2>/dev/null || true)
subagent_judge=0
if [ "${HIMMEL_CONSOLE_JUDGE:-}" != "1" ]; then
    case "$input" in *judge*) subagent_judge=1 ;; *) exit 0 ;; esac
fi

deny() {
    # deny <rule> <fragment>
    local reason
    reason=$(printf '%s' "judge write-deny: $1 ($2) — a judge reports by SendMessage and writes only its verdict, its own doc and its cache scratch" | jq -Rs . 2>/dev/null) \
        || reason='"judge write-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "unparseable-payload" "jq not on PATH"

[ -n "$input" ] || deny "unparseable-payload" "empty stdin"
if [ "$subagent_judge" = 1 ]; then
    agent_type=$(printf '%s' "$input" | jq -r '.agent_type | select(type == "string") // empty' 2>/dev/null) || deny "unparseable-payload" "cannot parse JSON stdin"  # swallow-ok: an unparseable payload is denied
    case "$agent_type" in
        judge | judge-ro | *:judge | *:judge-ro) ;;
        *) exit 0 ;;
    esac
fi

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    deny "unparseable-payload" "cannot parse JSON stdin"
fi
[ -n "$tool" ] || deny "unparseable-payload" "no tool_name"

# has_word <word>... — true if any listed word is a whole word of $words,
# bare or as the last component of a path (/usr/bin/git counts as git).
has_word() {
    local w t
    for w in "$@"; do
        for t in $words; do
            [ "$t" = "$w" ] && return 0
            [ "${t##*/}" = "$w" ] && return 0
        done
    done
    return 1
}

# resolve <abs-path> — physical path; a missing final component resolves
# through its existing parent. Returns 1 when neither resolves.
resolve() {
    local p="$1" parent leaf r
    # prim-ok: the plugin installs without scripts/lib, so prim.sh is absent; a missing-leaf fallback below needs the raw readlink exit status
    r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
    case "$p" in */) return 1 ;; esac
    # A symlink readlink could not resolve is dangling past a missing parent:
    # its own path says nothing about where a write would land.
    [ -L "$p" ] && return 1
    leaf="${p##*/}"
    parent="${p%/*}"
    [ -n "$parent" ] || parent="/"
    [ -d "$parent" ] || return 1
    # prim-ok: the plugin installs without scripts/lib, so prim.sh is absent; the guard must fail closed with no sourced dependency
    r=$(readlink -f -- "$parent" 2>/dev/null) && [ -n "$r" ] || return 1
    [ "$r" = "/" ] && r=""
    printf '%s\n' "$r/$leaf"
}

# first_off_list <prog> <pattern>... — prints the first word right after a
# <prog> word that matches no <pattern>; a flag there passes only as -v,
# --version, -h or --help, and the word after it is checked the same way, so
# a global flag's value is never read as the subcommand. Prints nothing when
# every <prog> word passes or ends the text.
first_off_list() {
    local prog=$1 t a want=0 ok
    shift
    for t in $words; do
        if [ "$want" = 1 ]; then
            case "$t" in
                -v | --version | -h | --help) continue ;;
                -*) printf '%s\n' "$t"; return 0 ;;
            esac
            want=0
            ok=0
            for a in "$@"; do
                # shellcheck disable=SC2254 # each allowed entry is a glob pattern
                case "$t" in $a) ok=1 ;; esac
            done
            [ "$ok" = 1 ] || { printf '%s\n' "$t"; return 0; }
        fi
        if [ "$t" = "$prog" ] || [ "${t##*/}" = "$prog" ]; then want=1; fi
    done
    return 0
}

package_fetch() {
    local t sub hint="run an installed tool by its own name, or report the check as not run"
    has_word bunx npx uvx && deny "package-fetch" "bunx, npx or uvx: $hint"
    sub=$(first_off_list npm ls list ll la view v info show outdated run run-script test t help prefix root why explain)
    [ -z "$sub" ] || deny "package-fetch" "npm $sub: only npm ls, view, outdated, run and test run in a judge; $hint"
    sub=$(first_off_list bun run test build help '*/*' '*.ts' '*.tsx' '*.js' '*.mjs' '*.cjs')
    [ -z "$sub" ] || deny "package-fetch" "bun $sub: only bun run, test, build and a script file run in a judge; $hint"
    has_word uv && has_word tool && deny "package-fetch" "uv tool: $hint"
    if has_word uv && has_word run; then
        for t in $words; do
            case "$t" in --with* | -[!-]*w* | -w*) deny "package-fetch" "uv run --with: $hint" ;; esac
        done
    fi
    has_word pip pip3 && has_word install download && deny "package-fetch" "pip install or pip download: $hint"
    has_word cargo && has_word install && deny "package-fetch" "cargo install: $hint"
    return 0
}

[ "$subagent_judge" = 1 ] && [ "$tool" != Bash ] && exit 0

case "$tool" in
    Bash)
        cmd_type=$(printf '%s' "$input" | jq -r '.tool_input.command | type' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command"
        [ "$cmd_type" = "string" ] || deny "unparseable-payload" "command not a string"
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command"

        # Words: split on whitespace and shell separators, quotes dropped.
        words=$(printf '%s' "$cmd" | tr ';|&()<>`"'"'"'\n\t\r' '             ')
        if [ "$subagent_judge" = 1 ]; then
            package_fetch
            exit 0
        fi

        case "$cmd" in
            *HIMMEL_CONSOLE_JUDGE*) deny "marker-override" "command names HIMMEL_CONSOLE_JUDGE" ;;
            *worker-pr-open*) deny "pr-open" "worker-pr-open" ;;
            *merge-on-green*) deny "merge" "merge-on-green" ;;
            *chief-kit/go.sh*) deny "go" "chief-kit/go.sh" ;;
            *inbox-send*) deny "inbox-send" "inbox-send" ;;
            *worker-jira-status*) deny "jira-write" "worker-jira-status" ;;
        esac

        if has_word git && has_word push commit merge rebase reset cherry-pick revert; then
            deny "git-write" "mutating git verb"
        fi
        if has_word gh; then
            has_word create comment review merge edit close reopen ready delete lock unlock transfer \
                && deny "gh-write" "gh write verb"
            if has_word api; then
                for t in $words; do
                    case "$t" in
                        -X* | --method* | -f* | -F* | --field* | --raw-field* | --input*)
                            deny "gh-write" "gh api $t" ;;
                    esac
                done
            fi
        fi
        jira=0
        for t in $words; do
            case "$t" in
                *jira | */scripts/jira/* | scripts/jira/*) jira=1 ;;
            esac
        done
        if [ "$jira" -eq 1 ] && has_word create comment transition update edit assign link delete worklog attach; then
            deny "jira-write" "Jira CLI write op"
        fi
        package_fetch
        exit 0
        ;;
    mcp__qmd__* | mcp__plugin_qmd_qmd__*)
        exit 0
        ;;
    mcp__*)
        deny "mcp" "$tool"
        ;;
    Write | Edit | MultiEdit | NotebookEdit)
        field=file_path
        [ "$tool" = "NotebookEdit" ] && field=notebook_path
        path_type=$(printf '%s' "$input" | jq -r --arg f "$field" '(.tool_input[$f] // .tool_input.file_path) | type' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read path"
        [ "$path_type" = "string" ] || deny "unparseable-payload" "path not a string"
        path=$(printf '%s' "$input" | jq -r --arg f "$field" '.tool_input[$f] // .tool_input.file_path' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read path"

        case "$path" in
            /*) ;;
            *) deny "write-outside" "relative path" ;;
        esac
        case "/$path/" in
            */../*) deny "write-outside" "'..' segment" ;;
        esac
        resolved=$(resolve "$path") || deny "write-outside" "path does not resolve"

        cache=$(resolve "$HOME/.cache/himmel/verdicts") || cache="$HOME/.cache/himmel/verdicts"
        case "$resolved" in
            "$cache"/*) exit 0 ;;
        esac
        # judge-dir.sh's /tmp/claude-<uid>/j<PR> scratch and the session
        # scratchpad.
        tmpscratch=$(resolve "/tmp/claude-$(id -u 2>/dev/null)") || tmpscratch=""
        if [ -n "$tmpscratch" ]; then
            case "$resolved" in
                "$tmpscratch"/*) exit 0 ;;
            esac
        fi
        if [ -n "${HANDOVER_DIR:-}" ]; then
            root=$(resolve "$HANDOVER_DIR") || deny "write-outside" "handover root does not resolve"
            # The launched judge's own doc and qid: headed-arm-worker.sh
            # --judge exports both. A missing or malformed binding allows nothing
            # under the handover root.
            own_doc=""
            case "${HIMMEL_CONSOLE_JUDGE_DOC:-}" in
                /*) own_doc=$(resolve "$HIMMEL_CONSOLE_JUDGE_DOC") || own_doc="" ;;
            esac
            own_qid="${HIMMEL_CONSOLE_JUDGE_QID:-}"
            case "$own_qid" in
                "" | *[!A-Za-z0-9._-]* | . | ..) own_qid="" ;;
            esac
            case "$resolved" in
                "$root"/inbox/* | "$root"/*/inbox/*) ;;
                "$root"/*/verdicts/* | "$root"/verdicts/*)
                    if [ -n "$own_qid" ]; then
                        case "$resolved" in
                            "$root"/*/verdicts/"$own_qid"/* | "$root"/verdicts/"$own_qid"/*) exit 0 ;;
                        esac
                    fi
                    ;;
                "$root"/*-judge-*.md)
                    if [ -n "$own_doc" ] && [ "$resolved" = "$own_doc" ]; then
                        case "${resolved##*/}" in
                            *-judge-*.md) exit 0 ;;
                        esac
                    fi
                    ;;
            esac
        fi
        deny "write-outside" "$resolved"
        ;;
esac
exit 0
