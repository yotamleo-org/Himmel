#!/usr/bin/env bash
# test-tick-rmqueue.sh — tick.sh rm-queue=<n>,<oldest age>m and the automatic `jira release rm-run`:
# an open placement request older than TICK_RMRUN_MIN minutes (default 2) makes the tick launch ONE
# detached rm-run for the chief doc's `release:` release, never while the lease is held and never
# twice inside TICK_RMRUN_MIN_SECS. The state read and the rm-run are stubbed; nothing touches Jira.
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
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-rmqueue-test.XXXXXX")" || exit 1
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

export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/chief-work" TICK_PROJECTS_DIR="$W/projects"
export TOKEN=t WORKERS=''
export HIMMEL_RELEASE_STATE_DIR="$W/releases" USER_SLUG=tester
mkdir -p "$HIMMEL_RELEASE_STATE_DIR"

# the state read: `release state <R> --json`, its body is $W/state.json; the rm-run logs its argv and stops.
printf '#!/bin/sh\necho "$@" >> "%s/state-asked"\ncat "%s/state.json"\nexit "${TICK_RMQ_EXIT:-0}"\n' "$W" "$W" > "$W/rmq-probe.sh"
printf '#!/bin/sh\necho "$@" >> "%s/rmrun-ran"\n' "$W" > "$W/rmrun-probe.sh"
export TICK_RMQ_PROBE="$W/rmq-probe.sh" TICK_RMRUN_PROBE="$W/rmrun-probe.sh" TICK_RMRUN_LAUNCHER=env

