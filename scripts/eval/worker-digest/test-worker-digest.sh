#!/usr/bin/env bash
# scripts/eval/worker-digest/test-worker-digest.sh - hermetic suite for the worker digest.
# Synthetic fixtures only; no model call, no bank, no ledger write.
#  1. every class key of spec section 2.2 comes out of fixtures/classes.jsonl;
#  2. the classifier sub-class: ledger first, else the journal's bracket against the fixed list;
#  3. suite rows carry final_red; trajectory joins by tool_call_id; trajectory rows;
#  4. the #1976 agents.jsonl fixture digests as expected;
#  5. canary: no free text from the journal reaches the digest (spec 6.1);
#  6. denial cross-check: mapper and trajectory.py agree except the enumerated exceptions (spec 2.3);
#  7. status ok / partial / inconclusive, and the digest spawns nothing but git and python3.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIG="$HERE/worker-digest.ts"
FX="$HERE/fixtures"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/worker-digest-test.XXXXXX")" || { echo "test-worker-digest: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# No case reads this checkout's real hook-chain logs: both point at an absent file unless a case overrides them.
export RUN_HOOK_CHAIN_SKIP_LOG="$TMP/no-chain-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$TMP/no-chain-runs.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# absent: grep found no match (status 1); a grep error (status 2) is not proof of absence.
absent() { grep -q "$@"; [ $? = 1 ]; }

SID=4670c1a5-0000-4000-8000-000000000001
cp "$FX/classes.jsonl" "$TMP/$SID.jsonl"
digest() { bun "$DIG" --transcript "$1" --denials-ledger "$FX/classifier-denials.jsonl" "${@:2}"; }
digest "$TMP/$SID.jsonl" >"$TMP/classes.json" 2>"$TMP/classes.err" || bad "digest of classes.jsonl exits 0: $(head -c 300 "$TMP/classes.err")"
row() { jq -c --arg k "$1" --arg a "${2:-main}" '[.failures[] | select(.class == $k and .agent.id == $a)] | .[0] // empty' "$TMP/classes.json"; }

echo "1. class keys (spec 2.2)"
check "a chained-runner refusal is keyed by the hook after the closing ]:, not by the chain" '[ "$(row denied/guard-pr-check-literal | jq .count)" = 2 ]'
check "an emoji-led hook refusal is keyed by its hook" '[ "$(row denied/read-clamp | jq .count)" = 1 ]'
check "a name that is not a scripts/hooks basename is denied/other" '[ "$(row denied/other | jq .count)" = 1 ]'
check "the permission prompt is denied/permission-prompt" '[ "$(row denied/permission-prompt | jq .count)" = 1 ]'
check "an allow-listed tool error is keyed by its tool" '[ "$(row error/Edit | jq .count)" = 1 ]'
check "an mcp tool error is error/mcp" '[ "$(row error/mcp | jq .count)" = 1 ]'
check "an unknown tool error is error/other" '[ "$(row error/other | jq .count)" = 1 ]'
check "a BLOCKED report is blocked/-" '[ "$(row blocked/- | jq .count)" = 1 ]'
check "an API error with a listed code is run_error/<code>" '[ "$(row run_error/server_error | jq .count)" = 1 ]'
check "a subagent refusal is its own row under its agent id, role subagent" '[ "$(row denied/check-push-target sub01 | jq -c "[.count, .agent.role, .agent.model]")" = "[1,\"subagent\",\"claude-sonnet-5-5\"]" ]'
check "the main agent row names role and model" '[ "$(row denied/read-clamp | jq -c "[.agent.role, .agent.model]")" = "[\"agent\",\"claude-opus-5-5\"]" ]'
check "tool_call_ids point back into the journal" '[ "$(row denied/guard-pr-check-literal | jq -c .tool_call_ids)" = "[\"toolu_d1\",\"toolu_d2\"]" ]'
check "first_ts and last_ts bound the class" 'row denied/guard-pr-check-literal | jq -e ".first_ts < .last_ts" >/dev/null'

echo "tool denominators (HIMMEL-4816)"
check "calls retain Bash, Read and the exact MCP tool separately" 'jq -e ".metrics.tool_calls_by_tool | .Bash > 0 and .Read > 0 and .mcp__qmd__query == 1" "$TMP/classes.json" >/dev/null'
check "per-tool calls sum to the session total and unknown lane never comes from a model" 'jq -e "([.metrics.tool_calls_by_tool[]] | add) == .metrics.tool_calls and .lane == \"unknown\" and ([.tool_health[].lane] | unique) == [\"unknown\"]" "$TMP/classes.json" >/dev/null'
check "per-tool failures exclude text reports and grep no-match" 'jq -e ".metrics.tool_failures_by_tool.Edit == 1 and .metrics.tool_failures_by_tool.mcp__qmd__query == 1" "$TMP/classes.json" >/dev/null'

echo "2. classifier sub-class: ledger, then the journal bracket against the fixed list"
# The fixture's ledger row and journal bracket for toolu_c1 share one category, so a broken ledger join
# would still pass via the bracket fallback. Rewrite the bracket to another listed category; the ledger's must win.
mkdir -p "$TMP/lw"  # the digest keys the ledger by the journal basename, so the copy keeps "$SID.jsonl"
sed 's/Reason: \[Merge Without Review\]\./Reason: [Security Weaken]./' "$TMP/$SID.jsonl" >"$TMP/lw/$SID.jsonl"
digest "$TMP/lw/$SID.jsonl" >"$TMP/ledger-wins.json" 2>/dev/null || bad "the ledger-priority digest exits 0"
check "a ledger row with a listed category keys it" '[ "$(grep -c "Reason: \[Security Weaken\]" "$TMP/lw/$SID.jsonl")" = 1 ] && [ "$(jq -c "[.failures[] | select(.class | startswith(\"denied/classifier:\")) | [.class, .tool_call_ids]] | map(select(.[1] | index(\"toolu_c1\")))" "$TMP/ledger-wins.json")" = "[[\"denied/classifier:merge-without-review\",[\"toolu_c1\"]]]" ]'
check "a ledger tag of unknown falls back to the journal bracket on the list" '[ "$(row denied/classifier:out-of-place-publication | jq -c .tool_call_ids)" = "[\"toolu_c2\"]" ]'
check "an off-list bracket and a malformed bracket are classifier:other" '[ "$(row denied/classifier:other | jq -c .tool_call_ids)" = "[\"toolu_c3\",\"toolu_c4\"]" ]'
check "another session's ledger row is never joined" 'absent session-transcript-tampering "$TMP/classes.json"'

echo "3. suite rows, the trajectory join, trajectory rows"
check "a tracked suite that later passes is not final_red" '[ "$(row suite/test-trajectory.sh | jq -c "[.count, .final_red]")" = "[1,false]" ]'
check "a tracked suite whose last run failed is final_red" '[ "$(row suite/test-eval-runs.sh | jq -c "[.count, .final_red]")" = "[1,true]" ]'
check "an untracked suite is suite/other" '[ "$(row suite/other | jq .count)" = 1 ]'
check "only suite rows carry final_red" '[ "$(jq "[.failures[] | select(has(\"final_red\") and (.failure != \"suite\"))] | length" "$TMP/classes.json")" = 0 ]'
check "identical_retry and recovered come from trajectory.py, joined by tool_call_id" '[ "$(row denied/guard-pr-check-literal | jq -c "[.identical_retry, .recovered]")" = "[1,false]" ]'
check "a subagent row has no trajectory join (main agent only)" '[ "$(row denied/check-push-target sub01 | jq -c "[.identical_retry, .recovered]")" = "[null,null]" ]'
check "identical_denied_retries >= 1 writes a traj/identical-retry row" '[ "$(row traj/identical-retry | jq -c "[.failure, .count]")" = "[\"traj\",1]" ]'
check "metrics count the session" 'jq -e ".metrics | .turns == 3 and .subagents == 1 and .fail_denied == 10 and .fail_suite == 3 and .fail_blocked == 1 and .fail_error == 3 and .run_errors == 1 and .interrupts == 1 and .identical_denied_retries == 1" "$TMP/classes.json" >/dev/null'
check "the digest names its versions and the main model" 'jq -e ".digest_v == 3 and .mapper_v == 2 and .trajectory_v == 2 and .model == \"claude-opus-5-5\" and .session == \"$SID\" and .status == \"ok\"" "$TMP/classes.json" >/dev/null'

echo "4. the #1976 agents.jsonl fixture"
cp "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$TMP/agents.jsonl"
digest "$TMP/agents.jsonl" >"$TMP/agents.json" 2>/dev/null
check "agents.jsonl digests to its four failures" '[ "$(jq -c "[.failures[] | select(.failure != \"traj\") | .class] | sort" "$TMP/agents.json")" = "[\"blocked/-\",\"denied/check-push-target\",\"error/Bash:no-such-file\",\"suite/other\"]" ]'
check "a subagent_type outside the allow-list is kind other" 'jq -e ".agents | map(select(.id == \"a1b2c3\")) | .[0].kind == \"other\"" "$TMP/agents.json" >/dev/null'

echo "5. canary: no journal text reaches the digest (spec 6.1)"
cp "$FX/canary.jsonl" "$TMP/$SID.c.jsonl"
check "the canary fixture carries the canary" '[ "$(grep -c CANARY4670zq "$FX/canary.jsonl")" -ge 20 ]'
digest "$TMP/$SID.c.jsonl" >"$TMP/canary.json" 2>"$TMP/canary.err" || bad "the canary digest exits 0"
check "the canary digest is non-empty" 'jq -e ".failures | length > 10" "$TMP/canary.json" >/dev/null'
check "the canary appears nowhere in the digest or its stderr" 'absent CANARY4670zq "$TMP/canary.json" "$TMP/canary.err"'
# input_head and the raw reason_tag never leave the host. The digest maps reason_tag onto the closed
# category list (slugged); every row here also carries input_head, and the off-list tag is a canary.
jq -c '. + {input_head: "IHEAD4670zq"} | if .reason_tag == "unknown" then .reason_tag = "RTAG4670zq" else . end' "$FX/classifier-denials.jsonl" >"$TMP/egress-ledger.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$TMP/egress-ledger.jsonl" >"$TMP/egress.json" 2>"$TMP/egress.err" || bad "the egress digest exits 0"
check "the egress ledger carries input_head and the canary tag" '[ "$(grep -c IHEAD4670zq "$TMP/egress-ledger.jsonl")" = 4 ] && [ "$(grep -c RTAG4670zq "$TMP/egress-ledger.jsonl")" = 1 ]'
check "the egress digest still keys the ledger category" '[ "$(jq -c "[.failures[] | select(.class == \"denied/classifier:merge-without-review\")] | length" "$TMP/egress.json")" = 1 ]'
check "no input_head key or value reaches the digest or its stderr" 'absent -e input_head -e IHEAD4670zq "$TMP/egress.json" "$TMP/egress.err"'
check "no raw reason_tag reaches the digest or its stderr, only the slugged category" 'absent -e RTAG4670zq -e "Merge Without Review" -e "Session Transcript Tampering" -e reason_tag "$TMP/egress.json" "$TMP/egress.err"'
# An off-list tag falls back to the journal bracket, so the class alone cannot show the canary row joined.
# The same row (ts, tool, session) with an on-list tag must key toolu_c2, else the absence check above is vacuous.
jq -c 'if .reason_tag == "RTAG4670zq" then .reason_tag = "Merge Without Review" else . end' "$TMP/egress-ledger.jsonl" >"$TMP/probe-ledger.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$TMP/probe-ledger.jsonl" >"$TMP/probe.json" 2>/dev/null || bad "the join-probe digest exits 0"
check "the canary ledger row is matched to toolu_c2" '[ "$(jq -c "[.failures[] | select(.class == \"denied/classifier:merge-without-review\") | .tool_call_ids[]]" "$TMP/probe.json")" = "[\"toolu_c1\",\"toolu_c2\"]" ]'

echo "6. denial cross-check: mapper vs trajectory.py (spec 2.3)"
: >"$TMP/divergence.txt"
for f in "$REPO"/scripts/eval/lane-quality/fixtures/trajectory/*.jsonl "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$FX/classes.jsonl"; do
  n="$(basename "$f")"
  digest "$f" >"$TMP/cross.json" || bad "the cross-check digest of $n exits 0"
  jq -r --arg n "$n" '.stats.denial_divergence[] | "\($n) \(.tool_call_id) \(.only)"' "$TMP/cross.json" >>"$TMP/divergence.txt" || bad "the cross-check digest of $n lists its divergences"
done
grep -v '^#' "$HERE/denial-exceptions.txt" | grep -v '^$' | awk '{print $1, $2, $3}' | sort >"$TMP/allowed.txt"
sort "$TMP/divergence.txt" >"$TMP/seen.txt"
check "every divergence is an enumerated exception" '[ -z "$(comm -23 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -23 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every enumerated exception still occurs (no stale lines)" '[ -z "$(comm -13 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -13 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every exception names its reason" 'awk "!/^#/ && NF > 0 && NF < 4 { bad = 1 } END { exit bad }" "$HERE/denial-exceptions.txt"'

echo "7. status and spawns"
check "a missing journal is inconclusive, exit 0" 'digest "$TMP/nope.jsonl" | jq -e ".status == \"inconclusive\" and .failures == []" >/dev/null'
check "a journal over the size cap is inconclusive" 'digest "$TMP/$SID.jsonl" --max-bytes 100 | jq -e ".status == \"inconclusive\"" >/dev/null'
{ cat "$FX/classes.jsonl"; echo 'not json'; } >"$TMP/$SID.p.jsonl"
check "a malformed line makes it partial" 'digest "$TMP/$SID.p.jsonl" | jq -e ".status == \"partial\" and .stats.malformed == 1" >/dev/null'
check "a usage error exits 2" 'bun "$DIG" >/dev/null 2>&1; [ $? = 2 ]'
check "the digest spawns only git and python3, never a model CLI" '[ "$(grep -oE "spawnSync\(\[\"[a-z0-9]+\"" "$DIG" | sort -u | tr -d "\n")" = "spawnSync([\"git\"spawnSync([\"python3\"" ] && absent -E "\b(claude|codex|gemini)\b.*spawn|spawn.*\b(claude|codex|gemini)\b" "$DIG"'

echo "8. a subagent in its own file, a relative path, more denials than ids, a failed trajectory"
S2=4670c1a5-0000-4000-8000-000000000002
cp -R "$FX/split" "$TMP/split"
(cd "$TMP/split" && bun "$DIG" --transcript "$S2.jsonl" --denials-ledger "$FX/classifier-denials.jsonl") >"$TMP/split.json" 2>"$TMP/split.err"
srow() { jq -c --arg k "$1" --arg a "${2:-main}" '[.failures[] | select(.class == $k and .agent.id == $a)] | .[0] // empty' "$TMP/split.json"; }
check "a relative --transcript still follows its subagent file" '[ "$(jq .stats.files "$TMP/split.json")" = 2 ] && [ -n "$(srow denied/permission-prompt sub02)$(srow suite/test-trajectory.sh sub02)" ]'
check "final_red is per agent: main went green, the subagent stayed red" '[ "$(srow suite/test-trajectory.sh | jq -c "[.count, .final_red]")" = "[1,false]" ] && [ "$(srow suite/test-trajectory.sh sub02 | jq -c "[.count, .final_red]")" = "[1,true]" ]'
check "two untracked suites on suite/other: one still red keeps the row final_red" '[ "$(srow suite/other | jq -c "[.count, .final_red]")" = "[2,true]" ]'
check "the trajectory join covers denials past the five tool_call_ids kept" '[ "$(srow denied/read-clamp | jq -c "[.count, (.tool_call_ids | length), .recovered, .identical_retry]")" = "[6,5,false,1]" ]'
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/fakebin/python3"
chmod +x "$TMP/fakebin/python3"
check "a failed trajectory.py makes it partial" 'PATH="$TMP/fakebin:$PATH" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.trajectory_failed == true" >/dev/null'
check "a trajectory.py that ran is not a failure" 'jq -e ".stats.trajectory_failed == false" "$TMP/classes.json" >/dev/null'
mkdir -p "$TMP/nogit"
printf '#!/bin/sh\nexit 1\n' >"$TMP/nogit/git"
chmod +x "$TMP/nogit/git"
check "a failed git ls-files makes it partial and names the lookup" 'PATH="$TMP/nogit:$PATH" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.lookups_failed == [\"tracked-tests\"]" >/dev/null'
mkdir -p "$TMP/onlybun"
ln -s "$(command -v bun)" "$TMP/onlybun/bun"
check "git and python3 missing from PATH make it partial, exit 0" 'PATH="$TMP/onlybun" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.trajectory_failed == true and .stats.lookups_failed == [\"tracked-tests\"]" >/dev/null'
check "lookups that worked leave lookups_failed empty" 'jq -e ".stats.lookups_failed == []" "$TMP/classes.json" >/dev/null'

echo "9. error/Bash sub-classes and the context-guard denials (HIMMEL-4785)"
S9=4785c1a5-0000-4000-8000-000000000001
cp "$FX/bash-errors.jsonl" "$TMP/$S9.jsonl"
digest "$TMP/$S9.jsonl" >"$TMP/be.json" 2>"$TMP/be.err" || bad "digest of bash-errors.jsonl exits 0: $(head -c 300 "$TMP/be.err")"
berow() { jq -c --arg k "$1" '[.failures[] | select(.class == $k and .agent.id == "main")] | .[0] // empty' "$TMP/be.json"; }
check "a grep that matched nothing (exit 1, empty output) is not a failure row" '[ "$(jq "[.failures[] | select(.class | test(\"no-match\"))] | length" "$TMP/be.json")" = 0 ] && [ -z "$(berow error/Bash:no-match)" ]'
check "it is counted as ok_no_match, not as an error" 'jq -e ".metrics.ok_no_match == 4 and .metrics.fail_error == 21" "$TMP/be.json" >/dev/null'
check "no failure row carries an ok/ class" '[ "$(jq "[.failures[] | select(.class | startswith(\"ok/\"))] | length" "$TMP/be.json")" = 0 ]'
check "a grep with output, a non-grep empty exit 1, a grep followed by a failing command or piped into one or into a parenthesized one, a grep with an apostrophe in a trailing comment followed by a failing command, a grep whose escaped space makes the # an argument, a grep whose backslash-newline continuation leaves a comment line with an apostrophe, a usage error that names two tracked scripts and neither in its output, a grep exit 2, an unmatched exit 3 and an untracked script stay error/Bash" '[ "$(berow error/Bash | jq .count)" = 13 ]'
check "a usage error is keyed by the tracked script, one row per script" '[ "$(berow error/Bash:usage:impacted-suites | jq .count)" = 3 ] && [ "$(berow error/Bash:usage:write-verdicts | jq .count)" = 1 ]'
check "clear-cr-marker exit 14 is error/Bash:cr-gate-exit-14, another script at 14 is not" '[ "$(berow error/Bash:cr-gate-exit-14 | jq -c "[.count, .tool_call_ids]")" = "[1,[\"toolu_cr1\"]]" ]'
check "a zsh nomatch is error/Bash:zsh-nomatch, not no-match" '[ "$(berow error/Bash:zsh-nomatch | jq -c .tool_call_ids)" = "[\"toolu_z1\"]" ]'
check "a missing path is error/Bash:no-such-file in both spellings" '[ "$(berow error/Bash:no-such-file | jq -c .tool_call_ids)" = "[\"toolu_f1\",\"toolu_f2\"]" ]'
check "a context-guard refusal is its own denied/ class, three spellings" '[ "$(berow denied/guard-leg-context-handoff | jq -c .tool_call_ids)" = "[\"toolu_c1\",\"toolu_c2\",\"toolu_c3\"]" ]'
check "an unknown hook is still denied/other" '[ "$(berow denied/other | jq -c .tool_call_ids)" = "[\"toolu_c4\"]" ]'
check "every sub-class key passes the router alphabet" 'jq -r ".failures[].class" "$TMP/be.json" | grep -Ev "^(denied|suite|blocked|error|run_error|traj)/[A-Za-z0-9._:+-]{1,80}$" | wc -l | tr -d " " | grep -qx 0'

echo "10. by-design exit codes come from the registry, not the failure count (HIMMEL-4853)"
# fixtures/exit-codes.jsonl: 14 non-zero Bash results. Before the registry all 14 were failures (12 error + 2 suite).
S10=4853c1a5-0000-4000-8000-000000000001
cp "$FX/exit-codes.jsonl" "$TMP/$S10.jsonl"
digest "$TMP/$S10.jsonl" >"$TMP/ec.json" 2>"$TMP/ec.err" || bad "digest of exit-codes.jsonl exits 0: $(head -c 300 "$TMP/ec.err")"
check "result and retry rcs are counted apart: 5 result, 2 retry" 'jq -e ".metrics.ok_result == 5 and .metrics.ok_retry == 2" "$TMP/ec.json" >/dev/null'
check "only the 7 real failures stay: a check-ci 1, an unlisted rc, a refusal, an unregistered script, two compound chains and a suite red" 'jq -e ".metrics.fail_error == 6 and .metrics.fail_suite == 1 and ([.failures[].count] | add) == 7" "$TMP/ec.json" >/dev/null'
check "quiet-run 75 (a suite run) is a retry, the same suite's exit 1 is still suite/other" 'jq -e "([.by_design[] | select(.script == \"quiet-run.sh\")] | .[0] | [.rc, .class, .count]) == [\"75\",\"retry\",1] and ([.failures[] | select(.class == \"suite/other\")] | .[0].count) == 1" "$TMP/ec.json" >/dev/null'
check "by_design rows carry script, rc, class and count only" 'jq -e "[.by_design[] | keys | join(\",\")] | unique == [\"class,count,rc,script\"]" "$TMP/ec.json" >/dev/null'
check "a compound command stays an error unless every segment resolves: check-ci then queue-lock status at rc 3 or 11 is not by design" 'jq -e "([.by_design[] | select(.script == \"check-ci.sh\" and .rc == \"3\")] | .[0].count) == 1 and ([.by_design[] | select(.script == \"queue-lock.sh\" and .rc == \"11\")] | .[0].count) == 1" "$TMP/ec.json" >/dev/null'
check "a refusal rc (merge-on-green 17) and an unlisted rc (check-ci 9) stay error/Bash" '[ "$(jq "[.failures[] | select(.class == \"error/Bash\")] | .[0].count" "$TMP/ec.json")" = 6 ]'
check "no failure row exists for a result or retry rc, so the router never sees one" 'jq -e "[.failures[] | select(.failure == \"error\" or .failure == \"suite\")] | map(.count) | add == 7" "$TMP/ec.json" >/dev/null'

echo "11. exploration cost: weighted tokens before the first edit (HIMMEL-5516)"
# fixtures/exploration.jsonl: Read (1650) + Grep (1300, one message streamed over two lines) + the Edit's own message (1950)
# = 4900 weighted (cache_read at the Sonnet 5.5 price x0.05, haiku x0.1; cache_creation x1); a 500 subagent turn before the cut; a 99999 turn after it.
S11=5516e0a1-0000-4000-8000-000000000001
cp "$FX/exploration.jsonl" "$TMP/$S11.jsonl"
digest "$TMP/$S11.jsonl" >"$TMP/ex.json" 2>"$TMP/ex.err" || bad "digest of exploration.jsonl exits 0: $(head -c 300 "$TMP/ex.err")"
check "tokens are the weighted sum up to and including the first Edit's message" 'jq -e ".exploration.tokens == 4900" "$TMP/ex.json" >/dev/null'
check "Read and Bash cat are 2 reads, Grep and Bash git grep are 2 searches, cut by an edit" 'jq -e ".exploration | .reads == 2 and .searches == 2 and .cut == \"edit\"" "$TMP/ex.json" >/dev/null'
check "subagent turns before the cut are counted apart and never added to tokens" 'jq -e ".exploration.sub_tokens == 500" "$TMP/ex.json" >/dev/null'
# A git commit cuts like an edit; a session with neither reports cut "none" and the whole-session sum.
sed -e '/toolu_x3/d' -e 's/"name": "Read", "input": {"file_path": "\/b"}/"name": "Bash", "input": {"command": "git commit -m x"}/' "$TMP/$S11.jsonl" >"$TMP/$S11.c.jsonl"
mkdir -p "$TMP/ex2" && mv "$TMP/$S11.c.jsonl" "$TMP/ex2/$S11.jsonl"
digest "$TMP/ex2/$S11.jsonl" >"$TMP/ex2.json" 2>/dev/null || bad "the commit-cut digest exits 0"
check "a git commit tool call is the cut when no edit came first" 'jq -e ".exploration | .cut == \"commit\" and .tokens == 2950 + 100000" "$TMP/ex2.json" >/dev/null'
# Only a real git commit command cuts. Same commit-cut fixture, other Bash commands in the cut slot.
cutwith() { # <dir> <json-escaped command>: digest the commit-cut fixture with that Bash command in the cut slot
  sed -e '/toolu_x3/d' -e "s/\"name\": \"Read\", \"input\": {\"file_path\": \"\\/b\"}/\"name\": \"Bash\", \"input\": {\"command\": \"$2\"}/" "$TMP/$S11.jsonl" >"$TMP/$1.jsonl"
  mkdir -p "$TMP/$1" && mv "$TMP/$1.jsonl" "$TMP/$1/$S11.jsonl"
  digest "$TMP/$1/$S11.jsonl" 2>/dev/null | jq -r .exploration.cut
}
check "echoed text that mentions git commit is not a commit cut" '[ "$(cutwith ex4 "echo git commit done")" = none ]'
check "git commit-tree is not a commit cut" '[ "$(cutwith ex5 "git commit-tree abc123 -m x")" = none ]'
check "a git commit after && and with a global option still cuts" '[ "$(cutwith ex6 "cd x \&\& git -C y commit -m x")" = commit ]'
check "a git commit behind an env assignment still cuts" '[ "$(cutwith ex7 "GIT_AUTHOR_DATE=2026-01-01 git commit -m x")" = commit ]'
check "a git commit behind command still cuts" '[ "$(cutwith ex8 "command git commit -m x")" = commit ]'
check "a git commit behind sudo still cuts" '[ "$(cutwith ex9 "sudo git commit -m x")" = commit ]'
check "a git commit behind env VAR=x still cuts" '[ "$(cutwith ex10 "env GIT_AUTHOR_DATE=2026-01-01 git commit -m x")" = commit ]'
check "a git commit in an if/then head still cuts" '[ "$(cutwith ex11 "if true; then git commit -m x; fi")" = commit ]'
check "a git commit in a do head still cuts" '[ "$(cutwith ex12 "for f in a; do git commit -m x; done")" = commit ]'
check "echoed sudo git commit is not a commit cut" '[ "$(cutwith ex13 "echo sudo git commit done")" = none ]'
grep -v '"name": "Edit"' "$TMP/$S11.jsonl" | grep -v 'toolu_x4' | grep -v 'msg_x4' >"$TMP/ex3.jsonl"
mkdir -p "$TMP/ex3" && mv "$TMP/ex3.jsonl" "$TMP/ex3/$S11.jsonl"
digest "$TMP/ex3/$S11.jsonl" >"$TMP/ex3.json" 2>/dev/null || bad "the no-cut digest exits 0"
check "no edit and no commit reports cut none" 'jq -e ".exploration.cut == \"none\"" "$TMP/ex3.json" >/dev/null'

echo "12. per-profile tool usage and drop-from-default candidates (HIMMEL-6970)"
check "the digest stamps --profile on every tool_health row and on the digest" 'bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" --profile worker-impl | jq -e ".profile == \"worker-impl\" and ([.tool_health[].profile] | unique) == [\"worker-impl\"]" >/dev/null'
check "without --profile the digest says unknown, never an ambient guess" 'jq -e ".profile == \"unknown\" and ([.tool_health[].profile] | unique) == [\"unknown\"]" "$TMP/classes.json" >/dev/null'
check "a profile name outside the closed alphabet is a usage error" 'bun "$DIG" --transcript "$TMP/$SID.jsonl" --profile "A b" >/dev/null 2>&1; [ $? = 2 ]'
PROLL() { node --input-type=module -e "
import { readFileSync } from 'node:fs';
import { rollupToolHealth } from '$HERE/tool-health.mjs';
const rows = readFileSync('$FX/profiles/eval-runs.jsonl', 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const listing = JSON.parse(readFileSync('$FX/profiles/listing.json', 'utf8'));
const out = rollupToolHealth(rows, [], new URLSearchParams('$1'), Date.parse('2026-10-22T12:00:00Z'), listing);
console.log(JSON.stringify(out));"; }
PROLL "" >"$TMP/prof.json" 2>"$TMP/prof.err" || bad "the profile roll-up runs: $(head -c 300 "$TMP/prof.err")"
pt() { jq -c --arg p "$1" --arg t "$2" '.profiles[]? | select(.profile == $p) | .tools[] | select(.tool == $t)' "$TMP/prof.json"; }
check "the roll-up lists the profiles it saw" 'jq -e ".filters.profiles == [\"chief\", \"worker-impl\"]" "$TMP/prof.json" >/dev/null'
check "a tool never called in profile A and called in profile B reads 0 calls in A and 20 in B" '[ "$(pt worker-impl mcp__qmd__query | jq .calls)" = 0 ] && [ "$(pt chief mcp__qmd__query | jq -c "[.calls, .failures, .rate]")" = "[20,3,0.15]" ]'
check "per-profile Bash counts do not mix: 70 in worker-impl, 15 in chief" '[ "$(pt worker-impl Bash | jq .calls)" = 70 ] && [ "$(pt chief Bash | jq .calls)" = 15 ]'
check "a listed tool with a cost and no calls is a drop candidate, a called one is kept" '[ "$(pt worker-impl mcp__qmd__query | jq -r .verdict)" = drop-candidate ] && [ "$(pt chief mcp__qmd__query | jq -r .verdict)" = keep ]'
check "drop_candidates names exactly the two unused listed tools with their cost and window" '[ "$(jq -c "[.drop_candidates[] | [.profile, .tool, .listing_tokens, .window_days]] | sort" "$TMP/prof.json")" = "[[\"chief\",\"mcp__graphify__query\",400,7],[\"worker-impl\",\"mcp__qmd__query\",900,7]]" ]'
check "a listed tool with zero listing cost is never flagged" '[ "$(pt worker-impl Read | jq -c "[.listing_tokens, .verdict]")" = "[0,\"keep\"]" ]'
check "the existing roll-up fields are untouched" 'jq -e ".tools | map(select(.tool == \"Bash\")) | .[0] | .calls == 85 and (has(\"rate\") and has(\"error_rate\") and has(\"trend\") and has(\"sessions\"))" "$TMP/prof.json" >/dev/null'
PROLL "profile=chief" >"$TMP/prof-c.json" 2>/dev/null || bad "the profile-filtered roll-up runs"
check "profile=chief keeps only that profile's sessions in the existing tools too" 'jq -e "(.tools | map(select(.tool == \"Bash\")) | .[0].calls) == 15 and (.profiles | map(.profile) == [\"chief\"]) and .selected.profile == \"chief\"" "$TMP/prof-c.json" >/dev/null'
check "rows with no profile read unknown, so legacy history still rolls up" 'node --input-type=module -e "
import { rollupToolHealth } from \"$HERE/tool-health.mjs\";
const r = { eval: \"leg-trajectory\", run_id: \"s1\", status: \"ok\", lane: \"native\", model: \"m\", meta: { leg: \"N1\", started_ts: Date.parse(\"2026-10-21T12:00:00Z\"), tool_health: [{ agent: { id: \"main\", model: \"m\" }, tool: \"Bash\", calls: 3, failures: 0, errors: 0, denials: 0 }] } };
const o = rollupToolHealth([r], [], new URLSearchParams(), Date.parse(\"2026-10-22T12:00:00Z\"));
process.exit(o.profiles.length === 1 && o.profiles[0].profile === \"unknown\" && o.profiles[0].tools[0].calls === 3 ? 0 : 1);"'

echo "13. drop-candidate window_days follows the since range (HIMMEL-7050)"
PROLL "since=2026-10-12" >"$TMP/prof-s.json" 2>"$TMP/prof-s.err" || bad "the since roll-up runs: $(head -c 300 "$TMP/prof-s.err")"
check "with since set, window_days is the days from since through today (2026-10-12..2026-10-22 = 11)" '[ "$(jq -c "[.drop_candidates[].window_days] | unique" "$TMP/prof-s.json")" = "[11]" ]'
check "with since set, the per-day trend has one entry per day of that range" '[ "$(jq -c "[.tools[].trend | length] | unique" "$TMP/prof-s.json")" = "[11]" ]'
check "without since, window_days and the trend stay at the days switch (7)" '[ "$(jq -c "[.drop_candidates[].window_days] | unique" "$TMP/prof.json")" = "[7]" ] && [ "$(jq -c "[.tools[].trend | length] | unique" "$TMP/prof.json")" = "[7]" ]'

echo "14. split tool keys and Bash command heads (HIMMEL-8509)"
# fixtures/split-keys.jsonl: 3 Skill, 2 Agent + 1 Task, 3 MCP and 5 Bash calls; one failure in each collapsed group but Bash (3).
S14=8509c1a5-0000-4000-8000-000000000001
cp "$FX/split-keys.jsonl" "$TMP/$S14.jsonl"
digest "$TMP/$S14.jsonl" >"$TMP/sk.json" 2>"$TMP/sk.err" || bad "digest of split-keys.jsonl exits 0: $(head -c 300 "$TMP/sk.err")"
skt() { jq -c --arg t "$1" '[.tool_health[] | select(.tool == $t)] | [(map(.calls) | add), (map(.failures) | add)]' "$TMP/sk.json"; }
check "Skill splits by its plugin:skill input, a bad name stays Skill" '[ "$(skt Skill:himmel-ops:pr-check)" = "[1,1]" ] && [ "$(skt Skill:handover)" = "[1,0]" ] && [ "$(skt Skill)" = "[1,0]" ]'
check "Agent and Task split by subagent_type, general-purpose when absent" '[ "$(skt Agent:Explore)" = "[1,0]" ] && [ "$(skt Agent:general-purpose)" = "[1,0]" ] && [ "$(skt Agent:judge)" = "[1,1]" ]'
check "an MCP server with a hyphen keeps its key, a capital or an over-long one folds to mcp" '[ "$(skt mcp__claude-in-chrome__navigate)" = "[1,1]" ] && [ "$(skt mcp)" = "[2,0]" ]'
check "the split rows add up to the old collapsed rows: Skill 3/1, Agent+Task 3/1, mcp 3/1, Bash 5/3" '[ "$(jq -c "[.tool_health[] | {k: (.tool | if test(\"^Skill(:|$)\") then \"Skill\" elif test(\"^(Agent|Task)(:|$)\") then \"Agent\" elif test(\"^mcp(__|$)\") then \"mcp\" else . end), calls, failures}] | group_by(.k) | map([.[0].k, (map(.calls) | add), (map(.failures) | add)])" "$TMP/sk.json")" = "[[\"Agent\",3,1],[\"Bash\",5,3],[\"Skill\",3,1],[\"mcp\",3,1]]" ]'
check "the per-tool metrics use the split key and still sum to tool_calls" 'jq -e ".metrics.tool_calls_by_tool[\"Skill:himmel-ops:pr-check\"] == 1 and .metrics.tool_failures_by_tool[\"Agent:judge\"] == 1 and ([.metrics.tool_calls_by_tool[]] | add) == .metrics.tool_calls" "$TMP/sk.json" >/dev/null'
check "Bash rows carry [id, head, cause] per call, plus the exit code of a command that failed with one: the first command word past env and rtk, else other" '[ "$(jq -c "[.tool_health[] | select(.tool == \"Bash\") | .bash_calls[]]" "$TMP/sk.json")" = "[[\"toolu_b1\",\"git\",null],[\"toolu_b2\",\"git\",null],[\"toolu_b3\",\"bun\",\"command\",2],[\"toolu_b4\",\"other\",\"command\",1],[\"toolu_b5\",\"cat\",\"guard\"]]" ]'
check "no argument, prompt or command text reaches the digest" 'absent -E "SECRET|rm -rf|example.invalid|run build" "$TMP/sk.json"'

echo "15. time to result per call: a single call, a batched call and a call with no result"
# fixtures/call-timing.jsonl: Read alone (400 ms), Bash and Read sharing one API message (1200 and 490 ms), Grep with no result.
S15=8510c1a5-0000-4000-8000-000000000001
cp "$FX/call-timing.jsonl" "$TMP/$S15.jsonl"
digest "$TMP/$S15.jsonl" >"$TMP/ct.json" 2>"$TMP/ct.err" || bad "digest of call-timing.jsonl exits 0: $(head -c 300 "$TMP/ct.err")"
ctt() { jq -c --arg t "$1" '[.tool_health[] | select(.tool == $t) | .timing] | .[0]' "$TMP/ct.json"; }
check "a single call keeps its time to result and is not marked batched" '[ "$(jq -c ".single" <<<"$(ctt Read)")" = "[400]" ]'
check "a batched call keeps its time to result in the batched list, apart from the headline" '[ "$(jq -c ".batched" <<<"$(ctt Read)")" = "[490]" ] && [ "$(ctt Bash)" = "{\"single\":[],\"batched\":[1200],\"missing\":0}" ]'
check "a call with no result has no time, counted as missing and never 0" '[ "$(ctt Grep)" = "{\"single\":[],\"batched\":[],\"missing\":1}" ]'
check "no call text reaches the timing" 'absent -E "/x/|ls|pattern" <<<"$(jq -c "[.tool_health[].timing]" "$TMP/ct.json")"'

echo "16. a tool behind bash -c, cd, env and rtk is counted under its own name (HIMMEL-8707)"
# fixtures/graph-heads.jsonl: 21 Bash calls, ids toolu_<g|q|r|k><n>. q3 to q7 are the forms the qmd hook allows:
# qmd-bounded.sh by bash, sh, an env prefix, its path alone, and after a cd. q1 and q2 are forms the hook refuses.
S16=8707c1a5-0000-4000-8000-000000000001
cp "$FX/graph-heads.jsonl" "$TMP/$S16.jsonl"
digest "$TMP/$S16.jsonl" >"$TMP/gh.json" 2>"$TMP/gh.err" || bad "digest of graph-heads.jsonl exits 0: $(head -c 300 "$TMP/gh.err")"
gh() { jq -r --arg id "toolu_$1" '[.tool_health[] | select(.tool == "Bash") | .bash_calls[] | select(.[0] == $id)] | .[0][1]' "$TMP/gh.json"; }
check "graphify behind bash -c, cd, env+rtk, the worker-graph.sh wrapper and a nested bash -c counts as graphify" '[ "$(gh g1)$(gh g2)$(gh g3)$(gh g4)$(gh g5)" = graphifygraphifygraphifygraphifygraphify ]'
check "graphify behind env assignments before bash -c, bare or after a cd, counts as graphify" '[ "$(gh g6)$(gh g7)" = graphifygraphify ]'
check "qmd behind bash -c and cd+rtk counts as qmd" '[ "$(gh q1)$(gh q2)" = qmdqmd ]'
check "qmd-bounded.sh by bash, sh, an env prefix, its own path and after a cd counts as qmd, whatever its verb" '[ "$(gh q3)$(gh q4)$(gh q5)$(gh q6)$(gh q7)" = qmdqmdqmdqmdqmd ]'
check "rtk own commands (gain, proxy, recall), bare or behind bash -c and cd, count as rtk" '[ "$(gh r1)$(gh r2)$(gh r3)" = rtkrtkrtk ]'
check "a real unknown stays under its own first word, other heads read as before" '[ "$(gh k1)" = weirdtool ] && [ "$(gh k2)" = bash ] && [ "$(gh k3)" = git ] && [ "$(gh k4)" = other ]'

echo "17. a refused call's digest row carries the runner's redacted deny line (HIMMEL-8575)"
# fixtures/chain-refusal: a journal of eleven refusals and the hook-chain run log that goes with it. make-chain-log.sh has the REAL launcher
# write the secret-bearing, long and huge identifier-like rows (the one field it sets to test is rewritten to production) and adds the static rows.
CR="$FX/chain-refusal"; S17=8575c1a5-0000-4000-8000-000000000001
mkdir -p "$TMP/cr/j"
cp "$CR/journal.jsonl" "$TMP/cr/j/$S17.jsonl"
bash "$CR/make-chain-log.sh" "$TMP/cr" >"$TMP/cr/make.out" 2>&1 || bad "the chain log builds: $(head -c 300 "$TMP/cr/make.out")"
cd17() { bun "$DIG" --transcript "$TMP/cr/j/$S17.jsonl" --denials-ledger "$FX/classifier-denials.jsonl"; }
T0=$SECONDS
RUN_HOOK_CHAIN_SKIP_LOG="$TMP/cr/no-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$TMP/cr/hook-runs.jsonl" cd17 >"$TMP/cr/with.json" 2>"$TMP/cr/with.err" || bad "the digest with a chain log exits 0: $(head -c 300 "$TMP/cr/with.err")"
T1=$SECONDS
cd17 >"$TMP/cr/without.json" 2>/dev/null || bad "the digest with no chain log exits 0"
crow() { jq -c --arg k "$1" '[.failures[] | select(.class == $k)] | .[0] // empty' "$2"; }
cline() { crow "$1" "$TMP/cr/with.json" | jq -c 'if has("refusal_line") then .refusal_line else "ABSENT" end'; }
check "the fixtures digest to the eleven refused calls in nine classes" '[ "$(jq "[.failures[] | select(.failure == \"denied\")] | length" "$TMP/cr/with.json")" = 9 ]'
check "a secret-bearing refusal: the row carries the runner-redacted line" '[ "$(cline denied/block-read-secrets)" = "\"refused: API_TOKEN=<redacted> was read\"" ]'
check "and the secret string is in neither the digest nor the chain log the launcher wrote" 'absent SECRETVALUE8575zq "$TMP/cr/with.json" "$TMP/cr/hook-runs.jsonl" && grep -q "API_TOKEN=<redacted>" "$TMP/cr/hook-runs.jsonl"'
check "a refusal longer than 240 code points is exactly 240 in the row" '[ "$(crow denied/read-clamp "$TMP/cr/with.json" | jq ".refusal_line | explode | length")" = 240 ]'
check "an aggregated row holds the line of its first refused call that has one (agg1 has none, agg3 comes after agg2)" '[ "$(cline denied/check-push-target)" = "\"check-push-target: push to a remote that is not the fork is refused (agg2)\"" ]'
check "a refused call with no chain row, with a test-origin row, or with only a row of another guard carries null" '[ "$(cline denied/guard-pr-check-literal)" = null ] && [ "$(cline denied/block-write-into-main-checkout)" = null ]'
check "a classifier denial and a permission prompt carry null" '[ "$(cline denied/classifier:merge-without-review)" = null ] && [ "$(cline denied/permission-prompt)" = null ]'
check "no denied row carries an empty string, and the key is present on every denied row" '[ "$(jq "[.failures[] | select(.failure == \"denied\" and (has(\"refusal_line\") | not))] | length" "$TMP/cr/with.json")" = 0 ] && [ "$(jq "[.failures[] | select(.refusal_line == \"\")] | length" "$TMP/cr/with.json")" = 0 ]'
check "the field is absent on every other failure kind" '[ "$(jq "[.failures[] | select(.failure != \"denied\" and has(\"refusal_line\"))] | length" "$TMP/cr/with.json")" = 0 ]'
check "a huge identifier-like run through the real launcher is a line of at most 240 code points" '[ "$(cline denied/block-destructive-commands | jq -r "length <= 240 and length > 0")" = true ]'
check "a 2 MB identifier-like denyLine written into a production row is cut to 240, and the digest finishes in under 5 s" '[ "$(cline denied/block-git-stash | jq length)" = 240 ] && [ "$((T1 - T0))" -lt 5 ]'
check "canary: the journal text never reaches the new field (the line comes from the chain log)" 'absent -e CANARY8575zq -e TESTORIGIN8575 -e WRONGMEMBER8575 "$TMP/cr/with.json" "$TMP/cr/without.json"'
check "a missing chain log is null on every denied row, never an error, and the status is unchanged" 'jq -e "([.failures[] | select(.failure == \"denied\") | if has(\"refusal_line\") then .refusal_line else \"ABSENT\" end] | all(. == null)) and .status == \"ok\"" "$TMP/cr/without.json" >/dev/null && [ "$(jq -r .status "$TMP/cr/with.json")" = ok ]'
check "control: apart from refusal_line the digest is the same with and without a chain log" '[ "$(jq -S "del(.failures[].refusal_line)" "$TMP/cr/with.json")" = "$(jq -S "del(.failures[].refusal_line)" "$TMP/cr/without.json")" ]'
check "control: the classes fixture digest gains only a null refusal_line on its denied rows" '[ "$(jq "[.failures[] | select(.failure == \"denied\") | .refusal_line] | all(. == null)" "$TMP/classes.json")" = true ] && [ "$(jq "[.failures[] | select(.failure == \"denied\" and (has(\"refusal_line\") | not))] | length" "$TMP/classes.json")" = 0 ]'

echo "9. a PreToolUse hook deny on an mcp tool or an Agent call is a denial, not an error"
# fixtures/hook-deny: an mcp__himmel-bus__read refused by the context hand-off guard (hyphen in the tool name), a real read error,
# an Agent refused with no hook prefix (only the hook-chain log says a guard refused it), and an Agent that really failed.
S9=9072c1a5-0000-4000-8000-000000000001
mkdir -p "$TMP/hd"
cp "$FX/hook-deny/journal.jsonl" "$TMP/hd/$S9.jsonl"
RUN_HOOK_CHAIN_SKIP_LOG="$TMP/hd/no-skips.jsonl" RUN_HOOK_CHAIN_RUN_LOG="$FX/hook-deny/hook-runs.jsonl" bun "$DIG" --transcript "$TMP/hd/$S9.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/hd/with.json" 2>"$TMP/hd/with.err" || bad "the hook-deny digest exits 0: $(head -c 300 "$TMP/hd/with.err")"
hrow() { jq -r --arg t "$1" '[.tool_health[] | select(.tool == $t)] | .[0] | "\(.calls) \(.failures) \(.errors) \(.denials)"' "$TMP/hd/with.json"; }
check "a hook-denied mcp call counts under denials, the read error under errors" '[ "$(hrow mcp__himmel-bus__read)" = "2 2 1 1" ]'
check "the mcp hook deny is keyed by its guard, the read error stays error/mcp" 'jq -e "([.failures[] | select(.class == \"denied/guard-leg-context-handoff\")] | length) == 1 and ([.failures[] | select(.class == \"error/mcp\")] | length) == 1" "$TMP/hd/with.json" >/dev/null'
check "a hook-denied Agent call (no prefix, named by the chain log) counts under denials, the crash under errors" '[ "$(hrow Agent:judge)" = "2 2 1 1" ]'
check "the Agent hook deny is keyed by the guard the chain log names" '[ "$(jq -r "[.failures[] | select(.class == \"denied/guard-agent-model\")] | .[0].count" "$TMP/hd/with.json")" = 1 ]'
check "the metrics count two denied and two errored calls" 'jq -e ".metrics.fail_denied == 2 and .metrics.fail_error == 2" "$TMP/hd/with.json" >/dev/null'

echo "9. refusal openings and no-op TaskStops"
S11=9623c1a5-0000-4000-8000-000000000001
mkdir -p "$TMP/op"
pair() {
  jq -nc --arg id "$1" --arg tool "$2" --argjson input "$3" --arg text "$4" --arg s "$S11" \
    '{type: "assistant", uuid: ("a-" + $id), message: {model: "claude-sonnet-5-5", id: ("msg_" + $id), role: "assistant", content: [{type: "tool_use", id: $id, name: $tool, input: $input}]}, sessionId: $s, timestamp: "2026-11-08T12:00:01.000Z", isSidechain: false},
     {type: "user", uuid: ("u-" + $id), message: {role: "user", content: [{type: "tool_result", tool_use_id: $id, content: $text, is_error: true}]}, sessionId: $s, timestamp: "2026-11-08T12:00:02.000Z", isSidechain: false}'
}
PRE='PreToolUse:Bash hook error: [bash $CLAUDE_PROJECT_DIR/scripts/hooks'
{
  pair op1 Bash '{"command":"bash chief-kit/x.sh"}' "$PRE/guard-chief-foreground.sh]: You are a CHIEF session running a long chief-kit script (x.sh) in the foreground — DENIED."
  pair op2 Bash '{"command":"cat store"}' "$PRE/guard-bus-store.sh]: bus store-deny: reads the bus store. himmel-bus keeps its store off-limits."
  pair op3 Bash '{"command":"agent"}' "$PRE/guard-agent-model.sh]: agent-model-deny: a judge model override 'sonnet' off its frontmatter tier."
  pair op4 Bash '{"command":"same"}' "$PRE/guard-identical-denied-retry.sh]: Refusing a repeat: this exact command was already denied 2 times in this session."
  pair op5 Bash '{"command":"edit hook"}' "$PRE/run-hook-with-bash.sh]: run-hook-with-bash: DENY block-read-secrets.sh — on-disk content no longer matches the session's record."
  pair op6 Bash '{"command":"nested"}' "$PRE/block-destructive-commands.sh]: guard-unwrap: refusing a command nested more than 6 levels deep."
  pair op7 Bash '{"command":"x=\"\" rm"}' "$PRE/block-read-secrets.sh]: guard-empty-expansion: a \${...} holding a command substitution sits in a command that names this guard's target - denied."
  pair op8 Bash '{"command":"other"}' "$PRE/block-read-secrets.sh]: some words no guard table claims"
  pair op9 Bash '{"command":"run-hook"}' "$PRE/run-hook-with-bash.sh]: run-hook-with-bash: DENY not-a-real-hook.sh — nothing vouches for it."
  pair ts1 TaskStop '{"task_id":"t1"}' "Task t1 is not running (status: completed)"
  pair ts2 TaskStop '{"task_id":"t2"}' "No task found with ID: t2"
  pair ts3 TaskStop '{"task_id":"t3"}' "TaskStop failed: the task runner crashed"
} >"$TMP/op/$S11.jsonl"
digest "$TMP/op/$S11.jsonl" >"$TMP/op/out.json" 2>"$TMP/op/err" || bad "the openings digest exits 0: $(head -c 300 "$TMP/op/err")"
orow() { jq -c --arg k "$1" '[.failures[] | select(.class == $k)] | .[0] // empty' "$TMP/op/out.json"; }
check "a CHIEF inline-guard refusal is denied/guard-chief-foreground" '[ "$(orow denied/guard-chief-foreground | jq .count)" = 1 ]'
check "a bus store-deny refusal is denied/guard-bus-store" '[ "$(orow denied/guard-bus-store | jq .count)" = 1 ]'
check "an agent-model-deny refusal is denied/guard-agent-model" '[ "$(orow denied/guard-agent-model | jq .count)" = 1 ]'
check "a Refusing a repeat refusal is denied/guard-identical-denied-retry" '[ "$(orow denied/guard-identical-denied-retry | jq .count)" = 1 ]'
check "a run-hook-with-bash DENY X.sh refusal is keyed by X" '[ "$(orow denied/block-read-secrets | jq .count)" = 1 ]'
check "a guard-unwrap refusal is denied/guard-unwrap" '[ "$(orow denied/guard-unwrap | jq .count)" = 1 ]'
check "a guard-empty-expansion refusal is denied/guard-empty-expansion" '[ "$(orow denied/guard-empty-expansion | jq .count)" = 1 ]'
check "control: a refusal no guard claims, and a DENY of a name that is no hook, stay denied/other" '[ "$(orow denied/other | jq .count)" = 2 ]'
check "a TaskStop error saying not running or No task found is a no-op, not error/TaskStop" '[ "$(orow error/TaskStop | jq .count)" = 1 ] && jq -e ".metrics.ok_noop_stop == 2" "$TMP/op/out.json" >/dev/null'
check "control: any other TaskStop error is still a failure" '[ "$(jq -r "[.tool_health[] | select(.tool == \"TaskStop\")] | .[0] | \"\(.calls) \(.failures)\"" "$TMP/op/out.json")" = "3 1" ]'

echo "one outcome partition per issued call (the shared fixture the mapper, reducer and rollup read too)"
SOUT=9696c1a5-0000-4000-8000-000000000001
mkdir -p "$TMP/out"; cp "$FX/outcomes.jsonl" "$TMP/out/$SOUT.jsonl"
digest "$TMP/out/$SOUT.jsonl" >"$TMP/out/out.json" 2>"$TMP/out/err" || bad "the outcomes digest exits 0: $(head -c 300 "$TMP/out/err")"
OJ="$TMP/out/out.json"
check "the digest meaning versions moved" 'jq -e ".digest_v == 3 and .mapper_v == 2" "$OJ" >/dev/null'
check "every tool row carries all seven outcome counts" 'jq -e "[.tool_health[] | .outcomes | keys] | all(. == [\"denied\",\"error\",\"interrupted\",\"no_verdict\",\"ok\",\"ok_blocked\",\"unknown\"])" "$OJ" >/dev/null'
check "each row's outcomes sum to its calls" 'jq -e "[.tool_health[] | ([.outcomes[]] | add) == .calls] | all" "$OJ" >/dev/null'
check "the session partition is exact" '[ "$(jq -c ".metrics.outcomes" "$OJ")" = "{\"ok\":5,\"ok_blocked\":1,\"error\":6,\"denied\":1,\"no_verdict\":2,\"interrupted\":2,\"unknown\":1}" ]'
check "the session partition sums to tool_calls" 'jq -e "([.metrics.outcomes[]] | add) == .metrics.tool_calls" "$OJ" >/dev/null'
check "errors and denials are views of the partition (no_verdict and interrupted are neither)" 'jq -e "([.tool_health[].errors] | add) == .metrics.outcomes.error and ([.tool_health[].denials] | add) == .metrics.outcomes.denied" "$OJ" >/dev/null'
check "a no-verdict call is no failure row" 'jq -e "[.failures[] | .tool_call_ids[]] | (index(\"c_nv\") == null and index(\"c_nv_edit\") == null and index(\"c_int\") == null)" "$OJ" >/dev/null'
check "Edit-input subclasses are counted" '[ "$(jq -c ".metrics.edit_input" "$OJ")" = "{\"not_found\":1,\"ambiguous\":1,\"unchanged\":1,\"stale\":0,\"not_read\":0}" ]'
check "the separator error is counted" 'jq -e ".metrics.separator_errors == 1" "$OJ" >/dev/null'
check "judge calls with and without the declared JUDGE-BRIEF marker are counted" 'jq -e ".metrics.judge_calls == {\"marked\":1,\"unmarked\":1}" "$OJ" >/dev/null'

echo "denied_calls: every refused call by id, bounded per row (5000 tuples or 64 KiB), with captured and omitted counts"
check "a refused call is a [call_id, class, ts] tuple on its tool row" 'jq -e "[.tool_health[] | .denied_calls[]? | select(.[0] == \"toolu_d1\")] | length == 1 and (.[0][1] == \"denied/guard-pr-check-literal\") and (.[0][2] | type == \"number\")" "$TMP/classes.json" >/dev/null'
check "captured counts the tuples and omitted is 0 under the cap" 'jq -e "[.tool_health[] | select(.denials > 0)] | all((.denied_calls | length) == .denied_calls_captured and .denied_calls_omitted == 0 and .denied_calls_captured == .denials)" "$TMP/classes.json" >/dev/null'
check "a row with no refusal carries an empty tuple list" 'jq -e "[.tool_health[] | select(.denials == 0) | .denied_calls] | all(. == [])" "$TMP/classes.json" >/dev/null'
SCAP=9696c1a5-0000-4000-8000-0000000000ca
mkdir -p "$TMP/cap"
python3 -I -c 'import json, sys
s = sys.argv[1]; out = []
out.append({"type": "user", "uuid": "p", "sessionId": s, "timestamp": "2026-11-09T12:00:00.000Z", "message": {"role": "user", "content": "go"}})
for i in range(1200):
    cid = "toolu_cap_%060d" % i
    out.append({"type": "assistant", "uuid": "a%d" % i, "sessionId": s, "timestamp": "2026-11-09T12:00:01.000Z", "message": {"model": "claude-opus-5-5", "id": "m%d" % i, "role": "assistant", "content": [{"type": "tool_use", "id": cid, "name": "Bash", "input": {"command": "git stash"}}]}})
    out.append({"type": "user", "uuid": "u%d" % i, "sessionId": s, "timestamp": "2026-11-09T12:00:02.000Z", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": cid, "is_error": True, "content": "PreToolUse:Bash hook error: [command hook 5]: block-git-stash: refused"}]}})
sys.stdout.write("".join(json.dumps(r) + "\n" for r in out))' "$SCAP" >"$TMP/cap/$SCAP.jsonl"
digest "$TMP/cap/$SCAP.jsonl" >"$TMP/cap/out.json" 2>"$TMP/cap/err" || bad "the capped digest exits 0: $(head -c 300 "$TMP/cap/err")"
check "the 64 KiB cap bounds the encoded tuples" 'jq -e "[.tool_health[] | select(.tool == \"Bash\")][0] | (.denied_calls | tojson | length) <= 65536 and .denied_calls_captured < 1200" "$TMP/cap/out.json" >/dev/null'
check "captured plus omitted is every refused call" 'jq -e "[.tool_health[] | select(.tool == \"Bash\")][0] | .denied_calls_captured + .denied_calls_omitted == 1200 and .denied_calls_omitted > 0" "$TMP/cap/out.json" >/dev/null'

echo "test-worker-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
