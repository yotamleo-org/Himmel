#!/usr/bin/env bash
# Suite for scripts/hooks/block-unexpanded-file-path.sh.
#
# Usage: bash scripts/hooks/test-block-unexpanded-file-path.sh
# Exit 0 when every row passes, 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../lib/override-env.sh
. "$HERE/../lib/override-env.sh"
scrub_override_env

HOOK="$HERE/block-unexpanded-file-path.sh"
TRIM_SET="$HERE/fixtures/js-trim-set.txt"
BASH_BIN=$(command -v bash)

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not on PATH"; exit 1; }
[ -f "$HOOK" ] || { echo "FATAL: $HOOK missing"; exit 1; }
[ -f "$TRIM_SET" ] || { echo "FATAL: $TRIM_SET missing"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/unexpanded-path.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
T=$(cd -P "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/nojq" "$T/emptyjq"
printf '#!/bin/sh\nexit 0\n' > "$T/emptyjq/jq"
chmod +x "$T/emptyjq/jq"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

N=0
mk() {
    local field=file_path
    [ "$1" = NotebookEdit ] && field=notebook_path
    N=$((N + 1))
    PAYLOAD="$T/payload-$N.json"
    jq -cn --arg tool "$1" --arg f "$field" \
        "{hook_event_name: \"PreToolUse\", cwd: \"/tmp\", tool_name: \$tool, tool_input: {(\$f): ($2), content: \"x\"}}" \
        > "$PAYLOAD" || { echo "FATAL: payload $N could not be built"; exit 1; }
}

mkraw() {
    N=$((N + 1))
    PAYLOAD="$T/payload-$N.json"
    printf '%s' "$1" > "$PAYLOAD"
}

run() {
    local label=$1
    shift
    env PATH="$PATH" "$@" "$BASH_BIN" "$HOOK" < "$PAYLOAD" > "$T/out-$label" 2> "$T/err-$label"
    RC=$?
}

denies() {
    local label=$1 remedy=$2 why=""
    shift 2
    run "$label" "$@"
    [ "$RC" = 2 ] || why="rc=$RC, want 2"
    if [ -z "$why" ] && ! jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | type == "string")' "$T/out-$label" >/dev/null 2>&1; then
        why="stdout is not the structured deny"
    fi
    if [ -z "$why" ] && ! grep -qF -- "$remedy" "$T/err-$label"; then
        why="stderr lacks the remedy '$remedy'"
    fi
    if [ -z "$why" ] && ! { grep -qF 'UNEXPANDED_FILE_PATH_OK=1' "$T/err-$label" && grep -qF 'launching shell' "$T/err-$label"; }; then
        why="stderr does not name the off switch UNEXPANDED_FILE_PATH_OK=1 and the launching shell"
    fi
    if [ -z "$why" ]; then
        ok "$label (deny, $remedy)"
    else
        bad "$label: $why: $(head -c 300 "$T/err-$label")"
    fi
}

allows() {
    local label=$1
    shift
    run "$label" "$@"
    if [ "$RC" = 0 ] && [ ! -s "$T/out-$label" ]; then
        ok "$label (allow)"
    else
        bad "$label: want exit 0 with empty stdout, got rc=$RC: $(head -c 300 "$T/out-$label" "$T/err-$label")"
    fi
}

LONG='Use a shorter path'
FORM='or send the absolute path'

echo "== length =="
for tool in Write Edit Read NotebookEdit; do
    mk "$tool" '"/" + ("a" * 4096)'
    denies "long-4097-$tool" "$LONG"
done
mk Write '"/" + ([128512] | implode) * 1024'
denies long-non-ascii-4097-bytes "$LONG"
mk Write '"/tmp/x" + ("\n" * 4100)'
denies long-newline-padded "$LONG"

echo "== trim set =="
rows=0
while IFS= read -r cp || [ -n "$cp" ]; do
    case "$cp" in
        U+[0-9A-F][0-9A-F][0-9A-F][0-9A-F]) ;;
        *) bad "trim-set fixture line '$cp' is not U+XXXX"; continue ;;
    esac
    n=$((16#${cp#U+}))
    mk Write "\"/tmp/x\" + ([$n] | implode)"
    denies "trim-trailing-$cp" "$FORM"
    mk Write "([$n] | implode) + \"x\""
    denies "trim-leading-relative-$cp" "$FORM"
    rows=$((rows + 1))
done < "$TRIM_SET"
if [ "$rows" = 25 ]; then ok "trim-set fixture has 25 members"; else bad "trim-set fixture has $rows members, want 25"; fi

echo "== form =="
form_row() { mk Write "$2"; denies "form-$1" "$FORM"; }
form_row tilde-slash '"~/x"'
form_row tilde-alone '"~"'
form_row tilde-user '"~user/x"'
form_row nul-inside '"/a" + ([0] | implode) + "b"'
form_row double-slash '"/a//b"'
form_row dot-segment '"/a/./b"'
form_row dotdot-segment '"/a/../b"'
form_row leading-dot '"./x"'
form_row leading-dotdot '"../x"'
form_row trailing-dot '"/a/."'
form_row trailing-dotdot '"/a/.."'
form_row dot-alone '"."'
form_row dotdot-alone '".."'

echo "== both fields =="
mkraw '{"hook_event_name":"PreToolUse","tool_name":"NotebookEdit","tool_input":{"file_path":"/tmp/nb.ipynb","notebook_path":"/tmp/nb.ipynb ","new_source":"x"}}'
denies both-fields-notebook-trailing-space "$FORM"

echo "== fail closed =="
mk Write '"/tmp/x"'
denies no-jq-on-path 'jq is not on PATH' PATH="$T/nojq"
mkraw '{"tool_name":"Write","tool_input":{"file_path":'
denies unparseable-payload 'cannot be parsed'
mk Write '"/tmp/x"'
denies jq-prints-nothing 'printed no verdict' PATH="$T/emptyjq:$PATH"
mk Write '5'
denies non-string-file-path 'not a string'

echo "== allowed controls =="
mk Write '"/" + ("a" * 4095)'
allows exactly-4096-bytes
mk Write '"/tmp/x.txt"'
allows short-absolute
mk Edit '"x/y"'
allows relative
mk Write '"/a b/c"'
allows interior-space
mk Write '"/tmp/dir/"'
allows trailing-slash
mkraw '{"hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"x","path":"src"}}'
allows grep-no-file-path
mkraw '{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: x.txt\n+x\n*** End Patch\n"}}'
allows apply-patch-no-file-path

echo "== off switch =="
mk Write '"/" + ("a" * 4096)'
allows switch-long-write UNEXPANDED_FILE_PATH_OK=1
mk Read '"~/x"'
allows switch-tilde-read UNEXPANDED_FILE_PATH_OK=1
mk NotebookEdit '"/tmp/nb.ipynb "'
allows switch-notebook-trailing-space UNEXPANDED_FILE_PATH_OK=1
mkraw '{"tool_name":"Write","tool_input":{"file_path":'
allows switch-unparseable UNEXPANDED_FILE_PATH_OK=1
mk Write '"/tmp/x"'
allows switch-no-jq UNEXPANDED_FILE_PATH_OK=1 PATH="$T/nojq"
mk Write '"/" + ("a" * 4096)'
denies switch-value-0 "$LONG" UNEXPANDED_FILE_PATH_OK=0
denies switch-value-true "$LONG" UNEXPANDED_FILE_PATH_OK=true
denies switch-value-empty "$LONG" UNEXPANDED_FILE_PATH_OK=

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
