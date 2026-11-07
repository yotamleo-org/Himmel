#!/usr/bin/env bash
# test-compaction-trigger-report.sh: scripts/eval/compaction-trigger-report.py over
# three hand-made transcripts: steady growth with a guard deny before its
# compaction, one large tool batch (the VM fixture shape) and a long idle gap.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/compaction-trigger-report.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/compaction-trigger.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi; }

call() { # id, time, api tokens (split across the three usage fields)
    printf '{"type":"assistant","timestamp":"2026-11-07T%sZ","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"output_tokens":50}}}\n' \
        "$2" "$1" $(($3 - 1005)) 1000
}
result() { # time, is_error, text
    printf '{"type":"user","timestamp":"2026-11-07T%sZ","message":{"content":[{"type":"tool_result","is_error":%s,"content":"%s"}]}}\n' "$1" "$2" "$3"
}
boundary() { # time, preTokens
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-07T%sZ","compactMetadata":{"trigger":"auto","preTokens":%d}}\n' "$1" "$2"
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

printf '2026-11-07_10:00:00 context=standard (explicit); model=claude-opus-5-5 (autocompact=800000)\n' > "$tmp/logs/fx-n1-steady.log"
printf '2026-11-07_11:00:00 context=standard (explicit); model=claude-opus-5-5 (autocompact=200000)\n' > "$tmp/logs/fx-n2-batch.log"
printf '2026-11-07_12:00:00 context=standard (explicit); model=claude-sonnet-5-5 (autocompact=800000)\n' > "$tmp/logs/fx-n3-idle.log"
python3 -I "$SUT" --json --launch-logs "$tmp/logs" --projects "$tmp/projects" > "$tmp/join.json" 2>"$tmp/join.err"
check "launch logs: only the opus launch at the ceiling is read" fx-n1-steady "$(jq -r '[.workers[].session] | join(",")' "$tmp/join.json")"

python3 -I "$SUT" > /dev/null 2>"$tmp/none.err"; rc=$?
check "no input exits 1" 1 "$rc"

if [ "$fails" -ne 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "PASS all"
