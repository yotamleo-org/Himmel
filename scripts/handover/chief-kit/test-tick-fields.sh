#!/usr/bin/env bash
# test-tick-fields.sh — the second half of test-tick.sh: the fails= ... slotage=
# field rows of the batched chief tick. test-tick.sh ran 490 s against the runner's 600 s cap
# and every new tick field added rows, so it is split at the fails= section; the two halves share
# tick-test-fixture.sh. Hermetic like test-tick.sh: no live queue, process, scheduler, GitHub or bank.
#
# PLATFORM GUARD: The chief kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
# shellcheck disable=SC2154  # fails is set by the sourced tick-test-fixture.sh
set -uo pipefail
KP=HIMMEL

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
# shellcheck source=../../lib/proc-tree.sh
. "$HERE/../../lib/proc-tree.sh"
hs_dir="$W/runner-sem"
mkdir -p "$hs_dir/slot-1"
printf 'pid=%s\nidentity=%s\nlabel=run-shell-tests\nstarted=%s\ndetail=worker=Himmel range=all suites=176\n' \
    "$$" "$(proc_tree_process_identity "$$")" "$(($(date +%s) - 3600))" > "$hs_dir/slot-1/owner"
export HIMMEL_SUITE_SEMAPHORE_DIR="$hs_dir" HIMMEL_SUITE_SLOT_CAP=1200
contains 'the canary held slot is one the tick reports' "$(bash "$SUT" 2>/dev/null)" ' slotage=Himmel:all:176suites:60m'
export HIMMEL_SUITE_SEMAPHORE_DIR="$W/suite-sem"
# --- fails=<n>/<workers>[@<top-class>*<k>][!<recur>] -----------------
# This shift = worker-failures rows with ts >= the chief lock's `started`. The stub
# queue-lock prints an owner.json for a *chief-fails* doc (started 03:00Z) and
# `free` for any other doc, so a chief lock with no start reads fails=?.
d4670="$W/handover/HIMMEL-4670-chief-fails.md"
d4670_free="$W/handover/HIMMEL-4670-chief-nolock.md"
printf '%s\n' '# chief' > "$d4670"
printf '%s\n' '# chief' > "$d4670_free"
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
fails_of() { TOKEN='' bash "$SUT" --doc "$1" 2>/dev/null | sed -n -E 's/.* fails=([^ ]*).*/\1/p'; }
frow() { printf '{"v":1,"ts":"%s","leg":"%s","class":"%s","failure":"denied","count":%s,"recovered":%s}\n' "$1" "$2" "$3" "$4" "${5:-null}"; }
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER" "$HIMMEL_EVAL_RUNS_LEDGER" "$HIMMEL_FAILURE_ROUTES_LOG"
same 'fails= is absent when no ledger exists yet' "$(fails_of "$d4670")" ''
same 'fails=? when the chief lock has no readable start' "$(fails_of "$d4670_free")" '?'
{
    frow 2026-10-07T02:59:59Z N1 denied/old-shift 9
    frow 2026-10-07T03:05:00Z N1 denied/guard-a 2 true
    frow 2026-10-07T03:06:00Z N2 denied/guard-a 3 false
    frow 2026-10-07T03:07:00Z N2 suite/test-x.sh 7
    printf 'not json\n'
} > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails= counts this shift only: rows, distinct workers, top class by workers' "$(fails_of "$d4670")" '3/2@denied/guard-a*2'
cp "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER" "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER.pre"
sed -e 's/^{"v":1,/{"v":1,"meta":{"digest_id":"0123456789abcdef0123456789abcdef","refreshed_at":"2026-10-07T03:40:00Z"},/' "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER.pre" > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails= is unchanged when the rows are refreshed in place, a pre-shift session included' "$(fails_of "$d4670")" '3/2@denied/guard-a*2'
mv "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER.pre" "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
{
    printf '%s\n' '{"ts":"2026-10-07T03:08:00Z","class":"denied/guard-a","legs":2,"decision":"filed","ticket":"HIMMEL-9001"}'
    printf '%s\n' '{"ts":"2026-10-07T03:08:00Z","class":"suite/test-x.sh","legs":1,"decision":"skipped:signal","ticket":null}'
    printf '%s\n' '{"ts":"2026-10-07T03:09:00Z","class":"denied/classifier:ship","legs":2,"decision":"capped","ticket":null}'
    printf '%s\n' '{"ts":"2026-10-07T03:09:30Z","class":"denied/guard-a","legs":2,"decision":"commented","ticket":"HIMMEL-9001"}'
    printf '%s\n' '{"ts":"2026-10-07T02:00:00Z","class":"denied/guard-b","legs":3,"decision":"commented","ticket":"HIMMEL-9002"}'
} > "$HIMMEL_FAILURE_ROUTES_LOG"
same 'fails= !<recur> = distinct classes the router did not skip this shift' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
printf '%s\n' '{"ts":"2026-10-07T03:20:00Z","eval":"leg-trajectory","status":"inconclusive","meta":{"digest_error":"timeout"}}' > "$HIMMEL_EVAL_RUNS_LEDGER"
same 'fails=? when the latest wrap digest this shift failed' "$(fails_of "$d4670")" '?'
printf '%s\n' '{"ts":"2026-10-07T03:30:00Z","eval":"leg-trajectory","status":"ok","meta":{}}' >> "$HIMMEL_EVAL_RUNS_LEDGER"
same 'a later good digest clears fails=?' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
printf '%s\n' '{"ts":"2026-10-07T02:30:00Z","eval":"leg-trajectory","status":"inconclusive","meta":{"digest_error":"crash"}}' > "$HIMMEL_EVAL_RUNS_LEDGER"
same 'a failed digest from before this shift does not read ?' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"; mkdir -p "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails=? when the ledger is unreadable' "$(fails_of "$d4670")" '?'
rmdir "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
frow 2026-10-07T03:05:00Z N7 error/Edit 1 > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
: > "$HIMMEL_FAILURE_ROUTES_LOG"
mkdir -p "$W/fl-old-dir"
same 'fails= reads only HIMMEL_WORKER_SESSION_FAILURES_LEDGER: the retired name beside it changes nothing' "$(HIMMEL_LEG_FAILURES_LEDGER="$W/fl-old-dir" fails_of "$d4670")" '1/1@error/Edit*1' # old-term-ok
rmdir "$W/fl-old-dir"
cp "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER" "$W/fl-old.jsonl"
same 'fails= ignores the retired HIMMEL_LEG_FAILURES_LEDGER when the new name is unset' "$(unset HIMMEL_WORKER_SESSION_FAILURES_LEDGER; HOME="$W/nohome" HIMMEL_LEG_FAILURES_LEDGER="$W/fl-old.jsonl" fails_of "$d4670")" '' # old-term-ok
f4670="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'fails= remains visible when OpenRouter is skipped' "$f4670" ' fails=1/1@error/Edit*1'
contains 'vmrun= follows fails=' "$f4670" ' fails=1/1@error/Edit*1 vmrun=off'
case "$f4670" in *' vmrun='*' '*) fail "vmrun= is the last field when spare= is absent (out='$f4670')" ;; *) pass 'vmrun= is the last field when spare= is absent' ;; esac
printf '#!/bin/sh\necho "garbage not a token"\n' > "$W/vmrun-probe-garbage.sh"
vmrun_garbage="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-garbage.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that prints a non-token reads vmrun=unknown' "$vmrun_garbage" ' vmrun=unknown'
printf '#!/bin/sh\necho DISAGREE:2/2,online=0\n' > "$W/vmrun-probe-disagree.sh"
vmrun_disagree="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-disagree.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that reports units up with no runner online reads vmrun=DISAGREE' "$vmrun_disagree" ' vmrun=DISAGREE:2/2,online=0'
printf '#!/bin/sh\necho DISAGREE:2/2,online=1\n' > "$W/vmrun-probe-partial.sh"
vmrun_partial="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-partial.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that reports fewer runners online than registered units reads vmrun=DISAGREE:2/2,online=1' "$vmrun_partial" ' vmrun=DISAGREE:2/2,online=1'
mkdir -p "$W/vd-mirror"
# --- ciguard= (ci-guardrail.sh -> compact field + one ACTION per ALERT line).
# The stub prints $STUB_CIG_OUT on its first call and $STUB_CIG_OUT2 on later ones.
cat > "$W/ciguard-probe.sh" <<'STUB'
#!/usr/bin/env bash
printf 'x\n' >> "${STUB_CIG_CALLS:-/dev/null}"
[ -z "${STUB_CIG_ENV:-}" ] || printf '%s\n' "${CIGUARD_SLICE_TIMEOUT:-}" > "$STUB_CIG_ENV"
n="$(wc -l < "${STUB_CIG_CALLS:-/dev/null}" | tr -d '[:space:]')"  # read-sink-ok: test stub counting its own call file
if [ "${n:-1}" -le 1 ]; then printf '%s\n' "$STUB_CIG_OUT"; else printf '%s\n' "${STUB_CIG_OUT2:-$STUB_CIG_OUT}"; fi
[ -z "${STUB_CIG_SLEEP:-}" ] || sleep "$STUB_CIG_SLEEP"
STUB
chmod +x "$W/ciguard-probe.sh"
cig_calls="$W/ciguard-calls.txt"
cig_alert=$'ciguard=OVER:runs-h\nALERT runs-h=160>150 (14:00)'
cig_tick() { : > "$cig_calls"; TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_CALLS="$cig_calls" STUB_CIG_OUT="$1" bash "$SUT" "${@:2}" 2>/dev/null; }
cig_ok="$(cig_tick 'ciguard=ok')"
contains 'a quiet guardrail prints ciguard=ok' "$cig_ok" ' ciguard=ok'
not_contains 'a quiet guardrail prints no ACTION ci-guardrail line' "$cig_ok" 'ACTION ci-guardrail'
calls="$(wc -l < "$cig_calls" | tr -d '[:space:]')"
if [ "$calls" = 1 ]; then pass 'one tick runs the guardrail exactly once'; else fail "guardrail calls per tick = $calls, want 1"; fi
cig_over="$(cig_tick "$cig_alert")"
contains 'an OVER guardrail prints ciguard=OVER:<metric>' "$cig_over" ' ciguard=OVER:runs-h'
contains 'one ALERT line prints an ACTION ci-guardrail line carrying it' "$cig_over" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
case "$(printf '%s\n' "$cig_over" | grep -c '^ACTION ci-guardrail')" in 1) pass 'one ALERT line prints exactly one ACTION' ;; *) fail 'one ALERT line prints exactly one ACTION' ;; esac
case "$(printf '%s\n' "$cig_over" | grep -c '^TICK ')" in 1) pass 'the ciguard ACTION line adds no second TICK line' ;; *) fail 'the ciguard ACTION line adds no second TICK line' ;; esac
cig_two="$(cig_tick $'ciguard=OVER:runs-h,reruns-h\nALERT runs-h=160>150 (14:00)\nALERT reruns-h=11>10 (14:00)')"
case "$(printf '%s\n' "$cig_two" | grep -c '^ACTION ci-guardrail')" in 2) pass 'two ALERT lines print two ACTION lines' ;; *) fail 'two ALERT lines print two ACTION lines' ;; esac
cig_a="$(cig_tick "$cig_alert")"
cig_b="$(STUB_CIG_CALLS="$cig_calls" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_OUT="$cig_alert" STUB_CIG_OUT2='ciguard=OVER:runs-h' bash "$SUT" 2>/dev/null)"
contains 'the first read of a crossing prints its ACTION' "$cig_a" 'ACTION ci-guardrail runs-h=160>150'
not_contains 'the next read of the same crossing prints no ACTION' "$cig_b" 'ACTION ci-guardrail'
contains 'the next read of the same crossing still shows ciguard=OVER' "$cig_b" ' ciguard=OVER:runs-h'
cig_unk="$(cig_tick 'ciguard=unknown')"
contains 'an unknown guardrail prints ciguard=unknown' "$cig_unk" ' ciguard=unknown'
not_contains 'an unknown guardrail prints no ACTION ci-guardrail line' "$cig_unk" 'ACTION ci-guardrail'
cig_junk="$(cig_tick 'ALERT runs-h=160>150 (14:00)')"
contains 'output with no status line reads ciguard=unknown' "$cig_junk" ' ciguard=unknown'
not_contains 'an ALERT with no status line prints no ACTION' "$cig_junk" 'ACTION ci-guardrail'
cig_miss="$(TICK_CIGUARD_PROBE="$W/no-such-probe" bash "$SUT" 2>/dev/null)"
contains 'a missing guardrail script reads ciguard=unknown' "$cig_miss" ' ciguard=unknown'
cig_verbose="$(cig_tick "$cig_alert" --verbose)"
contains 'verbose output names the ci guardrail reading' "$cig_verbose" 'ci guardrail: OVER:runs-h'
contains 'verbose output keeps the new ALERT line' "$cig_verbose" 'ALERT runs-h=160>150 (14:00)'

# --- the guardrail reads through a cache a detached refresh fills.
# A refresh still running would write into the next row's fixture, so each row waits it out.
bud_fresh() { [ ! -e "$W/bud/tick-ciguard-last.lock" ] || flock "$W/bud/tick-ciguard-last.lock" true; rm -rf "$W/bud"; mkdir -p "$W/bud"; : > "$cig_calls"; }
bud_tick() { TICK_STATE_DIR="$W/bud" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_CALLS="$cig_calls" bash "$SUT" 2>/dev/null; }
if [ -n "$_TIMEOUT_BIN" ]; then
    bud_fresh
    t0="$(date +%s)"
    bud_hung="$(TICK_CIGUARD_TIMEOUT=2 STUB_CIG_SLEEP=30 TICK_SECTION_WAIT=1 STUB_CIG_OUT="$cig_alert" bud_tick)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung guardrail costs the tick only its short wait'; else fail "a hung guardrail held the tick $((t1 - t0))s"; fi
    contains 'a hung guardrail still yields the worker state' "$bud_hung" ' workers=N61:FRESH'
    contains 'a hung guardrail with no cache reads ciguard=unknown' "$bud_hung" ' ciguard=unknown'
    not_contains 'no cache means no ciguard-age field' "$bud_hung" 'ciguard-age='

    bud_fresh
    bud_kill="$(TICK_CIGUARD_TIMEOUT=1 STUB_CIG_SLEEP=30 STUB_CIG_OUT="$cig_alert" bud_tick)"
    contains 'a refresh past its bound leaves ciguard=unknown' "$bud_kill" ' ciguard=unknown'
    bud_kill2="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT="$cig_alert" bud_tick)"
    same 'a failed refresh is not retried inside the cadence' "$(wc -l < "$cig_calls" | tr -d '[:space:]')" 1
    contains 'a failed refresh still reads ciguard=unknown on the next tick' "$bud_kill2" ' ciguard=unknown'

    bud_fresh
    bud_late="$(TICK_SECTION_WAIT=0 STUB_CIG_SLEEP=2 STUB_CIG_OUT="$cig_alert" bud_tick)"
    not_contains 'a refresh still running shows no ACTION yet' "$bud_late" 'ACTION ci-guardrail'
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/bud/tick-ciguard-last" ] && break; sleep 0.5; done
    bud_after="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT='ciguard=ok' bud_tick)"
    contains 'a refresh outlives the tick that launched it' "$bud_after" ' ciguard=OVER:runs-h'
    contains 'the late refresh delivers its ALERT on the next tick' "$bud_after" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
