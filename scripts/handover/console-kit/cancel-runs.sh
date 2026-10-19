#!/usr/bin/env bash
# scripts/handover/console-kit/cancel-runs.sh - console-run CI queue drain
# A console's own `gh run cancel` loop is refused by the auto-mode classifier
# (Interfere With Workloads); this named verb is the console's gated way to drain
# the hosted queue on an operator order.
#
# Usage:
#   cancel-runs.sh [--repo <owner/repo>] (--keep-pr <n> | --keep-sha <sha>)... [--dry-run]
#   cancel-runs.sh [--repo <owner/repo>] --all [--dry-run]
#
# Cancels every non-completed Actions run on the repo (default: the `origin`
# remote's) whose head sha is not on the keep-list. --keep-pr <n> keeps the
# head of PR <n>; --keep-sha <sha> keeps a full 40-hex head; both repeat.
# Refuses (exit 2) with no keep unless --all is given, and --all with a keep.
# A keep that cannot be resolved refuses (exit 1) before anything is cancelled.
#
# Prints: cancelled=<n> failed=<n> kept=<comma list of head shas, - if none>
# (--dry-run cancels nothing and appends would-cancel=<n>).
#
# Exit codes: 0 done; 1 gh failure, unresolvable keep, or a failed cancel;
# 2 usage.
#
# Literal `gh` only (no variable command name) so guard-pr-check-literal can
# verify the bytes. Linux/macOS bash 3.2+ (gh + jq).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too

usage() {
    echo "usage: cancel-runs.sh [--repo <owner/repo>] (--keep-pr <n> | --keep-sha <sha>)... | --all [--dry-run]" >&2
}

REPO=""
ALL=0
DRY_RUN=0
KEEPS=""
prs=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --all) ALL=1; shift ;;
        --repo|--keep-pr|--keep-sha)
            flag="$1"
            if [ "$#" -lt 2 ]; then usage; echo "cancel-runs: $flag needs a value" >&2; exit 2; fi
            val="$2"; shift 2
            case "$flag" in
                --repo)
                    printf '%s' "$val" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
                        || { usage; echo "cancel-runs: --repo needs owner/repo (got '$val')" >&2; exit 2; }
                    REPO="$val" ;;
                --keep-pr)
                    printf '%s' "$val" | grep -Eq '^[0-9]+$' \
                        || { usage; echo "cancel-runs: --keep-pr needs a number (got '$val')" >&2; exit 2; }
                    prs="$prs $val" ;;
                --keep-sha)
                    printf '%s' "$val" | grep -Eq '^[0-9a-f]{40}$' \
                        || { usage; echo "cancel-runs: --keep-sha needs a full 40-hex sha (got '$val')" >&2; exit 2; }
                    KEEPS="$KEEPS$val
" ;;
            esac ;;
        *) usage; echo "cancel-runs: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [ "$ALL" = 1 ] && { [ -n "$prs" ] || [ -n "$KEEPS" ]; }; then
    usage; echo "cancel-runs: --all contradicts a keep" >&2; exit 2
fi
if [ "$ALL" = 0 ] && [ -z "$prs" ] && [ -z "$KEEPS" ]; then
    usage; echo "cancel-runs: no keep given; pass --keep-pr/--keep-sha, or --all to cancel everything" >&2; exit 2
fi

if [ -z "$REPO" ]; then
    if ! url="$(git remote get-url origin)"; then
        echo "cancel-runs: no origin remote and no --repo" >&2; exit 2
    fi
    REPO="$(printf '%s\n' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
    printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
        || { echo "cancel-runs: cannot read owner/repo from origin '$url'" >&2; exit 2; }
fi

for n in $prs; do
    sha="$(gh pr view "$n" -R "$REPO" --json headRefOid -q .headRefOid)"
    if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
        echo "cancel-runs: cannot resolve the head of PR $n on $REPO; nothing cancelled" >&2; exit 1
    fi
    KEEPS="$KEEPS$sha
"
done

# One listing per active status: an unfiltered listing is capped by --limit and
# newer completed runs would crowd the active ones out of it.
runs=""
for st in queued in_progress waiting requested pending; do
    part="$(gh run list -R "$REPO" --status "$st" --limit 500 --json databaseId,status,headSha)" \
        || { echo "cancel-runs: gh run list --status $st failed on $REPO; nothing cancelled" >&2; exit 1; }
    runs="$runs$part"
done
ids="$(printf '%s' "$runs" | jq -rs --arg keep "$KEEPS" \
    '($keep | split("\n")) as $k | add[] | select(.status != "completed" and (.headSha as $h | $k | index($h) | not)) | .databaseId')" \
    || { echo "cancel-runs: could not parse the run list; nothing cancelled" >&2; exit 1; }

cancelled=0
failed=0
would=0
for id in $ids; do
    if [ "$DRY_RUN" = 1 ]; then
        would=$((would + 1))
    elif gh run cancel "$id" -R "$REPO" >/dev/null 2>&1; then
        cancelled=$((cancelled + 1))
    else
        failed=$((failed + 1))
    fi
done

kept="$(printf '%s' "$KEEPS" | sort -u | sed '/^$/d' | paste -sd, -)"
[ -n "$kept" ] || kept="-"
if [ "$DRY_RUN" = 1 ]; then
    echo "cancelled=0 failed=0 kept=$kept would-cancel=$would"
else
    echo "cancelled=$cancelled failed=$failed kept=$kept"
fi
[ "$failed" -eq 0 ]
