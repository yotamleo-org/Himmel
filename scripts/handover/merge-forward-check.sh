#!/usr/bin/env bash
# scripts/handover/merge-forward-check.sh.
# Read-only decision for the worker preface's merge-forward rule. Invariant: a worker
# never merges, or merges forward past, a red its own change introduced.
# Merge-forward cures ONLY a red inherited from a broken base.
#
#   merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file>
#                          --pr-cases <file> --base-cases <file>
#                          --base-sha <sha> --main-base-sha <sha> --latest-sha <sha>
#                          --pr-sha <sha> --main-base-conclusion <conclusion>
#                          [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha>
#                           --base-cover-conclusion <conclusion>]
#
# Each job file is one run's job list, one `<job name><TAB><conclusion>` per line
# (e.g. from `gh run view <id> --json jobs`):
#   --pr           the PR's own CI run
#   --main-base    main's CI run AT THE PR's MERGE-BASE commit (cron or dispatch; an
#                  EMPTY regular file when no run exists at that exact commit)
#   --main-latest  main's latest completed CI run
# Each case file lists the failing cases of a run, one `<job><TAB><case>` per
# line, read from the failed-job logs:
#   --pr-cases     the PR run's failing cases      --base-cases  the base run's
# ALLOW only if EVERY red PR job is red on --main-base (so it was inherited),
# every failing case of that PR job is among the base run's failing cases for
# the same job (a PR shard runs only the impacted suites and main shards run the
# full sweep, so a matching job name alone proves nothing: an extra failing case
# is the PR's own red), AND the job is success on --main-latest (so main has
# since been fixed). Everything else REFUSES: a job missing from either main run,
# a job green at the base, a job red on latest main, a PR job with no recorded
# failing case or with a case the base run did not fail.
# The job files carry no commit sha, so the shas are REQUIRED and non-empty:
# --base-sha must equal `git merge-base origin/main HEAD` (computed here, after a
# fetch, from the worker's own repo) and --main-base-sha (the base run's headSha
# from `gh run list --commit`); --latest-sha (the latest run's headSha) must equal
# an ancestor-or-equal of `git rev-parse origin/main` (main CI is a
# 7 h cron plus dispatch, so the latest completed run is usually behind the tip)
# and a descendant-or-equal of the verdict run (the covering run, else the
# merge-base), so a run from before the base cannot stand in for latest.
# --pr-sha (the PR run's headSha) must equal `git rev-parse HEAD`, so an
# older PR run cannot stand in for the current head.
# Exit 0 = ALLOW  1 = REFUSE  2 = usage / unreadable input
#      3 = nothing to merge forward: no red on the PR, or (--chain-s2 mode) the predecessor is already in HEAD
# Red = failure | timed_out | startup_failure.
# --main-base-conclusion / --base-cover-conclusion are the RUN's conclusion from
# `gh run view <id> --json conclusion` (`none` when no run exists at the merge-base):
# a cancelled run keeps the job rows that had finished, and its aggregator job fails
# because its shards were cancelled, so the rows alone read as a real red.
# main CI runs on a cron and on dispatch, so most
# merge-bases have NO run at their own commit (an empty --main-base file), and a
# run that exists may be cancelled. Either way the base verdict comes from the
# next completed main run covering the merge-base — the
# same contiguous-range attribution main-sweep-red uses: --base-cover-from (the
# previous completed sweep's headSha) must be a strict ancestor of the merge-base,
# the merge-base an ancestor of --base-cover-sha, and that sha on origin/main;
# --base-cases are then the covering run's failing cases. Without the trio
# (--base-cover, --base-cover-sha, --base-cover-from) a base with no completed run
# REFUSEs: wait for the next cron or dispatch run. A run whose conclusion is
# cancelled is cancelled whatever its job rows say, and --main-base-conclusion /
# --base-cover-conclusion carry that, so the script no longer trusts the rows alone.
# only success and failure are completed verdicts; any other conclusion
# REFUSEs (cancelled routes a base to the cover), and none is accepted for the base
# only with an empty file and never for a cover.
# the covering run is usually the one that carries the fix, so a red the PR
# inherited reads green there and looked like the PR's own. --base-cases-local <file>
# (`<job><TAB><case>`, the cases reproduced FAILING at the merge-base by running the failing
# suite there in a scratch worktree) lets a COVERING-run verdict yield: a job green on the
# cover is still inherited when EVERY failing case of the PR's job is in that file, and it is
# green on latest. It never overrides a completed run at the merge-base itself, and a case the
# PR's own diff introduced does not fail at the merge-base, so it stays the PR's own red.
# The file is bound to the merge-base: a required `# merge-base <40-hex>` header equal to
# --base-sha (missing or mismatched exits 2), `# command` and `# log` headers that the ALLOW
# line cites, and rows `<job><TAB><case><TAB><exit status>` (a zero status is no reproduction).
# ponytail: the file is still self-reported by the worker; the script checks only that the cited log
# exists and is non-empty, and the chief reviews its content. Upgrade path is this script running
# the reproduction itself in a scratch worktree at the merge-base.
# ponytail: the case lists are extracted from logs by the caller and taken as
# given, so a wrong list can still mislead; upgrade path is parsing the failed
# job logs here if that ever bites.
# ponytail: the script cannot see whether another completed run lies inside
# (from, cover], nor a newer one than --main-latest, so "next" and "latest" are
# taken from the caller; upgrade path is listing the main runs with gh here if a
# wrong one ever bites.
# ponytail: a red cover proves the failure existed somewhere in (from, cover], not
# at the merge-base itself, so a case introduced and fixed inside that range can
# read as inherited; ALLOW also needs it green on latest, which bounds this, and
# the upgrade path is per-commit main runs (or the gh push-run listing above).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"
# shellcheck source=../lib/prim.sh
. "$SCRIPT_DIR/../lib/prim.sh" || exit 2
git_env_scrub
# a run with no job rows, or only cancelled/skipped rows and at least one cancelled, was cancelled (a superseded pending sweep has 0 jobs)
is_cancelled() { awk -F'\t' 'NF {n++} NF && $2=="cancelled" {c++} NF && $2!="cancelled" && $2!="skipped" {o=1} END {exit !(n==0 || (!o && c))}' "$1"; }
# The chain-s2 reason: a separate mode, entered only when the FIRST argument is --chain-s2, so every
# invocation below it is untouched. It ALLOWs one merge of origin/main into a GREEN PR whose S2 predecessor has
# merged. It derives its own evidence, reads no flag and trusts no caller-written plan:
#   merge-forward-check.sh --chain-s2 <pr> --predecessor <pred> --pr <file> --pr-sha <sha>
# <pr> must be HEAD's PR (gh pr view --json number,headRefOid on the current branch, its head equal to HEAD). <pred>
# must be MERGED (gh pr view <pred> --json state,mergeCommit,headRefOid) with its merge commit on origin/main. The
# pair is rebuilt by chief-kit/chain-graph.py --pair <pred>@<premerge head> <pr> (a fresh cache, the gh seam
# scrubbed) and planned by chief-kit/chain-plan-core.sh --evidence with <pred> ready: ALLOW only on the line
# `MERGE-FORWARD <pr> after <pred>`. --chain-plan is dropped: a plan file the caller wrote is never trusted (REFUSE).
# --pr/--pr-sha: the PR's own CI run, as above.
# Exit 0 = ALLOW  1 = REFUSE  2 = usage  3 = the predecessor is already in HEAD
# The graph's jira_links must be ok: an unread Blocks link could hide an H1 pair, so unknown links REFUSE.
# ponytail: the Jira command seam of chain-graph.py stays honoured, like gh on PATH: the caller's environment
# is trusted to reach the real Jira; upgrade path is resolving both from the primary checkout here.
chain_s2() {
  local cpr="" pred="" jobs="" psha="" bad=0 a tip head reds view num hro state moid phead rmoid sd jl out edge line
  for a in "$@"; do
    if [ "$a" = --chain-plan ]; then
      echo "usage: merge-forward-check.sh --chain-s2 <pr> --predecessor <pred> --pr <file> --pr-sha <sha> (--chain-plan is dropped)" >&2
      echo "REFUSE — --chain-plan is dropped: a caller-written plan file is never trusted. Pass --predecessor <pred>; the check derives the pair itself. Do not merge forward."
      exit 1
    fi
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      --chain-s2) [ $# -ge 2 ] || { bad=1; break; }; cpr="$2"; shift 2 ;;
      --predecessor) [ $# -ge 2 ] || { bad=1; break; }; pred="${2#\#}"; shift 2 ;;
      --pr) [ $# -ge 2 ] || { bad=1; break; }; jobs="$2"; shift 2 ;;
      --pr-sha) [ $# -ge 2 ] || { bad=1; break; }; psha="$2"; shift 2 ;;
      *) bad=1; break ;;
    esac
  done
  if [ "$bad" -eq 1 ] || ! [[ "$cpr" =~ ^[0-9]+$ ]] || ! [[ "$pred" =~ ^[0-9]+$ ]] || [ "$pred" = "$cpr" ] \
     || [ ! -f "$jobs" ] || [ ! -r "$jobs" ] || [ -z "$psha" ]; then
    echo "usage: merge-forward-check.sh --chain-s2 <pr> --predecessor <pred> --pr <file> --pr-sha <sha> (no other flag)" >&2
    exit 2
  fi
  if awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 !~ /^(success|failure|cancelled|skipped|neutral|timed_out|startup_failure|action_required|stale)$/) {exit 1}' "$jobs"; then :; else
    echo "usage: $jobs has a malformed row (want <job><TAB><conclusion>): a skipped or misread row could hide a red" >&2
    exit 2
  fi
  reds="$(awk -F'\t' 'NF && $2 != "success" && $2 != "skipped" && $2 != "neutral" {printf "%s%s: %s", s, $1, $2; s = ", "}' "$jobs")"
  if [ -z "$(awk 'NF {print "x"; exit}' "$jobs")" ] || [ -n "$reds" ]; then
    echo "REFUSE — the PR run is not all green (${reds:-no job rows}): a red job goes through the inherited-red rules, never the chain-s2 reason. Do not merge forward."
    exit 1
  fi
  if [ -z "$(awk -F'\t' '$2 == "success" {print "x"; exit}' "$jobs")" ]; then
    echo "REFUSE — the PR run has no success row (only skipped or neutral jobs): that is no evidence the PR is green. Do not merge forward."
    exit 1
  fi
  if ! git fetch --quiet origin main 2>/dev/null || ! tip="$(git rev-parse --verify --quiet origin/main)"; then
    echo "usage: cannot fetch origin main from $(pwd): the chain-s2 check needs the worker's own repo" >&2
    exit 2
  fi
  if ! head="$(git rev-parse --verify --quiet HEAD)"; then
    echo "usage: cannot resolve HEAD in $(pwd)" >&2
    exit 2
  fi
  if [ "$psha" != "$head" ]; then
    echo "REFUSE — the --pr run is for $psha, but HEAD is $head: an older PR run proves nothing about the current head. Wait for the run of HEAD; do not merge forward."
    exit 1
  fi
  view="$(gh pr view --json number,headRefOid 2>/dev/null)" || view=""  # swallow-ok: an unread PR leaves num empty, which REFUSEs below
  num="$(jq -r '.number // ""' <<< "$view" 2>/dev/null)" || num=""  # swallow-ok: unparsable JSON leaves num empty, which REFUSEs below
  hro="$(jq -r '.headRefOid // ""' <<< "$view" 2>/dev/null)" || hro=""  # swallow-ok: an empty head never equals HEAD, which REFUSEs below
  if [ -z "$num" ]; then
    echo "REFUSE — cannot read HEAD's PR (gh pr view on the current branch): PR $cpr is not bound to this worktree. Do not merge forward."
    exit 1
  fi
  if [ "$num" != "$cpr" ]; then
    echo "REFUSE — HEAD's PR is #$num, not #$cpr: the check runs only for the PR this worktree pushes. Do not merge forward."
    exit 1
  fi
  if [ "$hro" != "$head" ]; then
    echo "REFUSE — HEAD is $head, but PR #$cpr's head on GitHub is ${hro:-unknown}: push HEAD and wait for its run first. Do not merge forward."
    exit 1
  fi
  view="$(gh pr view "$pred" --json state,mergeCommit,headRefOid 2>/dev/null)" || view=""  # swallow-ok: an unread PR leaves state empty, which REFUSEs below
  state="$(jq -r '.state // ""' <<< "$view" 2>/dev/null)" || state=""  # swallow-ok: an empty state is not MERGED, which REFUSEs below
  moid="$(jq -r '.mergeCommit.oid // ""' <<< "$view" 2>/dev/null)" || moid=""  # swallow-ok: an empty merge commit REFUSEs below
  phead="$(jq -r '.headRefOid // ""' <<< "$view" 2>/dev/null)" || phead=""  # swallow-ok: an empty premerge head REFUSEs below
  if [ "$state" != MERGED ] || [ -z "$moid" ] || ! [[ "$phead" =~ ^[0-9a-f]{40}$ ]]; then
    echo "REFUSE — PR #$pred is ${state:-unknown}, not MERGED with a merge commit and a premerge head: the chain-s2 reason runs only after the predecessor merges. Do not merge forward."
    exit 1
  fi
  if ! rmoid="$(git rev-parse --verify --quiet "$moid^{commit}")" || ! git merge-base --is-ancestor "$rmoid" "$tip" 2>/dev/null; then
    echo "REFUSE — PR #$pred's merge commit $moid is not an ancestor of origin/main ($tip). Do not merge forward."
    exit 1
  fi
  if git merge-base --is-ancestor "$rmoid" "$head" 2>/dev/null; then
    echo "nothing to merge forward — $rmoid (PR #$pred's merge) is already in HEAD"
    exit 3
  fi
  sd="$(tmpdir)" || { echo "usage: cannot create a scratch directory" >&2; exit 2; }
  trap 'rm -rf "$sd"' EXIT
  if ! env -u CHAIN_GRAPH_GH python3 "$SCRIPT_DIR/chief-kit/chain-graph.py" --pair "$pred@$phead" "$cpr" \
        --cache-dir "$sd/cache" --json > "$sd/graph.json" 2> "$sd/err"; then
    echo "REFUSE — chain-graph.py --pair $pred@$phead $cpr failed: $(head -c 300 "$sd/err"). The pair is unknown. Do not merge forward."
    exit 1
  fi
  jl="$(jq -r '.jira_links // "unknown"' "$sd/graph.json" 2>/dev/null)" || jl=unknown  # swallow-ok: an unparsable graph reads as unknown, which REFUSEs below
  if [ "$jl" != ok ]; then
    echo "REFUSE — the pair graph's Jira links are $jl: an unread Blocks link between #$pred and #$cpr would make the pair H1. Do not merge forward."
    exit 1
  fi
  if ! out="$(bash "$SCRIPT_DIR/chief-kit/chain-plan-core.sh" --evidence --graph "$sd/graph.json" --ready "$pred" 2>&1)"; then
    echo "REFUSE — chain-plan-core.sh --evidence failed: ${out:0:300}. Do not merge forward."
    exit 1
  fi
  if ! grep -Eq "^MERGE-FORWARD $cpr after $pred( |\$)" <<< "$out"; then
    edge="$(jq -r '.edges[0] | .kind + " " + .det + " (" + .evidence + ")"' "$sd/graph.json" 2>/dev/null)"  # swallow-ok: names the pair in a REFUSE message only; empty reads as unknown
    echo "REFUSE — the derived plan has no MERGE-FORWARD line for PR $cpr after #$pred: the pair rebuilt from #$pred's premerge head $phead is ${edge:-unknown}, not an S2 pair with $cpr second. Do not merge forward."
    exit 1
  fi
  line="$(grep -E "^MERGE-FORWARD $cpr after $pred( |\$)" <<< "$out")"
  echo "ALLOW chain-s2 $cpr — the pair rebuilt from #$pred's premerge head $phead and HEAD derives '$line', #$pred merged as $rmoid (on origin/main and not yet in HEAD) and the PR run is all green. This proves only #$pred's merge: confirm every other S2 predecessor of PR $cpr has merged before you merge forward. One 'git merge $tip' (the origin/main tip just fetched; CI re-runs at the merged head; never 'origin/main' again, it may have moved; merge commit; never rebase or force-push), then re-run impacted-suites.sh over the merged diff, regenerate generated files, ONE push, citing this ALLOW line in a Results bullet."
  exit 0
}
[ "${1:-}" = "--chain-s2" ] && chain_s2 "$@"
pr=""; base=""; latest=""; prc=""; bc=""; bsha=""; msha=""; lsha=""; psha=""; cover=""; csha=""; cfrom=""; bconc=""; cconc=""; lc=""; lc_set=0; cover_used=0; local_jobs=""; bad=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || { bad=1; break; }; pr="$2"; shift 2 ;;
    --main-base) [ $# -ge 2 ] || { bad=1; break; }; base="$2"; shift 2 ;;
    --main-latest) [ $# -ge 2 ] || { bad=1; break; }; latest="$2"; shift 2 ;;
    --pr-cases) [ $# -ge 2 ] || { bad=1; break; }; prc="$2"; shift 2 ;;
    --base-cases) [ $# -ge 2 ] || { bad=1; break; }; bc="$2"; shift 2 ;;
    --base-sha) [ $# -ge 2 ] || { bad=1; break; }; bsha="$2"; shift 2 ;;
    --main-base-sha) [ $# -ge 2 ] || { bad=1; break; }; msha="$2"; shift 2 ;;
    --latest-sha) [ $# -ge 2 ] || { bad=1; break; }; lsha="$2"; shift 2 ;;
    --pr-sha) [ $# -ge 2 ] || { bad=1; break; }; psha="$2"; shift 2 ;;
    --base-cover) [ $# -ge 2 ] || { bad=1; break; }; cover="$2"; shift 2 ;;
    --base-cover-sha) [ $# -ge 2 ] || { bad=1; break; }; csha="$2"; shift 2 ;;
    --base-cover-from) [ $# -ge 2 ] || { bad=1; break; }; cfrom="$2"; shift 2 ;;
    --base-cases-local) [ $# -ge 2 ] || { bad=1; break; }; lc="$2"; lc_set=1; shift 2 ;;
    --main-base-conclusion) [ $# -ge 2 ] || { bad=1; break; }; bconc="$2"; shift 2 ;;
    --base-cover-conclusion) [ $# -ge 2 ] || { bad=1; break; }; cconc="$2"; shift 2 ;;
    *) bad=1; break ;;
  esac