else
    skip 'guardrail refresh timing rows: no timeout binary'
fi

bud_fresh
bud_a="$(STUB_CIG_ENV="$W/bud-slice" STUB_CIG_OUT="$cig_alert" bud_tick)"
same 'the refresh widens the guardrail slice limit to 120 s' "$(cat "$W/bud-slice")" 120
case "$(printf '%s\n' "$bud_a" | grep -c '^ACTION ci-guardrail')" in 1) pass 'the refreshing tick prints the crossing once' ;; *) fail 'the refreshing tick prints the crossing once' ;; esac
contains 'OVER shows in the TICK line the waiter reads' "$(printf '%s\n' "$bud_a" | grep '^TICK ')" ' ciguard=OVER:runs-h'
contains 'a served guardrail result carries its age' "$bud_a" ' ciguard-age='
touch -d '5 minutes ago' "$W/bud/tick-ciguard-last"  # gnu-ok: chief kit is Linux-only
bud_b="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT='ciguard=ok' bud_tick)"
contains 'a tick inside the cadence serves the cached read' "$bud_b" ' ciguard=OVER:runs-h ciguard-age=30'
not_contains 'a cached read never repeats its ALERT' "$bud_b" 'ACTION ci-guardrail'
same 'a tick inside the cadence reads no guardrail' "$(wc -l < "$cig_calls" | tr -d '[:space:]')" 1
bud_junk="$(STUB_CIG_OUT='not a status line' bud_tick)"
contains 'a junk refresh keeps the last good read and its age' "$bud_junk" ' ciguard=OVER:runs-h ciguard-age=30'
touch -d '2 hours ago' "$W/bud/tick-ciguard-last"  # gnu-ok: chief kit is Linux-only
printf 'ALERT runs-h=160>150 (14:00)\n' > "$W/bud/tick-ciguard-last.alerts"
bud_old="$(TICK_CIGUARD_MIN_SECS=86400 TICK_STATE_DIR="$W/bud" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_CALLS="$cig_calls" flock -o "$W/bud/tick-ciguard-last.lock" bash "$SUT" 2>/dev/null)"
contains 'a cache past its TTL reads ciguard=unknown and shows its age' "$bud_old" ' ciguard=unknown ciguard-age=72'
not_contains 'a tick leaves the ALERT queue alone while a refresh holds the lock' "$bud_old" 'ACTION ci-guardrail'
printf 'garbage\n' > "$W/bud/tick-ciguard-last"
bud_bad="$(TICK_CIGUARD_MIN_SECS=86400 bud_tick)"
contains 'a corrupt cache reads ciguard=unknown' "$bud_bad" ' ciguard=unknown'
contains 'the next tick delivers the queued ALERT' "$bud_bad" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
not_contains 'a corrupt cache carries no age' "$bud_bad" 'ciguard-age='

# --- a tick past its deadline shortens the probes left, so it still answers.
printf '#!/bin/sh\nsleep 30\n' > "$W/hung-probe.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
    t0="$(date +%s)"
    bud_dl="$(TICK_DEADLINE_SEC=1 HIMMEL_VMRUN_PROBE="$W/hung-probe.sh" NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/hung-probe.sh" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'two hung sections past the deadline still return a tick'; else fail "two hung sections held the tick $((t1 - t0))s"; fi
    contains 'a deadline tick keeps the worker state' "$bud_dl" ' workers=N61:FRESH'
    contains 'a section cut by the deadline reads its failure value' "$bud_dl" ' vmrun=unknown'
    contains 'a tick past its deadline says so' "$bud_dl" ' deadline-over='
else
    skip 'deadline rows: no timeout binary'
fi

