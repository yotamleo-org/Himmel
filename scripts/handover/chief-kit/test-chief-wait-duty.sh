#!/usr/bin/env bash
# test-chief-wait-duty.sh — the waiter runs chief-duty-sweep.sh on each successful
# sample, carries its list on every wake and wakes once when a new duty stays listed.
#
# Linux-only kit (touch -d, /proc).
#
# CHIEF_WAIT overrides the script under test; DUTY_ROWS="D1 D9" runs only those rows.
# Run: bash scripts/handover/chief-kit/test-chief-wait-duty.sh
# shellcheck disable=SC2016  # single-quoted stub bodies expand at run time
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"
SWEEP="$HERE/chief-duty-sweep.sh"
RULES="$HERE/wake-rules.tsv"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 ('$3' in '$2')" ;; *) pass "$1" ;; esac; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
want() { case " ${DUTY_ROWS:-$1} " in *" $1 "*) return 0 ;; esac; return 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-duty-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$WORK/ticks" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$WORK/ticks.tmp" && mv "$WORK/ticks.tmp" "$WORK/ticks"
[ ! -f "$WORK/tickrc" ] || exit "$(cat "$WORK/tickrc")"
cat "$STUB/tick.line"
EOF
cat > "$STUB/sweep.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$WORK/n" 2>/dev/null || echo 0) + 1 ))
[ ! -e /proc/self/fd/9 ] || : > "$WORK/fd9"
printf '%s' "${CHIEF_DUTY_AUTORUN-unset}" > "$WORK/autorun"
tr '\0' ' ' < "/proc/$PPID/cmdline" > "$WORK/argv"
printf '%s\n' "$n" > "$WORK/n.tmp" && mv "$WORK/n.tmp" "$WORK/n"
[ ! -f "$WORK/sleep" ] || sleep "$(cat "$WORK/sleep")"
f="$WORK/lists/$n"
if [ ! -f "$f" ]; then
    last=$(ls "$WORK/lists" 2>/dev/null | sort -n | tail -n 1)
    f="$WORK/lists/$last"
fi
[ ! -f "$f" ] || cat "$f"
exit "$(cat "$WORK/rc" 2>/dev/null || echo 0)"
EOF
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$STUB/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
printf 'TICK 03:00 hb=1m workers=N1:FREE livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip\n' > "$STUB/tick.line"

unset CHIEF_WAIT_DUTY_TIMEOUT CHIEF_WAIT_DUTY_AUTORUN CHIEF_DUTY_AUTORUN CHIEF_WAIT_STREAM_SERVICE WORKERS_FROM HOUSEKEEPING_DIGEST_SECS
export WORK STUB CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh" CHIEF_WAIT_DISPATCH="$STUB/off.sh"
export CHIEF_WAIT_DUTY_CMD="$STUB/sweep.sh"
export CHIEF_WAIT_INTERVAL=2 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

mkdir -p "$WORK/in/consoles"
inbox="$WORK/in/consoles/c.md"
chief="$WORK/chief.md"
manifest="$WORK/fleet.json"
printf '{"legs":[]}\n' > "$manifest"
ARGS=()
R=""

reset() {
    R="$1"
    rm -rf "$WORK/n" "$WORK/ticks" "$WORK/lists" "$WORK/rc" "$WORK/sleep" "$WORK/fd9" "$WORK/autorun" "$WORK/argv" "$WORK/tickrc"
    rm -f "$inbox" "$inbox".*
    : > "$inbox"; : > "$inbox.announced"
    mkdir -p "$WORK/lists"
    printf '# chief\n' > "$chief"
    ARGS=(--doc "$chief" --workers-from "$manifest")
}
lists() { local i=0 l; for l in "$@"; do i=$((i + 1)); if [ -n "$l" ]; then printf '%s\n' "$l" > "$WORK/lists/$i"; else : > "$WORK/lists/$i"; fi; done; }
seed() { local now; now=$(date +%s); printf '%s %s %s %s %s %s\n' "$1" "$2" "$3" "$((now - $4))" "$((now - $5))" "$6" >> "$inbox.wait.duty-state"; }
aged() { seed "$1" "$2" "$3" 2000 1 0; }
count() { cat "$WORK/$1" 2>/dev/null || echo 0; }

