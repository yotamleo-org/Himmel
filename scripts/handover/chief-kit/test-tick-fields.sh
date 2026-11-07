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

# --- orphans-wip=: In Progress / In Review tickets with no worker and no open PR.
OW="$W/ow-mirror/HIMMEL"; mkdir -p "$OW"
mk_ow() { # <num> <status> <type>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "%s"\nstatus: "%s"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t%s\n\n## Description\n\nbody\n' \
        "$1" "$3" "$2" "$1" "$1" > "$OW/HIMMEL-$1.md"
}
cat > "$W/ow-gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${OW_GH_FAIL:-}" ] || exit 1
[ "$2" = list ] && case "$*" in *merged*) [ -z "${OW_MERGED_FAIL:-}" ] || exit 1; printf '%b' "${OW_MERGED_ROWS:-}" ;; *headRefName*) printf '%b' "${OW_PR_ROWS:-}" ;; esac
exit 0
STUB
chmod +x "$W/ow-gh"
ow_tick() { NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" bash "$SUT" 2>/dev/null; }
ow_of() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^orphans-wip=//p'; }
mk_ow 901 "In Progress" Task
mk_ow 902 "In Review" Task
mk_ow 903 "In Progress" Epic
mk_ow 904 "To Do" Task
owa="$(ow_of "$(ow_tick)")"
[ "$owa" = "2:HIMMEL-901,HIMMEL-902" ] && pass 'orphans-wip= counts the orphans and names them (Epic and To Do excluded)' || fail "orphans-wip= is '$owa'"
owb="$(ow_of "$(OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' ow_tick)")"
[ "$owb" = "1:HIMMEL-902" ] && pass 'orphans-wip= drops a ticket an open PR cites' || fail "orphans-wip= with a PR is '$owb'"
owc="$(ow_of "$(OW_GH_FAIL=1 ow_tick)")"
[ "$owc" = "?" ] && pass 'orphans-wip= is ? when the PR read fails, not an all-clear' || fail "orphans-wip= on gh failure is '$owc'"
owd="$(ow_of "$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" bash "$SUT" 2>/dev/null)")"
[ "$owd" = "skip" ] && pass 'orphans-wip= is skip without a Jira mirror' || fail "orphans-wip= without a mirror is '$owd'"
for n in 905 906 907 908; do mk_ow "$n" "In Progress" Task; done
owe="$(ow_of "$(ow_tick)")"
[ "$owe" = "6" ] && pass 'orphans-wip= names no keys above five' || fail "orphans-wip= with six is '$owe'"
contains '--verbose labels orphans-wip' "$(NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" bash "$SUT" --verbose 2>/dev/null)" 'orphans-wip: 6'

# IN CI tickets count too: one a merged PR cites (merged-not-closed) and one with no PR at all.
OW_SAVE="$OW"; OW="$W/ow-inci-mirror/HIMMEL"; mkdir -p "$OW"
mk_ow 921 "IN CI" Task
mk_ow 922 "IN CI" Task
OW_MERGED_ROWS='4400\tfix: [HIMMEL-921] x\tfix/himmel-921-x\n'
owi="$(ow_of "$(OW_MERGED_ROWS="$OW_MERGED_ROWS" ow_tick)")"
[ "$owi" = "2:HIMMEL-921,HIMMEL-922" ] && pass 'orphans-wip= counts an IN CI ticket with a merged PR and one with no PR' || fail "orphans-wip= with IN CI tickets is '$owi'"
owj="$(ow_of "$(OW_MERGED_ROWS="$OW_MERGED_ROWS" OW_PR_ROWS='4401\tfix: [HIMMEL-921] y\tfix/himmel-921-y\n' ow_tick)")"
[ "$owj" = "1:HIMMEL-922" ] && pass 'orphans-wip= drops an IN CI ticket an open PR cites' || fail "orphans-wip= with an IN CI open PR is '$owj'"
owk="$(ow_of "$(OW_MERGED_FAIL=1 ow_tick)")"
[ "$owk" = "?" ] && pass 'orphans-wip= is ? when the merged-PR read fails, not an all-clear' || fail "orphans-wip= on merged read failure is '$owk'"
OW="$OW_SAVE"

# --- orphans-wip= reads through a cache a detached refresh fills.
cat > "$W/ow-gh-hung" <<'STUB'
#!/usr/bin/env bash
sleep 3
STUB
chmod +x "$W/ow-gh-hung"
# A scan still running would write into the next row's fixture, so each row waits it out.
owc_fresh() { for l in "$W"/owc/tick-resume-*.lock; do [ ! -e "$l" ] || flock "$l" true; done; rm -rf "$W/owc"; mkdir -p "$W/owc"; }
owc_tick() { TICK_POOL_WAIT=0 TICK_STATE_DIR="$W/owc" NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" bash "$SUT" 2>/dev/null; }
owc_age() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^orphans-wip-age=//p'; }
if [ -n "$_TIMEOUT_BIN" ]; then
    owc_fresh
    t0="$(date +%s)"
    owh="$(TICK_POOL_WAIT=0 TICK_SECTION_WAIT=1 NEXT_DISPATCH_GH_CMD="$W/ow-gh-hung" TICK_STATE_DIR="$W/owc" NEXT_DISPATCH_MIRROR="$OW" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung resume scan costs the tick only its short wait (HIMMEL-8735)'; else fail "a hung resume scan held the tick $((t1 - t0))s (HIMMEL-8735)"; fi
    contains 'a hung resume scan still yields the worker state (HIMMEL-8735)' "$owh" ' workers=N61:FRESH'
    same 'a hung resume scan with no cache reads ?, never an all-clear (HIMMEL-8735)' "$(ow_of "$owh")" '?'
    same 'no scan cache means no orphans-wip-age field (HIMMEL-8735)' "$(owc_age "$owh")" ''
else
    skip 'resume scan timing rows: no timeout binary'
fi
owc_fresh
owf="$(owc_tick)"
same 'a finished scan serves its count (HIMMEL-8735)' "$(ow_of "$owf")" 6
case "$(owc_age "$owf")" in [0-9]*s) pass 'a served scan carries its age (HIMMEL-8735)' ;; *) fail "orphans-wip-age is '$(owc_age "$owf")' (HIMMEL-8735)" ;; esac
owc_rows="$(ls "$W"/owc/tick-resume-*.rows)"
touch -d '5 minutes ago' "$owc_rows"  # gnu-ok: chief kit is Linux-only
owg="$(TICK_ORPHANS_MIN_SECS=3600 OW_GH_FAIL=1 owc_tick)"
same 'a tick inside the cadence serves the cached scan (HIMMEL-8735)' "$(ow_of "$owg")" 6
case "$(owc_age "$owg")" in 30[0-9]s) pass 'the cached scan reports its true age (HIMMEL-8735)' ;; *) fail "cached orphans-wip-age is '$(owc_age "$owg")' (HIMMEL-8735)" ;; esac
# The first ticket in this row is the one the suite's FRESH worker N61 holds.
printf '# tick-resume-scan ok\nRESUME\tHIMMEL-111\tMedium\t-\tt\nRESUME\tHIMMEL-901\tMedium\t-\tt\nRESUME\tHIMMEL-902\tMedium\t-\tt\n' > "$owc_rows"
same 'cached rows name their keys, minus a ticket a worker took since the scan (HIMMEL-8735)' "$(ow_of "$(TICK_ORPHANS_MIN_SECS=3600 owc_tick)")" '2:HIMMEL-901,HIMMEL-902'
touch -d '2 hours ago' "$owc_rows"  # gnu-ok: chief kit is Linux-only
owl="$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)"
same 'a scan past its TTL reads ?, never an all-clear (HIMMEL-8735)' "$(ow_of "$owl")" '?'
case "$(owc_age "$owl")" in 72[0-9][0-9]s) pass 'an expired scan still shows how old it is (HIMMEL-8735)' ;; *) fail "expired orphans-wip-age is '$(owc_age "$owl")' (HIMMEL-8735)" ;; esac
printf 'RESUME\tHIMMEL-901\n' > "$owc_rows"
owm="$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)"
same 'a corrupt scan cache reads ?, never an all-clear (HIMMEL-8735)' "$(ow_of "$owm")" '?'
same 'a corrupt scan cache carries no age (HIMMEL-8735)' "$(owc_age "$owm")" ''
printf '# tick-resume-scan ok\n' > "$owc_rows"
same 'a scan that found nothing reads 0 (HIMMEL-8735)' "$(ow_of "$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)")" 0

# The same read-only interpreter serves the tick field and the waiter's wake.
pd_doc="$W/handover/pool-chief.md"
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-4 question operator decision 268' \
    'pool-disposition: HIMMEL-5 slice HIMMEL-900' \
    'pool-disposition: HIMMEL-6 close PR 3905' \
    'pool-disposition: HIMMEL-7 question' \
    'pool-disposition: HIMMEL-999 question operator decision 268' \
    '' '## Results' 'pool-disposition: HIMMEL-8 question not live state' > "$pd_doc"
printf '%s\n' \
    '# disposition HIMMEL-1 in-flight owned by worker N1' \
    '# disposition HIMMEL-2 collision scripts/a.sh held by PR #20' \
    '# disposition HIMMEL-3 blocker HIMMEL-900 (In Progress, live)' \
    '# disposition HIMMEL-4 label operator-decision' \
    '# disposition HIMMEL-5 classification BLOCKED: broad task' \
    '# disposition HIMMEL-6 listed MERGED-NOT-CLOSED' \
    '# disposition HIMMEL-7 listed LOCAL' \
    '# disposition HIMMEL-8 below --top 7' \
    '# disposition HIMMEL-9 blocker HIMMEL-901 (not in mirror)' \
    '# disposition HIMMEL-10 collision scripts/b.sh held by listed HIMMEL-7' \
    '# disposition HIMMEL-11 blocker HIMMEL-902 (reopened live)' \
    '# disposition HIMMEL-12 blocker-unknown HIMMEL-903' > "$W/pool.rows"