printf '#!/bin/sh\necho 3\n' > "$W/vd-probe-3.sh"
printf '#!/bin/sh\necho 0\n' > "$W/vd-probe-0.sh"
printf '#!/bin/sh\necho oops\n' > "$W/vd-probe-bad.sh"
vd_three="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-3.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'versionless Done tickets show as versionless-done=<n>' "$vd_three" ' vmrun=off versionless-done=3'
vd_zero="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$vd_zero" in *versionless-done*) fail "a clean project hides versionless-done (out='$vd_zero')" ;; *) pass 'a clean project hides versionless-done' ;; esac
vd_bad="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-bad.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that prints a non-count reads versionless-done=unknown' "$vd_bad" ' versionless-done=unknown'
printf '#!/bin/sh\necho 1234+\n' > "$W/vd-probe-big.sh"
vd_big="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-big.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a lower-bound count of any width is shown as-is' "$vd_big" ' versionless-done=1234+'
contains 'a non-zero versionless-done count prints an ACTION line' "$vd_three" 'ACTION versionless-done=3: bash '
contains 'the ACTION line names versionless-done.sh --backfill' "$vd_three" 'versionless-done.sh --backfill'
ln -s "$(dirname "$SUT")" "$W/vd dir"
vd_space="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-3.sh" TOKEN='' bash "$W/vd dir/tick.sh" --doc "$d4670" 2>/dev/null)"
contains 'the ACTION line escapes a script path with a space' "$vd_space" 'vd\ dir/versionless-done.sh --backfill'
case "$vd_zero$vd_bad" in *'ACTION versionless-done'*) fail "a zero or unknown count prints no ACTION line (out='$vd_zero$vd_bad')" ;; *) pass 'a zero or unknown count prints no ACTION line' ;; esac
case "$(printf '%s\n' "$vd_three" | grep -c '^TICK ')" in 1) pass 'the ACTION line adds no second TICK line' ;; *) fail 'the ACTION line adds no second TICK line' ;; esac
# --- vmismatch=<n|?>: RESET rows of version-status-audit.sh on the mirror.
vm_dir="$W/vm"; vm_m="$vm_dir/HIMMEL"; mkdir -p "$vm_m"
printf 'v1.0.0\ttrue\t2026-01-01\tfalse\nv1.0.1\tfalse\t\tfalse\nv1.0.2\tfalse\t\tfalse\n' > "$vm_dir/HIMMEL.versions.tsv"
vm_mk() { # <key> <status> <fixVersions json>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "In Progress"\npriority: "Medium"\nlabels: []\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: fixture\n' "$1" "$2" "$3" "$1" > "$vm_m/$1.md"
}
printf '#!/bin/sh\nprintf "9999\\tfeat: [HIMMEL-77] x\\tfeat/himmel-77-x\\n"\n' > "$W/vm-gh.sh"; chmod +x "$W/vm-gh.sh"
vm_tick() { NEXT_DISPATCH_MIRROR="$vm_m" VSA_GH_CMD="$W/vm-gh.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null; }
vm_mk HIMMEL-71 "In Progress" '["v1.0.1"]'
vm_clean="$(vm_tick)"
contains 'a clean mirror reads vmismatch=0' "$vm_clean" ' vmismatch=0'
vm_mk HIMMEL-72 "In Progress" '["v1.0.2"]'
vm_one="$(vm_tick)"
contains 'one started later-version ticket reads vmismatch=1' "$vm_one" ' vmismatch=1'
vm_mk HIMMEL-77 "In Progress" '["v1.0.2"]'
vm_owned="$(vm_tick)"
contains 'a later-version ticket held by an open PR is not counted' "$vm_owned" ' vmismatch=1'
rm -f "$vm_dir/HIMMEL.versions.tsv"
vm_bad="$(vm_tick)"
contains 'a failed audit read reads vmismatch=?' "$vm_bad" ' vmismatch=?'
vm_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
not_contains 'no mirror hides vmismatch' "$vm_skip" 'vmismatch'
if [ -n "$_TIMEOUT_BIN" ]; then
    printf '#!/bin/sh\nexec sleep 30\n' > "$W/vm-hung.sh"
    vm_t0="$(date +%s)"
    vm_hung="$(TICK_VMISMATCH_TIMEOUT=1 TICK_VMISMATCH_PROBE="$W/vm-hung.sh" vm_tick)"
    vm_t1="$(date +%s)"
    contains 'a hung audit reads vmismatch=?' "$vm_hung" ' vmismatch=?'
    if [ $((vm_t1 - vm_t0)) -lt 15 ]; then pass 'a hung audit is cut off inside the bound'; else fail "hung audit took $((vm_t1 - vm_t0))s"; fi
else
    skip 'audit timeout rows: no timeout binary'
fi
printf '#!/bin/sh\necho "vmismatch=0"\nexit 3\n' > "$W/vm-partial0.sh"
vm_partial0="$(TICK_VMISMATCH_PROBE="$W/vm-partial0.sh" vm_tick)"
contains 'an incomplete audit with no RESET row reads vmismatch=?' "$vm_partial0" ' vmismatch=?'
printf '#!/bin/sh\nprintf "LATER-VERSION\\tHIMMEL-72\\tIn Progress\\tv1.0.2\\tnone\\tRESET\\nvmismatch=1\\n"\nexit 3\n' > "$W/vm-partial1.sh"
vm_partial1="$(TICK_VMISMATCH_PROBE="$W/vm-partial1.sh" vm_tick)"
contains 'an incomplete audit still reports the RESET rows it found' "$vm_partial1" ' vmismatch=1'
# --- leaks=<n|?|skip>: `jira release leaks` of the active version on the mirror.
lk_dir="$W/lk"; lk_m="$lk_dir/HIMMEL"; mkdir -p "$lk_m"
printf 'v1.0.0\ttrue\t2026-01-01\tfalse\nv1.0.10\tfalse\t\tfalse\nv1.0.2\tfalse\t\tfalse\nv0.9.0\tfalse\t\ttrue\nzz-parked\tfalse\t\tfalse\n' > "$lk_dir/HIMMEL.versions.tsv"
# shellcheck disable=SC2016  # the stub's $1 must reach the stub unexpanded
printf '#!/bin/sh\necho "$1 $2" > "%s/lk-asked"\nprintf "LEAK K-1@%%s carries it\\nLEAK K-2@%%s carries it\\nLEAK K-3@%%s carries it\\n" "$1" "$1" "$1"\n' "$W" > "$W/lk-probe-3.sh"
# shellcheck disable=SC2016  # the stub's $1 must reach the stub unexpanded
printf '#!/bin/sh\necho "leaks $1: none (mirror synced now)"\n' > "$W/lk-probe-0.sh"
# shellcheck disable=SC2016  # the stub's $1 must reach the stub unexpanded
printf '#!/bin/sh\necho "release leaks: $1 is not frozen (no frozen: and frozen-keys: lines in its description)" >&2\nexit 1\n' > "$W/lk-probe-unfrozen.sh"
printf '#!/bin/sh\necho "release leaks: the Jira mirror is missing or unreadable, so no leak result" >&2\nexit 1\n' > "$W/lk-probe-err.sh"
lk_tick() { NEXT_DISPATCH_MIRROR="$lk_m" TICK_LEAKS_PROBE="$1" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null; }
lk_three="$(lk_tick "$W/lk-probe-3.sh")"
contains 'leaked tickets of the frozen version read leaks=<n>' "$lk_three" ' leaks=3'
case "$(cat "$W/lk-asked" 2>/dev/null)" in "v1.0.2 $lk_m") pass 'the probe is asked for the earliest unreleased, unarchived, non-zz version of the tick mirror' ;; *) fail "the probe was asked '$(cat "$W/lk-asked" 2>/dev/null)', want 'v1.0.2 $lk_m'" ;; esac
contains 'a non-zero leak count prints an ACTION line naming the comment run' "$lk_three" 'ACTION leaks=3: JIRA_PROJECT_KEY=HIMMEL node '
mkdir -p "$lk_dir/tickets"; cp "$lk_dir/HIMMEL.versions.tsv" "$lk_dir/tickets.versions.tsv"
lk_over="$(JIRA_PROJECT_KEY=CONFKEY NEXT_DISPATCH_MIRROR="$lk_dir/tickets" TICK_LEAKS_PROBE="$W/lk-probe-3.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'the leaks ACTION line takes the project key from the resolver, not the mirror directory name' "$lk_over" 'ACTION leaks=3: JIRA_PROJECT_KEY=CONFKEY node '
contains 'the leaks ACTION line never names the global jira shim' "$lk_three" '/scripts/jira/dist/index.js release leaks '
printf 'v1.0.2 beta\ttrue\t\tfalse\nv1.0.3 rc\tfalse\t\tfalse\n' > "$lk_dir/HIMMEL.versions.tsv"
lk_space="$(lk_tick "$W/lk-probe-3.sh")"
contains 'a version name with a space is escaped in the ACTION line' "$lk_space" 'release leaks v1.0.3\ rc --mirror-root '
contains 'the leaks ACTION line names the version, the tick mirror and --comment' "$lk_three" "release leaks v1.0.2 --mirror-root $lk_m --comment"
contains 'the leaks ACTION line keeps its explanation behind a shell comment' "$lk_three" '--comment  # posts one comment per leak'
lk_other="$(REPO="$W/repo-other" lk_tick "$W/lk-probe-3.sh")"
not_contains 'the leaks ACTION line resolves the CLI from the tick checkout, not from --repo' "$lk_other" "$W/repo-other/scripts/jira/dist/index.js"
contains 'a tick on another --repo still prints the leaks ACTION line' "$lk_other" '/scripts/jira/dist/index.js release leaks '
lk_cli_of() { printf '%s\n' "$1" | sed -n 's/^ACTION leaks=[0-9]*: JIRA_PROJECT_KEY=[^ ]* node \([^ ]*\) release leaks .*/\1/p'; }
lk_cli_three="$(lk_cli_of "$lk_three")"
if [ -n "$lk_cli_three" ] && [ "$(lk_cli_of "$lk_other")" = "$lk_cli_three" ] && [ -e "${lk_cli_three%/scripts/jira/dist/index.js}/.git" ]; then pass 'the leaks ACTION line names the same primary-checkout CLI whatever --repo is'; else fail "the leaks ACTION CLI is '$(lk_cli_of "$lk_other")' under --repo vs '$lk_cli_three' by default, want one primary checkout"; fi
lk_fix="$W/lk-fix"; mkdir -p "$lk_fix/scripts/handover/chief-kit" "$lk_fix/scripts/lanes"
if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git init -q "$lk_fix"; then pass 'the missing-CLI fixture checkout initialised'; else fail 'the missing-CLI fixture checkout failed git init, so its leaks=? row proves nothing'; fi
cp "$SUT" "$lk_fix/scripts/handover/chief-kit/tick.sh"
cp -R "$HERE/../../lib" "$lk_fix/scripts/lib"
cp -R "$HERE/../../lanes/lib" "$lk_fix/scripts/lanes/lib"
lk_nodist="$(env -u TICK_LEAKS_PROBE NEXT_DISPATCH_MIRROR="$lk_m" TOKEN='' bash "$lk_fix/scripts/handover/chief-kit/tick.sh" --doc "$d4670" 2>/dev/null)"
contains 'a tick whose primary checkout has no built Jira CLI reads leaks=?' "$lk_nodist" ' leaks=?'
not_contains 'a tick with no built Jira CLI prints no leaks ACTION line' "$lk_nodist" 'ACTION leaks'
lk_zero="$(lk_tick "$W/lk-probe-0.sh")"
not_contains 'a clean version hides leaks' "$lk_zero" 'leaks='
lk_unfrozen="$(lk_tick "$W/lk-probe-unfrozen.sh")"
not_contains 'an unfrozen active version hides leaks, it is not an error' "$lk_unfrozen" 'leaks='
lk_err="$(lk_tick "$W/lk-probe-err.sh")"
contains 'a failed leak read reads leaks=?' "$lk_err" ' leaks=?'
not_contains 'a failed leak read prints no ACTION line' "$lk_err" 'ACTION leaks'
lk_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TICK_LEAKS_PROBE="$W/lk-probe-3.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
not_contains 'no mirror hides leaks' "$lk_skip" 'leaks='
cp_dir="$W/cp"; cp_m="$cp_dir/HIMMEL"; mkdir -p "$cp_m"
printf 'v1.0.0\ttrue\t2026-01-01\tfalse\nv1.1.3\tfalse\t\tfalse\nv1.1.4\tfalse\t\tfalse\nv1.1.5\tfalse\t\tfalse\n' > "$cp_dir/HIMMEL.versions.tsv"
cp_n=0
cp_mk() { # <status> <labels json> <fixVersions json> [count]: count tickets (default 1)
    local i="${4:-1}"
    while [ "$i" -gt 0 ]; do
        cp_n=$((cp_n + 1))
        printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "x"\npriority: "Medium"\nlabels: %s\nfixVersions: %s\nparent: null\n---\n\n# HIMMEL-%s: fixture\n' "$cp_n" "$1" "$2" "$3" "$cp_n" > "$cp_m/HIMMEL-$cp_n.md"
        i=$((i - 1))
    done
}
cp_tick() { NEXT_DISPATCH_MIRROR="$cp_m" TICK_LEAKS_PROBE="$W/lk-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null; }
cp_mk "To Do" '["residual"]' '["v1.1.3"]' 16
cp_mk "In Progress" '["backlog","residual-depth-1"]' '["v1.1.4"]' 15
cp_mk "Done" '["residual"]' '["v1.1.4"]' 3
cp_mk "Closed" '["residual"]' '["v1.1.4"]' 2
cp_mk "To Do" '["backlog"]' '["v1.1.4"]' 4
cp_mk "To Do" '["residual"]' '["v1.0.0"]' 20
cp_f() { printf '%s\n' "$1" | awk -v k="$2=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) printf " %s", $i }'; }
cp_rc() { cp_f "$1" residual-cap; }
cp_is() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3' got '$2')"; fi; }
cp_over="$(cp_tick)"
cp_is 'a version past 15 open residuals puts residual-cap=<version>:<n> on the line' "$(cp_rc "$cp_over")" ' residual-cap=v1.1.3:16'
not_contains 'a version at exactly 15 open residuals is not on the residual-cap field, nor Done, Closed, unlabelled or a released version' "$(cp_rc "$cp_over")" 'v1.1.4:'
not_contains 'a released version past 15 is not on the residual-cap field' "$(cp_rc "$cp_over")" 'v1.0.0:'
not_contains 'the old cap= name is gone from the line' "$cp_over" ' cap='
cp_mk "To Do" '["residual"]' '["v1.1.5"]' 17
cp_is 'two versions past 15 are both named, in version order' "$(cp_f "$(cp_tick)" residual-cap)" ' residual-cap=v1.1.3:16,v1.1.5:17'
cp_mk "Wont Fix" '["residual"]' '["v1.1.3"]' 2
cp_mk "Won't Fix" '["backlog"]' '["v1.1.3"]'
cp_mk "To Do" '["backlog"]' '["v1.1.3"]' 5
cp_diff="$(cp_tick)"
cp_is 'a Wont Fix residual does not move residual-cap=' "$(cp_f "$cp_diff" residual-cap)" ' residual-cap=v1.1.3:16,v1.1.5:17'
cp_is "open= counts every open ticket per unreleased version, labels or not; Done, Closed, Wont Fix and Won't Fix excluded, a released version left out" "$(cp_f "$cp_diff" open)" ' open=v1.1.3:21,v1.1.4:19,v1.1.5:17'
rm -f "$cp_m/HIMMEL-1.md"
cp_fifteen="$(cp_tick)"
cp_is 'the other over-run stays on the residual-cap field' "$(cp_rc "$cp_fifteen")" ' residual-cap=v1.1.5:17'
not_contains 'a version dropping to exactly 15 open residuals leaves the residual-cap field' "$(cp_rc "$cp_fifteen")" 'v1.1.3:'
cp_is 'the open count follows the same drop' "$(cp_f "$cp_fifteen" open)" ' open=v1.1.3:20,v1.1.4:19,v1.1.5:17'
rm -f "$cp_m"/HIMMEL-6[1-9].md "$cp_m"/HIMMEL-7[0-7].md
cp_none="$(cp_tick)"
not_contains 'no version past 15 leaves residual-cap= off the line' "$cp_none" 'residual-cap='
cp_is 'open= stays when no version is past the residual cap' "$(cp_f "$cp_none" open)" ' open=v1.1.3:20,v1.1.4:19'
cp_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TICK_LEAKS_PROBE="$W/lk-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
if [ -n "$cp_skip" ]; then pass 'the tick prints its line when no mirror exists'; else fail 'the tick prints its line when no mirror exists'; fi
not_contains 'no mirror leaves residual-cap= off the line' "$cp_skip" ' residual-cap='
not_contains 'no mirror leaves open= off the line' "$cp_skip" ' open='
# Shared status/category contract through the actual tick consumer. Repeat rows
# so the four open fixture cases also exercise the residual soft-cap field.
cp_parity="$W/cp-parity/HIMMEL"
mkdir -p "$cp_parity"
printf 'v1.1.3\tfalse\n' > "$W/cp-parity/HIMMEL.versions.tsv"
python3 - "$HERE/fixtures/t1-views.json" "$cp_parity" <<'PYTEST'
import json, pathlib, sys
rows = json.loads(pathlib.Path(sys.argv[1]).read_text())['statuses']
rows = rows * 4 + [{'status': s, 'category': 'To Do'} for s in ['Done later', 'Wont Fix pending', 'Done\nreopened']]
for i, row in enumerate(rows, 1):
    fields = {'key': 'HIMMEL-%d' % i, 'status': row['status'], 'statusCategory': row['category'], 'labels': ['residual'], 'fixVersions': ['v1.1.3']}
    pathlib.Path(sys.argv[2], fields['key'] + '.md').write_text('---\n' + ''.join(k + ': ' + json.dumps(v) + '\n' for k, v in fields.items()) + '---\n')
PYTEST
cp_contract="$(NEXT_DISPATCH_MIRROR="$cp_parity" TICK_LEAKS_PROBE="$W/lk-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
cp_is 'shared terminal parity: unknown and whole-name negative controls stay open' "$(cp_f "$cp_contract" open)" ' open=v1.1.3:19'
cp_is 'shared terminal parity: only the same open residuals occupy cap slots' "$(cp_f "$cp_contract" residual-cap)" ' residual-cap=v1.1.3:19'
# Both brief templates file every follow-up with `jira create --follow-up-of <KEY>`.
for cp_tpl in worker-brief-template chief-template; do
    if grep -q -- 'jira create --follow-up-of <KEY>' "$HERE/../../../docs/handover/$cp_tpl.md"; then pass "docs/handover/$cp_tpl.md names jira create --follow-up-of <KEY>"; else fail "docs/handover/$cp_tpl.md names jira create --follow-up-of <KEY>"; fi
done
case "$vd_zero" in *wt-orphans*|*wt-ceiling*) fail "no worktree.sh under REPO reads no wt-orphans field (out='$vd_zero')" ;; *) pass 'no worktree.sh under REPO reads no wt-orphans field' ;; esac
mkdir -p "$REPO"
printf '#!/bin/sh\nprintf "ORPHAN /w/a branch=x dirty=0 ahead=1 idle=2d\\nORPHAN /w/b branch=detached:0123456789ab dirty=1 ahead=0 idle=9h\\nCEILING 72/100 worktrees (alarm at 70)\\n"\nexit 1\n' > "$W/wto-probe-2.sh"
printf '#!/bin/sh\nexit 0\n' > "$W/wto-probe-0.sh"
printf '#!/bin/sh\necho "SWEEP-ERROR (prune --orphans) open-PR list unavailable"\nexit 1\n' > "$W/wto-probe-err.sh"
printf '#!/bin/sh\nexit 3\n' > "$W/wto-probe-crash.sh"
printf '#!/bin/sh\nexit 1\n' > "$W/wto-probe-silent1.sh"
wto_two="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'leftover worktrees show as wt-orphans=<n>' "$wto_two" ' wt-orphans=2'
contains 'a live count at the alarm shows as wt-ceiling=<live>/<cap>' "$wto_two" ' wt-ceiling=72/100'
wto_cache_f="$TICK_STATE_DIR/tick-wt-orphans-$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
if [ -s "$wto_cache_f" ]; then pass 'the reading is cached under a file keyed by REPO'; else fail 'the reading is cached under a file keyed by REPO'; fi
contains 'leftover worktrees print an ACTION line naming prune --orphans' "$wto_two" 'ACTION wt-orphans=2 wt-ceiling=72/100: bash '
case "$(printf '%s\n' "$wto_two" | grep -c '^TICK ')" in 1) pass 'the wt-orphans ACTION line adds no second TICK line' ;; *) fail 'the wt-orphans ACTION line adds no second TICK line' ;; esac
wto_cached="$(TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a read younger than the TTL is served from the cache' "$wto_cached" ' wt-orphans=2'
mkdir -p "$W/repo-other"
wto_other="$(REPO="$W/repo-other" TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$wto_other" in *wt-orphans*|*wt-ceiling*) fail "a chief on another REPO never reads this REPO's cache (out='$wto_other')" ;; *) pass "a chief on another REPO never reads this REPO's cache" ;; esac
wto_zero="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$wto_zero" in *wt-orphans*|*wt-ceiling*) fail "a clean fleet hides wt-orphans and wt-ceiling (out='$wto_zero')" ;; *) pass 'a clean fleet hides wt-orphans and wt-ceiling' ;; esac
wto_err="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-err.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'an unavailable open-PR list reads wt-orphans=unknown, not an all-clear' "$wto_err" ' wt-orphans=unknown'
rm -f "$wto_cache_f.fail"
wto_crash="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-crash.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a failed probe reads wt-orphans=unknown' "$wto_crash" ' wt-orphans=unknown'
rm -f "$wto_cache_f"
wto_after="$(TICK_WT_ORPHANS_FAIL_TTL=0 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a failed probe is not cached, so the next tick reads afresh' "$wto_after" ' wt-orphans=2'
printf '# clean\n' > "$wto_cache_f"
rm -f "$wto_cache_f.fail"
wto_silent="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-silent1.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe exiting 1 with no alarm line reads wt-orphans=unknown' "$wto_silent" ' wt-orphans=unknown'
rm -f "$wto_cache_f"
wto_after="$(TICK_WT_ORPHANS_FAIL_TTL=0 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a silent exit 1 is not cached as an all-clear' "$wto_after" ' wt-orphans=2'
: > "$wto_cache_f"
wto_empty="$(TICK_WT_ORPHANS_FAIL_TTL=0 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'an empty cache is not an all-clear, so the tick reads afresh' "$wto_empty" ' wt-orphans=2'
case "$(find "$TICK_STATE_DIR" -name 'tick-wt-orphans-*.[0-9]*' 2>/dev/null)" in '') pass 'the cache write leaves no temp file behind' ;; *) fail 'the cache write leaves no temp file behind' ;; esac
rm -f "$wto_cache_f"
printf '#!/bin/sh\necho $$ > "%s"\nexec sleep 100\n' "$W/wto-slow.pid" > "$W/wto-probe-slow.sh"
printf '#!/bin/sh\necho x >> "%s"\nexit 3\n' "$W/wto-runs" > "$W/wto-probe-count.sh"
printf 'ORPHAN /w/a branch=x dirty=0 ahead=1 idle=2d\nORPHAN /w/b branch=y dirty=0 ahead=0 idle=3d\n' > "$wto_cache_f"
touch -d '2 hours ago' "$wto_cache_f"
rm -f "$W/wto-slow.pid"
wto_t0=$SECONDS
wto_slow="$(TICK_DEADLINE_SEC=30 TICK_SECTION_WAIT=2 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-slow.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
wto_slow_secs=$((SECONDS - wto_t0))
if [ "$wto_slow_secs" -lt 20 ]; then pass 'a 100 s sweep does not stall the tick'; else fail "a 100 s sweep stalled the tick for ${wto_slow_secs}s"; fi
contains 'a slow sweep serves the last good reading with its age' "$wto_slow" ' wt-orphans=2@2h'
if [ -s "$W/wto-slow.pid" ]; then kill "$(cat "$W/wto-slow.pid")" 2>/dev/null || true; fi  # swallow-ok: the stub may already be gone
for _ in $(seq 1 40); do [ -e "$wto_cache_f.fail" ] && break; sleep 0.25; done
rm -f "$wto_cache_f" "$wto_cache_f.fail" "$W/wto-runs"
TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-count.sh" TOKEN='' bash "$SUT" --doc "$d4670" >/dev/null 2>&1
TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-count.sh" TOKEN='' bash "$SUT" --doc "$d4670" >/dev/null 2>&1
same 'a failed sweep is not re-run inside its negative TTL' "$(wc -l < "$W/wto-runs" 2>/dev/null | tr -d ' ')" '1'
TICK_WT_ORPHANS_FAIL_TTL=0 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-count.sh" TOKEN='' bash "$SUT" --doc "$d4670" >/dev/null 2>&1
same 'a failed sweep is re-run once its negative TTL has passed' "$(wc -l < "$W/wto-runs" 2>/dev/null | tr -d ' ')" '2'
rm -f "$wto_cache_f" "$wto_cache_f.fail" "$W/wto-slow.pid"
printf '# clean\n' > "$wto_cache_f"
touch -d '2 hours ago' "$wto_cache_f"
wto_slow0="$(TICK_DEADLINE_SEC=30 TICK_SECTION_WAIT=2 TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-slow.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a stale clean reading shows its age, never a current all-clear' "$wto_slow0" ' wt-orphans=0@2h'
if [ -s "$W/wto-slow.pid" ]; then kill "$(cat "$W/wto-slow.pid")" 2>/dev/null || true; fi  # swallow-ok: the stub may already be gone
for _ in $(seq 1 40); do [ -e "$wto_cache_f.fail" ] && break; sleep 0.25; done
rm -f "$wto_cache_f" "$wto_cache_f.fail" "$W/wto-slow.pid"
wto_fast="$(TICK_FAST=1 TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$wto_fast" in *wt-orphans*) fail "a fast tick skips the worktree sweep (out='$wto_fast')" ;; *) pass 'a fast tick skips the worktree sweep' ;; esac
fp_full="$(TOKEN='' bash "$SUT" --doc "$d4670" --emit-fp 2>/dev/null | sed -n 's/^board-fp=//p')"
fp_fast="$(TICK_FAST=1 TOKEN='' bash "$SUT" --doc "$d4670" --emit-fp 2>/dev/null | sed -n 's/^board-fp=//p')"
if [ -n "$fp_full" ] && [ "$fp_full" = "$fp_fast" ]; then pass 'board-fp is equal under the fast and the full tick'; else fail "board-fp differs (full '$fp_full', fast '$fp_fast')"; fi
rm -f "$wto_cache_f" "$wto_cache_f.fail"
contains 'verbose labels worker failures' "$(TOKEN='' bash "$SUT" --doc "$d4670" --verbose 2>/dev/null)" 'worker-session failures: 1/1@error/Edit*1'
printf '%s\n' '{"v":1,"ts":"2026-10-07T03:05:00Z","leg":"N8","class":"denied/a b\tc","failure":"denied","count":1}' > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'whitespace in the top class cannot split the TICK line' "$(fails_of "$d4670")" '1/1@denied/a_b_c*1'
# ~<k> = workers whose wrap digest was skipped this shift (the step's
# skips.jsonl, distinct docs), so an undigested wrap is no longer silent.
{
    printf '%s\n' '{"ts":"2026-10-07T03:10:00Z","doc":"A.md","reason":"no-chain"}'
    printf '%s\n' '{"ts":"2026-10-07T03:11:00Z","doc":"A.md","reason":"no-chain"}'
    printf '%s\n' '{"ts":"2026-10-07T03:12:00Z","doc":"B.md","reason":"no-resume-cwd"}'
    printf '%s\n' '{"ts":"2026-10-07T02:00:00Z","doc":"C.md","reason":"no-chain"}'
} > "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"
same 'fails= ~<k> counts docs whose digest was skipped this shift' "$(fails_of "$d4670")" '1/1@denied/a_b_c*1~2'
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails=none~<k> when skips are the only signal' "$(fails_of "$d4670")" 'none~2'
rm -f "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"; mkdir -p "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"
same 'fails=? when the skips log is unreadable' "$(fails_of "$d4670")" '?'
rmdir "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER" "$HIMMEL_EVAL_RUNS_LEDGER" "$HIMMEL_FAILURE_ROUTES_LOG"

