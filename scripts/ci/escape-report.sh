#!/usr/bin/env bash
# scripts/ci/escape-report.sh -- one weekly page: what escaped, would CI have
# caught it, what did CI cost (source: section 6 of the ROI re-hardening spec).
#
# Read-only against Jira (`list`) and GitHub (`run list`, `run view`, `pr list`,
# `issue list`); the only file written is the report.
#
# Linux-only: needs GNU date (`date -d`); any other date exits 2 naming it.
#
# Usage: escape-report.sh --since YYYY-MM-DD [--out PATH] [--repo OWNER/NAME]
#   --out   report path (default: <handover root>/reports/ci-escape-weekly-<today>.md)
#   --repo  gh -R target (default: the checkout's own repo)
# Env:
#   ESCAPE_JIRA_CMD      the jira CLI command (default: node <primary checkout>/scripts/jira/dist/index.js)
#   ESCAPE_REPORT_DATE   today's date (tests)
# Exit: 0 ok, 2 usage, 3 a source was unreadable (the report is still written, the
#       section names what is missing under UNAVAILABLE).
#
# Sections: 1 escapes (Jira Bugs by found-by:* and escape:* label, UNLABELLED
# count), 2 would CI have caught it (fix PR changed a test, PR body records a RED
# line), 3 CI catches (a PR run failed and the next push to that branch changed the
# cause), 4 CI cost (<= 60 CI runs), 5 one line of judgement.
#
# ponytail: "impacted" is read as the pull_request runs (PR shards run only the
# impacted suites) and "full" as the schedule / dispatch / push runs, so no
# per-suite split; upgrade path = count suites per shard from the job logs.
# ponytail: the main-red root-cause split of spec section 1.1 is a manual
# classification and is not reproduced; only the issue count is.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_LIMIT=60

usage() { echo "usage: escape-report.sh --since YYYY-MM-DD [--out PATH] [--repo OWNER/NAME]" >&2; exit 2; }

SINCE=""; OUT=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    --out)   [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --repo)  [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$SINCE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) usage ;;
esac
date -u -d 1970-01-02 +%s >/dev/null 2>&1 || { echo "escape-report: needs GNU date (Linux-only)" >&2; exit 2; }
date -u -d "$SINCE" +%s >/dev/null 2>&1 || usage

TODAY="${ESCAPE_REPORT_DATE:-$(date -u +%F)}"
if [ -z "$OUT" ]; then
  # shellcheck source=../lib/handover-path.sh
  . "$ROOT/scripts/lib/handover-path.sh"
  hroot="$(handover_root_ensure)" || { echo "escape-report: no handover root; pass --out" >&2; exit 2; }
  OUT="$hroot/reports/ci-escape-weekly-$TODAY.md"
fi

if [ -n "${ESCAPE_JIRA_CMD:-}" ]; then
  read -r -a JIRA <<< "$ESCAPE_JIRA_CMD"
else
  primary="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)" \
    || { echo "escape-report: cannot find the primary checkout; set ESCAPE_JIRA_CMD" >&2; exit 2; }
  JIRA=(node "${primary%/.git}/scripts/jira/dist/index.js")
fi
export JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}"

GH=(gh)
[ -z "$REPO" ] || GH=(gh -R "$REPO")
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ ! -d "$OUT" ] || { echo "escape-report: --out $OUT is a directory; pass a report file path" >&2; exit 2; }
cd "$ROOT" || { echo "escape-report: cannot enter $ROOT" >&2; exit 1; }

# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh" || { echo "escape-report: cannot load prim.sh" >&2; exit 1; }
WORK="$(tmpdir)" || { echo "escape-report: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

rc=0
unavailable() { echo "UNAVAILABLE: $1 -- $2"; rc=3; }
one() { awk -v v="$1" 'BEGIN { printf "%.1f", v }'; }

FOUND_BY='operator|leg|console|tick|ci-pr|ci-main|review|user'
CLASSES='contract|merge-skew|platform|guard|flake'

# --- 1. Escapes ---------------------------------------------------------------
sec1="$WORK/sec1"; sec2="$WORK/sec2"
: > "$WORK/fb"; : > "$WORK/cls"; : > "$WORK/unlabelled"; : > "$WORK/done"; : > "$WORK/gaps"
bugs_ok=0
if "${JIRA[@]}" list --jql "project = HIMMEL AND issuetype = Bug AND created >= \"$SINCE\"" --labels --limit 200 > "$WORK/bugs.tsv" 2> "$WORK/jira.err"; then
  bugs_ok=1
  while IFS=$'\t' read -r key _type status title labels; do
    [ -n "$key" ] || continue
    fb="$(tr ',' '\n' <<< "$labels" | grep -E "^found-by:($FOUND_BY)\$" | head -1)"
    cl="$(tr ',' '\n' <<< "$labels" | grep -E "^escape:($CLASSES)\$" | head -1)"
    [ -z "$fb" ] || echo "$fb" >> "$WORK/fb"
    [ -z "$cl" ] || echo "$cl" >> "$WORK/cls"
    miss=""
    [ -n "$fb" ] || miss="found-by"
    [ -n "$cl" ] || miss="${miss:+$miss, }escape"
    [ -z "$miss" ] || printf -- '- %s (missing: %s) %s\n' "$key" "$miss" "$title" >> "$WORK/unlabelled"
    case "$(tr '[:upper:]' '[:lower:]' <<< "$status")" in
      done) printf '%s\t%s\n' "$key" "${cl:-}" >> "$WORK/done" ;;
    esac
  done < "$WORK/bugs.tsv"
