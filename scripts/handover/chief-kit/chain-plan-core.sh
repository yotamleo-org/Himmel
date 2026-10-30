#!/usr/bin/env bash
# scripts/handover/chief-kit/chain-plan-core.sh: the flag-free merge planner.
# chain-plan.sh is its flag-checking wrapper. merge-forward-check.sh --chain-s2 execs --evidence here, never the
# wrapper, so no flag value can change a gate verdict. This file reads no flag (check-flags.sh enforces it: it is on
# ci-trust-paths.txt).
#
#   chain-plan-core.sh --graph <file> [--ready <pr>,<pr>...]              the plan: ORDER, HOLD, MERGE-FORWARD lines
#   chain-plan-core.sh --evidence --graph <file> [--ready <pr>,<pr>...]   only the MERGE-FORWARD lines
#   chain-plan-core.sh --go-check <pr> --graph <file>                     the pre-GO check (below)
#
# The plan lines, as chain-plan.sh documents them:
#   ORDER <pr> <pr> ...                      every node, in merge order
#   HOLD <pr> for <pr> (<kind> <det>)        an H1 or H2 successor waits for its predecessor
#   MERGE-FORWARD <pr> after <pr> (S2 <det>) the later node of an S2 pair merges main forward once, after the last
#                                            of its S2 predecessors
# Order: one Kahn pass over the hard edges, taking at each step the available node that sorts first (the mergeable
# one; if several are, or none, the one with more H1/H2 dependants; then the lower PR number). S2 edges take their
# direction from that one order, so they cannot close a cycle the hard edges do not.
# --flag-state on|off is chain-plan.sh's alone: it prints the header (on) or the one notice line (off) the wrapper
# always printed, after the same argument check.
#
# --go-check REFUSEs (exit 1, one `REFUSE <reason>` line) when the graph's jira_links is not ok (missing =
# unknown), the graph's head for <pr> is not the PR's live head (gh pr view), <pr> or an S1 peer is not open, the
# graph's generated_at is missing or more than 30 minutes old, <pr>'s ticket has a hard predecessor (a live `links`
# read, either direction of the link, "X blocks <key>") whose live status is not done or cannot be read, or
# chain-push-check.sh --pr <pr> --peer <m> exits non-zero or prints no `HEADS <pr>=<head>` line for any S1 peer m
# (exit 3 = unknown = REFUSE; a missing HEADS line is unknown too). On a pass it prints `GO-CHECK OK <pr> head=<sha> graph=sha256:<hash of the graph file> at=<UTC>`.
# Environment: CHAIN_PLAN_JIRA_CMD (the jira CLI: `<cmd> links KEY`, `<cmd> get KEY`; default node <primary
# checkout>/scripts/jira/dist/index.js), CHAIN_PLAN_PUSH_CHECK (default chain-push-check.sh beside this file).
# ponytail: --go-check is procedural, the chief runs it before writing GO and nothing forces that; upgrade path is
# go.sh calling it for chain-registry members.
#
# Exit: 0 plan, evidence or GO-CHECK OK  1 cycle among the hard edges, or REFUSE  2 usage or unreadable graph
# Platform guard: bash, jq, awk; --go-check also gh, git, GNU date and sha256sum (the kit is Linux-only).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$SCRIPT_DIR/../../lib/git-clean.sh" || exit 2
git_env_scrub

usage() {
  echo "usage: chain-plan.sh [--evidence] --graph <chain-graph.py --json file> [--ready <pr>,<pr>...]" >&2
  echo "       chain-plan.sh --go-check <pr> --graph <chain-graph.py --json file>" >&2
  exit 2
}

# the done-category status names a live `get` read can carry (next-dispatchable.sh's LIVE_DONE)
DONE_RE='^(Done|Closed|wont do|wont fix|Resolved|In Public)$'

jira() {
  if [ -n "${CHAIN_PLAN_JIRA_CMD:-}" ]; then
    "$CHAIN_PLAN_JIRA_CMD" "$@"
  else
    local common
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 2  # swallow-ok: no repo means no jira CLI; return 2 makes every read below REFUSE
    JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" node "$(dirname "$common")/scripts/jira/dist/index.js" "$@"
  fi
}

