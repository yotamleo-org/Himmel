#!/usr/bin/env bash
# test-identity-retention.sh -- B5 of the RAG pilot: the canonical nonsecret experiment identity
# (experiment-identity.py) and durable content-addressed retention (retain-run.py): forward
# identity changes with shaper/dirty bytes at the same commit, missing fields make comparability
# unknown, only the named treatment may differ inside one comparable group, no secret enters
# the identity; retention is private, scrubbed, idempotent, never auto-deleted, reproduces a
# score after the scratch copy is gone, and shows a missing legacy artifact as unavailable.
#
# Platform guard: any bash with python3 and git.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EI="$HERE/experiment-identity.py"
RR="$HERE/retain-run.py"
FX="$HERE/fixtures/identity"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-ident.XXXXXX")" || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
j() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }
mode() { python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

G="$W/harness"; mkdir -p "$G"
printf 'shaper v1\n' > "$G/shaper.py"; printf 'evaluator v1\n' > "$G/eval.py"; printf '{"id": "t1"}\n' > "$G/bank.jsonl"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@t -c user.name=t commit -q -m h
id() { python3 -I "$EI" build --file bank_sha256="$G/bank.jsonl" --file evaluator_sha256="$G/eval.py" --shaper "$G/shaper.py" --value protocol=rag-pilot-r18 --repo "$G" "$@"; }
A=$(id)
eq "identity: a clean harness records dirty_digest clean and its commit" '"clean" true' "$(j "$A" identity.dirty_digest) $( [ "$(j "$A" identity.harness_commit)" = "\"$(git -C "$G" rev-parse HEAD)\"" ] && echo true || echo false)"
printf 'shaper v2\n' > "$G/shaper.py"
B=$(id)
eq "identity: an uncommitted shaper edit changes the hash at the same commit" "true true" "$( [ "$(j "$A" config_hash)" != "$(j "$B" config_hash)" ] && echo true || echo false) $( [ "$(j "$A" identity.harness_commit)" = "$(j "$B" identity.harness_commit)" ] && echo true || echo false)"
git -C "$G" checkout -q -- shaper.py; printf 'scratch\n' > "$G/untracked.txt"
C=$(id)
eq "identity: an untracked file alone changes the dirty digest" "true" "$( [ "$(j "$A" identity.dirty_digest)" != "$(j "$C" identity.dirty_digest)" ] && echo true || echo false)"
rm -f "$G/untracked.txt"
eq "identity: the same bytes give the same hash" "$(j "$A" config_hash)" "$(j "$(id)" config_hash)"
mkdir -p "$W/not-a-repo"
eq "identity: a harness that is not a readable git work tree refuses (never a made-up clean digest)" 3 "$(python3 -I "$EI" build --value protocol=x --repo "$W/not-a-repo" >/dev/null 2>&1; echo $?)"
eq "identity: a credential-like field name refuses" 3 "$(id --value openrouter_api_key=x >/dev/null 2>&1; echo $?)"
eq "identity: a token-shaped value refuses" 3 "$(id --value backend=sk-or''-v1-0123456789abcdef >/dev/null 2>&1; echo $?)"
cmp_() { python3 -I "$EI" compare "$1" "$2"; }
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); i=d["identity"]; i["backend"]="local"; i["models"]="hf:embeddinggemma|hf:qmd-query-expansion|hf:qwen3-reranker"; i["corpus_digest"]="9"*64; json.dump(d, open(sys.argv[2],"w"))' "$FX/complete-s.json" "$W/complete-q.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["identity"]["bank_sha256"]="0"*64; json.dump(d, open(sys.argv[2],"w"))' "$FX/complete-s.json" "$W/other-bank.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["identity"]["shaper_sha256"]="0"*64; json.dump(d, open(sys.argv[2],"w"))' "$FX/complete-s.json" "$W/other-shaper.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["identity"]["source_manifest_sha256"]="0"*64; json.dump(d, open(sys.argv[2],"w"))' "$FX/complete-s.json" "$W/other-source.json"
eq "compare: S and Q differing only in backend/models/corpus digest are one experiment, named treatment" '"same experiment, named treatment differs"' "$(j "$(cmp_ "$FX/complete-s.json" "$W/complete-q.json")" group)"
eq "compare: another bank never groups" '["bank_sha256"] 1' "$(j "$(cmp_ "$FX/complete-s.json" "$W/other-bank.json")" differs) $(cmp_ "$FX/complete-s.json" "$W/other-bank.json" >/dev/null; echo $?)"
eq "compare: another pre-expansion shaper never groups" '["shaper_sha256"]' "$(j "$(cmp_ "$FX/complete-s.json" "$W/other-shaper.json")" differs)"
eq "compare: another common source manifest never groups" '["source_manifest_sha256"]' "$(j "$(cmp_ "$FX/complete-s.json" "$W/other-source.json")" differs)"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["identity"]["dirty_digest"]=""; json.dump(d, open(sys.argv[2],"w"))' "$FX/complete-s.json" "$W/empty-field.json"
eq "compare: an empty required field is missing, so comparability is unknown" 'null ["dirty_digest"]' "$(j "$(cmp_ "$W/empty-field.json" "$W/empty-field.json")" comparable) $(j "$(cmp_ "$W/empty-field.json" "$W/empty-field.json")" missing)"
L=$(cmp_ "$FX/complete-s.json" "$FX/legacy-row.json")
eq "compare: a legacy row missing fields is comparability unknown, no invented hashes" 'null true' "$(j "$L" comparable) $(python3 -I -c 'import json,sys; print(json.dumps("graph_sha256" in json.loads(sys.argv[1])["missing"]))' "$L")"

