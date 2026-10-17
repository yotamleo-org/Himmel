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

# (10l) qmd's own saveConfig can write `models: null`; an empty `models: {}` is the same empty block. Both pass over a salus-free config.
for empty in 'null' '{}' 'null # none'; do
  printf 'collections:\n  himmel:\n    path: /x\nmodels: %s\n' "$empty" > "$work/em.yml"
  run_gate "$work/em.yml"; rc=$?
  [ "$rc" -eq 0 ] || fail "(10l) models: $empty over a salus-free config: expected rc 0, got $rc: $(cat "$work/err")"
done
# (10l) negative controls: any other inline models value is still refused, and a plain remote block still is.
for inl in '{embed: openai:jina-embeddings-v3}' 'nullx' '[]'; do
  printf 'collections:\n  himmel:\n    path: /x\nmodels: %s\n' "$inl" > "$work/em.yml"
  run_gate "$work/em.yml"; rc=$?
  [ "$rc" -eq 3 ] || fail "(10l) models: $inl must stay refused: expected rc 3, got $rc"
done
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  embed: openai:jina-embeddings-v3\n  openai_base_url: https://api.jina.ai/v1\n' > "$work/em.yml"
run_gate "$work/em.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10l) plain remote models block with salus: expected rc 3, got $rc"
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  embed: %s\n  rerank: %s\n' "$LOCAL_EMBED" "$LOCAL_EMBED" > "$work/em.yml"
run_gate "$work/em.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(10l) local hf: models with salus: expected rc 0, got $rc: $(cat "$work/err")"
printf 'collections:\n  salus:\n    path: /x\nmodels:\n  embed: /m/e.gguf\n  rerank: /m/r.gguf\n' > "$work/em.yml"
run_gate "$work/em.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(10l) local .gguf models with salus: expected rc 0, got $rc: $(cat "$work/err")"

# (10m) a quoted top-level key with a YAML escape hides the models block from the line reader: refuse it with its own message.
for key in '"mo\x64els"' '"\x6dodels"' "'mod\\x65ls'" '"coll\x65ctions"'; do
  printf 'collections:\n  salus:\n    path: /x\n%s:\n  embed: "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\n' "$key" > "$work/ek.yml"
  run_gate "$work/ek.yml"; rc=$?
  [ "$rc" -eq 3 ] || fail "(10m) escaped top-level key $key: expected rc 3, got $rc"
  grep -q 'escaped quoted top-level key' "$work/err" || fail "(10m) $key: the refusal must carry the escaped-key message: $(cat "$work/err")"
done
# (10m) a quoted key with an escape is refused even with no remote model anywhere.
printf 'collections:\n  himmel:\n    path: /x\n"mo\\x64els":\n  embed: %s\n' "$LOCAL_EMBED" > "$work/ek.yml"
run_gate "$work/ek.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10m) escaped key over local models: expected rc 3, got $rc"

# (10n) qmd's yaml parser reads these spellings as the models map; the line reader must refuse any top-level line it cannot recognise.
for key in 'models :' '? models' '&a models:' '!!str models:'; do
  printf 'collections:\n  himmel:\n    path: /x\n%s\n  embed: "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\n' "$key" > "$work/ak.yml"
  run_gate "$work/ak.yml"; rc=$?
  [ "$rc" -eq 3 ] || fail "(10n) top-level key '$key': expected rc 3, got $rc"
  grep -q 'unrecognised top-level key syntax' "$work/err" || fail "(10n) '$key': the refusal must carry the unrecognised-syntax message: $(cat "$work/err")"
done

# (10o) file-shape normalisation: CRLF endings, a leading BOM and an indented root mapping must not hide the models block.
printf 'collections:\r\n  himmel:\r\n    path: /x\r\nmodels: # c\r\n  embed: "openai\\x3ajina-embeddings-v3"\r\n  openai_base_url: https://api.jina.ai/v1\r\n' > "$work/sh.yml"
run_gate "$work/sh.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10o) CRLF models block with a trailing comment: expected rc 3, got $rc"
printf '\357\273\277models:\n  embed: "openai\\x3ajina-embeddings-v3"\n  openai_base_url: https://api.jina.ai/v1\ncollections:\n  himmel:\n    path: /x\n' > "$work/sh.yml"
run_gate "$work/sh.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10o) BOM before a models block: expected rc 3, got $rc"
printf '  collections:\n    himmel:\n      path: /x\n  models:\n    embed: "openai\\x3ajina-embeddings-v3"\n    openai_base_url: https://api.jina.ai/v1\n' > "$work/sh.yml"
run_gate "$work/sh.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(10o) indented root mapping: expected rc 3, got $rc"
# (10o) the literal openai: backstop also counts YAML colon escapes outside a role.
for esc in 'openai\x3ajina' 'openai:jina' 'openai\U0000003ajina'; do
  printf 'collections:\n  himmel:\n    path: /x\nextra:\n  x: "%s"\n' "$esc" > "$work/sh.yml"
  run_gate "$work/sh.yml"; rc=$?
  [ "$rc" -eq 3 ] || fail "(10o) escaped colon $esc outside a role: expected rc 3, got $rc"
