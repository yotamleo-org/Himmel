#!/usr/bin/env bash
# test-run-pilot.sh -- B4 of the RAG pilot: the three-arm runner state machine, the capped
# ledger (P16), the sealed balanced schedule, the stop/finalization states (D1), crash and
# resume accounting, the V/S/Q launch argv/prompt/profile (P14), the real per-session bwrap
# namespace driven with a stub CLI (P15) and the G0 auth-readiness checklist (P17). Claude,
# usage, quota and probes are mocks (fixtures/run/scenarios.py); no session starts, nothing is
# billed, HIMMEL_BILLED_OK is never set. Fixtures prove logic, never live readiness.
#
# Platform guard: Linux bash (bwrap rows SKIP loudly without an unprivileged bwrap).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixtures/run"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-run.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in '$3')" ;; esac; }
sc() { python3 -I "$FX/scenarios.py" "$1" "$W/$1"; }
f() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"; }

python3 -I - "$HERE" "$W" > "$W/ledger.out" 2>&1 <<'EOF'
import importlib.util, json, os, sys
s = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/ledger.py"); L = importlib.util.module_from_spec(s); s.loader.exec_module(L)
W = sys.argv[2]; out = {}
out["H_B"] = [round(L.H(.004), 3), round(L.btriple(.004), 3)]
out["old"] = L.scenario(1.0); out["double"] = L.scenario(2.0)
led = L.Ledger(W + "/u1.jsonl", cap=3.0); led.reserve_h()
before = led.committed(); led.admit_triple("t1"); led.book("a1", "answer", .35, "triple:t1:answers")
out["transfer_no_double_count"] = round(before + L.btriple(led.b), 6) == round(led.committed(), 6)
led2 = L.Ledger(W + "/u2.jsonl", cap=2.0); led2.reserve_h()
n = len(led2.events); out["capacity_refuses_whole_triple"] = [led2.admit_triple("t1"), len(led2.events) == n]
led3 = L.Ledger(W + "/u3.jsonl"); led3.book("q1", "s_query", .004); led3.book("q2", "s_query", .004)
out["s_interval_equal_is_ok"] = [led3.settle_s_interval(.008, 2), led3.stop]
led3.book("q3", "s_query", .004); out["s_interval_greater_hard_stops"] = [led3.settle_s_interval(.0081, 1), led3.stop]
led4 = L.Ledger(W + "/u4.jsonl"); led4.book("a", "answer", .35); out["subscription_overrun"] = [led4.settle("a", .36), led4.stop]
led5 = L.Ledger(W + "/u5.jsonl"); led5.reserve_h(); led5.book("q", "s_query", .004); led5.settle_s_interval(.004, 1)
out["reprice"] = [led5.b, round(led5.reserves["probes"], 6), round(led5.reserves["lists"], 6), round(L.H(led5.b), 6), round(L.btriple(led5.b), 6)]
led6 = L.Ledger(W + "/u6.jsonl", cap=2.0); led6.reserve_h(); led6.cap = led6.committed() + .02; led6.reprice(.006)
out["reprice_cancels_lists_keeps_judge"] = [led6.lists_cancelled(), round(led6.reserves.get("judge", 0), 4), round(led6.reserves.get("probes", 0), 6)]
led7 = L.Ledger(W + "/u7.jsonl"); led7.book("k1", "answer", .35); led7.killed("k1", .12, True)
out["killed_with_complete_usage_reconciles"] = [round(led7.spent, 6), led7.stop]
led8 = L.Ledger(W + "/u8.jsonl"); led8.book("k2", "answer", .35); led8.killed("k2", None, False)
try:
    led8.book("k3", "answer", .35); refused = False
except L.Refused:
    refused = True
out["killed_without_usage_blocks_paid_work"] = [sorted(led8.unsettled), led8.stop["reason"], refused]
led9 = L.Ledger(W + "/u8.jsonl")
out["replay_is_durable"] = [sorted(led9.unsettled), led9.stop["reason"], round(led9.committed(), 6) == round(led8.committed(), 6)]
d1 = led9.usage_refused(1000.0); d2 = led9.usage_refused(5000.0)
out["one_pause_deadline"] = [d1 == d2, d1 - 1000.0 == 7 * 86400, L.Ledger(W + "/u8.jsonl").usage_pause_deadline == d1]
led10 = L.Ledger(W + "/u10.jsonl"); led10.halt("FINALIZE_ONLY", "capacity_refused"); led10.halt("HARD_STOP", "overrun"); led10.halt("FINALIZE_ONLY", "auth_refused")
out["hard_dominates"] = led10.stop
led11 = L.Ledger(W + "/u11.jsonl"); led11.halt("FINALIZE_ONLY", "something_new")
out["unclassified_is_hard"] = led11.stop
s2 = importlib.util.spec_from_file_location("ledger_again", sys.argv[1] + "/ledger.py"); L2 = importlib.util.module_from_spec(s2); s2.loader.exec_module(L2)
led12 = L2.Ledger(W + "/u12.jsonl"); led12.reserve_h()
lb = L.ListBooking(led12)
out["list_booking_takes_another_module_ledger"] = [lb.ledger is led12, lb.reserve("t01") is not None]
led13 = L.Ledger(W + "/u13.jsonl"); led13.reserve_h(); n = len(led13.events); led13.admit_triple("t1")
out["admission_is_one_durable_event"] = [len(led13.events) - n, led13.events[-1]["ev"], round(sum(v for k, v in led13.reserves.items() if k.startswith("triple:")), 4),
                                         L.Ledger(W + "/u13.jsonl").triples.get("t1", {}).get("state")]
bad = []
for i, v in enumerate((float("nan"), -0.01, float("inf"))):
    led = L.Ledger(W + "/u14-%d.jsonl" % i); led.book("x", "answer", .35)
    bad.append([led.settle("x", v), led.stop["reason"], sorted(led.unsettled)])
out["invalid_cost_evidence_is_unsettled"] = bad
led15 = L.Ledger(W + "/u15.jsonl"); led15.book("q", "s_query", .004)
out["negative_meter_delta_stops"] = [led15.settle_s_interval(-0.01, 1), led15.stop, round(led15.spent, 6)]
print(json.dumps(out, sort_keys=True))
EOF
LO=$(tail -1 "$W/ledger.out")
eq "P16: H and Btriple at b=.004" "[1.076, 1.098]" "$(f "$LO" H_B)"
eq "P16: the old-rate proxy (A, total, projection, min cap)" "0.218 9.128 9.578 10.676" "$(f "$LO" old.A) $(f "$LO" old.total) $(f "$LO" old.projection) $(f "$LO" old.min_cap)"
eq "P16: the doubled proxy (total, Btriple, min cap, 25 headroom)" "18.256 1.146 19.402 5.598" "$(f "$LO" double.total) $(f "$LO" double.Btriple) $(f "$LO" double.min_cap) $(f "$LO" double.headroom_25)"
eq "ledger: a booking transfers its reservation, never counted twice" true "$(f "$LO" transfer_no_double_count)"
eq "ledger: a triple that cannot fit reserves nothing" "[false, true]" "$(f "$LO" capacity_refuses_whole_triple)"
eq "ledger: a settled S interval equal to its bookings is not an overrun" "[true, null]" "$(f "$LO" s_interval_equal_is_ok)"
eq "ledger: an S interval delta above its bookings is a HARD_STOP overrun" '[false, {"kind": "HARD_STOP", "reason": "overrun"}]' "$(f "$LO" s_interval_greater_hard_stops)"
eq "ledger: a subscription call above its booking is a HARD_STOP overrun" '[false, {"kind": "HARD_STOP", "reason": "overrun"}]' "$(f "$LO" subscription_overrun)"
eq "ledger: repricing raises b to 1.5x measured and recomputes the probe/list reserves, H and Btriple" "[0.006, 0.024, 0.24, 1.164, 1.122]" "$(f "$LO" reprice)"
eq "ledger: a b rise that makes the lists unaffordable cancels them without touching the judge reserve" "[true, 0.9, 0.024]" "$(f "$LO" reprice_cancels_lists_keeps_judge)"
eq "ledger: a killed call with complete transcript usage reconciles, no replay" "[0.12, null]" "$(f "$LO" killed_with_complete_usage_reconciles)"
eq "ledger: a killed call without usage stays unsettled and blocks paid work" '[["k2"], "unsettled", true]' "$(f "$LO" killed_without_usage_blocks_paid_work)"
eq "ledger: a fresh process replays the same unsettled state" '[["k2"], "unsettled", true]' "$(f "$LO" replay_is_durable)"
eq "ledger: one persisted 7-day usage-pause deadline, never reset" "[true, true, true]" "$(f "$LO" one_pause_deadline)"
eq "ledger: HARD_STOP dominates FINALIZE_ONLY" '{"kind": "HARD_STOP", "reason": "overrun"}' "$(f "$LO" hard_dominates)"
eq "ledger: an unclassified finalize reason becomes a HARD_STOP" '{"kind": "HARD_STOP", "reason": "unclassified"}' "$(f "$LO" unclassified_is_hard)"
eq "ledger: a negative key-meter delta (a reset) stops paid work and never lowers spend" '[false, {"kind": "HARD_STOP", "reason": "unknown_spend"}, 0.0]' "$(f "$LO" negative_meter_delta_stops)"
eq "ledger: the list adapter accepts a ledger from a separately loaded copy of the module" "[true, true]" "$(f "$LO" list_booking_takes_another_module_ledger)"
eq "ledger: a triple admission is one durable event (both reservations or none), replayed whole" '[1, "admit_triple", 1.098, "admitted"]' "$(f "$LO" admission_is_one_durable_event)"
eq "ledger: NaN, negative or infinite cost evidence leaves the booking unsettled and stops paid work" '[[false, "unsettled", ["x"]], [false, "unsettled", ["x"]], [false, "unsettled", ["x"]]]' "$(f "$LO" invalid_cost_evidence_is_unsettled)"