start() { bash "$WAIT" "$inbox" ${ARGS[@]+"${ARGS[@]}"} > "$WORK/out" 2> "$WORK/err" & wp=$!; }
finish() {
    local n=0
    while [ "$n" -lt "$1" ] && kill -0 "$wp" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$wp" 2>/dev/null; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; OUT=$(cat "$WORK/out"); return 1; fi
    wait "$wp" 2>/dev/null
    OUT=$(cat "$WORK/out")
}
after() {
    local i=0
    while [ "$i" -lt 200 ]; do
        if [ "$(count "$1")" -ge "$2" ] && ! grep -q 'state=sampling' "$inbox.wait" 2>/dev/null; then
            printf 'telegram line\n' >> "$inbox"; return 0
        fi
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
woke() {
    start
    if ! finish 200; then fail "$R $2: no wake in 20 s"; return 1; fi
    pass "$R $2: a wake was printed"
    check "$R $2: woke on sweep $1" "$1" "$(count n)"
}
after_sweep() {
    start
    if ! after n "$1"; then fail "$R $2: no sweep ran"; finish 1; return 1; fi
    if ! finish 200; then fail "$R $2: no wake after the inbox line"; return 1; fi
    if [ "$(count n)" != "$1" ]; then fail "$R $2: extra sweep (want $1 got $(count n))"; return 1; fi
    pass "$R $2: ran to sweep $1"
}
after_tick() {
    start
    if ! after ticks "$1"; then fail "$R $2: no tick ran"; finish 1; return 1; fi
    if ! finish 200; then fail "$R $2: no wake after the inbox line"; return 1; fi
    pass "$R $2: ran to tick $1"
}
quiet() {
    after_sweep "$1" "$2" || return 1
    contains "$R $2: ends on the inbox wake" "$OUT" 'WAKE telegram'
    lacks "$R $2: no chief-duty wake" "$OUT" 'WAKE chief-duty'
}

B='DUTY go-owed 12@abcdef0 :: READY holds at the PR head with no GO file (lane native) :: next: x'
C='DUTY ci-masked 14@1234567 :: CI run 9 failed at this head after an earlier green run :: next: x'
Q='DUTY? prs unread'
c_why() { printf 'DUTY ci-masked 14@1234567 :: %s :: next: x' "$1"; }
C_ID='ci-masked 14@1234567'
NEW_C='WAKE chief-duty 1 new=ci-masked:14@1234567'
HDR_RE='chief-duty [0-9]+ as of [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'
state() { cat "$inbox.wait.duty-state" 2>/dev/null; }

if want D1; then
    reset D1; lists "$C" "$C"
    woke 2 enter
    contains 'D1 the wake names the new id' "$OUT" "$NEW_C"
    contains 'D1 the tick line follows' "$OUT" 'TICK 03:00'
    contains 'D1 the carry header' "$OUT" 'chief-duty 1 as of'
    contains 'D1 the carry line' "$OUT" "$C"
    if printf '%s\n' "$OUT" | grep -qE "^$HDR_RE:\$"; then pass 'D1 the header carries a UTC time and no stale'; else fail "D1 header shape: $OUT"; fi
    quiet 3 'second run'
fi

if want D2; then
    reset D2; lists "$C"
    if after_sweep 1 carry; then
        contains 'D2 the unrelated wake' "$OUT" 'WAKE telegram'
        contains 'D2 carries the header' "$OUT" 'chief-duty 1 as of'
        contains 'D2 carries the line' "$OUT" "$C"
    fi
    quiet 3 'next run'
fi

if want D3; then
    reset D3; lists "$C
$B" "$C" "$C"
    aged ci-masked 14@1234567 -; aged go-owed 12@abcdef0 -
    woke 1 enter
    contains 'D3 both ids wake, sorted' "$OUT" 'WAKE chief-duty 2 new=ci-masked:14@1234567,go-owed:12@abcdef0'
    quiet 3 'the list only shrank'
fi

if want D4; then
    reset D4; lists "$C" "$C" "$Q" "$C" "$C"
    woke 2 enter
    contains 'D4 the first wake' "$OUT" "$NEW_C"
    quiet 5 'an unread flap'
fi

if want D5; then
    reset D5; lists ""
    if after_sweep 1 clean; then lacks 'D5 a clean list carries nothing' "$OUT" 'chief-duty '; fi
fi
if want D5b; then
    reset D5b; lists "$Q"
    if after_sweep 1 'young source'; then lacks 'D5b a young DUTY? line carries nothing' "$OUT" 'chief-duty '; fi
fi

if want D6; then
    reset D6; lists "$C"; printf '30\n' > "$WORK/sleep"
    export CHIEF_WAIT_DUTY_TIMEOUT=2
    start
    i=0; while [ "$i" -lt 100 ] && [ ! -e "$WORK/n" ]; do sleep 0.1; i=$((i + 1)); done
    if [ -e "$WORK/n" ]; then
        printf 'telegram line\n' >> "$inbox"
        if finish 70; then pass 'D6 the inbox wake prints within the bound'; else fail 'D6 no wake within 7 s of the inbox line'; fi
        contains 'D6 the inbox wake' "$OUT" 'WAKE telegram'
        if [ -e "$inbox.wait.duty" ]; then fail 'D6 a cut-off wrote the list'; else pass 'D6 a cut-off writes no list'; fi
        case "$(cat "$inbox.wait.duty-fail" 2>/dev/null)" in
            "124 "*|"137 "*) pass 'D6 duty-fail names the timeout' ;;
            *) fail "D6 duty-fail: $(cat "$inbox.wait.duty-fail" 2>/dev/null)" ;;
        esac
    else
        fail 'D6 no sweep ran'; finish 1
    fi
    unset CHIEF_WAIT_DUTY_TIMEOUT
