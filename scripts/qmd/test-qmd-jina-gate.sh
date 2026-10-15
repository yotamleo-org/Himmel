#!/usr/bin/env bash
# test-qmd-jina-gate.sh - a qmd index that holds a collection whose
# corpus the egress matrix denies for Jina (salus first; any unmapped collection
# too) must never run a remote Jina model. Covers the gate itself
# (scripts/qmd/qmd-jina-gate.mjs) and the daemon launcher that calls it
# (marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh).
# Hermetic: temp HOME, mock qmd binary and mock curl; nothing leaves the box.
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="$repo_root/scripts/qmd/qmd-jina-gate.mjs"
ensure="$repo_root/marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh" # t13b-ok: path of the ensure script under test
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/qmd-jina-gate.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

JINA_EMBED='openai:jina-embeddings-v3'
JINA_RERANK='openai:jina-reranker-v2-base-multilingual'
LOCAL_EMBED='hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf'

# cfg <file> <embed> <rerank> <base-url|-> <collection>...
cfg() {
  local f="$1" embed="$2" rerank="$3" base="$4"; shift 4
  {
    echo "collections:"
    local c
    for c in "$@"; do printf '  %s:\n    path: /nonexistent/%s\n    pattern: "**/*.md"\n' "$c" "$c"; done
    echo "models:"
    echo "  embed: $embed"
    echo "  rerank: $rerank"
    if [ "$base" != "-" ]; then echo "  openai_base_url: $base"; fi
  } > "$f"
}

run_gate() { env -u QMD_EMBED_MODEL -u QMD_RERANK_MODEL -u QMD_GENERATE_MODEL -u QMD_OPENAI_BASE_URL node "$gate" "$@" 2>"$work/err"; }

# (1) salus + himmel in ONE index with a Jina embed model: refused, salus named.
cfg "$work/a.yml" "$JINA_EMBED" "$LOCAL_EMBED" https://api.jina.ai/v1 himmel luna salus
run_gate "$work/a.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(1) salus in a Jina-embed index: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(1) the refusal must name salus: $(cat "$work/err")"

# (2) Jina rerank only is just as refused.
cfg "$work/b.yml" "$LOCAL_EMBED" "$JINA_RERANK" https://api.jina.ai/v1 himmel salus
run_gate "$work/b.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(2) salus in a Jina-rerank index: expected rc 3, got $rc"

# (3) every other collection on Jina is allowed.
cfg "$work/c.yml" "$JINA_EMBED" "$JINA_RERANK" https://api.jina.ai/v1 \
  himmel luna ggs-local ggs-bridge agent-command-chain station-ops nvidia-steam-shader-cache jira-himmel roadmap-plan skills
run_gate "$work/c.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) the non-salus index on Jina: expected rc 0, got $rc: $(cat "$work/err")"

# (4) a salus-only index on local models is allowed.
cfg "$work/d.yml" "$LOCAL_EMBED" "hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf" - salus
run_gate "$work/d.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) local salus index: expected rc 0, got $rc: $(cat "$work/err")"

# (5) a collection with no corpus mapping is denied (fail closed).
cfg "$work/e.yml" "$JINA_EMBED" "$LOCAL_EMBED" https://api.jina.ai/v1 himmel mystery-collection
run_gate "$work/e.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(5) unmapped collection on Jina: expected rc 3, got $rc"
grep -q 'mystery-collection' "$work/err" || fail "(5) the refusal must name the unmapped collection"

# (6) the model can come from the environment, not only the file.
cfg "$work/f.yml" "$LOCAL_EMBED" "$LOCAL_EMBED" - salus
QMD_EMBED_MODEL="$JINA_EMBED" QMD_OPENAI_BASE_URL=https://api.jina.ai/v1 node "$gate" "$work/f.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(6) QMD_EMBED_MODEL=openai:jina on a salus index: expected rc 3, got $rc"

