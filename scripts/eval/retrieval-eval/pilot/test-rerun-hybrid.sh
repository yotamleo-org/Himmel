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
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }
f() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

eq "losses: the free saved-list replay accounts the nine fusion losses" '{"fused_hits": 2, "fusion_losses": 9, "questions": 12, "union_hits": 11}' "$(python3 -I "$RH" losses --results "$FX/saved-results.jsonl")"
NR=$(python3 -I - "$RH" "$W" <<'EOF'
import argparse, importlib.machinery, importlib.util, json, sys
rh, W = sys.argv[1:3]
l = importlib.machinery.SourceFileLoader("rh", rh); s = importlib.util.spec_from_loader("rh", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
class Clk:
    t = 10000.0
    def now(self):
        return self.t
    def sleep(self, x):
        self.t += x
m.CLOCK = Clk()
a = argparse.Namespace(usage_cmd=None, settle_seconds=60)
def at(v):
    a.usage_cmd = "echo '{\"usage\": %r}'" % v
def state(name, rate=0.0003):
    st = m.State(W + "/" + name + ".jsonl")
    st.log({"ev": "noise_baseline", "path": "/run/noise-baseline-R5.json", "sha256": "f" * 64, "rate": rate, "ts": m.CLOCK.now()})
    at(1.0); m.settle(st, a, {"binding": {}}, "before")
    return st
stops = lambda st: [e.get("reason") for e in st.events if e["ev"] == "stop"]
last = lambda st: [e for e in st.events if e["ev"] == "settle"][-1]
out = {}
st = state("u1"); at(1.03); out["unbooked_under"] = [m.settle(st, a, {"binding": {}}, "after-5"), stops(st), round(last(st)["absorbed"], 6)]
st = state("u2"); at(1.06); out["unbooked_above"] = [m.settle(st, a, {"binding": {}}, "after-5"), stops(st)]
st = state("u3", rate=0.0001); st.log({"ev": "book", "task": "o01", "amount": 0.004}); at(1.04)
ok = m.settle(st, a, {"binding": {}}, "after-5"); e = last(st)
out["booked_beyond"] = [ok, stops(st), round(e["unabsorbed"], 6), round(e["absorbed"], 6)]
st = state("u4", rate=1.0); at(1.06); out["cap"] = [m.settle(st, a, {"binding": {}}, "after-5"), stops(st), round(last(st)["absorbed"], 6)]
st = state("u5", rate=0.0001); st.log({"ev": "book", "task": "o01", "amount": 0.004}); at(1.47); out["over_cap"] = [m.settle(st, a, {"binding": {}}, "after-5"), stops(st)]
st = state("u6"); st.log({"ev": "settle", "meter": 1.45, "at": "x", "ts": m.CLOCK.now()})
out["admission"] = [m.admit_ok(st), m.admit_ok(state("u7"))]
legacy = m.State(W + "/u8.jsonl"); at(1.0); m.settle(legacy, a, {"binding": {}}, "before"); at(1.0001)
out["legacy"] = [m.settle(legacy, a, {"binding": {}}, "end"), stops(legacy)]
out["cadence"] = [[q for q in range(1, 76) if m.settle_due(q, True)], [q for q in range(1, 76) if m.settle_due(q, False)]]
print(json.dumps(out, sort_keys=True))
EOF
)
eq "noise R5: an unbooked delta under A(t) continues and logs absorbed" '[true, [], 0.03]' "$(f "$NR" unbooked_under 2>/dev/null)"
eq "noise R5: an unbooked delta above A(t) stops with unexplained_usage" '[false, ["unexplained_usage"]]' "$(f "$NR" unbooked_above 2>/dev/null)"
eq "noise R5: booked-interval noise beyond A(t) is logged unabsorbed, not a stop" '[true, [], 0.017, 0.019]' "$(f "$NR" booked_beyond 2>/dev/null)"
eq "noise R5: the absorbed total never passes the 0.05 noise cap" '[false, ["unexplained_usage"], 0.05]' "$(f "$NR" cap 2>/dev/null)"
eq "noise R5: cash plus the noise reserve left above 0.50 after a settle stops" '[false, ["over_cap"]]' "$(f "$NR" over_cap 2>/dev/null)"
eq "noise R5: admission keeps the noise reserve" '[false, true]' "$(f "$NR" admission 2>/dev/null)"
eq "noise R5: without a baseline (legacy) any unbooked rise still stops" '[false, ["unexplained_usage"]]' "$(f "$NR" legacy 2>/dev/null)"
eq "noise R5: shared-credentials settles after query 5 and every 10; legacy after 5 only" '[[5, 15, 25, 35, 45, 55, 65, 75], [5]]' "$(f "$NR" cadence 2>/dev/null)"
printf '{"binding": {"key_fingerprint": "%s"}}\n' "$(printf 'fixture-key' | sha256sum | cut -d' ' -f1)" > "$W/nctx.json"
printf 'r5 go\n' > "$W/nr5-go"; printf '{"g3": "PASS"}\n' > "$W/ng3.json"
: > "$W/none.jsonl"
python3 -I - "$W" <<'EOF'
import hashlib, json, sys
W = sys.argv[1]
fp = hashlib.sha256(b"fixture-key").hexdigest()
good = {"start_meter": 1.0, "end_meter": 1.06, "start_ts": 9400.0, "end_ts": 10000.0, "window_s": 600, "key_fingerprint": fp, "rate": 0.0001}
for name, b in {"good": good, "other": dict(good, end_meter=1.03, rate=0.00005), "fp": dict(good, key_fingerprint="0" * 64),
                "window": dict(good, start_ts=9700.0, window_s=300, end_meter=1.03)}.items():
    json.dump(b, open(W + "/nbl-%s.json" % name, "w"))
json.dump({"ev": "settle", "meter": 1.0, "at": "before", "ts": 9990.0}, open(W + "/nstate-busy.jsonl", "w"))
open(W + "/nstate-busy.jsonl", "a").write("\n")
EOF
nrun() {
  python3 -I - "$RH" "$W" "$1" "$2" "$3" "${4:-10060}" "${5:-100}" <<'EOF'
import argparse, importlib.machinery, importlib.util, json, sys
rh, W, stance, bl, state, now, dur = sys.argv[1:8]
l = importlib.machinery.SourceFileLoader("rh", rh); s = importlib.util.spec_from_loader("rh", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
class Clk:
    t = float(now)
    def now(self):
        return self.t
    def sleep(self, x):
        self.t += x
m.CLOCK = Clk()
g = {"g0": "READY", "g1": True, "g1_evidence": "fixture", "g3_report": W + "/ng3.json", "r5_go": W + "/nr5-go"}
if stance != "-":
    g["g0_stance"] = stance
json.dump(g, open(W + "/ngates.json", "w"))
a = argparse.Namespace(questions=W + "/none.jsonl", ctx=W + "/nctx.json", state=W + "/nstate-%s.jsonl" % state, gates=W + "/ngates.json",
                       out=W + "/nrows.jsonl", usage_cmd="false", settle_seconds=0, noise_baseline=None if bl == "-" else bl, expected_duration=float(dur))
rc = m.run(a)
st = m.State(a.state)
print("first-event=%s queries=%d" % (st.events[0]["ev"] if st.events else "none", st.queries()))
sys.exit(rc)
EOF
}
for c in "-|-|nogst|G0 stance not recorded" "shared-credentials|-|nobl|needs a noise baseline" "eval-only-reachable|$W/nbl-good.json|legacy|legacy stance" \
         "shared-credentials|$W/nbl-fp.json|fp|taken on another key" "shared-credentials|$W/nbl-window.json|win|outside 600 to 1800" \
         "shared-credentials|$W/nbl-good.json|busy|already has events without a noise baseline"; do
  IFS='|' read -r st bl sn why <<< "$c"
  o=$(nrun "$st" "$bl" "$sn" 2>&1); rc=$?
  eq "noise R5: g0_stance=$st baseline=${bl##*/} state=$sn refuses before any query" "3 queries=0" "$rc $(printf '%s\n' "$o" | grep -o 'queries=[0-9]*')"
  has "noise R5: that refusal names its reason" "$why" "$o"
done
o=$(nrun shared-credentials "$W/nbl-good.json" stale 17201 2>&1); rc=$?
eq "noise R5: a baseline older than 2 hours at the first start refuses with zero queries" "3 queries=0" "$rc $(printf '%s\n' "$o" | grep -o 'queries=[0-9]*')"
has "noise R5: the stale refusal names its reason" "more than 2 hours" "$o"
o=$(nrun shared-credentials "$W/nbl-good.json" noisy 10060 1800 2>&1); rc=$?
eq "noise R5: 3 x rate x expected duration above the 0.05 cap refuses with zero queries" "3 queries=0" "$rc $(printf '%s\n' "$o" | grep -o 'queries=[0-9]*')"
has "noise R5: the feasibility refusal names its reason" "too noisy" "$o"
o=$(nrun shared-credentials "$W/nbl-good.json" ok 2>&1)
has "noise R5: a current baseline on the bound key passes start_noise and is the state's first event" "first-event=noise_baseline" "$o"
has "noise R5: past start_noise the run reaches its first settle (the fixture meter is unreadable)" "key usage could not be read" "$o"
o=$(nrun shared-credentials "$W/nbl-good.json" ok 99999 2>&1)
has "noise R5: a restart with the same baseline does not re-check its age" "key usage could not be read" "$o"
o=$(nrun shared-credentials "$W/nbl-other.json" ok 2>&1); rc=$?
eq "noise R5: a restart with a different baseline refuses with no new query" "3 queries=0" "$rc $(printf '%s\n' "$o" | grep -o 'queries=[0-9]*')"
has "noise R5: the different-baseline refusal names its reason" "different noise baseline" "$o"
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
gates() { python3 -I -c 'import json,sys; g={"g0": "READY", "g0_stance": "eval-only-reachable", "g1": True, "g1_evidence": "fixture: the free fixes are merged", "g3_report": sys.argv[2], "r5_go": sys.argv[3]}; [g.__setitem__(*kv.split("=",1)) for kv in sys.argv[4:]]; json.dump(g, open(sys.argv[1],"w"))' "$@"; }
gates "$W/gates.json" "$W/g3.json" "$W/r5-go"
lib() { # <name> <questions> <price> [gates] [settle seconds] -- the run path through the library (no opt-in set)
  rm -f "$W/fake/calls.log" "$W/fake/reads.log"; printf '%s\n' "$3" > "$W/fake/price.txt"
  python3 -I - "$RH" "$1" "$2" "$W" "${4:-$W/gates.json}" "${5:-0}" "$FX/meter" <<'EOF'
import argparse, importlib.machinery, importlib.util, json, sys
rh, name, qs, W, gates, settle, meter = sys.argv[1:8]
l = importlib.machinery.SourceFileLoader("rh", rh); s = importlib.util.spec_from_loader("rh", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
a = argparse.Namespace(questions=qs, ctx=W + "/ctx.json", state=W + "/%s.state.jsonl" % name, gates=gates, out=W + "/%s.rows.jsonl" % name,
                       usage_cmd="bash %s %s/fake" % (meter, W), settle_seconds=float(settle), noise_baseline=None, expected_duration=None)
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
