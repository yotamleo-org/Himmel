#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains()
# scripts/handover/test-headed-arm-tabs.sh - suite for headed-arm.sh's tab mode
# (HIMMEL_WORKER_SESSION_TABS=1): worker launches under one console land as tabs in one
# konsole window instead of one --separate window each.
#
# The stubs model the real konsole closely enough for the lifecycle to be real:
#   konsole  records its argv, saves its own env (a tab's shell inherits the
#            WINDOW's env, never the launcher's), runs the -e command as a real
#            child process (the window's first tab) and stays alive.
#   qdbus    newSession hands out session numbers on org.kde.konsole-<pid> only
#            while <pid> is alive; runCommand runs the typed line in a fresh
#            shell built from the window's saved env, like the tab's zsh would.
#   claude   (HEADED_ARM_LAUNCHER) writes a /proc fixture for its own real pid,
#            saves its env, then waits; TERM exits it 0, as claude does.
#   pgrep    matches the -f pattern against the live fixture pids.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/headed-arm.sh"
unset HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_RECORDER HIMMEL_WORKER_SESSION_TABS HIMMEL_CONSOLE_NAME 2>/dev/null || true
export HEADED_ARM_UNAME=Linux
tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-tabs-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
export HIMMELCTL_CACHE_DIR="$tmp/pinned-himmelctl-cache"
# shellcheck source=../lib/host-caps.sh
. "$HERE/../lib/host-caps.sh"
if ! host_modes_stick; then
  rm -rf "$tmp"
  host_skip "headed-arm.sh's claim-lock root needs a chmod/mkdir -m 0700 that sticks; this host's modes do not"
  exit 0
fi

cleanup() {
  local f p
  for f in "$tmp"/*/pids; do
    [ -f "$f" ] || continue
    while read -r p; do kill -KILL "$p" 2>/dev/null; done < "$f"
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grep -qF -e "$3" <<< "$2" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
lacks() {
  local rc=0
  grep -qF -e "$3" <<< "$2" || rc=$?
  case "$rc" in
    1) echo "ok - $1" ;;
    0) echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)) ;;
    *) echo "FAIL - $1: grep failed (rc $rc)"; fails=$((fails+1)) ;;
  esac
}
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# mk_env <dir> - write the four stubs into <dir>.
mk_env() {
  local d="$1"
  mkdir -p "$d/proc"
  : > "$d/pids"
  cat > "$d/konsole" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/konsole-record"
echo "$$" >> "$d/pids"
export -p > "$d/window-env.$$"
while [ "$#" -gt 0 ] && [ "$1" != "-e" ]; do shift; done
shift
"$@" < /dev/null > /dev/null 2>&1 &
echo "$!" >> "$d/pids"
trap 'exit 0' TERM
sleep 30 & wait
EOF
  cat > "$d/qdbus" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/qdbus-record"
[ -e "$d/qdbus-fail" ] && { echo "Error: org.freedesktop.DBus.Error.ServiceUnknown" ; exit 2; }
svc="$1"; obj="$2"; method="$3"; shift 3
kpid="${svc#org.kde.konsole-}"
kill -0 "$kpid" 2>/dev/null || { echo "Error: org.freedesktop.DBus.Error.ServiceUnknown"; exit 2; }
case "$obj $method" in
  "/Windows/1 newSession")
    n="$(cat "$d/sessions.$kpid" 2>/dev/null || echo 1)"; n=$((n + 1))
    echo "$n" > "$d/sessions.$kpid"; echo "$n" ;;
  "/Sessions/"*" runCommand")
    env -i bash -c '. "$1"; eval "$2"' tabshell "$d/window-env.$kpid" "$1" < /dev/null > /dev/null 2>&1 &
    echo "$!" >> "$d/pids" ;;
  "/Sessions/"*" setTabTitleFormat"|"/Sessions/"*" setTitle") : ;;
  *) echo "Error: no such method $obj $method"; exit 2 ;;
esac
EOF
  cat > "$d/claude" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
name=""; prev=""
for a in "$@"; do [ "$prev" = "-n" ] && name="$a"; prev="$a"; done
mkdir -p "$d/proc/$$"
echo claude > "$d/proc/$$/comm"
{ printf 'claude\0'; printf '%s\0' "$@"; } > "$d/proc/$$/cmdline"
env > "$d/env.$name"
echo "$$" > "$d/pid.$name"
echo "$$" >> "$d/pids"
trap 'exit 0' TERM
sleep 30 & wait
EOF
  cat > "$d/pgrep" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
pat="$2"; hit=1
for c in "$d"/proc/*/cmdline; do
  [ -f "$c" ] || continue
  p="$(basename "$(dirname "$c")")"
  kill -0 "$p" 2>/dev/null || continue
  if tr '\0' ' ' < "$c" | grep -Eq -- "$pat"; then echo "$p"; hit=0; fi
done
exit "$hit"
EOF
  cat > "$d/waker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/waker-record"
EOF
  chmod 755 "$d/konsole" "$d/qdbus" "$d/claude" "$d/pgrep" "$d/waker"
}

