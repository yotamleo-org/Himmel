#!/usr/bin/env bash
# scripts/handover/console-kit/cancel-runs.sh - console-run CI queue drain
# A console's own `gh run cancel` loop is refused by the auto-mode classifier
# (Interfere With Workloads); this named verb is the console's gated way to drain
# the hosted queue on an operator order.
#
# Usage:
#   cancel-runs.sh (--keep-pr <n> | --keep-sha <sha>)... [--live] [--max-cancels <n>] [--include-protected]
#   cancel-runs.sh --all [--live] [--max-cancels <n>] [--include-protected]
#
# DRY RUN BY DEFAULT: nothing is cancelled without --live. The repo is the
# `origin` remote's and is not overridable; --repo is accepted only when it
# equals origin. Only a github.com origin (https, ssh://, scp-style) is accepted;
# an ssh-config alias or an ssh.github.com:443 origin refuses (fail closed).
# Refuses (exit 3) in a console-spawned leg or a console relay,
# the same predicate go.sh uses.
#
# Cancels every non-completed Actions run whose head sha is not on the keep-list.
# --keep-pr <n> keeps the head of PR <n>; --keep-sha <sha> keeps a full 40-hex
# head; both repeat. Refuses (exit 2) with no keep unless --all is given, and
# --all with a keep. A keep that cannot be resolved refuses (exit 1) before
# anything is cancelled.
#
# Protected runs are never cancelled unless --include-protected: a run whose
# branch is main, or whose event is not pull_request/pull_request_target (push,
# including every tag push, schedule, workflow_dispatch, release, ...).
#
# Each cancel writes one stderr line: run, branch, sha, event, rc (+ gh's error).
# At most --max-cancels (default 100, 1-500) runs are cancelled per invocation.
# Cancels are paced: at most 10 in any minute and 30 in any 10 minutes (failed
# attempts count); the loop waits, so a full drain of 100 takes about 30 minutes.
#
# Prints: cancelled=<n> failed=<n> kept=<comma list of head shas, - if none>
# [protected=<n>] (a dry run appends would-cancel=<n>).
#
# Exit codes: 0 done; 1 gh failure, unresolvable keep, a failed cancel, a listing
# that hit the cap, or the cancel cap reached (cancelled what it could; re-run);
# 2 usage; 3 refused as a leg or relay.
#
# Literal `gh` only (no variable command name) so guard-pr-check-literal can
# verify the bytes. Linux/macOS bash 3.2+ (gh + jq).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too

# Same shared predicate go.sh and merge-on-green.sh enforce with. Fail closed: a
# broken or missing lib must never be read as "not a leg".
unset -f console_leg 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
    echo "cancel-runs: cannot load scripts/lib/go-gate.sh - refusing (the console-leg marker check must fail closed, not silently no-op)" >&2
    exit 1
fi
if console_leg; then
    echo "cancel-runs: refusing - this is a console-spawned leg (HIMMEL_CONSOLE_LEG is set); only the console drains CI. Send the request to your console." >&2
    exit 3
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "cancel-runs: refusing - this is a console relay (HIMMEL_CONSOLE_RELAY is set); only the console drains CI. Escalate to your console." >&2
        exit 3 ;;
esac

usage() {
    echo "usage: cancel-runs.sh (--keep-pr <n> | --keep-sha <sha>)... | --all [--live] [--max-cancels <n>] [--include-protected]" >&2
}

REPO_ARG=""
ALL=0
LIVE=0
DRY_FLAG=0
INCLUDE_PROTECTED=0
MAX_CANCELS=100
KEEPS=""
prs=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_FLAG=1; shift ;;
        --live) LIVE=1; shift ;;
        --all) ALL=1; shift ;;
        --include-protected) INCLUDE_PROTECTED=1; shift ;;
        --repo|--keep-pr|--keep-sha|--max-cancels)
            flag="$1"
            if [ "$#" -lt 2 ]; then usage; echo "cancel-runs: $flag needs a value" >&2; exit 2; fi
            val="$2"; shift 2
            case "$flag" in
                --repo)
                    printf '%s' "$val" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
                        || { usage; echo "cancel-runs: --repo needs owner/repo (got '$val')" >&2; exit 2; }
                    REPO_ARG="$val" ;;
                --keep-pr)
                    printf '%s' "$val" | grep -Eq '^[0-9]+$' \
                        || { usage; echo "cancel-runs: --keep-pr needs a number (got '$val')" >&2; exit 2; }
                    prs="$prs $val" ;;
                --keep-sha)
                    printf '%s' "$val" | grep -Eq '^[0-9a-f]{40}$' \
                        || { usage; echo "cancel-runs: --keep-sha needs a full 40-hex sha (got '$val')" >&2; exit 2; }
                    KEEPS="$KEEPS$val