SCH=$(python3 -I - "$HERE" <<'EOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("rp", sys.argv[1] + "/run-pilot.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
ids = ["t%02d" % i for i in range(1, 41)]
a, b = rp.schedule(ids, 7), rp.schedule(ids, 7)
pos = {arm: sorted({sum(1 for _, p in a if p[i] == arm) for i in range(3)}) for arm in "VSQ"}
try:
    rp.schedule(ids[:39], 7); short = "accepted"
except ValueError:
    short = "refused"
print(json.dumps({"same": a == b, "other": a != rp.schedule(ids, 8), "tasks": len({t for t, _ in a}), "pos": pos,
                  "attempts": 3 * len(a), "short": short, "first36": all(sum(1 for _, p in a[k:k + 6]) == 6 for k in range(0, 36, 6))}))
EOF
)
eq "schedule: the same seed seals the same schedule; another seed another one" "true true" "$(f "$SCH" same) $(f "$SCH" other)"
eq "schedule: 40 tasks, at most 120 answer attempts" "40 120" "$(f "$SCH" tasks) $(f "$SCH" attempts)"
eq "schedule: every arm holds every position 13 or 14 times" '{"Q": [13, 14], "S": [13, 14], "V": [13, 14]}' "$(f "$SCH" pos)"
eq "schedule: a bank that is not 40 tasks refuses" '"refused"' "$(f "$SCH" short)"

R=$(sc clean)
eq "run: a clean run finishes all 40 triples, full, finalized once on the 40-task cohort" '["NONE", null] "full" 40 [40]' "$(f "$R" stop) $(f "$R" finalization) $(f "$R" common) $(f "$R" finalize_calls)"
eq "run: seven unscored checks plus 120 answers, never more" "7 127 120" "$(f "$R" checks_booked) $(f "$R" launches) $(f "$R" answers)"
eq "run: P1-S books exactly one s-qmd query at b" "[0.004]" "$(f "$R" p1s_booking)"
eq "run: H holds fifteen judge bookings, four S probes and forty S lists" '[["judge", 0.9], ["lists", 0.16], ["probes", 0.016]]' "$(f "$R" h)"
eq "run: five S and five Q P3 probes" 10 "$(f "$R" probes)"
R=$(sc g0); eq "G0: missing auth readiness refuses before any booking or launch" '"G0" 0 0' "$(f "$R" refused) $(f "$R" launches) $(f "$R" events)"
for g in p1-skip p2-missing control q-unavailable fallback-shape; do
  R=$(sc "g5-$g"); eq "G5: $g stops before any scored triple" '["HARD_STOP", "g5_failed"] 0' "$(f "$R" stop) $(f "$R" answers)"
done
R=$(sc first-four); eq "G6: a first-four service failure stops without a fifth calibration task" '["HARD_STOP", "first_four_failure"] 4' "$(f "$R" stop) $(f "$R" attempted)"
R=$(sc g6-route-use); eq "G6: Q retrieval use on fewer than 3 of the first 4 tasks stops" '["HARD_STOP", "g6_failed"] 12' "$(f "$R" stop) $(f "$R" answers)"
R=$(sc g6-projection); eq "G6: a projection above the cap stops" '["HARD_STOP", "g6_failed"]' "$(f "$R" stop)"
R=$(sc capacity-at-38); eq "D1: a capacity stop at admission 38 finalizes a short 37-triple pilot" '["FINALIZE_ONLY", "capacity_refused"] "short" 37 [37]' "$(f "$R" stop) $(f "$R" finalization) $(f "$R" common) $(f "$R" finalize_calls)"
R=$(sc capacity-at-35); eq "D1: a capacity stop at admission 35 is void: HARD_STOP, no judge" '["HARD_STOP", "insufficient_common_cohort"] "capacity_refused" []' "$(f "$R" stop) $(f "$R" first_stop) $(f "$R" finalize_calls)"
R=$(sc overrun-after-37); eq "D1: an overrun after 37 triples is a HARD_STOP with no judge or comparison" '["HARD_STOP", "overrun"] []' "$(f "$R" stop) $(f "$R" finalize_calls)"
R=$(sc probe-benign-20); eq "D1: a benign probe failure after 20 ends admission and is void" '["HARD_STOP", "insufficient_common_cohort"] "benign_probe_failure" 20 []' "$(f "$R" stop) $(f "$R" first_stop) $(f "$R" attempted) $(f "$R" finalize_calls)"
R=$(sc probe-security); eq "D1: a security-failed probe is a HARD_STOP" '["HARD_STOP", "security_probe_failure"]' "$(f "$R" stop)"
R=$(sc quota-expiry-37)
eq "D1: quota expiry at 37 with continued refusal ends admission as FINALIZE_ONLY" '["FINALIZE_ONLY", "usage_expired"] "short" 37' "$(f "$R" stop) $(f "$R" finalization) $(f "$R" common)"
eq "D1: the pause checks every 30 minutes against one 7-day deadline" "[60, 1800] 7.0" "$(f "$R" sleeps) $(f "$R" deadline_days)"
R=$(sc quota-clears); eq "D1: a pause that clears resumes the run" '["NONE", null] 40' "$(f "$R" stop) $(f "$R" common)"
R=$(sc pause-deadline-persists); eq "D1: the pause deadline survives a restart and a second pause, never reset" "true 1" "$(f "$R" deadline_same) $(f "$R" deadline_events)"
R=$(sc auth-after-g6); eq "D1: a post-G6 auth refusal is FINALIZE_ONLY" '["FINALIZE_ONLY", "auth_refused"] "short"' "$(f "$R" stop) $(f "$R" finalization)"
R=$(sc unclassified); eq "D1: an unclassified failure is a HARD_STOP" '["HARD_STOP", "unclassified"]' "$(f "$R" stop)"
R=$(sc reachable-35); eq "D1: complete-common + unattempted = 35 stops buying at that boundary" '["HARD_STOP", "insufficient_common_cohort"] 9 4' "$(f "$R" stop) $(f "$R" attempted) $(f "$R" common)"
R=$(sc skips-two); eq "cohort: two disjoint S/Q skip tasks are allowed (short 38)" '["NONE", null] 2 38' "$(f "$R" stop) $(f "$R" skip_union) $(f "$R" common)"
R=$(sc skips-three); eq "cohort: a third skip task voids (skip ceiling)" '["HARD_STOP", "skip_ceiling"] 3' "$(f "$R" stop) $(f "$R" skip_union)"
R=$(sc skips-same-task); eq "cohort: an S and a Q skip in the same task count once" '1 39' "$(f "$R" skip_union) $(f "$R" common)"
for k in 1 2 3; do
  R=$(sc "kill-$k-usage")
  eq "kill: a kill at answer $k of a triple excludes the whole triple, no replay, costs kept" "{\"t31\": \"interrupted\"} $((117 + k)) true" "$(f "$R" excluded) $(f "$R" answers) $(f "$R" killed_settled)"
