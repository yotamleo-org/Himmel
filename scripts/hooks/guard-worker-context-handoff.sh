#!/usr/bin/env bash
# guard-worker-context-handoff.sh — PreToolUse hook (matcher "*") and PreCompact
# hook: a chief-spawned worker that was launched with the guard ON, once past its
# context threshold, is denied every NON-hand-off tool call, and its
# auto-compaction is refused, until it has checkpointed or handed off
#. Its job: a pushed checkpoint before a lossy compaction.
# OFF BY DEFAULT (operator ruling 2026-10-07): workers auto-compact
# anyway, so the guard runs only when the launch turned it on - by flag, env, or
# a worker profile that sets one for a native-lane claude-sonnet-5 launch
# (worker-impl hands off, worker-eval compacts). Reference:
# docs/internals/worker-context-guard.md.
#
# Scope: a chief-spawned worker only — HIMMEL_CONSOLE_LEG=1 AND a non-empty
# HIMMEL_CONSOLE_NAME, both exported by headed-arm-worker.sh.
# Anything else returns at once with no output. The worker's
# in-process subagents (a non-empty string agent_id) are exempt.
#
# Two modes, HIMMEL_WORKER_SESSION_CONTEXT_MODE, set at launch by
# `headed-arm-worker.sh --context-guard compact|handoff` and read only from this
# hook's own process env, so a worker cannot flip it mid-session (an export or a
# per-call prefix never reaches a hook process). Unset, empty or `none` = the
# guard is off (exit 0, no output); any other unknown value is compact, with
# one stderr line (someone asked for the guard).
#   compact  unlock = a `CHECKPOINT <full sha> pushed` Results bullet
#            whose sha is the worktree's HEAD and equals its upstream, or a
#            `CHECKPOINT <full sha> clean` bullet whose sha is HEAD while the
#            tree is clean and nothing is unpushed (HEAD = its upstream, or
#            HEAD is in origin/main); the session then compacts at its
#            ceiling and carries on.
#   handoff  unlock = a RESUME doc for this worker (the worker stops; a successor
#            resumes from the doc).
# In both modes a last marker of WRAPPED frees the worker. A last marker of
# BLOCKED frees only the hand-off calls and reads (Read, Grep, Glob): BLOCKED
# is a hand-off to the chief, not an unlock (N1383 wrote BLOCKED and then
# went on editing), and while it is the last marker neither
# unlock above reopens ordinary work; a saved state still lets PreCompact pass.
#
# The threshold is 75 % of the worker's autocompact ceiling, not of the model
# window: an opus worker launched with --autocompact 200000 reports a 1000000-token
# window, so the ceiling sits at 20 % fill and a flat % of the window never
# fired. Ceiling = CLAUDE_CODE_AUTO_COMPACT_WINDOW if numeric (it outranks the
# flag), else HIMMEL_WORKER_SESSION_AUTOCOMPACT (the launcher's resolved --autocompact;
# unset = the 200000 pin, `auto` = the window), clamped to the window. The share
# is HIMMEL_WORKER_SESSION_CONTEXT_SHARE (1-100, launch env only; anything else = 75).
# 75 % of 200000 is 150000 tokens (15 % fill on a 1M window). Compactions were
# observed firing from 157k of a 200k ceiling (157k-176k over 349
# compactions), so 75 % leaves 7000 tokens (3.5 pp of the ceiling) before the
# earliest one for commit + push + the CHECKPOINT bullet. The deny must land
# BEFORE the earliest compaction: a higher share (85 % = 170000) would let a
# compaction fire first and be refused blind (ruling 2026-10-07). 65 % (130000)
# left 27000 but stopped every opus worker at 13 % fill. More headroom than 7000
# comes from a higher launcher ceiling, an operator decision.
#
# The decision (PreToolUse), in order:
#   1. fill = scripts/context-fill.sh --percent on the hook's transcript_path.
#      Below the threshold -> allow.
#   2. A hand-off call -> allow, always: Write/Edit/MultiEdit of a *-RESUME.md,
#      SendMessage, ListAgents (the preface's name check before a send),
#      ToolSearch (SendMessage is a deferred tool), TaskStop (the wrap reaps
#      background tasks), the four mail reads (mcp__himmel-bus__read, its
#      plugin-prefixed form, ReadNotifications, FetchInboxMessage; exact names), and a bare `bash <...>/append-results.sh`,
#      `queue-lock.sh release`, `wrap-subtree-check.sh` or `context-fill.sh`,
#      a bare `git [-C <dir>] add|commit|push|status|rev-parse`, and a bare
#      `cd [<dir>]` (a worker whose cwd drifted is checked against the wrong HEAD).
#   3. The worker's own doc is the `.md` path named in the transcript's first user
#      turn — the launcher's `load <brief> and continue`. Its last marker
#      WRAPPED -> allow; BLOCKED -> allow a Read, Grep or Glob only.
#   4. The mode's unlock holds -> allow. A RESUME doc is a candidate when it sits
#      beside the doc, is not the doc itself, carries the doc's worker id (letter +
#      digits) with any one-letter suffix, and was modified after this session's
#      first user turn — so an older link of the same chain never counts. In handoff
#      mode the unlock holds only when every candidate passes the primary checkout's
#      brief-lint.sh (exit 0 pass, 1 fixable, other stuck; one 6 s / 3 s budget per
#      call), and an `append-results.sh` call is denied while a linted candidate is
#      fixable. A CHECKPOINT counts from the doc's newest CHECKPOINT bullet only.
#   5. Otherwise deny, naming the mode, the fill and exactly what unlocks it.
# PreCompact: a manual /compact passes; an auto one past the threshold passes
# only on steps 3-4, with EITHER unlock (a CHECKPOINT or a RESUME doc).
#
#
# Bypass: WORKER_SESSION_CONTEXT_HANDOFF_OK=1 (a falsy value keeps the guard on)
# in the launching shell (session-sticky; a per-call prefix does not reach this
# hook process).
#
# Platform guard: env vars, jq, git, stat -c/-f, sed; bash 3.2-safe.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus, for
# PreToolUse, a structured hookSpecificOutput.permissionDecision on stdout —
# same idiom as guard-worker-wakeup.sh; for PreCompact, {"decision":"block"}).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0
[ -n "${HIMMEL_CONSOLE_NAME:-}" ] || exit 0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${WORKER_SESSION_CONTEXT_HANDOFF_OK:-}" in
    ''|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) ;;
    *) exit 0 ;;