mkdir -p "$W/scratch"
printf '{"id": "t1", "question": "fixture q"}\n' > "$W/scratch/bank.jsonl"
printf 'ANSWER: one session per doc\nFILES:\n/work/himmel/docs/right.md\n' > "$W/scratch/answer.txt"
printf 'qmd error: Authorization: Bear''er abcdefghijklmnopqrstuvwxyz0123\nkey sk-or''-v1-abcdefabcdef0123456789\n' > "$W/scratch/errors.log"  # split so no scanner reads a fixture as a key
printf '\x00\x01binary trace\n' > "$W/scratch/trace.bin"
ret() { python3 -I "$RR" retain --root "$W/retained" --run-id "$1" --file bank="$W/scratch/bank.jsonl" --file answer="$W/scratch/answer.txt" --file errors="$W/scratch/errors.log" --file trace="$W/scratch/trace.bin"; }
M=$(ret run-1)
eq "retain: the manifest lists every artifact with its hash" '["answer", "bank", "errors", "trace"]' "$(python3 -I -c 'import json,sys; print(json.dumps(sorted(json.loads(sys.argv[1])["artifacts"])))' "$M")"
eq "retain: directories are 700 and objects 600" "700 700 600" "$(mode "$W/retained") $(mode "$W/retained/objects") $(mode "$(python3 -I "$RR" get --root "$W/retained" --run-id run-1 --kind answer)")"
ERR=$(cat "$(python3 -I "$RR" get --root "$W/retained" --run-id run-1 --kind errors)")
eq "retain: key and bearer strings are scrubbed before they are stored" "0 0 true" "$(printf '%s' "$ERR" | grep -c 'abcdefghijklmnopqrstuvwxyz0123') $(printf '%s' "$ERR" | grep -c 'v1-abcdef') $(j "$M" artifacts.errors.scrubbed)"
eq "retain: replaying the same run is idempotent" "$(j "$M" manifest_sha256)" "$(j "$(ret run-1)" manifest_sha256)"
printf 'ANSWER: changed\nFILES:\n' > "$W/scratch/answer.txt"
eq "retain: a different manifest for the same run id refuses" 3 "$(ret run-1 >/dev/null 2>&1; echo $?)"
printf 'ANSWER: one session per doc\nFILES:\n/work/himmel/docs/right.md\n' > "$W/scratch/answer.txt"
eq "retain: there is no delete or expiry command" 2 "$(python3 -I "$RR" delete --root "$W/retained" --run-id run-1 >/dev/null 2>&1; echo $?)"
S1=$(python3 -I - "$HERE" "$W/scratch/answer.txt" <<'EOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("score", sys.argv[1] + "/score.py"); sc = importlib.util.module_from_spec(s); s.loader.exec_module(sc)
print(json.dumps(sc.score(sc.CONTROL_TASK, open(sys.argv[2]).read(), sc.CONTROL_FILES.get)["supported"]))
EOF
)
rm -rf "$W/scratch"
S2=$(python3 -I - "$HERE" "$(python3 -I "$RR" get --root "$W/retained" --run-id run-1 --kind answer)" <<'EOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("score", sys.argv[1] + "/score.py"); sc = importlib.util.module_from_spec(s); s.loader.exec_module(sc)
print(json.dumps(sc.score(sc.CONTROL_TASK, open(sys.argv[2]).read(), sc.CONTROL_FILES.get)["supported"]))
EOF
)
eq "retain: the score reproduces from retained evidence after the scratch copy is deleted" "true true" "$S1 $S2"
eq "verify: every retained artifact is present" '{"answer": "present", "bank": "present", "errors": "present", "trace": "present"}' "$(python3 -I "$RR" verify --root "$W/retained" --run-id run-1)"
python3 -I -c 'import json,sys; json.dump({"run_id": "legacy-1", "artifacts": {"candidates": {"sha256": None, "name": "never-written"}, "bank": json.load(open(sys.argv[1]))["artifacts"]["bank"]}, "manifest_sha256": "x"}, open(sys.argv[2], "w"))' "$W/retained/runs/run-1.json" "$W/retained/runs/legacy-1.json"
eq "verify: a legacy artifact that never existed shows unavailable, never a fabricated hash" '{"bank": "present", "candidates": "unavailable"} 1' "$(python3 -I "$RR" verify --root "$W/retained" --run-id legacy-1) $(python3 -I "$RR" verify --root "$W/retained" --run-id legacy-1 >/dev/null; echo $?)"
eq "retain: an unsafe run id refuses" 3 "$(python3 -I "$RR" retain --root "$W/retained" --run-id ../escape --file x="$HERE/score.py" >/dev/null 2>&1; echo $?)"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all identity/retention rows passed\n'