ago() { /bin/date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
# state <open ids as a JSON list> <oldest open ts|null> <lease JSON>
state() { printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":%s,"requests":{"open":%s,"claimed":[],"oldest_open":%s}}\n' "$3" "$1" "$2" > "$W/state.json"; }
mkdoc() { printf '# chief\nrelease: %s\n' "$1" > "$W/handover/chief.md"; }
reset() { rm -f "$W/rmrun-ran" "$W/state-asked"; rm -rf "$W/state"; }
tick() { bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null; }
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
ran() { # wait up to 5 s for the detached stub to log, then print how many lines it logged
    local i=0
    while [ ! -s "$W/rmrun-ran" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$W/rmrun-ran" ] && wc -l < "$W/rmrun-ran" | tr -d ' ' || echo 0
}

mkdoc R1
reset; state '["Q-1","Q-2"]' "\"$(ago 45)\"" null
out="$(tick)"
check 'two open requests, the oldest 45 min old, read rm-queue=2,45m' '2,45m,run' "$(field rm-queue "$out")"
check 'and the tick launches ONE rm-run for the chief doc release' '1' "$(ran)"
check 'the rm-run is called with the release name' 'release rm-run R1' "$(sed -n 1p "$W/rmrun-ran" | sed 's/^.*\(release rm-run R1\).*$/\1/')"
check 'the state read is asked for the same release' 'R1 --json' "$(sed -n 1p "$W/state-asked")"

rm -f "$W/rmrun-ran" "$W/state-asked"
out="$(tick)"
sleep 1
check 'a second tick inside the minimum interval shows the queue but launches no second rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
check 'and still reads the queue' '2,45m' "$(field rm-queue "$out")"

reset; state '["Q-1"]' "\"$(ago 1)\"" null
out="$(tick)"
sleep 1
check 'a request younger than the threshold shows rm-queue and runs nothing' '1,1m' "$(field rm-queue "$out")"
check 'and no rm-run ran' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

reset; state '["Q-1"]' "\"$(ago 45)\"" '{"holder":"rm-run-1","epoch":3}'
out="$(tick)"
sleep 1
check 'a held lease still shows the queue' '1,45m' "$(field rm-queue "$out")"
check 'and no rm-run is launched while the lease is held' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

reset; state '["Q-1"]' "\"$(ago 45)\"" '{"epoch":3,"owner_doc":null,"released":true}'
out="$(tick)"
sleep 1
check 'a released lease is free: the tick launches the rm-run' '1' "$(ran)"

# 8731 U2 (review F2): a ruling interrupted after the Jira write leaves its request in ruled:<R>, not open, so an empty queue says nothing.
# The state read lists it under unfinished_rulings: status replay = a normal rm-run finishes it; blocked = the chief repairs by hand.
stateu() { # <open ids as a JSON list> <oldest open ts|null> <lease JSON> <unfinished_rulings JSON list>
    printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":%s,"requests":{"open":%s,"claimed":[],"oldest_open":%s},"unfinished_rulings":%s}\n' "$3" "$1" "$2" "$4" > "$W/state.json"
}
u_row() { printf '{"ruling":"R-R1-0007","req":"Q-R1-0007","key":"K-1","phase":"applied","op":"add backlog→v1.1.3","status":"%s","owner":"%s","next":"x","observed":null}' "$1" "$2"; }
U_REPLAY="[$(u_row replay release-manager)]"
U_BLOCKED="[$(u_row blocked chief)]"
reset; stateu '[]' null null "$U_REPLAY"
out="$(tick)"
check '8731 U2: an interrupted ruling with an empty queue launches ONE rm-run' '1' "$(ran)"
check '8731 U2: the field shows the empty queue, the ruling to replay and the launch' '0,0m,replay=1,run' "$(field rm-queue "$out")"
check '8731 U2: the rm-run is the ordinary one for the chief doc release' 'release rm-run R1' "$(sed -n 1p "$W/rmrun-ran" | sed 's/^.*\(release rm-run R1\).*$/\1/')"
rm -f "$W/rmrun-ran"
for n in 2 3; do
    out="$(tick)"
    sleep 1
    check "8731 U2: tick $n on the unchanged ruling inside the interval launches nothing" '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
    check "8731 U2: tick $n still shows the ruling" '0,0m,replay=1' "$(field rm-queue "$out")"
done
reset; stateu '[]' null null "$U_REPLAY"
TICK_RMRUN_MIN_SECS=0 tick > /dev/null
check '8731 U2: the interval is the existing TICK_RMRUN_MIN_SECS (0 lets the next tick launch again)' '1' "$(ran)"
reset; stateu '[]' null '{"epoch":3,"owner_doc":null,"released":false}' "$U_REPLAY"
out="$(tick)"
sleep 1
check '8731 U2: a held lease (the writing run is between its writes) shows the ruling and launches nothing' '0,0m,replay=1' "$(field rm-queue "$out")"
check '8731 U2: and no rm-run ran' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
# 8731 V3 (fix review F1): a hard-killed rm-run leaves its lease held. The state names an owner it can prove gone (owner_gone: true, the same
# helper rm-run's own reclaim uses); only that reads as free for the launch. The tick never judges a pid itself.
dead_lease() { printf '{"epoch":3,"owner_doc":"/rm.md","released":false,"owner_pid":4242,"owner_host":"h"%s}' "$1"; }
reset; stateu '[]' null "$(dead_lease ',"owner_gone":true')" "$U_REPLAY"
out="$(tick)"
check '8731 V3: a held lease whose owner the state proves gone reads as free: the replay launches' '0,0m,replay=1,run' "$(field rm-queue "$out")"
check '8731 V3: one rm-run' '1' "$(ran)"
reset; stateu '["Q-1"]' "\"$(ago 45)\"" "$(dead_lease ',"owner_gone":true')" '[]'
out="$(tick)"
check '8731 V3: the same gate frees an aged open request behind a dead owner' '1,45m,run' "$(field rm-queue "$out")"
for variant in ',"owner_gone":false' ',"owner_gone":"true"' ',"owner_gone":1' ''; do
    reset; stateu '[]' null "$(dead_lease "$variant")" "$U_REPLAY"
    out="$(tick)"
    sleep 1
    check "8731 V3: a held lease with owner_gone absent or not literally true (${variant:-absent}) stays held: no launch" '0,0m,replay=1' "$(field rm-queue "$out")"
    check "8731 V3: and no rm-run ran (${variant:-absent})" '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
done
# 8731 V4 (fix review F2): a replay that rm-run cannot finish stays in the state. What the tick PRINTS for it is the consumer contract:
# the same field text on every tick, the open count and the oldest-open age stay 0 and 0m (a ruling has no age here), replay=<n> names
# the count, and ,run marks only the ticks that launch (one per TICK_RMRUN_MIN_SECS). The waiter's rule reads a positive open count
# first (wake-rules.py), so a lingering replay with an empty queue is not woken on today; that is the waiter's to change.
reset; stateu '[]' null null "$U_REPLAY"
out="$(tick)"
check '8731 V4: a replay that keeps failing: the first tick launches and prints 0,0m,replay=1,run' '0,0m,replay=1,run' "$(field rm-queue "$out")"
check '8731 V4: and that launch ran' '1' "$(ran)"
rm -f "$W/rmrun-ran"
printed=''
for n in 1 2 3; do
    printed="$printed $(field rm-queue "$(tick)")"
done
sleep 1
check '8731 V4: the next ticks print the same field without ,run and launch nothing (no age ever appears)' ' 0,0m,replay=1 0,0m,replay=1 0,0m,replay=1' "$printed"
check '8731 V4: no launch inside the interval' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
touch -d '11 minutes ago' "$W"/state/tick-rm-run-*
out="$(tick)"
check '8731 V4: once the interval has passed the unchanged replay is retried: ,run again, the field otherwise unchanged' '0,0m,replay=1,run' "$(field rm-queue "$out")"
check '8731 V4: the retry ran' '1' "$(ran)"
# the waiter's rule reads the suffix after a positive open count and age: replay=<n> after them is tolerated (the producer side of that contract)
wr() { printf 'TICK x rm-queue=%s\n' "$1" | python3 -I "$HERE/wake-rules.py" --inbox "$W/wr-inbox-$2" --doc "$W/handover/chief.md" --release-root "$W/releases"; }
check '8731 V4: the waiter still wakes on an aged open request when replay=<n> and ,run follow it' 'WAKE rm-queue rm-queue=1,45m,replay=1,run' "$(wr '1,45m,replay=1,run' a)"

reset; stateu '[]' null null "$U_BLOCKED"
out="$(tick)"
sleep 1
check '8731 U2: a blocked move is the chief repair, never an rm-run job: no launch, field elided' '' "$(field rm-queue "$out")"
check '8731 U2: and no rm-run ran' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
reset; stateu '["Q-1"]' "\"$(ago 1)\"" null "$U_REPLAY"
out="$(tick)"
check '8731 U2: a young open request does not hold back the replay of an interrupted ruling' '1,1m,replay=1,run' "$(field rm-queue "$out")"
check '8731 U2: one rm-run' '1' "$(ran)"
reset; printf '{"status":"UNKNOWN","requests":{"open":[],"claimed":[]},"unfinished_rulings":%s}\n' "$U_REPLAY" > "$W/state.json"
out="$(TICK_RMQ_EXIT=3 tick)"
sleep 1
check '8731 U2: a state that is not OK launches nothing for an unfinished ruling' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
reset; stateu '[]' null null '[]'
out="$(tick)"
sleep 1
check '8731 U2: control: an empty unfinished list and an empty queue still launch nothing' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

# 8731 U3: a blocked unfinished ruling needs a person, so the tick prints rm-blocked=<n>:<KEY>@<ruling>,... (sorted, one pair per ruling),
# absent when none, ? while the state read is not OK. It never launches an rm-run and never enters rm-queue.
u_row2() { # <ruling> <key> <status> <owner>
    printf '{"ruling":"%s","req":"Q-%s","key":"%s","phase":"applied","op":"add backlog→v1.1.3","status":"%s","owner":"%s","next":"x","observed":null}' "$1" "$1" "$2" "$3" "$4"
}
reset; stateu '[]' null null "$U_BLOCKED"
out="$(tick)"
sleep 1
check '8731 U3: a blocked ruling prints rm-blocked with its key and ruling' '1:K-1@R-R1-0007' "$(field rm-blocked "$out")"
check '8731 U3: and still launches no rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
check '8731 U3: and the rm-queue field stays elided' '' "$(field rm-queue "$out")"
reset; stateu '[]' null null "[$(u_row2 R-R1-0008 K-2 blocked chief),$(u_row2 R-R1-0007 K-1 blocked chief)]"
out="$(tick)"
check '8731 U3: two blocked rulings print as one sorted set, whatever order the state lists them in' '2:K-1@R-R1-0007,K-2@R-R1-0008' "$(field rm-blocked "$out")"
printed=''
for n in 1 2 3 4; do
    printed="$printed $(field rm-blocked "$(tick)")"
done
check '8731 U3: the same set prints the same text on every tick' ' 2:K-1@R-R1-0007,K-2@R-R1-0008 2:K-1@R-R1-0007,K-2@R-R1-0008 2:K-1@R-R1-0007,K-2@R-R1-0008 2:K-1@R-R1-0007,K-2@R-R1-0008' "$printed"
reset; stateu '[]' null null "[$(u_row2 'R-R1-0009 x|y=z' 'K 3' blocked chief)]"
out="$(tick)"
check '8731 U3: a space, pipe or equals sign in an id is flattened so the field stays one token' '1:K_3@R-R1-0009_x_y_z' "$(field rm-blocked "$out")"
reset; stateu '[]' null null "[$(u_row2 R-R1-0007 K-1 replay release-manager),$(u_row2 R-R1-0008 K-2 blocked chief)]"
out="$(tick)"
check '8731 U3: a replay and a blocked ruling together: the replay launches and is counted' '0,0m,replay=1,run' "$(field rm-queue "$out")"
check '8731 U3: and the blocked one is named beside it' '1:K-2@R-R1-0008' "$(field rm-blocked "$out")"
check '8731 U3: and one rm-run, not two' '1' "$(ran)"
reset; stateu '[]' null null "$U_REPLAY"
out="$(tick)"
check '8731 U3: a replay alone prints no rm-blocked' '' "$(field rm-blocked "$out")"
reset; stateu '[]' null null '[]'
out="$(tick)"
check '8731 U3: control: no unfinished ruling prints no rm-blocked' '' "$(field rm-blocked "$out")"
reset; state '["Q-1"]' "\"$(ago 10)\"" null
out="$(tick)"
check '8731 U3: control: a state with no unfinished_rulings key prints no rm-blocked' '' "$(field rm-blocked "$out")"
mkdoc none
reset; stateu '[]' null null "$U_BLOCKED"
out="$(tick)"
check '8731 U3: no declared release prints no rm-blocked' '' "$(field rm-blocked "$out")"
mkdoc R1

# 8731 U3: a state read that fails is unknown, never an empty set and never a launch, whatever the body lists
UNF="[$(u_row2 R-R1-0007 K-1 replay release-manager),$(u_row2 R-R1-0008 K-2 blocked chief)]"
for variant in '3:UNKNOWN:off' '124:OK:?' '137:OK:?' '1:OK:off'; do
    rc="${variant%%:*}"; rest="${variant#*:}"; body="${rest%%:*}"; want="${rest#*:}"
    reset; printf '{"status":"%s","requests":{"open":[],"claimed":[]},"unfinished_rulings":%s}\n' "$body" "$UNF" > "$W/state.json"
    out="$(TICK_RMQ_EXIT=$rc tick)"
    sleep 1
    check "8731 U3: a state read that exits $rc ($body body) prints rm-queue=$want" "$want" "$(field rm-queue "$out")"
    check "8731 U3: and rm-blocked=? (unknown, not an empty set) (exit $rc)" '?' "$(field rm-blocked "$out")"
    check "8731 U3: and launches no rm-run (exit $rc)" '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
done
reset; printf 'broken\n' > "$W/state.json"
out="$(tick)"
check '8731 U3: an unparseable state prints rm-queue=off and rm-blocked=?' 'off ?' "$(field rm-queue "$out") $(field rm-blocked "$out")"

# 8731 U3: the run in flight holds the lease: the next tick launches nothing even once the interval has passed
reset; stateu '[]' null null "$U_REPLAY"
tick > /dev/null
check '8731 U3: an interrupted ruling with an empty queue launches its one rm-run' '1' "$(ran)"
rm -f "$W/rmrun-ran"
touch -d '11 minutes ago' "$W"/state/tick-rm-run-*
stateu '[]' null '{"holder":"rm-run-1","epoch":4,"released":false,"owner_pid":4243,"owner_host":"h","owner_gone":false}' "$U_REPLAY"
out="$(tick)"
sleep 1
check '8731 U3: the same tick, interval passed, lease held by the run in flight: no second rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
check '8731 U3: and the ruling still shows' '0,0m,replay=1' "$(field rm-queue "$out")"

# 8731 U4: rm-blocked prints ? when the state cannot be read as a set of blocked rulings: the mirror input is UNKNOWN (the engine then lists every
# ruling as replay while the status stays OK) or unfinished_rulings has no readable shape. A readable state prints its set.
stateum() { # <mirror input> <unfinished_rulings JSON>
    printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"inputs":{"mirror":"%s"},"lease":null,"requests":{"open":[],"claimed":[],"oldest_open":null},"unfinished_rulings":%s}\n' "$1" "$2" > "$W/state.json"
}
reset; stateum UNKNOWN "$U_REPLAY"
out="$(tick)"
sleep 1
check '8731 U4: an UNKNOWN mirror input prints rm-blocked=? (every ruling reads as replay then)' '?' "$(field rm-blocked "$out")"
reset; stateum UNKNOWN "$U_BLOCKED"
out="$(tick)"
check '8731 U4: and prints ? whatever the state lists as blocked' '?' "$(field rm-blocked "$out")"
reset; stateum UNKNOWN '[]'
out="$(tick)"
check '8731 U4: and prints ? with nothing listed: unknown is not none' '?' "$(field rm-blocked "$out")"
for mirror in FRESH STALE; do
    reset; stateum "$mirror" "$U_BLOCKED"
    out="$(tick)"
    check "8731 U4: control: a $mirror mirror input prints the set" '1:K-1@R-R1-0007' "$(field rm-blocked "$out")"
done
reset; stateum FRESH '[]'
out="$(tick)"
check '8731 U4: control: a FRESH mirror input with nothing blocked prints no rm-blocked' '' "$(field rm-blocked "$out")"

# 8731 U4: an unfinished_rulings that is not a list of rows with a key and a ruling id prints ?, never a partial set, an empty field or None@None
while IFS='|' read -r -u 3 shape body; do
    reset; stateu '[]' null null "$body"
    out="$(tick)"
    check "8731 U4: unfinished_rulings as $shape prints rm-blocked=?" '?' "$(field rm-blocked "$out")"
done 3<<'SHAPES'
a string|"blocked"
an object|{"ruling":"R-R1-0007","key":"K-1","status":"blocked"}
null|null
a list of non-objects|["x",1]
a row with a null key and ruling|[{"ruling":null,"key":null,"status":"blocked"}]
a row without a ruling id|[{"key":"K-1","status":"blocked"}]
a row without a key|[{"ruling":"R-R1-0007","status":"blocked"}]
a row with an empty key|[{"ruling":"R-R1-0007","key":"","status":"blocked"}]
a good blocked row beside a broken one|[{"ruling":"R-R1-0007","key":"K-1","status":"blocked"},{"status":"blocked"}]
SHAPES

# 8731 U4: the set prints in sorted order whichever way the state lists it, and beside an open request
ids_json() { # <numbers in the order to list>
    local n out=''
    for n in "$@"; do out="$out${out:+,}$(u_row2 "R-R1-000$n" "K-$n" blocked chief)"; done
    printf '[%s]' "$out"
}
WANT5='5:K-1@R-R1-0001,K-2@R-R1-0002,K-3@R-R1-0003,K-4@R-R1-0004,K-5@R-R1-0005'
reset; stateu '[]' null null "$(ids_json 1 2 3 4 5)"
check '8731 U4: five blocked rulings listed in ascending order print sorted' "$WANT5" "$(field rm-blocked "$(tick)")"
reset; stateu '[]' null null "$(ids_json 5 4 3 2 1)"
check '8731 U4: the same five listed in descending order print the same text' "$WANT5" "$(field rm-blocked "$(tick)")"
reset; stateu '[]' null null "$(ids_json 3 1 5 2 4)"
check '8731 U4: and listed in a mixed order' "$WANT5" "$(field rm-blocked "$(tick)")"
reset; stateu '["Q-1"]' "\"$(ago 1)\"" null "$U_BLOCKED"
out="$(tick)"
sleep 1
check '8731 U4: an open request and a blocked ruling together print both fields' '1,1m 1:K-1@R-R1-0007' "$(field rm-queue "$out") $(field rm-blocked "$out")"
check '8731 U4: and a young request still launches no rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

reset; state '[]' null null
out="$(tick)"
sleep 1
check 'an empty queue shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

printf '# chief\n' > "$W/handover/chief.md"
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(tick)"
sleep 1
check 'a chief doc with no release: line shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and asks no state and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"

# A real declaration with no usable chief line is broken wiring, not an empty queue.
mkdir -p "$HIMMEL_RELEASE_STATE_DIR/R1"
printf '{}\n' > "$HIMMEL_RELEASE_STATE_DIR/R1/release.json"
reset
out="$(tick)"
check 'declared release without a line reports off' 'off' "$(field rm-queue "$out")"
check 'off never reads state or launches a run' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"
mkdoc 'bad/name'
out="$(tick)"
check 'declared release with an invalid line reports off' 'off' "$(field rm-queue "$out")"
mkdoc none
rc=0; out="$(tick)" || rc=$?
check 'explicit none tick succeeds' 0 "$rc"
check 'explicit none still elides the field despite a declaration' '' "$(field rm-queue "$out")"
mkdoc none-test
reset; state '["Q-none"]' "\"$(ago 45)\"" null
rc=0; out="$(tick)" || rc=$?
check 'none-prefixed release tick succeeds' 0 "$rc"
check 'a valid none-prefixed release wakes normally' '1,45m,run' "$(field rm-queue "$out")"
check 'none-prefixed release is probed verbatim' 'none-test --json' "$(sed -n 1p "$W/state-asked" 2>/dev/null)"
mkdoc R1
printf 'broken\n' > "$W/state.json"
out="$(tick)"
check 'an unreadable state reports off instead of silently disabling the RM' 'off' "$(field rm-queue "$out")"
for status in UNKNOWN STALE; do
    reset
    printf '{"status":"%s","requests":{"open":[],"claimed":[]}}\n' "$status" > "$W/state.json"
    out="$(TICK_RMQ_EXIT=3 tick)"
    check "$status state is off even with an empty request list" off "$(field rm-queue "$out")"
    check "$status never launches an RM" '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
done
reset
printf '{"status":"OK","requests":{"open":[],"claimed":["Q-held"]}}\n' > "$W/state.json"
out="$(tick)"
sleep 1
check 'claimed-only requests remain visible' '0,0m,claimed=1' "$(field rm-queue "$out")"
check 'claimed-only requests never re-bill the held request' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
reset
printf '{"status":"OK","requests":{"open":["Q-new"],"claimed":["Q-held"],"oldest_open":"%s"}}\n' "$(ago 45)" > "$W/state.json"
out="$(tick)"
check 'open requests still wake while claimed work is visible' '1,45m,claimed=1,run' "$(field rm-queue "$out")"
check 'mixed queue launches just one run' 1 "$(ran)"

# No override: the declaration belongs to the primary checkout, not the chief bucket.
unset HIMMEL_RELEASE_STATE_DIR
checkout="$(git rev-parse --path-format=absolute --git-common-dir)"
checkout="${checkout%/.git}"
mkdir -p "$HANDOVER_DIR/$USER_SLUG/${checkout##*/}/release/Rcanonical"
printf '{}\n' > "$HANDOVER_DIR/$USER_SLUG/${checkout##*/}/release/Rcanonical/release.json"
printf '# chief\n' > "$W/handover/chief.md"
reset
out="$(tick)"
check 'canonical declaration with override unset reports missing wiring' off "$(field rm-queue "$out")"
check 'canonical missing wiring never probes or runs' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"
printf '> The project this console is FOR is **`%s`**.\n' "$W/projects/p" >> "$W/handover/chief.md"
out="$(tick)"
check 'foreign project never inherits the primary declaration warning' '' "$(field rm-queue "$out")"
rm -f "$W/handover/chief.md"
rc=0; out="$(tick)" || rc=$?
check 'missing chief doc tick succeeds' 0 "$rc"
check 'a missing chief doc still elides the field' '' "$(field rm-queue "$out")"

# Inline handovers belong to the script's primary checkout, not the observed --repo.
inline="$W/anchor"
mkdir -p "$inline/scripts/handover/chief-kit" "$inline/scripts/lanes" "$inline/handovers/tester/anchor/release/Rinline"
cp "$SUT" "$inline/scripts/handover/chief-kit/tick.sh"
cp -R "$HERE/../../lib" "$inline/scripts/lib"
cp -R "$HERE/../../lanes/lib" "$inline/scripts/lanes/lib"
git init -q "$inline"
printf '{}\n' > "$inline/handovers/tester/anchor/release/Rinline/release.json"
printf '# chief\n' > "$W/handover/chief.md"
reset
rc=0
out="$(unset HANDOVER_DIR HIMMEL_REPO; cd "$inline" && bash scripts/handover/chief-kit/tick.sh --repo "$W/repo" --doc "$W/handover/chief.md" 2>/dev/null)" || rc=$?
check 'inline primary-root tick succeeds with another observed repo' 0 "$rc"
check 'inline declaration reports off from the primary checkout' off "$(field rm-queue "$out")"

mkdoc R1
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(TICK_RMRUN_MIN=60 tick)"
sleep 1
check 'TICK_RMRUN_MIN=60 moves the threshold past a 45 min request' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

mkdoc R1
reset; state '["Q-1"]' "\"$(ago 3)\"" null
out="$(tick)"
check 'S3: with TICK_RMRUN_MIN unset, a 3 min request launches the rm-run (default 2)' '1,3m,run' "$(field rm-queue "$out")"
check 'S3: and the rm-run ran once' '1' "$(ran)"
check 'S3: tick --help says the default is 2' '1' "$(bash "$SUT" --help 2>&1 | grep -c 'TICK_RMRUN_MIN minutes (default 2)')"

GOLDEN="$HERE/fixtures/state-golden.json"
mkdoc R1
reset; cp "$GOLDEN" "$W/state.json"
out="$(tick)"
check 'rm-refused= counts every refused ask and lists the operator-asked one' '3:ABC-2@R-R1-0001' "$(field rm-refused "$out")"
gold() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); a=[x for x in d["refused_asks"] if x["key"]==sys.argv[2]][0]; print(a[sys.argv[3]])' "$GOLDEN" "$1" "$2"; }
tsv_row() { printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$(gold "$1" ruling)" "$(gold "$1" reason)" "$2" "$(gold "$1" ground)" "$(gold "$1" remedy)"; }
check 'the tsv holds one row per refused ask: key, ruling, reason, asks_operator, ground and the exact remedy' \
    "$(tsv_row ABC-2 1; echo; tsv_row ABC-3 0; echo; tsv_row ABC-4 0)" \
    "$(cat "$W/state/rm-refused-chief.tsv" 2>/dev/null)"
check 'release-state-<stem>.json carries status OK and the golden words_records and asks_operator_keys' 'OK|1|O-R1-0003|ABC-2' \
    "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%s|%d|%s|%s" % (d["status"], len(d["words_records"]), d["words_records"][0]["id"], ",".join(d["asks_operator_keys"])) + ("" if d.get("ts") else "|no-ts"))' "$W/state/release-state-chief.json" 2>/dev/null)"

mkdir -p "$W/cw/consoles"
: > "$W/cw/consoles/c.md"
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none rm-refused=%s\n' \
    "$(field rm-refused "$out")" > "$W/cw.line"
printf '#!/usr/bin/env bash\ncat "%s/cw.line"\n' "$W" > "$W/cw-tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/cw-bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/cw-off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$W/cw-budget.sh"
cw_wait() { # <timeout secs>: one chief-wait run against the tick line in cw.line
    CHIEF_WAIT_TICK="$W/cw-tick.sh" CHIEF_WAIT_USAGE="$W/cw-bank.sh" CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 \
    CHIEF_WAIT_PAGE_CMD="$W/cw-off.sh" CHIEF_WAIT_BUDGET="$W/cw-budget.sh" CHIEF_WAIT_ORPHAN="$W/cw-off.sh" CHIEF_WAIT_DISPATCH="$W/cw-off.sh" \
    WAIT_SWEEP_CMD="$W/cw-off.sh" WAIT_FOCUS_CMD="$W/cw-off.sh" HIMMEL_DENIAL_ACK_DIR="$W/acks" \
    timeout "${1:-20}" bash "$HERE/chief-wait.sh" "$W/cw/consoles/c.md" --doc "$W/handover/chief.md" --workers N1.md 2>/dev/null  # gnu-ok: Linux-only kit
}
cw_out="$(cw_wait 20)"
check "the tick's real tsv feeds chief-wait: one operator wake naming key, ruling, cause and the exact remedy, then the digest with its remedy" \
    "WAKE rm-refused ABC-2@R-R1-0001 — fix: $(gold ABC-2 reason) — ground: $(gold ABC-2 ground) — remedy: $(gold ABC-2 remedy)|WAKE rm-refused-digest 2 new: ABC-3@R-R1-0002,ABC-4@R-R1-0003 — remedy: $(gold ABC-3 remedy)" \
    "$(printf '%s\n' "$cw_out" | grep '^WAKE ' | paste -sd'|' -)"
# one delivery: the same refusals do not wake again
check 'the same pairs wake once: a second run on the unchanged tsv delivers nothing' '' "$(cw_wait 5 | grep '^WAKE ' || true)"
# changed evidence is a new ruling and so a new pair: it wakes once, with its own remedy, and the old pairs stay quiet
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); a=d["refused_asks"][0]; a["ruling"]="R-R1-0004"; a["reason"]="the operator words changed"; a["remedy"]=a["remedy"].replace("--why \"<why>\"", "--why \"<why>\" --required-by P-1"); print(json.dumps(d))' "$GOLDEN" > "$W/state.json"
out="$(tick)"
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none rm-refused=%s\n' \
    "$(field rm-refused "$out")" > "$W/cw.line"
