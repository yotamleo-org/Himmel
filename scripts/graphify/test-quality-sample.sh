#!/usr/bin/env bash
# test-quality-sample.sh — the REAL graphify and qmd on a 50-file sample.
#
# WHY: the stub suites prove each script's branches; none proves the output stays
# GOOD. A refresh that exits 0 on degraded output (batch 1 of 2026-10-16: 8 of 9 semantic
# chunks died, exit 0) passes every stub row. Here the real tools run on a copy of
# 50 tracked files (36 code, 14 docs) in a scratch dir — never a live vault, never
# a full index — and the suite asserts:
#   1. graph refresh keeps node and edge counts at 0.9 x baseline or better;
#   2. a known graph query returns a known file;
#   3. a failed semantic chunk exits non-zero (RED control: semantic-update.sh before its exit-5 fix exits 0);
#   4. qmd reindex keeps the indexed document count at 0.9 x the sample, and a
#      known lex query (scripts/lib/qmd-bounded.sh) returns the file it was planted in;
#   5. qmd update / embed failures and an incomplete embed exit 3 / 4 / 5.
# ponytail: `qmd embed` and `qmd cleanup` are stubbed (embed needs a model, remote or GPU); update, search, status and graphify run real, add an embed row when a CI model exists.
# Skips (exit 0) when graphify, qmd, python3 or git is missing; QS_REQUIRE_TOOLS=1 makes a missing tool exit 1 instead.
# RED replay: QS_SEMANTIC_UPDATE=<file> runs row S1 against that semantic-update.sh.
# Run: bash scripts/graphify/test-quality-sample.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

for tool in graphify qmd python3 git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not on PATH"; [ -z "${QS_REQUIRE_TOOLS:-}" ] && exit 0; echo "FAIL: $tool required (QS_REQUIRE_TOOLS)"; exit 1; }
done
REAL_QMD="$(command -v qmd)"

WS="$(mktemp -d "${TMPDIR:-/tmp}/test-quality-sample.XXXXXX")" || exit 1
trap 'rm -rf "$WS"' EXIT
C="$WS/corpus" BIN="$WS/bin"
mkdir -p "$C" "$BIN"

# --- the sample: 36 graphify scripts (the known-query target among them) + 14 docs
{ git -C "$REPO" ls-files scripts/graphify | grep -E '\.(sh|py)$' | head -36
  git -C "$REPO" ls-files docs/internals | grep '\.md$' | head -14; } > "$WS/list"
while IFS= read -r f; do
  mkdir -p "$C/$(dirname "$f")"; cp "$REPO/$f" "$C/$f"
done < "$WS/list"
NFILES=$(wc -l < "$WS/list" | tr -d ' ')
NDOCS=$(grep -c '\.md$' "$WS/list")
[ "$NFILES" -ge 40 ] && pass "sample holds $NFILES files ($NDOCS docs)" || fail "sample has only $NFILES files"
[ -f "$C/scripts/graphify/ast-update.sh" ] || fail "ast-update.sh missing from the sample"
MARK="zebrafishquartz7731"
DOCREL=$(grep '\.md$' "$WS/list" | head -1)
DOC="$C/$DOCREL"
printf '\nSample marker: %s\n' "$MARK" >> "$DOC"

nodes() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["nodes"]))' "$C/graphify-out/graph.json"; }
edges() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["links"]))' "$C/graphify-out/graph.json"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
# ge90 <now> <baseline>: now >= 0.9 x baseline, integer-exact; a non-numeric count is false
ge90() { isnum "${1:-}" && isnum "${2:-}" && [ $(( $1 * 10 )) -ge $(( $2 * 9 )) ]; }

echo "G1: first AST build on the sample sets the baseline"
bash "$HERE/ast-update.sh" "$C" >"$WS/g1.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "G1 ast-update exit 0" || fail "G1 ast-update exit $rc: $(tail -3 "$WS/g1.out")"
N0=$(nodes) E0=$(edges)
[ "$N0" -ge "$NFILES" ] && [ "$E0" -gt 0 ] && pass "G1 baseline $N0 nodes, $E0 edges" || fail "G1 degenerate baseline $N0 nodes, $E0 edges"

echo "G2: refresh after edits keeps >= 0.9 x baseline"
for f in ast-update.sh graph-cadence.sh semantic-update.sh; do [ -f "$C/scripts/graphify/$f" ] && printf '\n# edited by test\n' >> "$C/scripts/graphify/$f" || fail "G2 $f missing from the sample"; done
bash "$HERE/ast-update.sh" "$C" >"$WS/g2.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "G2 refresh exit 0" || fail "G2 refresh exit $rc"
N1=$(nodes) E1=$(edges)
ge90 "$N1" "$N0" && ge90 "$E1" "$E0" && pass "G2 $N1 nodes / $E1 edges vs baseline $N0 / $E0" || fail "G2 degraded: $N1 nodes / $E1 edges vs baseline $N0 / $E0"