# (7) a loopback OpenAI-compatible server (local llama-server) is not egress.
cfg "$work/g.yml" "openai:local-embed" "$LOCAL_EMBED" http://127.0.0.1:8080/v1 salus
run_gate "$work/g.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(7) loopback endpoint on salus: expected rc 0, got $rc: $(cat "$work/err")"

# (8) a remote openai: model with no endpoint named cannot be proven local: refused.
cfg "$work/h.yml" "$JINA_EMBED" "$LOCAL_EMBED" - himmel salus
run_gate "$work/h.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(8) openai: model with no base url on a salus index: expected rc 3, got $rc"

# (9) the generate role is inference on Jina, which no corpus has: refused even without salus.
cfg "$work/i.yml" "$LOCAL_EMBED" "$LOCAL_EMBED" https://api.jina.ai/v1 himmel
printf '  generate: openai:jina-something\n' >> "$work/i.yml"
run_gate "$work/i.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(9) Jina generate role: expected rc 3, got $rc"

# (10) unreadable config: usage error, not a pass.
run_gate "$work/does-not-exist.yml"; rc=$?
[ "$rc" -eq 2 ] || fail "(10) missing config: expected rc 2, got $rc"

# (10a) flow-style models, which the line reader cannot attribute, fail closed.
printf 'collections:\n  salus:\n    path: /x\nmodels: {embed: "openai:jina-embeddings-v3", openai_base_url: "https://api.jina.ai/v1"}\n' > "$work/j.yml"
run_gate "$work/j.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10a) flow-style models with salus: expected rc 3, got $rc"

# (10b) four-space indentation still lists salus (not silently empty).
printf 'collections:\n    himmel:\n        path: /x\n    salus:\n        path: /y\nmodels:\n    embed: openai:jina-embeddings-v3\n    openai_base_url: https://api.jina.ai/v1\n' > "$work/k.yml"
run_gate "$work/k.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10b) four-space indentation with salus: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(10b) the refusal must name salus"

# (10c) flow-style collections with a remote model fail closed too.
printf 'collections: {salus: {path: /x}}\nmodels:\n  embed: openai:jina-embeddings-v3\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/l.yml"
run_gate "$work/l.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10c) flow-style collections: expected rc 3, got $rc"

# (10d) a YAML-escaped openai URI is not recognised as local, so salus is refused.
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  embed: "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/m.yml"
run_gate "$work/m.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10d) escaped openai URI with salus: expected rc 3, got $rc"

# (10e) a quoted role key with an escaped URI is still read as a remote role, so salus is refused.
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  "embed": "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/n.yml"
run_gate "$work/n.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10e) quoted role key with escaped URI: expected rc 3, got $rc"

# (10f) an unparseable models entry is refused unconditionally.
printf 'collections:\n  luna:\n    path: /x\nmodels:\n  - embed: openai:jina-embeddings-v3\n' > "$work/o.yml"
run_gate "$work/o.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10f) unparsed models entry: expected rc 3, got $rc"

# (10g) a scheme-prefixed value ending in .gguf is not local.
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/p.yml"
QMD_EMBED_MODEL=openai:remote-model.gguf node "$gate" "$work/p.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(10g) openai:...gguf with salus: expected rc 3, got $rc"

# (10h) a non-https endpoint is never approved as the Jina provider.
printf 'collections:\n  luna:\n    path: /x\nmodels:\n  embed: openai:jina-embeddings-v3\n  openai_base_url: http://api.jina.ai/v1\n' > "$work/q.yml"
run_gate "$work/q.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10h) http endpoint: expected rc 3, got $rc"

# (10i) a quoted top-level "models" key hides the block from the line reader:
# refuse it even with an escaped model URI that carries no literal openai:.
printf 'collections:\n  salus:\n    path: /x\n"models":\n  embed: "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/qk.yml"
run_gate "$work/qk.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10i) quoted top-level models key with salus: expected rc 3, got $rc"

