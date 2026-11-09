#!/usr/bin/env bash
# test-rerun-hybrid.sh -- B7 of the RAG pilot: the separately capped old-75 S rerun (R5). The
# queries go through the real S wrapper path (preflight, target checks, key injected into the
# qmd child only, the shared classifier, the pin filter) on fresh disposable copies, but the qmd
# is a fake (fixtures/rerun/fake-qmd-rerun) and the key meter a fixture command: no network, no
# model, fetchOpenRouterKey is never reached. HIMMEL_BILLED_OK is never set: the run path is
# driven through the library; the CLI is checked only for its refusal.
#
# Platform guard: Linux bash; SKIPs loudly without the pinned qmd (its config loader) or bwrap.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RH="$HERE/rerun-hybrid.py"
FX="$HERE/fixtures/rerun"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-rerun.XXXXXX")" || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
f() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

eq "losses: the free saved-list replay accounts the nine fusion losses" '{"fused_hits": 2, "fusion_losses": 9, "questions": 12, "union_hits": 11}' "$(python3 -I "$RH" losses --results "$FX/saved-results.jsonl")"
QMD="${PILOT_QMD:-$(command -v qmd || true)}"
if [ -z "$QMD" ] || ! command -v node >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1 || ! bwrap --bind / / --unshare-net true 2>/dev/null; then
  printf 'SKIP - every rerun row: the pinned qmd, node or an unprivileged bwrap network namespace is absent on this host\n'
  [ "$fails" -gt 0 ] && exit 1
  exit 0
fi
QPKG="$(cd "$(dirname "$(readlink -f "$QMD")")/.." && pwd)"  # gnu-ok: Linux-only suite

mkdir -p "$W/src/docs" "$W/srcl/notes" "$W/cfg" "$W/fake" "$W/cache"
for i in $(seq -w 0 19); do printf '# Doc %s\nfixture content %s\n' "$i" "$i" > "$W/src/docs/d$i.md"; done
printf '# Note\nplain\n' > "$W/srcl/notes/n.md"
for r in src srcl; do git -C "$W/$r" init -q && gitc "$W/$r" add -A && gitc "$W/$r" commit -q -m pin; done
bash "$HERE/export-copies.sh" "$W/src" HEAD "$W/work/himmel" "$W/himmel.json" >/dev/null 2>&1
bash "$HERE/export-copies.sh" "$W/srcl" HEAD "$W/work/luna" "$W/luna.json" >/dev/null 2>&1
sed -e "s#@HIMMEL@#$W/work/himmel#" -e "s#@LUNA@#$W/work/luna#" "$HERE/fixtures/pins/eval.yml.in" > "$W/cfg/eval.yml"
( cd "$W" && bash "$HERE/fixtures/pins/netns-run.sh" "$W" env -i HOME="$W" PATH="/usr/bin:/bin:$(dirname "$QMD")" QMD_CONFIG_DIR="$W/cfg" INDEX_PATH="$W/build.sqlite" XDG_CACHE_HOME="$W/cache" "$QMD" --index eval update ) >/dev/null 2>&1
python3 -I "$HERE/pins.py" snapshot "$W/build.sqlite" "$W/master.sqlite"
python3 -I "$HERE/pins.py" finalize "$W/master.sqlite" --qmd "$QMD" --config-dir "$W/cfg" --expect-collection himmel="$W/work/himmel" --seal "$W/seal.json" >/dev/null
cp "$FX/fake-qmd-rerun" "$W/fake/qmd"; chmod +x "$W/fake/qmd"
printf 'fixture-key\n' > "$W/key"; chmod 600 "$W/key"
python3 -I - "$W" "$HERE" "$QPKG/dist" <<'EOF'
import hashlib, importlib.util, json, sys
W, here, dist = sys.argv[1:4]
man = json.load(open(W + "/himmel.json"))["files"]
hits = [{"docid": "#" + man["docs/d%02d.md" % i]["sha256"][:6], "score": 1 - i / 40, "file": "qmd://himmel/docs/d%02d.md?index=eval" % i,
         "line": 1, "title": "Doc", "snippet": "x"} for i in range(20)]
