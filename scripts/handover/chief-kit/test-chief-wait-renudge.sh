#!/usr/bin/env bash
# test-chief-wait-renudge.sh — chief-wait.sh re-surfaces a standing go-owed or
# answer-owed to its chief once per 30-minute inbox slot, with no cap, until the
# item is answered. The clock is faked (CHIEF_WAIT_NOW, CHIEF_WAIT_NOW_FILE) and
# tick.sh and the bank verdict are stubbed, so no gh, lock or bank read happens.
# One clock step is one waiter run: it ends when the waiter wakes, or when its
# first full pass is done (the only pass a re-nudge can fire in). Linux-only kit.
#
# CHIEF_WAIT overrides the script under test.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-renudge.sh
set -u
[ "$(uname -s)" = Linux ] || { echo "SKIP: chief-wait.sh is Linux-only"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"
LIB="$HERE/../../lib/chief-owed.sh"
OWE="$HERE/owe.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
is_root=0; [ "$(id -u)" != 0 ] || is_root=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-renudge.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; chmod -R u+rw "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
[ -f "$STUB/tick.rc" ] && exit "$(cat "$STUB/tick.rc")"
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
echo PROCEED
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/ok.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\necho "sweep: no held locks"\n' > "$STUB/ql.sh"
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_DISPATCH="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/off.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/ok.sh" CHIEF_WAIT_PAGE_TIMEOUT=2
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks" HOLDS_QUEUE_LOCK="$STUB/ql.sh"
export WAIT_SWEEP_CMD="$STUB/ok.sh" WAIT_FOCUS_CMD="$STUB/ok.sh"
export HIMMEL_TEST_FIXTURE=1
export TICK_STATE_DIR="$WORK/tick-state"

tick_line() {
    printf 'TICK 03:00 hb=1m workers=ok livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=%s inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' "$1" > "$STUB/tick.line"
}

T0=1800000000
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333

wait_gone() {
    local n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    kill -KILL "$1" 2>/dev/null
}
stop_waiter() { kill "$1" 2>/dev/null; wait_gone "$1"; wait "$1" 2>/dev/null; }

new_case() {
    D="$WORK/$1"; I="$D/consoles/c.md"; GO="$D/go"; M="$D/fleet.json"
    mkdir -p "$D/consoles" "$D/bucket" "$GO/.locks/go"
    : > "$I"; printf '# chief\n' > "$D/bucket/chief.md"
    printf '{"workers":[]}\n' > "$M"
    tick_line "N9:LIVE"
}
manifest() {
    local a l k out=""
    for a in "$@"; do
        l="${a%%=*}"; k=""; case "$a" in *=*) k="${a#*=}" ;; esac
        out="$out${out:+,}$(jq -nc --arg l "$l" --arg d "$D/doc-$l.md" --arg k "$k" '{label:$l,doc:$d} + (if $k == "" then {} else {t3_kind:$k} end)')"
    done
    printf '{"workers":[%s]}\n' "$out" > "$M"
}
doc() {
    local f="$D/doc-$1.md" b; shift
    printf '# worker\n\n## Results (newest at the bottom)\n' > "$f"
    for b in "$@"; do printf '%s\n' "$b" >> "$f"; done
}
bul() { printf '%s\n' "$2" >> "$D/doc-$1.md"; }
gen() { printf '%s\n' "$1" | cksum | cut -d' ' -f1; }