fi

failing_row() {
    local now
    now=$(date +%s)
    printf '%s\n' "$C" > "$inbox.wait.duty"
    printf '%s - %s %s 1\n' "$C_ID" "$((now - 100))" "$((now - 1))" > "$inbox.wait.duty-state"
    cp "$inbox.wait.duty" "$WORK/duty.before"; cp "$inbox.wait.duty-state" "$WORK/state.before"
    quiet 1 'failing sweep'
    if cmp -s "$WORK/duty.before" "$inbox.wait.duty"; then pass "$1 the list is byte-identical"; else fail "$1 the list changed: $(cat "$inbox.wait.duty" 2>/dev/null)"; fi
    if cmp -s "$WORK/state.before" "$inbox.wait.duty-state"; then pass "$1 the state is byte-identical"; else fail "$1 the state changed: $(state)"; fi
    # shellcheck disable=SC2254  # $2 is a glob on purpose
    case "$(cat "$inbox.wait.duty-fail" 2>/dev/null)" in
        $2) pass "$1 duty-fail names the rc" ;;
        *) fail "$1 duty-fail: $(cat "$inbox.wait.duty-fail" 2>/dev/null)" ;;
    esac
}
if want D7; then reset D7; lists ""; printf '1\n' > "$WORK/rc"; failing_row D7 '1 [0-9]*'; fi
if want D7b; then reset D7b; lists ""; printf '2\n' > "$WORK/rc"; failing_row D7b '2 [0-9]*'; fi
if want D7c; then
    reset D7c; lists ""; printf '30\n' > "$WORK/sleep"
    export CHIEF_WAIT_DUTY_TIMEOUT=1
    failing_row D7c '1[23][47] [0-9]*'
    unset CHIEF_WAIT_DUTY_TIMEOUT
fi

if want D8; then
    reset D8; lists "$C
