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
mkdir -p "$PRIMARY/scripts/hooks" "$PRIMARY/scripts/lib" "$PRIMARY/scripts/guardrails" "$PRIMARY/plugins/himmel-gh/lib" || exit 1
cp "$REAL_HOOK_DIR/allow-thread-resolve.sh" "$PRIMARY/scripts/hooks/" || exit 1
cp "$REAL_HOOK_DIR/../guardrails/himmel-adapters.json" "$PRIMARY/scripts/guardrails/" || exit 1
cp "$REAL_HOOK_DIR/../lib/git-clean.sh" "$PRIMARY/scripts/lib/" || exit 1
echo '// cli' >"$PRIMARY/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs" || exit 1
HOOK="$PRIMARY/scripts/hooks/allow-thread-resolve.sh"
g -C "$PRIMARY" add scripts plugins && g -C "$PRIMARY" commit -q -m init || exit 1
g -C "$PRIMARY" worktree add -q "$WT" -b worker || exit 1
g init -q "$OTHER" || exit 1
export HIMMEL_REPO="$PRIMARY"

REL='plugins/himmel-gh/lib/thread-resolve-action-cli.mjs'
CLI="$PRIMARY/$REL"
TID='PRRT_kwDOAbCdEf4A-b_Z9'
TAIL="--owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
GOOD="node $CLI $TAIL"

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

# expect_deny <name> <cwd> <command> <text the deny reason must carry>
expect_deny() {
    local name="$1" cwd="$2" cmd="$3" want="$4"
    run_hook "$cwd" "$cmd"
    local why
    why="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$OUT" 2>/dev/null)"
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$OUT" 2>/dev/null)" = deny ] \
        && grep -qF -- "$want" <<<"$why"; then
        echo "PASS deny:  $name"
    else
        echo "FAIL deny:  $name (rc=$RC out=$OUT)"; FAILED=1
    fi
}