" ;;
                --max-cancels)
                    if ! printf '%s' "$val" | grep -Eq '^[0-9]{1,3}$' || [ "$val" -lt 1 ] || [ "$val" -gt 500 ]; then
                        usage; echo "cancel-runs: --max-cancels needs a number from 1 to 500 (got '$val')" >&2; exit 2
                    fi
                    MAX_CANCELS="$val" ;;
            esac ;;
        *) usage; echo "cancel-runs: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [ "$LIVE" = 1 ] && [ "$DRY_FLAG" = 1 ]; then
    usage; echo "cancel-runs: --live contradicts --dry-run" >&2; exit 2
fi
if [ "$ALL" = 1 ] && { [ -n "$prs" ] || [ -n "$KEEPS" ]; }; then
    usage; echo "cancel-runs: --all contradicts a keep" >&2; exit 2
fi
if [ "$ALL" = 0 ] && [ -z "$prs" ] && [ -z "$KEEPS" ]; then
    usage; echo "cancel-runs: no keep given; pass --keep-pr/--keep-sha, or --all to cancel everything" >&2; exit 2
fi

# The repo is pinned to origin: a typo or a hostile --repo must not aim the cancels elsewhere.
if ! url="$(git remote get-url origin)"; then
    echo "cancel-runs: no origin remote; the repo is pinned to origin" >&2; exit 2
