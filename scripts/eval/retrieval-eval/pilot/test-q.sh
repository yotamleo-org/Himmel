#!/usr/bin/env bash
# test-q.sh -- B10 of the RAG pilot, lightweight: the Q master built from the S survivors
# (q-index.sh --no-embed), the Q readiness checks (q-lists.py check) and the matched S/Q fixed
# lists (matched-lists.py) on a synthetic 40-task fixture world. The lists run through the real
# s-qmd wrapper and broker against a fake qmd (fixtures/q/fake-qmd-lists): no model, no network,
# no key. S mode is exercised only for its refusal and through the library with the fixture
# booking adapter; HIMMEL_BILLED_OK is never set. The real-weights proof is test-q-runtime.sh.
#
# Platform guard: Linux bash (bwrap, SO_PEERCRED); SKIPs loudly without the pinned qmd.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/tools"
ML="$HERE/matched-lists.py"
QL="$HERE/q-lists.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-q.XXXXXX")" || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
jget() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(json.dumps(v))' "$1" "$2"; }

QMD="${PILOT_QMD:-$(command -v qmd || true)}"
if [ -z "$QMD" ] || ! command -v node >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1 || ! bwrap --bind / / --unshare-net true 2>/dev/null; then
  printf 'SKIP - every Q row: the pinned qmd, node or an unprivileged bwrap network namespace is absent on this host\n'
  exit 0
fi
QPKG="$(cd "$(dirname "$(readlink -f "$QMD")")/.." && pwd)"  # gnu-ok: Linux-only suite
QDIST="$QPKG/dist"; VEC0="$QPKG/node_modules/sqlite-vec-linux-x64/vec0.so"
NETNS="$HERE/fixtures/pins/netns-run.sh"

python3 -I "$HERE/fixtures/q/build.py" "$W/fx"
for r in himmel luna; do
  git -C "$W/fx/src-$r" init -q && gitc "$W/fx/src-$r" add -A && gitc "$W/fx/src-$r" commit -q -m pin
  bash "$HERE/export-copies.sh" "$W/fx/src-$r" HEAD "$W/work/$r" "$W/$r.json" >/dev/null 2>&1
done
mkdir -p "$W/cfg-s" "$W/cfg-q" "$W/models" "$W/fakebin" "$W/cache"
sed -e "s#@HIMMEL@#$W/work/himmel#" -e "s#@LUNA@#$W/work/luna#" "$HERE/fixtures/pins/eval.yml.in" > "$W/cfg-s/eval.yml"
sed -e "s#/work/himmel#$W/work/himmel#" -e "s#/work/luna#$W/work/luna#" "$T/qmd-eval-q.yml" > "$W/cfg-q/eval.yml"
for w in hf_ggml-org_embeddinggemma-300M-Q8_0.gguf hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf; do printf 'fixture weight %s\n' "$w" > "$W/models/$w"; done
cp "$HERE/fixtures/q/fake-qmd-lists" "$W/fakebin/qmd"; chmod +x "$W/fakebin/qmd"; cp "$W/fx/hits.json" "$W/fakebin/"

( cd "$W" && bash "$NETNS" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$W/cfg-s" INDEX_PATH="$W/s-build.sqlite" XDG_CACHE_HOME="$W/cache" "$QMD" --index eval update ) >/dev/null 2>&1
python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); m["files"].pop("docs/unrelated.md"); json.dump(m, open(sys.argv[2],"w"))' "$W/himmel.json" "$W/himmel-s.json"
python3 -I "$HERE/pins.py" snapshot "$W/s-build.sqlite" "$W/s-master.sqlite"
python3 -I "$HERE/prune-index.py" "$W/s-master.sqlite" --vec0 "$VEC0" --export himmel="$W/himmel-s.json" --export luna="$W/luna.json" >/dev/null
python3 -I "$HERE/pins.py" finalize "$W/s-master.sqlite" --qmd "$QMD" --config-dir "$W/cfg-s" --expect-collection himmel="$W/work/himmel" --expect-collection luna="$W/work/luna" --seal "$W/s.seal.json" >/dev/null
eq "S master: sealed with the fixture survivors" "yes" "$([ -f "$W/s.seal.json" ] && echo yes || echo no)"