done
# (10o) positive control: an ordinary config with comments, blank lines and CRLF still passes.
printf '# qmd config\r\n\r\ncollections:\r\n  himmel:\r\n    path: /x # note\r\n\r\nmodels:\r\n  embed: %s\r\n' "$LOCAL_EMBED" > "$work/sh.yml"
run_gate "$work/sh.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(10o) ordinary CRLF config with comments and blank lines: expected rc 0, got $rc: $(cat "$work/err")"

# ---- OpenRouter: host maps to provider openrouter, models pinned ----
OR_EMBED='openai:qwen/qwen3-embedding-8b'
OR_RERANK='openai:cohere/rerank-4-fast'
OR_GENERATE='openai:google/gemini-2.5-flash-lite'
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

# (28) a generate role on OpenRouter is allowed only as the pinned model.
cfg "$work/or9.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  generate: %s\n' "$OR_GENERATE" >> "$work/or9.yml"
run_gate "$work/or9.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(28) pinned OpenRouter generate model: expected rc 0, got $rc: $(cat "$work/err")"
cfg "$work/or9b.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  generate: openai:qwen/qwen3-embedding-8b\n' >> "$work/or9b.yml"
run_gate "$work/or9b.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(28b) unpinned OpenRouter generate model: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(28b) the refusal must say the model is not pinned: $(cat "$work/err")"
# (28c) an unpinned generate model named only by the environment is refused too.
QMD_GENERATE_MODEL='openai:openai/gpt-4o-mini' node "$gate" "$work/or9.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(28c) unpinned env generate model over a pinned file: expected rc 3, got $rc"
grep -q 'pinned' "$work/err" || fail "(28c) the refusal must say the model is not pinned: $(cat "$work/err")"
# (28d) the pinned generate model does not make a salus index pass: query text would reach OpenRouter.
cfg "$work/or9c.yml" "$LOCAL_EMBED" "$LOCAL_EMBED" "$OR_BASE" himmel salus
printf '  generate: %s\n' "$OR_GENERATE" >> "$work/or9c.yml"
run_gate "$work/or9c.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(28d) salus with a pinned OpenRouter generate model: expected rc 3, got $rc"
grep -q 'salus' "$work/err" || fail "(28d) the refusal must name salus: $(cat "$work/err")"
# (28e) a pinned-model name in the wrong role is not pinned for generate.
cfg "$work/or9d.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  generate: %s\n' "$OR_RERANK" >> "$work/or9d.yml"
run_gate "$work/or9d.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(28e) rerank model in the generate role: expected rc 3, got $rc"

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
# (30b) the same key in the flow form and with a space before the colon: refused, value never printed.
printf 'collections:\n  himmel:\n    path: /nonexistent/himmel\nmodels: {embed: %s, openai_base_url: %s, openai_api_key: sk-flow-secret-1}\n' "$OR_EMBED" "$OR_BASE" > "$work/or12.yml"
run_gate "$work/or12.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(30b) flow-form api key: expected rc 3, got $rc"
if grep -q 'sk-flow-secret-1' "$work/err"; then fail "(30b) the refusal echoed the flow-form key"; fi
cfg "$work/or13.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
printf '  "openai_api_key" : sk-spaced-secret-2\n' >> "$work/or13.yml"
run_gate "$work/or13.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(30c) spaced-colon api key: expected rc 3, got $rc"
if grep -q 'sk-spaced-secret-2' "$work/err"; then fail "(30c) the refusal echoed the spaced-colon key"; fi