# (10j) a himmel-only index with a plain-http Jina endpoint is refused too.
printf 'collections:\n  himmel:\n    path: /x\nmodels:\n  embed: openai:jina-embeddings-v3\n  openai_base_url: http://api.jina.ai/v1\n' > "$work/qh.yml"
run_gate "$work/qh.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10j) http endpoint on a himmel-only index: expected rc 3, got $rc"

# (10k) flow-style models with an escaped URI (no literal openai:) hide the
# remote role from the line reader: refuse it for a salus index.
printf 'collections:\n  salus:\n    path: /x\nmodels: {embed: "openai\\x3ajina-embeddings-v3", openai_base_url: "https://api.jina.ai/v1"}\n' > "$work/fe.yml"
run_gate "$work/fe.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10k) flow-style models with an escaped URI and salus: expected rc 3, got $rc"

# ---- OpenRouter: host maps to provider openrouter, models pinned ----
OR_EMBED='openai:qwen/qwen3-embedding-8b'
OR_RERANK='openai:cohere/rerank-4-fast'
OR_BASE=https://openrouter.ai/api/v1

# (22) the non-salus index on the pinned OpenRouter models is allowed.
cfg "$work/or1.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" \
  himmel luna ggs-local ggs-bridge agent-command-chain station-ops nvidia-steam-shader-cache jira-himmel roadmap-plan skills
run_gate "$work/or1.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(22) non-salus index on pinned OpenRouter models: expected rc 0, got $rc: $(cat "$work/err")"

# (23) salus in an OpenRouter index is refused, whichever role is remote.
cfg "$work/or2.yml" "$OR_EMBED" "$LOCAL_EMBED" "$OR_BASE" himmel salus
run_gate "$work/or2.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(23) salus on OpenRouter embed: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(23) the refusal must name salus: $(cat "$work/err")"
cfg "$work/or3.yml" "$LOCAL_EMBED" "$OR_RERANK" "$OR_BASE" himmel salus
run_gate "$work/or3.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(23b) salus on OpenRouter rerank: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(23b) the refusal must name salus"

# (24) a model that is not the pinned one is refused on an allowed corpus.
cfg "$work/or4.yml" 'openai:openai/text-embedding-3-large' "$OR_RERANK" "$OR_BASE" himmel
run_gate "$work/or4.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(24) unpinned OpenRouter embed model: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(24) the refusal must say the model is not pinned: $(cat "$work/err")"
cfg "$work/or5.yml" "$OR_EMBED" 'openai:cohere/rerank-v3.5' "$OR_BASE" himmel
run_gate "$work/or5.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(24b) unpinned OpenRouter rerank model: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(24b) the refusal must say the model is not pinned: $(cat "$work/err")"

# (25) a pinned model name in the wrong role is not pinned for that role.
cfg "$work/or6.yml" "$OR_RERANK" "$OR_EMBED" "$OR_BASE" himmel
run_gate "$work/or6.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(25) swapped embed/rerank models: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(25) the refusal must say the model is not pinned: $(cat "$work/err")"

# (26) an unpinned model named only by the environment is refused too.
cfg "$work/or7.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
QMD_EMBED_MODEL='openai:openai/text-embedding-3-large' node "$gate" "$work/or7.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(26) unpinned env model over a pinned file: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(26) the refusal must say the model is not pinned: $(cat "$work/err")"

# (27) a lookalike host is not OpenRouter: it stays default-deny.
cfg "$work/or8.yml" "$OR_EMBED" "$OR_RERANK" https://openrouter.ai.evil.example/api/v1 himmel
run_gate "$work/or8.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(27) lookalike OpenRouter host: expected rc 3, got $rc"

# (28) the generate role is inference, which no corpus allows on openrouter for qmd.
cfg "$work/or9.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  generate: openai:qwen/qwen3-embedding-8b\n' >> "$work/or9.yml"
run_gate "$work/or9.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(28) OpenRouter generate role: expected rc 3, got $rc"