pd_out="$(bash "$SUT" --pool-dispositions --doc "$pd_doc" < "$W/pool.rows" 2>/dev/null)"
contains 'pool counts in-flight as dispositioned, not a disjoint fifth bucket' "$pd_out" '# pool-counts 12/1/8/4'
not_contains 'a reopened-live blocker is not left unresolved' "$pd_out" '# pool-unresolved blocker HIMMEL-11 '
not_contains 'a blocker-unknown row is not left unresolved' "$pd_out" '# pool-unresolved blocker-unknown HIMMEL-12 '
contains 'malformed chief decisions remain named and unresolved' "$pd_out" '# pool-unresolved invalid HIMMEL-7 '
contains 'a non-Live-state decision never dispositions a key' "$pd_out" '# pool-unresolved below HIMMEL-8 '
contains 'an unread blocker is not a named live blocker' "$pd_out" '# pool-unresolved blocker HIMMEL-9 '
contains 'a listed candidate is not a live file holder' "$pd_out" '# pool-unresolved collision HIMMEL-10 '
contains 'unknown chief decision keys stay visible until corrected' "$pd_out" '# pool-unresolved invalid HIMMEL-999 '
same 'standalone pool mode resolves handover-relative document paths' "$(bash "$SUT" --pool-dispositions --doc pool-chief.md < "$W/pool.rows" 2>/dev/null)" "$pd_out"
same 'standalone pool mode resolves extensionless document names' "$(bash "$SUT" --pool-dispositions --doc pool-chief < "$W/pool.rows" 2>/dev/null)" "$pd_out"

# the retired --legs / --legs-from flags are unknown options of the script's own parser
for old_flag in --legs --legs-from; do
    old_rc=0
    old_out="$(bash "$SUT" "$old_flag" x 2>&1)" || old_rc=$?
    [ "$old_rc" = 2 ] && pass "$old_flag exits 2" || fail "$old_flag exited $old_rc"
    contains "$old_flag prints the script's usage" "$old_out" 'usage: tick.sh'
    not_contains "$old_flag is not a missing function" "$old_out" 'command not found'
done

PD="$W/pd-mirror/HIMMEL"; mkdir -p "$PD"
for n in 901 902 904; do sed 's/fixVersions: \[\]/fixVersions: ["v1.1.3"]/' "$OW/HIMMEL-$n.md" > "$PD/HIMMEL-$n.md"; done
printf 'v1.1.3\tfalse\t\n' > "$W/pd-mirror/HIMMEL.versions.tsv"
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-904 question operator decision 268\n' > "$pd_doc"
# shellcheck disable=SC2016  # the fixture expands arguments when the classifier runs
printf '#!/bin/sh\nfor k in "$@"; do printf "%%s\\tLOCAL-NATIVE\\tstub\\n" "$k"; done\n' > "$W/pd-classify"
chmod +x "$W/pd-classify"
pd_tick="$(NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TOKEN='' bash "$SUT" --doc "$pd_doc" 2>/dev/null)"
contains 'a real tick uses the shared pool interpretation with PR ownership and chief decisions' "$pd_tick" ' pool=3/1/2/1 '

