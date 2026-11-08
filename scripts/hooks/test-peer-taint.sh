#!/usr/bin/env bash
# Tests for the peer-bridge taint hooks in marketplace/plugins/himmel-ops/hooks/:
# peer-taint-gate.sh (PreToolUse). Each row runs the hook under a temp HOME.
# Mutation rows run a row against a temp copy of the hook with one guard removed
# (each guard line carries a `# guard:<name>` tag) and expect that row to turn red.
# Usage: bash scripts/hooks/test-peer-taint.sh
set -uo pipefail
unset PEER_DESK CLAUDECODE CLAUDE_CODE_SESSION_ID

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUG="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks"
GATE="$PLUG/peer-taint-gate.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/peer-taint-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

ALLOW_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# new_home [bare]: a temp HOME with the state dir S, the key dir C and peers.json
# naming ABS as himmelRoot. `bare` creates neither dir.
new_home() {
    H="$(mktemp -d "$tmp/h.XXXXXX")" || exit 1
    S="$H/.himmel/peer-bridge"
    C="$H/.config/himmel/peer-bridge"
    ABS="$H/himmel"
    mkdir -p "$ABS"
    [ "${1:-}" = bare ] && return 0
    mkdir -p "$S/taint" "$S/goomal" "$C"
    : > "$S/goomal/inbox.jsonl"
    : > "$C/env"
    printf '{"himmelRoot":"%s"}\n' "$ABS" > "$C/peers.json"
}

# run_hook HOOK INPUT [VAR=VALUE...]: sets RC, OUT, ERR.
run_hook() {
    local h="$1" in="$2"
    shift 2
    OUT=$(printf '%s' "$in" | env HOME="$H" "$@" "$BASH_BIN" "$h" 2>"$tmp/err")
    RC=$?
    ERR=$(cat "$tmp/err")
}

jb() { jq -cn --arg s "$1" --arg t "$2" --arg c "$3" '{session_id:$s,tool_name:$t,tool_input:{command:$c}}'; }
jf() { jq -cn --arg s "$1" --arg t "$2" --arg k "$3" --arg v "$4" '{session_id:$s,tool_name:$t,tool_input:{($k):$v}}'; }

expect() {
    # expect LABEL WANT_RC [WANT_OUT]
    if [ "$RC" = "$2" ] && { [ $# -lt 3 ] || [ "$OUT" = "$3" ]; }; then pass "$1"; else fail "$1" "rc=$RC out=$OUT err=$ERR"; fi
}

mutant() {
    # mutant NAME SED_EXPR: a copy of the gate with one guard changed, in the plugin dir layout.
    local d="$tmp/mut-$1"
    mkdir -p "$d"
    sed "$2" "$GATE" > "$d/peer-taint-gate.sh"
    if cmp -s "$GATE" "$d/peer-taint-gate.sh"; then echo "FAIL: mutation $1 changed nothing"; FAIL=$((FAIL+1)); fi
    MUT="$d/peer-taint-gate.sh"
}

read_cmd() { printf 'bun %s/scripts/peer-bridge/read.ts goomal --thread 12' "$1"; }
send_cmd() { printf "bun %s/scripts/peer-bridge/send.ts goomal --kind answer --reply-to 12 --text '%s'" "$1" "$2"; }

mkdir -p "$tmp/nojq"
mkdir -p "$tmp/stubjq"
printf '#!/bin/sh\nexit 5\n' > "$tmp/stubjq/jq"
chmod +x "$tmp/stubjq/jq"

echo "== inert: no peer-bridge dirs =="
new_home bare
run_hook "$GATE" "$(jb s1 Bash 'git status')"; expect "no bridge: git status exits 0 silently" 0 ""
run_hook "$GATE" "$(jf s1 Read file_path x)"; expect "no bridge: Read x exits 0 silently" 0 ""
run_hook "$GATE" 'not json {'; expect "no bridge: unparsable stdin exits 0 silently" 0 ""
run_hook "$GATE" 'not json {' PATH="$tmp/nojq"; expect "no bridge, jq absent: exits 0 silently" 0 ""
run_hook "$GATE" "$(jf s1 Read file_path x)" PATH="$tmp/nojq"; expect "no bridge, jq absent: Read x exits 0 silently" 0 ""

echo "== allowed in a tainted session =="
new_home
: > "$S/taint/sT"
run_hook "$GATE" "$(jb sT Bash "$(read_cmd "$ABS")")"; expect "tainted: read.ts --thread runs" 0 ""
run_hook "$GATE" "$(jb sT Bash "bun $ABS/scripts/peer-bridge/read.ts goomal --ack Ab12")"; expect "tainted: read.ts --ack runs" 0 ""
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" 'use n, r, \ and a ; here')")"; expect "tainted: a one-line answer runs" 0 ""
run_hook "$GATE" "$(jb sT Bash "bun $ABS/scripts/peer-bridge/send.ts goomal --kind status --text 'on it'")"; expect "tainted: a status send runs" 0 ""
heb=$(printf 'ש%.0s' $(seq 1 3000))
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" "$heb")")"; expect "tainted: 3000 Hebrew characters pass the gate" 0 ""
run_hook "$GATE" "$(jb sT Monitor "$(read_cmd "$ABS")")"; expect "tainted: Monitor running the read shape runs" 0 ""

