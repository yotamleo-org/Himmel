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
# the copied repo is a git repo of its own: a corpus inside it is "the himmel graph", one beside it is another repo
git init -q "$REPO"
# Other tools share TMPDIR (handover-path.sh's arm-resume-cache.* in CI): the
# scratch checks look only for this script's own graphify-semantic-* dirs.
mkdir "$WS/tmp/arm-resume-cache.foreign"
for f in semantic-update.sh semantic-merge.py harden-graph.py harden-allowlist.json semantic-batch-shim.mjs; do
  cp "$HERE/$f" "$REPO/scripts/graphify/$f" 2>/dev/null || true
done
ln -s "$REAL_REPO/scripts/guardrails" "$REPO/scripts/guardrails"
cat > "$REPO/scripts/graphify/seed-claude-config.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# Bank stub: verdict from $WS/bank (default PROCEED); every call logged. The real launcher's fallback asks
# with CADENCE_USAGE_LANE=native: $WS/bank-native answers it when present (the T68c rows).
cat > "$REPO/scripts/lib/usage-preflight.sh" <<EOF
#!/usr/bin/env bash
echo bank >> "$WS/calls.log"
[ "\${CADENCE_USAGE_LANE:-}" = native ] && [ -r "$WS/bank-native" ] && { cat "$WS/bank-native"; exit 0; }
cat "$WS/bank" 2>/dev/null || echo PROCEED
EOF
# API-lane stub: records its argv, stdin, cwd and whether `claude`
# still resolves to the semantic-update shim, then answers with a claude envelope.
cat > "$REPO/scripts/api-lane/claude-api.sh" <<EOF
#!/usr/bin/env bash
echo "lane-tools=\${HIMMEL_API_TOOLS-UNSET}" >> "$WS/calls.log"
echo "lane-kind=\${HIMMEL_API_KIND-UNSET}" >> "$WS/calls.log"
cat > "$WS/lane-stdin"
prev=""; for a in "\$@"; do
  if [ "\$prev" = --append-system-prompt-file ]; then
    mkdir -p "$WS/lane-sys"; echo "\$a" >> "$WS/lane-sys-paths"; cat "\$a" > "$WS/lane-sys/\$(ls "$WS/lane-sys" | wc -l | tr -d ' ')"
  fi
  prev="\$a"
done
echo "lane \$* | stdin=\$(tr '\\n' ' ' < "$WS/lane-stdin") | cwdcorpus=\$([ -e "\$PWD/.graphify-corpus" ] && echo yes || echo no) | claude=\$(command -v claude || echo none)" >> "$WS/calls.log"
if [ -n "\${LANE_STUB_REFUSE:-}" ]; then
  echo 'claude-api: refused: auto routing: no account has room for the budget ({"verdict":"SKIPPED-BANK","reason":"stale-snapshot"})' >&2
  exit 2
fi
if [ -n "\${LANE_STUB_REJECT:-}" ]; then
  echo '{"type":"result","is_error":true,"result":"API Error: 400 Your credit balance is too low to access the Anthropic API."}'
  echo "claude-api: account A credit exhausted; auto routing rotates to the other account" >&2
  exit 6
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
echo "EFFORT=\${CLAUDE_CODE_EFFORT_LEVEL-unset}" >> "$WS/env.log"
# GRAPHIFY_STUB_CACHE_HIT: a seeded entry answers the extract with no call, as graphify's cache does; graphify's
# real key is content plus its own prompt, so it cannot see which mode wrote the entry, and neither does this one.
if [ -n "\${GRAPHIFY_STUB_CALL_CLAUDE:-}" ] && [ "\$1" = extract ] && { [ -z "\${GRAPHIFY_STUB_CACHE_HIT:-}" ] || [ ! -e "\$2/graphify-out/cache/semantic/new.json" ]; }; then
  claude --help > "$WS/claude-help.out" 2>&1
  for call_n in \$(seq "\${GRAPHIFY_STUB_CALL_N:-1}"); do
    p="\${GRAPHIFY_STUB_PROMPT:-extract this}"
    printf '%b' "\${p//@CALL@/\$call_n}" | claude -p --output-format json --no-session-persistence --model sonnet --json-schema '{}' >> "$WS/claude.out" 2>&1 \\
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
gi = os.path.join(root, ".graphifyignore")
ignored = set(open(gi).read().split()) if os.path.exists(gi) else set()
for dp, dn, fn in os.walk(root):
    if "graphify-out" in os.path.relpath(dp, root).split(os.sep):
        continue
    for f in fn:
        if not f.endswith(".md"):
            continue
        full = os.path.join(dp, f)
        rel = os.path.relpath(full, root)
        if rel in ignored:
            continue  # graphify honours .graphifyignore: no nodes for an ignored file
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
# claude-cli is an explicit opt-in (the default is claude-api); a later --backend in "$@" wins.
run() { PATH="$WS/bin:$PATH" bash "$SCRIPT" --backend claude-cli "$@" 2>&1; }
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

echo "T21: an untouched file's edge to a node the re-extraction restores survives"
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

