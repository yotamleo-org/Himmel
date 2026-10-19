#!/usr/bin/env bash
# scripts/cr/test-cr-round-metrics.sh — fixture ledger with KNOWN numbers for
# cr-round-metrics.sh. bash 3.2-safe.
# shellcheck disable=SC2015,SC2016  # A && B || C intentional; literal $var in fixture text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; CM="$HERE/cr-round-metrics.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-round-metrics.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
L="$tmp/ledger.jsonl"; K="$tmp/known.json"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

f() { # f <ts> <branch> <head> <round> <id> <sev> <text>
  printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"codex","finding_id":"%s","severity":"%s","round":%s,"file":"x.sh","line":1,"verdict":"","text":"%s"}\n' "$1" "$2" "$3" "$5" "$6" "$4" "$7"
}
{
  # old: outside the 30-day window, but earlier history for the repeat rate
  f 2026-07-01T00:00:00Z fix/old o1 1 c-1 imp 'NUL-delimited paths are split on newline'
  # a: 3 rounds, no cap hit
  f 2026-10-01T00:00:00Z fix/a a1 1 c-1 imp 'unquoted $var causes word splitting in the guard'
  f 2026-10-01T00:00:01Z fix/a a1 1 c-2 sug 'rm -rf cleanup on an unvalidated path'
  f 2026-10-01T01:00:00Z fix/a a2 2 c-3 imp 'NUL-delimited paths are split on newline again'
  f 2026-10-01T02:00:00Z fix/a a3 3 c-4 sug 'unquoted $var causes word splitting again'
  # b: 4 rounds = cap hit
  f 2026-10-05T00:00:00Z fix/b b1 1 c-1 imp 'unquoted $var in the tokenizer breaks word splitting'
  f 2026-10-05T01:00:00Z fix/b b2 2 c-2 imp 'no timeout bound on the loop; it hangs'
  f 2026-10-05T02:00:00Z fix/b b3 3 c-3 crit 'fail-open on parse error lets the command through'
  f 2026-10-05T03:00:00Z fix/b b4 4 c-4 crit 'this test is vacuous: the assertion cannot fail'
  echo '{"kind":"amend","ts":"2026-10-01T00:05:00Z","branch":"","target_head":"a1","finding_id":"c-2","artifact":"diff","perspective":"off","set":{"verdict":"disproved"}}'
  echo '{"kind":"avail","ts":"2026-10-01T00:00:00Z","branch":"fix/a","head":"a1","model":"codex","status":"ok"}'
} > "$L"
cat > "$K" <<'EOF'
{"classes":[{"id":"timeout-bound","kind":"fix","learning_match":"timeout|hangs"}]}
EOF

out="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --days 30 --known "$K" 2>&1)"
rc=$?
check "exit 0" "$rc" "0"
json="$(grep -m1 '^{' <<< "$out")"
q() { node -e 'let o=JSON.parse(process.argv[1]),v=o;for(const k of process.argv[2].split("."))v=v==null?v:v[k];console.log(v===undefined?"undef":typeof v==="object"?JSON.stringify(v):v)' "$json" "$1" 2>&1; }

check "branches in window" "$(q branches)" "2"
check "rounds p50" "$(q rounds.p50)" "3"
check "rounds p90" "$(q rounds.p90)" "4"
check "cap hits" "$(q cap_hits.count)" "1"
check "cap hit branch" "$(q cap_hits.branches)" '["fix/b"]'
check "findings total" "$(q findings.total)" "8"
check "severity crit" "$(q findings.by_severity.crit)" "2"
check "severity imp" "$(q findings.by_severity.imp)" "4"
check "severity sug" "$(q findings.by_severity.sug)" "2"
check "class quoting" "$(q findings.by_class.quoting-tokenization)" "3"
check "class nul" "$(q findings.by_class.nul-delimited)" "1"
check "verdict disproved" "$(q findings.by_verdict.disproved)" "1"
# repeats vs an earlier PR: a/c-3 (nul vs old) and b/c-1 (quoting vs a). a/c-4 repeats within a branch only.
check "repeat count" "$(q repeat.vs_earlier_prs.count)" "2"
check "repeat rate" "$(q repeat.vs_earlier_prs.rate)" "0.25"
check "known matched" "$(q repeat.known_findings.matched)" "1"
check "top class" "$(node -e 'console.log(JSON.parse(process.argv[1]).top_classes[0].class)' "$json")" "quoting-tokenization"
check "summary line" "$(grep -c '^cr-round-metrics: ' <<< "$out")" "1"

