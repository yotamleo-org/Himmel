#!/usr/bin/env bash
# test-chain-plan.sh — hermetic tests for chain-plan.sh: the merge order and MERGE-FORWARD
# lines of a chain graph, both states of the chain_merge_plan flag. Graphs are fixture JSON in the
# chain-graph.py --json shape; nothing touches git, gh or Jira.
#
# PLATFORM GUARD: no .ps1 twin, by design. The chief kit is Linux-only; this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${CHAIN_PLAN_SUT:-$HERE/chain-plan.sh}"
if ! command -v jq >/dev/null 2>&1; then
    printf 'SKIP - test-chain-plan.sh (jq not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/chain-plan-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }

# graph <file> <node ids...> -- <from to kind>...: a chain-graph.py --json shape
graph() {
    local f="$1" ids="" edges=""
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do ids="$ids${ids:+,}{\"id\":\"$1\"}"; shift; done
    shift
    while [ "$#" -ge 3 ]; do
        edges="$edges${edges:+,}{\"from\":\"$1\",\"to\":\"$2\",\"kind\":\"$3\",\"det\":\"D4\",\"evidence\":\"fixture\",\"files\":[],\"source\":\"derived\",\"cycle\":false}"
        shift 3
    done
    printf '{"nodes":[%s],"edges":[%s]}\n' "$ids" "$edges" > "$f"
}

# plan <env-flag> <args...>: run the planner; the flag value is set in the environment
plan() { local fl="$1"; shift; HIMMEL_FLAG_CHAIN_MERGE_PLAN="$fl" bash "$SUT" "$@" 2>&1; }

graph "$W/s2.json" '#10' '#11' -- '#10' '#11' S2

# 1. the flag is off by default: no plan lines, no MERGE-FORWARD
out="$(env -u HIMMEL_FLAG_CHAIN_MERGE_PLAN HIMMEL_CONFIG_DIR="$W/nohome" bash "$SUT" --graph "$W/s2.json" 2>&1)"; rc=$?
same "default (flag off): exit 0" "$rc" 0
has "default (flag off): says so" "$out" 'chain_merge_plan off'
lacks "default (flag off): no MERGE-FORWARD line" "$out" 'MERGE-FORWARD'
lacks "default (flag off): no ORDER line" "$out" 'ORDER'
out="$(plan 0 --graph "$W/s2.json")"; rc=$?
lacks "flag 0: no MERGE-FORWARD line" "$out" 'MERGE-FORWARD'

# 2. flag on: an S2 pair, neither ready, equal dependants: the lower number first, the other merges forward
out="$(plan 1 --graph "$W/s2.json")"; rc=$?
same "S2 pair: exit 0" "$rc" 0
has "S2 pair: header names the flag on" "$out" 'chain-plan: chain_merge_plan on'
has "S2 pair: ORDER lower number first" "$out" 'ORDER 10 11'
has "S2 pair: later merges forward after the first" "$out" 'MERGE-FORWARD 11 after 10 (S2 D4)'
lacks "S2 pair: the first is not told to merge forward" "$out" 'MERGE-FORWARD 10'

# 3. a node that is mergeable now goes first (never held for ordering)
out="$(plan 1 --graph "$W/s2.json" --ready 11)"
has "ready node first: ORDER" "$out" 'ORDER 11 10'
has "ready node first: the other merges forward" "$out" 'MERGE-FORWARD 10 after 11'

# 4. both ready: the node with more dependants (the critical path) goes first
graph "$W/dep.json" '#10' '#12' '#13' -- '#10' '#12' S2 '#12' '#13' H2
out="$(plan 1 --graph "$W/dep.json" --ready 10,12)"
has "both ready: more dependants first" "$out" 'ORDER 12 10 13'
has "both ready: 10 merges forward after 12" "$out" 'MERGE-FORWARD 10 after 12'
has "H2 successor held for its predecessor" "$out" 'HOLD 13 for 12 (H2 D4)'

# 5. an H2 edge orders the successor after the predecessor even when only the successor is ready
graph "$W/h2.json" '#20' '#21' -- '#20' '#21' H2
out="$(plan 1 --graph "$W/h2.json" --ready 21)"
has "H2: predecessor first despite the successor being ready" "$out" 'ORDER 20 21'
has "H2: HOLD line" "$out" 'HOLD 21 for 20'
lacks "H2: no MERGE-FORWARD (the later node owns the conflict, not this reason)" "$out" 'MERGE-FORWARD'

