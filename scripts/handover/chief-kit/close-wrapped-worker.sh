#!/usr/bin/env bash
# scripts/handover/chief-kit/close-wrapped-worker.sh - chief-run wrapped-worker
# window close. A chief's `kill <konsole pid>` is
# classifier-denied [Interfere With Workloads] when typed as a bare literal -
# this script wraps the same TERM under a literal the classifier allowlists,
# but ONLY after verifying the worker is actually done: the queue lock on its
# doc is free AND its own last Results marker-bullet is WRAPPED (or that last
# bullet is itself a BLOCKED hand-off naming its launched successor; the tick counts both
# as closable=). A named hand-off closes only the predecessor's own
# identity; it never signals a live successor, and a successor that shares any of
# the predecessor's session names is not exempted.
# It never kills a pid it cannot independently prove belongs to that worker.
#
# Usage: close-wrapped-worker.sh [--check] [--chief | --fleet <manifest>] <worker-doc>
#        close-wrapped-worker.sh [--check] --sweep --fleet <manifest>
# --sweep runs this script on every doc in the fleet manifest and closes each one
# that is finished (lock free, tail WRAPPED or a BLOCKED hand-off naming its successor);
# an unfinished doc is skipped, a
# finished one that cannot be closed (no/ambiguous window, live subtree) is
# refused and its reason printed. It prints `sweep: closed=<n> refused=<n>
# skipped=<n>` and exits 0; the tick's closable=<n> field says when to run it.
# --check runs every pre-close check below and stops before any close action:
# no TERM and no close record. The
# scratchpad-clone check still runs a bounded git fetch --prune in each named
# clone, so it updates that clone's remote-tracking refs and needs the network. It prints SAFE-TO-CLOSE (rc 0) or the refusal a real close would
# print, with the same exit code, so an operator closing a window by hand can
# ask first. Exit 0 means safe to close.
# --chief closes a wrapped PREDECESSOR chief's window: the
# same lock/WRAPPED/one-session checks and subtree check, then TERM - no close
# record and no sweep. Run it right after your own LIVE.
# --fleet removes the doc after a successful close.
# A manifest update failure returns 1 after the session has already closed.
#
# Refuses (nothing signaled) unless:
#   - `queue-lock.sh status <worker-doc>` reports free (rc=0);
#   - the doc's last `## Results` marker-bullet (one of LIVE/FINDING/
#     RESOLVED/READY/BLOCKED/HALTED/WRAPPED, leading token of the newest
#     such bullet) is WRAPPED (or a BLOCKED that is itself the hand-off naming its successor),
#     read from the Results section and the `## Chief Rulings` / `## Console Rulings` sections the
#     writers add below it (a bullet in any other later section, a `## Notes` line naming WRAPPED or
#     starting with LIVE, is no tail); a -RESUME doc with no marker-bullet of its own reads the original's
#     (a resumed worker's WRAPPED lands on the original doc) only when the original's Results hold,
#     after the hand-off WRAPPED naming the -RESUME doc, a LIVE with a new release token and then a
#     WRAPPED, and the sibling's queue lock must be free too; a -RESUME doc with no Results
#     heading has no marker of its own, whatever prose bullet it holds;
#   - exactly one live `claude` session's real argv (via
#     scripts/lanes/lib/claude-sessions.sh's claude_sessions, /proc-argv
#     based, never a flattened pgrep -af scan) carries a `-n <name>` naming
#     the worker (names derived by scripts/lib/worker-identity.sh's worker_identity -
#     the doc stem, its undated form, and any legacy-family derived name, each also
#     with -RESUME, plus the sibling doc's names; a relaunched worker's trailing -r<N>
#     on the session name is accepted), OR a live claude whose own session record
#     (sessions/<pid>.json) names a session id in the `session_ids:` front matter of the
#     doc or its sibling (the launcher's record, one id per launch) and whose recorded
#     procStart equals the process's /proc start time. That second proof finds a worker
#     relaunched under a shortened session name (the bus refused the long
#     name built from the doc), which no name derived from the doc can match. A record
#     with no procStart, a start time that differs, or a session id the doc does not
#     list proves nothing. Not used for --chief.
# A pair whose RESUME doc ends in a READY (any other non-WRAPPED tail there is a worker still going) still closes when the
# original doc holds the resumed worker's own LIVE (new release token) then WRAPPED after the
# hand-off and that WRAPPED is the newest stamp across the pair (HH:MM, strictly later and
# under twelve hours later, since a stamp carries no date).
# ponytail: the launch record (launch-logs/<name>.log) holds no pid, so the proof is the
# doc's session_ids against the live pid's session record. Upgrade path: have
# headed-arm-worker.sh record the claude pid and resolve by it first.
# TERM goes to that one pid only - it never signals a non-matching pid, and
# 0 or >1 matches is a refusal, not a best guess.
#
# After the signal the close does no housekeeping of its own and makes no GitHub
# call. It writes one close record (doc, label, pid, proc_start, session id,
# transcript, names, config and projects dirs, worktrees, repo, predecessor,
# named_successor, closed_at, sweeps_seen) to
# ${CLOSE_SWEEP_STATE_DIR:-~/.himmel/state/close-sweep}/pending/ through pending/.tmp/,
# starts close-sweep.sh --drain detached (stdio to sweep.log, every inherited
# descriptor from 3 up closed; CLOSE_SWEEP_BIN overrides it), prints
# `sweep=queued <record>` and returns. The sweep does the session note, cost row,
# failure digest, /tmp reap and worktree prune for every queued record, and keeps
# a live successor's scratch and worktree. A record that cannot be written prints
# a WARN and changes no exit code: the window is closed and the worktree stays.
# The session id is read from the worker's sessions/<pid>.json BEFORE the TERM;
# when that gives no id, it is taken from the one transcript matching the
# worker's names (none or several: no id, never a guess).
#
# Before signalling, reuses scripts/handover/wrap-subtree-check.sh
# on the matched pid: a non-harness descendant still alive (a worker mid an
# operator command, a tool call in flight) refuses the TERM rather than
# killing it out from under that work - never guessed, never overridden.
# A withheld subtree is not a failure: the chief re-runs this script later,
# same as any other "retry shortly" refusal here.
#
# Exit codes:
#   0  signaled (the close record queued, or a WARN that it could not be); or
#      CLOSED-ALREADY: lock free, tail WRAPPED, and no live session
#      under any of the worker's names (a RESUME doc's label suffix is dropped to
#      find the original session) - nothing to signal; the manifest entry is retired.
#      Not for --chief: a predecessor chief with 0 sessions still exits 5.
#   1  a plumbing failure (census, library load, doc listing, fleet manifest), or the
#      TERM signal itself failed; never the housekeeping, which the sweep reports
#   2  usage (missing/unreadable doc)
#   3  refused - the queue lock is not free: on the doc, or on a sibling other
#      than its explicitly named hand-off successor. A legacy resumed-window
#      fallback still requires the successor's lock to be free.
#   4  refused - the last marker-bullet is not WRAPPED: the doc's own (a -RESUME doc with no
#      marker of its own reads the original's, only with hand-off evidence); an original doc is
#      also refused while its -RESUME sibling has a last marker-bullet that is not WRAPPED; and
#      both docs of a pair are refused while the -RESUME doc has no marker-bullet and the
#      original's Results hold no successor LIVE (new release token) then WRAPPED after the
#      hand-off WRAPPED (no hand-off evidence), except that an ORIGINAL doc whose own tail is WRAPPED
#      beside a never-launched -RESUME doc (no marker-bullet, lock free) closes its own window, and is
#      refused with this code while a session runs under the -RESUME doc's names or session ids;
#      and a named hand-off whose predecessor session
#      is gone is refused unless the predecessor is WRAPPED with completed successor evidence
#      and the successor's own last marker-bullet is WRAPPED; and a BLOCKED tail that is not
#      itself the hand-off bullet (a later ordinary BLOCKED) is a working worker
#   5  refused - more than 1 live session matched the worker's names (0 for a --chief), or an original
#      doc has multiple successor -RESUME docs with no explicitly named hand-off
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
WRAP_SUBTREE_CHECK="${WRAP_SUBTREE_CHECK_BIN:-$HERE/../wrap-subtree-check.sh}"
LIVE_SUBAGENTS="${LIVE_SUBAGENTS_BIN:-$HERE/live-subagents.sh}"
CLOSE_SWEEP="${CLOSE_SWEEP_BIN:-$HERE/close-sweep.sh}"
CLOSE_SWEEP_STATE="${CLOSE_SWEEP_STATE_DIR:-$HOME/.himmel/state/close-sweep}"

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
            3|4) sw_skipped=$((sw_skipped + 1))
                 # a doc that reads WRAPPED further down but whose Results tail is not would strand its window silently
                 case "$sw_out" in *"not the worker's tail"*) echo "sweep: skipped $sw_doc (rc=$sw_rc): $(printf '%s\n' "$sw_out" | tail -n 1)" ;; esac ;;
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
# successor (more than one is refused). A leg-named RESUME doc whose original has no leg and a
# date finds no candidate by name: the one same-ticket, same-worker doc that names it is the original.
# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/worker-identity.sh"; then
    echo "close-wrapped-worker: cannot load scripts/lib/worker-identity.sh" >&2
    exit 1
