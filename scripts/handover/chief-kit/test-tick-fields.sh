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

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
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
same 'fails=? when the chief lock has no readable start (HIMMEL-4670)' "$(fails_of "$d4670_free")" '?'
{
    frow 2026-10-07T02:59:59Z N1 denied/old-shift 9
    frow 2026-10-07T03:05:00Z N1 denied/guard-a 2 true
    frow 2026-10-07T03:06:00Z N2 denied/guard-a 3 false
    frow 2026-10-07T03:07:00Z N2 suite/test-x.sh 7
    printf 'not json\n'
} > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails= counts this shift only: rows, distinct workers, top class by workers (HIMMEL-4670)' "$(fails_of "$d4670")" '3/2@denied/guard-a*2'
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
same 'fails= !<recur> = distinct classes the router did not skip this shift (HIMMEL-4670)' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
printf '%s\n' '{"ts":"2026-10-07T03:20:00Z","eval":"leg-trajectory","status":"inconclusive","meta":{"digest_error":"timeout"}}' > "$HIMMEL_EVAL_RUNS_LEDGER"
same 'fails=? when the latest wrap digest this shift failed (HIMMEL-4670)' "$(fails_of "$d4670")" '?'
printf '%s\n' '{"ts":"2026-10-07T03:30:00Z","eval":"leg-trajectory","status":"ok","meta":{}}' >> "$HIMMEL_EVAL_RUNS_LEDGER"
same 'a later good digest clears fails=? (HIMMEL-4670)' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
printf '%s\n' '{"ts":"2026-10-07T02:30:00Z","eval":"leg-trajectory","status":"inconclusive","meta":{"digest_error":"crash"}}' > "$HIMMEL_EVAL_RUNS_LEDGER"
same 'a failed digest from before this shift does not read ? (HIMMEL-4670)' "$(fails_of "$d4670")" '3/2@denied/guard-a*2!2'
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"; mkdir -p "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails=? when the ledger is unreadable (HIMMEL-4670)' "$(fails_of "$d4670")" '?'
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
contains 'vmrun= follows fails= (HIMMEL-5037)' "$f4670" ' fails=1/1@error/Edit*1 vmrun=off'
case "$f4670" in *' vmrun='*' '*) fail "vmrun= is the last field when spare= is absent (out='$f4670')" ;; *) pass 'vmrun= is the last field when spare= is absent (HIMMEL-5037)' ;; esac
printf '#!/bin/sh\necho "garbage not a token"\n' > "$W/vmrun-probe-garbage.sh"
vmrun_garbage="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-garbage.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that prints a non-token reads vmrun=unknown (HIMMEL-5641)' "$vmrun_garbage" ' vmrun=unknown'
printf '#!/bin/sh\necho DISAGREE:2/2,online=0\n' > "$W/vmrun-probe-disagree.sh"
vmrun_disagree="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-disagree.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that reports units up with no runner online reads vmrun=DISAGREE (HIMMEL-6034)' "$vmrun_disagree" ' vmrun=DISAGREE:2/2,online=0'
printf '#!/bin/sh\necho DISAGREE:2/2,online=1\n' > "$W/vmrun-probe-partial.sh"
vmrun_partial="$(HIMMEL_VMRUN_PROBE="$W/vmrun-probe-partial.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that reports fewer runners online than registered units reads vmrun=DISAGREE:2/2,online=1 (HIMMEL-6034)' "$vmrun_partial" ' vmrun=DISAGREE:2/2,online=1'
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
contains 'a quiet guardrail prints ciguard=ok (HIMMEL-6733)' "$cig_ok" ' ciguard=ok'
not_contains 'a quiet guardrail prints no ACTION ci-guardrail line (HIMMEL-6733)' "$cig_ok" 'ACTION ci-guardrail'
calls="$(wc -l < "$cig_calls" | tr -d '[:space:]')"
if [ "$calls" = 1 ]; then pass 'one tick runs the guardrail exactly once (HIMMEL-6733)'; else fail "guardrail calls per tick = $calls, want 1"; fi
cig_over="$(cig_tick "$cig_alert")"
contains 'an OVER guardrail prints ciguard=OVER:<metric> (HIMMEL-6733)' "$cig_over" ' ciguard=OVER:runs-h'
contains 'one ALERT line prints an ACTION ci-guardrail line carrying it (HIMMEL-6733)' "$cig_over" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
case "$(printf '%s\n' "$cig_over" | grep -c '^ACTION ci-guardrail')" in 1) pass 'one ALERT line prints exactly one ACTION (HIMMEL-6733)' ;; *) fail 'one ALERT line prints exactly one ACTION (HIMMEL-6733)' ;; esac
case "$(printf '%s\n' "$cig_over" | grep -c '^TICK ')" in 1) pass 'the ciguard ACTION line adds no second TICK line (HIMMEL-6733)' ;; *) fail 'the ciguard ACTION line adds no second TICK line (HIMMEL-6733)' ;; esac
cig_two="$(cig_tick $'ciguard=OVER:runs-h,reruns-h\nALERT runs-h=160>150 (14:00)\nALERT reruns-h=11>10 (14:00)')"
case "$(printf '%s\n' "$cig_two" | grep -c '^ACTION ci-guardrail')" in 2) pass 'two ALERT lines print two ACTION lines (HIMMEL-6733)' ;; *) fail 'two ALERT lines print two ACTION lines (HIMMEL-6733)' ;; esac
cig_a="$(cig_tick "$cig_alert")"
cig_b="$(STUB_CIG_CALLS="$cig_calls" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_OUT="$cig_alert" STUB_CIG_OUT2='ciguard=OVER:runs-h' bash "$SUT" 2>/dev/null)"
contains 'the first read of a crossing prints its ACTION (HIMMEL-6733)' "$cig_a" 'ACTION ci-guardrail runs-h=160>150'
not_contains 'the next read of the same crossing prints no ACTION (HIMMEL-6733)' "$cig_b" 'ACTION ci-guardrail'
contains 'the next read of the same crossing still shows ciguard=OVER (HIMMEL-6733)' "$cig_b" ' ciguard=OVER:runs-h'
cig_unk="$(cig_tick 'ciguard=unknown')"
contains 'an unknown guardrail prints ciguard=unknown (HIMMEL-6733)' "$cig_unk" ' ciguard=unknown'
not_contains 'an unknown guardrail prints no ACTION ci-guardrail line (HIMMEL-6733)' "$cig_unk" 'ACTION ci-guardrail'
cig_junk="$(cig_tick 'ALERT runs-h=160>150 (14:00)')"
contains 'output with no status line reads ciguard=unknown (HIMMEL-6733)' "$cig_junk" ' ciguard=unknown'
not_contains 'an ALERT with no status line prints no ACTION (HIMMEL-6733)' "$cig_junk" 'ACTION ci-guardrail'
cig_miss="$(TICK_CIGUARD_PROBE="$W/no-such-probe" bash "$SUT" 2>/dev/null)"
contains 'a missing guardrail script reads ciguard=unknown (HIMMEL-6733)' "$cig_miss" ' ciguard=unknown'
cig_verbose="$(cig_tick "$cig_alert" --verbose)"
contains 'verbose output names the ci guardrail reading (HIMMEL-6733)' "$cig_verbose" 'ci guardrail: OVER:runs-h'
contains 'verbose output keeps the new ALERT line (HIMMEL-6733)' "$cig_verbose" 'ALERT runs-h=160>150 (14:00)'

