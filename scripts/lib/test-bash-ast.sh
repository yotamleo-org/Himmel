#!/usr/bin/env bash
# scripts/lib/test-bash-ast.sh — the command-position model (bash-ast.sh).
#
# Rows are this week's guard false positives and false negatives, read as
# positions: a jq string is one argv word, a heredoc body is data, a cd right
# of a pipe or behind || moves the cwd only where the shell really runs it.
# Also: the inlined model matches scripts/hooks/lib/bash-ast.jq, and a missing
# shfmt fails closed with a message naming it.
# shellcheck disable=SC2016  # rows are literal commands for the model, never expanded here

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/bash-ast.sh"
CANON="$SCRIPT_DIR/../hooks/lib/bash-ast.jq"
pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# the inlined copy between the markers is the canonical model, byte for byte
inl=$(awk '/^BASH_AST_JQ_EOF$/ {on = 0} on {print} /^IFS= read -r -d .. _BASH_AST_JQ <</ {on = 1}' "$LIB")
if [ -n "$inl" ] && [ "$inl" = "$(cat "$CANON")" ]; then ok "inlined model matches hooks/lib/bash-ast.jq"
else bad "inlined model matches hooks/lib/bash-ast.jq (re-copy the file between the bash-ast markers)"; fi

# shellcheck source=scripts/lib/bash-ast.sh
. "$LIB"

FIX=$(mktemp -d "${TMPDIR:-/tmp}/bash-ast.XXXXXX") || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