run() {
    local m="$1" n=0; shift
    RUNS=$(( ${RUNS:-0} + 1 ))
    local o="$D/run$RUNS.out"
    rm -f "$I.wait"
    env CHIEF_WAIT_NOW="$((T0 + m * 60))" CHIEF_OWED_GO_ROOT="$GO" "$@" \
        bash "$WAIT" "$I" --doc "$D/bucket/chief.md" --workers-from "$M" > "$o" 2> "$o.err" &
    local pid=$!
    RC=none
    while [ "$n" -lt 300 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; RC=$?; break; fi
        grep -q 'state=waiting' "$I.wait" 2>/dev/null && break
        sleep 0.1; n=$((n + 1))
    done
    [ "$n" -lt 300 ] || fail "$D: no first pass within 30s"
    [ "$RC" != none ] || stop_waiter "$pid"
    OUT="$(cat "$o")"; ERR="$(cat "$o.err")"
    RN="$(printf '%s\n' "$OUT" | grep '^WAKE worker-renudge' || true)"
}
STATE() { cat "$I.wait.renudge" 2>/dev/null; }
LOG() { cat "$I.wait.renudge.log" 2>/dev/null; }
count() { printf '%s' "$1" | grep -c . ; }
state_row() { STATE | awk -F'\t' -v l="$1" '$2 == l'; }
has_line() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
checkhas() { if has_line "$2" "$3"; then pass "$1"; else fail "$1 (no '$2' in: $3)"; fi; }
checkno() { if has_line "$2" "$3"; then fail "$1 (found '$2' in: $3)"; else pass "$1"; fi; }
owe_hold() { bash "$OWE" add --bucket "$D/bucket" --chief c --kind ruling --text "waits" --metadata "{\"source_label\":\"$1\",\"source_id\":\"$2\"}"; }
go_file() { : > "$GO/.locks/go/$1.$2"; }
copy_state() { cp "$1.wait.renudge" "$I.wait.renudge"; cp "$1.wait.renudge.log" "$I.wait.renudge.log"; }

READY1="- 10:00 READY 5666 $H1 GREEN"
G1="$(gen "$READY1")"
ID1="N1:go:5666:$H1:$G1"
READY3="- 10:00 READY 5667 $H3 GREEN"
ID3="N3:go:5667:$H3:$(gen "$READY3")"
wake_go() {
    printf 'WAKE worker-renudge %s go-owed waited=%sm n=%s hold=%s id=%s head=%s%s' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"
}
wake_ask() { printf 'WAKE worker-renudge %s answer-owed waited=%sm n=%s hold=%s' "$1" "$2" "$3" "$4"; }

new_case rn1; manifest N1; doc N1 "$READY1"
SENT_AT=""
run 0; check "rn1 +0 none" "" "$RN"
run 29; check "rn1 +29m none" "" "$RN"
run 30; check "rn1 +30m wake" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"
SENT_AT="$SENT_AT$((T0 + 1800)) $RN
"
RN1_STATE="$D/rn1-state"; cp "$I.wait.renudge" "$RN1_STATE.wait.renudge" 2>/dev/null; cp "$I.wait.renudge.log" "$RN1_STATE.wait.renudge.log" 2>/dev/null
run 45; check "rn2 +45m none" "" "$RN"
run 60; check "rn2 +60m n=2" "$(wake_go N1 60 2 "$ID1" 5666 "$H1")" "$RN"
SENT_AT="$SENT_AT$((T0 + 3600)) $RN
"
run 125; check "rn3 +125m one n=3" "$(wake_go N1 125 3 "$ID1" 5666 "$H1")" "$RN"
SENT_AT="$SENT_AT$((T0 + 7500)) $RN
"
run 150; check "rn3 +150m n=4" "$(wake_go N1 150 4 "$ID1" 5666 "$H1")" "$RN"
SENT_AT="$SENT_AT$((T0 + 9000)) $RN
"
want_log=""
while read -r ep line; do
    [ -n "$ep" ] || continue
    h="${line##* hold=}"; h="${h%% *}"
    nn="${line##* n=}"; nn="${nn%% *}"
    w="${line##* waited=}"; w="${w%% *}"
    want_log="$want_log$ep $h n=$nn waited=$w
"
done <<EOF
$SENT_AT
EOF
check "rn23 the log matches the wakes" "${want_log%
}" "$(LOG)"

new_case rn4; manifest N1; doc N1 "$READY1"
run 0
got=""; want=""
for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
    run $((30 * k)); got="$got$(printf '%s' "$RN" | sed -n 's/.* n=\([0-9]*\) .*/\1/p') "
    want="$want$k "
