#!/usr/bin/env bash
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$KIT/ask-mirror.sh"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fi
}

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-ask-mirror.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
HANDOVER_DIR="$TMP/handover"; XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$HANDOVER_DIR/.locks/queue" "$XDG_RUNTIME_DIR/himmel-queue-lock"
export HANDOVER_DIR XDG_RUNTIME_DIR

CHIEF_DOC="$HANDOVER_DIR/FIX-nextleg-chief.md"
WORKER_DOC="$HANDOVER_DIR/FIX-worker-W1.md"
printf 'chief doc\n' > "$CHIEF_DOC"; printf 'worker doc\n' > "$WORKER_DOC"
mkdir -p "$HANDOVER_DIR/.locks/queue/FIX-nextleg-chief.lock" "$HANDOVER_DIR/.locks/queue/FIX-worker-W1.lock"
printf '{"handover":"%s"}\n' "$CHIEF_DOC" > "$HANDOVER_DIR/.locks/queue/FIX-nextleg-chief.lock/owner.json"
printf '{"handover":"%s"}\n' "$WORKER_DOC" > "$HANDOVER_DIR/.locks/queue/FIX-worker-W1.lock/owner.json"
: > "$XDG_RUNTIME_DIR/himmel-queue-lock/$(digest_of "chief-sid|$CHIEF_DOC").tok"
: > "$XDG_RUNTIME_DIR/himmel-queue-lock/$(digest_of "worker-sid|$WORKER_DOC").tok"

CALLS="$TMP/calls.log"
STUB="$TMP/route-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
out=""; for a in "$@"; do out="$out|$(printf '%s' "$a" | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//')"; done
printf '%s\n' "${out#|}" | sed -E 's/\|ask-[0-9a-f]{16}/|ask-K/' >> "$ASK_MIRROR_TEST_CALLS"
[ "${ASK_MIRROR_TEST_FAIL:-0}" = 1 ] && { echo "stub: send failed" >&2; exit 1; }
echo escalate
EOF
chmod +x "$STUB"
export ASK_MIRROR_ROUTE="$STUB" ASK_MIRROR_TEST_CALLS="$CALLS"

payload() { jq -cn --arg s "$1" --arg m "$2" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:$m}'; }
run() { : > "$CALLS"; payload "$1" "$2" | bash "$SCRIPT" > "$TMP/out"; echo "rc=$?" > "$TMP/rc"; }
ncalls() { if [ -s "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }

ASK='Status: two PRs merged.

Needs you: approve the bypass for the station restart. Blocks: the bridge fix.
Reply yes to run it.

Done for now.'

echo "R1: a chief reply with a Needs you: block posts it"
run chief-sid "$ASK"
check "R1 rc 0" "$(cat "$TMP/rc")" "rc=0"
check "R1 stdout stays empty" "$(cat "$TMP/out")" ""
check "R1 one post" "$(ncalls)" "1"
check "R1 posted the block as written, kind chief-reply, to operator" "$(cat "$CALLS")" \
    "reply|--chief|FIX-nextleg-chief|--owed|ask-K|--doc|$CHIEF_DOC|--kind|chief-reply|operator|Needs you: approve the bypass for the station restart. Blocks: the bridge fix.\nReply yes to run it."

echo "R2: a reply with no ask posts nothing"
run chief-sid "All merged. Waiting on two workers."
check "R2 no post" "$(ncalls)" "0"

echo "R3: the same ask twice posts once"
run chief-sid "$ASK"
check "R3 repeat posts nothing" "$(ncalls)" "0"

echo "R4: a changed ask is sent again"
run chief-sid "Needs you: approve the bypass for the station restart, now for two hosts."
check "R4 changed ask posts" "$(ncalls)" "1"

echo "R5: a worker session posts nothing"
run worker-sid "Needs you: something a worker wrote."
check "R5 worker posts nothing" "$(ncalls)" "0"
run judge-sid "Needs you: something a judge wrote."
check "R5 unknown session posts nothing" "$(ncalls)" "0"

echo "R6: a code goes alone in its own message right after the ask"
CODE_ASK='Needs you: type this code to approve the merge.

```
GO-7731
```'
run chief-sid "$CODE_ASK"
check "R6 two posts" "$(ncalls)" "2"
check "R6 first is the ask without the code" "$(sed -n 1p "$CALLS")" \
    "reply|--chief|FIX-nextleg-chief|--owed|ask-K|--doc|$CHIEF_DOC|--kind|chief-reply|operator|Needs you: type this code to approve the merge."
check "R6 second is the code alone" "$(sed -n 2p "$CALLS")" \
    "reply|--chief|FIX-nextleg-chief|--owed|ask-K-code|--doc|$CHIEF_DOC|--kind|chief-reply|operator|GO-7731"

echo "R7: a failed post leaves an owed row and is retried next time"
export ASK_MIRROR_TEST_FAIL=1
run chief-sid "Needs you: sign the release notes."
check "R7 rc 0 (never blocks the stop)" "$(cat "$TMP/rc")" "rc=0"
check "R7 tried once" "$(ncalls)" "1"
owed="$HANDOVER_DIR/owed.jsonl"
check "R7 owed row written in the chief's bucket" \
    "$(jq -r 'select(.op=="add") | .kind + " " + .chief + " " + .text' "$owed" 2>/dev/null)" \
    "step FIX-nextleg-chief Telegram ask not delivered, check the bridge: Needs you: sign the release notes."
run chief-sid "Needs you: sign the release notes."
check "R7 retry adds no second owed row" "$(jq -r 'select(.op=="add") | .id' "$owed" 2>/dev/null | wc -l | tr -d ' ')" "1"
unset ASK_MIRROR_TEST_FAIL
run chief-sid "Needs you: sign the release notes."
check "R7 posts once the send works" "$(ncalls)" "1"

echo "R8: with no last_assistant_message the reply is read from the transcript"
TR="$TMP/transcript.jsonl"
{
    jq -cn '{type:"user", message:{role:"user", content:"status?"}}'
    jq -cn '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Checking."},{type:"tool_use", id:"t1", name:"Bash", input:{}}]}}'
    jq -cn '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"ok"}]}}'
    jq -cn '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Needs you: pick the release day."}]}}'
} > "$TR"
: > "$CALLS"
jq -cn --arg t "$TR" '{session_id:"chief-sid", hook_event_name:"Stop", stop_hook_active:false, transcript_path:$t}' | bash "$SCRIPT"
check "R8 transcript ask posted" "$(cat "$CALLS")" \
    "reply|--chief|FIX-nextleg-chief|--owed|ask-K|--doc|$CHIEF_DOC|--kind|chief-reply|operator|Needs you: pick the release day."

echo "R9: junk payload exits 0 and posts nothing"
: > "$CALLS"
printf 'not json' | bash "$SCRIPT"; rc=$?
check "R9 rc 0" "$rc" "0"
check "R9 no post" "$(ncalls)" "0"

for f in "$TMP"/xdg/himmel-queue-lock/* "$TMP"/handover/.locks/queue/*/owner.json; do rm -f "$f"; done
echo "ask-mirror: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