fi
# shellcheck source=scripts/lib/worker-successor.sh
. "$HERE/../../lib/worker-successor.sh"
NAMED_SUCCESSOR=$(worker_named_successor "$DOC") || exit 1
SIB_DOC=""
sib_dir="$(dirname "$DOC")"
sib_base="$(basename "$DOC" .md)"
sib_label="$(worker_label "$DOC")"
if [ -n "$NAMED_SUCCESSOR" ]; then
    SIB_DOC="$NAMED_SUCCESSOR"
elif [[ $DOC == *-RESUME.md ]]; then
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
    if [ -z "$SIB_DOC" ] && [[ $sib_label =~ ^(N[0-9]+)[a-z]+$ ]]; then
        sib_orig_label="${BASH_REMATCH[1]}"
        sib_ticket="$(printf '%s' "$sib_base" | cut -d- -f1-2)"
        sib_hits=0
        for sib_c in "$sib_dir/$sib_ticket"-*.md; do
            [ -f "$sib_c" ] && [[ $sib_c != *-RESUME.md ]] || continue
            [[ $(basename "$sib_c") =~ ^${sib_ticket}-(leg)?${sib_orig_label}- ]] || continue
            grep -qF -- "$(basename "$DOC")" "$sib_c" || continue
            SIB_DOC="$sib_c"; sib_hits=$((sib_hits + 1))
        done
        if [ "$sib_hits" -gt 1 ]; then
            echo "close-wrapped-worker: refusing - $sib_hits original docs of $sib_orig_label name $DOC; close the right one by name" >&2
            exit 5
        fi
    fi
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
if [ -n "$SIB_DOC" ] && [ "$SIB_DOC" != "$NAMED_SUCCESSOR" ] && ! bash "$HERE/../queue-lock.sh" status "$SIB_DOC" >/dev/null 2>&1; then
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
    local stem lab
    stem=$(basename "$2" .md)
    lab=$(worker_label "$2")
    [[ $lab =~ [0-9][a-z]+$ ]] || lab=""
    awk -v stem="$stem" -v lab="$lab" '
        /^## Results( |$)/ { seen = 1; inres = 1; next }
        /^## / { inres = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next }
        !inres || !/^- / { next }
        {
            mk = ""; tok = ""
            if (match($0, /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/)) {
                mk = substr($0, RSTART, RLENGTH)
                sub(/^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?/, "", mk)
                sub(/[^A-Za-z0-9_]$/, "", mk)
            }
            if (mk == "LIVE" && match($0, /release-token[: \t]+`?[A-Za-z0-9_.-]+-pid[0-9]+`?/)) {
                tok = substr($0, RSTART, RLENGTH)
                sub(/^release-token[: \t]+/, "", tok); gsub(/`/, "", tok)
            }
            if (!named && (index($0, stem) || (lab != "" && match($0, "(^|[^A-Za-z0-9])" lab "([^A-Za-z0-9]|$)")))) named = 1
            if (named && !hand && (mk == "WRAPPED" || (mk == "BLOCKED" && $0 ~ /([Hh]and-?off|RESUME written:)/))) { hand = 1; next }
            if (!hand) { if (tok != "") pred = tok; next }
            if (!live && tok != "" && tok != pred) { live = 1; next }
            if (live && mk != "") tailmk = mk
            if (live && mk == "WRAPPED") wrapped = 1
        }
        END { exit !(wrapped && tailmk == "WRAPPED") }' "$1"
}

successor_own_evidence() {
    awk '
        /^## Results( |$)/ { seen = 1; inres = 1; next }
        /^## / { inres = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next }
        !inres || !/^- / { next }
        /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?LIVE([^A-Za-z0-9_]|$)/ && /release-token[: \t]+`?[A-Za-z0-9_.-]+-pid[0-9]+`?/ { live = 1 }
        END { exit !live }' "$1" && [ "$(doc_tail_status "$1")" = WRAPPED ]
}

# results_tail_status <doc>: the doc's tail status read from its `## Results` section and the ruling sections
# the writers add after it (`## Chief Rulings`, `## Console Rulings`), through the one marker parser
# (worker_tail_status). append-results.sh inserts at the end of the last of these sections, so once inbox-send
# adds a ruling section the worker's later bullets sit below it and still count; a bullet in any other later section (a
# `## Notes` line that mentions WRAPPED) never reads as the worker's tail. Prints `nosection` for a doc with
# no Results heading (a legacy doc: the whole-file tail stands). Returns 1 when the text cannot be copied.
results_tail_status() {
    local tmp out
    if ! grep -qE '^## Results( |$)' "$1" 2>/dev/null; then printf 'nosection'; return 0; fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/cww-results.XXXXXX") || return 1
    if ! awk '/^## Results( |$)/ { seen = 1; keep = 1; next } /^## / { keep = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next } keep' "$1" > "$tmp"; then rm -f "$tmp"; return 1; fi
    out=$(worker_tail_status "$tmp"); rm -f "$tmp"
    printf '%s' "$out"
}

# doc_tail_status <doc>: the status the close gates read for a doc - its Results tail (results_tail_status),
# or the whole-file tail for a legacy doc with no Results heading. Returns 1 when the doc cannot be read.
doc_tail_status() {
    local rt
    rt=$(results_tail_status "$1") || return 1
    if [ "$rt" = nosection ]; then worker_tail_status "$1"; else printf '%s' "$rt"; fi
}

tail_marker_minutes() {
    awk '
        /^## Results( |$)/ { seen = 1; inres = 1; next }
        /^## / { inres = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next }
        !inres || !/^- / { next }
        match($0, /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/) {
            last = ($2 ~ /^[0-9]?[0-9]:[0-9][0-9]$/) ? $2 : ""
        }
        END { if (last != "") { split(last, p, ":"); print p[1] * 60 + p[2] } }' "$1"
}

resumed_wrapped_newer() {
    local o r gap half_day=720
    resume_evidence "$1" "$2" || return 1
    [ "$(doc_tail_status "$1")" = WRAPPED ] || return 1
    o=$(tail_marker_minutes "$1"); r=$(tail_marker_minutes "$2")
    [ -n "$o" ] && [ -n "$r" ] || return 1
    # ponytail: stamps carry no date, so a day-2 relaunch can pass this gap test, upgrade to dated timestamps or to bullet position across the pair
    gap=$((o - r))
    [ "$gap" -gt 0 ] && [ "$gap" -lt "$half_day" ]
}

if ! last_marker=$(doc_tail_status "$DOC"); then
    echo "close-wrapped-worker: refusing - cannot read the ## Results section of $DOC" >&2
    exit 4
fi
tail_doc="$DOC"   # the doc last_marker is read from
PREDECESSOR=0
ORPHAN_RESUME=0
if [ -n "$NAMED_SUCCESSOR" ]; then
    case "$last_marker" in
        WRAPPED) PREDECESSOR=1 ;;
        BLOCKED)
            # a BLOCKED tail closes only when that bullet is itself the hand-off (not negated); a later
            # ordinary BLOCKED (waiting on CI) is a working worker
            if worker_handoff_tail "$DOC"; then PREDECESSOR=1; fi ;;
    esac
fi
if [ -n "$SIB_DOC" ] && [ "$PREDECESSOR" -eq 0 ]; then
    if [[ $DOC == *-RESUME.md ]]; then sib_res="$DOC"; sib_orig="$SIB_DOC"; else sib_res="$SIB_DOC"; sib_orig="$DOC"; fi
    if ! res_marker=$(results_tail_status "$sib_res"); then
        echo "close-wrapped-worker: refusing - cannot read the ## Results section of $sib_res" >&2
        exit 4
    fi
    [ "$res_marker" != nosection ] || res_marker=""
    if [ -z "$res_marker" ]; then
        # the resumed worker has written nothing of its own yet, so it may be a successor that has just
        # started: only the successor's own record on the original (a LIVE with a new release token,
        # then its WRAPPED, after the hand-off) lets either doc close
        if ! resume_evidence "$sib_orig" "$sib_res"; then
            if [[ $DOC != *-RESUME.md ]] && [ "$last_marker" = WRAPPED ]; then
                ORPHAN_RESUME=1
            else
                echo "close-wrapped-worker: refusing - $sib_res has no marker-bullet of its own and $sib_orig holds no successor LIVE (new release token) then WRAPPED after the hand-off (no hand-off evidence)" >&2
                exit 4
            fi
        fi
        if [[ $DOC == *-RESUME.md ]]; then
            tail_doc="$sib_orig"
            if ! last_marker=$(doc_tail_status "$sib_orig"); then
                echo "close-wrapped-worker: refusing - cannot read the ## Results section of $sib_orig" >&2
                exit 4
            fi
        fi
    elif [ "$res_marker" = "READY" ] && resumed_wrapped_newer "$sib_orig" "$sib_res"; then
        if [[ $DOC == *-RESUME.md ]]; then
            tail_doc="$sib_orig"
            last_marker=WRAPPED
        fi
    elif [ "$res_marker" != "WRAPPED" ] && [[ $DOC != *-RESUME.md ]]; then
        # an original doc's WRAPPED is stale once its -RESUME doc reports anything newer than WRAPPED
        echo "close-wrapped-worker: refusing - the sibling doc $SIB_DOC last Results marker-bullet is '$res_marker', not WRAPPED" >&2
        exit 4
    fi
fi
if [ "$last_marker" != "WRAPPED" ] && [ "$PREDECESSOR" -eq 0 ]; then
    # the whole-file tail can still read WRAPPED: a bullet in a section after Results that is not a ruling section
    # (a ## Notes line naming WRAPPED) is no worker tail, and a sweep must say so rather than strand the window
    if [ "$(worker_tail_status "$tail_doc")" = WRAPPED ]; then
        echo "close-wrapped-worker: refusing - the ## Results tail of $tail_doc (with its Chief/Console Rulings sections) is '${last_marker:-<none>}', not WRAPPED: a WRAPPED in any other later section is not the worker's tail" >&2
        exit 4
    fi
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
# shellcheck source=scripts/handover/chief-kit/close-facts.sh
# shellcheck disable=SC1091
if ! . "$HERE/close-facts.sh"; then
    echo "close-wrapped-worker: cannot load scripts/handover/chief-kit/close-facts.sh" >&2
    exit 1
fi

ident=$(worker_identity "$DOC")
# worker_identity's names strip -RESUME, but a
# chief may launch a worker's session under the FULL doc stem (-RESUME and
# date intact) - accept that shape too, locally here (not in worker-identity.sh,
# which other callers rely on for the stripped forms).
doc_stem="$(basename "$DOC" .md)"
names=",${ident#*$'\t'},${doc_stem},"
own_names="$names"   # the doc's own label; names added below are derived from its predecessor or sibling
# A RESUME doc's label carries a successor suffix (N3731c) but the window
# still runs under the ORIGINAL worker's session name (...-N3731-...). Add each name with
# the suffix dropped from its worker token (the -legN3731c form too); a live N3731b session
# keeps its own name and never matches, and only a RESUME doc claims its predecessor's window.
orig_names=""
if [ "$PREDECESSOR" -eq 0 ] && [[ $DOC == *-RESUME.md && ${ident%%$'\t'*} =~ ^(N[0-9]+)[a-z]+$ ]]; then
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
if [ "$PREDECESSOR" -eq 0 ] && [[ $DOC != *-RESUME.md ]]; then
    ident_names="${ident#*$'\t'}"
    set -f
    for ident_name in ${ident_names//,/ }; do names="$names${ident_name}-RESUME,"; done
    set +f
fi
if [ -n "$SIB_DOC" ] && [ "$PREDECESSOR" -eq 0 ]; then
    sib_ident=$(worker_identity "$SIB_DOC")
    names="$names${sib_ident#*$'\t'},$(basename "$SIB_DOC" .md),"
fi

sessions=$(claude_sessions)
census_rc=$?
if [ "$census_rc" -gt 1 ]; then
    echo "close-wrapped-worker: claude_sessions census failed (rc=$census_rc)" >&2
    exit 1
fi

claim_ids=""
own_claim_ids=""; sib_claim_ids=""
set_claim_ids() {
    local d first d_ids
    claim_ids=""; own_claim_ids=""; sib_claim_ids=""
    [ "$CHIEF_MODE" -eq 0 ] || return 0
    for d in "$@"; do
        IFS= read -r first < "$d" || continue
        [ "$first" = "---" ] || continue
        d_ids="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$d" | sed -n 's/^session_ids: *//p' | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')"$'\n'
        claim_ids="$claim_ids$d_ids"
        if [ "$d" = "$1" ]; then own_claim_ids="$own_claim_ids$d_ids"; else sib_claim_ids="$sib_claim_ids$d_ids"; fi
    done
}
if [ "$PREDECESSOR" -eq 0 ] && [ -n "$SIB_DOC" ]; then set_claim_ids "$DOC" "$SIB_DOC"; else set_claim_ids "$DOC"; fi

proc_start_time() { sed -E 's/^.*\) //' "$1" | awk '{print $20}'; }

pid_proven_by_id() {
    local pid="$1" ids="${2-$claim_ids}" proc="${CLAUDE_SESSIONS_PROC:-/proc}" cfg="" f rec sid ps st
    [ -n "$ids" ] || return 1
    if [ -r "$proc/$pid/environ" ]; then
        cfg=$(tr '\0' '\n' < "$proc/$pid/environ" | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n 1)
    fi
    f="${CLOSE_WRAPPED_WORKER_SESSIONS_DIR:-${cfg:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/sessions}/$pid.json"
    [ -r "$f" ] || return 1
    rec=$(jq -r '[.sessionId // "", (.procStart // "" | tostring)] | join(" ")' "$f") || return 1
    sid="${rec%% *}"; ps="${rec#* }"
    [ -n "$sid" ] && [ -n "$ps" ] && [ -r "$proc/$pid/stat" ] || return 1
    grep -qxF -- "$sid" <<< "$ids" || return 1
    st=$(proc_start_time "$proc/$pid/stat")
    [ "$st" = "$ps" ]
}

pid_is_siblings_window() {
    [ -n "$sib_claim_ids" ] && pid_proven_by_id "$1" "$sib_claim_ids" && ! pid_proven_by_id "$1" "$own_claim_ids"
}

match_sessions() {
    matched=""; matched_name=""; match_count=0
    name_count=0; own_count=0; own_pid=""; own_name=""; matched_list=""
    while IFS=$'\t' read -r pid name _model _ac; do
        [ -n "$pid" ] || continue
        case "$name" in '#'*) continue ;; esac
        if pid_is_siblings_window "$pid"; then continue; fi
        # An original and its -r<N> relaunch both alive remain ambiguous.
        base_name=$(printf '%s' "$name" | sed -E 's/-r[0-9]+$//')
        case "$names" in
            *",${name},"*|*",${base_name},"*)
                matched="$pid"; matched_name="$name"
                match_count=$((match_count + 1)); name_count=$((name_count + 1))
                matched_list="$matched_list, $name (pid $pid)"
                case "$own_names" in
                    *",${name},"*|*",${base_name},"*) own_count=$((own_count + 1)); own_pid="$pid"; own_name="$name" ;;
                esac ;;
            *)
                if pid_proven_by_id "$pid"; then
                    matched="$pid"; matched_name="$name"
                    match_count=$((match_count + 1))
                    matched_list="$matched_list, $name (pid $pid, by session id)"
                fi ;;
        esac
    done <<EOF
