#!/usr/bin/env bash
# test-tick-repair.sh — tick.sh held=<n>:<sig8>, unfiled=<n>, repair=off:<why> and the detached
# `jira release repair <R> --apply --repo <slug>` launch. The tick only reads the
# release dir's repair-held.json / repair-status / repair-reviewed / repair.lock and tests whether
# repair-signature is there; the repair engine (S5b-2) clears the signature itself. The state read and
# the repair are stubbed: nothing touches Jira, the real journal or the real ledgers, and no Fix Version is written.
#
# PLATFORM GUARD: The chief kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - tick.sh is Linux-only by design (tick.sh:11-12); HIMMEL-7641"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
DOCPAGE="$HERE/../../../docs/handover/chief-sections/release-manager.md"
CHIEFWAIT="$HERE/chief-wait.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-repair-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/chief-work/chain"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) printf '%s\n' free; exit 0 ;;
esac
exit 2
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" 28\n' > "$W/repo/scripts/context-fill.sh"
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\ncat "$PS_FIXTURE"\n' > "$W/bin/ps"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/bun"
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"
cat > "$W/repo/scripts/lib/usage-preflight.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' >&2
printf '%s\n' PROCEED
STUB
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/usage-preflight.sh" "$W/bin/"*
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
git init -q "$W/repo"

unset HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER  # a worker session sets the fence variables; the rows that need them set them
export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/chief-work" TICK_PROJECTS_DIR="$W/projects"
export TOKEN=t WORKERS=''
export HIMMEL_RELEASE_STATE_DIR="$W/releases" USER_SLUG=tester
export HIMMEL_VERSION_WRITES="$W/journal.jsonl"
export NEXT_DISPATCH_MIRROR="$W/mirror/TESTKEY"
RDIR="$W/releases/R1"
mkdir -p "$RDIR"

# the state read: `release state <R> --json`, its body is $W/state.json; the repair stub logs its argv and JIRA_PROJECT_KEY.
printf '#!/bin/sh\necho "$@" >> "%s/state-asked"\ncat "%s/state.json"\nexit "${TICK_RMQ_EXIT:-0}"\n' "$W" "$W" > "$W/rmq-probe.sh"
printf '#!/bin/sh\necho "$@" >> "%s/rmrun-ran"\n' "$W" > "$W/rmrun-probe.sh"
printf '#!/bin/sh\necho "$* key=$JIRA_PROJECT_KEY" >> "%s/repair-ran"\n' "$W" > "$W/repair-probe.sh"
# the dead launcher: logs one line to a tally file and exits 127, so the probe never runs and no run ends
printf '#!/bin/sh\necho x >> "%s/launch-tried"\nexit 127\n' "$W" > "$W/bin/deadlaunch"
chmod +x "$W/bin/deadlaunch"
export TICK_RMQ_PROBE="$W/rmq-probe.sh" TICK_RMRUN_PROBE="$W/rmrun-probe.sh" TICK_REPAIR_PROBE="$W/repair-probe.sh" TICK_RMRUN_LAUNCHER=env

