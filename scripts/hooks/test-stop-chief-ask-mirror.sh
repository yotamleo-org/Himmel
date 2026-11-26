#!/usr/bin/env bash
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
HOOK="$HOOKS/stop-chief-ask-mirror.sh"
QUEUE="$HOOKS/stop-queue.mjs"
for t in jq node python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: no $t on PATH"; exit 0; }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "SKIP: no sha256 tool on PATH"; exit 0
fi

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fi
}
digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-stop-chief-ask-mirror.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
cleanup() {
    if [ -d "$HIMMEL_STOP_QUEUE_DIR/worker.lock" ]; then
        local p; p="$(cat "$HIMMEL_STOP_QUEUE_DIR/worker.lock/pid" 2>/dev/null)"
        [ -n "$p" ] && kill "$p" 2>/dev/null
    fi
    find "$TMP" -depth -mindepth 1 \( -type f -o -type l \) -exec rm -f {} + 2>/dev/null
    find "$TMP" -depth -type d -exec rmdir {} + 2>/dev/null
}
trap cleanup EXIT

export HIMMEL_STOP_QUEUE_DIR="$TMP/queue"
export HANDOVER_DIR="$TMP/handover" XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$HANDOVER_DIR/.locks/queue" "$XDG_RUNTIME_DIR/himmel-queue-lock" "$HIMMEL_STOP_QUEUE_DIR"

CHIEF_DOC="$HANDOVER_DIR/FIX-nextleg-chief.md"
printf 'chief doc\n' > "$CHIEF_DOC"
mkdir -p "$HANDOVER_DIR/.locks/queue/FIX-nextleg-chief.lock"
printf '{"handover":"%s"}\n' "$CHIEF_DOC" > "$HANDOVER_DIR/.locks/queue/FIX-nextleg-chief.lock/owner.json"
: > "$XDG_RUNTIME_DIR/himmel-queue-lock/$(digest_of "chief-sid|$CHIEF_DOC").tok"

CALLS="$TMP/calls.log"
STUB="$TMP/route-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
flat="$(printf '%s' "$*" | tr '\n' ' ')"
printf '%s|bridge=%s|access=%s\n' "$flat" "${BRIDGE_ROOT:-}" "${TELEGRAM_ACCESS_PATH:-}" >> "$ASK_MIRROR_TEST_CALLS"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
echo escalate
EOF
chmod +x "$STUB"
OWE_STUB="$TMP/owe-stub.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OWE_STUB"; chmod +x "$OWE_STUB"
export ASK_MIRROR_ROUTE="$STUB" ASK_MIRROR_OWE="$OWE_STUB" ASK_MIRROR_TEST_CALLS="$CALLS"
export HIMMEL_STOP_QUEUE_ENV_EXTRA="ASK_MIRROR_ROUTE,ASK_MIRROR_OWE,ASK_MIRROR_TEST_CALLS,STUB_SLEEP"
export BRIDGE_ROOT="$TMP/bridge-row" TELEGRAM_ACCESS_PATH="$TMP/access-row.json"

: > "$CALLS"
ncalls() { if [ -s "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
queue_rows() { cat "$HIMMEL_STOP_QUEUE_DIR/queue.jsonl" 2>/dev/null | grep -c 'chief-ask-mirror-' || true; }
wait_calls() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(ncalls)" -ge "$1" ] && return 0
        sleep 0.2; i=$((i+1))
    done
    return 1
}
fixture() { jq -cn --arg s "$1" --arg m "$2" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:$m}' > "$3"; }
run_hook() {
    HOUT="$(bash "$HOOK" < "$1" 2>/dev/null)"; HRC=$?  # read-sink-ok: every caller passes a payload file this suite wrote under its own mktemp dir
}

if [ ! -f "$HOOK" ]; then
    check "hook exists" "missing" "present"
    printf '\nstop-chief-ask-mirror: %s passed, %s failed\n' "$pass" "$fail"
    exit 1
fi

queue_status() { node "$QUEUE" status 2>/dev/null; }
wait_status() {
    local i=0 out
    while [ "$i" -lt 150 ]; do
        out="$(queue_status)"
        case "$out" in *"$1"*) return 0 ;; esac
        sleep 0.2; i=$((i+1))
    done
    return 1
}

