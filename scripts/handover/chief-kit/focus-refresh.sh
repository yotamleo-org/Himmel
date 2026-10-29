#!/usr/bin/env bash
# scripts/handover/chief-kit/focus-refresh.sh - refresh the FOCUS page after a
# ship event, so the page the chief republishes shows what Jira, the PRs and
# the worker records say now. Best effort for the caller: it prints one line and
# the caller never fails on it.
#
# Usage: focus-refresh.sh --doc <chief doc> [--mirror-fresh <dir>] [--repo <owner/repo>]
#        focus-refresh.sh --doc <chief doc> --status
#        focus-refresh.sh --doc <chief doc> --mark-dirty
# The chief doc's `focus-version: <version>` line pins the page to that version;
# `auto`, or no line beside a `release: <R>` line, follows the current (first)
# version of release R (`release state`; a failed read is `focus=FAILED:release`).
# `none`, or no line and no release: `focus=skip`. `focus-plan: <file>` names the plan carrying the `priority:`
# line; <doc dir>/focus-chains.json holds the merge chains when present. The
# page goes to <doc dir>/roadmap-tracker.html (the path the tick reads).
#
# One refresh, under an exclusive lock on the mirror root (a second one prints
# `focus=busy` and does nothing), runs in this order; the first failure stops
# the run and prints `focus=FAILED:<stage>` (exit 1):
#   mirror    jira mirror, then versions, each staged and moved into place
#             (--mirror-fresh <dir> names a mirror the caller just refreshed and skips both)
#   sweep     status-sweep.sh, so Jira and the worker records are current; it keeps
#             its PR, check and thread snapshot in the stage for the drift pass. It runs
#             with a 60+20 s budget and fails as sweep:<why>: timeout, rc<n>, the
#             snapshot read it could not finish (gh, jira, ...), unknown
#   prs       one `gh pr list` snapshot, staged
#   render    tracker.py --version, staged
#   drift    status-drift.sh over the sweep's snapshot, staged (report only). It fails as
#             drift:<why>: timeout, rc<n>, budget (its own cut-off), gh, jira, no-sdrift, unknown
#   publish   the page and its fingerprint (.vfp) replace the old ones unless the page on
#             disk already carries `<meta name="himmel-focus" content="<version> <fp>">`
#             for this version and fingerprint, then focus-state is written
#   known-bugs-sync.sh runs between the drift file's publish and the focus-state write, bounded by the
#             budget left (best effort, skipped under 5 s; its log is known-bugs-sync.log)
# `focus=ok` (exit 0) means all of it ran. A page whose fingerprint did not move is
# left alone, so the republish stamp is not disturbed; a page another writer
# replaced is restored.
#
# focus-state (<doc dir>/focus-state, key=value): status (ok|FAILED), stage, gen,
# dirty (epoch of the first unrefreshed ship event), sha8 (page fingerprint), sdrift, ver (the version the page shows)
# (the drift line), ts. A refresh marks the state dirty when it starts and clears
# that only on success, so a run that dies midway reads as DIRTY.
# --status prints focus=ok | focus=DIRTY:<minutes>m | focus=FAILED:<stage> |
# focus=skip; --mark-dirty marks a ship event the refresh has not yet seen.
# The whole run is cut off at FOCUS_REFRESH_BUDGET seconds (default 240) and reads
# FAILED:timeout.
#
# ponytail: one current-version page and no per-version refresh, upgrade path = a
# --version loop over the doc's tracker-<version> lines.
#
# Test seams (env): FR_JIRA FR_SWEEP FR_TRACKER FR_DRIFT FR_KNOWN_SYNC (each one executable),
# TICK_TRACKER_MIRROR_DIR.
# Platform guard: POSIX bash 3.2+, flock optional; no .ps1 twin by design (shell-only harness).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
export LC_ALL=C
# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"

usage() {
    echo "usage: focus-refresh.sh --doc <chief doc> [--mirror-fresh <dir>] [--repo <owner/repo>] | --status | --mark-dirty" >&2
    exit 2
}
ORIG=("$@")
DOC="" FRESH="" REPO="" MODE=refresh
while [ "$#" -gt 0 ]; do
    case "$1" in
        --status) MODE=status; shift ;;
        --mark-dirty) MODE=dirty; shift ;;
        --doc | --mirror-fresh | --repo)
            [ "$#" -ge 2 ] || usage
            case "$1" in --doc) DOC="$2" ;; --mirror-fresh) FRESH="$2" ;; --repo) REPO="$2" ;; esac
            shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$DOC" ] || usage