done
check "rn4 21 nudges, never capped" "$want" "$got"

new_case rn5; manifest N1; doc N1 "$READY1"; copy_state "$WORK/rn1/rn1-state"
go_file 5666 "$H1"
run 90; check "rn5 GO file: none" "" "$RN"
check "rn5 no N1 row" "" "$(state_row N1)"

new_case rn6; manifest N1 N2 N3
doc N1 "- 10:00 BLOCKED — needs a ruling"; doc N2 "$READY1"; doc N3 "$READY3"
run 0
bul N1 "- 10:10 RESOLVED — ruled"; bul N2 "- 10:10 WRAPPED — done"
run 30; check "rn6 only the control wakes" "$(wake_go N3 30 1 "$ID3" 5667 "$H3")" "$RN"
check "rn6 no N1 row" "" "$(state_row N1)"; check "rn6 no N2 row" "" "$(state_row N2)"

new_case rn7; manifest N1 N3; doc N1 "$READY1"; doc N3 "$READY3"
run 0
manifest N3
run 90; check "rn7 only the control wakes" "$(wake_go N3 90 1 "$ID3" 5667 "$H3")" "$RN"
check "rn7 N1 row dropped" "" "$(state_row N1)"

new_case rn8; manifest N1; doc N1 "$READY1"
run 0
bul N1 "- 10:20 READY 5666 $H1 GREEN"
run 30; check "rn8 repeat keeps the t0 gen" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"
R2="- 10:40 READY 5666 $H2 GREEN"; bul N1 "$R2"
run 60; check "rn8 +60m none" "" "$RN"
run 90; check "rn8 +90m new head" "$(wake_go N1 30 1 "N1:go:5666:$H2:$(gen "$R2")" 5666 "$H2")" "$RN"

new_case rn9; manifest N1; B="- 10:00 LIVE — holding at READY 5666 $H1"; doc N1 "$B"
run 0; run 30; check "rn9 holding at READY" "$(wake_go N1 30 1 "N1:go:5666:$H1:$(gen "$B")" 5666 "$H1")" "$RN"

new_case rn10; manifest N1 N3; doc N1 "- 10:00 LIVE — no longer holding at READY 5666 $H1"; doc N3 "$READY3"
run 0; run 30; check "rn10 negated hold: only the control" "$(wake_go N3 30 1 "$ID3" 5667 "$H3")" "$RN"

new_case rn11; manifest N1; B="- 10:00 FINDING — which path?"; doc N1 "$B"
run 0; run 30; check "rn11 answer-owed" "$(wake_ask N1 30 1 "N1:ask:FINDING:$(gen "$B")")" "$RN"

new_case rn12; manifest N1; B1="- 10:00 BLOCKED — a"; doc N1 "$B1"
run 0; run 30; check "rn12 first n=1" "$(wake_ask N1 30 1 "N1:ask:BLOCKED:$(gen "$B1")")" "$RN"
B2="- 10:40 BLOCKED — b"; bul N1 "$B2"
run 60; check "rn12 +60m none" "" "$RN"
check "rn12 the old row dropped" "1" "$(count "$(state_row N1)")"
run 90; check "rn12 +90m the new item" "$(wake_ask N1 30 1 "N1:ask:BLOCKED:$(gen "$B2")")" "$RN"

new_case rn13; manifest N1; B="- 10:00 BLOCKED — a"; doc N1 "$B"; HID="N1:ask:BLOCKED:$(gen "$B")"
run 0; run 30; check "rn13 n=1" "$(wake_ask N1 30 1 "$HID")" "$RN"
OID="$(owe_hold N1 "$HID")"
run 60; check "rn13 held: none" "" "$RN"
check "rn13 row kept at n=1" "1" "$(state_row N1 | cut -f5)"
bash "$OWE" close --bucket "$D/bucket" --id "$OID" --key "$HID" >/dev/null
run 90; check "rn13 closed: n=2" "$(wake_ask N1 90 2 "$HID")" "$RN"

