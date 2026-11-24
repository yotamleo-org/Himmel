#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/compaction-trigger-report.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/compaction-trigger.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi; }

call() {
    local id=$1 at=$2 api=$3 input=5 cache_create=1000
    printf '{"type":"assistant","timestamp":"2026-11-07T%sZ","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"output_tokens":50}}}\n' \
        "$at" "$id" "$input" $((api - input - cache_create)) "$cache_create"
}
result() {
    local at=$1 is_error=$2 text=$3
    printf '{"type":"user","timestamp":"2026-11-07T%sZ","message":{"content":[{"type":"tool_result","is_error":%s,"content":"%s"}]}}\n' "$at" "$is_error" "$text"
}
boundary() {
    local at=$1 pre_tokens=$2
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-07T%sZ","compactMetadata":{"trigger":"auto","preTokens":%d}}\n' "$at" "$pre_tokens"
}
title() { printf '{"type":"custom-title","customTitle":"%s"}\n' "$1"; }
deny='PreToolUse:Read hook error: worker context hand-off (mode handoff): this session is at 70 % context fill (threshold 70 % = 87 % of the 800000-token autocompact ceiling)'

mkdir -p "$tmp/projects/p" "$tmp/logs"
st="$tmp/projects/p/steady.jsonl"
{
    title fx-n1-steady
    call m1 10:00:00 600000
    result 10:00:10 false "a read that quotes the guard: $deny"
    call m2 10:01:00 650000
    call m2 10:01:00 655000
    result 10:01:10 false short
    call m3 10:02:00 690000
    result 10:02:10 true "$deny"
    call m4 10:03:00 705000
    printf '{"type":"assistant","isSidechain":true,"timestamp":"2026-11-07T10:03:30Z","message":{"id":"s1","model":"claude-haiku-5-5","usage":{"input_tokens":990000}}}\n'
    result 10:03:10 false short
    boundary 10:04:00 760000
    call m5 10:05:00 40000
} > "$st"
big=$(head -c 240000 /dev/zero | tr '\0' a)
ba="$tmp/projects/p/batch.jsonl"
{
    title fx-n2-batch
    call b1 11:00:00 600000
    result 11:00:10 false "$big"
    boundary 11:01:00 678169
    call b2 11:02:00 30000
} > "$ba"
id="$tmp/projects/p/idle.jsonl"
{
    title fx-n3-idle
    call i1 12:00:00 620000
    result 12:00:10 false short
    boundary 12:55:00 640000
    call i2 12:56:00 30000
} > "$id"

out="$tmp/out.json"
python3 -I "$SUT" --json "$st" "$ba" "$id" > "$out" 2>"$tmp/err"; rc=$?
check "exit 0" 0 "$rc"
s='.workers[] | select(.session == "fx-n1-steady")'
b='.workers[] | select(.session == "fx-n2-batch")'
i='.workers[] | select(.session == "fx-n3-idle")'
check "steady: shape" steady "$(jq -r "$s | .compactions[0].shape" "$out")"
check "steady: preTokens is the CLI estimate" 760000 "$(jq "$s | .compactions[0].cli_pre" "$out")"
check "steady: api usage on the call before" 705000 "$(jq "$s | .compactions[0].api_before" "$out")"
check "steady: api usage on the call after" 40000 "$(jq "$s | .compactions[0].api_after" "$out")"
check "steady: idle gap before it" 60 "$(jq "$s | .compactions[0].gap_s" "$out")"
check "steady: a repeated message id is one call, its last usage kept" 5 "$(jq "$s | .calls" "$out")"
check "steady: the sidechain call is not the peak" 705000 "$(jq "$s | .api_peak" "$out")"
check "steady: only the is_error deny counts, not a read quoting it" 1 "$(jq "$s | .denies" "$out")"
check "steady: deny fill and api before it" "70 690000" "$(jq -r "$s | \"\(.first_deny.fill_pct) \(.first_deny.api_before)\"" "$out")"
check "steady: ceiling named by the deny" 800000 "$(jq "$s | .deny_ceiling" "$out")"
check "steady: the guard denied first" deny-first "$(jq -r "$s | .order" "$out")"
check "control: one large batch is batch, not steady growth" batch "$(jq -r "$b | .compactions[0].shape" "$out")"
check "control: the batch size is chars over 4" 60000 "$(jq "$b | .compactions[0].batch_est" "$out")"
check "control: the batch worker compacted with no deny" compact-only "$(jq -r "$b | .order" "$out")"
check "idle: 54 minutes without a call is idle" idle "$(jq -r "$i | .compactions[0].shape" "$out")"
check "summary shapes" "1 1 1" "$(jq -r '.summary.shapes | "\(.steady) \(.batch) \(.idle)"' "$out")"
check "summary threshold is the hook's ceil(87 x 800000 / 1M) %" 700000 "$(jq '.summary.threshold_api' "$out")"
check "answer counts deny-first and compact-first" 1 "$(jq -r '.summary.answer' "$out" | grep -c 'denied before any compaction in 1, a compaction came first in 2')"

