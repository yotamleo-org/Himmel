#!/usr/bin/env bash
# test-block-busy-loop.sh — suite for the PreToolUse sleepless busy-loop deny.
# The suite is the spec.
#
# Every case runs the INSTALLED hooks.json command with CLAUDE_PLUGIN_ROOT on
# this plugin dir, so a wiring that points at $CLAUDE_PROJECT_DIR/scripts/hooks/
# (an --optional no-op outside himmel) reads as allow and fails the deny rows.
#
# Usage: bash marketplace/plugins/himmel-ops/hooks/test-block-busy-loop.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
HIMMEL_ROOT="$(cd "$HERE/../../../.." && pwd)"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/busy-loop.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"
LOG="$TMP/deny.jsonl"

plugin_cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("block-busy-loop.sh"))' "$PLUGIN_DIR/hooks/hooks.json")

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# run_case <payload> <project dir> [VAR=value]: sets RC and ERR.
run_case() {
    rm -f "$LOG"
    ERR=$(cd "$2" && printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
        CLAUDE_PROJECT_DIR="$2" BUSY_LOOP_LOG="$LOG" BUSY_LOOP_BYPASS=0 ${3:+"$3"} \
        sh -c "${plugin_cmd:-exit 0}" 2>&1 >/dev/null)
    RC=$?
}

assert_eq() {
    if [ "$3" = "$2" ]; then
        echo "PASS $1 ($3)"
    else
        echo "FAIL $1 - expected $2, got $3"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 - message did not contain: $2"
           echo "  got: $3"
           FAILED=$((FAILED + 1)) ;;
    esac
}

rows() { wc -l <"$LOG" 2>/dev/null | tr -d ' '; }

