#!/usr/bin/env bash
# PLATFORM GUARD: The chief kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
# shellcheck disable=SC2154  # fails, W, SUT, HERE come from the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
WAIT="$HERE/chief-wait.sh"
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
field() {
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
case " $* " in *' -eo '*|*' -ww '*) cat "$PS_FIXTURE" ;; *) exec /bin/ps "$@" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/killstub"
chmod +x "$W/bin/ps" "$W/bin/killstub"
export TICK_KILL_BIN="$W/bin/killstub"

chief="$W/handover/HIMMEL-9608-chief-unclosed.md"
printf '%s\n' '# chief' > "$chief"
state_glob="$TICK_STATE_DIR/tick-unclosed*"
# shellcheck disable=SC2086  # the state glob is meant to expand
reset() { rm -f $state_glob; printf '%s\n' '# chief' > "$chief"; }
mkworker() {
    local f="$W/handover/HIMMEL-97$1-N97$1-$2.md"; shift 2
    printf '# worker\n' > "$f"
    local b
    for b in "$@"; do printf '%s\n' "$b" >> "$f"; done
    printf '%s' "$f"
}
tk() { bash "$SUT" --doc "$chief" --workers "$1" 2>/dev/null; }
konsole() { printf '%s 1 %s konsole --separate --workdir /x -p tabtitle=%s -e env X=1 /launcher --model m -n %s load doc\n' "$1" "${3:-3600}" "$2" "$2"; }
child() { printf '%s %s 3600 claude --model m -n %s\n' "$1" "$2" "$3"; }

w1="$(mkworker 01 closable '- 12:00 LIVE — working' '- 12:30 WRAPPED — released')"
mkcmdline 9701 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9701-N9701-closable work
mk_pgrep_x "$W/bin-alive" 9701
mk_pgrep_x "$W/bin-gone"
export PS_FIXTURE="$W/ps-none.txt"
alive() { PATH="$W/bin-alive:$PATH" tk "$1"; }
gone() { PATH="$W/bin-gone:$PATH" tk "$1"; }

reset
o1="$(alive "$w1")"
contains 'a CLOSABLE worker reads CLOSABLE (control)' "$o1" 'workers=N9701:CLOSABLE'
check 'row 3: a worker first seen on this tick does not wake yet (no unclosed field)' '' "$(field unclosed "$o1")"
o2="$(alive "$w1")"
check 'row 1: a CLOSABLE worker still open on the next tick is named in unclosed=' 'N9701' "$(field unclosed "$o2")"
o3="$(alive "$w1")"
check 'the worker stays named while it stays open' 'N9701' "$(field unclosed "$o3")"

printf '%s\n' '- 12:40 DISPOSITION N9701 parked' >> "$chief"
check 'a parked disposition with no named wake does not clear it' 'N9701' "$(field unclosed "$(alive "$w1")")"
printf '%s\n' '- 12:41 DISPOSITION N9701 given-up' >> "$chief"
check 'a given-up disposition with no reason does not clear it' 'N9701' "$(field unclosed "$(alive "$w1")")"
printf '%s\n' '- 12:42 DISPOSITION N9701 parked wake=pr-4999-merge' >> "$chief"
check 'row 2: a parked disposition naming a wake clears the field' '' "$(field unclosed "$(alive "$w1")")"
check 'the cleared worker stays cleared on later ticks' '' "$(field unclosed "$(alive "$w1")")"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' '- 12:43 DISPOSITION N9701 closed' >> "$chief"
check 'row 2: a closed disposition clears the field' '' "$(field unclosed "$(alive "$w1")")"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' '- 12:44 DISPOSITION N9701 given-up reason: window is a hung closer, operator owns it' >> "$chief"
check 'row 2: a given-up disposition with a reason clears the field' '' "$(field unclosed "$(alive "$w1")")"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' '- 12:45 DISPOSITION N9791 closed' >> "$chief"
check 'a disposition for another worker does not clear this one' 'N9701' "$(field unclosed "$(alive "$w1")")"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
gone "$w1" > /dev/null
check 'row 4: a worker whose window is gone is not in unclosed=' '' "$(field unclosed "$(gone "$w1")")"
# shellcheck disable=SC2086  # the state glob is meant to expand
check 'row 4: its first-seen record is cleared from the state file' '' "$(cat $state_glob 2>/dev/null)"
check 'row 4: back again, it gets its one tick of grace afresh' '' "$(field unclosed "$(alive "$w1")")"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' '- 12:46 DISPOSITION N9701 closed' >> "$chief"
gone "$w1" > /dev/null
alive "$w1" > /dev/null
check 'a disposition from an earlier episode does not suppress a re-opened window' 'N9701' "$(field unclosed "$(alive "$w1")")"

