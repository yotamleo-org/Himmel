#!/usr/bin/env bash
# test-semantic-update.sh — hermetic tests for semantic-update.sh
# (the incremental semantic layer). Runs the script from a fake repo tree whose
# scripts/guardrails/ is the REAL fence (so the salus/DENY rows exercise the
# real egress matrix) while bank-preflight, seed-claude-config and `graphify`
# are stubs — never a real extraction, never the real bank.
# Run: bash scripts/graphify/test-semantic-update.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/test-semantic-update.XXXXXX")" || exit 1; trap 'rm -rf "$WS"' EXIT
REPO="$WS/repo"
mkdir -p "$REPO/scripts/graphify" "$REPO/scripts/lib" "$REPO/scripts/api-lane" "$WS/bin" "$WS/tmp" "$WS/glm"
# Other tools share TMPDIR (handover-path.sh's arm-resume-cache.* in CI): the
# scratch checks look only for this script's own graphify-semantic-* dirs.
mkdir "$WS/tmp/arm-resume-cache.foreign"
for f in semantic-update.sh semantic-merge.py harden-graph.py harden-allowlist.json; do
  cp "$HERE/$f" "$REPO/scripts/graphify/$f" 2>/dev/null || true
done
ln -s "$REAL_REPO/scripts/guardrails" "$REPO/scripts/guardrails"
cat > "$REPO/scripts/graphify/seed-claude-config.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# Bank stub: verdict from $WS/bank (default PROCEED); every call logged.
cat > "$REPO/scripts/lib/usage-preflight.sh" <<EOF
#!/usr/bin/env bash
echo bank >> "$WS/calls.log"
cat "$WS/bank" 2>/dev/null || echo PROCEED
EOF
# API-lane stub: records its argv, stdin, cwd and whether `claude`
# still resolves to the semantic-update shim, then answers with a claude envelope.
cat > "$REPO/scripts/api-lane/claude-api.sh" <<EOF
#!/usr/bin/env bash
echo "lane-tools=\${HIMMEL_API_TOOLS-UNSET}" >> "$WS/calls.log"
echo "lane \$* | stdin=\$(cat | tr '\\n' ' ') | cwdcorpus=\$([ -e "\$PWD/.graphify-corpus" ] && echo yes || echo no) | claude=\$(command -v claude || echo none)" >> "$WS/calls.log"
if [ -n "\${LANE_STUB_REFUSE:-}" ]; then
  echo 'claude-api: refused: auto routing: no account has room for the budget ({"verdict":"SKIPPED-BANK","reason":"stale-snapshot"})' >&2
  exit 2
fi
if [ -n "\${LANE_STUB_FAIL:-}" ]; then
  echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true}'
  echo "lane-stub-stderr-banner" >&2
  exit 1
fi
echo '{"type":"result","subtype":"success","is_error":false,"result":"{}","total_cost_usd":'"\${LANE_STUB_COST:-0.25}"',"usage":{"input_tokens":1,"output_tokens":1}}'
EOF
chmod +x "$REPO/scripts/api-lane/claude-api.sh"
cp "$REAL_REPO/scripts/api-lane/outcome.mjs" "$REPO/scripts/api-lane/outcome.mjs"
# graphify stub: `extract <scratch> ...` writes one semantic concept node per
# copied .md (label = first line), plus an AST heading node, plus an edge to
# the existing AST node "code_a". GRAPHIFY_STUB_RC fails it; GRAPHIFY_STUB_LEAK
# writes the absolute scratch path into a node field other than source_file
# (source_file is written absolute on purpose; the merge must normalize it).
cat > "$WS/bin/graphify" <<EOF
#!/usr/bin/env bash
echo "graphify \$*" >> "$WS/calls.log"
echo "OLLAMA_MODEL=\${OLLAMA_MODEL:-}" >> "$WS/env.log"
echo "OLLAMA_API_KEY=\${OLLAMA_API_KEY-unset}" >> "$WS/env.log"
echo "NO_AUTO_REFRESH=\${GRAPHIFY_NO_AUTO_REFRESH-unset}" >> "$WS/env.log"
echo "OLLAMA_NUM_CTX=\${GRAPHIFY_OLLAMA_NUM_CTX-unset}" >> "$WS/env.log"
echo "API_TIMEOUT=\${GRAPHIFY_API_TIMEOUT-unset}" >> "$WS/env.log"
echo "CLAUDE_BIN=\$(command -v claude || echo none)" >> "$WS/env.log"
echo "CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR-unset}" >> "$WS/env.log"
if [ -n "\${GRAPHIFY_STUB_CALL_CLAUDE:-}" ] && [ "\$1" = extract ]; then
  claude --help > "$WS/claude-help.out" 2>&1
  for _ in \$(seq "\${GRAPHIFY_STUB_CALL_N:-1}"); do
    printf 'extract this' | claude -p --output-format json --no-session-persistence --model sonnet --json-schema '{}' >> "$WS/claude.out" 2>&1 \\
      || echo "claude-shim-rc=\$?" >> "$WS/calls.log"
  done
fi
[ "\$1" = extract ] && ls "\$2/graphify-out/cache/semantic" > "$WS/seeded.log" 2>&1
[ "\$1" = extract ] || exit 0
if [ -n "\${GRAPHIFY_OUT:-}" ]; then echo "stub: GRAPHIFY_OUT=\$GRAPHIFY_OUT reached extract, which would read and write that live out-root instead of the scratch copy" >&2; exit 97; fi
if [ -n "\${GRAPHIFY_STUB_REFUSEDLOG:-}" ]; then
  # FIXTURE: the chunk-failed line of the 10-23 14:35 cadence run (graphmap-publish-himmel.log.prev), verbatim
  echo '[graphify] chunk 2/14 failed: claude -p exited 2: claude-api: refused: auto routing: no account has room for the budget ({"verdict":"SKIPPED-BANK","reason":"stale-snapshot"})'
fi
[ -z "\${GRAPHIFY_STUB_RC:-}" ] || exit "\$GRAPHIFY_STUB_RC"
# GRAPHIFY_STUB_CHUNKFAIL: the two lines graphify printed (verbatim) when 8 of 9 chunks died under the
# 0.25 USD per-call cap (himmel batch 1, 2026-10-16); the run still wrote a graph and exited 0.
if [ -n "\${GRAPHIFY_STUB_CHUNKFAIL:-}" ]; then
  echo '[graphify] chunk 1/9 failed: claude -p exited 1: bank-preflight: FLEET native=21 claudex=0 openrouter=0 reserved=0 total=21/31'
  echo '[graphify] WARNING: 8/9 semantic chunk(s) failed — see errors above. Partial results returned.'
fi
python3 - "\$2" <<'PY'
import json, os, sys
root = sys.argv[1]
nodes, links = [], []
for dp, dn, fn in os.walk(root):
    if "graphify-out" in dp:
        continue
    for f in fn:
        if not f.endswith(".md"):
            continue
        full = os.path.join(dp, f)
        rel = os.path.relpath(full, root)
        if rel == os.environ.get("GRAPHIFY_STUB_SKIP"):
            continue  # the model omitted this file: no nodes for it
        src = full  # absolute, as a scratch extraction may write it: the merge normalizes it
        label = open(full).read().strip().splitlines()[0]
        nid = "sem_" + rel.replace("/", "_") + "_" + label.replace(" ", "_")
        node = {"id": nid, "label": label, "file_type": "concept", "_origin": "semantic", "source_file": src}
        if os.environ.get("GRAPHIFY_STUB_LEAK"):
            node["description"] = "see " + full
        nodes.append(node)
        nodes.append({"id": "head_" + rel, "label": "h", "file_type": "document", "_origin": "ast", "source_file": rel})
        links.append({"source": nid, "target": "code_a", "relation": "references", "_origin": "semantic", "source_file": src})
        if os.environ.get("GRAPHIFY_STUB_DOCEDGES"):
            node["rationale"] = "because " + label
            for rel_kind in ("documents", "explains", "rationale_for"):
                links.append({"source": nid, "target": "code_a", "relation": rel_kind, "_origin": "semantic", "source_file": src})