done
if [ "$bad" -eq 1 ] || [ ! -f "$pr" ] || [ ! -r "$pr" ] || [ ! -f "$base" ] || [ ! -r "$base" ] || [ ! -f "$latest" ] || [ ! -r "$latest" ] \
   || [ ! -r "$prc" ] || [ ! -r "$bc" ] || [ -z "$bsha" ] || [ -z "$msha" ] || [ -z "$lsha" ] || [ -z "$psha" ] || [ -z "$bconc" ] \
   || ! [[ "$lsha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file> --pr-cases <file> --base-cases <file> --base-sha <sha> --main-base-sha <sha> --latest-sha <sha> --pr-sha <sha> --main-base-conclusion <conclusion> [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha> --base-cover-conclusion <conclusion>] [--base-cases-local <file>] (all but the --base-cover group required, shas non-empty, --latest-sha a full 40-hex sha)" >&2
  exit 2
fi
if [ -n "$cover$csha$cfrom$cconc" ] && { [ ! -f "$cover" ] || [ ! -r "$cover" ] || [ -z "$csha" ] || [ -z "$cfrom" ] || [ -z "$cconc" ]; }; then
  echo "usage: merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file> --pr-cases <file> --base-cases <file> --base-sha <sha> --main-base-sha <sha> --latest-sha <sha> --pr-sha <sha> --main-base-conclusion <conclusion> [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha> --base-cover-conclusion <conclusion>] [--base-cases-local <file>] (all but the --base-cover group required, shas non-empty; the group is all-or-none)" >&2
  exit 2
fi
if [ "$lc_set" -eq 1 ] && { [ -z "$lc" ] || [ ! -f "$lc" ] || [ ! -r "$lc" ]; }; then
  echo "usage: --base-cases-local $lc is not a readable regular file (want <job><TAB><case> rows reproduced failing at the merge-base)" >&2
  exit 2
fi
for c in "$bconc" ${cconc:+"$cconc"}; do
  case "$c" in
    success|failure|cancelled|skipped|neutral|timed_out|startup_failure|action_required|stale|none) ;;
    *) echo "usage: unknown run conclusion '$c' (want the \`gh run view --json conclusion\` value, or none when no run exists)" >&2; exit 2 ;;
  esac
