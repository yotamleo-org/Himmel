#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-compacted-check.sh
# scripts/handover/chief-kit/test-chief-budget.sh - suite for chief-budget.sh,
# the chief's turn / cumulative cache-read handover budget:
#   1. under both budgets                 -> rc 0, verdict=OK
#   2. turns at the budget                -> rc 3, verdict=HANDOVER
#   3. cache-read at the budget           -> rc 3, verdict=HANDOVER
#   4. duplicate requestIds count once    -> turns and cache_read deduped
#   5. unreadable / missing / empty       -> rc 2, never verdict=OK
#   6. session resolution                 -> CLAUDE_CODE_SESSION_ID and --title
#   7. sidechain rows and non-assistant rows are not turns
#
# Hermetic: temp dir only. Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/chief-budget.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-budget-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
unset CHIEF_TURN_BUDGET CHIEF_CACHE_READ_BUDGET_M
check()   { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { printf '%s' "$2" | grep -qF -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
lacks()    { printf '%s' "$2" | grep -qF -e "$3" && { echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# row <requestId> <cache_read> [extra-json-fields] - one assistant API-call row.
row() {
    printf '{"type":"assistant","requestId":"%s"%s,"message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":%s,"output_tokens":5}}}\n' "$1" "${3:-}" "$2"
}
# mk <file> <turns> <cache_read-per-turn> - a transcript of N distinct requests.
mk() {
    local f="$1" n="$2" cr="$3" i=1
    : > "$f"
    while [ "$i" -le "$n" ]; do row "req$i" "$cr" >> "$f"; i=$((i+1)); done
}

run() { rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$1" bash "$SCRIPT" 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"; }

# --- 1. under budget -----------------------------------------------------------
mk "$tmp/under.jsonl" 10 1000000
run "$tmp/under.jsonl"
check    "1: under budget rc 0" "$rc" 0
check    "1: one line, OK" "$out" "budget turns=10 cache_read=10.0M verdict=OK"

# --- 2. turns at the model-derived budget --------------------------------------
mk "$tmp/turns.jsonl" 110 1000
run "$tmp/turns.jsonl"
check    "2: 110 turns rc 3" "$rc" 3
contains "2: turns" "$out" "turns=110"
contains "2: verdict" "$out" "verdict=HANDOVER"
mk "$tmp/t109.jsonl" 109 1000
run "$tmp/t109.jsonl"
check    "2: 109 turns still OK (rc 0)" "$rc" 0
contains "2: one turn under the budget verdict" "$out" "verdict=OK"
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/t109.jsonl" CHIEF_TURN_BUDGET=100 bash "$SCRIPT" 2>&1)" || rc=$?
check    "2: CHIEF_TURN_BUDGET lowers the threshold (rc 3)" "$rc" 3
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/t109.jsonl" CONSOLE_TURN_BUDGET=100 bash "$SCRIPT" 2>&1)" || rc=$? # old-term-ok
check    "2: the retired name CONSOLE_TURN_BUDGET is ignored (rc 0)" "$rc" 0 # old-term-ok
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/turns.jsonl" CHIEF_TURN_BUDGET=200 CONSOLE_TURN_BUDGET=100 bash "$SCRIPT" 2>&1)" || rc=$? # old-term-ok
check    "2: CHIEF_TURN_BUDGET raises the threshold beside the retired name (rc 0)" "$rc" 0

# --- 3. cache-read at the budget -----------------------------------------------
mk "$tmp/cr.jsonl" 30 1000000
run "$tmp/cr.jsonl"
check    "3: 30.0M cache-read rc 3" "$rc" 3
contains "3: verdict" "$out" "cache_read=30.0M verdict=HANDOVER"
mk "$tmp/cr2.jsonl" 29 1000000
run "$tmp/cr2.jsonl"
check    "3: 29.0M still OK (rc 0)" "$rc" 0
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CHIEF_CACHE_READ_BUDGET_M=20 bash "$SCRIPT" 2>&1)" || rc=$?
check    "3: CHIEF_CACHE_READ_BUDGET_M overrides (rc 3)" "$rc" 3
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CONSOLE_CACHE_READ_BUDGET_M=20 bash "$SCRIPT" 2>&1)" || rc=$? # old-term-ok
check    "3: the retired name CONSOLE_CACHE_READ_BUDGET_M is ignored (rc 0)" "$rc" 0 # old-term-ok
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CHIEF_CACHE_READ_BUDGET_M=08 bash "$SCRIPT" 2>&1)" || rc=$?
check    "3: leading-zero budget 08 is decimal (rc 3, no octal abort)" "$rc" 3
contains "3: leading-zero budget still prints the line" "$out" "verdict=HANDOVER"
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CHIEF_CACHE_READ_BUDGET_M=008 bash "$SCRIPT" 2>&1)" || rc=$?
check    "3: 008 reads as decimal eight (rc 3)" "$rc" 3
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CHIEF_CACHE_READ_BUDGET_M=000 bash "$SCRIPT" 2>&1)" || rc=$?
check    "3: 000 is zero, falls back to the default (rc 0 at 29M)" "$rc" 0
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr.jsonl" CHIEF_CACHE_READ_BUDGET_M=000 bash "$SCRIPT" 2>&1)" || rc=$?
check    "3: 000 falls back to the default, not disabled (rc 3 at 30M)" "$rc" 3