os.makedirs(os.path.join(root, "graphify-out", "cache", "semantic"), exist_ok=True)
open(os.path.join(root, "graphify-out", "cache", "semantic", "new.json"), "w").write("{}")
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": links, "hyperedges": []},
          open(os.path.join(root, "graphify-out", "graph.json"), "w"))
PY
echo "[graphify extract] tokens: 1,234 in / 56 out, est. cost (~claude-cli): \$0.0000"
EOF
chmod +x "$WS/bin/graphify"

SCRIPT="$REPO/scripts/graphify/semantic-update.sh"
export GRAPHIFY_LEDGER="$WS/ledger.jsonl" CLAUDE_GLM_CONFIG_DIR="$WS/glm" TMPDIR="$WS/tmp"
export GRAPHIFY_SEMANTIC_LOCK_WAIT=0
unset ANTHROPIC_BASE_URL GRAPHIFY_OUT OLLAMA_HOST OLLAMA_BASE_URL OLLAMA_MODEL OLLAMA_API_KEY

# new_corpus <dir>: two docs + a live graph holding an AST node per doc, the
# code node "code_a", and one stale semantic node for a.md.
new_corpus() {
  local c="$1"
  mkdir -p "$c/graphify-out/cache/semantic" "$c/sub"
  printf 'alpha\n' > "$c/a.md"; printf 'beta\n' > "$c/b.md"; printf 'gamma\n' > "$c/sub/c.md"
  cat > "$c/graphify-out/graph.json" <<'EOF'
{"directed": false, "multigraph": false, "graph": {}, "hyperedges": [],
 "nodes": [{"id": "code_a", "label": "a.sh", "file_type": "code", "_origin": "ast", "source_file": "a.sh"},
           {"id": "head_a.md", "label": "h", "file_type": "document", "_origin": "ast", "source_file": "a.md"},
           {"id": "stale_a", "label": "old", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"}],
 "links": [{"source": "stale_a", "target": "code_a", "relation": "references", "_origin": "semantic", "source_file": "a.md"}]}
EOF
}
run() { PATH="$WS/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }
ids() { python3 -c 'import json,sys;print(" ".join(sorted(n["id"] for n in json.load(open(sys.argv[1]))["nodes"])))' "$1/graphify-out/graph.json"; }
scratch() { find "$WS/tmp" -maxdepth 1 -name 'graphify-semantic-*'; }
lastrun() { tail -1 "$1/graphify-out/semantic-runs.jsonl" | python3 -c "import json,sys;print(json.load(sys.stdin)['$2'])"; }

echo "T1: salus root refuses before any copy (exit 2, no scratch, no graphify, no bank)"
C1="$WS/c1"; new_corpus "$C1"; touch "$C1/.salus"; : > "$WS/calls.log"
out=$(run --name t1 --corpus-root "$C1" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && pass "T1 exit 2" || fail "T1 exit 2 (got $rc): $out"
[ -z "$(scratch)" ] && pass "T1 no scratch dir created" || fail "T1 scratch created: $(scratch)"
[ -s "$WS/calls.log" ] && fail "T1 graphify/bank invoked: $(cat "$WS/calls.log")" || pass "T1 nothing invoked"
[ -e "$C1/graphify-out/semantic-manifest.json" ] && fail "T1 manifest written" || pass "T1 no manifest"

echo "T2: an asserted salus class on a plain root also refuses (exit 2, no scratch)"
C2="$WS/c2"; new_corpus "$C2"; : > "$WS/calls.log"
out=$(run --name t2 --corpus-root "$C2" --corpus-class salus); rc=$?
[ "$rc" -eq 2 ] && [ -z "$(scratch)" ] && [ ! -s "$WS/calls.log" ] \
  && pass "T2 exit 2, nothing created or invoked" || fail "T2 (rc=$rc): $out"

echo "T3: first run, cap 2 of 3 changed -> batch 2, backlog 1, stale node replaced"
C3="$WS/c3"; new_corpus "$C3"; : > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code --max-files 2); rc=$?
[ "$rc" -eq 0 ] && pass "T3 exit 0" || fail "T3 exit 0 (got $rc): $out"
got=$(ids "$C3")
[ "$got" = "code_a head_a.md sem_a.md_alpha sem_b.md_beta" ] && pass "T3 graph merged (AST kept, stale dropped)" \
  || fail "T3 node ids: $got"
[ "$(lastrun "$C3" backlog)" = 1 ] && [ "$(lastrun "$C3" batch)" = 2 ] && pass "T3 JSONL batch 2 backlog 1" \
  || fail "T3 JSONL: $(tail -1 "$C3/graphify-out/semantic-runs.jsonl")"
[ "$(lastrun "$C3" tokens_in)" = 1234 ] && pass "T3 tokens parsed" || fail "T3 tokens: $(tail -1 "$C3/graphify-out/semantic-runs.jsonl")"
[ -f "$C3/graphify-out/cache/semantic/new.json" ] && pass "T3 cache copied back" || fail "T3 cache not copied back"
[ -z "$(scratch)" ] && pass "T3 scratch cleaned" || fail "T3 scratch left: $(scratch)"

echo "T4: second run drains the backlog"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code --max-files 2); rc=$?
case "$(ids "$C3")" in *sem_sub_c.md_gamma*) pass "T4 c.md extracted" ;; *) fail "T4 (rc=$rc): $out" ;; esac
[ "$(lastrun "$C3" backlog)" = 0 ] && pass "T4 backlog 0" || fail "T4 backlog"

echo "T5: no change -> no-op, no graphify, no bank"
: > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/calls.log" ] && pass "T5 no-op invokes nothing" || fail "T5 (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T6: edit a.md -> old semantic node replaced; delete b.md -> its node removed"
printf 'alef\n' > "$C3/a.md"; rm "$C3/b.md"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
got=$(ids "$C3")
[ "$got" = "code_a head_a.md sem_a.md_alef sem_sub_c.md_gamma" ] && pass "T6 replace + delete" || fail "T6 (rc=$rc) ids: $got / $out"

echo "T7: deletion only -> merge without graphify"
rm "$C3/sub/c.md"; : > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
[ "$(ids "$C3")" = "code_a head_a.md sem_a.md_alef" ] && ! grep -q graphify "$WS/calls.log" \
  && pass "T7 removed without extraction" || fail "T7 (rc=$rc): $(ids "$C3") / $out"

echo "T8: bank SKIPPED-BANK -> exit 3, graph + manifest untouched"
C8="$WS/c8"; new_corpus "$C8"; echo SKIPPED-BANK > "$WS/bank"
before=$(cat "$C8/graphify-out/graph.json")
out=$(run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
rm -f "$WS/bank"
[ "$rc" -eq 3 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ ! -e "$C8/graphify-out/semantic-manifest.json" ] \
  && pass "T8 skipped cleanly" || fail "T8 (rc=$rc): $out"

echo "T9: promote lock held -> exit 4, graph untouched"
mkdir "$C8/graphify-out/.promote.lock"; echo other > "$C8/graphify-out/.promote.lock/owner"
out=$(run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 4 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ "$(cat "$C8/graphify-out/.promote.lock/owner")" = other ] \
  && pass "T9 lock respected" || fail "T9 (rc=$rc): $out"
rm -rf "$C8/graphify-out/.promote.lock"

echo "T10: graphify fails -> exit 2, graph + manifest untouched"
out=$(GRAPHIFY_STUB_RC=7 run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ ! -e "$C8/graphify-out/semantic-manifest.json" ] \
  && pass "T10 failure leaves state" || fail "T10 (rc=$rc): $out"

echo "T11: scratch path leaking into the extraction -> refused, graph untouched"
out=$(GRAPHIFY_STUB_LEAK=1 run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && pass "T11 leak refused" || fail "T11 (rc=$rc): $out"

echo "T12: --seed-manifest stamps the baseline without extracting; .graphify-corpus-ignore honoured"
C12="$WS/c12"; new_corpus "$C12"; printf 'sub\n' > "$C12/.graphify-corpus-ignore"; : > "$WS/calls.log"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C12/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md b.md" ] && [ ! -s "$WS/calls.log" ] && pass "T12 seeded a.md b.md only" || fail "T12 (rc=$rc) '$n': $out"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/calls.log" ] && pass "T12 seeded corpus is a no-op" || fail "T12 no-op (rc=$rc): $out"

echo "T13: --max-files must be a positive integer"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code --max-files 0); rc=$?
[ "$rc" -eq 1 ] && pass "T13 usage error" || fail "T13 (rc=$rc): $out"

echo "T14: a file the extraction omits keeps its old semantic nodes and stays unstamped"
C14="$WS/c14"; new_corpus "$C14"
out=$(GRAPHIFY_STUB_SKIP=a.md run --name t14 --corpus-root "$C14" --corpus-class himmel-code); rc=$?
got=$(ids "$C14")
[ "$rc" -eq 0 ] && [ "$got" = "code_a head_a.md sem_b.md_beta sem_sub_c.md_gamma stale_a" ] && pass "T14 omitted file keeps stale_a" \
  || fail "T14 (rc=$rc) ids: $got :: $out"
[ "$(lastrun "$C14" failed)" = 1 ] && pass "T14 JSONL failed 1" || fail "T14 failed: $(tail -1 "$C14/graphify-out/semantic-runs.jsonl")"
python3 -c 'import json,sys;sys.exit("a.md" in json.load(open(sys.argv[1]))["files"])' "$C14/graphify-out/semantic-manifest.json" \
  && pass "T14 a.md unstamped" || fail "T14 a.md stamped"

echo "T15: a bank preflight with no verdict proceeds, but says so loudly"
C15="$WS/c15"; new_corpus "$C15"; : > "$WS/bank"
out=$(run --name t15 --corpus-root "$C15" --corpus-class himmel-code); rc=$?
rm -f "$WS/bank"
case "$out" in *UNGUARDED*) [ "$rc" -eq 0 ] && pass "T15 empty verdict warned" || fail "T15 rc=$rc: $out" ;;
  *) fail "T15 no UNGUARDED warning (rc=$rc): $out" ;; esac

