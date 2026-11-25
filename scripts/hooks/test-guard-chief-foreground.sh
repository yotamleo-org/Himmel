#!/usr/bin/env bash
# Tests for scripts/hooks/guard-chief-foreground.sh.
#
# Usage: bash scripts/hooks/test-guard-chief-foreground.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-chief-foreground.sh"
LIST="$SCRIPT_DIR/../handover/chief-kit/long-running.txt"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-chief-fg.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# NUL-delimited argv fixtures for the session-name seam (scripts/lib/session-name.sh)
printf 'claude\0-n\0N-chief\0' > "$TMP/cmdline-chief"
printf 'claude\0-n\0N2262-HIMMEL-5821-worker\0' > "$TMP/cmdline-worker"
printf 'claude\0-n\0N-roadmap-chief\0' > "$TMP/cmdline-chief"

ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# run_hook <console:yes|no> <command> <background:true|false|absent> [extra env...]
# Prints "<rc>|<stdout+stderr>".
run_hook() {
    local chief="$1" cmd="$2" bg="$3" payload out rc
    shift 3
    case "$bg" in
        true)   payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:true}}') ;;
        false)  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c,run_in_background:false}}') ;;
        *)      payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}') ;;
    esac
    if [ "$chief" = yes ]; then
        out=$(printf '%s' "$payload" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-chief" CHIEF_FG_LIST="$LIST" "$@" bash "${HOOK_RUN:-$HOOK}" 2>&1)
    else
        out=$(printf '%s' "$payload" | env -u HIMMEL_CONSOLE_DOC CHIEF_FG_LIST="$LIST" "$@" bash "${HOOK_RUN:-$HOOK}" 2>&1)
    fi
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

expect() {
    local label="$1" want_rc="$2" got="$3" needle="${4:-}"
    local rc="${got%%|*}" body="${got#*|}"
    if [ "$rc" != "$want_rc" ]; then
        bad "$label — expected rc=$want_rc, got rc=$rc: $body"
        return
    fi
    if [ -n "$needle" ] && ! grep -qF -- "$needle" <<< "$body"; then
        bad "$label — output lacks '$needle': $body"
        return
    fi
    ok "$label (rc=$rc)"
}

[ -f "$HOOK" ] || { bad "hook present: $HOOK"; echo "$pass passed, $fail failed"; exit 1; }
[ -f "$LIST" ] || { bad "list present: $LIST"; echo "$pass passed, $fail failed"; exit 1; }

K="bash scripts/handover/chief-kit"

# --- the headline DoD rows
expect "chief, foreground wrap-merged.sh: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "in the foreground — DENIED"
expect "chief, foreground wrap-merged.sh: deny names the script" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "wrap-merged.sh"
expect "chief, explicit run_in_background=false: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" false)" "in the foreground — DENIED"
expect "chief, wrap-merged.sh with run_in_background=true: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" true)"
expect "worker (no HIMMEL_CONSOLE_DOC), foreground wrap-merged.sh: allowed" 0 \
    "$(run_hook no "$K/wrap-merged.sh --pr 12" absent)"

