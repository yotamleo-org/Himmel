#!/usr/bin/env bash
# PLATFORM GUARD: The chief kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
# shellcheck disable=SC2154  # fails is set by the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
count_line() { printf '%s\n' "$1" | grep -c "^# $2 HIMMEL-$3\$"; }

PDOC="$W/handover/parked-chief.md"
mkdir -p "$W/handover"
{
    printf '%s\n' '# chief' '' '## Live state'
    for n in 8001 8002 8003 8004 8005 8006 8007 8008 8009 8010 8011 8012; do
        printf 'pool-disposition: HIMMEL-%s question decision 936 chief live proof owed (S 11-14 20:35Z re-read)\n' "$n"
    done
    printf 'pool-disposition: HIMMEL-8013 question decision 936 critic round owed on its spec (S 11-14 20:35Z re-read)\n'
    printf 'pool-disposition: HIMMEL-8014 question decision 936 chief signature owed before a build (S 11-14 20:35Z re-read)\n'
    printf 'pool-disposition: HIMMEL-8015 question decision 902 paid steps need the operator go code (S 11-14 20:35Z re-read)\n'
    printf 'pool-disposition: HIMMEL-8016 question decision 936 Proof needs the Mac station (S 11-14 20:35Z re-read)\n'
    for n in 8017 8018 8019 8020 8021 8022; do
        printf 'pool-disposition: HIMMEL-%s slice after HIMMEL-9479 T8 and T11 land (S 11-14 20:35Z re-read)\n' "$n"
    done
    printf 'pool-disposition: HIMMEL-8023 slice after HIMMEL-9561 closing drift run live (S 11-14 20:35Z re-read)\n'
    printf 'pool-disposition: HIMMEL-8024 question decision 902 held on bridge P1 rows (S 11-14 20:35Z re-read)\n'
    printf '%s\n' '' '## Results'
} > "$PDOC"
: > "$W/pool25.rows"
for n in $(seq 8001 8025); do
    printf 'LOCAL\tHIMMEL-%s\tMedium\tv1\trow %s\tfiles=f%s.sh\n' "$n" "$n" "$n" >> "$W/pool25.rows"
done
for n in $(seq 8001 8025); do printf '# disposition HIMMEL-%s listed LOCAL\n' "$n"; done >> "$W/pool25.rows"

out="$(DOC='' bash "$SUT" --pool-dispositions --doc "$PDOC" < "$W/pool25.rows" 2>/dev/null)"
same 'RED/GREEN: the 25 listed rows stay pool-dispatchable (chief-wait.sh counts these)' "$(printf '%s\n' "$out" | grep -c '^# pool-dispatchable ')" 25
same 'RED/GREEN: the 24 keys with a fresh disposition line print as pool-parked' "$(printf '%s\n' "$out" | grep -c '^# pool-parked ')" 24
same 'a parked key is named' "$(count_line "$out" pool-parked 8001)" 1
same 'the 16 owed lines (proof, critic round, signature, go code) print as pool-chief-owed' "$(printf '%s\n' "$out" | grep -c '^# pool-chief-owed ')" 16
same 'a line naming no chief step is parked but not chief-owed' "$(count_line "$out" pool-chief-owed 8017)" 0
same 'a go code line is chief-owed' "$(count_line "$out" pool-chief-owed 8015)" 1
same 'negative control: a key with no disposition line is not parked' "$(count_line "$out" pool-parked 8025)" 0
same 'negative control: a key with no disposition line stays dispatchable' "$(count_line "$out" pool-dispatchable 8025)" 1
same 'every chief-owed key is also parked' "$(comm -13 <(printf '%s\n' "$out" | sed -n 's/^# pool-parked //p' | sort) <(printf '%s\n' "$out" | sed -n 's/^# pool-chief-owed //p' | sort) | wc -l | tr -d ' ')" 0

nodoc="$(DOC='' bash "$SUT" --pool-dispositions < "$W/pool25.rows" 2>/dev/null)"
same 'without --doc nothing is parked' "$(printf '%s\n' "$nodoc" | grep -c '^# pool-parked ')" 0

PDOC2="$W/handover/parked-bad.md"
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-8001 question decision 936 chief live proof owed' \
    'pool-disposition: HIMMEL-8001 question decision 936 chief live proof owed again' \
    'pool-disposition: HIMMEL-8002 question will look at it after the release' \
    'pool-disposition: HIMMEL-8999 question decision 936 chief live proof owed' \
    'pool-disposition: HIMMEL-8003 question decision 936 chief live proof owed' \
    '' '## Results' > "$PDOC2"
bad="$(DOC='' bash "$SUT" --pool-dispositions --doc "$PDOC2" < "$W/pool25.rows" 2>/dev/null)"
same 'a duplicate line parks nothing for its key' "$(count_line "$bad" pool-parked 8001)" 0
same 'an unowned free-text line parks nothing' "$(count_line "$bad" pool-parked 8002)" 0
same 'a line for a key the pool does not list parks nothing' "$(count_line "$bad" pool-parked 8999)" 0
same 'the one valid line in that doc is parked, and only it' "$(printf '%s\n' "$bad" | sed -n 's/^# pool-parked //p' | paste -sd,)" "$(printf 'HIMMEL-%s' 8003)"