echo "T16: the plan is taken under the promote lock (a change reverted while waiting is a no-op)"
C16="$WS/c16"; new_corpus "$C16"
run --name t16 --corpus-root "$C16" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha2\n' > "$C16/a.md"; mkdir "$C16/graphify-out/.promote.lock"; : > "$WS/calls.log"
GRAPHIFY_SEMANTIC_LOCK_WAIT=30 run --name t16 --corpus-root "$C16" --corpus-class himmel-code > "$WS/t16.out" &
bgpid=$!
sleep 2; printf 'alpha\n' > "$C16/a.md"; rmdir "$C16/graphify-out/.promote.lock"
wait "$bgpid"; rc=$?
grep -q 'no-op' "$WS/t16.out" && ! grep -q '^graphify' "$WS/calls.log" && [ "$rc" -eq 0 ] \
  && pass "T16 re-planned under the lock" || fail "T16 (rc=$rc): $(cat "$WS/t16.out") calls: $(cat "$WS/calls.log")"

echo "T17: hyperedge members removed with their nodes; a hyperedge left under 2 members is dropped"
C17="$WS/c17"; new_corpus "$C17"
python3 - "$C17/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["hyperedges"] = [
    {"id": "h3", "label": "keep", "nodes": ["stale_a", "code_a", "head_a.md"], "_origin": "semantic", "source_file": "x.md"},
    {"id": "h2", "label": "drop", "nodes": ["stale_a", "code_a"], "_origin": "semantic", "source_file": "x.md"}]
json.dump(g, open(sys.argv[1], "w"))
PY
run --name t17 --corpus-root "$C17" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha2\n' > "$C17/a.md"
out=$(run --name t17 --corpus-root "$C17" --corpus-class himmel-code); rc=$?
got=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(";".join(h["id"]+"="+",".join(h["nodes"]) for h in g["hyperedges"]))' "$C17/graphify-out/graph.json")
[ "$rc" -eq 0 ] && [ "$got" = "h3=code_a,head_a.md" ] && pass "T17 hyperedges pruned" || fail "T17 (rc=$rc) '$got': $out"

echo "T18: --seed-manifest respects the promote lock (exit 4, no manifest)"
C18="$WS/c18"; new_corpus "$C18"; mkdir "$C18/graphify-out/.promote.lock"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --seed-manifest); rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$C18/graphify-out/semantic-manifest.json" ] && pass "T18 seed waits on the lock" || fail "T18 (rc=$rc): $out"
rmdir "$C18/graphify-out/.promote.lock"

echo "T19: --seed-manifest --dry-run writes nothing"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --seed-manifest --dry-run); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$C18/graphify-out/semantic-manifest.json" ] && pass "T19 dry-run seed wrote nothing" || fail "T19 (rc=$rc): $out"

echo "T20: --max-files 00 is not a positive integer"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --max-files 00); rc=$?
[ "$rc" -eq 1 ] && pass "T20 usage error" || fail "T20 (rc=$rc): $out"