# --- the guardrail reads through a cache a detached refresh fills.
# A refresh still running would write into the next row's fixture, so each row waits it out.
bud_fresh() { [ ! -e "$W/bud/tick-ciguard-last.lock" ] || flock "$W/bud/tick-ciguard-last.lock" true; rm -rf "$W/bud"; mkdir -p "$W/bud"; : > "$cig_calls"; }
bud_tick() { TICK_STATE_DIR="$W/bud" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_CALLS="$cig_calls" bash "$SUT" 2>/dev/null; }
if [ -n "$_TIMEOUT_BIN" ]; then
    bud_fresh
    t0="$(date +%s)"
    bud_hung="$(TICK_CIGUARD_TIMEOUT=2 STUB_CIG_SLEEP=30 TICK_SECTION_WAIT=1 STUB_CIG_OUT="$cig_alert" bud_tick)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung guardrail costs the tick only its short wait (HIMMEL-8735)'; else fail "a hung guardrail held the tick $((t1 - t0))s (HIMMEL-8735)"; fi
    contains 'a hung guardrail still yields the worker state (HIMMEL-8735)' "$bud_hung" ' workers=N61:FRESH'
    contains 'a hung guardrail with no cache reads ciguard=unknown (HIMMEL-8735)' "$bud_hung" ' ciguard=unknown'
    not_contains 'no cache means no ciguard-age field (HIMMEL-8735)' "$bud_hung" 'ciguard-age='

    bud_fresh
    bud_kill="$(TICK_CIGUARD_TIMEOUT=1 STUB_CIG_SLEEP=30 STUB_CIG_OUT="$cig_alert" bud_tick)"
    contains 'a refresh past its bound leaves ciguard=unknown (HIMMEL-8735)' "$bud_kill" ' ciguard=unknown'
    bud_kill2="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT="$cig_alert" bud_tick)"
    same 'a failed refresh is not retried inside the cadence (HIMMEL-8735)' "$(wc -l < "$cig_calls" | tr -d '[:space:]')" 1
    contains 'a failed refresh still reads ciguard=unknown on the next tick (HIMMEL-8735)' "$bud_kill2" ' ciguard=unknown'

    bud_fresh
    bud_late="$(TICK_SECTION_WAIT=0 STUB_CIG_SLEEP=2 STUB_CIG_OUT="$cig_alert" bud_tick)"
    not_contains 'a refresh still running shows no ACTION yet (HIMMEL-8735)' "$bud_late" 'ACTION ci-guardrail'
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/bud/tick-ciguard-last" ] && break; sleep 0.5; done
    bud_after="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT='ciguard=ok' bud_tick)"
    contains 'a refresh outlives the tick that launched it (HIMMEL-8735)' "$bud_after" ' ciguard=OVER:runs-h'
    contains 'the late refresh delivers its ALERT on the next tick (HIMMEL-8735)' "$bud_after" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
else
    skip 'guardrail refresh timing rows: no timeout binary'
fi

bud_fresh
bud_a="$(STUB_CIG_ENV="$W/bud-slice" STUB_CIG_OUT="$cig_alert" bud_tick)"
same 'the refresh widens the guardrail slice limit to 120 s (HIMMEL-8735)' "$(cat "$W/bud-slice")" 120
case "$(printf '%s\n' "$bud_a" | grep -c '^ACTION ci-guardrail')" in 1) pass 'the refreshing tick prints the crossing once (HIMMEL-8735)' ;; *) fail 'the refreshing tick prints the crossing once (HIMMEL-8735)' ;; esac
contains 'OVER shows in the TICK line the waiter reads (HIMMEL-8735)' "$(printf '%s\n' "$bud_a" | grep '^TICK ')" ' ciguard=OVER:runs-h'
contains 'a served guardrail result carries its age (HIMMEL-8735)' "$bud_a" ' ciguard-age='
touch -d '5 minutes ago' "$W/bud/tick-ciguard-last"  # gnu-ok: chief kit is Linux-only
bud_b="$(TICK_CIGUARD_MIN_SECS=3600 STUB_CIG_OUT='ciguard=ok' bud_tick)"
contains 'a tick inside the cadence serves the cached read (HIMMEL-8735)' "$bud_b" ' ciguard=OVER:runs-h ciguard-age=30'
not_contains 'a cached read never repeats its ALERT (HIMMEL-8735)' "$bud_b" 'ACTION ci-guardrail'
same 'a tick inside the cadence reads no guardrail (HIMMEL-8735)' "$(wc -l < "$cig_calls" | tr -d '[:space:]')" 1
bud_junk="$(STUB_CIG_OUT='not a status line' bud_tick)"
contains 'a junk refresh keeps the last good read and its age (HIMMEL-8735)' "$bud_junk" ' ciguard=OVER:runs-h ciguard-age=30'
touch -d '2 hours ago' "$W/bud/tick-ciguard-last"  # gnu-ok: chief kit is Linux-only
printf 'ALERT runs-h=160>150 (14:00)\n' > "$W/bud/tick-ciguard-last.alerts"
bud_old="$(TICK_CIGUARD_MIN_SECS=86400 TICK_STATE_DIR="$W/bud" TICK_CIGUARD_PROBE="$W/ciguard-probe.sh" STUB_CIG_CALLS="$cig_calls" flock -o "$W/bud/tick-ciguard-last.lock" bash "$SUT" 2>/dev/null)"
contains 'a cache past its TTL reads ciguard=unknown and shows its age (HIMMEL-8735)' "$bud_old" ' ciguard=unknown ciguard-age=72'
not_contains 'a tick leaves the ALERT queue alone while a refresh holds the lock (HIMMEL-8735)' "$bud_old" 'ACTION ci-guardrail'
printf 'garbage\n' > "$W/bud/tick-ciguard-last"
bud_bad="$(TICK_CIGUARD_MIN_SECS=86400 bud_tick)"
contains 'a corrupt cache reads ciguard=unknown (HIMMEL-8735)' "$bud_bad" ' ciguard=unknown'
contains 'the next tick delivers the queued ALERT (HIMMEL-8735)' "$bud_bad" 'ACTION ci-guardrail runs-h=160>150 (14:00): '
not_contains 'a corrupt cache carries no age (HIMMEL-8735)' "$bud_bad" 'ciguard-age='

# --- a tick past its deadline shortens the probes left, so it still answers.
printf '#!/bin/sh\nsleep 30\n' > "$W/hung-probe.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
    t0="$(date +%s)"
    bud_dl="$(TICK_DEADLINE_SEC=1 HIMMEL_VMRUN_PROBE="$W/hung-probe.sh" NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/hung-probe.sh" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'two hung sections past the deadline still return a tick (HIMMEL-8735)'; else fail "two hung sections held the tick $((t1 - t0))s (HIMMEL-8735)"; fi
    contains 'a deadline tick keeps the worker state (HIMMEL-8735)' "$bud_dl" ' workers=N61:FRESH'
    contains 'a section cut by the deadline reads its failure value (HIMMEL-8735)' "$bud_dl" ' vmrun=unknown'
    contains 'a tick past its deadline says so (HIMMEL-8735)' "$bud_dl" ' deadline-over='
