#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-merge-compound.sh: a Bash command that runs
# merge-on-green.sh in any spelling other than the two the allow rules match
# (`bash <anchor>/scripts/handover/merge-on-green.sh ...` and
# `bash scripts/handover/merge-on-green.sh ...`, alone) is denied with exit 2 and the
# allowed spelling on stderr, before it reaches the auto-mode classifier.
# Covers: the 2026-11-12 denied input (cd <worktree> && bash <anchor>/...), `;`, `|`
# and `&&` compounds, an env prefix, the "$HIMMEL_REPO/..." spelling of the
# 2026-11-07 rows, a worktree path; the two allowed spellings, mentions of the
# script that do not run it, an unrelated `cd x && ls`; fail-open on bad input.
#
# HIMMEL_REPO points at a throwaway git repo, so the anchor is a path this suite
# owns. bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-merge-compound.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-guard-merge-compound.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/anchor" || exit 1
A=$(cd -P "$TMP/anchor" && pwd -P)
MOG="scripts/handover/merge-on-green.sh"
GO="/handovers/.locks/go/5292.0123456789abcdef0123456789abcdef01234567"
WT="$A/.claude/worktrees/fix+himmel-8571-critic-panel-stdin-no-unbound-ledger"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

payload() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# run_hook <json> [ENV=val ...]: sets rc, err.
run_hook() {
    local json="$1"; shift
    err=$(env HIMMEL_REPO="$A" "$@" bash "$HOOK" <<< "$json" 2>&1 >/dev/null)
    rc=$?
}

# deny <label> <command>: exit 2 and stderr names the one allowed spelling.
deny() {
    run_hook "$(payload "$2")"
    if [ "$rc" != 2 ]; then bad "$1 - expected rc 2, got $rc ($err)"; return; fi
    case "$err" in
        *"bash $A/$MOG"*) ok "$1" ;;
        *) bad "$1 - denied but stderr lacks 'bash $A/$MOG': $err" ;;
    esac
}

# allow <label> <command> [ENV=val ...]: exit 0 with no output at all.
allow() {
    local label="$1" cmd="$2"; shift 2
    run_hook "$(payload "$cmd")" "$@"
    if [ "$rc" = 0 ] && [ -z "$err" ]; then ok "$label"; else
        bad "$label - expected rc 0 and no output, got rc $rc: $err"; fi
}

echo "== RED: spellings no allow rule matches -> deny =="
deny "11-12 denied input: cd <worktree> && bash <anchor>/... --go" \
    "cd $WT && bash $A/$MOG --jira-transition --go $GO"
deny "cd <worktree> && the relative spelling" "cd $WT && bash $MOG --go $GO"
deny "; compound" "git -C $WT status; bash $A/$MOG --go $GO"
deny "| compound" "echo y | bash $A/$MOG --go $GO"
deny "merge first, then && a rider" "bash $A/$MOG --go $GO && echo done"
deny "11-07 rows: bash \"\$HIMMEL_REPO/...\" spelling" \
    "bash \"\$HIMMEL_REPO/$MOG\" --jira-transition --go $GO"
deny "env-prefixed spelling" "FOO=1 bash $A/$MOG --go $GO"
deny "a worktree copy's absolute path" "bash $WT/$MOG --go $GO"
deny "direct exec without bash" "$A/$MOG --go $GO"
deny "newline-separated second command" "cd $WT
bash $A/$MOG --go $GO"

run_hook "$(payload "cd $WT && bash $A/$MOG --jira-transition --go $GO")"
case "$err" in
    *"bash $A/$MOG --jira-transition --go $GO"*) ok "stderr prints the copy-pasteable line with the typed arguments" ;;
    *) bad "stderr lacks the concrete allowed line: $err" ;;
esac

echo "== GREEN: the two allowed spellings and non-runs -> allow, no output =="
allow "bare absolute-path spelling" "bash $A/$MOG --jira-transition --go $GO"
allow "bare relative spelling" "bash $MOG --go $GO"
allow "bare absolute-path spelling, no arguments" "bash $A/$MOG"
allow "unrelated cd x && ls" "cd /tmp && ls"
allow "reading the script is a mention, not a run" "sed -n 1,40p $MOG && git grep -n merge-on-green.sh"
allow "a commit message naming the compound is data" \
    "git commit -m \"fix: cd x && bash $MOG --go f; done\""
allow "a heredoc body naming the script is data" "cat <<'EOF'
cd x && bash $A/$MOG --go $GO
EOF"

git init -q "$TMP/other" || exit 1
allow "an inherited GIT_DIR does not move the anchor" "bash $A/$MOG --go $GO" GIT_DIR="$TMP/other/.git"

echo "== HIMMEL_REPO unset -> the anchor is this hook's primary checkout =="
P=$(git -C "$HOOKS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
P=${P%/.git}
err=$(env -u HIMMEL_REPO bash "$HOOK" <<< "$(payload "bash $P/$MOG --go $GO")" 2>&1 >/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -z "$err" ]; then ok "primary-checkout absolute spelling allowed"; else
    bad "primary-checkout absolute spelling - rc $rc: $err"; fi

echo "== fail open =="
run_hook '{not json'
if [ "$rc" = 0 ]; then ok "malformed JSON with no merge-on-green -> allow"; else bad "malformed JSON - rc $rc"; fi
run_hook '{"tool_input":{"command":"cd x && bash scripts/handover/merge-on-green.sh"'
if [ "$rc" = 0 ]; then ok "unparseable JSON naming merge-on-green -> allow"; else bad "unparseable JSON - rc $rc"; fi
run_hook "$(payload "cd $WT && bash $A/$MOG --go $GO")" HIMMEL_REPO="$TMP/missing"
if [ "$rc" = 0 ]; then ok "unresolvable anchor -> allow with a note"; else bad "unresolvable anchor - rc $rc: $err"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
