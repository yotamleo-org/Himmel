#!/usr/bin/env bash
# Suite for the literal-loop unroll in scripts/hooks/run-hook-with-bash.js.
#
# Usage: bash scripts/hooks/test-run-hook-with-bash-unroll.sh
#
# A PreToolUse Bash chain judges `for NAME in w1..wn; do BODY; done` as its n
# literal iterations when the loop passes every rule in unrollableLoop(), and
# as the original text otherwise. Two sections:
#   * unit rows call unrollCommand() directly: the unrolled text for the loops
#     that qualify, null for one shape per qualifying rule (deleting a rule
#     turns its row red);
#   * chain rows run the real Bash PreToolUse members, read from
#     .claude/settings.json, through the runner: the loops a guard refused only
#     because of the loop variable are allowed, and every dangerous shape is
#     still denied.
#
# Exit codes: 0 all rows passed (or SKIP: no shfmt, so the unroll is off),
# 1 at least one failed.
# shellcheck disable=SC2016  # rows are command TEXT; nothing expands here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
RUNNER="$HERE/run-hook-with-bash.js"
SETTINGS="$ROOT/.claude/settings.json"

command -v node >/dev/null 2>&1 || { echo "FAIL fixture: node not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL fixture: jq not found"; exit 1; }
command -v shfmt >/dev/null 2>&1 || { echo "SKIP test-run-hook-with-bash-unroll: shfmt not on PATH"; exit 0; }

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hook-unroll.XXXXXX") || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