else
    skip 'deadline rows: no timeout binary'
fi

printf '#!/bin/sh\necho 3\n' > "$W/vd-probe-3.sh"
printf '#!/bin/sh\necho 0\n' > "$W/vd-probe-0.sh"
printf '#!/bin/sh\necho oops\n' > "$W/vd-probe-bad.sh"
vd_three="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-3.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'versionless Done tickets show as versionless-done=<n> (HIMMEL-6406)' "$vd_three" ' vmrun=off versionless-done=3'
vd_zero="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$vd_zero" in *versionless-done*) fail "a clean project hides versionless-done (out='$vd_zero')" ;; *) pass 'a clean project hides versionless-done (HIMMEL-6406)' ;; esac
vd_bad="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-bad.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe that prints a non-count reads versionless-done=unknown (HIMMEL-6406)' "$vd_bad" ' versionless-done=unknown'
printf '#!/bin/sh\necho 1234+\n' > "$W/vd-probe-big.sh"
vd_big="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-big.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a lower-bound count of any width is shown as-is (HIMMEL-6406)' "$vd_big" ' versionless-done=1234+'
contains 'a non-zero versionless-done count prints an ACTION line (HIMMEL-6416)' "$vd_three" 'ACTION versionless-done=3: bash '
contains 'the ACTION line names versionless-done.sh --backfill (HIMMEL-6416)' "$vd_three" 'versionless-done.sh --backfill'
ln -s "$(dirname "$SUT")" "$W/vd dir"
vd_space="$(NEXT_DISPATCH_MIRROR="$W/vd-mirror" TICK_VERSIONLESS_DONE_PROBE="$W/vd-probe-3.sh" TOKEN='' bash "$W/vd dir/tick.sh" --doc "$d4670" 2>/dev/null)"
contains 'the ACTION line escapes a script path with a space (HIMMEL-6416)' "$vd_space" 'vd\ dir/versionless-done.sh --backfill'
case "$vd_zero$vd_bad" in *'ACTION versionless-done'*) fail "a zero or unknown count prints no ACTION line (out='$vd_zero$vd_bad')" ;; *) pass 'a zero or unknown count prints no ACTION line (HIMMEL-6416)' ;; esac
case "$(printf '%s\n' "$vd_three" | grep -c '^TICK ')" in 1) pass 'the ACTION line adds no second TICK line (HIMMEL-6416)' ;; *) fail 'the ACTION line adds no second TICK line (HIMMEL-6416)' ;; esac
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
contains 'a clean mirror reads vmismatch=0 (HIMMEL-6549)' "$vm_clean" ' vmismatch=0'
vm_mk HIMMEL-72 "In Progress" '["v1.0.2"]'
vm_one="$(vm_tick)"
contains 'one started later-version ticket reads vmismatch=1 (HIMMEL-6549)' "$vm_one" ' vmismatch=1'
vm_mk HIMMEL-77 "In Progress" '["v1.0.2"]'
vm_owned="$(vm_tick)"
contains 'a later-version ticket held by an open PR is not counted (HIMMEL-6549)' "$vm_owned" ' vmismatch=1'
rm -f "$vm_dir/HIMMEL.versions.tsv"
vm_bad="$(vm_tick)"
contains 'a failed audit read reads vmismatch=? (HIMMEL-6549)' "$vm_bad" ' vmismatch=?'
vm_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
not_contains 'no mirror hides vmismatch (HIMMEL-6549)' "$vm_skip" 'vmismatch'
if [ -n "$_TIMEOUT_BIN" ]; then
    printf '#!/bin/sh\nexec sleep 30\n' > "$W/vm-hung.sh"
    vm_t0="$(date +%s)"
    vm_hung="$(TICK_VMISMATCH_TIMEOUT=1 TICK_VMISMATCH_PROBE="$W/vm-hung.sh" vm_tick)"
    vm_t1="$(date +%s)"
    contains 'a hung audit reads vmismatch=? (HIMMEL-6549)' "$vm_hung" ' vmismatch=?'
    if [ $((vm_t1 - vm_t0)) -lt 15 ]; then pass 'a hung audit is cut off inside the bound (HIMMEL-6549)'; else fail "hung audit took $((vm_t1 - vm_t0))s"; fi
else
    skip 'audit timeout rows: no timeout binary'
