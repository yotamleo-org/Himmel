#!/usr/bin/env bash
# test-chain-render.sh — Hermetic tests for chain-render.py.
# The graph is a fixture file in chain-graph.py --json shape and the Jira mirror is a temp dir, so the suite
# never touches the network, Jira or GitHub. Both states of the chain_render flag run here.
#
# PLATFORM GUARD: no .ps1 twin, by design. The chief kit is Linux-only; this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${CHAIN_RENDER_SUT:-$HERE/chain-render.py}"
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP - test-chain-render.sh (python3 not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/chain-render-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

MIR="$W/mirror" CFG="$W/cfg"
mkdir -p "$MIR" "$CFG"
export HIMMEL_CONFIG_DIR="$CFG"
unset HIMMEL_FLAG_CHAIN_RENDER

# mirror <n> <status> <category> <resolution-json>
mirror() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\nlabels: []\nfixVersions: ["v1.1.3"]\nresolution: %s\n---\n\n# HIMMEL-%s: step %s\n' \
        "$1" "$2" "$3" "$4" "$1" "$1" > "$MIR/HIMMEL-$1.md"
}
mirror 9001 Done Done '"Done"'
mirror 9002 "To Do" "To Do" null
mirror 9003 "To Do" "To Do" null
mirror 9004 "To Do" "To Do" null
mirror 9005 "In Progress" "In Progress" null

# 9001 is Done and has no PR (a PR-less node); 9002 H1 on 9001; 9003 H1 on 9002; 9003 and 9004 are soft.
cat > "$W/graph.json" <<'JSON'
{"base": "origin/main", "base_sha": "0", "jira_links": "ok",
 "nodes": [
  {"id": "HIMMEL-9001", "pr": null, "key": "HIMMEL-9001", "head": "", "title": "", "trust_files": [], "gates": {}, "files": 0},
  {"id": "#2", "pr": 2, "key": "HIMMEL-9002", "head": "a", "title": "t", "trust_files": [], "gates": {}, "files": 1},
  {"id": "#3", "pr": 3, "key": "HIMMEL-9003", "head": "b", "title": "t", "trust_files": [], "gates": {}, "files": 1},
  {"id": "#4", "pr": 4, "key": "HIMMEL-9004", "head": "c", "title": "t", "trust_files": [], "gates": {}, "files": 1},
  {"id": "#5", "pr": 5, "key": "HIMMEL-9005", "head": "d", "title": "t", "trust_files": [], "gates": {}, "files": 1}],
 "edges": [
  {"from": "HIMMEL-9001", "to": "#2", "kind": "H1", "det": "D1", "evidence": "Jira Blocks", "files": [], "source": "declared", "cycle": false},
  {"from": "#2", "to": "#3", "kind": "H1", "det": "D1", "evidence": "Jira Blocks", "files": [], "source": "declared", "cycle": false},
  {"from": "#3", "to": "#4", "kind": "S1", "det": "D4", "evidence": "clean", "files": ["x"], "source": "derived", "cycle": false},
  {"from": "#4", "to": "#5", "kind": "independent", "det": "", "evidence": "no shared file", "files": [], "source": "derived", "cycle": false}],
 "summary": {}}
JSON
CHAIN='Rename chain=HIMMEL-9001,HIMMEL-9002,HIMMEL-9003,HIMMEL-9004,HIMMEL-9005'

# stale hand file: the Done ticket shown as next, in the waterfall order
printf '[{"name":"Rename chain","steps":[{"key":"HIMMEL-9001","state":"next"},{"key":"HIMMEL-9002"}]}]\n' > "$W/out.json"
cp "$W/out.json" "$W/stale.json"

run() { python3 -I "$SUT" --graph "$W/graph.json" --mirror "$MIR" --chain "$CHAIN" --out "$W/out.json"; }
# keys <file> -> the step keys in order, space separated (waves in brackets)
keys() { python3 -I -c 'import json,sys
for c in json.load(open(sys.argv[1])):
    print(c["name"] + ":" + " ".join("%s[%s]" % (s["key"][7:], s.get("wave")) for s in c["steps"]))' "$1"; }

# --- flag off (the default): nothing is written
out="$(run 2>&1)"; rc=$?
same 'flag off exits 0' "$rc" 0
contains 'flag off says so' "$out" 'chain_render is off'
same 'flag off leaves the hand file byte for byte' "$(cmp -s "$W/out.json" "$W/stale.json" && echo same)" same

# --- flag on
out="$(HIMMEL_FLAG_CHAIN_RENDER=1 run 2>&1)"; rc=$?
same 'flag on exits 0' "$rc" 0
same 'a Done ticket is not a step (never rendered as next)' "$(keys "$W/out.json" | grep -c '9001')" 0
same 'hard edges set the waves, soft and independent ones do not' "$(keys "$W/out.json")" 'Rename chain:9002[0] 9004[0] 9005[0] 9003[1]'
same 'a rendered step carries no hand state' "$(grep -c '"state"' "$W/out.json")" 0

# --- the flag from the station conf layer
cp "$W/stale.json" "$W/out.json"
printf 'HIMMEL_FLAG_CHAIN_RENDER=1\n' > "$CFG/himmel.conf"
run >/dev/null 2>&1
same 'the himmel.conf layer turns it on' "$(keys "$W/out.json")" 'Rename chain:9002[0] 9004[0] 9005[0] 9003[1]'
rm -f "$CFG/himmel.conf"

# --- a hard cycle does not hang or drop a step
python3 -I - "$W/graph.json" "$W/cycle.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g['edges'].append({'from': '#3', 'to': '#2', 'kind': 'H2', 'det': 'D4', 'evidence': 'conflict', 'files': [], 'source': 'derived', 'cycle': False})
json.dump(g, open(sys.argv[2], 'w'))
PY
HIMMEL_FLAG_CHAIN_RENDER=1 python3 -I "$SUT" --graph "$W/cycle.json" --mirror "$MIR" --chain "$CHAIN" --out "$W/cyc-out.json" >/dev/null 2>&1
same 'a cycle keeps every open step' "$(keys "$W/cyc-out.json" | tr ' ' '\n' | grep -c '^[0-9]*\[\|:[0-9]*\[')" 4

# --- a key missing from the mirror stays a step (the tracker shows it unknown)
HIMMEL_FLAG_CHAIN_RENDER=1 python3 -I "$SUT" --graph "$W/graph.json" --mirror "$MIR" --chain 'Extra=HIMMEL-9099' --out "$W/extra.json" >/dev/null 2>&1
same 'an unmirrored key stays a step' "$(keys "$W/extra.json")" 'Extra:9099[0]'

# --- an unreadable graph fails loud and writes nothing
cp "$W/stale.json" "$W/out.json"
printf 'not json' > "$W/bad.json"
HIMMEL_FLAG_CHAIN_RENDER=1 python3 -I "$SUT" --graph "$W/bad.json" --mirror "$MIR" --chain "$CHAIN" --out "$W/out.json" >/dev/null 2>&1; rc=$?
same 'a bad graph exits 2' "$rc" 2
same 'a bad graph leaves the file alone' "$(cmp -s "$W/out.json" "$W/stale.json" && echo same)" same

printf '%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