esac

CEILING_SHARE=75
share="${HIMMEL_WORKER_SESSION_CONTEXT_SHARE:-}"
case "$share" in
    [1-9]|[1-9][0-9]|100) CEILING_SHARE="$share" ;;
esac
PIN_AUTOCOMPACT=200000
autocompact="${HIMMEL_WORKER_SESSION_AUTOCOMPACT:-$PIN_AUTOCOMPACT}"

warn_allow() {
    printf 'guard-worker-context-handoff: allowing - %s (fail-open)\n' "$1" >&2
    exit 0
}

# True when $1 is ONE command: no newline, no unclosed quote, no $'…' quote,
# no backtick or $( outside single quotes, and no & | ; < > ( ) outside any
# quotes. Quoted
# text stays usable (a bullet's `;`), but nothing can chain, pipe, background,
# redirect or substitute a second command.
is_bare_command() {
    local s=$1 n=${#1} i=0 c q=''
    case "$s" in *"
"*) return 1 ;; esac
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        if [ "$q" = "'" ]; then
            [ "$c" = "'" ] && q=''
        elif [ "$c" = "\\" ]; then
            i=$((i + 1))
        elif [ "$c" = '`' ]; then
            return 1
        elif [ "$c" = '$' ] && [ "${s:$((i + 1)):1}" = '(' ]; then
            return 1
        elif [ -z "$q" ] && [ "$c" = '$' ] && [ "${s:$((i + 1)):1}" = "'" ]; then
            # ANSI-C $'…' lets \' escape, so its end cannot be found this way.
            return 1
        elif [ "$q" = '"' ]; then
            [ "$c" = '"' ] && q=''
        else
            case "$c" in
                "'"|'"') q=$c ;;
                '&'|'|'|';'|'<'|'>'|'('|')') return 1 ;;
            esac
        fi
        i=$((i + 1))
    done
    [ -z "$q" ]
}