check 'a changed ruling re-notifies once with the new cause and remedy; the old and unchanged pairs stay quiet' \
    "WAKE rm-refused ABC-2@R-R1-0004 — fix: the operator words changed — ground: $(gold ABC-2 ground) — remedy: $(gold ABC-2 remedy | sed 's/--why "<why>"/--why "<why>" --required-by P-1/')" \
    "$(cw_wait 20 | grep '^WAKE ' | paste -sd'|' -)"
# an older four-column row wakes as it always did, and control characters never reach the line
printf 'ABC-9\tR-R1-0009\told row reason\t1\nABC-8\tR-R1-0008\tbad\033[31m reason\t1\t\033[2Jground\tremedy with\033[0m escapes\n' > "$W/state/rm-refused-chief.tsv"
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none rm-refused=2:ABC-9@R-R1-0009,ABC-8@R-R1-0008\n' > "$W/cw.line"
cw_old="$(cw_wait 20 | grep '^WAKE ' | paste -sd'|' -)"
check 'an older four-column tsv row wakes in the old shape' 'WAKE rm-refused ABC-9@R-R1-0009 — fix: old row reason' "$(printf '%s' "$cw_old" | tr '|' '\n' | sed -n 1p)"
check 'control characters in a row never reach the wake line' '0' "$(printf '%s' "$cw_old" | grep -c "$(printf '\033')" || true)"
check 'a six-column row carries its ground and remedy with the escapes flattened' 'WAKE rm-refused ABC-8@R-R1-0008 — fix: bad [31m reason — ground: [2Jground — remedy: remedy with [0m escapes' "$(printf '%s' "$cw_old" | tr '|' '\n' | sed -n 2p | tr -d '\033')"