# --- (8336) INTAKE=<n> and chains=STALE:<n>/<m>: versionless operator work the pool cannot show, and a
# focus-chains.json that still lists Done steps. Each field is absent when there is nothing to say.
PDI="$W/pdi-mirror/HIMMEL"; mkdir -p "$PDI" "$W/ic-dir"
cp "$PD"/*.md "$PDI"/; cp "$W/pd-mirror/HIMMEL.versions.tsv" "$W/pdi-mirror/HIMMEL.versions.tsv"
ic_doc="$W/ic-dir/HIMMEL-8336-chief.md"; cp "$pd_doc" "$ic_doc"
ic_tick() { NEXT_DISPATCH_MIRROR="$PDI" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_STATE_DIR="$W/ic-state" TOKEN='' bash "$SUT" "$@" --doc "$ic_doc" 2>/dev/null; }
not_contains 'with no versionless operator ticket the tick prints no INTAKE= (HIMMEL-8336)' "$(ic_tick)" ' INTAKE='
not_contains 'with no focus-chains.json the tick prints no chains= (HIMMEL-8336)' "$(ic_tick)" ' chains='
sed -e 's/^labels: \[\]/labels: ["operator-directed"]/' -e 's/904/905/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-905.md"
sed -e 's/^statusCategory: "x"/statusCategory: "Done"/' -e 's/904/906/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-906.md"
sed -e 's/^body$/statusCategory: "Done"/' -e 's/904/907/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-907.md"  # open ticket whose description quotes a Done line
rm -rf "$W/ic-state"
contains 'a versionless operator-directed ticket shows as INTAKE=<n> beside pool= (HIMMEL-8336)' "$(ic_tick)" ' INTAKE=1 '
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-906"},{"key":"HIMMEL-904"},{"key":"HIMMEL-907"}]},{"drain":"x"}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a focus-chains.json that lists a Done step shows chains=STALE:<done>/<steps>; a Done line in a description is not a Done step (HIMMEL-8336)' "$(ic_tick)" ' chains=STALE:1/4'
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"},{"key":"HIMMEL-907"}]}]\n' > "$W/ic-dir/focus-chains.json"
not_contains 'a focus-chains.json with no Done step prints no chains=, whatever its descriptions quote (HIMMEL-8336)' "$(ic_tick)" ' chains='
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"},{"key":"HIMMEL-999"}]}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a chain step with no readable mirror file reads chains: skip, not ok (HIMMEL-8336)' "$(ic_tick --verbose)" 'chains: skip'
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"}]}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a chain whose steps all read and none is Done reads chains: ok (HIMMEL-8336)' "$(ic_tick --verbose)" 'chains: ok'

# The pool snapshot classifies every version ticket (140 s on a 23-worker fleet),
# so a slow one never holds the tick: it reads ? until the detached snapshot lands, then counts.
# The kit is the real one, file by file, but its next-dispatchable.sh sleeps 8 s on the pool call.
if [ -n "$_TIMEOUT_BIN" ]; then
    real_scripts="$(cd "$HERE/../.." && pwd)"
    sk="$W/slowrepo/scripts"
    mkdir -p "$sk/handover/chief-kit"
    for f in "$real_scripts"/*; do [ "${f##*/}" = handover ] || ln -s "$f" "$sk/${f##*/}"; done
    for f in "$real_scripts"/handover/*; do [ "${f##*/}" = chief-kit ] || ln -s "$f" "$sk/handover/${f##*/}"; done
    for f in "$HERE"/*; do [ "${f##*/}" = next-dispatchable.sh ] || ln -s "$f" "$sk/handover/chief-kit/${f##*/}"; done
    printf '#!/usr/bin/env bash\ncase " $* " in *" --dispositions "*) sleep 8 ;; esac\nexec bash %q "$@"\n' "$HERE/next-dispatchable.sh" > "$sk/handover/chief-kit/next-dispatchable.sh"
    pd_slow() { NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_POOL_WAIT=1 TICK_STATE_DIR="$W/pd-slow-state" TOKEN='' "$_TIMEOUT_BIN" -k 2 6 bash "$sk/handover/chief-kit/tick.sh" --doc "$pd_doc" 2>/dev/null; }
    pd_slow_out="$(pd_slow)"; pd_rc=$?
    [ "$pd_rc" -eq 0 ] && pass 'a slow pool snapshot never holds the tick past its budget (HIMMEL-7609)' || fail "a slow pool snapshot held the tick past its 6 s budget (rc $pd_rc)"
    contains 'the tick reads pool=? until the slow snapshot lands (HIMMEL-7609)' "$pd_slow_out" ' pool=? '
    for _ in $(seq 1 40); do [ -z "$(find "$W/pd-slow-state" -name 'tick-pool-*.rows' 2>/dev/null)" ] || break; sleep 0.5; done
    contains 'the next tick counts from the finished snapshot (HIMMEL-7609)' "$(pd_slow)" ' pool=3/1/2/1 '
    # A snapshot that ends while the tick waits for it adds none of its CPU to the tick: the same
    # wrapper spins about 2 s on the pool call, the control does not.
    # shellcheck disable=SC2016  # the wrapper's own $vars expand when it runs, not here
    printf '#!/usr/bin/env bash\ncase " $* " in *" --dispositions "*) [ -z "${SPIN:-}" ] || { %s; } ;; esac\nexec bash %q "$@"\n' "$spin9342" "$HERE/next-dispatchable.sh" > "$sk/handover/chief-kit/next-dispatchable.sh"
    pd_cpu9342() { rm -rf "$W/pd-cpu-state"; cpu9342 "$W/pd-cpu-line" env SPIN="$1" TOKEN= NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_POOL_WAIT=30 TICK_STATE_DIR="$W/pd-cpu-state" bash "$sk/handover/chief-kit/tick.sh" --doc "$pd_doc"; }
    pd_base9342="$(pd_cpu9342 '')"
    contains 'the control tick counts from the snapshot it waited for' "$(cat "$W/pd-cpu-line")" ' pool=3/1/2/1 '
    pd_spin9342="$(pd_cpu9342 1)"
    contains 'the spinning snapshot lands in the tick that launched it' "$(cat "$W/pd-cpu-line")" ' pool=3/1/2/1 '
    if [ $((pd_spin9342 - pd_base9342)) -lt 1000 ]; then pass 'a pool snapshot the tick waits out adds none of its CPU to the tick'; else fail "a pool snapshot added $((pd_spin9342 - pd_base9342)) ms of CPU to the tick (spin ${pd_spin9342} ms, control ${pd_base9342} ms)"; fi
else
    skip 'a slow pool snapshot never holds the tick: no timeout'
fi

# --- pool-closed=<closed>/<total>: Done or wont-do keys on the Live state priority: line.
mk_ow 911 "Done" Task
mk_ow 912 "wont do" Task
for n in 911 912; do sed 's/^statusCategory: "x"$/statusCategory: "Done"/' "$OW/HIMMEL-$n.md" > "$OW/HIMMEL-$n.md.new" && mv "$OW/HIMMEL-$n.md.new" "$OW/HIMMEL-$n.md"; done
pc_doc="$W/handover/HIMMEL-6602-chief.md"
printf '%s\n' '# chief' '' '## Live state' 'priority: 911 | 912(K1) 904 | 901(+911) 9999' '' '## Results' > "$pc_doc"
pc_tick() { NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" TOKEN='' bash "$SUT" "$@" 2>/dev/null; }
contains 'closed keys on the priority line show as pool-closed=<closed>/<total> (HIMMEL-6602)' "$(pc_tick --doc "$pc_doc")" ' pool-closed=2/5'
contains '--verbose labels pool-closed (HIMMEL-6602)' "$(pc_tick --doc "$pc_doc" --verbose)" 'pool-closed: 2/5'
printf '%s\n' '## Live state' 'priority: 904 901' > "$pc_doc"
not_contains 'a priority line with no closed key hides pool-closed (HIMMEL-6602)' "$(pc_tick --doc "$pc_doc")" 'pool-closed'
not_contains 'no --doc hides pool-closed (HIMMEL-6602)' "$(pc_tick)" 'pool-closed'
# --- prio=<open>/<total> and prio-stale=WARN:<...>: the priority line gone dead or off-version.
mk_prio() { # <num> <statusCategory> <fixVersions json>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$1" > "$OW/HIMMEL-$1.md"
}
absent() { # <name> <needle> <tick args...>: the tick must print a TICK line, and that line lacks <needle>
    local n="$1" s="$2" o; shift 2; o="$(pc_tick "$@")"
    case "$o" in *"TICK "*) not_contains "$n" "$o" "$s" ;; *) fail "$n (the tick printed no TICK line)" ;; esac
}
pr_keys=""
for n in $(seq 8101 8180); do mk_prio "$n" Done '["v1.1.3"]'; pr_keys="$pr_keys $n"; done
mk_prio 8190 "To Do" '["v1.1.5"]'
mk_prio 8191 "To Do" '["v1.1.3"]'
pr_doc="$W/handover/HIMMEL-8072-chief.md"
printf '%s\n' '# chief' '' '## Live state' "priority:$pr_keys 8191" 'focus-version: v1.1.3' '' '## Results' > "$pr_doc"
contains 'a line with 1 open key of 81 shows prio=1/81 (HIMMEL-8072)' "$(pc_tick --doc "$pr_doc")" ' prio=1/81 '
contains 'a line with 1 open key of 81 gives WARN prio-stale (HIMMEL-8072)' "$(pc_tick --doc "$pr_doc")" ' prio-stale=WARN:low'
contains '--verbose labels prio and the prio-stale WARN (HIMMEL-8072)' "$(pc_tick --doc "$pr_doc" --verbose)" 'prio-stale: WARN:low'
printf '%s\n' '## Live state' 'priority: 8101 8190 8191' 'focus-version: v1.1.3' > "$pr_doc"
contains 'an open v1.1.5 key with focus-version v1.1.3 makes the WARN name the key (HIMMEL-8072)' "$(pc_tick --doc "$pr_doc")" ' prio-stale=WARN:HIMMEL-8190@v1.1.5'
absent 'the off-version WARN is quiet when the key matches (HIMMEL-8072)' 'HIMMEL-8191@' --doc "$pr_doc"
printf '%s\n' '## Live state' 'priority: 8191 904' 'focus-version: v1.1.3' > "$pr_doc"
contains 'a live line shows prio=<open>/<total> (HIMMEL-8072)' "$(pc_tick --doc "$pr_doc")" ' prio=2/2 '
absent 'a live on-version line has no prio-stale (HIMMEL-8072)' 'prio-stale' --doc "$pr_doc"
printf '%s\n' '## Live state' 'legs: none' > "$pr_doc"
absent 'no priority: line hides prio (HIMMEL-8072)' ' prio' --doc "$pr_doc"
DOC='' absent 'no --doc and no exported DOC hides prio (HIMMEL-8072)' ' prio='
# pool-stale=<n>:<KEY>,...: a pool-disposition: line whose named blocker is Done. The
# detailed rows live in test-tick-pool-stale.sh; this pins the tick line and --verbose.
printf '%s\n' '# chief' '' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' '' '## Results' > "$pc_doc"
contains 'a disposition whose blocker is Done shows as pool-stale=<n>:<KEY> (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc")" ' pool-stale=1:HIMMEL-7120'
contains '--verbose labels pool-stale (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc" --verbose)" 'pool-stale: 1:HIMMEL-7120'
not_contains 'a nothing-unversioned mirror hides residual-unversioned (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc")" 'residual-unversioned'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on a doc with an open blocker (HIMMEL-6604)' || fail 'the tick exits 0 on a doc with an open blocker (HIMMEL-6604)'
contains 'a disposition whose blocker is still open reads the all-clear pool-stale=0 (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
contains 'no --doc falls back to the exported DOC and reads pool-stale=0 (HIMMEL-6604)' "$(DOC="$pc_doc" pc_tick)" ' pool-stale=0'
printf '%s\n' '## Live state' 'priority: 904 901' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on a doc with no disposition line (HIMMEL-6604)' || fail 'the tick exits 0 on a doc with no disposition line (HIMMEL-6604)'
contains 'a doc with no disposition line still reads pool-stale=0, so the waiter can clear a marker whose line was removed (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
# The waiter reads the compact tick line, so the all-clear it needs to clear its marker (an
# explicit pool-stale=0 after a disposition was read) must be on that line. These rows feed the
# REAL tick to the REAL waiter: no injected field.
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on the waiter fixture doc (HIMMEL-6604)' || fail 'the tick exits 0 on the waiter fixture doc (HIMMEL-6604)'
contains 'a read disposition with no stale blocker prints the all-clear pool-stale=0 (HIMMEL-6604)' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
wt_dir="$W/wt-stale"; mkdir -p "$wt_dir/consoles" "$wt_dir/stub"
: > "$wt_dir/consoles/c.md"; wt_inbox="$wt_dir/consoles/c.md"
# the stub logs one line per COMPLETED tick, so a quiet arm can prove it saw whole samples
# shellcheck disable=SC2016  # $? must reach the generated stub literally, not expand here
printf '#!/usr/bin/env bash\nenv NEXT_DISPATCH_MIRROR=%q NEXT_DISPATCH_GH_CMD=%q TOKEN= bash %q --doc %q\nrc=$?\necho x >> %q\nexit $rc\n' "$OW" "$W/ow-gh" "$SUT" "$pc_doc" "$wt_dir/ticks" > "$wt_dir/stub/tick.sh"
printf '#!/usr/bin/env bash\nprintf "PROCEED\\n"\n' > "$wt_dir/stub/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$wt_dir/stub/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$wt_dir/stub/budget-off.sh"
printf '#!/usr/bin/env bash\nprintf "# pool=0/7,LOW\\nPOOL-EMPTY\\n"\n' > "$wt_dir/stub/dispatch.sh"
chmod +x "$wt_dir/stub/"*.sh
wt_arm() { # <outfile> [seconds]: one foreground waiter arm over the real tick; wt_rc is 124 when nothing woke it
    CHIEF_WAIT_TICK="$wt_dir/stub/tick.sh" CHIEF_WAIT_USAGE="$wt_dir/stub/bank.sh" CHIEF_WAIT_DISPATCH="$wt_dir/stub/dispatch.sh" \
    CHIEF_WAIT_PAGE_CMD="$wt_dir/stub/off.sh" CHIEF_WAIT_BUDGET="$wt_dir/stub/budget-off.sh" WAIT_SWEEP_CMD="$wt_dir/stub/off.sh" WAIT_FOCUS_CMD="$wt_dir/stub/off.sh" \
    CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 HIMMEL_DENIAL_ACK_DIR="$wt_dir/acks" \
        timeout "${2:-40}" bash "$HERE/chief-wait.sh" "$wt_inbox" --workers "N1.md" > "$1" 2>/dev/null  # gnu-ok: Linux-only kit
    wt_rc=$?
}
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
# The fixture's own state (underfilled, unwatched) wakes the waiter first. wt_quiet arms until a
# sample wakes nobody (rc 124) AFTER at least two whole ticks completed in that arm (a timeout
# mid-sample proves nothing; the first completed sample is processed before the second starts);
# wt_stale arms until the pool-stale wake shows up. Both bound the loop.
wt_ticks() { if [ -f "$wt_dir/ticks" ]; then wc -l < "$wt_dir/ticks" | tr -d ' '; else echo 0; fi; }
wt_quiet() { local i t0; wt_quiet_ok=no; : > "$1"; for i in 1 2 3 4 5; do t0="$(wt_ticks)"; wt_arm "$1.arm" 12; cat "$1.arm" >> "$1"; if [ "$wt_rc" -eq 124 ] && [ "$(( $(wt_ticks) - t0 ))" -ge 2 ]; then wt_quiet_ok=yes; break; fi; done; }
wt_stale() { local i; : > "$1"; for i in 1 2 3 4; do wt_arm "$1.arm" 20; cat "$1.arm" >> "$1"; grep -q '^WAKE pool-stale' "$1.arm" && break; done; }
wt_quiet "$W/wt0.out"
[ "$wt_quiet_ok" = yes ] && pass 'the warm-up drains every non-stale wake (HIMMEL-6604)' || fail 'the warm-up drains every non-stale wake (HIMMEL-6604)'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' > "$pc_doc"
wt_stale "$W/wt1.out"
contains 'the real tick makes the waiter wake for a stale disposition (HIMMEL-6604)' "$(cat "$W/wt1.out")" 'WAKE pool-stale HIMMEL-7120'
grep -q 'HIMMEL-7120' "$wt_inbox.wait.stale" 2>/dev/null && pass 'the waiter marker holds the stale key (HIMMEL-6604)' || fail 'the waiter marker holds the stale key (HIMMEL-6604)'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
wt_quiet "$W/wt2.out"
[ "$wt_quiet_ok" = yes ] && [ ! -e "$wt_inbox.wait.stale" ] && pass 'a real all-clear from the tick clears the waiter marker (HIMMEL-6604)' || fail 'a real all-clear from the tick clears the waiter marker (HIMMEL-6604)'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' > "$pc_doc"
wt_stale "$W/wt3.out"
contains 'a key that went stale again after an all-clear wakes again (HIMMEL-6604)' "$(cat "$W/wt3.out")" 'WAKE pool-stale HIMMEL-7120'
rm -f "$pc_doc"

