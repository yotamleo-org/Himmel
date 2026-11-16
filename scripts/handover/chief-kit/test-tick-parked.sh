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
printf '# dropped from v1: 25 of 25 To Do (listed 25)\n' > "$W/pool25.rows"
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

K1=HIMMEL-8001 K2=HIMMEL-8002 K3=HIMMEL-8003
ucnt() { printf '%s\n' "$1" | grep -c "^# pool-unresolved $2 HIMMEL-$3 "; }
uline() { printf '%s\n' "$1" | grep "^# pool-unresolved $2 HIMMEL-$3 "; }
E0=1800000000
RDN=$((E0 + 7200))
RD_SH="$HERE/readiness.sh"
RDW="$W/rd"
RM="$RDW/mirror/HIMMEL"
RS="$RDW/state"
RREL="$RDW/rel"
mkdir -p "$RM" "$RS"
mk_tk() {
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "High"\nlabels: ["standalone","phase:%s"]\nfixVersions: ["v1"]\nparent: null\ncreated: "x"\nupdated: "x"\nresolution: null\nresolved: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: fixture\n\n## Description\n\n%s\n\n## Comments\n\n_(none)_\n' \
        "$1" "$2" "$3" "$4" "$1" "$5" > "$RM/$1.md"
}
reset_mirror() {
    local k
    rm -f "$RM"/*.md
    for k in HIMMEL-8001 HIMMEL-8002 HIMMEL-8003 HIMMEL-8004 HIMMEL-8102; do mk_tk "$k" 'To Do' 'To Do' design "body of $k"; done
}
rd_ap() { READINESS_NOW_EPOCH=$E0 HIMMEL_RELEASE_STATE_DIR="$1" bash "$RD_SH" append v1 "${@:2}" --by fixture --mirror "$RM" > /dev/null 2>&1; }
rd_record() {
    rm -rf "$RREL"; mkdir -p "$RREL/v1"
    rd_ap "$RREL" HIMMEL-8001 c --evidence x --blocker HIMMEL-8102
    [ "${1:-}" = no-d ] || rd_ap "$RREL" HIMMEL-8002 d --evidence x
    rd_ap "$RREL" HIMMEL-8003 a --evidence x
}
pd() {
    local docarg=()
    [ -z "$2" ] || docarg=(--doc "$2")
    NEXT_DISPATCH_MIRROR="$RM" TICK_STATE_DIR="$RS" HIMMEL_RELEASE_STATE_DIR="$1" READINESS_NOW_EPOCH=$RDN DOC='' \
        bash "$SUT" --pool-dispositions "${docarg[@]}" < "$3" 2> /dev/null  # read-sink-ok: a snapshot fixture this suite wrote under its own temp root
}
rtick() {
    cp "$3" "$RS/tick-pool-$(printf '%s\n%s' "$(realpath -m "$2")" "$RM" | cksum | cut -d' ' -f1).rows"
    NEXT_DISPATCH_MIRROR="$RM" TICK_STATE_DIR="$RS" HIMMEL_RELEASE_STATE_DIR="$1" READINESS_NOW_EPOCH=$RDN TICK_POOL_WAIT=0 TICK_POOL_MIN_SECS=99999 \
        bash "$SUT" --doc "$2" 2> /dev/null
}
RDOC="$RDW/chief.md"
printf '%s\n' '# chief' '' '## Live state' '' '## Results' > "$RDOC"
reset_mirror
rd_record

out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T1: --pool-dispositions prints the readiness counts of the record' "$(printf '%s\n' "$out" | grep '^# readiness ')" '# readiness v1 blocked=1 chief-sign=1:2h rows-stale=0'
same 'T1: a live c row and a live d row are removed from pool-unresolved and counted disposed (the pool-counts numbers move)' "$(printf '%s\n' "$out" | grep '^# pool-counts ')" '# pool-counts 25/0/2/23'
same 'T1: the removed keys are not named unresolved, an a row is not a ruling' "$(ucnt "$out" '[a-z]*' 8001)/$(ucnt "$out" '[a-z]*' 8002)/$(ucnt "$out" '[a-z]*' 8003)" '0/0/1'
same 'T1: a live c and a live d row are listed held, sorted by key' "$(printf '%s\n' "$out" | grep '^# readiness-held ' | paste -sd'|')" '# readiness-held c HIMMEL-8001 blocker=HIMMEL-8102 age=2h|# readiness-held d HIMMEL-8002 blocker=- age=2h'
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T1: the tick line carries the three fields after the record is read' "$t" ' blocked=1 chief-sign=1:2h rows-stale=0'
rd_record no-d
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T1: with the d row removed the header reads chief-sign=0 with no age' "$(printf '%s\n' "$out" | grep '^# readiness ')" '# readiness v1 blocked=1 chief-sign=0 rows-stale=0'
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T1: the tick line carries chief-sign=0' "$t" ' chief-sign=0 '
not_contains 'T1: and chief-sign=0 carries no age' "$t" ' chief-sign=0:'
rm -f "$RREL/v1/readiness.jsonl"
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T1 control: a version directory with no record reads all zero' "$(printf '%s\n' "$out" | grep '^# readiness ')|$(printf '%s\n' "$out" | grep '^# pool-counts ')" '# readiness v1 blocked=0 chief-sign=0 rows-stale=0|# pool-counts 25/0/0/25'

rd_record
mk_tk HIMMEL-8102 Done Done design 'body of HIMMEL-8102'
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T2: a c row whose blocker reads Done is stale and counted' "$(printf '%s\n' "$out" | grep '^# readiness ')" '# readiness v1 blocked=0 chief-sign=1:2h rows-stale=1'
same 'T2: the stale row is named with its reason' "$(printf '%s\n' "$out" | grep '^# readiness-stale ')" '# readiness-stale HIMMEL-8001 blocker-done'
same 'T2: a stale row is no ruling, so its key is unresolved again' "$(ucnt "$out" listed 8001)" 1
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T2: the tick line carries blocked=0 and rows-stale=1' "$t" ' blocked=0 chief-sign=1:2h rows-stale=1'
rm -f "$RM/HIMMEL-8002.md"
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T2: a ruled key whose mirror file is gone is named no-ticket, and is not counted' "$(printf '%s\n' "$out" | grep -E '^# readiness( |-stale)')" "$(printf '%s\n' '# readiness v1 blocked=0 chief-sign=0 rows-stale=1' "# readiness-stale $K1 blocker-done" "# readiness-stale $K2 no-ticket")"

reset_mirror
mk_tk HIMMEL-8001 'To Do' 'To Do' design 'body of HIMMEL-8001 changed'
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T3: a changed description makes the row stale' "$(printf '%s\n' "$out" | grep -E '^# readiness( |-stale)')" "$(printf '%s\n' '# readiness v1 blocked=0 chief-sign=1:2h rows-stale=1' "# readiness-stale $K1 stamp")"
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T3: the tick line carries blocked=0 and rows-stale=1' "$t" ' blocked=0 chief-sign=1:2h rows-stale=1'

reset_mirror
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T4 control: with the fixture restored blocked=1 and rows-stale=0 come back' "$t" ' blocked=1 chief-sign=1:2h rows-stale=0'
grep -v '^# dropped from' "$W/pool25.rows" > "$W/pool25-nodrop.rows"
out="$(pd "$RREL" "$RDOC" "$W/pool25-nodrop.rows")"
same 'T4: a snapshot with no dropped-from line prints # readiness ?' "$(printf '%s\n' "$out" | grep '^# readiness')" '# readiness ?'
t="$(rtick "$RREL" "$RDOC" "$W/pool25-nodrop.rows")"
contains 'T4: and the tick shows blocked=?' "$t" ' blocked=? chief-sign=? rows-stale=?'
out="$(pd "$RREL" "$RDW/no-such-doc.md" "$W/pool25.rows")"
same 'T4: an unreadable doc prints # readiness ? before # pool-counts ?' "$(printf '%s\n' "$out" | grep '^# \(readiness\|pool-counts\)' | paste -sd'|')" '# readiness ?|# pool-counts ?'
mv "$RREL/v1" "$RREL/v1.away"
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T4: a missing version directory prints # readiness ?' "$(printf '%s\n' "$out" | grep '^# readiness')" '# readiness ?'
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T4: and the tick shows blocked=?' "$t" ' blocked=? chief-sign=? rows-stale=?'
mv "$RREL/v1.away" "$RREL/v1"
printf '# dropped from v1: 1 of 1 To Do (blocker 1)\n' > "$W/empty.rows"
out="$(pd "$RREL" "$RDOC" "$W/empty.rows")"
same 'T4: the empty snapshot reaches the no-rows exit and prints # readiness ? before # pool-counts ?' "$(printf '%s\n' "$out" | grep '^# \(readiness\|pool-counts\)' | paste -sd'|')" '# readiness ?|# pool-counts ?'
out="$(pd "$RREL" '' "$W/empty.rows")"
same 'T4: the same snapshot with no --doc prints # pool-counts ? and no # readiness line' "$(printf '%s\n' "$out" | grep -c '^# readiness')/$(printf '%s\n' "$out" | grep -c '^# pool-counts ?$')" '0/1'
out="$(pd "$RREL" '' "$W/pool25.rows")"
same 'T4: --pool-dispositions on pool25.rows with no --doc (the waiter second pass) prints no # readiness line' "$(printf '%s\n' "$out" | grep -c '^# readiness')" 0

T5="$W/rd5"; mkdir -p "$T5/a" "$T5/b"
reset_mirror
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-8001 question decision 964 waiting on the operator ruling' \
    'pool-disposition: HIMMEL-8002 maybe later' \
    'pool-disposition: HIMMEL-8003 question decision 964 waiting on the operator ruling' \
    '' '## Results' > "$T5/a/chief.md"
printf 'CLOSE-OR-DISPATCH HIMMEL-8001 the ticket is done in all but name\n' > "$T5/a/focus-drift.txt"
lh5="$(printf '%s question decision 964 waiting on the operator ruling' "$K3" | sha256sum | cut -c1-12)"
st5="$T5/a/state"; mkdir -p "$st5"
stale5="tick-pool-stale-$(printf '%s\n%s' "$(realpath -m "$T5/a/chief.md")" "$(realpath -m "$RM")" | cksum | cut -d' ' -f1).out"
printf '# mirror=%s\nSTALE-DISPOSITION HIMMEL-8003 line=%s HIMMEL-901=Done\npool-stale=1:HIMMEL-8003\npool-changed=0\nresidual-unversioned=skip\n' "$(realpath -m "$RM")" "$lh5" > "$st5/$stale5"
pd5() { NEXT_DISPATCH_MIRROR="$RM" TICK_STATE_DIR="$st5" HIMMEL_RELEASE_STATE_DIR="$T5/a/rel" READINESS_NOW_EPOCH=$RDN DOC='' bash "$SUT" --pool-dispositions --doc "$T5/a/chief.md" < "$W/pool25.rows" 2> /dev/null; }
mkdir -p "$T5/a/rel/v1"
base5="$(pd5)"
same 'T5 control: with no record 8001 is stale on its question decision, 8003 on its gone target, 8002 invalid' "$(uline "$base5" stale 8001 | grep -c 'its question decision names no end')/$(ucnt "$base5" stale 8003)/$(ucnt "$base5" invalid 8002)" '1/1/1'
rd_ap "$T5/a/rel" HIMMEL-8001 c --evidence x --blocker 964
rd_ap "$T5/a/rel" HIMMEL-8002 d --evidence x
rd_ap "$T5/a/rel" HIMMEL-8003 c --evidence x --blocker HIMMEL-8102
o5="$(pd5)"
same 'T5: a decision-number c row on a CLOSE-OR-DISPATCH key stays stale with the readiness-row text' "$(uline "$o5" stale 8001)" "# pool-unresolved stale $K1 its readiness row names decision 964, which has no observable end: the key carries a CLOSE-OR-DISPATCH drift row; close the ticket or name a worker"
same 'T5: an invalid document line stays invalid under a live d row' "$(ucnt "$o5" invalid 8002)" 1
same 'T5: a stale document line under a live c row is removed from pool-unresolved' "$(ucnt "$o5" '[a-z]*' 8003)" 0
same 'T5: and it gets no pool-parked line, parking reads the pre-override unresolved list' "$(count_line "$o5" pool-parked 8003)" 0
same 'T5: the pool-counts move by the one removed key' "$(printf '%s\n' "$o5" | grep '^# pool-counts ')" '# pool-counts 25/0/1/24'
printf '%s\n' '# chief' 'release: v1' '' '## Live state' \
    'pool-disposition: HIMMEL-8004 question decision 964 waiting on the operator ruling' \
    '' '## Results' > "$T5/b/chief.md"
mkdir -p "$T5/b/rel/v1"; printf '{}\n' > "$T5/b/rel/v1/release.json"
pd5b() { NEXT_DISPATCH_MIRROR="$RM" TICK_STATE_DIR="$T5/b/state" HIMMEL_RELEASE_STATE_DIR="$T5/b/rel" READINESS_NOW_EPOCH=$RDN DOC='' bash "$SUT" --pool-dispositions --doc "$T5/b/chief.md" < "$W/pool25.rows" 2> /dev/null; }
b0="$(pd5b)"
rd_ap "$T5/b/rel" HIMMEL-8004 c --evidence x --blocker HIMMEL-8102
b1="$(pd5b)"
same 'T5 control: the held key is unchecked with no holds file' "$(uline "$b0" unchecked 8004 | grep -c '^[^ ]* [^ ]* [^ ]* [^ ]* no holds file: ')" 1
same 'T5: a live c row does not lift a hold, its pool-unresolved line is byte-identical' "$(uline "$b1" unchecked 8004)" "$(uline "$b0" unchecked 8004)"
same 'T5: and pool-counts is unchanged by the row' "$(printf '%s\n' "$b1" | grep '^# pool-counts ')" "$(printf '%s\n' "$b0" | grep '^# pool-counts ')"

reset_mirror
rd_record
mk_tk HIMMEL-8002 'In Progress' 'In Progress' build 'body of HIMMEL-8002'
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T6: while the d ticket is In Progress the tick line shows chief-sign=0' "$t" ' blocked=1 chief-sign=0 '
same 'T6: and the row is listed why=in-progress' "$(printf '%s\n' "$out" | grep '^# readiness-held d ')" '# readiness-held d HIMMEL-8002 blocker=- age=2h why=in-progress'
mk_tk HIMMEL-8002 'To Do' 'To Do' design 'body of HIMMEL-8002'
t="$(rtick "$RREL" "$RDOC" "$W/pool25.rows")"
contains 'T6: back in To Do chief-sign=1:2h returns with the same age' "$t" ' chief-sign=1:2h '
rd_ap "$RREL" HIMMEL-8002 a --evidence signed
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T7: after the chief signs (an a row) chief-sign=0 and no held d line' "$(printf '%s\n' "$out" | grep '^# readiness ')/$(printf '%s\n' "$out" | grep -c '^# readiness-held d ')" '# readiness v1 blocked=1 chief-sign=0 rows-stale=0/0'
rd_record no-d
mk_tk HIMMEL-8002 'In Progress' 'In Progress' build 'body of HIMMEL-8002'
rd_ap "$RREL" HIMMEL-8002 d --evidence fresh
out="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same 'T7: a fresh d row on an In Progress ticket is not counted and is listed why=in-progress' "$(printf '%s\n' "$out" | grep '^# readiness ')/$(printf '%s\n' "$out" | grep '^# readiness-held d ')" '# readiness v1 blocked=1 chief-sign=0 rows-stale=0/# readiness-held d HIMMEL-8002 blocker=- age=2h why=in-progress'

reset_mirror
rd_record
RDN=$((E0 + 23 * 3600))
clock23="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
RDN=$((E0 + 25 * 3600))
clock25="$(pd "$RREL" "$RDOC" "$W/pool25.rows")"
same '10011 reminders do not change dispatchability' "$(printf '%s\n' "$clock23" | grep '^# pool-counts ')" "$(printf '%s\n' "$clock25" | grep '^# pool-counts ')"
clock_input="$(printf '%s\n' "$clock25" | sed -n 's/^# readiness-clock //p' | jq -s .)"
same '10011 readiness supplies accepted since/stamp and elapsed age' "$(printf '%s' "$clock_input" | jq -r '.[0] | [.key,.age_s] | @tsv')" $'HIMMEL-8002\t90000'
clock_events="$(printf '%s' "$clock_input" | python3 "$HERE/owed-events.py" --bucket "$RDW" --now "$RDN")"
same '10011 d produces a chief reminder and one operator digest input' "$(printf '%s' "$clock_events" | jq -r '[(.reminders|length),(.operator_digest|length)] | @tsv')" $'1\t1'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-parked.sh'
    exit 0
fi
printf 'FAIL - test-tick-parked.sh (%s failure(s))\n' "$fails"
exit 1