state '[]' null null
out="$(tick)"
check 'no refused ask shows no rm-refused field' '' "$(field rm-refused "$out")"
check 'and leaves an empty tsv' '' "$(cat "$W/state/rm-refused-chief.tsv" 2>/dev/null)"
cp "$GOLDEN" "$W/state.json"
tick > /dev/null
printf '{"status":"UNKNOWN","requests":{"open":[],"claimed":[]},"refused_asks":[{"key":"ABC-2","ruling":"R-R1-0001","req":"Q-R1-0001","reason":"x","asks_operator":true}]}\n' > "$W/state.json"
out="$(TICK_RMQ_EXIT=3 tick)"
check 'a state that is not OK shows no rm-refused field' '' "$(field rm-refused "$out")"
check 'and deletes release-state-<stem>.json and the tsv' 'gone' "$([ -e "$W/state/release-state-chief.json" ] || [ -e "$W/state/rm-refused-chief.tsv" ] || echo gone)"
cp "$GOLDEN" "$W/state.json"
mkdir -p "$W/state/.rm-refused-chief.tsv.tmp" "$W/state/.release-state-chief.json.tmp"
out="$(tick)"
check "another writer's temp file never blocks publication: each tick writes its own" '3:ABC-2@R-R1-0001|3' \
    "$(field rm-refused "$out")|$(wc -l < "$W/state/rm-refused-chief.tsv" 2>/dev/null | tr -d ' ')"