go_check() {
  local pr="$1" graph="$2" jl gen now age row head key live links preds p st peers m out hash
  refuse() { echo "REFUSE $1"; exit 1; }
  jl="$(jq -r '.jira_links // "unknown"' "$graph" 2>/dev/null)" || usage  # swallow-ok: an unreadable graph is a usage error
  [ "$jl" = ok ] || refuse "the graph's jira_links is $jl: an unread Jira Blocks link may hold PR $pr. Rebuild the graph."
  jq -e '(.nodes | type == "array") and (.edges | type == "array")
         and all(.edges[]; type == "object" and (.kind | IN("H1", "H2", "S1", "S2", "independent"))
                           and (.from | type == "string") and (.to | type == "string"))' "$graph" > /dev/null 2>&1 \
    || refuse "the graph's nodes or edges are malformed (an edge without a known kind, from and to): it could hide an S1 peer. Rebuild it."
  gen="$(jq -r '.generated_at // ""' "$graph")"
  now="$(date -u +%s)"
  if [ -z "$gen" ] || ! age="$(date -u -d "$gen" +%s 2>/dev/null)"; then  # swallow-ok: an unparsable date REFUSEs
    refuse "the graph carries no readable generated_at: its age is unknown. Rebuild it with chain-graph.py --json."
  fi
  age=$((now - age))
  [ "$age" -ge -60 ] || refuse "the graph's generated_at $gen is in the future: its age is unknown. Rebuild it."
  [ "$age" -le 1800 ] || refuse "the graph is $((age / 60)) minutes old (over 30): rebuild it."
  row="$(jq -r --arg id "#$pr" '.nodes[] | select(.id == $id) | [.head // "", .key // ""] | @tsv' "$graph")"
  [ -n "$row" ] || refuse "the graph lists no node #$pr."
  IFS=$'\t' read -r head key <<< "$row"
  out="$(gh pr view "$pr" --json headRefOid,state 2>/dev/null)" || out=""  # swallow-ok: an unread head is empty, which REFUSEs below
  live="$(jq -r '.headRefOid // ""' <<< "$out" 2>/dev/null)" || live=""  # swallow-ok: an unparsable head is empty, which REFUSEs on the next line
  [ -n "$live" ] || refuse "cannot read PR $pr's live head: unknown."
  [ "$(jq -r '.state // ""' <<< "$out" 2>/dev/null)" = OPEN ] || refuse "PR $pr is not open: nothing to GO."  # swallow-ok: an unparsable state is not OPEN, which REFUSEs
  [ "$live" = "$head" ] || refuse "the graph has PR $pr at $head, but its head is now $live: rebuild the graph."
  [ -n "$key" ] || refuse "node #$pr carries no ticket key: its hard predecessors cannot be read."
  links="$(jira links "$key" 2>/dev/null)" || refuse "cannot read $key's Jira links: unknown, never cleared."  # swallow-ok: an unread link list REFUSEs
  preds="$(awk -F'\t' -v k="$key" '$2 != "Blocks" {next}
      !match($NF, /[A-Z][A-Z0-9]*-[0-9]+ blocks [A-Z][A-Z0-9]*-[0-9]+/) {exit 1}
      {split(substr($NF, RSTART, RLENGTH), w, " "); if (w[3] == k && w[1] != k) print w[1]}' <<< "$links")" \
    || refuse "a Blocks row of $key's Jira links has no '<key> blocks <key>' text: its hard predecessors are unknown, never cleared."
  for p in $preds; do
    out="$(jira get "$p" 2>/dev/null)" || refuse "cannot read the status of $p (it blocks $key): unknown, never cleared."  # swallow-ok: an unread status REFUSEs
    st="$(awk -F'\t' 'NR == 1 {print $3}' <<< "$out")"
    [ -n "$st" ] || refuse "cannot read the status of $p (it blocks $key): unknown, never cleared."
    [[ "$st" =~ $DONE_RE ]] || refuse "$key has an unmerged hard predecessor: $p is $st."
  done
  peers="$(jq -r --arg id "#$pr" '.edges[] | select(.kind == "S1" and (.from == $id or .to == $id))
                                   | (if .from == $id then .to else .from end) | ltrimstr("#")' "$graph")" \
    || refuse "cannot read the graph's S1 edges: PR $pr's peers are unknown. Rebuild the graph."
  for m in $peers; do
    out="$(gh pr view "$m" --json state 2>/dev/null)" || out=""  # swallow-ok: an unread state is empty, which REFUSEs on the next line
    [ "$(jq -r '.state // ""' <<< "$out" 2>/dev/null)" = OPEN ] || refuse "S1 peer PR $m is not open (or unreadable): rebuild the graph."  # swallow-ok: an unparsable state is not OPEN, which REFUSEs
    out="$(bash "${CHAIN_PLAN_PUSH_CHECK:-$SCRIPT_DIR/chain-push-check.sh}" --pr "$pr" --peer "$m" 2>&1)" \
      || refuse "chain-push-check.sh --pr $pr --peer $m exited $? (1 conflict, 3 unknown): ${out:0:200}"
    grep -q "^HEADS $pr=$head " <<< "$out" \
      || refuse "chain-push-check.sh --pr $pr --peer $m printed no 'HEADS $pr=$head' line: no per-peer report, unknown."
  done
  hash="$(sha256sum "$graph" | cut -d' ' -f1)"
  echo "GO-CHECK OK $pr head=$head graph=sha256:$hash at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
}

