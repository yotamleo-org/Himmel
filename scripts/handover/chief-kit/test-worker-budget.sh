#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-chief-budget.sh
# scripts/handover/chief-kit/test-worker-budget.sh - suite for worker-budget.sh,
# a worker's live cost-eq budget (the worker-burn.sh formula):
#   1. under the soft threshold          -> rc 0, verdict=OK
#   2. at the soft threshold             -> rc 4, verdict=SOFT
#   3. at the hard ceiling               -> rc 3, verdict=HARD
#   4. duplicate message ids count once; cache-create and output are weighted
#   5. env overrides; a bad value falls back to the default
#   6. unreadable / missing / empty      -> rc 2, never verdict=OK
#   7. session resolution                -> CLAUDE_CODE_SESSION_ID and --title
#
# Hermetic: temp dir only. Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/worker-budget.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/worker-budget-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
unset WORKER_COST_SOFT_K WORKER_COST_HARD_K CONTEXT_FILL_TRANSCRIPT
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

# row <message id> <cache_read> [cache_create] [output] - one assistant API-call row.
# cost-eq = input*1 + cache_read*0.1 + cache_create*1.25 + output*5.
row() {
    printf '{"type":"assistant","message":{"id":"%s","usage":{"input_tokens":0,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' "$1" "${3:-0}" "$2" "${4:-0}"
}
# mk <file> <cache_read> - a one-call transcript whose cost-eq is cache_read / 10.
mk() { row m1 "$2" > "$1"; }

run() { rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$1" bash "$SCRIPT" 2>"$tmp/err")" || rc=$?; err="$(cat "$tmp/err")"; }

# --- 1. under the soft threshold -------------------------------------------------
mk "$tmp/under.jsonl" 29000000
run "$tmp/under.jsonl"
check    "1: under soft rc 0" "$rc" 0
check    "1: one line, OK" "$out" "worker-budget calls=1 cost-eq=2900.0k soft=3000k hard=7000k verdict=OK"

# --- 2. at the soft threshold ----------------------------------------------------
mk "$tmp/soft.jsonl" 30000000
run "$tmp/soft.jsonl"
check    "2: soft rc 4" "$rc" 4
contains "2: soft verdict" "$out" "cost-eq=3000.0k soft=3000k hard=7000k verdict=SOFT"
mk "$tmp/soft2.jsonl" 69000000
run "$tmp/soft2.jsonl"
check    "2: just under hard is still SOFT (rc 4)" "$rc" 4

# --- 3. at the hard ceiling ------------------------------------------------------
mk "$tmp/hard.jsonl" 70000000
run "$tmp/hard.jsonl"
check    "3: hard rc 3" "$rc" 3
contains "3: hard verdict" "$out" "cost-eq=7000.0k soft=3000k hard=7000k verdict=HARD"

# --- 4. dedupe and weights -------------------------------------------------------
{ row a 10000000; row a 10000000; row b 10000000; row b 10000000; row a 10000000; } > "$tmp/dup.jsonl"
run "$tmp/dup.jsonl"
check    "4: duplicate ids counted once" "$out" "worker-budget calls=2 cost-eq=2000.0k soft=3000k hard=7000k verdict=OK"
row c 0 2400000 0 > "$tmp/cc.jsonl"
run "$tmp/cc.jsonl"
contains "4: cache-create weighs 1.25 (2.4M -> 3000k)" "$out" "cost-eq=3000.0k"
row d 0 0 600000 > "$tmp/out.jsonl"
run "$tmp/out.jsonl"
contains "4: output weighs 5 (600k -> 3000k)" "$out" "cost-eq=3000.0k"
row e 0 0 100 > "$tmp/small.jsonl"
run "$tmp/small.jsonl"
check    "4: a sub-1000 cost-eq parses (rc 0)" "$rc" 0
contains "4: sub-1000 cost-eq printed in k" "$out" "cost-eq=0.5k"

# --- 5. env overrides ------------------------------------------------------------
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/under.jsonl" WORKER_COST_SOFT_K=2000 bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: WORKER_COST_SOFT_K overrides (rc 4)" "$rc" 4
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/under.jsonl" WORKER_COST_SOFT_K=1000 WORKER_COST_HARD_K=2500 bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: WORKER_COST_HARD_K overrides (rc 3)" "$rc" 3
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/under.jsonl" WORKER_COST_SOFT_K=abc bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: a bad soft value falls back to the default (rc 0)" "$rc" 0
contains "5: the bad value is named on stderr" "$out" "ignoring WORKER_COST_SOFT_K=abc"
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/soft.jsonl" WORKER_COST_SOFT_K=08 bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: leading-zero 08 is decimal (rc 4 at 3000k)" "$rc" 4
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/under.jsonl" WORKER_COST_SOFT_K=000 bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: zero falls back to the default, not disabled (rc 0)" "$rc" 0
rc=0; out="$(CONTEXT_FILL_TRANSCRIPT="$tmp/under.jsonl" WORKER_COST_SOFT_K=5000 WORKER_COST_HARD_K=4000 bash "$SCRIPT" 2>&1)" || rc=$?
check    "5: hard below soft is refused, defaults used (rc 0)" "$rc" 0
contains "5: hard below soft says so" "$out" "hard"