rf_before="$(cat "$W/state/rm-refused-chief.tsv")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["inputs"]["mirror"]="UNKNOWN"; [a.update(asks_operator=None) for a in d["refused_asks"]]; d["asks_operator_keys"]=[]; print(json.dumps(d))' "$GOLDEN" > "$W/state.json"
out="$(tick)"
check 'an unknown mirror shows no rm-refused field' '' "$(field rm-refused "$out")"
check 'and leaves the tsv as the last known read' "$rf_before" "$(cat "$W/state/rm-refused-chief.tsv" 2>/dev/null)"
check 'and deletes release-state-<stem>.json rather than claim no operator keys' 'gone' "$([ -e "$W/state/release-state-chief.json" ] || echo gone)"

# 8731 U3: the waiter wakes for a blocked ruling through the table row: once for a set, again only when the set changes.
# Every sample runs the real tick and carries its rm-blocked= token onto a fixed line, so a value that moved on every tick would wake every run.
printf '%s' 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none' > "$W/cw-base.line"
cat > "$W/cw-tick.sh" <<'STUB'
#!/usr/bin/env bash
b="$(bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null | tr ' ' '\n' | sed -n 's/^rm-blocked=//p' | head -n 1)"
printf '%s%s\n' "$(cat "$W/cw-base.line")" "${b:+ rm-blocked=$b}"
STUB
export W SUT
mkdoc R1
reset; stateu '[]' null null '[]'
cw_wait 6 > /dev/null
stateu '[]' null null "[$(u_row2 R-R1-0007 K-1 blocked chief)]"
check '8731 U3: a blocked ruling wakes the waiter, naming the field' 'WAKE tick changed=rm-blocked usage=PROCEED' "$(cw_wait 25 | grep '^WAKE ' || true)"
check '8731 U3: the same set on the next ticks wakes nothing' '' "$(cw_wait 8 | grep '^WAKE ' || true)"
stateu '[]' null null "[$(u_row2 R-R1-0007 K-1 blocked chief),$(u_row2 R-R1-0008 K-2 blocked chief)]"
check '8731 U3: a changed set wakes again' 'WAKE tick changed=rm-blocked usage=PROCEED' "$(cw_wait 25 | grep '^WAKE ' || true)"
check '8731 U3: a state read that fails is unknown: the set is kept, nothing wakes' '' "$(TICK_RMQ_EXIT=124 cw_wait 8 | grep '^WAKE ' || true)"
stateu '[]' null null '[]'
check '8731 U3: a set that empties wakes nothing' '' "$(cw_wait 8 | grep '^WAKE ' || true)"
stateu '[]' null null "[$(u_row2 R-R1-0007 K-1 blocked chief)]"
check '8731 U3: a ruling that blocks again after the set emptied wakes again' 'WAKE tick changed=rm-blocked usage=PROCEED' "$(cw_wait 25 | grep '^WAKE ' || true)"

