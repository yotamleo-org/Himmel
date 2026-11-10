#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012  # A && B || C is the pass/fail reporting idiom; ls only counts fixture files
# test-record-read-clamp.sh — the himmel-read-clamp/v2 Read lifecycle: read-clamp.sh
# (PreToolUse) writes a pending record, record-read-clamp.sh (PostToolUse Read)
# consumes the range only after a complete successful Read of an unchanged file.
# Every payload is a fixture built here; state lives under a temp XDG_RUNTIME_DIR.
# Platform guard: bash-only, like the hooks it exercises. bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PRE="$HERE/read-clamp.sh"
POST="${RECORD_READ_CLAMP:-$HERE/record-read-clamp.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/record-read-clamp.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
RT="$WORK/xdg"; mkdir -p "$RT"
F="$WORK/ten.txt"; seq 1 10 > "$F"
EMPTY_OBJ='{}'

# pre <session> <tool_use_id> <agent_id or -> <path> [offset limit] [extra-json-object]
pre_json() {
    jq -cn --arg s "$1" --arg t "$2" --arg a "$3" --arg p "$4" --arg o "${5:-}" --arg l "${6:-}" --argjson x "${7:-$EMPTY_OBJ}" '
        {tool_name:"Read", session_id:$s, tool_use_id:$t,
         tool_input:({file_path:$p} + (if $o != "" then {offset:($o|tonumber)} else {} end)
                     + (if $l != "" then {limit:($l|tonumber)} else {} end) + $x)}
        + (if $a != "-" then {agent_id:$a} else {} end)'
}
# post <session> <tool_use_id> <agent_id or -> <path> <offset> <limit> <startLine> <numLines> <totalLines> [response-extra-json]
post_json() {
    jq -cn --arg s "$1" --arg t "$2" --arg a "$3" --arg p "$4" --arg o "$5" --arg l "$6" \
        --argjson st "$7" --argjson n "$8" --argjson tot "$9" --argjson x "${10:-$EMPTY_OBJ}" '
        {tool_name:"Read", hook_event_name:"PostToolUse", session_id:$s, tool_use_id:$t,
         tool_input:({file_path:$p} + (if $o != "" then {offset:($o|tonumber)} else {} end)
                     + (if $l != "" then {limit:($l|tonumber)} else {} end)),
         tool_response:({type:"text", file:{filePath:$p, content:"x", numLines:$n, startLine:$st, totalLines:$tot}} * $x)}
        + (if $a != "-" then {agent_id:$a} else {} end)'
}
run() { # <hook> <json> [extra env...] -> rc
    local h="$1" j="$2"; shift 2
    printf '%s' "$j" | env XDG_RUNTIME_DIR="$RT" HIMMEL_CONSOLE_LEG=1 HIMMEL_READ_CLAMP_LINES=2000 "$@" bash "$h" >"$WORK/out" 2>"$WORK/err"
    echo $?
}
expect() { # <label> <want rc> <got rc>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (want rc=$2 got rc=$3: $(cat "$WORK/err"))"; fi
}
# cycle <session> <tid> <agent> <path> <offset> <limit> <startLine> <numLines> <totalLines> [resp-extra]: Pre then Post
cycle() {
    local rc
    rc=$(run "$PRE" "$(pre_json "$1" "$2" "$3" "$4" "$5" "$6")")
    [ "$rc" = 0 ] || { echo "cycle pre rc=$rc"; return 1; }
    rc=$(run "$POST" "$(post_json "$@")")
    [ "$rc" = 0 ] || { echo "cycle post rc=$rc"; return 1; }
}

echo "=== read lifecycle (himmel-read-clamp/v2) ==="
[ -f "$POST" ] && pass "the recorder exists" || fail "no recorder at $POST"

expect "first Pre allows" 0 "$(run "$PRE" "$(pre_json s1 t1 - "$F" 1 5)")"
expect "a second Pre with no successful Post still allows" 0 "$(run "$PRE" "$(pre_json s1 t2 - "$F" 1 5)")"

cycle s2 t1 - "$F" 1 5 1 5 10
expect "after a complete successful Read the same range is denied" 2 "$(run "$PRE" "$(pre_json s2 t2 - "$F" 1 5)")"
grep -q "already read" "$WORK/err" && pass "the deny says already read" || fail "deny text: $(cat "$WORK/err")"
expect "another range of the same file still allows" 0 "$(run "$PRE" "$(pre_json s2 t3 - "$F" 6 5)")"
expect "a subagent of the same session is independent" 0 "$(run "$PRE" "$(pre_json s2 t4 agent-a "$F" 1 5)")"
expect "another session is independent" 0 "$(run "$PRE" "$(pre_json s3 t5 - "$F" 1 5)")"
cycle s2 t6 agent-a "$F" 1 5 1 5 10
expect "the subagent's own repeat is denied" 2 "$(run "$PRE" "$(pre_json s2 t7 agent-a "$F" 1 5)")"
expect "a sibling subagent stays independent" 0 "$(run "$PRE" "$(pre_json s2 t8 agent-b "$F" 1 5)")"