echo "G3: a known query returns a known file"
GQ=$(cd "$C" && graphify query "_promote_lock_release" --graph "$C/graphify-out/graph.json" 2>&1)
case "$GQ" in *"src=scripts/graphify/ast-update.sh"*) pass "G3 query hit scripts/graphify/ast-update.sh" ;; *) fail "G3 no ast-update.sh in the answer: $(printf '%s' "$GQ" | head -3)" ;; esac

echo "G4: the count check bites (control): dropping 24 of 36 scripts reads below 0.9"
grep '\.\(sh\|py\)$' "$WS/list" | sed -n '13,36p' | while IFS= read -r f; do rm -f "${C:?}/$f"; done
bash "$HERE/ast-update.sh" "$C" >"$WS/g4.out" 2>&1; rc=$?
N2=$(nodes)
if [ "$rc" -ne 0 ] || ! isnum "$N2"; then fail "G4 rebuild unusable (exit $rc, nodes '$N2')"
elif ge90 "$N2" "$N0"; then fail "G4 control did not trip: $N2 vs $N0"
else pass "G4 control tripped ($N2 vs baseline $N0)"; fi

echo "S1: a failed semantic chunk exits non-zero after the good chunks merge"
# graphify shim: `extract` prints the two lines graphify printed in the 2026-10-16 batch-1 incident
# (8 of 9 chunks died, exit 0) and writes one node per doc; every other verb is the real graphify.
REAL_GRAPHIFY="$(command -v graphify)"
cat > "$BIN/graphify" <<EOF
#!/usr/bin/env bash
if [ "\$1" != extract ]; then exec "$REAL_GRAPHIFY" "\$@"; fi
echo '[graphify] chunk 1/9 failed: claude -p exited 1: bank-preflight: FLEET native=21 claudex=0 openrouter=0 reserved=0 total=21/31'
echo '[graphify] WARNING: 8/9 semantic chunk(s) failed — see errors above. Partial results returned.'
python3 - "\$2" <<'PY'
import json, os, sys
root = sys.argv[1]
nodes = []
for dp, dn, fn in os.walk(root):
    if "graphify-out" in dp:
        continue
    for f in fn:
        if f.endswith(".md"):
            rel = os.path.relpath(os.path.join(dp, f), root)
            nodes.append({"id": "sem_" + rel.replace("/", "_"), "label": f, "file_type": "concept", "_origin": "semantic", "source_file": rel})
os.makedirs(os.path.join(root, "graphify-out", "cache", "semantic"), exist_ok=True)
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": [], "hyperedges": []},
          open(os.path.join(root, "graphify-out", "graph.json"), "w"))