# True when $1 (already is_bare_command) is `bash <script> ...` and <script> is,
# as ONE parsed word, bare or "double"/'single' quoted with no $ or backslash,
# an allowed hand-off script. A quoted word may carry spaces, so a
# checkout path with spaces passes; a script after a path that merely ends in
# the allowed name must sit on a path-segment boundary.
is_handoff_script_call() {
    local re rest word
    HANDOFF_SCRIPT=""
    re='^[[:space:]]*bash[[:space:]]+("([^"$\\`]*)"|'"'([^']*)'"'|([^][:space:]"'"'"'$\\`;&|<>()]+))(.*)$'
    [[ $1 =~ $re ]] || return 1
    word="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    rest="${BASH_REMATCH[5]}"
    # The word ends at a space or the end: nothing glued after its closing quote.
    case "$rest" in ''|[[:space:]]*) ;; *) return 1 ;; esac
    case "$word" in
        scripts/handover/console-kit/append-results.sh|*/scripts/handover/console-kit/append-results.sh|scripts/handover/chief-kit/append-results.sh|*/scripts/handover/chief-kit/append-results.sh) ;;
        scripts/handover/wrap-subtree-check.sh|*/scripts/handover/wrap-subtree-check.sh) ;;
        scripts/context-fill.sh|*/scripts/context-fill.sh) ;;
        scripts/handover/queue-lock.sh|*/scripts/handover/queue-lock.sh)
            [[ $rest =~ ^[[:space:]]+release([[:space:]]|$) ]] || return 1
            ;;
        *) return 1 ;;
    esac
    HANDOFF_SCRIPT=${word##*/}
    return 0
}

MODE="${HIMMEL_WORKER_SESSION_CONTEXT_MODE:-}"
case "$MODE" in
    ''|none) exit 0 ;;
    compact|handoff) ;;
    *)
        printf 'guard-worker-context-handoff: unknown HIMMEL_WORKER_SESSION_CONTEXT_MODE %s - using compact\n' "$MODE" >&2
        MODE=compact
        ;;
esac

command -v jq >/dev/null 2>&1 || warn_allow "jq not on PATH"

input=$(cat)
# An in-process subagent (worker, judge call) inherits the worker's env and its
# transcript_path, so it would read the parent's fill and be denied too. It is
# never the one to hand off: exempt it, keyed on a NON-EMPTY STRING agent_id
# (the block-subagent-park.sh idiom; `// empty` would read `false` as absent).
if printf '%s' "$input" | jq -e '(.agent_id | type) == "string" and .agent_id != ""' >/dev/null 2>&1; then
    exit 0
fi
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null) || warn_allow "unparseable hook input"
if [ "$event" = "PreCompact" ]; then
    # An operator's own /compact is never refused.
    [ "$(printf '%s' "$input" | jq -r '.trigger // empty' 2>/dev/null)" = "manual" ] && exit 0
    tool=""
else
    tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || warn_allow "unparseable hook input"
    [ -n "$tool" ] || warn_allow "no tool_name in hook input"
fi
LINT_BUDGET=6
[ "$event" = "PreCompact" ] && LINT_BUDGET=3
handoff_append=0
selfcheck_cmd=""
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    warn_allow "no readable transcript_path, context fill unknown"
fi
wd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$wd" ] && [ -d "$wd" ] || wd="$PWD"

fill=$(CONTEXT_FILL_TRANSCRIPT="$transcript" bash "$HERE/../context-fill.sh" --percent 2>/dev/null)
fill_rc=$?
case "$fill_rc:$fill" in
    0:[0-9]|0:[0-9][0-9]|0:100) ;;
    3:*) warn_allow "context fill STALE (context-fill.sh rc 3)" ;;
    *) warn_allow "context fill UNKNOWN (context-fill.sh rc $fill_rc)" ;;
esac

# --- the threshold, as a % of the window, from the autocompact ceiling ------
snap=$(CONTEXT_FILL_TRANSCRIPT="$transcript" bash "$HERE/../context-fill.sh" --cache-path 2>/dev/null)
window=$(jq -r '.context_window_size // empty | floor' "$snap" 2>/dev/null)
case "$window" in ''|*[!0-9]*|0) window="" ;; esac
ceiling=""
case "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" in
    ''|*[!0-9]*) ;;
    *) ceiling="$CLAUDE_CODE_AUTO_COMPACT_WINDOW" ;;
