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

run_gate() { node "$gate" "$1" 2>"$work/err"; }

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

echo "PASS: test-qmd-jina-gate.sh (16 checks)"
