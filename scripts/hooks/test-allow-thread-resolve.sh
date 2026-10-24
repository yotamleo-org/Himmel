#!/usr/bin/env bash
# Smoke test for scripts/hooks/allow-thread-resolve.sh.
#
# Builds a throwaway himmel-shaped fixture (a primary clone and a linked
# worktree off it), then feeds the hook PreToolUse payloads. The one audited
# resolve shape must give an allow decision; every variation must give none
# (empty stdout, exit 0), so the permission layer decides as before.
#
# Usage: bash scripts/hooks/test-allow-thread-resolve.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

REAL_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

FAILED=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/allow-thread-resolve.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir "$TMP_ROOT/fx" || exit 1
TMP="$(cd "$TMP_ROOT/fx" && pwd -P)"

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

PRIMARY="$TMP/himmel"
WT="$TMP/wt"
OTHER="$TMP/other"
g init -q "$PRIMARY" || exit 1
mkdir -p "$PRIMARY/scripts/hooks" "$PRIMARY/scripts/lib" || exit 1
cp "$REAL_HOOK_DIR/allow-thread-resolve.sh" "$PRIMARY/scripts/hooks/" || exit 1
cp "$REAL_HOOK_DIR/../lib/git-clean.sh" "$PRIMARY/scripts/lib/" || exit 1
HOOK="$PRIMARY/scripts/hooks/allow-thread-resolve.sh"
g -C "$PRIMARY" add scripts && g -C "$PRIMARY" commit -q -m init || exit 1
g -C "$PRIMARY" worktree add -q "$WT" -b leg || exit 1
g init -q "$OTHER" || exit 1

CLI="$PRIMARY/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs"
TID='PRRT_kwDOAbCdEf4A-b_Z9'
GOOD="node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""

# run_hook <cwd> <command> -> stdout of the hook; sets RC
run_hook() {
    local f="$TMP/payload.json"
    jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' >"$f"
    OUT="$(bash "$HOOK" <"$f" 2>/dev/null)"
    RC=$?
}

expect_allow() {
    local name="$1" cwd="$2" cmd="$3"
    run_hook "$cwd" "$cmd"
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$OUT" 2>/dev/null)" = allow ]; then
        echo "PASS allow: $name"
    else
        echo "FAIL allow: $name (rc=$RC out=$OUT)"; FAILED=1
    fi
}

expect_none() {
    local name="$1" cwd="$2" cmd="$3"
    run_hook "$cwd" "$cmd"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        echo "PASS none:  $name"
    else
        echo "FAIL none:  $name (rc=$RC out=$OUT)"; FAILED=1
    fi
}

# ---- the audited shape -------------------------------------------------------
expect_allow 'fixed <sha> from a worktree' "$WT" "$GOOD"
expect_allow 'fixed <sha> from the primary' "$PRIMARY" "$GOOD"
expect_allow 'full 40-hex sha' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 1 --thread-id $TID --reason \"fixed 0123456789abcdef0123456789abcdef01234567\""
expect_allow 'followup HIMMEL-n' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"followup HIMMEL-7196\""
expect_allow 'rejected <text>' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected not a defect, the guard is intended\""

