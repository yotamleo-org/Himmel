#!/usr/bin/env bash
# test-s-tools.sh -- B2 of the RAG pilot: the shared S/Q tools (s-qmd, s-graph, the note), the
# two locked qmd configs, the N2-r config preflight, the runtime/output contract, the shared
# skip classifier and evidence integrity. Unbilled: most rows drive s-qmd against a fake qmd
# (fixtures/s-tools/fake-qmd); the P13-S rows run the REAL pinned qmd hybrid query against
# the local stub endpoint inside a network namespace. No model, no network, no real key.
# Hosts without the pinned qmd (its config loader) or bwrap SKIP those rows loudly.
#
# Platform guard: Linux bash (SO_PEERCRED, bwrap network namespaces).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/tools"
FX="$HERE/fixtures/s-tools"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-stools.XXXXXX")" || exit 1
BROKERS=()
cleanup() { for p in "${BROKERS[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1 ('$2' present)" ;; *) pass "$1" ;; esac; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

eq "note: the shared retrieval note is exactly three lines" 3 "$(wc -l < "$T/s-note.md" | tr -d ' ')"

QMD="${PILOT_QMD:-$(command -v qmd || true)}"
if [ -z "$QMD" ] || ! command -v node >/dev/null 2>&1; then
  printf 'SKIP - every s-qmd row: the pinned qmd config loader (qmd + node) is absent on this host\n'
  [ "$fails" -gt 0 ] && exit 1
  exit 0
fi
QPKG="$(cd "$(dirname "$(readlink -f "$QMD")")/.." && pwd)"  # gnu-ok: Linux-only suite
QDIST="$QPKG/dist"

# --- exports and fixtures
H="$W/src-himmel"; mkdir -p "$H/docs" "$H/bin"
printf '# Lock\nThe queue lock keeps one session per handover doc.\n' > "$H/docs/lock.md"
printf '# Zeta\nThe zeta rule is settled.\n' > "$H/docs/zeta.md"
printf '#!/bin/sh\nrelay_batch() { :; }\n' > "$H/bin/run.sh"
git -C "$H" init -q && gitc "$H" add -A && gitc "$H" commit -q -m h0
H0=$(git -C "$H" rev-parse HEAD)
L="$W/src-luna"; mkdir -p "$L/notes"; printf '# Garden\nWater on Tuesdays.\n' > "$L/notes/garden.md"
git -C "$L" init -q && gitc "$L" add -A && gitc "$L" commit -q -m l0
bash "$HERE/export-copies.sh" "$H" "$H0" "$W/work/himmel" "$W/himmel.json" >/dev/null 2>&1
bash "$HERE/export-copies.sh" "$L" "$(git -C "$L" rev-parse HEAD)" "$W/work/luna" "$W/luna.json" >/dev/null 2>&1
mkdir -p "$W/fakebin" "$W/cfg-s" "$W/cfg-q" "$W/idx" "$W/models" "$W/graph"
cp "$FX/fake-qmd" "$W/fakebin/qmd"; chmod +x "$W/fakebin/qmd"; printf 'ok\n' > "$W/fakebin/mode"
sed -e "s#@HIMMEL@#$W/work/himmel#" -e "s#@LUNA@#$W/work/luna#" "$HERE/fixtures/pins/eval.yml.in" > "$W/cfg-s/eval.yml"
sed -e "s#/work/himmel#$W/work/himmel#" -e "s#/work/luna#$W/work/luna#" "$T/qmd-eval-q.yml" > "$W/cfg-q/eval.yml"
: > "$W/idx/eval.sqlite"; : > "$W/master.sqlite"; chmod 444 "$W/master.sqlite"; : > "$W/live.sqlite"
for w in hf_ggml-org_embeddinggemma-300M-Q8_0.gguf hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf; do printf 'w\n' > "$W/models/$w"; done
printf 'fixture-key-1\n' > "$W/key"; chmod 600 "$W/key"
sed "s/@H0@/$H0/" "$FX/graph.json" > "$W/graph/graph.json"