done
if [ "$bsha" != "$msha" ]; then
  echo "REFUSE — the --main-base run is for $msha, not the PR's merge-base $bsha: it proves nothing about the base. Report BLOCKED; do not merge forward."
  exit 1
fi

for f in "$pr" "$base" "$latest" ${cover:+"$cover"}; do
  if awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 !~ /^(success|failure|cancelled|skipped|neutral|timed_out|startup_failure|action_required|stale)$/) {exit 1}' "$f"; then :; else
    echo "usage: $f has a malformed row (want <job><TAB><conclusion>): a skipped or misread row could hide a red" >&2
    exit 2
  fi
done
for f in "$prc" "$bc"; do
  if awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 == "") {exit 1}' "$f"; then :; else
    echo "usage: $f has a malformed row (want <job><TAB><case>): a misread case could hide the PR's own red" >&2
    exit 2
  fi
done
lc_cmd=""; lc_log=""
if [ -n "$lc" ]; then
  # the file is bound to THIS merge-base (a copied PR-cases file carries no such header) and
  # names the command and log that produced it, so the ALLOW line is checkable by the chief.
  lc_mb="$(awk '/^# merge-base /{print $3; exit}' "$lc")"
  lc_cmd="$(awk '/^# command /{sub(/^# command +/, ""); print; exit}' "$lc")"
  lc_log="$(awk '/^# log /{sub(/^# log +/, ""); print; exit}' "$lc")"
  if [ "$lc_mb" != "$bsha" ] || ! [[ "$lc_mb" =~ ^[0-9a-f]{40}$ ]]; then
    echo "usage: $lc needs a '# merge-base <40-hex sha>' header equal to --base-sha $bsha (got '${lc_mb:-none}'): the reproduction must be bound to this merge-base" >&2
    exit 2
  fi
  if [ -z "$lc_cmd" ] || [ -z "$lc_log" ]; then
    echo "usage: $lc needs '# command <reproduction command>' and '# log <local log path>' headers so the ALLOW can cite them" >&2
    exit 2
  fi
  if [ ! -f "$lc_log" ] || [ ! -s "$lc_log" ]; then
    echo "usage: the '# log' file $lc_log is missing or empty: the cited reproduction log must exist so the chief can review it" >&2
    exit 2
  fi
  if awk -F'\t' '/^#/ {next} NF && (NF != 3 || $1 == "" || $2 == "" || $3 !~ /^[0-9]+$/) {exit 1}' "$lc"; then :; else
    echo "usage: $lc has a malformed row (want <job><TAB><case><TAB><exit status>): a misread case could hide the PR's own red" >&2
    exit 2
  fi