[ -f "$DOC" ] || { echo "focus-refresh: $DOC is not a file" >&2; exit 2; }

VER=$(sed -n 's/^focus-version:[[:space:]]*//p' "$DOC" | head -n 1)
REL=$(sed -n 's/^release:[[:space:]]*//p' "$DOC" | head -n 1)
REL="${REL%%[[:space:]]*}"
case "$REL" in none*) REL="" ;; esac
case "$VER" in
    none*) echo "focus=skip"; exit 0 ;;
    '') [ -n "$REL" ] || { echo "focus=skip"; exit 0; }; VER=auto ;; # a declared release follows its current version
    auto | auto[[:space:]]*) VER=auto ;;
esac
[ "$VER" = auto ] || [[ "$VER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "focus-refresh: '$VER' is not a version name" >&2; exit 2; }

DIR=$(dirname "$DOC")
STATEF="$DIR/focus-state"
AGAIN="$DIR/focus-state.again"
OUT="$DIR/roadmap-tracker.html"
now() { date +%s; }

S_status="" S_stage="" S_gen=0 S_dirty="" S_sha8="" S_sdrift="" S_ver=""
load_state() {
    local k v
    S_status="" S_stage="" S_gen=0 S_dirty="" S_sha8="" S_sdrift="" S_ver=""
    if [ -f "$STATEF" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            case "$k" in
                status) S_status=$v ;; stage) S_stage=$v ;; gen) S_gen=$v ;;
                dirty) S_dirty=$v ;; sha8) S_sha8=$v ;; sdrift) S_sdrift=$v ;; ver) S_ver=$v ;;
            esac
        done < "$STATEF"
    fi
    case "$S_gen" in '' | *[!0-9]*) S_gen=0 ;; esac
}
save_state() {
    local t="$STATEF.tmp.$$"
    printf 'status=%s\nstage=%s\ngen=%s\ndirty=%s\nsha8=%s\nsdrift=%s\nver=%s\nts=%s\n' \
        "$S_status" "$S_stage" "$S_gen" "$S_dirty" "$S_sha8" "$S_sdrift" "$S_ver" "$(now)" > "$t" && mv -f "$t" "$STATEF"
}
load_state

if [ "$MODE" = status ]; then
    if [ ! -f "$STATEF" ]; then echo "focus=DIRTY:unknown"
    elif [ "$S_status" = FAILED ]; then echo "focus=FAILED:${S_stage:-unknown}"
    elif [ -n "$S_dirty" ]; then echo "focus=DIRTY:$(( ($(now) - S_dirty) / 60 ))m"
    # a request that landed after the last run read it and saved a clean state
    elif [ -f "$AGAIN" ]; then echo "focus=DIRTY:unknown"
    elif [ "$S_status" = ok ]; then echo "focus=ok"
    else echo "focus=DIRTY:unknown"; fi
    exit 0
fi
if [ "$MODE" = dirty ]; then
    [ -n "$S_dirty" ] || S_dirty=$(now)
    save_state
    # swallow-ok: an unwritable marker only loses the request that a running refresh stays DIRTY
    now > "$AGAIN" 2>/dev/null
    exit 0
fi

failed() { # <stage> - the run stops here; the page and the generation stay as they were
    [ -n "$S_dirty" ] || S_dirty=$(now)
    S_status=FAILED S_stage="$1"
    save_state
    echo "focus=FAILED:$1"
    exit 1
}

BUDGET="${FOCUS_REFRESH_BUDGET:-240}"
case "$BUDGET" in '' | *[!0-9]*) BUDGET=240 ;; esac

MIR="${TICK_TRACKER_MIRROR_DIR:-$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}}"
mkdir -p "${MIR%/*}" 2>/dev/null # swallow-ok: an unwritable mirror parent fails the mirror step by name

# the supervising process takes the lock before the budgeted child starts, so a killed child never frees it early
if [ -z "${FOCUS_REFRESH_LOCK_HELD:-}" ]; then
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$MIR.lock" || { echo "focus-refresh: cannot open $MIR.lock" >&2; exit 2; }
        if ! flock -n 9; then # prim-ok: a non-blocking single-instance guard, not a wait
            # swallow-ok: an unwritable marker only loses the request to re-run, the state file is unaffected
            now > "$AGAIN" 2>/dev/null
            echo "focus=busy"
            exit 0
        fi
    fi
    rm -f "$AGAIN" # a request made before this run is served by it
fi

if [ -z "${FOCUS_REFRESH_IN_BUDGET:-}" ] && [ -n "$_TIMEOUT_BIN" ]; then
    rc=0
    FOCUS_REFRESH_LOCK_HELD=1 FOCUS_REFRESH_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$BUDGET" bash "${BASH_SOURCE[0]}" "${ORIG[@]}" || rc=$?
    case "$rc" in 124 | 137) load_state; failed timeout ;; esac
    exit "$rc"