esac
if [ -z "$ceiling" ]; then
    case "$autocompact" in
        auto) ceiling="$window" ;;
        ''|*[!0-9]*)
            printf 'guard-worker-context-handoff: HIMMEL_WORKER_SESSION_AUTOCOMPACT %s is not a token count - using the window (fail-open)\n' \
                "$autocompact" >&2
            ceiling="$window"
            ;;
        *) ceiling="$autocompact" ;;
    esac
fi
if [ -n "$window" ] && [ -n "$ceiling" ] && [ "$ceiling" -gt 0 ]; then
    [ "$ceiling" -gt "$window" ] && ceiling="$window"
    threshold=$(( (CEILING_SHARE * ceiling + window - 1) / window ))
    basis="${CEILING_SHARE} % of the ${ceiling}-token autocompact ceiling on a ${window}-token window"
else
    # No window in the snapshot: the fill cannot be turned into tokens.
    threshold=$CEILING_SHARE
    basis="${CEILING_SHARE} % of the window (window size unknown)"
fi
[ "$fill" -ge "$threshold" ] || exit 0

# --- hand-off calls always pass -------------------------------------------
case "$tool" in
    SendMessage|ListAgents|ToolSearch|TaskStop) exit 0 ;;
    # The mail reads, by exact name and read-only. The idle waker keeps
    # typing "read them now" while mail sits unread; a denied read let it do so for hours.
    mcp__himmel-bus__read|mcp__plugin_himmel-bus_himmel-bus__read|ReadNotifications|FetchInboxMessage) exit 0 ;;
    Write|Edit|MultiEdit)
        path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
        case "$path" in *-RESUME.md) exit 0 ;; esac
        ;;
    Bash)
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
        # A bare call only, or a second command rides the allow.
        if is_bare_command "$cmd"; then
            if is_handoff_script_call "$cmd"; then
                if [ "$MODE" = handoff ] && [ "$HANDOFF_SCRIPT" = append-results.sh ]; then
                    handoff_append=1
                else
                    exit 0
                fi
            # WIP add/commit/push, and the status/rev-parse reads a
            # checkpoint needs, so the hand-off leaves nothing uncommitted.
            elif grep -qE '^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(add|commit|push|status|rev-parse)([[:space:]]|$)' <<< "$cmd"; then
                exit 0
            # Back to the worktree: one bare cd, nothing chained after it. The
            # operand is a literal path: bare, "double" or 'single' quoted;
            # a $ or backslash in it (a variable target) is refused.
            elif grep -qE "^[[:space:]]*cd([[:space:]]+([^][:space:];&|<>\$\"'\\\\]+|\"[^\"\$\\\\]*\"|'[^']*'))?[[:space:]]*\$" <<< "$cmd"; then
                exit 0
            elif [ "$MODE" = handoff ]; then
                case "$cmd" in "bash "*) selfcheck_cmd=$cmd ;; esac
            fi
        fi
        ;;
esac