fi
printf '#!/bin/sh\necho "vmismatch=0"\nexit 3\n' > "$W/vm-partial0.sh"
vm_partial0="$(TICK_VMISMATCH_PROBE="$W/vm-partial0.sh" vm_tick)"
contains 'an incomplete audit with no RESET row reads vmismatch=? (HIMMEL-6549)' "$vm_partial0" ' vmismatch=?'
printf '#!/bin/sh\nprintf "LATER-VERSION\\tHIMMEL-72\\tIn Progress\\tv1.0.2\\tnone\\tRESET\\nvmismatch=1\\n"\nexit 3\n' > "$W/vm-partial1.sh"
vm_partial1="$(TICK_VMISMATCH_PROBE="$W/vm-partial1.sh" vm_tick)"
contains 'an incomplete audit still reports the RESET rows it found (HIMMEL-6549)' "$vm_partial1" ' vmismatch=1'
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
contains 'leaked tickets of the frozen version read leaks=<n> (HIMMEL-7153)' "$lk_three" ' leaks=3'
case "$(cat "$W/lk-asked" 2>/dev/null)" in "v1.0.2 $lk_m") pass 'the probe is asked for the earliest unreleased, unarchived, non-zz version of the tick mirror (HIMMEL-7153)' ;; *) fail "the probe was asked '$(cat "$W/lk-asked" 2>/dev/null)', want 'v1.0.2 $lk_m' (HIMMEL-7153)" ;; esac
contains 'a non-zero leak count prints an ACTION line naming the comment run (HIMMEL-7153)' "$lk_three" 'ACTION leaks=3: JIRA_PROJECT_KEY=HIMMEL node '
contains 'the leaks ACTION line never names the global jira shim (HIMMEL-7153)' "$lk_three" '/scripts/jira/dist/index.js release leaks '
printf 'v1.0.2 beta\ttrue\t\tfalse\nv1.0.3 rc\tfalse\t\tfalse\n' > "$lk_dir/HIMMEL.versions.tsv"
lk_space="$(lk_tick "$W/lk-probe-3.sh")"
contains 'a version name with a space is escaped in the ACTION line (HIMMEL-7153)' "$lk_space" 'release leaks v1.0.3\ rc --mirror-root '
contains 'the leaks ACTION line names the version, the tick mirror and --comment (HIMMEL-7153)' "$lk_three" "release leaks v1.0.2 --mirror-root $lk_m --comment"
contains 'the leaks ACTION line keeps its explanation behind a shell comment (HIMMEL-7153)' "$lk_three" '--comment  # posts one comment per leak'
lk_other="$(REPO="$W/repo-other" lk_tick "$W/lk-probe-3.sh")"
not_contains 'the leaks ACTION line resolves the CLI from the tick checkout, not from --repo (HIMMEL-7153)' "$lk_other" "$W/repo-other/scripts/jira/dist/index.js"
contains 'a tick on another --repo still prints the leaks ACTION line (HIMMEL-7153)' "$lk_other" '/scripts/jira/dist/index.js release leaks '
lk_cli_of() { printf '%s\n' "$1" | sed -n 's/^ACTION leaks=[0-9]*: JIRA_PROJECT_KEY=[^ ]* node \([^ ]*\) release leaks .*/\1/p'; }
lk_cli_three="$(lk_cli_of "$lk_three")"
if [ -n "$lk_cli_three" ] && [ "$(lk_cli_of "$lk_other")" = "$lk_cli_three" ] && [ -e "${lk_cli_three%/scripts/jira/dist/index.js}/.git" ]; then pass 'the leaks ACTION line names the same primary-checkout CLI whatever --repo is (HIMMEL-7153)'; else fail "the leaks ACTION CLI is '$(lk_cli_of "$lk_other")' under --repo vs '$lk_cli_three' by default, want one primary checkout (HIMMEL-7153)"; fi
lk_fix="$W/lk-fix"; mkdir -p "$lk_fix/scripts/handover/chief-kit" "$lk_fix/scripts/lanes"
if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git init -q "$lk_fix"; then pass 'the missing-CLI fixture checkout initialised (HIMMEL-7153)'; else fail 'the missing-CLI fixture checkout failed git init, so its leaks=? row proves nothing (HIMMEL-7153)'; fi
cp "$SUT" "$lk_fix/scripts/handover/chief-kit/tick.sh"
cp -R "$HERE/../../lib" "$lk_fix/scripts/lib"
cp -R "$HERE/../../lanes/lib" "$lk_fix/scripts/lanes/lib"
lk_nodist="$(env -u TICK_LEAKS_PROBE NEXT_DISPATCH_MIRROR="$lk_m" TOKEN='' bash "$lk_fix/scripts/handover/chief-kit/tick.sh" --doc "$d4670" 2>/dev/null)"
contains 'a tick whose primary checkout has no built Jira CLI reads leaks=? (HIMMEL-7153)' "$lk_nodist" ' leaks=?'
not_contains 'a tick with no built Jira CLI prints no leaks ACTION line (HIMMEL-7153)' "$lk_nodist" 'ACTION leaks'
lk_zero="$(lk_tick "$W/lk-probe-0.sh")"
not_contains 'a clean version hides leaks (HIMMEL-7153)' "$lk_zero" 'leaks='
lk_unfrozen="$(lk_tick "$W/lk-probe-unfrozen.sh")"
not_contains 'an unfrozen active version hides leaks, it is not an error (HIMMEL-7153)' "$lk_unfrozen" 'leaks='
lk_err="$(lk_tick "$W/lk-probe-err.sh")"
contains 'a failed leak read reads leaks=? (HIMMEL-7153)' "$lk_err" ' leaks=?'
not_contains 'a failed leak read prints no ACTION line (HIMMEL-7153)' "$lk_err" 'ACTION leaks'
lk_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TICK_LEAKS_PROBE="$W/lk-probe-3.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
not_contains 'no mirror hides leaks (HIMMEL-7153)' "$lk_skip" 'leaks='
# --- cap=<version>:<n>[,...]: unreleased versions past 15 open residual slots, counted from the
# mirror as board.mjs counts them; absent at 15 or fewer.
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
cp_over="$(cp_tick)"
contains 'a version past 15 open residuals puts cap=<version>:<n> on the line (HIMMEL-6762)' "$cp_over" ' cap=v1.1.3:16'
not_contains 'a version at exactly 15 open residuals is not on the cap field, nor Done, Closed, unlabelled or a released version (HIMMEL-6762)' "$cp_over" 'v1.1.4:'
not_contains 'a released version past 15 is not on the cap field (HIMMEL-6762)' "$cp_over" 'v1.0.0:'
cp_mk "To Do" '["residual"]' '["v1.1.5"]' 17
contains 'two versions past 15 are both named, in version order (HIMMEL-6762)' "$(cp_tick)" ' cap=v1.1.3:16,v1.1.5:17'
rm -f "$cp_m/HIMMEL-1.md"
cp_fifteen="$(cp_tick)"
contains 'the other over-run stays on the field (HIMMEL-6762)' "$cp_fifteen" ' cap=v1.1.5:17'
not_contains 'a version dropping to exactly 15 open residuals leaves the cap field (HIMMEL-6762)' "$cp_fifteen" 'v1.1.3:'
rm -f "$cp_m"/HIMMEL-6[1-9].md "$cp_m"/HIMMEL-7[0-7].md
cp_none="$(cp_tick)"
not_contains 'no version past 15 leaves cap= off the line (HIMMEL-6762)' "$cp_none" 'cap='
cp_skip="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TICK_LEAKS_PROBE="$W/lk-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
not_contains 'no mirror leaves cap= off the line (HIMMEL-6762)' "$cp_skip" ' cap='
# Both brief templates file every follow-up with `jira create --follow-up-of <KEY>`.
for cp_tpl in worker-brief-template chief-template; do
    if grep -q -- 'jira create --follow-up-of <KEY>' "$HERE/../../../docs/handover/$cp_tpl.md"; then pass "docs/handover/$cp_tpl.md names jira create --follow-up-of <KEY> (HIMMEL-6762)"; else fail "docs/handover/$cp_tpl.md names jira create --follow-up-of <KEY> (HIMMEL-6762)"; fi