cfg_id() { # <config dir> -> "<config_hash> <bytes sha256>" from the pinned loader
  python3 -I - "$HERE/pins.py" "$QDIST" "$1" <<'EOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("pins", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
h, _, b = m.load_config(sys.argv[2], sys.argv[3]); print(h, b)
EOF
}
read -r SH SB <<<"$(cfg_id "$W/cfg-s")"
read -r QH QB <<<"$(cfg_id "$W/cfg-q")"

bind() { # <out> <S|Q> [key=json]...  -- the trusted launcher's binding, with overrides
  python3 -I - "$@" <<EOF
import hashlib, json, sys
out, arm = sys.argv[1], sys.argv[2]
b = {"arm": arm, "qmd": "$W/fakebin/qmd", "qmd_dist": "$QDIST", "node": "$(command -v node)",
     "preflight": "$T/config-preflight.mjs", "child_path": "/usr/bin:/bin",
     "index": "$W/idx/eval.sqlite", "forbidden_targets": ["$W/master.sqlite", "$W/live.sqlite"],
     "collections": {"himmel": "$W/work/himmel", "luna": "$W/work/luna"},
     "manifests": {"himmel": "$W/himmel.json", "luna": "$W/luna.json"},
     "graph": "$W/graph/graph.json", "graph_root": "$W/graph", "h0": "$H0",
     "env": {}, "deadline_term_ms": 800, "deadline_kill_ms": 1600}
if arm == "S":
    b.update({"config_dir": "$W/cfg-s", "config_sha256": "$SB", "config_hash": "$SH", "base_url": "http://127.0.0.1:18080/v1",
              "models": {"embed": "openai:stub-embed", "generate": "openai:stub-gen", "rerank": "openai:stub-rerank"},
              "key_file": "$W/key", "key_fingerprint": hashlib.sha256(open("$W/key", "rb").read()).hexdigest()})
else:
    b.update({"config_dir": "$W/cfg-q", "config_sha256": "$QB", "config_hash": "$QH", "models_dir": "$W/models",
              "models": {"embed": "hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf",
                         "generate": "hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf",
                         "rerank": "hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf"},
              "required_weights": ["hf_ggml-org_embeddinggemma-300M-Q8_0.gguf", "hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf",
                                   "hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf"]})
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    b[k] = json.loads(v)
b["socket"] = b.get("socket", "$W/b.sock")
json.dump(b, open(out, "w"), indent=1)
EOF
}
broker() { # <name> <arm> [serve args]... -- a fresh host broker; socket $W/<name>.sock, meta $W/meta-<name>
  "$T/s-qmd" serve --socket "$W/$1.sock" --meta "$W/meta-$1" --phase answer --arm "$2" "${@:3}" &
  BROKERS+=($!)
  for _ in $(seq 100); do [ -S "$W/$1.sock" ] && break; sleep 0.02; done
}
summ() { "$T/s-qmd" summary --meta "$W/meta-$1" --socket "$W/$1.sock"; }
calls() { [ -f "$W/fakebin/calls.log" ] && wc -l < "$W/fakebin/calls.log" | tr -d ' ' || echo 0; }
sq() { PILOT_BINDING="$1" "$T/s-qmd" "${@:2}"; }
field() { python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())[sys.argv[1]]))' "$1"; }

# --- the fixed-env baseline and the pin filter
broker base S; bind "$W/b-base.json" S 'socket="'"$W"'/base.sock"'
out=$(sq "$W/b-base.json" "queue lock"); rc=$?
eq "s-qmd: a bound S call succeeds" 0 "$rc"
has "s-qmd: hits are copy-relative paths under the pinned export" "$W/work/himmel/docs/lock.md:2  Lock" "$out"
printf 'postpin\n' > "$W/fakebin/mode"
out=$(sq "$W/b-base.json" "queue lock")
hasnt "pin filter: a post-pin hit never reaches the agent" "postpin" "$out"
hasnt "pin filter: a handovers hit never reaches the agent" "handovers" "$out"
eq "pin filter: both dropped hits are counted privately" 2 "$(summ base | field dropped)"
printf 'ok\n' > "$W/fakebin/mode"