# An adopter repo (not himmel) gets the guard from the plugin.
busy_payload='{"session_id":"s-busy","tool_name":"Bash","tool_input":{"command":"until [ -f /tmp/x ]; do :; done"}}'
run_case "$busy_payload" "$TMP/repo"
assert_eq "adopter: busy loop denied" 2 "$RC"
assert_contains "adopter: deny names sleep" "sleep" "$ERR"
assert_contains "adopter: deny names a portable pid wait" "kill -0" "$ERR"
case "$ERR" in
    *scripts/*|*quiet-run*|*QUIET_RUN*)
        echo "FAIL adopter: deny names a himmel script: $ERR"
        FAILED=$((FAILED + 1)) ;;
    *) echo "PASS adopter: deny names no himmel script" ;;
esac
n=$(jq -c 'select(.session_id == "s-busy" and .decision == "deny" and .loop == "until" and .body == ":")' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "adopter: one JSONL row with the session_id" 1 "$n"
run_case "$(j_bash "until pgrep -f clear-review-marker.sh && false; do :; done")" "$TMP/repo"
assert_eq "deny: do : loop" 2 "$RC"
run_case "$(j_bash "while true; do true; done")" "$TMP/repo"
assert_eq "deny: do true loop" 2 "$RC"
# shellcheck disable=SC2016  # the payload is literal shell text, not expanded here
run_case "$(j_bash 'while [ "$x" != ";" ]; do :; done')" "$TMP/repo"
assert_eq "deny: quoted ; in the loop head" 2 "$RC"
# shellcheck disable=SC2016  # the payload is literal shell text, not expanded here
run_case "$(j_bash 'while [ "$x" = "a\";b" ]; do :; done')" "$TMP/repo"
assert_eq "deny: escaped quote and ; inside a quoted span" 2 "$RC"
run_case "$(j_bash "while kill -0 1234; do sleep 2; done")" "$TMP/repo"
assert_eq "allow: sleep in the body" 0 "$RC"
run_case "$(j_bash "for x in a b; do :; done")" "$TMP/repo"
assert_eq "allow: finite for do :" 0 "$RC"
[ -e "$LOG" ] && present=yes || present=no
assert_eq "allow writes no row" no "$present"
run_case "$busy_payload" "$TMP/repo" BUSY_LOOP_BYPASS=1
assert_eq "bypass BUSY_LOOP_BYPASS=1" 0 "$RC"

SCR="$TMP/scratch"
mkdir -p "$SCR"
printf '#!/usr/bin/env bash\nwhile :\ndo\n  :\ndone\n' >"$SCR/spin.sh"
printf 'import subprocess\nfor _ in range(3):\n    subprocess.Popen(["bash", "-c", "while :; do :; done"])\n' >"$SCR/load_run.py"
printf 'while True:\n    pass\n' >"$SCR/spin.py"
printf 'import subprocess\nsubprocess.run(["taskset", "-c", "0", "bash", "suite.sh"])\n' >"$SCR/pin.py"
printf 'import time\nfor i in range(3):\n    time.sleep(1)\nprint("stress test notes")\n' >"$SCR/ok.py"
printf "#!/usr/bin/env bash\nwhile kill -0 \"\$1\"; do sleep 1; done\n" >"$SCR/wait.sh"

run_case "$(j_bash "bash $SCR/spin.sh")" "$TMP/repo"
assert_eq "deny: a bash file holding a sleepless loop" 2 "$RC"
run_case "$(j_bash "bash '$SCR/spin.sh'")" "$TMP/repo"
assert_eq "deny: a quoted path to a bash file holding a sleepless loop" 2 "$RC"
run_case "$(j_bash "git grep -n '$SCR/spin.sh' docs; git commit -m 'fix $SCR/spin.sh'")" "$TMP/repo"
assert_eq "allow: a script path inside a grep pattern or a commit message" 0 "$RC"
run_case "$(j_bash "cd '$SCR' && bash spin.sh")" "$TMP/repo"
assert_eq "deny: a quoted cd then a bash file holding a sleepless loop" 2 "$RC"
run_case "$(j_bash "python3 $SCR/load_run.py")" "$TMP/repo"
assert_eq "deny: a python file spawning sleepless loops" 2 "$RC"
assert_contains "deny names the deadline or timing seam route" "deadline or timing seam" "$ERR"
assert_contains "deny names the CI route" "CI run" "$ERR"
assert_contains "deny names the test VM route" "test VM" "$ERR"
case "$ERR" in
    *scripts/*|*quiet-run*|*QUIET_RUN*)
        echo "FAIL load deny names a himmel script: $ERR"
        FAILED=$((FAILED + 1)) ;;
    *) echo "PASS load deny names no himmel script" ;;
esac
n=$(jq -c 'select(.decision == "deny" and .shape == "script-file")' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "script-file deny writes one JSONL row" 1 "$n"
run_case "$(j_bash "cd $SCR && python3 spin.py")" "$TMP/repo"
assert_eq "deny: a python file with while True: pass" 2 "$RC"
run_case "$(j_bash "python3 $SCR/pin.py")" "$TMP/repo"
assert_eq "deny: a python file pinning a suite with taskset" 2 "$RC"
run_case "$(j_bash "python3 -c 'while True: pass'")" "$TMP/repo"
assert_eq "deny: inline python while True: pass" 2 "$RC"
run_case "$(j_bash "node -e 'for (;;) {}'")" "$TMP/repo"
assert_eq "deny: inline node for (;;) {}" 2 "$RC"
run_case "$(j_bash "bash -c 'while :; do :; done' &")" "$TMP/repo"
assert_eq "deny: bash -c sleepless loop" 2 "$RC"
run_case "$(j_bash "taskset -c 0 bash test-suite.sh")" "$TMP/repo"
assert_eq "deny: taskset pinning a suite" 2 "$RC"
run_case "$(j_bash "cd /x && timeout 60 numactl --physcpubind=0 bash test-suite.sh")" "$TMP/repo"
assert_eq "deny: numactl behind timeout" 2 "$RC"
run_case "$(j_bash "stress-ng --cpu 4 --timeout 60s")" "$TMP/repo"
assert_eq "deny: stress-ng" 2 "$RC"
run_case "$(j_bash "stress --vm 2 --vm-bytes 1G")" "$TMP/repo"
assert_eq "deny: stress memory hog" 2 "$RC"
run_case "$(j_bash "yes > /dev/null &")" "$TMP/repo"
assert_eq "deny: yes to /dev/null" 2 "$RC"
run_case "$(j_bash "dd if=/dev/zero of=/dev/null bs=1M")" "$TMP/repo"
assert_eq "deny: dd zero to /dev/null" 2 "$RC"

run_case "$(j_bash "bash test-suite.sh; sleep 5; bash test-suite.sh")" "$TMP/repo"
assert_eq "allow: a normal suite run with sleep" 0 "$RC"
run_case "$(j_bash "python3 $SCR/ok.py")" "$TMP/repo"
assert_eq "allow: a python file that sleeps and says stress" 0 "$RC"
run_case "$(j_bash "bash $SCR/wait.sh 1234")" "$TMP/repo"
assert_eq "allow: a bash file with a kill -0 wait loop" 0 "$RC"
run_case "$(j_bash "for i in 1 2 3; do bash test-suite.sh; done")" "$TMP/repo"
assert_eq "allow: a finite for loop of suite runs" 0 "$RC"
run_case "$(j_bash "git grep -n taskset docs && git commit -m 'stress-ng docs: taskset'")" "$TMP/repo"
assert_eq "allow: a tool name as an argument or in a message" 0 "$RC"
run_case "$(j_bash "bash -c 'exec taskset -c 0 yes'")" "$TMP/repo"
assert_eq "deny: taskset behind exec inside bash -c" 2 "$RC"
run_case "$(j_bash "sh -lc 'yes > /dev/null'")" "$TMP/repo"
assert_eq "deny: yes to /dev/null inside sh -lc" 2 "$RC"
run_case "$(j_bash "\"taskset\" -c 0 bash suite.sh")" "$TMP/repo"
assert_eq "deny: a quoted taskset as the command word" 2 "$RC"
run_case "$(j_bash "bash -c 'echo \"; taskset -c 0\"'")" "$TMP/repo"
assert_eq "allow: a quoted message inside bash -c" 0 "$RC"
run_case "$(j_bash "git grep -n 'taskset' docs; git commit -m 'stress'; grep -e 'numactl' f")" "$TMP/repo"
assert_eq "allow: a quoted tool name as a grep pattern or a message" 0 "$RC"
run_case "$(j_bash "for i in 1 2 3 4; do yes > /dev/null & done")" "$TMP/repo"
assert_eq "deny: yes to /dev/null as a for-loop body" 2 "$RC"
run_case "$(j_bash "for c in 0 1 2 3; do taskset -c \$c bash suite.sh & done")" "$TMP/repo"
assert_eq "deny: taskset as a for-loop body" 2 "$RC"
run_case "$(j_bash "if true; then stress-ng --cpu 8; fi")" "$TMP/repo"
assert_eq "deny: stress-ng after then" 2 "$RC"
run_case "$(j_bash "bash -c 'if true; then stress-ng --cpu 8; fi'")" "$TMP/repo"
assert_eq "deny: stress-ng after then inside bash -c" 2 "$RC"
run_case "$(j_bash "for f in a b; do echo stress-ng then taskset; done")" "$TMP/repo"
assert_eq "allow: tool names as echo operands in a loop body" 0 "$RC"
run_case "$(j_bash "git add $SCR/load_run.py; rm $SCR/load_run.py; cat $SCR/spin.sh")" "$TMP/repo"
assert_eq "allow: a load script named as a git add, rm or cat operand" 0 "$RC"
run_case "$(j_bash "python3 -W ignore $SCR/spin.py")" "$TMP/repo"
assert_eq "deny: a python file behind an option that takes an argument" 2 "$RC"
run_case "$(j_bash "bash < $SCR/spin.sh")" "$TMP/repo"
assert_eq "deny: a bash file fed to bash on stdin" 2 "$RC"
run_case "$(j_bash "cat < $SCR/spin.sh > out.txt")" "$TMP/repo"
assert_eq "allow: a load script as a redirect target of cat" 0 "$RC"
run_case "$(j_bash "git commit -m 'stress-ng --cpu 4 example'")" "$TMP/repo"
assert_eq "allow: a commit message naming a load tool and a flag" 0 "$RC"
mkdir -p "$TMP/repo/sub0"
cp "$SCR/spin.sh" "$TMP/repo/rootspin.sh"
run_case "$(j_bash "(cd sub0 && :); bash rootspin.sh")" "$TMP/repo"
assert_eq "deny: a cd inside a subshell leaves the parent base for the script scan" 2 "$RC"
run_case "$(j_bash "bash > $SCR/spin.sh; python3 -m py_compile $SCR/spin.py")" "$TMP/repo"
assert_eq "allow: a load script as an output redirect target or a py_compile operand" 0 "$RC"
run_case "$(j_bash "bash -e $SCR/spin.sh")" "$TMP/repo"
assert_eq "deny: a shell -e flag still runs the load script after it" 2 "$RC"
run_case "$(j_bash "bash -c \"bash $SCR/spin.sh\"")" "$TMP/repo"
assert_eq "deny: a bash file run inside a bash -c string" 2 "$RC"
run_case "$(j_bash "for f in x; do bash $SCR/spin.sh; done")" "$TMP/repo"
assert_eq "deny: a bash file holding a sleepless loop run in a loop body" 2 "$RC"
run_case "$(j_bash "yes | head -3; dd if=a.img of=/dev/null")" "$TMP/repo"
assert_eq "allow: yes into a pipe, dd of a file" 0 "$RC"
run_case "$(j_bash "python3 $SCR/missing.py")" "$TMP/repo"
assert_eq "allow: a missing script file fails open" 0 "$RC"
printf '#!/usr/bin/env bash\necho "while :; do :; done"\n' >"$TMP/repo/test-tracked.sh"
git -C "$TMP/repo" add test-tracked.sh
run_case "$(j_bash "bash test-tracked.sh")" "$TMP/repo"
assert_eq "allow: a tracked suite carrying a loop as payload text" 0 "$RC"
mkdir -p "$TMP/repo/sub"
cp "$SCR/spin.sh" "$TMP/repo/sub/spin.sh"
ln -s sub/spin.sh "$TMP/repo/link-in.sh"
ln -s "$SCR/spin.sh" "$TMP/repo/link-out.sh"
run_case "$(j_bash "bash link-in.sh")" "$TMP/repo"
assert_eq "deny: a symlinked script whose target is inside the cwd" 2 "$RC"
run_case "$(j_bash "bash link-out.sh")" "$TMP/repo"
assert_eq "allow: a symlinked script whose target is outside the cwd is not read" 0 "$RC"

# A himmel session: the project chain's require-quiet-run.sh leaves the busy
# loop alone and the plugin hook refuses it, one deny and one JSONL row.
quiet_run="$HIMMEL_ROOT/scripts/hooks/require-quiet-run.sh"
if [ -f "$quiet_run" ]; then
    printf '%s' "$busy_payload" | bash "$quiet_run" >/dev/null 2>&1
    assert_eq "himmel chain: require-quiet-run.sh allows the busy loop" 0 "$?"
    run_case "$busy_payload" "$HIMMEL_ROOT"
    assert_eq "himmel chain: plugin hook denies" 2 "$RC"
    assert_eq "himmel chain: one JSONL row" 1 "$(rows)"
else
    echo "SKIP himmel chain: no require-quiet-run.sh at $quiet_run"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All block-busy-loop.sh cases passed."
    exit 0
fi
echo "$FAILED case(s) failed."
exit 1