fi

# Job identity is the family, not the run's spelling: the shell-unit aggregator is named
# "shell-unit (dispatch verify) (os)" on a dispatch run, and a shard index differs between a PR
# run (impacted suites only) and a full main run, so one case lands in different shards. Both are
# folded to the family name in every input, which makes the existing per-job rules (base red if ANY
# row is red, latest green only if EVERY row is success, PR case in the base's cases) span all shards.
nd="$(tmpdir)" || { echo "usage: cannot create a scratch directory" >&2; exit 2; }
trap 'rm -rf "$nd"' EXIT
norm() { sed -e 's/^shell-unit (dispatch verify) (/shell-unit (/' -e 's/^\(shell-unit-shard ([^,)]*\), [0-9][0-9]*)/\1)/' "$1" > "$nd/$2" || exit 2; }
norm "$pr" pr; pr="$nd/pr"
norm "$base" base; base="$nd/base"
norm "$latest" latest; latest="$nd/latest"
norm "$prc" prc; prc="$nd/prc"
norm "$bc" bc; bc="$nd/bc"
[ -z "$cover" ] || { norm "$cover" cover; cover="$nd/cover"; }
[ -z "$lc" ] || { norm "$lc" lc; lc="$nd/lc"; }

# a parse failure here must not read as "nothing red": it is an input error
if ! reds="$(awk -F'\t' '($2=="failure"||$2=="timed_out"||$2=="startup_failure") && !seen[$1 ""]++ {print $1}' "$pr")"; then
  echo "usage: cannot parse $pr: a failed read must not pass as nothing red" >&2
  exit 2