echo "T21: an untouched file's edge to a node the re-extraction restores survives (HIMMEL-4211)"
C21="$WS/c21"; new_corpus "$C21"
python3 - "$C21/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"] += [{"id": "sem_a.md_alpha", "label": "alpha", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"},
               {"id": "sem_b.md_beta", "label": "beta", "file_type": "concept", "_origin": "semantic", "source_file": "b.md"}]
g["links"].append({"source": "sem_b.md_beta", "target": "sem_a.md_alpha", "relation": "mentions", "_origin": "semantic", "source_file": "b.md"})
json.dump(g, open(sys.argv[1], "w"))
PY
run --name t21 --corpus-root "$C21" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha\nmore\n' > "$C21/a.md"
out=$(run --name t21 --corpus-root "$C21" --corpus-class himmel-code); rc=$?
got=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(sum(1 for e in g["links"] if e["source"]=="sem_b.md_beta" and e["target"]=="sem_a.md_alpha"))' "$C21/graphify-out/graph.json")
[ "$rc" -eq 0 ] && [ "$got" = 1 ] && pass "T21 b.md edge to restored a.md node kept" || fail "T21 (rc=$rc) edges=$got: $out"

echo "T22: manifest write fails after graph.json landed -> non-zero; the rerun converges to the clean-run graph"
mkdir -p "$WS/pyfail"
cat > "$WS/pyfail/sitecustomize.py" <<'PY'
import os
_real = os.replace
def _replace(src, dst, *a, **k):
    if str(dst).endswith("semantic-manifest.json") and os.path.exists(os.environ.get("FAIL_MANIFEST_FLAG", "/nonexistent")):
        raise OSError("simulated manifest write failure")
    return _real(src, dst, *a, **k)
os.replace = _replace
PY
C22="$WS/c22"; C22B="$WS/c22b"; new_corpus "$C22"; new_corpus "$C22B"
out=$(run --name t22b --corpus-root "$C22B" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] || fail "T22 clean run (rc=$rc): $out"
: > "$WS/fail-manifest"
export PYTHONPATH="$WS/pyfail" FAIL_MANIFEST_FLAG="$WS/fail-manifest"
out=$(run --name t22 --corpus-root "$C22" --corpus-class himmel-code); rc=$?
unset PYTHONPATH FAIL_MANIFEST_FLAG
norm() { python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(json.dumps([sorted(n["id"] for n in g["nodes"]),sorted((e["source"],e["target"]) for e in g["links"])]))' "$1/graphify-out/graph.json"; }
# graph.json must already hold the new content: the failure came AFTER the graph write.
[ "$rc" -ne 0 ] && [ ! -e "$C22/graphify-out/semantic-manifest.json" ] && [ "$(norm "$C22")" = "$(norm "$C22B")" ] \
  && pass "T22 failure is non-zero, graph.json landed, files stay unstamped" || fail "T22 (rc=$rc): $out"
rm -f "$WS/fail-manifest"
out=$(run --name t22 --corpus-root "$C22" --corpus-class himmel-code); rc=$?
m=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C22/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$(norm "$C22")" = "$(norm "$C22B")" ] && [ "$m" = "a.md b.md sub/c.md" ] \
  && pass "T22 rerun converges, manifest stamped" || fail "T22 rerun (rc=$rc) m='$m': $out"

echo "T23: --backend ollama -> qwen3.6:27b, --max-concurrency 1, no bank-preflight call"
C23="$WS/c23"; new_corpus "$C23"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(run --name t23 --corpus-root "$C23" --corpus-class himmel-code --backend ollama); rc=$?
ext=$(grep '^graphify extract' "$WS/calls.log")
[ "$rc" -eq 0 ] && pass "T23 exit 0" || fail "T23 exit 0 (got $rc): $out"
case "$ext" in *"--backend ollama"*"--max-concurrency 1"*) pass "T23 extract args" ;; *) fail "T23 extract args: $ext" ;; esac
grep -qx 'OLLAMA_MODEL=qwen3.6:27b' "$WS/env.log" && pass "T23 model qwen3.6:27b" || fail "T23 model: $(cat "$WS/env.log")"
grep -qx bank "$WS/calls.log" && fail "T23 bank-preflight called on the ollama path" || pass "T23 ollama path does not call bank-preflight"
# T23b: graphify warns "no OLLAMA_API_KEY set" on every local
# run; the loopback-verified path hands it the documented placeholder so the log
# stays quiet, and a caller-set key is never overwritten.
grep -qx 'OLLAMA_API_KEY=ollama' "$WS/env.log" && pass "T23b local ollama gets the placeholder OLLAMA_API_KEY" || fail "T23b placeholder key: $(cat "$WS/env.log")"
C23B="$WS/c23b"; new_corpus "$C23B"; : > "$WS/env.log"
out=$(OLLAMA_API_KEY=real-key run --name t23b --corpus-root "$C23B" --corpus-class himmel-code --backend ollama); rc=$?
grep -qx 'OLLAMA_API_KEY=real-key' "$WS/env.log" && pass "T23c a caller-set OLLAMA_API_KEY is preserved" || fail "T23c caller key: $(cat "$WS/env.log")"
# T23d: the claude-cli path never receives the placeholder.
C23D="$WS/c23d"; new_corpus "$C23D"; : > "$WS/env.log"
out=$(run --name t23d --corpus-root "$C23D" --corpus-class himmel-code --backend claude-cli); rc=$?
grep -qx 'OLLAMA_API_KEY=unset' "$WS/env.log" && pass "T23d claude-cli path gets no OLLAMA_API_KEY" || fail "T23d claude-cli key leak: $(cat "$WS/env.log")"
grep -qx 'OLLAMA_NUM_CTX=unset' "$WS/env.log" && pass "T23h claude-cli path gets no GRAPHIFY_OLLAMA_NUM_CTX" || fail "T23h num_ctx leak: $(cat "$WS/env.log")"

# T23e-g: qwen3.6:27b at graphify's auto-derived num_ctx
# spilled 55% to CPU and every request outran graphify's 600 s default timeout.
# The ollama path pins a GPU-fitting num_ctx and a raised request timeout; a
# caller-set value of either wins.
C23E="$WS/c23e"; new_corpus "$C23E"; : > "$WS/env.log"
out=$(run --name t23e --corpus-root "$C23E" --corpus-class himmel-code --backend ollama); rc=$?
grep -qx 'OLLAMA_NUM_CTX=16384' "$WS/env.log" && pass "T23e ollama path pins GRAPHIFY_OLLAMA_NUM_CTX=16384" || fail "T23e num_ctx: $(cat "$WS/env.log")"
grep -qx 'API_TIMEOUT=1800' "$WS/env.log" && pass "T23f ollama path raises GRAPHIFY_API_TIMEOUT=1800" || fail "T23f timeout: $(cat "$WS/env.log")"
C23G="$WS/c23g"; new_corpus "$C23G"; : > "$WS/env.log"
out=$(GRAPHIFY_OLLAMA_NUM_CTX=8192 GRAPHIFY_API_TIMEOUT=300 run --name t23g --corpus-root "$C23G" --corpus-class himmel-code --backend ollama); rc=$?
grep -qx 'OLLAMA_NUM_CTX=8192' "$WS/env.log" && grep -qx 'API_TIMEOUT=300' "$WS/env.log" && pass "T23g caller-set num_ctx and timeout are preserved" || fail "T23g caller override: $(cat "$WS/env.log")"

# ollama_refused <name> <VAR=val...>: the script's OWN endpoint/model check
# refuses before the fence, the bank, the copy and graphify.
ollama_refused() {
  local name="$1"; shift
  local c="$WS/c-$name"; new_corpus "$c"; : > "$WS/calls.log"
  out=$(env "$@" PATH="$WS/bin:$PATH" bash "$SCRIPT" --name "$name" --corpus-root "$c" --corpus-class himmel-code --backend ollama 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [[ "$out" == *"semantic-update: refusing ollama"* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
    && pass "$name refused before anything ran" || fail "$name (rc=$rc): $out / $(cat "$WS/calls.log")"
}
echo "T24-T28: ollama endpoint/model refusals (independent of the fence)"
ollama_refused T24-lan-host OLLAMA_HOST=192.0.2.5
ollama_refused T25-ollama-com OLLAMA_BASE_URL=https://ollama.com/v1
ollama_refused T26-cloud-model OLLAMA_MODEL=gpt-oss:120b-cloud
ollama_refused T26b-cloud-tag OLLAMA_MODEL=glm-4.6:cloud
ollama_refused T27-garbage "OLLAMA_BASE_URL=not a url"
ollama_refused T28-remote-base-loopback-host OLLAMA_BASE_URL=http://198.51.100.5:11434/v1 OLLAMA_HOST=127.0.0.1
ollama_refused T28b-userinfo OLLAMA_BASE_URL=http://127.0.0.1@evil.example:11434/v1

echo "T29: salus root on the ollama path -> exit 2 before any copy"
C29="$WS/c29"; new_corpus "$C29"; touch "$C29/.salus"; : > "$WS/calls.log"
out=$(HOME="$WS/home" run --name t29 --corpus-root "$C29" --corpus-class himmel-code --backend ollama); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] && pass "T29 salus refused" || fail "T29 (rc=$rc): $out"

echo "T30: loopback OLLAMA_BASE_URL is accepted"
C30="$WS/c30"; new_corpus "$C30"
out=$(OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 run --name t30 --corpus-root "$C30" --corpus-class himmel-code --backend ollama); rc=$?
[ "$rc" -eq 0 ] && pass "T30 loopback accepted" || fail "T30 (rc=$rc): $out"

echo "T31: graphify extract runs with GRAPHIFY_NO_AUTO_REFRESH=1 (HIMMEL-4514)"
C31="$WS/c31"; new_corpus "$C31"; : > "$WS/env.log"
out=$(unset GRAPHIFY_NO_AUTO_REFRESH; PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t31 --corpus-root "$C31" --corpus-class himmel-code --backend ollama 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qx 'NO_AUTO_REFRESH=1' "$WS/env.log" && pass "T31 graphify saw GRAPHIFY_NO_AUTO_REFRESH=1" \
  || fail "T31 (rc=$rc): $(cat "$WS/env.log") $out"

# --- --backend claude-api through the API lane -----------------
LANE_ENV=(HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A)
run_api() { env "${LANE_ENV[@]}" PATH="$WS/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

echo "T32: claude-api with the lane OFF fails closed: exit 2, nothing copied, no claude-cli fallback"
C32="$WS/c32"; new_corpus "$C32"; : > "$WS/calls.log"
out=$(env -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t32 --corpus-root "$C32" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"API lane"* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
  && pass "T32 refused, nothing invoked" || fail "T32 (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T33: lane on -> graphify runs the claude-cli path, native bank untouched, shim first on PATH"
C33="$WS/c33"; new_corpus "$C33"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(run_api --name t33 --corpus-root "$C33" --corpus-class himmel-code --backend claude-api); rc=$?
ext=$(grep '^graphify extract' "$WS/calls.log")
[ "$rc" -eq 0 ] && pass "T33 exit 0" || fail "T33 exit 0 (got $rc): $out"
case "$ext" in *"--backend claude-cli"*) pass "T33 extract uses --backend claude-cli" ;; *) fail "T33 extract args: $ext" ;; esac
grep -qx bank "$WS/calls.log"; g33=$?
case "$g33" in 1) pass "T33 native bank not consulted" ;; 0) fail "T33 native bank-preflight called" ;; *) fail "T33 calls.log unreadable (grep rc=$g33)" ;; esac
echo "T33b: a zero per-call budget is refused before any work"
C33B="$WS/c33b"; new_corpus "$C33B"; : > "$WS/calls.log"
out=$(GRAPHIFY_API_CALL_BUDGET_USD=0.0 run_api --name t33b --corpus-root "$C33B" --corpus-class himmel-code --backend claude-api --dry-run); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"positive decimal"* ]] && pass "T33b zero budget refused" || fail "T33b (rc=$rc): $out"
grep -q '^CLAUDE_BIN=.*graphify-semantic-t33-' "$WS/env.log" && pass "T33 graphify's claude is the scratch shim" || fail "T33 claude bin: $(grep CLAUDE_BIN "$WS/env.log")"
[ -z "$(scratch)" ] && pass "T33 scratch (and shim) cleaned" || fail "T33 scratch left"