PY
echo "[graphify extract] tokens: 1 in / 1 out, est. cost (~claude-cli): \$0.0000"
EOF
chmod +x "$BIN/graphify"
# restore the 24 scripts dropped in G4 and rebuild so S1 starts from the full baseline
while IFS= read -r f; do [ -f "$C/$f" ] || { mkdir -p "$C/$(dirname "$f")"; cp "$REPO/$f" "$C/$f"; }; done < "$WS/list"
bash "$HERE/ast-update.sh" "$C" >/dev/null 2>&1; rc=$?
N3=$(nodes)
[ "$rc" -eq 0 ] && ge90 "$N3" "$N0" && pass "S1 pre-run rebuild restored $N3 nodes" || fail "S1 pre-run rebuild exit $rc, nodes '$N3' vs baseline $N0"
SCRIPT="$HERE/semantic-update.sh"
if [ -n "${QS_SEMANTIC_UPDATE:-}" ]; then
  mkdir -p "$WS/old/scripts"
  for d in "$REPO"/scripts/*/; do ln -s "${d%/}" "$WS/old/scripts/$(basename "$d")"; done
  rm "$WS/old/scripts/graphify"; mkdir "$WS/old/scripts/graphify"
  cp "$HERE"/semantic-merge.py "$HERE"/harden-graph.py "$HERE"/harden-allowlist.json "$WS/old/scripts/graphify/"
  cp "$QS_SEMANTIC_UPDATE" "$WS/old/scripts/graphify/semantic-update.sh"
  SCRIPT="$WS/old/scripts/graphify/semantic-update.sh"
fi
mkdir -p "$WS/tmp"
env -u GRAPHIFY_OUT -u OLLAMA_HOST -u OLLAMA_BASE_URL -u OLLAMA_MODEL -u OLLAMA_API_KEY \
  PATH="$BIN:$PATH" TMPDIR="$WS/tmp" GRAPHIFY_SEMANTIC_LOCK_WAIT=0 \
  bash "$SCRIPT" --name qs --corpus-root "$C" --corpus-class himmel-code --backend ollama >"$WS/s1.out" 2>&1; rc=$?
[ "$rc" -eq 5 ] && pass "S1 failed chunks exit 5" || fail "S1 failed chunks exited $rc, want 5 (old behaviour: exit 0): $(tail -3 "$WS/s1.out")"
N4=$(nodes)
ge90 "$N4" "$N3" && pass "S1 good chunks merged, $N4 nodes vs $N3 before" || fail "S1 graph degraded: $N4 vs $N3"
python3 -c 'import json,sys;sys.exit(0 if any(n["id"].startswith("sem_") for n in json.load(open(sys.argv[1]))["nodes"]) else 1)' "$C/graphify-out/graph.json" && pass "S1 a semantic node from the good chunks survived" || fail "S1 no sem_ node in the merged graph"

echo "Q1: qmd reindex on the sample docs keeps the document count and finds the planted marker"
QD="$WS/qmd" ; mkdir -p "$QD/cfg/qmd" "$QD/cache"
export INDEX_PATH="$QD/index.sqlite" QMD_INDEX_PATH="$QD/index.sqlite" QMD_REFRESH_STAMP="$QD/refresh-stamp" \
  XDG_CONFIG_HOME="$QD/cfg" XDG_CACHE_HOME="$QD/cache" QMD_CONFIG_DIR="$QD/cfg/qmd" QMD_TIMEOUT_SECS=60
unset QMD_EMBED_MODEL QMD_RERANK_MODEL QMD_GENERATE_MODEL
# qmd shim: update/search/status/collection run the real qmd; embed and cleanup are stubbed.
cat > "$BIN/qmd-shim" <<EOF
#!/usr/bin/env bash
case "\$1" in
  embed)
    case "\${QS_EMBED:-ok}" in
      ok) echo "✓ All content hashes already have embeddings" ;;
      pending) echo "Embedded 3 chunks" ;;
      fail) echo "embed model unavailable" >&2; exit 1 ;;
    esac ;;
  cleanup) exit 0 ;;
  update) [ -z "\${QS_UPDATE_FAIL:-}" ] || { echo "update failed" >&2; exit 1; }; exec "$REAL_QMD" "\$@" ;;
  *) exec "$REAL_QMD" "\$@" ;;
esac
EOF
chmod +x "$BIN/qmd-shim"
"$REAL_QMD" collection add "$C/docs" --name sample >/dev/null 2>&1 || fail "Q1 collection add"
reindex() { bash "$REPO/scripts/luna/qmd-reindex.sh" --qmd-bin "$BIN/qmd-shim" 2>&1; }
indexed() { "$REAL_QMD" status 2>/dev/null | sed -n 's/^ *Total: *\([0-9]*\) files indexed.*/\1/p' | head -1; }
out=$(reindex); rc=$?
[ "$rc" -eq 0 ] && pass "Q1 reindex exit 0" || fail "Q1 reindex exit $rc: $(printf '%s' "$out" | tail -3)"
[ -f "$QMD_REFRESH_STAMP" ] && pass "Q1 refresh stamp written" || fail "Q1 no refresh stamp"
D0=$(indexed)
ge90 "${D0:-0}" "$NDOCS" && pass "Q1 $D0 docs indexed of $NDOCS" || fail "Q1 indexed ${D0:-none} of $NDOCS"
hit=$(bash "$REPO/scripts/lib/qmd-bounded.sh" search -c sample "$MARK" 2>&1)
case "$hit" in *"qmd://sample/${DOCREL#docs/}"*) pass "Q1 marker query returns $(basename "$DOC")" ;; *) fail "Q1 marker not found: $(printf '%s' "$hit" | head -3)" ;; esac

echo "Q2: refresh after edits keeps the count"
printf '\nedited\n' >> "$C/$(grep '\.md$' "$WS/list" | sed -n 2p)"
out=$(reindex); rc=$?
D1=$(indexed)
[ "$rc" -eq 0 ] && ge90 "${D1:-0}" "${D0:-1}" && pass "Q2 exit 0, $D1 docs vs $D0" || fail "Q2 rc=$rc, $D1 docs vs $D0"

echo "Q3: injected failures exit non-zero and leave no stamp"
rm -f "$QMD_REFRESH_STAMP"
out=$(QS_EMBED=pending reindex); rc=$?
[ "$rc" -eq 5 ] && pass "Q3 incomplete embed exit 5" || fail "Q3 incomplete embed exit $rc, want 5"
[ ! -e "$QMD_REFRESH_STAMP" ] && pass "Q3 no stamp after the incomplete embed" || fail "Q3 stamp written after the incomplete embed"
out=$(QS_EMBED=fail reindex); rc=$?
[ "$rc" -eq 4 ] && pass "Q3 embed failure exit 4" || fail "Q3 embed failure exit $rc, want 4"
[ ! -e "$QMD_REFRESH_STAMP" ] && pass "Q3 no stamp after the embed failure" || fail "Q3 stamp written after the embed failure"
out=$(QS_UPDATE_FAIL=1 reindex); rc=$?
[ "$rc" -eq 3 ] && pass "Q3 update failure exit 3" || fail "Q3 update failure exit $rc, want 3"
[ ! -e "$QMD_REFRESH_STAMP" ] && pass "Q3 no stamp after the update failure" || fail "Q3 stamp written after the update failure"

echo
if [ "$FAILS" -eq 0 ]; then echo "test-quality-sample: all passed"; else echo "test-quality-sample: $FAILS FAILED"; exit 1; fi