# --- targets refuse before any query or booking
n0=$(calls)
for t in master live; do
  broker "tgt-$t" S; bind "$W/b-t.json" S 'socket="'"$W"'/tgt-'"$t"'.sock"' 'index="'"$W/$t.sqlite"'"'
  sq "$W/b-t.json" "queue lock" >/dev/null 2>&1; rc=$?
  eq "target: the $t index refuses before admission" "3 0" "$rc $(summ "tgt-$t" | field admitted)"
done
cp "$W/idx/eval.sqlite" "$W/ro.sqlite"; chmod 444 "$W/ro.sqlite"
broker tgt-ro S; bind "$W/b-t.json" S 'socket="'"$W"'/tgt-ro.sock"' 'index="'"$W/ro.sqlite"'"'
sq "$W/b-t.json" "queue lock" >/dev/null 2>&1; rc=$?
eq "target: a read-only index refuses before admission" "3 0" "$rc $(summ tgt-ro | field admitted)"
eq "target: no qmd process ran for any refused target" "$n0" "$(calls)"
has "target: the refusal is an integrity event" "pre_admission_refusal" "$(summ tgt-ro)"

# --- the per-task cap
broker cap S; bind "$W/b-cap.json" S 'socket="'"$W"'/cap.sock"'
n0=$(calls); ok=0
for i in $(seq 12); do sq "$W/b-cap.json" "q $i" >/dev/null 2>&1 && ok=$((ok + 1)); done
err=$(sq "$W/b-cap.json" "q 13" 2>&1 >/dev/null); rc=$?
eq "cap: twelve queries are admitted" 12 "$ok"
eq "cap: the thirteenth refuses" 3 "$rc"
has "cap: the refusal says so" "query limit reached (12 per task)" "$err"
eq "cap: the thirteenth started no qmd process" $((n0 + 12)) "$(calls)"
eq "cap: the host counter holds 12 admitted, 1 refused" "12 1" "$(summ cap | field admitted) $(summ cap | field cap_refused)"

# --- N2-r: wrong/missing config or altered environment stops before qmd and zero bookings
n2() { # <label> <arm> [binding overrides]...
  broker n2 "$2"; bind "$W/b-n2.json" "$2" 'socket="'"$W"'/n2.sock"' "${@:3}"
  local n0; n0=$(calls)
  sq "$W/b-n2.json" "queue lock" >/dev/null 2>&1; local rc=$?
  eq "preflight: $1 refuses before qmd with zero bookings" "3 0 $n0" "$rc $(summ n2 | field admitted) $(calls)"
  kill "${BROKERS[-1]}" 2>/dev/null; rm -rf "$W/meta-n2"
}
mkdir -p "$W/cfg-none" "$W/cfg-empty" "$W/cfg-key" "$W/cfg-norerank"
: > "$W/cfg-empty/eval.yml"
sed 's#^models:#models:\n  openai_api_key: ""#' "$W/cfg-s/eval.yml" > "$W/cfg-key/eval.yml"
grep -v '^  rerank:' "$W/cfg-s/eval.yml" > "$W/cfg-norerank/eval.yml"
n2 "a missing config" S 'config_dir="'"$W"'/cfg-none"'
n2 "an empty config" S 'config_dir="'"$W"'/cfg-empty"' 'config_sha256="'"$(sha256sum "$W/cfg-empty/eval.yml" | cut -d' ' -f1)"'"'
n2 "a credential-bearing config (empty key field)" S 'config_dir="'"$W"'/cfg-key"' 'config_sha256="'"$(sha256sum "$W/cfg-key/eval.yml" | cut -d' ' -f1)"'"'
n2 "a config missing models.rerank" S 'config_dir="'"$W"'/cfg-norerank"' 'config_sha256="'"$(sha256sum "$W/cfg-norerank/eval.yml" | cut -d' ' -f1)"'"'
n2 "a config byte-hash mismatch" S 'config_sha256="0000"'
n2 "a sealed config-hash mismatch" S 'config_hash="0000"'
n2 "a model-override variable in the child environment" S 'env={"QMD_RERANK_MODEL": "openai:other"}'
n2 "a rotated private key binding" S 'key_fingerprint="0000"'
n2 "a Q config naming a remote endpoint" Q 'config_dir="'"$W"'/cfg-s"' 'config_sha256="'"$SB"'"' 'config_hash="'"$SH"'"' \
  'models={"embed": "openai:stub-embed", "generate": "openai:stub-gen", "rerank": "openai:stub-rerank"}'