echo "R1: a chief reply with an ask reaches ask-mirror.sh with the session paths"
fixture chief-sid $'Status: done.\n\nNeeds you: approve the restart.\nReply yes.' "$TMP/p1.json"
run_hook "$TMP/p1.json"
check "R1 rc 0" "$HRC" "0"
check "R1 stdout empty" "$HOUT" ""
wait_calls 1
check "R1 one route call" "$(ncalls)" "1"
check "R1 call is a chief-reply to operator with the ask" "$(head -1 "$CALLS" | cut -d'|' -f1 | sed -E 's/ask-[0-9a-f]{16}/ask-K/')" \
    "reply --chief FIX-nextleg-chief --owed ask-K --doc $CHIEF_DOC --kind chief-reply operator Needs you: approve the restart. Reply yes."
check "R1 the job saw BRIDGE_ROOT and TELEGRAM_ACCESS_PATH" "$(head -1 "$CALLS" | cut -d'|' -f2-3)" \
    "bridge=$BRIDGE_ROOT|access=$TELEGRAM_ACCESS_PATH"
wait_status 'worker: idle'; check "R1 the job finished" "$?" "0"

echo "R2: a reply without Needs you: writes no queue entry"
before="$(queue_rows)"
fixture chief-sid "All merged. Waiting on two workers." "$TMP/p2.json"
run_hook "$TMP/p2.json"
check "R2 rc 0" "$HRC" "0"
check "R2 stdout empty" "$HOUT" ""
check "R2 no new queue row" "$(queue_rows)" "$before"
check "R2 no pending entry" "$(find "$HIMMEL_STOP_QUEUE_DIR/entries" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "R3: the hook returns before a slow post ends"
: > "$CALLS"
export STUB_SLEEP=8
fixture chief-sid "Needs you: slow one." "$TMP/p3.json"
t0=$SECONDS
run_hook "$TMP/p3.json"
elapsed=$((SECONDS - t0))
unset STUB_SLEEP
wait_calls 1
check "R3 rc 0" "$HRC" "0"
check "R3 stdout empty" "$HOUT" ""
check "R3 hook took under 3 s" "$([ "$elapsed" -lt 3 ] && echo yes || echo "no ($elapsed s)")" "yes"

echo "R4: two different ask replies queued behind a busy worker both run"
wait_status 'worker: idle'; check "R4 R3's slow job drained" "$?" "0"
: > "$CALLS"
RELEASE="$TMP/release"
node "$QUEUE" enqueue --key blocker -- bash -c "while [ ! -f '$RELEASE' ]; do sleep 0.2; done" < /dev/null >/dev/null 2>&1
wait_status 'UNFINISHED'; check "R4 the blocker holds the worker" "$?" "0"
fixture chief-sid "Needs you: first ask." "$TMP/p4a.json"
fixture chief-sid "Needs you: second ask." "$TMP/p4b.json"
run_hook "$TMP/p4a.json"; run_hook "$TMP/p4b.json"
check "R4 nothing ran while the blocker waited" "$(ncalls)" "0"
: > "$RELEASE"
wait_calls 2
check "R4 both asks reached the route" "$(ncalls)" "2"
rm -f "$RELEASE"
wait_status 'worker: idle'; check "R4 the queue drained" "$?" "0"

echo "R5: junk input exits 0, prints nothing, queues nothing"
n0="$(find "$HIMMEL_STOP_QUEUE_DIR/entries" -type f 2>/dev/null | wc -l | tr -d ' ')"
: > "$TMP/empty.json"
printf 'not json' > "$TMP/junk.json"
jq -cn '{session_id:"chief-sid", last_assistant_message:null}' > "$TMP/null.json"
jq -cn '{session_id:"chief-sid"}' > "$TMP/absent.json"
for f in empty junk null absent; do
    run_hook "$TMP/$f.json"
    check "R5 $f: rc 0 and no stdout" "$HRC|$HOUT" "0|"
done
check "R5 no entry written" "$(find "$HIMMEL_STOP_QUEUE_DIR/entries" -type f 2>/dev/null | wc -l | tr -d ' ')" "$n0"

echo "R6: wire-hook-bash --check passes and the script is not in EXPECTED_SCRIPT_ORDER"
(cd "$REPO" && node scripts/hooks/wire-hook-bash.mjs --check >/dev/null 2>&1); check "R6 --check passes" "$?" "0"
check "R6 no EXPECTED_SCRIPT_ORDER row" "$(grep -c 'stop-chief-ask-mirror' "$HOOKS/wire-hook-bash.mjs")" "0"

echo "R7: the Stop entry is wired in .claude/settings.json"
check "R7 a Stop group runs the hook" "$(jq -r '[.hooks.Stop[].hooks[].command | select(contains("stop-chief-ask-mirror.sh"))] | length' "$REPO/.claude/settings.json")" "1"

printf '\nstop-chief-ask-mirror: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