# --- 6. unreadable ---------------------------------------------------------------
run "$tmp/nope.jsonl"
check    "6: missing transcript rc 2" "$rc" 2
lacks    "6: missing never says OK" "$out$err" "verdict=OK"
: > "$tmp/empty.jsonl"
run "$tmp/empty.jsonl"
check    "6: empty transcript rc 2" "$rc" 2
lacks    "6: empty never says OK" "$out$err" "verdict=OK"
printf 'not json\n{"type":"user"}\n' > "$tmp/junk.jsonl"
run "$tmp/junk.jsonl"
check    "6: no assistant usage rc 2" "$rc" 2
lacks    "6: no usage never says OK" "$out$err" "verdict=OK"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" 2>&1)" || rc=$?
check    "6: no session at all rc 2" "$rc" 2
lacks    "6: no session never says OK" "$out" "verdict=OK"
rc=0; out="$(bash "$SCRIPT" --bogus 2>&1)" || rc=$?
check    "6: unknown argument rc 2" "$rc" 2

# --- 7. session resolution -------------------------------------------------------
cfg="$tmp/cfg"; mkdir -p "$cfg/projects/-slug"
mk "$cfg/projects/-slug/sid-1.jsonl" 10000000
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-1 bash "$SCRIPT" 2>&1)" || rc=$?
check    "7: CLAUDE_CODE_SESSION_ID resolves" "$out" "worker-budget calls=1 cost-eq=1000.0k soft=3000k hard=7000k verdict=OK"
{ printf '{"type":"custom-title","customTitle":"HIMMEL-1-N1-some-worker-2026-10-25"}\n'; row t1 40000000; } > "$cfg/projects/-slug/sid-2.jsonl"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title HIMMEL-1-N1-some-worker-2026-10-25 2>&1)" || rc=$?
check    "7: --title resolves by customTitle (rc 4)" "$rc" 4
contains "7: --title measured the titled transcript" "$out" "cost-eq=4000.0k"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" bash "$SCRIPT" --title no-such-worker 2>&1)" || rc=$?
check    "7: unknown --title rc 2" "$rc" 2
lacks    "7: unknown --title never says OK" "$out" "verdict=OK"
rc=0; out="$(env -u CONTEXT_FILL_TRANSCRIPT CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-9 bash "$SCRIPT" 2>&1)" || rc=$?
check    "7: unresolvable session id rc 2" "$rc" 2

# --- 8. --from-line judges a worker-burn line with no transcript --------------------
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn x.jsonl: calls=40 avg-ctx=90.0k first-turn=32.3k out=5 compactions=1 text-only=0 cost-eq=3100.5k floor-share=9%' 2>&1)" || rc=$?
check    "8: a soft line, rc 4" "$rc" 4
contains "8: soft line verdict" "$out" "worker-budget calls=40 cost-eq=3100.5k soft=3000k hard=7000k verdict=SOFT"
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn: calls=400 avg-ctx=106.9k first-turn=32.3k compactions=7 cost-eq=7689.4k profile=worker-impl' 2>&1)" || rc=$?
check    "8: a PR-body hard line, rc 3" "$rc" 3
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn: calls=16 avg-ctx=44.0k first-turn=32.9k compactions=0 cost-eq=154.4k profile=worker-impl' 2>&1)" || rc=$?
check    "8: a small line, rc 0" "$rc" 0
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn x.jsonl: calls=4 avg-ctx=128.1k first-turn=74.3k out=185 compactions=2 text-only=2' 2>&1)" || rc=$?
check    "8: a line without cost-eq, rc 2" "$rc" 2
lacks    "8: a line without cost-eq never says OK" "$out" "verdict=OK"
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn: calls=0 cost-eq=. profile=x' 2>&1)" || rc=$?
check    "8: a malformed cost-eq, rc 2" "$rc" 2
lacks    "8: a malformed cost-eq never says OK" "$out" "verdict=OK"
rc=0; out="$(bash "$SCRIPT" --from-line 'worker-burn: calls=0 cost-eq=1.0k profile=x' 2>&1)" || rc=$?
check    "8: zero calls, rc 2" "$rc" 2
lacks    "8: zero calls never says OK" "$out" "verdict=OK"

# --- 9. the stderr scratch file has an unpredictable name -------------------------
src="$(cat "$SCRIPT")"
lacks    "9: no pid-derived scratch file name" "$src" '.$$.err'
contains "9: scratch file comes from mktemp" "$src" 'mktemp'

echo
[ "$fails" -eq 0 ] && echo "all worker-budget checks passed" || { echo "$fails check(s) FAILED"; exit 1; }
