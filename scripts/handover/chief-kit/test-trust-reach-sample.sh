#!/usr/bin/env bash
# test-trust-reach-sample.sh - fixture suite for trust-reach-sample.sh (slice 2 of the 24-hour trust run, sampler 4).
# The first rows are the plan's control: a route.log escalate line of a kind not in the table reports UNCLASSIFIED,
# a monitor line reports nothing. Hermetic: route.log, inbound.jsonl and the chief docs are fixtures under
# fixtures/trust-reach/; no bridge, Telegram or live doc is read.
#
# PLATFORM GUARD: the chief kit is Linux-only; this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/trust-reach-sample.sh"
FIX="$HERE/fixtures/trust-reach"
fails=0
pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-trust-reach.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/empty-bucket"

SINCE=2026-11-25T10:00:00Z
NOW=2026-11-25T11:00:00Z
run() { bash "$SUT" --since "$SINCE" --now "$NOW" "$@" 2>/dev/null; }
count() { printf '%s\n' "$1" | grep -c '^{'; }
jf() { printf '%s\n' "$1" | jq -r "$2" 2>/dev/null; }

before="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"

ctl="$(run --bridge "$FIX/bridge-control" --bucket "$W/empty-bucket")"; rc=$?
same 'control: an escalate line of a kind not in the table is UNCLASSIFIED' "$(jf "$ctl" 'select(.kind == "weird-new-kind") | .class')" 'UNCLASSIFIED'
same 'control: a monitor line reports nothing (one row in all)' "$(count "$ctl")" '1'
same 'the run exits 0' "$rc" '0'

out="$(run --bridge "$FIX/bridge" --bucket "$FIX/bucket")"
same 'route.log escalate lines, DELIVERED receipts and operator messages are 8 rows in the window' "$(count "$out")" '8'
same 'every row has exactly ts, source, kind and class' "$(printf '%s\n' "$out" | jq -c 'keys' | sort -u)" '["class","kind","source","ts"]'
same 'a kind in the table has its class' "$(jf "$out" 'select(.kind == "hold-ask-operator") | .class')" 'operator-step'
same 'a phone ask over the operator destination is a row of the table too' "$(jf "$out" 'select(.kind == "bypass-ask") | .class')" 'operator-step'
same 'the kind unclassified is UNCLASSIFIED' "$(jf "$out" 'select(.kind == "unclassified") | .class')" 'UNCLASSIFIED'
same 'a silent line reports nothing' "$(jf "$out" 'select(.kind == "hold-ask-chief") | .kind')" ''
same 'a line whose class is not escalate reports nothing' "$(jf "$out" 'select(.kind == "title-unresolved") | .kind')" ''
same 'a route.log line before the window is not a row' "$(jf "$out" 'select(.source == "route.log") | .ts' | grep -c '09:00')" '0'
same 'route.log rows say so' "$(jf "$out" 'select(.source == "route.log") | .kind' | wc -l | tr -d ' ')" '4'
same 'a DELIVERED receipt is a row, dated through the chief doc name and the clock roll-over' "$(jf "$out" 'select(.source == "delivered") | .ts' | tr '\n' ' ')" '2026-11-25T10:12:00Z 2026-11-25T10:50:00Z '
same 'a DELIVERED receipt is UNCLASSIFIED (its kind says nothing of the ask)' "$(jf "$out" 'select(.source == "delivered") | .class' | sort -u)" 'UNCLASSIFIED'
same 'the operator own messages of inbound.jsonl and inbound.jsonl.1 are rows by time only' "$(jf "$out" 'select(.source == "inbound.jsonl") | .ts' | tr '\n' ' ')" '2026-11-25T10:15:00Z 2026-11-25T10:45:00Z '
same 'an operator message is its own class, not a reach' "$(jf "$out" 'select(.source == "inbound.jsonl") | .class' | sort -u)" 'operator-own'
same 'no row carries any message text' "$(printf '%s\n' "$out" | grep -c LEAKCHECK)" '0'
same 'rows are in time order' "$(jf "$out" '.ts' | sort -c && echo sorted)" 'sorted'

primary_name="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")")"
mkdir -p "$W/ho/fixture/$primary_name"
cp "$FIX/bucket/"*.md "$W/ho/fixture/$primary_name/"
dflt="$(HANDOVER_DIR="$W/ho" USER_SLUG=fixture bash "$SUT" --since "$SINCE" --now "$NOW" --bridge "$FIX/bridge" 2>/dev/null)"
same 'with no --bucket the handover root, user slug and primary checkout name give the bucket' "$dflt" "$out"

note="$(bash "$SUT" --since "$SINCE" --now "$NOW" --bridge "$FIX/bridge" --bucket "$FIX/bucket" 2>&1 >/dev/null)"
case "$note" in *'phone-approval-prompt'*'not seen'*) pass 'the run records that the phone approval prompt source was not seen' ;; *) fail "the run records that the phone approval prompt source was not seen (got '$note')" ;; esac

mkdir -p "$W/noroute"
cp "$FIX/bridge/inbound.jsonl" "$W/noroute/"
u="$(run --bridge "$W/noroute" --bucket "$FIX/bucket")"; urc=$?
same 'a bridge with no route.log prints UNKNOWN route-log' "$u" 'UNKNOWN route-log'
same 'a bridge with no route.log exits 3' "$urc" '3'
mkdir -p "$W/noinbound"
cp "$FIX/bridge/route.log" "$W/noinbound/"
u="$(run --bridge "$W/noinbound" --bucket "$FIX/bucket")"; urc=$?
same 'a bridge with no inbound.jsonl prints UNKNOWN inbound' "$u" 'UNKNOWN inbound'
same 'a bridge with no inbound.jsonl exits 3' "$urc" '3'
u="$(run --bridge "$FIX/bridge" --bucket "$W/no-bucket")"; urc=$?
same 'a missing bucket prints UNKNOWN bucket' "$u" 'UNKNOWN bucket'
same 'a missing bucket exits 3' "$urc" '3'
u="$(run --bridge "$FIX/bridge" --bucket "$FIX/bucket-undated")"; urc=$?
same 'a chief doc with a receipt and no date in its name prints UNKNOWN chief-doc-date' "$u" 'UNKNOWN chief-doc-date'
same 'a chief doc with a receipt and no date in its name exits 3' "$urc" '3'

after="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"
same 'the sampler writes nothing under its sources' "$after" "$before"

printf '%s\n' "$fails failing row(s)"
[ "$fails" -eq 0 ]