fi

{
  echo "## 1. Escapes"
  echo
  if [ "$bugs_ok" = 1 ]; then
    echo "Bugs created since $SINCE: $(wc -l < "$WORK/bugs.tsv" | tr -d ' ')"
    [ "$(wc -l < "$WORK/bugs.tsv")" -lt 200 ] || unavailable "the full Bug list" "Jira returned its 200-row cap, so these totals are a sample; narrow --since"
    echo
    echo "By found-by:"
    if [ -s "$WORK/fb" ]; then sort "$WORK/fb" | uniq -c | awk '{ printf "- %s: %s\n", $2, $1 }'; else echo "- (none labelled)"; fi
    echo
    echo "By class:"
    if [ -s "$WORK/cls" ]; then sort "$WORK/cls" | uniq -c | awk '{ printf "- %s: %s\n", $2, $1 }'; else echo "- (none labelled)"; fi
    echo
    echo "UNLABELLED ($(wc -l < "$WORK/unlabelled" | tr -d ' ')):"
    cat "$WORK/unlabelled"
  else
    unavailable "section 1" "jira list failed: $(head -c 300 "$WORK/jira.err")"
  fi
  echo
  if "${GH[@]}" issue list --label main-red --state all --limit 200 --json number,createdAt > "$WORK/mainred.json" 2>/dev/null \
     && jq -e 'type == "array"' "$WORK/mainred.json" >/dev/null 2>&1; then
    echo "main-red issues opened since $SINCE: $(jq --arg s "$SINCE" '[.[]|select(.createdAt[0:10] >= $s)]|length' "$WORK/mainred.json")"
  else
    unavailable "main-red issue count" "gh issue list failed"
  fi
} > "$sec1"

# --- 2. Would CI have caught it ----------------------------------------------
{
  echo "## 2. Would CI have caught it"
  echo
  if [ "$bugs_ok" != 1 ]; then
    unavailable "section 2" "no Bug list (see section 1)"
  elif [ ! -s "$WORK/done" ]; then
    echo "(no Done escapes in the window)"
  else
    while IFS=$'\t' read -r key cl; do
      if ! "${GH[@]}" pr list --state merged --search "$key in:title" --json number,title,body,files,mergedAt --limit 5 > "$WORK/pr.json" 2>/dev/null </dev/null \
         || ! jq -e 'type == "array"' "$WORK/pr.json" >/dev/null 2>&1; then
        unavailable "fix PR of $key" "gh pr list failed"
        continue
      fi
      if [ "$(jq length "$WORK/pr.json")" = 0 ]; then
        echo "- $key: no fix PR found, GAP: no fix PR found"
        printf '%s\t%s\n' "$cl" "$key" >> "$WORK/gaps"
        continue
      fi
      num="$(jq -r 'if length == 1 then "PR #\(.[0].number)" else "PRs " + ([.[] | "#\(.number)"] | join(" ")) end' "$WORK/pr.json")"
      test_in="$(jq -r '[.[].files[].path | select(test("(^|/)test[-_][^/]*$|(^|/)tests?/|\\.test\\.[^/]*$"))] | if length > 0 then "yes" else "no" end' "$WORK/pr.json")"
      red="$(jq -r '[.[].body // "" | select(test("(^|[^A-Za-z])RED([^A-Za-z]|$)"))] | if length > 0 then "yes" else "no" end' "$WORK/pr.json")"
      line="- $key: $num, test in fix: $test_in, RED recorded: $red"
      if [ "$test_in" = no ]; then
        line="$line, GAP: no test in fix"
        printf '%s\t%s\n' "$cl" "$key" >> "$WORK/gaps"
      fi
      echo "$line"
    done < "$WORK/done"
  fi
} > "$sec2"

