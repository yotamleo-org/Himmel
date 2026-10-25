#!/usr/bin/env bash
# test-graph-prune-deleted.sh — a graph update prunes the nodes of deleted and renamed files, and
# the promote shrink guard separates that prune from a lost chunk. Hermetic: stubs graphify, makes
# no model call, indexes a throwaway git repo of a few files. The graph shapes come from the live
# himmel graphify-out/graph.json (fixtures/prune-deleted-graph.json: the nodes, edges and `_origin`
# values of a handover section file that a rename moved to its current directory, and of
# scripts/telegram/poller.ts).
# Run: bash scripts/graphify/test-graph-prune-deleted.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AST="$HERE/ast-update.sh"
REFRESH="$HERE/refresh-graph-map.sh"
FIXTURE="$HERE/fixtures/prune-deleted-graph.json"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/graph-prune.XXXXXX")" || exit 1; trap 'rm -rf "$WS"' EXIT
export TMPDIR="$WS/tmp"; mkdir -p "$TMPDIR"
export GRAPHIFY_LEDGER="$WS/graphify-egress.jsonl"
unset ANTHROPIC_BASE_URL OLLAMA_HOST OLLAMA_BASE_URL OLLAMA_MODEL
HERMETIC_HOME="$WS/home"; mkdir -p "$HERMETIC_HOME/.claude"
printf 'test-subscription-auth\n' > "$HERMETIC_HOME/.claude/.credentials.json"
printf '{}\n' > "$HERMETIC_HOME/.claude/settings.json"
export HOME="$HERMETIC_HOME"
export CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_CACHE="$WS/no-bank-cache.json"
unset CLAUDE_USAGE_CACHE CLAUDE_ACCOUNT_CONFIG
export GIT_AUTHOR_NAME="himmel test" GIT_AUTHOR_EMAIL="test@himmel.invalid"
export GIT_COMMITTER_NAME="himmel test" GIT_COMMITTER_EMAIL="test@himmel.invalid"

git_repo() { # <dir> <files...> — a git repo with one commit holding the named files
  local d="$1"; shift
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config commit.gpgsign false
  local f
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf '# %s\n' "$f" > "$d/$f"; done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c core.hooksPath=/dev/null commit -qm init >/dev/null 2>&1
}
# gcount <graph> <python predicate over n> — how many nodes match
gcount() { python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); print(sum(1 for n in g["nodes"] if eval(sys.argv[2])))' "$1" "$2" 2>/dev/null; }

OLD="docs/handover/console-sections/waiter.md"  # old-term-ok: the pre-rename path is the fixture
NEW="docs/handover/chief-sections/waiter.md"

# --- ast-update: the stub `graphify update` rewrites graph.json AST-only, as a topology rebuild does ---
BIN="$WS/bin"; mkdir -p "$BIN"
cat > "$BIN/graphify" <<'STUB'
#!/usr/bin/env bash
python3 -I - "$2" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "graphify-out", "graph.json")
g = json.load(open(p))
g["nodes"] = [n for n in g["nodes"] if n.get("_origin") == "ast"]
g["links"] = [e for e in g["links"] if e.get("_origin") == "ast"]
g["hyperedges"] = []
json.dump(g, open(p, "w"))
PY
exit 0
STUB
chmod +x "$BIN/graphify"

# seed_graph <corpus> — the live-graph sample, plus a semantic node on a tracked file, an external
# import node and a hyperedge over the old path's semantic nodes
seed_graph() {
  mkdir -p "$1/graphify-out"
  python3 -I - "$FIXTURE" "$1/graphify-out/graph.json" "$OLD" <<'PY'
import copy, json, sys
g = json.load(open(sys.argv[1]))
old = [n for n in g["nodes"] if n.get("source_file") == sys.argv[3]]
sem = copy.deepcopy(old[0])
sem.update(id="poller_keeps_this", label="poller fact", source_file="scripts/telegram/poller.ts")
g["nodes"].append(sem)
g["nodes"].append({"id": "node_fs", "label": "node:fs", "_origin": "ast", "file_type": "code", "norm_label": "node:fs", "source_file": "node:fs", "type": "module"})
g["hyperedges"] = [{"id": "h_old", "label": "group", "nodes": [n["id"] for n in old], "relation": "participate_in", "_origin": "semantic", "source_file": sys.argv[3]}]
json.dump(g, open(sys.argv[2], "w"))
PY
}

