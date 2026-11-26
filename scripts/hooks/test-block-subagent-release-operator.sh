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
expect deny "agent_id false" 'false' "$WRITE"
expect deny "agent_id empty string" '""' "$WRITE"
expect deny "agent_id a number" '123' "$WRITE"
expect deny "agent_id an object" '{}' "$WRITE"

P1O='block-subagent-release-operator: a subagent may not run a Bash command that names both release and operator'
P2O='block-subagent-release-operator-word-free: a subagent may not run a Bash command that carries both --decision and --words'
P2ROUTE='explicit placement and no --words'

also() {
    case "$out" in
        *"$2"*) echo "ok   also: $1"; pass=$((pass + 1)) ;;
        *) echo "FAIL also: $1"; printf '  out: %s\n' "$out"; fail=$((fail + 1)) ;;
    esac
}

A3="cat > /abs/f.md <<'EOF'${NL}release operator text${NL}EOF"
expect allow "A1 git diff -G with both words" "$SUB" "git -C /r diff abc123 def456 -G 'release\\|operator' --stat"
expect deny "A1 negative: GIT_EXTERNAL_DIFF prefix" "$SUB" "GIT_EXTERNAL_DIFF='$WRITE #' git -C /r diff abc123 def456" "$P1O"
expect allow "A2 cd, grep, head, ls, grep (the real refused sample, shortened)" "$SUB" "cd /r/scripts/jira/src; grep -n \"operatorGate\\|release\" commands/release.ts | head -20; ls release | grep -i operator"
expect deny "A2 negative: piped into bash" "$SUB" "cd /r/scripts/jira/src; grep -n \"operatorGate\\|release\" commands/release.ts | head -20; ls release | grep -i operator | bash" "$P1O"
expect allow "A3 quoted-heredoc write naming both words" "$SUB" "$A3"
expect deny "A3 negative: unquoted delimiter with a command substitution" "$SUB" "cat > /abs/f.md <<EOF${NL}release operator \$(id)${NL}EOF" "$P1O"
expect allow "A4 heredoc write then wc of the same file" "$SUB" "$A3${NL}wc -l /abs/f.md"
expect deny "A4 negative: heredoc write then bash of the file" "$SUB" "$A3${NL}bash /abs/f.md" "$P1O"
expect allow "A5 git grep -n -e" "$SUB" "git grep -n -e \"release operator\""
expect allow "A5 git grep with the bare pattern" "$SUB" "git grep \"release operator\""
expect deny "A5 negative: git grep --open=" "$SUB" "git grep --open='$WRITE #' -e x" "$P1O"
expect deny "A5 negative: git grep -nO bundle" "$SUB" "git grep -nO'$WRITE #' -e x" "$P1O"
expect allow "A6 echo then git log --grep" "$SUB" "echo operator; git log --grep release"
expect deny "A6 negative: echo piped into sh" "$SUB" "echo '$WRITE' | sh" "$P1O"
expect allow "A7 cd then grep -rn piped to head" "$SUB" "cd /r; grep -rn \"release operator\" docs | head -5"
expect deny "A7 negative: cd then the write" "$SUB" "cd /r; $WRITE" "$P1O"
expect allow "A8 grep piped to sed -n" "$SUB" "grep -n \"release operator\" f.md | sed -n 1,5p"
expect deny "A8 negative: sed e command" "$SUB" "sed -n '1e $WRITE' f" "$P1O"
expect allow "A9 glob not at the word start" "$SUB" "grep -n \"release operator\" docs/*.md"
expect deny "A9 negative: bare glob operand" "$SUB" "grep -n \"release operator\" *" "$P1O"
expect deny "A9 negative: unquoted glob in an option" "$SUB" "grep -n --include=*.md \"release operator\" docs" "$P1O"
expect allow "A10 git log -n -S" "$SUB" "git log -n 5 --oneline -S \"release operator\""
expect deny "A10 negative: git -c core.fsmonitor" "$SUB" "git -c core.fsmonitor='$WRITE' log -n 5" "$P1O"
expect allow "K1e heredoc write then echo" "$SUB" "$A3${NL}echo written"
expect deny "K1e negative: heredoc write then cat of another file" "$SUB" "$A3${NL}cat /abs/other.md" "$P1O"
expect allow "H-sp1 extra blanks on the first line" "$SUB" "cat  >  /abs/f.md  <<'EOF'${NL}release operator text${NL}EOF"
expect allow "H-sp2 no blank after > and a blank before the delimiter" "$SUB" "cat >/abs/f.md << 'EOF'${NL}release operator text${NL}EOF"