done
case "$vd_zero" in *wt-orphans*|*wt-ceiling*) fail "no worktree.sh under REPO reads no wt-orphans field (out='$vd_zero')" ;; *) pass 'no worktree.sh under REPO reads no wt-orphans field (HIMMEL-6584)' ;; esac
mkdir -p "$REPO"
printf '#!/bin/sh\nprintf "ORPHAN /w/a branch=x dirty=0 ahead=1 idle=2d\\nORPHAN /w/b branch=detached:0123456789ab dirty=1 ahead=0 idle=9h\\nCEILING 72/100 worktrees (alarm at 70)\\n"\nexit 1\n' > "$W/wto-probe-2.sh"
printf '#!/bin/sh\nexit 0\n' > "$W/wto-probe-0.sh"
printf '#!/bin/sh\necho "SWEEP-ERROR (prune --orphans) open-PR list unavailable"\nexit 1\n' > "$W/wto-probe-err.sh"
printf '#!/bin/sh\nexit 3\n' > "$W/wto-probe-crash.sh"
printf '#!/bin/sh\nexit 1\n' > "$W/wto-probe-silent1.sh"
wto_two="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'leftover worktrees show as wt-orphans=<n> (HIMMEL-6584)' "$wto_two" ' wt-orphans=2'
contains 'a live count at the alarm shows as wt-ceiling=<live>/<cap> (HIMMEL-6584)' "$wto_two" ' wt-ceiling=72/100'
wto_cache_f="$TICK_STATE_DIR/tick-wt-orphans-$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
if [ -s "$wto_cache_f" ]; then pass 'the reading is cached under a file keyed by REPO (HIMMEL-6584)'; else fail 'the reading is cached under a file keyed by REPO (HIMMEL-6584)'; fi
contains 'leftover worktrees print an ACTION line naming prune --orphans (HIMMEL-6584)' "$wto_two" 'ACTION wt-orphans=2 wt-ceiling=72/100: bash '
case "$(printf '%s\n' "$wto_two" | grep -c '^TICK ')" in 1) pass 'the wt-orphans ACTION line adds no second TICK line (HIMMEL-6584)' ;; *) fail 'the wt-orphans ACTION line adds no second TICK line (HIMMEL-6584)' ;; esac
wto_cached="$(TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a read younger than the TTL is served from the cache (HIMMEL-6584)' "$wto_cached" ' wt-orphans=2'
mkdir -p "$W/repo-other"
wto_other="$(REPO="$W/repo-other" TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$wto_other" in *wt-orphans*|*wt-ceiling*) fail "a chief on another REPO never reads this REPO's cache (out='$wto_other')" ;; *) pass "a chief on another REPO never reads this REPO's cache (HIMMEL-6584)" ;; esac
wto_zero="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-0.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$wto_zero" in *wt-orphans*|*wt-ceiling*) fail "a clean fleet hides wt-orphans and wt-ceiling (out='$wto_zero')" ;; *) pass 'a clean fleet hides wt-orphans and wt-ceiling (HIMMEL-6584)' ;; esac
wto_err="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-err.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'an unavailable open-PR list reads wt-orphans=unknown, not an all-clear (HIMMEL-6584)' "$wto_err" ' wt-orphans=unknown'
rm -f "$wto_cache_f"
wto_crash="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-crash.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a failed probe reads wt-orphans=unknown (HIMMEL-6584)' "$wto_crash" ' wt-orphans=unknown'
wto_after="$(TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a failed probe is not cached, so the next tick reads afresh (HIMMEL-6584)' "$wto_after" ' wt-orphans=2'
rm -f "$wto_cache_f"
wto_silent="$(TICK_WT_ORPHANS_TTL=0 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-silent1.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a probe exiting 1 with no alarm line reads wt-orphans=unknown (HIMMEL-6584)' "$wto_silent" ' wt-orphans=unknown'
wto_after="$(TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'a silent exit 1 is not cached as an all-clear (HIMMEL-6584)' "$wto_after" ' wt-orphans=2'
: > "$wto_cache_f"
wto_empty="$(TICK_WT_ORPHANS_TTL=30 TICK_WORKTREE_ORPHANS_PROBE="$W/wto-probe-2.sh" TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
contains 'an empty cache is not an all-clear, so the tick reads afresh (HIMMEL-6584)' "$wto_empty" ' wt-orphans=2'
case "$(find "$TICK_STATE_DIR" -name 'tick-wt-orphans-*.*' 2>/dev/null)" in '') pass 'the cache write leaves no temp file behind (HIMMEL-6584)' ;; *) fail 'the cache write leaves no temp file behind (HIMMEL-6584)' ;; esac
rm -f "$wto_cache_f"
contains 'verbose labels worker failures (HIMMEL-4670)' "$(TOKEN='' bash "$SUT" --doc "$d4670" --verbose 2>/dev/null)" 'worker-session failures: 1/1@error/Edit*1'
printf '%s\n' '{"v":1,"ts":"2026-10-07T03:05:00Z","leg":"N8","class":"denied/a b\tc","failure":"denied","count":1}' > "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'whitespace in the top class cannot split the TICK line (HIMMEL-4670)' "$(fails_of "$d4670")" '1/1@denied/a_b_c*1'
# ~<k> = workers whose wrap digest was skipped this shift (the step's
# skips.jsonl, distinct docs), so an undigested wrap is no longer silent.
{
    printf '%s\n' '{"ts":"2026-10-07T03:10:00Z","doc":"A.md","reason":"no-chain"}'
    printf '%s\n' '{"ts":"2026-10-07T03:11:00Z","doc":"A.md","reason":"no-chain"}'
    printf '%s\n' '{"ts":"2026-10-07T03:12:00Z","doc":"B.md","reason":"no-resume-cwd"}'
    printf '%s\n' '{"ts":"2026-10-07T02:00:00Z","doc":"C.md","reason":"no-chain"}'
} > "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"
same 'fails= ~<k> counts docs whose digest was skipped this shift (HIMMEL-4786)' "$(fails_of "$d4670")" '1/1@denied/a_b_c*1~2'
rm -f "$HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
same 'fails=none~<k> when skips are the only signal (HIMMEL-4786)' "$(fails_of "$d4670")" 'none~2'
rm -f "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"; mkdir -p "$WORKER_SESSION_DIGEST_STATE_DIR/skips.jsonl"
same 'fails=? when the skips log is unreadable (HIMMEL-4786)' "$(fails_of "$d4670")" '?'
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
same 'flakes= is absent with no ledger (HIMMEL-5131)' "$(flakes_of "$d4670")" ''
{
    fkrow $((fk0 - 60)) test-old.sh tick-test-repo
    fkrow $((fk0 + 60)) test-x.sh tick-test-repo
    fkrow $((fk0 + 120)) test-x.sh tick-test-repo
    fkrow $((fk0 + 180)) test-y.sh tick-test-repo
    fkrow $((fk0 + 180)) test-other.sh some-other-repo
    printf 'not json\n'
} > "$SUITE_FLAKE_LEDGER"
same 'flakes= counts this shift, this repo only, with the top suite repeat count (HIMMEL-5131)' "$(flakes_of "$d4670")" '3/2@test-x.sh*2'
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *' flakes=3/2@test-x.sh*2') pass 'flakes= follows fails= and is the last field without spare= (HIMMEL-5131)' ;; *) fail "flakes= position (out='$fk_out')" ;; esac
contains 'verbose labels suite flakes (HIMMEL-5131)' "$(TOKEN='' bash "$SUT" --doc "$d4670" --verbose 2>/dev/null)" 'suite flakes: 3/2@test-x.sh*2'
same 'a doc with no lock start reads no flakes= (HIMMEL-5131)' "$(flakes_of "$d4670_free")" ''
# A suite name carrying Unicode whitespace plus a key=value must not forge a field:
# board.mjs splits the line on a JS \s regex where the last key wins.
fknbsp=$'test-x\xc2\xa0legs=9\xe2\x80\xa8fleet=9.sh'
fkrow $((fk0 + 60)) "$fknbsp" tick-test-repo > "$SUITE_FLAKE_LEDGER"
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *$'\xc2\xa0'*|*$'\xe2\x80\xa8'*) fail "flakes= carries Unicode whitespace from a suite name (out='$fk_out')" ;; *) pass 'flakes= strips Unicode whitespace from the top suite name (HIMMEL-5131)' ;; esac
same 'a forged key in a suite name stays inside the flakes= value (HIMMEL-5131)' "$(flakes_of "$d4670")" '1/1@test-x_legs_9_fleet_9.sh*1'
rm -f "$SUITE_FLAKE_LEDGER"; mkdir -p "$SUITE_FLAKE_LEDGER"
same 'flakes=? when the ledger is unreadable (HIMMEL-5131)' "$(flakes_of "$d4670")" '?'
rmdir "$SUITE_FLAKE_LEDGER"
# The tick.sh whitelist guard on its own: a stub reader that bypasses the reader's
# sanitising and emits an NBSP + a forged key; reverting the guard turns this red.
printf '#!/usr/bin/env bash\nprintf "1/1@test-x\\xc2\\xa0legs=9.sh*1\\n"\n' > "$W/repo/scripts/observability/suite-flake-summary.sh"
fk_out="$(TOKEN='' bash "$SUT" --doc "$d4670" 2>/dev/null)"
case "$fk_out" in *' flakes='*) fail "tick.sh guard let an NBSP-bearing reader line through (out='$fk_out')" ;; *) pass 'tick.sh drops a reader line carrying Unicode whitespace (HIMMEL-5131)' ;; esac
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
contains 'no vault configured reads vault=skip (HIMMEL-4911)' "$(t3361)" ' vault=skip'
contains 'a clean vault reads vault=ok (HIMMEL-4911)' "$(t4911 "$v4911")" ' vault=ok'
echo staged > "$v4911/a.md"; git -C "$v4911" add a.md
touch -d '50 minutes ago' "$v4911/a.md"  # gnu-ok: chief kit is Linux-only
contains 'files staged past the threshold read vault=STALL:<age>,<n> (HIMMEL-4911)' "$(t4911 "$v4911")" ' vault=STALL:50m,1'
contains '--verbose labels the vault (HIMMEL-4911)' "$(t4911 "$v4911" --verbose)" 'vault: STALL:50m,1'
GIT_COMMITTER_DATE="$(date -d '3 hours ago' +%s) +0000" gv4911 commit -q -m lag  # gnu-ok: chief kit is Linux-only
contains 'an unpushed commit past the threshold reads vault=PUSH-LAG:<age> (HIMMEL-4911)' "$(t4911 "$v4911")" ' vault=PUSH-LAG:3h'
mkdir -p "$W/vault4911bad/.git"; echo garbage > "$W/vault4911bad/.git/HEAD"
contains 'a corrupt vault reads vault=unknown and the tick still runs (HIMMEL-4911)' "$(t4911 "$W/vault4911bad")" ' vault=unknown'

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
contains 'no cloud-sessions.tsv reads cloud=skip (HIMMEL-5163)' "$(t5163)" ' cloud=skip'
printf '%s\t%s\t%s\t%s\n' \
    '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' \
    '2026-10-10T15:56:32' HIMMEL-4655 session_01JJVL8oEQVV6M19v4kobvRV 'claude --teleport session_01JJVL8oEQVV6M19v4kobvRV' \
    '2026-10-10T15:56:43' HIMMEL-4657 session_01BCqPMDHjUE9Z52yEy3J3Uf 'claude --teleport session_01BCqPMDHjUE9Z52yEy3J3Uf' \
    '2026-10-10T15:56:54' HIMMEL-4686 session_0173H75dC4x9nZ7JdeLqYoMc 'claude --teleport session_0173H75dC4x9nZ7JdeLqYoMc' \
    > "$c5163/cloud-sessions.tsv"