n2 "CI=true reaching the Q child" Q 'env={"CI": "true"}'
n2 "missing Q weights" Q 'models_dir="'"$W"'/no-models"'
n2 "a key file bound to the Q arm" Q 'key_file="'"$W"'/key"'

# --- scrubbed key/config variables come back only from the trusted wrapper
broker env S; bind "$W/b-env.json" S 'socket="'"$W"'/env.sock"'
mkdir -p "$W/proj/.qmd"; printf 'collections:\n  other:\n    path: /etc\n' > "$W/proj/.qmd/index.yml"
( cd "$W/proj" && QMD_CONFIG_DIR=/nonexistent QMD_OPENAI_API_KEY=ambient-junk QMD_EMBED_MODEL=x sq "$W/b-env.json" "queue lock" >/dev/null 2>&1 )
last=$(tail -1 "$W/fakebin/calls.log")
eq "env: the S child gets the bound key from the key file, never the ambient one" '"fixture-key-1"' "$(printf '%s' "$last" | field key)"
eq "env: the child environment is the allowlist only" '["HOME", "INDEX_PATH", "LANG", "PATH", "QMD_CONFIG_DIR", "QMD_OPENAI_API_KEY", "XDG_CACHE_HOME"]' "$(printf '%s' "$last" | field env)"
has "env: the child is pinned to the explicit index" '"--index", "eval"' "$(printf '%s' "$last" | field argv)"
hasnt "env: a project-local .qmd directory is not the child's cwd" "$W/proj" "$(printf '%s' "$last" | field cwd)"
broker envq Q; bind "$W/b-envq.json" Q 'socket="'"$W"'/envq.sock"'
QMD_OPENAI_API_KEY=ambient-junk sq "$W/b-envq.json" "queue lock" >/dev/null 2>&1
eq "env: the Q child never receives a key" '""' "$(tail -1 "$W/fakebin/calls.log" | field key)"