echo "T1: a renamed file's semantic nodes do not survive graphify update (ast-update.sh + restore)"
C1="$WS/c1"; git_repo "$C1" "$OLD" scripts/telegram/poller.ts
mkdir -p "$C1/docs/handover/chief-sections"; git -C "$C1" mv "$OLD" "$NEW" >/dev/null 2>&1
git -C "$C1" -c core.hooksPath=/dev/null commit -qm rename >/dev/null 2>&1
seed_graph "$C1"
n_old=$(gcount "$C1/graphify-out/graph.json" "n.get('source_file')=='$OLD'")
out1=$( PATH="$BIN:$PATH" bash "$AST" "$C1" 2>&1 ); rc1=$?
G1="$C1/graphify-out/graph.json"
[ "$n_old" = "6" ] && pass "T1 setup: the sample holds 6 nodes of the old path" || fail "T1 setup: old-path nodes before = $n_old"
[ "$rc1" -eq 0 ] && pass "T1 ast-update exits 0" || fail "T1 should exit 0 (got $rc1): $out1"
[ "$(gcount "$G1" "n.get('source_file')=='$OLD'")" = "0" ] \
  && pass "T1 (a) zero nodes of the untracked old path after the update" \
  || fail "T1 (a) $(gcount "$G1" "n.get('source_file')=='$OLD'") nodes of the untracked path survived: $out1"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); sys.exit(0 if not any(e.get("source_file")==sys.argv[2] for e in g["links"]) and not any(h.get("source_file")==sys.argv[2] for h in g["hyperedges"]) else 1)' "$G1" "$OLD" \
  && pass "T1 (a) no edge or hyperedge of the old path remains" || fail "T1 (a) an edge or hyperedge of the old path remains"
grep -qF "$OLD" <<<"$out1" && grep -q "6 node" <<<"$out1" \
  && pass "T1 (a) the log lists the old path with its node count" || fail "T1 (a) no per-file prune line for $OLD: $out1"
[ "$(gcount "$G1" "n['id']=='poller_keeps_this'")" = "1" ] \
  && pass "T1 (d) a semantic node of a tracked file survives the restore" || fail "T1 (d) the tracked file's semantic node was lost"
[ "$(gcount "$G1" "n.get('source_file')=='node:fs'")" = "1" ] \
  && pass "T1 an external-import node (source_file is a module name) is not pruned" || fail "T1 the node:fs node was pruned"
[ "$(gcount "$G1" "n.get('source_file')=='scripts/telegram/poller.ts' and n.get('_origin')=='ast'")" = "123" ] \
  && pass "T1 the 123 AST nodes of the tracked code file are untouched" || fail "T1 AST nodes of poller.ts changed"

echo "T2: a repo that is not a git work tree is never pruned (tracked files cannot be told)"
C2="$WS/c2"; mkdir -p "$C2"; seed_graph "$C2"
out2=$( PATH="$BIN:$PATH" bash "$AST" "$C2" 2>&1 ); rc2=$?
[ "$rc2" -eq 0 ] && [ "$(gcount "$C2/graphify-out/graph.json" "n.get('source_file')=='$OLD'")" = "6" ] \
  && pass "T2 the 6 semantic nodes are restored untouched outside a git work tree" || fail "T2 (rc=$rc2): $out2"

# --- the promote shrink guard, through refresh-graph-map.sh --merge-into-live ---
REPORT="$WS/report.md"
cat > "$REPORT" <<'RPT'
# Graph Report - X

## Summary
- 42 nodes · 30 edges · 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. `Core` - 9 edges

## Communities (5 total)

### Community 0 - "Alpha"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
RPT
export GL_REPORT="$REPORT"
MGBIN="$WS/mg-bin"; mkdir -p "$MGBIN"
cat > "$MGBIN/graphify" <<'STUB'
#!/usr/bin/env bash
case "$1" in --version) echo "0.9.0"; exit 0 ;; esac
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
python3 -I - "$target" <<'PY'
import json, os, sys
root = sys.argv[1]
nodes = []
for d, ds, fs in os.walk(root):
    ds[:] = [x for x in ds if x not in ("graphify-out", ".git")]
    for f in sorted(fs):
        if f.endswith(".md"):
            rel = os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/")
            nodes.append({"id": "sem-%s" % rel, "label": "sem %s" % rel, "source_file": rel})