# a worker launched from the chief inherits HIMMEL_CONSOLE_DOC; only the session name tells them apart
payload_worker=$(jq -nc --arg c "$K/ready-check.sh --only 7 12" '{tool_name:"Bash",tool_input:{command:$c}}')
out=$(printf '%s' "$payload_worker" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-worker" CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "worker session name with inherited HIMMEL_CONSOLE_DOC, foreground ready-check.sh: allowed" 0 "$rc|$out"
out=$(printf '%s' "$payload_worker" | env -u CLAUDE_PID HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "unresolvable session name: fails open" 0 "$rc|$out"
# a session named *-chief is a chief exactly as a *-console one is
payload_wrap=$(jq -nc --arg c "$K/wrap-merged.sh --pr 12" '{tool_name:"Bash",tool_input:{command:$c}}')
out=$(printf '%s' "$payload_wrap" | env HIMMEL_CONSOLE_DOC=/x/N-roadmap-chief.md CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$TMP/cmdline-chief" CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief-named session, foreground wrap-merged.sh: denied like a chief" 2 "$rc|$out" "in the foreground — DENIED"

# --- the short scripts stay foreground
for s in append-results.sh go.sh write-verdict.sh fleet-manifest.sh; do
    expect "chief, foreground $s: allowed" 0 "$(run_hook yes "$K/$s x" absent)"
    if grep -qxF "$s" "$LIST"; then bad "list must not name $s"; else ok "list omits $s"; fi
done

# --- invocation shapes
expect "chief, absolute path via bash: denied" 2 \
    "$(run_hook yes "bash /repo/scripts/handover/chief-kit/close-wrapped-worker.sh worker" absent)"
expect "chief, node script (board.mjs): denied" 2 \
    "$(run_hook yes "node scripts/handover/chief-kit/board.mjs" absent)"
expect "chief, direct path execution: denied" 2 \
    "$(run_hook yes "scripts/handover/chief-kit/ready-check.sh 12 abc" absent)"
expect "chief, chained after another command: denied" 2 \
    "$(run_hook yes "cd /x && bash scripts/handover/chief-kit/verdict-go.sh a b" absent)"

# --- a mention is not a run
expect "chief, git grep naming a listed script: allowed" 0 \
    "$(run_hook yes "git grep -n wrap-merged.sh -- scripts" absent)"
expect "chief, grep with an interpreter-named argument: allowed" 0 \
    "$(run_hook yes "grep bash scripts/handover/chief-kit/ready-check.sh" absent)"
expect "chief, longer name sharing a prefix: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh.bak" absent)"
expect "chief, unrelated command: allowed" 0 "$(run_hook yes "ls -la" absent)"

# --- bounded foreground: `timeout <=90` as the outermost command
expect "chief, timeout 90 ready-check.sh: allowed" 0 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 node board.mjs: allowed" 0 \
    "$(run_hook yes "timeout 90 node scripts/handover/chief-kit/board.mjs" absent)"
expect "chief, timeout 90s: allowed" 0 \
    "$(run_hook yes "timeout 90s $K/verdict-go.sh a b" absent)"
expect "chief, timeout 1.5m: allowed" 0 \
    "$(run_hook yes "timeout 1.5m $K/verdict-go.sh a b" absent)"
expect "chief, timeout 600: denied" 2 \
    "$(run_hook yes "timeout 600 $K/ready-check.sh 12 abc" absent)" "in the foreground — DENIED"
expect "chief, timeout 91: denied" 2 \
    "$(run_hook yes "timeout 91 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 0 (no limit): denied" 2 \
    "$(run_hook yes "timeout 0 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 2m: denied" 2 \
    "$(run_hook yes "timeout 2m $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 chief-wait.sh (unbounded waiter): denied" 2 \
    "$(run_hook yes "timeout 90 $K/chief-wait.sh --doc x" absent)"
expect "chief, timeout 90 console-wait.sh (retired, unlisted name): allowed" 0 \
    "$(run_hook yes "timeout 90 $K/console-wait.sh --doc x" absent)"
expect "chief, timeout 90 run-suite.sh (suite): denied" 2 \
    "$(run_hook yes "timeout 90 $K/run-suite.sh x" absent)"
expect "chief, timeout -k 999 90: denied" 2 \
    "$(run_hook yes "timeout -k 999 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout not outermost (chained before): denied" 2 \
    "$(run_hook yes "true; timeout 90 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 90 then a chained command: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc; sleep 600" absent)"
expect "chief, timeout 90 piped: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh 12 abc | cat" absent)"
expect "chief, timeout 90 with command substitution: denied" 2 \
    "$(run_hook yes "timeout 90 $K/ready-check.sh \$(sleep 600)" absent)"
expect "chief, wrapper after timeout (nohup): denied" 2 \
    "$(run_hook yes "timeout 90 nohup $K/ready-check.sh 12 abc" absent)"

# Any token after timeout is a timeout argument, so a timeout around a grep that names the script is denied too (accepted false deny).
expect "chief, timeout 30 grep naming ready-check.sh (accepted false deny): denied" 2 \
    "$(run_hook yes "timeout 30 grep -n x $K/ready-check.sh" absent)"
expect "chief, timeout \"\$T\" (variable duration): denied" 2 \
    "$(run_hook yes "timeout \"\$T\" $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout inf: denied" 2 \
    "$(run_hook yes "timeout inf $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout 1e9 (exponent): denied" 2 \
    "$(run_hook yes "timeout 1e9 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout +600 (signed): denied" 2 \
    "$(run_hook yes "timeout +600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -s kill 0 (lowercase signal, no limit): denied" 2 \
    "$(run_hook yes "timeout -s kill 0 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout '0' (quoted duration): denied" 2 \
    "$(run_hook yes "timeout '0' $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout \"600\" (double-quoted duration): denied" 2 \
    "$(run_hook yes "timeout \"600\" $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout --signal=term 600: denied" 2 \
    "$(run_hook yes "timeout --signal=term 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -sKILL 600 (attached signal): denied" 2 \
    "$(run_hook yes "timeout -sKILL 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout --signal term 600 (separate value): denied" 2 \
    "$(run_hook yes "timeout --signal term 600 $K/ready-check.sh 12 abc" absent)"
expect "chief, timeout -s KILL 600 (signal word before the bound): denied" 2 \
    "$(run_hook yes "timeout -s KILL 600 $K/ready-check.sh 12 abc" absent)"

# --- not a Bash call / unusable payload: fail open
nonbash=$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/x/wrap-merged.sh"}}')
out=$(printf '%s' "$nonbash" | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief, non-Bash tool: allowed" 0 "$rc|$out"
out=$(printf '%s' 'not json' | env HIMMEL_CONSOLE_DOC=/x/N-chief.md CHIEF_FG_LIST="$LIST" bash "$HOOK" 2>&1); rc=$?
expect "chief, unparseable payload: fails open" 0 "$rc|$out"

# --- the list seam reads CHIEF_FG_LIST
printf 'alt-only.sh\n' > "$TMP/alt-list.txt"
expect "chief, CHIEF_FG_LIST names an alternate list: its script is denied" 2 \
    "$(run_hook yes "bash alt-only.sh" absent CHIEF_FG_LIST="$TMP/alt-list.txt")" "alt-only.sh"

# --- documented bypass
expect "chief, CHIEF_FG_OK=1 in the launching shell: allowed" 0 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CHIEF_FG_OK=1)" ""
expect "chief, a per-call CHIEF_FG_OK=1 prefix does not lift the guard" 2 \
    "$(run_hook yes "CHIEF_FG_OK=1 $K/wrap-merged.sh --pr 12" absent)" "in the foreground — DENIED"
expect "chief, an empty VAR= prefix does not hide the script" 2 \
    "$(run_hook yes "FOO= $K/wrap-merged.sh --pr 12" absent)" "in the foreground — DENIED"
expect "chief, CHIEF_FG_OK=0 in the launching shell: denied" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent CHIEF_FG_OK=0)" "in the foreground — DENIED"
expect "chief, deny names CHIEF_FG_OK as the bypass" 2 \
    "$(run_hook yes "$K/wrap-merged.sh --pr 12" absent)" "CHIEF_FG_OK=1"

HAVE_SHFMT=0
command -v shfmt >/dev/null 2>&1 && HAVE_SHFMT=1
LIB_AST="$SCRIPT_DIR/../lib/bash-ast.sh"
CWP=/repo/scripts/handover/chief-kit/chief-wait.sh
CW="bash $CWP"
IN=/b/consoles/N.md
RC=/repo/scripts/handover/chief-kit/ready-check.sh
RS=/repo/scripts/handover/chief-kit/run-suite.sh
BM=/repo/scripts/handover/chief-kit/board.mjs
DET='DETACHED — DENIED'
FG='in the foreground — DENIED'
DETLINE='You are a CHIEF session running a long chief-kit script (chief-wait.sh) DETACHED — DENIED.'
FGLINE='You are a CHIEF session running a long chief-kit script (ready-check.sh) in the foreground — DENIED.'
BLK=main
BENV=""
ROWSET='*'
REPEAT="1 2 3 4 5 6 7 8 9 10 11 15 16 19 20 21 22 23 24 26 27 28 37 38 42 43 44 45 46 47 48 49"

rowx() {
    local n="$1" want="$2" needle="$3" bg="$4" cmd="$5" kind="${6:-}"
    if [ "$kind" = model ] && [ "$HAVE_SHFMT" = 0 ]; then
        if [ "${HIMMEL_REQUIRE_SHFMT:-}" = 1 ]; then bad "$BLK row $n needs shfmt (HIMMEL_REQUIRE_SHFMT=1)"; else echo "SKIP $BLK row $n needs shfmt"; fi
        return
    fi
    # shellcheck disable=SC2086
    expect "$BLK row $n: ${cmd%%$'\n'*}" "$want" "$(run_hook yes "$cmd" "$bg" $BENV)" "$needle"
}

row() {
    if [ "$ROWSET" != '*' ]; then
        case " $ROWSET " in *" $1 "*) ;; *) return ;; esac
    fi
    rowx "$@"
}

all_rows() {
    row 1 2 "$DET" absent "ls /x | grep 5821; bash \"$CWP\" \"$IN\" --doc \"/d.md\" &"
    row 2 2 "$DETLINE" true "$CW $IN &"
    row 3 2 "$DET" true "bash \"$CWP\" \"$IN\" &"
    row 4 2 "$DET" true "nohup $CW $IN"
    row 5 2 "$DET" true "setsid $CW $IN"
    row 6 2 "$DET" absent "setsid $CW $IN"
    row 7 2 "$DET" true "$CW $IN & disown"
    row 8 2 "$DET" true "bash $RC 12 abc &"
    row 9 2 "$DET" absent "$CW $IN &"
    row 10 2 "$DET" true "( $CW $IN & )"
    row 11 2 "$DET" true $'true\n'"$CW $IN &"
    row 12 2 "$DET" true "bash -c \"$CW $IN &\"" model
    row 13 2 "$DET" true "eval \"$CW $IN &\"" model
    row 14 2 "$DET" true "bash -x $CWP $IN &" model
    row 15 2 "$FGLINE" absent "bash \"$RC\" 12 abc"
    row 16 2 "$FG" absent "bash '$CWP' '$IN'"
    row 17 2 "$FG" absent "env $CW $IN" model
    row 18 2 "$FG" absent "exec $CW $IN" model
    row 19 0 "" true "$CW $IN --doc /d.md"
    row 20 0 "" true "bash \"$CWP\" \"$IN\" --doc \"/d.md\""
    row 21 0 "" true "$CW $IN 2>&1"
    PIPEAMP='|'; PIPEAMP="$PIPEAMP&"
    row 22 0 "" true "$CW $IN $PIPEAMP cat"
    row 23 0 "" true "$CW $IN &>/dev/null"
    row 24 0 "" true "cd /x && $CW $IN"
    row 25 0 "" true "$CW $IN --why \"R&D\"" model
    row 26 0 "" absent "grep -n \"bash\" \"$CWP\""
    row 27 0 "" absent "git grep -n \"chief-wait.sh\" -- scripts"
    row 28 0 "" absent "cat \"$CWP\""
    row 29 0 "" true "bash scripts/other.sh &"
    row 30 0 "" true "ls -la &"
    row 33 2 "$DET" true "bash $RS a & bash $RS b & wait"
    row 34 2 "$FG" absent "timeout 30 grep -n x $RC"
    row 35 2 "$DET" true "bash -o pipefail $CWP $IN &" model
    row 36 0 "" absent $'cat <<\'X\'\n'"$CW $IN &"$'\nX' model
    row 37 2 "$DET" true "node $BM &"
    row 38 2 "$DET" absent "timeout 90 $RC 12 abc &"
    row 39 2 "$DET" true "zsh $CWP $IN &" model
    row 40 2 "$DET" true "coproc $CW $IN" model
    row 41 2 "$DET" true "systemd-run --user $CW $IN" model
    row 42 2 "$FG" absent "timeout 600 bash -c \"bash $RC 12 abc\""
    row 43 2 "$DET" true "timeout 7200 bash -c \"$CW $IN &\""
    row 44 2 "$DET" true "setsid bash -c \"$CW $IN\""
    row 45 0 "" absent "bash -c \"cat $CWP\""
    row 46 2 "$DET" true "bash $RC 12 abc; $CW $IN &"
    row 47 2 "$DET" true "systemd-run --user bash -c \"$CW $IN\""
    row 48 2 "$DET" true "nice bash -c \"$CW $IN\" &"
    row 49 2 "$FG" absent "nice cat $RC"
    row 50 2 "$DET" true "bash -- $CWP $IN &" model
    row 51 2 "$DET" true "bash --norc $CWP $IN &" model
    row 52 2 "$FG" absent "env $CW $IN; \$X $CWP" model
    row 53 2 "$DET" true "$CW $IN; timeout 5 bash -c \"$CW $IN &\""
    row 54 2 "$DET" true "coproc timeout 5 $CW $IN" model
}

all_rows
expect "main row 31: a worker session name is not a chief" 0 "$(run_hook no "$CW $IN &" true)"
expect "main row 32: CHIEF_FG_OK=1 allows a detached run" 0 "$(run_hook yes "$CW $IN &" true CHIEF_FG_OK=1)"
rowx 55 2 "$DET" true "nohup bash -c \"$CW $IN\""

RUNNERS=$(sed -n '/def _runners:/,/\];/p' "$LIB_AST" | grep -o '"[a-z-]*"' | tr -d '"')
SHELLS=$(sed -n '/def _shells:/p' "$LIB_AST" | grep -o '"[a-z-]*"' | tr -d '"')
if [ -n "$RUNNERS" ]; then ok "the model's runner list is read from the lib"; else bad "no runner list read from $LIB_AST"; fi
if [ -n "$SHELLS" ]; then ok "the model's shell list is read from the lib"; else bad "no shell list read from $LIB_AST"; fi

runner_rows() {
    local r needle
    for r in $RUNNERS; do
        needle="$FG"
        case "$r" in setsid|systemd-run) needle="$DET" ;; esac
        rowx 56 2 "$needle" absent "$r bash -c \"bash $RC 12 abc\"" "$1"
    done
}
runner_rows model
for sh in $SHELLS; do
    rowx 57 2 "$DET" true "$sh $CWP $IN &" model
done

mkdir -p "$TMP/nosh"
oifs=$IFS; IFS=:
for d in $PATH; do
    for t in "$d"/*; do
        case "${t##*/}" in shfmt) ;; *) [ -e "$TMP/nosh/${t##*/}" ] || ln -s "$t" "$TMP/nosh/${t##*/}" 2>/dev/null ;; esac
    done
done
IFS=$oifs
if PATH="$TMP/nosh" command -v shfmt >/dev/null 2>&1; then bad "the no-shfmt farm still finds shfmt"; else ok "the no-shfmt farm has no shfmt"; fi

BLK=no-shfmt; BENV="PATH=$TMP/nosh"; ROWSET="$REPEAT"
all_rows
rowx 25 2 "$DET" true "$CW $IN --why \"R&D\""
rowx 12 0 "" true "bash -c \"$CW $IN &\""
rowx 55 2 "$DET" true "nohup bash -c \"$CW $IN\""
runner_rows ""

REAL_JQ=$(command -v jq)
mkdir -p "$TMP/jqfail"
# shellcheck disable=SC2016
printf '#!/bin/sh\np=\nfor a in "$@"; do\n  [ "$p" = --argjson ] && [ "$a" = L ] && exit 1\n  p=$a\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$TMP/jqfail/jq"
chmod +x "$TMP/jqfail/jq"

mkdir -p "$TMP/slow" "$TMP/state"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in --version) exit 0 ;; esac\ncase "$5" in jq) exit 124 ;; esac\nexit 0\n' > "$TMP/slow/timeout"
chmod +x "$TMP/slow/timeout"