fi
# gh -R OWNER/REPO addresses the default host, so any origin host but github.com could aim the cancels at a different repo.
case "$url" in
    *://*) ohost="${url#*://}"; ohost="${ohost%%/*}"; ohost="${ohost##*@}"; ohost="${ohost%%:*}" ;;
    */*:* | *:*/*) case "${url%%:*}" in */*) ohost="" ;; *) ohost="${url%%:*}"; ohost="${ohost##*@}" ;; esac ;;
    *) ohost="" ;;
esac
ohost="$(printf '%s' "$ohost" | tr '[:upper:]' '[:lower:]')"
if [ "$ohost" != "github.com" ]; then
    echo "cancel-runs: origin host '${ohost:-none}' is not github.com; the repo is pinned to a github.com origin" >&2; exit 2
fi
REPO="$(printf '%s\n' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || { echo "cancel-runs: cannot read owner/repo from origin '$url'" >&2; exit 2; }
# Every gh call names the host too: a bare OWNER/REPO follows GH_HOST.
GHREPO="github.com/$REPO"
if [ -n "$REPO_ARG" ] && [ "$REPO_ARG" != "$REPO" ]; then
    echo "cancel-runs: --repo $REPO_ARG differs from origin $REPO; the repo is pinned to origin" >&2; exit 2
fi

for n in $prs; do
    sha="$(gh pr view "$n" -R "$GHREPO" --json headRefOid -q .headRefOid)"
    if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
        echo "cancel-runs: cannot resolve the head of PR $n on $REPO; nothing cancelled" >&2; exit 1
    fi
    KEEPS="$KEEPS$sha
"
done

# One listing per active status: an unfiltered listing is capped by --limit and
# newer completed runs would crowd the active ones out of it.
# A listing that fills the cap may hide more: cancel what was seen, then exit 1 so the
# caller re-runs to drain the rest.
LIMIT="${CANCEL_RUNS_LIMIT:-500}"
printf '%s' "$LIMIT" | grep -Eq '^[0-9]{1,4}$' && [ "$LIMIT" -ge 1 ] \
    || { echo "cancel-runs: CANCEL_RUNS_LIMIT needs a number from 1 to 9999 (got '$LIMIT')" >&2; exit 2; }
runs=""
truncated=0
for st in queued in_progress waiting requested pending; do
    part="$(gh run list -R "$GHREPO" --status "$st" --limit "$LIMIT" --json databaseId,status,headSha,headBranch,event)" \
        || { echo "cancel-runs: gh run list --status $st failed on $REPO; nothing cancelled" >&2; exit 1; }
    if [ "$(printf '%s' "$part" | jq 'length')" -ge "$LIMIT" ]; then
        echo "cancel-runs: the $st listing hit the cap of $LIMIT runs; re-run to drain the rest" >&2
        truncated=1
    fi
    runs="$runs$part"
done
# One tab-separated row per run, deduped by id: class (C cancel, P protected), id, branch, sha, event.
rows="$(printf '%s' "$runs" | jq -rs --arg keep "$KEEPS" --argjson incl "$INCLUDE_PROTECTED" '
    ($keep | split("\n")) as $k
    | [add[] | select(.status != "completed" and (.headSha as $h | $k | index($h) | not))]
    | unique_by(.databaseId)[]
    | (((.headBranch // "") == "main") or ((.event // "") as $e | ($e != "pull_request" and $e != "pull_request_target"))) as $p
    | [(if $p and ($incl == 0) then "P" else "C" end), (.databaseId | tostring), (.headBranch // "-"), .headSha, (.event // "-")]
    | @tsv')" \
    || { echo "cancel-runs: could not parse the run list; nothing cancelled" >&2; exit 1; }

protected="$(printf '%s\n' "$rows" | grep -c '^P')"

# Pacing: at most PACE_PER_MIN cancels in any 60 s and PACE_PER_WINDOW in any 600 s.
# CANCEL_RUNS_FAKE_CLOCK=<file> is the test seam: the clock is the integer in that file
# and a wait advances it instead of sleeping.
PACE_PER_MIN=10
PACE_PER_WINDOW=30
stamps=""
pace_now() {
    if [ -n "${CANCEL_RUNS_FAKE_CLOCK:-}" ]; then cat "$CANCEL_RUNS_FAKE_CLOCK"; else date +%s; fi
}
pace_nap() {
    if [ -n "${CANCEL_RUNS_FAKE_CLOCK:-}" ]; then
        echo $(($(cat "$CANCEL_RUNS_FAKE_CLOCK") + $1)) > "$CANCEL_RUNS_FAKE_CLOCK"
    else
        sleep "$1"
    fi
}
# pace_wait: block until one more cancel fits both windows; stamps holds each cancel's time, oldest first.
pace_wait() {
    while :; do
        now="$(pace_now)"
        keep_stamps=""; in_min=0; in_win=0; oldest_min=""; oldest_win=""
        for t in $stamps; do
            [ "$t" -gt $((now - 600)) ] || continue
            keep_stamps="$keep_stamps $t"
            in_win=$((in_win + 1))
            [ -n "$oldest_win" ] || oldest_win=$t
            if [ "$t" -gt $((now - 60)) ]; then
                in_min=$((in_min + 1))
                [ -n "$oldest_min" ] || oldest_min=$t
            fi
        done
        stamps="$keep_stamps"
        need=0
        [ "$in_min" -lt "$PACE_PER_MIN" ] || need=$((oldest_min + 60 - now))
        if [ "$in_win" -ge "$PACE_PER_WINDOW" ] && [ $((oldest_win + 600 - now)) -gt "$need" ]; then
            need=$((oldest_win + 600 - now))
        fi
        [ "$need" -gt 0 ] || return 0
        echo "cancel-runs: pacing - waiting ${need}s ($PACE_PER_MIN per minute, $PACE_PER_WINDOW per 10 minutes)" >&2
        pace_nap "$need"
    done
}
TAB="$(printf '\t')"
cancelled=0
failed=0
would=0
capped=0
while IFS="$TAB" read -r class id br sha ev; do
    [ "$class" = C ] || continue
    if [ "$LIVE" = 0 ]; then
        would=$((would + 1))
        continue
    fi
    if [ $((cancelled + failed)) -ge "$MAX_CANCELS" ]; then
        echo "cancel-runs: cap of $MAX_CANCELS cancels reached; re-run to drain the rest" >&2
        capped=1
        break
    fi
    pace_wait
    err="$(gh run cancel "$id" -R "$GHREPO" 2>&1 >/dev/null)"
    rc=$?
    stamps="$stamps $(pace_now)"
    printf 'cancel-runs: cancel run=%s branch=%s sha=%s event=%s rc=%s\n' "$id" "$br" "$sha" "$ev" "$rc" >&2
    if [ "$rc" -eq 0 ]; then
        cancelled=$((cancelled + 1))
    else
        failed=$((failed + 1))
        [ -z "$err" ] || printf '%s\n' "$err" >&2
    fi
done <<EOF
$rows
EOF

kept="$(printf '%s' "$KEEPS" | sort -u | sed '/^$/d' | paste -sd, -)"
[ -n "$kept" ] || kept="-"
prot=""
[ "$protected" -eq 0 ] || prot=" protected=$protected"
if [ "$LIVE" = 0 ]; then
    echo "cancel-runs: dry run (default); pass --live to cancel" >&2
    [ "$would" -le "$MAX_CANCELS" ] || echo "cancel-runs: a live run cancels at most $MAX_CANCELS of these per invocation" >&2
    echo "cancelled=0 failed=0 kept=$kept would-cancel=$would$prot"
else
    echo "cancelled=$cancelled failed=$failed kept=$kept$prot"
fi
[ "$failed" -eq 0 ] && [ "$truncated" -eq 0 ] && [ "$capped" -eq 0 ]