# unrolled <command> [ENV=val ...] -> GOT (the unrolled text, or NULL)
unrolled() {
    local cmd=$1; shift
    GOT=$(printf '%s' "$cmd" | env -i PATH="$PATH" "$@" node -e '
        const { unrollCommand } = require(process.argv[1]);
        const out = unrollCommand(require("fs").readFileSync(0, "utf8"));
        process.stdout.write(out === null ? "NULL" : out);' "$RUNNER")
}
unit() {  # unit <label> <expected> <command> [ENV=val ...]
    local label=$1 want=$2; shift 2
    unrolled "$@"
    if [ "$GOT" = "$want" ]; then pass "unit: $label"; else fail "unit: $label - want [$want] got [$GOT]"; fi
}
keep() {  # keep <label> <command> [ENV=val ...] -- the loop is not unrolled
    local label=$1; shift
    unit "$label" NULL "$@"
}

echo "== unit: loops that unroll =="
unit 'GREEN 1: cat of four absolute files' \
    "$(printf 'cat "/srv/checkout/himmel/%s.md"\n' A B C D)" \
    'for d in A B C D; do cat "/srv/checkout/himmel/$d.md"; done'
unit 'GREEN 2: grep over two files' "$(printf 'grep -n x "%s"\n' a.sh b.sh)" \
    'for f in a.sh b.sh; do grep -n x "$f"; done'
unit 'a tilde path with the reference after the slash' 'ls ~/.local/state/himmel/bus' \
    'for x in bus; do ls ~/.local/state/himmel/$x; done'
unit 'the loop is spliced between its neighbours' "$(printf 'echo hi; cat "a" /y/a.md\ncat "b" /y/b.md\n echo bye')" \
    'echo hi; for x in a b; do cat "$x" /y/$x.md; done; echo bye'
unit '16 items, the cap' "$(printf 'cat a%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)" \
    'for x in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16; do cat $x; done'
unit 'a reference inside $(...)' 'cat $(echo a)' 'for x in a; do cat $(echo $x); done'

echo "== unit: one row per qualifying rule, each left as it came =="
keep 'select is not a for loop' 'select x in a; do cat $x; done; echo for'
keep 'a negated loop' '! for x in a; do cat $x; done'
keep 'a background loop' 'for x in a; do cat $x; done &'
keep 'a redirected loop' 'for x in a; do cat $x; done > out'
keep 'a C-style loop' 'for ((i = 0; i < 1; i++)); do cat $i; done'
keep 'an uppercase NAME' 'for X in a; do cat $X; done'
keep 'a zsh special NAME' 'for path in /tmp/evil; do ls; done'
keep 'a NAME already in the environment' 'for unrollprobe in a; do cat $unrollprobe; done' unrollprobe=1
keep 'no word list loops over "$@"' 'echo a; for x; do cat $x; done'
keep '17 items, over the cap' 'for x in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17; do cat $x; done'
keep 'a glob item' 'for x in b?s; do cat $x; done'
keep 'an item with an expansion' 'for x in a$y; do cat $x; done'
keep 'a leading = item (zsh =cmd)' 'for x in =ls; do cat $x; done'
keep 'break in the body' 'for x in a b; do cat $x; break; done'
keep 'a reference in [[ ]]' 'for x in a; do [[ $x == a ]]; done'
keep 'a ${NAME:-word} operator' 'for x in a; do echo ${x:-b}; done'
keep 'a zsh subscript $x[1]' 'for x in a; do cat $x[1]; done'
keep 'a zsh modifier "$x:h"' 'for x in a; do cat "$x:h"; done'
keep 'an open tilde prefix ~$x' 'for x in a; do cat ~$x; done'
keep 'a brace beside the reference' 'for x in a; do cat {$x,b}; done'
keep 'a heredoc in the body' "$(printf 'for x in a; do cat <<EOF\n$x\nEOF\ndone')"
keep 'a backtick substitution' 'for x in a; do echo `cat $x`; done'
keep 'an escaped \$x' 'for x in a; do echo \$x; done'
keep "a single-quoted '\$x'" "for x in a; do echo '\$x'; done"
keep 'NAME reassigned in the body' 'for x in a; do x=b; cat $x; done'
keep 'NAME used after the loop' 'for x in a; do cat $x; done; cat $x'
keep 'IFS named anywhere' 'IFS=.; for x in a; do cat $x; done'
keep 'a command over 8 KiB' "$(printf 'for x in a; do cat $x; # %09000d\ndone' 0)"
keep 'an unrolled text over 8 KiB' "for x in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16; do cat \$x /$(printf '%0600d' 0); done"
keep 'an item that re-reads as an assignment' 'for x in X=1; do $x ls; done'
keep 'an item that re-reads as a keyword' 'for x in time; do $x ls; done'

echo "== chain: the real Bash PreToolUse members =="
MEMBERS=()
while IFS= read -r m; do MEMBERS+=("$ROOT/$m"); done < <(
    jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$SETTINGS" \
        | grep -o -E 'scripts/hooks/[A-Za-z0-9_-]+\.sh' | awk '!seen[$0]++')
[ "${#MEMBERS[@]}" -gt 0 ] || { echo "FAIL fixture: no Bash PreToolUse members in $SETTINGS"; exit 1; }

# chain <command> -> RC and DECISION (deny when the chain exits 2 or says deny)
chain() {
    jq -n --arg c "$1" --arg cwd "$SANDBOX" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "hook-unroll"}' \
        > "$SANDBOX/payload.json" || { echo "FAIL fixture: jq"; exit 1; }
    OUT=$(env -i PATH="$PATH" HOME="$SANDBOX/home" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_PROJECT_DIR="$ROOT" \
        node "$RUNNER" --chain "${MEMBERS[@]}" < "$SANDBOX/payload.json" 2>/dev/null)
    RC=$?
    DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    [ "$RC" = 2 ] && DECISION=deny
}
denied() {  # denied <label> <command>
    chain "$2"
    if [ "$DECISION" = deny ]; then pass "chain denies: $1"; else fail "chain denies: $1 - rc=$RC out=$OUT"; fi
}
allowed() {  # allowed <label> <command>
    chain "$2"
    if [ "$RC" = 0 ] && [ "$DECISION" != deny ]; then pass "chain allows: $1"; else fail "chain allows: $1 - rc=$RC out=$OUT"; fi
}

allowed 'GREEN 1' 'for d in A B C D; do cat "/srv/checkout/himmel/$d.md"; done'
allowed 'GREEN 2' 'for f in a.sh b.sh; do grep -n x "$f"; done'

denied 'RED 1: the bus root via the loop variable' 'for x in bus; do ls ~/.local/state/himmel/$x; done'
denied 'RED 2: a glob item' 'for x in b?s; do ls ~/.local/state/himmel/$x; done'
denied 'RED 3: an expansion item' 'for x in $X; do ls ~/.local/state/himmel/$x; done'
denied 'RED 4: .env through the loop' 'for f in .env; do cat $f; done'
denied 'RED 5: /proc/$p/environ' 'for p in 1; do cat /proc/$p/environ; done'
denied 'RED 6: $x -rf /' 'for x in rm; do $x -rf /; done'
denied 'RED 7: export plus a single-quoted reference' "export x=bus; for x in foo; do bash -c 'ls ~/.local/state/himmel/\$x'; done"
denied 'RED 8: an escaped reference' 'for x in foo; do eval "ls ~/.local/state/himmel/\$x"; done'
denied 'RED 9: NAME reassigned in the body' 'for x in foo; do x=bus; ls ~/.local/state/himmel/$x; done'
denied 'RED 10: NAME used after the loop' 'for x in foo; do :; done; ls ~/.local/state/himmel/$x'
denied 'RED 11: a piped loop' 'for x in foo; do ls ~/.local/state/himmel/$x; done | cat'
denied 'RED 12: a redirected loop' 'for x in foo; do ls ~/.local/state/himmel/$x; done > /dev/null'
denied 'RED 13: 17 items' 'for x in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 bus; do ls ~/.local/state/himmel/$x; done'

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