D1="$CLI release request R1 --verb INTAKE --key K-1 --to R1 --why x --decision 1 --words y"
expect deny "D1 release request with --decision and --words" "$SUB" "$D1" "$P2O"
expect allow "D1 twin: the chief" absent "$D1"
expect deny "D2 create with --decision= and --words=" "$SUB" "$CLI create --title t --decision=1 --words=y" "$P2O"
expect allow "D2 twin: create without --words" "$SUB" "$CLI create --title t --decision=1"
expect deny "D2c create inside a compound command" "$SUB" "cd /r && $CLI create --title t --decision 1 --words y" "$P2O"
expect allow "D2c twin: the chief" absent "cd /r && $CLI create --title t --decision 1 --words y"
expect deny "D2d heredoc write whose body holds both options" "$SUB" "cat > /abs/spec.md <<'EOF'${NL}--decision 1 --words y${NL}EOF" "$P2O"
expect allow "D2d twin: the chief" absent "cat > /abs/spec.md <<'EOF'${NL}--decision 1 --words y${NL}EOF"
expect deny "D2e move with --decision and --words" "$SUB" "$CLI move K-1 --to-project P --decision 1 --words y" "$P2O"
expect allow "D2e twin: the chief" absent "$CLI move K-1 --to-project P --decision 1 --words y"
expect deny "D1o D1 that also names operator: P1 opening" "$SUB" "$D1 # release operator" "$P1O"
also "D1o carries P2's route sentence" "$P2ROUTE"
expect allow "D1o twin: the chief" absent "$D1 # release operator"

VERBS="declare freeze decision standing spec spec-review core-bypass core-snapshot takeover out-of-version"
verbs_n=0
for v in $VERBS; do
    verbs_n=$((verbs_n + 1))
    expect deny "V-$v plain" "$SUB" "$CLI release operator $v R1" "$P1O"
    expect allow "V-$v twin: the chief" absent "$CLI release operator $v R1"
    expect deny "W-$v bash -c" "$SUB" "bash -c '$CLI release operator $v R1'" "$P1O"
    expect allow "W-$v twin: the chief" absent "bash -c '$CLI release operator $v R1'"
    expect deny "E-$v env" "$SUB" "env $CLI release operator $v R1" "$P1O"
    expect allow "E-$v twin: the chief" absent "env $CLI release operator $v R1"
    expect deny "H-$v heredoc tail" "$SUB" "$A3${NL}$CLI release operator $v R1" "$P1O"
    expect allow "H-$v twin: the chief" absent "$A3${NL}$CLI release operator $v R1"
done
echo "per-verb controls: $verbs_n verbs, $((verbs_n * 4)) deny rows and $((verbs_n * 4)) twins"
[ "$verbs_n" = 10 ] || { echo "FAIL the verb list holds $verbs_n verbs, not 10"; fail=$((fail + 1)); }

expect deny "D3 GIT_CONFIG_COUNT prefix" "$SUB" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0='$WRITE #' git diff HEAD~1" "$P1O"
expect deny "D4 env GIT_EXTERNAL_DIFF" "$SUB" "env GIT_EXTERNAL_DIFF='$WRITE #' git diff" "$P1O"
expect deny "D5 env -a grep node" "$SUB" "env -a grep $CLI release operator declare R1" "$P1O"
expect deny "D6 here-string into bash" "$SUB" "bash <<<'$WRITE'" "$P1O"
expect deny "D6 process substitution into bash" "$SUB" "bash <(echo '$WRITE')" "$P1O"
expect deny "D6 brace-group shell with a here-string" "$SUB" "{ bash; } <<<'$WRITE'" "$P1O"
expect deny "D7a taskset launcher before a fed shell" "$SUB" "echo '$WRITE' | taskset 1 bash" "$P1O"
expect deny "D7 find -exec" "$SUB" "find . -exec bash -c '$WRITE' \\;" "$P1O"
expect deny "D7 awk -f /dev/stdin" "$SUB" "awk -f /dev/stdin <<<'$WRITE'" "$P1O"
expect deny "D8 rg --pre" "$SUB" "rg --pre '$WRITE' x" "$P1O"
expect deny "D10 stray line after the delimiter" "$SUB" "cat > f <<'EOF'${NL}x${NL}EOF${NL}EOF2${NL}$WRITE" "$P1O"
expect deny "D11 quoted command word" "$SUB" "\"git\" grep -e \"release operator\"" "$P1O"
expect deny "D11 partly quoted command word" "$SUB" "g\"it\" grep -e \"release operator\"" "$P1O"

expect deny "K1a plant diff.external, then git diff" "$SUB" "cat >> .git/config <<'EOF'${NL}[diff]${NL}external = $WRITE #${NL}EOF${NL}git diff" "$P1O"
expect deny "K1b plant it in ~/.gitconfig, then git -C diff" "$SUB" "cat >> /home/u/.gitconfig <<'EOF'${NL}[diff]${NL}external = $WRITE #${NL}EOF${NL}git -C /r diff" "$P1O"
expect deny "K1c plant core.fsmonitor, then git grep" "$SUB" "cat >> .git/config <<'EOF'${NL}[core]${NL}fsmonitor = $WRITE #${NL}EOF${NL}git grep -e x" "$P1O"