# --- this worker's doc, from the launcher's first turn -----------------------
first=$(head -n 400 "$transcript" 2>/dev/null | jq -rc '
    select(.type == "user" and (.isMeta | not))
    | [.timestamp // "", (.message.content
        | if type == "string" then . else ([.[]? | .text? // empty] | join(" ")) end)]
    | @tsv' 2>/dev/null | head -n 1)
started_iso=${first%%	*}
first_text=${first#*	}
doc=$(printf '%s' "$first_text" | grep -oE '/[^[:space:]"'"'"'`]+\.md' | head -n 1)
if [ -z "$doc" ] || [ ! -f "$doc" ]; then
    # the launcher's `load <doc> and continue` names a doc whose
    # path may carry spaces, which the space-free match above truncates.
    spaced=$(printf '%s' "$first_text" | sed -nE 's/^load (\/.*\.md) and continue.*$/\1/p' | head -n 1)
    [ -z "$spaced" ] || doc=$spaced
fi
if [ -z "$doc" ] || [ ! -f "$doc" ] || [ ! -r "$doc" ]; then
    warn_allow "worker handover doc not found or unreadable in the first turn"
fi

blocked=0
tail_lib="$HERE/../lib/worker-tail-status.sh"
# shellcheck source=../lib/worker-tail-status.sh
if { [ -r "$tail_lib" ] && . "$tail_lib"; } 2>/dev/null; then
    case "$(worker_tail_status "$doc")" in
        WRAPPED) exit 0 ;;
        BLOCKED)
            case "$tool" in Read|Grep|Glob) exit 0 ;; esac
            [ "$handoff_append" = 1 ] && exit 0
            blocked=1
            ;;
    esac
fi

# --- compact's unlock: the newest CHECKPOINT bullet names a pushed HEAD, or
# HEAD on a clean tree with nothing unpushed ----------------------------------
checkpoint_ok() {
    local line cp head up porcelain
    # An inherited GIT_DIR/GIT_WORK_TREE would read another repo's HEAD.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    # shellcheck disable=SC2016  # the backticks are literal Markdown
    line=$(grep -E '^- .*CHECKPOINT `?[0-9a-f]{40}`? (pushed|clean)' "$doc" 2>/dev/null | tail -n 1)
    # shellcheck disable=SC2016
    cp=$(printf '%s' "$line" | grep -oE 'CHECKPOINT `?[0-9a-f]{40}' | grep -oE '[0-9a-f]{40}')
    [ -n "$cp" ] || return 1
    head=$(git -C "$wd" rev-parse HEAD 2>/dev/null) || return 1
    [ "$cp" = "$head" ] || return 1
    up=$(git -C "$wd" rev-parse '@{u}' 2>/dev/null) || up=""
    # shellcheck disable=SC2016
    if grep -qE 'CHECKPOINT `?[0-9a-f]{40}`? pushed' <<< "$line"; then
        [ -n "$up" ] && [ "$up" = "$head" ]
        return
    fi
    # `clean`: a worker that has only read has nothing to commit, and
    # the pre-push CR gate refuses an empty push (N1386). It needs a clean tree
    # and nothing unpushed: HEAD is its upstream, or HEAD is already in
    # origin/main (a fresh branch at its base).
    porcelain=$(git -C "$wd" status --porcelain 2>/dev/null) || return 1
    [ -z "$porcelain" ] || return 1
    [ -n "$up" ] && [ "$up" = "$head" ] && return 0
    git -C "$wd" merge-base --is-ancestor HEAD refs/remotes/origin/main 2>/dev/null
}

# --- handoff's unlock: a RESUME doc written by this session -----------------
dir=$(dirname "$doc")
stem=$(basename "$doc" .md)
started=""
if [ -n "$started_iso" ]; then
    started=$(jq -rn --arg t "$started_iso" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || started=""
fi
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }  # gnu-ok: GNU -c paired with BSD -f on this line

# The worker id is the first `-`-separated part shaped like a letter plus digits.
worker_id=$(printf '%s\n' "$stem" | tr '-' '\n' | grep -E '^[A-Z][0-9]+[a-z]?$' | head -n 1)
worker_base=$(printf '%s' "$worker_id" | sed -E 's/[a-z]$//')
next_stem="${stem%-RESUME}"
no_successor=0
if [ -n "$worker_id" ]; then
    suffix=${worker_id#"$worker_base"}
    case "$suffix" in
        '') next=b ;;
        z) no_successor=1 ;;
        *) next=$(printf '%s' "$suffix" | tr 'a-y' 'b-z') ;;
    esac
    [ "$no_successor" = 1 ] ||
        next_stem=$(printf '%s' "$next_stem" | sed -E "s/(^|-)$worker_id(-|\$)/\\1$worker_base$next\\2/")
fi
want="$dir/$next_stem-RESUME.md"