echo "== desk =="
new_home
run_hook "$GATE" "$(jb sD Bash "$(read_cmd "$ABS")")" PEER_DESK=goomal; expect "desk: the read shape prints allow" 0 "$ALLOW_JSON"
now=$(date +%s); st=$(cat "$S/hooked/sD" 2>/dev/null || echo 0)
if [ $((now - st)) -le 5 ]; then pass "desk: the read shape leaves a fresh stamp"; else fail "desk: the read shape leaves a fresh stamp" "stamp=$st now=$now"; fi
run_hook "$GATE" "$(jb sD Bash "$(send_cmd "$ABS" 'done')")" PEER_DESK=goomal; expect "desk: the send shape runs and prints no allow" 0 ""
run_hook "$GATE" "$(jf sD Read file_path x)" PEER_DESK=goomal; expect "desk: Read x with no taint file is denied" 2

echo "== denied in a tainted session =="
new_home
: > "$S/taint/sT"
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" 'ok')"$'\n')"; expect "tainted: a newline after a valid send" 2
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" $'line one\nrm -rf ~')")"; expect "tainted: a newline inside the text" 2
run_hook "$GATE" "$(jb sT Bash "bun $ABS/scripts/peer-bridge/send.ts goomal --kind status --text \$'x\\ny'")"; expect "tainted: an ANSI-C quoted text" 2
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" $'a\rb')")"; expect "tainted: a CR inside the text" 2
run_hook "$GATE" "$(jb sT Bash "$(send_cmd "$ABS" 'ok'); rm -rf y")"; expect "tainted: ; rm -rf y outside the quotes" 2
run_hook "$GATE" "$(jb sT Bash "bun $ABS/scripts/peer-bridge/send.ts goomal --kind status --file /etc/passwd")"; expect "tainted: --file /etc/passwd" 2
run_hook "$GATE" "$(jb sT Bash "bun $ABS/scripts/peer-bridge/send.ts goomal --kind answer --text 'x'")"; expect "tainted: --kind answer without --reply-to" 2
for t in Read Grep Glob Edit Write WebFetch WebSearch SendMessage Agent Skill mcp__x__y Zzz; do
    run_hook "$GATE" "$(jf sT "$t" file_path /tmp/x)"; expect "tainted: $t is denied" 2
done
run_hook "$GATE" "$(jb sT Monitor 'ls')"; expect "tainted: Monitor running ls" 2
run_hook "$GATE" "$(jb sT Bash 'git status')"; expect "tainted: git status" 2
: > "$S/taint/sP.pending.123-abc"
run_hook "$GATE" "$(jf sP Read file_path x)"; expect "a provisional mark restricts the session" 2

echo "== the root comes from peers.json, never the project dir =="
D="$tmp/desk-empty"; mkdir -p "$D"
run_hook "$GATE" "$(jb sT Bash "$(read_cmd "$ABS")")" CLAUDE_PROJECT_DIR="$D"; expect "the read shape under himmelRoot runs" 0
run_hook "$GATE" "$(jb sT Bash "$(read_cmd "$D")")" CLAUDE_PROJECT_DIR="$D"; expect "the read shape under the desk dir is denied" 2