# (31) a collection is PHI by PATH, not only by name: fixtures only, never the live salus index.
mkdir -p "$work/vault/salus/sub" "$work/vault/other" "$work/marked/sub" "$work/glm" "$work/qc" "$work/vault2/s"
printf '%s\n' "$work/vault/salus" > "$work/glm/phi-roots"
: > "$work/marked/.salus"
pcfg() { # <file> <collection> <path>
  printf 'collections:\n  %s:\n    path: %s\n    pattern: "**/*.md"\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$2" "$3" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" > "$1"
}
run_path() { env -u QMD_EMBED_MODEL -u QMD_RERANK_MODEL -u QMD_GENERATE_MODEL -u QMD_OPENAI_BASE_URL CLAUDE_GLM_CONFIG_DIR="$work/glm" QMD_CONFIG_DIR="$work/qc" node "$gate" "$@" 2>"$work/err"; }
pcfg "$work/p1.yml" himmel "$work/vault/salus"
run_path "$work/p1.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31a) himmel pointing at the salus root: expected rc 3, got $rc"
grep -q 'PHI root' "$work/err" || fail "(31a) the refusal must name the PHI root: $(cat "$work/err")"
pcfg "$work/p2.yml" luna "$work/vault"
run_path "$work/p2.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31b) luna pointing at a directory that contains the salus root: expected rc 3, got $rc"
pcfg "$work/p3.yml" himmel "$work/vault/salus/sub"
run_path "$work/p3.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31c) himmel pointing inside the salus root: expected rc 3, got $rc"
pcfg "$work/p4.yml" himmel "$work/vault/other"
run_path "$work/p4.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(31d) himmel on a path clear of every PHI root: expected rc 0, got $rc: $(cat "$work/err")"
pcfg "$work/p5.yml" himmel "$work/marked/sub"
run_path "$work/p5.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31e) himmel inside a .salus vault: expected rc 3, got $rc"
printf 'collections:\n  salus:\n    path: %s\n' "$work/vault2/s" > "$work/qc/salus.yml"
pcfg "$work/p6.yml" himmel "$work/vault2/s"
env CLAUDE_GLM_CONFIG_DIR="$work/none" QMD_CONFIG_DIR="$work/qc" node "$gate" "$work/p6.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(31f) himmel on the path the sibling salus config declares: expected rc 3, got $rc"
rm -f "$work/qc/salus.yml"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$work/glm/phi-roots"
  run_path "$work/p4.yml"; rc=$?
  chmod 600 "$work/glm/phi-roots"
  [ "$rc" -eq 3 ] || fail "(31g) an unreadable PHI root list must fail closed: expected rc 3, got $rc"
fi
printf 'collections:\n  himmel:\n    pattern: "**/*.md"\nmodels:\n  embed: %s\n  openai_base_url: %s\n' "$OR_EMBED" "$OR_BASE" > "$work/p7.yml"
run_path "$work/p7.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31h) a collection with no path cannot be checked: expected rc 3, got $rc"

ln -s "$work/marked" "$work/link-to-marked"
pcfg "$work/p8.yml" himmel "$work/link-to-marked/sub"
run_path "$work/p8.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(31i) himmel behind a symlink into a .salus vault: expected rc 3, got $rc"
mkdir -p "$work/sib2" "$work/vault3/s"
printf 'collections:\n  salus:\n    path: %s\n' "$work/vault3/s" > "$work/sib2/salus.yml"
pcfg "$work/sib2/p9.yml" himmel "$work/vault3/s"
env CLAUDE_GLM_CONFIG_DIR="$work/none" QMD_CONFIG_DIR="$work/none" node "$gate" "$work/sib2/p9.yml" 2>"$work/err"; rc=$?
[ "$rc" -eq 3 ] || fail "(31j) a salus config next to the checked config, outside QMD_CONFIG_DIR: expected rc 3, got $rc"
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$work/unreadable"
  chmod 000 "$work/unreadable"
  env CLAUDE_GLM_CONFIG_DIR="$work/none" QMD_CONFIG_DIR="$work/unreadable" node "$gate" "$work/p4.yml" 2>"$work/err"; rc=$?
  chmod 700 "$work/unreadable"
  [ "$rc" -eq 3 ] || fail "(31k) an unlistable sibling config directory must fail closed: expected rc 3, got $rc"
fi

