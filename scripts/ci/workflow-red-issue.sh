#!/usr/bin/env bash
# scripts/ci/workflow-red-issue.sh -- maintain ONE `ci-red` issue per workflow
# and branch for the non-pull_request runs of the workflows listed in
# workflow-red-list.txt (HIMMEL-5595). Sibling of main-sweep-red-issue.sh, which
# keeps owning the `main-red` issue for CI itself; this script never touches CI.
#
# workflow-red.yml runs it once per completed run with the run id:
#
#   run red (failure / timed_out / startup_failure)
#                   -> open the issue for (workflow, branch) if absent, else refresh
#                      its body and add a "still red" comment.
#   run green       -> close that issue if open. A later green run of the SAME
#                      workflow on the SAME branch is the only thing that closes it.
#   anything else   -> (cancelled, skipped, ...) no verdict: no-op.
#   pull_request    -> never tracked: a leg owns its own PR's CI.
#   not in the list -> ignored.
#
# Identity: labels `ci-red` + `wf:<slug>` find the workflow's issues; the body
# marker `<!-- ci-red-branch: <branch> -->` picks the branch.
#
# ponytail: an out-of-order older red run that completes after a newer green run
# finds no open issue and opens a stale one (main-sweep-red-issue.sh stamps a
# closed-run marker for this, HIMMEL-5129), upgrade to that stamp if a stale
# ci-red issue is ever seen.
# ponytail: a run `cancelled` by timeout-minutes is no verdict here (main-sweep
# reads the job annotations for it), upgrade the same way if a hung job in a
# listed workflow goes unreported.
#
# Usage:  workflow-red-issue.sh <run-id>
# Env:
#   GITHUB_REPOSITORY   owner/repo (required) -- set by Actions.
#   GH_TOKEN            gh auth (issues:write, actions:read) -- supplied by the workflow.
#   WORKFLOW_RED_LIST   the workflow list file (default: workflow-red-list.txt beside this script).
set -uo pipefail

RUN_ID="${1:-}"
REPO="${GITHUB_REPOSITORY:-}"
LABEL="ci-red"
HERE="$(cd "$(dirname "$0")" && pwd)"
LIST="${WORKFLOW_RED_LIST:-$HERE/workflow-red-list.txt}"

case "$RUN_ID" in
  ''|*[!0-9]*) echo "usage: workflow-red-issue.sh <run-id>  (GITHUB_REPOSITORY=owner/repo)" >&2; exit 2 ;;
esac
if [ -z "$REPO" ]; then
  echo "workflow-red-issue: GITHUB_REPOSITORY is unset" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/workflow-red.XXXXXX")" || { echo "workflow-red-issue: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

tab="$(printf '\t')"

if ! run_line="$(gh api "repos/$REPO/actions/runs/$RUN_ID" \
    --jq '[.name, .event, .head_branch, .head_sha, (.conclusion // "none"), .html_url] | @tsv')"; then
  echo "workflow-red-issue: could not read run $RUN_ID (gh api failed)" >&2
  exit 1
fi
IFS="$tab" read -r WF EVENT BRANCH SHA CONCLUSION RUN_URL <<< "$run_line"

case "$EVENT" in
  pull_request|pull_request_target)
    echo "workflow-red-issue: run $RUN_ID is a $EVENT run -- legs own PR CI; not tracked."
    exit 0 ;;
esac

listed=0
if [ -r "$LIST" ]; then
  while IFS= read -r l; do
    case "$l" in ''|'#'*) continue ;; esac
    [ "$l" = "$WF" ] && listed=1
  done < "$LIST"
else
  echo "workflow-red-issue: workflow list '$LIST' is unreadable" >&2
  exit 1
fi
if [ "$listed" -ne 1 ]; then
  echo "workflow-red-issue: workflow '$WF' is not in $(basename "$LIST") -- ignored."
  exit 0
fi

case "$CONCLUSION" in
  failure|timed_out|startup_failure) red=1 ;;
  success)                           red=0 ;;
  *)
    echo "workflow-red-issue: run $RUN_ID concluded '$CONCLUSION' -- no verdict; nothing to report."
    exit 0 ;;
esac

# wf:<slug> -- lowercase, runs of non-alphanumerics become one dash.
SLUG="$(printf '%s' "$WF" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//')"
WFLABEL="wf:$SLUG"
MARK="<!-- ci-red-branch: $BRANCH -->"

# --- the open issue for (workflow, branch); a failed lookup is never "no issue" ---
# The branch marker is matched as data (grep -F over each issue body), never
# interpolated into a jq filter: a git ref may carry a double quote.
if ! gh issue list --label "$LABEL" --label "$WFLABEL" --state open --limit 100 \
    --json number --jq '.[].number' > "$TMP/open" 2>/dev/null; then
  echo "workflow-red-issue: could not query existing issues (gh lookup failed) -- not creating/closing, to avoid a duplicate or a blind close." >&2
  exit 1
