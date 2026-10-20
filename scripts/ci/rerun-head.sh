#!/usr/bin/env bash
# scripts/ci/rerun-head.sh
#
# The one safe way to rerun CI: only ever a PR's HEAD run. The concurrency group
# ci-pr-<N> has cancel-in-progress, so a rerun counts as the newest request in
# the group; rerunning a run at a superseded sha therefore cancels the PR's real
# head run (2026-10-19: one bulk rerun of stale-sha runs held 34 of 61 running
# slots and cancelled 13 head runs).
#
#   rerun-head.sh [--dry-run] <pr>     rerun the newest CI run at the PR's current
#                                      head iff it is completed and failure /
#                                      cancelled / timed_out
#   rerun-head.sh [--dry-run] --run <id>  same, but refuse (exit 1) when <id>'s
#                                      head_sha is not its PR's current head
#   rerun-head.sh [--dry-run] --fleet  cancel-superseded-runs.sh first, then <pr>
#                                      mode for every open PR: the sanctioned
#                                      recovery after an outage
#
# A live head run, a green one, a run already rerun once (attempt above 1) or no
# run at the head are no-ops. Fails SAFE: every run read happens before the first
# rerun, so a gh or jq error there means nothing is rerun and exit 1; the PR heads
# are re-read right before each rerun and a head that moved is skipped. A rerun or
# re-read that itself fails is reported, the rest still go, and the exit is 1.
# -R comes from GH_REPO or the origin remote, never a hardcoded slug.
# Console-run only, not wired into any hook or workflow.
set -uo pipefail

WORKFLOW="ci.yml"
RUN_LIMIT=50
PR_LIMIT=200
RUN_FIELDS="databaseId,status,conclusion,event,headBranch,headSha,workflowName,attempt"

usage() { echo "usage: rerun-head.sh [--dry-run] (<pr> | --run <id> | --fleet)" >&2; exit 2; }