SIG64=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
# mkstate <leaks (unauthorized) as a JSON list> <operator head> <requests head> <mirror head>; no open requests, so no rm-run.
mkstate() { printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":null,"requests":{"open":[],"claimed":[],"oldest_open":null},"leaks":{"unauthorized":%s,"ruled_in_non_member":[]},"heads":{"rulings":"x","operator":"%s","events":"e","requests":"%s","mirror":"%s"}}\n' "$1" "$2" "$3" "$4" > "$W/state.json"; }
base_state() { mkstate '["K-1@v1.1.4"]' op1 rq1 mi1; }
mkdoc() { printf '# chief\nrelease: %s\n' "$1" > "$W/handover/chief.md"; }
heldjson() { # <held> <unfiled>
    printf '{"release":"R1","held":%s,"unfiled":%s,"held_signature":"%s","classes":[]}\n' "$1" "$2" "$SIG64" > "$RDIR/repair-held.json"
}
reset() {
    rm -f "$W/repair-ran" "$W/launch-tried" "$W/rmrun-ran" "$W/state-asked" "$W/journal.jsonl"
    rm -rf "$W/state" "$RDIR"; mkdir -p "$RDIR"
    git -C "$W/repo" remote remove origin 2>/dev/null
    git -C "$W/repo" remote add origin git@github.com:acme/widgets.git
    base_state
    mkdoc R1
}
reviewed() { printf '2026-11-03T00:00:00Z\n' > "$RDIR/repair-reviewed"; touch -d '2 days ago' "$RDIR/repair-reviewed"; }  # older than every stamp a row writes, so it never reads as an end
age_log() { touch -d '20 minutes ago' "$RDIR/repair-run.log"; }
# the launch stamp: aging is a content rewrite, never touch -d (the tick reads the content)
stamp() { printf '%s %s\n' "$(( $(date +%s) - $1 ))" "$2" > "$RDIR/repair-launch"; }  # <age-secs> <k>
stamp_count() { awk '{print $2}' "$RDIR/repair-launch" 2>/dev/null; }
age_stamp() { stamp 1200 "$(stamp_count)"; }
stamp_is() { [ "$(cat "$RDIR/repair-launch" 2>/dev/null)" = "$1" ]; }  # <line>
tried() { # wait up to 5 s for the dead launcher to log <n> lines, then print how many it logged
    local n="$1" i=0
    while [ "$( [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0)" -lt "$n" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0
}
none_tried() { sleep 1; [ -f "$W/launch-tried" ] && wc -l < "$W/launch-tried" | tr -d ' ' || echo 0; }
tick() { bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null; }
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
launched() { # wait up to 5 s for the detached stub to log <n> lines, then print how many it logged
    local n="$1" i=0
    while [ "$( [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0)" -lt "$n" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0
}
none_launched() { sleep 1; [ -f "$W/repair-ran" ] && wc -l < "$W/repair-ran" | tr -d ' ' || echo 0; }

# --- held= and unfiled= (read from repair-held.json; elided at zero)
reset; heldjson 3 2
out1="$(tick)"; out2="$(tick)"
check 'held field prints each tick while nonzero, elided at zero' '3:abcdef01 3:abcdef01' "$(field held "$out1") $(field held "$out2")"
heldjson 0 0
out="$(tick)"
check 'held field prints each tick while nonzero, elided at zero (zero elides)' '' "$(field held "$out")"
check 'unfiled field likewise' '' "$(field unfiled "$out")"
heldjson 3 2
out1="$(tick)"; out2="$(tick)"
check 'unfiled field likewise (nonzero, each tick)' '2 2' "$(field unfiled "$out1") $(field unfiled "$out2")"
rm -f "$RDIR/repair-held.json"
out="$(tick)"
check 'no held file prints neither held nor unfiled' '' "$(field held "$out")$(field unfiled "$out")"

reset; heldjson 3 2
out1="$(tick)"
printf '{"ts":"2026-11-03T00:00:00Z","key":"K-9"}\n' >> "$W/journal.jsonl"
out2="$(tick)"
check 'journal head alone leaves held sig unchanged' "$(field held "$out1")" "$(field held "$out2")"

# --- the wake key: chief-wait.sh names no held/unfiled/repair field (a read, not a change)
fields_line="$(grep -E '^[[:space:]]*for f in .*; do' "$CHIEFWAIT" | head -n 1)"
case "$fields_line" in *workers*) ;; *) fields_line="" ;; esac
res=absent
case " $fields_line " in *" held "*|*" unfiled "*|*" repair "*) res=present ;; esac
[ -n "$fields_line" ] || res=unread
check 'held and repair fields stay out of the wake key' absent "$res"

# --- the launch
reset; reviewed
out="$(tick)"
check 'marker present launches apply' '1' "$(launched 1)"
check 'marker present launches apply (the verb and release)' 'release repair R1 --apply --repo acme/widgets' "$(sed -n 1p "$W/repair-ran" | sed 's/^\(.*--repo [^ ]*\).*$/\1/')"
check 'marker present: no repair=off field' '' "$(field repair "$out")"
check 'the tick writes the run signature on launch (one line, 64 hex)' 1 "$(grep -cE '^[0-9a-f]{64}$' "$RDIR/repair-signature")"
check 'launch sets JIRA_PROJECT_KEY' 'key=TESTKEY' "$(sed -n 1p "$W/repair-ran" | sed 's/^.* \(key=[^ ]*\)$/\1/')"
check 'the launch output goes to repair-run.log in the release dir' 1 "$([ -e "$RDIR/repair-run.log" ] && echo 1 || echo 0)"
check 'the state read is asked once for the same release' 'R1 --json' "$(sed -n 1p "$W/state-asked")"

