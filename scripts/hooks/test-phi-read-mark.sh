#!/usr/bin/env bash
# Tests for phi-read-mark.sh (PostToolUse and PostToolUseFailure): a tool call that
# touches a path under a .salus-marked or PHI-listed root writes
# ~/.himmel/phi-taint/<session_id>. Every row runs under a temp HOME with synthetic
# fixtures; no real salus or PHI path is read.
# Usage: bash scripts/hooks/test-phi-read-mark.sh
set -uo pipefail
unset CLAUDE_GLM_CONFIG_DIR

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUG="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks"
HOOK="$PLUG/phi-read-mark.sh"
CODEX_HOOK="$REPO_ROOT/scripts/hooks/phi-read-mark.sh"

PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/phi-read-mark-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

H="$tmp/home"
VAULT="$tmp/salus-vault"
CHECKOUT="$tmp/himmel"
PHI="$tmp/phi-root"
mkdir -p "$H" "$VAULT/notes" "$CHECKOUT/scripts" "$PHI"
: > "$VAULT/.salus"
printf 'synthetic\n' > "$VAULT/notes/visit.md"
printf 'readme\n' > "$CHECKOUT/README.md"
printf 'synthetic\n' > "$PHI/chart.md"
ln -s "$VAULT/notes" "$CHECKOUT/alias"

post() { jq -cn --arg s "$1" --arg t "$2" --argjson i "$3" --arg e "${4:-PostToolUse}" --arg c "$CHECKOUT" '{session_id:$s,hook_event_name:$e,tool_name:$t,cwd:$c,tool_input:$i,tool_response:{}}'; }
bash_in() { jq -cn --arg c "$1" '{command:$c}'; }
run() {
    local sh="$1" in="$2"; shift 2
    printf '%s' "$in" | env HOME="$H" "$@" bash "$sh" >/dev/null 2>"$tmp/err"
    RC=$?
    ERR=$(cat "$tmp/err")
}
marked() { [ -e "$H/.himmel/phi-taint/$1" ]; }
expect_mark() { if marked "$1" && [ "$RC" = 0 ]; then pass "$2"; else fail "$2" "rc=$RC err=$ERR"; fi; }
expect_none() { if ! marked "$1" && [ "$RC" = "${3:-0}" ]; then pass "$2"; else fail "$2" "rc=$RC marked=$(marked "$1" && echo yes || echo no) err=$ERR"; fi; }

echo "== salus marker: Read, Grep, Glob, NotebookRead =="
run "$HOOK" "$(post sRead Read "$(jq -cn --arg p "$VAULT/notes/visit.md" '{file_path:$p}')")"
expect_mark sRead "a Read of a file under a .salus root marks the session"
run "$HOOK" "$(post sRel Grep '{"pattern":"x","path":"alias"}')"
expect_mark sRel "a Grep of a relative symlink into a .salus root marks (canonical path)"
run "$HOOK" "$(post sGlob Glob "$(jq -cn --arg p "$VAULT/**/*.md" '{pattern:$p}')")"
expect_mark sGlob "a Glob whose absolute pattern starts under a .salus root marks"
run "$HOOK" "$(post sNb NotebookRead "$(jq -cn --arg p "$VAULT/notes/n.ipynb" '{notebook_path:$p}')")"
expect_mark sNb "a NotebookRead under a .salus root marks"
run "$HOOK" "$(post sFail Read "$(jq -cn --arg p "$VAULT/notes/missing.md" '{file_path:$p}')" PostToolUseFailure)"
expect_mark sFail "a failed Read under a .salus root marks (PostToolUseFailure)"