json.dump({"nodes": nodes, "links": []}, open(os.path.join(root, "graphify-out", "graph.json"), "w"))
PY
cp "$GL_REPORT" "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$MGBIN/graphify"
MAPS="$WS/maps"; mkdir -p "$MAPS"
# guard_corpus <dir> <ast nodes> <semantic nodes of tracked.md> <semantic nodes of gone.md>
# gone.md is in the semantic manifest and in no commit: the corpus deleted it.
guard_corpus() {
  git_repo "$1" tracked.md
  mkdir -p "$1/graphify-out"
  python3 -I - "$1/graphify-out" "$2" "$3" "$4" <<'PY'
import json, os, sys
d, na, nt, ng = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
nodes = [{"id": "ast-%d" % i, "label": "fn%d" % i, "source_file": "code.py", "_origin": "ast"} for i in range(na)]
nodes += [{"id": "old-sem-%d" % i, "label": "old %d" % i, "source_file": "tracked.md", "_origin": "semantic"} for i in range(nt)]
nodes += [{"id": "gone-%d" % i, "label": "g", "source_file": "gone.md", "_origin": "semantic"} for i in range(ng)]
json.dump({"nodes": nodes, "links": []}, open(os.path.join(d, "graph.json"), "w"))
json.dump({"version": 1, "files": {"gone.md": "x"}}, open(os.path.join(d, "semantic-manifest.json"), "w"))
PY
}
guard_run() { # <name> <corpus> [extra flags]
  local name="$1" corpus="$2"; shift 2
  GRAPHIFY_MAP_BIN="$MGBIN/graphify" PATH="$MGBIN:$PATH" \
    bash "$REFRESH" --name "$name" --corpus-root "$corpus" --backend claude-cli "$@" \
    --maps-dir "$MAPS" --title "$name Map" --slug "$name-map" --corpus-tag "$name" 2>&1
}

echo "T3: (b) a pure-deletion prune passes the shrink guard without a bypass and names the file that lost nodes"
C3="$WS/c3"; guard_corpus "$C3" 30 1 60
out3=$(guard_run g3 "$C3" --merge-into-live); rc3=$?
[ "$rc3" -eq 0 ] && pass "T3 the promote is not refused (60 of 91 nodes sat on a file the corpus deleted)" || fail "T3 expected rc 0 (got $rc3): $out3"
[ "$(gcount "$C3/graphify-out/graph.json" "n.get('source_file')=='gone.md'")" = "0" ] \
  && pass "T3 the deleted file's nodes are gone from the promoted graph" || fail "T3 gone.md nodes remain"
grep -q "gone.md.*60 -> 0" <<<"$out3" \
  && pass "T3 the log lists gone.md with its node count, 60 -> 0" || fail "T3 no per-file line for gone.md: $out3"

echo "T4: (c) an unexplained loss on a tracked file (an md-only promote over a graph with 60 of its nodes) is refused and names the file"
C4="$WS/c4"; guard_corpus "$C4" 5 60 0
out4=$(guard_run g4 "$C4"); rc4=$?
{ [ "$rc4" -ne 0 ] && grep -q "staged graph is below" <<<"$out4"; } \
  && pass "T4 the promote is refused" || fail "T4 expected the shrink-guard refusal (rc=$rc4): $out4"
grep -q "REFUSING.*tracked.md" <<<"$out4" \
  && pass "T4 the refusal names tracked.md as the unexplained loss" || fail "T4 refusal does not name tracked.md: $out4"
[ "$(gcount "$C4/graphify-out/graph.json" "True")" = "65" ] \
  && pass "T4 the live graph was kept" || fail "T4 the live graph changed"

echo "T5: a file removed from the work tree but not yet staged is pruned like a rename"
C5="$WS/c5"; git_repo "$C5" "$OLD" scripts/telegram/poller.ts
rm -f "$C5/$OLD"
seed_graph "$C5"
out5=$( PATH="$BIN:$PATH" bash "$AST" "$C5" 2>&1 ); rc5=$?
[ "$rc5" -eq 0 ] && [ "$(gcount "$C5/graphify-out/graph.json" "n.get('source_file')=='$OLD'")" = "0" ] \
  && pass "T5 zero nodes of the file deleted from the work tree" \
  || fail "T5 (rc=$rc5) $(gcount "$C5/graphify-out/graph.json" "n.get('source_file')=='$OLD'") nodes of the deleted file survived: $out5"

echo "T6: an edge that sits on a deleted file between two live nodes is pruned even when no node of the file is left"
C6="$WS/c6"; git_repo "$C6" "$NEW" scripts/telegram/poller.ts
seed_graph "$C6"
python3 -I - "$C6/graphify-out/graph.json" "$OLD" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
ids = [n["id"] for n in g["nodes"] if n.get("source_file") == "scripts/telegram/poller.ts" and n.get("_origin") == "ast"][:2]
g["links"].append({"source": ids[0], "target": ids[1], "relation": "calls", "_origin": "ast", "source_file": sys.argv[2]})
json.dump(g, open(sys.argv[1], "w"))
PY
out6=$( PATH="$BIN:$PATH" bash "$AST" "$C6" 2>&1 ); rc6=$?
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); sys.exit(0 if not any(e.get("source_file")==sys.argv[2] for e in g["links"]) else 1)' "$C6/graphify-out/graph.json" "$OLD" \
  && [ "$rc6" -eq 0 ] && pass "T6 no edge of the deleted file remains" || fail "T6 (rc=$rc6) an edge of the deleted file remains: $out6"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