# --- the shared S/Q classifier on the private evidence
mode() { # <mode> <arm> [serve args]... -> summary JSON; agent stdout in $W/agent.out, stderr in $W/agent.err
  printf '%s\n' "$1" > "$W/fakebin/mode"
  broker "m" "$2" "${@:3}"; bind "$W/b-m.json" "$2" 'socket="'"$W"'/m.sock"'
  sq "$W/b-m.json" "queue lock" >"$W/agent.out" 2>"$W/agent.err"; echo $? > "$W/agent.rc"
  summ m; kill "${BROKERS[-1]}" 2>/dev/null; rm -rf "$W/meta-m"
}
reasons() { mode "$@" | field skip_reasons; }
eq "classify: a clean result is no skip" '[]' "$(reasons ok S)"
eq "classify: quoted markers inside a hit snippet are not diagnostics" '[]' "$(reasons ok-quoted-marker S)"
eq "classify: an empty result is route behaviour, not a skip" '[]' "$(reasons empty S)"
eq "classify: the empty result prints the common no-results line" "s-qmd: no results" "$(cat "$W/agent.out")"
eq "classify: the expansion-failure stderr marker is a skip" '["expansion_failed"]' "$(reasons expand-fail S)"
eq "classify: the marker concatenated to progress text is a skip" '["expansion_failed"]' "$(reasons expand-fail-progress S)"
eq "classify: the zero-row embedding-service diagnostic is a skip" '["embedding_unanswered"]' "$(reasons embed-down-empty S)"
s=$(mode raw-only S)
eq "classify: a raw-query-only expansion tree is treatment behaviour, not a skip" '[] 1' "$(printf '%s' "$s" | field skip_reasons) $(printf '%s' "$s" | field raw_query_only)"
s=$(mode strong-bm25 S)
eq "classify: the strong-BM25 expansion skip is normal behaviour" '[] 0' "$(printf '%s' "$s" | field skip_reasons) $(printf '%s' "$s" | field raw_query_only)"
eq "classify: embedSkipped is a skip" '["flag:embedSkipped"]' "$(reasons flag-embed S)"
eq "classify: rerankSkipped is a skip" '["flag:rerankSkipped"]' "$(reasons flag-rerank S)"
eq "classify: rerankTimedOut is a skip" '["flag:rerankTimedOut"]' "$(reasons flag-rerank-timeout S)"
eq "classify: a non-zero qmd exit is a skip" '["qmd_exit_1"]' "$(reasons exit1 S)"
eq "classify: the failed call shows the agent one common error line" "1 s-qmd: search failed; try again or use grep" "$(cat "$W/agent.rc") $(cat "$W/agent.err")"
t0=$(date +%s)
eq "classify: a qmd that outlives the TERM deadline is a timeout skip" '["timeout"]' "$(reasons hang S)"
eq "classify: a qmd that ignores TERM is killed at the KILL deadline, still a timeout skip" '["timeout"]' "$(reasons hang-ignore-term S)"
eq "classify: both deadline rows finished within the deadlines" "yes" "$([ $(( $(date +%s) - t0 )) -lt 10 ] && echo yes || echo no)"
eq "classify: unparseable stdout (missing terminal JSON) is a skip" '["invalid_terminal_json"]' "$(reasons bad-json S)"
eq "classify: a Q CPU fallback is a skip" '["q_cpu_fallback"]' "$(reasons cpu-fallback Q)"
eq "classify: a blocked Q remote attempt is a skip" '["expansion_failed", "q_remote_attempt"]' "$(reasons remote-blocked Q)"
eq "classify: Q GPU memory on the admitted qmd child is positive evidence" '[]' "$(reasons ok-slow Q --nvml-cmd "$FX/nvml-fake qmd")"
eq "classify: another process's GPU memory never counts for the Q child" '["q_no_gpu_evidence"]' "$(reasons ok-slow Q --nvml-cmd "$FX/nvml-fake self")"
mode ok S >/dev/null; cp "$W/agent.out" "$W/agent-s.out"; mode ok Q >/dev/null
eq "output: S and Q print byte-identical agent output for the same hits" "same" "$(cmp -s "$W/agent-s.out" "$W/agent.out" && echo same || echo differ)"
for m in ok expand-fail cpu-fallback strong-bm25; do
  mode "$m" Q >/dev/null; all="$(cat "$W/agent.out" "$W/agent.err")"
  for bad in openai: hf: Expanding GPU Reranking Embedding stub; do hasnt "output: no '$bad' reaches the agent ($m)" "$bad" "$all"; done
done
printf 'ok\n' > "$W/fakebin/mode"

