#!/usr/bin/env bash
# scripts/luna/vault-stall-chief.sh tells the live chief a vault stall or repair as
# one inbox line, and hands every other case to vault-stall-alert.sh (Telegram).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINK="$ROOT/scripts/luna/vault-stall-chief.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP all — jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-stall-chief.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export VAULT_STALL_ALERT_STATE="$TMP/last-finding"
export FAILURE_ROUTE_SWEEP_CMD="$TMP/sweep.sh"
export FAILURE_ROUTE_INBOX_SEND="$TMP/inbox-send.sh"
export MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh"
export TELEGRAM_ACCESS_PATH="$TMP/access.json"
printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null\n' "$TMP/sweep.txt" >"$TMP/sweep.sh"
# shellcheck disable=SC2016  # the stub's own $1 and $2 stay literal
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >>"%s"\n' "$TMP/inbox.log" >"$TMP/inbox-send.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bad-inbox-send.sh"
printf '#!/usr/bin/env bash\necho swept >>"%s"\n' "$TMP/swept.log" >"$TMP/spy-sweep.sh"
# shellcheck disable=SC2016  # the stub's own $1 and $2 stay literal
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >>"%s"\n' "$TMP/sent.log" >"$TMP/sender.sh"
chmod +x "$TMP/sweep.sh" "$TMP/inbox-send.sh" "$TMP/bad-inbox-send.sh" "$TMP/spy-sweep.sh" "$TMP/sender.sh"
printf '{"allowFrom":["4242"]}\n' >"$TMP/access.json"

CHIEF_LINE='slug=u__himmel__X-chief session=s host=h age=5s status=OK'
count() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
chief_case() {
    local rc=0
    rm -f "$TMP/sent.log" "$TMP/inbox.log" "$VAULT_STALL_ALERT_STATE"
    printf '%s\n' "$2" >"$TMP/sweep.txt"
    HIMMEL_ALERT_KIND="$1" bash "$SINK" "$3" 2>/dev/null || rc=$?
    echo "$rc"
}

rc="$(chief_case cadence:vault-stall "$CHIEF_LINE" "msg one")"
assert_eq "C1 a live chief gets the stall as one inbox line, Telegram is not used, exit 0" \
    "0 1 X-chief|msg one 0" "$rc $(count "$TMP/inbox.log") $(cat "$TMP/inbox.log") $(count "$TMP/sent.log")"
rc="$(chief_case cadence:vault-stall "" "msg two")"
assert_eq "C2 no live chief: Telegram gets it, the inbox nothing" "0 0 1" "$rc $(count "$TMP/inbox.log") $(count "$TMP/sent.log")"
rm -f "$TMP/sent.log" "$TMP/inbox.log" "$VAULT_STALL_ALERT_STATE"
printf '%s\n' "$CHIEF_LINE" >"$TMP/sweep.txt"
rc=0
FAILURE_ROUTE_INBOX_SEND="$TMP/bad-inbox-send.sh" HIMMEL_ALERT_KIND=cadence:vault-stall bash "$SINK" "msg three" 2>/dev/null || rc=$?
assert_eq "C3 a failed inbox send falls through to Telegram" "0 0 1" "$rc $(count "$TMP/inbox.log") $(count "$TMP/sent.log")"
rc="$(chief_case cadence:qmd-reindex "$CHIEF_LINE" "msg four")"
assert_eq "C4 another cadence kind goes to Telegram even with a chief live" "0 0 1" "$rc $(count "$TMP/inbox.log") $(count "$TMP/sent.log")"
rc="$(chief_case cadence:vault-stall-repair "$CHIEF_LINE" "vault-stall REPAIRED: x")"
assert_eq "C5 a stall repair goes to the live chief" \
    "0 1 X-chief|vault-stall REPAIRED: x 0" "$rc $(count "$TMP/inbox.log") $(cat "$TMP/inbox.log") $(count "$TMP/sent.log")"
rc=0
bash "$SINK" 2>/dev/null || rc=$?
assert_eq "C6 empty message: rejected (2)" "2" "$rc"

rm -f "$TMP/sent.log" "$TMP/inbox.log" "$TMP/swept.log"
printf '%s\n' "$CHIEF_LINE" >"$TMP/sweep.txt"
rc=0
env -u MERGE_BLOCK_ALERT_CMD -u FAILURE_ROUTE_INBOX_SEND HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT='' FAILURE_ROUTE_SWEEP_CMD="$TMP/spy-sweep.sh" \
    HIMMEL_ALERT_KIND=cadence:vault-stall bash "$SINK" "from a test" 2>/dev/null || rc=$?
assert_eq "C7 the guard skips the chief (sweep never ran, no inbox) and Telegram's refusal exits 77" \
    "77 0 0" "$rc $(count "$TMP/swept.log") $(count "$TMP/inbox.log")"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "PASS: vault-stall-chief ($0)"; else echo "FAIL: vault-stall-chief — $FAILED failed ($0)" >&2; exit 1; fi
