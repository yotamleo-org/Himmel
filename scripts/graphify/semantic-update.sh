#!/usr/bin/env bash
# semantic-update.sh — incremental semantic layer for one corpus.
#
# WHY: the armed graphmap cadence rebuilds only the AST graph (hourly/daily
# `graphify update`); semantic extraction of markdown never runs on a schedule.
# refresh-graph-map.sh can run it, but it copies the whole corpus, re-runs
# clustering + LLM community labeling and has no change gate or spend cap.
# This step re-extracts ONLY the markdown files whose content changed since the
# last semantic pass and merges the result into the live graph.json.
#
# Flow: fence --eval (salus / any DENY refuses before anything is copied) ->
# content-hash plan against <out>/semantic-manifest.json -> no change = no-op
# (no bank, no copy) -> promote lock, re-planned under it (the protocol ast-update.sh and
# refresh-graph-map.sh share) -> bank-preflight -> scratch copy of the changed
# files only (+ `.graphify-corpus` marker + seeded semantic cache) ->
# `graphify extract --no-cluster` -> semantic-merge.py merge -> harden-graph.py.
# Clustering is left to the next AST pass, which reclusters and keeps semantic
# nodes. Each run appends one line to <out>/semantic-runs.jsonl (nodes/edges
# added and removed, backlog, runtime, tokens, cost equivalent).
# Measure the result with semantic-metrics.py <graph.json> [--files a.md,b.md]
# (rationale coverage, cross-file and doc-to-code edges).
#
# BILLING: --backend claude-cli makes graphify shell `claude -p` once per chunk,
# which draws the SAME subscription 5h/weekly bank as interactive use
#; hence the bank-preflight gate and the --max-files cap. Changed
# files above the cap stay unstamped and roll to the next run (reported as
# `backlog`).
#
# --backend claude-api bills API credit, not the subscription bank:
# graphify's claude-cli path runs through scripts/api-lane/claude-api.sh (per-
# account key, roster, credit gate, reserve/settle ledger all stay in the lane;
# this script never reads or handles a key). A scratch `claude` shim first on
# PATH adapts graphify's call to the lane's flag allowlist. It needs
# HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT=A|B|auto in the launching shell,
# refuses a caller ANTHROPIC_API_KEY, and fails closed (exit 2) otherwise: it
# never falls back to the subscription claude-cli. Spend is bounded by
# --max-files, a per-call lane budget (GRAPHIFY_API_CALL_BUDGET_USD, default
# 1.00) and the account cap the lane enforces; the plan's estimate line prints
# before any call, and --dry-run stops right after it.
#
# claude-api runs the extraction at GRAPHIFY_API_EFFORT (default high; low,
# medium, high, xhigh or max, what `claude --effort` accepts). A/B 2026-10-16:
# low/medium missed more facts and carried about 4 weak edges in
# 10 (high about 2); max costs over 5x and returned rc 1 rows. Measured at high:
# about 0.36 USD per 30k-token chunk, 23.70 USD for a full 680-file himmel run.
# A high-effort call needs a 1.00 USD cap at 30k-token chunks (at 0.50 and 60k
# it fails the per-call budget stop), so 1.00 is the default cap.
#
# claude-api also appends two requirements graphify's own prompt lacks to every
# chunk prompt (through the shim): a `rationale` on every non-code node, and
# doc-to-code edges of relation `documents`, `explains` or `rationale_for`. Its
# extraction cache is kept apart (cache/semantic-r1), so a chunk cached under the
# old prompt is never replayed without them. The per-run spend cap (--max-run-usd,
# default 15.00; GRAPHIFY_API_RUN_BUDGET_USD) is a planning input: the batch is sized so its estimated chunks fit
# it, and a run planned inside it is never stopped by it. Spend past the cap is logged as a WARN and the calls
# go on; only the API refusing for lack of credit stops a chunk, and the finished chunks still merge. The run
# row carries the summed cost (`cost_usd`), the backend and the cap.
#
# Usage:
#   semantic-update.sh --name N --corpus-root R --corpus-class C
#       [--backend claude-cli|claude-api|ollama] [--max-files 150] [--max-run-usd 15.00] [--seed-manifest] [--dry-run]
#
# --backend ollama runs the local model (OLLAMA_MODEL, default qwen3.6:27b) at
# --max-concurrency 1 and skips bank-preflight (no subscription draw). It
# refuses a non-loopback or unparseable endpoint and an Ollama cloud model.
#
# --seed-manifest stamps the current hashes as the baseline without extracting:
# run it once on a corpus whose graph already carries a semantic pass, or the
# first run treats every file as changed.
#
# Exit: 0 ok / no-op; 1 usage or IO; 2 fence deny, graphify or merge failure;
# 3 bank at/over threshold (nothing touched); 4 promote lock held.
# graph-cadence.sh --semantic treats 3 and 4 as benign skips (the next fire
# retries, nothing was touched) and alerts on every other non-zero rc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

