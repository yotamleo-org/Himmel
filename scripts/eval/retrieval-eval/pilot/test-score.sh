#!/usr/bin/env bash
# test-score.sh -- B5 of the RAG pilot: the strict supported-answer scorer and its eight controls
# in every arm, the Holm2 family statistics (exact McNemar, Holm, the 15-point bar, real-half
# qualifiers, pointwise Tango intervals, exploratory S-Q, power bounds), the interleaved
# complete-round judge scheduler (D3, fixtures/score/d3.py) and the safe report rows the RAG eval
# page reads (fixtures/score/rag-pilot-r18.jsonl). Fixtures only: no session, no judge call,
# no network, nothing billed.
#
# Platform guard: any bash with python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-score.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
f() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }
d3() { python3 -I "$HERE/fixtures/score/d3.py" "$1" "$W/d3-$1"; }

# --- the scorer and its controls
eq "controls: all eight planted answers score as planted in V, S and Q" '{"Q": true, "S": true, "V": true}' "$(python3 -I "$HERE/score.py" controls)"
ST=$(python3 -I - "$HERE" <<'EOF'
import importlib.util, json, random, sys
s = importlib.util.spec_from_file_location("score", sys.argv[1] + "/score.py"); sc = importlib.util.module_from_spec(s); s.loader.exec_module(sc)
out = {}
out["mcnemar"] = [sc.mcnemar(6, 0), sc.mcnemar(7, 0), round(sc.mcnemar(15, 5), 6), sc.mcnemar(0, 0)]
out["holm"] = [list(sc.holm2(.03125, 1)), list(sc.holm2(.015625, .03125)), list(sc.holm2(.03, .03)), list(sc.holm2(1, 1)), list(sc.holm2(1, .03125))]
out["tango0"] = [[round(x * 100, 1) for x in sc.tango(0, 0, 40)], [round(x * 100, 1) for x in sc.tango(0, 0, 36)]]
bank = {"t%02d" % i: {"id": "t%02d" % i, "half": "real" if i % 2 else "harder"} for i in range(1, 41)}
ids = sorted(bank)
def sc_(s_win, q_win, v_win=0, real_only=None):
    d = {}
    for i, t in enumerate(ids):
        d[t] = {"V": i < v_win, "S": i < s_win, "Q": i < q_win}
    return d
base = sc_(12, 2, 0)
out["s_wins_q_not"] = [c["label"] for c in sc.summarize(base, ids, bank)["comparisons"]]
out["q_wins_s_not"] = [c["label"] for c in sc.summarize(sc_(2, 12, 0), ids, bank)["comparisons"]]
out["v_beats_both"] = [c["label"] for c in sc.summarize({t: {"V": True, "S": i >= 12, "Q": i >= 12} for i, t in enumerate(ids)}, ids, bank)["comparisons"]]
# Holm with p=1 beside: 6 wins (exactly 15 points, raw .03125 -> adjusted .0625) is not established; 7 wins is far better.
out["holm_needed"] = [sc.summarize(sc_(6, 0), ids, bank)["comparisons"][0]["label"], sc.summarize(sc_(7, 0), ids, bank)["comparisons"][0]["label"]]
# the bar itself: exactly 15 points with an adjusted p <= .05 (S 6:0 beside Q 7:0) passes; 14.9 points never does
r = sc.summarize(sc_(6, 7), ids, bank)["comparisons"][0]
out["bar"] = [r["gain_pp"], r["p_adjusted"], r["label"],
              sc.label("S", {"p_adjusted": 0.001, "gain_pp": 14.9, "real_half_gain_pp": 10.0})]
# real-half qualifier: S wins only on harder (even) tasks, Q wins everywhere
d = {t: {"V": False, "S": i < 16 and int(t[1:]) % 2 == 0, "Q": i < 16} for i, t in enumerate(ids)}
r = sc.summarize(d, ids, bank)["comparisons"]
out["real_half"] = [r[0]["label"], r[1]["label"], r[0]["real_half_gain_pp"], r[1]["real_half_gain_pp"]]
out["exploratory"] = [r[2]["confirmatory"], r[2]["family"], r[2]["p_adjusted"], r[2]["label"], r[2]["interval_label"]]
# invariance: permuting the input order changes nothing; swapping the S and Q columns swaps the contrasts
items = list(base.items()); random.Random(3).shuffle(items)
a, b = sc.summarize(dict(items), ids, bank), sc.summarize(base, ids, bank)
out["order_invariant"] = a == b
sw = sc.summarize({t: {"V": v["V"], "S": v["Q"], "Q": v["S"]} for t, v in base.items()}, ids, bank)["comparisons"]
out["swap"] = [sw[0]["discordant"], sw[1]["discordant"], b["comparisons"][0]["discordant"], b["comparisons"][1]["discordant"]]
for label, bad in (("no_q", {t: {"V": True, "S": True} for t in ids}), ("mismatched", dict(list(base.items())[:39]))):
    try:
        sc.summarize(bad, ids, bank); out[label] = "accepted"
    except ValueError:
        out[label] = "refused"
out["power"] = sc.power_table()
print(json.dumps(out, sort_keys=True))
EOF
)
eq "stats: exact McNemar 6:0, 7:0, 15:5 and no discordance" "[0.03125, 0.015625, 0.041389, 1.0]" "$(f "$ST" mcnemar)"
eq "stats: Holm2 [.03125,1], [.015625,.03125], [.03,.03], [1,1] and the S-V-first tie order" "[[0.0625, 1.0], [0.03125, 0.03125], [0.06, 0.06], [1.0, 1.0], [1.0, 0.0625]]" "$(f "$ST" holm)"
eq "stats: zero-discordance Tango tops 8.8 points at n40 and 9.6 at n36, pointwise" "[[-8.8, 8.8], [-9.6, 9.6]]" "$(f "$ST" tango0)"
eq "labels: S wins and Q does not, rendered plainly per arm" '["S gave far more supported answers.", "Q: no family-adjusted answer improvement established; not far better.", null]' "$(f "$ST" s_wins_q_not)"
eq "labels: Q wins and S does not, the same way" '["S: no family-adjusted answer improvement established; not far better.", "Q gave far more supported answers.", null]' "$(f "$ST" q_wins_s_not)"
eq "labels: a loss is said plainly for each arm" '["Plain Claude Code beat S here.", "Plain Claude Code beat Q here.", null]' "$(f "$ST" v_beats_both)"
eq "labels: 6:0 beside a null Q is not family-significant; 7:0 is far better" '["S: no family-adjusted answer improvement established; not far better.", "S gave far more supported answers."]' "$(f "$ST" holm_needed)"
eq "labels: exactly 15 points with adjusted p <= .05 passes the bar; 14.9 points never does" '[15.0, 0.03125, "S gave far more supported answers.", "S: no family-adjusted answer improvement established; not far better."]' "$(f "$ST" bar)"
eq "labels: a nonpositive real-half gain qualifies only its own headline" '["S: far better only on tasks built to need search; not shown on real questions.", "Q gave far more supported answers.", 0.0, 40.0]' "$(f "$ST" real_half)"
eq "labels: S-Q is exploratory and can never claim a confirmatory result" '[false, "exploratory", null, null, "pointwise 95% Tango score interval, not simultaneous"]' "$(f "$ST" exploratory)"
eq "summary: permuted input order gives the identical summary" true "$(f "$ST" order_invariant)"
eq "summary: S and Q results stay attached to their arm (a column swap swaps the contrasts)" "[[2, 0], [12, 0], [12, 0], [2, 0]]" "$(f "$ST" swap)"
eq "summary: a missing Q arm refuses (no smaller family)" '"refused"' "$(f "$ST" no_q)"
eq "summary: scores that are not exactly the common cohort refuse" '"refused"' "$(f "$ST" mismatched)"
eq "power: the n40 bounds reproduce the design table" "[0.4, 0.9] [10.7, 17.2] [26.8, 36.4] [46.5, 56.7] [64.8, 74.1] [32.7, 44.0]" \
  "$(for i in 0 1 2 3 4 5; do f "$ST" "power.$i.n40"; done | paste -sd' ')"
