#!/usr/bin/env bash
# Smoke test for scripts/hooks/approval-grant-request.sh.
#
# A stub sudo on PATH records its argv and stdin. The hook must hand root the refused
# command's exact bytes on stdin (never on argv), print nothing and exit 0 on every path,
# and make no sudo call when the helper is not installed or the tool is not Bash. The
# helper's side runs end to end in scripts/lib/test-afk-sudo.sh.
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
    *" status "*) printf '%s\n' "\$*" >> "$TMP/status.argv"; s=\$(cat "$TMP/status"); printf '%s\n' "\$s"; case "\$s" in result=unknown*) echo 1 > "$TMP/status.released" ;; esac; exit \$(cat "$TMP/status.rc" 2>/dev/null || echo 0) ;;
    *" mode "*) cat "$TMP/mode"; exit 0 ;;
esac
printf '%s\n' "\$*" >> "$TMP/argv"
cat > "$TMP/stdin"
if [ -f "$TMP/oldhelper" ]; then case " \$* " in *" --desc="*) echo "afk-sudo: unrecognized arguments" >&2; exit 2 ;; esac; fi
cat "$TMP/reply"
exit \$(cat "$TMP/rc" 2>/dev/null || echo 0)
STUB
cat > "$TMP/bin/curl" <<STUB
#!/bin/sh
cat > /dev/null
[ -f "$TMP/slow" ] && sleep 5
printf '%s\n' "\$*" >> "$TMP/curl"
STUB
cat > "$TMP/bin/outbox" <<STUB
#!/bin/sh
printf 'chat=%s kind=%s text=%s\n' "\$1" "\$3" "\$2" >> "$TMP/outbox"
STUB
chmod 0755 "$TMP/bin/sudo" "$TMP/bin/curl" "$TMP/bin/outbox"
printf 'TELEGRAM_BOT_TOKEN=BRIDGETOKEN\n' > "$TMP/bridge.env"
printf '{"operator_id": 4242}\n' > "$TMP/afk-sudo.json"
: > "$TMP/bridge/consoles/boss-chief.md"
: > "$TMP/bridge/consoles/chief-A.md"

CMD='npx --yes cowsay@1.6.0 N4198-probe'
pending() { printf 'result=pending id=abcdefgh expires=%s operator=4242\n' "$(($(date +%s) + ${1:-600}))" > "$TMP/reply"; }
pending
printf 'result=approved\n' > "$TMP/status"
grants() { printf 'result=mode mode=all enabled=%s run_enabled=true classifier_requests=true grant_enabled=%s\n' "$1" "$2" > "$TMP/mode"; }
grants true true