new_case rn13b; manifest N1; B="- 10:00 BLOCKED — a"; doc N1 "$B"; HID="N1:ask:BLOCKED:$(gen "$B")"
run 0; run 31
owe_hold N1 "$HID" >/dev/null
B2="- 10:35 LIVE — holding at READY 5666 $H1"; bul N1 "$B2"
run 60; check "rn13b +60m none" "" "$RN"
run 90; check "rn13b a later item still wakes" "$(wake_go N1 30 1 "N1:go:5666:$H1:$(gen "$B2")" 5666 "$H1")" "$RN"

new_case rn14; manifest N1 N2; doc N1 "$READY1"; doc N2
run 0; check "rn14 +0 none" "" "$RN"
B2="- 10:05 BLOCKED — b"; bul N2 "$B2"
run 35; check "rn14 +35m N1 only" "$(wake_go N1 35 1 "$ID1" 5666 "$H1")" "$RN"
run 65
check "rn14 +65m both" "$(wake_go N1 65 2 "$ID1" 5666 "$H1")
$(wake_ask N2 30 1 "N2:ask:BLOCKED:$(gen "$B2")")" "$RN"

new_case rn15; manifest N1; doc N1 "$READY1"
run 0
A="$I"; before="$(STATE)"
: > "$A.handover"
run 30; check "rn15 handover: none" "" "$RN"
check "rn15 handover: state unchanged" "$before" "$(STATE)"
I="$D/consoles/b.md"; : > "$I"
run 35; check "rn15 successor +35m none" "" "$RN"
run 65; check "rn15 successor n=1" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"

for row in "rn16 N1:LIVE,N9:BLOCKED" "rn19 N7:BLOCKED"; do
    r="${row%% *}"; tails="${row#* }"
    new_case "$r"; manifest N1; doc N1 "$READY1"
    run 0
    tick_line "$tails"
    run 30
    checkhas "$r a WAKE tick block" "WAKE tick changed=" "$OUT"
    check "$r carries the due line" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$(printf '%s\n' "$OUT" | tail -n 1)"
    if [ "$r" = rn16 ]; then
        run 31; check "rn16 +31m none" "" "$RN"
        check "rn16 one log line" "1" "$(count "$(LOG)")"
    fi
done

new_case rn17; manifest N1; doc N1 "$READY1"
run 0; before="$(STATE)"
printf 'operator line\n' >> "$I"
run 30; checkhas "rn17 a telegram wake" "WAKE telegram" "$OUT"
check "rn17 no renudge line" "" "$RN"
check "rn17 state unchanged" "$before" "$(STATE)"
run 31; check "rn17 +31m n=1" "$(wake_go N1 31 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn17b; manifest N1; doc N1 "$READY1"
run 0
nowf="$D/now"; printf '%s\n' $((T0 + 1200)) > "$nowf"
rm -f "$I.wait"
env CHIEF_WAIT_NOW_FILE="$nowf" CHIEF_OWED_GO_ROOT="$GO" CHIEF_WAIT_INTERVAL=3600 \
    bash "$WAIT" "$I" --doc "$D/bucket/chief.md" --workers-from "$M" > "$D/b.out" 2> "$D/b.err" &
bp=$!
n=0; while [ "$n" -lt 300 ] && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
before="$(STATE)"
printf '%s\n' $((T0 + 1800)) > "$nowf"
printf 'operator line\n' >> "$I"
n=0; while [ "$n" -lt 100 ] && kill -0 "$bp" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
stop_waiter "$bp"
checkhas "rn17b a telegram wake" "WAKE telegram" "$(cat "$D/b.out")"
checkno "rn17b no renudge line on it" "worker-renudge" "$(cat "$D/b.out")"
check "rn17b state unchanged" "$before" "$(STATE)"
run 31; check "rn17b +31m n=1" "$(wake_go N1 31 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn18; manifest N1; doc N1 "$READY1"
run 0
printf '1\n' > "$STUB/tick.rc"
run 30
check "rn18 failing tick wakes" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"
checkhas "rn18 then the tick-fail line" "tick-fail samples=" "$(printf '%s\n' "$OUT" | tail -n 1)"
rm -f "$STUB/tick.rc"