eq "power: the n36 bounds reproduce the design table" "[0.3, 0.8] [8.4, 14.3] [22.1, 31.5] [40.1, 50.6] [58.2, 67.9] [28.8, 38.8]" \
  "$(for i in 0 1 2 3 4 5; do f "$ST" "power.$i.n36"; done | paste -sd' ')"

# --- D3: interleaved complete-round judging
R=$(d3 full); eq "D3: all fifteen candidates judged in five complete rounds, never replayed" '15 5 {"Q": 5, "S": 5, "V": 5} true' "$(f "$R" calls) $(f "$R" rounds) $(f "$R" applied) $(f "$R" distinct)"
R=$(d3 quota-expire-after-7)
eq "D3: a quota refusal after call 7 that expires applies rounds 1-2 only (two verdicts per arm)" '2 {"Q": 2, "S": 2, "V": 2} 1 "usage_expired"' "$(f "$R" rounds) $(f "$R" applied) $(f "$R" discarded) $(f "$R" ended)"
eq "D3: the seventh verdict is unapplied and every paid call's cost is kept" '7 0.14' "$(f "$R" calls) $(f "$R" spent)"
eq "D3: the pause uses one 7-day deadline" "7.0" "$(f "$R" deadline_days)"
R=$(d3 quota-clears-after-7); eq "D3: when quota clears, call 8 resumes and round 3 applies only once complete, no replay of 7" '15 5 true' "$(f "$R" calls) $(f "$R" rounds) $(f "$R" distinct)"
R=$(d3 in-call-usage); eq "D3: a usage refusal returned by a launched call is a failed slot: judging ends, complete rounds only" '"failed_slot" 1 5 1' "$(f "$R" ended) $(f "$R" rounds) $(f "$R" calls) $(f "$R" discarded)"
R=$(d3 invalid); eq "D3: an invalid paid verdict ends judging without retry; its partial round does not count" '"invalid_verdict" 1 5' "$(f "$R" ended) $(f "$R" rounds) $(f "$R" calls)"
R=$(d3 auth-mid-round); eq "D3: an auth refusal mid-round ends judging with the complete-round rule" '"auth_or_readiness_refused" 2 8' "$(f "$R" ended) $(f "$R" rounds) $(f "$R" calls)"
R=$(d3 absent-candidate); eq "D3: an absent candidate is a not_needed slot with no call or quota" '13 2 {"Q": 3, "S": 5, "V": 5}' "$(f "$R" calls) $(f "$R" not_needed) $(f "$R" applied)"
R=$(d3 restart-after-7); eq "D3: a restart at the boundary after call 7 resumes call 8 from the ledger, no replay" '7 8 0 5' "$(f "$R" first_calls) $(f "$R" calls) $(f "$R" replayed) $(f "$R" rounds)"
R=$(d3 deadline-persists); eq "D3: the admission-time pause deadline carries into judging, never a renewed window" '7.0 1 "usage_expired"' "$(f "$R" deadline_days_from_first_refusal) $(f "$R" deadlines) $(f "$R" ended)"
R=$(d3 lost-round-marker); eq "D3: a round whose last verdict landed before a crash gets its marker on resume, no call replayed" '4 5 0' "$(f "$R" before_resume) $(f "$R" rounds) $(f "$R" calls)"
R=$(d3 cost-missing); eq "D3: a judge call with no usage evidence is never settled as free: unsettled, paid work stops" '"unknown_spend" ["judge-03"] {"kind": "HARD_STOP", "reason": "unsettled"} 1' "$(f "$R" ended) $(f "$R" unsettled) $(f "$R" stop) $(f "$R" rounds)"
R=$(d3 contained-read); eq "judge: answer-named paths are read only inside the export (no traversal, no symlink out, no other root)" '"inside" null null null null' "$(f "$R" inside) $(f "$R" traversal) $(f "$R" deep_traversal) $(f "$R" symlink_out) $(f "$R" other_root)"
R=$(d3 validate); eq "D3: arm-sequential order, a sixth call in an arm and a sixteenth call all refuse" '{"arm_sequential": "refused", "sixteenth_total": "refused", "sixth_in_an_arm": "refused"}' "$R"