done
R=$(sc kill-2); eq "kill: a kill without complete usage leaves the booking unsettled and stops paid work" '["HARD_STOP", "unsettled"] 1' "$(f "$R" stop) $(f "$R" unsettled)"
R=$(sc crash-resume)
eq "resume: after a runner crash the in-flight call reconciles from its transcript and is never replayed" '0 "excluded:interrupted" [] 0' "$(f "$R" replayed) $(f "$R" crashed_task_status) $(f "$R" unsettled_after_resume) $(f "$R" preflight_rerun)"
R=$(sc crash-resume-nousage); eq "resume: an unresolved meter blocks the resumed run, never released" '["HARD_STOP", "unsettled"] ["answer-t31-V"] 0' "$(f "$R" stop) $(f "$R" unsettled_after_resume) $(f "$R" answers)"
R=$(sc no-cost-evidence); eq "cost: an answer with no cost evidence is never settled as free: unsettled, paid work stops" '["HARD_STOP", "unsettled"] 1' "$(f "$R" stop) $(f "$R" unsettled)"
R=$(sc background); eq "P14: a surviving background child is an integrity HARD_STOP" '["HARD_STOP", "integrity"]' "$(f "$R" stop)"
R=$(sc raw-only); eq "skip rule: a raw-query-only S expansion does not exclude the answer" '["NONE", null] 40' "$(f "$R" stop) $(f "$R" common)"
R=$(sc reprice-no-capacity); eq "repricing: a raised b with enough H but no next-triple capacity ends admission" '"capacity_refused" 0.006 false' "$(f "$R" first_stop) $(f "$R" b) $(f "$R" lists_cancelled)"