reset; reviewed; git -C "$W/repo" remote set-url origin https://github.com/other/thing.git
tick >/dev/null
check 'launch carries --repo from the remote' 'other/thing' "$(launched 1 >/dev/null; sed -n 's/^.*--repo \([^ ]*\) .*$/\1/p' "$W/repair-ran" | head -n 1)"

reset; reviewed; git -C "$W/repo" remote remove origin
out="$(tick)"
check 'no remote prints repair=off:bad-input' 'off:bad-input' "$(field repair "$out")"
check 'no remote starts nothing' 0 "$(none_launched)"
check 'no remote writes no signature' 0 "$([ -e "$RDIR/repair-signature" ] && echo 1 || echo 0)"

reset
out="$(tick)"
check 'no review marker starts no apply and prints repair=off:unreviewed' 'off:unreviewed' "$(field repair "$out")"
check 'no review marker starts no apply (negative control: nothing ran)' 0 "$(none_launched)"
check 'no review marker writes no signature' 0 "$([ -e "$RDIR/repair-signature" ] && echo 1 || echo 0)"

reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log
out="$(tick)"
check 'unchanged signature starts no process' 1 "$(none_launched)"

# each input moves the run signature; the gap is aged each time so only the signature decides
trigger() { # <name> <leaks> <operator> <requests> <mirror> <journal line or ''>
    reset; reviewed
    tick >/dev/null; launched 1 >/dev/null
    age_log
    mkstate "$2" "$3" "$4" "$5"
    [ -z "$6" ] || printf '%s\n' "$6" >> "$W/journal.jsonl"
    tick >/dev/null
    check "$1 triggers a run" 2 "$(launched 2)"
}
trigger 'leak set' '["K-1@v1.1.4","K-2@v1.1.4"]' op1 rq1 mi1 ''
trigger 'operator head' '["K-1@v1.1.4"]' op2 rq1 mi1 ''
trigger 'requests head' '["K-1@v1.1.4"]' op1 rq2 mi1 ''
trigger 'mirror head' '["K-1@v1.1.4"]' op1 rq1 mi2 ''
trigger 'journal head' '["K-1@v1.1.4"]' op1 rq1 mi1 '{"key":"K-9"}'
# an event-head-only move is not an input
reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log
sed -i 's/"events":"e"/"events":"e2"/' "$W/state.json"  # gnu-ok: console kit is Linux-only
tick >/dev/null
check 'leak set, operator, requests, journal and mirror heads each trigger (an events head alone does not)' 1 "$(none_launched)"

# --- the gap
reset; reviewed
tick >/dev/null; launched 1 >/dev/null
rm -f "$RDIR/repair-signature"   # a capped run with progress cleared it
out="$(tick)"
check 'capped run with progress runs again, no sooner than the gap (inside the gap: nothing)' 1 "$(none_launched)"
age_log
tick >/dev/null
check 'capped run with progress runs again, no sooner than the gap' 2 "$(launched 2)"

reset; reviewed
tick >/dev/null; launched 1 >/dev/null
age_log   # a capped run with no progress left the signature in place
tick >/dev/null
check 'capped run with no progress does not' 1 "$(none_launched)"

reset; reviewed
printf 'error\nJira live read of K-1 failed: HTTP 503\n' > "$RDIR/repair-status"
out="$(tick)"
check 'error status prints repair=off:error' 'off:error' "$(field repair "$out")"
reset; reviewed
printf 'error\nboom\n' > "$RDIR/repair-status"
touch "$RDIR/repair-run.log"          # last launch just now, signature gone
tick >/dev/null
check 'errored run is retried, no sooner than the gap (inside the gap: nothing)' 0 "$(none_launched)"
age_log
out="$(tick)"
check 'errored run is retried, no sooner than the gap' 1 "$(launched 1)"
check 'errored run still reads repair=off:error until a clean run clears the status' 'off:error' "$(field repair "$out")"