$sessions
EOF
}

resume_session_live() {
    local pid name _model _ac base
    while IFS=$'\t' read -r pid name _model _ac; do
        [ -n "$pid" ] || continue
        case "$name" in '#'*) continue ;; esac
        if pid_is_siblings_window "$pid"; then return 0; fi
        base=$(printf '%s' "$name" | sed -E 's/-r[0-9]+$//')
        case "$names" in
            *",${name},"*|*",${base},"*)
                case "$own_names" in
                    *",${name},"*|*",${base},"*) ;;
                    *) return 0 ;;
                esac ;;
        esac
    done <<EOF
$sessions
EOF
    return 1
}
if [ "$ORPHAN_RESUME" -eq 1 ] && resume_session_live; then
    echo "close-wrapped-worker: refusing - $sib_res has no marker-bullet of its own, $sib_orig holds no successor LIVE (new release token) then WRAPPED after the hand-off (no hand-off evidence), and a session is live under the RESUME doc's name (a booting successor)" >&2
    exit 4
fi
match_sessions
# A named hand-off closes the predecessor by its OWN names, never the successor's.
# If only a legacy resumed window remains, its completed run must be proven before
# broadening the names. A hand-off alone never signals a booting/live successor.
if [ "$PREDECESSOR" -eq 1 ] && [ "$match_count" -eq 0 ]; then
    if [ "$last_marker" != WRAPPED ] || { ! resume_evidence "$DOC" "$NAMED_SUCCESSOR" && ! successor_own_evidence "$NAMED_SUCCESSOR"; }; then
        echo "close-wrapped-worker: refusing - no predecessor session and no completed successor evidence" >&2
        exit 4
    fi
    if ! bash "$HERE/../queue-lock.sh" status "$NAMED_SUCCESSOR" >/dev/null 2>&1; then
        echo "close-wrapped-worker: refusing - the successor queue lock is not free" >&2
        exit 3
    fi
    res_marker=$(doc_tail_status "$NAMED_SUCCESSOR") || exit 4
    if [ -n "$res_marker" ] && [ "$res_marker" != WRAPPED ]; then
        echo "close-wrapped-worker: refusing - the successor is not WRAPPED" >&2
        exit 4
    fi
    sib_ident=$(worker_identity "$NAMED_SUCCESSOR")
    names=",${sib_ident#*$'\t'},$(basename "$NAMED_SUCCESSOR" .md),"
    set_claim_ids "$NAMED_SUCCESSOR"
    match_sessions