echo "T34: a caller ANTHROPIC_API_KEY is refused (the lane's own key file is the only source)"
C34="$WS/c34"; new_corpus "$C34"; : > "$WS/calls.log"
out=$(ANTHROPIC_API_KEY=sk-ant-test-not-real run_api --name t34 --corpus-root "$C34" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/calls.log" ] && [[ "$out" != *sk-ant-test-not-real* ]] \
  && pass "T34 refused, key not echoed" || fail "T34 (rc=$rc): $out"

echo "T35: --max-files caps the claude-api batch (cap 2 of 3 -> batch 2, backlog 1)"
C35="$WS/c35"; new_corpus "$C35"
out=$(run_api --name t35 --corpus-root "$C35" --corpus-class himmel-code --backend claude-api --max-files 2); rc=$?
[ "$rc" -eq 0 ] && [ "$(lastrun "$C35" batch)" = 2 ] && [ "$(lastrun "$C35" backlog)" = 1 ] \
  && pass "T35 batch 2 backlog 1" || fail "T35 (rc=$rc): $out"

echo "T36: --dry-run prints an estimate and makes no lane, graphify or bank call"
C36="$WS/c36"; new_corpus "$C36"; : > "$WS/calls.log"
out=$(run_api --name t36 --corpus-root "$C36" --corpus-class himmel-code --backend claude-api --dry-run); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"estimate: files=3 "* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
  && pass "T36 estimate printed, nothing invoked" || fail "T36 (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T37: the shim hands the lane an allowlisted argv, the prompt on stdin, a non-corpus cwd, no shim on PATH"
C37="$WS/c37"; new_corpus "$C37"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37 --corpus-root "$C37" --corpus-class himmel-code --backend claude-api); rc=$?
lane=$(grep '^lane ' "$WS/calls.log" | head -1)
[ "$rc" -eq 0 ] && pass "T37 exit 0" || fail "T37 exit 0 (got $rc): $out"
case "$lane" in
  *"graphify-semantic-"*) fail "T37 lane still sees the shim on PATH: $lane" ;;
  "lane -p --model sonnet --permission-mode default --max-budget-usd 1.00 --effort high | stdin=extract this"*" | cwdcorpus=no | claude="*) pass "T37 lane argv/stdin/cwd, shim off PATH" ;;
  *) fail "T37 lane call: $lane" ;;
esac
grep -qx 'lane-tools=' "$WS/calls.log"; g37t=$?
[ "$g37t" -eq 0 ] && pass "T37 lane called tool-free (HIMMEL_API_TOOLS set and empty)" || fail "T37 tool grant (rc=$g37t): $(grep lane-tools "$WS/calls.log")"
grep -q -- 'primary\|shim' "$WS/claude-help.out" || fail "T37 shim --help output missing (positive control)"
grep -q json-schema "$WS/claude-help.out"; h37=$?
case "$h37" in 1) pass "T37 shim --help omits --json-schema" ;; 0) fail "T37 shim --help advertises --json-schema" ;; *) fail "T37 claude-help.out unreadable (grep rc=$h37)" ;; esac

echo "T38: salus stays denied on the claude-api path (exit 2 before any copy or lane call)"
C38="$WS/c38"; new_corpus "$C38"; touch "$C38/.salus"; : > "$WS/calls.log"
out=$(run_api --name t38 --corpus-root "$C38" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] && pass "T38 salus refused" || fail "T38 (rc=$rc): $out"

echo "T39: any failed chunk exits 5 after the good chunks merge; a caller looping on the exit code stops"
C39="$WS/c39"; new_corpus "$C39"
out=$(GRAPHIFY_STUB_CHUNKFAIL=1 run_api --name t39 --corpus-root "$C39" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 5 ] && pass "T39 exit 5" || fail "T39 exit 5 (got $rc): $out"
[[ "$out" == *"FAILED: 8/9"* ]] && pass "T39 FAILED line names the chunk count" || fail "T39 FAILED line: $out"
case "$(ids "$C39")" in *sem_a.md_alpha*) pass "T39 the good chunks still merged" ;; *) fail "T39 merge skipped: $(ids "$C39")" ;; esac
C39B="$WS/c39b"; new_corpus "$C39B"
out=$(GRAPHIFY_STUB_CHUNKFAIL=1 run --name t39b --corpus-root "$C39B" --corpus-class himmel-code --backend claude-cli); rc=$?
[ "$rc" -eq 5 ] && pass "T39 claude-cli path exits 5 too" || fail "T39 cli exit 5 (got $rc): $out"

echo "T40: claude-api passes --token-budget derived from the per-call budget, capped at graphify's 60000"
C40="$WS/c40"; new_corpus "$C40"; : > "$WS/calls.log"
out=$(run_api --name t40 --corpus-root "$C40" --corpus-class himmel-code --backend claude-api); rc=$?
case "$(grep '^graphify extract' "$WS/calls.log")" in *"--token-budget 30000"*) pass "T40 default 1.00 -> 30000" ;; *) fail "T40 default: $(grep '^graphify extract' "$WS/calls.log") $out" ;; esac
C40B="$WS/c40b"; new_corpus "$C40B"; : > "$WS/calls.log"
out=$(GRAPHIFY_API_CALL_BUDGET_USD=3.00 run_api --name t40b --corpus-root "$C40B" --corpus-class himmel-code --backend claude-api); rc=$?
case "$(grep '^graphify extract' "$WS/calls.log")" in *"--token-budget 60000"*) pass "T40 3.00 -> capped at 60000" ;; *) fail "T40 capped: $(grep '^graphify extract' "$WS/calls.log") $out" ;; esac
C40C="$WS/c40c"; new_corpus "$C40C"; : > "$WS/calls.log"
out=$(run --name t40c --corpus-root "$C40C" --corpus-class himmel-code --backend claude-cli); rc=$?
ext40c="$(grep '^graphify extract' "$WS/calls.log")"
if [ "$rc" -ne 0 ] || [ -z "$ext40c" ]; then fail "T40 claude-cli control did not reach graphify extract (rc=$rc): $out"
else case "$ext40c" in *"--token-budget"*) fail "T40 claude-cli got a token budget" ;; *) pass "T40 claude-cli path unchanged" ;; esac; fi