fi
[ -n "$reds" ] || { echo "nothing red on the PR — no merge-forward needed"; exit 3; }

if ! git fetch --quiet origin main 2>/dev/null || ! tip="$(git rev-parse --verify --quiet origin/main)"; then
  echo "usage: cannot fetch origin main from $(pwd): the --latest-sha check needs the worker's own repo" >&2
  exit 2
fi
# main CI is a cron, so the latest completed run is usually behind the tip: it must be ON origin/main
# (resolved to a full sha: --is-ancestor is reflexive) and, below, at or after the verdict run
if ! rlsha="$(git rev-parse --verify --quiet "$lsha^{commit}")" || ! git merge-base --is-ancestor "$rlsha" "$tip" 2>/dev/null; then
  echo "REFUSE — the --main-latest run is for $lsha, which is not on origin/main ($tip): only a main run can stand in for latest main. Fetch the newest completed main run; do not merge forward."
  exit 1
fi

if ! mb="$(git merge-base origin/main HEAD 2>/dev/null)"; then
  echo "usage: cannot compute the merge-base of origin/main and HEAD in $(pwd)" >&2
  exit 2
fi
if [ "$bsha" != "$mb" ]; then
  echo "REFUSE — --base-sha $bsha is not the merge-base of origin/main and HEAD ($mb): the base run must be the one at the real merge-base. Report BLOCKED; do not merge forward."
  exit 1