# --- ready-mismatch=<flagged>/<ready>,nogo=<k>/<judged>[,ALERT] ---
# A READY claim a judge or the diff contradicts. Fixtures only: the changed-file lists are
# pre-recorded in the ready-files cache and the gh stub fails, so no live gh runs.
RMD="$W/rm"
mkdir -p "$RMD/verdicts" "$W/repo/scripts/ci" "$TICK_STATE_DIR/ready-files"
printf '# trust paths\n^scripts/ci/\n^scripts/lib/\n' > "$W/repo/scripts/ci/ci-trust-paths.txt"
# shellcheck disable=SC2016  # "$*" expands in the generated stub, not here
printf '#!/bin/sh\necho "$*" >> "%s/rm-gh.calls"\nexit 1\n' "$W" > "$W/rm-gh"
chmod +x "$W/rm-gh"
export TICK_GH_CMD="$W/rm-gh"
rm_head() { printf '%040d' "$1"; }
rm_worker() { printf '# T - worker N%s (%s, native)\n\n## Results\n\n- 10:00 READY %s %s GREEN %s\n' "$1" "$2" "$3" "$(rm_head "$3")" "$4" > "$RMD/worker$1.md"; }
rm_files() { local pr="$1"; shift; printf '%s\n' "$@" > "$TICK_STATE_DIR/ready-files/$pr-$(rm_head "$pr")"; }
# shellcheck disable=SC2016  # the backticks are literal verdict text
rm_verdict() { mkdir -p "$RMD/verdicts/j$1"; printf '# VERDICT j%s - judge\n\nwriter-session: x\nwritten-at: t\n\n## Verdict\n\n**%s** for head `%s`.\n\npr: %s\nprior: GO\n\nevidence\nmac: 0\n' "$1" "$2" "$(rm_head "$1")" "$1" > "$RMD/verdicts/j$1/judge.md"; }
rm_worker 1 claude-sonnet-5-5 101 '- trust path: none'
rm_files 101 docs/a.md scripts/ci/x.sh
rm_worker 2 claude-opus-5-5 102 '- CI green, marker cleared'
rm_files 102 scripts/lib/y.sh
rm_worker 3 claude-sonnet-5-5 103 '- no trust path touched'
rm_files 103 docs/a.md
rm_verdict 103 GO
rm_worker 4 claude-sonnet-5-5 104 '- trust path: none'
rm_files 104 docs/b.md
rm_verdict 104 NO-GO
mkdir -p "$RMD/verdicts/jdecoy"
# shellcheck disable=SC2016  # the backticks are literal verdict text
printf '## Verdict\n\n**NO-GO** for head `%s`.\n\npr: 777\n' "$(rm_head 103)" > "$RMD/verdicts/jdecoy/judge.md"
rm_worker 5 claude-opus-5-5 105 '- touches scripts/ci/, trust-reviewed GO needed'
rm_files 105 scripts/ci/z.sh
printf '# chief\n' > "$RMD/chief.md"
rm_of() { TOKEN='' bash "$SUT" --doc "$RMD/chief.md" 2>/dev/null | sed -n -E 's/.* ready-mismatch=([^ ]*).*/\1/p'; }
same 'ready-mismatch= flags a claimed-none and a silent READY, counts the NO-GO-at-head one in nogo only, and skips the GO control and the named-trust one (HIMMEL-6032, HIMMEL-6441)' "$(rm_of)" '2/5,nogo=1/2,ALERT'
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'detail flags the claimed-none READY on a trust-path diff as M1b' "$rm_det" "M1b	101	"
contains 'detail flags the silent READY on a trust-path diff as M1c' "$rm_det" "M1c	102	"
contains 'detail flags the READY whose head a judge NO-GO-ed as M1a' "$rm_det" "M1a	104	"
not_contains 'a clean READY with a GO verdict is not flagged' "$rm_det" "	103	"
not_contains 'a READY that names its trust-path touch is not flagged' "$rm_det" "	105	"
contains 'detail breaks the NO-GO rate out per model' "$rm_det" "MODEL	claude-sonnet-5-5	"
contains 'verbose labels the field' "$(TOKEN='' bash "$SUT" --doc "$RMD/chief.md" --verbose 2>/dev/null)" 'ready-mismatch: 2/5,nogo=1/2,ALERT'
[ -f "$W/rm-gh.calls" ] && ! grep -q 'files' "$W/rm-gh.calls" && pass 'cached file lists mean no file-list gh call' || fail 'a cached PR still read its files from gh'
rm -f "$W/rm-gh.calls"
rm -f "$RMD"/worker[1245].md
same 'ready-mismatch= is absent when every READY is clean' "$(rm_of)" ''
rm -f "$RMD/worker3.md"
for n in $(seq 201 224); do rm_worker "$n" claude-sonnet-5-5 "$n" '- trust path: none'; done
rm_of >/dev/null
[ "$(wc -l < "$W/rm-gh.calls" | tr -d ' ')" -le 20 ] && pass 'at most 20 uncached gh calls per tick' || fail "gh was called $(wc -l < "$W/rm-gh.calls" | tr -d ' ') times"
rm -f "$RMD"/worker2*.md "$W/rm-gh.calls"
rm -rf "$TICK_STATE_DIR/ready-files"
mkdir -p "$TICK_STATE_DIR/ready-files"
# shellcheck disable=SC2016  # $RM_GH_OID expands in the generated stub, not here
printf '#!/bin/sh\npwd >> "%s/rm-gh.pwd"\nprintf "%%s\\nscripts/ci/x.sh\\n" "$RM_GH_OID"\n' "$W" > "$W/rm-gh"
rm_worker 301 claude-sonnet-5-5 301 '- trust path: none'
RM_GH_OID="$(rm_head 999)" rm_of >/dev/null
[ ! -e "$TICK_STATE_DIR/ready-files/301-$(rm_head 301)" ] && pass 'a PR whose current head is not the READY head is not cached or trusted' || fail 'a stale-head file list was cached'
same 'a stale-head read is unchecked, not flagged' "$(RM_GH_OID="$(rm_head 999)" rm_of)" ''
rm_n1="$(wc -l < "$W/rm-gh.pwd" | tr -d ' ')"
RM_GH_OID="$(rm_head 999)" rm_of >/dev/null
[ "$(wc -l < "$W/rm-gh.pwd" | tr -d ' ')" = "$rm_n1" ] && pass 'a failed lookup backs off instead of retrying every tick' || fail 'a failed lookup was retried inside the backoff window'
rm -f "$TICK_STATE_DIR"/ready-files/*.fail
same 'a leading-zero TICK_READY_WINDOW_DAYS is read as decimal' "$(RM_GH_OID="$(rm_head 301)" TICK_READY_WINDOW_DAYS=08 rm_of)" '1/1,nogo=0/0,ALERT'
rm -f "$TICK_STATE_DIR"/ready-files/*.fail "$TICK_STATE_DIR/ready-files/301-$(rm_head 301)"
same 'a matching-head read flags the claimed-none READY' "$(RM_GH_OID="$(rm_head 301)" rm_of)" '1/1,nogo=0/0,ALERT'
[ "$(sort -u "$W/rm-gh.pwd")" = "$W/repo" ] && pass 'gh runs in the --repo checkout' || fail "gh ran in $(sort -u "$W/rm-gh.pwd")"
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
printf '#!/bin/sh\nexec sleep 30\n' > "$W/rm-gh"
for n in 311 312 313; do rm_worker "$n" claude-sonnet-5-5 "$n" '- trust path: none'; done
rm_t0=$SECONDS
rm_det="$(TICK_READY_BUDGET_SEC=2 bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
[ $((SECONDS - rm_t0)) -lt 8 ] && pass 'a hanging gh cannot hold the scan past its wall-clock budget' || fail "the scan took $((SECONDS - rm_t0))s against a 2s budget"
contains 'a spent budget is reported as PARTIAL' "$rm_det" "PARTIAL"
contains 'a spent budget leaves the remaining READYs unchecked' "$rm_det" "COUNT	3	0	0	0	3"
same 'the tick field reads partial when the budget was spent' "$(TICK_READY_BUDGET_SEC=2 rm_of)" '0/3,nogo=0/0,partial'
rm -f "$RMD"/worker*.md
printf '#!/bin/sh\nexit 1\n' > "$W/rm-gh"
rm_worker 321 claude-sonnet-5-5 321 '- trust path: not touched'
rm_worker 322 claude-sonnet-5-5 322 '- this PR does not touch a trust path'
rm_files 321 scripts/ci/a.sh
rm_files 322 scripts/ci/b.sh
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a not-touched claim on a trust-path diff is M1b' "$rm_det" "M1b	321	"
contains 'a does-not-touch claim on a trust-path diff is M1b' "$rm_det" "M1b	322	"
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
rm -rf "$RMD/verdicts"
mkdir -p "$RMD/verdicts"
# shellcheck disable=SC2016  # "$*" expands in the generated stub, not here
printf '#!/bin/sh\ncase "$*" in *state*) echo MERGED ;; *) exit 1 ;; esac\n' > "$W/rm-gh"
rm_worker 331 claude-sonnet-5-5 331 '- trust path: none'
rm_worker 332 claude-sonnet-5-5 332 '- CI green, marker cleared'
rm_files 331 scripts/ci/m.sh
rm_files 332 scripts/lib/n.sh
same 'a trust-path claim mismatch on an already-merged PR is not flagged (HIMMEL-6441)' "$(rm_of)" ''
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
not_contains 'a merged PR raises no M1b' "$rm_det" "M1b	331	"
not_contains 'a merged PR raises no M1c' "$rm_det" "M1c	332	"
not_contains 'a merged PR raises no trust ALERT' "$rm_det" "ALERT"
[ -e "$TICK_STATE_DIR/ready-files/331-$(rm_head 331).merged" ] && pass 'a merged state is cached' || fail 'a merged PR was not cached'
printf '#!/bin/sh\nexit 1\n' > "$W/rm-gh"
same 'a merged PR stays unflagged from its cache when gh is down' "$(rm_of)" ''
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
rm_worker 341 claude-sonnet-5-5 341 '- trust path: none'
rm_files 341 docs/ok.md
rm_verdict 341 NO-GO
same 'a lone NO-GO at the READY head is counted in nogo, not in ready-mismatch (HIMMEL-6441)' "$(rm_of)" ''
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a lone NO-GO is still listed as M1a in the detail' "$rm_det" "M1a	341	"
contains 'a lone NO-GO counts zero flagged and one nogo' "$rm_det" "COUNT	1	0	1	1	0"
rm -f "$RMD"/worker*.md
rm -rf "$RMD/verdicts"
mkdir -p "$RMD/verdicts"
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a window with no READY reports a zero count' "$rm_det" "COUNT	0	0	0	0	0"
unset TICK_GH_CMD
rm -rf "$RMD" "$W/rm-gh.calls" "$W/rm-gh.pwd"

# The chief's own HANDOFF (<doc stem>-HANDOFF.md) over HANDOFF_BUDGET_BYTES, or
# its decisions: line over DECISIONS_BUDGET_BYTES, prints an ACTION line.
# The decisions: text and the HANDOFF note are copied from live chief docs.
d6603="$W/handover/HIMMEL-6603-chief.md"
printf '%s\n' '# console' '' '## Live state' 'decisions: OPERATOR 10-17 afternoon (BINDING, carry verbatim to every successor): (3) Residuals 6102-6108, 6110 deferred (out of v1.1.3). Windows/WSL support work is NEVER dispatched. (4) qmd fork: version with tags + main (bump main too, tag releases). (6) Use more fleet + Claude API + claudex budget; WORKER_SESSION_EFFORT high on claudex legs.' > "$d6603"
printf '%s\n' '> HANDOFF over budget: 46253 bytes (limit 12000); Live state 41637 bytes, wrapped-PR list 198 bytes — tighten the Live state' > "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
hb_small="$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)"
not_contains 'a HANDOFF and decisions: line under their budgets print no ACTION (HIMMEL-6603)' "$hb_small" 'over-budget'
hb_over="$(HANDOFF_BUDGET_BYTES=100 DECISIONS_BUDGET_BYTES=200 TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)"
contains 'a HANDOFF over HANDOFF_BUDGET_BYTES prints an ACTION line (HIMMEL-6603)' "$hb_over" 'ACTION handoff-over-budget=127/100: '
contains 'the HANDOFF ACTION names the HANDOFF file (HIMMEL-6603)' "$hb_over" 'HIMMEL-6603-chief-HANDOFF.md'
contains 'a decisions: line over DECISIONS_BUDGET_BYTES prints an ACTION line (HIMMEL-6603)' "$hb_over" 'ACTION decisions-over-budget=347/200: '
contains 'the decisions ACTION names the bucket decisions file (HIMMEL-6603)' "$hb_over" "$W/handover/specs/decisions/chief-decisions-"
case "$(printf '%s\n' "$hb_over" | grep -c '^TICK ')" in 1) pass 'the size ACTION lines add no second TICK line (HIMMEL-6603)' ;; *) fail 'the size ACTION lines add no second TICK line (HIMMEL-6603)' ;; esac
head -c 6000 /dev/zero | tr '\0' x > "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
not_contains 'a HANDOFF of exactly 6000 bytes is within the default budget (HIMMEL-6603)' "$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'handoff-over-budget'
printf 'x' >> "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
contains 'a HANDOFF of 6001 bytes is over the default budget (HIMMEL-6603)' "$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION handoff-over-budget=6001/6000: '
contains 'a non-numeric HANDOFF_BUDGET_BYTES falls back to the default (HIMMEL-6603)' "$(HANDOFF_BUDGET_BYTES=12k TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION handoff-over-budget=6001/6000: '
printf '%s\n' '# chief' '' 'decisions: a brief note above Live state, not the line' '' '## Live state' 'decisions: (1) short.' > "$d6603"
contains 'only the Live state decisions: line is measured (HIMMEL-6603)' "$(DECISIONS_BUDGET_BYTES=10 TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION decisions-over-budget=21/10: '
rm -f "$d6603" "$W/handover/HIMMEL-6603-chief-HANDOFF.md"

# --- effort=MISMATCH:<worker> ----------------------------------------------------
# The asked effort is the WORKER_SESSION_EFFORT line in the launch-<label>.sh the chief
# wrote beside the worker doc; the live effort is the effort= token on the worker's
# newest LIVE bullet. A worker asked for high that reports medium is the 09-23 to
# 10-20 incident this field exists to show.
fm="$W/handover/chief.fleet.json"
ef_doc="$W/handover/HIMMEL-6588-N77-effort.md"
ef_ok="$W/handover/HIMMEL-6588-N78-effort.md"
ef_none="$W/handover/HIMMEL-6588-N79-effort.md"
printf '%s\n' '# worker' '- 09:00 LIVE — started effort=medium model=claude-sonnet-5-5' > "$ef_doc"
printf '%s\n' '# worker' '- 09:00 LIVE — started effort=high model=claude-sonnet-5-5' > "$ef_ok"
printf '%s\n' '# worker' '- 09:00 LIVE — started, no effort token' > "$ef_none"
for ef_l in N77 N78 N79; do printf '%s\n' '#!/usr/bin/env bash' 'export WORKER_SESSION_EFFORT=high' > "$W/handover/launch-$ef_l.sh"; done
printf '{"schema":1,"legs":[{"doc":"%s","label":"N77","lockless":true},{"doc":"%s","label":"N78","lockless":true},{"doc":"%s","label":"N79","lockless":true}]}\n' "$ef_doc" "$ef_ok" "$ef_none" > "$fm"
ef_out="$(WORKERS='' bash "$SUT" --workers-from "$fm")"; ef_rc=$?
if [ "$ef_rc" -eq 0 ]; then pass 'the effort fixture tick exits 0'; else fail "the effort fixture tick exits 0 (rc=$ef_rc)"; fi
contains 'a worker asked for high whose LIVE bullet says medium reads effort=MISMATCH:N77 (HIMMEL-6588)' "$ef_out" ' effort=MISMATCH:N77'
not_contains 'a worker whose LIVE effort matches the asked one is not flagged (HIMMEL-6588)' "$ef_out" 'MISMATCH:N78'
not_contains 'a LIVE bullet with no effort= token is not flagged (HIMMEL-6588)' "$ef_out" 'MISMATCH:N79'
printf '%s\n' '- 09:30 LIVE — resumed effort=high model=claude-sonnet-5-5' >> "$ef_doc"
ef_out2="$(WORKERS='' bash "$SUT" --workers-from "$fm")"; ef_rc2=$?
if [ "$ef_rc2" -eq 0 ]; then pass 'the re-run effort fixture tick exits 0'; else fail "the re-run effort fixture tick exits 0 (rc=$ef_rc2)"; fi
contains 'the re-run effort fixture tick prints its TICK line' "$ef_out2" 'TICK '
not_contains 'only the newest LIVE bullet decides the effort (HIMMEL-6588)' "$ef_out2" 'effort=MISMATCH'
rm -f "$ef_doc" "$ef_ok" "$ef_none" "$W/handover/launch-N77.sh" "$W/handover/launch-N78.sh" "$W/handover/launch-N79.sh" "$fm"

# --- tmp=<pct>[!] -----------------------------------------------------
# A read-only df on TICK_TMP_DIR (default /tmp); stubbed through TICK_DF.
cat > "$W/df-stub.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -P ] && [ "$2" = "$TICK_TMP_DIR" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'tmpfs 1000 %s %s %s%% /tmp\n' "$STUB_TMP_PCT" "$((1000 - STUB_TMP_PCT))" "$STUB_TMP_PCT"
STUB
chmod +x "$W/df-stub.sh"
tmp_run() { STUB_TMP_PCT="$1" TICK_TMP_DIR="$W" TICK_DF="$W/df-stub.sh" bash "$SUT" "${@:2}"; }
contains 'tmp= shows the /tmp percentage below the warn level (HIMMEL-4316)' "$(tmp_run 42)" ' tmp=42'
not_contains 'tmp= has no ! below 80 (HIMMEL-4316)' "$(tmp_run 79)" ' tmp=79!'
contains 'tmp= carries ! at 80 (HIMMEL-4316)' "$(tmp_run 80)" ' tmp=80!'
contains 'tmp= carries ! above 80 (HIMMEL-4316)' "$(tmp_run 97)" ' tmp=97!'
contains 'verbose labels tmp (HIMMEL-4316)' "$(tmp_run 42 --verbose)" 'tmp: 42'
not_contains 'tmp= is absent when the dir is unreadable (HIMMEL-4316)' "$(bash "$SUT")" ' tmp='
cw_keys="$(grep -m1 'for f in workers livestate' "$HERE/chief-wait.sh")"
contains "chief-wait's wake key list was found" "$cw_keys" ' vmrun '
not_contains "tmp= is not in chief-wait's wake key (HIMMEL-4316)" "$cw_keys" ' tmp'
# --- cired= (open ci-red issues): a count, unknown on failure, never a wake.
cired_tick() { STUB_CIRED_OUT="$1" bash "$SUT" 2>/dev/null; }
contains 'cired= prints the open ci-red issue count (HIMMEL-5596)' "$(cired_tick 3)" ' cired=3 '
contains 'a failed ci-red read prints cired=unknown (HIMMEL-5596)' "$(STUB_CIRED_RC=1 bash "$SUT" 2>/dev/null)" ' cired=unknown '
contains 'a non-count ci-red read prints cired=unknown (HIMMEL-5596)' "$(cired_tick 'oops')" ' cired=unknown '
contains 'a ci-red count at the read cap prints cired=1000+' "$(cired_tick 1000)" ' cired=1000+ '
not_contains "cired= is not in chief-wait's wake key (HIMMEL-5596)" "$cw_keys" ' cired'

# --- dispatch=: in-flight workflow_dispatch runs on worker branches, one runs
# list per tick plus one jobs read per run; late (>= 80 % of the job timeout), idle (no job
# changed state for 30 min) and orphan (its worker WRAPPED) raise ACTION dispatch-stall.
mkdir -p "$W/repo/.github/workflows"
printf '%s\n' 'jobs:' '  shell:' '    timeout-minutes: 120' '  summary:' '    timeout-minutes: 10' > "$W/repo/.github/workflows/macos-cadence.yml"
printf '%s\n' '# worker' '- WRAPPED — done' > "$W/handover/HIMMEL-333-legN333.md"
d_iso() { date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%SZ; }
d_wf='.github/workflows/macos-cadence.yml'
d_log="$W/dispatch-calls.txt"
d_tick() { # <runs> <jobs> [workers]
    WORKERS="${3:-HIMMEL-111-legN61 HIMMEL-333-legN333}" STUB_DISPATCH_RUNS="$1" STUB_DISPATCH_JOBS="$2" STUB_DISPATCH_LOG="$d_log" bash "$SUT" 2>/dev/null
}
d_head=1111111111111111111111111111111111111111
d_pr_rows="3768\\tfix/himmel-111-mac\\ttrue\\tme\\tfalse\\t2026-01-01T00:00:00Z\\t0\\t$d_head\\t\\n"

: > "$d_log"
d_late="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4001\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 6150)\\n" "9\\t3\\t$(d_iso 300)\\n")"
contains 'a run at 85 % of its job timeout lists dispatch= with the worker, elapsed/timeout and jobs done (HIMMEL-7479)' "$d_late" 'dispatch=4001:N61:102/120m:3/9@1111111:late'
contains 'a run at 85 % of its job timeout raises ACTION dispatch-stall (HIMMEL-7479)' "$d_late" 'ACTION dispatch-stall 4001 N61'
not_contains 'a run on the open PR head is not stale-head (HIMMEL-7479)' "$d_late" 'stale-head'
d_calls="$(grep -c '^runs ' "$d_log")"
if [ "$d_calls" = 1 ]; then pass 'one tick lists the runs exactly once (HIMMEL-7479)'; else fail "runs list calls per tick = $d_calls, want 1"; fi
if grep -q '^runs .*per_page=100' "$d_log"; then pass 'the runs list asks for the largest page, so the oldest in-flight runs are in it (HIMMEL-7479)'; else fail 'runs list is not per_page=100'; fi
d_jobs="$(grep -c '^jobs ' "$d_log")"
if [ "$d_jobs" = 1 ]; then pass 'one tick reads the jobs of each run once (HIMMEL-7479)'; else fail "jobs reads per tick = $d_jobs, want 1"; fi

d_early="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4002\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 1470)\\n" "9\\t1\\t$(d_iso 120)\\n")"
contains 'a run at 20 % of its job timeout is listed (HIMMEL-7479)' "$d_early" 'dispatch=4002:N61:24/120m:1/9@1111111'
not_contains 'a run at 20 % of its job timeout is not flagged late (HIMMEL-7479)' "$d_early" ':late'
not_contains 'a run at 20 % of its job timeout raises no ACTION dispatch-stall (HIMMEL-7479)' "$d_early" 'ACTION dispatch-stall'

d_idle="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4003\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 2400)\\n" "9\\t1\\t$(d_iso 2100)\\n")"
contains 'a run whose jobs have not changed state for 30 min is flagged idle (HIMMEL-7479)' "$d_idle" 'dispatch=4003:N61:40/120m:1/9@1111111:idle'
contains 'an idle run raises ACTION dispatch-stall (HIMMEL-7479)' "$d_idle" 'ACTION dispatch-stall 4003 N61'

d_orph="$(d_tick "4004\\t$d_wf\\tfix/himmel-333-mac\\t$d_head\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
contains 'a run whose worker is WRAPPED is flagged orphan (HIMMEL-7479)' "$d_orph" 'dispatch=4004:N333:5/120m:1/9@1111111:orphan'
contains 'an orphan run raises ACTION dispatch-stall (HIMMEL-7479)' "$d_orph" 'ACTION dispatch-stall 4004 N333'

d_stale="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4005\\t$d_wf\\tfix/himmel-111-mac\\t2222222222222222222222222222222222222222\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
contains 'a run whose head is no longer the PR head is flagged stale-head (HIMMEL-7479)' "$d_stale" 'dispatch=4005:N61:5/120m:1/9@2222222:stale-head'
not_contains 'a stale head alone raises no ACTION dispatch-stall (HIMMEL-7479)' "$d_stale" 'ACTION dispatch-stall'

d_other="$(d_tick "4006\\t$d_wf\\trelease/other\\t$d_head\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
not_contains 'a run on a branch no worker or PR owns is not listed (HIMMEL-7479)' "$d_other" 'dispatch='

d_cap="$(TICK_DISPATCH_MAX=1 STUB_PR_ROWS="$d_pr_rows" d_tick "4010\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 300)\\n4011\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 6150)\\n" "9\\t3\\t$(d_iso 300)\\n")"
contains 'under the per-tick cap the oldest run is read first, so a hung run is never crowded out by newer ones (HIMMEL-7479)' "$d_cap" 'dispatch=4011:'
not_contains 'under the per-tick cap a newer run does not take the slot of an older one (HIMMEL-7479)' "$d_cap" '4010:'

d_none="$(d_tick '' '')"
not_contains 'no in-flight run leaves dispatch= out of the compact line (HIMMEL-7479)' "$d_none" 'dispatch='
d_down="$(STUB_DISPATCH_RC=1 d_tick '' '')"
contains 'an unreadable runs list reads dispatch=? (HIMMEL-7479)' "$d_down" 'dispatch=?'
d_verbose="$(STUB_PR_ROWS="$d_pr_rows" WORKERS='HIMMEL-111-legN61' STUB_DISPATCH_RUNS="4002\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 1470)\\n" STUB_DISPATCH_JOBS="9\\t1\\t$(d_iso 120)\\n" bash "$SUT" --verbose 2>/dev/null)"
contains 'verbose labels dispatch (HIMMEL-7479)' "$d_verbose" 'dispatch: 4002:N61:24/120m:1/9@1111111'

# focus= and sdrift= come from the focus-state file beside the chief doc. The gh and jira
# stubs log any call made under focus-refresh.sh, so the two fields provably read no network.
f_dir="$W/focus6829"
f_calls="$W/focus6829-calls.txt"
mkdir -p "$f_dir" "$W/bin-focus6829"
for f_tool in gh jira; do
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # the stub body expands at its own run time
        printf 'p=$PPID; while [ "${p:-0}" -gt 1 ]; do\n'
        # shellcheck disable=SC2016
        printf '  case "$(tr "\\0" " " < /proc/$p/cmdline 2>/dev/null)" in *focus-refresh.sh*) echo "%s $*" >> %q ;; esac\n' "$f_tool" "$f_calls"
        # shellcheck disable=SC2016
        printf '  p=$(sed -n "s/^PPid:[[:space:]]*//p" /proc/$p/status 2>/dev/null)\n'
        printf 'done\n'
        if [ "$f_tool" = gh ]; then printf 'exec %q "$@"\n' "$W/bin/gh"; else printf 'exit 1\n'; fi
    } > "$W/bin-focus6829/$f_tool"
    chmod +x "$W/bin-focus6829/$f_tool"