# (32) a remote model with no base URL, or an unparseable one, cannot be proven pinned: refused.
cfg "$work/u1.yml" "openai:unpinned-model" "$LOCAL_EMBED" - himmel
run_gate "$work/u1.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(32a) remote model with no base URL: expected rc 3, got $rc"
cfg "$work/u2.yml" "openai:unpinned-model" "$LOCAL_EMBED" "not a url" himmel
run_gate "$work/u2.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(32b) remote model with an unparseable base URL: expected rc 3, got $rc"

# (33) a symlink whose LEXICAL parents carry no marker but whose target sits in a .salus
# vault is caught only by the realpath branch of the walk; (31i) cannot tell, its link parent resolves.
ln -s "$work/marked/sub" "$work/link-direct"
pcfg "$work/p10.yml" himmel "$work/link-direct"
run_path "$work/p10.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(33) a symlink straight onto a path inside a .salus vault: expected rc 3, got $rc"
grep -q '.salus vault' "$work/err" || fail "(33) the refusal must name the .salus vault: $(cat "$work/err")"

# (34) a .salus marker BELOW the collection path is PHI too (downward check).
mkdir -p "$work/above/deep/er/vault" "$work/clean/deep/er"
: > "$work/above/deep/er/vault/.salus"
pcfg "$work/p11.yml" luna "$work/above"
run_path "$work/p11.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(34a) a collection containing a .salus vault below it: expected rc 3, got $rc"
grep -q 'contains a .salus vault' "$work/err" || fail "(34a) the refusal must say the vault is below: $(cat "$work/err")"
pcfg "$work/p12.yml" luna "$work/clean"
run_path "$work/p12.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(34b) a clean tree must pass the downward check: rc $rc: $(cat "$work/err")"
if [ "$(id -u)" -ne 0 ]; then
  # (34d) a sub-directory the walk cannot read may hide a .salus vault: fail closed.
  mkdir -p "$work/locked-tree/sub/hidden"
  chmod 000 "$work/locked-tree/sub"
  pcfg "$work/p13.yml" luna "$work/locked-tree"
  run_path "$work/p13.yml"; rc=$?
  chmod 755 "$work/locked-tree/sub"
  [ "$rc" -eq 3 ] || fail "(34d) an unreadable sub-directory under a remote collection: expected rc 3, got $rc"
  # (34c) an unreadable claude-glm config dir cannot prove "no PHI roots": fail closed.
  mkdir -p "$work/glm-locked"
  chmod 000 "$work/glm-locked"
  CLAUDE_GLM_CONFIG_DIR="$work/glm-locked" QMD_CONFIG_DIR="$work/qc" node "$gate" "$work/p4.yml" 2>"$work/err"; rc=$?
  chmod 700 "$work/glm-locked"
  [ "$rc" -eq 3 ] || fail "(34c) an unreadable claude-glm config dir must fail closed: expected rc 3, got $rc"
  grep -q 'claude-glm' "$work/err" || fail "(34c) the refusal must name the config dir: $(cat "$work/err")"
fi

# (35) a collection that exists only in the database has no path to check: refused.
sqlite3 "$work/db4.sqlite" "CREATE TABLE documents(collection TEXT, active INTEGER); INSERT INTO documents VALUES('himmel',1),('skills',1);"
pcfg "$work/p13.yml" himmel "$work/vault/other"
run_path "$work/p13.yml" "$work/db4.sqlite"; rc=$?
[ "$rc" -eq 3 ] || fail "(35) a DB-only collection (no path to check): expected rc 3, got $rc"
grep -q 'skills' "$work/err" || fail "(35) the refusal must name the DB-only collection: $(cat "$work/err")"

# (36) refusals never print an unparsed collections line or a key in base URL userinfo.
printf 'collections:\n  himmel:\n    path: /nonexistent/himmel\n  - sk-line-secret-3\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$OR_EMBED" "$OR_RERANK" "$OR_BASE" > "$work/leak1.yml"
run_gate "$work/leak1.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(36a) an unparsed collections line: expected rc 3, got $rc"
if grep -q 'sk-line-secret-3' "$work/err"; then fail "(36a) the refusal printed the unparsed line"; fi
cfg "$work/leak2.yml" "$OR_EMBED" "$OR_RERANK" 'https://user:sk-url-secret-4@openrouter.ai/api/v1' himmel
run_gate "$work/leak2.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(36b) userinfo in the base URL: expected rc 3, got $rc"
if grep -q 'sk-url-secret-4' "$work/err"; then fail "(36b) the refusal printed the base URL userinfo"; fi
cfg "$work/leak3.yml" "$OR_EMBED" "$OR_RERANK" 'http://user:sk-url-secret-5@evil.example/v1' himmel
run_gate "$work/leak3.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(36c) insecure base URL with userinfo: expected rc 3, got $rc"
if grep -q 'sk-url-secret-5' "$work/err"; then fail "(36c) the insecure-endpoint refusal printed the userinfo"; fi
cfg "$work/leak4.yml" "$OR_EMBED" "$OR_RERANK" 'http://evil.example/sk-path-secret-7/v1' himmel
run_gate "$work/leak4.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(36d) insecure base URL with a secret in the path: expected rc 3, got $rc"
if grep -q 'sk-path-secret-7' "$work/err"; then fail "(36d) the insecure-endpoint refusal printed the URL path"; fi