DUTY-RAN ci-masked 14@1234567 rerun 9 rc=0" "$C"
    quiet 2 'code-done id'
    reset D8
    j='DUTY judge-running 13@1234567 :: x :: next: x'
    lists "$j" "$j"; aged judge-running 13@1234567 -
    quiet 2 'judge-running never wakes'
fi

if want D9; then
    reset D9; lists "$C" "" ""
    quiet 3 'a one-list blip'
fi

if want D10; then
    reset D10
    mkdir -p "$WORK/d10/state" "$WORK/d10/go" "$WORK/d10/mirror"
    printf '[]\n' > "$WORK/d10/prs.json"; printf '[]\n' > "$WORK/d10/runs.json"
    printf '# source mirror_age_min=1\n' > "$WORK/d10/dispositions.txt"
    unset CHIEF_WAIT_DUTY_CMD
    export CHIEF_DUTY_SWEEP_PRS="$WORK/d10/prs.json" CHIEF_DUTY_SWEEP_RUNS="$WORK/d10/runs.json" CHIEF_DUTY_SWEEP_GO_ROOT="$WORK/d10/go" \
        CHIEF_DUTY_SWEEP_MIRROR="$WORK/d10/mirror" CHIEF_DUTY_SWEEP_DISPOSITIONS="$WORK/d10/dispositions.txt" CHIEF_DUTY_SWEEP_GH="$STUB/off.sh" \
        TICK_STATE_DIR="$WORK/d10/state" CANCEL_RUNS_PACE_STATE="$WORK/d10/pace"
    if after_tick 2 'default off'; then
        lacks 'D10 no chief-duty line' "$OUT" 'chief-duty '
        if [ -e "$inbox.wait.duty" ]; then fail 'D10 a list file was written'; else pass 'D10 no list file'; fi
        lacks 'D10 no off line' "$OUT" 'chief-duty off:'
    fi
    unset CHIEF_DUTY_SWEEP_PRS CHIEF_DUTY_SWEEP_RUNS CHIEF_DUTY_SWEEP_GO_ROOT CHIEF_DUTY_SWEEP_MIRROR CHIEF_DUTY_SWEEP_DISPOSITIONS \
        CHIEF_DUTY_SWEEP_GH TICK_STATE_DIR CANCEL_RUNS_PACE_STATE
    export CHIEF_WAIT_DUTY_CMD="$STUB/sweep.sh"
fi

if want D11; then
    reset D11; lists "" "$C" "$C"
    seed ci-masked 14@1234567 - 2000 700 1
    woke 3 're-entry after 10 minutes'
    contains 'D11 the returned id wakes' "$OUT" "$NEW_C"
fi

if want D12; then
    reset D12; lists "$C"
    if after_sweep 1 lock; then
        if [ -e "$WORK/fd9" ]; then fail 'D12 the sweep holds fd 9'; else pass 'D12 the sweep sees no fd 9'; fi
    fi
fi

if want D13; then
    reset D13; lists "$B" "$B"
    seed go-owed 12@abcdef0 - 100 1 0
    quiet 2 'a young go-owed'
    reset D13; lists "$B" "$B"
    seed go-owed 12@abcdef0 - 1900 1 0
    woke 1 'a 31 min old go-owed'
    contains 'D13 the old go-owed wakes' "$OUT" 'WAKE chief-duty 1 new=go-owed:12@abcdef0'
fi

if want D14; then
    reset D14
    d='DUTY dispatch-owed HIMMEL-1 :: x :: next: x'
    lists "$d" "$d"; aged dispatch-owed HIMMEL-1 -
    if quiet 2 'dispatch-owed never wakes'; then contains 'D14 dispatch-owed is carried' "$OUT" "$d"; fi
    reset D14
    d='DUTY owed-stale o7 :: x :: next: x'
    lists "$d" "$d"; aged owed-stale o7 -
    if quiet 2 'owed-stale never wakes'; then contains 'D14 owed-stale is carried as its count line' "$OUT" 'DUTY owed-stale x1 (not listed; run the sweep by hand)'; fi
