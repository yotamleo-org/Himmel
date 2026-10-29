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

# 12. the wrapper's default output is byte-identical to the pre-core planner
nl=$'\n'
same "parity: S2 pair, byte for byte" "$(plan 1 --graph "$W/s2.json")" "chain-plan: chain_merge_plan on${nl}ORDER 10 11${nl}MERGE-FORWARD 11 after 10 (S2 D4)"
same "parity: ready, H2 and S2, byte for byte" "$(plan 1 --graph "$W/dep.json" --ready 10,12)" \
    "chain-plan: chain_merge_plan on${nl}ORDER 12 10 13${nl}HOLD 13 for 12 (H2 D4)${nl}MERGE-FORWARD 10 after 12 (S2 D4)"
same "parity: PR-less node, byte for byte" "$(plan 1 --graph "$W/key.json")" "chain-plan: chain_merge_plan on${nl}ORDER 50 HIMMEL-9${nl}HOLD HIMMEL-9 for 50 (H1 D4)"
same "parity: flag off, byte for byte" "$(plan 0 --graph "$W/s2.json")" "chain-plan: chain_merge_plan off - no plan"
out="$(plan 0 --graph "$W/missing.json")"; rc=$?
same "parity: flag off still checks the arguments first (exit 2)" "$rc" 2

# 13. --evidence skips the flag: only the MERGE-FORWARD lines, the same at flag 0 and 1
CORE="${CHAIN_PLAN_CORE_SUT:-$HERE/chain-plan-core.sh}"
e0="$(plan 0 --evidence --graph "$W/dep.json" --ready 10,12)"; rc0=$?
e1="$(plan 1 --evidence --graph "$W/dep.json" --ready 10,12)"; rc1=$?
same "--evidence: exit 0 at flag 0" "$rc0" 0
same "--evidence: exit 0 at flag 1" "$rc1" 0
same "--evidence: the same lines at flag 0 and 1" "$e0" "$e1"
same "--evidence: only the MERGE-FORWARD lines" "$e1" 'MERGE-FORWARD 10 after 12 (S2 D4)'
same "--evidence: the core prints the same lines" "$(HIMMEL_FLAG_CHAIN_MERGE_PLAN=0 bash "$CORE" --evidence --graph "$W/dep.json" --ready 10,12 2>&1)" "$e1"
out="$(plan 0 --evidence --graph "$W/h2.json")"; rc=$?
same "--evidence: no S2 pair, no line, exit 0" "$rc:$out" "0:"
out="$(plan 0 --evidence --graph "$W/cyc.json")"; rc=$?
same "--evidence: a hard cycle is exit 1" "$rc" 1

