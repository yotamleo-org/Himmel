#!/usr/bin/env bash
# Smoke test for scripts/hooks/approval-grant-request.sh.
#
# A stub sudo on PATH records its argv and stdin; a stub curl records every bridge send.
# The hook must hand root the refused command's exact bytes on stdin (never on argv),
# print nothing and exit 0 on every path, and make no sudo call when the helper is not
# installed or the tool is not Bash. A pending grant sends its card to the operator's
# bridge chat, a refused one sends one refusal line there, an ask with no chief is refused
# without filing, and a detached waiter posts the expiry. The helper's side runs end to end
# in scripts/lib/test-afk-sudo.sh.
#
# Usage: bash scripts/hooks/test-approval-grant-request.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/approval-grant-request.sh"
FAILED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-grant-request.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/marks" "$TMP/bridge/consoles"
cat > "$TMP/bin/sudo" <<STUB
#!/bin/sh
case " \$* " in
    *" status "*) printf '%s\n' "\$*" >> "$TMP/status.argv"; cat "$TMP/status"; exit 0 ;;
esac
printf '%s\n' "\$*" >> "$TMP/argv"
cat > "$TMP/stdin"
cat "$TMP/reply"
exit \$(cat "$TMP/rc" 2>/dev/null || echo 0)
STUB
cat > "$TMP/bin/curl" <<STUB
#!/bin/sh
cat > /dev/null
[ -f "$TMP/slow" ] && sleep 5
printf '%s\n' "\$*" >> "$TMP/curl"
STUB
chmod 0755 "$TMP/bin/sudo" "$TMP/bin/curl"
printf 'TELEGRAM_BOT_TOKEN=BRIDGETOKEN\n' > "$TMP/bridge.env"
printf '{"operator_id": 4242}\n' > "$TMP/afk-sudo.json"
: > "$TMP/bridge/consoles/boss-chief.md"

CMD='npx --yes cowsay@1.6.0 N4198-probe'
pending() { printf 'result=pending id=abcdefgh expires=%s operator=4242\n' "$(($(date +%s) + ${1:-600}))" > "$TMP/reply"; }
pending
printf 'result=approved\n' > "$TMP/status"

# CONSOLE is the chief name the launcher exports (empty: none); SNAME is the session's own -n name.
CONSOLE=chief-A SNAME='' MARGIN=130
run() {
    local tool=$1 command=$2 marks=${3:-$TMP/marks} reason=${4:-[Code from External] fetches a package}
    jq -n --arg t "$tool" --arg c "$command" --arg r "$reason" '{tool_name:$t,tool_input:{command:$c},session_id:"S1",cwd:"/w",reason:$r}' > "$TMP/payload.json"
    : > "$TMP/argv"; : > "$TMP/curl"; rm -f "$TMP/stdin"
    printf 'claude\0-n\0%s\0' "$SNAME" > "$TMP/cmdline"
    OUT=$(env -u HIMMEL_CONSOLE_NAME -u CLAUDE_PID ${CONSOLE:+HIMMEL_CONSOLE_NAME=$CONSOLE} \
        ${SNAME:+CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE=$TMP/cmdline} \
        PATH="$TMP/bin:$PATH" AFK_GRANT_DIR="$marks" BRIDGE_ROOT="$TMP/bridge" AFK_SUDO_CONFIG="$TMP/afk-sudo.json" \
        TELEGRAM_ENV="$TMP/bridge.env" AFK_SUDO_POLL_S=0.2 AFK_SUDO_WATCH_MARGIN_S="$MARGIN" \
        bash "$HOOK" < "$TMP/payload.json" 2>&1)
    RC=$?
    sleep 0.6  # the bridge sends run detached
    CALLS=$(cat "$TMP/argv")
    SENT=$(cat "$TMP/curl")
}
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; FAILED=1; fi; }
has() { case "$3" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL $1"; echo "  want substring: $2"; echo "  got: $3"; FAILED=1 ;; esac; }
lacks() { case "$3" in *"$2"*) echo "FAIL $1"; echo "  unwanted substring: $2"; echo "  got: $3"; FAILED=1 ;; *) echo "PASS $1" ;; esac; }
lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
quiet() { check "$1: the hook prints nothing" "" "$OUT"; check "$1: the hook exits 0" "0" "$RC"; }
# wait_sent PATTERN: up to 5 s for a bridge send matching PATTERN (the waiter is detached).
wait_sent() { local i=0; while [ $i -lt 25 ]; do grep -qF "$1" "$TMP/curl" 2>/dev/null && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

run Bash "$CMD" "$TMP/absent"
check "helper not installed: no sudo call" "" "$CALLS"
check "helper not installed: no bridge send" "" "$SENT"
quiet "helper not installed"

run Read "$CMD"
check "a non-Bash denial: no sudo call" "" "$CALLS"

run Bash "$CMD"
check "a Bash denial files one grant request" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Code from External] fetches a package" "$CALLS"
check "root gets the exact command bytes on stdin" "$(printf '%s' "$CMD" | sha256sum)" "$(sha256sum < "$TMP/stdin")"
quiet "a pending grant"
check "a pending grant: one bridge send" "1" "$(lines "$SENT")"
has "a pending grant: the card goes to the helper's operator chat" "chat_id=4242" "$SENT"
has "a pending grant: the card names the id, session and chief" "text=AFK grant abcdefgh: read the notice-bot message, then approve · session S1 · chief chief-A" "$SENT"
has "a pending grant: the card carries the Approve button" "afk:approve:abcdefgh" "$SENT"