expect "a Post with no matching pending record changes nothing" 0 "$(run "$POST" "$(post_json s4 tX - "$F" 1 5 1 5 10)")"
expect "so the range is still readable" 0 "$(run "$PRE" "$(pre_json s4 t1 - "$F" 1 5)")"

E="$WORK/edit.txt"; printf 'aaaa\nbbbb\n' > "$E"
cycle s5 t1 - "$E" "" "" 1 2 2
expect "a whole small file read completely is consumed" 2 "$(run "$PRE" "$(pre_json s5 t2 - "$E")")"
printf 'aaab\nbbbb\n' > "$E"
expect "a same-size edit makes the file readable again" 0 "$(run "$PRE" "$(pre_json s5 t3 - "$E")")"

C="$WORK/change.txt"; printf 'one\n' > "$C"
run "$PRE" "$(pre_json s6 t1 - "$C")" >/dev/null
printf 'two\n' > "$C"
run "$POST" "$(post_json s6 t1 - "$C" "" "" 1 1 1)" >/dev/null
expect "a change between Pre and Post prevents consumption" 0 "$(run "$PRE" "$(pre_json s6 t2 - "$C")")"

cycle s7 t1 - "$F" 1 5 1 3 10
expect "a ranged result shorter than its limit before EOF is not consumed" 0 "$(run "$PRE" "$(pre_json s7 t2 - "$F" 1 5)")"
cycle s7 t3 - "$F" 8 5 8 3 10
expect "a ranged result that reached EOF is consumed" 2 "$(run "$PRE" "$(pre_json s7 t4 - "$F" 8 5)")"
cycle s7 t5 - "$F" "" "" 1 6 10
expect "a whole-file result short of totalLines is not consumed" 0 "$(run "$PRE" "$(pre_json s7 t6 - "$F")")"
cycle s7 t7 - "$F" "" "" 1 10 10 '{"file":{"truncatedByTokenCap":true}}'
expect "a whole-file result marked truncatedByTokenCap is not consumed" 0 "$(run "$PRE" "$(pre_json s7 t8 - "$F")")"
cycle s7 t9 - "$F" 3 2 1 2 10
expect "a result starting at another line is not consumed" 0 "$(run "$PRE" "$(pre_json s7 t10 - "$F" 3 2)")"
cycle s7 t11 - "$F" 1 2 1 2 10 '{"type":"image"}'
expect "an unknown-shaped result is not consumed" 0 "$(run "$PRE" "$(pre_json s7 t12 - "$F" 1 2)")"

BIG="$WORK/big.txt"; head -c 1100000 /dev/zero | tr '\0' 'a' > "$BIG"
cycle s8 t1 - "$BIG" 1 1 1 1 1
expect "a file over 1 MiB skips duplicate enforcement" 0 "$(run "$PRE" "$(pre_json s8 t2 - "$BIG" 1 1)")"
BIN="$WORK/blob.dat"; printf 'a\000b\n' > "$BIN"
cycle s8 t3 - "$BIN" "" "" 1 1 1
expect "a binary file skips duplicate enforcement" 0 "$(run "$PRE" "$(pre_json s8 t4 - "$BIN")")"
PDF="$WORK/doc.pdf"; printf 'text\n' > "$PDF"
cycle s8 t5 - "$PDF" "" "" 1 1 1
expect "a PDF stays with native handling" 0 "$(run "$PRE" "$(pre_json s8 t6 - "$PDF")")"
run "$PRE" "$(pre_json s8 t7 - "$F" 1 5 '{"pages":"1-2"}')" >/dev/null
run "$POST" "$(post_json s8 t7 - "$F" 1 5 1 5 10)" >/dev/null
expect "a Read with an extra argument is not tracked" 0 "$(run "$PRE" "$(pre_json s8 t8 - "$F" 1 5)")"
run "$PRE" "$(pre_json s8 t9 - "$F" "" "" '{"allow_large":true}')" >/dev/null
run "$POST" "$(post_json s8 t9 - "$F" "" "" 1 10 10)" >/dev/null
expect "allow_large stays outside duplicate tracking" 0 "$(run "$PRE" "$(pre_json s8 t10 - "$F")")"