echo "T41: a failed lane call shows its result and exit code on the shim's stderr (what graphify prints in the chunk-failed line)"
C41="$WS/c41"; new_corpus "$C41"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_FAIL=1 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t41 --corpus-root "$C41" --corpus-class himmel-code --backend claude-api); rc=$?
grep -q 'error_max_budget_usd' "$WS/claude.out" && grep -q 'lane exited 1' "$WS/claude.out" && grep -qx 'claude-shim-rc=1' "$WS/calls.log" \
  && pass "T41 shim stderr carries the lane result and keeps rc 1" || fail "T41: $(cat "$WS/claude.out") / $(cat "$WS/calls.log")"

echo "T42: the estimate line states the per-call cap and the expected per-chunk cost"
out=$(run_api --name t42 --corpus-root "$C36" --corpus-class himmel-code --backend claude-api --dry-run); rc=$?
[[ "$out" == *"call-cap=1.00"* ]] && [[ "$out" == *"chunk-tokens=30000"* ]] && [[ "$out" == *"chunk-cost-est="* ]] \
  && pass "T42 estimate carries cap, chunk tokens and chunk cost" || fail "T42 (rc=$rc): $out"
out=$(GRAPHIFY_API_CALL_BUDGET_USD=3.00 run_api --name t42b --corpus-root "$C36" --corpus-class himmel-code --backend claude-api --dry-run); rc=$?
[[ "$out" == *"call-cap=3.00"* ]] && [[ "$out" == *"chunk-tokens=60000"* ]] && pass "T42 a bigger cap raises the chunk, capped at 60000" || fail "T42b (rc=$rc): $out"

echo "T43: a per-call budget too small for any chunk is refused, not turned into a zero token budget"
out=$(GRAPHIFY_API_CALL_BUDGET_USD=0.000001 run_api --name t43 --corpus-root "$C36" --corpus-class himmel-code --backend claude-api --dry-run 2>&1); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"too small"* ]] && pass "T43 tiny call budget exits 1" || fail "T43 (rc=$rc): $out"

echo "T44: the lane's --effort comes from GRAPHIFY_API_EFFORT (default high); garbage is refused"
C44="$WS/c44"; new_corpus "$C44"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_API_EFFORT=medium GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t44 --corpus-root "$C44" --corpus-class himmel-code --backend claude-api); rc=$?
case "$(grep '^lane ' "$WS/calls.log" | head -1)" in *"--effort medium |"*) pass "T44 GRAPHIFY_API_EFFORT=medium reaches the lane" ;; *) fail "T44 medium (rc=$rc): $(grep '^lane ' "$WS/calls.log") $out" ;; esac
C44B="$WS/c44b"; new_corpus "$C44B"; : > "$WS/calls.log"
out=$(GRAPHIFY_API_EFFORT=bogus run_api --name t44b --corpus-root "$C44B" --corpus-class himmel-code --backend claude-api --dry-run); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"GRAPHIFY_API_EFFORT"* ]] && [ ! -s "$WS/calls.log" ] && pass "T44 garbage effort exits 1, nothing invoked" || fail "T44b (rc=$rc): $out"

echo "T45: a re-extract returning a strict subset (under half the old nodes) is refused for that file: old nodes kept, file unstamped, decision logged"
C45="$WS/c45"; new_corpus "$C45"
python3 - "$C45/graphify-out/graph.json" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p))
for i in range(4):
    g["nodes"].append({"id": "old_a_%d" % i, "label": "old %d" % i, "file_type": "concept", "_origin": "semantic", "source_file": "a.md"})
json.dump(g, open(p, "w"))
PY
rm -f "$C45/b.md" "$C45/sub/c.md"
out=$(run --name t45 --corpus-root "$C45" --corpus-class himmel-code); rc=$?
all45=$(ids "$C45")
for want in old_a_0 old_a_1 old_a_2 old_a_3 stale_a; do
  case " $all45 " in *" $want "*) ;; *) fail "T45 dropped $want (rc=$rc): $all45" ;; esac
done
case " $all45 " in *" sem_a.md_alpha "*) fail "T45 the refused file's new node was merged: $all45" ;; *) pass "T45 old nodes survived, the shrunken extraction was not merged" ;; esac
[ "$(lastrun "$C45" failed)" = "0" ] && [ "$(lastrun "$C45" refused_files)" = "['a.md']" ] && [ "$(lastrun "$C45" failed_files)" = "[]" ] \
  && pass "T45 a refused file is counted once, as refused, not also as failed" || fail "T45 counts: $(tail -1 "$C45/graphify-out/semantic-runs.jsonl")"
[ "$(lastrun "$C45" shrink_refused)" = "1" ] && [[ "$out" == *"shrink guard"* ]] && pass "T45 decision logged to the run row and stderr" || fail "T45 no shrink log: $out"
python3 -c 'import json,sys;sys.exit(0 if "a.md" not in json.load(open(sys.argv[1]))["files"] else 1)' "$C45/graphify-out/semantic-manifest.json" \
  && pass "T45 a.md stays unstamped" || fail "T45 a.md was stamped"

echo "T46: a normal re-extract (nodes not under half) still replaces the file's old nodes"
C46="$WS/c46"; new_corpus "$C46"; rm -f "$C46/b.md" "$C46/sub/c.md"
out=$(run --name t46 --corpus-root "$C46" --corpus-class himmel-code); rc=$?
case " $(ids "$C46") " in *" stale_a "*) fail "T46 stale node kept" ;; *" sem_a.md_alpha "*) pass "T46 stale replaced by the new extraction" ;; *) fail "T46 (rc=$rc): $(ids "$C46")" ;; esac

echo "T47: the claude-api prompt demands a rationale on every node and the three doc-to-code edge types"
# FIXTURE: the relation enumeration of graphify's real extraction schema (installed llm.py _EXTRACTION_SYSTEM, copied verbatim)
REAL_SCHEMA_RELATIONS='"relation":"calls|implements|references|cites|conceptually_related_to|shares_data_with|semantically_similar_to"'
C47="$WS/c47"; new_corpus "$C47"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t47 --corpus-root "$C47" --corpus-class himmel-code --backend claude-api); rc=$?
lane=$(grep '^lane ' "$WS/calls.log" | head -1)
for want in "rationale" "documents" "explains" "rationale_for"; do
  case "$lane" in *"$want"*) pass "T47 prompt names $want" ;; *) fail "T47 prompt lacks $want (rc=$rc): $lane" ;; esac
done
case "$lane" in "lane "*"stdin=extract this"*) pass "T47 the original prompt stays first" ;; *) fail "T47 prompt order: $lane" ;; esac
for rel in documents explains rationale_for; do
  case "$REAL_SCHEMA_RELATIONS" in *"$rel"*) fail "T47 fixture already lists $rel" ;; *) pass "T47 real schema lacks $rel, so the addendum is needed" ;; esac
done

echo "T48: --max-run-usd stops further lane calls once the summed cost reaches it"
C48="$WS/c48"; new_corpus "$C48"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_COST=0.60 GRAPHIFY_STUB_CALL_N=4 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t48 --corpus-root "$C48" --corpus-class himmel-code --backend claude-api --max-run-usd 1.00); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 2 ] && pass "T48 two calls ran, the third was refused" || fail "T48 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'run spend cap' "$WS/claude.out" && pass "T48 shim states the cap" || fail "T48 no cap message: $(cat "$WS/claude.out")"

echo "T54: a lane call with no verified cost is reserved at the per-call budget against the run cap"
C54="$WS/c54"; new_corpus "$C54"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_FAIL=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t54 --corpus-root "$C54" --corpus-class himmel-code --backend claude-api --max-run-usd 2.50); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 3 ] && pass "T54 three unpriced calls ran, the fourth was refused" || fail "T54 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
[ "$(lastrun "$C54" cost_usd)" = "0.0" ] && pass "T54 the reservation is not reported as cost" || fail "T54 row: $(tail -1 "$C54/graphify-out/semantic-runs.jsonl")"