resume_candidates() {
    local cand m tok TAB
    TAB=$(printf '\t')
    for cand in "$dir"/*-RESUME.md; do
        [ -f "$cand" ] && [ -r "$cand" ] && [ ! -L "$cand" ] || continue
        [ "$cand" = "$doc" ] && continue
        if [ -n "$worker_id" ]; then
            tok=$(basename "$cand" .md | tr '-' '\n' | grep -E "^${worker_base}[a-z]?\$" | head -n 1)
            [ -n "$tok" ] || continue
            # a resumed worker's successor letter moves forward only; past z, the unsuffixed id
            [ -z "$suffix" ] || [[ ${tok#"$worker_base"} > $suffix ]] ||
                { [ "$no_successor" = 1 ] && [ "$tok" = "$worker_base" ]; } || continue
        else
            [ "$cand" = "$want" ] || continue
        fi
        # An unknown session start cannot tell this session's RESUME doc from a
        # stale one, so no doc counts.
        [ -n "$started" ] || continue
        m=$(mtime "$cand") || continue
        [ "$m" -ge "$started" ] || continue
        printf '%s\t%s\n' "$m" "$cand"
    done | sort -t "$TAB" -k1,1nr | cut -f2-
}

qb_lib="$HERE/../lib/qmd-bounded.sh"
csg_lib="$HERE/../lib/chokepoint-seam-guard.sh"
lint_ready=0
lint_path=""
lint_block_reason=""
LINT_ERRF=""
V_CLASS=""; V_PATH=""; V_LINE=""

shell_safe() { local re='^/[A-Za-z0-9._+/-]+$'; [[ $1 =~ $re ]]; }

lint_setup() {
    local primary=""
    [ "$lint_ready" = 1 ] && return 0
    lint_ready=1
    case "${HANDOVER_DIR:-}" in
        /*) [ -d "$HANDOVER_DIR" ] || lint_block_reason="handover root not loadable (HANDOVER_DIR is not a directory)" ;;
        *) lint_block_reason="handover root not loadable (HANDOVER_DIR is not an absolute directory)" ;;
    esac
    if [ -n "${GUARD_CONTEXT_HANDOFF_BRIEF_LINT:-}" ]; then
        lint_path=$GUARD_CONTEXT_HANDOFF_BRIEF_LINT
    else
        # shellcheck source=../lib/chokepoint-seam-guard.sh
        if { [ -r "$csg_lib" ] && . "$csg_lib"; } 2>/dev/null; then
            primary=$(_csg_primary_of "$HERE")
        fi
        [ -z "$primary" ] || lint_path="$primary/scripts/handover/chief-kit/brief-lint.sh"
    fi
    if [ -z "$lint_block_reason" ] && { [ -z "$lint_path" ] || [ ! -f "$lint_path" ]; }; then
        lint_block_reason="brief-lint not found at ${lint_path:-the primary checkout (none resolved)}"
    fi
    # shellcheck source=../lib/qmd-bounded.sh
    if [ -z "$lint_block_reason" ] && ! { [ -r "$qb_lib" ] && . "$qb_lib"; } 2>/dev/null; then
        lint_block_reason="qmd-bounded.sh is unreadable at ${qb_lib}, so the lint cannot be bounded"
    fi
    return 0
}

lint_verdicts() {
    local mode=$1 cands c cls line rc left
    V_CLASS=""; V_PATH=""; V_LINE=""
    cands=$(resume_candidates)
    V_COUNT=0
    [ -n "$cands" ] || return 1
    V_COUNT=1
    lint_setup
    LINT_ERRF=$(mktemp "${TMPDIR:-/tmp}/guard-ctx-lint.XXXXXX") || LINT_ERRF=""
    trap '[ -z "$LINT_ERRF" ] || rm -f "$LINT_ERRF"' EXIT
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        cls=pass; line=""
        if [ -n "$lint_block_reason" ]; then
            cls=stuck; line=$lint_block_reason
        elif [ -z "$LINT_ERRF" ]; then
            cls=stuck; line="no temp file for brief-lint's output"
        else
            left=$(( LINT_BUDGET - SECONDS - 1 ))
            if [ "$left" -lt 1 ]; then
                cls=unlinted; line="the ${LINT_BUDGET} s lint budget ran out before this doc"
            else
                rc=0
                QMD_KILL_GRACE_SECS=1 qmd_bounded "$left" bash "$lint_path" "$c" 2>"$LINT_ERRF" >/dev/null || rc=$?
                line=$(grep -F "brief-lint: $c:" "$LINT_ERRF" | tail -n 1)
                [ -n "$line" ] || line=$(tail -n 1 "$LINT_ERRF")
                line=${line:0:600}
                case "$rc" in
                    0) cls=pass ;;
                    1) cls=fixable; [ -n "$line" ] || line="brief-lint exited 1 with no message" ;;
                    124) cls=stuck; line="brief-lint did not answer in ${left} s" ;;
                    *) cls=stuck; [ -n "$line" ] || line="brief-lint exited $rc with no message" ;;
                esac
            fi
        fi
        [ "$cls" = pass ] && continue
        if [ "$mode" = unlock ] || [ "$cls" = fixable ]; then
            V_CLASS=$cls; V_PATH=$c; V_LINE=$line
            return 0
        fi
    done <<< "$cands"
    return 1
}

handoff_unlock_ok() {
    lint_verdicts unlock && return 1
    [ "$V_COUNT" -gt 0 ]
}

selfcheck_ok() {
    local name re='^[A-Za-z0-9._+-]+-RESUME\.md$'
    [ -n "$selfcheck_cmd" ] || return 1
    lint_setup
    shell_safe "$lint_path" && shell_safe "$dir" || return 1
    case "$selfcheck_cmd" in "bash $lint_path $dir/"*) ;; *) return 1 ;; esac
    name=${selfcheck_cmd#"bash $lint_path $dir/"}
    [[ $name =~ $re ]]
}

selfcheck_ok && exit 0
if [ "$event" = "PreCompact" ]; then
    checkpoint_ok && exit 0
    if [ "$MODE" = "handoff" ]; then
        handoff_unlock_ok && exit 0
    else
        [ -n "$(resume_candidates)" ] && exit 0
    fi
elif [ "$blocked" = 1 ]; then
    # BLOCKED is a hand-off: neither unlock reopens ordinary work after it.
    :
elif [ "$MODE" = "compact" ]; then
    checkpoint_ok && exit 0
elif [ "$handoff_append" = 1 ]; then
    lint_verdicts blocked || exit 0
else
    handoff_unlock_ok && exit 0
fi

# Display routing follows the worker's own accepted succession chain, not the
# launch environment's retired chief. Like succession-tracker.sh it reads Results
# to EOF, since append-results.sh writes at EOF; the strict bullet grammar below
# keeps a quoted or mirrored ruling from changing the hint.
# shellcheck disable=SC2016  # literal Markdown backticks in strict handshake grammar
current_chief=$(awk -v chief="$HIMMEL_CONSOLE_NAME" '
    BEGIN { retired[chief] = 1 }
    /^## Results([[:space:]]|$)/ { seen = 1; next }
    seen && /^- ([0-9][0-9]:[0-9][0-9] )?(LIVE — )?SUCCESSION accepted: (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+) replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)[[:space:]]*$/ {
        sub(/^.*SUCCESSION accepted: /, ""); gsub(/`/, "")
        split($0, words, /[[:space:]]+/)
        # the newest acceptance wins: any name already in the chain can be replaced, so a correction
        # overrides an earlier one and a chained replacement still resolves to the newest chief
        if (words[3] in retired) { retired[words[1]] = 1; chief = words[1] }
    }
    END { print chief }
' "$doc") || current_chief="$HIMMEL_CONSOLE_NAME"

allowed="SendMessage, ListAgents, ToolSearch, TaskStop, the mail reads (mcp__himmel-bus__read, ReadNotifications, FetchInboxMessage), append-results.sh, queue-lock.sh release, wrap-subtree-check.sh, context-fill.sh, git add/commit/push/status/rev-parse, a bare cd"
commit_form='A commit is one line (a newline in the command is denied): git commit -m "<subject>" -m "<body>" --trailer "Platforms tested: <os>" --trailer "Security reviewed: <token> - <what>".'
stuck_note="If you cannot push or commit (a moved upstream, a refused attestation or pre-commit gate), do not work around it: SendMessage your chief ${current_chief} what blocks you, then bash scripts/handover/chief-kit/append-results.sh '${doc}' \"BLOCKED — <why>\" and stop. BLOCKED frees only these hand-off calls and reads (Read, Grep, Glob), not your work; WRAPPED (after the merge) frees everything."
mode_note="The mode is set at launch by the chief (HIMMEL_WORKER_SESSION_CONTEXT_MODE); it cannot be changed in-session."
bypass_note="Bypass: WORKER_SESSION_CONTEXT_HANDOFF_OK=1 in the launching shell."
if [ "$MODE" = "compact" ]; then
    deny_msg="worker context checkpoint (mode compact): this session is at ${fill} % context fill (threshold ${threshold} % = ${basis}). Ordinary tool calls stay denied until you checkpoint. Do exactly this: 1) git add and git commit your WIP, then git push. ${commit_form} 2) git rev-parse HEAD. 3) bash scripts/handover/chief-kit/append-results.sh '${doc}' \"LIVE — CHECKPOINT <full sha of HEAD> pushed\". 4) Carry on with your work: the session compacts at its ceiling and continues. A new commit after the checkpoint needs a push and a fresh CHECKPOINT bullet. Nothing to commit and nothing unpushed (git status clean, HEAD on its upstream or in origin/main)? Skip 1 and write \"LIVE — CHECKPOINT <full sha of HEAD> clean\" instead. ${stuck_note} Still allowed meanwhile: ${allowed}. ${mode_note} ${bypass_note}"
else
    if [ "$no_successor" = 1 ]; then
        write_to="a new *-RESUME.md in ${dir} that is not ${doc}, whose name carries the worker id ${worker_base} with no suffix (the worker id ${worker_id} ends in z, so no successor suffix exists)"
    else
        write_to="${want}"
    fi
    step1a=""
    name_re='^[A-Za-z0-9._+-]+-RESUME\.md$'
    want_name=${want#"$dir"/}
    lint_setup
    if [ "$no_successor" != 1 ] && shell_safe "$lint_path" && shell_safe "$dir" && [[ $want_name =~ $name_re ]]; then
        step1a=" 1a) Check it: bash ${lint_path} ${want} (the one extra call allowed)."
    fi
    deny_msg="worker context hand-off (mode handoff): this session is at ${fill} % context fill (threshold ${threshold} % = ${basis}). Ordinary tool calls stay denied until you hand off. Do exactly this: 1) Write your resume brief to ${write_to} (ticket, branch, worktree, committed-vs-dirty, PR/CR state, remaining ordered steps). Copy the > **Prior art:** line and its > continuation lines from ${doc} verbatim, and keep description: and an absolute resume_cwd: in its front matter: the hand-off and the chief's launch both run brief-lint on it.${step1a} 2) SendMessage your chief ${current_chief}: context ${fill} %, RESUME at that path. 3) bash scripts/handover/chief-kit/append-results.sh '${doc}' \"BLOCKED — context ${fill} %, RESUME written: <path>\". 4) Stop. Still allowed meanwhile: ${allowed}. ${commit_form} ${mode_note} ${bypass_note}"
fi

lint_deny=""
case "$V_CLASS" in
    fixable)
        lint_deny="worker context hand-off [lint: fixable]: your RESUME doc ${V_PATH} fails brief-lint, so it cannot be launched: ${V_LINE}. Fix it with Edit (allowed), e.g. copy the > **Prior art:** line and its > continuation lines from ${doc}, then append your BLOCKED bullet again."
        ;;
    stuck|unlinted)
        lint_deny="worker context hand-off [lint: ${V_CLASS}]: brief-lint could not pass ${V_PATH} (${V_LINE}). You cannot clear this: put this reason in your BLOCKED bullet for your chief ${current_chief} and stop."
        ;;
esac
[ -z "$lint_deny" ] || deny_msg="${lint_deny} ${deny_msg}"

if [ "$event" = "PreCompact" ]; then
    if [ -n "$lint_deny" ]; then
        deny_msg="refusing auto-compaction: ${deny_msg}"
    else
        deny_msg="refusing auto-compaction: no CHECKPOINT or RESUME yet. ${deny_msg}"
    fi
    reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) || reason='"worker context guard: checkpoint before compacting"'
    printf '{"decision":"block","reason":%s}\n' "$reason"
else
    reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
        || reason='"worker context guard: past the context threshold - checkpoint or hand off"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
fi
printf '%s\n' "$deny_msg" >&2
exit 2
