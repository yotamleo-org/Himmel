#!/usr/bin/env bash
# Per-construct scaling test for the PreToolUse Bash hook chain.
#
# Usage: bash scripts/hooks/test-hook-construct-scaling.sh
#
# Why: the chain's escapes were construct-specific, and a generic payload cannot
# see them. One shape at a time went super-linear in a member: bare assignment
# segments (UNSET_NAMES doubled per segment, an 8 h spin), unclosed `((` and
# `$((` openers (arith_body rescanned to EOF for each), repeated digit
# redirects, nested-quote `${V:-"`, large heredocs, brace groups and
# apply_patch headers. test-hook-chain-latency.sh keeps the generic 4x payload;
# this suite supplies the constructs.
#
# Contract, for EVERY member wired on the Bash PreToolUse matcher (read from
# .claude/settings.json, so a new member is covered unasked), for EVERY
# generator below:
#   * the generator builds the construct at N units and at 8N units;
#   * each size runs once (a failing row is measured once more and the minimum
#     of each size counts, so one load spike cannot fail a row) under
#     `timeout` and `prlimit` 1G address space / 60 s CPU;
#   * RATIO: the 8N time is at most RATIO_MAX times the N time (floored at
#     FLOOR_MS so a member that costs nothing cannot fail on scheduler noise);
#   * BUDGET: the 8N time is at most BUDGET_MS, well inside the chain's
#     per-member window; a run that times out fails;
#   * VACUITY: the named scanner member must spend at least VACUOUS_MS at the
#     N size, else the generator is not reaching any scanning code.
# Plus a closed-stdin row: every member started with fd 0 closed must end
# inside CLOSED_TIMEOUT. A `$(cat)` reader hangs with fd 0 closed and that
# bug is open, so the members that hang today are listed in KNOWN_HANG:
# a member NOT listed that hangs fails, and a listed member that no longer
# hangs fails too (delete it from the list when its fix lands).
#
# RED control: HOOK_SCALING_ROOT points at another tree that provides
# scripts/hooks, scripts/lib and scripts/chokepoints.json (a `git archive`
# export of an old commit); members missing from that tree are skipped. Run it
# on the parent of the exponential-UNSET_NAMES fix and of the arith_body
# rescan fix and the suite fails.
#
# Exit codes: 0 all rows passed, 1 at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd -P)"
ROOT="${HOOK_SCALING_ROOT:-$REPO_ROOT}"
SETTINGS="$REPO_ROOT/.claude/settings.json"

RATIO_MAX=${HOOK_SCALING_RATIO_MAX:-12}
FLOOR_MS=${HOOK_SCALING_FLOOR_MS:-50}
BUDGET_MS=${HOOK_SCALING_BUDGET_MS:-10000}
VACUOUS_MS=10
RUN_TIMEOUT=${HOOK_SCALING_RUN_TIMEOUT:-15}
CLOSED_TIMEOUT=${HOOK_SCALING_CLOSED_TIMEOUT:-3}
# shellcheck source=../lib/timeout-bin.sh
. "$REPO_ROOT/scripts/lib/timeout-bin.sh"

# Members that hang with fd 0 closed today (the open `$(cat)` bug).
KNOWN_HANG=' guard-identical-denied-retry.sh read-clamp.sh block-edit-live-settings.sh block-write-into-main-checkout.sh block-bank-lift-writes.sh block-himmel-config-writes.sh guard-bus-store.sh guard-relay-writes.sh '

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

if [ -z "${EPOCHREALTIME:-}" ]; then
    echo "SKIP test-hook-construct-scaling: needs bash >= 5 (EPOCHREALTIME)"
    exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "FAIL fixture: jq not found"; exit 1; }