echo "T65: a call the lane refused before any API request adds nothing to the run cap"
C65="$WS/c65"; new_corpus "$C65"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_REFUSE=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t65 --corpus-root "$C65" --corpus-class himmel-code --backend claude-api --max-run-usd 2.50); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 5 ] && pass "T65 all five refused calls reached the lane" || fail "T65 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'run spend cap' "$WS/claude.out" && fail "T65 refused calls tripped the run cap: $(cat "$WS/claude.out")" || pass "T65 no run-cap message"
grep -q 'claude-api: refused: auto routing' "$WS/claude.out" && pass "T65 the refusal text still reaches stderr" || fail "T65 refusal text lost: $(cat "$WS/claude.out")"

echo "T66: a failed extract names the first lane refusal in its closing line"
C66="$WS/c66"; new_corpus "$C66"; : > "$WS/calls.log"
out=$(GRAPHIFY_STUB_REFUSEDLOG=1 GRAPHIFY_STUB_RC=1 run_api --name t66 --corpus-root "$C66" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[[ "$out" == *"graphify extract exited 1 (refused: stale-snapshot) --"* ]] && pass "T66 the closing line carries the refusal reason" || fail "T66 (rc=$rc): $(printf '%s' "$out" | tail -3)"

echo "T55: a merge that fails after billed lane calls still leaves a run row with the cost"
C55="$WS/c55"; new_corpus "$C55"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_STUB_LEAK=1 GRAPHIFY_STUB_CALL_N=2 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t55 --corpus-root "$C55" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ "$(lastrun "$C55" cost_usd)" = "0.5" ] && pass "T55 failed merge row carries cost 0.5" || fail "T55 (rc=$rc): $(tail -1 "$C55/graphify-out/semantic-runs.jsonl" 2>&1)"

echo "T49: the run row carries the summed lane cost, the backend and the cap"
[ "$(lastrun "$C48" cost_usd)" = "1.2" ] && [ "$(lastrun "$C48" backend)" = "claude-api" ] && [ "$(lastrun "$C48" cap_usd)" = "1.0" ] \
  && pass "T49 cost_usd 1.2, backend claude-api, cap_usd 1.0" || fail "T49 row: $(tail -1 "$C48/graphify-out/semantic-runs.jsonl")"
[ "$(lastrun "$C46" cost_usd)" = "0.0" ] && pass "T49 a non-api run row has cost_usd 0.0" || fail "T49b row: $(tail -1 "$C46/graphify-out/semantic-runs.jsonl")"

echo "T50: rationale and documents/explains/rationale_for edges survive the merge"
C50="$WS/c50"; new_corpus "$C50"
out=$(GRAPHIFY_STUB_DOCEDGES=1 run_api --name t50 --corpus-root "$C50" --corpus-class himmel-code --backend claude-api); rc=$?
python3 - "$C50/graphify-out/graph.json" <<'PY' && pass "T50 rationale + three relations merged" || fail "T50 (rc=$rc): $out"
import json, sys
g = json.load(open(sys.argv[1]))
rels = {e["relation"] for e in g["links"]}
sys.exit(0 if {"documents", "explains", "rationale_for"} <= rels and any(n.get("rationale") for n in g["nodes"]) else 1)
PY

echo "T51: claude-api keeps its extraction cache apart (cache/semantic-r1) so old-prompt chunks are never replayed"
C51="$WS/c51"; new_corpus "$C51"; printf '{}' > "$C51/graphify-out/cache/semantic/old.json"
out=$(run_api --name t51 --corpus-root "$C51" --corpus-class himmel-code --backend claude-api); rc=$?
! grep -q 'old.json' "$WS/seeded.log" && [ -f "$C51/graphify-out/cache/semantic-r1/new.json" ] && [ ! -f "$C51/graphify-out/cache/semantic/new.json" ] \
  && pass "T51 old cache not seeded, new entries land in semantic-r1" || fail "T51 (rc=$rc) seeded=$(cat "$WS/seeded.log") $(ls "$C51/graphify-out/cache/semantic" "$C51/graphify-out/cache/semantic-r1" 2>&1)"
C51B="$WS/c51b"; new_corpus "$C51B"; printf '{}' > "$C51B/graphify-out/cache/semantic/old.json"
out=$(run --name t51b --corpus-root "$C51B" --corpus-class himmel-code); rc=$?
grep -qx 'old.json' "$WS/seeded.log" && pass "T51 claude-cli still seeds cache/semantic" || fail "T51b (rc=$rc) seeded=$(cat "$WS/seeded.log")"

echo "T52: a non-positive --max-run-usd exits 1 with nothing invoked"
C52="$WS/c52"; new_corpus "$C52"; : > "$WS/calls.log"
out=$(run_api --name t52 --corpus-root "$C52" --corpus-class himmel-code --backend claude-api --max-run-usd 0 --dry-run); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"--max-run-usd"* ]] && [ ! -s "$WS/calls.log" ] && pass "T52 refused" || fail "T52 (rc=$rc): $out"

echo "T53: semantic-metrics.py counts coverage and cross-file semantic edges, whole graph and per --files"
M53="$WS/m53.json"
cat > "$M53" <<'EOF'
{"nodes": [{"id": "c1", "file_type": "concept", "source_file": "a.md", "rationale": "because"},
           {"id": "c2", "file_type": "document", "source_file": "a.md", "rationale": " "},
           {"id": "c3", "file_type": "concept", "source_file": "b.md"},
           {"id": "k1", "file_type": "code", "source_file": "x.sh"}],
 "links": [{"source": "c1", "target": "k1", "relation": "documents", "_origin": "semantic"},
           {"source": "c2", "target": "c3", "relation": "references", "_origin": "semantic"},
           {"source": "c2", "target": "c1", "relation": "references", "_origin": "semantic"},
           {"source": "c1", "target": "k1", "relation": "calls", "_origin": "ast"}]}
EOF
all53=$(python3 "$HERE/semantic-metrics.py" "$M53"); a53=$(python3 "$HERE/semantic-metrics.py" "$M53" --files a.md)
[[ "$all53" == *'"coverage_pct": 33.3'* ]] && [[ "$all53" == *'"cross_file_semantic_edges": 2'* ]] && [[ "$all53" == *'"doc_to_code_edges": 1'* ]] \
  && pass "T53 whole graph" || fail "T53 whole: $all53"
[[ "$all53" == *'"model_made_coverage_pct": 50.0'* ]] && [[ "$all53" == *'"model_made_nodes": 2'* ]] \
  && [[ "$a53" == *'"model_made_coverage_pct": 100.0'* ]] && pass "T53 model-made metric" || fail "T53 model-made: $all53 $a53"
[[ "$a53" == *'"coverage_pct": 50.0'* ]] && [[ "$a53" == *'"semantic_nodes": 2'* ]] && pass "T53 --files scope" || fail "T53 scoped: $a53"

stuck() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("stuck",{}).get(sys.argv[2],{}).get(sys.argv[3],""))' "$1/graphify-out/semantic-manifest.json" "$2" "$3"; }

echo "T56: a file never extracted is backed off after 3 attempts on the same content, alerted once, retried when it changes"
C56="$WS/c56"; new_corpus "$C56"
for _ in 1 2 3; do out=$(GRAPHIFY_STUB_SKIP=a.md run --name t56 --corpus-root "$C56" --corpus-class himmel-code); done
[ "$(stuck "$C56" a.md attempts)" = 3 ] && [[ "$(stuck "$C56" a.md reason)" == *"not extracted"* ]] \
  && pass "T56 three attempts recorded with a reason" || fail "T56 stuck record: $(cat "$C56/graphify-out/semantic-manifest.json")"