equals5163="STALL:HIMMEL-5077,HIMMEL-4655,HIMMEL-4686"
contains 'no-branch + CLOUD-DONE-without-shepherd sessions read cloud=STALL (merged 4657 is not a stall) (HIMMEL-5163)' "$(t5163 | cloud_of)" "$equals5163"
not_contains 'a merged cloud PR is never a stall (HIMMEL-5163)' "$(t5163 | cloud_of)" 'HIMMEL-4657'
printf '%s\n' '# HIMMEL-5077 shepherd' '- 16:00 LIVE — shepherding PR 2314' > "$c5163/HIMMEL-5077-N9-shepherd-2026-10-10.md"
contains 'a live worker doc naming the PR clears the unshepherded stall (HIMMEL-5163)' "$(t5163 | cloud_of)" 'STALL:HIMMEL-4655,HIMMEL-4686'
printf '%s\n' '# HIMMEL-5077 shepherd' '- 16:00 LIVE — shepherding PR 2314' '- 16:20 WRAPPED — done' > "$c5163/HIMMEL-5077-N9-shepherd-2026-10-10.md"
contains 'a WRAPPED worker doc is not a live shepherd (HIMMEL-5163)' "$(t5163 | cloud_of)" "$equals5163"
contains 'an unreadable forge reads cloud=skip, never a failed tick (HIMMEL-5163)' "$(GHSTUB5163=gh-down t5163 | cloud_of)" 'skip'
contains '--verbose labels the cloud field (HIMMEL-5163)' "$(t5163 --verbose)" "cloud: $equals5163"
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
contains 'an open PR with no CLOUD-DONE and no commit for an hour reads STALL (HIMMEL-5163)' "$(t5163 | cloud_of)" 'STALL:HIMMEL-5077'
contains 'the same PR under a raised quiet threshold is working, not a stall (HIMMEL-5163)' "$(CLOUD_LIVENESS_PR_MIN=9999 t5163 | cloud_of)" 'ok'
# a relaunch supersedes the earlier launch, so a PR made before it no longer
# speaks for the ticket; a full gh page that may have cut a live session's PR off is unknown.
printf '%s\t%s\t%s\t%s\n' '2026-10-10T18:20:00' HIMMEL-5077 session_relaunch 'claude --teleport session_relaunch' > "$c5163/cloud-sessions.tsv"
contains 'a PR from before the relaunch does not stall the new session (HIMMEL-5163)' "$(t5163 | cloud_of)" 'ok'
printf '%s\n' \
    "const a = [];" \
    "for (let i = 0; i < 100; i++) a.push({ number: i + 1, title: 'x', body: '', state: 'MERGED', headRefName: 'z', createdAt: '2026-10-10T16:00:00Z', mergedAt: '2026-10-10T16:01:00Z', comments: [], commits: [] });" \
    "process.stdout.write(JSON.stringify(a));" > "$c5163/full.js"