# 8731 U4: a member swapped at the same count is a changed set; an unknown mirror input keeps the last known set, so the same set returning wakes
# nobody and a different set after it wakes once. The saved set going in is the one the previous row woke for.
stateu '[]' null null "[$(u_row2 R-R1-0008 K-2 blocked chief)]"
check '8731 U4: a member swapped at the same count (K-1 for K-2) wakes' 'WAKE tick changed=rm-blocked usage=PROCEED' "$(cw_wait 25 | grep '^WAKE ' || true)"
stateum UNKNOWN "[$(u_row2 R-R1-0008 K-2 replay release-manager)]"
check '8731 U4: an UNKNOWN mirror input (the engine lists the ruling as replay) wakes nobody' '' "$(cw_wait 8 | grep '^WAKE ' || true)"
stateu '[]' null null "[$(u_row2 R-R1-0008 K-2 blocked chief)]"
check '8731 U4: the same set returning after the unknown wakes nobody' '' "$(cw_wait 8 | grep '^WAKE ' || true)"
stateum UNKNOWN "[$(u_row2 R-R1-0008 K-2 replay release-manager)]"
cw_wait 8 > /dev/null
stateu '[]' null null "[$(u_row2 R-R1-0007 K-1 blocked chief)]"
check '8731 U4: a different set after an unknown wakes once' 'WAKE tick changed=rm-blocked usage=PROCEED' "$(cw_wait 25 | grep '^WAKE ' || true)"
check '8731 U4: and that set is then the baseline: no second wake' '' "$(cw_wait 8 | grep '^WAKE ' || true)"
rm -f "$W/cw/consoles/c.md.wait.state"
check '8731 U4: a set already present when the waiter has no saved key is its baseline: wakes nobody' '' "$(cw_wait 8 | grep '^WAKE ' || true)"