# --- the report rows the page reads
python3 -I "$HERE/report.py" fixtures --out "$W/fx.jsonl"
eq "report: the committed page fixture is exactly what report.py emits" same "$(cmp -s "$W/fx.jsonl" "$HERE/fixtures/score/rag-pilot-r18.jsonl" && echo same || echo differ)"
RP=$(python3 -I - "$HERE" "$W/fx.jsonl" <<'EOF'
import importlib.util, json, os, sys
here = sys.argv[1]
s = importlib.util.spec_from_file_location("eval_runs", os.path.join(here, "..", "..", "lib", "eval_runs.py")); er = importlib.util.module_from_spec(s); s.loader.exec_module(er)
rows = [json.loads(l) for l in open(sys.argv[2])]
by = {r["run_id"]: r for r in rows}
out = {"valid": all(not er.validate(r) for r in rows), "protocols": sorted({r.get("protocol") or "legacy" for r in rows}),
       "void_no_comparisons": by["fixture-rag-pilot-r18-void"]["pilot"]["comparisons"] is None and by["fixture-rag-pilot-r18-void"]["pilot"]["void"],
       "short": [by["fixture-rag-pilot-r18-short"]["pilot"]["finalization_status"], by["fixture-rag-pilot-r18-short"]["pilot"]["counts"]["common_scored"]],
       "contrast_order": [c["contrast"] for c in by["fixture-rag-pilot-r18-mixed"]["pilot"]["comparisons"]],
       "families": [c["family"] for c in by["fixture-rag-pilot-r18-mixed"]["pilot"]["comparisons"]],
       "small_cells": all(min(v[1] for v in per.values()) >= 5 for r in rows if r.get("pilot") and r["pilot"]["kinds"] for per in r["pilot"]["kinds"].values()),
       "disclosures": all(r["pilot"]["exposure"].startswith("eval-only-reachable") and "Q can stop or void" in r["pilot"]["coupling"] for r in rows if r.get("pilot"))}
print(json.dumps(out, sort_keys=True))
EOF
)
eq "report: every fixture row is a valid eval-runs row" true "$(f "$RP" valid)"
eq "report: r18 rows and the legacy file-hit row are separate protocol groups" '["legacy", "rag-pilot-r18"]' "$(f "$RP" protocols)"
eq "report: a HARD_STOP/void row exposes no comparison" true "$(f "$RP" void_no_comparisons)"
eq "report: a FINALIZE_ONLY 37-triple run is a labelled short pilot" '["short", 37]' "$(f "$RP" short)"
eq "report: fixed S-V, Q-V order with the exploratory S-Q last" '["S-V", "Q-V", "S-Q"] ["baseline-holm2", "baseline-holm2", "exploratory"]' "$(f "$RP" contrast_order) $(f "$RP" families)"
eq "report: no printed kind cell holds fewer than 5 tasks" true "$(f "$RP" small_cells)"
eq "report: the exposure stance and the Q-to-S coupling are disclosed on every pilot row" true "$(f "$RP" disclosures)"
EDGE=$(python3 -I - "$HERE" "$W" <<'EOF'
import importlib.util, json, os, sys
s = importlib.util.spec_from_file_location("report", sys.argv[1] + "/report.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
W = sys.argv[2]
bank = rp._bank()
ids = sorted(bank)
ident = {"config_hash": "f" * 64, "identity": {"protocol": rp.PROTOCOL}}
ret = {"run_id": "edge", "manifest_sha256": "0" * 64}
out = {}
def blk(run, n, judge=None, scores=None):
    c = ids[:n]
    return rp.pilot_block(run, scores or rp._scores(c, .7, .55, .4), c, bank, judge or {"completed_rounds": 5}, rp._arms(), None,
                          {"subscription_equivalent_usd": 9, "cash_usd": .3, "total_usd": 9.3})
o37 = blk({"stop_kind": "HARD_STOP", "reason": "overrun", "finalization_status": "none", "attempted": 38, "completed": 37}, 37)
out["overrun37"] = [o37["void"], o37["comparisons"]]
v34 = blk({"stop_kind": "HARD_STOP", "reason": "insufficient_common_cohort", "finalization_status": "none", "attempted": 35, "completed": 34}, 34)
out["void34"] = [v34["void"], v34["comparisons"]]
uj = blk({"stop_kind": "FINALIZE_ONLY", "reason": "usage_expired", "finalization_status": "short", "attempted": 37, "completed": 37}, 37,
         judge={"completed_rounds": 0, "discarded_verdicts": 0, "unjudged": {"V": 5, "S": 5, "Q": 4}, "ended": "auth_or_readiness_refused"})
out["unavailable_judge"] = [uj["void"], uj["judge"]["ended"], uj["judge"]["unjudged"], len(uj["comparisons"])]
try:
    rp.make_row(uj, ident, None, "edge"); out["unretained"] = "accepted"
except ValueError:
    out["unretained"] = "refused"
row = rp.make_row(uj, ident, ret, "edge-run", gitsha="x", ts="2026-11-09T12:00:00Z")
led = os.path.join(W, "edge-ledger.jsonl")
rp.append(row, {"x": {"id": "secret-task-id-x1", "question": "a private question nobody prints", "facts": [], "files": []}}, led)
try:
    rp.append(row, {}, led); out["duplicate"] = "accepted"
except ValueError:
    out["duplicate"] = "refused"
leaky = json.loads(json.dumps(row)); leaky["run_id"] = "edge-2"; leaky["pilot"]["reason"] = "a private question nobody prints"
try:
    rp.append(leaky, {"x": {"id": "x", "question": "a private question nobody prints", "facts": [], "files": []}}, led); out["leak"] = "accepted"
except ValueError:
    out["leak"] = "refused"
open(led, "a").write('{"torn": ')
fresh = json.loads(json.dumps(row)); fresh["run_id"] = "edge-3"
try:
    rp.append(fresh, {}, led); out["torn"] = "accepted"
except ValueError:
    out["torn"] = "refused"
print(json.dumps(out, sort_keys=True))
EOF
)
eq "report: an overrun after 37 triples publishes void/spend only" "[true, null]" "$(f "$EDGE" overrun37)"
eq "report: 34 common triples are void, no comparison" "[true, null]" "$(f "$EDGE" void34)"
eq "report: an unavailable judge still reports, its candidates unjudged and counted" '[false, "auth_or_readiness_refused", {"Q": 4, "S": 5, "V": 5}, 3]' "$(f "$EDGE" unavailable_judge)"
eq "report: a row is refused until the run is retained" '"refused"' "$(f "$EDGE" unretained)"
eq "report: a resumed publish of the same run id is refused" '"refused"' "$(f "$EDGE" duplicate)"
eq "report: a row naming private task text is refused" '"refused"' "$(f "$EDGE" leak)"
eq "report: an interrupted (torn) ledger line blocks the next append" '"refused"' "$(f "$EDGE" torn)"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all score rows passed\n'