w2="$(mkworker 02 wrapped '- 12:00 LIVE — working' '- 12:30 WRAPPED — released')"
{ konsole 5702 "HIMMEL-9702-N9702-wrapped"; child 5703 5702 "HIMMEL-9702-N9702-wrapped"; } > "$W/ps-win2.txt"
reset
export PS_FIXTURE="$W/ps-win2.txt"
o="$(gone "$w2")"
contains 'a WRAPPED worker with no census row reads WRAPPED (control)' "$o" 'workers=N9702:WRAPPED'
check 'a WRAPPED worker with a live window: first tick is grace' '' "$(field unclosed "$o")"
check 'row 1: a WRAPPED worker with a live window is named on the next tick' 'N9702' "$(field unclosed "$(gone "$w2")")"
export PS_FIXTURE="$W/ps-none.txt"
reset
gone "$w2" > /dev/null; gone "$w2" > /dev/null
check 'a WRAPPED worker with no window and no session is never unclosed' '' "$(field unclosed "$(gone "$w2")")"

w3="$(mkworker 03 nolive)"
touch -d '60 minutes ago' "$w3"
{ konsole 5704 "HIMMEL-9703-N9703-nolive"; child 5705 5704 "HIMMEL-9703-N9703-nolive"; } > "$W/ps-win3.txt"
reset
export PS_FIXTURE="$W/ps-win3.txt"
o="$(gone "$w3")"
contains 'a worker that never went LIVE reads NOLIVE (control)' "$o" 'workers=N9703:NOLIVE'
check 'row 1: a NOLIVE worker with a live window is named on the next tick' 'N9703' "$(field unclosed "$(gone "$w3")")"
export PS_FIXTURE="$W/ps-none.txt"

w4="$W/handover/HIMMEL-9608-N301-busy.md"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$w4"
mkcmdline 9704 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9608-N301-busy work
mk_pgrep_x "$W/bin-busy" 9704
reset
busy() { PATH="$W/bin-busy:$PATH" tk "$1"; }
contains 'a worker holding its lock reads FRESH (control)' "$(busy "$w4")" 'workers=N301:FRESH'
check 'a worker that is still working is never unclosed' '' "$(field unclosed "$(busy "$w4")")"

w6="$(mkworker 06 childless '- 12:00 LIVE — working' '- 12:30 WRAPPED — released')"
konsole 5706 "HIMMEL-9706-N9706-childless" > "$W/ps-win6.txt"
reset
export PS_FIXTURE="$W/ps-win6.txt"
gone "$w6" > /dev/null
o="$(gone "$w6")"
contains '(a) a WRAPPED worker with a childless konsole reads WRAPPED (control)' "$o" 'workers=N9706:WRAPPED'
check '(a) its childless konsole is closed by deadwin=' 'N9706:closed' "$(field deadwin "$o")"
check '(a) a WRAPPED worker whose konsole has no child is never unclosed' '' "$(field unclosed "$o")"
export PS_FIXTURE="$W/ps-none.txt"

reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' 'DISPOSITION N9701 closed' >> "$chief"
check '(b) a DISPOSITION line that is not a bullet does not clear it' 'N9701' "$(field unclosed "$(alive "$w1")")"
printf '%s\n' '- DISPOSITION N9701 closed' >> "$chief"
check '(b) a disposition bullet without HH:MM clears the field' '' "$(field unclosed "$(alive "$w1")")"
reset
alive "$w1" > /dev/null; alive "$w1" > /dev/null
printf '%s\n' '- 12:47 **DISPOSITION N9701 closed**' >> "$chief"
check '(b) a bold disposition bullet with HH:MM clears the field' '' "$(field unclosed "$(alive "$w1")")"