printf '%s\n' '#!/bin/sh' "node '$c5163/full.js'" > "$c5163/gh-full"
chmod +x "$c5163/gh-full"
printf '%s\t%s\t%s\t%s\n' '2026-10-10T15:56:20' HIMMEL-5077 session_012yMgxSaSskpLb4qrfXBhk1 'claude --teleport session_012yMgxSaSskpLb4qrfXBhk1' > "$c5163/cloud-sessions.tsv"
contains 'a full gh page newer than the session launch reads cloud=skip (HIMMEL-5163)' "$(GHSTUB5163=gh-full t5163 | cloud_of)" 'skip'

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
same 'stall= folds the probe rows to pr:class (HIMMEL-6049)' "$(t6049 | stall_of)" '2887:conflict,2869:ci-slow'
contains 'verbose labels the stall field (HIMMEL-6049)' "$(t6049 --verbose)" 'stall: 2887:conflict,2869:ci-slow'
same 'a failing probe with nothing cached reads stall=? (HIMMEL-6049)' "$(ST_FAIL=1 t6049 | stall_of)" '?'
rm -f "$st6049/count" "$st6049/cache"
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
touch -d '3 hours ago' "$st6049/cache"
same 'a failing probe after the TTL emits the last cached value (HIMMEL-6049)' "$(ST_FAIL=1 ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" 2>/dev/null | stall_of)" '2887:conflict,2869:ci-slow'
: > "$st6049/count"
ST_FAIL=1 ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
same 'the failure is cached for the TTL: a second tick does not re-run the probe (HIMMEL-6049)' "$(wc -l < "$st6049/count" | tr -d ' ')" '0'
rm -f "$st6049/count" "$st6049/cache"
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
ST_COUNT="$st6049/count" TICK_STALL_PROBE="$st6049/probe" TICK_STALL_CACHE="$st6049/cache" TICK_STALL_TTL_MIN=60 bash "$SUT" >/dev/null 2>&1
same 'two ticks inside the TTL run the probe once (HIMMEL-6049)' "$(wc -l < "$st6049/count" | tr -d ' ')" '1'

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
same 'doctor= lists the WARN and FAIL ids, sorted, and leaves OK and INFO out (HIMMEL-7849)' "$(t7849 | doctor_of)" 'C16-hooks,C77-bridge-stale'
contains 'verbose labels the doctor field (HIMMEL-7849)' "$(t7849 --verbose)" 'doctor: C16-hooks,C77-bridge-stale'
same 'a clean doctor leaves doctor= off the line (HIMMEL-7849)' "$(DR_CLEAN=1 t7849 | doctor_of)" ''
same 'a failing doctor with nothing cached reads doctor=? (HIMMEL-7849)' "$(DR_FAIL=1 t7849 | doctor_of)" '?'
same 'TTL 0 turns the doctor probe off (HIMMEL-7849)' "$(TTL7849=0 t7849 | doctor_of)" ''
rm -f "$dr7849/count" "$dr7849/cache"
DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" >/dev/null 2>&1
same 'the second tick inside the TTL serves the cached ids (HIMMEL-7849)' "$(DR_FAIL=1 DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'two ticks inside the TTL run the doctor once (HIMMEL-7849)' "$(wc -l < "$dr7849/count" | tr -d ' ')" '1'
touch -d '3 hours ago' "$dr7849/cache"
same 'a failing doctor after the TTL emits the last cached ids (HIMMEL-7849)' "$(DR_FAIL=1 DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/cache" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'a missing doctor script leaves doctor= off the line (HIMMEL-7849)' "$(TICK_DOCTOR_CMD="$dr7849/no-such-doctor" TICK_DOCTOR_CACHE="$dr7849/none" bash "$SUT" 2>/dev/null | doctor_of)" ''
# A doctor slower than the tick's wait budget runs detached: the tick answers `?` at once, the
# run finishes on its own, and the next tick folds the finished rows in without a second run.
rm -f "$dr7849/count" "$dr7849/slow".*
DR_SLEEP=3 DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/slow" bash "$SUT" > "$dr7849/slow-line" 2>/dev/null
same 'a doctor slower than the wait budget reads doctor=? on that tick (HIMMEL-7849)' "$(doctor_of < "$dr7849/slow-line")" '?'
sleep 5
same 'the next tick folds in the finished slow run (HIMMEL-7849)' "$(DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/slow" bash "$SUT" 2>/dev/null | doctor_of)" 'C16-hooks,C77-bridge-stale'
same 'the slow run was started once, not once per tick (HIMMEL-7849)' "$(wc -l < "$dr7849/count" | tr -d ' ')" '1'
# The default wait is short (3 s): a 5 s doctor does not hold the tick, so the tick reads `?`.
rm -f "$dr7849/dflt" "$dr7849/dflt".*
DR_SLEEP=5 DR_COUNT="$dr7849/dflt-count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/dflt" bash "$SUT" > "$dr7849/dflt-line" 2>/dev/null
same 'the default wait does not hold the tick for a 5 s doctor (HIMMEL-7849)' "$(doctor_of < "$dr7849/dflt-line")" '?'
# Two ticks share one cache: a live run holds the run directory and a tick that finds it starts no
# second run; a run directory older than 15 minutes is a lost run and the next tick starts a new one.
rm -rf "$dr7849/count" "$dr7849/held".*
mkdir "$dr7849/held.cache.run"
DR_COUNT="$dr7849/count" TICK_DOCTOR_WAIT_SEC=1 TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/held.cache" bash "$SUT" > "$dr7849/held-line" 2>/dev/null
same 'a live run directory keeps a second tick from starting a run (HIMMEL-7849)' "$(cat "$dr7849/count" 2>/dev/null | wc -l | tr -d ' ')" '0'
same 'a tick waiting on a run another tick holds reads doctor=? (HIMMEL-7849)' "$(doctor_of < "$dr7849/held-line")" '?'
touch -d '20 minutes ago' "$dr7849/held.cache.run"
DR_COUNT="$dr7849/count" TICK_DOCTOR_CMD="$dr7849/doctor" TICK_DOCTOR_CACHE="$dr7849/held.cache" bash "$SUT" > "$dr7849/lost-line" 2>/dev/null
same 'a run directory older than 15 minutes is a lost run and a new one starts (HIMMEL-7849)' "$(doctor_of < "$dr7849/lost-line")" 'C16-hooks,C77-bridge-stale'

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
dr9342="$W/dr9342"; mkdir -p "$dr9342"
printf '%s\n' '#!/usr/bin/env bash' "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" \
    'echo "{\"sev\":\"WARN\",\"id\":\"C9-spin\",\"msg\":\"m\",\"remedy\":\"r\"}"; exit 0' > "$dr9342/doctor"
chmod +x "$dr9342/doctor"
dr_run9342() { rm -f "$dr9342/cache".*; rm -rf "$dr9342/cache.run"; cpu9342 "$dr9342/line" env SPIN="$1" TICK_DOCTOR_WAIT_SEC=30 TICK_DOCTOR_CMD="$dr9342/doctor" TICK_DOCTOR_CACHE="$dr9342/cache" bash "$SUT"; }
rm -f "$dr9342/cache"
dr_base9342="$(dr_run9342 '')"
same 'the control tick harvests the doctor run' "$(doctor_of < "$dr9342/line")" 'C9-spin'
rm -f "$dr9342/cache"
dr_spin9342="$(dr_run9342 1)"
same 'the spinning doctor run is harvested in the tick' "$(doctor_of < "$dr9342/line")" 'C9-spin'
same 'the doctor launch prints no pid line on the tick stdout' "$(grep -c '^[0-9][0-9]*$' "$dr9342/line")" '0'
if [ $((dr_spin9342 - dr_base9342)) -lt 1000 ]; then pass 'a harvested doctor run adds none of its CPU to the tick'; else fail "a harvested doctor run added $((dr_spin9342 - dr_base9342)) ms of CPU to the tick (spin ${dr_spin9342} ms, control ${dr_base9342} ms)"; fi