QI=(--s-master "$W/s-master.sqlite" --s-seal "$W/s.seal.json" --qmd "$QMD" --models-dir "$W/models" --vec0 "$VEC0"
    --collection himmel="$W/work/himmel" --collection luna="$W/work/luna" --llama-gpu vulkan --no-embed)
bash "$HERE/q-index.sh" "${QI[@]}" --config-dir "$W/cfg-q" --out "$W/q" > "$W/qi.out" 2>&1
eq "q-index: the fixture Q master builds and seals" 0 "$?"
R="$W/q/q-ready.json"
eq "q-index: the Q source manifest equals the S survivors" true "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r["q_source_manifest_sha256"]==r["s_source_manifest_sha256"]))' "$R")"
eq "q-index: the Q-only export doc was pruned from the Q index" 1 "$(jget "$W/q/q-prune.json" documents)"
eq "q-index: the per-backend corpus digests are recorded apart" true "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(bool(r["q_digest"]) and r["q_digest"]!=r["s_digest"]))' "$R")"
eq "q-index: a fixture build is marked embedded=false" false "$(jget "$R" embedded)"
mkdir -p "$W/cfg-remote"; sed 's#^models:#models:\n  openai_base_url: http://127.0.0.1:18080/v1#' "$W/cfg-q/eval.yml" > "$W/cfg-remote/eval.yml"
bash "$HERE/q-index.sh" "${QI[@]}" --config-dir "$W/cfg-remote" --out "$W/q-remote" >/dev/null 2>&1
eq "q-index: a Q config naming a remote URL refuses" 3 "$?"

QC=(check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q" --models-dir "$W/models")
eq "check: the fresh Q master passes" 0 "$(python3 -I "$QL" "${QC[@]}" >/dev/null 2>&1; echo $?)"
eq "check: --runtime refuses a fixture build without vectors" 3 "$(python3 -I "$QL" "${QC[@]}" --runtime >/dev/null 2>&1; echo $?)"
mkdir -p "$W/cfg-q2"; sed 's#embeddinggemma-300M-Q8_0.gguf$#embeddinggemma-300M-Q4_0.gguf#' "$W/cfg-q/eval.yml" > "$W/cfg-q2/eval.yml"
eq "check: a wrong Q model refuses" 3 "$(python3 -I "$QL" check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q2" --models-dir "$W/models" >/dev/null 2>&1; echo $?)"
eq "check: a remote URL in the Q config refuses" 3 "$(python3 -I "$QL" check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-remote" --models-dir "$W/models" >/dev/null 2>&1; echo $?)"
python3 -I "$HERE/pins.py" disposable "$W/q/q-master.sqlite" "$W/qcopy.sqlite" --seal "$W/q/q-master.seal.json" >/dev/null
sqlite3 "$W/qcopy.sqlite" "update documents set title='x' where id=1"
eq "check: a changed Q digest on a disposable copy refuses" 3 "$(python3 -I "$QL" "${QC[@]}" --copy "$W/qcopy.sqlite" >/dev/null 2>&1; echo $?)"
cp -r "$W/models" "$W/models2"; printf 'swapped\n' >> "$W/models2/hf_ggml-org_qwen3-reranker-0.6b-q8_0.gguf"
eq "check: a changed pinned weight refuses" 3 "$(python3 -I "$QL" check --ready "$R" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q" --models-dir "$W/models2" >/dev/null 2>&1; echo $?)"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["q_source_manifest_sha256"]="0"*64; json.dump(r, open(sys.argv[2],"w"))' "$R" "$W/q-ready-extra.json"
eq "check: a Q-ready source manifest with an extra Q-only doc refuses" 3 "$(python3 -I "$QL" check --ready "$W/q-ready-extra.json" --master "$W/q/q-master.sqlite" --config-dir "$W/cfg-q" --models-dir "$W/models" >/dev/null 2>&1; echo $?)"