reset; reviewed
printf 'mirror-unknown\nthe mirror is UNKNOWN\n' > "$RDIR/repair-status"
out="$(tick)"
check 'stop prints repair=off with its reason' 'off:mirror-unknown' "$(field repair "$out")"

# --- a launch that left no end record: the dead launcher exits 127 and writes nothing
export TICK_RMRUN_LAUNCHER="$W/bin/deadlaunch"
reset; reviewed
tick >/dev/null
check '1a lost launch: the first tick tries once' 1 "$(tried 1)"
check '1a lost launch: the first tick writes a stamp with count 0' 0 "$(stamp_count)"
s1a="$(cat "$RDIR/repair-launch" 2>/dev/null)"
age_log
out="$(tick)"
check '1b log aged only: no new try' 1 "$(none_tried 1)"
check '1b log aged only: the stamp is unchanged' 1 "$(stamp_is "$s1a" && echo 1 || echo 0)"
check '1b log aged only: no repair=off:lost field' '' "$(field repair "$out")"
touch "$RDIR/repair-run.log"; age_stamp
s1c="$(cat "$RDIR/repair-launch" 2>/dev/null)"
tick >/dev/null
check '1c stamp aged only: no new try (the log gap holds)' 1 "$(none_tried 1)"
check '1c stamp aged only: the stamp is unchanged' 1 "$(stamp_is "$s1c" && echo 1 || echo 0)"
age_log; age_stamp
out="$(tick)"
check '1d both aged: a second try' 2 "$(tried 2)"
check '1d both aged: the field reads off:lost' 'off:lost' "$(field repair "$out")"

# a pid that is dead and reaped, so no zombie keeps /proc/<pid>
deadpid() { sleep 60 & local p=$!; kill "$p"; wait "$p" 2>/dev/null; echo "$p"; }
lost_field() { # <name> <want> <tick output>
    check "$1" "$2" "$(field repair "$3")"
}

# 2 control, a clean run: the probe rewrites repair-reviewed, so the run reached its end
printf '#!/bin/sh\ntouch "%s/repair-reviewed"\necho "$*" >> "%s/repair-ran"\n' "$RDIR" "$W" > "$W/clean-probe.sh"
reset; reviewed
TICK_RMRUN_LAUNCHER=env TICK_REPAIR_PROBE="$W/clean-probe.sh" tick >/dev/null
check '2 clean run: launched once' 1 "$(launched 1)"
age_log; age_stamp
out="$(TICK_RMRUN_LAUNCHER=env TICK_REPAIR_PROBE="$W/clean-probe.sh" tick)"
check '2 clean run: no relaunch after the gap' 1 "$(none_launched)"
lost_field '2 clean run: no repair= field' '' "$out"

# 3 control, a stop: the probe writes repair-status, so the run reached its end
printf '#!/bin/sh\nprintf "mirror-unknown\\nx\\n" > "%s/repair-status"\necho "$*" >> "%s/repair-ran"\n' "$RDIR" "$W" > "$W/stop-probe.sh"
reset; reviewed
TICK_RMRUN_LAUNCHER=env TICK_REPAIR_PROBE="$W/stop-probe.sh" tick >/dev/null
check '3 stop: launched once' 1 "$(launched 1)"
age_log; age_stamp
out="$(TICK_RMRUN_LAUNCHER=env TICK_REPAIR_PROBE="$W/stop-probe.sh" tick)"
check '3 stop: no relaunch after the gap' 1 "$(none_launched)"
lost_field '3 stop: the field reads off:mirror-unknown' 'off:mirror-unknown' "$out"

# 4 the bound (I2): wait(3) is 2400 s at the default gap
reset; reviewed; age_log; stamp 1500 2
out="$(tick)"
check '4 bound: inside wait(3) nothing launches' 0 "$(none_tried 0)"
lost_field '4 bound: inside wait(3) the field reads off:lost' 'off:lost' "$out"
stamp 2500 2
tick >/dev/null
check '4 bound: past wait(3) it launches' 1 "$(tried 1)"
check '4 bound: the count reads 3' 3 "$(stamp_count)"