statel() {
    printf '{"status":"%s","versions":["v1.1.3","v1.1.4"],"lease":null,"requests":{"open":[],"claimed":[],"oldest_open":null},"priority_review":%s,"chief_placements":%s,"asks_apart":%s}\n' "${4:-OK}" "$1" "$2" "$3" > "$W/state.json"
}
mkdoc R1
reset; statel '[]' '[]' '[]'
rc0=0; out="$(tick)" || rc0=$?
check 'S1b: empty lists print no prio-review, chief-placed or ask-apart field' '||' "$(field prio-review "$out")|$(field chief-placed "$out")|$(field ask-apart "$out")"
reset; statel '[{"key":"K-2","ruling":"R-R1-0002","ground":"door:mild"},{"key":"K-3","ruling":"R-R1-0003","ground":"door:started"}]' \
    '[{"key":"K-5","ruling":"R-R1-0005","reason":"the chief placed it"}]' \
    '[{"key":"K-7","ruling":"R-R1-0007","version":"v1.1.4","parent":"P-1","parent_version":"v1.1.3"},{"key":"K-8","ruling":"R-R1-0008","version":"backlog","parent":"P-2","parent_version":"v1.1.3"}]'
rc1=0; out="$(tick)" || rc1=$?
check 'S1b: prio-review= counts the priority review and names its oldest key' '2:K-2' "$(field prio-review "$out")"
check 'S1b: chief-placed= counts the chief placements and names each key' '1:K-5' "$(field chief-placed "$out")"
check 'S1b: ask-apart= counts the asks apart and names each key' '2:K-7,K-8' "$(field ask-apart "$out")"
check 'S1b: rm-lists-<stem>.tsv holds a row per chief placement and ask apart for the waiter' \
    "$(printf 'chief\tK-5\tR-R1-0005\tthe chief placed it\t\t\napart\tK-7\tR-R1-0007\tv1.1.4\tP-1\tv1.1.3\napart\tK-8\tR-R1-0008\tbacklog\tP-2\tv1.1.3')" \
    "$(cat "$W/state/rm-lists-chief.tsv" 2>/dev/null)"
check 'S1b: listed entries never change the tick exit code' "$rc0" "$rc1"
check 'S1b: none of the three fields is a row of the wake table (outside the action key)' '' "$(cut -f1 "$HERE/wake-rules.tsv" | grep -xE 'prio-review|chief-placed|ask-apart' || true)"
statel '[{"key":"K-2","ruling":"R-R1-0002","ground":"door:mild"}]' '[{"key":"K-5","ruling":"R-R1-0005","reason":"r"}]' '[]' DEGRADED
out="$(tick)"
check 'S1b: a state that is not OK prints none of the three fields' '||' "$(field prio-review "$out")|$(field chief-placed "$out")|$(field ask-apart "$out")"
check 'S1b: and leaves no rm-lists tsv' 'gone' "$([ -e "$W/state/rm-lists-chief.tsv" ] || echo gone)"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