# --- 4. duplicate requestIds ---------------------------------------------------
{ row a 1000000; row a 1000000; row b 2000000; row b 2000000; row a 1000000; } > "$tmp/dup.jsonl"
run "$tmp/dup.jsonl"
check    "4: duplicates counted once" "$out" "budget turns=2 cache_read=3.0M verdict=OK"
printf '%s\n' '{"type":"assistant","message":{"id":"m1","usage":{"cache_read_input_tokens":500000}}}' \
              '{"type":"assistant","message":{"id":"m1","usage":{"cache_read_input_tokens":500000}}}' > "$tmp/mid.jsonl"
run "$tmp/mid.jsonl"
check    "4: message.id dedupes when requestId is absent" "$out" "budget turns=1 cache_read=0.5M verdict=OK"

# --- 5. unreadable -------------------------------------------------------------
run "$tmp/nope.jsonl"
check    "5: missing transcript rc 2" "$rc" 2
lacks    "5: missing never says OK" "$out$err" "verdict=OK"
: > "$tmp/empty.jsonl"
run "$tmp/empty.jsonl"
check    "5: empty transcript rc 2" "$rc" 2
lacks    "5: empty never says OK" "$out$err" "verdict=OK"
printf 'not json\n{"type":"user"}\n' > "$tmp/junk.jsonl"
run "$tmp/junk.jsonl"
check    "5: no assistant usage rc 2" "$rc" 2
lacks    "5: no usage never says OK" "$out$err" "verdict=OK"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: no session at all rc 2" "$rc" 2
lacks    "5: no session never says OK" "$out" "verdict=OK"
mk "$tmp/big.jsonl" 200 1000
chmod 000 "$tmp/big.jsonl"
if [ ! -r "$tmp/big.jsonl" ]; then
    run "$tmp/big.jsonl"
    check "5: unreadable file rc 2" "$rc" 2
    lacks "5: unreadable never says OK" "$out$err" "verdict=OK"
fi
chmod 600 "$tmp/big.jsonl"

