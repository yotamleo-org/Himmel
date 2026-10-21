#!/usr/bin/env bash
# scripts/ci/cr-first-measure.sh
#
# How much CI does a CodeRabbit finding waste? Over the last N merged PRs, read
# every pull_request ci.yml run, CodeRabbit's verdict on each run's head, and
# the jobs each run started, then print:
#
#   pr=<n> runs=R superseded=S cr_superseded=C cr_superseded_jobs=J cr_superseded_min=M
#   cr-first: prs=P runs=R superseded=S cr_superseded=C
#   cr-first: heads=H flagged=F clean=K skipped=K rate_limited=L absent=A
#   cr-first: review_latency_min n=N median=X p90=Y
#   cr-first: cr_superseded_jobs=J cr_superseded_min=M superseded_jobs=J superseded_min=M total_jobs=J total_min=M jobs_per_pr=X
#
# superseded    = a later run on this PR is at a different head.
# cr_superseded = superseded AND CodeRabbit posted >=1 actionable comment on
#                 this run's head: the run a CodeRabbit-first trigger never starts.
# Head verdict, first match wins: flagged (a review at this head with
#   "Actionable comments posted: N>0"), clean (a CodeRabbit success status that
#   is not a skip), rate_limited (a "Rate Limit Exceeded" comment between this
#   head's first run and the next head's), skipped (only skip statuses), absent.
# Latency = the head's first run created_at to its first non-skip success
#   status: push to review, the wait a CodeRabbit-first trigger would add.
# Jobs/minutes count only jobs that started (attempts included), minutes are
#   completed_at - started_at.
#
# Usage: cr-first-measure.sh [-R owner/repo] [--limit N] [--dump FILE]
#        cr-first-measure.sh --bundle FILE   (re-analyse a --dump, no API)
# Read-only. Any API error exits 1: a measurement with holes is not a number.
# ponytail: one page (100) of runs per branch and of statuses per head; a PR
# with more is undercounted, add --paginate there if one ever does.
# ponytail: a run belongs to a PR by its head being in the PR's commit list (a
# closed PR's runs carry an empty pull_requests), so runs on a head a force-push
# dropped are not counted; himmel forbids force-push, upgrade = a PR-event key.
set -uo pipefail

usage() { echo "usage: cr-first-measure.sh [-R owner/repo] [--limit N] [--dump FILE] | --bundle FILE" >&2; exit 2; }