# ---- every variation falls through ------------------------------------------
expect_none 'chained with ;' "$WT" "$GOOD; echo hi"
expect_none 'chained with &&' "$WT" "$GOOD && echo hi"
expect_none 'chained with ||' "$WT" "$GOOD || echo hi"
expect_none 'piped' "$WT" "$GOOD | cat"
expect_none 'backgrounded' "$WT" "$GOOD &"
expect_none 'redirected out' "$WT" "$GOOD > /tmp/x"
expect_none 'redirected in' "$WT" "$GOOD < /tmp/x"
expect_none 'stderr redirect' "$WT" "$GOOD 2>&1"
expect_none 'command substitution in reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected \$(id)\""
expect_none 'backtick in reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected \`id\`\""
expect_none 'variable in reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected \$HOME\""
expect_none 'embedded quote in reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected a\" --x \"b\""
expect_none 'newline chained' "$WT" "$GOOD
echo hi"
expect_none 'env prefix' "$WT" "FOO=1 $GOOD"
expect_none 'cd prefix' "$WT" "cd /tmp && $GOOD"
expect_none 'other repo' "$WT" "node $CLI --owner yotamleo-org --repo Other --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'other owner' "$WT" "node $CLI --owner evil-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'extra flag' "$WT" "$GOOD --force"
expect_none 'extra flag before reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --dry --reason \"fixed abc1234\""
expect_none 'non-PRRT thread id' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id PRT_abc --reason \"fixed abc1234\""
expect_none 'thread id with metachar' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id PRRT_a\$b --reason \"fixed abc1234\""
expect_none '--prefix instead of --thread-id' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --prefix abc123 --reason \"fixed abc1234\""
expect_none 'non-digit number' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 36x --thread-id $TID --reason \"fixed abc1234\""
expect_none 'reason outside vocabulary' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"merge it\""
expect_none 'short sha' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc12\""
expect_none 'empty rejected text' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected \""
expect_none 'unquoted reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason fixed"
expect_none 'branch-relative cli path' "$WT" "node plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'cli path outside the primary' "$WT" "node $TMP/evil/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'the worktree copy of the cli' "$WT" "node $WT/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'dot-dot in cli path' "$WT" "node $PRIMARY/x/../plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'unrelated repo carrying its own cli, cwd there' "$OTHER" "node $OTHER/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_allow 'cwd not a repo (the cwd is not the trust anchor)' "$TMP_ROOT" "$GOOD"
HOOK_SAVED="$HOOK"; HOOK="$WT/scripts/hooks/allow-thread-resolve.sh"
expect_allow 'the worktree copy of the hook, same primary cli' "$WT" "$GOOD"
expect_none 'the worktree copy of the hook, worktree cli' "$WT" "node $WT/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
HOOK="$HOOK_SAVED"
expect_none 'other node script' "$WT" "node $PRIMARY/plugins/himmel-gh/lib/thread-reply-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'other mutation' "$WT" "gh pr merge 3628"
expect_none 'empty command' "$WT" ""

# non-Bash tool, empty and unparseable stdin: no decision, exit 0
jq -n --arg c "$GOOD" --arg d "$WT" '{tool_name:"PowerShell",tool_input:{command:$c},cwd:$d}' >"$TMP/p2.json"
OUT="$(bash "$HOOK" <"$TMP/p2.json" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then echo "PASS none:  non-Bash tool"; else echo "FAIL none:  non-Bash tool (rc=$RC out=$OUT)"; FAILED=1; fi
OUT="$(bash "$HOOK" </dev/null 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then echo "PASS none:  empty stdin"; else echo "FAIL none:  empty stdin (rc=$RC out=$OUT)"; FAILED=1; fi
OUT="$(printf 'not json' | bash "$HOOK" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then echo "PASS none:  unparseable stdin"; else echo "FAIL none:  unparseable stdin (rc=$RC out=$OUT)"; FAILED=1; fi

# the hook is registered: wirer inventory and the settings Bash chain both name it
REPO="$(cd "$REAL_HOOK_DIR/../.." && pwd)"
if grep -q "'allow-thread-resolve.sh'" "$REPO/scripts/hooks/wire-hook-bash.mjs" \
    && [ "$(grep -c 'run-hook-with-bash.js\\" --chain .*scripts/hooks/allow-thread-resolve.sh' "$REPO/.claude/settings.json")" -ge 1 ] \
    && (cd "$REPO" && node scripts/hooks/wire-hook-bash.mjs --check >/dev/null 2>&1); then
    echo "PASS wired: inventory + settings Bash chain"
else
    echo "FAIL wired: inventory + settings Bash chain"; FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