mkdir -p "$TMP/tree/hooks" "$TMP/tree/lib"
cp "$HOOK" "$TMP/tree/hooks/guard-chief-foreground.sh"
ln -sf "$SCRIPT_DIR/../lib/session-name.sh" "$TMP/tree/lib/session-name.sh"

shfmt_block() {
    if [ "$HAVE_SHFMT" = 1 ]; then return 0; fi
    if [ "${HIMMEL_REQUIRE_SHFMT:-}" = 1 ]; then bad "block $1 needs shfmt (HIMMEL_REQUIRE_SHFMT=1)"; else echo "SKIP block $1 needs shfmt"; fi
    return 1
}

if shfmt_block verdict-jq-fails; then
    BLK=verdict-jq-fails; BENV="PATH=$TMP/jqfail:$PATH"; ROWSET="$REPEAT"
    all_rows
    rowx 25 2 "$DET" true "$CW $IN --why \"R&D\""
fi

if shfmt_block slow-model; then
    BLK=slow-model; BENV="XDG_STATE_HOME=$TMP/state PATH=$TMP/slow:$PATH"; ROWSET="$REPEAT"
    all_rows
    rowx 25 2 "$DET" true "$CW $IN --why \"R&D\""
fi

BLK=missing-lib; BENV=""; ROWSET="$REPEAT"; HOOK_RUN="$TMP/tree/hooks/guard-chief-foreground.sh"
all_rows
rowx 25 2 "$DET" true "$CW $IN --why \"R&D\""
HOOK_RUN=""

if shfmt_block parse-failure; then
    # shellcheck source=../lib/bash-ast.sh
    pf=$(. "$LIB_AST"; bash_ast_positions 'CW IN &|' >/dev/null 2>&1; echo $?)
    if [ "$pf" = 3 ]; then ok "the model returns rc 3 on a parse failure"; else bad "the model returned rc $pf, not 3, on 'CW IN &|'"; fi
    BLK=parse-failure; BENV=""
    rowx 58 2 "$DET" true "$CW $IN &|"
    rowx 59 0 "" absent "cat $CWP &|"
fi
BLK=main; BENV=""; ROWSET='*'

# --- data file shape: every non-comment line is a kit script that exists
bad_rows=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [ ! -f "$SCRIPT_DIR/../handover/chief-kit/$line" ]; then
        bad "list names a missing script: $line"; bad_rows=$((bad_rows + 1))
    fi
done < "$LIST"
[ "$bad_rows" -eq 0 ] && ok "every list row is an existing kit script"

for s in wrap-merged.sh close-wrapped-worker.sh ready-check.sh verdict-go.sh action-zero.sh board.mjs; do
    if grep -qxF "$s" "$LIST"; then ok "list names $s"; else bad "list lacks the ticket's named script $s"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