echo "== salus marker: Bash and Monitor command text =="
run "$HOOK" "$(post sCat Bash "$(bash_in "cat $VAULT/notes/visit.md")")"
expect_mark sCat "a Bash cat of an absolute path under a salus root marks the session"
run "$HOOK" "$(post sQ Bash "$(bash_in "wc -l '$VAULT/notes/visit.md'|sort")")"
expect_mark sQ "a quoted absolute path before a pipe marks"
run "$HOOK" "$(post sEq Bash "$(bash_in "tool --in=$VAULT/notes")")"
expect_mark sEq "an absolute path after = marks"
SPACED="$tmp/patient records"
mkdir -p "$SPACED"; : > "$SPACED/.salus"
run "$HOOK" "$(post sDq Bash "$(bash_in "cat \"$SPACED/chart.md\"")")"
expect_mark sDq "a double-quoted absolute path holding a space marks"
run "$HOOK" "$(post sSq Bash "$(bash_in "head -1 '$SPACED/chart.md'")")"
expect_mark sSq "a single-quoted absolute path holding a space marks"
run "$HOOK" "$(post sBs Bash "$(bash_in "cat ${SPACED// /\\ }/chart.md")")"
expect_mark sBs "a backslash-escaped space in an absolute path marks"
DEEP="$tmp/deep root"
mkdir -p "$DEEP/notes"; : > "$DEEP/notes/.salus"
run "$HOOK" "$(post sPart Bash "$(bash_in "cat \"$DEEP\"/notes/chart.md")")"
expect_mark sPart "a quoted prefix joined to an unquoted tail is checked as one path"
PUNCT="$tmp/patient,records=a:b"
mkdir -p "$PUNCT"; : > "$PUNCT/.salus"
run "$HOOK" "$(post sPunct Bash "$(bash_in "cat '$PUNCT/chart.md'")")"
expect_mark sPunct "a quoted path holding , = and : is checked whole"
run "$HOOK" "$(post sEsc Bash "$(bash_in "echo don\\'t; cat $VAULT/notes/visit.md")")"
expect_mark sEsc "an escaped quote outside quotes does not hide a later path"
run "$HOOK" "$(post sDqEsc Bash "$(bash_in "echo \"say \\\"hi\\\"\"; cat $VAULT/notes/visit.md")")"
expect_mark sDqEsc "an escaped double quote inside double quotes does not hide a later path"
run "$HOOK" "$(post sSub Bash "$(bash_in "echo \"\$(cat $VAULT/notes/visit.md)\"")")"
expect_mark sSub "a path inside a double-quoted command substitution marks"
BSL="$tmp/patient\\records"
mkdir -p "$BSL"; : > "$BSL/.salus"
run "$HOOK" "$(post sBsl Bash "$(bash_in "cat \"$BSL/chart.md\"")")"
expect_mark sBsl "a backslash before an ordinary character inside double quotes stays in the path"
NL='
'
run "$HOOK" "$(post sCont Bash "$(bash_in "cat \"$tmp/sal\\${NL}us-vault/notes/visit.md\"")")"
expect_mark sCont "a backslash-newline inside a quoted path marks"
run "$HOOK" "$(post sContU Bash "$(bash_in "cat $tmp/sal\\${NL}us-vault/notes/visit.md")")"
expect_mark sContU "a backslash-newline inside an unquoted path marks"
run "$HOOK" "$(post sAnsi Bash "$(bash_in "cat \$'$tmp/sal\\x75s-vault/notes/visit.md'")")"
expect_mark sAnsi "an ANSI-C quoted string marks"
run "$HOOK" "$(post sLoc Bash "$(bash_in "cat \$\"$tmp/sal\"us-vault/notes/visit.md")")"
expect_mark sLoc "a locale-quoted string marks"
run "$HOOK" "$(post sLocNl Bash "$(bash_in "cat \$\\${NL}\"$tmp/sal\"us-vault/notes/visit.md")")"
expect_mark sLocNl "a backslash-newline between \$ and a double quote marks"
run "$HOOK" "$(post sAnsiNl Bash "$(bash_in "cat \$\\${NL}'$tmp/sal\\x75s-vault/notes/visit.md'")")"
expect_mark sAnsiNl "a backslash-newline between \$ and a single quote marks"
run "$HOOK" "$(post sMon Monitor "$(bash_in "tail -f $VAULT/notes/visit.md")")"
expect_mark sMon "a Monitor command naming a salus path marks"

echo "== PHI lists =="
mkdir -p "$H/.config/claude-glm"
printf '%s\n' "$PHI" > "$H/.config/claude-glm/phi-roots"
run "$HOOK" "$(post sList Read "$(jq -cn --arg p "$PHI/chart.md" '{file_path:$p}')")"
expect_mark sList "a Read under a phi-roots root marks"
run "$HOOK" "$(post sListB Bash "$(bash_in "cat $PHI/chart.md")")"
expect_mark sListB "a Bash cat under a phi-roots root marks"
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$H/.config/claude-glm/phi-roots"
    run "$HOOK" "$(post sUnr Read "$(jq -cn --arg p "$CHECKOUT/README.md" '{file_path:$p}')")"
    expect_mark sUnr "an unreadable phi-roots list marks (decision rc 2)"
    chmod 600 "$H/.config/claude-glm/phi-roots"