done
f_doc() { printf '%s\n' '# chief' ${1:+"focus-version: $1"} '' '## Results (newest at the bottom)' > "$f_dir/chief.md"; }
f_state() { printf 'status=%s\nstage=%s\ngen=3\ndirty=\nsha8=0a1b2c3d\nsdrift=%s\nts=1\n' "$1" "$2" "$3" > "$f_dir/focus-state"; }
f_tick() { PATH="$W/bin-focus6829:$PATH" bash "$SUT" --doc "$f_dir/chief.md" "$@" 2>/dev/null; }
# positive control: a gh call under a script named focus-refresh.sh is logged
: > "$f_calls"
printf '#!/usr/bin/env bash\ngh probe\n' > "$W/bin-focus6829/focus-refresh.sh"
PATH="$W/bin-focus6829:$PATH" bash "$W/bin-focus6829/focus-refresh.sh" >/dev/null 2>&1
f_probe="$(cat "$f_calls")"
: > "$f_calls"
f_doc v1.0.1
f_state FAILED drift 2:abcd1234
f_out="$(f_tick)"
contains 'a FAILED:drift focus state puts focus=FAILED:drift on the compact line (HIMMEL-6829)' "$f_out" ' focus=FAILED:drift'
contains 'a drift line in the focus state puts sdrift= on the compact line (HIMMEL-6829)' "$f_out" ' sdrift=2:abcd1234'
f_state ok '' 0:0f0f0f0f
f_out="$(f_tick)"
not_contains 'a healthy focus state leaves focus= off the compact line (HIMMEL-6829)' "$f_out" ' focus='
not_contains 'a zero drift line leaves sdrift= off the compact line (HIMMEL-6829)' "$f_out" ' sdrift='
f_out="$(f_tick --verbose)"
contains '--verbose shows a healthy focus state (HIMMEL-6829)' "$f_out" 'focus: ok'
contains '--verbose shows a zero drift line (HIMMEL-6829)' "$f_out" 'sdrift: 0:0f0f0f0f'
f_doc ''
f_state FAILED drift 2:abcd1234
f_out="$(f_tick --verbose)"
not_contains 'a doc with no focus-version: line shows no focus (HIMMEL-6829)' "$f_out" 'focus:'
not_contains 'a doc with no focus-version: line shows no sdrift (HIMMEL-6829)' "$f_out" 'sdrift:'
f_doc v1.0.1
rm -f "$f_dir/focus-state"
f_out="$(f_tick)"
not_contains 'no focus-state file leaves focus= off the line (HIMMEL-6829)' "$f_out" ' focus='
not_contains 'no focus-state file leaves sdrift= off the line (HIMMEL-6829)' "$f_out" ' sdrift='
if [ ! -r "/proc/$$/status" ]; then skip 'the focus fields make no gh or jira call: no /proc to walk the callers (HIMMEL-6829)'
elif [ "$f_probe" != 'gh probe' ]; then fail "the call-log stub missed a gh call under focus-refresh.sh (got '$f_probe')"
elif [ -s "$f_calls" ]; then fail "focus-refresh.sh called gh or jira from the tick: $(tr '\n' ';' < "$f_calls")"; else pass 'the focus fields make no gh or jira call (HIMMEL-6829)'; fi