# A UTF-8 locale: the quadratic cost is worst there, and it is what the station
# and the CI runners run hooks under. No locale would time the cheap path.
LOCALES=$(locale -a 2>/dev/null)
UTF8_LOCALE=''
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if printf '%s\n' "$LOCALES" | grep -x -- "$l" >/dev/null; then UTF8_LOCALE=$l; break; fi
done
[ -n "$UTF8_LOCALE" ] || { echo "FAIL fixture: no UTF-8 locale (tried C.UTF-8, C.utf8, en_US.UTF-8, en_US.utf8)"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hook-construct.XXXXXX") || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

MEMBERS=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$SETTINGS" \
    | grep -o -E 'scripts/hooks/[A-Za-z0-9_-]+\.sh' | awk '!seen[$0]++')
[ -n "$MEMBERS" ] || { echo "FAIL fixture: no Bash PreToolUse members in $SETTINGS"; exit 1; }

# Bound memory and CPU where prlimit exists (util-linux; absent on macOS).
LIMIT=()
if command -v prlimit >/dev/null 2>&1; then LIMIT=(prlimit --as=1073741824 --cpu=60); fi

payload() {  # payload <command> <file>
    jq -n --arg c "$1" --arg cwd "$SANDBOX" \
        '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "hook-construct"}' > "$2" \
        && [ -s "$2" ] || { echo "FAIL fixture: jq wrote no payload to ${2##*/}"; exit 1; }
}

rep() {  # rep <string> <count> -- doubling, so building the payload is linear
    local s=$1 cnt=$2 out=$1 k=1
    while [ $(( k * 2 )) -le "$cnt" ]; do out+=$out; k=$(( k * 2 )); done
    while [ "$k" -lt "$cnt" ]; do out+=$s; k=$(( k + 1 )); done
    printf '%s' "$out"
}

prose() {  # prose <lines> -- a python heredoc of multibyte prose
    local i out="python3 - <<'PYEOF'"$'\n'
    for ((i = 0; i < $1; i++)); do
        out+="print('line $i — the console hands the leg a brief; see the doc é')"$'\n'
    done
    printf '%sPYEOF' "$out"
}

MS=0
RC=0
run_ms() {  # run_ms <member> <payload file> -- wall ms into MS, exit status into RC
    local t0 t1
    t0=${EPOCHREALTIME//[!0-9]/}
    env -i PATH="$PATH" HOME="$SANDBOX/home" TMPDIR="${TMPDIR:-/tmp}" \
        LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" CLAUDE_PROJECT_DIR="$ROOT" \
        HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_RELAY=1 \
        "${LIMIT[@]}" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$RUN_TIMEOUT"} bash "$ROOT/$1" < "$2" > /dev/null 2>&1
    RC=$?
    t1=${EPOCHREALTIME//[!0-9]/}
    MS=$(( (t1 - t0) / 1000 ))
}

# A member answers 0 (allow / no opinion) or 2 (deny); 124 is the timeout.
rc_ok() { [ "$1" -eq 0 ] || [ "$1" -eq 2 ]; }

# verdict <small ms> <big ms> <small rc> <big rc> -- prints why the row fails, else nothing
verdict() {
    local base=$1
    [ "$base" -ge "$FLOOR_MS" ] || base=$FLOOR_MS
    if [ "$3" -eq 124 ]; then echo "timed out at N (> ${RUN_TIMEOUT}s)"
    elif [ "$4" -eq 124 ]; then echo "timed out at 8N (> ${RUN_TIMEOUT}s)"
    elif ! rc_ok "$3"; then echo "exit $3 at N (a member answers 0 or 2)"
    elif ! rc_ok "$4"; then echo "exit $4 at 8N (a member answers 0 or 2)"
    elif [ "$2" -gt "$BUDGET_MS" ]; then echo "8N ${2}ms over the ${BUDGET_MS}ms member budget"
    elif [ "$2" -gt $(( RATIO_MAX * base )) ]; then echo "8N ${2}ms is more than ${RATIO_MAX}x the N time ${1}ms"
    fi
}

# gen <name> <scanner> <unit> <N> <prefix> <suffix> <closer>
gen() {
    local name=$1 scanner=$2 unit=$3 n=$4 pre=$5 suf=$6 cl=$7 m mname
    local small big brc srcs why worstm='' bigw=0 members=0 bad=0 scan_small=-1 line
    payload "${pre}$(rep "$unit" "$n")$([ -n "$cl" ] && rep "$cl" "$n")${suf}" "$SANDBOX/s.json"
    payload "${pre}$(rep "$unit" $(( n * 8 )))$([ -n "$cl" ] && rep "$cl" $(( n * 8 )))${suf}" "$SANDBOX/b.json"
    for m in $MEMBERS; do
        mname=${m##*/}
        if [ ! -f "$ROOT/$m" ]; then
            if [ "$ROOT" = "$REPO_ROOT" ]; then fail "$name $mname: wired in settings.json but missing"; fi
            continue
        fi
        members=$((members + 1))
        run_ms "$m" "$SANDBOX/s.json"; small=$MS; srcs=$RC
        run_ms "$m" "$SANDBOX/b.json"; big=$MS; brc=$RC
        why=$(verdict "$small" "$big" "$srcs" "$brc")
        if [ -n "$why" ]; then
            # one more measurement of each size; the minimum counts
            run_ms "$m" "$SANDBOX/s.json"; [ "$MS" -lt "$small" ] && small=$MS; srcs=$RC
            run_ms "$m" "$SANDBOX/b.json"; [ "$MS" -lt "$big" ] && big=$MS; brc=$RC
            why=$(verdict "$small" "$big" "$srcs" "$brc")
        fi
        [ "$mname" = "$scanner" ] && scan_small=$small
        [ "$big" -gt "$bigw" ] && { bigw=$big; worstm=$mname; }
        if [ -n "$why" ]; then fail "$name $mname: $why"; bad=1; fi
    done
    if [ "$members" -eq 0 ]; then fail "$name: no member ran"; return; fi
    if [ "$scan_small" -ge 0 ] && [ "$scan_small" -lt "$VACUOUS_MS" ]; then
        fail "$name $scanner: ran ${scan_small}ms at N (exited before scanning: vacuous generator)"; bad=1
    fi
    line="$name: $members members, slowest 8N ${bigw}ms ($worstm)"
    [ "$bad" -eq 0 ] && pass "$line (<= ${RATIO_MAX}x, <= ${BUDGET_MS}ms)"
}

CHOKE=block-chokepoint-env-prefix.sh
# shellcheck disable=SC2016  # generator units are command TEXT; nothing expands here
{
    gen 'assign-only segments'      "$CHOKE" 'V=1; '                      12  ''           'true' ''
    gen 'repeated digit redirects'  "$CHOKE" '2>&1 '                      25  'echo x '    ''     ''
    gen 'unclosed ((  openers'      "$CHOKE" '(( x '                      40  'echo '      ''     ''
    gen 'unclosed $(( openers'      "$CHOKE" '$(( x '                     40  'echo '      ''     ''
    gen 'nested-quote ${V:-"'       "$CHOKE" '${V:-"'                     6   'echo '      ''     '"}'
    gen 'brace groups'              block-destructive-commands.sh '{ echo a; ' 25  ''      ''     '; }'
    gen 'apply_patch headers'       "$CHOKE" $'*** Update File: a/b.txt\n@@\n-old\n+new\n' 50 $'apply_patch <<\'EOF\'\n*** Begin Patch\n' $'*** End Patch\nEOF' ''
}
# heredoc: lines, not repeats of one string
{
    payload "$(prose 40)" "$SANDBOX/hs.json"
    payload "$(prose 320)" "$SANDBOX/hb.json"
    hbad=0 hmembers=0 hworst=0 hworstm='' hscan=-1
    for m in $MEMBERS; do
        [ -f "$ROOT/$m" ] || continue
        mname=${m##*/}; hmembers=$((hmembers + 1))
        run_ms "$m" "$SANDBOX/hs.json"; small=$MS; srcs=$RC
        run_ms "$m" "$SANDBOX/hb.json"; big=$MS; brc=$RC
        why=$(verdict "$small" "$big" "$srcs" "$brc")
        if [ -n "$why" ]; then
            run_ms "$m" "$SANDBOX/hs.json"; [ "$MS" -lt "$small" ] && small=$MS; srcs=$RC
            run_ms "$m" "$SANDBOX/hb.json"; [ "$MS" -lt "$big" ] && big=$MS; brc=$RC
            why=$(verdict "$small" "$big" "$srcs" "$brc")
        fi
        [ "$mname" = "$CHOKE" ] && hscan=$small
        [ "$big" -gt "$hworst" ] && { hworst=$big; hworstm=$mname; }
        if [ -n "$why" ]; then fail "22 KB heredoc $mname: $why"; hbad=1; fi
    done
    if [ "$hscan" -ge 0 ] && [ "$hscan" -lt "$VACUOUS_MS" ]; then
        fail "22 KB heredoc $CHOKE: ran ${hscan}ms at N (exited before scanning: vacuous generator)"; hbad=1
    fi
    [ "$hbad" -eq 0 ] && pass "22 KB heredoc: $hmembers members, slowest 8N ${hworst}ms ($hworstm) (<= ${RATIO_MAX}x, <= ${BUDGET_MS}ms)"
}

# Closed stdin: start every member at once with fd 0 closed.
payload 'git status' "$SANDBOX/closed.json"
for m in $MEMBERS; do
    [ -f "$ROOT/$m" ] || continue
    (
        env -i PATH="$PATH" HOME="$SANDBOX/home" TMPDIR="${TMPDIR:-/tmp}" \
            LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" CLAUDE_PROJECT_DIR="$ROOT" \
            HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_RELAY=1 \
            "${LIMIT[@]}" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$CLOSED_TIMEOUT"} bash "$ROOT/$m" <&- > /dev/null 2>&1
        echo $? > "$SANDBOX/closed.${m##*/}.rc"
    ) &
done
wait
cbad=0 chung=0
for m in $MEMBERS; do
    mname=${m##*/}
    [ -f "$SANDBOX/closed.$mname.rc" ] || continue
    crc=$(cat "$SANDBOX/closed.$mname.rc")
    case "$KNOWN_HANG" in *" $mname "*) known=1 ;; *) known=0 ;; esac
    if [ "$crc" -eq 124 ]; then
        chung=$((chung + 1))
        if [ "$known" -eq 0 ]; then fail "closed stdin $mname: hung past ${CLOSED_TIMEOUT}s with fd 0 closed (not a known case)"; cbad=1; fi
    elif [ "$known" -eq 1 ]; then
        fail "closed stdin $mname: no longer hangs (exit $crc); remove it from KNOWN_HANG"; cbad=1
    elif ! rc_ok "$crc"; then
        fail "closed stdin $mname: exit $crc (a member answers 0 or 2)"; cbad=1
    fi
done
[ "$cbad" -eq 0 ] && pass "closed stdin: $chung known hangs, every other member ends inside ${CLOSED_TIMEOUT}s"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