python3 -I - "$W" "$T" "$QDIST" "$R" <<'EOF'
import hashlib, importlib.util, json, sys
W, T, QDIST, R = sys.argv[1:5]
s = importlib.util.spec_from_file_location("pins", T + "/../pins.py"); pins = importlib.util.module_from_spec(s); s.loader.exec_module(pins)
ready = json.load(open(R))
src = json.load(open(W + "/q/source-manifest.json"))["sha256"]
common = {"qmd": W + "/fakebin/qmd", "qmd_dist": QDIST, "node": "node", "preflight": T + "/config-preflight.mjs",
          "child_path": "/usr/bin:/bin", "forbidden_targets": [W + "/s-master.sqlite", W + "/q/q-master.sqlite"],
          "collections": {"himmel": W + "/work/himmel", "luna": W + "/work/luna"},
          "manifests": {"himmel": W + "/himmel.json", "luna": W + "/luna.json"}, "env": {},
          "deadline_term_ms": 20000, "deadline_kill_ms": 21000}
for mode, cfg, master, seal in (("S", "cfg-s", W + "/s-master.sqlite", W + "/s.seal.json"), ("Q", "cfg-q", W + "/q/q-master.sqlite", W + "/q/q-master.seal.json")):
    h, _, b = pins.load_config(QDIST, W + "/" + cfg)
    bind = dict(common, config_dir=W + "/" + cfg, config_sha256=b, config_hash=h)
    if mode == "S":
        bind.update(base_url="http://127.0.0.1:18080/v1", key_file=W + "/key", key_fingerprint=hashlib.sha256(b"fixture-key\n").hexdigest(),
                    models={"embed": "openai:stub-embed", "generate": "openai:stub-gen", "rerank": "openai:stub-rerank"})
        open(W + "/key", "w").write("fixture-key\n")
    else:
        bind.update(models_dir=W + "/models", required_weights=sorted(ready["weights"]),
                    models={"embed": "hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf",
                            "generate": "hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf",
                            "rerank": "hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf"})
    ctx = {"master": master, "seal": seal, "tools": T, "binding": bind, "collections": common["collections"], "work": W,
           "corpus_digest": json.load(open(seal))["digest"], "source_manifest_sha256": ready["q_source_manifest_sha256"] if mode == "Q" else src}
    json.dump(ctx, open("%s/ctx-%s.json" % (W, mode), "w"))
EOF
python3 -I "$ML" run --bank "$W/fx/bank.jsonl" --mode Q --ctx "$W/ctx-Q.json" --out "$W/q.jsonl" > "$W/qrun.out" 2>&1
eq "lists: Q mode runs locally without any opt-in" 0 "$?"
eq "lists: Q gives each of the 40 tasks exactly one fixed query" "40 40" "$(wc -l < "$W/q.jsonl" | tr -d ' ') $(wc -l < "$W/fakebin/calls.log" | tr -d ' ')"
eq "lists: the Q child never received a key" 0 "$(grep -c '"key": true' "$W/fakebin/calls.log")"
n0=$(wc -l < "$W/fakebin/calls.log" | tr -d ' ')
python3 -I "$ML" run --bank "$W/fx/bank.jsonl" --mode S --ctx "$W/ctx-S.json" --out "$W/s-refused.jsonl" > "$W/srefuse.out" 2>&1
eq "lists: S mode refuses without the billed opt-in" 2 "$?"
has "lists: the refusal names the opt-in" "HIMMEL_BILLED_OK" "$(cat "$W/srefuse.out")"
eq "lists: the refused S mode ran no query" "$n0" "$(wc -l < "$W/fakebin/calls.log" | tr -d ' ')"
slib() { # <out> <allow> -- S mode through the library with the fixture booking adapter (no opt-in set)
  python3 -I - "$ML" "$W/fx/bank.jsonl" "$W/ctx-S.json" "$1" "$2" <<'EOF'
import importlib.machinery, importlib.util, json, sys
ml_path, bank, ctx, out, allow = sys.argv[1:6]
l = importlib.machinery.SourceFileLoader("ml", ml_path); s = importlib.util.spec_from_loader("ml", l); ml = importlib.util.module_from_spec(s); l.exec_module(ml)
b = ml.FixtureBooking(int(allow))
ml.run_lists([json.loads(x) for x in open(bank)], "S", json.load(open(ctx)), b, out)
print(json.dumps({"reserve": sum(1 for e in b.events if e[0] == "reserve"), "settle": sum(1 for e in b.events if e[0] == "settle"),
                  "refused": sum(1 for e in b.events if e[0] == "refused")}))
EOF
}
eq "lists: every S query is booked before it runs and settled after" '{"reserve": 40, "settle": 40, "refused": 0}' "$(slib "$W/s.jsonl" 1000)"
eq "lists: the S child got the bound key" 40 "$(grep -c '"key": true' "$W/fakebin/calls.log")"
python3 -I "$ML" compare --s "$W/s.jsonl" --q "$W/q.jsonl" --expect 40 > "$W/cmp.json" 2>"$W/cmp.err"
eq "compare: the same 40 ids, question and query hashes in S and Q compare" 0 "$?"
eq "compare: both lists are complete" true "$(jget "$W/cmp.json" complete)"
eq "compare: fact-bearing-file@5 counts a fact file, never a gold name alone (S)" "[27, 36]" "$(jget "$W/cmp.json" S.fact_file_at5)"
eq "compare: the gold file hit without its fact still counts as legacy gold@5" "[35, 36]" "$(jget "$W/cmp.json" S.gold_file_at5)"
eq "compare: not-there tasks are N/A, not a miss" 4 "$(jget "$W/cmp.json" Q.not_applicable)"
eq "compare: the doc/code/mixed strata print apart" '{"code": [8, 8], "doc": [19, 20], "mixed": [0, 8]}' "$(jget "$W/cmp.json" S.fact_file_at5_by_stratum)"
eq "compare: each backend's corpus digest is recorded separately" true "$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["corpus_digests"]; print(json.dumps(c["S"]!=c["Q"]))' "$W/cmp.json")"
eq "lists: a wrong-gold file without the fact is no fact hit" "false true" "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][28]; print(json.dumps(r["fact_file_hit"]), json.dumps(r["gold_file_hit"]))' "$W/s.jsonl")"