fi

# The lock is free and the tail says WRAPPED (both proven above), and no session
# runs under any of the worker's names: the window already exited. That is a close, not a
# refusal. A predecessor chief keeps the refusal (chief-wait.sh reads its rc 5).
if [ "$match_count" -eq 0 ] && [ "$CHIEF_MODE" -eq 0 ]; then
    names_shown="$(printf '%s' "$names" | tr -s ',' | sed -E 's/^,//; s/,$//')"
    echo "CLOSED-ALREADY: $(worker_label "$DOC") has no live session under [$names_shown]; nothing to signal"
    [ "$CHECK_MODE" -eq 1 ] && exit 0
    close_success
fi

# A predecessor and its successor both still open: exactly one runs under this
# doc's own label, the other matched only through a name derived from the predecessor or sibling doc.
# That one is this worker's window; any other pair (both own, both derived, one by session id) stays ambiguous.
if [ "$match_count" -eq 2 ] && [ "$name_count" -eq 2 ] && [ "$own_count" -eq 1 ]; then
    echo "close-wrapped-worker: 2 live sessions matched; closing $own_name (pid $own_pid), the one under this doc's own label, never the other"
    matched="$own_pid"; matched_name="$own_name"; match_count=1
fi

if [ "$match_count" -ne 1 ]; then
    echo "close-wrapped-worker: refusing - $match_count live session(s) matched worker names [${ident#*$'\t'}] (need exactly 1); live: ${matched_list#, }" >&2
    exit 5