P14=$(python3 -I - "$HERE" <<'EOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("rp", sys.argv[1] + "/run-pilot.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
arms = json.load(open(sys.argv[1] + "/arms.json"))
v, sa, q = (rp.claude_argv(arms, a) for a in "VSQ")
diff = [(x, y) for x, y in zip(v, sa) if x != y]
pv, ps, pq = (rp.render_prompt("Which file?", a, arms) for a in "VSQ")
print(json.dumps({"sq_equal": sa == q, "vs_diff": [d[1].replace(d[0], "").strip(",") for d in diff], "len": len(v) == len(sa),
                  "flags": all(f in v for f in ("--safe-mode", "--strict-mcp-config", "--setting-sources", "--settings", "--output-format")),
                  "setting_sources_empty": v[v.index("--setting-sources") + 1] == "",
                  "prompt_sq_equal": ps == pq, "prompt_v_has_note": "s-qmd" in pv, "prompt_s_has_note": "s-qmd" in ps,
                  "prompt_v_is_s_minus_note": pv.replace("\n\n", "\n") == ps.replace(open(sys.argv[1] + "/tools/s-note.md").read(), "").replace("\n\n", "\n"),
                  "env": arms["env"], "absent": "CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS" in arms["env_absent"],
                  "q_key": arms["arms"]["Q"]["key"], "q_base_url": arms["arms"]["Q"]["base_url"], "s_key": arms["arms"]["S"]["key"]}))
EOF
)
eq "P14: S and Q launch with byte-identical argv" true "$(f "$P14" sq_equal)"
eq "P14: V differs from S only by the two retrieval commands in allowedTools" '["Bash(s-qmd:*),Bash(s-graph:*)"]' "$(f "$P14" vs_diff)"
eq "P14: the pinned flags are present and setting sources are explicitly empty" "true true" "$(f "$P14" flags) $(f "$P14" setting_sources_empty)"
eq "P14: S and Q get the same prompt with the shared note; V gets it without" "true false true true" "$(f "$P14" prompt_sq_equal) $(f "$P14" prompt_v_has_note) $(f "$P14" prompt_s_has_note) $(f "$P14" prompt_v_is_s_minus_note)"
eq "P14: the locked session environment" '{"BASH_DEFAULT_TIMEOUT_MS": "600000", "BASH_MAX_TIMEOUT_MS": "600000", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1", "DISABLE_AUTOUPDATER": "1"} true' "$(f "$P14" env) $(f "$P14" absent)"
eq "P14: Q has no key and no remote endpoint; S has the dedicated key" "false null true" "$(f "$P14" q_key) $(f "$P14" q_base_url) $(f "$P14" s_key)"
eq "P14: the read-only profile denies /proc and the session home, and blocks reads outside /work" "yes" "$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; print("yes" if "Read(//proc/**)" in p["deny"] and "Read(//session/.claude/**)" in p["deny"] and p["blockReadsOutsideWorkingDirectories"] else "no")' "$HERE/session-permissions.json")"

mkdir -p "$W/home-V" "$W/home-S" "$W/home-Q" "$W/ex/himmel/docs" "$W/ex/luna/notes" "$W/private" "$W/station" "$W/qcfg" "$W/graph" "$W/man" "$W/models" "$W/qpkg"
printf 'lock\n' > "$W/ex/himmel/docs/lock.md"; printf 'garden\n' > "$W/ex/luna/notes/garden.md"; printf 'secret task\n' > "$W/private/tasks.jsonl"
printf 'station cred\n' > "$W/station/cred"; : > "$W/binding.json"; : > "$W/sock"; : > "$W/index.sqlite"; printf 'dummy\n' > "$W/key"
cp "$FX/stub-claude" "$W/stub-claude"; chmod +x "$W/stub-claude"
base=(--himmel "$W/ex/himmel" --luna "$W/ex/luna" --claude "$W/stub-claude" --settings "$HERE/session-permissions.json"
      --env CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 --env CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1)
ret=(--tools "$HERE/tools" --binding "$W/binding.json" --socket "$W/sock" --index "$W/index.sqlite" --qmd-pkg "$W/qpkg"
     --qmd-config "$W/qcfg" --graph "$W/graph" --manifests "$W/man")
sb() { bash "$HERE/sandbox.sh" "$@"; }
eq "sandbox: V refuses a retrieval mount" 3 "$(sb --arm V --home "$W/home-V" "${base[@]}" --tools "$HERE/tools" --print -- /opt/claude/claude >/dev/null 2>&1; echo $?)"
eq "sandbox: Q refuses the S key" 3 "$(sb --arm Q --home "$W/home-Q" "${base[@]}" "${ret[@]}" --models "$W/models" --key "$W/key" --print -- x >/dev/null 2>&1; echo $?)"
eq "sandbox: S refuses to start without its dedicated key" 3 "$(sb --arm S --home "$W/home-S" "${base[@]}" "${ret[@]}" --print -- x >/dev/null 2>&1; echo $?)"
sb --arm S --home "$W/home-S" "${base[@]}" "${ret[@]}" --key "$W/key" --print -- x > "$W/argv-S"
sb --arm Q --home "$W/home-Q" "${base[@]}" "${ret[@]}" --models "$W/models" --print -- x > "$W/argv-Q"
sb --arm V --home "$W/home-V" "${base[@]}" --print -- x > "$W/argv-V"
mkdir -p "$W/fakebin"; printf '#!/bin/sh\necho usr/lib64\n' > "$W/fakebin/readlink"; chmod +x "$W/fakebin/readlink"
eq "sandbox: /lib64 mirrors the host link, so the loader resolves on a usr/lib64 host" "usr/lib64" "$(PATH="$W/fakebin:$PATH" sb --arm V --home "$W/home-V" "${base[@]}" --print -- x | grep -B1 -x /lib64 | head -n1)"
eq "P14: V's namespace has no /run/pilot mount at all" 0 "$(grep -c '^/run/pilot' "$W/argv-V")"
eq "P14: S and Q mount the same retrieval paths except key versus weights" "/run/pilot/key|/run/pilot/models" "$(diff <(grep '^/run/pilot' "$W/argv-S") <(grep '^/run/pilot' "$W/argv-Q") | grep -E '^[<>]' | sed 's/^[<>] //' | sort | paste -sd'|' -)"
if ! command -v bwrap >/dev/null 2>&1 || ! bwrap --ro-bind / / true 2>/dev/null; then
  printf 'SKIP - P15 real namespace rows: no unprivileged bwrap on this host\n'
else
  for a in V S Q; do
    extra=(); [ "$a" = S ] && extra=("${ret[@]}" --key "$W/key"); [ "$a" = Q ] && extra=("${ret[@]}" --models "$W/models")
    sb --arm "$a" --home "$W/home-$a" "${base[@]}" ${extra[@]+"${extra[@]}"} -- /opt/claude/claude "$W/private/tasks.jsonl" "$W/station/cred" > "$W/ns-$a.json" 2>"$W/ns-$a.err"
  done
  for a in V S Q; do [ -s "$W/ns-$a.json" ] || sed "s/^/ns-$a.err: /" "$W/ns-$a.err"; done
  NV=$(cat "$W/ns-V.json"); NS=$(cat "$W/ns-S.json"); NQ=$(cat "$W/ns-Q.json")
  eq "P15: every arm reads the two exports read-only from /work" '"yes" "yes" "no" "/work"' "$(f "$NV" work) $(f "$NV" luna) $(f "$NV" work_writable) $(f "$NV" cwd)"
  eq "P15: no arm can reach the private task file or a station path" '"no" "no" "no" "no" "no" "no"' "$(f "$NV" private) $(f "$NV" station) $(f "$NS" private) $(f "$NS" station) $(f "$NQ" private) $(f "$NQ" station)"
  eq "P15: the session home is /session and the locked scrub/background env is set" '"/session" "1" "1"' "$(f "$NV" home) $(f "$NV" scrub) $(f "$NV" bg)"
  eq "P15: V has no retrieval command, binding, key or weights" '"no" "no" "no" "no" "no"' "$(f "$NV" sqmd) $(f "$NV" tools) $(f "$NV" binding) $(f "$NV" key) $(f "$NV" models)"
  eq "P15: S has the wrappers and the dedicated key file, no weights" '"yes" "yes" "no"' "$(f "$NS" sqmd) $(f "$NS" key) $(f "$NS" models)"
  eq "P15: Q has the wrappers and the weights, never the S key" '"yes" "no" "yes"' "$(f "$NQ" sqmd) $(f "$NQ" key) $(f "$NQ" models)"
  eq "P15: no key variable reaches any session environment" '"none" "none" "none"' "$(f "$NV" qkey) $(f "$NS" qkey) $(f "$NQ" qkey)"
  eq "P15: each session has its own PID namespace and the read-only profile" '"yes"' "$( [ "$(f "$NV" pid1)" != '"systemd"' ] && f "$NV" settings || echo '"pid1 is the host init"')"
fi

mkdir -p "$W/g0/proof"; printf 'claude binary\n' > "$W/g0/claude"; printf 'scrub fixture output\n' > "$W/g0/proof/scrub.txt"
python3 -I "$HERE/tools-lock.py" build --out "$W/g0/tools.lock" --h0 a --l0 b --file claude="$W/g0/claude" --file sandbox="$HERE/sandbox.sh" \
  --file settings="$HERE/session-permissions.json" --const claude_version=2.1.319 >/dev/null
python3 -I - "$W/g0" "$HERE" <<'EOF'
import hashlib, json, sys
g, here = sys.argv[1], sys.argv[2]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
fp = lambda s: hashlib.sha256(s.encode()).hexdigest()
r = {"schema": "rag-pilot-auth-readiness/1", "lock_sha256": sha(g + "/tools.lock"),
     "mechanism": {"id": "claude-setup-token/CLAUDE_CODE_OAUTH_TOKEN", "retrieved": "2026-11-09", "cli_version": "2.1.319",
                   "sources": ["https://code.claude.com/docs/en/cli-reference", "https://code.claude.com/docs/en/authentication#generate-a-long-lived-token"],
                   "cli_sha256": sha(g + "/claude"), "sandbox_sha256": sha(here + "/sandbox.sh"), "settings_sha256": sha(here + "/session-permissions.json")},
     "provisioning": {"operator": "fixture operator", "date": "2026-11-09", "eval_account": "fixture eval account", "credential_root_fingerprint": fp("root"),
                      "path_fingerprint": fp("path"), "revocation_procedure": "fixture: revoke through the provider console",
                      "independence": {"kind": "separate_eval_identity", "evidence": "fixture: a separate eval account"}},
     "station_nonmutation": {"before": {"path": fp("s"), "inode": 1, "digest": fp("d")}, "after": {"path": fp("s"), "inode": 1, "digest": fp("d")},
                             "eval_station_alias": False, "station_mounted": False},
     "stance": {"selected": "eval-only-reachable", "decision": "operator conversation 2026-11-09", "design_revision": "r18", "card_sha256": fp("card")},
     "r4": {"ran": True, "shape_sha256": sha(here + "/sandbox.sh"), "station_reachable": False, "other_account_reachable": False,
            "channels": {"bash_env": "no", "bash_proc_ancestors": "no", "native_proc": {"Read": "no", "Grep": "no", "Glob": "no"},
                         "session_home": {"Read": "yes", "Grep": "no", "Glob": "no", "Bash": "yes"}}},
     "scrub": {"fixtures_pass": True, "revocation_recorded": True, "artifacts": {"scrub": {"path": "proof/scrub.txt", "sha256": sha(g + "/proof/scrub.txt")}}}}
json.dump(r, open(g + "/ready.json", "w"), indent=1)
json.dump({"passed": True}, open(g + "/bare.json", "w"))
EOF
CARD=$(printf 'card' | sha256sum | cut -d' ' -f1)
g0() { python3 -I "$HERE/auth-preflight.py" --readiness "$1" --lock "$W/g0/tools.lock" --card-sha256 "${2:-$CARD}" "${@:3}"; }
out=$(g0 "$W/g0/ready.json" "$CARD" --stance eval-only-reachable); rc=$?
eq "G0: a complete record under the recorded reachable stance is READY (P2 not required for R5)" 0 "$rc"
has "G0: READY names the stance and never claims isolation" "never called isolation" "$out"
eq "G0: a bare passed:true record proves nothing" 3 "$(g0 "$W/g0/bare.json" >/dev/null; echo $?)"
mut() { # <label> <reason fragment> <python mutation of r>
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(r, open(sys.argv[2],"w"))' "$W/g0/ready.json" "$W/g0/m.json" "$3"
  local o; o=$(g0 "$W/g0/m.json" "$CARD" --stance eval-only-reachable); local rc=$?
  eq "G0: $1 blocks paid work" 3 "$rc"
  has "G0: $1 names its reason" "$2" "$o"
}
mut "another mechanism" "1: mechanism" 'r["mechanism"]["id"] = "station-login-copy"'
mut "missing official sources" "1: official source" 'r["mechanism"]["sources"] = []'
mut "a different CLI build" "1: cli_sha256" 'r["mechanism"]["cli_sha256"] = "0" * 64'
mut "a missing provisioning field" "2: provisioning record lacks revocation_procedure" 'del r["provisioning"]["revocation_procedure"]'
mut "file non-mutation as the only independence proof" "2: no independence" 'r["provisioning"]["independence"] = {"kind": "file_unchanged", "evidence": "x"}'
mut "a changed station credential digest" "3: station" 'r["station_nonmutation"]["after"]["digest"] = "0" * 64'
mut "an eval/station alias" "3: an eval/station alias" 'r["station_nonmutation"]["eval_station_alias"] = True'
mut "another card" "4: the stance" 'r["stance"]["card_sha256"] = "0" * 64'
mut "R4 not run" "5: R4 did not run" 'r["r4"]["ran"] = False'
mut "an unknown channel" "5: channel native_proc has no definite result" 'r["r4"]["channels"]["native_proc"]["Glob"] = "unknown"'
mut "station reachability" "5: station or other-account" 'r["r4"]["station_reachable"] = True'
mut "failed scrub fixtures" "6: scrub fixtures" 'r["scrub"]["fixtures_pass"] = False'
mut "a changed proof artifact" "6: proof artifact scrub" 'r["scrub"]["artifacts"]["scrub"]["sha256"] = "0" * 64'
mut "a record bound to another lock (stale)" "stale" 'r["lock_sha256"] = "0" * 64'
mut "token bytes in the record" "credential-shaped value" 'r["provisioning"]["eval_account"] = "sk-ant-oat01-" + "A" * 60'
eq "G0: the legacy unreadable stance refuses any readable channel (negative control)" 3 "$(g0 "$W/g0/ready.json" "$CARD" --stance unreadable >/dev/null; echo $?)"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["stance"]["selected"]="unreadable"; r["r4"]["channels"]["session_home"]={"Read":"no","Grep":"no","Glob":"no","Bash":"no"}; json.dump(r, open(sys.argv[2],"w"))' "$W/g0/ready.json" "$W/g0/strict.json"
eq "G0: an all-denied record satisfies the unreadable stance" 0 "$(g0 "$W/g0/strict.json" "$CARD" --stance unreadable >/dev/null; echo $?)"

python3 -I - "$W/g0" <<'EOF'
import hashlib, json, os, sys
g = sys.argv[1]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def mk(p, data, mode=0o600):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(data)
    os.chmod(p, mode)
mk(g + "/secrets/claude-oauth-token", "fixture-not-a-token\n")
mk(g + "/state/qmd-key.env", "QMD_OPENAI_API_KEY=fixture-key\n")
os.makedirs(g + "/HIMMEL-9264-rerun-2026-11-14/private", mode=0o700)
mk(g + "/proof/rotate-answer.md", "fixture: rotate the shared token, fleet-wide\n", 0o644)
mk(g + "/proof/rotate-search.md", "fixture: rotate the regular key, re-derive s-key, re-pin the binding\n", 0o644)
mk(g + "/var/empty-token", "")
mk(g + "/var/group-token", "x\n", 0o640)
mk(g + "/var/linked-token", "x\n"); os.link(g + "/var/linked-token", g + "/var/linked-token-2")
os.symlink(g + "/secrets/claude-oauth-token", g + "/var/symlink-token")
mk(g + "/var/.credentials.json", "{}\n")
legacy = json.load(open(g + "/ready.json"))
r = {"schema": "rag-pilot-auth-readiness/1", "lock_sha256": legacy["lock_sha256"],
     "credentials": {"answer": {"kind": "shared-subscription", "source_path": g + "/secrets/claude-oauth-token"},
                     "search": {"kind": "regular-openrouter-key", "source_path": g + "/state/qmd-key.env",
                                "derived_path": g + "/HIMMEL-9264-rerun-2026-11-14/private/s-key"}},
     "stance": {"selected": "shared-credentials", "decision": "decision 946 (operator 2026-11-15)", "design_revision": "r20",
                "card_sha256": legacy["stance"]["card_sha256"]},
     "r4": legacy["r4"], "scrub": {"fixtures_pass": True, "artifacts": legacy["scrub"]["artifacts"]},
     "rotation": {"answer": {"path": "proof/rotate-answer.md", "sha256": sha(g + "/proof/rotate-answer.md")},
                  "search": {"path": "proof/rotate-search.md", "sha256": sha(g + "/proof/rotate-search.md")}}}
json.dump(r, open(g + "/shared.json", "w"), indent=1)
EOF
TOK="$W/g0/secrets/claude-oauth-token"; SKEY="$W/g0/HIMMEL-9264-rerun-2026-11-14/private/s-key"
sg0() { g0 "$1" "$CARD" --answer-file "${2:-$TOK}" --search-key-file "${3:-$SKEY}"; }
out=$(sg0 "$W/g0/shared.json"); rc=$?
eq "G0 r20: a complete shared-credentials record is READY under the default stance" 0 "$rc"
has "G0 r20: READY names the stance on its own line" "stance: shared-credentials" "$out"
has "G0 r20: READY says the credentials are shared with the fleet" "shared with the fleet" "$out"
smut() {
  python3 -I -c 'import json,sys; g=sys.argv[4]; r=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(r, open(sys.argv[2],"w"))' "$W/g0/shared.json" "$W/g0/sm.json" "$3" "$W/g0"
  local o; o=$(sg0 "$W/g0/sm.json"); local rc=$?
  eq "G0 r20: $1 blocks paid work" 3 "$rc"
  has "G0 r20: $1 names its reason" "$2" "$o"
}
smut "an unknown channel" "S: unknown channel embed" 'r["credentials"]["embed"] = {"kind": "regular-openrouter-key", "source_path": "/x"}'
smut "a missing search channel" "S: missing channel search" 'del r["credentials"]["search"]'
smut "the API key as the answer kind" "S: unknown kind api-key for answer" 'r["credentials"]["answer"]["kind"] = "api-key"'
smut "a symlinked answer source" "S: the answer source is a symlink" 'r["credentials"]["answer"]["source_path"] = g + "/var/symlink-token"'
smut "an answer source with two hard links" "S: the answer source has 2 hard links" 'r["credentials"]["answer"]["source_path"] = g + "/var/linked-token"'
smut "an empty answer source" "S: the answer source is empty" 'r["credentials"]["answer"]["source_path"] = g + "/var/empty-token"'
smut "a group-readable answer source" "S: the answer source has mode 0640" 'r["credentials"]["answer"]["source_path"] = g + "/var/group-token"'
smut "the interactive login file as the answer source" "S: the answer source is the interactive login file" 'r["credentials"]["answer"]["source_path"] = g + "/var/.credentials.json"'
smut "a token-shaped value in the statement" "credential-shaped value at .credentials.search.note" 'r["credentials"]["search"]["note"] = "sk-or-v1-" + "a1B2" * 12'
smut "a credential field beside the paths" "S: search carries a field that is not a path or kind (note)" 'r["credentials"]["search"]["note"] = "plain"'
smut "a token pasted as a path component" "credential-shaped value at .credentials.answer.source_path" 'r["credentials"]["answer"]["source_path"] = g + "/" + "aB3dE5" * 8'
smut "a stance bound to r18" "4: the stance" 'r["stance"]["design_revision"] = "r18"'
smut "a stance without decision 946" "4: the stance" 'r["stance"]["decision"] = "operator conversation"'
smut "a stance naming decision 1946" "4: the stance" 'r["stance"]["decision"] = "decision 1946"'
smut "a token in the kind field" "S: unknown kind [redacted] for answer" 'r["credentials"]["answer"]["kind"] = "sk-ant-oat01-" + "Zq9" * 20'
smut "a token as a channel name" "S: unknown channel [redacted]" 'r["credentials"]["sk-or-v1-" + "Zq9" * 20] = {}'
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["credentials"]["answer"]["kind"]="sk-ant-oat01-"+"Zq9"*20; r["r4"]["channels"]["bash_env"]="sk-or-v1-"+"Zq9"*20; json.dump(r, open(sys.argv[2],"w"))' "$W/g0/shared.json" "$W/g0/tok.json"
eq "G0 r20: no diagnostic repeats a token-shaped record value" no "$(case "$(sg0 "$W/g0/tok.json")" in (*Zq9Zq9*) echo yes ;; (*) echo no ;; esac)"
smut "a missing rotation procedure" "6: the rotation procedure for search is missing or its hash changed" 'del r["rotation"]["search"]'
smut "a changed rotation procedure" "6: the rotation procedure for answer is missing or its hash changed" 'r["rotation"]["answer"]["sha256"] = "0" * 64'
smut "an unknown channel result" "5: channel native_proc has no definite result" 'r["r4"]["channels"]["native_proc"]["Glob"] = "unknown"'
smut "station reachability" "5: station or other-account" 'r["r4"]["station_reachable"] = True'
smut "failed scrub fixtures" "6: scrub fixtures" 'r["scrub"]["fixtures_pass"] = False'
smut "a changed proof artifact" "6: proof artifact scrub" 'r["scrub"]["artifacts"]["scrub"]["sha256"] = "0" * 64'
o=$(sg0 "$W/g0/shared.json" "$W/g0/var/group-token"); rc=$?
eq "G0 r20: a configured answer file that disagrees with the statement blocks paid work" 3 "$rc"
has "G0 r20: the answer disagreement names its reason" "S: the configured answer file is not the stated answer source_path" "$o"
o=$(sg0 "$W/g0/shared.json" "$TOK" "$W/g0/other-s-key"); rc=$?
eq "G0 r20: a configured S key file that disagrees with the statement blocks paid work" 3 "$rc"
has "G0 r20: the S key disagreement names its reason" "S: the configured S key file is not the stated search derived_path" "$o"
eq "G0 r20: the legacy record does not pass the default shared-credentials stance" 3 "$(sg0 "$W/g0/ready.json" >/dev/null; echo $?)"

D="$W/derive"; mkdir -p "$D/out"; chmod 700 "$D/out"
printf 'QMD_OPENAI_PROVIDER=openrouter\nQMD_OPENAI_API_KEY=fixture-or-key-123\nQMD_OPENAI_EMBED_BATCH_SIZE=64\nQMD_OPENAI_EMBED_CONCURRENCY=4\nQMD_QUERY_MAX_QUEUED=8\nQMD_OPENAI_API_KEY=second-line-ignored\n' > "$D/qmd-key.env"  # gitleaks:allow fake fixture key
chmod 600 "$D/qmd-key.env"
dsk() { python3 -I "$HERE/run-pilot.py" derive-s-key --source "$1" --out "$2" 2>&1; }
out=$(dsk "$D/qmd-key.env" "$D/out/s-key"); rc=$?
eq "derive-s-key: the qmd key-file line format yields exactly the first key line's value in a 0600 file" "0 fixture-or-key-123 600" "$rc $(cat "$D/out/s-key" 2>/dev/null) $(python3 -I -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$D/out/s-key" 2>/dev/null)"
eq "derive-s-key: the value is never printed" no "$(case "$out" in (*fixture-or-key*) echo yes ;; (*) echo no ;; esac)"
printf 'models:\n  embed: openai:x\nbase_url: https://openrouter.ai/api/v1\n' > "$D/index.yml"
PARITY=$(bash -c '. "$1"; QMD_DAEMON_ENV_FILE="$2" qmd_daemon_key_load "$3" && printf %s "$QMD_OPENAI_API_KEY"' _ "$HERE/../../../lib/qmd-daemon-env.sh" "$D/qmd-key.env" "$D/index.yml")  # t13b-ok: sources the qmd key loader to read a fixture file, starts nothing
eq "derive-s-key: parity with the qmd key loader on the same file" "$PARITY" "$(cat "$D/out/s-key" 2>/dev/null)"
for m in 640 700; do
  cp "$D/qmd-key.env" "$D/env-$m"; chmod "$m" "$D/env-$m"
  dsk "$D/env-$m" "$D/out/k-$m" > /dev/null; rc=$?
  eq "derive-s-key: a source with mode $m refuses and writes nothing" "3 no" "$rc $([ -e "$D/out/k-$m" ] && echo yes || echo no)"