fi

if want D15; then
    reset D15
    printf '%s\n' "$C" > "$inbox.wait.duty"
    printf 'telegram line\n' >> "$inbox"
    woke 0 'a wake before the sample'
    contains 'D15 carries the previous list' "$OUT" "$C"
    if [ -e "$WORK/n" ]; then fail 'D15 a sweep ran first'; else pass 'D15 no sweep ran first'; fi
fi

if want D16; then
    reset D16
    printf '%s\n' "$C" > "$inbox.wait.duty"
    touch -d "@$(( $(date +%s) - 1000 ))" "$inbox.wait.duty"
    printf '1\n' > "$WORK/rc"
    if after_sweep 1 'an old list'; then
        if printf '%s\n' "$OUT" | grep -qE "^$HDR_RE stale:\$"; then pass 'D16 the header reads stale'; else fail "D16 no stale header: $OUT"; fi
    fi
fi

if want D17; then
    reset D17; lists "" ""; printf '1\n' > "$WORK/rc"
    if after_sweep 1 'failing'; then contains 'D17 the failure line' "$OUT" 'chief-duty sweep failing rc=1 since '; fi
    rm -f "$WORK/rc"
    if after_sweep 2 'recovered'; then lacks 'D17 no failure line after a clean sweep' "$OUT" 'chief-duty sweep failing'; fi
fi

if want D18; then
    reset D18; lists "$C" "$(c_why 'CI run 9 failed, now another why text')"
    woke 2 'a changed why text'
    contains 'D18 the id still counts' "$OUT" "$NEW_C"
fi

if want D19; then
    reset D19; lists "$C" "$C"
    export CHIEF_WAIT_STREAM_SERVICE=1
    woke 2 stream
    contains 'D19 the stream wake' "$OUT" "$NEW_C"
    contains 'D19 the stream carry' "$OUT" 'chief-duty 1 as of'
    unset CHIEF_WAIT_STREAM_SERVICE
fi

if want D21; then
    reset D21; lists "$Q"; seed '?' prs - 1000 1 0
    if after_sweep 1 'old source'; then
        contains 'D21 the header counts no item' "$OUT" 'chief-duty 0 as of'
        contains 'D21 the old source is carried' "$OUT" "$Q"
    fi
fi
if want D21b; then
    reset D21b; lists "$Q"; seed '?' prs - 100 1 0
    if after_sweep 1 'young seeded source'; then lacks 'D21b a young source carries nothing' "$OUT" 'chief-duty '; fi
fi
if want D21c; then
    reset D21c; lists 'DUTY? worker N1 unread'
    if after_sweep 1 'worker source'; then
        if state | grep -q '^? worker:N1 - '; then pass 'D21c the worker source is one state line'; else fail "D21c state: $(state)"; fi
    fi
fi
if want D21d; then
    reset D21d; lists ""; seed '?' prs - 1000 1 0
    if after_sweep 1 'recovered source'; then lacks 'D21d a recovered source carries nothing' "$OUT" 'chief-duty '; fi
fi

if want D22; then
    reset D22
    s=$(c_why 'CI run 9 cancelled at this head after a green run; rerun sent')
    lists "$s" "$s"; aged ci-masked 14@1234567 sent
    quiet 2 'phase sent never wakes'
    x=$(c_why 'CI run 9 cancelled x2 at this head after a green run')
    lists "$s" "$s" "$x" "$x"
    woke 4 'cancelled x2 after sent'
    contains 'D22 the moved phase wakes' "$OUT" "$NEW_C"
    reset D22
    s=$(c_why 'CI run 9 cancelled at this head after a green run; held: drain 5m ago')
    lists "$s" "$s"; aged ci-masked 14@1234567 drain
    quiet 2 'phase drain never wakes'
    reset D22
    s=$(c_why 'CI run 9 cancelled at this head after a green run; a rerun is reserved by another sweep, outcome unknown')
    lists "$s" "$s"; aged ci-masked 14@1234567 sent
    quiet 2 'a rerun reserved by another sweep never wakes'