fi

# shellcheck disable=SC2329  # called by name through env_value
origin_slug() { git -C "$HERE" remote get-url origin | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##'; }
[ -n "$REPO" ] || REPO=$(env_value HIMMEL_REPO origin_slug) || { echo "focus-refresh: cannot resolve the himmel repo; pass --repo <owner/repo>" >&2; exit 2; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "focus-refresh: '$REPO' is not an owner/repo" >&2; exit 2; }
export GH_REPO="$REPO"

# swallow-ok: no git checkout leaves PRIMARY empty, and the mirror stage then fails by name
PRIMARY=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && PRIMARY="${PRIMARY%/.git}" || PRIMARY=""
if [ -n "${FR_JIRA:-}" ]; then JIRA=("$FR_JIRA"); else JIRA=(node "$PRIMARY/scripts/jira/dist/index.js"); fi
if [ -n "${FR_SWEEP:-}" ]; then SWEEP=("$FR_SWEEP"); else SWEEP=(bash "$HERE/status-sweep.sh"); fi
if [ -n "${FR_TRACKER:-}" ]; then TRACKER=("$FR_TRACKER"); else TRACKER=(python3 "$HERE/tracker.py"); fi
if [ -n "${FR_DRIFT:-}" ]; then DRIFT=("$FR_DRIFT"); else DRIFT=(bash "$HERE/status-drift.sh"); fi
if [ -n "${FR_KNOWN_SYNC:-}" ]; then KSYNC=("$FR_KNOWN_SYNC"); else KSYNC=(bash "$HERE/known-bugs-sync.sh"); fi

bounded() {
    local s=$1
    shift
    if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" -k 2 "$s" "$@"; else "$@"; fi
}

# focus-version: auto - the first version of the declared release (`release state <R> --json`;
# exit 3 is the CLI's not-OK status and still prints the state). A failed read is loud, never a stale version.
if [ "$VER" = auto ]; then
    rel_fail() { echo "focus-refresh: WARN: focus-version: auto: $1; the page is not rendered" >&2; failed release; }
    [[ "$REL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || rel_fail "no release: line in the chief doc"
    rc=0
    # swallow-ok: stderr is dropped, the exit code is checked on the next line and rel_fail names it
    rs=$(JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" bounded 60 "${JIRA[@]}" release state "$REL" --json 2>/dev/null) || rc=$?
    case "$rc" in 0 | 3) ;; *) rel_fail "release state $REL failed (rc$rc)" ;; esac
    # swallow-ok: unparseable output leaves VER empty and rel_fail names it
    VER=$(printf '%s' "$rs" | python3 -I -c 'import json,sys; v=json.load(sys.stdin)["versions"][0]; assert isinstance(v,str); print(v)' 2>/dev/null)
    [[ "$VER" =~ ^[A-Za-z0-9._-]+$ ]] || rel_fail "release $REL names no current version"
fi

load_state
NEWGEN=$((S_gen + 1))
[ -n "$S_dirty" ] || S_dirty=$(now)
save_state

stage=$(mktemp -d "$DIR/.focus-stage.XXXXXX") || failed stage  # prim-ok: the stage must share the doc dir's filesystem for the atomic mv
trap 'rm -rf "$stage"' EXIT

if [ -n "$FRESH" ]; then
    MIR="$FRESH"
else
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" bounded 120 "${JIRA[@]}" mirror --root "$MIR" >/dev/null 2>&1 || failed mirror
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" bounded 120 "${JIRA[@]}" versions > "$stage/versions.tsv" 2>/dev/null || failed versions
    mv -f "$stage/versions.tsv" "$MIR.versions.tsv" || failed versions
fi

# the sweep's own budget plus grace (60+20) ends inside the 90 s bound, so it reports why it stopped
rc=0
sweep_out=$(TICKET_STATUS_SWEEP_BUDGET=60 TICKET_STATUS_SWEEP_GRACE=20 bounded 90 "${SWEEP[@]}" --repo "$REPO" --snapshot-out "$stage/snap" 2>&1) || rc=$?
sweep_failed() { # <cause>
    last=$(printf '%s\n' "$sweep_out" | grep '^status-sweep:' | tail -n 1)
    [ -z "$last" ] || echo "focus-refresh: $last" >&2
    failed "sweep:$1"
}
case "$rc" in 0) ;; 124 | 137) sweep_failed timeout ;; *) sweep_failed "rc$rc" ;; esac
case "$sweep_out" in
    *"status-sweep: unknown (timeout"*) sweep_failed timeout ;;
    *"status-sweep: unknown (snapshot "*)
        why=$(printf '%s\n' "$sweep_out" | sed -n 's/.*status-sweep: unknown (snapshot \([^)]*\)).*/\1/p' | tail -n 1)
        [[ "$why" =~ ^[a-z-]+$ ]] || why=unknown
        sweep_failed "$why" ;;
    *"status-sweep: unknown"*) sweep_failed unknown ;;