# --- flakes=<rows>/<suites>@<top-suite>*<k> ---------------------------
# This shift = suite-flake rows for this repo id with ts >= the chief lock's
# `started` (03:00Z). Absent unless a row is new; a quiet shift keeps the line as is.
mkdir -p "$W/repo/scripts/observability"
cp "$HERE/../../observability/suite-flake-summary.sh" "$W/repo/scripts/observability/suite-flake-summary.sh"
flakes_of() { TOKEN='' bash "$SUT" --doc "$1" 2>/dev/null | sed -n -E 's/.* flakes=([^ ]*).*/\1/p'; }
fk0=$(date -u -d 2026-10-07T03:00:00Z +%s)
fkrow() { printf '{"v":1,"ts":%s,"host":"h","source":"run-shell-tests","kind":"flake","suite":"%s","repo":"%s","case":"c","rc":1,"sha":"s","run":"1"}\n' "$1" "$2" "$3"; }
rm -f "$SUITE_FLAKE_LEDGER"
same 'flakes= is absent with no ledger' "$(flakes_of "$d4670")" ''
{
    fkrow $((fk0 - 60)) test-old.sh tick-test-repo
    fkrow $((fk0 + 60)) test-x.sh tick-test-repo
    fkrow $((fk0 + 120)) test-x.sh tick-test-repo
    fkrow $((fk0 + 180)) test-y.sh tick-test-repo
    fkrow $((fk0 + 180)) test-other.sh some-other-repo
    printf 'not json\n'
} > "$SUITE_FLAKE_LEDGER"
same 'flakes= counts this shift, this repo only, with the top suite repeat count' "$(flakes_of "$d4670")" '3/2@test-x.sh*2'
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *' flakes=3/2@test-x.sh*2') pass 'flakes= follows fails= and is the last field without spare=' ;; *) fail "flakes= position (out='$fk_out')" ;; esac
contains 'verbose labels suite flakes' "$(TOKEN='' bash "$SUT" --doc "$d4670" --verbose 2>/dev/null)" 'suite flakes: 3/2@test-x.sh*2'
same 'a doc with no lock start reads no flakes=' "$(flakes_of "$d4670_free")" ''
# A suite name carrying Unicode whitespace plus a key=value must not forge a field:
# board.mjs splits the line on a JS \s regex where the last key wins.
fknbsp=$'test-x\xc2\xa0legs=9\xe2\x80\xa8fleet=9.sh'
fkrow $((fk0 + 60)) "$fknbsp" tick-test-repo > "$SUITE_FLAKE_LEDGER"
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *$'\xc2\xa0'*|*$'\xe2\x80\xa8'*) fail "flakes= carries Unicode whitespace from a suite name (out='$fk_out')" ;; *) pass 'flakes= strips Unicode whitespace from the top suite name' ;; esac
same 'a forged key in a suite name stays inside the flakes= value' "$(flakes_of "$d4670")" '1/1@test-x_legs_9_fleet_9.sh*1'
rm -f "$SUITE_FLAKE_LEDGER"; mkdir -p "$SUITE_FLAKE_LEDGER"
same 'flakes=? when the ledger is unreadable' "$(flakes_of "$d4670")" '?'
rmdir "$SUITE_FLAKE_LEDGER"
# The tick.sh whitelist guard on its own: a stub reader that bypasses the reader's
# sanitising and emits an NBSP + a forged key; reverting the guard turns this red.
printf '#!/usr/bin/env bash\nprintf "1/1@test-x\\xc2\\xa0legs=9.sh*1\\n"\n' > "$W/repo/scripts/observability/suite-flake-summary.sh"
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *' flakes='*) fail "tick.sh guard let an NBSP-bearing reader line through (out='$fk_out')" ;; *) pass 'tick.sh drops a reader line carrying Unicode whitespace' ;; esac
cp "$HERE/../../observability/suite-flake-summary.sh" "$W/repo/scripts/observability/suite-flake-summary.sh"

# --- vault=<ok|STALL:<age>,<n>|PUSH-LAG:<age>|skip|unknown> -- the luna
# vault's commit health, from vault-status.sh. RED control (pre-change tick.sh): the
# line carries no vault= field, so a stalled vault commit is invisible to the chief.
# The vault rows read a one-worker tick: the worker doc and its live process, which the first
# half of the suite (test-tick.sh, the board= section) sets up for its own rows. Repeated here
# so this half runs alone.
b3361="HIMMEL-3361-N361-board-2026-09-21-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$b3361.md"
mkcmdline 361 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3361-N361-board work
mk_pgrep_x "$W/bin-3361" 361
t3361() { PATH="$W/bin-3361:$PATH" bash "$SUT" --workers "$W/handover/$b3361.md"; }
v4911="$W/vault4911"
gv4911() { git -C "$v4911" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
git init -q -b main "$v4911" && git init -q --bare "$W/vault4911.git"
git -C "$v4911" remote add origin "$W/vault4911.git"
echo seed > "$v4911/seed.md"
git -C "$v4911" add seed.md
gv4911 commit -q -m seed
git -C "$v4911" push -q -u origin main
t4911() { TICK_VAULT_DIR="$1" bash "$SUT" --workers "$W/handover/$b3361.md" "${@:2}"; }
contains 'no vault configured reads vault=skip' "$(t3361)" ' vault=skip'
contains 'a clean vault reads vault=ok' "$(t4911 "$v4911")" ' vault=ok'
echo staged > "$v4911/a.md"; git -C "$v4911" add a.md
touch -d '50 minutes ago' "$v4911/a.md"  # gnu-ok: chief kit is Linux-only
contains 'files staged past the threshold read vault=STALL:<age>,<n>' "$(t4911 "$v4911")" ' vault=STALL:50m,1'
contains '--verbose labels the vault' "$(t4911 "$v4911" --verbose)" 'vault: STALL:50m,1'
GIT_COMMITTER_DATE="$(date -d '3 hours ago' +%s) +0000" gv4911 commit -q -m lag  # gnu-ok: chief kit is Linux-only
contains 'an unpushed commit past the threshold reads vault=PUSH-LAG:<age>' "$(t4911 "$v4911")" ' vault=PUSH-LAG:3h'
mkdir -p "$W/vault4911bad/.git"; echo garbage > "$W/vault4911bad/.git/HEAD"
contains 'a corrupt vault reads vault=unknown and the tick still runs' "$(t4911 "$W/vault4911bad")" ' vault=unknown'

# --- cloud=<ok|STALL:<ticket>[,...]|skip> -- cloud-sessions.tsv against the
# forge. Fixtures are REAL: the tsv rows are the 2026-10-10 launch rows, the PR JSON is the
# trimmed `gh pr list` output for PR 2314 (open, one commit, CLOUD-DONE, no
# shepherd), PR 2306 and PR 1982. 4655 and 4686 produced no branch.
# RED control (pre-change tick.sh): the line carries no cloud= field at all.
c5163="$W/cloud5163"
mkdir -p "$c5163"
cp "$W/handover/chief.md" "$c5163/chief.md" 2>/dev/null || printf '%s\n' '# chief' > "$c5163/chief.md"
printf '%s\n' '#!/bin/sh' "cat '$HERE/fixtures/cloud-liveness-prs.json'" > "$c5163/gh"
printf '%s\n' '#!/bin/sh' "printf '%s\n' 'aaaa	refs/heads/main' 'bbbb	refs/heads/claude/agui-sse-hardening-fwa0t2'" > "$c5163/git"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$c5163/gh-down"
chmod +x "$c5163/gh" "$c5163/git" "$c5163/gh-down"
t5163() {
    TZ=Europe/Berlin TOKEN='' CLOUD_LIVENESS_NOW='2026-10-10T16:30:00Z' CLOUD_LIVENESS_GH_CMD="$c5163/${GHSTUB5163:-gh}" \
        CLOUD_LIVENESS_GIT_CMD="$c5163/git" bash "$SUT" --doc "$c5163/chief.md" "$@" 2>/dev/null
}
cloud_of() { sed -nE 's/.* cloud=([^ ]*).*/\1/p'; }
contains 'no cloud-sessions.tsv reads cloud=skip' "$(t5163)" ' cloud=skip'
printf '%s\t%s\t%s\t%s\n' \
    '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' \
    '2026-10-10T15:56:32' HIMMEL-4655 session_01JJVL8oEQVV6M19v4kobvRV 'claude --teleport session_01JJVL8oEQVV6M19v4kobvRV' \
    '2026-10-10T15:56:43' HIMMEL-4657 session_01BCqPMDHjUE9Z52yEy3J3Uf 'claude --teleport session_01BCqPMDHjUE9Z52yEy3J3Uf' \
    '2026-10-10T15:56:54' HIMMEL-4686 session_0173H75dC4x9nZ7JdeLqYoMc 'claude --teleport session_0173H75dC4x9nZ7JdeLqYoMc' \
    > "$c5163/cloud-sessions.tsv"
equals5163="STALL:HIMMEL-5077,HIMMEL-4655,HIMMEL-4686"
contains 'no-branch + CLOUD-DONE-without-shepherd sessions read cloud=STALL (merged 4657 is not a stall)' "$(t5163 | cloud_of)" "$equals5163"
not_contains 'a merged cloud PR is never a stall' "$(t5163 | cloud_of)" 'HIMMEL-4657'
printf '%s\n' '# HIMMEL-5077 shepherd' '- 16:00 LIVE — shepherding PR 2314' > "$c5163/HIMMEL-5077-N9-shepherd-2026-10-10.md"
contains 'a live worker doc naming the PR clears the unshepherded stall' "$(t5163 | cloud_of)" 'STALL:HIMMEL-4655,HIMMEL-4686'
printf '%s\n' '# HIMMEL-5077 shepherd' '- 16:00 LIVE — shepherding PR 2314' '- 16:20 WRAPPED — done' > "$c5163/HIMMEL-5077-N9-shepherd-2026-10-10.md"
contains 'a WRAPPED worker doc is not a live shepherd' "$(t5163 | cloud_of)" "$equals5163"
contains 'an unreadable forge reads cloud=skip, never a failed tick' "$(GHSTUB5163=gh-down t5163 | cloud_of)" 'skip'
contains '--verbose labels the cloud field' "$(t5163 --verbose)" "cloud: $equals5163"
# An open PR with no CLOUD-DONE: the real 2314 JSON minus its CLOUD-DONE comment, carrying
# the cloud brief's mandated `cloud-pilot:` body line (the PR's own last commit is 14:05Z).
printf '%s\n' \
    "const p = JSON.parse(require('fs').readFileSync('$HERE/fixtures/cloud-liveness-prs.json', 'utf8')).filter((x) => x.number === 2314);" \
    "p[0].comments = p[0].comments.filter((c) => !/^CLOUD-DONE/.test(c.body));" \
    "p[0].body += '\ncloud-pilot: HIMMEL-5077 (chief c)';" \
    "process.stdout.write(JSON.stringify(p));" > "$c5163/silent.js"
printf '%s\n' '#!/bin/sh' "node '$c5163/silent.js'" > "$c5163/gh-silent"
chmod +x "$c5163/gh-silent"
printf '%s\t%s\t%s\t%s\n' '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' > "$c5163/cloud-sessions.tsv"
GHSTUB5163=gh-silent
contains 'an open PR with no CLOUD-DONE and no commit for an hour reads STALL' "$(t5163 | cloud_of)" 'STALL:HIMMEL-5077'
contains 'the same PR under a raised quiet threshold is working, not a stall' "$(CLOUD_LIVENESS_PR_MIN=9999 t5163 | cloud_of)" 'ok'
# a relaunch supersedes the earlier launch, so a PR made before it no longer
# speaks for the ticket; a full gh page that may have cut a live session's PR off is unknown.
printf '%s\t%s\t%s\t%s\n' '2026-10-10T18:20:00' HIMMEL-5077 session_relaunch 'claude --teleport session_relaunch' > "$c5163/cloud-sessions.tsv"
contains 'a PR from before the relaunch does not stall the new session' "$(t5163 | cloud_of)" 'ok'
printf '%s\n' \
    "const a = [];" \
    "for (let i = 0; i < 100; i++) a.push({ number: i + 1, title: 'x', body: '', state: 'MERGED', headRefName: 'z', createdAt: '2026-10-10T16:00:00Z', mergedAt: '2026-10-10T16:01:00Z', comments: [], commits: [] });" \
    "process.stdout.write(JSON.stringify(a));" > "$c5163/full.js"
printf '%s\n' '#!/bin/sh' "node '$c5163/full.js'" > "$c5163/gh-full"
chmod +x "$c5163/gh-full"
printf '%s\t%s\t%s\t%s\n' '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' > "$c5163/cloud-sessions.tsv"
contains 'a full gh page newer than the session launch reads cloud=skip' "$(GHSTUB5163=gh-full t5163 | cloud_of)" 'skip'

# --- stall=<pr>:<class>[,...]: pr-stall.sh's STALL rows folded into one field.
# Absent when nothing is stuck, the probe fails or prints STALL-UNKNOWN. RED control
# (pre-change tick.sh): the line never carries stall=. A cache bounds the probe to one run
# per TICK_STALL_TTL_MIN.
st6049="$W/stall6049"
mkdir -p "$st6049"
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
printf '%s\n' '#!/bin/sh' 'echo run >> "$ST_COUNT"' 'if [ -n "$ST_FAIL" ]; then echo "STALL-UNKNOWN gh failed"; exit 3; fi' \
    'echo "STALL 2887 conflict N2362 mergeStateStatus=DIRTY head=abc action=merge"' \
    'echo "STALL 2869 ci-slow - 2 check(s) in flight queue=5"' 'echo "STALL-SUMMARY stuck=2 queue=5"' > "$st6049/probe"
chmod +x "$st6049/probe"
t6049() { rm -f "$st6049/cache"; ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN="${TTL6049:-0}" bash "$SUT" "$@" 2>/dev/null; }
stall_of() { sed -nE 's/.* stall=([^ ]*).*/\1/p'; }
same 'stall= folds the probe rows to pr:class' "$(t6049 | stall_of)" '2887:conflict,2869:ci-slow'
contains 'verbose labels the stall field' "$(t6049 --verbose)" 'stall: 2887:conflict,2869:ci-slow'
same 'a failing probe with nothing cached reads stall=?' "$(ST_FAIL=1 t6049 | stall_of)" '?'
rm -f "$st6049/count" "$st6049/cache"
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
touch -d '3 hours ago' "$st6049/cache"
same 'a failing probe after the TTL emits the last cached value' "$(ST_FAIL=1 ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" 2>/dev/null | stall_of)" '2887:conflict,2869:ci-slow'
: > "$st6049/count"
ST_FAIL=1 ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
same 'the failure is cached for the TTL: a second tick does not re-run the probe' "$(wc -l < "$st6049/count" | tr -d ' ')" '0'
rm -f "$st6049/count" "$st6049/cache"
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
same 'two ticks inside the TTL run the probe once' "$(wc -l < "$st6049/count" | tr -d ' ')" '1'

