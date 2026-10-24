#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-leg-cache-ttl.sh: the Stop hook that
# refuses, once per stop, the stop of a console-spawned leg that holds its
# queue lock while no background task or Monitor is running to wake it before
# the 1 h prompt-cache TTL.
#
# RED control first: the hook did not exist at the base this ticket cut from,
# so on main nothing refused such a stop.
#
# Isolated fixture: its own HANDOVER_DIR/XDG_RUNTIME_DIR under mktemp -d, a real
# queue-lock.sh acquire on a fabricated leg doc scoped via
# QUEUE_LOCK_SESSION_SCOPE, and transcript fixtures written as JSONL files.
# Cleanup is non-recursive rm -f plus rmdir (block-destructive-commands.sh
# refuses rm -rf). bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
HOOK="${CACHE_TTL_HOOK:-$HOOKS/guard-leg-cache-ttl.sh}"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: no jq on PATH"; exit 0; }
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "SKIP: no sha256 tool on PATH"
    exit 0
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/canon-path.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-leg-cache-ttl-test.XXXXXX")" || { echo "setup: mktemp -d failed" >&2; exit 1; }
TMP="$(canon_path "$TMP")" || { echo "setup: canon_path failed" >&2; exit 1; }
HANDOVER_DIR="$TMP/handover"
XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$HANDOVER_DIR" "$XDG_RUNTIME_DIR"
export HANDOVER_DIR XDG_RUNTIME_DIR

SESSION_ID="test-session-himmel-6527"
LEG_DOC="$HANDOVER_DIR/HIMMEL-1-N1-fixture-leg.md"
printf 'fixture leg doc\n' > "$LEG_DOC"