# a PATH holding every tool but shfmt
nosh="$FIX/no-shfmt-bin"; mkdir -p "$nosh"
oifs=$IFS; IFS=:
for d in $PATH; do
    for t in "$d"/*; do
        case "${t##*/}" in shfmt) ;; *) [ -e "$nosh/${t##*/}" ] || ln -s "$t" "$nosh/${t##*/}" 2>/dev/null ;; esac
    done
done
IFS=$oifs
err=$(PATH="$nosh" bash_ast_positions 'ls' 2>&1 >/dev/null); rc=$?
if [ "$rc" = 2 ] && [[ $err == *"shfmt not on PATH"* ]]; then ok "no shfmt: rc 2 and the message names shfmt"
else bad "no shfmt: rc 2 and the message names shfmt — rc=$rc err=$err"; fi

if ! command -v shfmt >/dev/null 2>&1; then
    # CI sets HIMMEL_REQUIRE_SHFMT=1 after installing shfmt, so a runner that lost it fails here instead of skipping
    if [ "${HIMMEL_REQUIRE_SHFMT:-}" = 1 ]; then bad "HIMMEL_REQUIRE_SHFMT=1 but shfmt is not on PATH — the model rows did not run"
    else echo "SKIP: shfmt not on PATH — the model rows did not run"; fi
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
    exit
fi

# row LABEL CMD JQ-EXPR: the positions of CMD satisfy JQ-EXPR
row() {
    local out
    out=$(bash_ast_positions "$2" 2>&1) || { bad "$1 — rc=$? $out"; return; }
    if printf '%s' "$out" | jq -e "$3" >/dev/null 2>&1; then ok "$1"
    else bad "$1 — got $(printf '%s' "$out" | jq -c '[.[] | {prog, argv: [.argv[] | .v // .raw], cwd, in, opaque}]')"; fi
}
nl=$'\n'

row "jq string (.jobs | length) is one argv word, no pipe, no redirect" \
    "jq '(.jobs | length)' run.json" \
    'length == 1 and .[0].prog == "jq" and (.[0].argv | map(.v)) == ["jq", "(.jobs | length)", "run.json"] and .[0].redirs == [] and .[0].in == []'
row "gh --jq (.jobs | length) > /dev/null writes only /dev/null" \
    "gh run view 5 --json jobs --jq '(.jobs | length)' > /dev/null" \
    'length == 1 and ([.[].redirs[] | .w.v] == ["/dev/null"]) and any(.[0].argv[]; .v == "(.jobs | length)")'
row "heredoc body naming settings.json is data, not a write" \
    "cat <<'EOF' | wc -l${nl}the live file is ~/.claude/settings.json${nl}EOF" \
    '([.[].redirs[] | select(.op | test(">"))] | length) == 0
     and ([.[].argv[] | select((.v // .raw) | test("settings"))] | length) == 0
     and ([.[].redirs[] | select(.hdoc and (.text | test("settings.json")))] | length) == 1'
row "cd left of a pipe runs in a subshell" \
    'cd sub | true; cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[]]'
row "cd right of a pipe: bash stays, zsh moves" \
    'echo x | cd sub && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[], ["sub"]]'
row "cd skipped by || (PR 3198)" \
    'cd R || cd V && engine' \
    '(.[] | select(.prog == "engine") | .cwd) == [["R"], ["V"]]'
row "|| body runs only where the cd failed" \
    'cd sub || cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[]]'
row "&& after a cd runs in the new dir" \
    'cd sub && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [["sub"]]'
row "; after a cd runs in either dir" \
    'cd sub; cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[], ["sub"]]'
row "cd inside a subshell does not leave it" \
    '(cd sub) && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[]] and (.[] | select(.prog == "cd") | .in) == ["subshell"]'
row "cd inside a brace group does leave it" \
    '{ cd sub; } && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [["sub"]]'
row "env -C moves only its own command" \
    'env -C sub cat x; cat y' \
    '(.[0] | .prog == "cat" and .cwd == [["sub"]] and .via == ["env"]) and (.[1].cwd == [[]])'
row "a later -C in one env replaces the earlier; a nested env chains" \
    'env -C a -C b cat x; env -C a env --chdir=b cat y' \
    '(.[0] | .argv[1].v == "x" and .cwd == [["b"]]) and (.[1] | .argv[1].v == "y" and .cwd == [["a", "b"]])'
row "a cd to an expansion is unknown" \
    'cd "$D" && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [null]'
row "cd - and popd are unknown" \
    'cd - && cat x; popd && cat y' \
    '([.[] | select(.prog == "cat") | .cwd] | .[0] == [null] and (.[1] | index(null) != null))'
row "a bash -c body is re-parsed from the outer cwd" \
    "cd a && bash -c 'cd ../b; cat x'" \
    '(.[] | select(.prog == "cat") | .cwd == [["a"], ["a", "../b"]] and .in == ["shell-c"])'
row "a literal eval body is re-parsed; the cwd after it is unknown" \
    "eval 'cd b' && cat x" \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null) and any(.[]; .prog == "cd" and .in == ["eval"])'
row "a loop that moves the cwd makes it unknown" \
    'for d in a b; do cd $d; done; cat x' \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "a function definition makes the cwd unknown" \
    'f() { cd a; }; f; cat x' \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "a CDPATH assignment makes the cwd unknown" \
    'CDPATH=/x; cd a && cat x' \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "a \$(…) cd does not leave the substitution" \
    'echo $(cd a; cat x) && cat y' \
    '(.[] | select(.prog == "cat" and .argv[1].v == "y") | .cwd) == [[]] and (.[] | select(.prog == "cat" and .argv[1].v == "x") | .in) == ["subst"]'
row "command -v cd is a lookup, not a cd" \
    'command -v cd && cat x' \
    '(.[] | select(.prog == "cat") | .cwd) == [[]] and .[0].lookup'
row "sudo, xargs and find -exec are opaque" \
    'sudo cat x; ls | xargs cat; find . -exec cat {} \;' \
    '[.[] | .opaque | select(. != null)] | length == 3'
row "a shell reading stdin is opaque" \
    "bash <<'EOF'${nl}cat x${nl}EOF" \
    '.[0].opaque | test("stdin")'
row "env NAME=value operands reach assigns, through a nested env too" \
    "env FOO=1 echo x; env A=1 env -u Z B=2 echo y; FOO=1 env BAR='x; cat .env' echo z; env -i echo w" \
    '(.[0] | .prog == "echo" and .via == ["env"] and .assigns == ["FOO"])
     and (.[1] | .assigns == ["A", "B"])
     and (.[2] | .assigns == ["FOO", "BAR"])
     and (.[3] | .assigns == [])'
row "a glob arg keeps its live-glob flag and raw text" \
    'cat .en* ".en"*' \
    '(.[0].argv[1] | .v == ".en*" and .g and .raw == ".en*") and (.[0].argv[2] | .g and .raw == "\".en\"*")'
row "env -C runs in its dir but the caller expands words and opens redirects" \
    'cd sub && env -C e cat x* < y*' \
    '(.[] | select(.prog == "cat") | .cwd == [["sub", "e"]] and .ecwd == [["sub"]]) and (.[] | select(.prog == "cd") | .ecwd == .cwd)'
row "pushd -n does not move the cwd; a dash target is unknown" \
    'cd sub && pushd -n /e && cat x; pushd -n; cat y; cd -q; cat z' \
    '(.[] | select(.prog == "cat" and .argv[1].v == "x") | .cwd) == [["sub"]] and (.[] | select(.prog == "cat" and .argv[1].v == "y") | .cwd) == [[], ["sub"]] and (.[] | select(.prog == "cat" and .argv[1].v == "z") | .cwd | index(null) != null)'
row "a redirect on a subshell, brace or loop is a position in the outer cwd" \
    'cd sub && (cat) < a*; { cat; } < b*; while read -r l; do :; done < c*' \
    '[.[] | select(.prog == null) | {w: .redirs[0].w.v, cwd}] == [{w: "a*", cwd: [["sub"]]}, {w: "b*", cwd: [[], ["sub"]]}, {w: "c*", cwd: [[], ["sub"]]}]'
row "a pipeline numbers its stages and keeps one id; in is unchanged" \
    'a | b |& c; d' \
    '([.[] | .pipe | if . == null then null else {stage, n} end] == [{stage: 0, n: 3}, {stage: 1, n: 3}, {stage: 2, n: 3}, null])
     and ([.[:3][] | .pipe.id] | unique | length) == 1
     and ([.[] | .in] == [["pipe", "pipe"], ["pipe", "pipe"], ["pipe"], []])'
row "two pipelines have different ids" \
    'a | b; c | d' \
    '([.[] | .pipe.id] | .[0] == .[1] and .[2] == .[3] and .[0] != .[2])'
row "a brace group takes its element's stage; a substitution is its own pipeline" \
    '{ a; } | b; x=$(c | d); echo $(f) | g' \
    '(.[] | select(.prog == "a") | .pipe | .stage == 0 and .n == 2)
     and (.[] | select(.prog == "c") | .pipe | .stage == 0 and .n == 2)
     and ((.[] | select(.prog == "c") | .pipe.id) != (.[] | select(.prog == "a") | .pipe.id))
     and (.[] | select(.prog == "f") | .pipe == null)
     and (.[] | select(.prog == "g") | .pipe.stage == 1)'
row "a bash -c body inherits its caller's stage; its own pipeline wins inside" \
    "bash -c 'a' | b; bash -c 'c | d' | e" \
    '(.[] | select(.prog == "a") | .pipe) == (.[] | select(.prog == "bash" and .body == "a") | .pipe)
     and (.[] | select(.prog == "a") | .pipe.id) == (.[] | select(.prog == "b") | .pipe.id)
     and (.[] | select(.prog == "c") | .pipe | .stage == 0 and .n == 2)
     and ((.[] | select(.prog == "c") | .pipe.id) != (.[] | select(.prog == "e") | .pipe.id))'
row "two bash -c bodies get different pipeline ids" \
    "bash -c 'a | b'; bash -c 'c | d'" \
    '(.[] | select(.prog == "a") | .pipe.id) != (.[] | select(.prog == "c") | .pipe.id)'

# jq 1.7 rejects a bare binary expression as an object value (jq -n '{a: [1] + [2]}'; jq 1.8 accepts it).
# CI carries one jq, so these rows run where HIMMEL_JQ_171 names a real jq 1.7.1 binary.
if [ -n "${HIMMEL_JQ_171:-}" ] && [ -x "$HIMMEL_JQ_171" ] && [ "$("$HIMMEL_JQ_171" --version 2>/dev/null)" = "jq-1.7.1" ]; then
    mkdir -p "$FIX/jq171" && ln -s "$HIMMEL_JQ_171" "$FIX/jq171/jq"
    out=$(PATH="$FIX/jq171:$PATH" bash_ast_positions 'for ((i = 0; i < 2; i++)); do cat x; done' 2>/dev/null); rc=$?
    if [ "$rc" = 0 ]; then ok "jq 1.7.1: the model reads a C-style for loop"; else bad "jq 1.7.1: the model reads a C-style for loop — rc=$rc"; fi
    for f in "$SCRIPT_DIR/../hooks/lib/bash-ast.jq" "$SCRIPT_DIR/../hooks/lib/bash-ast-bwimc.jq"; do
        err=$("$HIMMEL_JQ_171" -n -f "$f" 2>&1)
        if [[ $err == *"syntax error"* ]]; then bad "jq 1.7.1: ${f##*/} compiles — ${err%%$'\n'*}"; else ok "jq 1.7.1: ${f##*/} compiles"; fi
    done
else
    echo "note: HIMMEL_JQ_171 is not a jq 1.7.1 binary — the jq 1.7 compile rows did not run"
fi

out=$(bash_ast_positions 'if then' 2>/dev/null); rc=$?
if [ "$rc" = 3 ]; then ok "a parse error is rc 3"; else bad "a parse error is rc 3 — rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
