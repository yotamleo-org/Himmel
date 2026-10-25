#!/usr/bin/env bash
# test-tick-deadwin.sh — tick.sh reports a leg konsole whose session died (its
# tabtitle names a fleet leg and the konsole has no child process) as
# `deadwin=<label>:closed|held`, TERMs it only when the leg's lock is free or a
# newer -r<n> relaunch is live, and console-wait.sh wakes on a new deadwin.
# Hermetic: stubs for every external probe, scratch HOME / handover / projects.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
WAIT="$HERE/console-wait.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-deadwin-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/console-work/chain"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) case "$2" in *-N810-*|*-N811-*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
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
cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
# like procps: a table read without -ww is cut to $COLUMNS
case " $* " in
  *' -ww '*) cat "$PS_FIXTURE" ;;
  *) if [ -n "${COLUMNS:-}" ]; then cut -c "1-$COLUMNS" "$PS_FIXTURE"; else cat "$PS_FIXTURE"; fi ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/bun"
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"
cat > "$W/repo/scripts/lib/usage-preflight.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' >&2
printf '%s\n' PROCEED
STUB
KILLLOG="$W/kill.log"; : > "$KILLLOG"
printf '#!/usr/bin/env bash\nshift\nprintf "%%s\\n" "$@" >> "%s"\n' "$KILLLOG" > "$W/bin/killstub"
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/usage-preflight.sh" "$W/bin/"*
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"

export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/console-work" TICK_PROJECTS_DIR="$W/projects"
export DOC="$W/handover/console.md" TOKEN=t LEGS=''
export TICK_KILL_BIN="$W/bin/killstub"

mkleg() { # <id-slug> [bullet...]
    local f="$W/handover/HIMMEL-9$1.md"; shift
    printf '# leg\n' > "$f"
    local b
    for b in "$@"; do printf '%s\n' "$b" >> "$f"; done
    printf '%s' "$f"
}
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
# konsole <pid> <tabtitle> [etimes]: a ps fixture row (pid ppid etimes args).
konsole() { printf '%s 1 %s konsole --separate --workdir /x -p tabtitle=%s -e env X=1 /launcher --model m -n %s load doc\n' "$1" "${3:-3600}" "$2" "$2"; }
child() { printf '%s %s 3600 claude --model m -n %s\n' "$1" "$2" "$3"; }
run() { bash "$SUT" --legs "$1" 2>/dev/null; }

dead="HIMMEL-9801-N801-dead"
d_free="$(mkleg 801-N801-dead '- 10:00 LIVE — x')"
d_held="$(mkleg 810-N810-held)"
d_rel="$(mkleg 811-N811-relaunched)"

# dead window, lock free: reported and closed
konsole 5001 "$dead" > "$W/ps1.txt"
export PS_FIXTURE="$W/ps1.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(run "$d_free")"
check 'a leg konsole with no child reads deadwin=<label>:closed when its lock is free' 'N801:closed' "$(field deadwin "$out")"
check 'the dead window pid is TERMed' '5001' "$(tr -d '\n' < "$KILLLOG")"

# live child: no deadwin
{ konsole 5002 "$dead"; child 5003 5002 "$dead"; } > "$W/ps2.txt"
export PS_FIXTURE="$W/ps2.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(run "$d_free")"
check 'a leg konsole with a live child has no deadwin field' '' "$(field deadwin "$out")"
check 'a live window is never signalled' '' "$(cat "$KILLLOG")"

# dead window, lock held, no relaunch: reported, not closed
konsole 5004 "HIMMEL-9810-N810-held" > "$W/ps3.txt"
export PS_FIXTURE="$W/ps3.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(run "$d_held")"
check 'a dead window whose lock is held and has no relaunch is reported held' 'N810:held' "$(field deadwin "$out")"
check 'a held dead window is not signalled' '' "$(cat "$KILLLOG")"

# dead window, lock held, newer -r1 relaunch live: closed
{ konsole 5005 "HIMMEL-9811-N811-relaunched"; konsole 5006 "HIMMEL-9811-N811-relaunched-r1"; child 5007 5006 "HIMMEL-9811-N811-relaunched-r1"; } > "$W/ps4.txt"
export PS_FIXTURE="$W/ps4.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(run "$d_rel")"
check 'a dead window with a live -r<n> relaunch is closed even while the lock is held' 'N811:closed' "$(field deadwin "$out")"
check 'only the dead window pid is TERMed, not the relaunch' '5005' "$(tr -d '\n' < "$KILLLOG")"