fi

if want D23; then
    reset D23; lists "$C"; ARGS=(--doc "$chief")
    if after_tick 1 'no manifest'; then
        contains 'D23 the off line' "$OUT" 'chief-duty off: no --workers-from'
        if [ -e "$WORK/n" ]; then fail 'D23 the sweep ran'; else pass 'D23 the sweep never runs'; fi
    fi
fi
if want D23b; then
    reset D23b; lists "$C"; ARGS=(--workers-from "$manifest")
    if after_tick 1 'no doc'; then
        contains 'D23b the off line' "$OUT" 'chief-duty off: no --doc'
        if [ -e "$WORK/n" ]; then fail 'D23b the sweep ran'; else pass 'D23b the sweep never runs'; fi
    fi
fi

if want D24; then
    reset D24
    p='DUTY judge-owed 15@7654321 :: judge-pending: x :: next: x'
    a='DUTY judge-owed 15@7654321 :: the push after prior verdict j1 at aaaaaaa is a trust delta :: next: x'
    lists "$p" "$p" "$a" "$a"
    woke 2 'judge pending'
    contains 'D24 the pending judge wakes' "$OUT" 'WAKE chief-duty 1 new=judge-owed:15@7654321'
    woke 4 'judge actionable'
    contains 'D24 the actionable judge wakes again' "$OUT" 'WAKE chief-duty 1 new=judge-owed:15@7654321'
fi

if want D25; then
    reset D25; lists "$C"; seed ci-masked 14@1234567 - 100 1 1
    if after_sweep 1 default; then check 'D25 the sweep sees autorun 0' 0 "$(cat "$WORK/autorun" 2>/dev/null)"; fi
    export CHIEF_WAIT_DUTY_AUTORUN=1
    if after_sweep 2 'waiter autorun on'; then check 'D25 CHIEF_WAIT_DUTY_AUTORUN=1 reads 1' 1 "$(cat "$WORK/autorun" 2>/dev/null)"; fi
    unset CHIEF_WAIT_DUTY_AUTORUN
    export CHIEF_DUTY_AUTORUN=1
    if after_sweep 3 'inherited autorun'; then check "D25 the waiter's own CHIEF_DUTY_AUTORUN is not passed through" 0 "$(cat "$WORK/autorun" 2>/dev/null)"; fi
    unset CHIEF_DUTY_AUTORUN
fi

if want D26; then
    R=D26
    check 'D26 the chief-duty rule row' "$(printf 'chief-duty\tduty-ids-two-lists-kind-age\tenter\t0\tduty-state\tabsent-10m-or-phase')" "$(awk -F'\t' '$1 == "chief-duty"' "$RULES")"
fi

if want D27; then
    reset D27; lists "$C"; seed ci-masked 14@1234567 - 100 1 1
    k=0
    for v in 0 abc -5 1.5 '' 7; do
        k=$((k + 1))
        export CHIEF_WAIT_DUTY_TIMEOUT="$v"
        case "$v" in 7) bound=7 ;; *) bound=60 ;; esac
        rm -f "$WORK/argv"
        if after_sweep "$k" "bound '$v'"; then contains "D27 bound '$v' reads $bound" "$(cat "$WORK/argv" 2>/dev/null)" "-k 2 $bound "; fi
    done
    unset CHIEF_WAIT_DUTY_TIMEOUT
fi

if want D28; then
    reset D28; lists "$C"
    printf 'pool-unresolved capacity=?\n' > "$inbox.wait.housekeeping"
    printf '%s\n' "$(( $(date +%s) - 5 ))" > "$inbox.wait.housekeeping.since"
    export HOUSEKEEPING_DIGEST_SECS=1
    woke 1 housekeeping
    contains 'D28 the housekeeping wake' "$OUT" 'WAKE housekeeping'
    contains 'D28 carries the list' "$OUT" 'chief-duty 1 as of'
    unset HOUSEKEEPING_DIGEST_SECS
