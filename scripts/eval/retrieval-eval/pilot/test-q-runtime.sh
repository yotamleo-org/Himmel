#!/usr/bin/env bash
# test-q-runtime.sh [--require-runtime] -- P13-Q, B10's required runtime proof: the REAL pinned
# local-Q qmd with the actual pinned GGUF weights (read-only, already on disk: never
# downloaded), inside a network namespace with the GPU device nodes bound, a fresh qmd
# process and cache, on a fixture index. Asserts full expansion/embedding/rerank, host NVML
# memory on the admitted qmd child, zero skips and completion inside the fixed deadlines;
# and that missing weights, a missing device and CI=true reaching the child refuse or skip.
# Local unbilled compute only: no network, no paid or remote model call.
#
# Default (lightweight CI) mode SKIPs when the weights, the GPU, qmd or bwrap are absent, or
# CI is set; --require-runtime (station G3) FAILs instead. A SKIP is never a G3 PASS.
#
# Platform guard: Linux bash with an NVIDIA GPU (nvidia-smi), bwrap and the pinned qmd.
set -uo pipefail

REQUIRE=0; [ "${1:-}" = "--require-runtime" ] && REQUIRE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/tools"
MODELS="${PILOT_Q_MODELS:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/models}"
WEIGHTS=(hf_ggml-org_embeddinggemma-300M-Q8_0.gguf hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf)
QMD="${PILOT_QMD:-$(command -v qmd || true)}"
QGPU="${PILOT_Q_GPU:-vulkan}"   # the station's locked QMD_LLAMA_GPU (this station's cuda prebuilt does not load)
missing=""
[ -n "${CI:-}" ] && missing="$missing CI=$CI"
[ -n "$QMD" ] || missing="$missing qmd"
command -v node >/dev/null 2>&1 || missing="$missing node"
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 || missing="$missing gpu"
{ command -v bwrap >/dev/null 2>&1 && bwrap --bind / / --unshare-net true 2>/dev/null; } || missing="$missing bwrap-netns"
for w in "${WEIGHTS[@]}"; do [ -f "$MODELS/$w" ] || missing="$missing weight:$w"; done
if [ -n "$missing" ]; then
  if [ "$REQUIRE" = 1 ]; then printf 'FAIL - P13-Q --require-runtime: missing runtime assets:%s\n' "$missing"; exit 1; fi
  printf 'SKIP - P13-Q real-runtime rows (not a G3 pass): missing%s\n' "$missing"
  exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-qrt.XXXXXX")" || exit 1
