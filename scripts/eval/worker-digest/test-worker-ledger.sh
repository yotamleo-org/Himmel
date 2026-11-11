#!/usr/bin/env bash
# scripts/eval/worker-digest/test-worker-ledger.sh - hermetic suite for the worker ledgers.
# Scratch ledgers only; never ~/.himmel. No model call, no bank.
#  1. record writes one worker-failures row per digest class and one leg-trajectory eval-runs row; both validate;
#  2. idempotence by session: a second run, and a run after a crash between writes, append only what is missing;
#  3. the worker-failures validator refuses unknown keys, free-text keys, a bad class and more than five ids;
#  4. canary: no journal text reaches either ledger or the digest file (spec 6.1);
#  5. an inconclusive digest still writes a valid eval-runs row; a later ok run supersedes it;
#  6. backfill --since takes only worker-titled main journals from that date, skips a salus root, and is idempotent;
#  14. a canary in refusal_line reaches no router ticket, review, notifier line or tool-health output (RED control: a canary in the class does);
#  15. a salus-rooted session records no refusal_line, in the digest, the ledger, the marker or a backfill.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIG="$HERE/worker-digest.ts"
LL="${WORKER_LEDGER_PY:-$HERE/worker_ledger.py}"
EVR="$HERE/../lib/eval_runs.py"
FX="$HERE/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/worker-ledger-test.XXXXXX")" || { echo "test-worker-ledger: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# No case reads this checkout's real hook-chain logs: both point at an absent file unless a case overrides them.
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/no-chain-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$TMP/no-chain-runs.jsonl"
# Never the live ledgers, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-eval.jsonl"
unset HIMMEL_WORKER_SESSION_FAILURES_LEDGER
export HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$TMP/never-fail.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
absent() { grep -q "$@"; [ $? = 1 ]; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

SID=4670c1a5-0000-4000-8000-000000000001
FL="$TMP/fail.jsonl"; EL="$TMP/eval.jsonl"; ST="$TMP/state"
cp "$FX/classes.jsonl" "$TMP/$SID.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/digest.json" 2>/dev/null || bad "the P1 digest exits 0"
rec() { python3 "$LL" record --failures-ledger "$FL" --eval-ledger "$EL" --state-dir "$ST" "$@"; }

echo "1. record: worker-failures rows and the leg-trajectory eval-runs row"
rec --digest "$TMP/digest.json" --worker N1373 --ticket HIMMEL-4670 --chief demo-chief --pr 1990 --doc himmel/x.md >"$TMP/rec1.out" 2>&1 || bad "record exits 0: $(head -c 300 "$TMP/rec1.out")"
check "one worker-failures row per digest class" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$FL")" -gt 10 ]'
check "one eval-runs row" '[ "$(lines "$EL")" = 1 ]'
check "validate passes on the worker-failures ledger" 'python3 "$LL" validate "$FL" >/dev/null'
check "validate passes on the eval-runs ledger" 'python3 "$EVR" validate "$EL" >/dev/null'
check "a worker-failures row carries the envelope and the worker fields" 'jq -e "select(.class == \"denied/guard-pr-check-literal\") | .v == 1 and .kind == \"leg-failure\" and .source == \"scripts/eval/worker-digest/worker_ledger.py\" and (.host | length > 0) and (.ts | length > 0) and .session == \"$SID\" and .leg == \"N1373\" and .ticket == \"HIMMEL-4670\" and .console == \"demo-chief\" and .pr == 1990 and .count == 2 and .identical_retry == 1 and .recovered == false" "$FL" >/dev/null'
check "a suite row keeps final_red" 'jq -e "select(.class == \"suite/test-eval-runs.sh\") | .final_red == true" "$FL" >/dev/null'
check "the eval-runs row is the observational leg-trajectory row keyed by session" 'jq -e ".eval == \"leg-trajectory\" and .run_id == \"$SID\" and .status == \"ok\" and .meta.observational == true and .meta.leg == \"N1373\" and .meta.pr == 1990 and .n == 3 and .reps == 1 and .cases == null and .config.digest_v == 3 and .model == \"claude-opus-5-5\"" "$EL" >/dev/null'
check "its metrics are the digest metrics, booleans as 1/0" 'jq -e ".metrics | .fail_denied == 10 and .turns == 3 and .identical_denied_retries == 1 and has(\"red_before_green\") and has(\"verify_before_claim\")" "$EL" >/dev/null'
check "the digest file is written last and the row points at it" '[ -f "$ST/$SID.json" ] && [ "$(jq -r .artifact "$EL")" = "$ST/$SID.json" ]'

echo "1b. the old --leg and --console are no longer accepted"
HIMMEL_LEGACY_NAMES=1 python3 "$LL" record --failures-ledger "$TMP/ofail.jsonl" --eval-ledger "$TMP/oeval.jsonl" --state-dir "$TMP/ostate" --digest "$TMP/digest.json" --leg N1373 --ticket HIMMEL-4670 --console demo-chief --pr 1990 --doc himmel/x.md >"$TMP/o.out" 2>"$TMP/o.err"; orc=$?
check "legacy flags are unknown even with compatibility enabled" '[ "$orc" = 2 ] && grep -q "unrecognized arguments: --leg" "$TMP/o.err"'
check "legacy flags write no ledgers or state and offer no forwarding" '[ ! -e "$TMP/ofail.jsonl" ] && [ ! -e "$TMP/oeval.jsonl" ] && [ ! -e "$TMP/ostate" ] && ! grep -q "is deprecated: use" "$TMP/o.err"'
HIMMEL_LEGACY_NAMES=0 python3 "$LL" record --failures-ledger "$TMP/nfail.jsonl" --eval-ledger "$TMP/neval.jsonl" --state-dir "$TMP/nstate" --digest "$TMP/digest.json" --leg N1373 >"$TMP/n.out" 2>"$TMP/n.err"; nrc=$?
check "legacy names off: --leg is an unknown option (rc 2, nothing written)" '[ "$nrc" = 2 ] && grep -q "unrecognized arguments: --leg" "$TMP/n.err" && [ ! -e "$TMP/nfail.jsonl" ]'

echo "2. idempotence by session id"
rec --digest "$TMP/digest.json" --worker N1373 >"$TMP/rec2.out" 2>&1 || bad "the second record exits 0"
check "a second run appends 0 rows to either ledger" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ]'
rm -f "$ST/$SID.json"
head -n 5 "$FL" >"$TMP/f5" && mv "$TMP/f5" "$FL"
: >"$EL"
rec --digest "$TMP/digest.json" --worker N1373 >"$TMP/rec3.out" 2>&1 || bad "the healing record exits 0"
check "a crash after five rows heals: the missing rows and the eval row, nothing doubled" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ] && [ -z "$(jq -r "[.agent.id, .class] | join(\" \")" "$FL" | sort | uniq -d)" ]'
rm -f "$ST/$SID.json"
rec --digest "$TMP/digest.json" --worker N1373 >/dev/null 2>&1
check "a crash before the digest file only rewrites the marker" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ] && [ -f "$ST/$SID.json" ]'

echo "3. the worker-failures validator"
row1="$(head -n 1 "$FL")"
vrow() { printf '%s\n' "$1" >"$TMP/v.jsonl"; python3 "$LL" validate "$TMP/v.jsonl" >/dev/null; }
check "a valid row passes" 'vrow "$row1"'
check "an unknown key fails" '! vrow "$(jq -c ". + {extra: 1}" <<<"$row1")"'
for k in content command message prompt path; do
  check "a $k field fails" '! vrow "$(jq -c --arg k "$k" ". + {(\$k): \"x\"}" <<<"$row1")"'
done
check "a free-text class fails" '! vrow "$(jq -c ".class = \"denied/run rm -rf\"" <<<"$row1")"'
check "a class whose prefix is not its failure fails" '! vrow "$(jq -c ".class = \"suite/other\" | .failure = \"denied\"" <<<"$row1")"'
check "more than five tool_call_ids fail" '! vrow "$(jq -c ".tool_call_ids = [\"t1\",\"t2\",\"t3\",\"t4\",\"t5\",\"t6\"]" <<<"$row1")"'
check "a non-UUID session fails" '! vrow "$(jq -c ".session = \"../x\"" <<<"$row1")"'
check "a missing envelope field fails" '! vrow "$(jq -c "del(.source)" <<<"$row1")"'
check "a not-JSON line fails" '! vrow "not json"'

echo "4. canary (spec 6.1)"
CS=4670c1a5-0000-4000-8000-0000000000cc
cp "$FX/canary.jsonl" "$TMP/$CS.jsonl"
bun "$DIG" --transcript "$TMP/$CS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/canary.json" 2>/dev/null
rec --digest "$TMP/canary.json" >"$TMP/canary.out" 2>&1 || bad "the canary record exits 0"
check "the canary run wrote rows" '[ "$(grep -c "$CS" "$FL")" -gt 5 ]'
check "the canary appears in no ledger, digest file or output" 'absent CANARY4670zq "$FL" "$EL" "$ST/$CS.json" "$TMP/canary.out"'

echo "5. inconclusive, then superseded"
IS=4670c1a5-0000-4000-8000-0000000000dd
bun "$DIG" --transcript "$TMP/$IS.jsonl" >"$TMP/inc.json" 2>/dev/null
rec --digest "$TMP/inc.json" >/dev/null 2>&1 || bad "the inconclusive record exits 0"
check "an inconclusive digest writes a valid eval-runs row with null metrics" 'python3 "$EVR" validate "$EL" >/dev/null && jq -e "select(.run_id == \"$IS\") | .status == \"inconclusive\" and .metrics.turns == null" "$EL" >/dev/null'
rec --digest "$TMP/inc.json" >/dev/null 2>&1
check "a second inconclusive run appends nothing" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 1 ]'
cp "$FX/classes.jsonl" "$TMP/$IS.jsonl"
bun "$DIG" --transcript "$TMP/$IS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/inc2.json" 2>/dev/null
rec --digest "$TMP/inc2.json" >/dev/null 2>&1
check "a later ok run supersedes it with one more row" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 2 ] && [ "$(jq -r "select(.run_id == \"$IS\") | .status" "$EL" | tail -n 1)" = ok ]'
rec --digest "$TMP/inc2.json" >/dev/null 2>&1
check "and an ok run is final" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 2 ]'