eq "incomplete: a refused booking stops the S list" '{"reserve": 10, "settle": 10, "refused": 1}' "$(slib "$W/s10.jsonl" 10)"
python3 -I "$ML" compare --s "$W/s10.jsonl" --q "$W/q.jsonl" --expect 40 > "$W/cmp10.json" 2>&1
eq "incomplete: the cut list is labelled incomplete with 30 unaffordable rows" "false 30" "$(jget "$W/cmp10.json" S.complete) $(jget "$W/cmp10.json" S.statuses.unaffordable)"
printf 'qid-05\n' > "$W/fakebin/skip.txt"
python3 -I "$ML" run --bank "$W/fx/bank.jsonl" --mode Q --ctx "$W/ctx-Q.json" --out "$W/q-skip.jsonl" >/dev/null 2>&1
rm -f "$W/fakebin/skip.txt"
eq "incomplete: a skipped fixed query is labelled and the list is incomplete" '"skip" ["expansion_failed"]' "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][4]; print(json.dumps(r["status"]), json.dumps(r["skip_reasons"]))' "$W/q-skip.jsonl")"

tamper() { # <label> <python on rows `r`>
  python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; exec(sys.argv[3]); open(sys.argv[2],"w").write("".join(json.dumps(x)+"\n" for x in r))' "$W/q.jsonl" "$W/q-t.jsonl" "$2"
  python3 -I "$ML" compare --s "$W/s.jsonl" --q "$W/q-t.jsonl" --expect 40 >/dev/null 2>&1
  eq "compare: $1 refuses" 3 "$?"
}
tamper "a missing Q task id" 'r.pop()'
tamper "a different pre-expansion query hash" 'r[0]["query_sha256"] = "0"'
tamper "a different question hash" 'r[1]["question_sha256"] = "0"'
tamper "a different shaper" 'r[2]["shaper_sha256"] = "0"'
tamper "an extra Q-only document (different source manifest)" '[x.__setitem__("source_manifest_sha256", "0"*64) for x in r]'
tamper "a different collection scope" 'r[3]["collections"] = ["himmel"]'

python3 -I "$ML" run --bank "$W/fx/legacy.jsonl" --mode Q --ctx "$W/ctx-Q.json" --out "$W/legacy.jsonl" >/dev/null 2>&1
eq "legacy: old-75 rows are gold-file@5 diagnostics with no fact score" '6 6 0' "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; print(len(r), sum(x["legacy"] for x in r), sum(x["fact_file_hit"] is not None for x in r))' "$W/legacy.jsonl")"
eq "no network: every list query reached only the fake qmd" "$(( 40 + 40 + 10 + 40 + 6 ))" "$(wc -l < "$W/fakebin/calls.log" | tr -d ' ')"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all Q rows passed\n'