# 5 the cap (I2): the doubling stops at 6 h, so k=100 neither overflows nor waits longer than the cap
reset; reviewed; age_log; stamp 21000 100
tick >/dev/null
check '5 cap: inside the cap nothing launches' 0 "$(none_tried 0)"
stamp 21700 100
tick >/dev/null
check '5 cap: past the cap it launches' 1 "$(tried 1)"
check '5 cap: the count reads 101' 101 "$(stamp_count)"

# 6 a live lock (I1)
reset; reviewed; age_log; stamp 1200 0
sleep 60 &
holder=$!
printf '%s\n' "$holder" > "$RDIR/repair.lock"
out="$(tick)"
check '6 live lock: nothing launches' 0 "$(none_tried 0)"
lost_field '6 live lock: no off:lost' '' "$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 7 a mid-run kill: the lock names a dead pid
reset; reviewed; age_log; stamp 1200 0
deadp="$(deadpid)"
printf '%s\n' "$deadp" > "$RDIR/repair.lock"
out="$(tick)"
check '7 mid-run kill: it launches' 1 "$(tried 1)"
lost_field '7 mid-run kill: the field reads off:lost' 'off:lost' "$out"

# 8 a lock from before the boot, naming a live pid, is not live
reset; reviewed; age_log; stamp 1200 0
sleep 60 &
holder=$!
printf '%s\n' "$holder" > "$RDIR/repair.lock"
touch -d @1 "$RDIR/repair.lock"
out="$(tick)"
check '8 pre-boot lock: it launches' 1 "$(tried 1)"
lost_field '8 pre-boot lock: the field reads off:lost' 'off:lost' "$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 9 the reset (I3): a run that reached its end puts the next launch at count 0
reset; reviewed; age_log; stamp 1200 3
touch "$RDIR/repair-reviewed"
mkstate '["K-1@v1.1.4"]' op2 rq1 mi1
out="$(tick)"
check '9 reset: it launches' 1 "$(tried 1)"
check '9 reset: the count reads 0' 0 "$(stamp_count)"
lost_field '9 reset: no off:lost' '' "$out"

# 12 precedence: a stale error status older than the stamp loses to lost
reset; reviewed; age_log; stamp 1200 0
printf 'error\nboom\n' > "$RDIR/repair-status"; touch -d '3 days ago' "$RDIR/repair-status"
out="$(tick)"
lost_field '12 precedence: lost beats a stale error' 'off:lost' "$out"

# 13 a malformed stamp reads as none: no launch on the same signature, a launch on a changed one
for bad in garbage '08 0' '5' "$(( $(date +%s) + 3600 )) 1"; do
    reset; reviewed
    tick >/dev/null
    check "13 malformed stamp '$bad': the first tick launches" 1 "$(tried 1)"
    printf '%s\n' "$bad" > "$RDIR/repair-launch"; age_log
    out="$(tick)"
    check "13 malformed stamp '$bad': the same signature launches nothing" 1 "$(none_tried 1)"
    lost_field "13 malformed stamp '$bad': no off:lost" '' "$out"
    mkstate '["K-1@v1.1.4"]' op2 rq1 mi1; age_log
    tick >/dev/null
    check "13 malformed stamp '$bad': a changed signature launches" 2 "$(tried 2)"
    check "13 malformed stamp '$bad': the stamp is rewritten with count 0" 0 "$(stamp_count)"
done

# 14 a zero gap does not turn the backoff off (I2): base is floored at 60
reset; reviewed
TICK_RMRUN_MIN_SECS=0 tick >/dev/null
check '14 zero gap: the first tick launches' 1 "$(tried 1)"
stamp 10 0
out="$(TICK_RMRUN_MIN_SECS=0 tick)"
check '14 zero gap: inside the floor nothing launches' 1 "$(none_tried 1)"
lost_field '14 zero gap: no off:lost' '' "$out"

# 15 a pending launch after a lost one (I2): a changed signature does not shorten the wait
reset; reviewed; stamp 10 1
printf '%064d\n' 0 > "$RDIR/repair-signature"
out="$(TICK_RMRUN_MIN_SECS=0 tick)"
check '15 pending after lost: nothing launches' 0 "$(none_tried 0)"
lost_field '15 pending after lost: the field reads off:lost' 'off:lost' "$out"