NAME="" CORPUS_ROOT="" CORPUS_CLASS="" BACKEND="claude-cli" MAX_FILES=150 SEED=0 DRY=0 RUN_CAP="${GRAPHIFY_API_RUN_BUDGET_USD:-15.00}"
usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --corpus-class) CORPUS_CLASS="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --max-files) MAX_FILES="${2:-}"; shift 2 ;;
    --max-run-usd) RUN_CAP="${2:-}"; shift 2 ;;
    --seed-manifest) SEED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "semantic-update: unknown argument '$1'" >&2; usage ;;
  esac
done
if [ -z "$NAME" ] || [ -z "$CORPUS_ROOT" ] || [ -z "$CORPUS_CLASS" ]; then usage; fi
case "$NAME" in *[!A-Za-z0-9._-]*) echo "semantic-update: --name must match [A-Za-z0-9._-]+" >&2; exit 1 ;; esac
case "$MAX_FILES" in ''|*[!0-9]*) MAX_FILES=0 ;; *) MAX_FILES=$((10#$MAX_FILES)) ;; esac
[ "$MAX_FILES" -gt 0 ] || { echo "semantic-update: --max-files must be a positive integer" >&2; exit 1; }
[ -d "$CORPUS_ROOT" ] || { echo "semantic-update: --corpus-root '$CORPUS_ROOT' is not a directory" >&2; exit 1; }
CORPUS_ROOT="$(cd "$CORPUS_ROOT" && pwd -P)"
# Same out dir ast-update.sh resolves: an absolute GRAPHIFY_OUT (the luna AST wrapper keeps its graph outside the
# vault) is used as-is, a relative one must be a single directory name under the corpus.
_out_name="${GRAPHIFY_OUT:-graphify-out}"
case "$_out_name" in
  /*) OUT_DIR="$_out_name" ;;
  *)
    case "$_out_name" in
      [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
        echo "semantic-update: a relative GRAPHIFY_OUT must be a single directory name (got '$_out_name')" >&2; exit 1 ;;
    esac
    OUT_DIR="$CORPUS_ROOT/$_out_name" ;;
esac
# A symlink at an overridden out dir escapes the directory named; -d and the graph.json check follow it, -L sees the
# link itself. ast-update.sh refuses the same value with the same exit.
if [ "$OUT_DIR" != "$CORPUS_ROOT/graphify-out" ] && [ -L "$OUT_DIR" ]; then
  echo "semantic-update: GRAPHIFY_OUT is overridden to '$_out_name' and $OUT_DIR is a SYMLINK, which would place the graph write outside the directory named. Point it at a real directory" >&2
  exit 3
fi
API_CALL_BUDGET="${GRAPHIFY_API_CALL_BUDGET_USD:-1.00}"
API_EFFORT="${GRAPHIFY_API_EFFORT:-high}"
if [ "$BACKEND" = "claude-api" ]; then
  case "$API_CALL_BUDGET" in ''|*[!0-9.]*|.|*.*.*) echo "semantic-update: GRAPHIFY_API_CALL_BUDGET_USD must be a positive decimal" >&2; exit 1 ;; esac
  case "$API_CALL_BUDGET" in *[1-9]*) ;; *) echo "semantic-update: GRAPHIFY_API_CALL_BUDGET_USD must be a positive decimal" >&2; exit 1 ;; esac
  case "$RUN_CAP" in ''|*[!0-9.]*|.|*.*.*) echo "semantic-update: --max-run-usd must be a positive decimal" >&2; exit 1 ;; esac
  case "$RUN_CAP" in *[1-9]*) ;; *) echo "semantic-update: --max-run-usd must be a positive decimal" >&2; exit 1 ;; esac
  case "$API_EFFORT" in low|medium|high|xhigh|max) ;; *) echo "semantic-update: GRAPHIFY_API_EFFORT must be one of low, medium, high, xhigh, max (got '$API_EFFORT')" >&2; exit 1 ;; esac
fi
# A chunk must fit one lane call: graphify's default 60000-token chunk costs about 0.45 USD on sonnet and died
# under the 0.25 USD cap (himmel batch 1, 8 of 9 chunks). At high effort a 30k-token chunk costs about 0.36 USD,
# so 30000 tokens per USD keeps a chunk near 0.36 of its cap.
# ponytail: the rate is measured on one A/B run (HIMMEL-5835), not a table; re-measure from the lane ledger once real batches settle, HIMMEL-5871.
CHUNK_TOKENS=""
if [ "$BACKEND" = "claude-api" ]; then
  CHUNK_TOKENS="$(awk -v b="$API_CALL_BUDGET" 'BEGIN { t = int(b * 30000); if (t > 60000) t = 60000; print t }')"
  if [ "$CHUNK_TOKENS" -lt 1000 ]; then
    echo "semantic-update: GRAPHIFY_API_CALL_BUDGET_USD=$API_CALL_BUDGET is too small for any chunk (needs at least 0.04)" >&2
    exit 1
  fi
fi
MERGE=(python3 "$HERE/semantic-merge.py")

# --backend ollama: local model, zero egress, no bank draw. This
# script's OWN check, independent of the fence (defence in depth): the endpoint
# graphify will reach (OLLAMA_BASE_URL verbatim when set, else OLLAMA_HOST,
# else the loopback default - graphify's llm.py order) must be loopback, and
# the model must not be an Ollama cloud model (`-cloud` / `:cloud`), which the
# local daemon forwards to ollama.com.
ollama_endpoint_is_loopback() {
  local v re
  if [ "${OLLAMA_BASE_URL+set}" = set ]; then
    v="$(printf '%s' "$OLLAMA_BASE_URL" | tr '[:upper:]' '[:lower:]')"
    re='^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?(/[a-z0-9._/-]*)?$'
  elif [ -n "${OLLAMA_HOST:-}" ]; then
    v="$(printf '%s' "$OLLAMA_HOST" | tr '[:upper:]' '[:lower:]')"
    re='^((https?://)?(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?|:?[0-9]{1,5})/?$'
  else
    return 0
  fi
  [[ "$v" =~ $re ]]
}
if [ "$BACKEND" = "ollama" ]; then
  export OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.6:27b}"
  ollama_endpoint_is_loopback \
    || { echo "semantic-update: refusing ollama: the endpoint (OLLAMA_BASE_URL, else OLLAMA_HOST) is not loopback or does not parse -- nothing copied" >&2; exit 2; }
  case "$(printf '%s' "$OLLAMA_MODEL" | tr '[:upper:]' '[:lower:]')" in
    *-cloud|*:cloud) echo "semantic-update: refusing ollama: OLLAMA_MODEL '$OLLAMA_MODEL' is an Ollama cloud model -- nothing copied" >&2; exit 2 ;;
  esac
  # Loopback + non-cloud model are verified above, so graphify's "no OLLAMA_API_KEY
  # set" warning is noise: it exists to flag a corpus leaving the
  # machine. Hand it the documented placeholder; a caller-set key still wins, and
  # the cloud path (refresh-graph-map.sh) never gets one, so its warning and any
  # real auth error stay visible.
  : "${OLLAMA_API_KEY:=ollama}"; export OLLAMA_API_KEY
  # graphify derives num_ctx from the chunk size (32768 seen), which
  # spilled qwen3.6:27b 55% to CPU, and its request timeout defaults to 600 s.
  # Pin a context that should fit the 24 GB card and raise the timeout; a
  # caller-set value of either wins.
  # ponytail: num_ctx 16384 unmeasured, the GPU was unavailable; re-measure per HIMMEL-4527 when the 4090 returns from RMA
  : "${GRAPHIFY_OLLAMA_NUM_CTX:=16384}"; export GRAPHIFY_OLLAMA_NUM_CTX
  : "${GRAPHIFY_API_TIMEOUT:=1800}"; export GRAPHIFY_API_TIMEOUT
fi

# Egress first, before any copy or bank call (direct-eval contract:
# the same verdict, provider map and ledger an agent-typed graphify gets; the
# asserted class can only be tightened by the path classifier, so a .salus
# root denies whatever is asserted). Reroute selectors are cleared first, as
# refresh-graph-map.sh does, so the anthropic verdict is the provider reached.
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
unset CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS
if [ "$SEED" -eq 0 ]; then
  bash "$REPO_ROOT/scripts/guardrails/graphify-fence.sh" --eval "$CORPUS_CLASS" "$BACKEND" "$CORPUS_ROOT" semantic-update \
    || { echo "semantic-update: egress fence refused corpus '$NAME' -- nothing copied" >&2; exit 2; }
fi

[ -f "$OUT_DIR/graph.json" ] || { echo "semantic-update: no $OUT_DIR/graph.json -- run the AST pass (ast-update.sh) first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/graphify-semantic-$NAME-XXXXXX")"
PROMOTE_LOCK="$OUT_DIR/.promote.lock" PROMOTE_LOCK_HELD=0 PROMOTE_LOCK_TOKEN="$$-$RANDOM"
cleanup() {
  if [ "$PROMOTE_LOCK_HELD" -eq 1 ] && [ "$(cat "$PROMOTE_LOCK/owner" 2>/dev/null)" = "$PROMOTE_LOCK_TOKEN" ]; then
    rm -rf "$PROMOTE_LOCK"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Promote lock, same protocol as ast-update.sh (mkdir arbiter, owner token,
# acquired stamp). Bounded wait, then skip: the next run retries.
acquire_promote_lock() {
  local waited=0
  until mkdir "$PROMOTE_LOCK" 2>/dev/null; do
    if [ "$waited" -ge "${GRAPHIFY_SEMANTIC_LOCK_WAIT:-120}" ]; then
      echo "semantic-update: SKIPPED -- promote lock $PROMOTE_LOCK held by another graph refresh" >&2
      exit 4
    fi
    sleep 5; waited=$((waited + 5))
  done
  PROMOTE_LOCK_HELD=1
  printf '%s\n' "$PROMOTE_LOCK_TOKEN" > "$PROMOTE_LOCK/owner"
  date -u +%s > "$PROMOTE_LOCK/acquired"
}

if [ "$SEED" -eq 1 ]; then
  [ "$DRY" -eq 0 ] || { echo "semantic-update: --dry-run, not stamping the manifest"; exit 0; }
  acquire_promote_lock
  "${MERGE[@]}" seed --root "$CORPUS_ROOT" --out "$OUT_DIR"
  exit 0
fi

PLAN="$WORK/plan.json"
plan_or_noop() {
  "${MERGE[@]}" plan --root "$CORPUS_ROOT" --out "$OUT_DIR" --max-files "$MAX_FILES" --plan "$PLAN"
  read -r N_BATCH N_DELETED < <(python3 -c 'import json,sys;p=json.load(open(sys.argv[1]));print(len(p["batch"]),len(p["deleted"]))' "$PLAN")
  if [ "$N_BATCH" -eq 0 ] && [ "$N_DELETED" -eq 0 ]; then
    echo "semantic-update: corpus '$NAME' unchanged since the last semantic pass -- no-op"
    exit 0
  fi
}
plan_or_noop
if [ "$BACKEND" = "claude-api" ]; then
  # ponytail: tokens ~ bytes/4 plus 2000 prompt tokens per file, output a quarter of input, at the sonnet list
  # rate ($3/$15 per M); a rough ceiling, replace with a measured figure once a real run is ledgered.
  FIT_FILES="$(python3 - "$PLAN" "$CORPUS_ROOT" "${GRAPHIFY_CLAUDE_CLI_MODEL-sonnet}" "$API_CALL_BUDGET" "$CHUNK_TOKENS" "$RUN_CAP" <<'PY'
import json, os, sys
plan, root, model, budget, chunk, cap = sys.argv[1:7]
files = json.load(open(plan))["batch"]
size = sum(os.path.getsize(os.path.join(root, f)) for f in files)
tin = size // 4 + 2000 * len(files)
tout = tin // 4
usd = (tin * 3 + tout * 15) / 1e6
log = lambda m: print(m, file=sys.stderr)
log("semantic-update: estimate: files=%d bytes=%d ~tokens_in=%d ~tokens_out=%d ~usd=%.2f model=%s per-call-budget-usd=%s"
    % (len(files), size, tin, tout, usd, model, budget))
ct = int(chunk)
chunk_usd = (ct * 3 + ct // 4 * 15) / 1e6
chunks = -(-tin // ct)
log("semantic-update: chunk: call-cap=%s chunk-tokens=%d chunk-cost-est=~%.2f chunks~%d run-cap-usd=%s"
    % (budget, ct, chunk_usd, chunks, cap))
# the run cap sizes the batch: keep the share of files whose chunks fit it; the rest stay unstamped for the next run
fit_chunks = int(float(cap) / chunk_usd)
print(len(files) if chunks <= fit_chunks else max(1, len(files) * fit_chunks // chunks))
PY
)"
  if [ "$FIT_FILES" -lt "$N_BATCH" ]; then
    echo "semantic-update: sized: batch of $N_BATCH files cut to $FIT_FILES to fit the run cap of $RUN_CAP USD; the rest stay unstamped for the next run" >&2
    MAX_FILES="$FIT_FILES"
    plan_or_noop
  fi
fi
[ "$DRY" -eq 0 ] || { echo "semantic-update: --dry-run, stopping before the bank and the copy"; exit 0; }
if [ "$BACKEND" = "claude-api" ]; then
  { [ "${HIMMEL_API_LANE:-}" = "on" ] && [ -n "${HIMMEL_API_ACCOUNT:-}" ]; } \
    || { echo "semantic-update: refusing claude-api: the API lane is off (HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT=A|B|auto are required) -- nothing copied, no claude-cli fallback" >&2; exit 2; }
  [ -z "${ANTHROPIC_API_KEY:-}" ] \
    || { echo "semantic-update: refusing claude-api: a caller ANTHROPIC_API_KEY is set; the lane reads its own per-account key file -- nothing copied" >&2; exit 2; }
  [ -f "$REPO_ROOT/scripts/api-lane/claude-api.sh" ] \
    || { echo "semantic-update: refusing claude-api: scripts/api-lane/claude-api.sh is missing -- nothing copied" >&2; exit 2; }
fi
acquire_promote_lock
# Re-plan under the lock: another run may have promoted (or the corpus moved)
# while we waited, and the pre-lock plan would re-extract a stale batch.
plan_or_noop

TOKENS_IN=0 TOKENS_OUT=0 FAILED_CHUNKS="" START="$(date +%s)"
# Summed verified cost of the lane calls so far (0 off the claude-api path, which never writes the file).
spent_usd() { if [ -f "$WORK/spend.log" ]; then awk '{ s += $1 } END { printf "%.6f", s + 0 }' "$WORK/spend.log"; else echo 0; fi; }
SCRATCH="$WORK/corpus"
if [ "$N_BATCH" -gt 0 ]; then
  case "$BACKEND" in
    claude|claude-cli)
      # Fail-open by bank-preflight's own contract; bounded and loud like
      # refresh-graph-map.sh, so a hung or silent preflight is visible.
      _bound=()
      if command -v timeout >/dev/null 2>&1; then _bound=(timeout -k 10 120); fi
      verdict="$(CADENCE_USAGE_LEG="graphmap-semantic-$NAME" ${_bound[@]+"${_bound[@]}"} bash "$REPO_ROOT/scripts/lib/usage-preflight.sh" || true)"
      if [ -z "$verdict" ]; then
        echo "semantic-update: WARN bank-preflight gave no verdict (timed out or failed) -- proceeding UNGUARDED" >&2
      fi
      if [ "$verdict" = "SKIPPED-BANK" ]; then
        echo "semantic-update: bank at/over threshold -- extraction SKIPPED for '$NAME', nothing touched" >&2
        exit 3
      fi ;;
  esac
  if [ "$BACKEND" = "claude-cli" ] || [ "$BACKEND" = "claude-api" ]; then
    # Same pins as refresh-graph-map.sh: sonnet, low effort,
    # raised timeout, and a hook-free config dir.
    export GRAPHIFY_CLAUDE_CLI_MODEL="${GRAPHIFY_CLAUDE_CLI_MODEL-sonnet}"
    export CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_CODE_EFFORT_LEVEL-low}"
    export GRAPHIFY_API_TIMEOUT="${GRAPHIFY_API_TIMEOUT-900}"
    export GRAPHIFY_CLAUDE_CONFIG_DIR="${GRAPHIFY_CLAUDE_CONFIG_DIR:-$HOME/.claude-graphify}"
    bash "$HERE/seed-claude-config.sh" \
      || { echo "semantic-update: failed to seed the hook-free Claude config dir; refusing claude-cli extraction" >&2; exit 2; }
    export CLAUDE_CONFIG_DIR="$GRAPHIFY_CLAUDE_CONFIG_DIR"
  fi
  GRAPHIFY_BACKEND="$BACKEND"
  if [ "$BACKEND" = "claude-api" ]; then
    # graphify only knows claude-cli, which execs `claude -p`. Put a shim first on PATH that drops the flags the
    # lane's allowlist refuses (--output-format, --no-session-persistence, --json-schema), adds its required
    # ones, and runs from the shim dir so the lane's sandbox stubs never land in a checkout. The shim removes
    # its own dir from PATH, so the lane finds the real claude. The prompt stays on stdin.
    GRAPHIFY_BACKEND="claude-cli"
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/claude" <<'SHIM'
#!/usr/bin/env bash
# graphify claude-cli -> API lane shim (written by semantic-update.sh)
case "${1:-}" in
  --help|-h) echo "claude (himmel API-lane shim): -p [--model M] [--output-format json]; the prompt is read from stdin"; exit 0 ;;
esac
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--no-session-persistence) shift ;;
    --output-format|--json-schema) [ $# -ge 2 ] || exit 2; shift 2 ;;
    --model) [ $# -ge 2 ] || exit 2; model="$2"; shift 2 ;;
    *) echo "claude-api shim: refusing unexpected argument '$1'" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
newpath=""
IFS=: read -ra parts <<< "$PATH"
for d in "${parts[@]}"; do [ "$d" = "$here" ] || newpath="${newpath:+$newpath:}$d"; done
export PATH="$newpath"
cd "$here" || exit 2
# Corpus text is untrusted prompt input, so the extraction runs tool-free (the lane's narrow-only override).
export HIMMEL_API_TOOLS=""
# The lane's result goes to stdout, where graphify never shows it on a failed call; echo its tail to stderr
# so the chunk-failed line carries the real reason (a budget stop, a refusal) and the exit code.
out="$here/lane-out.$$"
err="$here/lane-err.$$"
# The run cap sized the plan; spend past it is a warning, never a refusal.
spent="$(awk '{ s += $1 } END { printf "%.6f", s + 0 }' "$GRAPHIFY_SEMANTIC_SPEND_FILE" "$GRAPHIFY_SEMANTIC_RESERVE_FILE")"
if awk -v s="$spent" -v c="$GRAPHIFY_SEMANTIC_RUN_CAP" 'BEGIN { exit !(s + 0 >= c + 0) }'; then
  echo "claude-api shim: WARN: run spend $spent is past the planned cap $GRAPHIFY_SEMANTIC_RUN_CAP USD; the call goes on" >&2
fi
{ cat; printf '\n\n---\n'; cat "$GRAPHIFY_SEMANTIC_ADDENDUM"; } | "$GRAPHIFY_SEMANTIC_LANE_BIN" -p --model "${model:-sonnet}" --permission-mode default \
  --max-budget-usd "$GRAPHIFY_SEMANTIC_LANE_BUDGET" --effort "$GRAPHIFY_SEMANTIC_LANE_EFFORT" > "$out" 2> "$err"
rc=${PIPESTATUS[1]}
cat "$err" >&2
# A call without a verified cost (a failure) may still have been billed: reserve its per-call budget against the
# cap, but keep it out of the spend file so the run row reports only verified cost. A call the lane refused
# before any API request (exit 2, nothing on stdout, its own refusal line) was never billed: it counts for nothing.
cost="$(node "$GRAPHIFY_SEMANTIC_OUTCOME_BIN" "$out" 2>/dev/null)"
if [ "$rc" -eq 2 ] && [ ! -s "$out" ] && grep -q '^claude-api: refused: ' "$err"; then :
elif [ -n "$cost" ]; then echo "$cost" >> "$GRAPHIFY_SEMANTIC_SPEND_FILE"; else echo "$GRAPHIFY_SEMANTIC_LANE_BUDGET" >> "$GRAPHIFY_SEMANTIC_RESERVE_FILE"; fi
[ "$rc" -eq 0 ] || echo "claude-api shim: lane exited $rc; result: $(tail -c 400 "$out" | tr '\n' ' ')" >&2
cat "$out"; rm -f "$out" "$err"
exit "$rc"
SHIM
    chmod +x "$WORK/bin/claude"
    cat > "$WORK/addendum.txt" <<'ADD'
ADDITIONAL REQUIREMENTS (these override the optional-rationale rule above for every node that is not a code symbol):
- Every document, concept or rationale node MUST carry a non-empty `rationale`: one sentence of WHY, the reason, trade-off, constraint or intent behind what the node says. If the source never states a reason, give the reason it implies and prefix it with "implied: ". Never null, never a restatement of the label.
- Doc-to-code edges: whenever a document names a code file, script, function, command, hook or gate, add an edge from the document or concept node to that code node, source = the document or concept node, target = the code node (a path scripts/x/y.sh gives the id scripts_x_y, a symbol adds _name). Relation `documents` when the text describes that code, `explains` when it explains how or why that code works, `rationale_for` when it gives the reason that code exists or has its shape. Confidence EXTRACTED when the code is named in the text, otherwise INFERRED.
- `documents`, `explains` and `rationale_for` are allowed relation values in addition to the schema's list.
ADD
    : > "$WORK/spend.log"; : > "$WORK/reserve.log"
    export GRAPHIFY_SEMANTIC_ADDENDUM="$WORK/addendum.txt" GRAPHIFY_SEMANTIC_SPEND_FILE="$WORK/spend.log" GRAPHIFY_SEMANTIC_RUN_CAP="$RUN_CAP"
    export GRAPHIFY_SEMANTIC_RESERVE_FILE="$WORK/reserve.log"
    export GRAPHIFY_SEMANTIC_OUTCOME_BIN="$REPO_ROOT/scripts/api-lane/outcome.mjs"
    export GRAPHIFY_SEMANTIC_LANE_BIN="$REPO_ROOT/scripts/api-lane/claude-api.sh" GRAPHIFY_SEMANTIC_LANE_BUDGET="$API_CALL_BUDGET" GRAPHIFY_SEMANTIC_LANE_EFFORT="$API_EFFORT"
    export PATH="$WORK/bin:$PATH"
  fi
  mkdir -p "$SCRATCH/graphify-out/cache"
  python3 - "$PLAN" "$CORPUS_ROOT" "$SCRATCH" <<'PY'
import json, os, shutil, sys
plan, src, dst = sys.argv[1:4]
for rel in json.load(open(plan))["batch"]:
    os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))
PY
  [ ! -f "$CORPUS_ROOT/.graphifyignore" ] || cp "$CORPUS_ROOT/.graphifyignore" "$SCRATCH/"
  # The claude-api prompt differs from graphify's own, whose cache stamp would not notice: keep its entries apart.
  CACHE_SUB="semantic"
  if [ "$BACKEND" = "claude-api" ]; then CACHE_SUB="semantic-r1"; fi
  [ ! -d "$OUT_DIR/cache/$CACHE_SUB" ] || cp -R "$OUT_DIR/cache/$CACHE_SUB" "$SCRATCH/graphify-out/cache/semantic"
  printf '%s\n' "$CORPUS_CLASS" > "$SCRATCH/.graphify-corpus"
  EXTRA=()
  # One request at a time: the local model holds the whole GPU.
  if [ "$BACKEND" = "ollama" ]; then EXTRA=(--max-concurrency 1); fi
  if [ "$BACKEND" = "claude-api" ]; then EXTRA=(--token-budget "$CHUNK_TOKENS"); fi
  # GRAPHIFY_NO_AUTO_REFRESH=1: no skill-dir rewrite from a cadence run.
  export GRAPHIFY_NO_AUTO_REFRESH=1
  set +e
  # env -u GRAPHIFY_OUT: extract reads and writes the out-root GRAPHIFY_OUT names, so an inherited absolute one
  # (the luna AST wrapper's) would make it work on the LIVE graph instead of the scratch copy.
  env -u GRAPHIFY_OUT graphify extract "$SCRATCH" --backend "$GRAPHIFY_BACKEND" ${EXTRA[@]+"${EXTRA[@]}"} --no-cluster > "$WORK/extract.log" 2>&1
  rc=$?
  set -e
  cat "$WORK/extract.log" >&2
  FAILED_CHUNKS="$(sed -n 's|.*WARNING: \([0-9]*/[0-9]*\) semantic chunk(s) failed.*|\1|p' "$WORK/extract.log" | tail -1)"
  if [ "$rc" -ne 0 ]; then
    # Calls made before the failure were billed: leave a row so the spend is not lost.
    "${MERGE[@]}" failrow --name "$NAME" --out "$OUT_DIR" --backend "$BACKEND" --cost-usd "$(spent_usd)" --rc "$rc" || true
    # The first lane refusal (its reason, else its text) rides the closing line, which is what the cadence ledger keeps.
    REFUSED="$(sed -n 's/.*claude-api: refused: //p' "$WORK/extract.log" | head -n 1)"
    case "$REFUSED" in *'"reason":"'*) REFUSED="$(printf '%s' "$REFUSED" | sed 's/.*"reason":"\([^"]*\)".*/\1/')" ;; esac
    echo "semantic-update: graphify extract exited $rc${REFUSED:+ (refused: ${REFUSED:0:80})} -- graph and manifest untouched" >&2; exit 2
  fi
  read -r TOKENS_IN TOKENS_OUT < <(sed -n 's/.*tokens: \([0-9,]*\) in \/ \([0-9,]*\) out.*/\1 \2/p' "$WORK/extract.log" | tr -d , | tail -1; echo)
  : "${TOKENS_IN:=0}" "${TOKENS_OUT:=0}"
fi

# A failed or refused file's cache entry is evicted from both copies, or the cp-back below would restore it.
EVICT=()
[ -z "${CACHE_SUB:-}" ] || EVICT=(--evict-cache "$SCRATCH/graphify-out/cache/semantic" --evict-cache "$OUT_DIR/cache/$CACHE_SUB")
"${MERGE[@]}" merge --name "$NAME" --out "$OUT_DIR" --scratch "$SCRATCH" --plan "$PLAN" ${EVICT[@]+"${EVICT[@]}"} \
  --runtime-s "$(( $(date +%s) - START ))" --tokens-in "$TOKENS_IN" --tokens-out "$TOKENS_OUT" \
  --backend "$BACKEND" --cost-usd "$(spent_usd)" --cap-usd "$([ "$BACKEND" = "claude-api" ] && echo "$RUN_CAP" || echo 0)" \
  || {
    # The merge writes its row last, so a failed merge billed calls without leaving one.
    "${MERGE[@]}" failrow --name "$NAME" --out "$OUT_DIR" --backend "$BACKEND" --cost-usd "$(spent_usd)" --rc 2 || true
    echo "semantic-update: merge failed -- the batch stays unstamped and re-extracts next run" >&2; exit 2
  }
if [ -d "$SCRATCH/graphify-out/cache/semantic" ]; then
  mkdir -p "$OUT_DIR/cache/$CACHE_SUB"
  cp -R "$SCRATCH/graphify-out/cache/semantic/." "$OUT_DIR/cache/$CACHE_SUB/"
fi
python3 "$HERE/harden-graph.py" --out "$OUT_DIR" --root "$CORPUS_ROOT" >&2 \
  || echo "semantic-update: WARN harden-graph.py failed; the merged graph stands, the next refresh re-hardens it" >&2
# The chunks that did land are merged and stamped; the failed ones stay unstamped and retry next run. Exit 5 so a
# loop on the exit code stops instead of re-billing the same failure.
if [ -n "$FAILED_CHUNKS" ]; then
  echo "semantic-update: FAILED: $FAILED_CHUNKS semantic chunks failed -- the good chunks merged, the failed files stay unstamped; do not rerun until the cause is fixed" >&2
  exit 5
fi