wa="$W/handover/HIMMEL-9707-N9707-a.md"; wb="$W/handover/HIMMEL-9707-N9707b-b.md"
for f in "$wa" "$wb"; do printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$f"; done
mkcmdline 9707 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9707-N9707-a work
mkcmdline 9708 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9707-N9707b-b work
mk_pgrep_x "$W/bin-pair" 9707 9708
pair() { PATH="$W/bin-pair:$PATH" tk "$wa,$wb"; }
reset
pair > /dev/null
check '(c) both prefix-labelled workers are unclosed on the second tick' 'N9707,N9707b' "$(field unclosed "$(pair)")"
printf '%s\n' '- 12:50 DISPOSITION N9707 closed' >> "$chief"
check '(c) a disposition for N9707 leaves N9707b unclosed' 'N9707b' "$(field unclosed "$(pair)")"
reset
pair > /dev/null; pair > /dev/null
printf '%s\n' '- 12:51 DISPOSITION N9707b closed' >> "$chief"
check '(c) a disposition for N9707b leaves N9707 unclosed' 'N9707' "$(field unclosed "$(pair)")"

touch -d '20 minutes ago' "$w1"
reset
check 'closable=<n> still counts an aged CLOSABLE worker' '1' "$(field closable "$(alive "$w1")")"

STUB="$W/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\ncat "$STUB/tick.line"\n' > "$STUB/tick.sh"
printf '#!/usr/bin/env bash\ncat "$STUB/bank"\n' > "$STUB/bank.sh"
export STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
printf 'PROCEED\n' > "$STUB/bank"
tick_line() {
    printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip%s\n' "$1" > "$STUB/tick.line"
}
inbox="$W/in/consoles/c.md"; mkdir -p "$(dirname "$inbox")"; : > "$inbox"
run_waiter() {
    bash "$WAIT" "$inbox" --workers "N1.md" > "$1" 2>/dev/null &
    local wp=$! n=0
    while [ "$n" -lt "$2" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; return 1; fi
    wait "$wp" 2>/dev/null; return 0
}
rm -f "$inbox".wait*
tick_line ' unclosed=N2315'
if run_waiter "$W/w1.out" 80; then pass 'the waiter wakes on a new unclosed worker'; else fail 'the waiter did not wake on unclosed=N2315'; fi
case "$(cat "$W/w1.out")" in *'WAKE unclosed N2315'*) pass 'the wake names the worker: WAKE unclosed N2315' ;; *) fail "waiter out: $(cat "$W/w1.out")" ;; esac
if run_waiter "$W/w2.out" 40; then fail "the waiter woke again for the same unclosed worker: $(cat "$W/w2.out")"; else pass 'the same unclosed worker does not wake the waiter again'; fi
touch -d '30 minutes ago' "$inbox.wait.unclosed"
if run_waiter "$W/w2b.out" 40; then fail "(d) a 30-minute-old marker woke inside the 60-minute window: $(cat "$W/w2b.out")"; else pass '(d) the same unclosed worker stays quiet inside the re-wake window'; fi
touch -d '61 minutes ago' "$inbox.wait.unclosed"
if run_waiter "$W/w2c.out" 80; then pass '(d) the same unclosed worker wakes again after 60 minutes'; else fail '(d) the waiter did not re-wake after the 60-minute window'; fi
case "$(cat "$W/w2c.out")" in *'WAKE unclosed N2315'*) pass '(d) the re-wake names the worker: WAKE unclosed N2315' ;; *) fail "(d) waiter out: $(cat "$W/w2c.out")" ;; esac
if run_waiter "$W/w2d.out" 40; then fail "(d) the re-wake repeated at once: $(cat "$W/w2d.out")"; else pass '(d) the re-wake restarts the clock'; fi
tick_line ' unclosed=N2315,N2316'
if run_waiter "$W/w3.out" 80; then pass 'a second unclosed worker wakes the waiter'; else fail 'the waiter did not wake on the second unclosed worker'; fi
case "$(cat "$W/w3.out")" in *'WAKE unclosed N2316'*) pass 'only the new worker is named: WAKE unclosed N2316' ;; *) fail "waiter out: $(cat "$W/w3.out")" ;; esac
case "$(cat "$W/w3.out")" in *'WAKE unclosed N2315'*) fail 'the already-woken worker was named again' ;; *) pass 'the already-woken worker is not named again' ;; esac
tick_line ''
run_waiter "$W/w4.out" 30 > /dev/null
tick_line ' unclosed=N2315'
if run_waiter "$W/w5.out" 80; then pass 'a worker that left the field and came back wakes the waiter again'; else fail 'the waiter did not wake on the returning worker'; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
