#!/usr/bin/env bash
# test-route-rows.sh -- B3 of the RAG pilot: arm-tagged trace/route rows from a session
# transcript plus the host broker's private events, and the shared design section 5
# skip/service classifier. Fixture transcripts only (fixtures/route/build.py): no session,
# no model, no network.
#
# Platform guard: any bash with python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RR="$HERE/route-rows.py"
POL="$HERE/fixtures/route/policy.json"
W="$(mktemp -d "${TMPDIR:-/tmp}/pilot-route.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

python3 -I "$HERE/fixtures/route/build.py" "$W/fx"
row() { # <scenario> <arm> -> row JSON in $W/<scenario>.json, rc in $W/<scenario>.rc
  python3 -I "$RR" row --arm "$2" --transcript "$W/fx/$1/transcript.jsonl" --meta "$W/fx/$1/meta" \
    --result "$W/fx/$1/result.json" --policy "$POL" > "$W/$1.json" 2>"$W/$1.err"
  echo $? > "$W/$1.rc"
}
f() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(json.dumps(v))' "$W/$1.json" "$2"; }

# P5: counts reconcile to tool-use ids and broker admissions
row two-calls S
eq "P5: two s-qmd invocations in one Bash tool use count 2" 2 "$(f two-calls qmd_calls)"
eq "P5: they reconcile with the two broker admissions" "true 0" "$(f two-calls reconciled) $(cat "$W/two-calls.rc")"
eq "P5: every tool use has its result" '2 0' "$(f two-calls tool_uses) $(f two-calls unmatched_tool_uses)"
eq "P5: the returned files, the read one and the cited one" '2 1 1' "$(f two-calls returned_files) $(f two-calls returned_read) $(f two-calls cited_returned)"
eq "P5: first route and the qmd-only use class" '"s-qmd" "qmd_only"' "$(f two-calls first_route) $(f two-calls route_use)"
eq "P5: the row is arm-tagged and scorable" '"S" true' "$(f two-calls arm) $(f two-calls scorable)"
row none V
eq "P5: a session with no route call counts 0 and no use" '0 0 "none"' "$(f none qmd_calls) $(f none graph_calls) $(f none route_use)"
eq "P5: a V row reconciles trivially" "true" "$(f none reconciled)"
row offbyone S
eq "P5 red: three admissions against two invocations do not reconcile" "false 3" "$(f offbyone reconciled) $(cat "$W/offbyone.rc")"
row skip1 S
eq "skip: one answer-phase skip counts once" '1 ["expansion_failed"] true' "$(f skip1 skips) $(f skip1 skip_reasons) $(f skip1 skip_union)"
eq "skip: a probe-phase skip never counts toward the answer triple" '1' "$(f skip1 probe_or_fixed_skips_ignored)"
eq "skip: a skipped arm is not scorable" "false" "$(f skip1 scorable)"
row route-events S
eq "route events: empty, cap refusal, dropped hits and graph errors are not skips" '0 true' "$(f route-events skips) $(f route-events scorable)"
eq "route events: each is counted as a route event" '1 1 2 1' "$(f route-events empty_results) $(f route-events cap_refusals) $(f route-events dropped_hits) $(f route-events graph_errors)"
eq "route events: qmd and graph use are counted apart" '2 2 "both"' "$(f route-events qmd_calls) $(f route-events graph_calls) $(f route-events route_use)"
row forbidden S
eq "forbidden: a blocked credential read is recorded, not a void" '1' "$(f forbidden forbidden_blocked)"
eq "forbidden: a private task file whose content came back voids" '1 true' "$(f forbidden forbidden_content_returned) $(f forbidden hard_abort)"
row blocked-only S
eq "forbidden: blocked Read and Grep alone are recorded but do not void" '2 0 false' "$(f blocked-only forbidden_blocked) $(f blocked-only forbidden_content_returned) $(f blocked-only hard_abort)"
row runtime-reads S
eq "runtime: tool and qmd library reads are allowed runtime reads, not a void" '2 false' "$(f runtime-reads runtime_reads) $(f runtime-reads hard_abort)"
row channel S
eq "integrity: agent access to the broker channel is an integrity abort" '["channel_access"] true' "$(f channel integrity) $(f channel hard_abort)"
row direct-qmd S
eq "integrity: a direct qmd binary call bypasses the counter and aborts" '["direct_qmd"] true' "$(f direct-qmd integrity) $(f direct-qmd hard_abort)"
row q-remote Q
eq "Q: a recorded remote attempt is counted (it must stay zero) and is a skip" '1 1' "$(f q-remote q_remote_attempts) $(f q-remote skips)"
row no-json V
eq "service: no parseable CLI result JSON is a service failure" '["no_cli_json"] false' "$(f no-json service) $(f no-json scorable)"
row auth-error V
eq "service: a provider/auth error is a service failure" '["provider_or_auth_error"]' "$(f auth-error service)"
row budget V
eq "scored false: an explicit budget-reached result is scorable, not service" '[] true false' "$(f budget service) $(f budget scorable) $(f budget answer_block)"
row malformed V
eq "scored false: a missing ANSWER/FILES block is scorable, not service" '[] true false' "$(f malformed service) $(f malformed scorable) $(f malformed answer_block)"
row skip-and-service Q
eq "both: a co-occurring service failure and skip keep both reasons" '["no_cli_json"] ["timeout"]' "$(f skip-and-service service) $(f skip-and-service skip_reasons)"

# the task-level union: excluded once, counted toward the two-task skip ceiling
python3 -I "$RR" task --row "$W/none.json" --row "$W/skip-and-service.json" --row "$W/two-calls.json" > "$W/task.json"
eq "task: a service+skip triple is excluded once and counts toward the skip ceiling" '{"excluded": true, "hard_abort": false, "reasons": {"Q": ["no_cli_json", "timeout"]}, "skip_counted": true}' "$(cat "$W/task.json")"
python3 -I "$RR" task --row "$W/no-json.json" --row "$W/two-calls.json" --row "$W/two-calls.json" > "$W/task2.json"
eq "task: a V service failure excludes the triple without touching the skip ceiling" '{"excluded": true, "hard_abort": false, "reasons": {"V": ["no_cli_json"]}, "skip_counted": false}' "$(cat "$W/task2.json")"
python3 -I "$RR" task --row "$W/none.json" --row "$W/two-calls.json" --row "$W/route-events.json" > "$W/task3.json"
eq "task: a clean triple is not excluded" '{"excluded": false, "hard_abort": false, "reasons": {}, "skip_counted": false}' "$(cat "$W/task3.json")"
eq "task: answer-ab.py is never imported" 0 "$(grep -c 'answer-ab\|answer_ab' "$RR")"

if [ "$fails" -gt 0 ]; then printf '%d failure(s)\n' "$fails"; exit 1; fi
printf 'all route-row rows passed\n'