# --- doctor=<id>[,<id>...]: the WARN/FAIL check ids of himmel-doctor --json,
# read on a slow cache (TICK_DOCTOR_TTL_MIN, default 30, 0 = off). Absent when the doctor is
# clean or the probe is missing; a failed probe reads the last cached value, else ?. The stub
# stands in for the doctor: no suite ever runs the real one. RED control (pre-change tick.sh):
# the line never carries doctor=.
dr7849="$W/doctor7849"
mkdir -p "$dr7849"
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
printf '%s\n' '#!/bin/sh' 'echo run >> "$DR_COUNT"' '[ -n "$DR_SLEEP" ] && sleep "$DR_SLEEP"' 'if [ -n "$DR_FAIL" ]; then echo "doctor crashed" >&2; exit 3; fi' \
    'echo "himmel-doctor — Linux — checkout: /x"; echo' \
    'if [ -n "$DR_CLEAN" ]; then echo "{\"sev\":\"OK\",\"id\":\"C1\",\"msg\":\"fine\",\"remedy\":\"\"}"; echo; echo "Summary: 0 FAIL  0 WARN  0 INFO"; exit 0; fi' \
    'echo "{\"sev\":\"OK\",\"id\":\"C1-guardrail\",\"msg\":\"fine\",\"remedy\":\"\"}"' \
    'echo "{\"sev\":\"WARN\",\"id\":\"C77-bridge-stale\",\"msg\":\"stale\",\"remedy\":\"restart\"}"' \
    'echo "{\"sev\":\"INFO\",\"id\":\"C45-qmd-daemon\",\"msg\":\"note\",\"remedy\":\"\"}"' \
    'echo "{\"sev\":\"FAIL\",\"id\":\"C16-hooks\",\"msg\":\"missing\",\"remedy\":\"setup\"}"' \
    'echo; echo "Summary: 1 FAIL  1 WARN  1 INFO"; exit 1' > "$dr7849/doctor"
chmod +x "$dr7849/doctor"
t7849() { rm -f "$dr7849/cache"; DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" TICK_DOCTOR_TTL_MIN="${TTL7849:-30}" bash "$SUT" "$@" 2>/dev/null; }
doctor_of() { sed -nE 's/.* doctor=([^ ]*).*/\1/p'; }
same 'doctor= lists the WARN and FAIL ids, sorted, and leaves OK and INFO out' "$(t7849 | doctor_of)" 'C16-hooks,C77-bridge-stale'
contains 'verbose labels the doctor field' "$(t7849 --verbose)" 'doctor: C16-hooks,C77-bridge-stale'
same 'a clean doctor leaves doctor= off the line' "$(DR_CLEAN=1 t7849 | doctor_of)" ''
same 'a failing doctor with nothing cached reads doctor=?' "$(DR_FAIL=1 t7849 | doctor_of)" '?'
same 'TTL 0 turns the doctor probe off' "$(TTL7849=0 t7849 | doctor_of)" ''
rm -f "$dr7849/count" "$dr7849/cache"
DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" >/dev/null 2>&1
same 'the second tick inside the TTL serves the cached ids' "$(DR_FAIL=1 DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'two ticks inside the TTL run the doctor once' "$(wc -l < "$dr7849/count" | tr -d ' ')" '1'
touch -d '3 hours ago' "$dr7849/cache"
same 'a failing doctor after the TTL emits the last cached ids' "$(DR_FAIL=1 DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'a missing doctor script leaves doctor= off the line' "$(TICK_DOCTOR_CMD="$dr7849/no-such-doctor" TICK_DOCTOR_CACHE="$dr7849/none" bash "$SUT" 2>/dev/null | doctor_of)" ''
# A doctor slower than the tick's wait budget runs detached: the tick answers `?` at once, the
# run finishes on its own, and the next tick folds the finished rows in without a second run.
rm -f "$dr7849/count" "$dr7849/slow".*
DR_SLEEP=3 DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/slow" bash "$SUT" > "$dr7849/slow-line" 2>/dev/null
same 'a doctor slower than the wait budget reads doctor=? on that tick' "$(doctor_of < "$dr7849/slow-line")" '?'
sleep 5
same 'the next tick folds in the finished slow run' "$(DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/slow" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'the slow run was started once, not once per tick' "$(wc -l < "$dr7849/count" | tr -d ' ')" '1'
# The default wait is short (3 s): a 5 s doctor does not hold the tick, so the tick reads `?`.
rm -f "$dr7849/dflt" "$dr7849/dflt".*
DR_SLEEP=5 DR_COUNT="$dr7849/dflt-count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/dflt" bash "$SUT" > "$dr7849/dflt-line" 2>/dev/null
same 'the default wait does not hold the tick for a 5 s doctor' "$(doctor_of < "$dr7849/dflt-line")" '?'
# Two ticks share one cache: a live run holds the run directory and a tick that finds it starts no
# second run; a run directory older than 15 minutes is a lost run and the next tick starts a new one.
rm -rf "$dr7849/count" "$dr7849/held".*
mkdir "$dr7849/held.cache.run"
DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/held.cache" bash "$SUT" > "$dr7849/held-line" 2>/dev/null
same 'a live run directory keeps a second tick from starting a run' "$(cat "$dr7849/count" 2>/dev/null | wc -l | tr -d ' ')" '0'
same 'a tick waiting on a run another tick holds reads doctor=?' "$(doctor_of < "$dr7849/held-line")" '?'
touch -d '20 minutes ago' "$dr7849/held.cache.run"
DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/held.cache" bash "$SUT" > "$dr7849/lost-line" 2>/dev/null
same 'a run directory older than 15 minutes is a lost run and a new one starts' "$(doctor_of < "$dr7849/lost-line")" 'C16-hooks,C77-bridge-stale'

# --- a detached refresh the tick harvests adds none of its CPU to the tick.
# A timed tick counts the CPU of every child it reaped, so a refresh the tick launched itself
# and waited out landed in its time. The stubs spin about 2 s of CPU; the control stubs do not.
cpu9342() {  # cpu9342 <stdout-file> <cmd...>: the CPU ms of the children the command reaped
    local out="$1" t; shift
    t="$( { TIMEFORMAT='%U %S'; time "$@" >"$out" 2>/dev/null; } 2>&1 )"
    printf '%s\n' "$t" | tr , . | LC_ALL=C awk 'END { printf "%d", ($1 + $2) * 1000 }'  # a de_DE station prints 2,987
}
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
spin9342='i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done'
# A stub that is given NICE_OUT writes its own nice value there as its FIRST step: the rows below read
# it. (A station daemon such as ananicy-cpp renices a running bash a few seconds after it starts, so a
# stub that read it after its spin saw the daemon's value, not the launch's.)
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
nice9342='[ -z "${NICE_OUT:-}" ] || sed "s/.*) //" /proc/$$/stat | cut -d" " -f17 >"$NICE_OUT"'
# /proc/<pid>/stat field 19 is the nice value; `ps -o ni` prints "-" for a process under a non-default scheduler.
stub_niced_10_below_suite9342() {
    local got want
    got="$(cat "$1" 2>/dev/null)"; want=$(( $(sed 's/.*) //' /proc/$$/stat | cut -d' ' -f17) + 10 )); [ "$want" -le 19 ] || want=19
    case "$got" in '' | *[!0-9-]*) return 1 ;; esac
    [ "$got" -ge "$want" ]
}
dr9342="$W/dr9342"; mkdir -p "$dr9342"
printf '%s\n' '#!/usr/bin/env bash' "$nice9342" "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" \
    'echo "{\"sev\":\"WARN\",\"id\":\"C9-spin\",\"msg\":\"m\",\"remedy\":\"r\"}"; exit 0' > "$dr9342/doctor"
chmod +x "$dr9342/doctor"
dr_run9342() { rm -f "$dr9342/cache".*; rm -rf "$dr9342/cache.run"; cpu9342 "$dr9342/line" env SPIN="$1" TICK_DOCTOR_WAIT_SEC=30 TICK_DOCTOR_CMD="$dr9342/doctor" TICK_DOCTOR_CACHE="$dr9342/cache" bash "$SUT"; }
rm -f "$dr9342/cache"
dr_base9342="$(dr_run9342 '')"
same 'the control tick harvests the doctor run' "$(doctor_of < "$dr9342/line")" 'C9-spin'
rm -f "$dr9342/cache"
rm -f "$dr9342/nice"
dr_spin9342="$(NICE_OUT="$dr9342/nice" dr_run9342 1)"
same 'the spinning doctor run is harvested in the tick' "$(doctor_of < "$dr9342/line")" 'C9-spin'
if stub_niced_10_below_suite9342 "$dr9342/nice"; then pass 'the detached doctor run is niced below the tick'; else fail "the detached doctor run was not niced below the tick (nice '$(cat "$dr9342/nice" 2>/dev/null)')"; fi
same 'the doctor launch prints no pid line on the tick stdout' "$(grep -c '^[0-9][0-9]*$' "$dr9342/line")" '0'
if [ $((dr_spin9342 - dr_base9342)) -lt 1000 ]; then pass 'a harvested doctor run adds none of its CPU to the tick'; else fail "a harvested doctor run added $((dr_spin9342 - dr_base9342)) ms of CPU to the tick (spin ${dr_spin9342} ms, control ${dr_base9342} ms)"; fi

cg9342="$W/cg9342"; mkdir -p "$cg9342"
printf '%s\n' '#!/usr/bin/env bash' "$nice9342" "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'echo ciguard=ok' > "$cg9342/probe"
chmod +x "$cg9342/probe"
cg_run9342() { rm -rf "$cg9342/state"; mkdir -p "$cg9342/state"; cpu9342 "$cg9342/line" env SPIN="$1" TICK_STATE_DIR="$cg9342/state" TICK_SECTION_WAIT=30 TICK_CIGUARD_PROBE="$cg9342/probe" bash "$SUT"; }
cg_base9342="$(cg_run9342 '')"
contains 'the control tick serves the guardrail refresh' "$(cat "$cg9342/line")" ' ciguard=ok'
rm -f "$cg9342/nice"
cg_spin9342="$(NICE_OUT="$cg9342/nice" cg_run9342 1)"
contains 'the spinning guardrail refresh lands in the tick that launched it' "$(cat "$cg9342/line")" ' ciguard=ok'
if stub_niced_10_below_suite9342 "$cg9342/nice"; then pass 'a detached section refresh is niced below the tick'; else fail "a detached section refresh was not niced below the tick (nice '$(cat "$cg9342/nice" 2>/dev/null)')"; fi
if [ $((cg_spin9342 - cg_base9342)) -lt 1000 ]; then pass 'a section refresh the tick waits out adds none of its CPU to the tick'; else fail "a section refresh added $((cg_spin9342 - cg_base9342)) ms of CPU to the tick (spin ${cg_spin9342} ms, control ${cg_base9342} ms)"; fi