[[ "$out" == *"BACKED OFF a.md"* ]] && pass "T56 the third failure prints one BACKED OFF line" || fail "T56 no BACKED OFF line: $out"
: > "$WS/calls.log"
out=$(GRAPHIFY_STUB_SKIP=a.md run --name t56 --corpus-root "$C56" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^graphify' "$WS/calls.log" && [[ "$out" == *"backed_off=1"* ]] && [[ "$out" != *"BACKED OFF"* ]] \
  && pass "T56 a backed-off file is not re-extracted (no graphify call, no repeat alert)" || fail "T56 run 4 (rc=$rc): $out / $(cat "$WS/calls.log")"
[ "$(lastrun "$C56" backed_off_files)" = "['a.md']" ] && pass "T56 the run row names the backed-off file" || fail "T56 backed_off_files: $(lastrun "$C56" backed_off_files)"
printf 'aleph\n' > "$C56/a.md"; : > "$WS/calls.log"
out=$(run --name t56 --corpus-root "$C56" --corpus-class himmel-code); rc=$?
case " $(ids "$C56") " in *" sem_a.md_aleph "*) pass "T56 changed content is retried and lands" ;; *) fail "T56 retry (rc=$rc): $(ids "$C56") $out" ;; esac
[ -z "$(stuck "$C56" a.md attempts)" ] && pass "T56 a landed file leaves the stuck record" || fail "T56 stuck kept: $(cat "$C56/graphify-out/semantic-manifest.json")"

echo "T56b: unstick drops the backed-off records so the next run retries the same content"
C56b="$WS/c56b"; new_corpus "$C56b"
for _ in 1 2 3; do GRAPHIFY_STUB_SKIP=a.md run --name t56b --corpus-root "$C56b" --corpus-class himmel-code >/dev/null; done
out=$(python3 "$HERE/semantic-merge.py" unstick --out "$C56b/graphify-out" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"unstick: cleared 1 backed-off record"* ]] && [[ "$out" == *"a.md"* ]] \
  && pass "T56b unstick reports the cleared file" || fail "T56b unstick (rc=$rc): $out"
[ -z "$(stuck "$C56b" a.md attempts)" ] && pass "T56b the stuck record is gone" || fail "T56b stuck kept: $(cat "$C56b/graphify-out/semantic-manifest.json")"
out=$(run --name t56b --corpus-root "$C56b" --corpus-class himmel-code); rc=$?
case " $(ids "$C56b") " in *" sem_a.md_"*) pass "T56b the unstuck file is re-extracted and lands" ;; *) fail "T56b retry (rc=$rc): $(ids "$C56b") $out" ;; esac
python3 - "$C56b/graphify-out/semantic-manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m["stuck"] = {"young.md": {"hash": "h", "attempts": 2, "reason": "r"}}
json.dump(m, open(p, "w"))
PY
out=$(python3 "$HERE/semantic-merge.py" unstick --out "$C56b/graphify-out" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"cleared 0 backed-off"* ]] && [ "$(stuck "$C56b" young.md attempts)" = 2 ] \
  && pass "T56b control: a record still under the attempt limit is kept" || fail "T56b control (rc=$rc): $out"

echo "T57: a refused file's own cache entry is evicted so the retry re-extracts; other entries stay"
C57="$WS/c57"; new_corpus "$C57"; rm -f "$C57/b.md" "$C57/sub/c.md"
mkdir -p "$C57/graphify-out/cache/semantic/p1"
printf '{"nodes":[{"id":"x","source_file":"a.md"}],"edges":[],"hyperedges":[]}' > "$C57/graphify-out/cache/semantic/p1/a-entry.json"
printf '{"nodes":[{"id":"y","source_file":"b.md"}],"edges":[],"hyperedges":[]}' > "$C57/graphify-out/cache/semantic/p1/b-entry.json"
python3 - "$C57/graphify-out/graph.json" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p))
for i in range(4):
    g["nodes"].append({"id": "old_a_%d" % i, "label": "old %d" % i, "file_type": "concept", "_origin": "semantic", "source_file": "a.md"})
json.dump(g, open(p, "w"))
PY
out=$(run --name t57 --corpus-root "$C57" --corpus-class himmel-code); rc=$?
[ ! -e "$C57/graphify-out/cache/semantic/p1/a-entry.json" ] && [ -e "$C57/graphify-out/cache/semantic/p1/b-entry.json" ] \
  && pass "T57 only the refused file's entry is evicted" || fail "T57 (rc=$rc): $(find "$C57/graphify-out/cache" -type f) $out"

echo "T58: files under graphify's skipped dirs (.obsidian) never enter the batch"
C58="$WS/c58"; new_corpus "$C58"; mkdir -p "$C58/.obsidian/plugins/p"; printf 'setup\n' > "$C58/.obsidian/plugins/p/VENDORED.md"
out=$(run --name t58 --corpus-root "$C58" --corpus-class himmel-code); rc=$?
[ "$(lastrun "$C58" batch)" = 3 ] && [ "$(lastrun "$C58" failed)" = 0 ] && pass "T58 .obsidian file skipped" || fail "T58 (rc=$rc): $(tail -1 "$C58/graphify-out/semantic-runs.jsonl")"

echo "T59: test fixtures (any fixtures/ dir) never enter the batch"
C59="$WS/c59"; new_corpus "$C59"; mkdir -p "$C59/scripts/kit/fixtures/mirror"; printf '# T-1\n' > "$C59/scripts/kit/fixtures/mirror/T-1.md"
out=$(run --name t59 --corpus-root "$C59" --corpus-class himmel-code); rc=$?
[ "$(lastrun "$C59" batch)" = 3 ] && pass "T59 fixtures file skipped" || fail "T59 (rc=$rc): $(tail -1 "$C59/graphify-out/semantic-runs.jsonl")"

echo "T60: a never-stamped file removed from the corpus loses its stuck record"
C60="$WS/c60"; new_corpus "$C60"
for _ in 1 2 3; do out=$(GRAPHIFY_STUB_SKIP=a.md run --name t60 --corpus-root "$C60" --corpus-class himmel-code); done
[ "$(stuck "$C60" a.md attempts)" = 3 ] || fail "T60 setup: a.md not backed off: $(cat "$C60/graphify-out/semantic-manifest.json")"
rm -f "$C60/a.md"
out=$(run --name t60 --corpus-root "$C60" --corpus-class himmel-code); rc=$?
[ -z "$(stuck "$C60" a.md attempts)" ] && pass "T60 the removed file's stuck record is pruned" || fail "T60 (rc=$rc): $(cat "$C60/graphify-out/semantic-manifest.json")"

echo "T61: an absolute GRAPHIFY_OUT outside the corpus (the luna AST wrapper's shape) is where the pass reads and writes"
C61="$WS/c61"; new_corpus "$C61"; O61="$WS/state/himmel/graphify/luna/graphify-out"
mkdir -p "$(dirname "$O61")"; mv "$C61/graphify-out" "$O61"
out=$(GRAPHIFY_OUT="$O61" run --name t61 --corpus-root "$C61" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$C61/graphify-out" ] && [ -f "$O61/semantic-manifest.json" ] && [ -f "$O61/semantic-runs.jsonl" ] \
  && pass "T61 absolute GRAPHIFY_OUT honoured, nothing written under the corpus" || fail "T61 (rc=$rc): $out"

echo "T62: a relative GRAPHIFY_OUT that is not a single directory name is still refused"
out=$(GRAPHIFY_OUT=../elsewhere run --name t61 --corpus-root "$C61" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"GRAPHIFY_OUT"* ]] && pass "T62 refused" || fail "T62 (rc=$rc): $out"

echo "T63: a multi-line relative GRAPHIFY_OUT whose later line is a traversal is refused"
out=$(GRAPHIFY_OUT=$'ok\n../elsewhere' run --name t61 --corpus-root "$C61" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"GRAPHIFY_OUT"* ]] && pass "T63 refused" || fail "T63 (rc=$rc): $out"

echo "T64: an absolute GRAPHIFY_OUT that is a symlink is refused, as ast-update.sh refuses it"
C64="$WS/c64"; new_corpus "$C64"; mv "$C64/graphify-out" "$WS/real64"; ln -s "$WS/real64" "$WS/link64"
out=$(GRAPHIFY_OUT="$WS/link64" run --name t64 --corpus-root "$C64" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"SYMLINK"* ]] && [ ! -e "$WS/real64/semantic-manifest.json" ] \
  && pass "T64 symlinked override refused, nothing written through it" || fail "T64 (rc=$rc): $out"

echo
[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