mn="$tmp/manual.jsonl"
{
    title fx-n4-manual
    call k1 13:00:00 610000
    result 13:00:10 false short
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-07T13:01:00Z","compactMetadata":{"trigger":"manual","preTokens":640000}}\n'
    call k2 13:02:00 30000
} > "$mn"
python3 -I "$SUT" --json "$mn" "$mn" > "$tmp/mn.json"
check "a manual /compact is manual, not steady growth" "manual 0" "$(jq -r '"\(.workers[0].compactions[0].shape) \(.summary.shapes.steady)"' "$tmp/mn.json")"
check "a transcript given twice is read once" 1 "$(jq '.summary.workers' "$tmp/mn.json")"

python3 -I "$SUT" "$ba" > "$tmp/ba.txt" 2>&1
check "no steady compaction: the answer says the sample is too small" 1 "$(grep -c '^ANSWER: sample too small: 0 steady-growth compactions at 800000 across 1 workers' "$tmp/ba.txt")"
python3 -I "$SUT" --json --min-peak 700000 "$st" "$ba" > "$tmp/peak.json"
check "a worker under --min-peak is left out" 1 "$(jq '.summary.workers' "$tmp/peak.json")"

U1=bbbbbbbb-0000-4000-8000-000000000001; U2=bbbbbbbb-0000-4000-8000-000000000002
U3=bbbbbbbb-0000-4000-8000-000000000003; U4=bbbbbbbb-0000-4000-8000-000000000004
cp "$st" "$tmp/projects/p/$U1.jsonl"; cp "$ba" "$tmp/projects/p/$U2.jsonl"
sed 's/claude-opus-5-5/claude-sonnet-5-5/' "$id" > "$tmp/projects/p/$U3.jsonl"
sed "s/fx-n1-steady/fx-n5-headless/" "$st" > "$tmp/projects/p/$U4.jsonl"
rec() { printf 'headed-arm-worker: profile=worker-impl lane=native model=%s role=worker session=%s%s launched=2026-11-07T10:00:00Z%s\n' "$1" "$2" "${3:+ session_id=$3}" "${4:+ $4}" >> "$tmp/logs/$2.log"; }
rec opus fx-n1-steady "$U1"
rec opus fx-n2-batch "$U2" autocompact=200000
rec sonnet fx-n3-idle "$U3"
rec opus fx-n4-nosid ""
printf 'headed-arm: headless=1 pid=1 session-id=%s short-id=x name=fx-n5-headless launched=2026-11-07T10:00:00Z\n' "$U4" > "$tmp/logs/fx-n5-headless.log"
rec opus fx-n5-headless ""
python3 -I "$SUT" --json --launch-logs "$tmp/logs" --projects "$tmp/projects" --ceiling 850000 --model opus > "$tmp/join.json" 2>"$tmp/join.err"; rc=$?
check "durable-record: exit 0" 0 "$rc"
check "durable-record: the opus launches at the ceiling are read by session_id (a headless line's session-id too)" "fx-n1-steady,fx-n5-headless" "$(jq -r '[.workers[].session] | sort | join(",")' "$tmp/join.json")"
check "durable-record: a worker line with no session_id is counted as no-session-id and skipped" 1 "$(jq '.summary.cohort.no_session_id' "$tmp/join.json")"
python3 -I "$SUT" --json --launch-logs "$tmp/logs" --projects "$tmp/projects" --ceiling 850000 --model sonnet > "$tmp/son.json" 2>/dev/null
check "sonnet-cohort: --model sonnet reads the sonnet launch" fx-n3-idle "$(jq -r '[.workers[].session] | join(",")' "$tmp/son.json")"
python3 -I "$SUT" --json --launch-logs "$tmp/logs" --projects "$tmp/projects" --ceiling 850000 --model all > "$tmp/all.json" 2>/dev/null
check "sonnet-cohort: --model all reads all three" "fx-n1-steady,fx-n3-idle,fx-n5-headless" "$(jq -r '[.workers[].session] | sort | join(",")' "$tmp/all.json")"
check "record-keys: the sessions without an autocompact= key used the profile's ceiling" 3 "$(jq '.summary.cohort.fallback_ceiling' "$tmp/all.json")"
python3 -I "$SUT" --json --launch-logs "$tmp/logs" --projects "$tmp/projects" --ceiling 200000 --model all > "$tmp/key.json" 2>/dev/null
check "record-keys: an autocompact= key wins over the profile" fx-n2-batch "$(jq -r '[.workers[].session] | join(",")' "$tmp/key.json")"
check "record-keys: and is not a fallback" 0 "$(jq '.summary.cohort.fallback_ceiling' "$tmp/key.json")"
python3 -I "$SUT" --launch-logs "$tmp/logs" --projects "$tmp/projects" --ceiling 123 > /dev/null 2>"$tmp/nt.err"; rc=$?
check "durable-record: no launch at the ceiling exits 1 with no transcripts" "1 1" "$rc $(grep -c 'no transcripts' "$tmp/nt.err")"

python3 -I "$SUT" > /dev/null 2>"$tmp/none.err"; rc=$?
check "no input exits 1" 1 "$rc"

if [ "$fails" -ne 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "PASS all"