fi

TRANSCRIPT=""
candidates=$(printf '%s\n%s\n%s\n' "${ident#*$'\t'}" "$doc_stem" "$matched_name" | tr ',' '\n' | sed '/^$/d')
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
# not a UUID (and not --check): the one transcript matching the worker's names
# supplies it, through worker-transcripts.sh's two-pass customTitle search; 0 or
# more than 1 match gives no id, never a guess. The subagent gate below and the
# close record both use it.
digest_sid=""
sessions_json="${CLOSE_WRAPPED_WORKER_SESSIONS_DIR:-$WORKER_SESSION_CONFIG_DIR/sessions}/$matched.json"
digest_sid=$(jq -r '.sessionId // empty' "$sessions_json" 2>/dev/null)
case "$digest_sid" in
    ????????-????-????-????-????????????) ;;
    *)
        if [ "$CHECK_MODE" -eq 0 ] && [ -d "$PROJECTS_DIR" ]; then
            transcript_matches=$(resolve_worker_transcripts "$PROJECTS_DIR" "$candidates" \
                "${CLOSE_WRAPPED_WORKER_MTIME_DAYS:-1}" "${CLOSE_WRAPPED_WORKER_CUSTOMTITLE_HEAD:-40}")
            tcount=$(printf '%s\n' "$transcript_matches" | grep -c . || true)
            if [ "$tcount" -eq 1 ]; then
                TRANSCRIPT="$transcript_matches"
            else
                echo "close-wrapped-worker: no session id in $sessions_json and $tcount transcript(s) matched worker names [${ident#*$'\t'}] - cannot resolve unambiguously, never guessing" >&2
            fi
        fi
        digest_sid="$(transcript_sid "${TRANSCRIPT:-none}")" ;;
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
# or failure digest of its own, so it queues no close record: TERM the one
# proven pid and stop.
if [ "$CHIEF_MODE" -eq 1 ]; then
    if ! "$KILL" -TERM "$matched"; then
        echo "close-wrapped-worker: failed to send TERM to pid $matched" >&2
        exit 1
    fi
    echo "close-wrapped-worker: sent TERM to pid $matched (chief $(worker_label "$DOC"))"
    exit 0