DRY=0; MODE=""; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --fleet) [ -z "$MODE" ] || usage; MODE=fleet; shift ;;
    --run) [ -z "$MODE" ] && [ $# -ge 2 ] || usage; MODE=run; ARG="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$MODE" ] || usage; MODE="pr"; ARG="$1"; shift ;;
  esac
done
[ -n "$MODE" ] || usage
[ "$MODE" = fleet ] || printf '%s' "$ARG" | grep -Eq '^[0-9]+$' || usage

die() { echo "rerun-head: $*; nothing rerun" >&2; exit 1; }

REPO="${GH_REPO:-}"
if [ -z "$REPO" ]; then
  url="$(git -C "$(dirname "$0")" remote get-url origin)" || die "GH_REPO unset and no origin remote"
  REPO="$(printf '%s' "$url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##; s#/$##')"
fi
printf '%s' "$REPO" | grep -Eq '^[^/[:space:]]+/[^/[:space:]]+$' || die "cannot read an owner/repo slug from '${GH_REPO:-origin}'"
export GH_REPO="$REPO"

# Open PRs as a JSON array; extra args (--head <b>) narrow the listing.
read_prs() {
  local out
  out="$(gh pr list -R "$REPO" --state open --json number,headRefName,headRefOid,isCrossRepository --limit "$PR_LIMIT" "$@")" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# The newest pull_request CI run at exactly sha $1 on branch $2 (two open PRs can
# share a commit; the branch keeps each to its own run), or {} when there is none.
head_run() {
  local runs
  runs="$(gh run list -R "$REPO" --workflow "$WORKFLOW" --commit "$1" --limit "$RUN_LIMIT" --json "$RUN_FIELDS")" || return 1
  printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$runs" | jq -c --arg sha "$1" --arg b "$2" \
    'map(select(.headSha == $sha and .headBranch == $b and .event == "pull_request")) | sort_by(.databaseId) | last // {}'
}

# "rerun<TAB>conclusion" or "noop<TAB>reason" for a head run.
decide() {
  printf '%s' "$1" | jq -r '
    if .databaseId == null then "noop\tno CI run at the head"
    elif .status != "completed" then "noop\thead run is live (\(.status))"
    elif (.conclusion | IN("success", "skipped", "neutral")) then "noop\thead run is green (\(.conclusion))"
    elif (.attempt // 1) > 1 then "noop\thead run was already rerun (attempt \(.attempt)), once per head"
    elif (.conclusion | IN("failure", "cancelled", "timed_out")) then "rerun\t\(.conclusion)"
    else "noop\thead run ended \(.conclusion), not rerunnable with --failed" end'
}

PLAN=()
# plan_pr <number> <headRefOid> <headRefName>: read the head run, queue a rerun or say why not.
plan_pr() {
  local run verdict action why
  run="$(head_run "$2" "$3")" || die "gh run list failed or unparseable for PR #$1"
  verdict="$(decide "$run")" || die "jq filter failed for PR #$1"
  IFS=$'\t' read -r action why <<< "$verdict"
  if [ "$action" = rerun ]; then
    PLAN+=("$1"$'\t'"$2"$'\t'"$(printf '%s' "$run" | jq -r '.databaseId')"$'\t'"$why")
  else
    echo "skip PR #$1 ${2:0:8}: $why"
  fi
}

# Rerun each planned run whose PR head has not moved, re-reading the PR heads
# right before every rerun.
apply() {
  local fresh entry pr oid id why now desc rc=0
  for entry in ${PLAN[@]+"${PLAN[@]}"}; do
    IFS=$'\t' read -r pr oid id why <<< "$entry"
    desc="$id PR #$pr head ${oid:0:8} ($why)"
    if [ "$DRY" -eq 1 ]; then echo "would-rerun $desc"; continue; fi
    if ! fresh="$(read_prs)"; then
      echo "rerun-failed $desc: gh pr list failed on the re-read" >&2; rc=1; continue
    fi
    now="$(printf '%s' "$fresh" | jq -r --argjson n "$pr" 'map(select(.number == $n)) | .[0].headRefOid // ""')" || { echo "rerun-failed $desc: jq failed on the re-read" >&2; rc=1; continue; }
    if [ "$now" != "$oid" ]; then
      echo "skip PR #$pr: head moved to ${now:0:8} since the reads, run $id is now stale"
      # an explicit <pr> / --run asked for this rerun; a fleet pass just moves on
      [ "$MODE" = fleet ] || rc=1
      continue
    fi
    if gh run rerun -R "$REPO" "$id" --failed >/dev/null 2>&1; then
      echo "rerun $desc"
    else
      echo "rerun-failed $desc" >&2; rc=1
    fi
  done
  return "$rc"
}

case "$MODE" in
  pr)
    prs="$(read_prs)" || die "gh pr list failed or unparseable"
    oid="$(printf '%s' "$prs" | jq -r --argjson n "$ARG" 'map(select(.number == $n)) | .[0].headRefOid // ""')" || die "jq filter failed"
    [ -n "$oid" ] || die "PR #$ARG is not among the open PRs"
    branch="$(printf '%s' "$prs" | jq -r --argjson n "$ARG" 'map(select(.number == $n)) | .[0].headRefName')" || die "jq filter failed"
    plan_pr "$ARG" "$oid" "$branch"
    ;;
  run)
    view="$(gh run view -R "$REPO" "$ARG" --json "$RUN_FIELDS")" || die "gh run view $ARG failed"
    printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1 || die "unparseable gh run view output"
    printf '%s' "$view" | jq -e '.workflowName == "CI" and .event == "pull_request"' >/dev/null 2>&1 \
      || die "run $ARG is not a pull_request CI run"
    branch="$(printf '%s' "$view" | jq -r '.headBranch')"; sha="$(printf '%s' "$view" | jq -r '.headSha')"
    prs="$(read_prs --head "$branch")" || die "gh pr list failed or unparseable"
    mine="$(printf '%s' "$prs" | jq -c --arg b "$branch" 'map(select(.headRefName == $b))')" || die "jq filter failed"
    [ "$(printf '%s' "$mine" | jq 'length')" = 1 ] || die "branch $branch has no single open PR to attribute run $ARG to"
    printf '%s' "$mine" | jq -e '.[0].isCrossRepository == false' >/dev/null 2>&1 || die "run $ARG belongs to a fork PR"
    oid="$(printf '%s' "$mine" | jq -r '.[0].headRefOid')"; pr="$(printf '%s' "$mine" | jq -r '.[0].number')"
    [ "$oid" = "$sha" ] || { echo "rerun-head: run $ARG is at ${sha:0:8}, not PR #$pr's current head ${oid:0:8}: stale, refused; nothing rerun" >&2; exit 1; }
    plan_pr "$pr" "$oid" "$branch"
    ;;
  fleet)
    cancel="$(dirname "$0")/cancel-superseded-runs.sh"
    if [ "$DRY" -eq 1 ]; then bash "$cancel" --dry-run; else bash "$cancel"; fi || die "cancel-superseded-runs.sh failed"
    prs="$(read_prs)" || die "gh pr list failed or unparseable"
    printf '%s' "$prs" | jq -e 'length < 200' >/dev/null 2>&1 || die "gh pr list hit its 200 limit, PR heads may be hidden"
    pairs="$(printf '%s' "$prs" | jq -r '.[] | [.number, .headRefOid, .headRefName] | @tsv')" || die "jq filter failed"
    while IFS=$'\t' read -r pr oid ref; do
      [ -n "$pr" ] || continue
      plan_pr "$pr" "$oid" "$ref"
    done <<< "$pairs"
    ;;
esac

apply