# --groups: fix/a gated, fix/b ungrouped
printf 'fix/a\tgated\n' > "$tmp/groups.tsv"
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/groups.tsv" | grep -m1 '^{')"
check "group gated p90" "$(q groups.gated.p90)" "3"
check "group ungrouped cap hits" "$(q groups.ungrouped.cap_hits)" "1"
check "group gated repeat rate" "$(q groups.gated.repeat_rate)" "0.25"

# --now bounds every row: at 10-05T01:30 fix/b has 2 rows and no cap hit
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-05T01:30:00Z --known "$K" | grep -m1 '^{')"
check "--now findings total" "$(q findings.total)" "6"
check "--now cap hits" "$(q cap_hits.count)" "0"

# group names that collide with Object.prototype keys must not crash
printf 'fix/a\tconstructor\n' > "$tmp/groups2.tsv"
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/groups2.tsv" | grep -m1 '^{')"
check "proto-named group" "$(q groups.constructor.branches)" "1"

# overlapping branches: x starts first but raises nul only AFTER y does, so y is no repeat
{
  f 2026-10-02T00:00:00Z fix/x x1 1 c-1 imp 'no timeout bound on the loop; it hangs'
  f 2026-10-02T09:00:00Z fix/x x2 2 c-2 imp 'NUL-delimited paths are split on newline'
  f 2026-10-02T05:00:00Z fix/y y1 1 c-1 imp 'NUL-delimited paths are split on newline'
} > "$tmp/overlap.jsonl"
json="$(CR_LEDGER="$tmp/overlap.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" | grep -m1 '^{')"
check "overlap repeat count" "$(q repeat.vs_earlier_prs.count)" "1"

# empty ledger: no crash, zero branches
: > "$tmp/empty.jsonl"
CR_LEDGER="$tmp/empty.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/e.out" 2>&1
check "empty ledger exits 0" "$?" "0"
json="$(grep -m1 '^{' "$tmp/e.out")"
check "empty ledger is JSON with zero branches" "$(q branches)" "0"
CR_LEDGER="$tmp/missing.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/m.out" 2>&1
check "missing ledger exits 2" "$?" "2"
check "missing ledger names the path" "$(grep -c "$tmp/missing.jsonl" "$tmp/m.out")" "1"
check "missing ledger prints no JSON" "$(grep -c '^{' "$tmp/m.out")" "0"

# no CR_LEDGER and not inside a git repo: no ledger to read, not a zero report
( cd "$tmp" && env -u CR_LEDGER GIT_CEILING_DIRECTORIES="$tmp/.." bash "$CM" --known "$K" ) > "$tmp/nr.out" 2>&1
check "outside a repo exits 2" "$?" "2"

# a non-empty ledger with no usable record is an error, not a zero report
printf 'garbage\n{not json\nnull\n' > "$tmp/allbad.jsonl"
CR_LEDGER="$tmp/allbad.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/ab.out" 2>&1
check "all-malformed ledger exits 2" "$?" "2"
check "all-malformed prints no JSON" "$(grep -c '^{' "$tmp/ab.out")" "0"

# some malformed lines: reported in the JSON and on stderr, still exit 0
printf 'garbage\n' > "$tmp/mixed.jsonl"; cat "$L" >> "$tmp/mixed.jsonl"
CR_LEDGER="$tmp/mixed.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/mx.out" 2> "$tmp/mx.err"
check "mixed ledger exits 0" "$?" "0"
json="$(grep -m1 '^{' "$tmp/mx.out")"
check "skipped lines counted in JSON" "$(q ledger_lines_skipped)" "1"
check "skipped lines noted on stderr" "$(grep -c 'skipped 1 of' "$tmp/mx.err")" "1"