# The tick's wait for a refresh is CPU too. A wait that forks `date` and `sleep` on every
# 50 ms poll costs more CPU the longer the refresh runs, so on a loaded runner the row above
# failed with no refresh CPU in the tick. This row counts those forks, which load does not change:
# a refresh that sleeps 2 s (no CPU) must cost the tick no more than 15 more date/sleep calls.
wp9461="$W/wp9461"; mkdir -p "$wp9461/bin"
for wp_cmd9461 in date sleep; do
    printf '%s\n' '#!/usr/bin/env bash' "echo x >>\"$wp9461/calls\"" "exec $(command -v "$wp_cmd9461") \"\$@\"" > "$wp9461/bin/$wp_cmd9461"
    chmod +x "$wp9461/bin/$wp_cmd9461"
done
printf '%s\n' '#!/usr/bin/env bash' "[ -z \"\${WAIT:-}\" ] || $(command -v sleep) 2" 'echo ciguard=ok' > "$wp9461/probe"
chmod +x "$wp9461/probe"
wp_run9461() {  # wp_run9461 <WAIT>: how many date and sleep calls the whole tick made
    rm -rf "$wp9461/state"; mkdir -p "$wp9461/state"; : > "$wp9461/calls"
    env WAIT="$1" PATH="$wp9461/bin:$PATH" TICK_STATE_DIR="$wp9461/state" TICK_SECTION_WAIT=30 TICK_CIGUARD_PROBE="$wp9461/probe" bash "$SUT" > "$wp9461/line" 2>/dev/null
    wc -l < "$wp9461/calls" | tr -d ' '
}
wp_base9461="$(wp_run9461 '')"
contains 'the control tick serves the instant refresh' "$(cat "$wp9461/line")" ' ciguard=ok'
wp_wait9461="$(wp_run9461 1)"
contains 'the tick waited out the 2 s refresh' "$(cat "$wp9461/line")" ' ciguard=ok'
if [ $((wp_wait9461 - wp_base9461)) -le 15 ]; then pass 'the tick waits for a refresh without a date or sleep fork on every poll'; else fail "the wait for a 2 s refresh made $((wp_wait9461 - wp_base9461)) more date/sleep calls (wait ${wp_wait9461}, control ${wp_base9461})"; fi

# The dependabot sweep and the plan-index refresh are not waited on, but a tick that is still
# running when one ends reaps it all the same. Each stub child touches $HD_DONE as its last step;
# a stub `bun` (the tick's last slow step) holds the tick until that file exists (at most 15 s)
# and one second more, so the child ends inside the tick however loaded the host is.
hd9342="$W/hd9342"; mkdir -p "$hd9342/bin"
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
printf '%s\n' '#!/usr/bin/env bash' 'i=0; while [ ! -e "${HD_DONE:-/nonexistent}" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done; sleep 1' > "$hd9342/bin/bun"
chmod +x "$hd9342/bin/bun"
wait9342() {  # wait9342 <file>: up to 15 s for a file the detached child writes
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
}

db9342="$W/db9342"; mkdir -p "$db9342/state" "$W/repo/scripts/cr"
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
printf '%s\n' '#!/usr/bin/env bash' "$nice9342" "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'echo "dependabot-go sweep: merged=1 skipped=2"' 'touch "$HD_DONE"' > "$W/repo/scripts/cr/dependabot-go.sh"
db_run9342() {
    rm -rf "$db9342/state"; mkdir -p "$db9342/state"; rm -f "$db9342/done"
    cpu9342 "$db9342/line" env SPIN="$1" HD_DONE="$db9342/done" DEPENDABOT_AUTOLAND=on TICK_DBOT_MIN_SECS=0 TICK_STATE_DIR="$db9342/state" PATH="$hd9342/bin:$PATH" bash "$SUT"
}
db_base9342="$(db_run9342 '')"
contains 'the control tick launches the dependabot sweep' "$(cat "$db9342/line")" ' dbot=none,run'
rm -f "$db9342/nice"
db_spin9342="$(NICE_OUT="$db9342/nice" db_run9342 1)"
contains 'the spinning tick launches the dependabot sweep' "$(cat "$db9342/line")" ' dbot=none,run'
same 'the dependabot sweep ended before the spinning tick did' "$([ -e "$db9342/done" ] && echo yes || echo no)" 'yes'
if stub_niced_10_below_suite9342 "$db9342/nice"; then pass 'the detached dependabot sweep is niced below the tick'; else fail "the detached dependabot sweep was not niced below the tick (nice '$(cat "$db9342/nice" 2>/dev/null)')"; fi
wait9342 "$db9342/state"/tick-dbot-*.log
same 'the dependabot sweep still moves its tmp log to the log' "$(cat "$db9342/state"/tick-dbot-*.log 2>/dev/null)" 'dependabot-go sweep: merged=1 skipped=2'
if [ $((db_spin9342 - db_base9342)) -lt 1000 ]; then pass 'a dependabot sweep that ends inside the tick adds none of its CPU to the tick'; else fail "a dependabot sweep added $((db_spin9342 - db_base9342)) ms of CPU to the tick (spin ${db_spin9342} ms, control ${db_base9342} ms)"; fi

if command -v python3 >/dev/null 2>&1; then
    pi9342="$W/pi9342"; mkdir -p "$pi9342/plan" "$pi9342/mirror"
    printf '%s\n' '# chief' '' "tracker-plan: $pi9342/plan" '' '## Results (newest at the bottom)' > "$pi9342/chief.md"
    # shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
    printf '%s\n' '#!/usr/bin/env bash' "$nice9342" "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'touch "$HD_DONE"' 'exit 0' > "$pi9342/launcher"
    chmod +x "$pi9342/launcher"
    pi_run9342() {
        rm -rf "$pi9342/out"; rm -f "$pi9342/done"
        cpu9342 "$pi9342/line" env SPIN="$1" HD_DONE="$pi9342/done" TOKEN='' TICK_PLAN_INDEX_OUT="$pi9342/out" TICK_PLAN_INDEX_LAUNCHER="$pi9342/launcher" TICK_TRACKER_MIRROR_DIR="$pi9342/mirror" PATH="$hd9342/bin:$PATH" bash "$SUT" --doc "$pi9342/chief.md"
    }
    pi_base9342="$(pi_run9342 '')"
    contains 'the control tick launches the plan-index refresh' "$(cat "$pi9342/line")" ' plan-index=REFRESHING'
    rm -f "$pi9342/nice"
    pi_spin9342="$(NICE_OUT="$pi9342/nice" pi_run9342 1)"
    contains 'the spinning tick launches the plan-index refresh' "$(cat "$pi9342/line")" ' plan-index=REFRESHING'
    same 'the plan-index refresh ended before the spinning tick did' "$([ -e "$pi9342/done" ] && echo yes || echo no)" 'yes'
    if stub_niced_10_below_suite9342 "$pi9342/nice"; then pass 'the detached plan-index refresh is niced below the tick'; else fail "the detached plan-index refresh was not niced below the tick (nice '$(cat "$pi9342/nice" 2>/dev/null)')"; fi
    if [ $((pi_spin9342 - pi_base9342)) -lt 1000 ]; then pass 'a plan-index refresh that ends inside the tick adds none of its CPU to the tick'; else fail "a plan-index refresh added $((pi_spin9342 - pi_base9342)) ms of CPU to the tick (spin ${pi_spin9342} ms, control ${pi_base9342} ms)"; fi
else
    skip 'plan-index CPU row: no python3'
fi

# --- leg_forked: the root filter, the exact title match and a transcript grep reads as binary.
# leg_forked trusts only transcripts under its own root ($HOME/.claude/projects), though the
# title index also covers the codex root; and only a title that IS the worker name links one.
tf9342="$W/handover/HIMMEL-777-legN81.md"
printf '%s\n' '# worker' > "$tf9342"
tfh9342="$W/home9342"
tf_state9342() { ( unset TICK_PROJECTS_DIR; HOME="$tfh9342" bash "$SUT" --workers 'HIMMEL-777-legN81' 2>/dev/null | sed -nE 's/.* workers=([^ ]*).*/\1/p' ); }
tf_put9342() {  # tf_put9342 <root> <title> [<extra>]: a transcript that ended in continued-in
    mkdir -p "$tfh9342/$1/p"
    printf '{"type":"custom-title","customTitle":"%s"}\n%b{"type":"continued-in","sessionId":"s1"}\n' "$2" "${3:-}" > "$tfh9342/$1/p/s1.jsonl"
}
tf_put9342 .claude/projects HIMMEL-777-legN81
same 'a continued-in transcript under the worker title reads FORKED' "$(tf_state9342)" 'N81:FORKED'
rm -rf "$tfh9342"
mkdir -p "$tfh9342/.claude/projects"
tf_put9342 .claude-codex/projects HIMMEL-777-legN81
same 'a continued-in transcript outside the fork root is not FORKED' "$(tf_state9342)" 'N81:FREE'
rm -rf "$tfh9342"
tf_put9342 .claude/projects HIMMEL-777-legN81-extra
same 'a title that only starts with the worker name is not FORKED' "$(tf_state9342)" 'N81:FREE'
rm -rf "$tfh9342"
tf_put9342 .claude/projects xHIMMEL-777-legN81
same 'a title that only ends with the worker name is not FORKED' "$(tf_state9342)" 'N81:FREE'
rm -rf "$tfh9342"
tf_put9342 .claude/projects HIMMEL-777-legN81 '\0\n'
same 'a transcript with a NUL byte still links its title and reads FORKED' "$(tf_state9342)" 'N81:FORKED'
rm -rf "$tfh9342"

# --- parked=<worker>:<age>m: a worker on an unanswered permission prompt -----
# Absent unless a worker's newest trust-ledger row is a permission prompt older than
# TICK_PARKED_MIN; the rule itself is pinned by test-parked-on-prompt.sh.
pk_sid=33333333-3333-4333-8333-333333333333
printf -- '---\nsession_ids: %s\n---\n# worker\n- LIVE — working\n' "$pk_sid" > "$W/handover/HIMMEL-333-legN70.md"
parked_of() { bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null | sed -n -E 's/.* parked=([^ ]*).*/\1/p'; }
mkdir -p "$HIMMEL_TRUST_LEDGER_DIR"
pk_ts="$(date -u -d '-12 minutes' +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"ts":"%s","kind":"permission_request","session_id":"%s"}\n' "$pk_ts" "$pk_sid" > "$HIMMEL_TRUST_LEDGER_DIR/ledger.jsonl"
same 'parked= names a worker on an unanswered permission prompt' "$(parked_of)" 'HIMMEL-333-legN70:12m'
pk_out="$(bash "$SUT" --workers "$KP-333-legN70" 2>/dev/null)"
case "$pk_out" in *' vmrun='*' parked=HIMMEL-333-legN70:12m') pass 'parked= follows vmrun= and is the last field without flakes=/spare=' ;; *) fail "parked= position (out='$pk_out')" ;; esac
contains 'verbose labels the parked worker' "$(bash "$SUT" --workers "$KP-333-legN70" --verbose 2>/dev/null)" "parked on prompt: $KP-333-legN70:12m"
printf '{"ts":"%s","kind":"outcome","session_id":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$pk_sid" >> "$HIMMEL_TRUST_LEDGER_DIR/ledger.jsonl"
same 'parked= is absent once the prompt is answered' "$(parked_of)" ''

# --- station=BEHIND:<components>: the last station-sync.sh left a component behind main
station_of() { bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null | sed -n -E 's/.* station=([^ ]*).*/\1/p'; }
same 'station= is absent with no sync state' "$(station_of)" ''
printf 'ok\n' > "$TICK_STATION_STATE"
same 'station= is absent when the station is current' "$(station_of)" ''
printf 'BEHIND:luna_template,codex\n' > "$TICK_STATION_STATE"
same 'station= names the behind components' "$(station_of)" 'BEHIND:luna_template,codex'
contains 'verbose labels the behind station' "$(bash "$SUT" --workers "$KP-333-legN70" --verbose 2>/dev/null)" 'station: BEHIND:luna_template,codex'
rm -f "$TICK_STATION_STATE"

# --- alert-fail=<cadence>:<age>: cadence-alert.sh could not deliver a failure alert
alertfail_of() { bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null | sed -n -E 's/.* alert-fail=([^ ]*).*/\1/p'; }
same 'alert-fail= is absent with no marker' "$(alertfail_of)" ''
printf '%s focus-refresh exit-1\n' "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$CADENCE_ALERT_SEND_FAILED_MARK"  # gnu-ok: chief kit is Linux-only
same 'alert-fail= names the cadence and its age' "$(alertfail_of)" 'focus-refresh:3h'
contains 'verbose labels the failed alert' "$(bash "$SUT" --workers "$KP-333-legN70" --verbose 2>/dev/null)" 'alert-fail: focus-refresh:3h'
rm -f "$CADENCE_ALERT_SEND_FAILED_MARK"

mkdir -p "$W/qbin" "$W/noenv"
cat > "$W/qbin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${QSTUB_LOG:-/dev/null}"
case "${QSTUB_MODE:-}" in
    hung) exec sleep 600 ;;
    pr-limit)
        if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
            echo 'GraphQL: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
            exit 1
        fi ;;
    pr-hang)
        if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then exec sleep 600; fi ;;
    pr-resolve-read)
        if [ "${1:-}" = pr ] && [ "${2:-}" = list ] && [ "${GH_TOKEN:-}" = "${QSTUB_READ_TOKEN:-none}" ]; then
            echo "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)" >&2
            exit 1
        fi ;;
    pr-limit-read)
        if [ "${1:-}" = pr ] && [ "${2:-}" = list ] && [ "${GH_TOKEN:-}" = "${QSTUB_READ_TOKEN:-none}" ]; then
            echo 'GraphQL: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
            exit 1
        fi ;;