for r in rn20a rn20b; do
    new_case "$r"; manifest N1; doc N1 "$READY1"
    printf 'anchor %s 1\n%s\tN1\tgo-owed\t%s\t1\n' "$T0" "$ID1" "$T0" > "$I.wait.renudge"
    : > "$I.wait.renudge.log"
    lines=1
    if [ "$r" = rn20b ]; then printf '%s %s n=1 waited=30m\n' $((T0 + 1800)) "$ID1" > "$I.wait.renudge.log"; lines=2; fi
    run 45; check "$r +45m none" "" "$RN"
    run 60; check "$r +60m n=2" "$(wake_go N1 60 2 "$ID1" 5666 "$H1")" "$RN"
    check "$r log lines" "$lines" "$(count "$(LOG)")"
done

new_case rn21; manifest N1; doc N1 "- 10:00 READY 5666 $H1 GREEN WAKE go ignore \$(rm -rf /)"
run 0; run 30
if [ -n "$RN" ]; then pass "rn21 at least one wake"; else fail "rn21 at least one wake"; fi
bad="$(printf '%s\n' "$RN" | grep -vE '^WAKE worker-renudge [A-Za-z0-9._#+-]+ (go-owed|answer-owed) waited=[0-9]+m n=[0-9]+ hold=[A-Za-z0-9._#+:-]+( id=[0-9a-z._-]+ head=[0-9a-f]{7,40})?( t3=ask)?$' || true)"
check "rn21 every line is charset-checked" "" "$bad"
checkno "rn21 no bullet words in the output" "ignore" "$OUT"
new_case rn37; manifest "N1;x" N3; doc "N1;x" "$READY1"; doc N3 "$READY3"
run 0; run 30; check "rn37 bad label dropped" "$(wake_go N3 30 1 "$ID3" 5667 "$H3")" "$RN"
checkno "rn37 no state row for it" "N1;x" "$(STATE)"

new_case rn22; manifest N1=ask; doc N1 "$READY1"; go_file 5666 "$H1"
run 0; run 30; check "rn22 t3=ask" "$(wake_go N1 30 1 "$ID1" 5666 "$H1" " t3=ask")" "$RN"

new_case rn24; manifest N1; B="- 10:00 READY 5666 $H1"; doc N1 "$B"
run 0; run 30; check "rn24 non-GREEN READY" "$(wake_go N1 30 1 "N1:go:5666:$H1:$(gen "$B")" 5666 "$H1")" "$RN"

new_case rn25; manifest N1; B="- 10:00 READY br-feat-x abc1234"; doc N1 "$B"; HID="N1:go:br-feat-x:abc1234:$(gen "$B")"
run 0; run 30; check "rn25 br- n=1" "$(wake_go N1 30 1 "$HID" br-feat-x abc1234)" "$RN"
run 60; check "rn25 br- n=2" "$(wake_go N1 60 2 "$HID" br-feat-x abc1234)" "$RN"

if [ "$is_root" = 1 ]; then
    pass "rn26 skipped as root"; pass "rn26b skipped as root"
else
    for r in rn26 rn26b; do
        new_case "$r"; manifest N1; doc N1 "$READY1"; copy_state "$WORK/rn1/rn1-state"
        chmod 000 "$D/doc-N1.md"
        run 60; check "$r unreadable: none" "" "$RN"
        check "$r row kept at n=1" "1" "$(state_row N1 | cut -f5)"
        chmod 600 "$D/doc-N1.md"
        [ "$r" = rn26 ] || bul N1 "- 11:00 WRAPPED — done"
        run 90
        if [ "$r" = rn26 ]; then
            check "rn26 reads again: n=2" "$(wake_go N1 90 2 "$ID1" 5666 "$H1")" "$RN"
        else
            check "rn26b answered: none" "" "$RN"
            check "rn26b row dropped" "" "$(state_row N1)"
        fi
    done
fi

