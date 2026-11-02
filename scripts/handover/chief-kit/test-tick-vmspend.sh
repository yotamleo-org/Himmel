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

# VM_COST_SUT overrides the script under test (RED control: a mutated copy must fail a row below).
COST="${VM_COST_SUT:-$HERE/../../vm/vm-cost.sh}"
LEDGER="$W/vm-cost.jsonl"
export LAUNCH_GUEST_COST_LEDGER="$LEDGER"
today="$(date -u +%Y-%m-%d)"
row() { printf '{"ticket":"%s","vm":"v","account":"%s","seconds":10,"usd":%s,"usd_source":"x","ts":"%sT01:02:03Z"}\n' "$1" "$2" "$3" "$4"; }
vmspend_of() { bash "$SUT" 2>/dev/null | sed -n -E 's/.* vmspend=([^ ]*).*/\1/p'; }
tick_rc() { bash "$SUT" >/dev/null 2>&1; echo "$?"; }

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

# --- the line's own logic: money format, row guards, the UTC day, the account label ----------
row HIMMEL-1 acct-p 1.05 "$today" > "$LEDGER"
same 'vm-cost --today: a 1.05 cost keeps its zero pad' "$(bash "$COST" --today 2>/dev/null)" 'acct-p:1.05usd/1runs'
{ printf '{"ticket":"HIMMEL-2","account":"acct-q","usd":1}\n'; row HIMMEL-3 acct-r 2 "$today"; } > "$LEDGER"
out="$(bash "$COST" --today 2>/dev/null)"; rc=$?
same 'vm-cost --today: a row with no ts is skipped and the rest still print' "$out" 'acct-r:2.00usd/1runs'
same 'vm-cost --today: a row with no ts leaves exit 0' "$rc" 0
{ printf '5\n'; row HIMMEL-3 acct-r 2 "$today"; } > "$LEDGER"
out="$(bash "$COST" --today 2>/dev/null)"; rc=$?
same 'vm-cost --today: a bare 5 line is skipped and the rest still print' "$out" 'acct-r:2.00usd/1runs'
same 'vm-cost --today: a bare 5 line leaves exit 0' "$rc" 0
row HIMMEL-1 acct-a 1.5 "$today" > "$LEDGER"
same 'vm-cost --today: a clock ahead of UTC (TZ=Etc/GMT-14) still reads the UTC day' "$(TZ=Etc/GMT-14 bash "$COST" --today 2>/dev/null)" 'acct-a:1.50usd/1runs'
same 'vm-cost --today: a clock behind UTC (TZ=Etc/GMT+12) still reads the UTC day' "$(TZ=Etc/GMT+12 bash "$COST" --today 2>/dev/null)" 'acct-a:1.50usd/1runs'
row HIMMEL-1 'a b,c:d=e' 1 "$today" > "$LEDGER"
same 'vm-cost --today: an odd account label cannot split or spoof a tick field' "$(bash "$COST" --today 2>/dev/null)" 'a_b_c_d_e:1.00usd/1runs'

# --- negative controls: no row for today means no line ----------------------
row HIMMEL-5 acct-c 9 2000-01-01 > "$LEDGER"
same 'vm-cost --today: only old rows prints nothing' "$(bash "$COST" --today 2>/dev/null)" ''
same 'tick: only old rows prints no vmspend=' "$(vmspend_of)" ''
same 'tick: only old rows still completes (exit 0)' "$(tick_rc)" 0
case "$(bash "$SUT" --verbose 2>/dev/null)" in *'vm spend'*) fail 'tick --verbose: only old rows still printed a vm spend line' ;; *) pass 'tick --verbose: only old rows prints no vm spend line' ;; esac
rm -f "$LEDGER"
same 'tick: no ledger prints no vmspend=' "$(vmspend_of)" ''
same 'tick: no ledger still completes (exit 0)' "$(tick_rc)" 0
mkdir "$LEDGER"
[ -d "$LEDGER" ] && pass 'fixture: the unreadable ledger is a directory' || fail 'fixture: the ledger directory was not created'
bash "$COST" --today >/dev/null 2>&1; rc=$?
same 'vm-cost --today: an unreadable ledger (a directory) is not an empty report: nonzero' "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" nonzero
same 'tick: an unreadable ledger prints no vmspend=' "$(vmspend_of)" ''
same 'tick: an unreadable ledger still completes (exit 0)' "$(tick_rc)" 0
rmdir "$LEDGER"

[ "$fails" -eq 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
printf 'all tick vmspend rows passed\n'