fi

if ! head="$(git rev-parse --verify --quiet HEAD)"; then
  echo "usage: cannot resolve HEAD in $(pwd)" >&2
  exit 2
fi
if [ "$psha" != "$head" ]; then
  echo "REFUSE — the --pr run is for $psha, but HEAD is $head: an older PR run proves nothing about the current head. Wait for the run of HEAD; do not merge forward."
  exit 1
fi

# only success and failure are completed verdicts whose rows are trusted; cancelled
# routes to the cover below; none means no run exists, so it must come with an empty file
case "$bconc" in
  success|failure|cancelled) ;;
  none)
    if awk -F'\t' 'NF {f=1} END {exit !f}' "$base"; then
      echo "REFUSE — --main-base-conclusion is none (no run at the merge-base $bsha) but --main-base carries job rows: the input contradicts itself and proves nothing about the base. Do not merge forward."
      exit 1
    fi ;;
  *)
    echo "REFUSE — the merge-base run at $bsha concluded $bconc, not success or failure: it is not a completed verdict and proves nothing about the base. Wait for a completed main run; do not merge forward."
    exit 1 ;;
esac

base_note=""
verdict="$bsha"
if is_cancelled "$base" || [ "$bconc" = cancelled ]; then
  if [ -z "$cover" ]; then
    echo "REFUSE — the merge-base at $bsha has no completed main run (none at that commit, or it was cancelled) and no completed run covering it was given (--base-cover, --base-cover-sha, --base-cover-from): it proves nothing about the base. Wait for the next cron or dispatch main run; do not merge forward."
    exit 1
  fi
  if is_cancelled "$cover" || [ "$cconc" = cancelled ]; then
    echo "REFUSE — the covering run at $csha was cancelled too: it proves nothing about the base. Use the next COMPLETED main run; do not merge forward."
    exit 1
  fi
  case "$cconc" in
    success|failure) ;;
    *)
      echo "REFUSE — the covering run at $csha concluded $cconc, not success or failure: it is not a completed run and proves nothing about the base. Use the next COMPLETED main run; do not merge forward."
      exit 1 ;;
  esac
  # resolve both range ends to full shas: --is-ancestor is reflexive, so a short sha, S^0 or HEAD~1
  # naming the merge-base must not slip past a string compare; the ALLOW line names the resolved sha too
  if ! rcsha="$(git rev-parse --verify --quiet "$csha^{commit}")" || ! rcfrom="$(git rev-parse --verify --quiet "$cfrom^{commit}")"; then
    echo "REFUSE — cannot resolve --base-cover-sha $csha or --base-cover-from $cfrom to a commit: a covering range that cannot be read proves nothing. Do not merge forward."
    exit 1
  fi
  if ! git merge-base --is-ancestor "$rcsha" "$tip" 2>/dev/null; then
    echo "REFUSE — the covering run at $rcsha is not on origin/main ($tip): only a main run can stand in for the base. Do not merge forward."
    exit 1
  fi
  if [ "$rcfrom" = "$bsha" ] || ! git merge-base --is-ancestor "$rcfrom" "$bsha" 2>/dev/null || ! git merge-base --is-ancestor "$bsha" "$rcsha" 2>/dev/null; then
    echo "REFUSE — the covering run's range ($rcfrom, $rcsha] does not cover the merge-base $bsha: it is not the next completed main run after the merge-base. Do not merge forward."
    exit 1
  fi
  base="$cover"
  verdict="$rcsha"
  cover_used=1
  base_note=" — base verdict from the next completed covering main run at $rcsha (range $rcfrom..$rcsha), since the merge-base at $bsha has no completed run of its own"