esac
exec "$W_GH" "$@"
STUB
chmod +x "$W/qbin/gh"
q_reset=$(( $(date +%s) + 1800 ))
q_hm="$(date -d "@$q_reset" +%H:%M)"  # gnu-ok: chief kit is Linux-only
q_tick() {
    local d="$1"; shift
    env W_GH="$W/bin/gh" PATH="$W/qbin:$PATH" GH_READ_ENV_ROOT="$W/noenv" HIMMEL_QUOTA_DIR="$d" QSTUB_LOG="$W/qstub.log" "$@" \
        timeout 100 bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null  # gnu-ok: chief kit is Linux-only (PLATFORM GUARD)
}
q_gql_out="HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: $q_reset\r\n\r\n"
: > "$W/qstub.log"
q_out="$(q_tick "$W/q-out" QSTUB_MODE=pr-limit STUB_GQL_OUT="$q_gql_out" STUB_GQL_RC=1)"
contains 'a refused GraphQL budget prints quota=main.graphql:0@<reset>' "$q_out" " quota=main.graphql:0@$q_hm"
contains 'a PR list refused on the main token reads prs=? beside a quota= that names the bucket' "$q_out" ' prs=? '
contains 'gql= still prints its value on the refused budget' "$q_out" " gql=0/$q_hm"
q_ok="$(q_tick "$W/q-ok")"
not_contains 'RED control: a healthy budget prints no quota=' "$q_ok" ' quota='
contains 'RED control: the healthy PR list still reads' "$q_ok" ' prs=#2247,#2250 '
mkdir -p "$W/q-seed"
printf 'main\tgraphql\t3333\t5000\t%s\t%s\tok\nmain\tcore\t4444\t5000\t%s\t%s\tok\n' "$q_reset" "$(date +%s)" "$q_reset" "$(date +%s)" > "$W/q-seed/quota.tsv"
: > "$W/qstub.log"
q_seed="$(q_tick "$W/q-seed")"
contains 'gql= renders from quota.tsv' "$q_seed" " gql=3333/$q_hm "
contains 'rest-main= renders from quota.tsv' "$q_seed" " rest-main=4444/5000@$q_hm "
case "$(grep -c -E '(^| )graphql( |$)|rateLimit|api -i user|api rate_limit' "$W/qstub.log")" in
    0) pass 'a fresh quota.tsv costs the tick no graphql or budget call of its own' ;;
    *) fail "the tick spent a budget call with a fresh quota.tsv (log: $(tr '\n' '|' < "$W/qstub.log"))" ;;
esac
reads_of() { printf '%s' "$1" | sed -n -E 's/.* reads=([^ ]*).*/\1/p'; }
contains 'reads= sits right after the rest budget fields' "$q_seed" " rest-main=4444/5000@$q_hm reads="
q_reads="$(reads_of "$q_ok")"
if grep -qE '^main:core[0-9]+\+gql[1-9][0-9]*,read:core0\+gql0$' <<< "$q_reads"; then pass 'the tick prints its own per-token read count (no read token: on main)'; else fail "reads= with no read token (got '$q_reads')"; fi
mkdir -p "$W/qenv" && printf 'himmel_github_token_vm2=readfixture0123\n' > "$W/qenv/.env" && : > "$W/outer-used"
q_reads="$(reads_of "$(q_tick "$W/q-rd" GH_READ_ENV_ROOT="$W/qenv" GH_READ_USED_FILE="$W/outer-used")")"
if grep -qE '^main:core0\+gql0,read:core[0-9]+\+gql[1-9][0-9]*$' <<< "$q_reads"; then pass 'the tick prints its own per-token read count (read token: on read)'; else fail "reads= with a read token (got '$q_reads')"; fi
same "a caller's own GH_READ_USED_FILE gets none of the tick's rows" "$(cat "$W/outer-used" 2>/dev/null)" ''
q_rt_default="$(q_tick "$W/q-rt" GH_READ_ENV_ROOT="$W/qenv" QSTUB_MODE=pr-resolve-read QSTUB_READ_TOKEN=readfixture0123)"
q_rt_reads="$(reads_of "$q_rt_default")"
if grep -qE '^main:core0\+gql1,read:core[0-9]+\+gql[1-9][0-9]*$' <<< "$q_rt_reads"; then pass 'a read retried on main counts once on main in reads='; else fail "reads= with one retried read (got '$q_rt_reads')"; fi
not_contains 'the default line names no retried read' "$q_rt_default" 'retried'
q_rt_verbose="$(env W_GH="$W/bin/gh" PATH="$W/qbin:$PATH" GH_READ_ENV_ROOT="$W/qenv" HIMMEL_QUOTA_DIR="$W/q-rt" QSTUB_LOG="$W/qstub.log" QSTUB_MODE=pr-resolve-read QSTUB_READ_TOKEN=readfixture0123 \
    timeout 100 bash "$SUT" --workers 'HIMMEL-333-legN70' --verbose 2>/dev/null)"  # gnu-ok: chief kit is Linux-only (PLATFORM GUARD)
contains 'verbose prints each read retried on main with its reason and what it read' "$q_rt_verbose" 'reads retried on main: notfound pr list --limit 200'
contains 'verbose prints the per-token read count' "$q_rt_verbose" 'reads: main:core0+gql1,read:core'
q_ok_verbose="$(env W_GH="$W/bin/gh" PATH="$W/qbin:$PATH" GH_READ_ENV_ROOT="$W/qenv" HIMMEL_QUOTA_DIR="$W/q-rt" QSTUB_LOG="$W/qstub.log" \
    timeout 100 bash "$SUT" --workers 'HIMMEL-333-legN70' --verbose 2>/dev/null)"  # gnu-ok: chief kit is Linux-only (PLATFORM GUARD)
not_contains 'RED control: a tick with no retried read prints no retried line' "$q_ok_verbose" 'reads retried on main:'
: > "$W/qstub.log"
q_t0=$SECONDS
q_hung="$(q_tick "$W/q-hung" QSTUB_MODE=hung GHQ_PROBE_TIMEOUT=2)"
q_hung_s=$((SECONDS - q_t0))
case "$q_hung" in TICK*) pass 'a hung gh still prints a TICK line by itself' ;; *) fail "a hung gh printed no TICK line (out='$q_hung')" ;; esac
contains 'a probe that timed out reads quota=main.graphql:stall' "$q_hung" ' quota=main.graphql:stall'
contains 'a probe that timed out leaves prs=?' "$q_hung" ' prs=? '
[ "$q_hung_s" -lt 60 ] && pass "a hung gh ends the tick in ${q_hung_s}s, inside the waiter's 120 s kill" || fail "a hung gh took ${q_hung_s}s"
case "$(wc -l < "$W/qstub.log" | tr -d '[:space:]')" in  # read-sink-ok: this suite's own stub log
    1) pass 'the stub log holds the one probe and no router read after it' ;;
    *) fail "a router read followed the timed-out probe (log: $(tr '\n' '|' < "$W/qstub.log"))" ;;
esac
: > "$W/qstub.log"
q_hang="$(q_tick "$W/q-prhang" QSTUB_MODE=pr-hang GH_READ_TIMEOUT=2)"
contains 'a PR list the router timed out reads quota=main.graphql:stall' "$q_hang" ' quota=main.graphql:stall'
contains 'a PR list the router timed out leaves prs=?' "$q_hang" ' prs=? '
not_contains 'no dispatch read follows a PR list the router timed out' "$(cat "$W/qstub.log")" 'actions/runs'
not_contains 'no ci-red read follows a PR list the router timed out' "$(cat "$W/qstub.log")" 'issue list'
: > "$W/qstub.log"
q_cut="$(q_tick "$W/q-prcut" QSTUB_MODE=pr-hang TICK_DEADLINE_SEC=8)"
contains 'a PR list the tick cut with its own timeout reads quota=main.graphql:stall' "$q_cut" ' quota=main.graphql:stall'
contains 'a PR list the tick cut with its own timeout leaves prs=?' "$q_cut" ' prs=? '
not_contains 'no dispatch read follows a PR list the tick cut' "$(cat "$W/qstub.log")" 'actions/runs'
not_contains 'no ci-red read follows a PR list the tick cut' "$(cat "$W/qstub.log")" 'issue list'
mkdir -p "$W/q-readroot"
printf 'himmel_github_token_vm2=ghp_TICKTEST0123456789\n' > "$W/q-readroot/.env"  # gitleaks:allow fixture token
: > "$W/qstub.log"
q_fb="$(q_tick "$W/q-fb" GH_READ_ENV_ROOT="$W/q-readroot" QSTUB_MODE=pr-limit-read QSTUB_READ_TOKEN=ghp_TICKTEST0123456789)"
contains 'a PR list the read token had refused names quota=read.graphql' "$q_fb" ' quota=read.graphql:'
contains 'a PR list the read token had refused reads prs=?, not the main token answer' "$q_fb" ' prs=? '
case "$(grep -c '^pr list' "$W/qstub.log")" in
    1) pass 'a rate-limited read token is not retried on main' ;;
    *) fail "the PR list was read more than once (log: $(tr '\n' '|' < "$W/qstub.log"))" ;;
esac
seed_floor() {
    local d="$1" rem="$2" now
    now="$(date +%s)"
    mkdir -p "$d"
    printf 'main\tgraphql\t%s\t5000\t%s\t%s\tok\nmain\tcore\t4000\t5000\t%s\t%s\tok\n' "$rem" "$q_reset" "$now" "$q_reset" "$now" > "$d/quota.tsv"
}
seed_floor "$W/q-low" 200
contains 'a bucket under the floor prints quota=main.graphql:200@<reset>' "$(q_tick "$W/q-low")" " quota=main.graphql:200@$q_hm"
seed_floor "$W/q-edge" 500
not_contains 'RED control: a bucket at the floor prints no quota=' "$(q_tick "$W/q-edge")" ' quota='
PW="$W/pw-mirror/HIMMEL"; mkdir -p "$PW"
printf -- '---\nkey: "HIMMEL-951"\ntype: "Task"\nstatus: "In Progress"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-951: an orphan\n\n## Description\n\nEdit scripts/lib/pw-orphan.sh.\n' > "$PW/HIMMEL-951.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/pw-gh"; chmod +x "$W/pw-gh"
{ git init -q -b main "$W/pw-main" && git -C "$W/pw-main" -c user.name=t -c user.email=t@e.x -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init; } \
    || fail "the pw-main fixture repo could not be created"
pw_tick() { # <graphql remaining in the seeded quota.tsv>: orphans-wip= of one tick whose resume scan runs to its end
    local d="$W/pw-$1"
    rm -rf "$d"; seed_floor "$d/quota" "$1"
    TICK_SECTION_WAIT=60 TICK_POOL_WAIT=0 TICK_STATE_DIR="$d/state" HIMMEL_QUOTA_DIR="$d/quota" GH_READ_ENV_ROOT="$W/noenv" \
        NEXT_DISPATCH_MIRROR="$PW" NEXT_DISPATCH_GH_CMD="$W/pw-gh" NEXT_DISPATCH_GIT_DIR="$W/pw-main" NEXT_DISPATCH_MAIN_REF=main \
        timeout 100 bash "$SUT" 2>/dev/null | tr ' ' '\n' | sed -n 's/^orphans-wip=//p'  # gnu-ok: chief kit is Linux-only (PLATFORM GUARD)
}
same 'a resume scan the dispatcher paused on quota reads orphans-wip=?, not 0' "$(pw_tick 100)" '?'
same 'RED control: a healthy resume scan still counts the orphan' "$(pw_tick 4000)" '1:HIMMEL-951'
pd_pause_out="$(printf '# quota-pause QUOTA-PAUSE github graphql token=main remaining=0 floor=500 reset=unknown caller=next-dispatchable nothing-was-judged\n' | bash "$SUT" --pool-dispositions 2>/dev/null)"
same '--pool-dispositions reads a paused snapshot as pool unknown' "$(printf '%s\n' "$pd_pause_out" | grep '^# pool-counts')" '# pool-counts ?'
pd_stall_out="$(printf '# gh-stall GH-STALL github read timed out after 400s token=main caller=next-dispatchable nothing-was-judged\n' | bash "$SUT" --pool-dispositions 2>/dev/null)"
same '--pool-dispositions reads a stalled snapshot as pool unknown' "$(printf '%s\n' "$pd_stall_out" | grep '^# pool-counts')" '# pool-counts ?'

PS_DOC="$W/ps-doc/HIMMEL-nextleg-2026-11-11A-chief.md"; mkdir -p "${PS_DOC%/*}"
printf '# chief\n\n## Live state\n\npool-disposition: HIMMEL-952 slice blocked on PR 77\n\n## Results\n' > "$PS_DOC"
cat > "$W/ps-gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PS_GH_LOG"
case "$*" in *"api graphql"*"p77:issueOrPullRequest(number:77)"*) printf '{"data":{"repository":{"p77":{"__typename":"PullRequest","state":"MERGED"}}}}\n' ;; esac
STUB
chmod +x "$W/ps-gh"
ps_run() {
    local d="$W/ps-$1" rc
    rm -rf "$d"; seed_floor "$d" "$1"; : > "$W/ps-gh.log"
    HIMMEL_QUOTA_DIR="$d" TICK_GH_CMD="$W/ps-gh" PS_GH_LOG="$W/ps-gh.log" NEXT_DISPATCH_MIRROR="$PW" \
        bash "$SUT" --pool-holds --doc "$PS_DOC" --repo "$W/pw-main" > /dev/null 2>&1
    rc=$?
    NEXT_DISPATCH_MIRROR="$PW" bash "$SUT" --pool-stale --doc "$PS_DOC" --repo "$W/pw-main" 2>/dev/null
    return "$rc"
}
ps_out="$(ps_run 100)"; ps_rc=$?
same 'a paused GitHub skips the pool-holds PR read: exit 0 and pool-stale=?' "$ps_rc:$(printf '%s\n' "$ps_out" | sed -n 's/^pool-stale=//p')" '0:?'
same 'a paused GitHub makes no pool-holds gh call' "$(wc -l < "$W/ps-gh.log" | tr -d ' ')" '0'
same 'RED control: a healthy budget judges the merged PR stale' "$(ps_run 4000 | sed -n 's/^pool-stale=//p')" '1:HIMMEL-952'
st_tick() {
    local d="$W/st-$1"
    rm -rf "$d"; seed_floor "$d" "$1"
    printf '2887:conflict' > "$W/stall-q.cache"; touch -d '3 hours ago' "$W/stall-q.cache"
    : > "$W/qstub.log"
    q_tick "$d" TICK_STALL_PROBE="$HERE/pr-stall.sh" TICK_STALL_CACHE="$W/stall-q.cache" TICK_STALL_TTL_MIN=60 | stall_of
}
same 'a paused pr-stall keeps the cached stall=' "$(st_tick 100)" '2887:conflict'
not_contains 'a paused pr-stall makes no PR list call' "$(cat "$W/qstub.log")" 'mergeStateStatus,statusCheckRollup'
st_tick 4000 > /dev/null
contains 'RED control: a healthy pr-stall reads its PR list' "$(cat "$W/qstub.log")" 'mergeStateStatus,statusCheckRollup'