# 5b. an S2 pair never closes a cycle the hard edges do not: a hard path fixes the S2 direction
graph "$W/s2hard.json" '#10' '#11' '#12' -- '#10' '#12' H1 '#12' '#11' H1 '#10' '#11' S2
out="$(plan 1 --graph "$W/s2hard.json" --ready 11)"; rc=$?
same "S2 across a hard path: exit 0, not a false cycle" "$rc" 0
has "S2 across a hard path: the hard order wins over readiness" "$out" 'ORDER 10 12 11'
has "S2 across a hard path: the later node merges forward after the first" "$out" 'MERGE-FORWARD 11 after 10'

# 5c. several S2 pairs never close a cycle together: one total order, S2 directions read off it
graph "$W/s2tri.json" '#10' '#11' '#12' -- '#10' '#11' H1 '#11' '#12' S2 '#12' '#10' S2
out="$(plan 1 --graph "$W/s2tri.json" --ready 11,12)"; rc=$?
same "S2 triangle over a hard edge: exit 0, not a false cycle" "$rc" 0
has "S2 triangle over a hard edge: one consistent order" "$out" 'ORDER 12 10 11'

# 6. S1 and independent edges order nothing and merge-forward nothing
graph "$W/s1.json" '#30' '#31' '#32' -- '#30' '#31' S1 '#31' '#32' independent
out="$(plan 1 --graph "$W/s1.json")"
lacks "S1/independent: no MERGE-FORWARD" "$out" 'MERGE-FORWARD'
lacks "S1/independent: no HOLD" "$out" 'HOLD'
has "S1/independent: every node is in ORDER" "$out" 'ORDER 30 31 32'

# 7. a node with two S2 predecessors merges forward once, after the last of them
graph "$W/two.json" '#40' '#41' '#42' -- '#40' '#42' S2 '#41' '#42' S2
out="$(plan 1 --graph "$W/two.json")"
has "two S2 predecessors: ORDER" "$out" 'ORDER 40 41 42'
same "two S2 predecessors: exactly one MERGE-FORWARD line for 42" "$(printf '%s\n' "$out" | grep -c '^MERGE-FORWARD 42 ')" 1
has "two S2 predecessors: after the last" "$out" 'MERGE-FORWARD 42 after 41'

# 8. a PR-less node (a Jira key) is planned by its key
graph "$W/key.json" '#50' 'HIMMEL-9' -- '#50' 'HIMMEL-9' H1
out="$(plan 1 --graph "$W/key.json")"
has "PR-less node: held by key" "$out" 'HOLD HIMMEL-9 for 50 (H1 D4)'

# 9. a cycle of hard edges is an error, not a plan
graph "$W/cyc.json" '#60' '#61' -- '#60' '#61' H1 '#61' '#60' H1
out="$(plan 1 --graph "$W/cyc.json")"; rc=$?
same "cycle: exit 1" "$rc" 1
has "cycle: names the nodes" "$out" 'cycle'
lacks "cycle: no ORDER line" "$out" 'ORDER'

# 10. bad input is a usage error, never an empty plan
out="$(plan 1 --graph "$W/missing.json")"; rc=$?
same "missing graph file: exit 2" "$rc" 2
printf 'not json\n' > "$W/bad.json"
out="$(plan 1 --graph "$W/bad.json")"; rc=$?
same "unparseable graph: exit 2" "$rc" 2
out="$(plan 1)"; rc=$?
same "no --graph: exit 2" "$rc" 2
out="$(plan 1 --graph "$W/s2.json" --ready 'x;y')"; rc=$?
same "malformed --ready: exit 2" "$rc" 2
out="$(plan 1 --graph "$W/s2.json" --bogus)"; rc=$?
same "unknown flag: exit 2" "$rc" 2

# 11. the plan is a pure function of its input
a="$(plan 1 --graph "$W/dep.json" --ready 10,12)"; b="$(plan 1 --graph "$W/dep.json" --ready 10,12)"
same "deterministic" "$a" "$b"

if [ "$fails" -eq 0 ]; then printf 'PASS: chain-plan\n'; else printf 'FAIL: chain-plan (%d)\n' "$fails"; exit 1; fi