RELEASE_TOKEN=""
release_lock() {
    [ -n "$RELEASE_TOKEN" ] || return 0
    QUEUE_LOCK_SESSION_SCOPE="$SESSION_ID" bash "$REPO/scripts/handover/queue-lock.sh" release "$LEG_DOC" "$RELEASE_TOKEN" >/dev/null 2>&1
    RELEASE_TOKEN=""
}
cleanup() {
    release_lock
    for f in "$HANDOVER_DIR"/.locks/queue/*.lock/*; do rm -f "$f" 2>/dev/null; done
    for d in "$HANDOVER_DIR"/.locks/queue/*.lock; do rmdir "$d" 2>/dev/null; done
    rm -f "$HANDOVER_DIR/.locks/queue/takeovers.log" 2>/dev/null
    rmdir "$HANDOVER_DIR/.locks/queue" "$HANDOVER_DIR/.locks" 2>/dev/null
    rm -f "$LEG_DOC" 2>/dev/null
    rmdir "$HANDOVER_DIR" 2>/dev/null
    for f in "$XDG_RUNTIME_DIR/himmel-queue-lock"/*; do rm -f "$f" 2>/dev/null; done
    rmdir "$XDG_RUNTIME_DIR/himmel-queue-lock" "$XDG_RUNTIME_DIR" 2>/dev/null
    rmdir "$TMP/dir.jsonl" 2>/dev/null
    for f in "$TMP"/*.jsonl; do rm -f "$f" 2>/dev/null; done
    rmdir "$TMP" 2>/dev/null
}
trap cleanup EXIT

lock_out="$(QUEUE_LOCK_SESSION_SCOPE="$SESSION_ID" bash "$REPO/scripts/handover/queue-lock.sh" acquire "$LEG_DOC")" \
    || { echo "setup: could not acquire the fixture leg lock" >&2; exit 1; }
# shellcheck disable=SC2016  # backtick span pattern, not a shell expansion
RELEASE_TOKEN="$(printf '%s\n' "$lock_out" | sed -n 's/^release-token: `\(.*\)`$/\1/p')"
[ -n "$RELEASE_TOKEN" ] || { echo "setup: acquire printed no release token" >&2; exit 1; }

# --- transcript fixtures ----------------------------------------------------
ROW_TEXT='{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"READY sent, holding for GO."}]}}'
row_bg()      { printf '{"type":"user","toolUseResult":{"stdout":"","backgroundTaskId":"%s"}}' "$1"; }
row_monitor() { printf '{"type":"user","toolUseResult":{"taskId":"%s","timeoutMs":1800000,"persistent":false}}' "$1"; }
row_stopped() { printf '{"type":"user","toolUseResult":{"message":"Successfully stopped task: %s","task_id":"%s","task_type":"local_bash"}}' "$1" "$1"; }
row_done()    { printf '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\\n<task-id>%s</task-id>\\n<status>completed</status>\\n<summary>done</summary>\\n</task-notification>"}' "$1"; }
row_event()   { printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>%s</task-id>\\n<event>line</event>\\n</task-notification>"}}' "$1"; }

T_IDLE="$TMP/idle.jsonl";        printf '%s\n' "$ROW_TEXT" > "$T_IDLE"
T_BG="$TMP/bg.jsonl";            { row_bg b1; echo; printf '%s\n' "$ROW_TEXT"; } > "$T_BG"
T_MON="$TMP/mon.jsonl";          { row_monitor b2; echo; row_event b2; echo; printf '%s\n' "$ROW_TEXT"; } > "$T_MON"
T_DONE="$TMP/done.jsonl";        { row_bg b3; echo; row_done b3; echo; printf '%s\n' "$ROW_TEXT"; } > "$T_DONE"
T_STOP="$TMP/stopped.jsonl";     { row_monitor b4; echo; row_stopped b4; echo; printf '%s\n' "$ROW_TEXT"; } > "$T_STOP"
T_JUNK="$TMP/junk.jsonl";        { printf 'not json {\n'; row_bg b5; echo; } > "$T_JUNK"
T_MIXED="$TMP/mixed.jsonl";      { row_bg b6; echo; row_done b6; echo; row_bg b7; echo; } > "$T_MIXED"

payload() {   # payload <transcript> [stop_hook_active] [session]
    printf '{"session_id":"%s","stop_hook_active":%s,"hook_event_name":"Stop","transcript_path":"%s"}' \
        "${3:-$SESSION_ID}" "${2:-false}" "$1"
}
OUT=""; RC=0
run_guard() {   # run_guard <payload> [ENV=val ...] — sets OUT and RC
    local p="$1"; shift
    OUT="$(printf '%s' "$p" | env HIMMEL_CONSOLE_LEG=1 "$@" bash "$HOOK")"; RC=$?
}
expect_block() {   # expect_block <label> — reads OUT/RC from the last run_guard
    case "$OUT" in
        *'"decision":"block"'*) if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 — blocked but exit $RC"; fi ;;
        *) bad "$1 — expected block, got: ${OUT:-<no output>} (exit $RC)" ;;
    esac
}
expect_allow() {   # expect_allow <label> — silent AND exit 0, so a crash is not an allow
    if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1 — expected a silent exit-0 allow, got: ${OUT:-<no output>} (exit $RC)"; fi
}

# --- RED control --------------------------------------------------------------
BASE_SHA="4eff389fb4a74863c297bb826c9b3a5104df07b7"
if ! git -C "$REPO" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
    ok "RED control: SKIP — base $BASE_SHA is not in this clone (shallow checkout)"
elif git -C "$REPO" cat-file -e "$BASE_SHA:scripts/hooks/guard-leg-cache-ttl.sh" 2>/dev/null; then
    bad "RED control: guard-leg-cache-ttl.sh already existed at $BASE_SHA"
else
    ok "RED control: no leg cache guard at base $BASE_SHA — an idle lock-holding leg's stop was never refused"
fi

# --- refused ------------------------------------------------------------------
run_guard "$(payload "$T_IDLE")"; out="$OUT"
expect_block "lock held, no background task -> block"
case "$out" in
    *'check-ci.sh <pr> --max-wait 3000'*) ok "reason names a bounded check-ci wait at the 3000s default" ;;
    *) bad "reason lacks the bounded check-ci wait — got: $out" ;;
esac
case "$out" in
    *'leg-sections/cache-keepalive.md'*) ok "reason names the wrap rule" ;;
    *) bad "reason lacks leg-sections/cache-keepalive.md — got: $out" ;;
esac
case "$out" in
    *'HIMMEL-1-N1-fixture-leg.md'*) ok "reason names the held doc" ;;
    *) bad "reason lacks the held doc — got: $out" ;;
esac
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | length > 0)' >/dev/null 2>&1; then
    ok "block output is valid JSON"
else
    bad "block output is not valid JSON: $out"
fi

run_guard "$(payload "$T_DONE")"
expect_block "background task completed (task-notification status) -> block"
run_guard "$(payload "$T_STOP")"
expect_block "Monitor stopped by TaskStop -> block"

run_guard "$(payload "$T_IDLE")" HIMMEL_LEG_CACHE_KEEPALIVE_SECS=1800; out="$OUT"
case "$out" in *'--max-wait 1800'*) ok "bound is config: HIMMEL_LEG_CACHE_KEEPALIVE_SECS=1800 is named" ;; *) bad "bound 1800 not named — got: $out" ;; esac
run_guard "$(payload "$T_IDLE")" HIMMEL_LEG_CACHE_KEEPALIVE_SECS=7200; out="$OUT"
case "$out" in *'--max-wait 3000'*) ok "bound past the TTL margin (7200) falls back to 3000" ;; *) bad "bound 7200 did not fall back — got: $out" ;; esac
run_guard "$(payload "$T_IDLE")" HIMMEL_LEG_CACHE_KEEPALIVE_SECS=junk; out="$OUT"
case "$out" in *'--max-wait 3000'*) ok "junk bound falls back to 3000" ;; *) bad "junk bound did not fall back — got: $out" ;; esac

# --- allowed ------------------------------------------------------------------
run_guard "$(payload "$T_BG")"
expect_allow "background Bash still running -> allow"
run_guard "$(payload "$T_MON")"
expect_allow "Monitor running (an event is not terminal) -> allow"
run_guard "$(payload "$T_MIXED")"
expect_allow "one of two background tasks still running -> allow"
run_guard "$(payload "$T_JUNK")"
expect_allow "malformed transcript line is skipped, running task still seen -> allow"
run_guard "$(payload "$T_IDLE" true)"
expect_allow "stop_hook_active=true -> allow (one refusal per stop)"
run_guard "$(payload "$T_IDLE" false other-session)"
expect_allow "another session's stop (lock not ours) -> allow"
OUT="$(printf '%s' "$(payload "$T_IDLE")" | env -u HIMMEL_CONSOLE_LEG bash "$HOOK")"; RC=$?
expect_allow "not a console leg (HIMMEL_CONSOLE_LEG unset) -> allow"
run_guard "$(payload "$T_IDLE")" HIMMEL_RELEASE_MANAGER=1
expect_allow "release manager (HIMMEL_RELEASE_MANAGER=1) holding STANDBY, no background task -> allow"
run_guard "$(payload "$T_IDLE")" HIMMEL_RELEASE_MANAGER=0
expect_block "HIMMEL_RELEASE_MANAGER=0 is not a release manager -> block"
run_guard "$(payload "$TMP/absent.jsonl")"
expect_allow "missing transcript -> allow (fail open)"
mkdir -p "$TMP/dir.jsonl"
run_guard "$(payload "$TMP/dir.jsonl")"
expect_allow "transcript scan fails (path is a directory) -> allow, not a 0-task block"
run_guard 'not json'
expect_allow "junk payload -> allow (fail open)"
run_guard ''
expect_allow "empty payload -> allow (fail open)"

release_lock
run_guard "$(payload "$T_IDLE")"
expect_allow "wrapped leg (lock released) -> allow"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