# --- slotage=: shared suite slots held past the cap -------------
# Reads each live slot's owner record under the semaphore dir; the holder's worker, range and
# suite count come from the detail run-shell-tests.sh records. Advisory: never a wake key.
sa_dir="$W/sem5788"
sa_now="$(date +%s)"
mkdir -p "$sa_dir/slot-1" "$sa_dir/slot-2" "$sa_dir/slot-3" "$sa_dir/slot-4" "$sa_dir/slot-5"
sa_dead="$(sh -c 'echo $$')"
# shellcheck source=../../lib/proc-tree.sh
. "$HERE/../../lib/proc-tree.sh"
sa_id="$(proc_tree_process_identity "$$")"
sa_owner() { # <slot> <pid> <age-seconds> [detail] [identity]
    printf 'pid=%s\nidentity=%s\nlabel=run-shell-tests\nstarted=%s\n%s' "$2" "${5-$sa_id}" "$((sa_now - $3))" "${4:+detail=$4$'\n'}" > "$sa_dir/slot-$1/owner"
}
sa_owner 1 $$ 1500 'worker=N3912 range=aaa1111..bbb2222 suites=3'
sa_owner 2 $$ 60 'worker=N3913 range=ccc..ddd suites=9'
sa_owner 3 "$sa_dead" 9000 'worker=N3914 range=eee..fff suites=5'
sa_owner 4 $$ 1300
sa_owner 5 $$ 9000 'worker=N3915 range=ggg..hhh suites=7' 'reused-pid-other-process'
sa_tick() { HIMMEL_SUITE_SEMAPHORE_DIR="$sa_dir" bash "$SUT" "$@" 2>/dev/null; }
sa_out="$(sa_tick)"
contains 'a live slot held past the cap prints its worker, range, suite count and age (HIMMEL-5788)' "$sa_out" ' slotage=N3912:aaa1111..bbb2222:3suites:25m'
not_contains 'a slot younger than the cap is not listed (HIMMEL-5788)' "$sa_out" 'N3913'
not_contains 'a slot whose owner is dead is not listed (HIMMEL-5788)' "$sa_out" 'N3914'
not_contains 'a slot whose pid now names another process is not listed (HIMMEL-5788)' "$sa_out" 'N3915'
contains 'a slot past the cap with no detail reads ? for each part (HIMMEL-5788)' "$sa_out" ',?:?:?suites:21m'
contains 'verbose labels slotage (HIMMEL-5788)' "$(sa_tick --verbose)" 'slot age: N3912:aaa1111..bbb2222:3suites:25m'
contains 'HIMMEL_SUITE_SLOT_CAP lowers the cap (HIMMEL-5788)' "$(HIMMEL_SUITE_SLOT_CAP=30 sa_tick)" 'N3913:ccc..ddd:9suites:1m'
not_contains 'a raised cap lists nothing (HIMMEL-5788)' "$(HIMMEL_SUITE_SLOT_CAP=99999 sa_tick)" 'slotage='
not_contains 'no semaphore dir leaves slotage= off the line (HIMMEL-5788)' "$(HIMMEL_SUITE_SEMAPHORE_DIR="$W/no-sem5788" bash "$SUT" 2>/dev/null)" 'slotage='
not_contains "slotage= is not in chief-wait's wake key (HIMMEL-5788)" "$cw_keys" 'slotage'
rm -rf "$sa_dir"