# ---- the audited shape -------------------------------------------------------
expect_allow 'fixed <sha> from a worktree' "$WT" "$GOOD"
expect_allow 'fixed <sha> from the primary' "$PRIMARY" "$GOOD"
expect_allow 'full 40-hex sha' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 1 --thread-id $TID --reason \"fixed 0123456789abcdef0123456789abcdef01234567\""
expect_allow 'followup HIMMEL-n' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"followup HIMMEL-7196\""
expect_allow 'rejected <text>' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected not a defect, the guard is intended\""
expect_allow 'single-quoted reason (PR 4011)' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 4011 --thread-id $TID --reason 'followup HIMMEL-7766'"
expect_allow 'single-quoted rejected <text>' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason 'rejected not a defect'"

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
expect_deny 'reason outside vocabulary' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"merge it\"" 'rejected <why>'
expect_deny 'short sha' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc12\"" 'fixed <7-40 hex sha>'
expect_deny 'empty rejected text' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"rejected \"" 'rejected <why>'
expect_deny 'disproved: reason (PR 4014)' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 4014 --thread-id $TID --reason \"disproved: the guard already covers it\"" 'a disproved finding is rejected <why>'
expect_deny 'single-quoted reason outside vocabulary' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 4014 --thread-id $TID --reason 'disproved: x'" 'rejected <why>'
expect_none 'mismatched reason quotes' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234'"
expect_none 'single-quoted reason carrying a quote' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason 'fixed abc1234' --x 'b'"
expect_none 'unquoted reason' "$WT" "node $CLI --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason fixed"
expect_deny 'branch-relative cli path (PR 4010)' "$WT" "node $REL $TAIL" "Retry once with exactly: $GOOD"
expect_deny 'dot-slash relative cli path' "$WT" "node ./$REL $TAIL" "Retry once with exactly: $GOOD"
expect_deny 'CLAUDE_PROJECT_DIR cli path' "$WT" "node \$CLAUDE_PROJECT_DIR/$REL $TAIL" "Retry once with exactly: $GOOD"
expect_deny 'braced CLAUDE_PROJECT_DIR cli path' "$WT" "node \${CLAUDE_PROJECT_DIR}/$REL $TAIL" "Retry once with exactly: $GOOD"
expect_deny 'relative path keeps a single-quoted reason' "$WT" "node $REL --owner yotamleo-org --repo Himmel --number 4011 --thread-id $TID --reason 'followup HIMMEL-7766'" "Retry once with exactly: node $CLI --owner yotamleo-org --repo Himmel --number 4011 --thread-id $TID --reason 'followup HIMMEL-7766'"
expect_none 'relative cli path, chained' "$WT" "node $REL $TAIL; echo hi"
expect_none 'relative cli path, other repo' "$WT" "node $REL --owner yotamleo-org --repo Other --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'other variable in cli path' "$WT" "node \$HOME/$REL $TAIL"
expect_none 'cli path outside the primary' "$WT" "node $TMP/evil/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_deny 'the worktree copy of the cli' "$WT" "node $WT/$REL $TAIL" "Retry once with exactly: $GOOD"
expect_none 'a subdirectory of the worktree' "$WT" "node $WT/scripts/$REL $TAIL"
expect_none 'dot-dot in cli path' "$WT" "node $PRIMARY/x/../plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'unrelated repo carrying its own cli, cwd there' "$OTHER" "node $OTHER/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_allow 'cwd not a repo (the cwd is not the trust anchor)' "$TMP_ROOT" "$GOOD"
HOOK_SAVED="$HOOK"; HOOK="$WT/scripts/hooks/allow-thread-resolve.sh"
expect_allow 'the worktree copy of the hook, same primary cli' "$WT" "$GOOD"
expect_deny 'the worktree copy of the hook, worktree cli' "$WT" "node $WT/$REL $TAIL" "Retry once with exactly: $GOOD"
HOOK="$HOOK_SAVED"
expect_none 'other node script' "$WT" "node $PRIMARY/plugins/himmel-gh/lib/thread-reply-cli.mjs --owner yotamleo-org --repo Himmel --number 3628 --thread-id $TID --reason \"fixed abc1234\""
expect_none 'other mutation' "$WT" "gh pr merge 3628"
expect_none 'empty command' "$WT" ""

# ---- the anchor: $HIMMEL_REPO on refs/heads/main, the CLI main's own bytes --
HIMMEL_REPO='' expect_none 'HIMMEL_REPO unset' "$WT" "$GOOD"
HIMMEL_REPO='' expect_none 'HIMMEL_REPO unset, relative cli path' "$WT" "node $REL $TAIL"
HIMMEL_REPO="$WT" expect_none 'HIMMEL_REPO names a worktree' "$WT" "node $WT/$REL $TAIL"
g -C "$PRIMARY" checkout -q -b side || exit 1
expect_none 'primary not on main' "$WT" "$GOOD"
g -C "$PRIMARY" checkout -q main || exit 1
echo '// planted' >>"$CLI" || exit 1
expect_none 'cli blob differs from main' "$WT" "$GOOD"
expect_none 'cli blob differs from main, relative cli path' "$WT" "node $REL $TAIL"
g -C "$PRIMARY" checkout -q -- "$REL" || exit 1
mv "$CLI" "$CLI.real" && ln -s "$CLI.real" "$CLI" || exit 1
expect_none 'symlinked cli' "$WT" "$GOOD"
rm "$CLI" && mv "$CLI.real" "$CLI" || exit 1
expect_allow 'the cli restored' "$WT" "$GOOD"
# forged gitfile: a worktree's .git rewritten to a planted repo that carries its own cli
WT2="$TMP/wt2"; EVIL="$TMP/evil"
g -C "$PRIMARY" worktree add -q "$WT2" -b forged || exit 1
g init -q "$EVIL" && mkdir -p "$EVIL/plugins/himmel-gh/lib" && echo '// planted' >"$EVIL/$REL" || exit 1
g -C "$EVIL" add plugins && g -C "$EVIL" commit -q -m planted || exit 1
printf 'gitdir: %s/.git\n' "$EVIL" >"$WT2/.git" || exit 1
HOOK_SAVED="$HOOK"; HOOK="$WT2/scripts/hooks/allow-thread-resolve.sh"
expect_none 'forged worktree gitfile, planted cli' "$WT2" "node $EVIL/$REL $TAIL"
expect_none 'forged worktree gitfile, its own cli' "$WT2" "node $WT2/$REL $TAIL"
HOOK="$HOOK_SAVED"