esac
moved=$(printf '%s\n' "$sweep_out" | sed -n 's/.* moved=\([0-9][0-9]*\).*/\1/p' | tail -n 1)
if [ "${moved:-0}" -gt 0 ]; then
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" bounded 120 "${JIRA[@]}" mirror --root "$MIR" >/dev/null 2>&1 || failed mirror
fi

bounded 60 gh pr list --state open --limit 300 --json number,title,headRefName,headRefOid,isDraft,statusCheckRollup > "$stage/prs.json" 2>/dev/null || failed prs

plan=$(sed -n 's/^focus-plan:[[:space:]]*//p' "$DOC" | head -n 1)
case "$plan" in none*) plan="" ;; esac
set -- --version "$VER" --out "$stage/page.html" --mirror-dir "$MIR" --versions-file "$MIR.versions.tsv" \
    --prs-file "$stage/prs.json" --workers-dir "$(ts_state_dir)/workers" --repo "$REPO"
[ -z "$plan" ] || set -- "$@" --priority-file "$plan"
[ ! -f "$DIR/focus-chains.json" ] || set -- "$@" --chains-file "$DIR/focus-chains.json"
bounded 120 "${TRACKER[@]}" "$@" >/dev/null 2>&1 || failed render
{ [ -f "$stage/page.html" ] && [ -f "$stage/page.html.vfp" ]; } || failed render
vfp=$(cat "$stage/page.html.vfp")

rc=0
bounded 120 "${DRIFT[@]}" --repo "$REPO" --snapshot "$stage/snap" > "$stage/drift.txt" 2>/dev/null || rc=$?
case "$rc" in 0) ;; 124 | 137) failed drift:timeout ;; *) failed "drift:rc$rc" ;; esac
sdrift=$(tail -n 1 "$stage/drift.txt")
case "$sdrift" in
    sdrift=unknown)
        case "$(grep -m 1 '^HEALTH - ' "$stage/drift.txt")" in
            'HEALTH - drift:'*) failed drift:budget ;;
            'HEALTH - gh:'*) failed drift:gh ;;
            'HEALTH - jira:'*) failed drift:jira ;;
            *) failed drift:unknown ;;
        esac ;;
    sdrift=?*) ;;
    *) failed drift:no-sdrift ;;
esac

if ! grep -Fq "<meta name=\"himmel-focus\" content=\"$VER $vfp\">" "$OUT" 2>/dev/null; then
    mv -f "$stage/page.html" "$OUT" || failed publish
    mv -f "$stage/page.html.vfp" "$OUT.vfp" || failed publish
fi
mv -f "$stage/drift.txt" "$DIR/focus-drift.txt" || failed publish
# Keep the known-checker-bugs file and the checker ticket's Jira links in step. Best effort: a failed sync never fails the refresh.
ksync_left=$((BUDGET - SECONDS - 5)) # leave the run's own cut-off out of reach, so a slow sync never turns a published refresh into FAILED:timeout
[ "$ksync_left" -le 60 ] || ksync_left=60
if [ "$ksync_left" -ge 5 ]; then
    KBS_JIRA="${FR_JIRA:-}" bounded "$ksync_left" "${KSYNC[@]}" --checker HIMMEL-7980 --log "$DIR/known-bugs-sync.log" >/dev/null 2>&1 \
        || echo "focus-refresh: WARN: known-bugs-sync failed; the known-checker-bugs file is as it was" >&2
else
    echo "focus-refresh: WARN: known-bugs-sync skipped; too little of the refresh budget is left" >&2
fi
S_status=ok S_stage="" S_gen=$NEWGEN S_dirty="" S_sha8="${vfp:0:8}" S_sdrift="${sdrift#sdrift=}" S_ver="$VER"
again=""
[ ! -f "$AGAIN" ] || again=$(cat "$AGAIN")
if [[ "$again" =~ ^[0-9]+$ ]]; then
    S_dirty=$again # a request arrived while this run held the lock: its snapshot may predate it
fi
save_state || failed publish
echo "focus=ok"
exit 0
