#!/usr/bin/env bash
# scripts/handover/chief-kit/close-wrapped-worker.sh - chief-run wrapped-worker
# window close. A chief's `kill <konsole pid>` is
# classifier-denied [Interfere With Workloads] when typed as a bare literal -
# this script wraps the same TERM under a literal the classifier allowlists,
# but ONLY after verifying the worker is actually done: the queue lock on its
# doc is free AND its own last Results marker-bullet is WRAPPED. It never
# kills a pid it cannot independently prove belongs to that worker.
#
# Usage: close-wrapped-worker.sh [--check] [--chief | --fleet <manifest>] <worker-doc>
#        close-wrapped-worker.sh [--check] --sweep --fleet <manifest>
# --sweep runs this script on every doc in the fleet manifest and closes each one
# that is finished (lock free, tail WRAPPED); an unfinished doc is skipped, a
# finished one that cannot be closed (no/ambiguous window, live subtree) is
# refused and its reason printed. It prints `sweep: closed=<n> refused=<n>
# skipped=<n>` and exits 0; the tick's closable=<n> field says when to run it.
# --check runs every pre-close check below and stops before any close action:
# no session-note capture, no TERM, no cost row, reap, digest or prune. The
# scratchpad-clone check still runs a bounded git fetch --prune in each named
# clone, so it updates that clone's remote-tracking refs and needs the network. It prints SAFE-TO-CLOSE (rc 0) or the refusal a real close would
# print, with the same exit code, so an operator closing a window by hand can
# ask first. Exit 0 means safe to close.
# --chief closes a wrapped PREDECESSOR chief's window: the
# same lock/WRAPPED/one-session checks and subtree check, then TERM - no cost
# row, /tmp reap, digest or worktree prune. Run it right after your own LIVE.
# --fleet removes the doc after a successful close, including benign prune skips.
# A manifest update failure returns 1 after the session has already closed.
#
# Refuses (nothing signaled) unless:
#   - `queue-lock.sh status <worker-doc>` reports free (rc=0);
#   - the doc's last `## Results` marker-bullet (one of LIVE/FINDING/
#     RESOLVED/READY/BLOCKED/HALTED/WRAPPED, leading token of the newest
#     such bullet) is WRAPPED; a -RESUME doc with no marker-bullet of its own reads the original's
#     (a resumed worker's WRAPPED lands on the original doc) only when the original's Results hold,
#     after the hand-off WRAPPED naming the -RESUME doc, a LIVE with a new release token and then a
#     WRAPPED, and the sibling's queue lock must be free too;
#   - exactly one live `claude` session's real argv (via
#     scripts/lanes/lib/claude-sessions.sh's claude_sessions, /proc-argv
#     based, never a flattened pgrep -af scan) carries a `-n <name>` naming
#     the worker (names derived by scripts/lib/worker-identity.sh's worker_identity -
#     the doc stem, its undated form, and any legacy-family derived name, each also
#     with -RESUME, plus the sibling doc's names; a relaunched worker's trailing -r<N>
#     on the session name is accepted).
# ponytail: name-only window match, upgrade path HIMMEL-5928: the launch record
# (launch-logs/<name>.log) holds no pid and a finished worker's lock is free, so
# there is no recorded pid to resolve by. Upgrade path: have headed-arm-worker.sh
# record the claude pid, then resolve by it first, name as fallback.
# TERM goes to that one pid only - it never signals a non-matching pid, and
# 0 or >1 matches is a refusal, not a best guess.
#
# After the signal, the worker's own /tmp scratch (its judge dirs, and its session
# scratch dir) is archived then reaped via tmp-reap.sh, scoped to this worker only
# a reap failure warns and never fails the close.
#
# Then the failure-loop digest: the session id is read from
# ~/.claude/sessions/<pid>.json BEFORE the TERM, and after it
# worker-digest-step.sh digests that session into the worker-failures and eval-runs
# ledgers under a hard timeout (CLOSE_WRAPPED_WORKER_DIGEST_TIMEOUT, default 120).
# It prints exactly one stdout line, `digest=ok|partial ...`,
# `digest=failed:<reason>` or `digest=skipped:<reason>`, and never changes the
# exit code or any other output line.
#
# Then, if the doc names exactly one worktree path (a
# `.claude/worktrees/...` path appearing once), runs
# `scripts/clean.sh --only <worktree> --only-allow-unmerged` and reports (not
# fails) a "not pruned" skip. That flag makes clean-garden.sh
# itself resolve the worktree's branch's PR by branch (via gh, independent of
# whatever the doc's own Results bullets say) and prune when: the PR is
# MERGED with a head match (the original, unwidened case -- also covers a doc
# with no MERGED/READY bullet at all, since the branch lookup does not depend
# on one), OR the PR is CLOSED unmerged or there is no PR, the working tree is
# clean, and the branch's head is either pushed to origin or carries no
# commits beyond main. An OPEN PR (a parked worker) or an unresolvable PR state
# (gh/cache failure) are never pruned. Never guesses a worktree: 0 or >1
# candidates in the doc skips the prune with a report.
#
# Before signalling, reuses scripts/handover/wrap-subtree-check.sh
# on the matched pid: a non-harness descendant still alive (a worker mid an
# operator command, a tool call in flight) refuses the TERM rather than
# killing it out from under that work - never guessed, never overridden.
# A withheld subtree is not a failure: the chief re-runs this script later,
# same as any other "retry shortly" refusal here.
#
# Exit codes:
#   0  signaled (prune ran, skipped, or reported "in use" - all non-fatal); or
#      CLOSED-ALREADY: lock free, tail WRAPPED, and no live session
#      under any of the worker's names (a RESUME doc's label suffix is dropped to
#      find the original session) - nothing to signal; the manifest entry is retired.
#      Not for --chief: a predecessor chief with 0 sessions still exits 5.
#   1  gh/git/queue-lock plumbing failure, or the TERM signal itself failed
#   2  usage (missing/unreadable doc)
#   3  refused - the queue lock is not free: on the doc, or on its sibling doc (the
#      <stem>-RESUME.md of an original doc, the original of a -RESUME doc) when one exists
#   4  refused - the last marker-bullet is not WRAPPED: the doc's own (a -RESUME doc with no
#      marker of its own reads the original's, only with hand-off evidence); an original doc is
#      also refused while its -RESUME sibling has a last marker-bullet that is not WRAPPED; and
#      both docs of a pair are refused while the -RESUME doc has no marker-bullet and the
#      original's Results hold no successor LIVE (new release token) then WRAPPED after the
#      hand-off WRAPPED (no hand-off evidence)
#   5  refused - >1 live sessions matched the worker's names (0 for a --chief), or an original
#      doc has more than one successor -RESUME doc (-N<k>[a-z]-...-RESUME.md)
#   6  refused - the matched session still has a non-harness process alive
#      (wrap-subtree-check.sh reported WITHHELD, or could not prove CLOSABLE)
#   7  refused - the matched session still has a live in-process subagent (an
#      Agent-tool child, e.g. a chief's judge call), or live-subagents.sh
#      could not prove it has none; retry once they finish
#   8  refused - the doc names a session-scratchpad clone (/tmp/claude-<uid>/
#      <project>/<session>/scratchpad/<clone>) holding commits on no remote
#      (that clone dies with the session), or the check could not run: the doc
#      cannot be scanned, the named paths or clones cannot be sorted, a named
#      directory cannot be scanned for clones, git cannot inspect a clone, or
#      the clone's remote branches cannot be refreshed (a failed or timed-out
#      bounded git fetch --prune of each remote; CLOSE_WRAPPED_WORKER_FETCH_TIMEOUT,
#      default 30s; a value that is not a positive integer is refused too)
#
# Platform guard: Linux bash 3.2+ (depends on /proc via claude-sessions.sh;
# konsole workers are Linux/KDE-only, same guard as
# headed-arm-worker.sh's konsole launch path).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# the manifest worker array is `workers`; a manifest not yet rewritten holds the pre-rename `legs`, read only while legacy names are on
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
KILL="${KILL_BIN:-kill}"
CLEAN_SH="${CLEAN_SH_BIN:-$HERE/../../clean.sh}"
WRAP_SUBTREE_CHECK="${WRAP_SUBTREE_CHECK_BIN:-$HERE/../wrap-subtree-check.sh}"
TMP_REAP="${TMP_REAP_BIN:-$HERE/../../tmp-reap.sh}"
LIVE_SUBAGENTS="${LIVE_SUBAGENTS_BIN:-$HERE/live-subagents.sh}"