# --- 3 + 4. CI runs ------------------------------------------------------------
sec3="$WORK/sec3"; sec4="$WORK/sec4"
runs_ok=0; nojobs=0
if "${GH[@]}" run list --workflow ci.yml --limit "$RUN_LIMIT" --created ">=$SINCE" \
     --json databaseId,event,status,conclusion,createdAt,startedAt,updatedAt,headBranch,headSha > "$WORK/runs.json" 2> "$WORK/runs.err" \
   && jq -e 'type == "array"' "$WORK/runs.json" >/dev/null 2>&1; then
  runs_ok=1
  : > "$WORK/enriched.jsonl"; nojobs=0
  while IFS= read -r run; do
    id="$(jq -r '.databaseId' <<< "$run")"
    if "${GH[@]}" run view "$id" --json jobs > "$WORK/jobs.json" 2>/dev/null </dev/null && jq -e '.jobs' "$WORK/jobs.json" >/dev/null 2>&1 \
       && jq -c --argjson run "$run" '
        def sec: fromdateiso8601;
        ($run + {
          runner_s: ([.jobs[] | select(.conclusion != "skipped" and .startedAt != null and .completedAt != null)
                      | ((.completedAt | sec) - (.startedAt | sec)) | select(. > 0)] | add // 0),
          first_start: ([.jobs[].startedAt | select(. != null)] | min),
          families: ([.jobs[] | select(.conclusion == "failure") | .name | sub(" \\(.*$"; "")] | unique),
          passed: ([.jobs[] | select(.conclusion == "success") | .name | sub(" \\(.*$"; "")] | unique)
        })' "$WORK/jobs.json" >> "$WORK/enriched.jsonl"; then
      :
    else
      nojobs=$((nojobs + 1))
      jq -c --argjson run "$run" -n '$run + {runner_s: 0, first_start: null, families: [], passed: []}' >> "$WORK/enriched.jsonl"
    fi
  done < <(jq -c --arg s "$SINCE" '[.[] | select(.createdAt[0:10] >= $s)] | .[0:60][]' "$WORK/runs.json")

  stats_ok=0
  if jq -s -r '
    def sec: fromdateiso8601;
    def nextpush($f; $pr): [$pr[] | select(.headBranch == $f.headBranch and .createdAt > $f.createdAt and .headSha != $f.headSha)] | sort_by(.createdAt) | .[0];
    def fixed($f; $n): $n != null and $n.status == "completed" and ($f.families | length) > 0
      and ($f.families | all(. as $x | ($n.passed | index($x)) != null and ($n.families | index($x)) == null));
    def pct($p): sort as $a | if ($a | length) == 0 then "n/a"
      else $a[(((($p / 100) * ($a | length)) | ceil) - 1 | if . < 0 then 0 else . end)] end;
    . as $r
    | ($r | map(select(.event == "pull_request"))) as $pr
    | ($r | map(select(.event != "pull_request"))) as $other
    | ($pr | map(select(.conclusion == "failure"))) as $failed
    | ($failed | map(. as $f | select(fixed($f; nextpush($f; $pr))))) as $caught
    | [ ($r | length),
        ($pr | map(.runner_s) | add // 0) / 60,
        ($other | map(.runner_s) | add // 0) / 60,
        ($r | map(select(.conclusion == "cancelled") | .runner_s) | add // 0) / 60,
        ($pr | map(select(.status == "completed") | (((.updatedAt | sec) - ((.startedAt // .createdAt) | sec)) / 60)) | pct(50)),
        ($pr | map(select(.status == "completed") | (((.updatedAt | sec) - ((.startedAt // .createdAt) | sec)) / 60)) | pct(90)),
        ($r | map(select(.first_start != null) | (((.first_start | sec) - (.createdAt | sec)) / 60)) | pct(50)),
        ($failed | length), ($caught | length),
        ($r | map(.runner_s) | add // 0) / 60
      ] | @tsv' "$WORK/enriched.jsonl" > "$WORK/stats.tsv" 2>/dev/null \
     && IFS=$'\t' read -r n_runs pr_min full_min can_min wall50 wall90 q50 n_failed n_caught tot_min < "$WORK/stats.tsv" \
     && [ -n "$tot_min" ]; then
    stats_ok=1
  fi
  if [ "$stats_ok" = 1 ]; then
    num() { case "$1" in n/a) echo n/a ;; *) one "$1" ;; esac; }

    {
      echo "## 3. CI catches"
      echo
      echo "Catches: $n_caught (of $n_failed failed PR runs)"
      echo "Failed without a fixing next push: $((n_failed - n_caught))"
      echo
      echo "By job family:"
      jq -s -r '
        def nextpush($f; $pr): [$pr[] | select(.headBranch == $f.headBranch and .createdAt > $f.createdAt and .headSha != $f.headSha)] | sort_by(.createdAt) | .[0];
      def fixed($f; $n): $n != null and $n.status == "completed" and ($f.families | length) > 0
        and ($f.families | all(. as $x | ($n.passed | index($x)) != null and ($n.families | index($x)) == null));
        . as $r | ($r | map(select(.event == "pull_request"))) as $pr
        | ($pr | map(select(.conclusion == "failure"))) as $failed
        | $failed | map(. as $f | select(fixed($f; nextpush($f; $pr))))
        | map(.families[]) | group_by(.) | map({f: .[0], n: length}) | sort_by(-.n, .f)[] | "- \(.f): \(.n)"' "$WORK/enriched.jsonl" \
        || unavailable "job families" "jq failed"
      [ "$n_caught" != 0 ] || echo "- (none)"
    } > "$sec3"

    {
      echo "## 4. CI cost"
      echo
      echo "Runs sampled: $n_runs"
      [ "$nojobs" = 0 ] || unavailable "runner time of $nojobs run(s)" "gh run view failed; those runs count as 0 runner-min"
      echo "PR runner-min (impacted selection): $(one "$pr_min")"
      echo "Full runner-min (schedule, dispatch, push): $(one "$full_min")"
      echo "PR wall p50/p90 min: $(num "$wall50") / $(num "$wall90")"
      echo "Queue wait p50 min: $(num "$q50")"
      echo "Cancelled-run minutes: $(one "$can_min")"
      echo
      echo "Main sweep and nightly runs:"
      jq -s -r 'def sec: fromdateiso8601;
        map(select(.event != "pull_request" and .status == "completed"))
        | if length == 0 then "- (none in the sample)" else .[] | "- \(.databaseId) \(.event) \(.conclusion): \((((.updatedAt | sec) - ((.startedAt // .createdAt) | sec)) / 60) * 10 | round / 10) min" end' "$WORK/enriched.jsonl" \
        || unavailable "sweep runs" "jq failed"
    } > "$sec4"
  else
    runs_ok=0
    { echo "## 3. CI catches"; echo; unavailable "sections 3 and 4" "the run statistics could not be computed from the sampled runs"; } > "$sec3"
    { echo "## 4. CI cost"; echo; echo "UNAVAILABLE: see section 3"; } > "$sec4"
  fi
else
  {
    echo "## 3. CI catches"; echo
    unavailable "sections 3 and 4" "gh run list failed: $(head -c 300 "$WORK/runs.err")"
  } > "$sec3"
  { echo "## 4. CI cost"; echo; echo "UNAVAILABLE: see section 3"; } > "$sec4"
fi

# --- 5. One line of judgement --------------------------------------------------
{
  echo "## 5. Judgement"
  echo
  if [ "$runs_ok" = 1 ] && [ "$nojobs" = 0 ]; then
    echo "Catches per 1000 runner-min: $(awk -v c="$n_caught" -v m="$tot_min" 'BEGIN { if (m > 0) printf "%.1f", c / m * 1000; else printf "n/a" }')"
  else
    echo "Catches per 1000 runner-min: n/a"
  fi
  echo "Escapes by class: $(if [ -s "$WORK/cls" ]; then sort "$WORK/cls" | uniq -c | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'; else echo none labelled; fi)"
  echo
  echo "Top uncovered classes (ticket drafts for the console, not filed):"
  if [ -s "$WORK/gaps" ]; then
    awk -F'\t' '$1 != "" { n[$1]++; k[$1] = k[$1] (k[$1] == "" ? "" : ", ") $2 }
      END { for (c in n) printf "%d\t%s\t%s\n", n[c], c, k[c] }' "$WORK/gaps" | sort -t$'\t' -k1,1nr -k2,2 | head -3 \
    | awk -F'\t' '{ s = substr($2, 8); printf "%d. %s (%d %s without a test in the fix: %s): draft: test(%s): cover %s escapes with a test in the fix\n", NR, $2, $1, ($1 == 1 ? "escape" : "escapes"), $3, s, $2 }'
  else
    echo "(none)"
  fi
} > "$WORK/sec5"

mkdir -p "$(dirname "$OUT")" || { echo "escape-report: cannot create $(dirname "$OUT")" >&2; exit 1; }
{
  echo "# CI escape report since $SINCE"
  echo
  echo "Generated $TODAY by scripts/ci/escape-report.sh"
  echo
  cat "$sec1"; echo; cat "$sec2"; echo; cat "$sec3"; echo; cat "$sec4"; echo; cat "$WORK/sec5"
} > "$WORK/report.md"
mv "$WORK/report.md" "$OUT" || { echo "escape-report: cannot write $OUT" >&2; exit 1; }
echo "$OUT"
exit "$rc"