fi

echo "== negative control: himmel-only reads are not marked =="
for row in "Read|$(jq -cn --arg p "$CHECKOUT/README.md" '{file_path:$p}')" \
           "Grep|{\"pattern\":\"x\",\"path\":\"scripts\"}" \
           "Glob|{\"pattern\":\"**/*.md\"}" \
           "Bash|$(bash_in "cat $CHECKOUT/README.md && ls $CHECKOUT/scripts")"; do
    run "$HOOK" "$(post sNeg "${row%%|*}" "${row#*|}")"
    expect_none sNeg "a ${row%%|*} of himmel files only is not marked"
done
run "$HOOK" "$(post sWrite Write "$(jq -cn --arg p "$VAULT/notes/visit.md" '{file_path:$p,content:"x"}')")"
expect_none sWrite "a tool outside Read, Grep, Glob, NotebookRead, Bash and Monitor is not checked"
# shellcheck disable=SC2016 # $V is command text the hook sees unexpanded
run "$HOOK" "$(post sVar Bash '{"command":"cat \"$V/notes/visit.md\""}')" V="$VAULT"
expect_none sVar "residual: a path built from a variable is not seen (a narrowing, not a boundary)"

echo "== fail direction =="
run "$HOOK" "$(post '../x' Read "$(jq -cn --arg p "$VAULT/notes/visit.md" '{file_path:$p}')")"
if [ "$RC" = 2 ] && [ ! -e "$H/.himmel/x" ]; then pass "an invalid session_id exits 2 and writes nothing"; else fail "an invalid session_id exits 2 and writes nothing" "rc=$RC"; fi
mkdir -p "$tmp/nolib"; cp "$HOOK" "$tmp/nolib/phi-read-mark.sh"
run "$tmp/nolib/phi-read-mark.sh" "$(post sNoLib Read "$(jq -cn --arg p "$CHECKOUT/README.md" '{file_path:$p}')")"
expect_mark sNoLib "a hook with no phi-egress-lib.sh beside it marks"
many=""; i=0; while [ "$i" -le 256 ]; do many="$many $CHECKOUT/f$i"; i=$((i+1)); done
run "$HOOK" "$(post sMany Bash "$(bash_in "ls$many")")"
expect_mark sMany "a command with more than 256 path words marks"

echo "== the Codex-lane copy =="
if cmp -s "$HOOK" "$CODEX_HOOK"; then pass "scripts/hooks/phi-read-mark.sh is byte-identical to the plugin copy"; else fail "scripts/hooks/phi-read-mark.sh is byte-identical to the plugin copy"; fi
run "$CODEX_HOOK" "$(post sCodex Bash "$(bash_in "cat $VAULT/notes/visit.md")")"
expect_mark sCodex "the Codex-lane copy marks a Bash cat under a salus root"

echo "== wired: the plugin hooks.json commands =="
HOOKS_JSON="$PLUG/hooks.json"
for ev in PostToolUse PostToolUseFailure; do
    c=$(jq -r --arg e "$ev" '[.hooks[$e][]?.hooks[].command | select(contains("/hooks/phi-read-mark.sh\""))] | if length == 1 then .[0] else empty end' "$HOOKS_JSON")
    if [ -z "$c" ]; then fail "wired $ev command runs phi-read-mark.sh" "no single wired command"; continue; fi
    (cd "$tmp" && printf '%s' "$(post "sW$ev" Read "$(jq -cn --arg p "$VAULT/notes/visit.md" '{file_path:$p}')" "$ev")" \
        | env HOME="$H" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/marketplace/plugins/himmel-ops" CLAUDE_PROJECT_DIR="$tmp" sh -c "$c" >/dev/null 2>"$tmp/err")
    RC=$?; ERR=$(cat "$tmp/err")
    expect_mark "sW$ev" "wired $ev command runs phi-read-mark.sh and marks"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