REPO="$tmp/repo"; mkdir -p "$REPO"
PAST=$(( $(date +%s) - 100 ))

# arm <dir> <name> [extra env NAME=VALUE...] - one launch, returns its rc.
arm() {
  local d="$1" name="$2"; shift 2
  env KONSOLE_CMD="$d/konsole" PGREP_CMD="$d/pgrep" HEADED_ARM_QDBUS="$d/qdbus" \
    HEADED_ARM_LAUNCHER="$d/claude" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d/locks" \
    HEADED_ARM_PROC="$d/proc" "$@" \
    bash "$SCRIPT" "$name" "doc-$name.md" "$d/signal-never" "$PAST" "$d/log" > "$d/out.$name" 2>&1
}
# konsole_count <dir> - how many windows were opened.
konsole_count() { if [ -f "$1/konsole-record" ]; then wc -l < "$1/konsole-record" | tr -d ' '; else echo 0; fi; }
# window_of <dir> <name> - the window pid the arm log names for <name>.
window_of() { grep -E "konsole launched pid=[0-9]+ for $2( |\$)" "$1/log" | tail -n 1 | sed -E 's/.*pid=([0-9]+) .*/\1/'; }
pid_of() { cat "$1/pid.$2" 2>/dev/null; }

# --- 1. control: the default (no HIMMEL_WORKER_SESSION_TABS) is unchanged - one --separate
# window per launch, qdbus never touched.
d1="$tmp/c1"; mk_env "$d1"
arm "$d1" HIMMEL-1-N1-a HIMMEL_CONSOLE_NAME=CHIEF-A; rc1a=$?
arm "$d1" HIMMEL-1-N2-b HIMMEL_CONSOLE_NAME=CHIEF-A; rc1b=$?
check "1a default: first launch exit 0" "$rc1a" 0
check "1b default: second launch exit 0" "$rc1b" 0
check "1c default: one window per launch" "$(konsole_count "$d1")" 2
contains "1d default: windows are --separate" "$(cat "$d1/konsole-record")" "--separate"
check "1e default: qdbus never called" "$([ -e "$d1/qdbus-record" ] && echo called || echo none)" none

# --- 2. tab mode: three launches under one console land in ONE window.
d2="$tmp/c2"; mk_env "$d2"
export CLAUDE_CODE_CHILD_SESSION=1
arm "$d2" HIMMEL-2-N1-a HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A ONLY_A=1; rc2a=$?
arm "$d2" HIMMEL-2-N2-b HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A ONLY_B=1; rc2b=$?
arm "$d2" HIMMEL-2-N3-c HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A; rc2c=$?
unset CLAUDE_CODE_CHILD_SESSION
check "2a tabs: launch 1 exit 0" "$rc2a" 0
check "2b tabs: launch 2 exit 0" "$rc2b" 0
check "2c tabs: launch 3 exit 0" "$rc2c" 0
check "2d tabs: three launches open exactly one window" "$(konsole_count "$d2")" 1
w2a="$(window_of "$d2" HIMMEL-2-N1-a)"; w2b="$(window_of "$d2" HIMMEL-2-N2-b)"; w2c="$(window_of "$d2" HIMMEL-2-N3-c)"
check "2e tabs: launch 2 is tracked in launch 1's window" "${w2b:-none}" "${w2a:-unset}"
check "2f tabs: launch 3 is tracked in launch 1's window" "${w2c:-none}" "${w2a:-unset}"
qrec2="$(cat "$d2/qdbus-record" 2>/dev/null)"
contains "2g tabs: tab 2 opened with newSession on the window's service" "$qrec2" "org.kde.konsole-${w2a:-x} /Windows/1 newSession"
contains "2h tabs: tab 2 titled with its session name" "$qrec2" "/Sessions/2 setTabTitleFormat 0 HIMMEL-2-N2-b"
contains "2i tabs: tab 3 titled with its session name" "$qrec2" "/Sessions/3 setTabTitleFormat 0 HIMMEL-2-N3-c"
contains "2j tabs: the log names each tab's session" "$(cat "$d2/log")" "for HIMMEL-2-N3-c tab=/Sessions/3"
# The tab's env is its OWN launch's, not the window's (launch 1's).
envb="$(cat "$d2/env.HIMMEL-2-N2-b" 2>/dev/null)"
contains "2k tabs: tab carries its own launch env" "$envb" "ONLY_B=1"
lacks "2l tabs: tab does not inherit the window's launch env" "$envb" "ONLY_A=1"
lacks "2m tabs: tab clears CLAUDE_CODE_CHILD_SESSION" "$envb" "CLAUDE_CODE_CHILD_SESSION="
contains "2n tabs: tab forces session persistence" "$envb" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"
contains "2o tabs: tab runs in the repo" "$envb" "PWD=$REPO"
lacks "2p tabs: the tab script is gone once the launch is confirmed" "$(ls "$d2/locks")" ".lock"