for bad in '"has space"' '7' '""'; do
    j="$(pre_json s9 t1 - "$F" 1 5 | jq -c --argjson a "$bad" '.agent_id = $a')"
    p="$(post_json s9 t1 - "$F" 1 5 1 5 10 | jq -c --argjson a "$bad" '.agent_id = $a')"
    run "$PRE" "$j" >/dev/null; run "$POST" "$p" >/dev/null
    expect "a malformed agent_id ($bad) skips tracking" 0 "$(run "$PRE" "$(pre_json s9 t2 - "$F" 1 5 | jq -c --argjson a "$bad" '.agent_id = $a')")"
done
run "$PRE" "$(pre_json s9 '' - "$F" 1 5)" >/dev/null
expect "no tool_use_id: nothing to pair, still allows" 0 "$(run "$PRE" "$(pre_json s9 '' - "$F" 1 5)")"

# shellcheck source=scripts/hooks/lib/read-clamp-state.sh
. "$HERE/lib/read-clamp-state.sh"
statedir() { (export XDG_RUNTIME_DIR="$RT"; rc_state_init "$1" null "" && printf '%s\n' "$RC_DIR"); }
D="$(statedir s10)"
now=$(date +%s); i=0
while [ "$i" -lt 256 ]; do printf 'k\th\t%s\n' "$now" > "$D/pending/p$i"; i=$((i + 1)); done
run "$PRE" "$(pre_json s10 tcap - "$F" 1 5)" >/dev/null
run "$POST" "$(post_json s10 tcap - "$F" 1 5 1 5 10)" >/dev/null
expect "past 256 pending records tracking is skipped, never denied" 0 "$(run "$PRE" "$(pre_json s10 tcap2 - "$F" 1 5)")"
i=0; while [ "$i" -lt 256 ]; do printf 'k\th\t%s\n' "$((now - 4000))" > "$D/pending/p$i"; i=$((i + 1)); done
cycle s10 tok - "$F" 1 5 1 5 10
expect "expired pending records are pruned, so tracking resumes" 2 "$(run "$PRE" "$(pre_json s10 tok2 - "$F" 1 5)")"
[ "$(ls "$D/pending" | wc -l | tr -d ' ')" -le 1 ] && pass "expired pending records are deleted" || fail "pending left: $(ls "$D/pending" | wc -l)"
run "$PRE" "$(pre_json s10 told - "$F" 6 5)" >/dev/null
for f in "$D"/pending/*; do printf 'x\ty\t%s\n' "$((now - 4000))" > "$f"; done
run "$POST" "$(post_json s10 told - "$F" 6 5 6 5 10)" >/dev/null
expect "an expired pending record is never consumed" 0 "$(run "$PRE" "$(pre_json s10 told2 - "$F" 6 5)")"

D="$(statedir s11)"
i=0; : > "$D/done.tsv"; while [ "$i" -lt 2048 ]; do printf 'old%s\th\t00:00:00\n' "$i"; i=$((i + 1)); done >> "$D/done.tsv"
cycle s11 t1 - "$F" 1 5 1 5 10
[ "$(wc -l < "$D/done.tsv" | tr -d ' ')" = 2048 ] && pass "done keys stay capped at 2048" || fail "done rows: $(wc -l < "$D/done.tsv")"
! grep -q '^old0	' "$D/done.tsv" && pass "the oldest done key is evicted" || fail "oldest key kept"
expect "the newest key survives eviction" 2 "$(run "$PRE" "$(pre_json s11 t2 - "$F" 1 5)")"

D="$(statedir s12)"; printf 'himmel-read-clamp/v9\n' > "$D/format"
cycle s12 t1 - "$F" 1 5 1 5 10
expect "an unknown state format skips tracking" 0 "$(run "$PRE" "$(pre_json s12 t2 - "$F" 1 5)")"

post_json s13 t1 - "$F" 1 5 1 5 10 > "$WORK/gate.json"
expect "gate off: the recorder is a no-op" 0 "$(env XDG_RUNTIME_DIR="$RT" HIMMEL_CONSOLE_LEG=0 bash "$POST" < "$WORK/gate.json" >/dev/null 2>&1; echo $?)"
expect "malformed stdin: the recorder fails open" 0 "$(run "$POST" '{not json')"
[ ! -s "$WORK/out" ] && pass "the recorder prints nothing on stdout" || fail "recorder stdout: $(cat "$WORK/out")"

echo "==============================="
[ "$FAILED" -eq 0 ] && { echo "All cases passed."; exit 0; }
echo "$FAILED case(s) failed."; exit 1