elif [ -n "$cover" ]; then
  echo "usage: the merge-base run at $bsha is not cancelled: its own verdict stands; drop --base-cover" >&2
  exit 2
fi

if ! git merge-base --is-ancestor "$verdict" "$rlsha" 2>/dev/null; then
  echo "REFUSE — the --main-latest run at $rlsha does not descend from the base verdict run at $verdict: a run from before the base proves nothing about it being fixed. Fetch the newest completed main run; do not merge forward."
  exit 1
fi

blocked=""
while IFS= read -r job; do
  # a job name may repeat: base counts if ANY row is red, latest only if EVERY row is success
  b="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && ($2=="failure"||$2=="timed_out"||$2=="startup_failure") {print $2; f=1; exit} ($1 "")==(ENVIRON["J"] "") && !s {s=$2} END {if (!f && s) print s}' "$base")"
  l="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && $2!="success" {print $2; f=1; exit} ($1 "")==(ENVIRON["J"] "") {s=1} END {if (!f && s) print "success"}' "$latest")"
  pcases="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") {print $2}' "$prc")"
  case "$b" in failure|timed_out|startup_failure) inherited=1 ;; *) inherited=0 ;; esac
  # the covering run may already hold the fix, so it reads green though the case failed at the
  # merge-base. Only a covering-run verdict yields to a local reproduction at the merge-base: a completed run
  # at the merge-base itself is that commit's own verdict. Every one of the PR's failing cases must reproduce.
  local_ok=0; unrepro=""
  if [ "$inherited" -ne 1 ] && [ "$cover_used" -eq 1 ] && [ -n "$lc" ] && [ -n "$pcases" ]; then
    while IFS= read -r c; do
      J="$job" C="$c" awk -F'\t' '/^#/ {next} ($1 "")==(ENVIRON["J"] "") && ($2 "")==(ENVIRON["C"] "") && $3 != 0 {f=1} END {exit !f}' "$lc" || unrepro="${unrepro:+$unrepro; }$c"
    done <<< "$pcases"
    if [ -z "$unrepro" ]; then inherited=1; local_ok=1; fi
  fi
  if [ "$inherited" -ne 1 ]; then
    blocked="${blocked:+$blocked, }$job (base: ${b:-absent} — not inherited${unrepro:+; not reproduced at the merge-base: $unrepro}, the PR's own red)"
    continue
  elif [ "$l" != "success" ]; then
    blocked="${blocked:+$blocked, }$job (latest main: ${l:-absent} — not proven fixed)"
    continue
  fi
  if [ "$local_ok" -eq 1 ]; then
    local_jobs="${local_jobs:+$local_jobs, }$job"
    continue
  fi
  if [ -z "$pcases" ]; then
    blocked="${blocked:+$blocked, }$job (no failing case recorded for the PR's job — cannot prove it inherited)"
    continue
  fi
  extra=""
  while IFS= read -r c; do
    J="$job" C="$c" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && ($2 "")==(ENVIRON["C"] "") {f=1} END {exit !f}' "$bc" || extra="${extra:+$extra; }$c"
  done <<< "$pcases"
  if [ -n "$extra" ]; then
    blocked="${blocked:+$blocked, }$job (failing case not failing at the base: $extra — the PR's own red)"
  fi