# --- 6. session resolution -----------------------------------------------------
cfg="$tmp/cfg"; mkdir -p "$cfg/projects/-slug"
mk "$cfg/projects/-slug/sid-1.jsonl" 7 1000000
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-1 bash "$SCRIPT" 2>&1)" || rc=$?
check    "6: CLAUDE_CODE_SESSION_ID resolves" "$out" "budget turns=7 cache_read=7.0M verdict=OK"
mk "$tmp/body" 4 1000000
{ printf '{"type":"custom-title","customTitle":"HIMMEL-nextleg-x-roadmap-chief"}\n'; cat "$tmp/body"; } > "$cfg/projects/-slug/sid-2.jsonl"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title HIMMEL-nextleg-x-roadmap-chief 2>&1)" || rc=$?
check    "6: --title resolves by customTitle" "$out" "budget turns=4 cache_read=4.0M verdict=OK"
mk "$tmp/late" 300 1000
{ cat "$tmp/late"; printf '{"type":"custom-title","customTitle":"late-titled-chief"}\n'; } > "$cfg/projects/-slug/sid-3.jsonl"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title late-titled-chief 2>&1)" || rc=$?
check    "6: a customTitle written late in the transcript still resolves" "$rc" 3
contains "6: late-title transcript measured" "$out" "turns=300"
{ printf '{"type":"custom-title","customTitle":"old-name-chief"}\n'; cat "$tmp/body"; printf '{"type":"custom-title","customTitle":"new-name-chief"}\n'; } > "$cfg/projects/-slug/sid-4.jsonl"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title old-name-chief 2>&1)" || rc=$?
check    "6: a renamed session no longer answers to its old title (rc 2)" "$rc" 2
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title new-name-chief 2>&1)" || rc=$?
check    "6: a renamed session answers to its latest title" "$out" "budget turns=4 cache_read=4.0M verdict=OK"
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/cr2.jsonl" CHIEF_CACHE_READ_BUDGET_M=99999999999999999999 bash "$SCRIPT" 2>&1)" || rc=$?
check    "6: an oversized budget falls back to the default (rc 0 at 29M)" "$rc" 0
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title no-such-chief 2>&1)" || rc=$?
check    "6: unknown --title rc 2" "$rc" 2
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-1 bash "$SCRIPT" --title '' 2>&1)" || rc=$?
check    "6: empty --title rc 2, never the session-id transcript" "$rc" 2
rc=0; out="$(bash "$SCRIPT" --bogus 2>&1)" || rc=$?
check    "6: unknown flag rc 2" "$rc" 2
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title new-name-chief --resolve 2>&1)" || rc=$?
check    "6: --resolve prints the transcript path (rc 0)" "$rc:$out" "0:$cfg/projects/-slug/sid-4.jsonl"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title no-such-chief --resolve 2>&1)" || rc=$?
check    "6: --resolve on an unknown --title rc 2" "$rc" 2

printf '%s\n' '{"type":"assistant","requestId":"n1","message":{"usage":{"cache_read_input_tokens":null}}}' \
              '{"type":"assistant","requestId":"n2","message":{"usage":{"input_tokens":3}}}' > "$tmp/nullcr.jsonl"
run "$tmp/nullcr.jsonl"
check    "4: a turn without cache_read still counts" "$out" "budget turns=2 cache_read=0.0M verdict=OK"
printf '%s\n' '{"type":"assistant","requestId":"k1","message":{"usage":{"cache_read_input_tokens":1000000}}}' \
              '{"type":"assistant","requestId":"k1","message":{"usage":{"cache_read_input_tokens":null}}}' > "$tmp/keep.jsonl"
run "$tmp/keep.jsonl"
check    "4: a later streamed row without cache_read keeps the earlier count" "$out" "budget turns=1 cache_read=1.0M verdict=OK"

# --- 7. sidechains and non-assistant rows --------------------------------------
{ row s1 1000000; row s2 1000000 ',"isSidechain":true'; printf '{"type":"user","requestId":"u1"}\n'; } > "$tmp/side.jsonl"
run "$tmp/side.jsonl"
check    "7: sidechain and user rows are not turns" "$out" "budget turns=1 cache_read=1.0M verdict=OK"

# --- 8. bash 3.2 parse safety --------------------------------------------------
# Apple bash 3.2 scans a $( ... <<'NODE' ... NODE ) body for quote balance, so an
# odd count of apostrophes in the node body is a syntax error there (rc 2 in every
# case on the macOS cadence, run 40145990367).
apos="$(awk '/<<.NODE.$/ {b=1; next} /^NODE$/ {b=0} b {n += gsub(/\047/, "&")} END {print n + 0}' "$SCRIPT")"
check    "8: the node heredoc body has an even number of apostrophes" "$((apos % 2))" 0