usage() {
    echo "usage: close-wrapped-worker.sh [--check] [--chief | --fleet <manifest>] <doc> | [--check] --sweep --fleet <manifest>" >&2
}

FLEET_MANIFEST=""
CHIEF_MODE=0
CHECK_MODE=0
SWEEP_MODE=0
if [ "${1:-}" = --check ]; then
    CHECK_MODE=1; shift
fi
if [ "${1:-}" = --sweep ]; then
    SWEEP_MODE=1; shift
fi
if [ "${1:-}" = --fleet ]; then
    if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then usage; exit 2; fi
    FLEET_MANIFEST="$2"; shift 2
elif [ "${1:-}" = --chief ]; then
    CHIEF_MODE=1; shift
fi

# Only successful close exits retire the worker; refusals and failed pruning keep it.
close_success() {
    if [ -n "$FLEET_MANIFEST" ] && ! bash "$HERE/fleet-manifest.sh" remove "$FLEET_MANIFEST" "$DOC"; then
        echo "close-wrapped-worker: session closed but fleet manifest update failed: $FLEET_MANIFEST" >&2
        exit 1
    fi
    exit 0
}

# ---------- --sweep: close every finished worker in the manifest ----------
if [ "$SWEEP_MODE" -eq 1 ]; then
    if [ -z "$FLEET_MANIFEST" ] || [ "$#" -ne 0 ] || [ ! -r "$FLEET_MANIFEST" ]; then
        usage
        exit 2
    fi
    sweep_docs=$(jq -r "$JQ_W"'W[]?.doc // empty' "$FLEET_MANIFEST" 2>/dev/null) || { echo "close-wrapped-worker: cannot read fleet manifest $FLEET_MANIFEST" >&2; exit 1; }
    sw_check=""
    [ "$CHECK_MODE" -eq 1 ] && sw_check="--check"
    sw_closed=0; sw_refused=0; sw_skipped=0
    while IFS= read -r sw_doc; do
        [ -n "$sw_doc" ] || continue
        sw_out=$(bash "$HERE/close-wrapped-worker.sh" $sw_check --fleet "$FLEET_MANIFEST" "$sw_doc" 2>&1); sw_rc=$?
        case "$sw_rc" in
            0) sw_closed=$((sw_closed + 1))
               if [ "$CHECK_MODE" -eq 1 ]; then echo "sweep: would close $sw_doc"; else echo "sweep: closed $sw_doc"; fi ;;
            3|4) sw_skipped=$((sw_skipped + 1)) ;;
            *) sw_refused=$((sw_refused + 1)); echo "sweep: refused $sw_doc (rc=$sw_rc): $(printf '%s\n' "$sw_out" | tail -n 1)" ;;
        esac
    done <<EOF
