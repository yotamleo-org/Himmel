#!/usr/bin/env bash
# test-launch-confirm.sh - Exercises launch-confirm.sh: a launch whose claude session is seen confirms; a launch that
# never starts one, or whose launcher refused, is reported on stderr, in the launch log and in the chief inbox.
# Scratch dirs and a PGREP_CMD stub only; never a real session or the real bridge.
#
# Run: bash scripts/handover/chief-kit/test-launch-confirm.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/launch-confirm.sh"

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi; }
has() { grep -qF -e "$2" "$1" 2>/dev/null && echo yes || echo no; }

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

echo PROJ-1-N1-up > "$WORK/SEEN"
rc=0; out="$(bash "$SUT" --chief lc-chief --secs 2 PROJ-1-N1-up "$WORK/a.log" 2>&1)" || rc=$?
check "(a) a seen session exits 0" 0 "$rc"
check "(a) it prints LAUNCH-CONFIRMED with the pid" "LAUNCH-CONFIRMED PROJ-1-N1-up pid=4242" "$out"
check "(a) nothing reaches the chief inbox" 0 "$(wc -l < "$inbox" | tr -d ' ')"

: > "$WORK/SEEN"
: > "$WORK/b.log"
t0=$(date +%s)
rc=0; out="$(HIMMEL_CONSOLE_NAME=lc-chief bash "$SUT" --secs 2 PROJ-1-N2-silent "$WORK/b.log" 2>&1)" || rc=$?
check "(b) no session exits 1" 1 "$rc"
check "(b) ... within the window" yes "$([ $(( $(date +%s) - t0 )) -le 5 ] && echo yes || echo no)"
check "(b) ... says LAUNCH-UNCONFIRMED on stderr" yes "$(printf '%s\n' "$out" | grep -qF 'LAUNCH-UNCONFIRMED PROJ-1-N2-silent no claude session within 2s' && echo yes || echo no)"
check "(b) ... appends it to the launch log" yes "$(has "$WORK/b.log" 'LAUNCH-UNCONFIRMED PROJ-1-N2-silent no claude session within 2s')"
check "(b) ... and to the chief inbox (HIMMEL_CONSOLE_NAME)" yes "$(has "$inbox" "LAUNCH-UNCONFIRMED PROJ-1-N2-silent no claude session within 2s (log $WORK/b.log)")"

printf '%s\n' '2026-11-21_19:00:00 armed: name=PROJ-1-N3-refused' '2026-11-21_19:00:01 LAUNCH-REFUSED PROJ-1-N3-refused fleet-paused: managed worker has no manifest reference' > "$WORK/c.log"
t0=$(date +%s)
rc=0; out="$(bash "$SUT" --chief lc-chief --secs 30 PROJ-1-N3-refused "$WORK/c.log" 2>&1)" || rc=$?
check "(c) a refused launch exits 1" 1 "$rc"
check "(c) ... without waiting out the window" yes "$([ $(( $(date +%s) - t0 )) -le 3 ] && echo yes || echo no)"
check "(c) ... and the inbox carries the launcher's reason" yes "$(has "$inbox" 'LAUNCH-UNCONFIRMED PROJ-1-N3-refused the launcher refused: fleet-paused: managed worker has no manifest reference')"

rm -f "$inbox"
rc=0; out="$(bash "$SUT" --chief lc-chief --secs 0 PROJ-1-N4-noinbox "$WORK/d.log" 2>&1)" || rc=$?
check "(d) exits 1" 1 "$rc"
check "(d) ... and does not create the inbox" no "$([ -e "$inbox" ] && echo yes || echo no)"

rc=0; bash "$SUT" "bad name" "$WORK/e.log" >/dev/null 2>&1 || rc=$?
check "(e) a session name outside the charset is a usage error" 2 "$rc"
rc=0; bash "$SUT" PROJ-1-N5 >/dev/null 2>&1 || rc=$?
check "(e) a missing log is a usage error" 2 "$rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-launch-confirm.sh"; exit 0; fi
echo "FAIL - test-launch-confirm.sh ($fails failure(s))"; exit 1