ST="$W/parked-state"; mkdir -p "$ST"
PM="$W/parked-mirror/HIMMEL"; mkdir -p "$PM"
DOC3="$W/handover/parked-stale.md"
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-8001 question decision 936 chief live proof owed' \
    'pool-disposition: HIMMEL-8002 question decision 936 chief live proof owed' \
    '' '## Results' > "$DOC3"
lh="$(printf 'HIMMEL-%s question decision 936 chief live proof owed' 8001 | sha256sum | cut -c1-12)"
stale_name="tick-pool-stale-$(printf '%s\n%s' "$(realpath -m "$DOC3")" "$(realpath -m "$PM")" | cksum | cut -d' ' -f1).out"
printf '# mirror=%s\n# stale-file=%s/%s\nSTALE-DISPOSITION HIMMEL-8001 line=%s HIMMEL-901=Done\npool-stale=1:HIMMEL-8001\npool-changed=0\nresidual-unversioned=skip\n' \
    "$(realpath -m "$PM")" "$ST" "$stale_name" "$lh" > "$ST/$stale_name"
stale="$(NEXT_DISPATCH_MIRROR="$PM" TICK_STATE_DIR="$ST" DOC='' bash "$SUT" --pool-dispositions --doc "$DOC3" < "$W/pool25.rows" 2>/dev/null)"
same 'a stale line is not fresh: its key is not parked' "$(count_line "$stale" pool-parked 8001)" 0
same 'a fresh line beside it still parks' "$(count_line "$stale" pool-parked 8002)" 1

launch_log="$W/chief-work/chain/HIMMEL-9-N1-x.launch.log"
mkdir -p "$W/chief-work/chain"
: > "$launch_log"; touch -d '2 hours ago' "$launch_log"
TM="$W/tick-mirror/HIMMEL"; mkdir -p "$TM"
TS="$W/tick-state"; mkdir -p "$TS"
seed_fresh_pool_snapshot() {
    local base
    base="$TS/tick-pool-$(printf '%s\n%s' "$(realpath -m "$1")" "$TM" | cksum | cut -d' ' -f1)"
    cp "$2" "$base.rows"
}
tick() { NEXT_DISPATCH_MIRROR="$TM" TICK_STATE_DIR="$TS" TICK_POOL_WAIT=0 TICK_POOL_MIN_SECS=99999 bash "$SUT" --doc "$1" 2>/dev/null; }
seed_fresh_pool_snapshot "$PDOC" "$W/pool25.rows"
t="$(tick "$PDOC")"
contains 'RED/GREEN: the tick line carries pool-parked=24' "$t" ' pool-parked=24 '
contains 'the tick line carries chief-owed=16' "$t" ' chief-owed=16 '
contains 'RED/GREEN: 25 listed rows less 24 parked is 1 free, below the slack of 7: supply=SHORT:1' "$t" ' supply=SHORT:1 '
contains 'capacity= is unchanged, chief-wait.sh reads UNDERFILLED:<slack> from it' "$t" 'capacity=UNDERFILLED:7'
v="$(NEXT_DISPATCH_MIRROR="$TM" TICK_STATE_DIR="$TS" TICK_POOL_WAIT=0 TICK_POOL_MIN_SECS=99999 bash "$SUT" --verbose --doc "$PDOC" 2>/dev/null)"
contains '--verbose says supply short' "$v" 'supply: SHORT:1'

free_doc="$W/handover/parked-free.md"
printf '%s\n' '# chief' '' '## Live state' '' '## Results' > "$free_doc"
: > "$W/pool8.rows"
for n in $(seq 8101 8108); do printf 'LOCAL\tHIMMEL-%s\tMedium\tv1\trow\tfiles=g%s.sh\n' "$n" "$n" >> "$W/pool8.rows"; done
for n in $(seq 8101 8108); do printf '# disposition HIMMEL-%s listed LOCAL\n' "$n" >> "$W/pool8.rows"; done
seed_fresh_pool_snapshot "$free_doc" "$W/pool8.rows"
t8="$(tick "$free_doc")"
not_contains 'negative control: free rows at or above the slack print no supply=' "$t8" ' supply='
not_contains 'negative control: nothing parked prints no pool-parked=' "$t8" ' pool-parked='

tok="$(STUB_FLEET_LINE='bank-preflight: FLEET native=8 claudex=0 reserved=0 total=8/8' NEXT_DISPATCH_MIRROR="$TM" TICK_STATE_DIR="$TS" TICK_POOL_WAIT=0 TICK_POOL_MIN_SECS=99999 bash "$SUT" --doc "$PDOC" 2>/dev/null)"
not_contains 'a full fleet prints no supply=' "$tok" ' supply='
contains 'a full fleet still counts the parked rows' "$tok" ' pool-parked=24 '

nopool="$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" TICK_STATE_DIR="$TS" bash "$SUT" --doc "$PDOC" 2>/dev/null)"
not_contains 'a tick with no readable pool prints no supply=' "$nopool" ' supply='

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-parked.sh'
    exit 0
fi
printf 'FAIL - test-tick-parked.sh (%s failure(s))\n' "$fails"
exit 1