fi
num=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  if ! cbody="$(gh issue view "$cand" --json body --jq .body 2>/dev/null)"; then
    echo "workflow-red-issue: could not read issue #$cand (gh failed) -- not creating/closing." >&2
    exit 1
  fi
  if grep -Fxq -- "$MARK" <<< "$cbody"; then num="$cand"; break; fi
done < "$TMP/open"

# Ordering guard: an older run must not overwrite or close a newer verdict.
body=""
if [ -n "$num" ]; then
  if ! body="$(gh issue view "$num" --json body --jq .body 2>/dev/null)"; then
    echo "workflow-red-issue: could not read issue #$num (gh failed) -- leaving it untouched." >&2
    exit 1
  fi
  seen_run="$(printf '%s\n' "$body" | sed -n 's/^<!-- ci-red-run: \([0-9][0-9]*\) -->[[:space:]]*$/\1/p' | sort -n | tail -n 1)"
  if [ -n "$seen_run" ] && [ "$seen_run" -gt "$RUN_ID" ]; then
    echo "workflow-red-issue: #$num was last written by run $seen_run, newer than $RUN_ID -- ignoring this older run."
    exit 0
  fi
fi

now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# --- red: open or refresh ---------------------------------------------------
if [ "$red" -eq 1 ]; then
  if ! gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" --paginate \
      --jq '.jobs[] | "\(.conclusion // "none")\t\(.name)\t\(.id)"' > "$TMP/jobs"; then
    echo "workflow-red-issue: could not read the jobs of run $RUN_ID (gh api failed)" >&2
    exit 1
  fi
  : > "$TMP/failed"
  while IFS="$tab" read -r concl name _; do
    case "$concl" in failure|timed_out) printf '%s\n' "$name" >> "$TMP/failed" ;; esac
  done < "$TMP/jobs"
  [ -s "$TMP/failed" ] || echo "(run concluded $CONCLUSION with no failed job -- see the run)" > "$TMP/failed"

  TITLE="$WF is red on $BRANCH (ci-red)"
  {
    echo "**Automated ci-red report** -- maintained in place by workflow-red.yml. Do not open duplicates; this issue is refreshed on each red run of **$WF** on **$BRANCH** and is closed automatically by the next green run of the same workflow on the same branch."
    echo ""
    echo "- workflow: $WF"
    echo "- branch: $BRANCH"
    echo "- event: $EVENT"
    echo "- tested sha: $SHA"
    echo "- run: $RUN_URL"
    echo "- last red run: $(now)"
    echo ""
    echo "Failed jobs:"
    while IFS= read -r n; do echo "- failed: $n"; done < "$TMP/failed"
    echo ""
    echo "$MARK"
    echo "<!-- ci-red-run: $RUN_ID -->"
  } > "$TMP/body.md"
  cat "$TMP/body.md"

  mut=0
  if [ -n "$num" ]; then
    echo "workflow-red-issue: refreshing existing issue #$num"
    gh issue edit "$num" --body-file "$TMP/body.md" || mut=1
    gh issue comment "$num" --body "Still red as of $(now) at $SHA: $RUN_URL" || mut=1
  else
    echo "workflow-red-issue: opening the ci-red issue for $WF on $BRANCH"
    gh label create "$LABEL" --color B60205 \
      --description "A tracked non-PR workflow run is red (auto-maintained)" --force || mut=1
    gh label create "$WFLABEL" --color 5319E7 \
      --description "ci-red: $WF" --force || mut=1
    gh issue create --title "$TITLE" --label "$LABEL" --label "$WFLABEL" --body-file "$TMP/body.md" || mut=1
  fi
  if [ "$mut" -ne 0 ]; then
    echo "workflow-red-issue: an issue mutation failed (see above) -- failing so the red run is not silently green." >&2
    exit 1
  fi
  exit 0
fi

# --- green: close the open issue ----------------------------------------------
if [ -z "$num" ]; then
  echo "workflow-red-issue: $WF is green on $BRANCH and has no open $LABEL issue -- nothing to do."
  exit 0
fi
echo "workflow-red-issue: $WF is green on $BRANCH (run $RUN_ID) -- closing #$num"
mut=0
gh issue comment "$num" --body "Green as of $(now) at $SHA: $WF passed on $BRANCH in $RUN_URL. Closing." || mut=1
gh issue close "$num" || mut=1
if [ "$mut" -ne 0 ]; then
  echo "workflow-red-issue: failed to close #$num (see above) -- retries on the next run." >&2
  exit 1
fi
exit 0