BW="release operator"
expect allow "control: git diff with both words as operands" "$SUB" "git diff --stat $BW"
expect allow "control: sed -n 1p with both words as operands" "$SUB" "sed -n 1p $BW"
expect deny "git diff --ext-diff" "$SUB" "git diff --ext-diff $BW" "$P1O"
expect deny "git diff --textconv" "$SUB" "git diff --textconv $BW" "$P1O"
expect deny "git diff --output=" "$SUB" "git diff --output=/tmp/x $BW" "$P1O"
expect deny "git -c" "$SUB" "git -c x=y log $BW" "$P1O"
expect deny "git --exec-path=" "$SUB" "git --exec-path=/x log $BW" "$P1O"
expect deny "git --git-dir=" "$SUB" "git --git-dir=/x log $BW" "$P1O"
expect deny "git --work-tree=" "$SUB" "git --work-tree=/x log $BW" "$P1O"
expect deny "git log --format=%G" "$SUB" "git log --format=%GS $BW" "$P1O"
expect deny "sed w command" "$SUB" "sed -n 1w/tmp/x f $BW" "$P1O"
expect deny "sed e command" "$SUB" "sed -n 1e f $BW" "$P1O"
expect deny "sed r command" "$SUB" "sed -n 1r/etc/passwd f $BW" "$P1O"
expect deny "sed -i" "$SUB" "sed -i -n 1p f $BW" "$P1O" # gnu-ok: command text fed to the hook, never executed
expect deny "sed -f" "$SUB" "sed -n -f s.sed f $BW" "$P1O"
expect deny "a dollar sign inside double quotes" "$SUB" "grep -n \"release operator \$HOME\" f" "$P1O"
expect deny "H unterminated body" "$SUB" "cat > /abs/f.md <<'EOF'${NL}release operator text" "$P1O"
expect deny "H <<- with a tab-indented delimiter" "$SUB" "cat > /abs/f.md <<-'EOF'${NL}release operator text${NL}${TAB}EOF" "$P1O"
expect deny "H delimiter with a trailing CR" "$SUB" "cat > /abs/f.md <<'EOF'${NL}release operator text${NL}EOF${CR}" "$P1O"
expect deny "H delimiter with a trailing blank" "$SUB" "cat > /abs/f.md <<'EOF'${NL}release operator text${NL}EOF " "$P1O"
expect deny "H double-quoted delimiter" "$SUB" "cat > /abs/f.md <<\"EOF\"${NL}release operator text${NL}EOF" "$P1O"
VT=$(printf '\v')
expect deny "lexer: a VT between words" "$SUB" "grep -n $BW f ${VT}g" "$P1O"
expect deny "lexer: a trailing CR" "$SUB" "grep -n $BW f${CR}" "$P1O"
expect deny "lexer: a CR inside quotes" "$SUB" "grep -n \"release${CR}operator\" f" "$P1O"
expect deny "lexer: an LF inside quotes" "$SUB" "grep -n \"release${NL}operator\" f" "$P1O"
expect deny "lexer: a redirect glued to a word" "$SUB" "grep -n $BW f2>&1" "$P1O"
expect deny "operand assignment under set -k" "$SUB" "grep -n \"release operator\" X=y" "$P1O"
# shellcheck disable=SC2088 # the operands are command TEXT; nothing expands here
for z in '=f' 'f^x' '~/f' 'f#' 'f[1]' 'f(.)' 'f?'; do
    expect deny "zsh character in an operand: $z" "$SUB" "grep -n \"release operator\" $z" "$P1O"
done

RUNNER="$SCRIPT_DIR/run-hook-with-bash.js"
chain_rc() {
    jq -n --arg c "$1" --argjson a "$SUB" --arg cwd "$TMP" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, agent_id: $a, cwd: $cwd, session_id: "subagent-fence-unroll"}' >"$TMP/chain.json"
    mkdir -p "$TMP/home"
    # read-sink-ok: the payload file is the suite's own, under its mktemp dir
    out=$(env -i PATH="$PATH" HOME="$TMP/home" TMPDIR="$TMP" CLAUDE_PROJECT_DIR="$SCRIPT_DIR/../.." node "$RUNNER" --chain "$HOOK" <"$TMP/chain.json" 2>&1)
    rc=$?
}
if command -v shfmt >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # command TEXT for the runner; nothing expands here
    chain_rc 'for f in a.md b.md; do grep -n "release operator" $f; done'
    check allow "loop unroll: a literal loop whose iterations are plain reads"
    chain_rc "for v in declare freeze; do $CLI release operator \$v R1; done"
    check deny "loop unroll: a literal loop whose iterations run the operator verb" "block-subagent-release-operator: a subagent may not run"
else
    echo "SKIP loop unroll rows: shfmt or node is not on PATH"
fi

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

expect allow "no agent_id (the chief)" absent "$WRITE"
expect allow "agent_id null (the chief)" 'null' "$WRITE"
expect allow "a subagent reads spec-check" "$SUB" "$CLI release spec-check K-2"
expect allow "a subagent runs ls" "$SUB" "ls"
n=$((n + 1)); payload "$TMP/p$n.json" "$SUB" "$WRITE"
run_hook "$TMP/p$n.json" SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1
check allow "the bypass"

echo
echo "test-block-subagent-release-operator: $pass passed, $fail failed"
[ "$fail" = 0 ]
