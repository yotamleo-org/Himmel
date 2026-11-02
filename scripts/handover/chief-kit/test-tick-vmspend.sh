#!/usr/bin/env bash
# test-tick-vmspend.sh — the chief tick shows the day's VM test spend, per account,
# as one vmspend= field read through vm-cost.sh --today, and shows nothing when the ledger has no
# row for today. Hermetic: a fixture ledger under the temp root, never the real one; no network.
#
# PLATFORM GUARD: The chief kit is Linux-only; this Bash 3.2 suite exercises that script.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail
# shellcheck disable=SC2154  # fails/W/SUT/HERE come from the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

COST="$HERE/../../vm/vm-cost.sh"
mkdir -p "$W/repo/scripts/vm"
cp "$COST" "$W/repo/scripts/vm/vm-cost.sh"
LEDGER="$W/vm-cost.jsonl"
export LAUNCH_GUEST_COST_LEDGER="$LEDGER"
today="$(date -u +%Y-%m-%d)"
row() { printf '{"ticket":"%s","vm":"v","account":"%s","seconds":10,"usd":%s,"usd_source":"x","ts":"%sT01:02:03Z"}\n' "$1" "$2" "$3" "$4"; }
vmspend_of() { bash "$SUT" 2>/dev/null | sed -n -E 's/.* vmspend=([^ ]*).*/\1/p'; }

# --- vm-cost.sh --today -----------------------------------------------------
{
    row HIMMEL-1 acct-a 1.25 "$today"
    row HIMMEL-2 acct-a 0.5 "$today"
    row HIMMEL-3 acct-b 2.25 "$today"
    row HIMMEL-4 acct-b null "$today"
    row HIMMEL-5 acct-c 9 2000-01-01
    printf 'not json\n'
} > "$LEDGER"
out="$(bash "$COST" --today 2>/dev/null)"; rc=$?
same 'vm-cost --today: exit 0' "$rc" 0
same 'vm-cost --today: one line, per account, today only, an unknown cost marked' "$out" 'acct-a:1.75usd/2runs,acct-b:2.25usd?/2runs'

# --- the tick field ---------------------------------------------------------
same 'tick: vmspend= carries the same per-account line' "$(vmspend_of)" 'acct-a:1.75usd/2runs,acct-b:2.25usd?/2runs'
verbose="$(bash "$SUT" --verbose 2>/dev/null)"
case "$verbose" in *$'\n''vm spend today: acct-a:1.75usd/2runs,acct-b:2.25usd?/2runs'$'\n'*) pass 'tick --verbose: one vm spend today line' ;; *) fail "tick --verbose: no vm spend today line in '$verbose'" ;; esac

# --- negative controls: no row for today means no line ----------------------
row HIMMEL-5 acct-c 9 2000-01-01 > "$LEDGER"
same 'vm-cost --today: only old rows prints nothing' "$(bash "$COST" --today 2>/dev/null)" ''
same 'tick: only old rows prints no vmspend=' "$(vmspend_of)" ''
case "$(bash "$SUT" --verbose 2>/dev/null)" in *'vm spend'*) fail 'tick --verbose: only old rows still printed a vm spend line' ;; *) pass 'tick --verbose: only old rows prints no vm spend line' ;; esac
rm -f "$LEDGER"
same 'tick: no ledger prints no vmspend=' "$(vmspend_of)" ''

[ "$fails" -eq 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
printf 'all tick vmspend rows passed\n'