# (37) an index that holds salus must pin explicit local models for every role.
printf 'collections:\n  salus:\n    path: /nonexistent/salus\n' > "$work/s1.yml"
run_gate "$work/s1.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(37a) a salus index with no models block: expected rc 3, got $rc"
grep -q 'explicit local' "$work/err" || fail "(37a) the refusal must ask for explicit local models: $(cat "$work/err")"
printf 'collections:\n  salus:\n    path: /nonexistent/salus\nmodels:\n  embed: %s\n' "$LOCAL_EMBED" > "$work/s2.yml"
run_gate "$work/s2.yml"; rc=$?
[ "$rc" -eq 3 ] || fail "(37b) a salus index missing the rerank model: expected rc 3, got $rc"
printf 'collections:\n  salus:\n    path: /nonexistent/salus\nmodels:\n  embed: %s\n  rerank: hf:x/y/z.gguf\n' "$LOCAL_EMBED" > "$work/s3.yml"
run_gate "$work/s3.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(37c) a salus index with explicit local embed and rerank: expected rc 0, got $rc: $(cat "$work/err")"

# (38) a non-loopback remote role needs the provider key in THIS process env when the
# caller asks (the launcher does); loopback needs none.
cfg "$work/k1.yml" "$OR_EMBED" "$OR_RERANK" "$OR_BASE" himmel
( unset QMD_OPENAI_API_KEY JINA_API_KEY JINA_API; QMD_GATE_REQUIRE_KEY=1 run_gate "$work/k1.yml" ); rc=$?
[ "$rc" -eq 3 ] || fail "(38a) remote role with no key in the env: expected rc 3, got $rc"
grep -q 'QMD_OPENAI_API_KEY' "$work/err" || fail "(38a) the refusal must name QMD_OPENAI_API_KEY: $(cat "$work/err")"
QMD_GATE_REQUIRE_KEY=1 QMD_OPENAI_API_KEY=sk-env-secret-6 run_gate "$work/k1.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(38b) remote role with the key in the env: expected rc 0, got $rc: $(cat "$work/err")"
if grep -q 'sk-env-secret-6' "$work/err"; then fail "(38b) the gate printed the key"; fi
cfg "$work/k3.yml" "openai:local-embed" "$LOCAL_EMBED" http://127.0.0.1:8080/v1 himmel
QMD_GATE_REQUIRE_KEY=1 run_gate "$work/k3.yml"; rc=$?
[ "$rc" -eq 0 ] || fail "(38c) a loopback endpoint needs no key: expected rc 0, got $rc: $(cat "$work/err")"

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
    QMD_DAEMON_ENV_FILE="$work/daemon0.env" QMD_INDEX_NAME="$idx" ${QMD_JINA_GATE:+QMD_JINA_GATE="$QMD_JINA_GATE"} \
    bash "$ensure" >"$work/out" 2>"$work/err"
}

# (11) launcher refuses to start a daemon on a salus + Jina index.
cp "$work/a.yml" "$work/cfg/index.yml"
launch index; rc=$?
[ "$rc" -eq 1 ] || fail "(11) launcher on salus+Jina: expected rc 1, got $rc: $(cat "$work/err")"
[ ! -e "$work/started" ] || fail "(11) launcher STARTED qmd despite the refusal"
grep -q 'salus' "$work/err" || fail "(11) the launcher refusal must name salus"

# (12) launcher starts normally on the non-salus Jina index (a remote daemon needs its key file).
printf 'QMD_OPENAI_API_KEY=sk-test-jina\n' > "$work/daemon0.env"; chmod 600 "$work/daemon0.env"
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