CHIEF_ENV=chief-A SESSION_N_NAME='' MARGIN=130
settle_detached() { sleep 0.6; }
run() {
    local tool=$1 command=$2 marks=${3:-$TMP/marks} reason=${4:-[Code from External] fetches a package}
    jq -n --arg t "$tool" --arg c "$command" --arg r "$reason" --arg d "${GDESC:-}" \
        '{tool_name:$t,tool_input:({command:$c}+(if $d == "" then {} else {description:$d} end)),session_id:"S1",cwd:"/w",reason:$r}' > "$TMP/payload.json"
    : > "$TMP/argv"; : > "$TMP/curl"; : > "$TMP/outbox"; rm -f "$TMP/stdin"
    for f in "$TMP"/bridge/consoles/*.md; do : > "$f"; done
    printf 'claude\0-n\0%s\0' "$SESSION_N_NAME" > "$TMP/cmdline"
    OUT=$(env -u HIMMEL_CONSOLE_NAME -u CLAUDE_PID ${CHIEF_ENV:+HIMMEL_CONSOLE_NAME=$CHIEF_ENV} \
        ${SESSION_N_NAME:+CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE=$TMP/cmdline} \
        PATH="$TMP/bin:$PATH" AFK_GRANT_DIR="$marks" BRIDGE_ROOT="$TMP/bridge" AFK_SUDO_CONFIG="$TMP/afk-sudo.json" \
        TELEGRAM_ENV="$TMP/bridge.env" AFK_SUDO_POLL_S=0.2 AFK_SUDO_WATCH_MARGIN_S="$MARGIN" \
        MERGE_BLOCK_ALERT_CMD="$TMP/bin/outbox" \
        bash "$HOOK" < "$TMP/payload.json" 2>&1)
    RC=$?
    settle_detached
    CALLS=$(cat "$TMP/argv")
    SENT=$(cat "$TMP/curl")
    BOX=$(cat "$TMP/outbox")
}
inbox() { cat "$TMP/bridge/consoles/$1.md"; }
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; FAILED=1; fi; }
has() { case "$3" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL $1"; echo "  want substring: $2"; echo "  got: $3"; FAILED=1 ;; esac; }
lacks() { case "$3" in *"$2"*) echo "FAIL $1"; echo "  unwanted substring: $2"; echo "  got: $3"; FAILED=1 ;; *) echo "PASS $1" ;; esac; }
lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
quiet() { check "$1: the hook prints nothing" "" "$OUT"; check "$1: the hook exits 0" "0" "$RC"; }
wait_sent() { local i=0; while [ $i -lt 25 ]; do grep -qF "$1" "$TMP/outbox" 2>/dev/null && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }

run Bash "$CMD" "$TMP/absent"
check "helper not installed: no sudo call" "" "$CALLS"
check "helper not installed: no bridge send" "" "$SENT"
quiet "helper not installed"

run Read "$CMD"
check "a non-Bash denial: no sudo call" "" "$CALLS"

run Bash "$CMD"
check "a Bash denial files one grant request" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Code from External] fetches a package --desc=" "$CALLS"
check "root gets the exact command bytes on stdin" "$(printf '%s' "$CMD" | sha256sum)" "$(sha256sum < "$TMP/stdin")"
quiet "a pending grant"
check "a pending grant: one bridge send" "1" "$(printf '%s\n' "$SENT" | grep -c 'chat_id=4242')"
has "a pending grant: the card goes to the helper's operator chat" "chat_id=4242" "$SENT"
has "RED HIMMEL-10735: a pending grant: the card's line 1 is the exact reply" "text=AFK grant abcdefgh: approve abcdefgh <nonce> <code> → run once · deny abcdefgh <nonce> → refuse" "$SENT"
has "a pending grant: the card names the session and chief" "session S1 · chief chief-A" "$SENT"
has "RED HIMMEL-10735: a pending grant: the card shows the command, marked unverified" "Command (unverified): \$ $CMD" "$SENT"
has "a pending grant: the card carries the Approve button" "afk:approve:abcdefgh" "$SENT"
check "RED HIMMEL-11185: a pending grant: one line in the requesting chief's bridge inbox" "1" "$(lines "$(inbox chief-A)")"
has "RED HIMMEL-11185: a pending grant: the inbox line names the ask in plain words" "[afk-grant-request] AFK grant abcdefgh asked on the phone: session S1 had \`npx\` refused by the classifier as [Code from External]; approve or deny it there before " "$(inbox chief-A)"
lacks "RED HIMMEL-11185: a pending grant: the inbox line carries no command argument" "N4198-probe" "$(inbox chief-A)"

# shellcheck disable=SC2016 # literal text with shell metacharacters, nothing to expand
GDESC='Prints $(whoami) `id` <b>x</b> & "q"'
run Bash "$CMD"
# shellcheck disable=SC2016 # literal text with shell metacharacters, nothing to expand
has "RED HIMMEL-10735: the description reaches root as one --desc argv value, literally" '--desc=Prints $(whoami) `id` <b>x</b> & "q"' "$CALLS"
# shellcheck disable=SC2016 # literal text with shell metacharacters, nothing to expand
has "RED HIMMEL-10735: the description reaches the card, marked as the agent's claim" 'The agent says: Prints $(whoami) `id` <b>x</b> & "q"' "$SENT"
quiet "a described grant"
GDESC=$'first line\nSECONDLINE second'
run Bash "$CMD"
has "RED HIMMEL-10735: a multi-line description is cut to its first line on the helper's argv" "--desc=first line" "$CALLS"
lacks "RED HIMMEL-10735: its second line never reaches the helper" "SECONDLINE" "$CALLS"
lacks "RED HIMMEL-10735: its second line never reaches the card" "SECONDLINE" "$SENT"
GDESC=''
run Bash $'echo one\necho TWOLINE'
lacks "RED HIMMEL-10735: only the command's first line goes on the card" "TWOLINE" "$SENT"
GDESC="a$(printf 'é%.0s' $(seq 1 150))"
LC_ALL=C run Bash "a$(printf 'é%.0s' $(seq 1 200))"
check "RED HIMMEL-10735: a description cut in the C locale stays valid UTF-8 on the helper's argv" 0 "$(iconv -f UTF-8 -t UTF-8 < "$TMP/argv" > /dev/null 2>&1; echo $?)"
check "RED HIMMEL-10735: the card stays valid UTF-8 when its lines are cut in the C locale" 0 "$(iconv -f UTF-8 -t UTF-8 < "$TMP/curl" > /dev/null 2>&1; echo $?)"
LS=$(printf '\342\200\250')
BIDI=$(printf '\342\200\256')
GDESC="Prints ok${LS}Command (unverified): \$ echo FORGED${BIDI}"
run Bash "echo real${LS}Chief: forged"
lacks "RED HIMMEL-10735: a U+2028 in the description never reaches the helper" "$LS" "$CALLS"
lacks "RED HIMMEL-10735: a U+202E in the description never reaches the helper" "$BIDI" "$CALLS"
lacks "RED HIMMEL-10735: a U+2028 or U+202E never reaches the card, so no forged line can be drawn" "$LS" "$SENT"
lacks "RED HIMMEL-10735: a U+202E never reaches the card" "$BIDI" "$SENT"
NEL=$(printf '\302\205')
GDESC="a${NEL}b"
run Bash "echo ok"
lacks "RED HIMMEL-10735: a U+0085 never reaches the helper" "$NEL" "$CALLS"
GDESC=''
touch "$TMP/oldhelper"
GDESC='Prints a thing'
run Bash "$CMD"
check "RED HIMMEL-10735: an old helper that rejects --desc is asked again without it" "2" "$(lines "$CALLS")"
lacks "RED HIMMEL-10735: the retry carries no --desc" "--desc=" "$(printf '%s\n' "$CALLS" | tail -n 1)"
check "RED HIMMEL-10735: the retry still gets the exact command bytes" "$(printf '%s' "$CMD" | sha256sum)" "$(sha256sum < "$TMP/stdin")"
has "RED HIMMEL-10735: the card still goes out after the retry" "afk:approve:abcdefgh" "$SENT"
quiet "an old helper"
rm -f "$TMP/oldhelper"
GDESC=''
run Bash $'echo one\necho TWOLINE'
check "RED HIMMEL-10735: root still gets every command byte on stdin" "$(printf '%s' $'echo one\necho TWOLINE' | sha256sum)" "$(sha256sum < "$TMP/stdin")"

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
check "a real refusal files exactly one request, argv unchanged" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Unauthorized Persistence] adds a cron job --desc=" "$CALLS"

printf 'result=busy\n' > "$TMP/reply"; printf '5' > "$TMP/rc"
run Bash "$CMD"
quiet "a refused request"
check "RED HIMMEL-10845: a refused request: no direct Telegram call" "" "$SENT"
check "RED HIMMEL-10845: a refused request: one outbox line" "1" "$(lines "$BOX")"
has "RED HIMMEL-10845: a refused request: the refusal goes to the outbox as kind afk-grant-refused, to the operator chat from the config" "chat=4242 kind=afk-grant-refused " "$BOX"
has "RED HIMMEL-10845: a refused request: the line says no ask was sent" "no ask was sent and nothing ran" "$BOX"
has "a refused request: the line names the session, the chief and the result" "session S1 (chief chief-A)" "$BOX"
has "a refused request: the line names the helper's result" "(busy)" "$BOX"
has "RED HIMMEL-10845: a refused request: the line names the refused command's head and its category" "had \`npx\` refused by the classifier as [Code from External]" "$BOX"
run Bash "python3 -c 'print(SECRET_VALUE)'"
lacks "RED HIMMEL-10845: a runner's inline code never reaches the line" "SECRET_VALUE" "$BOX"
has "RED HIMMEL-10845: a runner with a flag names the runner only" "had \`python3\`" "$BOX"
run Bash "bash 'SECRET_VALUE x'"
lacks "RED HIMMEL-10845: a quoted word after a runner never reaches the line" "SECRET_VALUE" "$BOX"
run Bash $'\n  npx cowsay'
has "RED HIMMEL-10845: a command that starts with a blank line still names its program" "had \`npx cowsay\`" "$BOX"
run Bash "TOKEN=SECRET_VALUE env OTHER=SECRET_VALUE curl https://h/x"
lacks "RED HIMMEL-10845: an assignment never reaches the line" "SECRET_VALUE" "$BOX"
has "RED HIMMEL-10845: assignments are skipped to the program" "had \`env curl\`" "$BOX"
has "RED HIMMEL-10845: a refused request: the chief's bridge inbox gets the same line" "[afk-grant-refused] AFK grant refused" "$(inbox chief-A)"

printf 'result=notice-failed id=abcdefgh\n' > "$TMP/reply"
run Bash "$CMD"
has "a failed notice: the refusal line says the ask could not reach the phone" "could not send the ask to the phone" "$BOX"
lacks "a failed notice: no card" "afk:approve" "$SENT"
quiet "a failed notice"

printf 'result=never-remote rule=guards-off\n' > "$TMP/reply"
: > "$TMP/bridge/consoles/chief-B.md"
printf 'chief-B\n' > "$TMP/bridge/consoles/chief-A.md.handover"
run Bash 'bash /h/scripts/handover/chief-kit/append-results.sh /h/doc.md "RESOLVED - SECRETWORD"' "$TMP/marks" "[Undermining Oversight] edits a results doc"
quiet "a never-remote refusal"
check "RED HIMMEL-10845: a never-remote refusal: no direct Telegram call" "" "$SENT"
has "RED HIMMEL-10845: a never-remote refusal names the current chief, after the succession" "(chief chief-B)" "$BOX"
lacks "RED HIMMEL-10845: a never-remote refusal does not name the launching chief" "chief-A" "$BOX"
has "RED HIMMEL-10845: a never-remote refusal names the command head" "had \`bash append-results.sh\` refused by the classifier as [Undermining Oversight]" "$BOX"
lacks "RED HIMMEL-10845: a never-remote refusal never carries the command's arguments" "SECRETWORD" "$BOX"
has "RED HIMMEL-10845: a never-remote refusal says it can never be approved from the phone" "rule guards-off covers it, so it can never be approved from the phone" "$BOX"
has "RED HIMMEL-10845: a never-remote refusal says the worker must take another route and its chief is told" "the worker must take another route; its chief is told" "$BOX"
has "RED HIMMEL-10845: the current chief's bridge inbox gets the line" "(chief chief-B)" "$(inbox chief-B)"
check "RED HIMMEL-10845: the launching chief's inbox gets nothing" "" "$(inbox chief-A)"

pending
run Bash "$CMD"
has "RED HIMMEL-10845: a pending grant's card names the current chief" "chief chief-B" "$SENT"
has "RED HIMMEL-11185: a pending grant's inbox line goes to the current chief" "[afk-grant-request] AFK grant abcdefgh" "$(inbox chief-B)"
check "RED HIMMEL-11185: the launching chief's inbox gets no request line" "" "$(inbox chief-A)"

printf 'chief-gone\n' > "$TMP/bridge/consoles/chief-A.md.handover"
printf 'result=busy\n' > "$TMP/reply"
run Bash "$CMD"
has "RED HIMMEL-10845: a successor with no bridge inbox is not followed" "(chief chief-A)" "$BOX"
printf 'chief-A\n' > "$TMP/bridge/consoles/chief-B.md.handover"
printf 'chief-B\n' > "$TMP/bridge/consoles/chief-A.md.handover"
run Bash "$CMD"
quiet "a handover loop"
has "RED HIMMEL-10845: a handover loop ends at one chief" "kind=afk-grant-refused" "$BOX"
rm -f "$TMP/bridge/consoles/chief-A.md.handover" "$TMP/bridge/consoles/chief-B.md.handover" "$TMP/bridge/consoles/chief-B.md"

printf 'OUTSIDE\n' > "$TMP/bridge/x.md"
CHIEF_ENV=../x run Bash "$CMD"
quiet "a chief name that is a path"
check "RED HIMMEL-10845: a chief name that is a path never appends to a file outside the bridge inboxes" "OUTSIDE" "$(cat "$TMP/bridge/x.md")"
printf 'OUTSIDE\n' > "$TMP/bridge/x.md"
printf '../x\n' > "$TMP/bridge/consoles/chief-A.md.handover"
run Bash "$CMD"
check "RED HIMMEL-10845: a handover marker naming a path never appends outside the bridge inboxes" "OUTSIDE" "$(cat "$TMP/bridge/x.md")"
has "RED HIMMEL-10845: a handover marker naming a path is not followed" "(chief chief-A)" "$BOX"
rm -f "$TMP/bridge/consoles/chief-A.md.handover" "$TMP/bridge/x.md"

printf 'result=grant-disabled\n' > "$TMP/reply"
run Bash "$CMD"
check "grants off: no bridge send (afk-denied-to-request.sh owns that refusal)" "" "$SENT"
quiet "grants off"

printf 'result=disabled\n' > "$TMP/reply"
run Bash "$CMD"
check "a station locked down: no bridge send" "" "$SENT"
quiet "a station locked down"
rm -f "$TMP/rc"; pending

CHIEF_ENV='' SESSION_N_NAME=boss-chief
run Bash "$CMD"
check "no chief, the session is a chief: the grant is filed" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Code from External] fetches a package --desc=" "$CALLS"
has "no chief, the session is a chief: the card names it as session and chief" "session boss-chief · chief boss-chief" "$SENT"
quiet "a chief's own ask"
: > "$TMP/bridge/consoles/boss2-chief.md"
printf 'boss2-chief\n' > "$TMP/bridge/consoles/boss-chief.md.handover"
run Bash "$CMD"
has "RED HIMMEL-10845: a chief that handed over names its successor as chief" "session boss-chief · chief boss2-chief" "$SENT"
rm -f "$TMP/bridge/consoles/boss-chief.md.handover" "$TMP/bridge/consoles/boss2-chief.md"

CHIEF_ENV='' SESSION_N_NAME=worker-x
run Bash "$CMD"
check "no chief, not a chief: nothing filed" "" "$CALLS"
check "RED HIMMEL-10845: no chief, not a chief: no direct Telegram call" "" "$SENT"
check "no chief, not a chief: one outbox line" "1" "$(lines "$BOX")"
has "RED HIMMEL-10845: no chief, not a chief: the refusal says no ask was sent, and why" "text=AFK grant from session worker-x refused, no ask was sent: the session has no chief to route the ask to, so the denied call \`npx\` [Code from External] was not filed" "$BOX"
has "RED HIMMEL-10845: no chief, not a chief: the refusal goes to the outbox as kind afk-grant-refused, to the operator chat" "chat=4242 kind=afk-grant-refused " "$BOX"
quiet "an unroutable ask"

CHIEF_ENV='' SESSION_N_NAME=''
run Bash "$CMD"
check "no chief, no session name: nothing filed" "" "$CALLS"
has "no chief, no session name: the refusal names the session id" "session S1 refused, no ask was sent: the session has no chief" "$BOX"
quiet "an unnamed session"

grants true false
run Bash "$CMD"
check "no chief, grants off: nothing filed" "" "$CALLS"
check "no chief, grants off: no refusal line (afk-denied-to-request.sh may still file it)" "" "$SENT$BOX"
quiet "no chief, grants off"

grants false true
run Bash "$CMD"
check "no chief, station locked down: no refusal line" "" "$SENT$BOX"
quiet "no chief, station locked down"

printf '' > "$TMP/mode"
run Bash "$CMD"
check "no chief, the helper does not answer mode: no refusal line" "" "$SENT$BOX"
grants true true

CHIEF_ENV=chief-A SESSION_N_NAME=''
printf 'result=expired\n' > "$TMP/status"
run Bash "$CMD"
quiet "a grant that will expire"
if wait_sent "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) expired, nothing ran"; then echo "PASS the waiter posts the expiry line"; else echo "FAIL the waiter posts the expiry line"; echo "  got: $(cat "$TMP/outbox")"; FAILED=1; fi
has "RED HIMMEL-10845: the expiry line goes to the outbox as kind afk-grant-expired, to the operator chat" "chat=4242 kind=afk-grant-expired " "$(grep -F 'expired, nothing ran' "$TMP/outbox")"
lacks "RED HIMMEL-10845: the expiry line is no direct Telegram call" "expired, nothing ran" "$(cat "$TMP/curl")"
check "RED HIMMEL-11185: an expired grant: one outcome line on Telegram" "1" "$(grep -c 'kind=afk-grant-' "$TMP/outbox")"
has "RED HIMMEL-11185: an expired grant: the Telegram line names what it was for" "for \`npx\` [Code from External] from session S1" "$(grep -F 'expired, nothing ran' "$TMP/outbox")"
check "RED HIMMEL-11185: an expired grant: one outcome line in the chief's bridge inbox" "1" "$(grep -c '\[afk-grant-expired\]' "$TMP/bridge/consoles/chief-A.md")"
has "RED HIMMEL-11185: an expired grant: the inbox line names what it was for" "[afk-grant-expired] grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) expired, nothing ran" "$(inbox chief-A)"

: > "$TMP/bridge/consoles/chief-B.md"
printf 'chief-B\n' > "$TMP/bridge/consoles/chief-A.md.handover"
run Bash "$CMD"
if wait_sent "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-B) expired, nothing ran"; then echo "PASS RED HIMMEL-10845: the expiry line names the current chief"; else echo "FAIL RED HIMMEL-10845: the expiry line names the current chief"; echo "  got: $(cat "$TMP/outbox")"; FAILED=1; fi
rm -f "$TMP/bridge/consoles/chief-A.md.handover" "$TMP/bridge/consoles/chief-B.md"

printf 'result=pending\n' > "$TMP/status"
run Bash "$CMD"
: > "$TMP/bridge/consoles/chief-C.md"
printf 'chief-C\n' > "$TMP/bridge/consoles/chief-A.md.handover"
printf 'result=expired\n' > "$TMP/status"
if wait_sent "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-C) expired, nothing ran"; then echo "PASS RED HIMMEL-10845: a succession while the grant is pending moves the expiry line to the new chief"; else echo "FAIL RED HIMMEL-10845: a succession while the grant is pending moves the expiry line to the new chief"; echo "  got: $(cat "$TMP/outbox")"; FAILED=1; fi
has "RED HIMMEL-11185: a succession while the grant is pending moves the inbox outcome line to the new chief" "[afk-grant-expired] grant abcdefgh" "$(inbox chief-C)"
rm -f "$TMP/bridge/consoles/chief-A.md.handover" "$TMP/bridge/consoles/chief-C.md"

outcome() {
    local status=$1 kind=$2 text=$3 name=$4
    printf '%s\n' "$status" > "$TMP/status"
    run Bash "$CMD"
    quiet "$name"
    if wait_sent "$text"; then echo "PASS RED HIMMEL-11185: $name: one Telegram outcome line"; else echo "FAIL RED HIMMEL-11185: $name: one Telegram outcome line"; echo "  got: $(cat "$TMP/outbox")"; FAILED=1; fi
    has "RED HIMMEL-11185: $name: the Telegram line goes to the operator chat as kind $kind" "chat=4242 kind=$kind text=$text" "$(cat "$TMP/outbox")"
    check "RED HIMMEL-11185: $name: exactly one outcome line on Telegram" "1" "$(grep -c 'kind=afk-grant-' "$TMP/outbox")"
    has "RED HIMMEL-11185: $name: the chief's bridge inbox gets the same line" "[$kind] $text" "$(inbox chief-A)"
    lacks "RED HIMMEL-11185: $name: the outcome is no direct Telegram call" "$text" "$(cat "$TMP/curl")"
}
outcome "result=granted id=abcdefgh" afk-grant-approved "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) approved: that session's next identical call runs once" "an approved grant"
outcome "result=denied id=abcdefgh" afk-grant-denied "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) denied, nothing ran" "a denied grant"
outcome "result=denied:bad-nonce id=abcdefgh" afk-grant-denied "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) denied, nothing ran" "a grant denied on a wrong nonce"
outcome "result=refused:never-remote id=abcdefgh" afk-grant-denied "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) approved but refused by the helper (never-remote), nothing ran" "a grant refused after approval"
printf 'result=running id=abcdefgh\n' > "$TMP/status"
run Bash "$CMD"
sleep 0.6
printf 'result=granted id=abcdefgh\n' > "$TMP/status"
if wait_sent "approved: that session's next identical call runs once"; then echo "PASS RED HIMMEL-11185: a grant seen running keeps the waiter until its outcome"; else echo "FAIL RED HIMMEL-11185: a grant seen running keeps the waiter until its outcome"; echo "  got: $(cat "$TMP/outbox")"; FAILED=1; fi
printf 'result=unknown id=abcdefgh\n' > "$TMP/status"
run Bash "$CMD"
sleep 0.6
check "RED HIMMEL-11185: an unknown status posts no outcome" "" "$(cat "$TMP/outbox")"

: > "$TMP/status"
run Bash "$CMD"
quiet "a status query that fails first"
printf 'result=expired\n' > "$TMP/status"
if wait_sent "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) expired, nothing ran"; then echo "PASS a failed status query does not end the waiter"; else echo "FAIL a failed status query does not end the waiter"; FAILED=1; fi

wait_nonempty() { local end=$(($(date +%s) + $2)); while [ ! -s "$1" ] && [ "$(date +%s)" -le "$end" ]; do sleep 0.2; done; }
poll_row() {
    local c1
    wait_nonempty "$TMP/status.argv" "$1"
    c1=$(lines "$(cat "$TMP/status.argv")")
    if [ "$c1" -ge 1 ]; then echo "PASS the waiter polls the request status"; else echo "FAIL the waiter polls the request status (no status call)"; FAILED=1; fi
}
cap_row() {
    if [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then echo "SKIP cap row not exercised: waiter missed its window"; else check "the waiter stops at expiry plus its margin" "$1" "$2"; fi
}

printf 'result=pending\n' > "$TMP/status"; : > "$TMP/status.argv"
pending 0; MARGIN=130
run Bash "$CMD"
poll_row 20
rm -f "$TMP/status.released"
printf 'result=unknown\n' > "$TMP/status"
wait_nonempty "$TMP/status.released" 20
check "the poll row's waiter has exited before the cap case" "1" "$(cat "$TMP/status.released" 2>/dev/null)"

printf 'result=pending\n' > "$TMP/status"; : > "$TMP/status.argv"
pending 0; MARGIN=1
run Bash "$CMD"
quiet "a grant still pending at the cap"
sleep 3
c1=$(lines "$(cat "$TMP/status.argv")")
sleep 1.5
c2=$(lines "$(cat "$TMP/status.argv")")
cap_row "$c1" "$c2"
lacks "a waiter that hits its cap posts nothing" "expired, nothing ran" "$(cat "$TMP/curl" "$TMP/outbox")"

: > "$TMP/status.argv"
pending -10
run Bash "$CMD"
check "control: a waiter that never polls fails the poll row" "FAIL the waiter polls the request status (no status call)" "$(poll_row 2)"
c1=$(lines "$(cat "$TMP/status.argv")")
check "control: a waiter that never polls leaves the cap row not exercised" "SKIP cap row not exercised: waiter missed its window" "$(cap_row "$c1" "$c1")"

MARGIN=130; pending
printf 'result=error OSError\n' > "$TMP/status"; printf '5' > "$TMP/status.rc"
run Bash "$CMD"
quiet "a status query the helper cannot answer"
printf 'result=expired\n' > "$TMP/status"; rm -f "$TMP/status.rc"
if wait_sent "grant abcdefgh for \`npx\` [Code from External] from session S1 (chief chief-A) expired, nothing ran"; then echo "PASS a status query the helper cannot answer does not end the waiter"; else echo "FAIL a status query the helper cannot answer does not end the waiter"; FAILED=1; fi

touch "$TMP/slow"; printf 'result=approved\n' > "$TMP/status"
t0=$(date +%s)
run Bash "$CMD"
t1=$(date +%s)
quiet "a slow bridge"
if [ $((t1 - t0)) -lt 3 ]; then echo "PASS a slow bridge send does not delay the hook"; else echo "FAIL a slow bridge send delays the hook ($((t1 - t0)) s)"; FAILED=1; fi

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAILED"