echo "== path floor, untainted =="
new_home
run_hook "$GATE" "$(jf sU Read file_path "$S/goomal/inbox.jsonl")"; expect "Read the state-dir inbox is denied" 2
run_hook "$GATE" "$(jf sU Glob path "$C")"; expect "Glob under the key dir is denied" 2
run_hook "$GATE" "$(jf sU Glob pattern "$C/**")"; expect "Glob pattern under the key dir is denied" 2
run_hook "$GATE" "$(jb sU Bash 'cat ~/.config/himmel/peer-bridge/env')"; expect "Bash cat the key-dir env is denied" 2
run_hook "$GATE" "$(jf sU Write file_path "$S/new/x")"; expect "Write under a missing state subdir is denied" 2
# shellcheck disable=SC2088 # the literal ~ spelling is the input under test
run_hook "$GATE" "$(jf sU Read file_path '~/.himmel/peer-bridge/goomal/inbox.jsonl')"; expect "Read a ~ spelling is denied" 2
run_hook "$GATE" "$(jb sU Bash 'git status')"; expect "git status runs" 0 ""
run_hook "$GATE" "$(jf sU Read file_path "$ABS/README.md")"; expect "Read an unrelated file runs" 0 ""
L="$tmp/link-home"; ln -s "$H" "$L"
OH="$H"; H="$L"
run_hook "$GATE" "$(jf sU Read file_path "$OH/.himmel/peer-bridge/goomal/inbox.jsonl")"; expect "symlinked HOME: the canonical spelling is denied" 2
H="$OH"
run_hook "$GATE" "$(jf sU Read file_path "$L/.himmel/peer-bridge/goomal/inbox.jsonl")"; expect "real HOME: a spelling through a symlink is denied" 2

echo "== prefix sync with block-read-secrets =="
BRS="$REPO_ROOT/scripts/hooks/block-read-secrets.sh"
for p in .himmel/peer-bridge .config/himmel/peer-bridge; do
    if grep -qF "\${HOME:-}/$p\"" "$GATE" && grep -qF "*/$p|*/$p/*)" "$BRS"; then pass "both carry the prefix $p"; else fail "both carry the prefix $p"; fi
done

echo "== fail closed =="
new_home
: > "$S/taint/sT"
if [ "$(id -u)" = 0 ]; then
    echo "  SKIP: root reads mode 000"
else
    chmod 000 "$S/taint"
    run_hook "$GATE" "$(jf sT Read file_path x)"; expect "an unlistable taint dir denies" 2
    chmod 700 "$S/taint"
fi
run_hook "$GATE" "$(jb sU Bash 'git status')" PATH="$tmp/stubjq:$PATH"; expect "a jq that exits 5 denies" 2
run_hook "$GATE" 'not json {'; expect "unparsable stdin denies once a bridge exists" 2
run_hook "$GATE" "$(jb sU Bash 'git status')" PATH="$tmp/nojq"; expect "jq absent denies once a bridge exists" 2
run_hook "$GATE" '{"session_id":"s","tool_name":"Bash","tool_input":{"command":["ls"]}}'; expect "a command of the wrong type denies" 2
run_hook "$GATE" "$(jb '../x' Bash "$(read_cmd "$ABS")")"; expect "a session_id of ../x denies" 2
if [ ! -e "$S/x" ] && [ ! -e "$S/hooked" ]; then pass "../x creates nothing"; else fail "../x creates nothing"; fi

echo "== stamp =="
new_home
run_hook "$GATE" "$(jb sU Bash "$(read_cmd "$ABS")")"; expect "untainted read shape runs" 0 ""
if [ -s "$S/hooked/sU" ]; then pass "the read shape writes hooked/<sid> untainted"; else fail "the read shape writes hooked/<sid> untainted"; fi

echo "== mutation rows: each guard removed turns its row red =="
new_home
: > "$S/taint/sT"
mutant ctl '/# guard:ctl$/d'
run_hook "$MUT" "$(jb sT Bash "$(send_cmd "$ABS" $'line one\nrm -rf ~')")"
if [ "$RC" = 0 ]; then pass "no control-byte check: the newline row turns red"; else fail "no control-byte check: the newline row turns red" "rc=$RC"; fi
mutant floor '/# guard:floor$/d'
run_hook "$MUT" "$(jf sU Read file_path "$S/goomal/inbox.jsonl")"
if [ "$RC" = 0 ]; then pass "no path floor: the inbox Read row turns red"; else fail "no path floor: the inbox Read row turns red" "rc=$RC"; fi
mutant desk '/# guard:desk$/d'
run_hook "$MUT" "$(jf sD Read file_path x)" PEER_DESK=goomal
if [ "$RC" = 0 ]; then pass "no desk restriction: the desk Read x row turns red"; else fail "no desk restriction: the desk Read x row turns red" "rc=$RC"; fi
mutant failclosed 's/|| deny "unparsable hook input" # guard:failclosed$/|| exit 0/'
run_hook "$MUT" "$(jb sU Bash 'git status')" PATH="$tmp/stubjq:$PATH"
if [ "$RC" = 0 ]; then pass "fail-open default: the stub-jq row turns red"; else fail "fail-open default: the stub-jq row turns red" "rc=$RC"; fi
new_home bare
mutant inert '/# guard:inert$/d'
run_hook "$MUT" "$(jb s1 Bash 'git status')" PATH="$tmp/nojq"
if [ "$RC" != 0 ]; then pass "no inert exit: the jq-absent row turns red"; else fail "no inert exit: the jq-absent row turns red" "rc=$RC"; fi

MARKER_JS="$PLUG/peer-marker.mjs"
MARK="$PLUG/peer-taint-mark.sh"
RESUME="$PLUG/peer-taint-resume.sh"

# sign KEYFILE NONCE: a fence marker signed with the key in KEYFILE.
sign() {
    node --input-type=module -e "import { signFence } from '$MARKER_JS'; import { readFileSync } from 'node:fs'; process.stdout.write(signFence(readFileSync(process.argv[1]), process.argv[2]));" "$1" "$2"
}
verify_rc() { printf '%s' "$2" | node "$MARKER_JS" verify --key-file "$1" >/dev/null 2>&1; echo $?; }
jpost() { jq -cn --arg s "$1" --arg e "$2" --arg c "$3" --arg t "$4" '{session_id:$s,hook_event_name:$e,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$t}}'; }
new_keyed_home() {
    new_home
    printf 'k3y-for-the-peer-taint-suite-0123456789abcdef' > "$C/hmac.key"
    GOOD=$(sign "$C/hmac.key" 0123456789abcdef)
}
pending_count() { local n=0 f; for f in "$S/taint/$1".pending.*; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }

# stub_hooks NAME HOOK_SED: a hooks dir holding a (possibly mutated) mark hook, the
# real node launcher and a stub verifier driven by STUB_RC, STUB_FIFO, STUB_TOUCH,
# STUB_SLEEP and STUB_THROW. Sets SH to the hook path.
stub_hooks() {
    local d="$tmp/stub-$1"
    mkdir -p "$d"
    sed "${2:-}" "$MARK" > "$d/peer-taint-mark.sh"
    cp "$PLUG/run-node.sh" "$PLUG/resolve-node.sh" "$d/"
    cat > "$d/peer-marker.mjs" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
if (process.env.STUB_THROW) throw new Error('stub verifier crash');
if (process.env.STUB_FIFO) readFileSync(process.env.STUB_FIFO);
if (process.env.STUB_TOUCH) writeFileSync(process.env.STUB_TOUCH, '');
const rc = Number(process.env.STUB_RC || 1);
const done = () => { process.stdout.write(rc === 0 ? 'verified\n' : 'unverified\n'); process.exit(rc); };
if (process.env.STUB_SLEEP) setTimeout(done, Number(process.env.STUB_SLEEP)); else done();
JS
    SH="$d/peer-taint-mark.sh"
}

wait_pending() {
    local i=0
    while [ "$(pending_count "$1")" = 0 ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
}

# concurrent HOOK ORDER: two mark hooks on one sid, one verified (rc 0) and one
# not (rc 1). The first one blocks on a fifo until the second has finished.
concurrent() {
    local h="$1" order="$2" fifo first_rc second_rc pid
    fifo="$tmp/fifo-$order"
    rm -f "$fifo"; mkfifo "$fifo"
    if [ "$order" = verified-first ]; then first_rc=0; second_rc=1; else first_rc=1; second_rc=0; fi
    jpost sC PostToolUse x "$GOOD" | env HOME="$H" STUB_RC="$first_rc" STUB_FIFO="$fifo" "$BASH_BIN" "$h" >/dev/null 2>&1 &
    pid=$!
    wait_pending sC
    jpost sC PostToolUse x "$GOOD" | env HOME="$H" STUB_RC="$second_rc" "$BASH_BIN" "$h" >/dev/null 2>&1
    run_hook "$GATE" "$(jf sC Read file_path x)"
    MID_RC=$RC
    echo go > "$fifo"
    wait "$pid"
}

echo "== fence verifier CLI =="
new_keyed_home
printf 'another-key' > "$tmp/wrong.key"
r=$(verify_rc "$C/hmac.key" "before $GOOD after"); if [ "$r" = 0 ]; then pass "sign then verify exits 0"; else fail "sign then verify exits 0" "$r"; fi
ln -s "$PLUG" "$tmp/plug-link"
r=$(printf '%s' "$GOOD" | node "$tmp/plug-link/peer-marker.mjs" verify --key-file "$C/hmac.key" 2>/dev/null)
if [ "$r" = verified ]; then pass "the CLI runs when reached through a symlinked dir"; else fail "the CLI runs when reached through a symlinked dir" "$r"; fi
r=$(verify_rc "$tmp/wrong.key" "$GOOD"); if [ "$r" = 1 ]; then pass "a wrong key exits 1"; else fail "a wrong key exits 1" "$r"; fi
last="${GOOD: -4:1}"; if [ "$last" = 0 ]; then last=1; else last=0; fi
flipped="${GOOD:0:$((${#GOOD}-4))}$last>>>"
r=$(verify_rc "$C/hmac.key" "$flipped"); if [ "$r" = 1 ]; then pass "a flipped mac hex exits 1"; else fail "a flipped mac hex exits 1" "$r"; fi
r=$(verify_rc "$C/hmac.key" '<<<PEER-UNTRUSTED nonce=0123456789abcdef>>>'); if [ "$r" = 1 ]; then pass "a bare marker with no mac exits 1"; else fail "a bare marker with no mac exits 1" "$r"; fi
r=$(verify_rc "$C/hmac.key" "$(jq -cn --arg t "digest: $GOOD" '{type:"user",message:{content:[{type:"tool_result",content:$t}]}}')")
if [ "$r" = 0 ]; then pass "a JSON-escaped marker inside a transcript line exits 0"; else fail "a JSON-escaped marker inside a transcript line exits 0" "$r"; fi

echo "== mark hook =="
new_keyed_home
run_hook "$MARK" "$(jpost sV PostToolUse x "out $GOOD")"
if [ -e "$S/taint/sV" ] && [ "$(pending_count sV)" = 0 ]; then pass "a verified marker in PostToolUse output taints"; else fail "a verified marker in PostToolUse output taints" "rc=$RC err=$ERR"; fi
run_hook "$MARK" "$(jpost sN PostToolUse x "out $flipped")"
if [ ! -e "$S/taint/sN" ] && [ "$(pending_count sN)" = 0 ]; then pass "an unverified copy does not taint"; else fail "an unverified copy does not taint"; fi
run_hook "$MARK" "$(jpost sF PostToolUseFailure x "err $GOOD")"
if [ -e "$S/taint/sF" ]; then pass "PostToolUseFailure with a verified marker taints"; else fail "PostToolUseFailure with a verified marker taints"; fi
stub_hooks pre ''
run_hook "$SH" "$(jpost sQ PostToolUse 'git status' 'plain output')" STUB_TOUCH="$tmp/node-calls"
if [ ! -e "$tmp/node-calls" ] && [ "$RC" = 0 ]; then pass "output without the prefix never starts the verifier"; else fail "output without the prefix never starts the verifier"; fi
mv "$C/hmac.key" "$C/hmac.key.off"
run_hook "$MARK" "$(jpost sK PostToolUse x "out $GOOD")"
if [ "$RC" = 0 ] && [ -z "$ERR" ] && [ ! -e "$S/taint/sK" ]; then pass "a missing key file: no taint and no error"; else fail "a missing key file: no taint and no error" "rc=$RC err=$ERR"; fi
mv "$C/hmac.key.off" "$C/hmac.key"
stub_hooks throw ''
run_hook "$SH" "$(jpost sX PostToolUse x "out $GOOD")" STUB_THROW=1
run_hook "$GATE" "$(jf sX Read file_path x)"
if [ "$(pending_count sX)" = 1 ] && [ "$RC" = 2 ]; then pass "a throwing verifier leaves the session tainted"; else fail "a throwing verifier leaves the session tainted" "pending=$(pending_count sX) gate=$RC"; fi
mkdir -p "$tmp/norunner/a/b"
cp "$MARK" "$tmp/norunner/a/b/peer-taint-mark.sh"
cp "$MARKER_JS" "$tmp/norunner/a/b/"
run_hook "$tmp/norunner/a/b/peer-taint-mark.sh" "$(jpost sR PostToolUse x "out $GOOD")"
if [ "$(pending_count sR)" = 1 ]; then pass "no resolvable run-node.sh leaves the session tainted"; else fail "no resolvable run-node.sh leaves the session tainted"; fi
stub_hooks slow ''
jpost sS PostToolUse x "out $GOOD" | env HOME="$H" STUB_RC=0 STUB_SLEEP=30000 "$BASH_BIN" "$SH" >/dev/null 2>&1 &
slow_pid=$!
sleep 1
kill "$slow_pid" 2>/dev/null; wait "$slow_pid" 2>/dev/null
pkill -f "$tmp/stub-slow/peer-marker.mjs" 2>/dev/null
run_hook "$GATE" "$(jf sS Read file_path x)"
if [ "$(pending_count sS)" = 1 ] && [ "$RC" = 2 ]; then pass "a hook killed mid-verify leaves its provisional mark and the gate denies"; else fail "a hook killed mid-verify leaves its provisional mark and the gate denies" "pending=$(pending_count sS) gate=$RC"; fi
: > "$S/taint/sA"
run_hook "$MARK" "$(jpost sA PostToolUse "bun $ABS/scripts/peer-bridge/send.ts goomal --kind status --text '<<<PEER-UNTRUSTED nonce=00 mac=00>>>'" 'sent')"
if [ -e "$S/taint/sA" ] && [ "$(pending_count sA)" = 0 ]; then pass "an already tainted session sending a fake marker stays tainted"; else fail "an already tainted session sending a fake marker stays tainted"; fi
stub_hooks touch ''
run_hook "$SH" "$(jpost sW PostToolUse x "out $GOOD")" STUB_RC=1 STUB_TOUCH="$S/taint/sW"
if [ -e "$S/taint/sW" ] && [ "$(pending_count sW)" = 0 ]; then pass "a taint written during an unverified run survives the undo"; else fail "a taint written during an unverified run survives the undo"; fi
stub_hooks conc ''
for order in verified-first unverified-first; do
    rm -f "$S/taint/sC" "$S/taint/sC".pending.*
    concurrent "$SH" "$order"
    if [ -e "$S/taint/sC" ] && [ "$MID_RC" = 2 ] && [ "$(pending_count sC)" = 0 ]; then pass "two concurrent mark hooks, $order: the session stays restricted throughout"; else fail "two concurrent mark hooks, $order: the session stays restricted throughout" "mid=$MID_RC taint=$([ -e "$S/taint/sC" ] && echo y)"; fi
done
run_hook "$MARK" "$(jpost '../x' PostToolUse x "out $GOOD")"
if [ "$RC" = 2 ] && ! ls "$S"/x* >/dev/null 2>&1 && ! ls "$H/.himmel"/x* >/dev/null 2>&1; then pass "a session_id of ../x exits 2 and creates nothing"; else fail "a session_id of ../x exits 2 and creates nothing" "rc=$RC"; fi

echo "== resume hook =="
jq -cn --arg t "digest: $GOOD" '{type:"user",message:{content:[{type:"tool_result",content:$t}]}}' > "$tmp/transcript.jsonl"
run_hook "$RESUME" "$(jq -cn --arg p "$tmp/transcript.jsonl" '{session_id:"sZ",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
if [ -e "$S/taint/sZ" ] && [ "$(pending_count sZ)" = 0 ]; then pass "resume from a transcript with a verified marker taints"; else fail "resume from a transcript with a verified marker taints" "rc=$RC err=$ERR"; fi
run_hook "$RESUME" "$(jq -cn --arg p "$tmp/transcript.jsonl" '{session_id:"sY",hook_event_name:"SessionStart",source:"startup",transcript_path:$p}')"
if [ ! -e "$S/taint/sY" ]; then pass "a startup source is not checked"; else fail "a startup source is not checked"; fi
printf '{"type":"user","message":{"content":"plain"}}\n' > "$tmp/clean.jsonl"
run_hook "$RESUME" "$(jq -cn --arg p "$tmp/clean.jsonl" '{session_id:"sCl",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
if [ ! -e "$S/taint/sCl" ] && [ "$(pending_count sCl)" = 0 ]; then pass "resume from a transcript with no marker leaves no mark"; else fail "resume from a transcript with no marker leaves no mark"; fi
run_hook "$RESUME" "$(jq -cn --arg p "$tmp/no-such.jsonl" '{session_id:"sMi",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
if [ "$(pending_count sMi)" = 1 ]; then pass "resume with a missing transcript keeps a provisional mark"; else fail "resume with a missing transcript keeps a provisional mark"; fi
if [ "$(id -u)" = 0 ]; then
    echo "  SKIP: root reads mode 000"
else
    cp "$tmp/transcript.jsonl" "$tmp/locked.jsonl"; chmod 000 "$tmp/locked.jsonl"
    run_hook "$RESUME" "$(jq -cn --arg p "$tmp/locked.jsonl" '{session_id:"sLk",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
    if [ "$(pending_count sLk)" = 1 ]; then pass "resume with an unreadable transcript keeps a provisional mark"; else fail "resume with an unreadable transcript keeps a provisional mark"; fi
    chmod 600 "$tmp/locked.jsonl"
    # shellcheck disable=SC2016 # sed text, not shell
    sed 's/^if \[ "\$scan" = clean \]; then exit 0; fi # guard:scan$/if [ "$scan" != marked ]; then exit 0; fi/' "$RESUME" > "$tmp/mut-resume.sh"
    chmod 000 "$tmp/locked.jsonl"
    run_hook "$tmp/mut-resume.sh" "$(jq -cn --arg p "$tmp/locked.jsonl" '{session_id:"sLm",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
    if [ "$(pending_count sLm)" = 0 ]; then pass "an inspection failure read as clean: the unreadable-transcript row turns red"; else fail "an inspection failure read as clean: the unreadable-transcript row turns red"; fi
    chmod 600 "$tmp/locked.jsonl"
fi

echo "== mark hook mutation rows =="
new_keyed_home
# shellcheck disable=SC2016 # sed text, not shell
stub_hooks mkeep 's/^    \*) : ;; # guard:keep$/    *) rm -f "$own" ;;/'
run_hook "$SH" "$(jpost sX PostToolUse x "out $GOOD")" STUB_THROW=1
if [ "$(pending_count sX)" = 0 ]; then pass "other outcome clears: the throwing-verifier row turns red"; else fail "other outcome clears: the throwing-verifier row turns red"; fi
mkdir -p "$tmp/mpf"; sed '/# guard:prefilter$/d' "$MARK" > "$tmp/mpf/peer-taint-mark.sh"; cp "$PLUG/run-node.sh" "$PLUG/resolve-node.sh" "$MARKER_JS" "$tmp/mpf/"
rm -f "$tmp/node-calls"
stub_hooks nopre '/# guard:prefilter$/d'
run_hook "$SH" "$(jpost sQ PostToolUse 'git status' 'plain output')" STUB_TOUCH="$tmp/node-calls"
if [ -e "$tmp/node-calls" ]; then pass "no prefilter: the verifier-start row turns red"; else fail "no prefilter: the verifier-start row turns red"; fi
# shellcheck disable=SC2016 # sed text, not shell
sed 's|^    1:unverified) rm -f "$own" ;; # guard:undo$|    1:unverified) rm -f "$own" "$S/taint/$sid" ;;|' "$MARK" > "$tmp/mpf/peer-taint-mark.sh"
: > "$S/taint/sA"
run_hook "$tmp/mpf/peer-taint-mark.sh" "$(jpost sA PostToolUse "bun $ABS/scripts/peer-bridge/send.ts goomal --kind status --text '<<<PEER-UNTRUSTED nonce=00 mac=00>>>'" 'sent')"
if [ ! -e "$S/taint/sA" ]; then pass "undo removes <sid>: the already-tainted row turns red"; else fail "undo removes <sid>: the already-tainted row turns red"; fi
# shellcheck disable=SC2016 # sed text, not shell
stub_hooks mshared 's|^own=.*# guard:pername$|own="$S/taint/$sid.pending.shared"|'
rm -f "$S/taint/sC" "$S/taint/sC".pending*
concurrent "$SH" verified-first
if [ "$MID_RC" != 2 ]; then pass "one shared provisional name: the concurrent row turns red"; else fail "one shared provisional name: the concurrent row turns red" "mid=$MID_RC"; fi

echo "== wired: the hooks.json commands run from a desk cwd outside any checkout =="
HOOKS_JSON="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/hooks.json"
# wired_cmd EVENT SCRIPT: the hooks.json command that runs SCRIPT on EVENT.
wired_cmd() {
    node -e 'const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks[process.argv[2]] || [];
const c = h.flatMap((g) => g.hooks).map((x) => x.command).filter((x) => x.includes("/" + process.argv[3] + "\""));
if (c.length !== 1) process.exit(1); process.stdout.write(c[0]);' "$HOOKS_JSON" "$1" "$2"
}
# run_wired EVENT SCRIPT INPUT: run the wired command the way Claude Code does, from the desk dir.
run_wired() {
    local c
    c=$(wired_cmd "$1" "$2") || { RC=99; OUT=""; ERR="no single wired command for $2 on $1"; return; }
    OUT=$(cd "$DESK" && printf '%s' "$3" | env HOME="$H" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/marketplace/plugins/himmel-ops" CLAUDE_PROJECT_DIR="$DESK" sh -c "$c" 2>"$tmp/err")
    RC=$?
    ERR=$(cat "$tmp/err")
}
new_keyed_home
DESK="$S/desk/goomal"; mkdir -p "$DESK"
: > "$S/taint/sT"
run_wired PreToolUse peer-taint-gate.sh "$(jf sT Read file_path x)"; expect "wired gate denies Read x for a tainted sid from the desk cwd" 2
run_wired PreToolUse peer-taint-gate.sh "$(jb sT Bash "$(read_cmd "$ABS")")" ; expect "wired gate allows the read shape for a tainted sid" 0
run_wired PostToolUse peer-taint-mark.sh "$(jpost sM PostToolUse x "out $GOOD")"
if [ -e "$S/taint/sM" ]; then pass "wired PostToolUse mark hook taints"; else fail "wired PostToolUse mark hook taints" "rc=$RC err=$ERR"; fi
run_wired PostToolUseFailure peer-taint-mark.sh "$(jpost sMF PostToolUseFailure x "err $GOOD")"
if [ -e "$S/taint/sMF" ]; then pass "wired PostToolUseFailure mark hook taints"; else fail "wired PostToolUseFailure mark hook taints" "rc=$RC err=$ERR"; fi
run_wired SessionStart peer-taint-resume.sh "$(jq -cn --arg p "$tmp/transcript.jsonl" '{session_id:"sMR",hook_event_name:"SessionStart",source:"resume",transcript_path:$p}')"
if [ -e "$S/taint/sMR" ]; then pass "wired SessionStart resume hook taints"; else fail "wired SessionStart resume hook taints" "rc=$RC err=$ERR"; fi

echo "== untaint.sh: only a human at a terminal clears a taint =="
UNTAINT="$REPO_ROOT/scripts/peer-bridge/untaint.sh"
# tty.py MODE ANSWER CMD...: MODE pty runs CMD on a new pty and types ANSWER;
# MODE notty runs CMD in a new session with no controlling terminal.
cat > "$tmp/tty.py" <<'PY'
import os, pty, sys
mode, answer, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
if mode == "notty":
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.execvp(cmd[0], cmd)
else:
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    os.write(fd, (answer + "\n").encode())
    try:
        while True:
            chunk = os.read(fd, 1024)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
    except OSError:
        pass
    sys.stdout.flush()
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
PY
# untaint MODE ANSWER SID [VAR=VALUE...]: sets RC.
untaint() {
    local mode="$1" ans="$2" sid="$3"
    shift 3
    env HOME="$H" "$@" python3 -I "$tmp/tty.py" "$mode" "$ans" "$BASH_BIN" "$UNTAINT" "$sid" >/dev/null 2>&1
    RC=$?
}
new_home
: > "$S/taint/sU"
untaint notty yes sU; if [ "$RC" = 3 ] && [ -e "$S/taint/sU" ]; then pass "no TTY: exit 3 and the taint stays"; else fail "no TTY: exit 3 and the taint stays" "rc=$RC"; fi
untaint pty yes sU CLAUDECODE=1; if [ "$RC" = 3 ] && [ -e "$S/taint/sU" ]; then pass "a pty answering yes with CLAUDECODE set: exit 3"; else fail "a pty answering yes with CLAUDECODE set: exit 3" "rc=$RC"; fi
untaint pty yes sU CLAUDE_CODE_SESSION_ID=abc; if [ "$RC" = 3 ] && [ -e "$S/taint/sU" ]; then pass "a pty answering yes with CLAUDE_CODE_SESSION_ID set: exit 3"; else fail "a pty answering yes with CLAUDE_CODE_SESSION_ID set: exit 3" "rc=$RC"; fi
untaint pty no sU; if [ "$RC" = 3 ] && [ -e "$S/taint/sU" ]; then pass "a pty answering no: exit 3"; else fail "a pty answering no: exit 3" "rc=$RC"; fi
seen=$(env HOME="$H" python3 -I "$tmp/tty.py" pty no "$BASH_BIN" "$UNTAINT" sU 2>&1)
case "$seen" in *"Type yes"*"not cleared"*) pass "the human sees the prompt and the refusal on the terminal" ;; *) fail "the human sees the prompt and the refusal on the terminal" "$seen" ;; esac
: > "$H/.himmel/x"
untaint pty yes '../../x'; if [ "$RC" = 3 ] && [ -e "$H/.himmel/x" ]; then pass "the id ../../x: exit 3 and nothing outside taint/ is removed"; else fail "the id ../../x: exit 3 and nothing outside taint/ is removed" "rc=$RC"; fi
if [ "$(id -u)" = 0 ]; then
    echo "  SKIP: root removes from a read-only dir"
else
    chmod 500 "$S/taint"
    untaint pty yes sU
    chmod 700 "$S/taint"
    if [ "$RC" = 3 ] && [ -e "$S/taint/sU" ] && ! grep -q '"sid":"sU"' "$S/taint/cleared.log" 2>/dev/null; then pass "a removal that fails: exit 3 and no log line"; else fail "a removal that fails: exit 3 and no log line" "rc=$RC"; fi
fi
untaint pty yes sU; if [ "$RC" = 0 ] && [ ! -e "$S/taint/sU" ] && grep -q '"sid":"sU"' "$S/taint/cleared.log"; then pass "a pty answering yes with a clean env clears and logs"; else fail "a pty answering yes with a clean env clears and logs" "rc=$RC"; fi
: > "$S/taint/sP.pending.1-a"; : > "$S/taint/sP.pending.2-b"
untaint pty yes sP
run_hook "$GATE" "$(jf sP Read file_path x)"
if [ "$(pending_count sP)" = 0 ] && grep -q '"sid":"sP"' "$S/taint/cleared.log" && [ "$RC" = 0 ]; then pass "leftover provisional marks are cleared and the gate no longer restricts"; else fail "leftover provisional marks are cleared and the gate no longer restricts" "gate=$RC pending=$(pending_count sP)"; fi

echo
echo "peer-taint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