# ---- the provider key reaches ONLY a remote-model daemon, and only from the daemon env file ----
# the mock qmd records whether the key was in the environment it started with
cat > "$work/bun/bin/qmd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/qmd-calls"
printf 'key=%s\n' "\${QMD_OPENAI_API_KEY:+set}" >> "$work/qmd-env"
printf 'provider=%s\nbatch=%s\nconc=%s\nunlisted=%s\nqueue=%s\n' "\${QMD_OPENAI_PROVIDER-}" "\${QMD_OPENAI_EMBED_BATCH_SIZE-}" "\${QMD_OPENAI_EMBED_CONCURRENCY-}" "\${QMD_OPENAI_UNLISTED-}" "\${QMD_QUERY_MAX_QUEUED-}" >> "$work/qmd-env"
touch "$work/started"
exit 0
EOF
launch_key() { # launch_key <extra VAR=val>...
  rm -f "$work/started" "$work/qmd-calls" "$work/qmd-env"
  env -i PATH="$PATH" HOME="$work/home" BUN_INSTALL="$work/bun" QMD_CONFIG_DIR="$work/cfg" \
    XDG_CACHE_HOME="$work/cache" QMD_CURL="$work/curl" QMD_MCP_URL=http://localhost:1/mcp \
    QMD_DAEMON_ENV_FILE="$work/daemon.env" "$@" \
    bash "$ensure" >"$work/out" 2>"$work/err"
}
cp "$work/or1.yml" "$work/cfg/index.yml"

# (39) remote-model config, no key anywhere: refuse to start (the fork would send content unauthenticated).
rm -f "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 1 ] || fail "(39) remote config with no daemon key: expected rc 1, got $rc: $(cat "$work/err")"
[ ! -e "$work/started" ] || fail "(39) launcher STARTED a remote-model daemon with no key"

# (40) a key that is only in the SESSION env is not the daemon's key: refused, never forwarded.
launch_key QMD_OPENAI_API_KEY=sk-session-secret-7; rc=$?
[ "$rc" -eq 1 ] || fail "(40) key only in the session env: expected rc 1, got $rc"
[ ! -e "$work/started" ] || fail "(40) launcher started a daemon on a session-env key"
if grep -q 'sk-session-secret-7' "$work/err" "$work/out"; then fail "(40) the launcher printed the key"; fi

# (41) the key in the daemon env file reaches the daemon (and only it).
printf 'QMD_OPENAI_API_KEY=sk-file-secret-8\n' > "$work/daemon.env"; chmod 600 "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 0 ] || fail "(41) remote config with the daemon env file: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^key=set$' "$work/qmd-env" || fail "(41) the daemon did not get the key: $(cat "$work/qmd-env")"
if grep -q 'sk-file-secret-8' "$work/err" "$work/out" "$work/qmd-calls"; then fail "(41) the key leaked into argv or output"; fi

# (42) a group/world-readable env file is refused (the key must not sit in an open file).
chmod 644 "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 1 ] || fail "(42) a 0644 daemon env file: expected rc 1, got $rc"
[ ! -e "$work/started" ] || fail "(42) launcher used a world-readable key file"
chmod 600 "$work/daemon.env"

# (43) a LOCAL-only config never gets the key, whatever the session env or the file holds.
cp "$work/d.yml" "$work/cfg/index.yml"
launch_key QMD_OPENAI_API_KEY=sk-session-secret-9; rc=$?
[ "$rc" -eq 0 ] || fail "(43) local config: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^key=$' "$work/qmd-env" || fail "(43) a local daemon was handed a provider key: $(cat "$work/qmd-env")"

# (44) a mixed-case model prefix (OpenAI:, OPENAI:) still reaches the gate.
printf 'collections:\n  salus:\n    path: /nonexistent/salus\n    pattern: "**/*.md"\nmodels:\n  embed: OpenAI:qwen/qwen3-embedding-8b\n  rerank: %s\n  openai_base_url: %s\n' "$LOCAL_EMBED" "$OR_BASE" > "$work/cfg/index.yml"
launch_key; rc=$?
[ "$rc" -eq 1 ] || fail "(44) OpenAI: (mixed case) model on a salus index: expected rc 1, got $rc: $(cat "$work/err")"
[ ! -e "$work/started" ] || fail "(44) launcher STARTED qmd on a mixed-case remote salus config"
rm -f "$work/daemon.env"