# --- cadence=<name>:<state>:<age>:<run id>[:RED|:SKIP|:MISSED],...: the last SCHEDULED
# run of every workflow with a schedule: trigger, read through ci-cadence.sh at most once per
# CI_CADENCE_INTERVAL_SEC and served from the cache between. cg9247 stands in for gh: it counts each
# call and answers `run list --workflow <file>` from <dir>/<file>.row (status, conclusion, createdAt, id),
# so no suite reaches GitHub. RED control (tick.sh before this change): the line never carries cadence=.
cg9247="$W/cadence9247"
mkdir -p "$cg9247"
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$CG_DIR/calls"' '[ -n "$CG_FAIL" ] && exit 1' \
    'case "$1 $2" in' \
    '"run list") wf=; while [ $# -gt 0 ]; do [ "$1" = --workflow ] && wf=$2; shift; done; [ -f "$CG_DIR/$wf.row" ] && cat "$CG_DIR/$wf.row"; exit 0 ;;' \
    '"run view") printf "https://github.com/x/y/actions/runs/%s\tbuild / Run tests\n" "$3"; exit 0 ;;' \
    'esac' 'exit 0' > "$cg9247/gh"
chmod +x "$cg9247/gh"
cg_row() { # <workflow file> <status> <conclusion> <age> <id>
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$(date -u -d "$4 ago" +%Y-%m-%dT%H:%M:%SZ)" "$5" > "$cg9247/$1.row"  # gnu-ok: Linux-only kit
}
cg_seed() {
    rm -f "$cg9247"/*.row "$cg9247/calls" "$cg9247/cache"
    cg_row ci.yml completed success '3 hours' 101
    cg_row ledger-drift.yml completed success '20 hours' 102
    cg_row fork-drift.yml completed success '5 hours' 103
    cg_row pages.yml completed success '9 hours' 104
    cg_row ci-image.yml completed success '3 days' 105
    cg_row macos-cadence.yml completed failure '2 days' 106
    cg_row snyk-weekly.yml completed failure '3 days' 107
}
cg_tick() { CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" "$@" 2>/dev/null; }
cadence_of() { sed -nE 's/.* cadence=([^ ]*).*/\1/p'; }
cg_seed
cg_line="$(cg_tick | cadence_of)"
for cg_name in ci ledger-drift fork-drift pages ci-image macos-cadence snyk-weekly; do
    contains "cadence= carries $cg_name (HIMMEL-9247)" "$cg_line" "$cg_name:"
done
contains 'a failure run reads RED with its run id (HIMMEL-9247)' "$cg_line" 'macos-cadence:failure:2d:106:RED'
contains 'a green run carries no flag (HIMMEL-9247)' "$cg_line" 'ci:success:3h:101,'
contains 'verbose labels the field (HIMMEL-9247)' "$(cg_tick --verbose)" 'ci cadence: ci:success'
# (d) a second tick inside the interval makes no gh call
cg_n="$(wc -l < "$cg9247/calls" | tr -d ' ')"
cg_tick >/dev/null
same 'a second tick inside the interval makes no gh call (HIMMEL-9247)' "$(wc -l < "$cg9247/calls" | tr -d ' ')" "$cg_n"
same 'the first read made one call per workflow (HIMMEL-9247)' "$cg_n" '7'
# a run older than the interval is read again
CI_CADENCE_INTERVAL_SEC=0 CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" >/dev/null 2>&1
same 'interval 0 reads again (HIMMEL-9247)' "$(wc -l < "$cg9247/calls" | tr -d ' ')" '14'
# (c) a skipped run is flagged; a run that gated itself on purpose concludes success and is not
cg_seed; cg_row pages.yml completed skipped '4 hours' 204
contains 'a skipped scheduled run reads SKIP (HIMMEL-9247)' "$(cg_tick | cadence_of)" 'pages:skipped:4h:204:SKIP'
cg_seed; cg_row snyk-weekly.yml completed success '3 days' 205
not_contains 'a gated run that concluded success is not flagged (HIMMEL-9247)' "$(cg_tick | cadence_of)" 'snyk-weekly:success:3d:205:'
# no scheduled run inside 1.5 times the period reads MISSED; a running run flags nothing
cg_seed; cg_row fork-drift.yml completed success '40 hours' 206
contains 'a scheduled run older than 1.5 periods reads MISSED (HIMMEL-9247)' "$(cg_tick | cadence_of)" 'fork-drift:success:40h:206:MISSED'
cg_seed; cg_row ci.yml in_progress - '50 hours' 207
not_contains 'a run still in progress is not flagged (HIMMEL-9247)' "$(cg_tick | cadence_of)" '207:MISSED'
# (e) gh unreadable: cadence=?, the tick still answers
cg_seed
cg_bad="$(CG_FAIL=1 cg_tick)"
same 'an unreadable gh reads cadence=? (HIMMEL-9247)' "$(printf '%s\n' "$cg_bad" | cadence_of)" '?'
contains 'a tick with gh unreadable still prints its line (HIMMEL-9247)' "$cg_bad" 'TICK '
printf '%s\n' '#!/bin/sh' 'echo "not a run row"' > "$cg9247/gh-junk"
chmod +x "$cg9247/gh-junk"
rm -f "$cg9247/cache"
not_contains 'a gh answer that is no run row leaves cadence= off the line (HIMMEL-9247)' "$(CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh-junk" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" 2>/dev/null)" 'cadence='
rm -rf "$cg9247"

# --- the station row for ledger-drift: ci-cadence.sh arm / status / run / disarm on a stub
# crontab, a stub ledger check and a stub alert sink, in a temp HOME. The crontab is written only through
# crontab_locked_rmw: two cadences armed at once on a SLOW crontab (its read sleeps) both land. RED
# control (before ci-cadence.sh has the verbs): the first arm prints a usage line and installs nothing.
sr="$W/station9247"
mkdir -p "$sr/home"
# shellcheck disable=SC2016  # the stubs' own $-expressions must stay literal
printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-l" ]; then cat "$SR_TAB"; [ -z "${SR_SLOW:-}" ] || sleep 1; else cat > "$SR_TAB"; fi\n' > "$sr/crontab"  # read-sink-ok: a stub crontab written into the test sandbox, the suite names the file
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '#!/usr/bin/env bash\necho "ledger-drift ran" ; exit "${SR_RC:-0}"\n' > "$sr/ledger.sh"
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '#!/usr/bin/env bash\necho "$*" >> "$SR_ALERTS"\n' > "$sr/alert.sh"
chmod +x "$sr/crontab"
printf '0 1 * * * /other/job # HIMMEL-Other\n' > "$sr/tab"
sr_cad() { HOME="$sr/home" HIMMEL_CRONTAB_LOCK="$sr/lock" SR_TAB="$sr/tab" SR_ALERTS="$sr/alerts" CICADENCE_CRONTAB="$sr/crontab" CICADENCE_RUNNER_DIR="$sr/runner" CICADENCE_LEDGER_SCRIPT="$sr/ledger.sh" CICADENCE_ALERT="$sr/alert.sh" bash "$HERE/ci-cadence.sh" "$@"; }
sr_n() { grep -c "# $1" "$sr/tab" || true; }  # swallow-ok: grep -c prints 0 and exits 1 on no match
sr_cad arm --dry-run >/dev/null 2>&1
same 'arm --dry-run installs nothing (HIMMEL-9247)' "$(sr_n HIMMEL-LedgerDrift)" '0'
sr_cad arm >/dev/null 2>&1
same 'arm installs one HIMMEL-LedgerDrift row (HIMMEL-9247)' "$(sr_n HIMMEL-LedgerDrift)" '1'
same 'arm keeps the other cron line (HIMMEL-9247)' "$(sr_n HIMMEL-Other)" '1'
contains 'the default time is 09:20 (HIMMEL-9247)' "$(cat "$sr/tab")" '20 09 * * * '
sr_cad arm >/dev/null 2>&1
same 'a second arm refuses with rc 3 (HIMMEL-9247)' "$?" '3'
contains 'status says ARMED (HIMMEL-9247)' "$(sr_cad status 2>&1)" 'ARMED      HIMMEL-LedgerDrift'
sr_cad run >/dev/null 2>&1
same 'run on a balanced ledger exits 0 (HIMMEL-9247)' "$?" '0'
contains 'a clean run clears the alert (HIMMEL-9247)' "$(cat "$sr/alerts")" 'clear ledger-drift'
SR_RC=1 sr_cad run >/dev/null 2>&1
same 'run on a drifted ledger exits 1 (HIMMEL-9247)' "$?" '1'
contains 'a failed run reports through cadence-alert fail (HIMMEL-9247)' "$(cat "$sr/alerts")" 'fail ledger-drift the shard ledger check exited 1'
sr_cad disarm >/dev/null 2>&1
same 'disarm removes the row (HIMMEL-9247)' "$(sr_n HIMMEL-LedgerDrift)" '0'
same 'disarm keeps the other cron line (HIMMEL-9247)' "$(sr_n HIMMEL-Other)" '1'
# two cadences armed at once on a slow crontab both land (the cadence lock)
printf '#!/usr/bin/env bash\necho gen\n' > "$sr/gen.sh"
mr_env() { HOME="$sr/home" HANDOVER_DIR="$sr/ho" HIMMEL_CRONTAB_LOCK="$sr/lock" SR_TAB="$sr/tab" SR_SLOW=1 MORNINGREPORT_CRONTAB="$sr/crontab" MORNINGREPORT_RUNNER_DIR="$sr/mr-runner" MORNINGREPORT_GENERATOR="$sr/gen.sh" "$@"; }
mkdir -p "$sr/ho"
mr_env bash "$HERE/../morning-report-cadence.sh" arm >/dev/null 2>&1 &
sr_p1=$!
SR_SLOW=1 sr_cad arm >/dev/null 2>&1 &
sr_p2=$!
wait "$sr_p1" "$sr_p2"
same 'two cadences armed at once on a slow crontab both land (HIMMEL-9247)' "$(sr_n HIMMEL-LedgerDrift)$(sr_n HIMMEL-MorningReport)$(sr_n HIMMEL-Other)" '111'
rm -rf "$sr"

# --- review=<date>:<age>:<failures>:<new>:<new 5+>:<filed>[:CAPPED][:STALE] (decision 593): the daily failure
# review as one more scheduled row, a local read of the newest failure-review-<date>.md and its .json sidecar
# in HIMMEL_FAILURE_REVIEW_DIR. RED control (tick.sh before this change): the line never carries review=.
rv="$W/review593"
mkdir -p "$rv"
review_of() { sed -nE 's/.* review=([^ ]*).*/\1/p'; }
rv_tick() { HIMMEL_FAILURE_REVIEW_DIR="$rv" bash "$SUT" "$@" 2>/dev/null; }
rv_write() { # <date> <age as touch -d reads it> <sidecar json>
    printf '## Failure review\n' > "$rv/failure-review-$1.md"
    printf '%s\n' "$3" > "$rv/failure-review-$1.json"
    touch -d "$2 ago" "$rv/failure-review-$1.md"  # gnu-ok: Linux-only kit
}
rv_json_filed='{"totals":{"rows":100,"classes":4,"workers":9},"classes":[{"class":"denied/a","rows":7,"recurring":false},{"class":"error/b","rows":1,"recurring":false},{"class":"error/c","rows":50,"recurring":true},{"class":"traj/x","rows":9,"recurring":false}],"routing":[{"decision":"filed","class":"denied/a","ticket":"HIMMEL-9256"},{"decision":"filed","class":"error/c","ticket":"HIMMEL-9257"},{"decision":"commented","class":"x","ticket":"HIMMEL-1"},{"decision":"capped","class":"y"}]}'
rv_json_quiet='{"totals":{"rows":100,"classes":2,"workers":9},"classes":[{"class":"error/b","rows":1,"recurring":false},{"class":"error/c","rows":50,"recurring":true}],"routing":[{"decision":"commented","class":"x","ticket":"HIMMEL-1"}]}'
rv_write 2026-11-05 '2 hours' "$rv_json_filed"
same 'a fresh review reads its age, failures, new classes, big new classes, filed keys and the cap (decision 593)' "$(rv_tick | review_of)" '2026-11-05:2h:100:2:1:HIMMEL-9256+HIMMEL-9257:CAPPED'
contains 'verbose labels the failure review (decision 593)' "$(rv_tick --verbose)" 'failure review: 2026-11-05:2h:100:2:1:'
rv_write 2026-11-05 '30 hours' "$rv_json_filed"
same 'a review older than 26 h reads STALE (decision 593)' "$(rv_tick | review_of)" '2026-11-05:30h:100:2:1:HIMMEL-9256+HIMMEL-9257:CAPPED:STALE'
rv_write 2026-11-05 '3 hours' "$rv_json_quiet"
same 'a 1-count new class files nothing and flags nothing (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:100:1:0:-'
rm -f "$rv/failure-review-2026-11-05.json"
same 'a review with no sidecar reads ? for the counts (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:?:?:?:-'
rm -f "$rv"/*
not_contains 'no review file leaves review= off the line (decision 593)' "$(rv_tick)" 'review='
rm -rf "$rv"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-fields.sh'
    exit 0
fi
printf 'FAIL - test-tick-fields.sh (%s failure(s))\n' "$fails"
exit 1