REPO=""; LIMIT=50; DUMP=""; BUNDLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --limit) [ $# -ge 2 ] || usage; LIMIT="$2"; shift 2 ;;
    --dump) [ $# -ge 2 ] || usage; DUMP="$2"; shift 2 ;;
    --bundle) [ $# -ge 2 ] || usage; BUNDLE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$LIMIT" in ''|*[!0-9]*) usage ;; esac

die() { echo "cr-first-measure: $*" >&2; exit 1; }
# The jobs endpoint answers 502 now and then over a 50-PR sweep: 3 tries. The
# reply is buffered so a failed --paginate never leaves half its pages behind.
ghr() { local i r; for i in 1 2 3; do r="$(gh "$@")" && { printf '%s\n' "$r"; return 0; }; sleep $((i * 5)); done; return 1; }

# shellcheck disable=SC2016 # $-names here are jq variables, not shell
ANALYSE='
def fmt: (. * 10 | round / 10) | tostring | if test("\\.") then . else . + ".0" end;
def ts: fromdateiso8601;
def pct($q): sort as $a | if ($a | length) == 0 then "n/a"
  else $a[([(($q * ($a | length)) | ceil) - 1, 0] | max)] | fmt end;
def started: [.jobs[] | select(.s != null and .c != "skipped")];
def jobs: started | length;
def mins: [started[] | select(.e != null) | ((.e | ts) - (.s | ts))] | add // 0 | . / 60;
def done_status: .state == "success" and ((.description // "") | test("skip"; "i") | not);

map(
  . as $pr
  | ($pr.runs | sort_by(.created_at, .id)) as $runs
  | [$runs[] | .head_sha] as $order
  | ([$order | to_entries[] | select(.value as $h | $order[:.key] | index($h) | not) | .value]) as $heads
  | ($heads | map(. as $h | {key: $h, value: ([$runs[] | select(.head_sha == $h)][0].created_at)}) | from_entries) as $first
  | ($heads | to_entries | map({key: .value, value: ($heads[.key + 1] // null)}) | from_entries) as $next
  | ($heads | map(. as $h | ($pr.statuses[$h] // []) as $st
      | {key: $h, value: {
          state: (
            if any($pr.reviews[]; .commit_id == $h and .actionable > 0) then "flagged"
            elif any($st[]; done_status) then "clean"
            elif any($pr.rate_limits[]; ts >= ($first[$h] | ts)
                 and ($next[$h] == null or ts < ($first[$next[$h]] | ts))) then "rate_limited"
            elif ($st | length) > 0 then "skipped"
            else "absent" end),
          latency: ([$st[] | select(done_status) | .created_at | ts] | min
            | if . == null then null else (. - ($first[$h] | ts)) / 60 end)
        }}) | from_entries) as $verdict
  | ($runs | to_entries | map(.key as $i | .value + {
      superseded: ($runs[$i + 1:] | any(.head_sha != $runs[$i].head_sha)),
      jobs: (.value | jobs), mins: (.value | mins)})
    | map(. + {cr: (.superseded and $verdict[.head_sha].state == "flagged")})) as $rows
  | {pr: $pr.pr, rows: $rows, verdict: $verdict}
) as $prs
| ([$prs[].rows[]]) as $all
| ([$prs[].verdict[]]) as $heads
| ([$heads[] | .latency | select(. != null and . >= 0)]) as $lat
| def burn(sel): [$all[] | select(sel)] | {j: (map(.jobs) | add // 0), m: (map(.mins) | add // 0)};
  ($prs[] | "pr=\(.pr) runs=\(.rows | length) superseded=\([.rows[] | select(.superseded)] | length) cr_superseded=\([.rows[] | select(.cr)] | length) cr_superseded_jobs=\([.rows[] | select(.cr) | .jobs] | add // 0) cr_superseded_min=\([.rows[] | select(.cr) | .mins] | add // 0 | fmt)"),
  "cr-first: prs=\($prs | length) runs=\($all | length) superseded=\([$all[] | select(.superseded)] | length) cr_superseded=\([$all[] | select(.cr)] | length)",
  "cr-first: heads=\($heads | length)" + ([["flagged","clean","skipped","rate_limited","absent"][] as $s | " \($s)=\([$heads[] | select(.state == $s)] | length)"] | add),
  "cr-first: review_latency_min n=\($lat | length) median=\($lat | pct(0.5)) p90=\($lat | pct(0.9))",
  (burn(.cr) as $c | burn(.superseded) as $s | burn(true) as $t
   | "cr-first: cr_superseded_jobs=\($c.j) cr_superseded_min=\($c.m | fmt) superseded_jobs=\($s.j) superseded_min=\($s.m | fmt) total_jobs=\($t.j) total_min=\($t.m | fmt) jobs_per_pr=\(if ($prs | length) > 0 then $t.j / ($prs | length) | fmt else "n/a" end)")
'

if [ -n "$BUNDLE" ]; then
  [ -f "$BUNDLE" ] || die "no bundle $BUNDLE"
  jq -rs "$ANALYSE" "$BUNDLE" || die "cannot analyse $BUNDLE"
  exit 0
fi

if [ -z "$REPO" ]; then
  url="$(git remote get-url origin)" || die "no -R and no origin remote"
  REPO="$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
fi

out="$(mktemp "${TMPDIR:-/tmp}/cr-first-measure.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$out"' EXIT

prs="$(ghr pr list -R "$REPO" --state merged --limit "$LIMIT" --json number,headRefName \
  --jq '.[] | "\(.number)\t\(.headRefName)"')" || die "cannot list merged PRs"

while IFS=$'\t' read -r num branch; do
  [ -n "$num" ] || continue
  shas="$(ghr api --paginate "repos/$REPO/pulls/$num/commits?per_page=100" --jq '.[].sha' | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    || die "PR $num: cannot read commits"
  runs="$(ghr api "repos/$REPO/actions/workflows/ci.yml/runs?event=pull_request&per_page=100&branch=$(jq -rn --arg b "$branch" '$b | @uri')" \
    --jq '[.workflow_runs[] | {id, head_sha, created_at, conclusion}]' | jq -c --argjson shas "$shas" '[.[] | select(.head_sha as $h | $shas | index($h))]')" \
    || die "PR $num: cannot read runs"
  withjobs="[]"
  for id in $(jq -r '.[].id' <<<"$runs"); do
    jobs="$(ghr api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=all&per_page=100" \
      --jq '.jobs[] | {c: .conclusion, s: .started_at, e: .completed_at}' | jq -sc .)" || die "run $id: cannot read jobs"
    withjobs="$(jq -c --argjson id "$id" --argjson jobs "$jobs" 'map(if .id == $id then . + {jobs: $jobs} else . end)' <<<"$runs")"
    runs="$withjobs"
  done
  statuses="{}"
  for sha in $(jq -r '[.[].head_sha] | unique | .[]' <<<"$runs"); do
    st="$(ghr api "repos/$REPO/commits/$sha/statuses?per_page=100" \
      --jq '[.[] | select(.context == "CodeRabbit") | {state, description, created_at}]')" || die "$sha: cannot read statuses"
    statuses="$(jq -c --arg s "$sha" --argjson st "$st" '. + {($s): $st}' <<<"$statuses")"
  done
  reviews="$(ghr api --paginate "repos/$REPO/pulls/$num/reviews?per_page=100" \
    --jq '.[] | select(.user.login == "coderabbitai[bot]") | {commit_id, actionable: ((.body // "") | capture("Actionable comments posted: (?<n>[0-9]+)").n | tonumber? // 0)}' \
    | jq -sc .)" || die "PR $num: cannot read reviews"
  limits="$(ghr api --paginate "repos/$REPO/issues/$num/comments?per_page=100" \
    --jq '.[] | select(.user.login == "coderabbitai[bot]" and ((.body // "") | test("Rate Limit Exceeded"))) | .created_at' \
    | jq -Rsc 'split("\n") | map(select(length > 0))')" || die "PR $num: cannot read comments"
  jq -nc --argjson pr "$num" --argjson runs "$runs" --argjson statuses "$statuses" \
    --argjson reviews "$reviews" --argjson limits "$limits" \
    '{pr: $pr, runs: $runs, statuses: $statuses, reviews: $reviews, rate_limits: $limits}' >> "$out" \
    || die "PR $num: cannot assemble"
done <<<"$prs"

[ -z "$DUMP" ] || cp "$out" "$DUMP" || die "cannot write $DUMP"
jq -rs "$ANALYSE" "$out" || die "cannot analyse"