fi

if want D29; then
    reset D29; lists "$C"
    printf 'tick changed=prs usage=PROCEED\n' > "$inbox.wait.housekeeping"
    date +%s > "$inbox.wait.housekeeping.since"
    if after_sweep 1 order; then
        order=$(printf '%s\n' "$OUT" | sed -nE 's/^(chief-duty) [0-9]+ as of .*/\1/p; s/^(look-only) since last wake:$/\1/p' | tr '\n' ' ')
        check 'D29 the duty block comes before the look-only block' 'chief-duty look-only ' "$order"
    fi
fi

if want D30; then
    reset D30; lists "$Q" "$Q" "$Q"; seed '?' prs - 2000 1 0
    quiet 3 'an unread source never wakes'
fi

if want D31; then
    reset D31; lists "$C"; printf '1\n' > "$WORK/tickrc"
    if after_tick 2 'failed sample'; then
        if [ -e "$WORK/n" ]; then fail 'D31 a failed sample ran the sweep'; else pass 'D31 a failed sample runs no sweep'; fi
    fi
fi

if want D32; then
    reset D32; lists ""
    if after_sweep 3 'once per sample'; then check 'D32 one sweep per sample' "$(count ticks)" "$(count n)"; fi
fi

if want D33; then
    reset D33
    h=$(c_why 'CI run 9 cancelled at this head after a green run; held: autorun off')
    x=$(c_why 'CI run 9 cancelled x2 at this head after a green run')
    lists "$h" "$h" "$h" "$h" "$x" "$x"; aged ci-masked 14@1234567 held
    woke 1 'held: autorun off'
    contains 'D33 the held line wakes' "$OUT" "$NEW_C"
    quiet 3 'held: a second run'
    lists "$h" "$h" "$h" "$x" "$x"
    woke 5 'cancelled x2 after held'
    contains 'D33 the hand rerun cancelled again wakes' "$OUT" "$NEW_C"
fi

if want D34; then
    R=D34
    for phrase in 'rerun sent' 'reserved by another sweep' 'held: ' 'judge-pending:' 'hold="drain '; do
        if grep -qF -e "$phrase" "$SWEEP"; then pass "D34 the sweep prints: $phrase"; else fail "D34 the sweep no longer prints: $phrase"; fi
    done
fi

if want D35; then
    reset D35
    many=""
    i=0
    while [ "$i" -lt 120 ]; do
        i=$((i + 1))
        many="${many}DUTY owed-stale o$i :: x :: next: x
"
    done
    lists "$C
${many%?}"
    if after_sweep 1 'over 100 owed-stale'; then
        check 'D35 one owed-stale line' 'DUTY owed-stale x120 (not listed; run the sweep by hand)' "$(printf '%s\n' "$OUT" | grep '^DUTY owed-stale ')"
        contains 'D35 the other kind is carried in full' "$OUT" "$C"
        check 'D35 no folded id is marked shown' 0 "$(state | awk '$1 == "owed-stale" && $6 != 0' | grep -c .)"
        check 'D35 every folded id keeps its state line' 120 "$(state | awk '$1 == "owed-stale"' | grep -c .)"
        check 'D35 the carried id is marked shown' 1 "$(state | awk '$1 == "ci-masked" { print $6 }')"
    fi
fi

if want D36; then
    reset D36
    g='DUTY guard-refusal block-x:rule-1:main :: x :: next: x'
    lists "$g" ""
    woke 1 'a once-printed guard-refusal'
    contains 'D36 the first list wakes' "$OUT" 'WAKE chief-duty 1 new=guard-refusal:block-x:rule-1:main'
    contains 'D36 the wake carries the line' "$OUT" "$g"
    quiet 2 'the line is gone'
fi

if [ "$fails" -ne 0 ]; then printf '%s FAILED\n' "$fails"; exit 1; fi
echo ALL PASS