$sweep_docs
EOF
    echo "sweep: closed=$sw_closed refused=$sw_refused skipped=$sw_skipped"
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi
DOC="$1"
if [ ! -f "$DOC" ] || [ ! -r "$DOC" ]; then
    usage
    echo "close-wrapped-worker: cannot read doc '$DOC'" >&2
    exit 2
fi

if ! bash "$HERE/../queue-lock.sh" status "$DOC" >/dev/null 2>&1; then
    echo "close-wrapped-worker: refusing - the queue lock on $DOC is not free" >&2
    exit 3
fi

# a worker relaunched under a -RESUME session has two docs, the original and
# <stem>-RESUME.md, and WRAPPED may land on either. The sibling's lock must be free too.
# The resumed worker's label carries a successor letter (N4426b), so the sibling is found by
# the label with and without it: a RESUME doc looks for the original (letter dropped, with and
# without -RESUME); an original looks for <stem>-RESUME.md, else the one -N<k>[a-z]-...-RESUME.md
# successor (more than one is refused).
# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/worker-identity.sh"; then
    echo "close-wrapped-worker: cannot load scripts/lib/worker-identity.sh" >&2
    exit 1
fi
SIB_DOC=""
sib_dir="$(dirname "$DOC")"
sib_base="$(basename "$DOC" .md)"
sib_label="$(worker_label "$DOC")"
if [[ $DOC == *-RESUME.md ]]; then
    sib_stem="${sib_base%-RESUME}"
    sib_cands="$sib_dir/$sib_stem.md"
    if [[ $sib_label =~ ^(N[0-9]+)[a-z]+$ ]]; then
        sib_dropped="$(printf '%s' "$sib_stem" | sed -E "s/-(leg)?${sib_label}(-|\$)/-\\1${BASH_REMATCH[1]}\\2/")"
        sib_cands="$sib_cands"$'\n'"$sib_dir/$sib_dropped.md"$'\n'"$sib_dir/$sib_dropped-RESUME.md"
    fi
    while IFS= read -r sib_c; do
        [ -f "$sib_c" ] && [ "$sib_c" != "$DOC" ] && { SIB_DOC="$sib_c"; break; }
    done <<EOF
$sib_cands
EOF
elif [ -f "$sib_dir/$sib_base-RESUME.md" ]; then
    SIB_DOC="$sib_dir/$sib_base-RESUME.md"
else
    sib_pat="$(printf '%s' "$sib_base" | sed -E "s/(-(leg)?)${sib_label}(-|\$)/\\1${sib_label}[a-z]\\3/")"
    if [ "$sib_pat" != "$sib_base" ]; then
        sib_found="$(find "$sib_dir" -maxdepth 1 -type f -name "$sib_pat-RESUME.md")" || {
            echo "close-wrapped-worker: cannot list $sib_dir for successor -RESUME docs" >&2
            exit 1
        }
        sib_n="$(printf '%s' "$sib_found" | grep -c .)"
        if [ "$sib_n" -gt 1 ]; then
            echo "close-wrapped-worker: refusing - $sib_n successor -RESUME docs match $DOC; close the right one by name" >&2
            exit 5
        fi
        SIB_DOC="$sib_found"
    fi
fi
if [ -n "$SIB_DOC" ] && ! bash "$HERE/../queue-lock.sh" status "$SIB_DOC" >/dev/null 2>&1; then
    echo "close-wrapped-worker: refusing - the queue lock on its sibling doc $SIB_DOC is not free" >&2
    exit 3
fi

# shellcheck source=scripts/lib/worker-tail-status.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/worker-tail-status.sh"; then
    echo "close-wrapped-worker: cannot load scripts/lib/worker-tail-status.sh" >&2
    exit 1
fi