# (29) an active salus document in the database refuses an OpenRouter index.
sqlite3 "$work/db3.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('salus',1);"
cfg "$work/or10.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
run_gate "$work/or10.yml" "$work/db3.sqlite"; rc=$?
[ "$rc" -eq 3 ] || fail "(29) active salus doc under an OpenRouter index: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(29) the refusal must name salus"

# (30) a provider key in index.yml is refused: the key lives only in the launching shell's environment.
cfg "$work/or11.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  openai_api_key: sk-or-not-a-real-key\n' >> "$work/or11.yml"
run_gate "$work/or11.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(30) api key in index.yml: expected rc 3, got $rc"
grep -q 'api_key' "$work/err" || fail "(30) the refusal must name the key: $(cat "$work/err")"
if grep -q 'not-a-real-key' "$work/err"; then fail "(30) the refusal must not echo the key"; fi

# ---- the daemon launcher -------------------------------------------------
mkdir -p "$work/bun/bin" "$work/home" "$work/cfg" "$work/cache"
cat > "$work/bun/bin/qmd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/qmd-calls"
touch "$work/started"
exit 0
EOF
chmod +x "$work/bun/bin/qmd"
cat > "$work/curl" <<EOF
#!/usr/bin/env bash
if [ -f "$work/started" ]; then
  printf '%s' '{"result":{"serverInfo":{"name":"qmd","version":"1"}}}'
fi
exit 0
EOF
chmod +x "$work/curl"

launch() { # launch <index name|-> ; QMD_JINA_GATE inherited from the caller
  rm -f "$work/started" "$work/qmd-calls"
  local idx="${1:-index}"
  env -i PATH="$PATH" HOME="$work/home" BUN_INSTALL="$work/bun" QMD_CONFIG_DIR="$work/cfg" \
    XDG_CACHE_HOME="$work/cache" QMD_CURL="$work/curl" QMD_MCP_URL=http://localhost:1/mcp \
    QMD_INDEX_NAME="$idx" ${QMD_JINA_GATE:+QMD_JINA_GATE="$QMD_JINA_GATE"} \
    bash "$ensure" >"$work/out" 2>"$work/err"
}

# (11) launcher refuses to start a daemon on a salus + Jina index.
cp "$work/a.yml" "$work/cfg/index.yml"
launch index; rc=$?
[ "$rc" -eq 1 ] || fail "(11) launcher on salus+Jina: expected rc 1, got $rc: $(cat "$work/err")"
[ ! -e "$work/started" ] || fail "(11) launcher STARTED qmd despite the refusal"
grep -q 'salus' "$work/err" || fail "(11) the launcher refusal must name salus"

# (12) launcher starts normally on the non-salus Jina index.
cp "$work/c.yml" "$work/cfg/index.yml"
launch index; rc=$?
[ "$rc" -eq 0 ] || fail "(12) launcher on the non-salus Jina index: expected rc 0, got $rc: $(cat "$work/err")"
[ -e "$work/started" ] || fail "(12) launcher did not start qmd"

# (13) a local-only config never needs the gate (works outside a himmel checkout).
cp "$work/d.yml" "$work/cfg/index.yml"
QMD_JINA_GATE=/nonexistent/gate.mjs launch index; rc=$?
[ "$rc" -eq 0 ] || fail "(13) local config with no gate script: expected rc 0, got $rc: $(cat "$work/err")"

# (14) a remote model with the gate script missing fails closed.
cp "$work/c.yml" "$work/cfg/index.yml"
QMD_JINA_GATE=/nonexistent/gate.mjs launch index; rc=$?
[ "$rc" -eq 1 ] || fail "(14) Jina config with no gate script: expected rc 1, got $rc"
[ ! -e "$work/started" ] || fail "(14) launcher STARTED qmd with no gate to vet the config"

# (15) a named index reads its own <name>.yml and starts qmd with --index.
cp "$work/d.yml" "$work/cfg/salus.yml"
cp "$work/a.yml" "$work/cfg/index.yml"
launch salus; rc=$?
[ "$rc" -eq 0 ] || fail "(15) salus index launcher: expected rc 0, got $rc: $(cat "$work/err")"
grep -q -- '--index salus' "$work/qmd-calls" || fail "(15) qmd was not started with --index salus: $(cat "$work/qmd-calls")"

