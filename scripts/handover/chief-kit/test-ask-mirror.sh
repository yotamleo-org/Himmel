#!/usr/bin/env bash
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$KIT/ask-mirror.sh"
REPO="$(cd "$KIT/../../.." && pwd)"
# shellcheck source=../../lib/timeout-bin.sh
. "$REPO/scripts/lib/timeout-bin.sh" 2>/dev/null

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
printf '%s\n' "$5" >> "$ASK_MIRROR_TEST_IDS"
printf '%s\n' "${CHIEF_ROUTE_RECEIPT_WAIT_SEC:-unset}" >> "$ASK_MIRROR_TEST_WAIT"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ "${ASK_MIRROR_TEST_FAIL:-0}" = 1 ] && { echo "stub: send failed" >&2; exit 1; }
[ "${ASK_MIRROR_TEST_FAIL_FIRST:-0}" = 1 ] && [ "$(wc -l < "$ASK_MIRROR_TEST_CALLS" | tr -d ' ')" -eq 1 ] && { echo "stub: first send failed" >&2; exit 1; }
echo escalate
EOF
chmod +x "$STUB"
IDS="$TMP/ids.log"; WAITS="$TMP/waits.log"
export ASK_MIRROR_ROUTE="$STUB" ASK_MIRROR_TEST_CALLS="$CALLS" ASK_MIRROR_TEST_IDS="$IDS" ASK_MIRROR_TEST_WAIT="$WAITS"

payload() { jq -cn --arg s "$1" --arg m "$2" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:$m}'; }
run() { : > "$CALLS"; : > "$IDS"; : > "$WAITS"; payload "$1" "$2" | bash "$SCRIPT" > "$TMP/out"; echo "rc=$?" > "$TMP/rc"; }
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

owed_rows() { jq -r 'select(.op=="add") | .text' "$owed" 2>/dev/null | grep -c "$1" || true; }
posted_text() { sed -E 's/^.*\|operator\|//' "$CALLS"; }
POSTED="$HANDOVER_DIR/.ask-mirror/FIX-nextleg-chief.posted"

echo "R10: a spent budget cuts the run off and owes the blocks that did not post"
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    export ASK_MIRROR_BUDGET_SEC=2 STUB_SLEEP=3
    t0=$SECONDS
    run chief-sid "$(printf 'Needs you: R10 one.\n\nNeeds you: R10 two.\n\nNeeds you: R10 three.\n\nNeeds you: R10 four.')"
    elapsed=$((SECONDS - t0))
    unset ASK_MIRROR_BUDGET_SEC STUB_SLEEP
    check "R10 one stub call, cut off by the timeout" "$(ncalls)" "1"
    check "R10 four owed rows" "$(owed_rows 'R10 ')" "4"
    check "R10 the run ends in under 6 s" "$([ "$elapsed" -lt 6 ] && echo yes || echo "no ($elapsed s)")" "yes"
else
    echo "  skip R10: no timeout binary"
fi

echo "R11: after a failed post the rest still post, with no receipt wait"
unset CHIEF_ROUTE_RECEIPT_WAIT_SEC
export ASK_MIRROR_TEST_FAIL_FIRST=1
run chief-sid "$(printf 'Needs you: R11 one.\n\nNeeds you: R11 two.\n\nNeeds you: R11 three.\n\nNeeds you: R11 four.')"
unset ASK_MIRROR_TEST_FAIL_FIRST
check "R11 four calls" "$(ncalls)" "4"
check "R11 the first call keeps the receipt wait, the three later ones carry 0" "$(tr '\n' ' ' < "$WAITS")" "unset 0 0 0 "
check "R11 the first block has an owed row" "$(owed_rows 'R11 one')" "1"
check "R11 the later blocks have none" "$(owed_rows 'R11 [ttf]')" "0"

echo "R12: a renumbered restatement posts once, with its first number"
run chief-sid "1. Needs you: R12 X"
check "R12 first posts" "$(ncalls)" "1"
check "R12 the post begins at its list number" "$(posted_text)" "1. Needs you: R12 X"
run chief-sid "2.  Needs you: R12 X"
check "R12 the renumbered, respaced restatement posts nothing" "$(ncalls)" "0"

echo "R13: a code-less restatement of a sent ask posts nothing"
R13_ASK=$'Needs you: R13 X\n\n```\nGO-13\n```'
run chief-sid "$R13_ASK"
check "R13 the ask and its code post" "$(ncalls)" "2"
run chief-sid "Needs you: R13 X"
check "R13 the code-less restatement posts nothing" "$(ncalls)" "0"

echo "R14: a restatement of a pending post reuses its owed id and text"
export ASK_MIRROR_TEST_FAIL_FIRST=1
run chief-sid "1. Needs you: R14 X"
unset ASK_MIRROR_TEST_FAIL_FIRST
first_id="$(cat "$IDS")"; first_text="$(posted_text)"
run chief-sid "3. Needs you: R14 X"
check "R14 the restatement posts again (the first never landed)" "$(ncalls)" "1"
check "R14 same owed id" "$(cat "$IDS")" "$first_id"
check "R14 same text, with the first number" "$(posted_text)" "$first_text"
check "R14 that text is the first one" "$first_text" "1. Needs you: R14 X"

echo "R15: every posted ask is one chief-route records for reply binding"
if command -v bun >/dev/null 2>&1; then
    printf 'import { recordAsk } from "%s/scripts/telegram/chief-route.ts";\nawait recordAsk(process.argv[2], 1, process.argv[3]);\n' "$REPO" > "$TMP/rec.ts"
    run chief-sid "$(printf '1. Needs you: R15 A\n\n- Needs you: R15 B\n\nStatus: Needs you: R15 C')"
    check "R15 three posts" "$(ncalls)" "3"
    ROUTE_ROOT="$TMP/route-root"; mkdir -p "$ROUTE_ROOT"
    while IFS= read -r text; do bun "$TMP/rec.ts" "$ROUTE_ROOT" "$text" >/dev/null 2>&1; done <<EOF
$(posted_text)
EOF
    check "R15 each posted text adds one ask row" "$(wc -l < "$ROUTE_ROOT/consoles/asks.ndjson" 2>/dev/null | tr -d ' ')" "3"
else
    echo "  skip R15: no bun"
fi

echo "R16: the .posted store holds every ask as the phone shows it"
run chief-sid "$(printf '1. Needs you: R16 A\n\n2. Needs you: R16 B')"
check "R16 two posts in the first run" "$(ncalls)" "2"
run chief-sid "$(printf '1. Needs you: R16 B\n\n2. Needs you: R16 C')"
check "R16 one post (C) in the second run" "$(ncalls)" "1"
check "R16 the store lists two files that start with 2., the texts of B and C" \
    "$(grep -h '^2\. Needs you: R16' "$POSTED"/* 2>/dev/null | sort | tr '\n' ' ')" "2. Needs you: R16 B 2. Needs you: R16 C "

for f in "$TMP"/xdg/himmel-queue-lock/* "$TMP"/handover/.locks/queue/*/owner.json; do rm -f "$f"; done
echo "ask-mirror: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
