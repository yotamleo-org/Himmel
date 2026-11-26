#!/usr/bin/env bash
# Tests for scripts/hooks/block-subagent-release-operator.sh.
#
# Usage: bash scripts/hooks/test-block-subagent-release-operator.sh
#
# Every row feeds a real payload to the real hook and asserts on its exit status
# and output. Each payload is built with jq, so a TAB, a newline or a backslash in
# the command reaches the hook JSON-encoded, as Claude Code sends it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-subagent-release-operator.sh"

BASH_ABS=$(command -v bash)
command -v jq >/dev/null 2>&1 || { echo "FATAL: the suite needs jq to build payloads" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-subagent-release-operator.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
CLI='node /repo/scripts/jira/dist/index.js'
TAB=$(printf '\t')
CR=$(printf '\r')
NL=$'\n'

# run_hook <stdin-file> [env...] — sets rc and out (stdout + stderr).
run_hook() {
    local input="$1"; shift
    # read-sink-ok: every caller passes a payload file the suite wrote under its own mktemp dir
    out=$(env -u SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE "$@" "$BASH_ABS" "$HOOK" <"$input" 2>&1)
    rc=$?
}

payload() {  # payload <file> <agent_id JSON or "absent"> <command>
    if [ "$2" = absent ]; then
        jq -n --arg c "$3" '{tool_name: "Bash", tool_input: {command: $c}}' >"$1"
    else
        jq -n --arg c "$3" --argjson a "$2" '{tool_name: "Bash", tool_input: {command: $c}, agent_id: $a}' >"$1"
    fi
}

n=0
expect() {  # expect <deny|allow> <label> <agent_id JSON or absent> <command> [needle]
    n=$((n + 1))
    payload "$TMP/p$n.json" "$3" "$4"
    run_hook "$TMP/p$n.json"
    check "$1" "$2" "${5:-}"
}

check() {  # check <deny|allow> <label> [needle] — reads rc and out
    local want="$1" label="$2" needle="${3:-}"
    if [ "$want" = deny ]; then
        if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"' \
            && printf '%s' "$out" | grep -qF "${needle:-SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1}"; then
            echo "ok   deny: $label"; pass=$((pass + 1))
        else
            echo "FAIL deny: $label (rc=$rc)"; printf '  out: %s\n' "$out"; fail=$((fail + 1))
        fi
    else
        if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q deny; then
            echo "ok   allow: $label"; pass=$((pass + 1))
        else
            echo "FAIL allow: $label (rc=$rc)"; printf '  out: %s\n' "$out"; fail=$((fail + 1))
        fi
    fi
}

SUB='"a1"'
WRITE="$CLI release operator spec-review R1 --keys K-2 --spec s.md --plan p.md --verdict s.md.critic-spec-r1.md"

expect deny "a subagent cannot write an operator row" "$SUB" "$WRITE"
expect deny "a subagent cannot write an operator row: names the rule" "$SUB" "$WRITE" "only the main session"

expect deny "release operator spec" "$SUB" "$CLI release operator spec R1 --keys K-2"
expect deny "release operator core-bypass" "$SUB" "$CLI release operator core-bypass R1 --keys K-2"
expect deny "single-quoted word" "$SUB" "$CLI release 'operator' spec R1"
expect deny "double-quoted word" "$SUB" "$CLI release \"operator\" spec R1"
expect deny "backslash inside the word" "$SUB" "$CLI release o\\perator spec R1"
expect deny "TAB between the words" "$SUB" "$CLI release${TAB}operator spec R1"
expect deny "CRLF line ending after the word" "$SUB" "$CLI release operator${CR}${NL}echo hello"
expect deny "backslash-newline between the words" "$SUB" "$CLI release \\${NL}operator spec R1"
expect deny "ANSI-C quoted word" "$SUB" "$CLI release \$'operator' spec R1"
expect deny "bash -c string" "$SUB" "bash -c \"$CLI release operator spec R1\""
expect deny "node on the dist directory" "$SUB" "node scripts/jira/dist release operator spec R1"
expect deny "cd then node ." "$SUB" "cd scripts/jira/dist && node . release operator spec R1"
expect deny "node on index without .js" "$SUB" "node scripts/jira/dist/index release operator spec R1"
expect deny "the jira bin" "$SUB" "jira release operator spec R1"
expect deny "xargs supplies the verb" "$SUB" "printf 'spec-review R1 --keys K-2' | xargs $CLI release operator"
expect deny "xargs supplies both words" "$SUB" "printf 'release operator spec-review R1' | xargs $CLI"
expect deny "a brace group feeds xargs" "$SUB" "{ echo release; echo operator spec-review R1; } | xargs $CLI"
expect deny "the words in reverse order" "$SUB" "printf operator | xargs -I{} $CLI release {} spec-review R1"
expect deny "2>&1 between the words" "$SUB" "$CLI release 2>&1 operator spec R1"
expect deny ">&2 between the words" "$SUB" "$CLI release >&2 operator spec R1"
expect deny "&>f between the words" "$SUB" "$CLI release &>f operator spec R1"
expect deny "release>f with no space" "$SUB" "$CLI release>f operator spec R1"
expect deny "--help after the verb" "$SUB" "$CLI release operator spec --help"
expect deny "-h on operator" "$SUB" "$CLI release operator -h"
expect deny "-h and --help as option values" "$SUB" "$CLI release operator spec-review R1 --spec -h --verdict --help"
expect deny "--help as the verdict value" "$SUB" "$CLI release operator spec-review R1 --verdict --help"
for verb in declare freeze decision takeover standing spec-signer; do
    V="$CLI release operator $verb R1 --versions v1.1.3 --decision 214"
    expect deny "verb $verb: plain" "$SUB" "$V"
    expect deny "verb $verb: bash -c" "$SUB" "bash -c \"$V\""
    expect deny "verb $verb: env, timeout and sudo wrappers" "$SUB" "env X=1 timeout 5 sudo -n $V"
    expect deny "verb $verb: sh -c with single quotes" "$SUB" "sh -c '$V'"
    expect deny "verb $verb: nested bash -c" "$SUB" "bash -c \"bash -c '$V'\""
    expect deny "verb $verb: eval" "$SUB" "eval \"$V\""
    expect deny "verb $verb: after a pipe" "$SUB" "echo go | $V"
    expect deny "verb $verb: command substitution" "$SUB" "echo \$($V)"
    expect deny "verb $verb: xargs supplies the verb" "$SUB" "echo $verb R1 | xargs $CLI release operator"
    expect deny "verb $verb: a heredoc fed to bash" "$SUB" "bash <<'EOF'${NL}$V${NL}EOF"
    expect deny "verb $verb: a heredoc piped to bash" "$SUB" "cat <<'EOF' | bash${NL}$V${NL}EOF"
done
RO="$CLI release operator declare R1"
expect deny "echo piped to bash" "$SUB" "echo '$RO' | bash"
expect deny "printf piped to sh" "$SUB" "printf '%s\\n' '$RO' | sh"
AMP='&'
expect deny "echo piped to bash with the stderr pipe" "$SUB" "echo '$RO' |$AMP bash"
expect deny "a here-string fed to bash" "$SUB" "bash <<<'$RO'"
expect deny "a here-string fed to node" "$SUB" "node - <<<\"require('child_process').execSync('$RO')\""
expect deny "bash reads a process substitution" "$SUB" "bash <(echo '$RO')"
expect deny "source reads a process substitution" "$SUB" "source <(echo '$RO')"
expect deny "dot reads a process substitution" "$SUB" ". <(printf '%s\\n' '$RO')"
expect deny "a pipe into a subshell around bash" "$SUB" "echo '$RO' | (bash)"
expect deny "a pipe into an if body that runs bash" "$SUB" "echo '$RO' | if true; then bash; fi"
expect deny "a brace group around bash with a here-string" "$SUB" "{ bash; } <<<'$RO'"
expect deny "an fd here-string then bash reading the fd" "$SUB" "exec 3<<<'$RO'; bash <&3"
expect deny "script -qc runs its argument" "$SUB" "script -qc \"$RO\" /dev/null"
expect deny "flock -c runs its argument" "$SUB" "flock /tmp/l -c \"$RO\""
expect deny "watch runs its argument" "$SUB" "watch -n 1 '$RO'"
expect deny "taskset launcher with an empty expansion between the words" "$SUB" "taskset 1 $CLI release \$EMPTY operator declare R1"
expect deny "strace launcher with an empty expansion between the words" "$SUB" "strace -o /dev/null $CLI release \$EMPTY operator declare R1"
expect deny "a variable command word with an empty expansion between the words" "$SUB" "\$CLI release \$EMPTY operator declare R1"
expect deny "sed e command runs the words" "$SUB" "sed -n '1e $RO' /dev/null"
expect deny "rg --pre runs the words" "$SUB" "rg --pre \"$RO\" x ."
expect deny "git grep --open-files-in-pager runs the words" "$SUB" "git grep --open-files-in-pager=\"$RO\" x"
expect deny "git -c alias runs the words" "$SUB" "git -c alias.zz=\"!$RO\" zz"
expect deny "node -e with the words inside the code string" "$SUB" "node -e \"require('child_process').execSync('$CLI release operator declare R1')\""
expect deny "python3 -c with the words inside the code string" "$SUB" "python3 -c \"import os; os.system('$CLI release operator declare R1')\""
expect deny "a refusal names grep as the route" "$SUB" "$WRITE" "quote it as one argument to grep or git grep"
expect deny "agent_id false" 'false' "$WRITE"
expect deny "agent_id empty string" '""' "$WRITE"
expect deny "agent_id a number" '123' "$WRITE"
expect deny "agent_id an object" '{}' "$WRITE"

# Fail closed: no jq on PATH. The PATH holds a link to every external tool the hook's source
# names except jq (bash included), so the row tests the deny text, not a 127.
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for w in bash $(grep -v '^[[:space:]]*#' "$HOOK" | grep -oE '[a-z][a-z0-9_-]+' | sort -u); do
    [ "$w" = jq ] && continue
    p=$(type -P "$w" 2>/dev/null) || continue
    [ -e "$NOJQ/$w" ] || ln -s "$p" "$NOJQ/$w"
done
[ ! -e "$NOJQ/jq" ] || { echo "FATAL: jq leaked into the no-jq PATH" >&2; exit 1; }
n=$((n + 1)); payload "$TMP/p$n.json" "$SUB" "$WRITE"
run_hook "$TMP/p$n.json" PATH="$NOJQ"
check deny "no jq: the matching command" "cannot read the hook input without jq"
n=$((n + 1)); payload "$TMP/p$n.json" "$SUB" "ls"
run_hook "$TMP/p$n.json" PATH="$NOJQ"
check deny "no jq: ls" "cannot read the hook input without jq"

for raw in 'not json release operator' '[]' '"x"' ''; do
    n=$((n + 1)); printf '%s' "$raw" >"$TMP/p$n.json"
    run_hook "$TMP/p$n.json"
    check deny "stdin '$raw'" "cannot parse the hook input"
done

n=$((n + 1)); payload "$TMP/p$n.json" absent "ls"; payload "$TMP/q$n.json" "$SUB" "$WRITE"; cat "$TMP/q$n.json" >>"$TMP/p$n.json"
run_hook "$TMP/p$n.json"
check deny "two JSON objects, the first with no agent_id" "cannot parse the hook input"

expect allow "no agent_id (the chief)" absent "$WRITE"
expect allow "agent_id null (the chief)" 'null' "$WRITE"
expect allow "a subagent reads spec-check" "$SUB" "$CLI release spec-check K-2"
expect allow "a subagent runs ls" "$SUB" "ls"

expect allow "git diff -G with both words in one pattern" "$SUB" "git -C /repo diff abc123 def456 -G 'release|operator|decision' --stat"
expect allow "grep -n over commands/release.ts" "$SUB" "grep -n \"operator\\|release\" scripts/jira/src/commands/release.ts"
expect allow "grep -n for the quoted phrase" "$SUB" "grep -n 'release operator' scripts/jira/src/commands/release.ts"
expect allow "a heredoc that only writes a file naming both words" "$SUB" "cat > /tmp/note.md <<'EOF'${NL}The release operator verbs write an operator-chain row.${NL}EOF"
expect allow "a heredoc with both words on separate lines" "$SUB" "cat > /tmp/note.md <<'EOF'${NL}release${NL}operator${NL}EOF"
expect allow "a heredoc whose body holds a backtick fence" "$SUB" "cat > /tmp/note.md <<'EOF'${NL}\`\`\`bash${NL}jira release operator declare R1${NL}\`\`\`${NL}EOF"
expect allow "git grep for the quoted phrase" "$SUB" "git grep \"release operator\""
expect allow "two commands, one word each" "$SUB" "echo operator; git log --grep release"
expect allow "git log --grep with the phrase" "$SUB" "git log --oneline --grep 'release operator' -n 5"
expect allow "release then operator across two segments" "$SUB" "git log --grep release | grep operator"
expect allow "a quoted pair in reverse order" "$SUB" "grep -rn 'operator release' docs"
expect allow "rg over the two words in one pattern" "$SUB" "rg -n 'release|operator' scripts/jira/src"
n=$((n + 1)); payload "$TMP/p$n.json" "$SUB" "$WRITE"
run_hook "$TMP/p$n.json" SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1
check allow "the bypass"

echo
echo "test-block-subagent-release-operator: $pass passed, $fail failed"
[ "$fail" = 0 ]