json.dump(hits, open(W + "/fake/hits.json", "w"))
s = importlib.util.spec_from_file_location("pins", here + "/pins.py"); p = importlib.util.module_from_spec(s); s.loader.exec_module(p)
h, _, b = p.load_config(dist, W + "/cfg")
bind = {"arm": "S", "qmd": W + "/fake/qmd", "qmd_dist": dist, "node": "node", "preflight": here + "/tools/config-preflight.mjs",
        "child_path": "/usr/bin:/bin", "config_dir": W + "/cfg", "config_sha256": b, "config_hash": h,
        "models": {"embed": "openai:stub-embed", "generate": "openai:stub-gen", "rerank": "openai:stub-rerank"}, "base_url": "http://127.0.0.1:18080/v1",
        "key_file": W + "/key", "key_fingerprint": hashlib.sha256(open(W + "/key", "rb").read()).hexdigest(),
        "forbidden_targets": [W + "/master.sqlite"], "collections": {"himmel": W + "/work/himmel", "luna": W + "/work/luna"},
        "manifests": {"himmel": W + "/himmel.json", "luna": W + "/luna.json"}, "env": {}, "deadline_term_ms": 20000, "deadline_kill_ms": 21000}
json.dump({"master": W + "/master.sqlite", "seal": W + "/seal.json", "binding": bind, "work": W}, open(W + "/ctx.json", "w"))
with open(W + "/old80.jsonl", "w") as f:
    for i in range(1, 81):
        f.write(json.dumps({"id": "o%02d" % i, "q": "fixture question marker-%02d about doc" % i, "gold": ["docs/d%02d.md" % (i % 25)]}) + "\n")