BROKERS=()
cleanup() { local p; for p in "${BROKERS[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
QPKG="$(cd "$(dirname "$(readlink -f "$QMD")")/.." && pwd)"  # gnu-ok: Linux-only suite
QDIST="$QPKG/dist"; VEC0="$QPKG/node_modules/sqlite-vec-linux-x64/vec0.so"

# a tiny fixture corpus, its S master (stub namespace, no embedding needed) and the real Q build
mkdir -p "$W/src/docs" "$W/srcl/notes" "$W/cfg-s" "$W/cfg-q" "$W/cache"
printf '# Lock\nThe queue lock keeps one session per handover doc.\n' > "$W/src/docs/lock.md"
printf '# Zeta\nThe zeta rule is settled.\n' > "$W/src/docs/zeta.md"
printf '# Garden\nWater the tomatoes on Tuesdays.\n' > "$W/srcl/notes/garden.md"
for r in src srcl; do git -C "$W/$r" init -q && gitc "$W/$r" add -A && gitc "$W/$r" commit -q -m pin; done
bash "$HERE/export-copies.sh" "$W/src" HEAD "$W/work/himmel" "$W/himmel.json" >/dev/null 2>&1
bash "$HERE/export-copies.sh" "$W/srcl" HEAD "$W/work/luna" "$W/luna.json" >/dev/null 2>&1
sed -e "s#@HIMMEL@#$W/work/himmel#" -e "s#@LUNA@#$W/work/luna#" "$HERE/fixtures/pins/eval.yml.in" > "$W/cfg-s/eval.yml"
sed -e "s#/work/himmel#$W/work/himmel#" -e "s#/work/luna#$W/work/luna#" "$T/qmd-eval-q.yml" > "$W/cfg-q/eval.yml"
( cd "$W" && bash "$HERE/fixtures/pins/netns-run.sh" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$W/cfg-s" INDEX_PATH="$W/s-build.sqlite" XDG_CACHE_HOME="$W/cache" "$QMD" --index eval update ) >/dev/null 2>&1
python3 -I "$HERE/pins.py" snapshot "$W/s-build.sqlite" "$W/s-master.sqlite"
python3 -I "$HERE/pins.py" finalize "$W/s-master.sqlite" --qmd "$QMD" --config-dir "$W/cfg-s" --expect-collection himmel="$W/work/himmel" --seal "$W/s.seal.json" >/dev/null
bash "$HERE/q-index.sh" --s-master "$W/s-master.sqlite" --s-seal "$W/s.seal.json" --config-dir "$W/cfg-q" --qmd "$QMD" --models-dir "$MODELS" \
  --vec0 "$VEC0" --llama-gpu "$QGPU" --collection himmel="$W/work/himmel" --collection luna="$W/work/luna" --out "$W/q" > "$W/qi.out" 2>&1
rc=$?
eq "P13-Q: the real Q index embeds on the locked GPU, finalizes and seals" 0 "$rc"
[ "$rc" = 0 ] || { sed 's/^/# /' "$W/qi.out"; tail -5 "$W/q/q-embed.log" 2>/dev/null | sed 's/^/# /'; }
R="$W/q/q-ready.json"
eq "P13-Q: the Q-ready manifest is a real (embedded) build with vectors" "true yes" "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r["embedded"]), "yes" if r["vector_rows"] > 0 else "no")' "$R")"
QC=(check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q" --models-dir "$MODELS" --runtime)
eq "P13-Q: the runtime readiness check passes before any query" 0 "$(python3 -I "$HERE/q-lists.py" "${QC[@]}" >/dev/null 2>&1; echo $?)"

binding() { # <out> <index> <socket> <child prefix json> [extra key=json]
  python3 -I - "$@" <<EOF
import importlib.util, json, sys
out, index, sock, prefix = sys.argv[1:5]
s = importlib.util.spec_from_file_location("pins", "$HERE/pins.py"); p = importlib.util.module_from_spec(s); s.loader.exec_module(p)
h, _, b = p.load_config("$QDIST", "$W/cfg-q")
d = {"arm": "Q", "qmd": "$QMD", "qmd_dist": "$QDIST", "node": "$(command -v node)", "preflight": "$T/config-preflight.mjs",
     "child_path": "/usr/bin:/bin:$(dirname "$QMD")", "config_dir": "$W/cfg-q", "config_sha256": b, "config_hash": h,
     "models": {"embed": "hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf",
                "generate": "hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf",
                "rerank": "hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf"},
     "models_dir": "$MODELS", "required_weights": $(printf '"%s",' "${WEIGHTS[@]}" | sed 's/^/[/; s/,$/]/'),
     "index": index, "forbidden_targets": ["$W/q/q-master.sqlite"], "socket": sock,
     "collections": {"himmel": "$W/work/himmel", "luna": "$W/work/luna"},
     "manifests": {"himmel": "$W/himmel.json", "luna": "$W/luna.json"},
     "env": {"QMD_LLAMA_GPU": "$QGPU", "QMD_RERANK_LOAD_TIMEOUT_MS": "480000"},
     "child_prefix": json.loads(prefix), "deadline_term_ms": 530000, "deadline_kill_ms": 540000}
for kv in sys.argv[5:]:
    k, v = kv.split("=", 1); d[k] = json.loads(v)
json.dump(d, open(out, "w"), indent=1)
EOF
}
GPU='["bwrap", "--bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc", "--unshare-net", "--die-with-parent"]'
NODEV='["bwrap", "--bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--unshare-net", "--die-with-parent"]'
NVML="nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits"
realq() { # <name> <prefix> [binding extra]... -- one real Q call on a fresh disposable copy, fresh broker
  python3 -I "$HERE/pins.py" disposable "$W/q/q-master.sqlite" "$W/$1.sqlite" --seal "$W/q/q-master.seal.json" >/dev/null
  "$T/s-qmd" serve --socket "$W/$1.sock" --meta "$W/meta-$1" --phase probe --arm Q --cap 12 --nvml-cmd "$NVML" &
  BROKERS+=($!)
  for _ in $(seq 100); do [ -S "$W/$1.sock" ] && break; sleep 0.02; done
  binding "$W/b-$1.json" "$W/$1.sqlite" "$W/$1.sock" "$2" "${@:3}"
  PILOT_BINDING="$W/b-$1.json" "$T/s-qmd" "exclusive access to shared notes" > "$W/$1.out" 2> "$W/$1.err"
  echo $? > "$W/$1.rc"
}
realq p13 "$GPU"
python3 -I "$HERE/q-lists.py" evidence --meta "$W/meta-p13" --deadline-ms 540000 > "$W/p13.ev" 2> "$W/p13.everr"
eq "P13-Q: full expansion/embedding/rerank, NVML memory on the qmd child, zero skips, inside the deadline" 0 "$?"
[ -s "$W/p13.everr" ] && sed 's/^/# /' "$W/p13.everr"
eq "P13-Q: the agent got results" 0 "$(cat "$W/p13.rc")"
eq "P13-Q: the disposable Q copy keeps the Q digest after the query" 0 "$(python3 -I "$HERE/q-lists.py" check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q" --models-dir "$MODELS" --copy "$W/p13.sqlite" >/dev/null 2>&1; echo $?)"
realq nodev "$NODEV"
python3 -I "$HERE/q-lists.py" evidence --meta "$W/meta-nodev" > /dev/null 2> "$W/nodev.everr"
eq "P13-Q: without the GPU device nodes the call is a CPU-fallback skip and fails the evidence" "1" "$( [ -s "$W/nodev.everr" ] && grep -c 'q_cpu_fallback' "$W/nodev.everr" || echo 0)"
realq ci "$GPU" 'env={"QMD_LLAMA_GPU": "'"$QGPU"'", "QMD_RERANK_LOAD_TIMEOUT_MS": "480000", "CI": "true"}'
realq cuda "$GPU" 'env={"QMD_LLAMA_GPU": "cuda", "QMD_RERANK_LOAD_TIMEOUT_MS": "480000"}'
python3 -I "$HERE/q-lists.py" evidence --meta "$W/meta-cuda" > /dev/null 2> "$W/cuda.everr"
eq "P13-Q: a GPU backend that cannot load is a CPU-fallback skip, never silently another device" "1" "$( [ -s "$W/cuda.everr" ] && grep -c 'q_cpu_fallback' "$W/cuda.everr" || echo 0)"
eq "P13-Q: CI=true reaching the child refuses before inference" "3 0" "$(cat "$W/ci.rc") $(grep -c '"kind": "admit"' "$W/meta-ci/events.jsonl")"
realq now "$GPU" 'models_dir="'"$W"'/no-weights"'
eq "P13-Q: missing weights refuse before inference (never a download)" "3 0" "$(cat "$W/now.rc") $(grep -c '"kind": "admit"' "$W/meta-now/events.jsonl")"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all P13-Q runtime rows passed\n'