# --- 9. the context-fill rule --------------------------------------------------
# fx-chief-trimmed.jsonl is the FX chief's own transcript (800d2790, 2026-10-25) cut
# to its customTitle row and its last 50 usage rows: 50 turns, about 30M cache-read,
# the session that ran to 59 % fill with no handover wake. The fill comes from the
# HUD snapshot context-fill.sh --percent reads, keyed by sha256 of the transcript path.
fx_src="$HERE/fixtures/fx-chief-trimmed.jsonl"
fxd="$tmp/fx"; mkdir -p "$fxd/cfg/plugins/claude-hud/context-cache"
cp "$fx_src" "$fxd/fx.jsonl"
fxt="$(cd "$fxd" && pwd)/fx.jsonl"
fx_key="$(printf '%s' "$fxt" | sha256sum | cut -d' ' -f1)"
fx_fill() { # <pct> [age seconds] - a HUD snapshot for fx.jsonl at that fill
    printf '{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":1000000,"saved_at":%s000}' \
        "$1" "$((100 - $1))" "$(( $(date +%s) - ${2:-0} ))" > "$fxd/cfg/plugins/claude-hud/context-cache/$fx_key.json"
}
fx_run() { rc=0; out="$(CLAUDE_CONFIG_DIR="$fxd/cfg" CONTEXT_FILL_TRANSCRIPT="$fxt" CHIEF_CACHE_READ_BUDGET_M=999 "$@" bash "$SCRIPT" 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"; }
fx_fill 50
fx_run env
check    "9: 50 % fill with turns and cache-read under budget rc 3" "$rc" 3
contains "9: the line carries the fill" "$out" "fill=50%"
contains "9: verdict HANDOVER" "$out" "verdict=HANDOVER"
contains "9: turns stay under the turn budget" "$out" "turns=50 "
fx_fill 44
fx_run env
check    "9: 44 % fill stays OK (rc 0)" "$rc" 0
contains "9: the OK line carries the fill" "$out" "fill=44% verdict=OK"
fx_fill 45
fx_run env
check    "9: 45 % is the threshold itself (rc 3)" "$rc" 3
fx_fill 50
fx_run env CHIEF_FILL_HANDOVER_PCT=60
check    "9: CHIEF_FILL_HANDOVER_PCT overrides (50 % under 60 is OK, rc 0)" "$rc" 0
fx_run env CHIEF_FILL_HANDOVER_PCT=abc
check    "9: a bad CHIEF_FILL_HANDOVER_PCT falls back to 45 (rc 3)" "$rc" 3
contains "9: and says so on stderr" "$err" "ignoring CHIEF_FILL_HANDOVER_PCT=abc"
fx_run env CHIEF_FILL_HANDOVER_PCT=101
check    "9: a CHIEF_FILL_HANDOVER_PCT above 100 falls back to 45 (rc 3)" "$rc" 3
contains "9: and says so on stderr (above 100)" "$err" "ignoring CHIEF_FILL_HANDOVER_PCT=101"
fx_run env CHIEF_FILL_HANDOVER_PCT=100
check    "9: CHIEF_FILL_HANDOVER_PCT=100 is accepted (50 % under 100 is OK, rc 0)" "$rc" 0
fx_fill 80 4000
fx_run env
check    "9: a stale snapshot is an estimate, the fill rule is skipped (rc 0)" "$rc" 0
lacks    "9: and no fill is printed for it" "$out" "fill="
rm -f "$fxd/cfg/plugins/claude-hud/context-cache/$fx_key.json"
fx_run env
check    "9: no snapshot at all keeps the turn and cache-read rules only (rc 0)" "$rc" 0
check    "9: and prints the old line byte for byte" "$out" "budget turns=50 cache_read=31.5M verdict=OK"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