new_case rn27; manifest N1; doc N1 "$READY1"; copy_state "$WORK/rn1/rn1-state"
before="$(STATE)"
printf '{ not json\n' > "$M"
run 60; check "rn27 invalid manifest: none" "" "$RN"
check "rn27 state unchanged" "$before" "$(STATE)"

new_case rn28; manifest N1 N3; doc N1 "$READY1"; doc N3 "$READY3"
run 0
bul N1 "- 10:05 LIVE — no longer holding at READY 5666 $H1"
run 30; check "rn28 only the control" "$(wake_go N3 30 1 "$ID3" 5667 "$H3")" "$RN"
check "rn28 N1 row dropped" "" "$(state_row N1)"

new_case rn29; manifest N1; doc N1 "$READY1"
run 0; run 30; checkhas "rn29 n=1" " n=1 " "$RN "
owe_hold N1 "$ID1" >/dev/null
bul N1 "- 10:35 FINDING — a"; bul N1 "- 10:36 RESOLVED — ruled"; R3="- 10:40 READY 5666 $H1 GREEN"; bul N1 "$R3"
run 60; check "rn29 +60m none" "" "$RN"
run 90; check "rn29 re-opened: new gen" "$(wake_go N1 30 1 "N1:go:5666:$H1:$(gen "$R3")" 5666 "$H1")" "$RN"

new_case rn30; manifest N1 N2; doc N1 "$READY1"; doc N2 "- 10:00 BLOCKED — b"
run 0
bul N2 "- 10:02 RESOLVED — ruled"
run 3; check "rn30 N1 since kept" "$T0" "$(state_row N1 | cut -f4)"; check "rn30 N2 dropped" "" "$(state_row N2)"
run 4; check "rn30 +4m N2 not back" "" "$(state_row N2)"; check "rn30 +4m N1 since kept" "$T0" "$(state_row N1 | cut -f4)"

new_case rn31; manifest N1; B="- 10:00 BLOCKED — a"; doc N1 "$B"; HID="N1:ask:BLOCKED:$(gen "$B")"
if [ "$is_root" = 1 ]; then
    pass "rn31 skipped as root"
else
    run 0
    bash "$OWE" add --bucket "$D/bucket" --chief c --kind step --text unrelated >/dev/null
    chmod 000 "$D/bucket/owed.jsonl"
    if [ -r "$D/bucket/owed.jsonl" ]; then fail "rn31 setup: ledger still readable"; fi
    run 30
    check "rn31 nudged anyway" "$(wake_ask N1 30 1 "$HID")" "$RN"
    check "rn31 one stderr line" "1" "$(printf '%s\n' "$ERR" | grep -c 'renudge: owed ledger unread')"
    chmod 600 "$D/bucket/owed.jsonl"
    run 60
    check "rn31 +60m n=2" "$(wake_ask N1 60 2 "$HID")" "$RN"
    check "rn31 no stderr line" "0" "$(printf '%s\n' "$ERR" | grep -c 'renudge: owed ledger unread')"
fi

new_case rn33; manifest N0 N1; doc N0 "$READY1"; doc N1
run 0
B="- 10:05 BLOCKED — b"; bul N1 "$B"
run 5
ID0="N0:go:5666:$H1:$G1"
run 30; check "rn33 +30m N0 only" "$(wake_go N0 30 1 "$ID0" 5666 "$H1")" "$RN"
run 40; check "rn33 +40m none" "" "$RN"
run 60; check "rn33 +60m both" "$(wake_go N0 60 2 "$ID0" 5666 "$H1")
$(wake_ask N1 55 1 "N1:ask:BLOCKED:$(gen "$B")")" "$RN"