cg9342="$W/cg9342"; mkdir -p "$cg9342"
printf '%s\n' '#!/usr/bin/env bash' "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'echo ciguard=ok' > "$cg9342/probe"
chmod +x "$cg9342/probe"
cg_run9342() { rm -rf "$cg9342/state"; mkdir -p "$cg9342/state"; cpu9342 "$cg9342/line" env SPIN="$1" TICK_STATE_DIR="$cg9342/state" TICK_SECTION_WAIT=30 TICK_CIGUARD_PROBE="$cg9342/probe" bash "$SUT"; }
cg_base9342="$(cg_run9342 '')"
contains 'the control tick serves the guardrail refresh' "$(cat "$cg9342/line")" ' ciguard=ok'
cg_spin9342="$(cg_run9342 1)"
contains 'the spinning guardrail refresh lands in the tick that launched it' "$(cat "$cg9342/line")" ' ciguard=ok'
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
printf '%s\n' '#!/usr/bin/env bash' "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'echo "dependabot-go sweep: merged=1 skipped=2"' 'touch "$HD_DONE"' > "$W/repo/scripts/cr/dependabot-go.sh"
db_run9342() {
    rm -rf "$db9342/state"; mkdir -p "$db9342/state"; rm -f "$db9342/done"
    cpu9342 "$db9342/line" env SPIN="$1" HD_DONE="$db9342/done" DEPENDABOT_AUTOLAND=on TICK_DBOT_MIN_SECS=0 TICK_STATE_DIR="$db9342/state" PATH="$hd9342/bin:$PATH" bash "$SUT"
}
db_base9342="$(db_run9342 '')"
contains 'the control tick launches the dependabot sweep' "$(cat "$db9342/line")" ' dbot=none,run'
db_spin9342="$(db_run9342 1)"
contains 'the spinning tick launches the dependabot sweep' "$(cat "$db9342/line")" ' dbot=none,run'
same 'the dependabot sweep ended before the spinning tick did' "$([ -e "$db9342/done" ] && echo yes || echo no)" 'yes'
wait9342 "$db9342/state"/tick-dbot-*.log
same 'the dependabot sweep still moves its tmp log to the log' "$(cat "$db9342/state"/tick-dbot-*.log 2>/dev/null)" 'dependabot-go sweep: merged=1 skipped=2'
if [ $((db_spin9342 - db_base9342)) -lt 1000 ]; then pass 'a dependabot sweep that ends inside the tick adds none of its CPU to the tick'; else fail "a dependabot sweep added $((db_spin9342 - db_base9342)) ms of CPU to the tick (spin ${db_spin9342} ms, control ${db_base9342} ms)"; fi

if command -v python3 >/dev/null 2>&1; then
    pi9342="$W/pi9342"; mkdir -p "$pi9342/plan" "$pi9342/mirror"
    printf '%s\n' '# chief' '' "tracker-plan: $pi9342/plan" '' '## Results (newest at the bottom)' > "$pi9342/chief.md"
    # shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
    printf '%s\n' '#!/usr/bin/env bash' "[ -z \"\${SPIN:-}\" ] || { $spin9342; }" 'touch "$HD_DONE"' 'exit 0' > "$pi9342/launcher"
    chmod +x "$pi9342/launcher"
    pi_run9342() {
        rm -rf "$pi9342/out"; rm -f "$pi9342/done"
        cpu9342 "$pi9342/line" env SPIN="$1" HD_DONE="$pi9342/done" TOKEN='' TICK_PLAN_INDEX_OUT="$pi9342/out" TICK_PLAN_INDEX_LAUNCHER="$pi9342/launcher" TICK_TRACKER_MIRROR_DIR="$pi9342/mirror" PATH="$hd9342/bin:$PATH" bash "$SUT" --doc "$pi9342/chief.md"
    }
    pi_base9342="$(pi_run9342 '')"
    contains 'the control tick launches the plan-index refresh' "$(cat "$pi9342/line")" ' plan-index=REFRESHING'
    pi_spin9342="$(pi_run9342 1)"
    contains 'the spinning tick launches the plan-index refresh' "$(cat "$pi9342/line")" ' plan-index=REFRESHING'
    same 'the plan-index refresh ended before the spinning tick did' "$([ -e "$pi9342/done" ] && echo yes || echo no)" 'yes'
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
same 'parked= names a worker on an unanswered permission prompt (HIMMEL-2563)' "$(parked_of)" 'HIMMEL-333-legN70:12m'
pk_out="$(bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null)"
case "$pk_out" in *' vmrun='*' parked=HIMMEL-333-legN70:12m') pass 'parked= follows vmrun= and is the last field without flakes=/spare= (HIMMEL-2563)' ;; *) fail "parked= position (out='$pk_out')" ;; esac
contains 'verbose labels the parked worker (HIMMEL-2563)' "$(bash "$SUT" --workers 'HIMMEL-333-legN70' --verbose 2>/dev/null)" 'parked on prompt: HIMMEL-333-legN70:12m'
printf '{"ts":"%s","kind":"outcome","session_id":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$pk_sid" >> "$HIMMEL_TRUST_LEDGER_DIR/ledger.jsonl"
same 'parked= is absent once the prompt is answered (HIMMEL-2563)' "$(parked_of)" ''

# --- station=BEHIND:<components>: the last station-sync.sh left a component behind main
station_of() { bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null | sed -n -E 's/.* station=([^ ]*).*/\1/p'; }
same 'station= is absent with no sync state (HIMMEL-5945)' "$(station_of)" ''
printf 'ok\n' > "$TICK_STATION_STATE"
same 'station= is absent when the station is current (HIMMEL-5945)' "$(station_of)" ''
printf 'BEHIND:luna_template,codex\n' > "$TICK_STATION_STATE"
same 'station= names the behind components (HIMMEL-5945)' "$(station_of)" 'BEHIND:luna_template,codex'
contains 'verbose labels the behind station (HIMMEL-5945)' "$(bash "$SUT" --workers 'HIMMEL-333-legN70' --verbose 2>/dev/null)" 'station: BEHIND:luna_template,codex'
rm -f "$TICK_STATION_STATE"

# --- alert-fail=<cadence>:<age>: cadence-alert.sh could not deliver a failure alert
alertfail_of() { bash "$SUT" --workers 'HIMMEL-333-legN70' 2>/dev/null | sed -n -E 's/.* alert-fail=([^ ]*).*/\1/p'; }
same 'alert-fail= is absent with no marker (HIMMEL-7419)' "$(alertfail_of)" ''
printf '%s focus-refresh exit-1\n' "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$CADENCE_ALERT_SEND_FAILED_MARK"  # gnu-ok: chief kit is Linux-only
same 'alert-fail= names the cadence and its age (HIMMEL-7419)' "$(alertfail_of)" 'focus-refresh:3h'
contains 'verbose labels the failed alert (HIMMEL-7419)' "$(bash "$SUT" --workers 'HIMMEL-333-legN70' --verbose 2>/dev/null)" 'alert-fail: focus-refresh:3h'
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
q_key_line="$(grep -n -E '^[[:space:]]+for f in workers livestate prs ' "$HERE/chief-wait.sh")"
[ -n "$q_key_line" ] && pass "chief-wait's key field list is found" || fail "chief-wait's key field list moved"
not_contains "chief-wait's key field list gains no quota" "$q_key_line" 'quota'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-fields.sh'
    exit 0
fi
printf 'FAIL - test-tick-fields.sh (%s failure(s))\n' "$fails"
exit 1
