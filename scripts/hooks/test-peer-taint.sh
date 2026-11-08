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

echo
echo "peer-taint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