echo "6. backfill --since"
P="$TMP/projects"; mkdir -p "$P/-home-x-himmel" "$P/-home-x-other"
B1=4670b000-0000-4000-8000-000000000001; B2=4670b000-0000-4000-8000-000000000002
B3=4670b000-0000-4000-8000-000000000003; B4=4670b000-0000-4000-8000-000000000004
title() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"; }
{ title HIMMEL-4670-N1365-agui-spec "$B1"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B1.jsonl"
B5=4670b000-0000-4000-8000-000000000005
{ title HIMMEL-5-N6-nocwd "$B5"; cat "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B5.jsonl"
cat "$FX/classes.jsonl" >"$P/-home-x-himmel/$B2.jsonl"
B6=4670b000-0000-4000-8000-000000000006
{ title chief-roadmap "$B6"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B6.jsonl"
B7=4670b000-0000-4000-8000-000000000007
sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl" >"$P/-home-x-himmel/$B7.jsonl"
{ title HIMMEL-1-N9-old "$B3"; sed 's/2026-10-06T/2026-09-01T/g' "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B3.jsonl"
mkdir -p "$TMP/salus-root" && : >"$TMP/salus-root/.salus"
{ title HIMMEL-2-N8-phi "$B4"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/salus-root/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P/-home-x-other/$B4.jsonl"
mkdir -p "$P/-home-x-himmel/$B1/subagents"
{ title HIMMEL-3-N7-sub "$B1"; cat "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B1/subagents/agent-x.jsonl"
BF="$TMP/bf-fail.jsonl"; BE="$TMP/bf-eval.jsonl"; BS="$TMP/bf-state"
bf() { python3 "$LL" backfill --since 2026-10-01 --projects "$P" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$BF" --eval-ledger "$BE" --state-dir "$BS"; }
bf >"$TMP/bf1.out" 2>&1 || bad "backfill exits 0: $(head -c 300 "$TMP/bf1.out")"
check "backfill digests the worker-titled, the titled non-worker and the titleless main journal from the window, not the old one" '[ "$(jq -r .run_id "$BE" | sort | tr "\n" " ")" = "$B1 $B6 $B7 " ]'
check "a titleless session with a cwd is digested with no launch name, and does not stop the run" 'jq -e "select(.run_id == \"$B7\") | .meta.leg == null and .meta.backfill == true" "$BE" >/dev/null'
check "a non-worker session is digested with no worker or ticket, marked backfill" 'jq -e "select(.run_id == \"$B6\") | .meta.leg == null and .meta.ticket == null and .meta.backfill == true" "$BE" >/dev/null'
check "the worker and ticket come from the title, marked backfill" 'jq -e "select(.run_id == \"$B1\") | .meta.leg == \"N1365\" and .meta.ticket == \"HIMMEL-4670\" and .meta.backfill == true and .meta.observational == true" "$BE" >/dev/null'
check "the salus-rooted and the cwd-less journals are refused and counted" 'grep -q "salus=3" "$TMP/bf1.out" && absent "$B4" "$BF" "$BE" && absent "$B5" "$BF" "$BE" && absent "$B2" "$BF" "$BE"'
check "backfill reports its row counts" 'grep -qE "^backfill: .*workers=1 others=2 .*failures\+=[1-9][0-9]* eval\+=3" "$TMP/bf1.out"'
check "both backfill ledgers validate" 'python3 "$LL" validate "$BF" >/dev/null && python3 "$EVR" validate "$BE" >/dev/null'
n1="$(lines "$BF")"
bf >"$TMP/bf2.out" 2>&1
check "a second backfill appends 0 rows" '[ "$(lines "$BE")" = 3 ] && [ "$(lines "$BF")" = "$n1" ] && grep -qE "failures\+=0 eval\+=0" "$TMP/bf2.out"'
# A session recorded with its lane known but no profile is asked again once its launch record names a profile.
mkdir -p "$TMP/bfp-cache/launch-logs"
printf 'headed-arm-worker: profile=none lane=native model=m role=worker session=HIMMEL-4670-N1365-agui-spec launched=2026-10-23T00:00:00Z\n' >"$TMP/bfp-cache/launch-logs/HIMMEL-4670-N1365-agui-spec.log"
bfp() { HIMMELCTL_CACHE_DIR="$TMP/bfp-cache" python3 "$LL" backfill --since 2026-10-01 --projects "$P" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/bfp-f.jsonl" --eval-ledger "$TMP/bfp-e.jsonl" --state-dir "$TMP/bfp-s"; }
bfp >"$TMP/bfp1.out" 2>&1
check "backfill: a launch with a lane and no profile records the lane and no profile" 'jq -e "select(.run_id == \"$B1\") | .lane == \"native\" and .meta.profile == null" "$TMP/bfp-e.jsonl" >/dev/null'
printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=HIMMEL-4670-N1365-agui-spec launched=2026-10-23T00:00:00Z\n' >"$TMP/bfp-cache/launch-logs/HIMMEL-4670-N1365-agui-spec.log"
bfp >"$TMP/bfp2.out" 2>&1
check "backfill asks a lane-known, profile-unknown session again, and the profile is stamped" 'jq -s "[.[] | select(.run_id == \"$B1\")] | length == 2 and (.[-1].meta.profile == \"worker-impl\")" "$TMP/bfp-e.jsonl" | grep -q true && jq -e "all(.tool_health[]; .profile == \"worker-impl\")" "$TMP/bfp-s/$B1.json" >/dev/null'
check "the attribution restamp keeps the original record time" 'jq -s "[.[] | select(.run_id == \"$B1\")] | .[0].ts == .[-1].ts" "$TMP/bfp-e.jsonl" | grep -q true'
mkdir -p "$TMP/h/.config/claude-glm/phi-roots"
HOME="$TMP/h" python3 "$LL" backfill --since 2026-10-01 --projects "$P" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/bf3-f.jsonl" --eval-ledger "$TMP/bf3-e.jsonl" --state-dir "$TMP/bf3-s" >"$TMP/bf3.out" 2>&1; rc3=$?
check "an unreadable PHI-roots file fails closed: nonzero, nothing written" '[ "$rc3" != 0 ] && [ ! -s "$TMP/bf3-e.jsonl" ]'
check "a usage error exits 2" 'python3 "$LL" backfill >/dev/null 2>&1; [ $? = 2 ]'
# Lane labels can name codex; check the subprocess call and its argv instead.
check "the writer spawns only bun, never a model CLI" 'python3 -c "import ast,sys; t=ast.parse(open(sys.argv[1]).read()); calls=[n for n in ast.walk(t) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and isinstance(n.func.value,ast.Name) and n.func.value.id==\"subprocess\"]; assert len(calls)==1 and calls[0].func.attr==\"run\" and isinstance(calls[0].args[0],ast.Name) and calls[0].args[0].id==\"cmd\"; assignments=[n for n in ast.walk(t) if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id==\"cmd\" for x in n.targets)]; assert len(assignments)==1 and isinstance(assignments[0].value,ast.List) and assignments[0].value.elts[0].value==\"bun\"" "$LL"'

echo "7. --digest-error: a closed-vocabulary reason in meta (HIMMEL-4670 P3)"
DE=4670c1a5-0000-4000-8000-0000000000de; DX=4670c1a5-0000-4000-8000-0000000000df
printf '{"digest_v":1,"mapper_v":1,"trajectory_v":null,"session":"%s","status":"inconclusive","model":null,"metrics":{},"failures":[]}\n' "$DE" >"$TMP/de.json"
rec --digest "$TMP/de.json" --digest-error timeout >/dev/null 2>&1
check "an accepted reason lands in meta.digest_error" 'jq -e "select(.run_id == \"$DE\") | .status == \"inconclusive\" and .meta.digest_error == \"timeout\"" "$EL" >/dev/null'
sed "s/$DE/$DX/" "$TMP/de.json" >"$TMP/dx.json"
python3 "$LL" record --failures-ledger "$FL" --eval-ledger "$EL" --state-dir "$ST" --digest "$TMP/dx.json" --digest-error "boom at line 3" >/dev/null 2>&1; rcx=$?
check "an unknown reason is refused and writes no row" '[ "$rcx" != 0 ] && absent "$DX" "$EL" && [ ! -f "$ST/$DX.json" ]'

echo "8. a partial-to-ok upgrade replaces the session's rows (HIMMEL-4701)"
US=4670c1a5-0000-4000-8000-0000000000e1; OS=4670c1a5-0000-4000-8000-0000000000e2
UF="$TMP/up-fail.jsonl"; UE="$TMP/up-eval.jsonl"; US_ST="$TMP/up-state"
urec() { python3 "$LL" record --failures-ledger "$UF" --eval-ledger "$UE" --state-dir "$US_ST" "$@"; }
jq -c --arg s "$US" '.session = $s | .status = "partial" | .failures = [(.failures | map(select(.failure == "denied")) | .[0] | .count = 99), (.failures | map(select(.failure == "denied")) | .[0] | .class = "denied/stale-class")]' "$TMP/digest.json" >"$TMP/up-partial.json"
jq -c --arg s "$US" '.session = $s' "$TMP/digest.json" >"$TMP/up-ok.json"
jq -c --arg s "$OS" '.session = $s | .status = "partial" | .failures = (.failures | map(select(.failure == "denied")) | .[0:1])' "$TMP/digest.json" >"$TMP/other-partial.json"
urec --digest "$TMP/other-partial.json" >/dev/null 2>&1
urec --digest "$TMP/up-partial.json" >/dev/null 2>&1 || bad "the partial record exits 0"
check "the partial digest wrote its two rows" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = 2 ]'
urec --digest "$TMP/up-ok.json" >"$TMP/up.out" 2>&1 || bad "the upgrading record exits 0: $(head -c 300 "$TMP/up.out")"
check "after the upgrade the session has exactly the ok digest rows" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = "$(jq ".failures | length" "$TMP/up-ok.json")" ]'
check "no stale class survives the upgrade" 'absent "denied/stale-class" "$UF"'
check "no stale count survives the upgrade" 'absent "\"count\":99" "$UF"'
check "another session's rows are untouched" '[ "$(grep -c "\"session\":\"$OS\"" "$UF")" = 1 ]'
check "the upgraded ledger still validates" 'python3 "$LL" validate "$UF" >/dev/null'
urec --digest "$TMP/up-ok.json" >/dev/null 2>&1
check "a second ok run changes nothing" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = "$(jq ".failures | length" "$TMP/up-ok.json")" ]'

echo "9. backfill reads the LAST title in the whole journal (HIMMEL-4701)"
P2="$TMP/projects2"; mkdir -p "$P2/-home-x-himmel"
T1=4670b000-0000-4000-8000-000000000011
{ title HIMMEL-1-N1-scratch "$T1"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; title HIMMEL-4701-N1418-late-title "$T1"; } >"$P2/-home-x-himmel/$T1.jsonl"
check "the fixture's final title sits past line 40" '[ "$(grep -n "late-title" "$P2/-home-x-himmel/$T1.jsonl" | cut -d: -f1)" -gt 40 ]'
python3 "$LL" backfill --since 2026-10-01 --projects "$P2" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/t-fail.jsonl" --eval-ledger "$TMP/t-eval.jsonl" --state-dir "$TMP/t-state" >"$TMP/t.out" 2>&1 || bad "title backfill exits 0"
check "the title after line 40 wins: worker and ticket come from it" 'jq -e ".meta.leg == \"N1418\" and .meta.ticket == \"HIMMEL-4701\"" "$TMP/t-eval.jsonl" >/dev/null'

echo "10. backfill --live-minutes skips a still-live journal (HIMMEL-4699, HIMMEL-4701)"
P3="$TMP/projects3"; mkdir -p "$P3/-home-x-himmel"
L1=4670b000-0000-4000-8000-000000000021; L2=4670b000-0000-4000-8000-000000000022
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
{ title HIMMEL-4701-N1-live "$L1"; jq -c --arg n "$NOW" --arg c "$TMP/w" '.cwd = $c | if has("timestamp") then .timestamp = $n else . end' "$FX/classes.jsonl"; } >"$P3/-home-x-himmel/$L1.jsonl"
{ title HIMMEL-4701-N2-old "$L2"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P3/-home-x-himmel/$L2.jsonl"
lbf() { python3 "$LL" backfill --since 2026-10-01 --projects "$P3" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/l-fail.jsonl" --eval-ledger "$TMP/l-eval.jsonl" --state-dir "$TMP/l-state" "$@"; }
lbf >"$TMP/l1.out" 2>&1 || bad "live backfill exits 0: $(head -c 300 "$TMP/l1.out")"
check "the recent journal is counted live=1 and the old one is digested" 'grep -qE "workers=2 .*eval\+=1 live=1" "$TMP/l1.out" && [ "$(jq -r .run_id "$TMP/l-eval.jsonl")" = "$L2" ]'
check "the live journal has no marker and no rows in either ledger" '[ ! -e "$TMP/l-state/$L1.json" ] && absent "$L1" "$TMP/l-fail.jsonl" "$TMP/l-eval.jsonl"'
lbf --live-minutes 0 >"$TMP/l2.out" 2>&1
check "control: with the skip disabled (--live-minutes 0) the same journal is digested" 'grep -q "live=0" "$TMP/l2.out" && [ -f "$TMP/l-state/$L1.json" ] && grep -q "$L1" "$TMP/l-eval.jsonl"'

echo "W. the worker-session ledger name sets the path; the lane reads the worker-session name"
lpath() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import worker_ledger; print(worker_ledger.ledger_path())' "$HERE"; }
check "HIMMEL_WORKER_SESSION_FAILURES_LEDGER sets the ledger path" '[ "$(HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$TMP/new.jsonl" lpath)" = "$TMP/new.jsonl" ]'
printf '# HIMMEL-1-N9 worker (WORKER_SESSION_LANE=claudex)\n' >"$TMP/wlane.md"
check "a doc title naming WORKER_SESSION_LANE gives the lane" '[ "$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import worker_ledger; print(worker_ledger.launch_lane({}, {\"doc\": sys.argv[2]}))" "$HERE" "$TMP/wlane.md")" = claudex ]'

echo "11. the recorder stamps the launch profile on tool_health (HIMMEL-7048)"
LP=4670c1a5-0000-4000-8000-0000000000f1; LQ=4670c1a5-0000-4000-8000-0000000000f2; LR=4670c1a5-0000-4000-8000-0000000000f3
LF="$TMP/lp-fail.jsonl"; LE="$TMP/lp-eval.jsonl"; LS="$TMP/lp-state"
lrec() { HIMMELCTL_CACHE_DIR="$TMP/cache" python3 "$LL" record --failures-ledger "$LF" --eval-ledger "$LE" --state-dir "$LS" "$@"; }
mkdir -p "$TMP/cache/launch-logs"
printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=lp-worker launched=2026-10-23T00:00:00Z\n' >"$TMP/cache/launch-logs/lp-worker.log"
{ printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=lp-two launched=2026-10-23T00:00:00Z\n'; printf 'headed-arm-worker: profile=judge lane=native model=m role=judge session=lp-two launched=2026-10-23T00:05:00Z\n'; } >"$TMP/cache/launch-logs/lp-two.log"
printf 'headed-arm-worker: profile=none lane=native model=m role=worker session=lp-none launched=2026-10-23T00:00:00Z\n' >"$TMP/cache/launch-logs/lp-none.log"
LN=4670c1a5-0000-4000-8000-0000000000f4
for s in "$LP" "$LQ" "$LR" "$LN"; do jq -c --arg s "$s" '.session = $s' "$TMP/digest.json" >"$TMP/lp-$s.json"; done
check "the digest under test carries tool_health" '[ "$(jq ".tool_health | length" "$TMP/digest.json")" -gt 0 ]'
lrec --digest "$TMP/lp-$LP.json" --launch-name lp-worker >/dev/null 2>&1
lrec --digest "$TMP/lp-$LQ.json" >/dev/null 2>&1
lrec --digest "$TMP/lp-$LR.json" --launch-name lp-two >/dev/null 2>&1
check "a launch record gives every tool_health row the launched profile" 'jq -e "select(.run_id == \"$LP\") | (.meta.tool_health | length > 0) and all(.meta.tool_health[]; .profile == \"worker-impl\") and .meta.profile == \"worker-impl\"" "$LE" >/dev/null'
check "no launch name reads unknown" 'jq -e "select(.run_id == \"$LQ\") | all(.meta.tool_health[]; .profile == \"unknown\")" "$LE" >/dev/null'
check "two launch lines that disagree read unknown" 'jq -e "select(.run_id == \"$LR\") | all(.meta.tool_health[]; .profile == \"unknown\")" "$LE" >/dev/null'
lrec --digest "$TMP/lp-$LN.json" --launch-name lp-none >/dev/null 2>&1
check "a launch with no profile (profile=none) reads unknown, never the literal none" 'jq -e "select(.run_id == \"$LN\") | .meta.profile == null and all(.meta.tool_health[]; .profile == \"unknown\")" "$LE" >/dev/null'
check "the saved digest marker carries the stamped profile too" 'jq -e "all(.tool_health[]; .profile == \"worker-impl\")" "$LS/$LP.json" >/dev/null'
lrec --digest "$TMP/lp-$LP.json" --launch-name ../../etc/passwd >/dev/null 2>&1; rcp=$?
check "a launch name with a path separator is refused" '[ "$rcp" != 0 ]'
# A -RESUME doc's session is filed without the suffix, a chief's launch line carries a role, a native launch carries its lane
LC=4670c1a5-0000-4000-8000-0000000000f5; LZ=4670c1a5-0000-4000-8000-0000000000f6; LX=4670c1a5-0000-4000-8000-0000000000f7
printf 'headed-arm: role=chief session=lp-chief context=1m source=default autocompact=auto launched=2026-10-23T00:00:00Z\n' >"$TMP/cache/launch-logs/lp-chief.log"
printf 'headed-arm-worker: profile=worker-impl lane=claudex model=m role=worker session=lp-lane launched=2026-10-23T00:00:00Z\n' >"$TMP/cache/launch-logs/lp-lane.log"
for s in "$LC" "$LZ" "$LX"; do jq -c --arg s "$s" '.session = $s | del(.lane)' "$TMP/digest.json" >"$TMP/lp-$s.json"; done
lrec --digest "$TMP/lp-$LC.json" --launch-name lp-chief >/dev/null 2>&1
lrec --digest "$TMP/lp-$LZ.json" --launch-name lp-worker-RESUME >/dev/null 2>&1
lrec --digest "$TMP/lp-$LX.json" --launch-name lp-lane >/dev/null 2>&1
check "a chief launch line gives its role as the profile" 'jq -e "select(.run_id == \"$LC\") | .meta.profile == \"chief\" and all(.meta.tool_health[]; .profile == \"chief\")" "$LE" >/dev/null'
check "a -RESUME launch name finds the launch record filed without the suffix" 'jq -e "select(.run_id == \"$LZ\") | .meta.profile == \"worker-impl\"" "$LE" >/dev/null'
check "a native launch gets its lane from the launch record" 'jq -e "select(.run_id == \"$LP\") | .lane == \"native\" and all(.meta.tool_health[]; .lane == \"native\")" "$LE" >/dev/null'
check "a claudex launch record gives claudex" 'jq -e "select(.run_id == \"$LX\") | .lane == \"claudex\"" "$LE" >/dev/null'
# the chief row the launchers really write (chief_context_write_record) carries the lane, so a chief reads native, not unknown
LK=4670c1a5-0000-4000-8000-0000000000fc
( HIMMELCTL_CACHE_DIR="$TMP/cache"; . "$HERE/../../lib/chief-context.sh"; chief_context_write_record lp-chief-real 1m default auto )
jq -c --arg s "$LK" '.session = $s | del(.lane)' "$TMP/digest.json" >"$TMP/lp-$LK.json"
lrec --digest "$TMP/lp-$LK.json" --launch-name lp-chief-real >/dev/null 2>&1
check "a chief row written by chief_context_write_record gives lane native and profile chief" 'jq -e "select(.run_id == \"$LK\") | .lane == \"native\" and .meta.profile == \"chief\" and (.meta | has(\"launch_gap\") | not)" "$LE" >/dev/null'

# A session with no launch name still finds its launch record by the session id the launcher writes, then by its doc's stem;
# a session found by neither names the kind of session it was; a later record fills an unknown lane once the launch record exists.
S1=4670c1a5-0000-4000-8000-0000000000f8; S2=4670c1a5-0000-4000-8000-0000000000f9; S3=4670c1a5-0000-4000-8000-0000000000fa; S4=4670c1a5-0000-4000-8000-0000000000fb
printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=lp-by-sid session_id=%s launched=2026-10-23T00:00:00Z\n' "$S1" >"$TMP/cache/launch-logs/lp-by-sid.log"
printf 'headed-arm-worker: profile=worker-e2e lane=claudex model=m role=worker session=lp-by-doc launched=2026-10-23T00:00:00Z\n' >"$TMP/cache/launch-logs/lp-by-doc.log"
for s in "$S1" "$S2" "$S3" "$S4"; do jq -c --arg s "$s" '.session = $s | del(.lane)' "$TMP/digest.json" >"$TMP/lp-$s.json"; done
lrec --digest "$TMP/lp-$S1.json" >/dev/null 2>&1
lrec --digest "$TMP/lp-$S2.json" --doc "$TMP/handovers/lp-by-doc.md" >/dev/null 2>&1
lrec --digest "$TMP/lp-$S3.json" --kind release-manager >/dev/null 2>&1
check "no launch name: the launch record is found by the session id" 'jq -e "select(.run_id == \"$S1\") | .lane == \"native\" and .meta.profile == \"worker-impl\" and all(.meta.tool_health[]; .lane == \"native\" and .profile == \"worker-impl\")" "$LE" >/dev/null'
check "no launch name: the launch record is found by the doc stem" 'jq -e "select(.run_id == \"$S2\") | .lane == \"claudex\" and .meta.profile == \"worker-e2e\"" "$LE" >/dev/null'
check "a session with no launch record stays unknown and names its kind" 'jq -e "select(.run_id == \"$S3\") | .lane == \"unknown\" and .meta.launch_gap == \"release-manager\"" "$LE" >/dev/null'
check "a session with a launch record carries no launch_gap" 'jq -e "select(.run_id == \"$S1\") | (.meta | has(\"launch_gap\") | not)" "$LE" >/dev/null'
lrec --digest "$TMP/lp-$S4.json" >/dev/null 2>&1
printf 'headed-arm-worker: profile=worker-impl lane=claudex model=m role=worker session=lp-late session_id=%s launched=2026-10-23T00:00:00Z\n' "$S4" >"$TMP/cache/launch-logs/lp-late.log"
lrec --digest "$TMP/lp-$S4.json" >/dev/null 2>&1
check "a session recorded unknown is recorded again once its launch record exists" '[ "$(jq -s "[.[] | select(.run_id == \"$S4\")] | map(.lane) | join(\",\")" -r "$LE")" = "unknown,claudex" ]'
check "a session recorded again does not repeat its failure rows" '[ "$(jq -s "[.[] | select(.session == \"$S4\")] | length" "$LF")" = "$(jq -s "[.[] | select(.session == \"$LP\")] | length" "$LF")" ]'
lrec --digest "$TMP/lp-$S4.json" >/dev/null 2>&1
check "and a third record of it changes nothing" '[ "$(jq -s "[.[] | select(.run_id == \"$S4\")] | length" "$LE")" = 2 ]'

echo "12. the daily tool-health record: validated row, one per day, and the eval feedback step"
THR="$HERE/tool_health_record.py"; FB="$HERE/../lib/eval_feedback.py"; RULES="$HERE/../feedback-rules.json"
TL="$TMP/th-eval.jsonl"
thbody() { jq -n --arg day "$1" --arg st "$2" --arg w "${3:-w1}" '{day: $day, status: $st, n: 10, config: {count_definition_version: 1, day_window: "utc-day", population: "all-production-sessions", wiring: $w}, metrics: {calls: 10, "guard.g.deny_rate": 0.3}, cases: {"guard:g": {denials: 3, eligible_calls: 10}}, meta: {audit: {missing_sources: []}}}'; }
thw() { thbody "$1" "$2" "${3:-w1}" >"$TMP/th-body.json"; python3 "$THR" write --body "$TMP/th-body.json" --ledger "$TL"; }
newest_ok_day() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import eval_runs; print([r for r in eval_runs.read_rows(sys.argv[2]) if r["eval"] == "tool-health" and r["status"] == "ok"][-1]["meta"]["day"])' "$HERE/../lib" "$TL" 2>/dev/null; }
printf '%s\n' '{"v": 1, "rules": [{"eval": "tool-health", "metric": "guard.*.deny_rate", "threshold": 0.1, "better": "lower", "absent": null, "change": "learning", "target": "x.md"}]}' >"$TMP/th-rules.json"
fbrun() { python3 "$FB" run --ledger "$TL" --changes "$1" --rules "$2"; }
thw 2026-10-27 ok >"$TMP/th1.out" 2>&1 || bad "the first day writes: $(head -c 300 "$TMP/th1.out")"
check "one validated tool-health row" '[ "$(lines "$TL")" = 1 ] && python3 "$EVR" validate "$TL" >/dev/null'
check "the envelope: eval, ok, n, no interval, one rep, the day in meta" 'jq -e ".eval == \"tool-health\" and .status == \"ok\" and .n == 10 and .reps == 1 and .ci == {} and .ci_level == null and .ci_method == null and .meta.day == \"2026-10-27\" and .cases.\"guard:g\".denials == 3" "$TL" >/dev/null'
thw 2026-10-27 ok >"$TMP/th2.out" 2>&1
check "the same day twice appends nothing" '[ "$(lines "$TL")" = 1 ] && grep -q "already\|exists" "$TMP/th2.out"'
thw 2026-10-28 ok >/dev/null 2>&1
check "a second day is a second row of the same series (same confighash)" '[ "$(lines "$TL")" = 2 ] && [ "$(jq -s "map(.confighash) | unique | length" "$TL")" = 1 ]'
check "the config carries neither the date nor a count" 'absent "2026-\|\"n\"\|denials" <<<"$(jq -c .config "$TL")"'
thw 2026-10-20 ok >/dev/null 2>&1
check "a late backfill is stored partial with its revision, never ok" 'jq -e "select(.meta.day == \"2026-10-20\") | .status == \"partial\" and .meta.revision == \"backfill\"" "$TL" >/dev/null'
check "the newest ok row is still the newest day, though the backfill was written last" '[ "$(newest_ok_day)" = 2026-10-28 ]'
thw 2026-10-20 ok >/dev/null 2>&1
check "the backfilled day twice appends nothing" '[ "$(lines "$TL")" = 3 ]'
fbrun "$TMP/th-ch0.jsonl" "$RULES" >"$TMP/fb0.out" 2>&1
fb0rc=$?
check "no rule in feedback-rules.json names tool-health, so the feedback step runs clean and writes nothing" '[ "$fb0rc" = 0 ] && [ ! -s "$TMP/th-ch0.jsonl" ] && ! grep -q "tool-health" "$TMP/fb0.out"'
fbrun "$TMP/th-ch1.jsonl" "$TMP/th-rules.json" >"$TMP/fb1.out" 2>&1
check "given a rule, feedback picks the newest ok day as its baseline, not the late backfill" '[ "$(lines "$TMP/th-ch1.jsonl")" = 1 ] && jq -e ".baseline_run_id | contains(\"2026-10-28\")" "$TMP/th-ch1.jsonl" >/dev/null'
thw 2026-10-29 partial >/dev/null 2>&1; thw 2026-10-29 partial >/dev/null 2>&1
check "a partial day twice appends one row" '[ "$(jq -s "map(select(.meta.day == \"2026-10-29\")) | length" "$TL")" = 1 ]'
check "a partial row is never the newest ok row" '[ "$(newest_ok_day)" = 2026-10-28 ]'
thw 2026-10-29 ok >/dev/null 2>&1
check "an ok body over that partial day is the finalized revision" '[ "$(jq -s "map(select(.meta.day == \"2026-10-29\")) | map(.status) | join(\",\")" "$TL" | tr -d \")" = "partial,ok" ] && [ "$(newest_ok_day)" = 2026-10-29 ]'
check "every run_id is unique" '[ "$(jq -s "map(.run_id) | length - (unique | length)" "$TL")" = 0 ]'
printf '%s\n' '{"day": "2026-10-30", "status": "ok", "extra": 1, "config": {}, "metrics": {"a": 1}}' >"$TMP/th-bad.json"
python3 "$THR" write --body "$TMP/th-bad.json" --ledger "$TL" >/dev/null 2>&1; rcb=$?
check "an unknown body key is refused (exit 2) and nothing is appended" '[ "$rcb" = 2 ] && [ "$(jq -s "map(select(.meta.day == \"2026-10-30\")) | length" "$TL")" = 0 ]'

thw 2026-10-18 ok w2 >/dev/null 2>&1
check "an older day under another wiring is stored partial too, because feedback picks its newest ok row across every series" 'jq -e "select(.meta.day == \"2026-10-18\") | .status == \"partial\" and .meta.revision == \"backfill\"" "$TL" >/dev/null && [ "$(newest_ok_day)" = 2026-10-29 ]'

echo "13. the ledger row carries the refusal line of a denied row only (HIMMEL-8575)"
# The chain-refusal journal and its run log (the REAL launcher writes the secret-bearing and long rows); the ledger row is the digest row's line.
CR="$FX/chain-refusal"; RS=8575c1a5-0000-4000-8000-000000000001
mkdir -p "$TMP/rl/j"
cp "$CR/journal.jsonl" "$TMP/rl/j/$RS.jsonl"
bash "$CR/make-chain-log.sh" "$TMP/rl" >"$TMP/rl/make.out" 2>&1 || bad "the chain log builds: $(head -c 300 "$TMP/rl/make.out")"
RUN_HOOK_CHAIN_SKIP_LOG="$TMP/rl/no-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$TMP/rl/hook-runs.jsonl" bun "$DIG" --transcript "$TMP/rl/j/$RS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/rl/digest.json" 2>/dev/null || bad "the digest of the chain-refusal journal exits 0"
RF="$TMP/rl/fail.jsonl"
python3 "$LL" record --failures-ledger "$RF" --eval-ledger "$TMP/rl/eval.jsonl" --state-dir "$TMP/rl/state" --digest "$TMP/rl/digest.json" --worker N1 >"$TMP/rl/rec.out" 2>&1 || bad "record of the refusal digest exits 0: $(head -c 300 "$TMP/rl/rec.out")"
lrow() { jq -c --arg k "$1" 'select(.class == $k)' "$RF"; }
check "a secret-bearing refusal: the ledger row carries the redacted line, and the secret is in neither the digest nor the ledger" '[ "$(lrow denied/block-read-secrets | jq -r .refusal_line)" = "refused: API_TOKEN=<redacted> was read" ] && absent SECRETVALUE8575zq "$TMP/rl/digest.json" "$RF"'
check "a refusal longer than 240 code points is exactly 240 in the ledger row" '[ "$(lrow denied/read-clamp | jq ".refusal_line | explode | length")" = 240 ]'
check "a call with no recorded line, a classifier denial and a permission prompt carry null, never an empty string" '[ "$(lrow denied/guard-pr-check-literal | jq -c .refusal_line)" = null ] && [ "$(lrow denied/classifier:merge-without-review | jq -c .refusal_line)" = null ] && [ "$(lrow denied/permission-prompt | jq -c .refusal_line)" = null ] && [ "$(jq "select(.refusal_line == \"\")" "$RF" | wc -c | tr -d " ")" = 0 ]'
check "an aggregated row carries the first line its refused calls have" '[ "$(lrow denied/check-push-target | jq -r .refusal_line)" = "check-push-target: push to a remote that is not the fork is refused (agg2)" ]'
check "the key is on denied rows only, and the ledger validates" '[ "$(jq -s "map(select(.failure != \"denied\" and has(\"refusal_line\"))) | length" "$RF")" = 0 ] && python3 "$LL" validate "$RF" >/dev/null'
check "canary: no journal text reaches the ledger" 'absent -e CANARY8575zq -e TESTORIGIN8575 -e WRONGMEMBER8575 "$RF"'
drow="$(lrow denied/check-push-target)"
check "control: a denied row without the key (every row written before this change) still validates" '[ "$(jq "has(\"refusal_line\")" <<<"$(jq -c "del(.refusal_line)" <<<"$drow")")" = false ] && vrow "$(jq -c "del(.refusal_line)" <<<"$drow")"'
srow="$(jq -c 'select(.failure == "suite")' "$FL" | head -n 1)"
check "validate refuses a refusal_line on a suite row" '! vrow "$(jq -c ". + {refusal_line: \"x\"}" <<<"$srow")"'
check "validate refuses an empty refusal_line, a line break, a control character, 241 code points and a non-string" '! vrow "$(jq -c ".refusal_line = \"\"" <<<"$drow")" && ! vrow "$(jq -c ".refusal_line = \"a\\nb\"" <<<"$drow")" && ! vrow "$(jq -c ".refusal_line = \"a\\u0007b\"" <<<"$drow")" && ! vrow "$(jq -c ".refusal_line = (\"x\" * 241)" <<<"$drow")" && ! vrow "$(jq -c ".refusal_line = 7" <<<"$drow")"'
check "validate takes 240 code points and null" 'vrow "$(jq -c ".refusal_line = (\"x\" * 240)" <<<"$drow")" && vrow "$(jq -c ".refusal_line = null" <<<"$drow")"'
check "validate still refuses a free-text key such as message beside a valid refusal_line" '! vrow "$(jq -c ". + {message: \"x\"}" <<<"$drow")"'

echo "14. a refusal_line canary is not forwarded (HIMMEL-8575)"
# Pinned: the failure router's Jira calls and body files, the daily review file, the router and review notifier lines,
# and the tool-health rollup as the real reader (readToolHealth) returns it. NOT pinned: worker_ledger.py's marker dump and
# tool-health.mjs's in-memory row spread, which hold the whole row and stay on this host by design (never sent).
export JIRA_PROJECT_KEY=HIMMEL
FRT="$HERE/failure_router.py"; FRV="$HERE/failure_review.py"; TH="$HERE/tool-health.mjs"
PIN="$TMP/pin"; mkdir -p "$PIN/stub"
# Hermetic seams, the same as test-failure-review.sh: the review's router child takes its notifier from the environment
# (the review forwards none), so without these a live review files a real INTAKE and writes a real chief inbox line.
export TZ=UTC
export FAILURE_ROUTER_NOTIFY_CMD="$PIN/stub/route-notify"
export FAILURE_REVIEW_FRICTION_CMD=""
export HIMMEL_EVAL_CHANGES_LEDGER="$PIN/never-changes.jsonl"
export HIMMEL_FAILURE_ROUTES_LOG="$PIN/never-log.jsonl" HIMMEL_FAILURE_ROUTES_STATE="$PIN/never-state.json" HIMMEL_FAILURE_INBOX="$PIN/never-inbox.md" HIMMEL_FAILURE_REVIEW_DIR="$PIN/never-review"
# Tripwires behind the notifier's own seams: if the stubbed notifier were ever bypassed and the real one ran, these record it.
export FAILURE_ROUTE_SWEEP_CMD="$PIN/stub/tripwire" FAILURE_ROUTE_INBOX_SEND="$PIN/stub/tripwire" FAILURE_ROUTE_JIRA="$PIN/stub/tripwire"
export CADENCE_ALERT_FILE="$PIN/cadence-alerts.log" CADENCE_ALERT_DEDUPE_DIR="$PIN/alert-sent" CADENCE_ALERT_SEND_CMD="$PIN/stub/tripwire" CADENCE_ALERT_SEND_FAILED_MARK="$PIN/alert-send-failed"
cat >"$PIN/stub/jira" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >>"$d/calls.log"
op="$1"; shift
while [ $# -gt 0 ]; do case "$1" in --desc-file|--comment-file) cp "$2" "$d/body.$op.$(wc -l <"$d/calls.log")"; shift 2 ;; *) shift ;; esac; done
case "$op" in list) ;; create) echo "Created HIMMEL-9001" ;; comment) echo "Comment added" ;; *) exit 9 ;; esac
EOF
cat >"$PIN/stub/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/notify.log"
EOF
cat >"$PIN/stub/route-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/route-notify.log"
EOF
cat >"$PIN/stub/tripwire" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"$(dirname "$0")/../tripwire.log"
EOF
chmod +x "$PIN/stub/jira" "$PIN/stub/notify" "$PIN/stub/route-notify" "$PIN/stub/tripwire"
PNOW=2026-10-07T12:00:00Z
# pinrows <ledger> <class> <refusal_line json>: two distinct workers, an identical retry each, so the class fires.
pinrows() {
  local n
  for n in 1 2; do
    jq -nc --arg cls "$2" --argjson rl "$3" --arg w "N$n" --arg sid "8575c1a5-0000-4000-8000-00000000009$n" '
      {v:1, ts:"2026-10-07T08:00:00Z", host:"h", source:"scripts/eval/worker-digest/worker_ledger.py", kind:"leg-failure", session:$sid,
       leg:$w, console:"c", ticket:"HIMMEL-8575", pr:2030, agent:{id:"main", role:"worker", kind:"k", model:"claude-opus-5-5"},
       class:$cls, failure:"denied", count:2, identical_retry:1, recovered:false, first_ts:1, last_ts:2, tool_call_ids:["t"], refusal_line:$rl}' >>"$1"
  done
}
# pinrun <case>: the router, the review (live, so its notifier line is sent) and the tool-health reader over <case>/ledger.jsonl.
pinrun() {
  local c="$PIN/$1"
  python3 "$FRT" route --ledger "$c/ledger.jsonl" --state "$c/state.json" --log "$c/log.jsonl" --inbox "$c/inbox.md" --now "$PNOW" --jira-bin "$PIN/stub/jira" --notify-cmd "$PIN/stub/notify" >"$c/route.out" 2>&1
  mkdir -p "$c/rv"
  python3 "$FRV" --live --ledger "$c/ledger.jsonl" --state "$c/rv/state.json" --log "$c/rv/log.jsonl" --inbox "$c/rv/inbox.md" --out-dir "$c/rv/out" --now "$PNOW" --jira-bin "$PIN/stub/jira" --notify-cmd "$PIN/stub/notify" >"$c/review.out" 2>&1
  HOME="$PIN/home" HIMMEL_EVAL_RUNS_LEDGER="$TMP/rl/eval.jsonl" HIMMEL_WORKER_SESSION_FAILURES_LEDGER="$c/th-fail.jsonl" TH_PATH="$TH" bun -e 'const { readToolHealth } = await import(process.env.TH_PATH); console.log(JSON.stringify(readToolHealth(process.env, new URLSearchParams("days=30"), Date.parse("2026-11-03T00:00:00Z"))))' >"$c/tool-health.json" 2>"$c/tool-health.err"
}
# pinleaks <case> <canary>: every artifact a sender or reader wrote, searched for the canary (case-insensitive).
pinleaks() { grep -ril -e "$2" "$PIN/stub" "$PIN/$1" 2>/dev/null | grep -v "/ledger.jsonl$\|/th-fail.jsonl$"; }
mkdir -p "$PIN/green" "$PIN/red"
pinrows "$PIN/green/ledger.jsonl" denied/guard-pr-check-literal '"CANARY8575fw"'
jq -c 'select(.failure == "denied") | .refusal_line = "CANARY8575fw"' "$RF" >"$PIN/green/th-fail.jsonl"
pinrun green
check "precondition: the router filed, the review ran live and sent its line, and the tool-health reader returned the denied class" '[ -s "$PIN/stub/calls.log" ] && grep -q "^create " "$PIN/stub/calls.log" && [ -s "$PIN/stub/notify.log" ] && [ -s "$PIN/green/rv/out/failure-review-2026-10-07.md" ] && grep -q "denied/block-read-secrets" "$PIN/green/tool-health.json"'
check "the review's router lines reach the stub notifier (chief line and INTAKE), and no real notifier seam, alert or friction scan ran" '[ -s "$PIN/stub/route-notify.log" ] && grep -q "^chief failure-router: " "$PIN/stub/route-notify.log" && grep -q "^intake HIMMEL-9001 " "$PIN/stub/route-notify.log" && [ ! -e "$PIN/tripwire.log" ] && [ ! -e "$PIN/never-changes.jsonl" ] && [ ! -e "$PIN/cadence-alerts.log" ]'
check "precondition: the ledger rows under test do carry the canary" 'grep -qi CANARY8575fw "$PIN/green/ledger.jsonl" && grep -qi CANARY8575fw "$PIN/green/th-fail.jsonl"'
check "canary in refusal_line: absent from the Jira stub arguments and bodies, the review file, the notifier lines and the tool-health output" '[ -z "$(pinleaks green CANARY8575fw)" ]'
# RED control: the same assertion fails when the canary rides in a field the router does send (the class).
rm -f "$PIN/stub/calls.log" "$PIN/stub/notify.log" "$PIN"/stub/body.*
pinrows "$PIN/red/ledger.jsonl" denied/guard-canary8575fw null
jq -c 'select(.failure == "denied") | .class = "denied/guard-canary8575fw"' "$RF" >"$PIN/red/th-fail.jsonl"
pinrun red
check "RED control: the same canary in the class is found in the Jira stub, the review and the notifier output, so the pin is not vacuous" '[ -n "$(pinleaks red CANARY8575fw)" ] && grep -qi canary8575fw "$PIN/stub/calls.log"'

echo "15. a salus-rooted session records no refusal_line (HIMMEL-8575)"
# Pinned, with the chain-log overrides CLEARED so the digest resolves its logs by default: the digest reads only the chain logs
# of the checkout it runs from (its own REPO), never a log at the session's cwd. So a deny row in a salus root's own log never
# reaches the digest, the ledger or the marker. The pin is the root the digest runs from: a copy of the digest rooted at the
# salus root (the RED control) does read that log. NOT pinned: a himmel-cwd session that names a salus path (it stays
# host-only), and there is no wrap-path gate on salus; both are the follow-up ticket's work.
SR="$TMP/salus-root"; mkdir -p "$SR/.claude/logs"
SS=8575c1a5-0000-4000-8000-0000000000a1
sed 's#"sessionId"#"cwd": "'"$SR"'/w", "sessionId"#; s#8575c1a5-0000-4000-8000-000000000001#'"$SS"'#g' "$CR/journal.jsonl" >"$TMP/$SS.jsonl"
# mklayout <root>: a checkout layout whose own copy of the digest takes REPO = <root> (import.meta.dir is the copy's directory).
mklayout() {
  mkdir -p "$1/scripts/eval/worker-digest" "$1/.claude/logs" || return 1
  cp "$HERE/worker-digest.ts" "$HERE/chain-incidents.mjs" "$1/scripts/eval/worker-digest/" || return 1
  ln -s "$HERE/../../config-ui" "$1/scripts/config-ui" && ln -s "$HERE/../../hooks" "$1/scripts/hooks" && ln -s "$HERE/../../observability" "$1/scripts/observability" && ln -s "$HERE/../lane-quality" "$1/scripts/eval/lane-quality" && ln -s "$HERE/../../lib" "$1/scripts/lib" && ln -s "$HERE/../../lanes" "$1/scripts/lanes"
}
# chainrow <call id> <member> <deny line>: one production hook-runs row.
chainrow() { jq -cn --arg c "$1" --arg m "$2" --arg l "$3" '{ts:"2026-11-02T12:00:09.000Z",v:1,origin:"production",event:"PreToolUse",session:"sess-8575",callId:$c,tool:"Bash",invocation:"000000000c01",exit:2,elapsed:20,members:[{member:$m,occurrence:1,outcome:"deny",reason:"RULE",elapsed:11,denyLine:$l}]}'; }
# layout_digest <root>: the layout's digest of the salus-rooted journal, both overrides cleared.
layout_digest() { env -u RUN_HOOK_CHAIN_SKIP_LOG -u RUN_HOOK_CHAIN_RUN_LOG bun "$1/scripts/eval/worker-digest/worker-digest.ts" --transcript "$TMP/$SS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" 2>/dev/null; }
ISO="$TMP/iso-checkout"; ISO2="$TMP/iso-checkout-2"
if ! { mklayout "$ISO" && mklayout "$ISO2" && mklayout "$SR"; }; then bad "the checkout layouts build"; fi
chainrow toolu_unrelated9 block-git-stash.sh "refused: HIMMELUNRELATED8575" >"$ISO/.claude/logs/hook-runs.jsonl"
chainrow toolu_sec1 block-read-secrets.sh "refused: HIMMELCANARY8575ix" >"$ISO2/.claude/logs/hook-runs.jsonl"
chainrow toolu_sec1 block-read-secrets.sh "refused: SALUSCANARY8575ph" >"$SR/.claude/logs/hook-runs.jsonl"
check "precondition: the salus root's own log holds the canary deny row, and the journal is under that root" 'grep -q SALUSCANARY8575ph "$SR/.claude/logs/hook-runs.jsonl" && grep -q "\"cwd\": \"$SR/w\"" "$TMP/$SS.jsonl"'
layout_digest "$ISO" >"$TMP/salus-digest.json" || bad "the himmel-side layout digest of the salus-rooted journal exits 0"
layout_digest "$ISO2" >"$TMP/salus-ctl-himmel.json"
layout_digest "$SR" >"$TMP/salus-ctl.json"
check "control: default resolution is live, a layout whose own log holds the call's row carries that row's line" '[ "$(jq -r ".failures[] | select(.class == \"denied/block-read-secrets\") | .refusal_line" "$TMP/salus-ctl-himmel.json")" = "refused: HIMMELCANARY8575ix" ]'
check "RED control: the same digest rooted at the salus root reads the log of that root and carries the canary, so the null below is the root the digest runs from" 'grep -q SALUSCANARY8575ph "$TMP/salus-ctl.json"'
check "the himmel-side digest of the salus-rooted journal carries a null line for the call and no salus canary" '[ "$(jq -r ".failures[] | select(.class == \"denied/block-read-secrets\") | .refusal_line" "$TMP/salus-digest.json")" = null ] && absent SALUSCANARY8575ph "$TMP/salus-digest.json"'
SF="$TMP/salus-fail.jsonl"
python3 "$LL" record --failures-ledger "$SF" --eval-ledger "$TMP/salus-eval.jsonl" --state-dir "$TMP/salus-state" --digest "$TMP/salus-digest.json" --worker N1 >"$TMP/salus-rec.out" 2>&1 || bad "record of the salus-rooted digest exits 0: $(head -c 300 "$TMP/salus-rec.out")"
check "the salus-rooted session's denied rows carry a null refusal_line, and the canary is in no digest, ledger, marker or eval row" '[ "$(jq -s "map(select(.failure == \"denied\")) | length" "$SF")" -gt 0 ] && [ "$(jq -s "map(select(.failure == \"denied\" and .refusal_line != null)) | length" "$SF")" = 0 ] && absent SALUSCANARY8575ph "$TMP/salus-digest.json" "$SF" "$TMP/salus-eval.jsonl" "$TMP/salus-state/$SS.json"'
SP="$TMP/salus-projects"; mkdir -p "$SP/-home-x-other"
{ title HIMMEL-8575-N9-salus "$SS"; cat "$TMP/$SS.jsonl"; } >"$SP/-home-x-other/$SS.jsonl"
python3 "$LL" backfill --since 2026-10-01 --projects "$SP" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/salus-bf-f.jsonl" --eval-ledger "$TMP/salus-bf-e.jsonl" --state-dir "$TMP/salus-bf-s" >"$TMP/salus-bf.out" 2>&1
check "backfill refuses the salus-rooted journal (salus=1) and writes nothing, the canary included" 'grep -q "salus=1" "$TMP/salus-bf.out" && [ ! -s "$TMP/salus-bf-f.jsonl" ] && [ ! -s "$TMP/salus-bf-e.jsonl" ] && absent SALUSCANARY8575ph "$TMP/salus-bf.out"'

echo "16. backfill --refresh: a corrected classifier reaches an old session without moving it in time"
R1=4670b000-0000-4000-8000-0000000000f1
OLD_E=2026-10-06T12:30:00Z; OLD_F=2026-10-06T12:31:00Z
# setup_refresh <dir>: one backfilled session made old (original times) and of an older generation (no digest_id,
# plus a stale error/TaskStop class the current digest no longer writes).
setup_refresh() {
    local d="$1"; mkdir -p "$d/p/-home-x-himmel"
    { title HIMMEL-4670-N1365-refresh "$R1"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$d/p/-home-x-himmel/$R1.jsonl"
    python3 "$LL" backfill --since 2026-10-01 --projects "$d/p" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$d/f.jsonl" --eval-ledger "$d/e.jsonl" --state-dir "$d/s" >/dev/null 2>&1
    jq -c --arg t "$OLD_E" '.ts = $t | del(.meta.digest_id, .meta.tool_failures)' "$d/e.jsonl" >"$d/e2" && mv "$d/e2" "$d/e.jsonl"
    jq -c --arg t "$OLD_F" '.ts = $t' "$d/f.jsonl" >"$d/f2" && mv "$d/f2" "$d/f.jsonl"
    local first; first="$(head -n 1 "$d/f.jsonl")"
    printf '%s\n' "$first" | jq -c --arg t "2026-10-06T12:32:00Z" '.ts = $t | .class = "error/TaskStop" | .failure = "error" | del(.refusal_line)' >>"$d/f.jsonl"
    jq -c 'del(.digest_id)' "$d/s/$R1.json" >"$d/m2" && mv "$d/m2" "$d/s/$R1.json"
}
rf() { env HIMMEL_LEDGER_REFRESH_STOP_AFTER="${2:-}" python3 "$LL" backfill --refresh --since 2026-10-01 --projects "$1/p" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$1/f.jsonl" --eval-ledger "$1/e.jsonl" --state-dir "$1/s"; }
D="$TMP/rf1"; setup_refresh "$D"
check "control: the old generation carries the stale error/TaskStop class" 'grep -q "\"class\":\"error/TaskStop\"" "$D/f.jsonl"'
rf "$D" >"$D/out" 2>&1 || bad "refresh exits 0: $(head -c 300 "$D/out")"
check "refresh reports one refreshed session" 'grep -q "refreshed=1 unchanged=0 refused=0 inconclusive=0" "$D/out"'
check "the refreshed eval row keeps the original ts and records refreshed_at and digest_id apart" 'jq -s "[.[] | select(.run_id == \"$R1\")] | length == 2 and .[-1].ts == \"$OLD_E\" and (.[-1].meta.refreshed_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\")) and (.[-1].meta.digest_id | test(\"^[0-9a-f]{32}$\"))" "$D/e.jsonl" | grep -q true'
check "the eval row carries its paired failures, without refusal text" 'jq -s ".[-1].meta.tool_failures | type == \"array\" and length > 0 and all(has(\"refusal_line\") | not)" "$D/e.jsonl" | grep -q true'
check "the stale TaskStop class is gone end to end" 'absent "error/TaskStop" "$D/f.jsonl" && jq -s ".[-1].meta.tool_failures | all(.class != \"error/TaskStop\")" "$D/e.jsonl" | grep -q true'
check "every superseding failure row keeps its original ts and names the generation" 'jq -s --arg id "$(jq -s -r ".[-1].meta.digest_id" "$D/e.jsonl")" "all(.ts == \"$OLD_F\" and .meta.digest_id == \$id and (.meta.refreshed_at | type == \"string\"))" "$D/f.jsonl" | grep -q true'
check "refreshed failure rows pass the v1 validator, and so do old ones" 'python3 "$LL" validate "$D/f.jsonl" >/dev/null && python3 "$LL" validate "$TMP/bf-fail.jsonl" >/dev/null'
check "the marker carries the digest_id last" '[ "$(jq -r .digest_id "$D/s/$R1.json")" = "$(jq -s -r ".[-1].meta.digest_id" "$D/e.jsonl")" ]'
cp "$D/f.jsonl" "$D/f.after"
rf "$D" >"$D/out2" 2>&1
check "the same digest_id on the marker is a complete no-op" 'grep -q "refreshed=0 unchanged=1" "$D/out2" && [ "$(jq -s "[.[] | select(.run_id == \"$R1\")] | length" "$D/e.jsonl")" = 2 ] && cmp -s "$D/f.jsonl" "$D/f.after"'

D="$TMP/rf1"; X="$(jq -s -r ".[-1].meta.digest_id" "$D/e.jsonl")"
gen_b="$(jq -s -c '.[-1] | .meta.digest_id = "ffffffffffffffffffffffffffffffff"' "$D/e.jsonl")"; printf '%s\n' "$gen_b" >>"$D/e.jsonl"
jq -c '.digest_id = "ffffffffffffffffffffffffffffffff"' "$D/s/$R1.json" >"$D/m3" && mv "$D/m3" "$D/s/$R1.json"
rf "$D" >"$D/out3" 2>&1
check "a generation that comes back (A, B, A) is appended again, so the newest row is A" 'grep -q "refreshed=1" "$D/out3" && [ "$(jq -s -r ".[-1].meta.digest_id" "$D/e.jsonl")" = "$X" ] && [ "$(jq -s "[.[] | select(.run_id == \"$R1\")] | length" "$D/e.jsonl")" = 4 ]'

D="$TMP/rf2"; setup_refresh "$D"
rf "$D" eval >/dev/null 2>&1
check "crash after the eval write: the new eval row is in, the failures and marker are still old" '[ "$(jq -s "[.[] | select(.run_id == \"$R1\")] | length" "$D/e.jsonl")" = 2 ] && grep -q "error/TaskStop" "$D/f.jsonl" && [ "$(jq -r ".digest_id // \"none\"" "$D/s/$R1.json")" = none ]'
rf "$D" >"$D/out" 2>&1
check "the replay finishes the failures and the marker with no duplicate eval row" 'grep -q "refreshed=1" "$D/out" && [ "$(jq -s "[.[] | select(.run_id == \"$R1\")] | length" "$D/e.jsonl")" = 2 ] && absent "error/TaskStop" "$D/f.jsonl" && [ "$(jq -r .digest_id "$D/s/$R1.json")" != null ]'
D="$TMP/rf3"; setup_refresh "$D"
rf "$D" failures >/dev/null 2>&1
check "crash after the failures write: rows replaced, marker still old" 'absent "error/TaskStop" "$D/f.jsonl" && [ "$(jq -r ".digest_id // \"none\"" "$D/s/$R1.json")" = none ]'
cp "$D/f.jsonl" "$D/f.crash"
rf "$D" >/dev/null 2>&1
check "the replay repairs the marker with no duplicate row anywhere" '[ "$(jq -s "[.[] | select(.run_id == \"$R1\")] | length" "$D/e.jsonl")" = 2 ] && cmp -s "$D/f.jsonl" "$D/f.crash" && [ "$(jq -r .digest_id "$D/s/$R1.json")" != null ]'

D="$TMP/rf4"; setup_refresh "$D"; : >"$D/e.jsonl"; cp "$D/f.jsonl" "$D/f.before"
rf "$D" >"$D/out" 2>&1
check "no original ok eval row: refused, never stamped with the refresh time" 'grep -q "refused=1" "$D/out" && grep -q "no original ok eval row" "$D/out" && [ ! -s "$D/e.jsonl" ] && cmp -s "$D/f.jsonl" "$D/f.before"'
D="$TMP/rf5"; setup_refresh "$D"; printf '{not json\n' >>"$D/p/-home-x-himmel/$R1.jsonl"; cp "$D/f.jsonl" "$D/f.before"; cp "$D/e.jsonl" "$D/e.before"
rf "$D" >"$D/out" 2>&1
check "a partial re-digest leaves the previous measurement untouched" 'grep -q "inconclusive=1" "$D/out" && cmp -s "$D/f.jsonl" "$D/f.before" && cmp -s "$D/e.jsonl" "$D/e.before"'
D="$TMP/rf6"; setup_refresh "$D"; printf '{"type":"system","subtype":"x","timestamp":"%s","sessionId":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$R1" >>"$D/p/-home-x-himmel/$R1.jsonl"; cp "$D/f.jsonl" "$D/f.before"
rf "$D" >"$D/out" 2>&1
check "a live session is not refreshed" 'grep -q "live=1" "$D/out" && cmp -s "$D/f.jsonl" "$D/f.before"'
row1="$(head -n 1 "$TMP/rf1/f.jsonl")"
printf '%s\n' "$(printf '%s' "$row1" | jq -c '.meta.extra = 1')" >"$TMP/rf-bad1.jsonl"
printf '%s\n' "$(printf '%s' "$row1" | jq -c '.meta.refreshed_at = "yesterday"')" >"$TMP/rf-bad2.jsonl"
printf '%s\n' "$(printf '%s' "$row1" | jq -c '.meta = "x"')" >"$TMP/rf-bad3.jsonl"
check "the validator rejects any other meta key, a bad refreshed_at and a non-object meta" '! python3 "$LL" validate "$TMP/rf-bad1.jsonl" >/dev/null 2>&1 && ! python3 "$LL" validate "$TMP/rf-bad2.jsonl" >/dev/null 2>&1 && ! python3 "$LL" validate "$TMP/rf-bad3.jsonl" >/dev/null 2>&1'
check "a normal record also writes the paired snapshot" 'jq -e "select(.run_id == \"$SID\") | (.meta.digest_id | test(\"^[0-9a-f]{32}$\")) and (.meta.tool_failures | type == \"array\")" "$EL" >/dev/null'

echo "17. backfill --refresh keeps each session's attribution, Claude version and effort, and reads the eval ledger once"
AT_TICKET=HIMMEL-4701
CV="$TMP/cv"; mkdir -p "$CV/vers" "$CV/bin1" "$CV/bin2" "$CV/cache/launch-logs" "$CV/nocache"
for v in 1.2.3 4.5.6; do printf '#!/bin/sh\n' >"$CV/vers/$v"; chmod +x "$CV/vers/$v"; done
ln -s "$CV/vers/1.2.3" "$CV/bin1/claude"; ln -s "$CV/vers/4.5.6" "$CV/bin2/claude"
printf 'headed-arm-worker: profile=worker-impl lane=native model=m role=worker session=attr-launch launched=2026-10-23T00:00:00Z\n' >"$CV/cache/launch-logs/attr-launch.log"
cat >"$CV/count.py" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import worker_ledger
scans = [0]
real = worker_ledger.eval_runs.scan_rows
def counted(*a, **k):
    scans[0] += 1
    return real(*a, **k)
worker_ledger.eval_runs.scan_rows = counted
rc = worker_ledger.main(sys.argv[2:])
print("scans=%d" % scans[0])
sys.exit(rc)
EOF
setup_attr() {
    local d="$1" s; shift; mkdir -p "$d/p/-home-x-himmel"
    for s in "$@"; do
        { title HIMMEL-4670-N1365-attr "$s"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$d/p/-home-x-himmel/$s.jsonl"
        bun "$DIG" --transcript "$d/p/-home-x-himmel/$s.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$d/$s.digest" 2>/dev/null
        env PATH="$CV/bin1:$PATH" CLAUDE_CODE_EFFORT_LEVEL=medium HIMMELCTL_CACHE_DIR="$CV/cache" python3 "$LL" record --failures-ledger "$d/f.jsonl" --eval-ledger "$d/e.jsonl" --state-dir "$d/s" --digest "$d/$s.digest" --worker N7777 --ticket "$AT_TICKET" --chief demo-chief --pr 4242 --doc himmel/x.md --launch-name attr-launch >/dev/null 2>&1
        jq -c 'del(.digest_id)' "$d/s/$s.json" >"$d/m2" && mv "$d/m2" "$d/s/$s.json"
    done
    jq -c 'del(.meta.digest_id, .meta.tool_failures)' "$d/e.jsonl" >"$d/e2" && mv "$d/e2" "$d/e.jsonl"
}
arf() { local d="$1"; shift; env PATH="$CV/bin2:$PATH" CLAUDE_CODE_EFFORT_LEVEL=xhigh HIMMELCTL_CACHE_DIR="$CV/nocache" "$@" backfill --refresh --since 2026-10-01 --projects "$d/p" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$d/f.jsonl" --eval-ledger "$d/e.jsonl" --state-dir "$d/s"; }
A1=9863b000-0000-4000-8000-000000000001; A2=9863b000-0000-4000-8000-000000000002; A3=9863b000-0000-4000-8000-000000000003
D="$TMP/at1"; setup_attr "$D" "$A1"
check "precondition: the original row carries the attribution, the Claude version and the effort" 'jq -e "select(.run_id == \"$A1\") | .lane == \"native\" and (.meta | .leg == \"N7777\" and .ticket == \"$AT_TICKET\" and .console == \"demo-chief\" and .pr == 4242 and .doc == \"himmel/x.md\" and .profile == \"worker-impl\" and .cli_version == \"1.2.3\" and .effort == \"medium\")" "$D/e.jsonl" >/dev/null && [ "$(jq -s "map(select(.session == \"$A1\" and .pr == 4242 and .console == \"demo-chief\" and .ticket == \"$AT_TICKET\" and .leg == \"N7777\")) | length" "$D/f.jsonl")" -gt 0 ]'
arf "$D" python3 -I "$HERE/worker_ledger.py" >"$D/out" 2>&1 || bad "attribution refresh exits 0: $(head -c 300 "$D/out")"
check "the refresh ran: one refreshed session, a second eval row" 'grep -q "refreshed=1 unchanged=0" "$D/out" && [ "$(jq -s "[.[] | select(.run_id == \"$A1\")] | length" "$D/e.jsonl")" = 2 ]'
check "the refreshed eval row keeps leg, ticket, pr, console, doc, profile and lane (the title names N1365)" 'jq -s -e ".[-1] | .lane == \"native\" and (.meta | .leg == \"N7777\" and .ticket == \"$AT_TICKET\" and .console == \"demo-chief\" and .pr == 4242 and .doc == \"himmel/x.md\" and .profile == \"worker-impl\")" "$D/e.jsonl" >/dev/null'
check "every refreshed failure row keeps leg, console, ticket and pr" 'jq -s -e --arg s "$A1" "map(select(.session == \$s)) | length > 0 and all(.leg == \"N7777\" and .console == \"demo-chief\" and .ticket == \"$AT_TICKET\" and .pr == 4242)" "$D/f.jsonl" >/dev/null'
check "the refresh under another CLAUDE_CODE_EFFORT_LEVEL and claude version leaves meta.cli_version and meta.effort at the original values" 'jq -s -e ".[-1].meta | .cli_version == \"1.2.3\" and .effort == \"medium\"" "$D/e.jsonl" >/dev/null'
D="$TMP/at2"; setup_attr "$D" "$A1" "$A2" "$A3"
arf "$D" python3 -I "$CV/count.py" "$HERE" >"$D/out" 2>&1 || bad "counted refresh exits 0: $(head -c 300 "$D/out")"
check "one backfill --refresh over three sessions refreshes all three and scans the eval ledger once" 'grep -q "refreshed=3 unchanged=0" "$D/out" && grep -qx "scans=1" "$D/out"'
cat >"$CV/stale.py" <<'EOF'
import json
import os
import sys
sys.path.insert(0, sys.argv[1])
import worker_ledger
d, session = sys.argv[2], sys.argv[3]
evals, fails, state = d + "/e.jsonl", d + "/f.jsonl", d + "/s"
with open(d + "/" + session + ".digest", encoding="utf-8") as fh:
    digest = json.load(fh)
who = {"leg": None, "ticket": None, "console": None, "pr": None, "doc": None, "lane": None, "state_dir": state,
       "backfill": True, "launch_name": None, "kind": "worker"}
index = worker_ledger._OkIndex(evals)
print(worker_ledger.refresh(digest, who, fails, evals, index))
marker = state + "/" + session + ".json"
with open(marker, encoding="utf-8") as fh:
    saved = json.load(fh)
del saved["digest_id"]
with open(marker, "w", encoding="utf-8") as fh:
    json.dump(saved, fh)
print(worker_ledger.refresh(digest, who, fails, evals, index))
print("eval_rows=%d" % sum(1 for line in open(evals, encoding="utf-8") if session in line))
EOF
D="$TMP/at3"; setup_attr "$D" "$A1"
env HIMMELCTL_CACHE_DIR="$CV/nocache" python3 -I "$CV/stale.py" "$HERE" "$D" "$A1" >"$D/out" 2>&1
check "an index built before another writer's eval row does not append the generation a second time" 'grep -qx "eval_rows=2" "$D/out"'
cat >"$CV/partial.py" <<'EOF'
import json
import sys
sys.path.insert(0, sys.argv[1])
import worker_ledger
d, session = sys.argv[2], sys.argv[3]
evals, fails, state = d + "/e.jsonl", d + "/f.jsonl", d + "/s"
with open(d + "/" + session + ".digest", encoding="utf-8") as fh:
    digest = json.load(fh)
who = {"leg": None, "ticket": None, "console": None, "pr": None, "doc": None, "lane": None, "state_dir": state,
       "backfill": True, "launch_name": None, "kind": "worker"}
print(worker_ledger.refresh(digest, who, fails, evals, worker_ledger._OkIndex(evals)))
with open(evals, "rb") as fh:
    data = fh.read()
start = data.rstrip(b"\n").rfind(b"\n") + 1
cut = start + (len(data) - start) // 2
with open(evals, "wb") as fh:
    fh.write(data[:cut])
index = worker_ledger._OkIndex(evals)
with open(evals, "ab") as fh:
    fh.write(data[cut:])
marker = state + "/" + session + ".json"
with open(marker, encoding="utf-8") as fh:
    saved = json.load(fh)
del saved["digest_id"]
with open(marker, "w", encoding="utf-8") as fh:
    json.dump(saved, fh)
print(worker_ledger.refresh(digest, who, fails, evals, index))
print("eval_rows=%d" % sum(1 for line in open(evals, encoding="utf-8") if session in line))
EOF
D="$TMP/at4"; setup_attr "$D" "$A1"
env HIMMELCTL_CACHE_DIR="$CV/nocache" python3 -I "$CV/partial.py" "$HERE" "$D" "$A1" >"$D/out" 2>&1
check "an index built while another writer's row is half appended reads that row whole and appends nothing again" 'grep -qx "eval_rows=2" "$D/out"'

echo "test-worker-ledger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