# --- evidence integrity: the host owns phase, ids and counters
client() { # <sock> <argv0> <json line>... -- a hand-rolled client speaking to the broker
  python3 -I - "$@" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rwb")
for m in sys.argv[3:]:
    f.write(m.encode() + b"\n"); f.flush(); f.readline()
EOF
}
broker int S
client "$W/int.sock" x '{"op": "admit", "query_sha256": "x", "phase": "probe", "counter": 0}'
has "integrity: a forged phase/counter is an integrity event" "forged_field" "$(summ int)"
eq "integrity: a forged admit is never counted" 0 "$(summ int | field admitted)"
broker int2 S; client "$W/int2.sock" x '{"op": "admit", "query_sha256": "x"}'
has "integrity: an admit from a process that is not the wrapper is an integrity event" "unattributed_peer" "$(summ int2)"
broker int3 S; ( exec -a s-qmd python3 -I - "$W/int3.sock" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rwb")
f.write(b'{"op": "terminal", "id": "answer-01-abcdef", "rc": 0}\n'); f.flush(); f.readline()
EOF
)
has "integrity: a terminal record on a connection that was never admitted is refused" "unbound_terminal" "$(summ int3)"
broker int4 S
python3 -I -c 'import os,socket,sys; os.unlink(sys.argv[1]); s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$W/int4.sock"
has "integrity: a replaced channel endpoint is detected" "channel_replaced" "$(summ int4)"
broker kill S; bind "$W/b-kill.json" S 'socket="'"$W"'/kill.sock"' 'deadline_term_ms=30000' 'deadline_kill_ms=31000'
printf 'hang\n' > "$W/fakebin/mode"
PILOT_BINDING="$W/b-kill.json" "$T/s-qmd" "queue lock" >/dev/null 2>&1 &
wp=$!
for _ in $(seq 100); do pgrep -f 'fakebin/qmd' >/dev/null && break; sleep 0.05; done
kill -9 "$wp"; wait "$wp" 2>/dev/null; sleep 0.5
s=$(summ kill)
eq "integrity: a killed wrapper leaves a missing-terminal skip, not an integrity abort" '["missing_terminal"] []' "$(printf '%s' "$s" | field skip_reasons) $(printf '%s' "$s" | field integrity)"
eq "integrity: the killed wrapper's qmd child did not outlive it" 0 "$(pgrep -fc 'fakebin/qmd')"
printf 'ok\n' > "$W/fakebin/mode"

# --- s-graph: the frozen H0 graph, export nodes only
bind "$W/b-g.json" S
out=$(PILOT_BINDING="$W/b-g.json" "$T/s-graph" relay_batch)
has "s-graph: finds the symbol with its export path" "relay_batch()  $W/work/himmel/bin/run.sh:2" "$out"
has "s-graph: lists an in-export neighbour" "documented_by Queue lock doc" "$out"
hasnt "s-graph: a node outside the export never prints" "secret" "$out"
mkdir -p "$W/other"; cp "$W/graph/graph.json" "$W/other/graph.json"
bind "$W/b-g2.json" S 'graph="'"$W"'/other/graph.json"'
PILOT_BINDING="$W/b-g2.json" "$T/s-graph" relay_batch >/dev/null 2>&1
eq "s-graph: a graph outside the pinned copy refuses" 3 "$?"
bind "$W/b-g3.json" S 'h0="0000000"'
PILOT_BINDING="$W/b-g3.json" "$T/s-graph" relay_batch >/dev/null 2>&1
eq "s-graph: a graph not built at H0 refuses" 3 "$?"

# --- P13-S: the real pinned qmd hybrid command, local stub endpoints, no network
if ! command -v bwrap >/dev/null 2>&1 || ! bwrap --bind / / --unshare-net true 2>/dev/null; then
  printf 'SKIP - P13-S real-qmd rows: no unprivileged bwrap network namespace on this host\n'
