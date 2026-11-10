#!/usr/bin/env bash
# q-index.sh -- build, finalize and seal the local Q master from the S master's survivors (B10).
#
#   q-index.sh --s-master M --s-seal SEAL --config-dir QCFG --qmd QMD --models-dir MD \
#              --vec0 VEC0 --llama-gpu cuda|vulkan --collection name=root [--collection ...] --out DIR [--no-embed]
# (--llama-gpu is the locked QMD_LLAMA_GPU of the Q treatment: never auto, so a backend that
# cannot load fails loudly as a CPU fallback instead of silently picking another device)
#
# 1. the S master's surviving document/file-hash list is the common source manifest;
# 2. the pinned qmd indexes the exports with the locked local-Q config, inside a network
#    namespace with the GPU device nodes bound (no remote URL can be reached, no download);
# 3. every Q row outside the S survivors is pruned, and a survivor missing from Q refuses;
# 4. the Q vectors are embedded locally (timed), unless --no-embed (lightweight fixture builds,
#    whose Q-ready manifest is marked embedded=false and can never pass a runtime check);
# 5. pins.py finalizes and seals the Q master (pinned open, config sync, cache clear, digest);
# 6. q-ready.json records both source-manifest hashes (they must be equal), the separate Q
#    corpus digest, the config identity, every pinned weight file's sha256 and the timings.
# Exit 0 ok, 3 refusal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
smaster='' sseal='' cfg='' qmd='' models='' vec0='' out='' gpumode='' embed=1 colls=()
while [ $# -gt 0 ]; do
  case "$1" in
    --s-master) smaster=$2; shift 2 ;; --s-seal) sseal=$2; shift 2 ;; --config-dir) cfg=$2; shift 2 ;;
    --qmd) qmd=$2; shift 2 ;; --models-dir) models=$2; shift 2 ;; --vec0) vec0=$2; shift 2 ;;
    --collection) colls+=("$2"); shift 2 ;; --out) out=$2; shift 2 ;; --no-embed) embed=0; shift ;;
    --llama-gpu) gpumode=$2; shift 2 ;;
    *) echo "q-index: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$gpumode" in cuda|vulkan) ;; *) echo "q-index: --llama-gpu must be cuda or vulkan" >&2; exit 2 ;; esac
for v in smaster sseal cfg qmd models vec0 out; do [ -n "${!v}" ] || { echo "q-index: --${v} is required" >&2; exit 2; }; done
mkdir -p "$out" || exit 3
python3 -I "$HERE/pins.py" verify "$smaster" --seal "$sseal" >/dev/null || { echo "q-index: refused: the S master does not match its seal" >&2; exit 3; }
if grep -q -E 'openai:|openai_base_url|https?://' "$cfg/eval.yml"; then echo "q-index: refused: the Q config names a remote model or URL" >&2; exit 3; fi
src="$out/source-manifest.json"
python3 -I - "$smaster" "$src" <<'EOF' || exit 3
import hashlib, json, sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
rows = sorted("%s/%s %s" % r for r in c.execute("select collection, path, hash from documents where active=1"))
man = {}
for r in rows:
    key, h = r.rsplit(" ", 1)
    coll, path = key.split("/", 1)
    man.setdefault(coll, {})[path] = {"sha256": h}
json.dump({"documents": rows, "sha256": hashlib.sha256("\n".join(rows).encode()).hexdigest(), "by_collection": man}, open(sys.argv[2], "w"), indent=1)
EOF
gpu=(bwrap --bind / / --dev-bind /dev /dev --proc /proc --unshare-net --die-with-parent)
cache=$(mktemp -d "${TMPDIR:-/tmp}/q-index-cache.XXXXXX") || exit 3  # prim-ok: Linux-only pilot tool (bwrap)
trap 'rm -rf "$cache"' EXIT
mkdir -p "$cache/qmd" && ln -s "$models" "$cache/qmd/models"
build="$out/q-build.sqlite"; master="$out/q-master.sqlite"
rm -f "$build" "$master"
qrun() { "${gpu[@]}" env -i HOME="$cache" PATH="/usr/bin:/bin:$(dirname "$qmd")" QMD_CONFIG_DIR="$cfg" INDEX_PATH="$build" \
  XDG_CACHE_HOME="$cache" QMD_LLAMA_GPU="$gpumode" QMD_RERANK_LOAD_TIMEOUT_MS=480000 "$qmd" --index eval "$@"; }