done <<< "$reds"

if [ -n "$blocked" ]; then
  hint=""
  [ "$cover_used" -eq 1 ] && hint=" If the covering run already holds the fix, see docs/handover/worker-preface.md (merge-forward, --base-cases-local)."
  echo "REFUSE — red not proven inherited-and-fixed: $blocked$base_note.$hint Report BLOCKED; do not merge forward."
  exit 1
fi
allow_basis="was red on the merge-base run with the same failing cases"
[ -n "$local_jobs" ] && allow_basis="was proven inherited (red on the merge-base run with the same failing cases, or, for $local_jobs, every failing case reproduced failing at the merge-base locally via --base-cases-local at merge-base $bsha because the covering run already holds the fix; reproduction command: $lc_cmd; local log: $lc_log — the chief reviews that log)"
cite="both main run ids"
[ -n "$local_jobs" ] && cite="both main run ids PLUS the local reproduction command ($lc_cmd) and log path ($lc_log)"
echo "ALLOW — every red job $allow_basis and is green on latest main: $(paste -sd, - <<< "$reds" | sed 's/,/, /g')$base_note. One 'git merge $tip' (the origin/main tip just fetched and checked as a descendant of the latest run, not itself tested: CI re-runs at the merged head; never 'origin/main' again, it may have moved; merge commit; never rebase or force-push), citing $cite in a Results bullet."
exit 0
