#!/usr/bin/env bash
# scripts/ci/workflow-red-issue.sh -- maintain ONE `ci-red` issue per workflow
# and branch for the non-pull_request runs of the workflows listed in
# workflow-red-list.txt. Sibling of main-sweep-red-issue.sh, which
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
# A red manual dispatch (workflow_dispatch) on a non-default branch is not tracked:
# its branch merges and is deleted, so nothing would ever close the issue.
# Closing an issue stamps the run id into its body, and the lookup
# pages through closed issues too, so an older red run finishing after a newer
# green one is ignored.
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

# A red manual dispatch on a non-default branch is a proof run for a branch that
# is about to merge and vanish: no later green run of that branch ever closes the
# issue, so it is not opened (console-kit ready-check already gates a
# PR on its own dispatch runs). A green one still falls through and closes any
# issue left for the branch.
if [ "$red" -eq 1 ] && [ "$EVENT" = "workflow_dispatch" ]; then
  if ! default_branch="$(gh api "repos/$REPO" --jq .default_branch)"; then
    echo "workflow-red-issue: could not read the default branch of $REPO (gh api failed)" >&2
    exit 1
  fi
  if [ "$BRANCH" != "$default_branch" ]; then
    echo "workflow-red-issue: run $RUN_ID is a $EVENT run on '$BRANCH', not the default branch '$default_branch' -- not tracked."
    exit 0
  fi
fi

# wf:<slug> -- lowercase, runs of non-alphanumerics become one dash.
SLUG="$(printf '%s' "$WF" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//')"
WFLABEL="wf:$SLUG"
MARK="<!-- ci-red-branch: $BRANCH -->"

# --- the issues for (workflow, branch), open AND closed; a failed lookup is never "no issue" ---
# All pages of the label-filtered issue list (state=all keeps the closed ones, so
# a closed issue's last run id is a watermark). The branch marker is matched as
# data (grep -Fx over each decoded body), never interpolated into a jq filter: a
# git ref may carry a double quote.
if ! gh api --paginate "repos/$REPO/issues?state=all&per_page=100&labels=$LABEL,$WFLABEL" \
    --jq '.[] | "\(.number)\t\(.state)\t\(.body // "" | @base64)"' > "$TMP/issues" 2>/dev/null; then
  echo "workflow-red-issue: could not query existing issues (gh lookup failed) -- not creating/closing, to avoid a duplicate or a blind close." >&2
  exit 1
fi
num=""; body=""; seen_run=0
while IFS="$tab" read -r cand state b64; do
  [ -n "$cand" ] || continue
  if ! cbody="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"; then
    echo "workflow-red-issue: could not decode the body of issue #$cand -- not creating/closing, to avoid a duplicate or a blind close." >&2
    exit 1
  fi
  grep -Fxq -- "$MARK" <<< "$cbody" || continue
  # the newest run any issue of this branch has seen: open (the live issue) or closed (the watermark)
  r="$(printf '%s\n' "$cbody" | sed -n 's/^<!-- ci-red-run: \([0-9][0-9]*\) -->[[:space:]]*$/\1/p' | sort -n | tail -n 1)"
  [ -n "$r" ] && [ "$r" -gt "$seen_run" ] && seen_run="$r"
  if [ "$state" = "open" ] && [ -z "$num" ]; then num="$cand"; body="$cbody"; fi
done < "$TMP/issues"

# Ordering guard: an older run must not overwrite, reopen or close a newer verdict.
if [ "$seen_run" -gt "$RUN_ID" ]; then
  echo "workflow-red-issue: this branch's issue was last written by run $seen_run, newer than $RUN_ID -- ignoring this older run."
  exit 0
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
# Stamp this run into the body first: the closed issue is the watermark that keeps
# an older red run, finishing late, from opening a stale issue.
{ printf '%s\n' "$body"; echo "<!-- ci-red-run: $RUN_ID -->"; } > "$TMP/closed.md"
if ! gh issue edit "$num" --body-file "$TMP/closed.md"; then
  echo "workflow-red-issue: could not stamp run $RUN_ID into #$num -- leaving it open; retries on the next run." >&2
  exit 1
fi
gh issue comment "$num" --body "Green as of $(now) at $SHA: $WF passed on $BRANCH in $RUN_URL. Closing." || mut=1
gh issue close "$num" || mut=1
if [ "$mut" -ne 0 ]; then
  echo "workflow-red-issue: failed to close #$num (see above) -- retries on the next run." >&2
  exit 1
fi
exit 0