# an explicit --known that is missing or unparsable fails; the default stays tolerant
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$tmp/nope.json" > "$tmp/k1.out" 2>&1
check "missing --known exits 2" "$?" "2"
printf '{oops' > "$tmp/badknown.json"
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$tmp/badknown.json" > "$tmp/k2.out" 2>&1
check "unparsable --known exits 2" "$?" "2"

# a missing --groups file is a clean message, not a stack trace
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/nogroups.tsv" > "$tmp/g.out" 2>&1
check "missing --groups exits 2" "$?" "2"
check "missing --groups has no stack trace" "$(grep -c ' at ' "$tmp/g.out")" "0"
check "missing --groups names the file" "$(grep -c 'nogroups.tsv' "$tmp/g.out")" "1"

# an amend after --now is not applied: the disproved verdict lands at 10-01T00:05
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-01T00:03:00Z --known "$K" | grep -m1 '^{')"
check "amend after --now ignored" "$(q findings.by_verdict.disproved)" "undef"

CR_LEDGER="$L" bash "$CM" --now not-a-date --known "$K" > "$tmp/bad.out" 2>&1
check "invalid --now exits 2" "$?" "2"

# unreadable ledger (a directory) is an error, not an empty report
CR_LEDGER="$tmp" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/d.out" 2>&1
check "unreadable ledger exits 2" "$?" "2"

# a JSON null line is skipped like a malformed line
{ echo null; echo 42; cat "$L"; } > "$tmp/nulls.jsonl"
json="$(CR_LEDGER="$tmp/nulls.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" | grep -m1 '^{')"
check "null record skipped" "$(q findings.total)" "8"

# huge --days is a usage error, not a crash
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --days 99999999999 --known "$K" > "$tmp/h.out" 2>&1
check "huge --days exits 2" "$?" "2"

# --critic-split: a branch is "critic" when the ledger has a claude attempt row with status ok.
# Launch-row shape copied from a real claude-api.sh row (organization_id redacted); a critic launch
# joins an attempt when its ts is within 60s of the attempt ts (both are written at call end).
{
  cat "$L"
  echo '{"kind":"attempt","ts":"2026-10-01T02:30:00Z","branch":"fix/a","head":"a3","model":"claude","status":"ok","hour_utc":2,"artifact":"diff","perspective":"off","responding_model":"claude-opus-5-5","attempt":1,"duration_secs":20,"detail":"rc=0"}'
  echo '{"kind":"attempt","ts":"2026-10-05T03:30:00Z","branch":"fix/b","head":"b4","model":"claude","status":"error","hour_utc":3,"artifact":"diff","perspective":"off","responding_model":"claude-opus-5-5","attempt":1,"duration_secs":0,"detail":"rc=5: critic-first-pass.sh: claude critic SKIPPED (api lane is OFF (set HIMMEL_API_LANE=on)) - clean no-op"}'
  echo '{"kind":"attempt","ts":"2026-10-05T03:31:00Z","branch":"fix/b","head":"b4","model":"codex","status":"ok","hour_utc":3,"artifact":"diff","perspective":"off","attempt":1,"duration_secs":11,"detail":"rc=0"}'
} > "$tmp/split.jsonl"
LF="$tmp/launches.jsonl"
{
  echo '{"ts":"2026-10-01T02:30:05Z","job_id":"cr-claude-critic-4242","account":"A","organization_id":"redacted","key_id":"A-pilot","cycle_id":"2026-10","model":"claude-opus-5-5","budget_usd":"1.00","source":"operator-console-snapshot","outcome":"settled","cost_usd":"0.400000","rc":0,"kind":"critic","cache_ttl":"5m","input_tokens":2,"cache_creation_tokens":34847,"cache_read_tokens":1250}'
  echo '{"ts":"2026-10-03T00:00:00Z","job_id":"cr-claude-critic-4343","account":"A","organization_id":"redacted","key_id":"A-pilot","cycle_id":"2026-10","model":"claude-opus-5-5","budget_usd":"1.00","source":"operator-console-snapshot","outcome":"settled","cost_usd":"0.990000","rc":0,"kind":"critic","cache_ttl":"5m","input_tokens":2,"cache_creation_tokens":1,"cache_read_tokens":1}'
  echo '{"ts":"2026-10-01T02:30:06Z","job_id":"api-1","account":"B","organization_id":"redacted","key_id":"B-pilot","cycle_id":"2026-10","model":"sonnet","budget_usd":"1.00","source":"operator-console-snapshot","outcome":"settled","cost_usd":"0.370000","rc":0,"kind":"other","cache_ttl":"5m","input_tokens":2,"cache_creation_tokens":1,"cache_read_tokens":1}'
} > "$LF"
json="$(CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$LF" | grep -m1 '^{')"
check "split critic branches" "$(q critic_split.critic.branches)" "1"
check "split critic p90" "$(q critic_split.critic.p90)" "3"
check "split no-critic branches" "$(q critic_split.no_critic.branches)" "1"
check "split no-critic cap hits" "$(q critic_split.no_critic.cap_hits)" "1"
check "split critic cost total" "$(q critic_split.critic.cost_usd_total)" "0.4"
check "split critic cost per PR" "$(q critic_split.critic.cost_usd_per_pr)" "0.4"
check "split critic cost joined" "$(q critic_split.critic.cost_joined)" "1"
check "split unjoined critic launches" "$(q critic_split.launches_unjoined)" "1"
check "split failed attempts counted" "$(q critic_split.critic_attempts_failed)" "1"