# a hook-inherited COLUMNS must not cut the tabtitle out of the table
konsole 5014 "$dead" > "$W/ps9.txt"
export PS_FIXTURE="$W/ps9.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(COLUMNS=40 run "$d_free")"
check 'a narrow COLUMNS still reads the dead window' 'N801:closed' "$(field deadwin "$out")"

# a console tab with no child is not a leg window
konsole 5008 "HIMMEL-nextleg-2026-10-17D-roadmap-console" > "$W/ps5.txt"
export PS_FIXTURE="$W/ps5.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
check 'a non-leg tabtitle (a console) is never deadwin' '' "$(field deadwin "$(run "$d_free")")"

# a just-launched konsole has not spawned its child yet
konsole 5009 "$dead" 3 > "$W/ps6.txt"
export PS_FIXTURE="$W/ps6.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
check 'a konsole younger than the grace window is not deadwin' '' "$(field deadwin "$(run "$d_free")")"

export PS_FIXTURE="$W/ps-none.txt"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
check 'no dead window: the deadwin field is absent' '' "$(field deadwin "$(run "$d_free")")"

# a closed window is gone from ps next tick: :closed is still reported (waiter debounce needs two samples)
konsole 5010 "$dead" > "$W/ps7.txt"
export PS_FIXTURE="$W/ps7.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
run "$d_free" > /dev/null
export PS_FIXTURE="$W/ps-none.txt"
check 'a closed window is re-reported on the next tick once it left ps' 'N801:closed' "$(field deadwin "$(run "$d_free")")"
check 'the closed report expires after TICK_DEADWIN_KEEP' '' "$(field deadwin "$(TICK_DEADWIN_KEEP=0 run "$d_free")")"

# dead base-r1 window superseded by a live base-r2 window while the lock is held
{ konsole 5011 "HIMMEL-9811-N811-relaunched-r1"; konsole 5012 "HIMMEL-9811-N811-relaunched-r2"; child 5013 5012 "HIMMEL-9811-N811-relaunched-r2"; } > "$W/ps8.txt"
export PS_FIXTURE="$W/ps8.txt"; : > "$KILLLOG"; rm -f "$TICK_STATE_DIR/tick-deadwin-closed"
out="$(run "$d_rel")"
check 'a dead -r1 window with a live -r2 window is closed' 'N811:closed' "$(field deadwin "$out")"
check 'only the dead -r1 pid is TERMed' '5011' "$(tr -d '\n' < "$KILLLOG")"
rm -f "$TICK_STATE_DIR/tick-deadwin-closed"

# the waiter wakes on a new deadwin
STUB="$W/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\ncat "$STUB/bank"\n' > "$STUB/bank.sh"
export STUB CONSOLE_WAIT_TICK="$STUB/tick.sh" CONSOLE_WAIT_BANK="$STUB/bank.sh"
export CONSOLE_WAIT_INTERVAL=1 CONSOLE_WAIT_POLL_SEC=0.2 CONSOLE_WAIT_FAIL_WAKE=1000
printf 'PROCEED\n' > "$STUB/bank"
tick_line() {
    printf 'TICK 03:00 hb=1m legs=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip%s\n' "$1" > "$STUB/tick.line"
}
inbox="$W/in/consoles/c.md"; mkdir -p "$(dirname "$inbox")"; : > "$inbox"
tick_line ''
bash "$WAIT" "$inbox" --legs "N1.md" > "$W/w.out" 2>/dev/null &
wpid=$!
n=0; while [ "$n" -lt 50 ] && ! grep -q 'key=[0-9a-f]' "$inbox.wait" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
tick_line ' deadwin=N2315:held'
n=0; while [ "$n" -lt 80 ] && kill -0 "$wpid" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
if kill -0 "$wpid" 2>/dev/null; then kill "$wpid" 2>/dev/null; fail 'the waiter did not wake on a new deadwin'; else wait "$wpid"; fi
case "$(cat "$W/w.out")" in *'WAKE tick changed=deadwin'*) pass 'the waiter wakes with changed=deadwin' ;; *) fail "waiter out: $(cat "$W/w.out")" ;; esac

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