# ---- registered adapter repos (scripts/guardrails/himmel-adapters.json) ---
ADAPTERS="$PRIMARY/scripts/guardrails/himmel-adapters.json"
cp "$ADAPTERS" "$TMP/adapters.keep" || exit 1
ATAIL() { printf '%s' "--owner $1 --repo $2 --number 1 --thread-id $TID --reason \"fixed abc1234\""; }
expect_allow 'registered adapter repo (himmel-voice)' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
expect_allow 'registered adapter repo from the primary' "$PRIMARY" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
expect_allow 'another registered repo (qmd)' "$WT" "node $CLI $(ATAIL yotamleo-org qmd)"
expect_allow 'registered repo, single-quoted rejected reason' "$WT" "node $CLI --owner yotamleo-org --repo himmel-voice --number 1 --thread-id $TID --reason 'rejected not a defect'"
expect_none 'unregistered repo' "$WT" "node $CLI $(ATAIL yotamleo-org not-registered)"
expect_none 'registered name with a suffix' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice-2)"
expect_none 'registered name with a prefix' "$WT" "node $CLI $(ATAIL yotamleo-org xhimmel-voice)"
expect_none 'registered repo under another owner' "$WT" "node $CLI $(ATAIL evil-org himmel-voice)"
expect_none 'registered repo, wrong case' "$WT" "node $CLI $(ATAIL yotamleo-org Himmel-Voice)"
expect_none 'owner and repo swapped' "$WT" "node $CLI $(ATAIL himmel-voice yotamleo-org)"
expect_none 'registered repo, extra flag' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice) --force"
expect_deny 'registered repo, relative cli path' "$WT" "node $REL $(ATAIL yotamleo-org himmel-voice)" "Retry once with exactly: node $CLI $(ATAIL yotamleo-org himmel-voice)"
expect_none 'unregistered repo, relative cli path' "$WT" "node $REL $(ATAIL yotamleo-org not-registered)"
printf '%s\n' '[{"nwo": "yotamleo-org/a.b"}]' >"$ADAPTERS" || exit 1
expect_allow 'registry name with a dot, the literal name' "$WT" "node $CLI $(ATAIL yotamleo-org a.b)"
expect_none 'registry name with a dot is not a regex' "$WT" "node $CLI $(ATAIL yotamleo-org aXb)"
expect_allow 'himmel itself needs no registry row' "$WT" "$GOOD"
printf '%s\n' '[{"nwo": "yotamleo-org/himmel-voice"}, {"nwo": ' >"$ADAPTERS" || exit 1
expect_none 'malformed registry: no adapter allowed' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
expect_allow 'malformed registry: himmel still allowed' "$WT" "$GOOD"
printf '%s\n' '{"nwo": "yotamleo-org/himmel-voice"}' >"$ADAPTERS" || exit 1
expect_none 'registry not an array: no adapter allowed' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
: >"$ADAPTERS" || exit 1
expect_none 'empty registry: no adapter allowed' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
rm "$ADAPTERS" || exit 1
expect_none 'missing registry: no adapter allowed' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
expect_allow 'missing registry: himmel still allowed' "$WT" "$GOOD"
cp "$TMP/adapters.keep" "$ADAPTERS.real" && ln -s "$ADAPTERS.real" "$ADAPTERS" || exit 1
expect_none 'symlinked registry: no adapter allowed' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"
rm "$ADAPTERS" "$ADAPTERS.real" && cp "$TMP/adapters.keep" "$ADAPTERS" || exit 1
expect_allow 'the registry restored' "$WT" "node $CLI $(ATAIL yotamleo-org himmel-voice)"

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