# a branch with two successful critic calls but one matched launch is not fully joined
{
  cat "$tmp/split.jsonl"
  echo '{"kind":"attempt","ts":"2026-10-01T02:45:00Z","branch":"fix/a","head":"a3","model":"claude","status":"ok","hour_utc":2,"artifact":"diff","perspective":"off","responding_model":"claude-opus-5-5","attempt":1,"duration_secs":20,"detail":"rc=0"}'
} > "$tmp/split2.jsonl"
json="$(CR_LEDGER="$tmp/split2.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$LF" | grep -m1 '^{')"
check "split two calls one launch: partly unjoined" "$(q critic_split.critic.cost)" "partly unjoined"
check "split one call one launch: joined" "$(CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$LF" | grep -m1 '^{' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).critic_split.critic.cost))')" "joined"

# a launch row with branch and head joins by key, days away from the attempt timestamp
{
  echo '{"ts":"2026-10-02T09:00:00Z","job_id":"cr-claude-critic-5151","kind":"critic","outcome":"settled","cost_usd":"0.770000","rc":0,"branch":"fix/a","head":"a3","pr":77}'
} > "$tmp/keyed.jsonl"
json="$(CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$tmp/keyed.jsonl" | grep -m1 '^{')"
check "keyed launch joins without a timestamp match" "$(q critic_split.critic.cost_usd_total)" "0.77"
check "keyed launch: cost joined" "$(q critic_split.critic.cost)" "joined"
# a keyed row for another branch never joins by timestamp
sed 's/"branch":"fix\/a"/"branch":"fix\/zzz"/' "$tmp/keyed.jsonl" | sed 's/2026-10-02T09:00:00Z/2026-10-01T02:30:05Z/' > "$tmp/keyed-other.jsonl"
json="$(CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$tmp/keyed-other.jsonl" | grep -m1 '^{')"
check "keyed launch of another branch does not join by time" "$(q critic_split.critic.cost_usd_total)" "null"

# no successful critic attempt anywhere: zero critic PRs, cost null (never a made-up zero)
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$LF" | grep -m1 '^{')"
check "split with no critic runs: critic branches" "$(q critic_split.critic.branches)" "0"
check "split with no critic runs: cost null" "$(q critic_split.critic.cost_usd_total)" "null"
check "split with no critic runs: all in no-critic" "$(q critic_split.no_critic.branches)" "2"

# default launches file absent is tolerated (cost null); an explicit missing one is an error
json="$(HOME="$tmp/nohome" CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split | grep -m1 '^{')"
check "split default launches absent: cost null" "$(q critic_split.critic.cost_usd_total)" "null"
CR_LEDGER="$tmp/split.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --critic-split --launches "$tmp/nolaunch.jsonl" > "$tmp/l.out" 2>&1
check "missing --launches exits 2" "$?" "2"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