# (45) a Jina key in the SESSION env (JINA_API_KEY / JINA_API) is not the daemon's key either.
cfg "$work/cfg/index.yml" "$JINA_EMBED" "$JINA_RERANK" https://api.jina.ai/v1 himmel
for jv in JINA_API_KEY JINA_API; do
  launch_key "$jv=jina-session-secret-10"; rc=$?
  [ "$rc" -eq 1 ] || fail "(45) $jv only in the session env: expected rc 1, got $rc: $(cat "$work/err")"
  [ ! -e "$work/started" ] || fail "(45) launcher started a Jina daemon on a session-env $jv"
done

# (48) the non-secret tuning names in the daemon env file reach the daemon; an unlisted name does not.
cp "$work/or1.yml" "$work/cfg/index.yml"
printf 'QMD_OPENAI_API_KEY=sk-file-secret-11\nQMD_OPENAI_PROVIDER=openrouter-fast_1.0\nQMD_OPENAI_EMBED_BATCH_SIZE=64\nQMD_OPENAI_EMBED_CONCURRENCY=8\nQMD_OPENAI_UNLISTED=leak\n' > "$work/daemon.env"; chmod 600 "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 0 ] || fail "(48) tuning env file: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^provider=openrouter-fast_1.0$' "$work/qmd-env" || fail "(48) PROVIDER did not reach the daemon: $(cat "$work/qmd-env")"
grep -q '^batch=64$' "$work/qmd-env" || fail "(48) EMBED_BATCH_SIZE did not reach the daemon: $(cat "$work/qmd-env")"
grep -q '^conc=8$' "$work/qmd-env" || fail "(48) EMBED_CONCURRENCY did not reach the daemon: $(cat "$work/qmd-env")"
grep -q '^unlisted=$' "$work/qmd-env" || fail "(48) an unlisted name reached the daemon: $(cat "$work/qmd-env")"

# (49) an invalid value is dropped, the valid ones and the key still pass.
printf 'QMD_OPENAI_API_KEY=sk-file-secret-12\nQMD_OPENAI_PROVIDER=bad value;x\nQMD_OPENAI_EMBED_BATCH_SIZE=abc\nQMD_OPENAI_EMBED_CONCURRENCY=0\n' > "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 0 ] || fail "(49) invalid tuning values: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^key=set$' "$work/qmd-env" || fail "(49) the key was lost: $(cat "$work/qmd-env")"
grep -q '^provider=$' "$work/qmd-env" || fail "(49) an invalid PROVIDER reached the daemon: $(cat "$work/qmd-env")"
grep -q '^batch=$' "$work/qmd-env" || fail "(49) a non-integer BATCH_SIZE reached the daemon: $(cat "$work/qmd-env")"
grep -q '^conc=$' "$work/qmd-env" || fail "(49) a zero CONCURRENCY reached the daemon: $(cat "$work/qmd-env")"
rm -f "$work/daemon.env"

# (50) the query-queue cap reaches the daemon from the env file; a non-positive or non-integer value is dropped.
printf 'QMD_OPENAI_API_KEY=sk-file-secret-13\nQMD_QUERY_MAX_QUEUED=2\n' > "$work/daemon.env"; chmod 600 "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 0 ] || fail "(50) queue cap env file: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^queue=2$' "$work/qmd-env" || fail "(50) QUERY_MAX_QUEUED did not reach the daemon: $(cat "$work/qmd-env")"
printf 'QMD_OPENAI_API_KEY=sk-file-secret-14\nQMD_QUERY_MAX_QUEUED=0\n' > "$work/daemon.env"; chmod 600 "$work/daemon.env"
launch_key; rc=$?
[ "$rc" -eq 0 ] || fail "(50) zero queue cap: expected rc 0, got $rc: $(cat "$work/err")"
grep -q '^queue=$' "$work/qmd-env" || fail "(50) a zero QUERY_MAX_QUEUED reached the daemon: $(cat "$work/qmd-env")"
rm -f "$work/daemon.env"