# (16) a named index whose own config holds salus + Jina is refused too.
cp "$work/a.yml" "$work/cfg/salus.yml"
launch salus; rc=$?
[ "$rc" -eq 1 ] || fail "(16) salus index with Jina: expected rc 1, got $rc"

# (17) the launcher detects a flow-style remote model and the gate refuses it.
cp "$work/j.yml" "$work/cfg/index.yml"
launch index; rc=$?
[ "$rc" -eq 1 ] || fail "(17) launcher on flow-style salus+Jina: expected rc 1, got $rc"
[ ! -e "$work/started" ] || fail "(17) launcher STARTED qmd on a flow-style salus+Jina config"

# (18) qmd reads the config first and the env only as a fallback: an env that
# names a local model must not hide a Jina model written in the file.
env -u QMD_OPENAI_BASE_URL QMD_EMBED_MODEL="$LOCAL_EMBED" QMD_RERANK_MODEL="$LOCAL_EMBED" node "$gate" "$work/a.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(18) local env over a salus+Jina file: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(18) the refusal must name salus"
cfg "$work/k.yml" "$JINA_EMBED" "$LOCAL_EMBED" https://api.jina.ai/v1 himmel
env QMD_OPENAI_BASE_URL=http://localhost:9/v1 node "$gate" "$work/k.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 0 ] || fail "(18b) a clean Jina file must not be refused by an env base url: rc $rc"
cfg "$work/k2.yml" "$JINA_EMBED" "$LOCAL_EMBED" https://api.jina.ai/v1 salus
env QMD_OPENAI_BASE_URL=http://localhost:9/v1 node "$gate" "$work/k2.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(18c) a salus file naming Jina must not be rescued by a loopback env base url: expected rc 3, got $rc"

# (19) the index database is checked too: an active salus document in the DB
# refuses a Jina model even when the config no longer lists salus.
command -v sqlite3 >/dev/null 2>&1 || fail "(19) sqlite3 is required for this suite"
sqlite3 "$work/db.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('salus',1);"
run_gate "$work/k.yml" "$work/db.sqlite"; rc=$?
[ "$rc" -eq 3 ] || fail "(19) active salus document in the DB: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(19) the refusal must name salus"
sqlite3 "$work/db2.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('salus',0);"
run_gate "$work/k.yml" "$work/db2.sqlite"; rc=$?
[ "$rc" -eq 0 ] || fail "(19b) inactive salus document must not refuse: rc $rc: $(cat "$work/err")"

# (20) a database that cannot be read fails closed; a missing file means no documents.
printf 'not a database' > "$work/bad.sqlite"
run_gate "$work/k.yml" "$work/bad.sqlite"; rc=$?
[ "$rc" -eq 3 ] || fail "(20) unreadable DB: expected rc 3, got $rc"
run_gate "$work/k.yml" "$work/absent.sqlite"; rc=$?
[ "$rc" -eq 0 ] || fail "(20b) absent DB: expected rc 0, got $rc"

# (21) the launcher passes the index database to the gate: a Jina config that no
# longer lists salus is still refused while the database holds active salus docs.
mkdir -p "$work/cache/qmd"
sqlite3 "$work/cache/qmd/index.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('salus',1);"
cp "$work/c.yml" "$work/cfg/index.yml"
rm -f "$work/started"
launch index; rc=$?
[ "$rc" -eq 1 ] || fail "(21) Jina config over a DB with active salus docs: expected rc 1, got $rc"
[ ! -e "$work/started" ] || fail "(21) launcher STARTED qmd over a DB holding salus documents"
grep -q 'salus' "$work/err" || fail "(21) the launcher refusal must name salus"
rm -f "$work/cache/qmd/index.sqlite"

echo "PASS: test-qmd-jina-gate.sh (43 checks)"