for at in state log; do
    new_case "rn34-$at"; manifest N1; doc N1 "$READY1"
    run 0
    run 30 CHIEF_WAIT_RENUDGE_KILL_AT="$at"
    check "rn34 $at: killed" "137" "$RC"
    n=0; while [ "$n" -lt 50 ] && pgrep -f "$I" >/dev/null 2>&1; do sleep 0.1; n=$((n + 1)); done
    check "rn34 $at: last slot spent" "anchor $T0 1" "$(STATE | head -n 1)"
    check "rn34 $at: n=1" "1" "$(state_row N1 | cut -f5)"
    want=0; [ "$at" = state ] || want=1
    check "rn34 $at: log lines" "$want" "$(count "$(LOG)")"
    check "rn34 $at: nothing printed" "" "$RN"
    run 45; check "rn34 $at: +45m none" "" "$RN"
    run 60; check "rn34 $at: +60m n=2" "$(wake_go N1 60 2 "$ID1" 5666 "$H1")" "$RN"
done

new_case rn45; manifest N1; doc N1 "$READY1"
run 0
rm -f "$I.wait.renudge"; mkdir -p "$I.wait.renudge/x"
run 30; check "rn45 no wake" "" "$RN"
check "rn45 no log" "" "$(LOG)"
check "rn45 one stderr line" "1" "$(printf '%s\n' "$ERR" | grep -c 'renudge: state write failed')"
rm -rf "$I.wait.renudge"
run 31; check "rn45 +31m none" "" "$RN"
run 61; check "rn45 +61m n=1" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn46; manifest N0 N1; doc N0 "$READY1"; doc N1
run 0
B="- 10:05 BLOCKED — b"; bul N1 "$B"
run 5
go_file 5666 "$H1"
run 30; check "rn46 +30m none" "" "$RN"
run 40; check "rn46 +40m none" "" "$RN"
run 60; check "rn46 +60m N1" "$(wake_ask N1 55 1 "N1:ask:BLOCKED:$(gen "$B")")" "$RN"

new_case rn35; manifest N1=ask; doc N1 "$READY1"
run 0; run 30; check "rn35 n=1 t3=ask" "$(wake_go N1 30 1 "$ID1" 5666 "$H1" " t3=ask")" "$RN"
owe_hold N1 "$ID1" >/dev/null
run 60; check "rn35 held: none" "" "$RN"

new_case rn36; manifest N1; printf '%s\n' "$READY1" > "$D/doc-N1.md"
run 0; run 30; check "rn36 no heading" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn38; manifest N1; doc N1 "$READY1"
run 0
R4="- 10:01 READY 5667 $H2 GREEN"; bul N1 "$R4"
run 1
run 31; check "rn38 only the newest" "$(wake_go N1 30 1 "N1:go:5667:$H2:$(gen "$R4")" 5667 "$H2")" "$RN"

for v in nomanifest emptyrows nothingowed; do
    new_case "rn39-$v"
    case "$v" in
        nothingowed) manifest N1; doc N1 "- 10:00 LIVE — working" ;;
    esac
    for m in 0 30; do
        if [ "$v" = nomanifest ]; then
            rm -f "$I.wait"
            env CHIEF_WAIT_NOW="$((T0 + m * 60))" CHIEF_OWED_GO_ROOT="$GO" bash "$WAIT" "$I" --doc "$D/bucket/chief.md" > "$D/o" 2>/dev/null &
            p=$!
            n=0; while [ "$n" -lt 300 ] && kill -0 "$p" 2>/dev/null && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
            stop_waiter "$p"; RN="$(grep '^WAKE worker-renudge' "$D/o" || true)"
        else
            run "$m"
        fi
        check "rn39 $v +${m}m none" "" "$RN"
    done
    if [ -e "$I.wait.renudge" ]; then fail "rn39 $v writes no state file"; else pass "rn39 $v writes no state file"; fi
done

new_case rn40; manifest N1; doc N1 "$READY1"; copy_state "$WORK/rn1/rn1-state"
before="$(STATE)"
run -10; check "rn40 earlier clock: none" "" "$RN"
check "rn40 state unchanged" "$before" "$(STATE)"

