#!/usr/bin/env bash
# scripts/handover/chief-kit/chain-plan.sh: the merge planner.
# Reads a chain graph (chain-graph.py --json) and prints the order the chain's PRs should merge in.
#
#   chain-graph.py --open --json > graph.json
#   chain-plan.sh --graph graph.json [--ready 3971,3972]      (--ready: PRs green and GO-able now)
#
# Output, one line each (nothing else on stdout):
#   chain-plan: chain_merge_plan on
#   ORDER <pr> <pr> ...                      every node, in merge order
#   HOLD <pr> for <pr> (<kind> <det>)        an H1 or H2 successor waits for its predecessor
#   MERGE-FORWARD <pr> after <pr> (S2 <det>) the later node of an S2 pair merges main forward once, after
#                                            the last of its S2 predecessors, then re-runs its impacted
#                                            suites; merge-forward-check.sh --chain-s2 proves the line
# S1 and independent edges order nothing: those nodes merge as they go green.
# Order: one Kahn pass over the hard edges, taking at each step the available node that sorts first (the
# mergeable one; if several are, or none, the one with more H1/H2 dependants; then the lower PR number). A
# green node is never held for ordering: ready nodes sort first. An S2 pair is not a constraint of its own:
# its first node is whichever the pass placed first, so S2 edges cannot close a cycle the hard edges do not.
#
# Behind the flag chain_merge_plan (scripts/lib/flags.tsv, default off). Off prints one notice line and no
# plan, so merge-forward-check.sh --chain-s2 has no evidence. The flag is read here, never in a gate.
#
# Exit: 0 plan (or flag off)  1 cycle among the hard edges  2 usage, unreadable graph or flag registry
# Platform guard (gitbash-only): bash, jq, awk.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/flags.sh
. "$SCRIPT_DIR/../../lib/flags.sh" || exit 2

graph="" ready=""
while [ $# -gt 0 ]; do
  case "$1" in
    --graph) [ $# -ge 2 ] || { graph=""; break; }; graph="$2"; shift 2 ;;
    --ready) [ $# -ge 2 ] || { ready="!"; break; }; ready="${2//#/}"; shift 2 ;;
    *) graph=""; break ;;
  esac
done
if [ -z "$graph" ] || [ ! -f "$graph" ] || [ ! -r "$graph" ] \
   || { [ -n "$ready" ] && ! [[ "$ready" =~ ^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$ ]]; }; then
  echo "usage: chain-plan.sh --graph <chain-graph.py --json file> [--ready <pr>,<pr>...]" >&2
  exit 2
fi

himmel_flag chain_merge_plan; rc=$?
if [ "$rc" -eq 1 ]; then
  echo "chain-plan: chain_merge_plan off - no plan"
  exit 0
elif [ "$rc" -ne 0 ]; then
  exit 2
fi

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
echo "chain-plan: chain_merge_plan on"
printf '%s\n' "$plan"
