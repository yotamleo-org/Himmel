#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181 # compact status assertions
# Suite for scripts/hooks/notify-console-on-prompt.sh: a console
# leg's permission_prompt Notification sends ONE debounced line to its console;
# anything else is silent. A stub sender records calls.
# env: HOOK overrides the hook under test (RED run against a tree without it).
#
# bash 3.2-safe. PLATFORM GUARD: Linux-only console-kit surface, no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOK="${HOOK:-$HERE/notify-console-on-prompt.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/notify-prompt.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
CALLS="$T/calls"
# The hook always runs the inbox-send.sh beside it, so the suite installs a copy of the
# hook next to a stub sender.
mkdir -p "$T/inst/scripts/hooks" "$T/inst/scripts/handover/console-kit"
cp "$SRC_HOOK" "$T/inst/scripts/hooks/notify-console-on-prompt.sh" || exit 1
HOOK="$T/inst/scripts/hooks/notify-console-on-prompt.sh"
SEND="$T/inst/scripts/handover/console-kit/inbox-send.sh"
cat > "$SEND" <<'EOS'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"
EOS
export CALLS_FILE="$CALLS"

# fire <notification_type> <session> [ENV=val ...]
fire() {
    local nt="$1" sid="$2"; shift 2
    jq -n --arg nt "$nt" --arg sid "$sid" '{hook_event_name:"Notification",notification_type:$nt,session_id:$sid,cwd:"/w/feat+leg",message:"Claude needs your permission to use Bash: rm secret"}' \
        | env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_NAME HIMMEL_PROMPT_ALERT_DIR="$T/state" "$@" bash "$HOOK" >/dev/null 2>&1
}
count() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }

fire permission_prompt aaaa1111-2222 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console
[ "$(count)" = 1 ] && ok "permission_prompt sends one line" || bad "permission_prompt sends one line"
grep -q '^my-console	PARKED-ON-PROMPT leg=feat+leg session=aaaa1111 ' "$CALLS" && ok "line names console, leg, session prefix" || bad "line names console, leg, session prefix"
grep -q 'secret' "$CALLS" && bad "notification text never forwarded" || ok "notification text never forwarded"

fire permission_prompt aaaa1111-2222 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console
[ "$(count)" = 1 ] && ok "second prompt inside the debounce window is silent" || bad "second prompt inside the debounce window is silent"

fire permission_prompt bbbb3333-4444 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console
[ "$(count)" = 2 ] && ok "another session is not debounced" || bad "another session is not debounced"

fire idle_prompt cccc5555-6666 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console
[ "$(count)" = 2 ] && ok "non-permission notification is silent" || bad "non-permission notification is silent"

fire permission_prompt dddd7777-8888 HIMMEL_CONSOLE_NAME=my-console
[ "$(count)" = 2 ] && ok "non-leg session is silent" || bad "non-leg session is silent"

fire permission_prompt eeee9999-0000 HIMMEL_CONSOLE_LEG=1
[ "$(count)" = 2 ] && ok "no console name is silent" || bad "no console name is silent"

fire permission_prompt aaaa1111-2222 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console HIMMEL_PROMPT_ALERT_DEBOUNCE=0
[ "$(count)" = 3 ] && ok "debounce 0 re-sends" || bad "debounce 0 re-sends"

# The sender is not retargetable from the environment.
printf '#!/usr/bin/env bash\ntouch "%s/canary"\n' "$T" > "$T/canary-send.sh"
fire permission_prompt gggg2222-3333 HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console "HIMMEL_INBOX_SEND=$T/canary-send.sh"
[ ! -e "$T/canary" ] && [ "$(count)" = 4 ] && ok "HIMMEL_INBOX_SEND is not honoured" || bad "HIMMEL_INBOX_SEND is not honoured"

# A leg directory name with shell or markup characters never reaches the console line.
jq -n '{notification_type:"permission_prompt",session_id:"hhhh4444-5555",cwd:"/w/le g;$(id)"}' \
    | env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console HIMMEL_PROMPT_ALERT_DIR="$T/state" bash "$HOOK" >/dev/null 2>&1
grep -q 'leg=unknown session=hhhh4444 ' "$CALLS" && ok "unsafe leg name is replaced" || bad "unsafe leg name is replaced"

printf '#!/usr/bin/env bash\nexit 1\n' > "$SEND"
jq -n '{notification_type:"permission_prompt",session_id:"ffff0000-1111",cwd:"/w/x"}' \
    | env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=my-console HIMMEL_PROMPT_ALERT_DIR="$T/state" bash "$HOOK" >/dev/null 2>&1
[ ! -e "$T/state/ffff0000-1111" ] && ok "failed delivery does not start the debounce window" || bad "failed delivery does not start the debounce window"

printf 'not json' | env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=c bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "malformed stdin exits 0" || bad "malformed stdin exits 0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