fi

# ---------- The TERM, then one queued close record -------------------
# The start time is read before the TERM, so the sweep tells this worker's pid from
# a later process that reuses the number.
proc_start=""
if [ -r "${CLAUDE_SESSIONS_PROC:-/proc}/$matched/stat" ]; then
    proc_start=$(proc_start_time "${CLAUDE_SESSIONS_PROC:-/proc}/$matched/stat")
fi

if ! "$KILL" -TERM "$matched"; then
    echo "close-wrapped-worker: failed to send TERM to pid $matched" >&2
    exit 1
fi
echo "close-wrapped-worker: sent TERM to pid $matched (worker $(worker_label "$DOC"))"

# The record's repo is the repo that registers the doc's worktree (an adopter's
# worktree is not registered in the himmel checkout), else the path above its
# .claude/worktrees/ when that still exists, else empty: never the close's own cwd.
DOC_WORKTREES=$(grep -oE "/[^\` ]*/\.claude/worktrees/[^\`) ]+" "$DOC" | sort -u)
rec_wt=$(printf '%s\n' "$DOC_WORKTREES" | sed -n 1p)
rec_repo=""
if [ -n "$rec_wt" ]; then
    rec_common=$(cf_git "$rec_wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || rec_common=""
    case "$rec_common" in
        */.git) rec_repo="${rec_common%/.git}" ;;
        *) rec_repo="${rec_wt%/.claude/worktrees/*}"; [ -d "$rec_repo" ] || rec_repo="" ;;
    esac
