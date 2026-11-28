#!/usr/bin/env bash
# test-launch-confirm.sh - Exercises launch-confirm.sh: a launch attempt that ends LAUNCH-OK with its claude session seen
# confirms; one that is refused, exits 0 with no session, or never starts is reported on stderr, in the launch log and in
# the chief inbox, and only the newest fresh attempt in a reused log decides.
# Scratch dirs and a PGREP_CMD stub only; never a real session or the real bridge.
#
# Run: bash scripts/handover/chief-kit/test-launch-confirm.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/launch-confirm.sh"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi; }
has() { grep -qF -e "$2" "$1" 2>/dev/null && echo yes || echo no; }
says() { grep -qF -e "$2" <<< "$1" && echo yes || echo no; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/launch-confirm-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" BRIDGE_ROOT="$WORK/bridge"
unset HIMMEL_CONSOLE_NAME LAUNCH_CONFIRM_SECS
mkdir -p "$HOME" "$BRIDGE_ROOT/consoles"
inbox="$BRIDGE_ROOT/consoles/lc-chief.md"; : > "$inbox"
cat > "$WORK/pgrep" <<'EOF'
#!/usr/bin/env bash
seen="$(cat "$(dirname "$0")/SEEN" 2>/dev/null)"
case "$*" in *"-n ${seen//./\\.}"*) [ -n "$seen" ] && { echo 4242; exit 0; } ;; esac
exit 1
EOF
chmod +x "$WORK/pgrep"
export PGREP_CMD="$WORK/pgrep"
now=$(date +%s) fresh=$(( $(date +%s) + 5 ))
start_line() { printf '2026-11-21_19:00:00 LAUNCH-START %s epoch=%s\n' "$1" "$2"; }

echo PROJ-1-N1-up > "$WORK/SEEN"
{ start_line PROJ-1-N1-up "$fresh"; echo '2026-11-21_19:00:05 LAUNCH-OK PROJ-1-N1-up launched'; } > "$WORK/a.log"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 2 PROJ-1-N1-up "$WORK/a.log" 2>&1)" || rc=$?
check "(a) an attempt that ended LAUNCH-OK with its session seen exits 0" 0 "$rc"
check "(a) it prints LAUNCH-CONFIRMED with the pid" "LAUNCH-CONFIRMED PROJ-1-N1-up pid=4242" "$out"
check "(a) nothing reaches the chief inbox" 0 "$(wc -l < "$inbox" | tr -d ' ')"

: > "$WORK/SEEN"
{ start_line PROJ-1-N2-silent "$fresh"; echo '2026-11-21_19:00:05 LAUNCH-OK PROJ-1-N2-silent indeterminate'; } > "$WORK/b.log"
t0=$(date +%s)
rc=0; out="$(HIMMEL_CONSOLE_NAME=lc-chief bash "$SUT" --since "$now" --secs 2 PROJ-1-N2-silent "$WORK/b.log" 2>&1)" || rc=$?
check "(b) a launch that exited 0 but started no session exits 1" 1 "$rc"
check "(b) ... within the window" yes "$([ $(( $(date +%s) - t0 )) -le 5 ] && echo yes || echo no)"
check "(b) ... says LAUNCH-UNCONFIRMED on stderr" yes "$(says "$out" 'LAUNCH-UNCONFIRMED PROJ-1-N2-silent the launcher exited 0 but no claude session within 2s')"
check "(b) ... appends it to the launch log" yes "$(has "$WORK/b.log" 'LAUNCH-UNCONFIRMED PROJ-1-N2-silent the launcher exited 0 but no claude session within 2s')"
check "(b) ... and to the chief inbox (HIMMEL_CONSOLE_NAME)" yes "$(has "$inbox" "LAUNCH-UNCONFIRMED PROJ-1-N2-silent the launcher exited 0 but no claude session within 2s (log $WORK/b.log)")"

{ start_line PROJ-1-N3-refused "$fresh"; echo '2026-11-21_19:00:01 LAUNCH-REFUSED PROJ-1-N3-refused fleet-paused: managed worker has no manifest reference'; } > "$WORK/c.log"
t0=$(date +%s)
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 30 PROJ-1-N3-refused "$WORK/c.log" 2>&1)" || rc=$?
check "(c) a refused attempt exits 1" 1 "$rc"
check "(c) ... without waiting out the window" yes "$([ $(( $(date +%s) - t0 )) -le 3 ] && echo yes || echo no)"
check "(c) ... and the inbox carries the launcher's reason" yes "$(has "$inbox" 'LAUNCH-UNCONFIRMED PROJ-1-N3-refused the launcher refused: fleet-paused: managed worker has no manifest reference')"

echo PROJ-1-N4-stale > "$WORK/SEEN"
{ start_line PROJ-1-N4-stale "$fresh"; echo '2026-11-21_19:00:01 LAUNCH-REFUSED PROJ-1-N4-stale holds: a file is held'; } > "$WORK/d.log"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 2 PROJ-1-N4-stale "$WORK/d.log" 2>&1)" || rc=$?
check "(d) an older session with the name does not confirm a refused relaunch" 1 "$rc"
check "(d) ... which is reported as refused" yes "$(says "$out" 'LAUNCH-UNCONFIRMED PROJ-1-N4-stale the launcher refused: holds: a file is held')"