done
printf 'QMD_OPENAI_PROVIDER=openrouter\n' > "$D/env-nokey"; printf 'QMD_OPENAI_API_KEY=\n' > "$D/env-empty"; chmod 600 "$D/env-nokey" "$D/env-empty"
for c in nokey empty; do
  dsk "$D/env-$c" "$D/out/k-$c" > /dev/null; rc=$?
  eq "derive-s-key: a source with $c refuses and writes nothing" "3 no" "$rc $([ -e "$D/out/k-$c" ] && echo yes || echo no)"
done
dsk "$D/qmd-key.env" "$D/out/s-key" > /dev/null; rc=$?
eq "derive-s-key: an existing output refuses and is left as it was" "3 fixture-or-key-123" "$rc $(cat "$D/out/s-key")"
ln -s "$D/nowhere" "$D/out/dangling"
dsk "$D/qmd-key.env" "$D/out/dangling" > /dev/null; rc=$?
eq "derive-s-key: a dangling symlink at the output refuses and creates nothing" "3 no" "$rc $([ -e "$D/nowhere" ] && echo yes || echo no)"
ln -s "$D/qmd-key.env" "$D/env-link"
dsk "$D/env-link" "$D/out/k-link" > /dev/null; rc=$?
eq "derive-s-key: a symlinked source refuses and writes nothing" "3 no" "$rc $([ -e "$D/out/k-link" ] && echo yes || echo no)"
mkdir -p "$D/open"; chmod 755 "$D/open"
dsk "$D/qmd-key.env" "$D/open/s-key" > /dev/null; rc=$?
eq "derive-s-key: an output directory that is not 0700 refuses" "3 no" "$rc $([ -e "$D/open/s-key" ] && echo yes || echo no)"