else
  NETNS="$HERE/fixtures/pins/netns-run.sh"
  qrun() { ( cd "$W" && bash "$NETNS" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$W/cfg-s" INDEX_PATH="$1" XDG_CACHE_HOME="$W/cache" "$QMD" --index eval "${@:2}" ) >/dev/null 2>&1; }
  qrun "$W/build.sqlite" update; qrun "$W/build.sqlite" embed
  python3 -I "$HERE/pins.py" snapshot "$W/build.sqlite" "$W/real-master.sqlite"
  python3 -I "$HERE/pins.py" finalize "$W/real-master.sqlite" --qmd "$QMD" --config-dir "$W/cfg-s" --expect-collection himmel="$W/work/himmel" --seal "$W/real.seal.json" >/dev/null
  eq "P13-S: the fixture master finalized and sealed" "yes" "$([ -f "$W/real.seal.json" ] && echo yes || echo no)"
  real() { # <name> [STUB_MODE] -> runs the real s-qmd path on a fresh disposable copy inside the stub namespace
    python3 -I "$HERE/pins.py" disposable "$W/real-master.sqlite" "$W/$1.sqlite" --seal "$W/real.seal.json" >/dev/null
    broker "$1" S; bind "$W/b-$1.json" S 'socket="'"$W/$1"'.sock"' 'qmd="'"$QMD"'"' 'index="'"$W/$1.sqlite"'"' \
      'forbidden_targets=["'"$W"'/real-master.sqlite"]' 'child_path="/usr/bin:/bin:'"$(dirname "$QMD")"'"' 'deadline_term_ms=120000' 'deadline_kill_ms=125000'
    : > "$W/stub.log"
    ( cd "$W/proj" && STUB_MODE="${2:-}" PILOT_BINDING="$W/b-$1.json" bash "$NETNS" "$W" "$T/s-qmd" "queue lock session" ) >"$W/$1.out" 2>"$W/$1.err"
  }
  real r1
  has "P13-S: the real hybrid query returns the lock note through the wrapper" "$W/work/himmel/docs/lock.md" "$(cat "$W/r1.out")"
  s=$(summ r1)
  eq "P13-S: the real call is skip-free with a real (non-fallback) expansion" '[] 0' "$(printf '%s' "$s" | field skip_reasons) $(printf '%s' "$s" | field raw_query_only)"
  eq "P13-S: the stub saw the bound key on every request (injected by the wrapper only)" "yes" "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; print("yes" if r and all(x["auth"] for x in r) else "no")' "$W/stub.log")"
  eq "P13-S: expansion/rerank cache rows were written to the disposable copy" "yes" "$([ "$(sqlite3 "$W/r1.sqlite" 'select count(*) from llm_cache')" -gt 0 ] && echo yes || echo no)"
  eq "P13-S: the corpus digest still passes after the query" 0 "$(python3 -I "$HERE/pins.py" verify "$W/r1.sqlite" --seal "$W/real.seal.json" >/dev/null 2>&1; echo $?)"
  sqlite3 "$W/r1.sqlite" "update documents set title='Tampered' where path='docs/lock.md'"
  eq "P13-S: a documents mutation then fails the lock" 3 "$(python3 -I "$HERE/pins.py" verify "$W/r1.sqlite" --seal "$W/real.seal.json" >/dev/null 2>&1; echo $?)"
  real r2 expand-fail
  eq "P13-S: the real expansion-failure stderr is classified as a skip" '["expansion_failed"]' "$(summ r2 | field skip_reasons)"
  real r3 embed-down
  eq "P13-S: the real embedding-service diagnostic and its result flag are both a skip" '["embedding_unanswered", "flag:embedSkipped"]' "$(summ r3 | field skip_reasons)"
  real r4 expand-empty
  s=$(summ r4)
  eq "P13-S: the real empty-reply fallback is recorded raw-query-only, not a skip" '[] 1' "$(printf '%s' "$s" | field skip_reasons) $(printf '%s' "$s" | field raw_query_only)"
  eq "P13-S: the sealed master is untouched by every real row" 0 "$(python3 -I "$HERE/pins.py" verify "$W/real-master.sqlite" --seal "$W/real.seal.json" >/dev/null 2>&1; echo $?)"
fi

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all s-tools rows passed\n'