# --- 3. closing ONE worker (close-wrapped-leg TERMs the claude pid) leaves the
# window and the other tabs alive.
pa="$(pid_of "$d2" HIMMEL-2-N1-a)"; pb="$(pid_of "$d2" HIMMEL-2-N2-b)"; pc="$(pid_of "$d2" HIMMEL-2-N3-c)"
kill -TERM "${pb:-0}" 2>/dev/null
n=0; while kill -0 "${pb:-0}" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n+1)); done
check "3a close one: the TERMed worker is gone" "$(alive "${pb:-0}")" no
check "3b close one: the window survives" "$(alive "${w2a:-0}")" yes
check "3c close one: tab 1 survives" "$(alive "${pa:-0}")" yes
check "3d close one: tab 3 survives" "$(alive "${pc:-0}")" yes

# --- 4. a crashed tab (SIGKILL) does not take the window down: the window
# survives and the next launch still lands in it as a tab.
kill -KILL "${pc:-0}" 2>/dev/null
n=0; while kill -0 "${pc:-0}" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n+1)); done
check "4a crash: the window survives a killed tab" "$(alive "${w2a:-0}")" yes
check "4b crash: tab 1 survives a killed tab" "$(alive "${pa:-0}")" yes
arm "$d2" HIMMEL-2-N4-d HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A; rc4=$?
check "4c crash: the next launch exit 0" "$rc4" 0
check "4d crash: the next launch is a tab, not a new window" "$(konsole_count "$d2")" 1
check "4e crash: the next launch is tracked in the same window" "$(window_of "$d2" HIMMEL-2-N4-d)" "${w2a:-unset}"

# --- 5. a different console gets its own window.
arm "$d2" HIMMEL-2-N5-e HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-B; rc5=$?
check "5a other console: exit 0" "$rc5" 0
check "5b other console: opens its own window" "$(konsole_count "$d2")" 2

# --- 6. the recorded window is gone: the next launch opens a new window, and
# the launch after that tabs into the new one.
d6="$tmp/c6"; mk_env "$d6"
arm "$d6" HIMMEL-6-N1-a HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A
w6a="$(window_of "$d6" HIMMEL-6-N1-a)"
kill -KILL "${w6a:-0}" "$(pid_of "$d6" HIMMEL-6-N1-a)" 2>/dev/null; sleep 0.2
arm "$d6" HIMMEL-6-N2-b HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A; rc6=$?
arm "$d6" HIMMEL-6-N3-c HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A
w6b="$(window_of "$d6" HIMMEL-6-N2-b)"
check "6a dead window: launch exit 0" "$rc6" 0
check "6b dead window: a new window is opened" "$(konsole_count "$d6")" 2
check "6c dead window: the next launch tabs into the new window" "$(window_of "$d6" HIMMEL-6-N3-c)" "${w6b:-unset}"

# --- 7. newSession fails: the launch falls back to its own window, never lost.
d7="$tmp/c7"; mk_env "$d7"
arm "$d7" HIMMEL-7-N1-a HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A
: > "$d7/qdbus-fail"
arm "$d7" HIMMEL-7-N2-b HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A; rc7=$?
check "7a qdbus fails: launch exit 0" "$rc7" 0
check "7b qdbus fails: falls back to a new window" "$(konsole_count "$d7")" 2
contains "7c qdbus fails: the fallback is logged" "$(cat "$d7/log")" "WARN: tab launch for HIMMEL-7-N2-b failed"

# --- 8. a console arm and a launch with no console name never tab.
d8="$tmp/c8"; mk_env "$d8"
arm "$d8" HIMMEL-8-N1-a HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A
arm "$d8" HIMMEL-8-N2-b HIMMEL_WORKER_SESSION_TABS=1; rc8=$?
check "8a no console name: exit 0" "$rc8" 0
check "8b no console name: own window" "$(konsole_count "$d8")" 2

# --- 9. the idle waker targets the tab's own session and the worker's pid.
d9="$tmp/c9"; mk_env "$d9"
arm "$d9" HIMMEL-9-N1-a HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A HEADED_ARM_WAKER="$d9/waker"
arm "$d9" HIMMEL-9-N2-b HIMMEL_WORKER_SESSION_TABS=1 HIMMEL_CONSOLE_NAME=CHIEF-A HEADED_ARM_WAKER="$d9/waker"
n=0; while [ "$(wc -l < "$d9/waker-record" 2>/dev/null || echo 0)" -lt 2 ] && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n+1)); done
w9="$(window_of "$d9" HIMMEL-9-N1-a)"
contains "9a waker: tab 2 gets its own session" "$(cat "$d9/waker-record" 2>/dev/null)" \
  "--name HIMMEL-9-N2-b --service org.kde.konsole-$w9 --session /Sessions/2 --pid $(pid_of "$d9" HIMMEL-9-N2-b)"
contains "9b waker: the window's first tab keeps /Sessions/1, bound to its worker" "$(cat "$d9/waker-record" 2>/dev/null)" \
  "--name HIMMEL-9-N1-a --service org.kde.konsole-$w9 --session /Sessions/1 --pid $(pid_of "$d9" HIMMEL-9-N1-a)"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