printf 'card' > "$W/g0/card"; : > "$W/g0/r8go"
NZ=$(python3 -I - "$HERE" "$W" <<'EOF'
import hashlib, importlib.util, json, os, sys
here, w = sys.argv[1], sys.argv[2]
s = importlib.util.spec_from_file_location("rp", here + "/run-pilot.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
L = rp.L; g = w + "/g0"; out = {}
cfg = {"card": g + "/card", "astra_review": g + "/noreview", "r8_go": g + "/r8go", "lock": g + "/tools.lock", "auth_readiness": g + "/shared.json",
       "eval_token_file": g + "/secrets/claude-oauth-token", "s_key_file": g + "/HIMMEL-9264-rerun-2026-11-14/private/s-key", "run_root": w + "/nzrun"}
os.makedirs(cfg["run_root"])
g0lines = lambda c: [b for b in rp.gates(c) if b.startswith("G0")]
out["g0_match"] = g0lines(cfg)
out["g0_answer_mismatch"] = g0lines(dict(cfg, eval_token_file=g + "/var/group-token"))
out["g0_key_mismatch"] = g0lines(dict(cfg, s_key_file=g + "/other-s-key"))
out["gates_run_root_files"] = sum(len(fs) for _, _, fs in os.walk(cfg["run_root"]))
tf = w + "/tok1"; open(tf, "w").write("  tok-value  \n")
t2 = w + "/tok2"; open(t2, "w").write("tok-value\nsecond\n")
try:
    rp.read_token(t2); two = "accepted"
except ValueError:
    two = "refused"
out["token"] = [rp.read_token(tf), two]
key = w + "/fake-s-key"; open(key, "w").write("fixture-key"); fpk = hashlib.sha256(b"fixture-key").hexdigest()

class Meter:
    def __init__(self, vals):
        self.vals = list(vals)
    def read(self):
        return self.vals.pop(0)
class Clk:
    t = 5000.0
    def now(self):
        return self.t
    def sleep(self, s):
        self.t += s
def mb(name, vals, window=600):
    p = w + "/mb-" + name + ".json"
    try:
        rp.meter_baseline(key, window, p, Meter(vals), Clk())
        rec = json.load(open(p))
        return [round(rec["rate"], 9), rec["window_s"], rec["key_fingerprint"] == fpk, oct(os.stat(p).st_mode & 0o777), "fixture-key" in open(p).read()]
    except rp.Refuse as e:
        return ["refused", os.path.exists(p)]
out["mb_ok"] = mb("ok", [1.0, 1.06]); out["mb_neg"] = mb("neg", [1.0, 0.9]); out["mb_none"] = mb("none", [None, 1.0]); out["mb_window"] = mb("win", [1.0, 1.0], 100)

base = {"start_meter": 1.0, "end_meter": 1.06, "start_ts": 4400.0, "end_ts": 5000.0, "window_s": 600, "key_fingerprint": fpk, "rate": 0.0001}
bp = w + "/bl.json"; json.dump(base, open(bp, "w"))
nb = lambda stance, c: rp.noise_binding(stance, c)[1]
c2 = dict(cfg, s_key_file=key, noise_baseline=bp, expected_duration_s=1200)
out["nb_ok"] = nb("shared-credentials", c2)
out["nb_missing"] = nb("shared-credentials", dict(c2, noise_baseline=None))
json.dump(dict(base, key_fingerprint="0" * 64), open(w + "/bl-fp.json", "w")); out["nb_fp"] = nb("shared-credentials", dict(c2, noise_baseline=w + "/bl-fp.json"))
json.dump(dict(base, window_s=300), open(w + "/bl-win.json", "w")); out["nb_window"] = nb("shared-credentials", dict(c2, noise_baseline=w + "/bl-win.json"))
out["nb_noisy"] = nb("shared-credentials", dict(c2, expected_duration_s=600000))
json.dump(dict(base, rate=0.0002), open(w + "/bl-rate.json", "w")); out["nb_inconsistent"] = nb("shared-credentials", dict(c2, noise_baseline=w + "/bl-rate.json"))
open(w + "/bl-bad.json", "w").write("{not json"); out["nb_malformed"] = nb("shared-credentials", dict(c2, noise_baseline=w + "/bl-bad.json"))
out["nb_legacy_with"] = nb("eval-only-reachable", c2)
out["nb_legacy_without"] = nb("eval-only-reachable", dict(c2, noise_baseline=None))
print(json.dumps(out, sort_keys=True))
EOF
)
eq "R8 gates: a config that matches the statement raises no G0 refusal" '[]' "$(f "$NZ" g0_match)"
has "R8 gates: a configured answer file that disagrees with the record refuses with a G0 reason" "configured answer file" "$(f "$NZ" g0_answer_mismatch)"
has "R8 gates: a configured S key file that disagrees with the record refuses with a G0 reason" "configured S key file" "$(f "$NZ" g0_key_mismatch)"
eq "R8 gates: the refusals booked and launched nothing (the run root stays empty)" 0 "$(f "$NZ" gates_run_root_files)"
eq "token: the answer token is the first line, whitespace stripped; a second line refuses" '["tok-value", "refused"]' "$(f "$NZ" token)"
eq "meter-baseline: two reads over the window give the rate, the key fingerprint, mode 0600 and no key value" '[0.0001, 600, true, "0o600", false]' "$(f "$NZ" mb_ok)"
eq "meter-baseline: a negative delta refuses and writes nothing" '["refused", false]' "$(f "$NZ" mb_neg)"
eq "meter-baseline: an unreadable meter refuses and writes nothing" '["refused", false]' "$(f "$NZ" mb_none)"
eq "meter-baseline: a window outside 600 to 1800 s refuses" '["refused", false]' "$(f "$NZ" mb_window)"
eq "noise binding: a current baseline on the bound key with a feasible duration is accepted" '[]' "$(f "$NZ" nb_ok)"
has "noise binding: shared-credentials without a baseline refuses" "needs a noise baseline" "$(f "$NZ" nb_missing)"
has "noise binding: a baseline taken on another key refuses" "another key" "$(f "$NZ" nb_fp)"
has "noise binding: a baseline window out of range refuses" "window" "$(f "$NZ" nb_window)"
has "noise binding: a fleet too noisy for the stated duration refuses" "too noisy" "$(f "$NZ" nb_noisy)"
has "noise binding: a rate that does not match the meters over the window refuses" "inconsistent" "$(f "$NZ" nb_inconsistent)"
has "noise binding: a malformed baseline refuses" "unreadable" "$(f "$NZ" nb_malformed)"
has "noise binding: a baseline under a legacy stance refuses (a file never switches the allowance on)" "legacy stance" "$(f "$NZ" nb_legacy_with)"
eq "noise binding: a legacy stance without a baseline needs none" '[]' "$(f "$NZ" nb_legacy_without)"

python3 -I - "$HERE" "$W" > "$W/noise.out" 2>&1 <<'EOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("ledger", sys.argv[1] + "/ledger.py"); L = importlib.util.module_from_spec(s); s.loader.exec_module(L)
W = sys.argv[2]; out = {}
def led(name, cap=L.CAP_PILOT, noise=L.NOISE_CAP_R8, rate=0.0003):
    l = L.Ledger(W + "/" + name + ".jsonl", cap=cap)
    l.noise_start("/run/noise-baseline-R8.json", "f" * 64, rate, 1000.0)
    l.reserve("noise", noise)
    l.meter_start(0.0, 1000.0)
    return l
a = led("n1"); a.book("q1", "s_query", .004); a.book("q2", "s_query", .004)
ok = a.settle_s_interval(.018, 2, meter=.018, ts=1060.0)
e = a.events[-1]
out["within"] = [ok, a.stop, round(a.spent, 6), round(e["absorbed"], 6), round(e["expected_noise"], 6), round(a.reserves["noise"], 6), a.b]
b = led("n2"); b.book("q1", "s_query", .004); b.book("q2", "s_query", .004)
out["above"] = [b.settle_s_interval(.068, 2, meter=.068, ts=1060.0), b.stop]
c = led("n3"); out["unbooked_under"] = [c.settle_s_interval(.03, 0, meter=.03, ts=1060.0), c.stop, round(c.spent, 6)]
d = led("n4"); out["unbooked_above"] = [d.settle_s_interval(.06, 0, meter=.06, ts=1060.0), d.stop]
x = led("n5", cap=0.033, noise=0.02); x.book("q1", "s_query", .004); x.book("q2", "s_query", .004)
r1 = x.settle_s_interval(.028, 2, meter=.028, ts=1060.0)
edge = [r1, x.committed() <= x.cap + L.EPS, round(x.reserves.get("noise", 0.0), 6)]
x.book("q3", "s_query", .004)
out["reserve_edge"] = edge + [x.settle_s_interval(.005, 1, meter=.033, ts=1120.0), x.stop]
y = L.Ledger(W + "/n1.jsonl")
out["replay"] = [round(y.noise_absorbed, 6), round(y.reserves["noise"], 6), y.noise_rate, y.last_meter()]
print(json.dumps(out, sort_keys=True))
EOF
NO=$(tail -1 "$W/noise.out")
eq "noise R8: an excess within A(t) settles, books the full delta, draws absorbed from the reserve and reprices net of E(t)" '[true, null, 0.018, 0.01, 0.018, 0.49, 0.004]' "$(f "$NO" within 2>/dev/null)"
eq "noise R8: an excess above A(t) is a HARD_STOP overrun" '[false, {"kind": "HARD_STOP", "reason": "overrun"}]' "$(f "$NO" above 2>/dev/null)"
eq "noise R8: an unbooked delta under A(t) settles and counts as spend" '[true, null, 0.03]' "$(f "$NO" unbooked_under 2>/dev/null)"
eq "noise R8: an unbooked delta above A(t) is unknown_spend" '[false, {"kind": "HARD_STOP", "reason": "unknown_spend"}]' "$(f "$NO" unbooked_above 2>/dev/null)"
eq "noise R8: absorbing at the reserve's edge keeps committed within the cap; a spent reserve stops the next excess" '[true, true, 0.0, false, {"kind": "HARD_STOP", "reason": "overrun"}]' "$(f "$NO" reserve_edge 2>/dev/null)"
eq "noise R8: a restart replays the absorbed total, the reserve, the rate and the last reading" '[0.01, 0.49, 0.0003, 0.018]' "$(f "$NO" replay 2>/dev/null)"
R=$(sc meter-start); eq "R8: the first meter reading is a durable event before the first S booking, and the first interval is metered from it" 'true 1 true' "$(f "$R" start_before_first_s) $(f "$R" starts) $(f "$R" first_delta_ok)"
R=$(sc meter-start-restart); eq "R8: a restart before the first settle replays meter_start, never re-reads it" '1 true' "$(f "$R" starts) $(f "$R" first_delta_ok)"
R=$(sc fleet-noise); eq "R8: steady fleet noise on the shared key is absorbed and the run completes" '["NONE", null] 40 true true' "$(f "$R" stop) $(f "$R" common) $(f "$R" absorbed_positive) $(f "$R" first_event_is_baseline)"
R=$(sc fleet-noise-legacy); eq "R8: the same fleet noise without a baseline (legacy stance) still stops as r19 does" '["HARD_STOP", "overrun"]' "$(f "$R" stop)"
R=$(sc noise-stale); eq "R8: a baseline older than 2 hours refuses before any booking or launch" '"noise" 0 0' "$(f "$R" refused) $(f "$R" launches) $(f "$R" events)"
R=$(sc noise-other-baseline); eq "R8: a restart with a different baseline refuses" '"noise"' "$(f "$R" refused)"
R=$(sc noise-future); eq "R8: a baseline that ends after the run's start refuses before any booking" '"noise" 0' "$(f "$R" refused) $(f "$R" events)"
R=$(sc noise-late-baseline); eq "R8: a baseline added to a run that started without one refuses" '"noise"' "$(f "$R" refused)"

cat > "$W/runner.py" <<'EOF'
import importlib.util, os, sys, time
s = importlib.util.spec_from_file_location("rp", sys.argv[1] + "/run-pilot.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
w = sys.argv[2]
if sys.argv[3:] == ["orphan"]:
    pretend_runner_already_died = lambda: 1
    rp.os.getpid = pretend_runner_already_died
    b = rp.start_broker_bound_to_runner([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        b.wait(timeout=10); print("exit", b.returncode)
    except Exception:
        b.kill(); print("still running")
    sys.exit(0)
b = rp.start_broker_bound_to_runner([sys.executable, "-I", sys.argv[1] + "/tools/s-qmd", "serve", "--socket", w + "/rb.sock", "--meta", w + "/rb-meta", "--phase", "answer", "--arm", "S"])
open(w + "/broker.pid", "w").write(str(b.pid))
if len(sys.argv) > 3:
    b.terminate(); b.wait(timeout=10); print("stopped", b.poll() is not None); sys.exit(0)
time.sleep(60)
EOF
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
waitsock() { for _ in $(seq 150); do [ -S "$W/rb.sock" ] && return 0; sleep 0.02; done; return 1; }
python3 -I "$W/runner.py" "$HERE" "$W" &
RUNNER=$!
waitsock; BROKER=$(cat "$W/broker.pid" 2>/dev/null)
eq "broker: the broker is up while its runner lives" yes "$(alive "$BROKER" && echo yes || echo no)"
kill -9 "$RUNNER"; wait "$RUNNER" 2>/dev/null
for _ in $(seq 100); do alive "$BROKER" || break; sleep 0.05; done
eq "broker: a hard kill of the runner ends the broker" no "$(alive "$BROKER" && echo yes || echo no)"
alive "$BROKER" && kill -9 "$BROKER"
rm -rf "$W/rb.sock" "$W/rb-meta"
eq "broker: the normal path still stops the broker" "stopped True" "$(python3 -I "$W/runner.py" "$HERE" "$W" normal)"
eq "broker: a runner that died before the signal was armed leaves no broker" "exit 1" "$(python3 -I "$W/runner.py" "$HERE" "$W" orphan)"

cat > "$W/gates.py" <<'EOF'
import hashlib, importlib.util, json, os, sys
here, w = sys.argv[1], sys.argv[2]
s = importlib.util.spec_from_file_location("rp", here + "/run-pilot.py"); rp = importlib.util.module_from_spec(s); s.loader.exec_module(rp)
card, go, rev, run_root = w + "/gcard.md", w + "/gr8go", w + "/greview", w + "/grun"
open(card, "w").write("pilot card\n"); open(go, "w").write("a distinct go file\n"); os.makedirs(run_root)
sha = hashlib.sha256(open(card, "rb").read()).hexdigest()
old = hashlib.sha256(b"an older card").hexdigest()
def put(data):
    if os.path.isdir(rev):
        os.rmdir(rev)
    elif os.path.exists(rev):
        os.remove(rev)
    if data is not None:
        open(rev, "wb").write(data)
def case(data, go_path=go, as_dir=False):
    put(data)
    if as_dir:
        os.mkdir(rev)
    try:
        bad = rp.gates({"card": card, "astra_review": rev, "r8_go": go_path, "lock": w + "/nolock", "auth_readiness": w + "/noready", "run_root": run_root})
    except Exception as e:
        return ["traceback:" + type(e).__name__]
    case.names_path = all(rev in b for b in bad if b.startswith("G4"))
    return [b.split(":")[0] if b.startswith("G4") else b for b in bad if b.startswith("G4") or "R8" in b]
out = {"absent": case(None), "absent_names_path": case.names_path,
       "stale": case(("card %s\nPILOT REVISE 1\n" % old).encode()),
       "refused": case(("card %s\nPILOT REFUSED 2\n" % sha).encode()),
       "other_hash": case(("card %s\nPILOT APPROVED\n" % old).encode()),
       "no_go": case(("card %s\nPILOT APPROVED\n" % sha).encode(), w + "/no-such-go"),
       "non_utf8": case(b"card \xff\xfe\x00 \x80\nPILOT APPROVED\n")}
out["directory"] = case(None, go, True)
out["approved_control"] = case(("card %s\nPILOT APPROVED\n" % sha).encode())
out["run_root_files"] = sum(len(fs) for _, _, fs in os.walk(run_root))
print(json.dumps(out, sort_keys=True))
EOF
GT=$(python3 -I "$W/gates.py" "$HERE" "$W" 2>/dev/null | tail -1)
eq "G4: an absent review refuses with a G4 message" '["G4"]' "$(f "$GT" absent)"
eq "G4: the refusal names the review path it tried to read" true "$(f "$GT" absent_names_path)"
eq "G4: a review for an older card (stale) refuses" '["G4"]' "$(f "$GT" stale)"
eq "G4: a review whose last line is PILOT REFUSED 2 refuses" '["G4"]' "$(f "$GT" refused)"
eq "G4: PILOT APPROVED for another card hash refuses" '["G4"]' "$(f "$GT" other_hash)"
eq "R8: a missing R8 go file refuses even under a current PILOT APPROVED" '["no distinct R8 go"]' "$(f "$GT" no_go)"
eq "G4: a non-UTF-8 review refuses cleanly, never a traceback" '["G4"]' "$(f "$GT" non_utf8)"
eq "G4: a directory in place of the review refuses cleanly, never a traceback" '["G4"]' "$(f "$GT" directory)"
eq "G4: negative control, a current PILOT APPROVED review with the R8 go raises neither refusal" '[]' "$(f "$GT" approved_control)"
eq "G4: every refusal case booked, reserved and launched nothing (the run root stays empty)" 0 "$(f "$GT" run_root_files)"

python3 -I "$HERE/run-pilot.py" --config /nonexistent > "$W/cli.out" 2>&1
eq "CLI: run-pilot refuses without HIMMEL_BILLED_OK, before reading any config" 2 "$?"
has "CLI: the refusal names the opt-in" "HIMMEL_BILLED_OK" "$(cat "$W/cli.out")"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all run-pilot rows passed\n'