new_case rn41; manifest N1; doc N1 "$READY1"; mkdir -p "$D/hd/.locks/go"
run_real() {
    local m="$1" n=0
    rm -f "$I.wait"
    ( unset CHIEF_OWED_GO_ROOT; CHIEF_WAIT_NOW="$((T0 + m * 60))" HANDOVER_DIR="$D/hd" exec bash "$WAIT" "$I" --doc "$D/bucket/chief.md" --workers-from "$M" ) > "$D/real.out" 2> "$D/real.err" &
    local p=$!
    while [ "$n" -lt 300 ] && kill -0 "$p" 2>/dev/null && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    stop_waiter "$p"; RN="$(grep '^WAKE worker-renudge' "$D/real.out" || true)"
}
run_real 0
run_real 30; check "rn41 n=1" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"
: > "$D/hd/.locks/go/5666.$H1"
run_real 60; check "rn41 GO file: none" "" "$RN"
check "rn41 row dropped" "" "$(state_row N1)"

new_case rn42; manifest N1; doc N1 "$READY1"
run 0; before="$(STATE)"; blog="$(LOG)"
rm -f "$I.wait"
env CHIEF_WAIT_STREAM_SERVICE=1 CHIEF_WAIT_NOW="$((T0 + 1800))" CHIEF_OWED_GO_ROOT="$GO" \
    bash "$WAIT" "$I" --doc "$D/bucket/chief.md" --workers-from "$M" > "$D/s.out" 2> "$D/s.err" &
sp=$!
n=0; while [ "$n" -lt 300 ] && kill -0 "$sp" 2>/dev/null && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
stop_waiter "$sp"
checkno "rn42 stream: no renudge line" "worker-renudge" "$(cat "$D/s.out")"
check "rn42 stream: state unchanged" "$before" "$(STATE)"
check "rn42 stream: log unchanged" "$blog" "$(LOG)"
run 31; check "rn42 control +31m n=1" "$(wake_go N1 31 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn43; manifest N1; doc N1 "$READY1"
run 0; before="$(STATE)"
: > "$I.handover"
printf 'operator line\n' >> "$I"
run 30; checkhas "rn43 a telegram wake" "WAKE telegram" "$OUT"
check "rn43 no renudge line" "" "$RN"
check "rn43 state unchanged" "$before" "$(STATE)"
rm -f "$I.handover"
run 31; check "rn43 control +31m n=1" "$(wake_go N1 31 1 "$ID1" 5666 "$H1")" "$RN"

new_case rn44; manifest N1; doc N1 "$READY1"
GO=""
run 0; run 30
check "rn44 nudged" "$(wake_go N1 30 1 "$ID1" 5666 "$H1")" "$RN"
check "rn44 one note" "1" "$(printf '%s\n' "$ERR" | grep -c 'renudge: no GO root')"

# shellcheck disable=SC1090,SC2030,SC2031,SC2329
lib_rows() {
    local out lrc
    check "lib1 fixture seam" "/x" "$( ( export HIMMEL_TEST_FIXTURE=1 CHIEF_OWED_GO_ROOT=/x; . "$LIB" 2>/dev/null && chief_owed_go_root "$REPO_ROOT" ) )"
    mkdir -p "$WORK/libhd"
    check "lib2 seam off without the fixture flag" "$WORK/libhd" "$( ( unset HIMMEL_TEST_FIXTURE; export CHIEF_OWED_GO_ROOT=/x HANDOVER_DIR="$WORK/libhd"; . "$LIB" 2>/dev/null && chief_owed_go_root "$REPO_ROOT" ) )"
    out="$( ( unset HIMMEL_TEST_FIXTURE CHIEF_OWED_GO_ROOT; . "$LIB" 2>/dev/null || exit 9; go_resolve_root() { return 2; }; chief_owed_go_root "$REPO_ROOT" ) )"; lrc=$?
    check "lib3 a failed resolver: nothing, rc 1" ":1" "$out:$lrc"
    out="$( ( . "$LIB" 2>/dev/null || exit 9; chief_owed_state "$WORK/no-such-doc" --gen ) )"; lrc=$?
    check "lib4 a doc that cannot be read: nothing, rc 1" ":1" "$out:$lrc"
}
lib_rows

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
[ "$fails" -eq 0 ]