# 16 no reset on a signature change (Q5)
reset; reviewed; age_log; stamp 2500 2
printf '%064d\n' 0 > "$RDIR/repair-signature"
tick >/dev/null
check '16 no reset: it launches' 1 "$(tried 1)"
check '16 no reset: the count reads 3' 3 "$(stamp_count)"

# 17 the stamp write fails (I4): nothing launches and the signature is not written
reset; reviewed
mkdir "$RDIR/repair-launch"
tick >/dev/null
check '17 stamp write fails: nothing launches' 0 "$(none_tried 0)"
check '17 stamp write fails: no signature' 0 "$([ -e "$RDIR/repair-signature" ] && echo 1 || echo 0)"

# 18 an EPERM pid is live (I1); pid 1 is probe-able when this user may signal it, so the row is skipped then
if kill -0 1 2>/dev/null; then
    pass '18 EPERM pid: skipped (pid 1 is probe-able for this user)'
else
    reset; reviewed; age_log; stamp 1200 0
    printf '1\n' > "$RDIR/repair.lock"
    out="$(tick)"
    check '18 EPERM pid: nothing launches' 0 "$(none_tried 0)"
    lost_field '18 EPERM pid: no off:lost' '' "$out"
fi

# 19 a leading-zero gap is decimal, not octal
reset; reviewed; age_log; stamp 900 0
out="$(TICK_RMRUN_MIN_SECS=0800 tick)"
check '19 leading-zero gap: it launches' 1 "$(tried 1)"
lost_field '19 leading-zero gap: the field reads off:lost' 'off:lost' "$out"
export TICK_RMRUN_LAUNCHER=env

# --- the fence and the lock
reset; reviewed
for fence in HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER; do
    rm -f "$W/repair-ran" "$RDIR/repair-signature"
    out="$(env "$fence=1" bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null)"
    check "fence variables skip the launch and write no signature ($fence: no process)" 0 "$(none_launched)"
    check "fence variables skip the launch and write no signature ($fence: no signature)" 0 "$([ -e "$RDIR/repair-signature" ] && echo 1 || echo 0)"
    check "fence variables skip the launch and write no stamp ($fence: no repair-launch)" 0 "$([ -e "$RDIR/repair-launch" ] && echo 1 || echo 0)"
done
out="$(tick)"
check 'fence variables skip the launch and write no signature (negative control: unset, it launches)' 1 "$(launched 1)"

reset; reviewed
sleep 60 &
holder=$!
printf '%s\n' "$holder" > "$RDIR/repair.lock"
tick >/dev/null
check 'second chief does not start a second run' 0 "$(none_launched)"
check 'second chief does not start a second run (no signature written)' 0 "$([ -e "$RDIR/repair-signature" ] && echo 1 || echo 0)"
check 'second chief does not start a second run (the lock is read, not taken)' "$holder" "$(cat "$RDIR/repair.lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
tick >/dev/null
check 'a stale lock (owner gone) does not block the launch' 1 "$(launched 1)"

# --- no release line
reset; reviewed; heldjson 3 2
printf '# chief\n' > "$W/handover/chief.md"
out="$(tick)"
check 'no release line prints nothing' '' "$(field held "$out")$(field unfiled "$out")$(field repair "$out")"
check 'no release line launches nothing' 0 "$(none_launched)"

# --- the doc
doc_ok=1
for f in 'held=' 'unfiled=' 'repair=off:'; do grep -qF "$f" "$DOCPAGE" || doc_ok=0; done
check 'the doc names all three fields' 1 "$doc_ok"
doc_flat="$(tr '\n' ' ' < "$DOCPAGE")"
doc_lost=0; case "$doc_flat" in *'`lost` (a launched run'*) doc_lost=1 ;; esac
check 'the doc names the lost reason' 1 "$doc_lost"
doc_rule=0; case "$doc_flat" in *'or when the last launch left no end record'*) doc_rule=1 ;; esac
check 'the doc states the retry in the launch rule' 1 "$doc_rule"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
