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
export XDG_STATE_HOME="$FIX/state"

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
row "a CDPATH prefix assignment makes a nested bash -c body's cwd unknown" \
    "CDPATH=/tmp bash -c 'cd x && cat f'" \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "env CDPATH= makes a nested bash -c body's cwd unknown" \
    "env CDPATH=/tmp bash -c 'cd x && cat f'" \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "a CDPATH prefix assignment makes a nested eval body's cwd unknown" \
    "CDPATH=/tmp eval 'cd x && cat f'" \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "an exported CDPATH makes a later bash -c body's cwd unknown" \
    "export CDPATH=/tmp; bash -c 'cd x && cat f'" \
    '(.[] | select(.prog == "cat") | .cwd | index(null) != null)'
row "a non-CDPATH prefix assignment keeps a nested body's cwd known" \
    "FOO=1 bash -c 'cd x && cat f'" \
    '(.[] | select(.prog == "cat") | .cwd) == [["x"]]'
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

row "brace groups expand left to right, in bash order" \
    'echo a{b,c}{d,e} x{1..2}' \
    '(.[0].argv | map(.v)) == ["echo", "abd", "abe", "acd", "ace", "x1", "x2"]'

ms_now() {
    local n
    n=$(date +%s%N 2>/dev/null)
    case $n in *N | '') python3 -c 'import time; print(int(time.time() * 1000))' ;; *) echo $((n / 1000000)) ;; esac
}
tmo=$(command -v timeout || command -v gtimeout)
# timed LABEL CMD-FILE JQ-EXPR: the model reads CMD-FILE in under five seconds and its positions satisfy JQ-EXPR
timed() {
    local t0 out rc el
    t0=$(ms_now)
    # read-sink-ok: $2 is a command fixture this suite names, from its own fixtures dir or its own mktemp dir
    out=$("$tmo" -k 2 20 bash -c '. "$1"; bash_ast_positions "$(cat "$2")"' _ "$LIB" "$2" 2>&1); rc=$?
    el=$(($(ms_now) - t0))
    if [ "$rc" = 0 ] && [ "$el" -lt 5000 ] && printf '%s' "$out" | jq -e "$3" >/dev/null 2>&1; then ok "$1 (${el}ms)"
    else bad "$1 — rc=$rc ${el}ms $(printf '%s' "$out" | head -c 300)"; fi
}
if [ -n "$tmo" ]; then
    b18=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do b18="$b18{a,b}"; done
    printf 'echo %s\n' "$b18" >"$FIX/b18.cmd"
    timed "eighteen brace groups are past 64 words in under five seconds" "$FIX/b18.cmd" \
        '.[0].argv[1].t == "amb"'
    timed "a heredoc of many brace groups (the 2026-10-25 hang) reads in under five seconds" \
        "$SCRIPT_DIR/fixtures/bash-ast/heredoc-brace-groups.cmd" 'any(.[]; .prog == "python3")'

    # a model run that never returns fails closed within the bound and logs the command
    mkdir -p "$FIX/stuck-jq"
    printf '#!/usr/bin/env bash\ncase "$*" in *"def positions("*) exec sleep 60 ;; esac\nexec %s "$@"\n' "$(command -v jq)" >"$FIX/stuck-jq/jq"
    chmod +x "$FIX/stuck-jq/jq"
    t0=$(ms_now)
    err=$(BASH_AST_TIMEOUT_S=1 XDG_STATE_HOME="$FIX/state" PATH="$FIX/stuck-jq:$PATH" \
        "$tmo" -k 2 20 bash -c '. "$1"; bash_ast_positions "echo stuck-model-row"' _ "$LIB" 2>&1 >/dev/null); rc=$?
    el=$(($(ms_now) - t0))
    log="$FIX/state/himmel/bash-ast-timeouts.log"
    if [ "$rc" = 5 ] && [ "$el" -lt 5000 ] && [[ $err == *"timed out"* ]]; then ok "a stuck model run is rc 5 within the bound (${el}ms)"
    else bad "a stuck model run is rc 5 within the bound — rc=$rc ${el}ms err=$err"; fi
    if grep -q 'stuck-model-row' "$log" 2>/dev/null && [ -n "$(find "$log" -perm 600 2>/dev/null)" ]; then ok "a stuck model run logs its command, owner-only"
    else bad "a stuck model run logs its command, owner-only — $(head -c 200 "$log" 2>&1)"; fi

    # the bound keeps jq in the caller's process group and grows 1 s per KiB past 4 KiB
    mkdir -p "$FIX/argv-timeout"
    # answers --version and the probe run like GNU timeout, and logs the bound it is given around jq
    printf '#!/bin/sh\ncase "$1" in --version) exit 0 ;; esac\ncase "$5" in jq) echo "$1 $2 $3 $4 $5" >>"$TMO_ARGV"; exit 124 ;; esac\nexit 0\n' >"$FIX/argv-timeout/timeout"
    chmod +x "$FIX/argv-timeout/timeout"
    big="echo $(head -c 10240 /dev/zero | tr '\0' x)"
    TMO_ARGV="$FIX/timeout-argv" XDG_STATE_HOME="$FIX/state" PATH="$FIX/argv-timeout:$PATH" bash -c \
        '. "$1"; bash_ast_positions "echo short"; bash_ast_positions "$2"; BASH_AST_TIMEOUT_S=3 bash_ast_positions "$2"' _ "$LIB" "$big" >/dev/null 2>&1
    # read-sink-ok: the file is this suite's own stub output in its mktemp dir
    argv=$(tr '\n' ';' <"$FIX/timeout-argv" 2>&1)
    if [ "$argv" = "--foreground -k 2 10 jq;--foreground -k 2 16 jq;--foreground -k 2 3 jq;" ]; then ok "the model bound is --foreground, scales with the command and takes BASH_AST_TIMEOUT_S"
    else bad "the model bound is --foreground, scales with the command and takes BASH_AST_TIMEOUT_S — $argv"; fi

    # the scaled bound stops at 40 s
    huge="echo $(head -c 60000 /dev/zero | tr '\0' x)"
    rm -f "$FIX/timeout-argv"
    TMO_ARGV="$FIX/timeout-argv" XDG_STATE_HOME="$FIX/state" PATH="$FIX/argv-timeout:$PATH" bash -c \
        '. "$1"; bash_ast_positions "$2"' _ "$LIB" "$huge" >/dev/null 2>&1
    # read-sink-ok: the file is this suite's own stub output in its mktemp dir
    argv=$(tr '\n' ';' <"$FIX/timeout-argv" 2>&1)
    if [ "$argv" = "--foreground -k 2 40 jq;" ]; then ok "the scaled model bound stops at 40 s"
    else bad "the scaled model bound stops at 40 s — $argv"; fi

    # a pin above the 15 s member window less the 2 s kill grace is capped, and a cut-off at the cap is rc 5 with a log line
    rm -f "$FIX/timeout-argv" "$FIX/state/himmel/bash-ast-timeouts.log"
    err=$(BASH_AST_TIMEOUT_S=60 TMO_ARGV="$FIX/timeout-argv" XDG_STATE_HOME="$FIX/state" PATH="$FIX/argv-timeout:$PATH" bash -c \
        '. "$1"; bash_ast_positions "echo pinned-row"' _ "$LIB" 2>&1 >/dev/null); rc=$?
    # read-sink-ok: the file is this suite's own stub output in its mktemp dir
    argv=$(tr '\n' ';' <"$FIX/timeout-argv" 2>&1)
    if [ "$rc" = 5 ] && [ "$argv" = "--foreground -k 2 13 jq;" ] && [[ $err == *"timed out after 13s"* ]] && grep -q 'pinned-row' "$log" 2>/dev/null; then ok "a pin of 60 s is capped at 13 s, and its cut-off is rc 5 with a log line"
    else bad "a pin of 60 s is capped at 13 s, and its cut-off is rc 5 with a log line — rc=$rc argv=$argv err=$err"; fi

    # one absolute deadline runs through the nested shell bodies: each body used to get a fresh bound
    mkdir -p "$FIX/slow-jq"
    printf '#!/usr/bin/env bash\ncase "$*" in *"def positions("*) sleep 2 ;; esac\nexec %s "$@"\n' "$(command -v jq)" >"$FIX/slow-jq/jq"
    chmod +x "$FIX/slow-jq/jq"
    rm -f "$FIX/state/himmel/bash-ast-timeouts.log"
    t0=$(ms_now)
    err=$(BASH_AST_TIMEOUT_S=3 XDG_STATE_HOME="$FIX/state" PATH="$FIX/slow-jq:$PATH" \
        "$tmo" -k 2 20 bash -c '. "$1"; bash_ast_positions "bash -c \"echo a\"; bash -c \"echo b\""' _ "$LIB" 2>&1 >/dev/null); rc=$?
    el=$(($(ms_now) - t0))
    if [ "$rc" = 5 ] && [[ $err == *"timed out"* ]] && grep -q 'echo [ab]' "$log" 2>/dev/null; then ok "nested shell bodies share one deadline: rc 5 with a log line (${el}ms)"
    else bad "nested shell bodies share one deadline: rc 5 with a log line — rc=$rc ${el}ms err=$err"; fi

    # a timeout that fails --version, ahead of a working one on PATH, is skipped
    mkdir -p "$FIX/bad-tmo" "$FIX/good-tmo"
    printf '#!/bin/sh\necho "$*" >>"$BAD_LOG"\nexit 1\n' >"$FIX/bad-tmo/timeout"
    printf '#!/bin/sh\ncase "$1" in --version) exit 0 ;; esac\necho "$*" >>"$GOOD_LOG"\n[ "$1" = --foreground ] && shift\n[ "$1" = -k ] && shift 2\nshift\nexec "$@"\n' >"$FIX/good-tmo/gtimeout"
    chmod +x "$FIX/bad-tmo/timeout" "$FIX/good-tmo/gtimeout"
    out=$(BAD_LOG="$FIX/bad-log" GOOD_LOG="$FIX/good-log" PATH="$FIX/bad-tmo:$FIX/good-tmo:$PATH" bash -c \
        '. "$1"; bash_ast_positions "echo skip-bad-timeout"' _ "$LIB" 2>&1); rc=$?
    # read-sink-ok: the files are this suite's own stub output in its mktemp dir
    badcalls=$(sort -u "$FIX/bad-log" 2>&1)
    if [ "$rc" = 0 ] && [ "$badcalls" = "--version" ] && grep -q -e '^--foreground -k 2 10 jq ' "$FIX/good-log" 2>/dev/null; then ok "a timeout that fails --version, ahead of a working one, is skipped"
    else bad "a timeout that fails --version, ahead of a working one, is skipped — rc=$rc bad=$badcalls out=$(printf '%s' "$out" | head -c 200)"; fi

    # a timeout without --foreground still bounds the model run, instead of failing every call to rc 4
    mkdir -p "$FIX/nofg-tmo"
    printf '#!/bin/sh\ncase "$1" in --version) exit 0 ;; --foreground) echo "timeout: unrecognized option" >&2; exit 125 ;; esac\n[ "$1" = -k ] && shift 2\nshift\nexec "$@"\n' >"$FIX/nofg-tmo/timeout"
    chmod +x "$FIX/nofg-tmo/timeout"
    out=$(PATH="$FIX/nofg-tmo:$PATH" bash -c '. "$1"; bash_ast_positions "echo no-foreground"' _ "$LIB" 2>&1); rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.[0].prog == "echo"' >/dev/null 2>&1; then ok "a timeout without --foreground still reads the command"
    else bad "a timeout without --foreground still reads the command — rc=$rc out=$(printf '%s' "$out" | head -c 200)"; fi
else
    echo "SKIP: no timeout binary — the termination rows did not run"
fi

out=$(bash_ast_positions 'if then' 2>/dev/null); rc=$?
if [ "$rc" = 3 ]; then ok "a parse error is rc 3"; else bad "a parse error is rc 3 — rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