AR_DOC="$W/ar-doc/HIMMEL-ar-chief.md"; mkdir -p "${AR_DOC%/*}"; printf '# chief\n' > "$AR_DOC"
ar_ev() { printf '{"ts":"%sT10:00:00.000Z","kind":"ruled","key":"%s","from":null,"to":"v9.9.9","ruling":"R-v9.9.9-%s","readback":"ok"}\n' "$1" "$2" "$3"; }
ar_rq() { printf '{"verb":"INTAKE","key":"%s","from_v":null,"to_v":"v9.9.9","why":"%s","evidence":%s,"from":"console","req":"Q-%s","ts":"2026-11-24T10:00:00.000Z","state":"ruled:R-v9.9.9-%s"}\n' "$1" "$2" "$3" "$4" "$4"; }
ar_build() {
    local d="$1" n=0 day i p r o
    rm -rf "$d"; mkdir -p "$d/v9.9.9"; : > "$d/v9.9.9/events.jsonl"; : > "$d/v9.9.9/requests.jsonl"
    for day in 2026-11-19:2 2026-11-20:3 2026-11-21:2 2026-11-22:3 2026-11-23:2; do
        for ((i = 0; i < ${day#*:}; i++)); do n=$((n + 1)); ar_ev "${day%:*}" "HIMMEL-9$n" "$n" >> "$d/v9.9.9/events.jsonl"; done
    done
    IFS=: read -r p r o <<< "$2"
    for ((i = 0; i < p; i++)); do n=$((n + 1)); ar_ev 2026-11-24 "HIMMEL-9$n" "$n" >> "$d/v9.9.9/events.jsonl"; ar_rq "HIMMEL-9$n" 'follow-up of HIMMEL-1 (To Do)' '{"follow_up_of":"HIMMEL-1"}' "$n" >> "$d/v9.9.9/requests.jsonl"; done
    for ((i = 0; i < r; i++)); do n=$((n + 1)); ar_ev 2026-11-24 "HIMMEL-9$n" "$n" >> "$d/v9.9.9/events.jsonl"; ar_rq "HIMMEL-9$n" 'filed by the daily failure review' '{}' "$n" >> "$d/v9.9.9/requests.jsonl"; done
    for ((i = 0; i < o; i++)); do n=$((n + 1)); ar_ev 2026-11-24 "HIMMEL-9$n" "$n" >> "$d/v9.9.9/events.jsonl"; ar_rq "HIMMEL-9$n" 'operator decision 1' '{"authority":"operator","ref":"O-1"}' "$n" >> "$d/v9.9.9/requests.jsonl"; done
}
ar_tick() {
    TOKEN='' TICK_ARRIVALS_DIR="$1/v9.9.9" TICK_ARRIVALS_NOW=2026-11-24 TICK_STATE_DIR="$2" bash "$SUT" --doc "$AR_DOC" 2>/dev/null
}
ar_build "$W/ar-jump" 6:4:2
ar_jump="$(ar_tick "$W/ar-jump" "$W/ar-state-jump")"
same 'a jump in arrivals prints exactly one WAKE arrivals-jump line' "$(printf '%s\n' "$ar_jump" | grep -c '^WAKE arrivals-jump ')" '1'
contains 'the jump wake names the version and each source group with its count' "$ar_jump" 'WAKE arrivals-jump v9.9.9 12 vs 2.4/day over 5d: parent=6 review=4 operator=2'
contains 'the jump marks the arrivals= field with !' "$ar_jump" ' arrivals=12/2.4!'
same 'the same UTC day wakes once: a second tick prints no second wake' "$(ar_tick "$W/ar-jump" "$W/ar-state-jump" | grep -c '^WAKE arrivals-jump ')" '0'
ar_build "$W/ar-jump2" 6:4:2
same 'a jump in another release directory the same day still wakes: the claim is per release' "$(ar_tick "$W/ar-jump2" "$W/ar-state-jump" | grep -c '^WAKE arrivals-jump ')" '1'
ar_build "$W/ar-steady" 3:0:0
ar_steady="$(ar_tick "$W/ar-steady" "$W/ar-state-steady")"
not_contains 'steady days print no arrivals wake' "$ar_steady" 'WAKE arrivals-jump'
contains 'steady days print arrivals=<n>/<mean>' "$ar_steady" ' arrivals=3/2.4'
not_contains 'steady days leave the arrivals= field unmarked' "$ar_steady" ' arrivals=3/2.4!'
mkdir -p "$W/ar-new/v9.9.9"; : > "$W/ar-new/v9.9.9/events.jsonl"
for ar_i in $(seq 1 10); do ar_ev 2026-11-24 "HIMMEL-8$ar_i" "$ar_i" >> "$W/ar-new/v9.9.9/events.jsonl"; done
ar_new="$(ar_tick "$W/ar-new" "$W/ar-state-new")"
not_contains 'a version with no earlier days has no baseline and wakes nothing' "$ar_new" 'WAKE arrivals-jump'
contains 'a version with no earlier days reads arrivals=<n>/?' "$ar_new" ' arrivals=10/?'
mkdir -p "$W/ar-big/v9.9.9"; : > "$W/ar-big/v9.9.9/events.jsonl"
for ar_d in 2026-11-19 2026-11-20 2026-11-21 2026-11-22 2026-11-23; do for ar_i in $(seq 1 30); do ar_ev "$ar_d" "HIMMEL-5${ar_d#2026-11-}-$ar_i" "5$ar_i" >> "$W/ar-big/v9.9.9/events.jsonl"; done; done
for ar_i in $(seq 1 40); do ar_ev 2026-11-24 "HIMMEL-4$ar_i" "4$ar_i" >> "$W/ar-big/v9.9.9/events.jsonl"; done
not_contains 'RED control: 40 against a version that files 30 a day is no jump (the bar is relative, not a count)' "$(ar_tick "$W/ar-big" "$W/ar-state-big")" 'WAKE arrivals-jump'
for ar_i in $(seq 41 100); do ar_ev 2026-11-24 "HIMMEL-4$ar_i" "4$ar_i" >> "$W/ar-big/v9.9.9/events.jsonl"; done
contains 'the same version at 100 a day against 30 is a jump' "$(ar_tick "$W/ar-big" "$W/ar-state-big2")" 'WAKE arrivals-jump v9.9.9 100 vs 30/day over 5d'
ar_before="$(cksum "$W/ar-jump/v9.9.9/"* | tr -d '\n')"
ar_tick "$W/ar-jump" "$W/ar-state-jump2" > /dev/null
same 'a tick with the jump wake active writes nothing under the release records' "$(cksum "$W/ar-jump/v9.9.9/"* | tr -d '\n')" "$ar_before"
same 'no jira create path reads the arrivals wake, so a filing is never refused or slowed by it' "$(git -C "$HERE" grep -l -e 'arrivals-jump' -e 'tick-arrivals' -- ../../jira/src ../../jira/package.json | wc -l | tr -d ' ')" '0'

# The waiter's wake key is the key rows of the table that its loop selects. The loop line must be this
# one exactly, so an edit anywhere in it (a condition inside the awk, a filter after it) leaves the list empty.
IFS= read -r q_loop <<'LOOP'
for f in $(awk -F'\t' '$0 !~ /^#/ && $5 == "key" && $1 != "usage" { print $1 }' "$HERE/wake-rules.tsv"); do
LOOP
# shellcheck disable=SC2016  # the text searched for is the loop's own, not an expansion
q_have="$(grep -F -e 'for f in $(awk' "$HERE/chief-wait.sh" | sed -E 's/^[[:space:]]+//')"
q_key_line=""
if [ "$q_have" = "$q_loop" ]; then
    # shellcheck disable=SC2016  # $4 is awk's field, not an expansion
    q_prog="$(printf '%s' "$q_loop" | awk -F"'" '{ print $4 }')"
    q_key_line=" $(awk -F'\t' "$q_prog" "$HERE/wake-rules.tsv" | tr '\n' ' ')"
fi
[ -n "$q_key_line" ] && pass "chief-wait's key field list is found" || fail "chief-wait's key field list moved"
for q_field in workers livestate prs tails acts vmrun; do
    contains "chief-wait's key field list holds $q_field" "$q_key_line" " $q_field "
done
not_contains "chief-wait's key field list gains no quota" "$q_key_line" 'quota'

fr_build="$W/fr-build.py"
cat > "$fr_build" <<'PY'
import json, socket, sys
bucket, target, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
host = socket.gethostname()
boot = open('/proc/sys/kernel/random/boot_id').read().strip()
def ident(pid, dead):
    if dead:
        return {'host': host, 'boot': boot, 'pid': pid, 'start': '1'}
    start = open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()[19]
    return {'host': host, 'boot': boot, 'pid': pid, 'start': start}
attempts = {}
for spec in sys.argv[4:]:
    aid, kind, pid = spec.split(':')
    pid = int(pid)
    attempts[aid] = {'attempt_id': aid, 'phase': 'launched', 'doc': bucket + '/' + aid + '.md', 'name': 'HIMMEL-' + aid,
                     'keys': [], 'manifest': bucket + '/chief.fleet.json', 'family': 'fam', 'control_generation': 1,
                     'owner': ident(pid, True), 'session': ident(pid, kind == 'dead'), 'began_ticks': 0, 'initial_marker': '',
                     'receipt': {'v': 2, 'kind': 'launch-attempt', 'attempt_id': aid}}
json.dump({'schema': 1, 'family': 'fam', 'mode': mode, 'generation': 1, 'target': target,
           'updated': '2026-11-26T00:00:00Z', 'reason': 'test', 'attempts': attempts}, open(bucket + '/fleet-control.json', 'w'))
json.dump({'schema': 1, 'workers': [], 'control': {'family': 'fam', 'anchor': bucket + '/fleet-control.json'}}, open(bucket + '/chief.fleet.json', 'w'))
PY
sleep 300 & fr_live=$!
{ true & fr_dead=$!; wait "$fr_dead"; } 2>/dev/null
fr_root="$(cd "$W" && pwd -P)"
fr_tick() {
    if [ "$2" = - ]; then
        STUB_FLEET_LINE="$1" TICK_LAUNCH_DIR="$W/no-launch-dir-fr" bash "$SUT" 2>/dev/null
    else
        STUB_FLEET_LINE="$1" TICK_LAUNCH_DIR="$W/no-launch-dir-fr" bash "$SUT" --workers-from "$2" 2>/dev/null
    fi
}
fr_census='bank-preflight: FLEET native=31 claudex=0 openrouter=0 reserved=0 total=31/50'
mkdir -p "$fr_root/fr-low" "$fr_root/fr-eq" "$fr_root/fr-high"
python3 -I "$fr_build" "$fr_root/fr-low" 35 active "live1:live:$fr_live"
python3 -I "$fr_build" "$fr_root/fr-eq" 50 active "live1:live:$fr_live"
python3 -I "$fr_build" "$fr_root/fr-high" 60 active "live1:live:$fr_live"
fr_low="$(fr_tick "$fr_census" "$fr_root/fr-low/chief.fleet.json")"
contains 'a family target of 35 under a policy cap of 50 reads fleet=<live>/35' "$fr_low" ' fleet=31/35'
contains 'the line names the policy cap beside the family target' "$fr_low" 'policy-cap=50'
contains 'capacity= is held to the family target too: 35 minus 31 live' "$fr_low" 'capacity=UNDERFILLED:4'
fr_eq="$(fr_tick "$fr_census" "$fr_root/fr-eq/chief.fleet.json")"
contains 'control: a target equal to the policy cap keeps fleet=<live>/<cap>' "$fr_eq" ' fleet=31/50 '
not_contains 'control: no policy-cap note when the target equals the cap' "$fr_eq" 'policy-cap'
contains 'control: capacity= still reads against the cap' "$fr_eq" 'capacity=UNDERFILLED:19'
fr_high="$(fr_tick "$fr_census" "$fr_root/fr-high/chief.fleet.json")"
contains 'a target above the policy cap leaves the policy cap the effective cap' "$fr_high" ' fleet=31/50 '
fr_none="$(fr_tick "$fr_census" -)"
contains 'no manifest: fleet= reads the census cap unchanged' "$fr_none" ' fleet=31/50 '
not_contains 'no manifest: no stale-attempts field' "$fr_none" 'stale-attempts'
printf '%s\n' '{"schema":1,"workers":[]}' > "$fr_root/fr-unbound.fleet.json"
fr_unbound="$(fr_tick "$fr_census" "$fr_root/fr-unbound.fleet.json")"
contains 'an unmanaged manifest (no control reference): fleet= reads the census cap unchanged' "$fr_unbound" ' fleet=31/50 '
not_contains 'an unmanaged manifest: no stale-attempts field' "$fr_unbound" 'stale-attempts'
contains 'only live records: stale-attempts=0' "$fr_low" 'stale-attempts=0'
not_contains 'only live records: no stale-attempts wake line' "$fr_low" 'ACTION stale-attempts'
mkdir -p "$fr_root/fr-stale"
python3 -I "$fr_build" "$fr_root/fr-stale" 35 active "live1:live:$fr_live" "gone1:dead:$fr_dead"
fr_before="$(cksum "$fr_root/fr-stale/fleet-control.json" "$fr_root/fr-stale/chief.fleet.json" | tr -d '\n')"
fr_stale="$(fr_tick "$fr_census" "$fr_root/fr-stale/chief.fleet.json")"
contains 'one launched record whose session is gone: stale-attempts=1' "$fr_stale" 'stale-attempts=1'
contains 'a wake line names fleet-manifest.sh runtime ack' "$fr_stale" 'ACTION stale-attempts=1:'
contains 'the wake line points at the read-only ack listing' "$fr_stale" 'fleet-manifest.sh runtime ack --read-only --manifest'
same 'a tick settles and edits no record: fleet-control.json and the manifest are byte-identical' "$(cksum "$fr_root/fr-stale/fleet-control.json" "$fr_root/fr-stale/chief.fleet.json" | tr -d '\n')" "$fr_before"
kill "$fr_live" 2>/dev/null

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-fields.sh'
    exit 0
fi
printf 'FAIL - test-tick-fields.sh (%s failure(s))\n' "$fails"
exit 1