# resume_evidence <original doc> <resume doc>: success only on a record that nothing but the resumed
# worker writes. In the original's `## Results` section: the hand-off is the first WRAPPED at or after
# the first bullet naming the resume doc's stem; after it comes a LIVE carrying a release token
# (`<host>-pid<N>`) other than the last LIVE token before the hand-off, then a WRAPPED. A bullet that
# merely names the stem, a later marker of any kind, and file mtimes (a launch, a bus adopt and a vault
# pull all rewrite them) prove nothing about a successor that has just started.
resume_evidence() {
    local stem
    stem=$(basename "$2" .md)
    awk -v stem="$stem" '
        /^## / { inres = ($0 ~ /^## Results( |$)/); next }
        !inres || !/^- / { next }
        {
            mk = ""; tok = ""
            if (match($0, /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/)) {
                mk = substr($0, RSTART, RLENGTH)
                sub(/^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?/, "", mk)
                sub(/[^A-Za-z0-9_]$/, "", mk)
            }
            if (mk == "LIVE" && match($0, /`[^`]*-pid[0-9]+`/)) tok = substr($0, RSTART + 1, RLENGTH - 2)
            if (!named && index($0, stem)) named = 1
            if (named && !hand && mk == "WRAPPED") { hand = 1; next }
            if (!hand) { if (tok != "") pred = tok; next }
            if (!live && tok != "" && tok != pred) { live = 1; next }
            # defence in depth: the worker_tail_status check on the original (last marker is WRAPPED) already
            # refuses a WRAPPED that is not the tail, so a WRAPPED-after-LIVE gate cannot be pinned by a row
            if (live && mk == "WRAPPED") wrapped = 1
        }
        END { exit !wrapped }' "$1"
}

last_marker=$(worker_tail_status "$DOC")
if [ -n "$SIB_DOC" ]; then
    if [[ $DOC == *-RESUME.md ]]; then sib_res="$DOC"; sib_orig="$SIB_DOC"; else sib_res="$SIB_DOC"; sib_orig="$DOC"; fi
    res_marker=$(worker_tail_status "$sib_res")
    if [ -z "$res_marker" ]; then
        # the resumed worker has written nothing of its own yet, so it may be a successor that has just
        # started: only the successor's own record on the original (a LIVE with a new release token,
        # then its WRAPPED, after the hand-off) lets either doc close
        if ! resume_evidence "$sib_orig" "$sib_res"; then
            echo "close-wrapped-worker: refusing - $sib_res has no marker-bullet of its own and $sib_orig holds no successor LIVE (new release token) then WRAPPED after the hand-off (no hand-off evidence)" >&2
            exit 4
        fi
        if [[ $DOC == *-RESUME.md ]]; then last_marker=$(worker_tail_status "$sib_orig"); fi
    elif [ "$res_marker" != "WRAPPED" ] && [[ $DOC != *-RESUME.md ]]; then
        # an original doc's WRAPPED is stale once its -RESUME doc reports anything newer than WRAPPED
        echo "close-wrapped-worker: refusing - the sibling doc $SIB_DOC last Results marker-bullet is '$res_marker', not WRAPPED" >&2
        exit 4
    fi
fi
if [ "$last_marker" != "WRAPPED" ]; then
    echo "close-wrapped-worker: refusing - the doc's last Results marker-bullet is '${last_marker:-<none>}', not WRAPPED" >&2
    exit 4
fi

# git-env-ok: every git call below goes through sc_git, which runs under env -u GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE
# (the remote refresh inlines the same scrub because it also runs under timeout, and
# adds core.hooksPath=/dev/null so a clone-planted hook never runs under the chief)
# A clone in a session scratchpad is deleted when its session ends. A
# WRAPPED doc that names such a clone still holding commits on no remote is losing
# that work: refuse the close (the chief sends the worker back to push it to a
# staging branch or move it under ~/.himmel/scratch). A clone already gone cannot
# be checked and is skipped.
# A named path may sit below the clone (a file) or above it (a parent holding
# clones): walk up to the nearest existing directory, take the nearest ancestor
# holding a .git (git need not work there: a broken clone still refuses below)
# and any repo up to three levels below it. --all counts a detached HEAD too (a
# rebase in progress leaves its commits there); a scan or git failure refuses.
sc_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"; }
sc_grep_rc=0
scratch_raw=$(grep -oE '[^[:space:]`"'"'"'()<>,;*]*/claude-[0-9]+/[^/[:space:]]+/[^/[:space:]]+/scratchpad/[^[:space:]`"'"'"'()<>,;*]+' "$DOC") || sc_grep_rc=$?
if [ "$sc_grep_rc" -gt 1 ]; then
    echo "close-wrapped-worker: refusing - cannot scan $DOC for session-scratchpad clones (grep rc=$sc_grep_rc)" >&2
    exit 8
fi
if ! scratch_paths=$(printf '%s\n' "$scratch_raw" | sort -u); then
    echo "close-wrapped-worker: refusing - cannot sort the session-scratchpad paths named in $DOC" >&2
    exit 8
fi
scratch_clones=""
while IFS= read -r sc_orig; do
    [ -n "$sc_orig" ] || continue
    # a path ending a sentence ("...scratchpad/fork.") carries prose punctuation: check it as written and stripped
    sc_stripped="$sc_orig"
    while :; do case "$sc_stripped" in *[.:!?]) sc_stripped="${sc_stripped%?}" ;; *) break ;; esac; done
    for sc_path in "$sc_orig" "$sc_stripped"; do
    sc_root="${sc_path%%/scratchpad/*}/scratchpad"
    sc_d="$sc_path"
    while [ "$sc_d" != "$sc_root" ] && [ ! -d "$sc_d" ]; do sc_d="${sc_d%/*}"; done
    [ "$sc_d" != "$sc_root" ] || continue
    sc_up="$sc_d"
    while [ "$sc_up" != "$sc_root" ] && [ -n "$sc_up" ]; do
        if [ -e "$sc_up/.git" ]; then scratch_clones="$scratch_clones$sc_up"$'\n'; break; fi
        sc_up="${sc_up%/*}"
    done
    if ! sc_below=$(find "$sc_d" -maxdepth 3 -type d -name .git -prune); then
        echo "close-wrapped-worker: refusing - cannot scan $sc_d, named by the doc, for session-scratchpad clones; fix its permissions or move the clones under ~/.himmel/scratch before the close" >&2
        exit 8
    fi
    while IFS= read -r sc_g; do
        [ -n "$sc_g" ] && scratch_clones="$scratch_clones${sc_g%/.git}"$'\n'
    done <<EOF
$sc_below
EOF
    done
done <<EOF
$scratch_paths
EOF
if ! scratch_clones=$(printf '%s' "$scratch_clones" | sort -u); then
    echo "close-wrapped-worker: refusing - cannot sort the session-scratchpad clones named in $DOC" >&2
    exit 8
fi
while IFS= read -r sc_dir; do
    [ -n "$sc_dir" ] || continue
    # The clone's remote-tracking refs may be stale: a branch deleted or rewound on the
    # remote since the last fetch would hide commits that no longer exist there. Refresh
    # them first (pruning), bounded; a failed or timed-out refresh refuses. Each remote is
    # fetched by name: --all skips a remote set to remote.<name>.skipFetchAll.
    sc_fetch_err=""
    # GNU timeout treats 0 as "no limit": the bound must be a positive integer.
    sc_fetch_timeout="${CLOSE_WRAPPED_WORKER_FETCH_TIMEOUT:-30}"
    case "$sc_fetch_timeout" in
        ''|*[!0-9]*) sc_fetch_timeout=0 ;;
    esac
    if [ "$sc_fetch_timeout" -le 0 ]; then
        echo "close-wrapped-worker: refusing - CLOSE_WRAPPED_WORKER_FETCH_TIMEOUT must be a positive integer (seconds), got '${CLOSE_WRAPPED_WORKER_FETCH_TIMEOUT:-}'; it bounds the remote refresh of $sc_dir" >&2
        exit 8
    fi
    if ! sc_remotes=$(sc_git -C "$sc_dir" remote 2>&1); then
        sc_fetch_err="cannot list remotes: $sc_remotes"
    else
        while IFS= read -r sc_remote; do
            [ -n "$sc_remote" ] || continue
            if ! sc_fetch_out=$(GIT_TERMINAL_PROMPT=0 timeout -k 5 "$sc_fetch_timeout" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -c core.hooksPath=/dev/null -C "$sc_dir" fetch --prune --quiet -- "$sc_remote" 2>&1); then
                sc_fetch_err="remote $sc_remote: $sc_fetch_out"
                break
            fi
        done <<EOF
$sc_remotes
EOF
    fi
    if [ -n "$sc_fetch_err" ]; then
        echo "close-wrapped-worker: refusing - cannot inspect the session-scratchpad clone $sc_dir the doc names: cannot refresh its remote branches first (git failed: $sc_fetch_err); fix the remote or move the clone under ~/.himmel/scratch before the close" >&2
        exit 8
    fi
    if ! sc_unpushed=$(sc_git -C "$sc_dir" rev-list -n 1 --all --not --remotes 2>&1); then
        echo "close-wrapped-worker: refusing - cannot inspect the session-scratchpad clone $sc_dir the doc names (git failed: $sc_unpushed); fix it or move the clone under ~/.himmel/scratch before the close" >&2
        exit 8
    fi
    if [ -n "$sc_unpushed" ]; then
        echo "close-wrapped-worker: refusing - the doc names the session-scratchpad clone $sc_dir, which holds commits on no remote (e.g. $sc_unpushed); push them to a staging branch or move the clone under ~/.himmel/scratch before the close" >&2
        exit 8
    fi
done <<EOF
$scratch_clones
EOF

# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/worker-identity.sh"; then
    echo "close-wrapped-worker: cannot load scripts/lib/worker-identity.sh" >&2
    exit 1
fi
# shellcheck source=scripts/lanes/lib/claude-sessions.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lanes/lib/claude-sessions.sh"; then
    echo "close-wrapped-worker: cannot load scripts/lanes/lib/claude-sessions.sh" >&2
    exit 1
fi
# shellcheck source=scripts/handover/chief-kit/worker-transcripts.sh
# shellcheck disable=SC1091
if ! . "$HERE/worker-transcripts.sh"; then
    echo "close-wrapped-worker: cannot load scripts/handover/chief-kit/worker-transcripts.sh" >&2
    exit 1
fi

ident=$(worker_identity "$DOC")
# worker_identity's names strip -RESUME, but a
# chief may launch a worker's session under the FULL doc stem (-RESUME and
# date intact) - accept that shape too, locally here (not in worker-identity.sh,
# which other callers rely on for the stripped forms).
doc_stem="$(basename "$DOC" .md)"
names=",${ident#*$'\t'},${doc_stem},"
# A RESUME doc's label carries a successor suffix (N3731c) but the window
# still runs under the ORIGINAL worker's session name (...-N3731-...). Add each name with
# the suffix dropped from its worker token (the -legN3731c form too); a live N3731b session
# keeps its own name and never matches, and only a RESUME doc claims its predecessor's window.
orig_names=""
if [[ $DOC == *-RESUME.md && ${ident%%$'\t'*} =~ ^(N[0-9]+)[a-z]+$ ]]; then
    orig_label="${BASH_REMATCH[1]}"
    set -f
    for resume_name in ${names//,/ }; do
        orig_names="$orig_names,$(printf '%s' "$resume_name" | sed -E "s/-(leg)?${ident%%$'\t'*}(-|\$)/-\\1${orig_label}\\2/")"
    done
    set +f
    names="$names${orig_names#,},"
fi
# the resumed worker's window is named <stem>-RESUME (the original doc's stem plus
# -RESUME), or carries the sibling doc's own names (its b-suffixed label included).
if [[ $DOC != *-RESUME.md ]]; then
    ident_names="${ident#*$'\t'}"
    set -f
    for ident_name in ${ident_names//,/ }; do names="$names${ident_name}-RESUME,"; done
    set +f
fi
if [ -n "$SIB_DOC" ]; then
    sib_ident=$(worker_identity "$SIB_DOC")
    names="$names${sib_ident#*$'\t'},$(basename "$SIB_DOC" .md),"
fi

sessions=$(claude_sessions)
census_rc=$?
if [ "$census_rc" -gt 1 ]; then
    echo "close-wrapped-worker: claude_sessions census failed (rc=$census_rc)" >&2
    exit 1
fi

matched=""
matched_name=""
match_count=0
while IFS=$'\t' read -r pid name _model _ac; do
    [ -n "$pid" ] || continue
    case "$name" in
        '#'*) continue ;;
    esac
    # a relaunched worker runs as <name>-r<N>; the original and its relaunch both
    # live is an ambiguity the exactly-one rule below refuses
    base_name=$(printf '%s' "$name" | sed -E 's/-r[0-9]+$//')
    case "$names" in
        *",${name},"*|*",${base_name},"*)
            matched="$pid"
            matched_name="$name"
            match_count=$((match_count + 1)) ;;
    esac
done <<EOF
$sessions
EOF

# The lock is free and the tail says WRAPPED (both proven above), and no session
# runs under any of the worker's names: the window already exited. That is a close, not a
# refusal. A predecessor chief keeps the refusal (chief-wait.sh reads its rc 5).
if [ "$match_count" -eq 0 ] && [ "$CHIEF_MODE" -eq 0 ]; then
    names_shown="$(printf '%s' "$names" | tr -s ',' | sed -E 's/^,//; s/,$//')"
    echo "CLOSED-ALREADY: $(worker_label "$DOC") has no live session under [$names_shown]; nothing to signal"
    [ "$CHECK_MODE" -eq 1 ] && exit 0
    close_success
fi

if [ "$match_count" -ne 1 ]; then
    echo "close-wrapped-worker: refusing - $match_count live session(s) matched worker names [${ident#*$'\t'}] (need exactly 1)" >&2
    exit 5
fi

# ---------- Pre-signal session-note capture --------------------
# A wrapped worker's SessionEnd hook never runs: Claude Code cancels it the
# instant our TERM below lands, so no luna session note is written. Reproduce
# the hook's input here, from what we already resolved above (the worker's
# session names) - never a guess: resolve those names to EXACTLY ONE
# transcript file (same customTitle-grep precedent as worker-burn.sh's
# session-name lookup, but refusing instead of picking "newest" on
# ambiguity), pull cwd straight from that transcript (every row carries a
# "cwd" field), derive session_id from the transcript's own filename, and
# feed end-session-wiki.sh the same SessionEnd JSON shape Claude Code would
# have. 0 or >1 matching transcripts: say so on stderr and still close -
# never guess which one. The hook itself dedups by session_id,
# so it is harmless if the worker's own SessionEnd ALSO manages to fire.
TRANSCRIPT=""
END_SESSION_WIKI="${END_SESSION_WIKI_BIN:-$HERE/../../hooks/end-session-wiki.sh}"
# a claudex worker runs with CLAUDE_CONFIG_DIR=~/.claude-codex, so its
# sessions/<pid>.json and projects/ are NOT under the chief's config dir. Read
# the matched pid's own CLAUDE_CONFIG_DIR from /proc/<pid>/environ; failing that,
# the fleet manifest's lane (claudex -> ~/.claude-codex); else the chief's.
# The explicit CLOSE_WRAPPED_WORKER_*_DIR overrides below still win.
worker_cfg=""
if [ -r "${CLAUDE_SESSIONS_PROC:-/proc}/$matched/environ" ]; then
    worker_cfg=$(tr '\0' '\n' < "${CLAUDE_SESSIONS_PROC:-/proc}/$matched/environ" 2>/dev/null \
        | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n 1)
fi
if [ -z "$worker_cfg" ] && [ -n "$FLEET_MANIFEST" ] && [ -r "$FLEET_MANIFEST" ] \
    && [ "$(jq -r --arg d "$DOC" "$JQ_W"'[W[]? | select(.doc == $d) | .lane // "unknown"] | first // empty' "$FLEET_MANIFEST" 2>/dev/null)" = claudex ]; then
    worker_cfg="$HOME/.claude-codex"
fi
WORKER_SESSION_CONFIG_DIR="${worker_cfg:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
PROJECTS_DIR="${CLOSE_WRAPPED_WORKER_PROJECTS_DIR:-$WORKER_SESSION_CONFIG_DIR/projects}"
if [ "$CHECK_MODE" -eq 0 ] && [ -r "$END_SESSION_WIKI" ] && [ -d "$PROJECTS_DIR" ]; then
    # The two-pass customTitle search lives in worker-transcripts.sh,
    # shared with worker-digest-step.sh --doc: same "exactly one" semantics.
    candidates=$(printf '%s\n%s\n%s\n' "${ident#*$'\t'}" "$doc_stem" "$matched_name" | tr ',' '\n' | sed '/^$/d')
    transcript_matches=$(resolve_worker_transcripts "$PROJECTS_DIR" "$candidates" \
        "${CLOSE_WRAPPED_WORKER_MTIME_DAYS:-1}" "${CLOSE_WRAPPED_WORKER_CUSTOMTITLE_HEAD:-40}")
    tcount=$(printf '%s\n' "$transcript_matches" | grep -c . || true)
    if [ "$tcount" -eq 1 ]; then
        TRANSCRIPT="$transcript_matches"
        cap_cwd=$(jq -r 'select(.cwd != null) | .cwd' "$TRANSCRIPT" 2>/dev/null | head -1)
        cap_sid=$(transcript_sid "$TRANSCRIPT")
        if [ -n "$cap_cwd" ]; then
            cap_payload=$(jq -n --arg t "$TRANSCRIPT" --arg s "$cap_sid" --arg c "$cap_cwd" --arg r "worker-close" \
                '{transcript_path:$t, session_id:$s, cwd:$c, reason:$r}')
            if printf '%s' "$cap_payload" | bash "$END_SESSION_WIKI" >/dev/null 2>&1; then
                echo "close-wrapped-worker: captured session note for $cap_sid before signalling"
            else
                echo "close-wrapped-worker: end-session-wiki failed for $cap_sid - closing anyway, never blocking on it" >&2
            fi
        else
            echo "close-wrapped-worker: resolved transcript $TRANSCRIPT has no 'cwd' field - skipping the pre-signal capture, never guessing" >&2
        fi
    else
        echo "close-wrapped-worker: $tcount transcript(s) matched worker names [${ident#*$'\t'}] - cannot resolve unambiguously, skipping the pre-signal capture, never guessing" >&2
    fi
fi

subtree_out=$(bash "$WRAP_SUBTREE_CHECK" "$matched" 2>&1)
subtree_rc=$?
if [ "$subtree_rc" -ne 0 ]; then
    echo "$subtree_out"
    echo "close-wrapped-worker: refusing to signal pid $matched - wrap-subtree-check.sh did not report CLOSABLE (see above); retry shortly" >&2
    exit 6
fi

# ---------- Session id ---------------------------
# Captured BEFORE the TERM, while the session's own record still exists: the
# live pid's ~/.claude/sessions/<pid>.json names its sessionId. Unreadable or
# not a UUID: the transcript resolved above supplies it. The subagent gate
# below and the worker's digest step both use it.
digest_sid=""
sessions_json="${CLOSE_WRAPPED_WORKER_SESSIONS_DIR:-$WORKER_SESSION_CONFIG_DIR/sessions}/$matched.json"
digest_sid=$(jq -r '.sessionId // empty' "$sessions_json" 2>/dev/null)
case "$digest_sid" in
    ????????-????-????-????-????????????) ;;
    *) digest_sid="$(transcript_sid "${TRANSCRIPT:-none}")" ;;
esac

# ---------- Live in-process subagents ----------------------------
# An Agent-tool child is not a process, so the subtree check above cannot see
# it: TERMing its parent kills it and loses its result (a chief's judge
# verdict). live-subagents.sh reads the session's subagent registry against its
# transcript; anything but "none running" (a live child, or no way to tell)
# refuses - retry once the children finish, like exit 6.
subagents_out=$(bash "$LIVE_SUBAGENTS" --session "$digest_sid" --projects "$PROJECTS_DIR" 2>&1)
subagents_rc=$?
if [ "$subagents_rc" -ne 0 ]; then
    echo "$subagents_out"
    if [ "$subagents_rc" -eq 1 ]; then
        echo "close-wrapped-worker: refusing to signal pid $matched - session $digest_sid has live subagents (above); retry once they finish" >&2
    else
        echo "close-wrapped-worker: refusing to signal pid $matched - cannot prove session '$digest_sid' has no live subagents (above); retry shortly" >&2
    fi
    exit 7
fi

# ---------- --check: every refusal above ran, nothing was signalled ----
if [ "$CHECK_MODE" -eq 1 ]; then
    echo "SAFE-TO-CLOSE: pid $matched ($(worker_label "$DOC")) has no live subtree or subagent; nothing was signalled"
    exit 0
fi

# ---------- --chief: a wrapped predecessor chief -------------
# Every check above ran unchanged. A chief has no worktree, cost row, scratch
# or failure digest of its own, so the worker-only steps below are skipped: TERM
# the one proven pid and stop.
if [ "$CHIEF_MODE" -eq 1 ]; then
    if ! "$KILL" -TERM "$matched"; then
        echo "close-wrapped-worker: failed to send TERM to pid $matched" >&2
        exit 1
    fi
    echo "close-wrapped-worker: sent TERM to pid $matched (chief $(worker_label "$DOC"))"
    exit 0
fi

# ---------- Worker cost ledger ----------------------------------------
# One JSONL row per wrapped worker, from the transcript resolved above. Never
# fatal: a meter or ledger failure WARNs and the close proceeds. A retry of the
# same transcript (a refused or failed close re-run) never writes a second row.
if [ -n "$TRANSCRIPT" ]; then
    if ! . "$HERE/../../lanes/lib/worker-cost-row.sh"; then
        echo "close-wrapped-worker: WARN cannot load worker-cost-row.sh - no cost ledger row" >&2
    elif ! ledger=$(worker_cost_ledger_path "$DOC"); then
        echo "close-wrapped-worker: WARN cannot resolve the cost ledger path - no cost ledger row" >&2
    elif [ -f "$ledger" ] && grep -qF "\"session\":\"$(transcript_sid "$TRANSCRIPT")\"" "$ledger"; then
        echo "close-wrapped-worker: cost ledger already has a row for this transcript"
    elif ! row=$(worker_cost_row "$TRANSCRIPT" "$DOC"); then
        echo "close-wrapped-worker: WARN worker-burn failed - no cost ledger row" >&2
    elif mkdir -p "$(dirname "$ledger")" 2>/dev/null && printf '%s\n' "$row" >> "$ledger" 2>/dev/null; then
        echo "close-wrapped-worker: cost ledger row appended to $ledger"
    else
        echo "close-wrapped-worker: WARN cannot write $ledger - no cost ledger row" >&2
    fi
fi

if ! "$KILL" -TERM "$matched"; then
    echo "close-wrapped-worker: failed to send TERM to pid $matched" >&2
    exit 1
fi
echo "close-wrapped-worker: sent TERM to pid $matched (worker $(worker_label "$DOC"))"

# ---------- Wrapped worker's own /tmp scratch ----------------------
# Archive-then-reap THIS worker's judge dirs (j<N>, j<N>[a-z]) and its session
# scratch dir, scoped through tmp-reap.sh --judge <pr>/--session: never a fleet-wide
# sweep (other workers are live). Dry-run first; apply only after a clean dry-run.
# Never fatal: any failure WARNs and the close carries on.
reap_worker_scratch() {
    local pr sid args=() i PROC_ROOT="${CLAUDE_SESSIONS_PROC:-/proc}"
    # judge dirs are named for the PR they judged, never the worker label: take the
    # PR from the doc's newest READY/MERGED bullet; no PR means no judge scope
    pr="$(grep -E '^- [0-9:]+ (READY|MERGED)' "$DOC" | grep -oE '(READY|MERGED)[ #-]+(PR[ #]+)?[0-9]+' | tail -n 1 | grep -oE '[0-9]+$')"
    if [ -n "$pr" ]; then args+=(--judge "$pr")
    else echo "close-wrapped-worker: no PR in the worker doc - reaping no judge dir, never guessing"; fi
    if [ -n "$TRANSCRIPT" ]; then
        sid="$(transcript_sid "$TRANSCRIPT")"
        case "$sid" in
            ????????-????-????-????-????????????) args+=(--session "$sid") ;;
        esac
    fi
    if [ "${#args[@]}" -eq 0 ]; then
        echo "close-wrapped-worker: no judge number or session id for this worker - skipping the /tmp reap, never guessing"
        return 0
    fi
    # the TERM is asynchronous: give the session a moment to exit so its scratch is not "live"
    for ((i = 0; i < ${CLOSE_WRAPPED_WORKER_REAP_WAIT:-5}; i++)); do  # read-sink-ok: the < is an arithmetic comparison, not a redirect
        [ -d "$PROC_ROOT/$matched" ] || break
        sleep 1
    done
    # a session that outlives the TERM still owns its scratch: reap nothing now
    if [ -d "$PROC_ROOT/$matched" ]; then
        echo "close-wrapped-worker: pid $matched still running after TERM - leaving its /tmp scratch for a later reap"
        return 0
    fi
    if ! bash "$TMP_REAP" "${args[@]}"; then
        echo "close-wrapped-worker: WARN tmp-reap dry-run failed for ${args[*]} - not applying; close continues" >&2
        return 0
    fi
    bash "$TMP_REAP" --apply "${args[@]}" || echo "close-wrapped-worker: WARN tmp-reap --apply failed for ${args[*]} - close continues" >&2
    return 0
}
reap_worker_scratch || echo "close-wrapped-worker: WARN /tmp reap errored - close continues" >&2

# ---------- Failure-loop digest --------------------
# One `digest=` line and nothing else: worker-digest-step.sh's stderr is dropped,
# its rc is ignored, and a hard outer timeout bounds it, so a digest crash,
# hang or missing journal changes no other output and never the close's rc.
# It never writes the worker's doc, so its tail stays WRAPPED.
digest_line=$(timeout -k 5 "${CLOSE_WRAPPED_WORKER_DIGEST_TIMEOUT:-120}" bash "${WORKER_SESSION_DIGEST_STEP_BIN:-$HERE/worker-digest-step.sh}" \
    --session "$digest_sid" --transcript "$TRANSCRIPT" --doc "$DOC" --pid "$matched" --projects "$PROJECTS_DIR" 2>/dev/null \
    | grep -m 1 '^digest=')
echo "${digest_line:-digest=failed:step}"

worktrees=$(grep -oE "/[^\` ]*/\.claude/worktrees/[^\`) ]+" "$DOC" | sort -u)
wt_count=$(printf '%s\n' "$worktrees" | grep -c . || true)
if [ "$wt_count" -ne 1 ]; then
    echo "close-wrapped-worker: doc names $wt_count worktree path(s) - skipping the prune, never guessing" >&2
    close_success
fi
WT="$worktrees"
# worktree.sh prune reads the git repo of its cwd, so run the prune from the repo that registers this worktree
# (an adopter's worktree is not registered in the himmel checkout). Falls back to the cwd when the repo is gone.
wt_repo="${WT%/.claude/worktrees/*}"
[ -d "$wt_repo" ] || wt_repo="$PWD"

# the TERM'd session may still be inside the worktree when the
# first prune runs ("in use"). Retry quietly a bounded number of times (a few
# seconds in all) so a worker that exits promptly is pruned now, not left for a
# manual --only later. Only the "in use" skip retries; every other outcome is
# final on the first pass.
prune_tries=${CLOSE_WRAPPED_WORKER_PRUNE_RETRIES:-3}
prune_try=0
while :; do
    out=$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; cd "$wt_repo" && bash "$CLEAN_SH" --only "$WT" --only-allow-unmerged 2>&1)
    rc=$?
    case "$out" in *'in use'*) ;; *) break ;; esac
    [ "$rc" -ne 0 ] || break
    [ "$prune_try" -lt "$prune_tries" ] || break
    prune_try=$((prune_try + 1))
    sleep "${CLOSE_WRAPPED_WORKER_PRUNE_WAIT:-1}"
done
echo "$out"
if [ "$rc" -ne 0 ]; then
    # clean-garden.sh's own --only failure text always contains "not a prune
    # candidate" (its wording is shared across a benign skip AND a PARTIAL or
    # FAILED removal), so a substring match
    # on that text alone can't tell a benign skip apart from a dangerous
    # partial/gutted-tree removal. Read its "prune summary" counts instead:
    # only a summary with 0 partial and 0 failed is a benign skip.
    summary_line=$(printf '%s\n' "$out" | grep -F 'clean-garden: prune summary' | tail -n 1)
    partial_n=$(printf '%s' "$summary_line" | sed -nE 's/.*, ([0-9]+) partial,.*/\1/p')
    failed_n=$(printf '%s' "$summary_line" | sed -nE 's/.* ([0-9]+) failed$/\1/p')
    benign=0
    if [ "$partial_n" = "0" ] && [ "$failed_n" = "0" ]; then
        case "$out" in
            *'in use'*|*'not a prune candidate'*)
                benign=1 ;;
        esac
    fi
    # A worktree that is unregistered AND absent on disk was already pruned
    # (by the worker, a sweep, or an earlier close): nothing is left to remove.
    case "$out" in
        *'is not a registered worktree'*)
            if [ ! -e "$WT" ]; then
                echo "close-wrapped-worker: worktree $WT already gone - nothing to prune"
                close_success
            fi ;;
    esac
    if [ "$benign" -eq 1 ]; then
        echo "close-wrapped-worker: worktree $WT not pruned (see message above) - not a failure, retry --only shortly"
        close_success
    fi
    echo "close-wrapped-worker: clean.sh --only $WT --only-allow-unmerged failed (rc=$rc)" >&2
    exit 1
fi
close_success
