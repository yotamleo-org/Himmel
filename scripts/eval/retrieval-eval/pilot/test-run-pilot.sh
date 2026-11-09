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

# --- P16 arithmetic and the ledger rules
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

# --- the sealed balanced schedule
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

# --- the runner state machine (mocks; every row is a score bomb: a gate that reads a score fails)
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
R=$(sc background); eq "P14: a surviving background child is an integrity HARD_STOP" '["HARD_STOP", "integrity"]' "$(f "$R" stop)"
R=$(sc raw-only); eq "skip rule: a raw-query-only S expansion does not exclude the answer" '["NONE", null] 40' "$(f "$R" stop) $(f "$R" common)"
R=$(sc reprice-no-capacity); eq "repricing: a raised b with enough H but no next-triple capacity ends admission" '"capacity_refused" 0.006 false' "$(f "$R" first_stop) $(f "$R" b) $(f "$R" lists_cancelled)"

# --- P14: the launch argv, prompt and profile differ only by the declared retrieval treatment
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

# --- the per-session namespace: --print argv and a real bwrap run with a stub CLI
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
eq "P14: V's namespace has no /run/pilot mount at all" 0 "$(grep -c '^/run/pilot' "$W/argv-V")"
eq "P14: S and Q mount the same retrieval paths except key versus weights" "/run/pilot/key|/run/pilot/models" "$(diff <(grep '^/run/pilot' "$W/argv-S") <(grep '^/run/pilot' "$W/argv-Q") | grep -E '^[<>]' | sed 's/^[<>] //' | sort | paste -sd'|')"
if ! command -v bwrap >/dev/null 2>&1 || ! bwrap --ro-bind / / true 2>/dev/null; then
  printf 'SKIP - P15 real namespace rows: no unprivileged bwrap on this host\n'
else
  for a in V S Q; do
    extra=(); [ "$a" = S ] && extra=("${ret[@]}" --key "$W/key"); [ "$a" = Q ] && extra=("${ret[@]}" --models "$W/models")
    sb --arm "$a" --home "$W/home-$a" "${base[@]}" "${extra[@]}" -- /opt/claude/claude "$W/private/tasks.jsonl" "$W/station/cred" > "$W/ns-$a.json" 2>"$W/ns-$a.err"
  done
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

# --- P17: the objective G0 checklist
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
out=$(g0 "$W/g0/ready.json"); rc=$?
eq "G0: a complete record under the recorded reachable stance is READY (P2 not required for R5)" 0 "$rc"
has "G0: READY names the stance and never claims isolation" "never called isolation" "$out"
eq "G0: a bare passed:true record proves nothing" 3 "$(g0 "$W/g0/bare.json" >/dev/null; echo $?)"
mut() { # <label> <reason fragment> <python mutation of r>
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(r, open(sys.argv[2],"w"))' "$W/g0/ready.json" "$W/g0/m.json" "$3"
  local o; o=$(g0 "$W/g0/m.json"); local rc=$?
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

# --- the CLI refuses without the billed opt-in
python3 -I "$HERE/run-pilot.py" --config /nonexistent > "$W/cli.out" 2>&1
eq "CLI: run-pilot refuses without HIMMEL_BILLED_OK, before reading any config" 2 "$?"
has "CLI: the refusal names the opt-in" "HIMMEL_BILLED_OK" "$(cat "$W/cli.out")"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all run-pilot rows passed\n'