mode=plan graph="" ready="" gpr="" fstate=""
while [ $# -gt 0 ]; do
  case "$1" in
    --graph) [ $# -ge 2 ] || usage; graph="$2"; shift 2 ;;
    --ready) [ $# -ge 2 ] || usage; ready="${2//#/}"; shift 2 ;;
    --evidence) mode=evidence; shift ;;
    --go-check) [ $# -ge 2 ] || usage; mode=go; gpr="${2#\#}"; shift 2 ;;
    --flag-state) [ $# -ge 2 ] || usage; fstate="$2"; shift 2 ;;
    *) usage ;;
  esac
done
if [ -z "$graph" ] || [ ! -f "$graph" ] || [ ! -r "$graph" ] \
   || { [ -n "$ready" ] && ! [[ "$ready" =~ ^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$ ]]; } \
   || { [ "$mode" = go ] && { ! [[ "$gpr" =~ ^[0-9]+$ ]] || [ -n "$ready" ]; }; } \
   || { [ -n "$fstate" ] && { [ "$mode" != plan ] || ! [[ "$fstate" =~ ^(on|off)$ ]]; }; }; then
  usage
fi
if [ "$fstate" = off ]; then
  echo "chain-plan: chain_merge_plan off - no plan"
  exit 0
fi
[ "$mode" = go ] && go_check "$gpr" "$graph"

if ! rows="$(jq -r '(.nodes[] | "N\t" + (.id | tostring)),
                    (.edges[] | "E\t" + (.from | tostring) + "\t" + (.to | tostring) + "\t" + .kind + "\t" + (.det // ""))' "$graph" 2>&1)"; then
  echo "usage: cannot read $graph as a chain-graph.py --json file: $rows" >&2
  exit 2
fi

plan="$(printf '%s\n' "$rows" | awk -F'\t' -v ready=" ${ready//,/ } " '
function num(s) { return s ~ /^[0-9]+$/ }
function ready_p(a) { return index(ready, " " a " ") > 0 }
# higher priority: mergeable now, then more dependants, then PR numbers by value, then keys
function before(a, b) {
  if (ready_p(a) != ready_p(b)) return ready_p(a)
  if (dep[a] != dep[b]) return dep[a] > dep[b]
  if (num(a) != num(b)) return num(a)
  if (num(a)) return a + 0 < b + 0
  return a < b
}
function tag(k, d) { return "(" k (d == "" ? "" : " " d) ")" }
{ for (i = 2; i <= NF; i++) sub(/^#/, "", $i) }
$1 == "N" { if (!($2 in known)) { known[$2] = 1; ids[++n] = $2; dep[$2] = 0 } }
$1 == "E" { ne++; ef[ne] = $2; et[ne] = $3; ek[ne] = $4; ed[ne] = $5 }
END {
  for (e = 1; e <= ne; e++) {
    if (!(ef[e] in known) || !(et[e] in known)) { print "edge names a node the graph does not list: " ef[e] " " et[e] > "/dev/stderr"; exit 2 }
    if (ek[e] == "H1" || ek[e] == "H2") dep[ef[e]]++
  }
  # only the hard edges constrain; an S2 pair takes its direction from the one total order below
  for (e = 1; e <= ne; e++) if (ek[e] == "H1" || ek[e] == "H2") { nc++; cf[nc] = ef[e]; ct[nc] = et[e] }
  for (placed_n = 0; placed_n < n; placed_n++) {
    best = ""
    for (i = 1; i <= n; i++) {
      c = ids[i]
      if (c in pos) continue
      ok = 1
      for (k = 1; k <= nc; k++) if (ct[k] == c && !(cf[k] in pos)) { ok = 0; break }
      if (ok && (best == "" || before(c, best))) best = c
    }
    if (best == "") {
      left = ""
      for (i = 1; i <= n; i++) if (!(ids[i] in pos)) left = left (left == "" ? "" : ", ") ids[i]
      print "chain-plan: cycle among the hard edges, no merge order exists for: " left > "/dev/stderr"
      exit 1
    }
    pos[best] = placed_n + 1; order[placed_n + 1] = best
  }
  line = "ORDER"
  for (i = 1; i <= n; i++) line = line " " order[i]
  print line
  for (e = 1; e <= ne; e++) if (ek[e] == "H1" || ek[e] == "H2") print "HOLD " et[e] " for " ef[e] " " tag(ek[e], ed[e])
  for (e = 1; e <= ne; e++) {
    if (ek[e] != "S2") continue
    if (pos[ef[e]] < pos[et[e]]) { first = ef[e]; later = et[e] } else { first = et[e]; later = ef[e] }
    if (pos[first] > last[later]) { last[later] = pos[first]; by[later] = first; det[later] = ed[e] }
  }
  for (i = 1; i <= n; i++) if (order[i] in by) print "MERGE-FORWARD " order[i] " after " by[order[i]] " " tag("S2", det[order[i]])
}')"; rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
if [ "$mode" = evidence ]; then
  printf '%s\n' "$plan" | grep '^MERGE-FORWARD ' || true
  exit 0
fi
[ "$fstate" = on ] && echo "chain-plan: chain_merge_plan on"
printf '%s\n' "$plan"