: > "$WORK/SEEN"
{ start_line PROJ-1-N5-retry "$((now - 5))"; echo '2026-11-21_18:59:01 LAUNCH-REFUSED PROJ-1-N5-retry an earlier refusal'; } > "$WORK/e.log"
( sleep 1; { start_line PROJ-1-N5-retry "$fresh"; echo '2026-11-21_19:00:05 LAUNCH-OK PROJ-1-N5-retry launched'; } >> "$WORK/e.log"; echo PROJ-1-N5-retry > "$WORK/SEEN" ) &
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 5 PROJ-1-N5-retry "$WORK/e.log" 2>&1)" || rc=$?
wait
check "(e) a reused log's earlier refusal does not fail the retry whose start lands after the confirm began" 0 "$rc"
check "(e) ... which confirms" "LAUNCH-CONFIRMED PROJ-1-N5-retry pid=4242" "$out"

: > "$WORK/SEEN"
{ start_line PROJ-1-N6-old "$((now - 600))"; echo '2026-11-21_18:50:00 LAUNCH-REFUSED PROJ-1-N6-old an old refusal'; } > "$WORK/f.log"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 1 PROJ-1-N6-old "$WORK/f.log" 2>&1)" || rc=$?
check "(f) only an attempt older than --since: not reported as that old refusal" no "$(says "$out" 'an old refusal')"
check "(f) ... but as no launch attempt started" yes "$(says "$out" "LAUNCH-UNCONFIRMED PROJ-1-N6-old no launch attempt started in $WORK/f.log within 1s")"
echo PROJ-1-N9-prior > "$WORK/SEEN"
{ start_line PROJ-1-N9-prior "$((now - 5))"; echo '2026-11-21_18:59:05 LAUNCH-OK PROJ-1-N9-prior launched'; } > "$WORK/j.log"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 1 PROJ-1-N9-prior "$WORK/j.log" 2>&1)" || rc=$?
check "(j) an earlier attempt's LAUNCH-OK and its running session do not confirm a launch that logged no start" 1 "$rc"
check "(j) ... reported as no launch attempt started" yes "$(says "$out" "LAUNCH-UNCONFIRMED PROJ-1-N9-prior no launch attempt started in $WORK/j.log within 1s")"
rc=0; out="$(bash "$SUT" --chief lc-chief --secs 1 --since "$((now - 20))" PROJ-1-N9-prior "$WORK/j.log" 2>&1)" || rc=$?
check "(j) a later check that passes --since from before that launch confirms it" "LAUNCH-CONFIRMED PROJ-1-N9-prior pid=4242" "$out"
: > "$WORK/SEEN"
start_line PROJ-1-N7-slow "$fresh" > "$WORK/g.log"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 1 PROJ-1-N7-slow "$WORK/g.log" 2>&1)" || rc=$?
check "(g) a launcher still running at the window's end exits 1" 1 "$rc"
check "(g) ... and says so" yes "$(says "$out" 'LAUNCH-UNCONFIRMED PROJ-1-N7-slow the launcher had not finished within 1s')"

rm -f "$inbox"
rc=0; out="$(bash "$SUT" --since "$now" --chief lc-chief --secs 0 PROJ-1-N8-noinbox "$WORK/h.log" 2>&1)" || rc=$?
check "(h) no chief inbox: exits 1" 1 "$rc"
check "(h) ... and does not create the inbox" no "$([ -e "$inbox" ] && echo yes || echo no)"

rc=0; bash "$SUT" --since "$now" "bad name" "$WORK/i.log" >/dev/null 2>&1 || rc=$?
check "(i) a session name outside the charset is a usage error" 2 "$rc"
rc=0; bash "$SUT" --since "$now" PROJ-1-N9 >/dev/null 2>&1 || rc=$?
check "(i) a missing log is a usage error" 2 "$rc"
rc=0; bash "$SUT" --since soon PROJ-1-N9 "$WORK/i.log" >/dev/null 2>&1 || rc=$?
check "(i) a non-numeric --since is a usage error" 2 "$rc"
rc=0; bash "$SUT" --chief lc-chief PROJ-1-N9 "$WORK/i.log" >/dev/null 2>&1 || rc=$?
check "(i) no --since is a usage error" 2 "$rc"

mkdir -p "$WORK/nosleep"
printf '#!/bin/sh\nexit 0\n' > "$WORK/nosleep/sleep"; chmod +x "$WORK/nosleep/sleep"
: > "$WORK/SEEN"
start_line PROJ-1-N10-wait "$fresh" > "$WORK/k.log"
rc=0; out="$(PATH="$WORK/nosleep:$PATH" bash "$SUT" --since "$now" --chief lc-chief PROJ-1-N10-wait "$WORK/k.log" 2>&1)" || rc=$?
check "(K1) the default window ends unconfirmed for a launcher still running" 1 "$rc"
check "(K1) ... after 240s" yes "$(says "$out" 'LAUNCH-UNCONFIRMED PROJ-1-N10-wait the launcher had not finished within 240s')"
rc=0; out="$(PATH="$WORK/nosleep:$PATH" bash "$SUT" --since "$now" --chief lc-chief --secs 3 PROJ-1-N10-wait "$WORK/k.log" 2>&1)" || rc=$?
check "(K1) --secs still sets the window" yes "$(says "$out" 'LAUNCH-UNCONFIRMED PROJ-1-N10-wait the launcher had not finished within 3s')"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-launch-confirm.sh"; exit 0; fi
echo "FAIL - test-launch-confirm.sh ($fails failure(s))"; exit 1