EOF
head -12 "$W/old80.jsonl" > "$W/old12.jsonl"
printf 'r5 go\n' > "$W/r5-go"
printf '{"g3": "PASS"}\n' > "$W/g3.json"; printf '{"g3": "INCOMPLETE"}\n' > "$W/g3-incomplete.json"
gates() { python3 -I -c 'import json,sys; g={"g0": "READY", "g1": True, "g1_evidence": "fixture: the free fixes are merged", "g3_report": sys.argv[2], "r5_go": sys.argv[3]}; [g.__setitem__(*kv.split("=",1)) for kv in sys.argv[4:]]; json.dump(g, open(sys.argv[1],"w"))' "$@"; }
gates "$W/gates.json" "$W/g3.json" "$W/r5-go"
lib() { # <name> <questions> <price> [gates] [settle seconds] -- the run path through the library (no opt-in set)
  rm -f "$W/fake/calls.log" "$W/fake/reads.log"; printf '%s\n' "$3" > "$W/fake/price.txt"
  python3 -I - "$RH" "$1" "$2" "$W" "${4:-$W/gates.json}" "${5:-0}" "$FX/meter" <<'EOF'
import argparse, importlib.machinery, importlib.util, json, sys
rh, name, qs, W, gates, settle, meter = sys.argv[1:8]
l = importlib.machinery.SourceFileLoader("rh", rh); s = importlib.util.spec_from_loader("rh", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
a = argparse.Namespace(questions=qs, ctx=W + "/ctx.json", state=W + "/%s.state.jsonl" % name, gates=gates, out=W + "/%s.rows.jsonl" % name,
                       usage_cmd="bash %s %s/fake" % (meter, W), settle_seconds=float(settle))
sys.exit(m.run(a))
EOF
}
calls() { [ -f "$W/fake/calls.log" ] && wc -l < "$W/fake/calls.log" | tr -d ' ' || echo 0; }

python3 -I "$RH" run --questions "$W/old12.jsonl" --ctx "$W/ctx.json" --state "$W/cli.state" --gates "$W/gates.json" --out "$W/cli.rows" > /dev/null 2>&1
eq "opt-in: the CLI refuses without HIMMEL_BILLED_OK and runs no query" "2 0" "$? $(calls)"
for g in "g0=BLOCKED" "g1=" "r5_go=$W/missing-go"; do
  gates "$W/gates-bad.json" "$W/g3.json" "$W/r5-go" "$g"
  lib bad "$W/old12.jsonl" 0.001 "$W/gates-bad.json" > /dev/null 2>&1; rc=$?
  eq "gates: ${g%%=*} missing refuses with zero queries" "3 0" "$rc $(calls)"
done
gates "$W/gates-bad.json" "$W/g3-incomplete.json" "$W/r5-go"
lib bad "$W/old12.jsonl" 0.001 "$W/gates-bad.json" > /dev/null 2>&1; rc=$?
eq "gates: a G3 that is not PASS refuses with zero queries" "3 0" "$rc $(calls)"

R=$(lib cap75 "$W/old80.jsonl" 0.001)
eq "cap: 75 queries run, the 76th and later are refused" "75 5 75" "$(f "$R" queries) $(f "$R" refused) $(calls)"
eq "cap: a cheap measured price keeps b at the .004 floor" "0.004" "$(f "$R" b)"
eq "cap: every query got the bound key in its qmd child only" 75 "$(grep -c '"key": true' "$W/fake/calls.log")"
eq "final: a complete run records the settled final b for the card" '0.004 75' "$(f "$(python3 -I "$RH" final --state "$W/cap75.state.jsonl")" b) $(f "$(python3 -I "$RH" final --state "$W/cap75.state.jsonl")" queries)"
R=$(lib dear "$W/old80.jsonl" 0.01)
eq "price: a measured .01 per query raises b to max(.004, 1.5 x .01) and only 35 queries fit \$0.50" "0.015 35 0.35" "$(f "$R" b) $(f "$R" queries) $(f "$R" cash)"
lib settle "$W/old12.jsonl" 0.001 "$W/gates.json" 0.4 > /dev/null
eq "settle: every key read waits the settle interval after the last query" "yes" "$(python3 -I - "$W/fake/calls.log" "$W/fake/reads.log" <<'EOF'
import json, sys
ends = [json.loads(l)["end"] for l in open(sys.argv[1])]
reads = [float(x) for x in open(sys.argv[2])]
ok = all(r - max([e for e in ends if e < r] or [0]) >= 0.39 for r in reads)
print("yes" if ok and len(reads) == 3 else "no %d" % len(reads))
EOF
)"
printf 'marker-03\n' > "$W/fake/fail.txt"; printf 'marker-04\n' > "$W/fake/skip.txt"
lib failrows "$W/old12.jsonl" 0.001 > /dev/null
rm -f "$W/fake/fail.txt" "$W/fake/skip.txt"
eq "rows: a failed query keeps its row with its raw evidence, no retry" '"error" true 12' "$(f "$(sed -n 3p "$W/failrows.rows.jsonl")" status) $(python3 -I -c 'import json,sys; print(json.dumps("502" in json.loads(sys.argv[1])["stderr"]))' "$(sed -n 3p "$W/failrows.rows.jsonl")") $(calls)"
eq "rows: a skipped query keeps its row and its skip reason, deep evidence marked incomplete" '"skip" ["expansion_failed"] false' "$(f "$(sed -n 4p "$W/failrows.rows.jsonl")" status) $(f "$(sed -n 4p "$W/failrows.rows.jsonl")" skip_reasons) $(f "$(sed -n 4p "$W/failrows.rows.jsonl")" deep_complete)"
eq "rows: a clean query scores its first 5 and keeps its top 20" '20 5 true' "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(len(r["top20"]), len(r["top5"]), json.dumps(r["deep_complete"]))' "$(sed -n 1p "$W/failrows.rows.jsonl")")"
: > "$W/fake/meter-fail.txt"
lib nousage "$W/old12.jsonl" 0.001 > /dev/null 2>&1; rc=$?
rm -f "$W/fake/meter-fail.txt"
eq "usage: an unreadable key meter stops the rerun before any query" "3 0" "$rc $(calls)"
python3 -I "$RH" final --state "$W/nousage.state.jsonl" > /dev/null 2>&1
eq "final: a rerun without a settled final booking rate makes the later card/pilot refuse" 3 "$?"
R=$(python3 -I - "$RH" "$W" <<'EOF'
import argparse, importlib.machinery, importlib.util, json, sys
rh, W = sys.argv[1:3]
l = importlib.machinery.SourceFileLoader("rh", rh); s = importlib.util.spec_from_loader("rh", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
st = m.State(W + "/reset.state.jsonl"); st.log({"ev": "settle", "meter": 1.0, "at": "before"})
a = argparse.Namespace(usage_cmd="echo '{\"usage\": 0.5}'", settle_seconds=0)
ok = m.settle(st, a, {"binding": {}}, "after-5")
print(json.dumps([ok, [e.get("reason") for e in st.events if e["ev"] == "stop"]]))
EOF
)
eq "usage: a key meter that went backwards (a reset) stops the rerun" '[false, ["usage_reset"]]' "$R"
lib resume "$W/old12.jsonl" 0.001 > /dev/null
n1=$(calls)
lib resume "$W/old12.jsonl" 0.001 > /dev/null
eq "resume: a second run on the same state never replays a booked query" "12 0" "$n1 $(calls)"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all rerun rows passed\n'