# 14. --go-check <pr> --graph <g>: the pre-GO check. gh, the jira CLI and chain-push-check.sh are stubs.
mkdir -p "$W/bin" "$W/gc"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 2
cat "$GC_FIX/head-$3.json" 2>/dev/null || exit 1  # read-sink-ok: stub reads its own fixture dir only
STUB
cat > "$W/bin/jira" <<'STUB'
#!/usr/bin/env bash
f="$GC_FIX/$1-$2.txt"
[ -f "$f" ] || exit 1
cat "$f"  # read-sink-ok: stub reads its own fixture dir only
STUB
cat > "$W/bin/push" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GC_FIX/push-calls"
cat "$GC_FIX/push-out" 2>/dev/null  # read-sink-ok: stub reads its own fixture dir only
exit "$(cat "$GC_FIX/push-rc")"
STUB
chmod +x "$W/bin/gh" "$W/bin/jira" "$W/bin/push"
H11=1111111111111111111111111111111111111111 H12=2222222222222222222222222222222222222222
# gcgraph <file> <generated_at> <jira_links>: #11 (key 2) with an S1 peer #12 and an independent #13
gcgraph() {
    printf '{"generated_at":"%s","jira_links":"%s","nodes":[{"id":"#11","pr":11,"key":"HIMMEL-2","head":"%s"},{"id":"#12","pr":12,"key":"HIMMEL-3","head":"%s"},{"id":"#13","pr":13,"key":"HIMMEL-4","head":"x"}],"edges":[{"from":"#12","to":"#11","kind":"S1","det":"D4"},{"from":"#11","to":"#13","kind":"independent","det":""}]}\n' \
        "$1" "$2" "$H11" "$H12" > "$W/gc/graph.json"
}
gcreset() {
    gcgraph "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ok
    printf '{"headRefOid":"%s"}\n' "$H11" > "$W/gc/head-11.json"
    # both directions: key 5 blocks key 2 (Done), key 2 blocks key 9 (open, but a successor)
    printf '1\tBlocks\tinward=HIMMEL-5\toutward=HIMMEL-2\tHIMMEL-5 blocks HIMMEL-2\n2\tBlocks\tinward=HIMMEL-2\toutward=HIMMEL-9\tHIMMEL-2 blocks HIMMEL-9\n' > "$W/gc/links-HIMMEL-2.txt"
    printf 'HIMMEL-5\tTask\tDone\tthe blocker\n' > "$W/gc/get-HIMMEL-5.txt"
    printf 'HIMMEL-9\tTask\tTo Do\tthe blocked\n' > "$W/gc/get-HIMMEL-9.txt"
    printf 'HEADS 11=%s 12=%s\nCHECKED 12 clean\nPEERS checked=1 skipped=0 conflicting=0\n' "$H11" "$H12" > "$W/gc/push-out"
    echo 0 > "$W/gc/push-rc"; : > "$W/gc/push-calls"
}
gc() { PATH="$W/bin:$PATH" GC_FIX="$W/gc" CHAIN_PLAN_JIRA_CMD="$W/bin/jira" CHAIN_PLAN_PUSH_CHECK="$W/bin/push" bash "$SUT" --go-check "$@" 2>&1; }
gcreset
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
gsha="$(sha256sum "$W/gc/graph.json" | cut -d' ' -f1)"
same "--go-check all good: exit 0" "$rc" 0
has "--go-check all good: the OK line names the head and the graph identity" "$out" "GO-CHECK OK 11 head=$H11 graph=sha256:$gsha at="
same "--go-check all good: the push check ran for the S1 peer only" "$(cat "$W/gc/push-calls")" '--pr 11 --peer 12'
gcgraph "$(date -u +%Y-%m-%dT%H:%M:%SZ)" unreadable
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check jira_links unreadable: exit 1" "$rc" 1
has "--go-check jira_links unreadable: REFUSE" "$out" 'REFUSE'
printf '{"generated_at":"%s","nodes":[{"id":"#11","pr":11,"key":"HIMMEL-2","head":"%s"}],"edges":[]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$H11" > "$W/gc/graph.json"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check jira_links missing (unknown): REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; printf '{"headRefOid":"%s"}\n' "$H12" > "$W/gc/head-11.json"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check stale head: exit 1" "$rc" 1
has "--go-check stale head: REFUSE names the live head" "$out" "$H12"
gcreset; gcgraph "$(date -u -d '-31 min' +%Y-%m-%dT%H:%M:%SZ)" ok
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a 31-minute-old graph: REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; gcgraph '' ok
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a graph with no generated_at: REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; gcgraph "$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ)" ok
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a graph generated 10 minutes in the future: REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset
printf '{"generated_at":"%s","jira_links":"ok","nodes":[{"id":"#11","pr":11,"key":"HIMMEL-2","head":"%s"}],"edges":"S1 #12 #11"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$H11" > "$W/gc/graph.json"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a graph whose edges are not an array (an S1 peer may hide): REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset
printf '{"generated_at":"%s","jira_links":"ok","nodes":[{"id":"#11","pr":11,"key":"HIMMEL-2","head":"%s"}],"edges":[{"from":"#12","to":"#11","kind":"s1","det":"D4"}]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$H11" > "$W/gc/graph.json"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check an edge with an unknown kind (an S1 peer may hide): REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; printf 'HIMMEL-5\tTask\tIn Progress\tthe blocker\n' > "$W/gc/get-HIMMEL-5.txt"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check an unmerged hard predecessor: exit 1" "$rc" 1
has "--go-check an unmerged hard predecessor: REFUSE names it" "$out" 'HIMMEL-5'
gcreset; rm -f "$W/gc/links-HIMMEL-2.txt"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check live Jira links unreadable: REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; rm -f "$W/gc/get-HIMMEL-5.txt"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a predecessor whose status is unreadable: REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; echo 3 > "$W/gc/push-rc"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check the push check exits 3 (unknown): REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset; echo 1 > "$W/gc/push-rc"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check the push check finds a conflict: REFUSE" "$rc:${out%% *}" '1:REFUSE'
# today's chain-push-check.sh has no --pr/--peer mode: flag off it exits 0 and prints nothing
gcreset; : > "$W/gc/push-out"
out="$(gc 11 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a push check without the --pr/--peer mode (exit 0, no HEADS line): REFUSE" "$rc:${out%% *}" '1:REFUSE'
gcreset
out="$(gc 99 --graph "$W/gc/graph.json")"; rc=$?
same "--go-check a PR the graph does not list: REFUSE" "$rc:${out%% *}" '1:REFUSE'
out="$(gc 11)"; rc=$?
same "--go-check without --graph: usage (exit 2)" "$rc" 2

if [ "$fails" -eq 0 ]; then printf 'PASS: chain-plan\n'; else printf 'FAIL: chain-plan (%d)\n' "$fails"; exit 1; fi