t0=$(date +%s%3N)  # gnu-ok: Linux-only (bwrap)
qrun update > "$out/q-update.log" 2>&1 || { echo "q-index: refused: Q update failed" >&2; exit 3; }
t1=$(date +%s%3N)  # gnu-ok: Linux-only (bwrap)
ex=()
for c in "${colls[@]}"; do
  name=${c%%=*}
  python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1]))["by_collection"].get(sys.argv[2], {}); json.dump({"files": m, "symlinks": {}}, open(sys.argv[3], "w"))' "$src" "$name" "$out/survivors-$name.json"
  ex+=(--export "$name=$out/survivors-$name.json")
done
python3 -I "$HERE/prune-index.py" "$build" --vec0 "$vec0" "${ex[@]}" > "$out/q-prune.json" || { echo "q-index: refused: Q prune failed" >&2; exit 3; }
python3 -I - "$build" "$src" <<'EOF' || exit 3
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
have = sorted("%s/%s %s" % r for r in c.execute("select collection, path, hash from documents where active=1"))
want = json.load(open(sys.argv[2]))["documents"]
missing = sorted(set(want) - set(have))
if missing:
    sys.exit("q-index: refused: %d S survivor(s) missing from the Q index" % len(missing))
EOF
t2=$t1
if [ "$embed" = 1 ]; then
  qrun embed > "$out/q-embed.log" 2>&1 || { echo "q-index: refused: Q embed failed" >&2; exit 3; }
  if grep -q -E 'running on CPU|GPU init failed|CPU-only|fetch failed|ENETUNREACH' "$out/q-embed.log"; then
    echo "q-index: refused: the Q embed did not run on the locked GPU or tried the network" >&2; exit 3
  fi
  t2=$(date +%s%3N)  # gnu-ok: Linux-only (bwrap)
fi
python3 -I "$HERE/pins.py" snapshot "$build" "$master" || exit 3
expect=()
for c in "${colls[@]}"; do expect+=(--expect-collection "$c"); done
python3 -I "$HERE/pins.py" finalize "$master" --qmd "$qmd" --config-dir "$cfg" "${expect[@]}" --seal "$out/q-master.seal.json" > /dev/null || exit 3
t3=$(date +%s%3N)  # gnu-ok: Linux-only (bwrap)
Q_GPUMODE="$gpumode" python3 -I - "$master" "$src" "$sseal" "$out/q-master.seal.json" "$cfg/eval.yml" "$models" "$out/q-ready.json" "$embed" "$((t1 - t0))" "$((t2 - t1))" "$((t3 - t2))" <<'EOF' || exit 3
import hashlib, json, os, sqlite3, sys
master, src, sseal, qseal, cfg, models, out = sys.argv[1:8]
embedded, build_ms, embed_ms, fin_ms = sys.argv[8] == "1", int(sys.argv[9]), int(sys.argv[10]), int(sys.argv[11])
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
c = sqlite3.connect("file:%s?mode=ro" % master, uri=True)
rows = sorted("%s/%s %s" % r for r in c.execute("select collection, path, hash from documents where active=1"))
qsrc = hashlib.sha256("\n".join(rows).encode()).hexdigest()
ssrc = json.load(open(src))["sha256"]
if qsrc != ssrc:
    sys.exit("q-index: refused: the Q source manifest differs from the S survivors")
vectors = c.execute("select count(*) from vector_rows").fetchone()[0]
q, s = json.load(open(qseal)), json.load(open(sseal))
weights = {n: sha(os.path.join(models, n)) for n in sorted(os.listdir(models)) if n.endswith(".gguf")}
ready = {"schema": "rag-pilot-q-ready/1", "llama_gpu": os.environ.get("Q_GPUMODE"), "s_source_manifest_sha256": ssrc, "q_source_manifest_sha256": qsrc,
         "s_digest": s["digest"], "q_digest": q["digest"], "digest_schema": q["digest_schema"],
         "config_sha256": sha(cfg), "config_hash": q["config_hash"], "weights": weights, "embedded": embedded,
         "vector_rows": vectors, "build_ms": build_ms, "embed_ms": embed_ms, "finalize_ms": fin_ms}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(ready, f, indent=1, sort_keys=True)
EOF
rm -f "$build"
echo "q-index: sealed $master"