echo "T31: graphify extract runs with GRAPHIFY_NO_AUTO_REFRESH=1"
C31="$WS/c31"; new_corpus "$C31"; : > "$WS/env.log"
out=$(unset GRAPHIFY_NO_AUTO_REFRESH; PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t31 --corpus-root "$C31" --corpus-class himmel-code --backend ollama 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qx 'NO_AUTO_REFRESH=1' "$WS/env.log" && pass "T31 graphify saw GRAPHIFY_NO_AUTO_REFRESH=1" \
  || fail "T31 (rc=$rc): $(cat "$WS/env.log") $out"

# --- --backend claude-api through the API lane -----------------
# GRAPHIFY_API_BATCH=0: these rows exercise the synchronous lane path; the batch path has its own rows (T70+).
LANE_ENV=(HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A GRAPHIFY_API_BATCH=0)
run_api() { env "${LANE_ENV[@]}" PATH="$WS/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

echo "T32: claude-api with the lane OFF fails closed: exit 2, nothing copied, no claude-cli fallback"
C32="$WS/c32"; new_corpus "$C32"; : > "$WS/calls.log"
out=$(env -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t32 --corpus-root "$C32" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"API lane"* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
  && pass "T32 refused, nothing invoked" || fail "T32 (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T32b: no --backend and the lane OFF: the default is claude-api, so it refuses (exit 2) and never calls claude or graphify"
C32B="$WS/c32b"; new_corpus "$C32B"; : > "$WS/calls.log"
out=$(env -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t32b --corpus-root "$C32B" --corpus-class himmel-code 2>&1); rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"semantic-update: refusing claude-api: the API lane is off"* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
  && pass "T32b default backend refused with the lane off, nothing invoked" || fail "T32b (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T32c: no --backend and the lane ON: the default resolves to claude-api (graphify's claude is the lane shim, no bank-preflight)"
C32C="$WS/c32c"; new_corpus "$C32C"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(run_api --name t32c --corpus-root "$C32C" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && grep -q '^CLAUDE_BIN=.*graphify-semantic-t32c-' "$WS/env.log" && ! grep -qx bank "$WS/calls.log" \
  && pass "T32c default backend is claude-api" || fail "T32c (rc=$rc): $out / $(cat "$WS/calls.log")"

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

echo "T37b: the lane call is tagged kind=graphify and the fixed addendum sits between graphify's instructions and the chunk"
addendum() { sed -n "/<<'ADD'/,/^ADD\$/p" "$SCRIPT" | sed '1d;$d'; }
reset_lane() { : > "$WS/calls.log"; : > "$WS/claude.out"; : > "$WS/lane-stdin"; : > "$WS/lane-sys-paths"; rm -rf "$WS/lane-sys"; }
# same_bytes <label> <expected file> <got file>: a byte comparison; the flattened form is only the failure message
same_bytes() {
  if cmp -s "$2" "$3"; then pass "$1"
  # read-sink-ok: both paths are this suite's own files under $WS
  else fail "$1: got [$(tr '\n' ' ' < "$3")] want [$(tr '\n' ' ' < "$2")]"; fi
}
C37B="$WS/c37b"; new_corpus "$C37B"; reset_lane
TAIL37B='Now extract the knowledge graph from the following source file(s) and output ONLY the JSON object.\n\nCHUNK BODY'
out=$(GRAPHIFY_STUB_PROMPT="SCHEMA TEXT\\n\\n---\\n$TAIL37B" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37b --corpus-root "$C37B" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && pass "T37b exit 0" || fail "T37b exit 0 (got $rc): $out"
grep -qx 'lane-kind=graphify' "$WS/calls.log" && pass "T37b lane kind is graphify" || fail "T37b kind: $(grep lane-kind "$WS/calls.log")"
ADD37B="$(addendum)"
[ "${#ADD37B}" -gt 200 ] && pass "T37b positive control: the addendum text was read from the script" || fail "T37b addendum text not read from the script (${#ADD37B} chars)"
# the expected prompt: instructions, "---", the whole addendum, "---", then graphify's own request and the chunk, unchanged
{ printf 'SCHEMA TEXT\n\n---\n'; addendum; printf '\n\n---\n'; printf '%b' "$TAIL37B"; } > "$WS/exp37b"
same_bytes "T37b the lane gets exactly: instructions, whole addendum, graphify's request, chunk" "$WS/exp37b" "$WS/lane-stdin"
[ ! -s "$WS/lane-sys-paths" ] && pass "T37b unset opt-in: no system-prompt file" || fail "T37b unset opt-in passed a system-prompt file: $(cat "$WS/lane-sys-paths")"

echo "T37c: GRAPHIFY_API_SYSTEM_PROMPT=1 sends the instructions and the addendum as ONE system file, the request and the chunk on stdin"
C37C="$WS/c37c"; new_corpus "$C37C"; reset_lane
TAIL37C='Now extract the knowledge graph from the following source file(s) and output ONLY the JSON object.\n\nCHUNK @CALL@ BODY'
out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_CALL_N=2 GRAPHIFY_STUB_PROMPT="SCHEMA TEXT\\n\\n---\\n$TAIL37C" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37c --corpus-root "$C37C" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && pass "T37c exit 0" || fail "T37c exit 0 (got $rc): $out"
[ "$(wc -l < "$WS/lane-sys-paths")" -eq 2 ] && [ "$(sort -u "$WS/lane-sys-paths" | wc -l)" -eq 1 ] && pass "T37c both calls pass the same file" || fail "T37c paths: $(cat "$WS/lane-sys-paths")"
{ printf 'SCHEMA TEXT\n\n---\n'; addendum; } > "$WS/exp37c-sys"
same_bytes "T37c the system file is the instructions plus the whole addendum" "$WS/exp37c-sys" "$WS/lane-sys/0"
same_bytes "T37c the second call's system file is byte-identical" "$WS/lane-sys/0" "$WS/lane-sys/1"
printf 'Now extract the knowledge graph from the following source file(s) and output ONLY the JSON object.\n\nCHUNK 2 BODY' > "$WS/exp37c-in"
same_bytes "T37c stdin is only the request and the chunk" "$WS/exp37c-in" "$WS/lane-stdin"
grep -q 'stdin=Now extract .*CHUNK 1 BODY' "$WS/calls.log" && pass "T37c the first call carried its own chunk" || fail "T37c first call stdin: $(grep '^lane ' "$WS/calls.log" | head -1)"
SYS37C="$(head -1 "$WS/lane-sys-paths")"
case "$SYS37C" in /*) pass "T37c the path is absolute" ;; *) fail "T37c relative path: $SYS37C" ;; esac
[ ! -e "$SYS37C" ] && [ -z "$(scratch)" ] && pass "T37c the scratch file is gone after the run" || fail "T37c left behind: $SYS37C $(scratch)"

echo "T37d: opt-in, a call whose instructions differ from the run's file stays inline, so the file never changes"
C37D="$WS/c37d"; new_corpus "$C37D"; reset_lane
out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_CALL_N=2 GRAPHIFY_STUB_PROMPT="SCHEMA @CALL@\\n\\n---\\n$TAIL37C" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37d --corpus-root "$C37D" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$WS/lane-sys-paths")" -eq 1 ] && pass "T37d only the first call passes the file" || fail "T37d (rc=$rc) paths: $(cat "$WS/lane-sys-paths"): $out"
{ printf 'SCHEMA 2\n\n---\n'; addendum; printf '\n\n---\n'; printf 'Now extract the knowledge graph from the following source file(s) and output ONLY the JSON object.\n\nCHUNK 2 BODY'; } > "$WS/exp37d"
same_bytes "T37d the differing call sends today's whole prompt" "$WS/exp37d" "$WS/lane-stdin"

echo "T37e: opt-in without graphify's request line behaves as today: no file, the addendum last"
C37E="$WS/c37e"; new_corpus "$C37E"; reset_lane
out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_PROMPT="no request line" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37e --corpus-root "$C37E" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/lane-sys-paths" ] && pass "T37e no system-prompt file" || fail "T37e (rc=$rc) paths: $(cat "$WS/lane-sys-paths"): $out"
{ printf 'no request line\n\n---\n'; addendum; } > "$WS/exp37e"
same_bytes "T37e the prompt is unchanged" "$WS/exp37e" "$WS/lane-stdin"

echo "T37f: only the value 1 opts in"
C37F="$WS/c37f"; new_corpus "$C37F"; reset_lane
out=$(GRAPHIFY_API_SYSTEM_PROMPT=0 GRAPHIFY_STUB_PROMPT="SCHEMA TEXT\\n\\n---\\n$TAIL37B" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37f --corpus-root "$C37F" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/lane-sys-paths" ] && pass "T37f the value 0 is off" || fail "T37f (rc=$rc) paths: $(cat "$WS/lane-sys-paths"): $out"
same_bytes "T37f the prompt is unchanged" "$WS/exp37b" "$WS/lane-stdin"

echo "T37g: the opt-in keeps its own extraction cache, so a later run without it never replays its answers"
C37G="$WS/c37g"; new_corpus "$C37G"
cache_run() { GRAPHIFY_STUB_CACHE_HIT=1 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37g --corpus-root "$C37G" --corpus-class himmel-code --backend claude-api; }
reset_lane; out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 cache_run); rc=$?
[ "$rc" -eq 0 ] && grep -q '^lane ' "$WS/calls.log" && [ -f "$C37G/graphify-out/cache/semantic-r1-system/new.json" ] && [ ! -e "$C37G/graphify-out/cache/semantic-r1" ] \
  && pass "T37g the on-run calls the lane and its entries land in semantic-r1-system" || fail "T37g on-run (rc=$rc): $(ls "$C37G/graphify-out/cache") $out"
printf 'aleph\n' > "$C37G/a.md"; reset_lane; out=$(cache_run); rc=$?
[ "$rc" -eq 0 ] && grep -q '^lane ' "$WS/calls.log" \
  && pass "T37g the off-run on the same corpus calls the lane" || fail "T37g off-run replayed the on-run's answers (rc=$rc): $out"
printf 'alpha\n' > "$C37G/a.md"; reset_lane; out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 cache_run); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^lane ' "$WS/calls.log" \
  && pass "T37g positive control: a second on-run replays its own cache with no call" || fail "T37g second on-run (rc=$rc): $(cat "$WS/calls.log") $out"

echo "T37h: opt-in, a scratch path with a space reaches the lane as one argument"
C37H="$WS/c37h"; new_corpus "$C37H"; reset_lane; mkdir -p "$WS/tmp space"
out=$(TMPDIR="$WS/tmp space" GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_PROMPT="SCHEMA TEXT\\n\\n---\\n$TAIL37C" GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t37h --corpus-root "$C37H" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && case "$(cat "$WS/lane-sys-paths")" in *"/tmp space/"*) true ;; *) false ;; esac \
  && pass "T37h the path holds the space" || fail "T37h (rc=$rc) paths: $(cat "$WS/lane-sys-paths"): $out"
same_bytes "T37h the file behind that path is the system text" "$WS/exp37c-sys" "$WS/lane-sys/0"

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
C40C="$WS/c40c"; new_corpus "$C40C"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(unset GRAPHIFY_TOKEN_BUDGET CLAUDE_CODE_EFFORT_LEVEL; run --name t40c --corpus-root "$C40C" --corpus-class himmel-code --backend claude-cli); rc=$?
ext40c="$(grep '^graphify extract' "$WS/calls.log")"
if [ "$rc" -ne 0 ] || [ -z "$ext40c" ]; then fail "T40 claude-cli control did not reach graphify extract (rc=$rc): $out"
else case "$ext40c" in *"--token-budget 8000"*) pass "T40 claude-cli caps the chunk at 8000" ;; *) fail "T40 claude-cli expected --token-budget 8000: $ext40c" ;; esac; fi
[ "$(grep '^EFFORT=' "$WS/env.log" | sort -u)" = "EFFORT=high" ] && pass "T40 claude-cli extract runs at effort high by default" || fail "T40 effort: $(grep '^EFFORT=' "$WS/env.log")"
C40D="$WS/c40d"; new_corpus "$C40D"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(GRAPHIFY_TOKEN_BUDGET=4000 CLAUDE_CODE_EFFORT_LEVEL=medium run --name t40d --corpus-root "$C40D" --corpus-class himmel-code --backend claude-cli); rc=$?
case "$(grep '^graphify extract' "$WS/calls.log")" in *"--token-budget 4000"*) pass "T40 GRAPHIFY_TOKEN_BUDGET wins on claude-cli" ;; *) fail "T40 claude-cli override (rc=$rc): $(grep '^graphify extract' "$WS/calls.log") $out" ;; esac
[ "$(grep '^EFFORT=' "$WS/env.log" | sort -u)" = "EFFORT=medium" ] && pass "T40 an operator CLAUDE_CODE_EFFORT_LEVEL wins" || fail "T40 effort override: $(grep '^EFFORT=' "$WS/env.log")"

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

echo "T48: --max-run-usd is a planning input; a planned run goes past it with a WARN and no refusal"
C48="$WS/c48"; new_corpus "$C48"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_COST=0.60 GRAPHIFY_STUB_CALL_N=4 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t48 --corpus-root "$C48" --corpus-class himmel-code --backend claude-api --max-run-usd 1.00); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 4 ] && pass "T48 all four calls ran, none refused at the cap" || fail "T48 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'past the planned cap' "$WS/claude.out" && pass "T48 shim logs the overshoot as a WARN" || fail "T48 no overshoot WARN: $(cat "$WS/claude.out")"
grep -q 'run spend cap reached' "$WS/claude.out" && fail "T48 a call was refused at the cap: $(cat "$WS/claude.out")" || pass "T48 no cap refusal"

echo "T54: unpriced failing calls all run past the cap; the failure is not reported as cost"
C54="$WS/c54"; new_corpus "$C54"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_FAIL=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t54 --corpus-root "$C54" --corpus-class himmel-code --backend claude-api --max-run-usd 2.50); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 5 ] && pass "T54 all five unpriced calls ran" || fail "T54 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'past the planned cap' "$WS/claude.out" && pass "T54 the overshoot is a WARN" || fail "T54 no overshoot WARN: $(cat "$WS/claude.out")"
[ "$(lastrun "$C54" cost_usd)" = "0.0" ] && pass "T54 the reservation is not reported as cost" || fail "T54 row: $(tail -1 "$C54/graphify-out/semantic-runs.jsonl")"

echo "T65: a call the lane refused before any API request adds nothing to the run cap"
C65="$WS/c65"; new_corpus "$C65"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(LANE_STUB_REFUSE=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t65 --corpus-root "$C65" --corpus-class himmel-code --backend claude-api --max-run-usd 2.50); rc=$?
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 5 ] && pass "T65 all five refused calls reached the lane" || fail "T65 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'run spend cap' "$WS/claude.out" && fail "T65 refused calls tripped the run cap: $(cat "$WS/claude.out")" || pass "T65 no run-cap message"
grep -q 'claude-api: refused: auto routing' "$WS/claude.out" && pass "T65 the refusal text still reaches stderr" || fail "T65 refusal text lost: $(cat "$WS/claude.out")"

echo "T68: a credit or key rejection (lane exit 6) stops dispatch: a pinned account gets no call after the first"
C68="$WS/c68"; new_corpus "$C68"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_STUB_CHUNKFAIL=1 LANE_STUB_REJECT=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t68 --corpus-root "$C68" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 5 ] && pass "T68 the run exits 5, never success, after rejected chunks" || fail "T68 exit (got $rc): $out"
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 1 ] && pass "T68 one lane call, the other four chunks never dispatched" || fail "T68 lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"
grep -q 'not dispatching' "$WS/claude.out" && pass "T68 the shim says why it stopped" || fail "T68 no stop line: $(cat "$WS/claude.out")"
[ "$(grep -c '^claude-shim-rc=6$' "$WS/calls.log")" -eq 5 ] && pass "T68 every chunk call reports the non-retryable rc 6" || fail "T68 shim rcs: $(grep claude-shim-rc "$WS/calls.log" | tr '\n' ' ')"
[ "$(lastrun "$C68" cost_usd)" = "0.0" ] && pass "T68 rejected calls add no cost" || fail "T68 row: $(tail -1 "$C68/graphify-out/semantic-runs.jsonl" 2>&1)"

echo "T68b: on auto routing each account in play (A, B and C: no roster here) gets one call, then dispatch stops"
C68B="$REPO/c68b"; new_corpus "$C68B"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(env HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto GRAPHIFY_API_BATCH=0 GRAPHIFY_STUB_CHUNKFAIL=1 LANE_STUB_REJECT=1 GRAPHIFY_STUB_CALL_N=5 GRAPHIFY_STUB_CALL_CLAUDE=1 PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t68b --corpus-root "$C68B" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[ "$rc" -eq 5 ] && pass "T68b the run exits 5 too" || fail "T68b exit (got $rc): $out"
[ "$(grep -c '^lane ' "$WS/calls.log")" -eq 3 ] && pass "T68b three lane calls: one rejection per account in play" || fail "T68b lane calls: $(grep -c '^lane ' "$WS/calls.log") (rc=$rc)"

# --- the real launcher (scripts/api-lane/claude-api.sh) under the shim, only `claude` stubbed ---
# The rows above stub the whole lane, so they cannot show what the launcher really does with a rejection: replay
# it on the subscription (exit 0, the fallback's own cost) or, when the fallback does not run, exit 6.
RL="$WS/rl"
real_lane_on() {
  mkdir -p "$RL/alerts" "$RL/slots" "$WS/home"
  cp "$REPO/scripts/api-lane/claude-api.sh" "$WS/claude-api.stub.sh"
  cp "$REAL_REPO/scripts/api-lane/claude-api.sh" "$REAL_REPO/scripts/api-lane/roster.mjs" "$REAL_REPO/scripts/api-lane/usage.mjs" "$REPO/scripts/api-lane/"
  cp "$REAL_REPO/scripts/lib/api-credit-state.mjs" "$REAL_REPO/scripts/lib/api-roles.mjs" "$REAL_REPO/scripts/lib/fleet-reservation-key.sh" "$REAL_REPO/scripts/lib/native-auth-pin.sh" "$REPO/scripts/lib/"
  local now; now=$(date +%s)
  printf '{"version":1,"ledger_path":"%s","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00","key_id":"key-a","reset_at":"2099-01-01T00:00:00Z"}}}' "$RL/ledger.json" > "$RL/config.json"
  printf '{"version":1,"accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","grant_usd":"50.00","remaining_usd":"50.00","reconciled_spent_usd":"0","starts_at":%d,"expires_at":%d,"observed_at":%d,"source":"operator-console-snapshot","exclusive_org":true,"discrepancy":false}}}' $((now-1000)) $((now+3600)) "$now" > "$RL/snapshot.json"
  printf 'ANTHROPIC_API_KEY=sk-ant-dummy-not-a-real-key-0000\n' > "$RL/key-A.env"; chmod 600 "$RL/key-A.env"
  printf '#!/bin/bash\nexit 0\n' > "$RL/alert-stub"; chmod +x "$RL/alert-stub"
  # a call with the API key is the API call; one without it is the subscription fallback
  cat > "$RL/claude-stub" <<STUB
#!/usr/bin/env bash
cat > /dev/null
if [ -n "\${ANTHROPIC_API_KEY:-}" ]; then
  echo api >> "$WS/rl-calls.log"
  if [ -n "\${RL_STUB_FAIL:-}" ]; then
    echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true}'
    exit 1
  fi
  if [ -n "\${RL_STUB_REJECT:-}" ]; then
    echo '{"type":"result","is_error":true,"result":"API Error: 400 Your credit balance is too low to access the Anthropic API."}'
    exit 1
  fi
  echo '{"type":"result","subtype":"success","is_error":false,"result":"{}","total_cost_usd":0.25,"usage":{"input_tokens":1,"output_tokens":1}}'
  exit 0
fi
echo sub >> "$WS/rl-calls.log"
echo '{"type":"result","subtype":"success","is_error":false,"result":"{}","total_cost_usd":0.31,"usage":{"input_tokens":1,"output_tokens":1}}'
STUB
  chmod +x "$RL/claude-stub"
  : > "$WS/rl-calls.log"; : > "$WS/calls.log"; : > "$WS/claude.out"; rm -f "$WS/bank-native" "$RL"/ledger.json* "$RL/launches.jsonl"
}
real_lane_off() { cp "$WS/claude-api.stub.sh" "$REPO/scripts/api-lane/claude-api.sh"; rm -f "$WS/bank-native"; }
run_real_lane() {
  env "${LANE_ENV[@]}" HOME="$WS/home" PATH="$WS/bin:$PATH" HIMMEL_API_CREDIT_CONFIG="$RL/config.json" HIMMEL_API_CREDIT_SNAPSHOT="$RL/snapshot.json" \
    HIMMEL_API_CREDIT_STATE="$RL/ledger.json" HIMMEL_API_CLAUDE_BIN="$RL/claude-stub" HIMMEL_API_ALERT_CMD="$RL/alert-stub" \
    HIMMEL_API_ALERT_DIR="$RL/alerts" HIMMEL_FLEET_SLOTS="$RL/slots" CADENCE_USAGE_SKIP_REFRESH=1 GRAPHIFY_STUB_CALL_CLAUDE=1 \
    bash "$SCRIPT" "$@" 2>&1
}

echo "T68c: through the real launcher, a rejection the fallback does not rerun exits 6 and the breaker stops dispatch"
real_lane_on
C68C="$WS/c68c"; new_corpus "$C68C"; echo SKIPPED-BANK > "$WS/bank-native"
out=$(GRAPHIFY_STUB_CHUNKFAIL=1 RL_STUB_REJECT=1 GRAPHIFY_STUB_CALL_N=5 run_real_lane --name t68c --corpus-root "$C68C" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 5 ] && pass "T68c the run exits 5 after rejected chunks" || fail "T68c exit (got $rc): $out"
[ "$(grep -c '^api$' "$WS/rl-calls.log")" -eq 1 ] && pass "T68c one API call, the other four chunks never dispatched" || fail "T68c API calls: $(grep -c '^api$' "$WS/rl-calls.log") (rc=$rc)"
[ "$(grep -c '^claude-shim-rc=6$' "$WS/calls.log")" -eq 5 ] && pass "T68c every chunk reports the launcher's own exit 6" || fail "T68c shim rcs: $(grep claude-shim-rc "$WS/calls.log" | tr '\n' ' ')"
[ "$(grep -c '^sub$' "$WS/rl-calls.log")" -eq 0 ] && pass "T68c the subscription fallback never ran" || fail "T68c fallback ran: $(cat "$WS/rl-calls.log")"
real_lane_off

echo "T68d: through the real launcher, a rejection replayed on the subscription adds nothing to the API spend, and the breaker stays open"
real_lane_on
C68D="$WS/c68d"; new_corpus "$C68D"
out=$(RL_STUB_REJECT=1 GRAPHIFY_STUB_CALL_N=3 run_real_lane --name t68d --corpus-root "$C68D" --corpus-class himmel-code --backend claude-api --max-run-usd 1.50); rc=$?
grep -q 'past the planned cap' "$WS/claude.out" && fail "T68d a rejected (unbilled) attempt reserved against the run cap: $(cat "$WS/claude.out")" || pass "T68d a rejected attempt reserves nothing"
[ "$(grep -c '^sub$' "$WS/rl-calls.log")" -eq 3 ] && pass "T68d all three chunks ran on the subscription" || fail "T68d lane calls: $(tr '\n' ' ' < "$WS/rl-calls.log") (rc=$rc): $out"
[ "$(grep -c '^claude-shim-rc=' "$WS/calls.log")" -eq 0 ] && pass "T68d no chunk failed: the fallback's exit replaced the rejection" || fail "T68d shim rcs: $(grep claude-shim-rc "$WS/calls.log" | tr '\n' ' ')"
[ "$(lastrun "$C68D" cost_usd)" = "0.0" ] && pass "T68d the API spend is 0 (the subscription's 0.31 per chunk is not API spend)" || fail "T68d row: $(tail -1 "$C68D/graphify-out/semantic-runs.jsonl" 2>&1)"
real_lane_off

echo "T68f: through the real launcher, a failed API attempt replayed on the subscription still reserves its per-call budget"
real_lane_on
C68F="$WS/c68f"; new_corpus "$C68F"
out=$(RL_STUB_FAIL=1 GRAPHIFY_STUB_CALL_N=3 run_real_lane --name t68f --corpus-root "$C68F" --corpus-class himmel-code --backend claude-api --max-run-usd 1.50); rc=$?
[ "$(grep -c '^sub$' "$WS/rl-calls.log")" -eq 3 ] && pass "T68f all three chunks ran on the subscription" || fail "T68f lane calls: $(tr "\n" " " < "$WS/rl-calls.log") (rc=$rc): $(head -c 900 "$WS/claude.out")"
[ "$(lastrun "$C68F" cost_usd)" = "0.0" ] && pass "T68f the API spend stays 0" || fail "T68f row: $(tail -1 "$C68F/graphify-out/semantic-runs.jsonl" 2>&1)"
grep -q 'past the planned cap' "$WS/claude.out" && pass "T68f the failed attempts' reserve (1.00 each) passes the 1.50 cap" || fail "T68f no cap WARN: $(head -c 900 "$WS/claude.out")"
real_lane_off

echo "T68e: through the real launcher, an API call that succeeds still adds its cost to the spend"
real_lane_on
C68E="$WS/c68e"; new_corpus "$C68E"
out=$(GRAPHIFY_STUB_CALL_N=2 run_real_lane --name t68e --corpus-root "$C68E" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$(grep -c '^api$' "$WS/rl-calls.log")" -eq 2 ] && pass "T68e both calls ran on the API" || fail "T68e lane calls: $(tr "\n" " " < "$WS/rl-calls.log") (rc=$rc): $(head -c 900 "$WS/claude.out")"
[ "$(lastrun "$C68E" cost_usd)" = "0.5" ] && pass "T68e the spend is the two calls' 0.25" || fail "T68e row: $(tail -1 "$C68E/graphify-out/semantic-runs.jsonl" 2>&1)"
real_lane_off

echo "T66: a failed extract names the first lane refusal in its closing line"
C66="$WS/c66"; new_corpus "$C66"; : > "$WS/calls.log"
out=$(GRAPHIFY_STUB_REFUSEDLOG=1 GRAPHIFY_STUB_RC=1 run_api --name t66 --corpus-root "$C66" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[[ "$out" == *"graphify extract exited 1 (refused: stale-snapshot) --"* ]] && pass "T66 the closing line carries the refusal reason" || fail "T66 (rc=$rc): $(printf '%s' "$out" | tail -3)"

echo "T66b: an exit-zero extract with failed chunks names the first lane refusal in its FAILED line"
C66B="$WS/c66b"; new_corpus "$C66B"; : > "$WS/calls.log"
out=$(GRAPHIFY_STUB_REFUSEDLOG=1 GRAPHIFY_STUB_CHUNKFAIL=1 run_api --name t66b --corpus-root "$C66B" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[ "$rc" -eq 5 ] && [[ "$out" == *"FAILED: 8/9 semantic chunks failed (refused: stale-snapshot) --"* ]] && pass "T66b the FAILED line carries the refusal reason, exit 5" || fail "T66b (rc=$rc): $(printf '%s' "$out" | tail -3)"

echo "T67: the run cap sizes the batch so its estimated chunks fit"
C67="$WS/c67"; new_corpus "$C67"
for i in $(seq 1 40); do printf 'file %s\n' "$i" > "$C67/f$i.md"; done
out=$(run_api --name t67 --corpus-root "$C67" --corpus-class himmel-code --backend claude-api --max-run-usd 0.50 --dry-run); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"sized: batch of "* ]] && [[ "$out" == *"to fit the run cap of 0.50 USD"* ]] && pass "T67 an oversized batch is cut to fit the cap" || fail "T67 (rc=$rc): $out"
out=$(run_api --name t67b --corpus-root "$C67" --corpus-class himmel-code --backend claude-api --max-run-usd 15.00 --dry-run); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" != *"sized:"* ]] && pass "T67 a batch inside the cap is not cut" || fail "T67b (rc=$rc): $out"

echo "T55: a merge that fails after billed lane calls still leaves a run row with the cost"
C55="$WS/c55"; new_corpus "$C55"; : > "$WS/calls.log"; : > "$WS/claude.out"
out=$(GRAPHIFY_STUB_LEAK=1 GRAPHIFY_STUB_CALL_N=2 GRAPHIFY_STUB_CALL_CLAUDE=1 run_api --name t55 --corpus-root "$C55" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ "$(lastrun "$C55" cost_usd)" = "0.5" ] && pass "T55 failed merge row carries cost 0.5" || fail "T55 (rc=$rc): $(tail -1 "$C55/graphify-out/semantic-runs.jsonl" 2>&1)"

echo "T49: the run row carries the summed lane cost, the backend and the cap"
[ "$(lastrun "$C48" cost_usd)" = "2.4" ] && [ "$(lastrun "$C48" backend)" = "claude-api" ] && [ "$(lastrun "$C48" cap_usd)" = "1.0" ] \
  && pass "T49 cost_usd 2.4, backend claude-api, cap_usd 1.0" || fail "T49 row: $(tail -1 "$C48/graphify-out/semantic-runs.jsonl")"
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

# --- --backend claude-api through the Message Batches API (the default) -----
# The real client (semantic-batch.mjs) is covered by semantic-batch.test.mjs against a loopback stub of the endpoint;
# here a stand-in client and credit-state with the same command line prove the wiring around them.
cat > "$REPO/scripts/graphify/semantic-batch.mjs" <<'EOF'
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [cmd, ...a] = process.argv.slice(2);
const o = {}; for (let i = 0; i < a.length; i += 2) o[a[i].slice(2)] = a[i + 1];
const ws = process.env.BATCH_STUB_WS;
const log = (m) => appendFileSync(join(ws, 'batch.log'), `${m}\n`);
const sp = join(o.dir, 'batch.json');
const state = () => JSON.parse(readFileSync(sp, 'utf8'));
if (cmd === 'submit') {
  if (existsSync(sp)) { console.error('a pending batch is resumed, never resubmitted'); process.exit(2); }
  const ids = readdirSync(o.prompts).filter((f) => f.endsWith('.txt')).map((f) => f.slice(0, -4));
  log(`submit account=${o.account} prompts=${ids.length} model=${o.model} effort=${o.effort}`);
  if ((process.env.BATCH_STUB_EXHAUSTED || '').split(',').includes(o.account)) { console.error('semantic-batch: credit exhausted (HTTP 400)'); process.exit(5); }
  if ((process.env.BATCH_STUB_FAIL || '').split(',').includes(o.account)) { console.error('semantic-batch: HTTP 401 invalid x-api-key'); process.exit(4); }
  mkdirSync(o.dir, { recursive: true });
  // as the real client: the shim's chunk-body key sidecars ride in batch.json
  const bodies = {};
  for (const id of ids) if (existsSync(join(o.prompts, `${id}.key`))) bodies[readFileSync(join(o.prompts, `${id}.key`), 'utf8').trim()] = id;
  writeFileSync(sp, JSON.stringify({ batch_id: 'msgbatch_stub', account: o.account, request_count: ids.length, custom_ids: ids, bodies, status: 'in_progress' }));
  console.log(JSON.stringify({ batch_id: 'msgbatch_stub', request_count: ids.length, status: 'in_progress' }));
} else if (cmd === 'poll') {
  const st = state();
  st.status = existsSync(join(ws, 'batch-status')) ? readFileSync(join(ws, 'batch-status'), 'utf8').trim() : 'in_progress';
  log(`poll ${st.status}`);
  writeFileSync(sp, JSON.stringify(st));
  console.log(JSON.stringify({ batch_id: st.batch_id, status: st.status }));
} else if (cmd === 'results') {
  const st = state();
  log('results');
  mkdirSync(o.out, { recursive: true });
  for (const id of st.custom_ids) {
    if (process.env.BATCH_STUB_DROP) continue;
    writeFileSync(join(o.out, `${id}.json`), JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: '{}', usage: {}, total_cost_usd: 0.0035 }));
  }
  if (Object.keys(st.bodies || {}).length > 0 && !process.env.BATCH_STUB_DROP) writeFileSync(join(o.out, 'bodies.json'), JSON.stringify(st.bodies));
  st.cost_usd = '0.003500';
  writeFileSync(sp, JSON.stringify(st));
  console.log(JSON.stringify({ batch_id: st.batch_id, succeeded: process.env.BATCH_STUB_DROP ? 0 : st.custom_ids.length, cost_usd: st.cost_usd }));
} else process.exit(2);
EOF
cat > "$REPO/scripts/lib/api-credit-state.mjs" <<'EOF'
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
const ws = process.env.BATCH_STUB_WS;
const f = join(ws, 'exhausted.log');
if (process.argv[2] === 'pick') {
  // as the real pick: the first account of --only (else A, B, C) not marked exhausted; every one marked, the first serves
  const marked = existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(Boolean) : [];
  const i = process.argv.indexOf('--only');
  const list = i > 0 ? process.argv[i + 1].split(',') : ['A', 'B', 'C'];
  console.log(JSON.stringify({ verdict: 'PROCEED', account: list.find((l) => !marked.includes(l)) || list[0], snapshot_stale: false }));
} else if (process.argv[2] === 'exhausted') {
  appendFileSync(f, `${process.env.HIMMEL_API_ACCOUNT}\n`);
  console.log('{}');
}
EOF
: > "$REPO/scripts/lib/api-roles.mjs"  # the stub tree has no role map: an empty module prints no accounts, as no roles.json does
chmod +x "$REPO/scripts/graphify/semantic-batch-shim.mjs"
export BATCH_STUB_WS="$WS"
run_batch() { env HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT="${ACCT:-A}" PATH="$WS/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }
batch_reset() { : > "$WS/batch.log"; : > "$WS/calls.log"; rm -f "$WS/batch-status" "$WS/exhausted.log"; }

echo "T70: claude-api submits ONE batch of the recorded chunk prompts and leaves the graph, manifest and cache untouched"
C70="$WS/c70"; new_corpus "$C70"; batch_reset; before=$(ids "$C70")
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t70 --corpus-root "$C70" --corpus-class himmel-code --backend claude-api); rc=$?
P70="$C70/graphify-out/semantic-batch"
[ "$rc" -eq 0 ] && [ "$(ids "$C70")" = "$before" ] && [ ! -e "$C70/graphify-out/semantic-manifest.json" ] \
  && pass "T70 exit 0, graph and manifest untouched" || fail "T70 (rc=$rc): $out"
[ "$(grep -c '^submit' "$WS/batch.log")" -eq 1 ] && grep -q '^submit account=A prompts=1 model=sonnet effort=high$' "$WS/batch.log" \
  && pass "T70 one submit: account A, one recorded prompt, sonnet at high effort" || fail "T70 batch.log: $(cat "$WS/batch.log")"
[ -f "$P70/batch.json" ] && [ -f "$P70/plan.json" ] && [ -f "$P70/corpus/a.md" ] \
  && pass "T70 batch.json, plan and the frozen corpus are persisted" || fail "T70 pending dir: $(ls -R "$P70" 2>&1)"
[ ! -e "$P70/corpus/graphify-out/cache/semantic/new.json" ] \
  && pass "T70 the record run's placeholder cache is not in the frozen corpus" || fail "T70 placeholder cache leaked into the frozen corpus"
[[ "$out" == *"BATCH id=msgbatch_stub state=submitted requests=1 cost_usd=-"* ]] \
  && pass "T70 the BATCH line names id, state and request count" || fail "T70 BATCH line: $out"
grep -q '^lane ' "$WS/calls.log" && fail "T70 the synchronous lane was called" || pass "T70 no synchronous lane call"

echo "T71: a batch still in progress is polled, not resubmitted; the graph stays untouched"
: > "$WS/calls.log"
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t70 --corpus-root "$C70" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^submit' "$WS/batch.log")" -eq 1 ] && grep -q '^poll in_progress$' "$WS/batch.log" \
  && [ "$(ids "$C70")" = "$before" ] && [[ "$out" == *"still in progress"* ]] && [[ "$out" == *"state=pending"* ]] \
  && pass "T71 polled, one submit in total, graph untouched" || fail "T71 (rc=$rc): $out / $(cat "$WS/batch.log")"
grep -q '^graphify extract' "$WS/calls.log" && fail "T71 graphify ran on a pending batch" || pass "T71 no extraction while pending"

echo "T72: an ended batch is replayed through graphify, merged with batch id, request count and cost on the run row"
: > "$WS/calls.log"; echo ended > "$WS/batch-status"
# a retried resume finds the match log of the attempt before it: its lines must not count into this run
mkdir -p "$P70/results"; printf 'body\nbody\n' > "$P70/results/replay-matches.log"
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t70 --corpus-root "$C70" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [[ "$(ids "$C70")" == *sem_a.md_alpha* ]] && [[ "$(ids "$C70")" != *stale_a* ]] \
  && pass "T72 exit 0, results merged into the graph" || fail "T72 (rc=$rc): $out / $(ids "$C70")"
[ "$(grep -c '^submit' "$WS/batch.log")" -eq 1 ] && [ ! -e "$P70" ] \
  && pass "T72 still one submit in total, the pending dir is gone" || fail "T72 submits/pending: $(cat "$WS/batch.log") / $(ls "$P70" 2>&1)"
[ "$(lastrun "$C70" batch_id)" = "msgbatch_stub" ] && [ "$(lastrun "$C70" batch_requests)" = "1" ] \
  && [ "$(lastrun "$C70" cost_usd)" = "0.0035" ] && [ "$(lastrun "$C70" backend)" = "claude-api" ] \
  && pass "T72 run row: batch_id msgbatch_stub, batch_requests 1, cost_usd 0.0035" || fail "T72 row: $(tail -1 "$C70/graphify-out/semantic-runs.jsonl")"
[[ "$out" == *"state=merged requests=1 cost_usd=0.003500"* ]] && pass "T72 the BATCH line closes the run as merged" || fail "T72 BATCH line: $out"
grep -q 'claude-shim-rc' "$WS/calls.log" && fail "T72 the replay shim missed an answer: $(cat "$WS/calls.log")" || pass "T72 every chunk prompt was answered from the batch"
[[ "$out" == *"semantic-update: replay answered 1 chunk(s) by full prompt hash and 0 by chunk-body key"* ]] \
  && pass "T72 the run log says how many chunks matched by full hash and by chunk-body key" || fail "T72 replay match line: $out"

echo "T72c: a batch recorded under one set of graphify instructions is replayed under another and still answers, counted as a chunk-body match"
# FIXTURE: the boundary paragraph and the <untrusted_source> wrapper are copied from a graphify 0.9.103+himmel.1 record run
# on the frozen corpus of the 2026-10-29 batch (the prompt's own text); only the instructions above the boundary differ.
BOUND72C='Now extract the knowledge graph from the following source file(s) and output ONLY the JSON object described above. No prose, no preamble, no markdown fences.'
CHUNK72C='<untrusted_source path="a.md" sha256="4da4ea7e34cf5ba0423d5c7d2b9768c31d2e7b1cf3b868b0e391456f4f81b77b">\nalpha text\n</untrusted_source>'
C72C="$WS/c72c"; new_corpus "$C72C"; batch_reset
out=$(GRAPHIFY_STUB_PROMPT="OLD INSTRUCTIONS\\n\\n$BOUND72C\\n\\n$CHUNK72C" GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t72c --corpus-root "$C72C" --corpus-class himmel-code --backend claude-api); rc=$?
echo ended > "$WS/batch-status"
out=$(GRAPHIFY_STUB_PROMPT="NEW INSTRUCTIONS, reworded\\n\\n$BOUND72C\\n\\n$CHUNK72C" GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t72c --corpus-root "$C72C" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'claude-shim-rc' "$WS/calls.log" \
  && pass "T72c the changed instructions still got their answer from the batch" || fail "T72c (rc=$rc): $out / $(cat "$WS/calls.log")"
[[ "$out" == *"semantic-update: replay answered 0 chunk(s) by full prompt hash and 1 by chunk-body key"* ]] \
  && pass "T72c the run log counts the chunk as a chunk-body match" || fail "T72c replay match line: $out"

echo "T72b: the opt-in does not reach a batch, so a batch keeps semantic-r1 with the knob set"
C72B="$WS/c72b"; new_corpus "$C72B"; batch_reset
out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t72b --corpus-root "$C72B" --corpus-class himmel-code --backend claude-api); rc=$?
echo ended > "$WS/batch-status"
out=$(GRAPHIFY_API_SYSTEM_PROMPT=1 GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t72b --corpus-root "$C72B" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ -f "$C72B/graphify-out/cache/semantic-r1/new.json" ] && [ ! -e "$C72B/graphify-out/cache/semantic-r1-system" ] \
  && pass "T72b entries land in semantic-r1" || fail "T72b (rc=$rc): $(ls "$C72B/graphify-out/cache") $out"

echo "T73: a prompt the batch did not answer fails that chunk call (exit 1), so its files stay unstamped"
C73="$WS/c73"; new_corpus "$C73"; batch_reset
GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t73 --corpus-root "$C73" --corpus-class himmel-code --backend claude-api >/dev/null
echo ended > "$WS/batch-status"
out=$(BATCH_STUB_DROP=1 GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t73 --corpus-root "$C73" --corpus-class himmel-code --backend claude-api); rc=$?
grep -q 'claude-shim-rc=1' "$WS/calls.log" && pass "T73 the replay shim exited 1 on the unanswered prompt" || fail "T73 (rc=$rc): $(cat "$WS/calls.log")"

echo "T74: auto routing rotates to the other account on a credit-exhausted answer (decision 229)"
C74="$REPO/c74"; new_corpus "$C74"; batch_reset
out=$(ACCT=auto BATCH_STUB_EXHAUSTED=A GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t74 --corpus-root "$C74" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^submit' "$WS/batch.log")" -eq 2 ] && [ "$(sed -n 1p "$WS/batch.log" | cut -d' ' -f2)" = "account=A" ] \
  && [ "$(sed -n 2p "$WS/batch.log" | cut -d' ' -f2)" = "account=B" ] && [ "$(cat "$WS/exhausted.log")" = "A" ] \
  && [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["account"])' "$C74/graphify-out/semantic-batch/batch.json")" = "B" ] \
  && pass "T74 A exhausted and marked, the batch went to B" || fail "T74 (rc=$rc): $out / $(cat "$WS/batch.log") / $(cat "$WS/exhausted.log" 2>&1)"

echo "T74b: auto routing over a corpus outside the himmel checkout is refused before any pick or submit"
C74B="$WS/c74b"; new_corpus "$C74B"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t74b --corpus-root "$C74B" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/batch.log" ] && [ ! -e "$C74B/graphify-out/semantic-batch" ] && [[ "$out" == *"himmel graph pass only"* ]] \
  && pass "T74b exit 2, nothing submitted, no batch directory" || fail "T74b (rc=$rc): $out / $(cat "$WS/batch.log")"

echo "T75: a pinned account is marked exhausted but never rotated; nothing is submitted, exit 2"
C75="$WS/c75"; new_corpus "$C75"; batch_reset
out=$(ACCT=A BATCH_STUB_EXHAUSTED=A,B GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t75 --corpus-root "$C75" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ "$(grep -c '^submit' "$WS/batch.log")" -eq 1 ] && [ ! -e "$C75/graphify-out/semantic-batch" ] && [[ "$out" == *"nothing submitted"* ]] \
  && pass "T75 one attempt, exit 2, no pending batch" || fail "T75 (rc=$rc): $out / $(cat "$WS/batch.log")"

echo "T76: a run that waited out another run's submit resumes that batch instead of resubmitting"
C76="$WS/c76"; new_corpus "$C76"; batch_reset
mkdir -p "$C76/graphify-out/.promote.lock"
GRAPHIFY_SEMANTIC_LOCK_WAIT=60 GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t76 --corpus-root "$C76" --corpus-class himmel-code --backend claude-api > "$WS/t76-b.out" &
t76_b=$!
for _ in $(seq 1 50); do grep -q 'chunk: call-cap' "$WS/t76-b.out" && break; sleep 0.2; done
sleep 1
rmdir "$C76/graphify-out/.promote.lock"
GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t76 --corpus-root "$C76" --corpus-class himmel-code --backend claude-api > "$WS/t76-a.out"
wait "$t76_b"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^submit' "$WS/batch.log")" -eq 1 ] && [ -f "$C76/graphify-out/semantic-batch/batch.json" ] \
  && grep -q 'still in progress' "$WS/t76-b.out" \
  && pass "T76 one submit in total, the waiting run polled the first run's batch" || fail "T76 (rc=$rc): $(cat "$WS/batch.log") / A: $(cat "$WS/t76-a.out") / B: $(cat "$WS/t76-b.out")"

echo "T77: GRAPHIFY_API_BATCH=0 refuses to extract synchronously while a batch is pending (exit 2, graph untouched)"
C77="$WS/c77"; new_corpus "$C77"; batch_reset; before=$(ids "$C77")
GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77 --corpus-root "$C77" --corpus-class himmel-code --backend claude-api >/dev/null
: > "$WS/calls.log"
out=$(GRAPHIFY_API_BATCH=0 GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77 --corpus-root "$C77" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"a batch is pending"* ]] && [ "$(ids "$C77")" = "$before" ] && [ -f "$C77/graphify-out/semantic-batch/batch.json" ] \
  && ! grep -q '^graphify extract' "$WS/calls.log" \
  && pass "T77 exit 2, the pending batch and the graph are untouched, nothing extracted" || fail "T77 (rc=$rc): $out / $(cat "$WS/calls.log")"

batch_accounts() { sed -n 's/^submit account=\([A-C]\) .*/\1/p' "$WS/batch.log" | tr '\n' ' '; }

echo "T78: auto routing with A and B exhausted and C live submits on C: each account once, in order, every retry line names its account"
C78="$REPO/c78"; new_corpus "$C78"; batch_reset
out=$(ACCT=auto BATCH_STUB_EXHAUSTED=A,B GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t78 --corpus-root "$C78" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(batch_accounts)" = "A B C " ] && [ "$(tr '\n' ' ' < "$WS/exhausted.log")" = "A B " ] \
  && [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["account"])' "$C78/graphify-out/semantic-batch/batch.json")" = "C" ] \
  && pass "T78 A and B marked, the one batch went to C" || fail "T78 (rc=$rc) accounts '$(batch_accounts)': $out / $(cat "$WS/exhausted.log" 2>&1)"
[[ "$out" == *"account A credit exhausted (tried: A)"* ]] && [[ "$out" == *"retrying the batch on account B (tried: A)"* ]] \
  && [[ "$out" == *"account B credit exhausted (tried: A B)"* ]] && [[ "$out" == *"retrying the batch on account C (tried: A B)"* ]] \
  && pass "T78 each retry line names the account and every account tried so far" || fail "T78 retry lines: $out"

echo "T79: every account exhausted: each is tried once, the failure names them all, and nothing loops"
C79="$REPO/c79"; new_corpus "$C79"; batch_reset
out=$(ACCT=auto BATCH_STUB_EXHAUSTED=A,B,C GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t79 --corpus-root "$C79" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ "$(batch_accounts)" = "A B C " ] && [ ! -e "$C79/graphify-out/semantic-batch" ] \
  && [[ "$out" == *"credit exhausted on every account tried (A B C)"* ]] && [[ "$out" == *"submitting the batch failed (rc 5)"* ]] \
  && pass "T79 three submits, one per account, the failure names A B C, nothing pending" || fail "T79 (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T80: a bad key or any non-credit error does not walk the other accounts: one attempt, the rule stated"
C80="$REPO/c80"; new_corpus "$C80"; batch_reset
out=$(ACCT=auto BATCH_STUB_FAIL=A GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t80 --corpus-root "$C80" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ "$(batch_accounts)" = "A " ] && [ ! -s "$WS/exhausted.log" ] && [[ "$out" == *"only a credit-exhausted answer tries the next account"* ]] \
  && pass "T80 one submit on A, no marker, the walk rule is in the log" || fail "T80 (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T81: nothing chosen (the API lane off): no semantic call on any account, and the output says AST only"
C81="$WS/c81"; new_corpus "$C81"; batch_reset
out=$(env -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT PATH="$WS/bin:$PATH" bash "$SCRIPT" --name t81 --corpus-root "$C81" --corpus-class himmel-code --backend claude-api 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/batch.log" ] && ! grep -q '^lane \|^graphify extract' "$WS/calls.log" && [[ "$out" == *"AST only"* ]] \
  && pass "T81 refused before any call, the output says AST only" || fail "T81 (rc=$rc): $out / $(cat "$WS/calls.log")"

# --- the role map (roles.json beside the account config) narrows the auto batch pick ---
# These rows run the REAL api-credit-state.mjs and api-roles.mjs over a temp config and snapshot (A, B and C all
# roomy, A expiring first); only the batch client stays the stand-in. The stub credit-state is put back afterwards.
cp "$REPO/scripts/lib/api-credit-state.mjs" "$WS/credit-state.stub.mjs"
RC="$WS/roles-cfg"
roles_fixture() {
  rm -rf "$RC"; mkdir -p "$RC"
  local now; now=$(date +%s)
  printf '{"version":1,"ledger_path":"%s","accounts":{"A":{"organization_id":"org-a","cycle_id":"cycle-a","cap_usd":"50.00","reset_at":"2099-01-01T00:00:00Z"},"B":{"organization_id":"org-b","cycle_id":"cycle-b","cap_usd":"50.00","reset_at":"2099-01-01T00:00:00Z"},"C":{"organization_id":"org-c","cycle_id":"cycle-c","cap_usd":"50.00","reset_at":"2099-01-01T00:00:00Z"}}}' "$RC/ledger.json" > "$RC/config.json"
  local l i=0
  { printf '{"version":1,"accounts":{'
    for l in A B C; do
      [ "$i" -eq 0 ] || printf ','
      printf '"%s":{"organization_id":"org-%s","cycle_id":"cycle-%s","grant_usd":"50.00","remaining_usd":"50.00","reconciled_spent_usd":"0","starts_at":%d,"expires_at":%d,"observed_at":%d,"source":"operator-console-snapshot","exclusive_org":true,"discrepancy":false}' \
        "$l" "$(echo "$l" | tr A-C a-c)" "$(echo "$l" | tr A-C a-c)" $((now-1000)) $((now+3600+i*3600)) "$now"
      i=$((i+1))
    done
    printf '}}'; } > "$RC/snapshot.json"
  export HIMMEL_API_CREDIT_CONFIG="$RC/config.json" HIMMEL_API_CREDIT_SNAPSHOT="$RC/snapshot.json"
}
roles_real_on() { cp "$REAL_REPO/scripts/lib/api-credit-state.mjs" "$REAL_REPO/scripts/lib/api-roles.mjs" "$REPO/scripts/lib/"; }
roles_real_off() { cp "$WS/credit-state.stub.mjs" "$REPO/scripts/lib/api-credit-state.mjs"; : > "$REPO/scripts/lib/api-roles.mjs"; unset HIMMEL_API_CREDIT_CONFIG HIMMEL_API_CREDIT_SNAPSHOT; }

echo "T77a: no roles.json, auto batch submits on A (the earliest-expiring), as before the role map"
roles_fixture; roles_real_on
C77A="$REPO/c77a"; new_corpus "$C77A"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77a --corpus-root "$C77A" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(batch_accounts)" = "A " ] && pass "T77a one submit, on A" || fail "T77a (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T77b: a non-JSON roles.json is decision 525 too: the batch submits on A"
roles_fixture; roles_real_on; printf '{not json' > "$RC/roles.json"
C77B="$REPO/c77b"; new_corpus "$C77B"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77b --corpus-root "$C77B" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(batch_accounts)" = "A " ] && pass "T77b one submit, on A" || fail "T77b (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T77c: graphify mapped to C narrows the auto batch to C"
roles_fixture; roles_real_on; printf '{"version":1,"roles":{"graphify":["C"]}}' > "$RC/roles.json"
C77C="$REPO/c77c"; new_corpus "$C77C"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77c --corpus-root "$C77C" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 0 ] && [ "$(batch_accounts)" = "C " ] && pass "T77c one submit, on C" || fail "T77c (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T77d: graphify mapped to C and C credit-exhausted: exactly one submit, on C, none on A or B, rc 5"
roles_fixture; roles_real_on; printf '{"version":1,"roles":{"graphify":["C"]}}' > "$RC/roles.json"
C77D="$REPO/c77d"; new_corpus "$C77D"; batch_reset
out=$(ACCT=auto BATCH_STUB_EXHAUSTED=C GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77d --corpus-root "$C77D" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"submitting the batch failed (rc 5)"* ]] && [ "$(batch_accounts)" = "C " ] \
  && pass "T77d one submit, on C, the batch failed with rc 5"|| fail "T77d (rc=$rc) accounts '$(batch_accounts)': $out"

echo "T77e: a role mapped to a letter with no roster row refuses the batch, never widening to A or B"
roles_fixture; roles_real_on; printf '{"version":1,"roles":{"graphify":["C"]}}' > "$RC/roles.json"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); del d["accounts"]["C"]; json.dump(d, open(p,"w"))' "$RC/config.json"
C77E="$REPO/c77e"; new_corpus "$C77E"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77e --corpus-root "$C77E" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/batch.log" ] && [[ "$out" == *"no-role-account-configured"* ]] \
  && pass "T77e refused, nothing submitted" || fail "T77e (rc=$rc) log '$(cat "$WS/batch.log")': $out"

echo "T77f: RED control: the real role reader and fixture over a credit-state that ignores --only submits the C-mapped batch on A"
roles_fixture; roles_real_on; printf '{"version":1,"roles":{"graphify":["C"]}}' > "$RC/roles.json"
sed 's/!only?.length || only.includes(account)/true/' "$REAL_REPO/scripts/lib/api-credit-state.mjs" > "$REPO/scripts/lib/api-credit-state.mjs"
cmp -s "$REAL_REPO/scripts/lib/api-credit-state.mjs" "$REPO/scripts/lib/api-credit-state.mjs" && fail "T77f the control copy still filters by --only"
C77F="$REPO/c77f"; new_corpus "$C77F"; batch_reset
out=$(ACCT=auto GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t77f --corpus-root "$C77F" --corpus-class himmel-code --backend claude-api); rc=$?
[ "$(batch_accounts)" = "A " ] && pass "T77f without the --only filter the batch submits on A, so T77c is a real check" || fail "T77f accounts '$(batch_accounts)' (rc=$rc): $out"
roles_real_off

echo "T78: a .graphifyignore naming a planned file strands nothing: the planner is the only selector"
C78="$WS/c78"; new_corpus "$C78"; printf 'b.md\n' > "$C78/.graphifyignore"
out=$(run --name t78 --corpus-root "$C78" --corpus-class himmel-code); rc=$?
python3 -c 'import json,sys;sys.exit("b.md" not in json.load(open(sys.argv[1]))["files"])' "$C78/graphify-out/semantic-manifest.json"; stamped=$?
[ "$rc" -eq 0 ] && [ "$(lastrun "$C78" failed)" = 0 ] && [ "$stamped" -eq 0 ] && [[ "$(ids "$C78")" == *sem_b.md_beta* ]] \
  && pass "T78 failed=0, b.md has nodes and is stamped despite .graphifyignore" || fail "T78 (rc=$rc) failed=$(lastrun "$C78" failed) stamped_rc=$stamped: $out"

echo "T79: a directory the repo's .graphifyignore lists is not corpus (graphify never extracts it, so it would fail every run)"
C79D="$WS/c79d"; new_corpus "$C79D"; mkdir -p "$C79D/archive/voice/docs"; printf 'voice\n' > "$C79D/archive/voice/docs/voice.md"
printf '# Voice is archived until it returns for Linux/macOS.\narchive/voice/\n' > "$C79D/.graphifyignore"
out=$(run --name t79d --corpus-root "$C79D" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C79D/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md b.md sub/c.md" ] && pass "T79 archive/voice/docs/voice.md left out of the corpus" || fail "T79 (rc=$rc) '$n': $out"

echo "T80: a .graphifyignore with a negation line keeps its directory entries in the corpus (a re-included file must not be dropped)"
C80="$WS/c80"; new_corpus "$C80"; mkdir -p "$C80/archive"; printf 'keep\n' > "$C80/archive/keep.md"
printf 'archive/\n!archive/keep.md\n' > "$C80/.graphifyignore"
out=$(run --name t80 --corpus-root "$C80" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C80/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md archive/keep.md b.md sub/c.md" ] && pass "T80 archive/keep.md stays in the corpus" || fail "T80 (rc=$rc) '$n': $out"

echo "T81: a thin extraction of unchanged content that the shrink guard refused MAX_ATTEMPTS times is accepted, not stuck forever"
C79="$WS/c79"; new_corpus "$C79"
python3 - "$C79/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
for i in (2, 3, 4):
    g["nodes"].append({"id": "stale_a%d" % i, "label": "old", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"})
json.dump(g, open(sys.argv[1], "w"))
PY
for i in 1 2; do
  out=$(run --name t79 --corpus-root "$C79" --corpus-class himmel-code); rc=$?
  [ "$rc" -eq 0 ] && [[ "$(ids "$C79")" == *stale_a4* ]] && ! [[ "$(ids "$C79")" == *sem_a.md_alpha* ]] \
    && pass "T81 attempt $i: shrink guard refuses, the old nodes stay" || fail "T81 attempt $i (rc=$rc): $(ids "$C79") :: $out"
done
out=$(run --name t79 --corpus-root "$C79" --corpus-class himmel-code); rc=$?
got=$(ids "$C79")
[ "$rc" -eq 0 ] && [[ "$got" == *sem_a.md_alpha* ]] && ! [[ "$got" == *stale_a4* ]] \
  && pass "T81 attempt 3: the thin extraction replaces the old nodes" || fail "T81 attempt 3 (rc=$rc): $got :: $out"
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));sys.exit(0 if "a.md" in m["files"] and "a.md" not in m.get("stuck", {}) else 1)' "$C79/graphify-out/semantic-manifest.json" \
  && pass "T81 a.md is stamped and no longer stuck" || fail "T81 manifest: $(cat "$C79/graphify-out/semantic-manifest.json")"

echo "T82: two omitted extractions are not shrink refusals, so a thin extraction after them is still refused"
C81="$WS/c81"; new_corpus "$C81"
python3 - "$C81/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
for i in (2, 3, 4):
    g["nodes"].append({"id": "stale_a%d" % i, "label": "old", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"})
json.dump(g, open(sys.argv[1], "w"))
PY
for i in 1 2; do GRAPHIFY_STUB_SKIP=a.md run --name t81 --corpus-root "$C81" --corpus-class himmel-code >/dev/null; done
python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["stuck"]["a.md"];sys.exit(0 if r["attempts"]==2 and r["reason"].startswith("not extracted") else 1)' "$C81/graphify-out/semantic-manifest.json" \
  && pass "T82 setup: two omitted runs recorded two not-extracted attempts" || fail "T82 setup: $(cat "$C81/graphify-out/semantic-manifest.json")"
out=$(run --name t81 --corpus-root "$C81" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [[ "$(ids "$C81")" == *stale_a4* ]] && ! [[ "$(ids "$C81")" == *sem_a.md_alpha* ]] \
  && pass "T82 the thin extraction is refused: no shrink refusal came before it" || fail "T82 (rc=$rc): $(ids "$C81") :: $out"

echo "T83: graphify's own export (60-Maps/graph/) is never planned or stamped; a hand-authored 60-Maps note still is"
C83="$WS/c83"; new_corpus "$C83"; mkdir -p "$C83/60-Maps/graph"
printf 'derived\n' > "$C83/60-Maps/graph/Skills.md"; printf 'derived\n' > "$C83/60-Maps/graph/Skills1.md"; printf 'hand\n' > "$C83/60-Maps/hand.md"
out=$(run --name t83 --corpus-root "$C83" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C83/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "60-Maps/hand.md a.md b.md sub/c.md" ] && pass "T83 export dir excluded, hand.md kept" || fail "T83 (rc=$rc) '$n': $out"

echo "T84: a '# Moved' pointer stub is never planned (the model omits it, so it backed off and stayed stuck); its old nodes go with it"
C84="$WS/c84"; new_corpus "$C84"
printf '# Moved: AFK mode\n\nThis page moved to [afk-mode.md](afk-mode.md).\n' > "$C84/moved.md"
printf '# Moved on\n\nA real page that merely starts with the word.\n' > "$C84/real.md"
out=$(run --name t84 --corpus-root "$C84" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C84/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md b.md real.md sub/c.md" ] && pass "T84 the stub is out of the corpus, a page that merely starts with 'Moved' stays" || fail "T84 (rc=$rc) '$n': $out"
python3 - "$C84/graphify-out" <<'PY'
import json, os, sys
out = sys.argv[1]
g = json.load(open(os.path.join(out, "graph.json")))
g["nodes"].append({"id": "stale_moved", "label": "old", "file_type": "concept", "_origin": "semantic", "source_file": "moved.md"})
json.dump(g, open(os.path.join(out, "graph.json"), "w"))
m = json.load(open(os.path.join(out, "semantic-manifest.json")))
m["files"]["moved.md"] = "0" * 64
json.dump(m, open(os.path.join(out, "semantic-manifest.json"), "w"))
PY
[[ " $(ids "$C84") " == *" stale_moved "* ]] \
  && python3 -c 'import json,sys;sys.exit(0 if "moved.md" in json.load(open(sys.argv[1]))["files"] else 1)' "$C84/graphify-out/semantic-manifest.json" \
  && pass "T84 setup: the stale node and the stale manifest hash were injected" || fail "T84 setup: the stale-state injection did not land: $(ids "$C84")"
out=$(GRAPHIFY_STUB_SKIP=moved.md run --name t84 --corpus-root "$C84" --corpus-class himmel-code); rc=$?
got=$(ids "$C84")
[ "$rc" -eq 0 ] && [[ " $got " == *" code_a "* ]] && ! [[ " $got " == *" stale_moved "* ]] \
  && pass "T84 the stub's old nodes are dropped" || fail "T84 the stub's old nodes (rc=$rc) '$got': $out"
python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));sys.exit(0 if "moved.md" not in m["files"] and "moved.md" not in m.get("stuck", {}) else 1)' "$C84/graphify-out/semantic-manifest.json" \
  && pass "T84 the stub is neither stamped nor stuck" || fail "T84 manifest: $(cat "$C84/graphify-out/semantic-manifest.json")"
[ "$(lastrun "$C84" backed_off)" = 0 ] && [ "$(lastrun "$C84" failed)" = 0 ] && pass "T84 the run row carries no failed or backed-off file" || fail "T84 run row: $(tail -1 "$C84/graphify-out/semantic-runs.jsonl")"

echo "T85: a batch run caps its chunk at 15000 tokens, so a batch answer fits max_tokens and graphify never splits into a prompt the batch lacks"
C85="$WS/c85"; new_corpus "$C85"; batch_reset
out=$(GRAPHIFY_STUB_CALL_CLAUDE=1 run_batch --name t85 --corpus-root "$C85" --corpus-class himmel-code --backend claude-api); rc=$?
case "$rc:$(grep '^graphify extract' "$WS/calls.log")" in
  0:*"--token-budget 15000"*) pass "T85 default 1.00 in batch mode -> 15000" ;;
  *) fail "T85 (rc=$rc) '$(grep '^graphify extract' "$WS/calls.log")': $out" ;;
esac

echo "T86: templates, testdata, evals, -fixtures and VENDORED.md dirs are never planned or stamped; a content file beside them still is"
C86="$WS/c86"; new_corpus "$C86"
mkdir -p "$C86/plugins/p/templates" "$C86/.github/ISSUE_TEMPLATE" "$C86/_Templates" "$C86/scripts/testdata" "$C86/plugins/p/evals/case" "$C86/scripts/ci/x-fixtures" "$C86/vend/skills/s" "$C86/docs"
for f in plugins/p/templates/t.md .github/ISSUE_TEMPLATE/bug.md _Templates/n.md scripts/testdata/d.md plugins/p/evals/case/g.md scripts/ci/x-fixtures/f.md vend/skills/s/SKILL.md vend/VENDORED.md; do printf 'x\n' > "$C86/$f"; done
printf 'real\n' > "$C86/docs/real.md"
out=$(run --name t86 --corpus-root "$C86" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C86/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md b.md docs/real.md sub/c.md" ] && pass "T86 only the content files are stamped" || fail "T86 (rc=$rc) '$n': $out"
printf 'real2\n' > "$C86/docs/real.md"; printf 'y\n' > "$C86/plugins/p/templates/t.md"
out=$(python3 "$HERE/semantic-merge.py" status --root "$C86" --out "$C86/graphify-out" 2>&1)
[ "$out" = "backed_off=0 unstamped=1 oldest_unstamped=0d" ] && pass "T86 an edited template is not unstamped, an edited content file is" || fail "T86 status: $out"

echo
[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