# (46) with no --index the fork prefers a cwd-walked project-local .qmd/index.{yaml,yml}
# over the global config; `--resolve` makes the gate check the SAME file, not only the global one.
OR_PIN_E='openai:qwen/qwen3-embedding-8b'
OR_PIN_R='openai:cohere/rerank-4-fast'
OR_URL='https://openrouter.ai/api/v1'
mkdir -p "$work/proj/.qmd" "$work/proj/sub/deep" "$work/clean" "$work/yamlproj/.qmd"
cfg "$work/glob.yml" "$LOCAL_EMBED" "$LOCAL_EMBED" - himmel
# a project-local config that sends the salus collection to a remote route
printf 'collections:\n  salus:\n    path: /nonexistent/salus\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$OR_PIN_E" "$OR_PIN_R" "$OR_URL" > "$work/proj/.qmd/index.yml"
# run_res <cwd> [VAR=value...]: the gate in --resolve mode, started from <cwd>
run_res() {
  local d="$1"; shift
  ( cd "$d" && env -u QMD_EMBED_MODEL -u QMD_RERANK_MODEL -u QMD_GENERATE_MODEL -u QMD_OPENAI_BASE_URL CLAUDE_GLM_CONFIG_DIR="$work/none" QMD_CONFIG_DIR="$work/qc-none" "$@" node "$gate" --resolve "$work/glob.yml" 2>"$work/err" )
}
run_res "$work/proj"; rc=$?
[ "$rc" -eq 3 ] || fail "(46a) project-local salus + remote route from its own dir: expected rc 3, got $rc: $(cat "$work/err")"
grep -q 'salus' "$work/err" || fail "(46a) the refusal must name salus: $(cat "$work/err")"
grep -q "$work/proj/.qmd/index.yml" "$work/err" || fail "(46a) the refusal must name the project-local file: $(cat "$work/err")"
run_res "$work/proj/sub/deep"; rc=$?
[ "$rc" -eq 3 ] || fail "(46b) the cwd walk must find .qmd/index.yml from a deeper dir: expected rc 3, got $rc"
run_res "$work/clean"; rc=$?
[ "$rc" -eq 0 ] || fail "(46c) no project-local config: the global (local-model) config applies: expected rc 0, got $rc: $(cat "$work/err")"
# index.yaml wins over index.yml, as the fork orders them
printf 'collections:\n  himmel:\n    path: /nonexistent/h\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$OR_PIN_E" "$OR_PIN_R" "$OR_URL" > "$work/yamlproj/.qmd/index.yml"
printf 'collections:\n  salus:\n    path: /nonexistent/salus\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$OR_PIN_E" "$OR_PIN_R" "$OR_URL" > "$work/yamlproj/.qmd/index.yaml"
run_res "$work/yamlproj"; rc=$?
[ "$rc" -eq 3 ] || fail "(46d) index.yaml must be the file checked when both exist: expected rc 3, got $rc"
# a clean remote project-local config (non-salus, pinned openrouter models) is allowed: the positive control
printf 'collections:\n  himmel:\n    path: /nonexistent/h\nmodels:\n  embed: %s\n  rerank: %s\n  openai_base_url: %s\n' "$OR_PIN_E" "$OR_PIN_R" "$OR_URL" > "$work/proj/.qmd/index.yml"
run_res "$work/proj"; rc=$?
[ "$rc" -eq 0 ] || fail "(46e) clean remote project-local config: expected rc 0, got $rc: $(cat "$work/err")"
# an unreadable project-local config fails closed
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$work/proj/.qmd/index.yml"
  run_res "$work/proj"; rc=$?
  chmod 600 "$work/proj/.qmd/index.yml"
  [ "$rc" -ne 0 ] || fail "(46f) an unreadable project-local config must fail closed, got rc 0"
fi

# (47) a remote value in ANY QMD_*_MODEL env refuses a salus index, whichever config file applies.
printf 'collections:\n  salus:\n    path: /nonexistent/salus\nmodels:\n  embed: %s\n  rerank: %s\n' "$LOCAL_EMBED" "$LOCAL_EMBED" > "$work/proj/.qmd/index.yml"
for ev in QMD_EMBED_MODEL QMD_RERANK_MODEL QMD_GENERATE_MODEL; do
  run_res "$work/proj" "$ev=$OR_PIN_E" "QMD_OPENAI_BASE_URL=$OR_URL"; rc=$?
  [ "$rc" -eq 3 ] || fail "(47) $ev=openai:... with a project-local salus config: expected rc 3, got $rc: $(cat "$work/err")"
done
run_res "$work/proj"; rc=$?
[ "$rc" -eq 0 ] || fail "(47) project-local salus on local models, no env: expected rc 0, got $rc: $(cat "$work/err")"

echo "PASS: test-qmd-jina-gate.sh"