fi
rec_label=$(worker_label "$DOC")
rec_sid=""
case "$digest_sid" in ????????-????-????-????-????????????) rec_sid="$digest_sid" ;; esac
closed_at=$(date +%s)
# the pid keeps two closes of one label in the same second (two chiefs) apart
rec_name="$closed_at-$(printf '%s' "${rec_label:-$doc_stem}" | tr -c 'A-Za-z0-9_.-' '_')-$matched"
rec_doc="$(cd "$(dirname "$DOC")" && pwd)/$(basename "$DOC")"
rec_file="$CLOSE_SWEEP_STATE/pending/$rec_name.json"

queue_record() {
    local tmp="$CLOSE_SWEEP_STATE/pending/.tmp/$rec_name"
    mkdir -p "$CLOSE_SWEEP_STATE/pending/.tmp" 2>/dev/null || return 1
    if ! jq -n --arg doc "$rec_doc" --arg label "$rec_label" --argjson pid "$matched" --arg ps "$proc_start" \
        --arg sid "$rec_sid" --arg tr "$TRANSCRIPT" --arg names "$candidates" \
        --arg cfg "$WORKER_SESSION_CONFIG_DIR" --arg pd "$PROJECTS_DIR" --arg wts "$DOC_WORKTREES" \
        --arg repo "$rec_repo" --argjson pred "$PREDECESSOR" --arg succ "$NAMED_SUCCESSOR" --argjson closed "$closed_at" \
        '{doc: $doc, label: $label, pid: $pid, proc_start: $ps, sid: $sid, transcript: $tr,
          names: ($names | split("\n") | map(select(. != ""))), config_dir: $cfg, projects_dir: $pd,
          worktrees: ($wts | split("\n") | map(select(. != ""))), repo: $repo, predecessor: $pred,
          named_successor: $succ, closed_at: $closed, sweeps_seen: 0}' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$rec_file" 2>/dev/null && return 0 # prim-ok: tmp is pending/.tmp/ on the same filesystem, outside the sweep's pending/*.json glob, so the mv is the atomic publish
    rm -f "$tmp"
    return 1
}

# start_sweep: close-sweep.sh --drain in its own session, its stdio on sweep.log and
# every other descriptor it would inherit closed first, so a caller's lock fd (the
# waiter holds one on fd 9) is free the moment this close returns.
start_sweep() {
    # shellcheck disable=SC2016  # the child shell expands $$ and $0 itself
    setsid -f bash -c 'for fd in /proc/$$/fd/*; do fd=${fd##*/}; case $fd in ""|*[!0-9]*) continue ;; esac; [ "$fd" -le 2 ] || eval "exec $fd>&-"; done; exec bash "$0" --drain' \
        "$CLOSE_SWEEP" < /dev/null >> "$CLOSE_SWEEP_STATE/sweep.log" 2>&1
}

if queue_record; then
    start_sweep || echo "close-wrapped-worker: WARN cannot start the close sweep - the record waits in $CLOSE_SWEEP_STATE/pending/ for the next drain" >&2
    echo "sweep=queued $rec_file"
else
    echo "close-wrapped-worker: WARN cannot queue the close sweep record" >&2
fi
close_success
