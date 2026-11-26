#!/usr/bin/env bash
# Tests for scripts/hooks/block-station-load-test.sh.
#
# Usage: bash scripts/hooks/test-block-station-load-test.sh
#
# Every row feeds a real payload to the real hook and asserts on its exit status
# and output. The loaded-runs rows replay a captured scratchpad script: one busy
# loop per core, then the suite run in the foreground.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-station-load-test.sh"

BASH_ABS=$(command -v bash)
command -v jq >/dev/null 2>&1 || { echo "FATAL: the suite needs jq to build payloads" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-station-load-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
n=0
SUITE=scripts/handover/chief-kit/test-chief-wait-stream.sh
NEEDLE="decision 1309"

run_hook() {
    local input="$1"; shift
    # read-sink-ok: every caller passes a payload file the suite wrote under its own mktemp dir
    out=$(env -u HIMMEL_WORKER "$@" "$BASH_ABS" "$HOOK" <"$input" 2>&1)
    rc=$?
}

payload() {
    jq -n --arg c "$3" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' >"$1"
}

check() {
    local want="$1" label="$2" needle="${3:-$NEEDLE}"
    if [ "$want" = deny ]; then
        if [ "$rc" = 2 ] && grep -q '"permissionDecision":"deny"' <<<"$out" \
            && grep -qF "$needle" <<<"$out"; then
            echo "ok   deny: $label"; pass=$((pass + 1))
        else
            echo "FAIL deny: $label (rc=$rc)"; printf '  out: %s\n' "$out"; fail=$((fail + 1))
        fi
    else
        if [ "$rc" = 0 ] && ! grep -q deny <<<"$out"; then
            echo "ok   allow: $label"; pass=$((pass + 1))
        else
            echo "FAIL allow: $label (rc=$rc)"; printf '  out: %s\n' "$out"; fail=$((fail + 1))
        fi
    fi
}

expect() {
    n=$((n + 1))
    payload "$TMP/p$n.json" "$TMP" "$3"
    run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
    check "$1" "$2" "${4:-}"
}

SCR="$TMP/scratchpad"
mkdir -p "$SCR"
cat >"$SCR/loaded-runs.sh" <<'LOADED'
#!/usr/bin/env bash
# usage: loaded-runs.sh <suite path relative to worktree> <runs> <log>
# Runs the suite <runs> times back to back under <nproc> busy loops; one PASS/FAIL line per run.
W=/path/to/the/worktree
suite="$1"; runs="$2"; log="$3"
cores="$(nproc)"
pids=""
i=0
while [ "$i" -lt "$cores" ]; do
    ( while :; do :; done ) &
    pids="$pids $!"
    i=$((i + 1))
done
trap 'kill $pids 2>/dev/null' EXIT
: > "$log"
echo "load: $cores busy loops, suite=$suite runs=$runs" >> "$log"
n=1
while [ "$n" -le "$runs" ]; do
    start=$(date +%s)
    ( cd "$W" && bash "$suite" ) > "$log.run$n" 2>&1
    rc=$?
    echo "run $n rc=$rc secs=$(( $(date +%s) - start ))" >> "$log"
    n=$((n + 1))
done
echo "done" >> "$log"
LOADED

cat >"$SCR/one-run.sh" <<'ONE'
#!/usr/bin/env bash
suite="$1"
bash "$suite" > "$2" 2>&1
echo "rc=$?" >> "$2"
ONE

echo "== the loaded-runs shape is refused =="
expect deny "the captured loaded-runs.sh run by bash" "bash $SCR/loaded-runs.sh $SUITE 3 $TMP/log" "script-file"
expect deny "the captured loaded-runs.sh run in the background" "bash $SCR/loaded-runs.sh $SUITE 3 $TMP/log &" "script-file"
expect deny "the captured loaded-runs.sh run after cd" "cd $SCR && bash loaded-runs.sh $SUITE 3 $TMP/log" "script-file"
expect deny "the captured loaded-runs.sh run as a command word" "bash -c 'chmod +x $SCR/loaded-runs.sh'; $SCR/loaded-runs.sh $SUITE 3 $TMP/log" "script-file"
expect deny "script-file deny names the file" "bash $SCR/loaded-runs.sh $SUITE 3 $TMP/log" "loaded-runs.sh"
expect deny "the suite in 32 background copies (for, seq)" "for i in \$(seq 32); do bash $SUITE & done; wait" "loop-fanout"
expect deny "the suite in 32 background copies (seq 1 32)" "for i in \$(seq 1 32); do bash $SUITE & done; wait" "loop-fanout"
expect deny "the suite in one copy per core (nproc)" "for i in \$(seq \"\$(nproc)\"); do bash $SUITE & done; wait" "loop-fanout"
expect deny "the suite in 32 background copies (brace range)" "for i in {1..32}; do bash $SUITE & done; wait" "loop-fanout"
expect deny "the suite in 32 background copies (counted while)" "i=0; while [ \"\$i\" -lt 32 ]; do bash $SUITE & i=\$((i+1)); done; wait" "loop-fanout"
expect deny "the suite in 32 background copies (c-style for)" "for ((i=0;i<32;i++)); do bash $SUITE & done; wait" "loop-fanout"
expect deny "two loop iterations that each start two background jobs" "for i in 1 2; do bash $SUITE & bash $SUITE & done; wait" "loop-fanout"
expect deny "the captured loaded-runs.sh path in double quotes" "bash \"$SCR/loaded-runs.sh\" $SUITE 3 $TMP/log" "script-file"
expect deny "the captured loaded-runs.sh path in single quotes" "bash '$SCR/loaded-runs.sh' $SUITE 3 $TMP/log" "script-file"
expect deny "the suite fanned out by xargs -P 32" "seq 32 | xargs -P 32 -I{} bash $SUITE" "xargs-fanout"
expect deny "the suite fanned out by xargs -P8 glued" "seq 32 | xargs -n1 -P8 bash $SUITE" "xargs-fanout"
expect deny "xargs --max-procs=16" "seq 32 | xargs --max-procs=16 -I{} bash $SUITE" "xargs-fanout"
expect deny "xargs -P 0 (unlimited)" "seq 32 | xargs -P 0 -I{} bash $SUITE" "xargs-fanout"
expect deny "parallel with no job flag (one per core)" "seq 32 | parallel bash $SUITE" "parallel:"
expect deny "parallel -j 32" "seq 32 | parallel -j 32 bash $SUITE" "parallel:"
expect deny "parallel -j0" "seq 32 | parallel -j0 bash $SUITE" "parallel:"
expect deny "parallel --jobs 200%" "seq 32 | parallel --jobs 200% bash $SUITE" "parallel:"
expect deny "four background launches in one command" "bash $SUITE & bash $SUITE & bash $SUITE & bash $SUITE & wait" "bg-fanout"
expect deny "a busy loop in the background (seed: busy-loop suite)" "bash -c 'while :; do :; done' &" "busy-loop"
expect deny "a subshell busy loop in the background" "( while :; do :; done ) &" "busy-loop"
expect deny "stress-ng (seed: busy-loop suite)" "stress-ng --cpu 4 --timeout 60s" "load-tool"
expect deny "three background launches inside a bash -c string" "bash -c \"bash $SUITE & bash $SUITE & bash $SUITE &\"" "bg-fanout"
expect deny "a quoted tool name at command position" "\"stress-ng\" --cpu 32" "load-tool"
expect deny "a quoted tool name after a pipe" "echo go | 'stress' --cpu 8" "load-tool"
expect deny "three background launches inside a double-quoted command substitution" "echo \"\$(sleep 60 & sleep 60 & sleep 60 &)\"" "bg-fanout"
expect deny "a quoted tool name after env" "env \"stress-ng\" --cpu 32" "load-tool"
expect deny "a quoted tool name after sudo" "sudo \"stress-ng\" --cpu 32" "load-tool"
expect deny "a single-quoted tool name after nohup" "nohup 'stress' -c 8 &" "load-tool"
expect deny "a quoted tool name after timeout and a duration" "timeout 60 'stress' --cpu 8" "load-tool"
expect deny "a word list continued over a backslash newline" "for i in 1 \\"$'\n'"2 3 4 5 6 7 8; do bash $SUITE & done; wait" "loop-fanout"
expect deny "stress after a pipe" "echo go | stress --cpu 8" "load-tool"
expect deny "stress in a bash -c string" "bash -c \"stress --cpu 8\"" "load-tool"
expect deny "yes to /dev/null" "yes > /dev/null" "load-tool"
expect deny "yes in the background" "yes &" "load-tool"

echo "== controls pass =="
expect allow "a single foreground suite run" "bash $SUITE"
expect allow "a single foreground suite through quiet-run" "bash scripts/quiet-run.sh suite -- bash $SUITE"
expect allow "xargs -P 2" "seq 2 | xargs -P 2 -I{} bash $SUITE"
expect allow "xargs -P 1" "seq 4 | xargs -P 1 -I{} bash $SUITE"
expect allow "xargs without -P" "git ls-files | xargs grep -l HIMMEL"
expect allow "xargs grep -P with a pattern" "git ls-files | xargs grep -P foo"  # gnu-ok: a payload string the hook reads, never run
expect allow "parallel -j 2" "seq 2 | parallel -j 2 bash $SUITE"
expect allow "parallel --jobs=1" "seq 2 | parallel --jobs=1 bash $SUITE"
expect allow "two background copies, word list" "for i in 1 2; do bash $SUITE & done; wait"
expect allow "two background copies, seq 2" "for i in \$(seq 2); do bash $SUITE & done; wait"
expect allow "two background copies, brace range" "for i in {1..2}; do bash $SUITE & done; wait"
expect allow "two background copies, counted while" "i=0; while [ \"\$i\" -lt 2 ]; do bash $SUITE & i=\$((i+1)); done; wait"
expect allow "two plain background launches" "bash $SUITE & bash $SUITE & wait"
expect allow "a loop with no background work" "for f in \$(git ls-files); do echo \$f; done"
expect allow "a counted loop in the foreground" "for i in \$(seq 32); do bash $SUITE; done"
expect allow "a loop over files with one background log tail" "for f in a b c; do echo \$f; done; tail -f x &"
expect allow "a redirect that holds an ampersand" "bash $SUITE > $TMP/log 2>&1"
expect allow "&> and && are not background launches" "bash $SUITE &> $TMP/log && echo done && echo again && echo more"
expect allow "a URL with ampersands in quotes" "curl -s 'https://example.com/x?a=1&b=2&c=3&d=4'"
expect allow "a commit message that names stress and xargs -P 32" "git commit -m 'fix stress test: no xargs -P 32 fan-out'"
expect allow "a commit message with three ampersands" "git commit -m 'safety & enforcement & proof & more'"
expect allow "a commit message that names stress with a flag" "git commit -m 'stress --cpu 8'"
expect allow "an echo with three ampersands in quotes" "echo \"a & b & c & d\""
expect allow "ampersands inside a single-quoted string never run" "echo '\$(sleep 60 & sleep 60 & sleep 60 &)'"
expect allow "a quoted word that follows a non-wrapper command" "git commit -m 'stress' --amend-none"
expect allow "a word list of two continued over a backslash newline" "for i in 1 \\"$'\n'"2; do bash $SUITE & done; wait"
expect allow "yes feeding a prompt" "yes | head -n 3"
expect allow "a foreground one-run scratchpad script" "bash $SCR/one-run.sh $SUITE $TMP/log"
expect allow "reading the loaded script is not running it" "cat $SCR/loaded-runs.sh"
expect allow "a missing script file" "bash $SCR/no-such-script.sh"
expect allow "ls" "ls"

echo "== a tracked suite is never read =="
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
n=$((n + 1)); payload "$TMP/p$n.json" "$REPO_ROOT" "bash scripts/handover/chief-kit/test-chief-wait-stream.sh"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
check allow "the committed stream suite, run from the checkout"

echo "== scope =="
n=$((n + 1)); payload "$TMP/p$n.json" "$TMP" "seq 32 | xargs -P 32 -I{} bash $SUITE"
run_hook "$TMP/p$n.json"
check allow "no HIMMEL_WORKER marker (a headed or chief session)"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=0
check allow "HIMMEL_WORKER=0"
n=$((n + 1)); jq -n '{tool_name: "Read", tool_input: {file_path: "x"}}' >"$TMP/p$n.json"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
check allow "another tool"
n=$((n + 1)); printf 'not json' >"$TMP/p$n.json"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
check allow "stdin that is not JSON (a workflow guard fails open)"
n=$((n + 1)); : >"$TMP/p$n.json"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
check allow "empty stdin"

echo "== the deny text names the allowed shape =="
n=$((n + 1)); payload "$TMP/p$n.json" "$TMP" "seq 32 | xargs -P 32 -I{} bash $SUITE"
run_hook "$TMP/p$n.json" HIMMEL_WORKER=1
check deny "names the stubbed clock" "stub the clock"
check deny "names a simulated slow tick" "simulated slow tick"
check deny "names CI" "let CI run it"
check deny "names the cap that passes" "xargs -P 2"

echo
echo "test-block-station-load-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
