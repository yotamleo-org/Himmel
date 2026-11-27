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

dep_two='TICK workers=0 dependabot=2:12m:6m:#3101,#3102'
check 'W1: a settled set wakes with its PRs and oldest age' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d1 "$dep_two")"
check 'W2: the same set does not wake again' '1 ' "$(wr d1 "$dep_two")"
check 'W3: a smaller set does not wake' '1 ' "$(wr d1 'TICK dependabot=1:12m:12m:#3102')"
check 'W3: a PR that left and came back, with a new one, wakes with all' '0 WAKE dependabot #3101,#3102,#3103 oldest=20m' "$(wr d1 'TICK dependabot=3:20m:6m:#3101,#3102,#3103')"
check 'W4: a fresh inbox holds while the newest PR is young' '1 ' "$(wr d4 'TICK dependabot=3:12m:2m:#3201,#3202,#3203')"
check 'W4: the same set wakes once it has settled' '0 WAKE dependabot #3201,#3202,#3203 oldest=12m' "$(wr d4 'TICK dependabot=3:12m:6m:#3201,#3202,#3203')"
dep_marker="$W/d5.wait.rule-dependabot"
check 'W5 control: the set wakes' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d5 "$dep_two")"
dep_state() { printf '%s %s' "$(stat -c %Y "$1")" "$(cat "$1")"; }  # gnu-ok: Linux-only kit; read-sink-ok: the suite's own marker under its temp dir
touch -d '1 hour ago' "$dep_marker"
dep_before="$(dep_state "$dep_marker")"
for dep_bad in '?' skip garbled '2:12m:#3101'; do
    check "W5: dependabot=$dep_bad does not wake" '1 ' "$(wr d5 "TICK dependabot=$dep_bad")"
    check "W5: dependabot=$dep_bad leaves the marker" "$dep_before" "$(dep_state "$dep_marker")"
done
check 'W5: an absent field does not wake' '1 ' "$(wr d5 'TICK workers=0')"
check 'W5: an absent field clears the marker' gone "$([ -e "$dep_marker" ] && echo there || echo gone)"
check 'W5: the next settled sight wakes' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d5 "$dep_two")"
check 'W6 control: the set wakes' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d6 "$dep_two" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=1)"
touch -d '2 minutes ago' "$W/d6.wait.rule-dependabot"
check 'W6: past the reminder the same set wakes again' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d6 "$dep_two" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=1)"
touch -d '2 minutes ago' "$W/d6.wait.rule-dependabot"
dep_one='TICK dependabot=1:12m:12m:#3102'
check 'W7: past the reminder a smaller set wakes' '0 WAKE dependabot #3102 oldest=12m' "$(wr d6 "$dep_one" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=1)"
check 'W7: and only once' '1 ' "$(wr d6 "$dep_one" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=1)"
dep_marker="$W/d8.wait.rule-dependabot"
check 'W8 control: the set wakes' '0 WAKE dependabot #3101,#3102 oldest=12m' "$(wr d8 "$dep_two" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=3)"
touch -d '2 minutes ago' "$dep_marker"
dep_mtime="$(stat -c %Y "$dep_marker")"  # gnu-ok: Linux-only kit
check 'W8: a smaller set inside the reminder does not wake' '1 ' "$(wr d8 "$dep_one" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=3)"
check 'W8: the shrink keeps the reminder clock and records the smaller set' "$dep_mtime #3102" "$(dep_state "$dep_marker")"
touch -d '4 minutes ago' "$dep_marker"
check 'W8: past the reminder the smaller set wakes' '0 WAKE dependabot #3102 oldest=12m' "$(wr d8 "$dep_one" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=3)"
check 'W8: and only once' '1 ' "$(wr d8 "$dep_one" CHIEF_WAIT_DEPENDABOT_REWAKE_MIN=3)"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-chief-wait-rules.sh'
    exit 0
fi
printf 'FAIL - test-chief-wait-rules.sh (%s failure(s))\n' "$fails"
exit 1