NO_VERDICT="The server-side auto mode classifier gave no verdict for Bash: another call in this response was changed by a hook after auto mode reviewed it, or could not be confirmed unchanged, so this call's review no longer applies. This is not a judgment that the action is unsafe."
run Bash "$CMD" "$TMP/marks" "$NO_VERDICT"
check "a no-verdict denial: no sudo call" "" "$CALLS"
check "a no-verdict denial: no bridge send" "" "$SENT"
quiet "a no-verdict denial"

run Bash "$CMD" "$TMP/marks" "Classifier unavailable"
check "Classifier unavailable: no sudo call" "" "$CALLS"

run Bash "$CMD" "$TMP/marks" "denied with no category"
check "a reason with no bracketed category: no sudo call" "" "$CALLS"

run Bash "$CMD" "$TMP/marks" "[Credential Exploration] reads a token file"
check "a credential category: no sudo call" "" "$CALLS"
check "a credential category: no bridge send" "" "$SENT"

run Bash "$CMD" "$TMP/marks" "[Unauthorized Persistence] adds a cron job"
check "a real refusal files exactly one request, argv unchanged" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Unauthorized Persistence] adds a cron job" "$CALLS"

printf 'result=busy\n' > "$TMP/reply"; printf '5' > "$TMP/rc"
run Bash "$CMD"
quiet "a refused request"
check "a refused request: one bridge send" "1" "$(lines "$SENT")"
has "a refused request: the refusal goes to the operator chat from the config" "chat_id=4242" "$SENT"
has "a refused request: the line names the session and the result" "text=AFK grant from session S1 (chief chief-A) refused: busy, nothing ran" "$SENT"
lacks "a refused request: no card" "afk:approve" "$SENT"

printf 'result=notice-failed id=abcdefgh\n' > "$TMP/reply"
run Bash "$CMD"
has "a failed notice: the refusal line names the result" "refused: notice-failed, nothing ran" "$SENT"
lacks "a failed notice: no card" "afk:approve" "$SENT"
quiet "a failed notice"

printf 'result=grant-disabled\n' > "$TMP/reply"
run Bash "$CMD"
check "grants off: no bridge send (afk-denied-to-request.sh owns that refusal)" "" "$SENT"
quiet "grants off"
rm -f "$TMP/rc"; pending

CONSOLE='' SNAME=boss-chief
run Bash "$CMD"
check "no chief, the session is a chief: the grant is filed" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Code from External] fetches a package" "$CALLS"
has "no chief, the session is a chief: the card names it as session and chief" "session boss-chief · chief boss-chief" "$SENT"
quiet "a chief's own ask"

CONSOLE='' SNAME=worker-x
run Bash "$CMD"
check "no chief, not a chief: nothing filed" "" "$CALLS"
check "no chief, not a chief: one bridge send" "1" "$(lines "$SENT")"
has "no chief, not a chief: the refusal names the session and the denied tool" "text=AFK grant from session worker-x refused: no chief to route the ask; the denied Bash call [Code from External] was not filed" "$SENT"
has "no chief, not a chief: the refusal goes to the operator chat" "chat_id=4242" "$SENT"
quiet "an unroutable ask"

CONSOLE='' SNAME=''
run Bash "$CMD"
check "no chief, no session name: nothing filed" "" "$CALLS"
has "no chief, no session name: the refusal names the session id" "session S1 refused: no chief to route the ask" "$SENT"
quiet "an unnamed session"

CONSOLE=chief-A SNAME=''
printf 'result=expired\n' > "$TMP/status"
run Bash "$CMD"
quiet "a grant that will expire"
if wait_sent "grant abcdefgh from session S1 (chief chief-A) expired, nothing ran"; then echo "PASS the waiter posts the expiry line"; else echo "FAIL the waiter posts the expiry line"; echo "  got: $(cat "$TMP/curl")"; FAILED=1; fi
has "the expiry line goes to the operator chat" "chat_id=4242" "$(grep -F 'expired, nothing ran' "$TMP/curl")"

printf 'result=pending\n' > "$TMP/status"; : > "$TMP/status.argv"
pending 0; MARGIN=1
run Bash "$CMD"
quiet "a grant still pending at the cap"
sleep 3
c1=$(lines "$(cat "$TMP/status.argv")")
sleep 1.5
c2=$(lines "$(cat "$TMP/status.argv")")
if [ "$c1" -ge 1 ]; then echo "PASS the waiter polls the request status"; else echo "FAIL the waiter polls the request status (no status call)"; FAILED=1; fi
check "the waiter stops at expiry plus its margin" "$c1" "$c2"
lacks "a waiter that hits its cap posts nothing" "expired, nothing ran" "$(cat "$TMP/curl")"

# Last: the slow sends finish after every other row.
touch "$TMP/slow"; MARGIN=130; pending
t0=$(date +%s)
run Bash "$CMD"
t1=$(date +%s)
quiet "a slow bridge"
if [ $((t1 - t0)) -lt 3 ]; then echo "PASS a slow bridge send does not delay the hook"; else echo "FAIL a slow bridge send delays the hook ($((t1 - t0)) s)"; FAILED=1; fi

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAILED"
