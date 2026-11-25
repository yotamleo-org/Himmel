#!/usr/bin/env bash
# Table/wake integration uses the same offline process fixture as the stream.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-rules-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

python3 -I "$HERE/test-chief-wait-stream.py" Stream.test_rules_table_is_the_printed_contract Stream.test_station_repair_aged_queue_and_mon_wakes || fails=$((fails + 1))

TABLE="${WAKE_RULES_TABLE:-$HERE/wake-rules.tsv}"
REL="$W/release/R1"
mkdir -p "$REL" "$W/home"
printf '# chief\nrelease: R1\n' > "$W/doc.md"

wr() {
    local inbox="$W/$1" tick="$2" out rc
    shift 2
    out="$(printf '%s\n' "$tick" | env -i PATH="$PATH" HOME="$W/home" "$@" \
        python3 -I "$HERE/wake-rules.py" --inbox "$inbox" --doc "${DOC:-$W/doc.md}" --release-root "$W/release" 2>/dev/null)"
    rc=$?
    printf '%s %s' "$rc" "$out"
}

REPAIR_UNAVAILABLE='WAKE repair off:unread remedy=unavailable; reconcile CLI-owned repair-state record'
QUEUE='WAKE rm-queue rm-queue=1,31m'
MON='WAKE mon monitor down since=1234; inspect bridge monitor/state and monitoring bot/group wiring'
TICK_RQ="TICK workers=0 repair=off:unread rm-queue=1,31m capacity=FULL"

printf '%s' '{"operator_command": "run X"}' > "$REL/repair-state.json"
check 'X11-7 control: an object record gives its remedy' '0 WAKE repair off:unread remedy=run X' "$(wr c1 "$TICK_RQ")"
rm -f "$REL/repair-state.json"
check 'X11-7 control: an absent record is remedy unavailable' "0 $REPAIR_UNAVAILABLE" "$(wr c2 "$TICK_RQ")"
printf '%s' 'not json' > "$REL/repair-state.json"
check 'X11-7 control: a garbled record is remedy unavailable' "0 $REPAIR_UNAVAILABLE" "$(wr c3 "$TICK_RQ")"

for record in '[]' 'null' '"s"' '7' '{"operator_command": null}'; do
    printf '%s' "$record" > "$REL/repair-state.json"
    check "X11-7: record $record is remedy unavailable" "0 $REPAIR_UNAVAILABLE" "$(wr "r-$record" "$TICK_RQ")"
    check "X11-7: record $record leaves the later rm-queue rule running" "0 $QUEUE" "$(wr "r-$record" "$TICK_RQ")"
done

printf '%s' '{"operator_command": "run X"}' > "$REL/repair-state.json"
mkdir -p "$W/dir.md"
printf '\377\376\n' > "$W/binary.md"
for bad in "$W/dir.md" "$W/binary.md" "$W/missing.md"; do
    name="d-$(basename "$bad")"
    check "X11-7: doc $(basename "$bad") is remedy unavailable" "0 $REPAIR_UNAVAILABLE" "$(DOC="$bad" wr "$name" "$TICK_RQ")"
    check "X11-7: doc $(basename "$bad") leaves the later rm-queue rule running" "0 $QUEUE" "$(DOC="$bad" wr "$name" "$TICK_RQ")"
done

TICK_QM='TICK workers=0 rm-queue=1,31m mon-down=1234'
check 'X10-11 control: unset takes the default and the queue is aged' "0 $QUEUE" "$(wr u1 "$TICK_QM")"
check 'X10-11 control: unset leaves the monitor rule running' "0 $MON" "$(wr u1 "$TICK_QM")"
n=0
for bad in '' abc 1.5 -5 ' 12' '1e3'; do
    n=$((n + 1))
    check "X10-11: interval '$bad' takes the default: queue wakes" "0 $QUEUE" "$(wr "i$n" "$TICK_QM" "TICK_RMRUN_MIN_SECS=$bad")"
    check "X10-11: interval '$bad' leaves the monitor rule running" "0 $MON" "$(wr "i$n" "$TICK_QM" "TICK_RMRUN_MIN_SECS=$bad")"
done
check 'X10-11 control: a numeric interval is honoured (1000 makes a 31 minute queue young, the monitor wakes)' "0 $MON" "$(wr n1 "$TICK_QM" TICK_RMRUN_MIN_SECS=1000)"
check 'X10-11 control: a leading zero is decimal like the tick (0800 makes the queue aged)' "0 $QUEUE" "$(wr n2 "$TICK_QM" TICK_RMRUN_MIN_SECS=0800)"

TICK_RM="TICK workers=0 repair=off:unread mon-down=1234"
check 'crash: the monitor rule after a crashed repair rule still wakes' "0 $MON" "$(wr k1 "$TICK_RM" CHIEF_WAIT_REPAIR_REWAKE_MIN=abc)"
check 'crash: a crashed rule is a distinct waiter-error wake naming the rule and the error' '0 WAKE waiter-error wake-rules rule=repair error=ValueError' "$(wr k1 "$TICK_RM" CHIEF_WAIT_REPAIR_REWAKE_MIN=abc)"
check 'crash: the same crash does not wake again' '1 ' "$(wr k1 "$TICK_RM" CHIEF_WAIT_REPAIR_REWAKE_MIN=abc)"
check 'crash: once the setting is repaired the repair wake is back' '0 WAKE repair off:unread remedy=run X' "$(wr k1 "$TICK_RM")"
check 'crash: a crash returning right after the repair wake wakes again' '0 WAKE waiter-error wake-rules rule=repair error=ValueError' "$(wr k1 "$TICK_RM" CHIEF_WAIT_REPAIR_REWAKE_MIN=abc)"

check 'X11-23: the table names rm-blocked as a whole-retain-unknown change key row' \
    "rm-blocked	whole-retain-unknown	change	0	key	absent" "$(awk -F'\t' '$1 == "rm-blocked"' "$TABLE")"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-chief-wait-rules.sh'
    exit 0
fi
printf 'FAIL - test-chief-wait-rules.sh (%s failure(s))\n' "$fails"
exit 1
