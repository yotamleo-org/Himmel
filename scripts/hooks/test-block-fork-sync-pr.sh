#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-fork-sync-pr.sh.
#
# A sync of one of our forks is upkeep, never a PR: a `gh pr create` whose base
# is a registered fork and whose head is an upstream (other-owner) branch is
# refused, and so is one whose head on our fork is mostly upstream commits. A PR
# of our own carried delta is allowed. gh is a PATH stub; no network.
#
# Usage: bash scripts/hooks/test-block-fork-sync-pr.sh
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/block-fork-sync-pr.sh"
REAL_REGISTRY="$HOOK_DIR/../guardrails/himmel-adapters.json"

FAILED=0
PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/fork-sync-pr.XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# The registry is the real one (copied, not hand-written), under a fake
# HIMMEL_REPO so a test never depends on the operator's environment.
mkdir -p "$SANDBOX/himmel/scripts/guardrails"
cp "$REAL_REGISTRY" "$SANDBOX/himmel/scripts/guardrails/himmel-adapters.json"
export HIMMEL_REPO="$SANDBOX/himmel"
unset FORK_SYNC_PR_OK

# gh stub: answers default_branch and compare ahead_by from env, logs calls.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
case "$*" in
  "api repos/Graphify-Labs/graphify --jq .default_branch") echo v8 ;;
  "api repos/yotamleo-org/graphify --jq .default_branch") echo main ;;
  "api repos/Graphify-Labs/graphify/compare/"*) echo "${GH_OURS:-0}" ;;
  "api repos/yotamleo-org/graphify/compare/"*) echo "${GH_TOTAL:-0}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"
export GH_LOG="$SANDBOX/gh.log"

# run_hook <label> <expected-rc> <command> [cwd] — writes the payload to a
# fixture file and feeds it on stdin.
LAST_ERR=""
run_hook() {
    local label="$1" want="$2" cmd="$3" cwd="${4:-$SANDBOX}" rc
    jq -n --arg c "$cmd" --arg d "$cwd" \
        '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}' > "$SANDBOX/payload.json"
    : > "$GH_LOG"
    bash "$HOOK" < "$SANDBOX/payload.json" > /dev/null 2> "$SANDBOX/err"
    rc=$?
    LAST_ERR="$(cat "$SANDBOX/err")"
    if [ "$rc" = "$want" ]; then pass "$label (rc=$rc)"; else fail "$label: want rc=$want got rc=$rc; stderr: $LAST_ERR"; fi
}

# 1. Replay of yotamleo-org/core#3, the command copied from the lane log that
#    opened it: base yotamleo-org/core dev, head home-assistant:dev.
CORE3="gh pr create --repo yotamleo-org/core --base dev --head home-assistant:dev --no-maintainer-edit --title 'chore(deps): [HIMMEL-8282] sync core dev from upstream' --body-file /tmp/himmel-8282-core-sync-body.md"
run_hook "core#3 replay: upstream head into our fork is refused" 2 "$CORE3"
if grepq "$LAST_ERR" -F "resync-fork.sh --sync"; then pass "deny names the replacement"; else fail "deny must name resync-fork.sh --sync: $LAST_ERR"; fi
if grepq "$LAST_ERR" -F "FORK_SYNC_PR_OK=1"; then pass "deny names the bypass"; else fail "deny must name the bypass"; fi

# 2. graphify#19 and home-assistant.io#1 shapes (gh pr view, 2026-10-31).
run_hook "graphify#19 shape is refused" 2 "gh pr create --repo yotamleo-org/graphify --base himmel-main --head Graphify-Labs:v8 --title x --body y"
run_hook "home-assistant.io#1 shape (= and short flags) is refused" 2 "gh pr create -R=yotamleo-org/home-assistant.io -B current -H home-assistant:current -t x -b y"
run_hook "owner/repo:branch head spelling is refused" 2 "gh pr create --repo=yotamleo-org/core --head home-assistant/core:dev -t x -b y"
run_hook "a later segment of a compound command is checked" 2 "cd /tmp && gh pr create --repo yotamleo-org/core --head home-assistant:dev -t x -b y"

# 3. No --repo: the base is the cwd's origin.
FORKCLONE="$SANDBOX/core-clone"
git init -q "$FORKCLONE"
git -C "$FORKCLONE" remote add origin https://github.com/yotamleo-org/core.git
run_hook "no --repo: origin is our fork, upstream head refused" 2 "gh pr create --head home-assistant:dev -t x -b y" "$FORKCLONE"
run_hook "cd into the fork clone first: origin is read there" 2 "cd $FORKCLONE && gh pr create --head home-assistant:dev -t x -b y"
run_hook "relative cd into the fork clone is followed" 2 "cd core-clone; gh pr create --head home-assistant:dev -t x -b y"
run_hook "GH_REPO prefix names the base repo" 2 "GH_REPO=yotamleo-org/core gh pr create --head home-assistant:dev -t x -b y"
run_hook "exported GH_REPO names the base repo" 2 "export GH_REPO=yotamleo-org/core && gh pr create --head home-assistant:dev -t x -b y"
GH_REPO=yotamleo-org/core run_hook "GH_REPO in the session env names the base repo" 2 "gh pr create --head home-assistant:dev -t x -b y"

# 4. Our own carried branch is allowed (3 of 3 PR commits are ours).
GH_OURS=3 GH_TOTAL=3 run_hook "our carried branch into our fork is allowed" 0 "gh pr create --repo yotamleo-org/graphify --base himmel-main --head himmel/fix-x -t x -b y"

# 5. Our branch carrying mostly upstream commits is a sync PR in disguise.
GH_OURS=1 GH_TOTAL=40 run_hook "own branch with mostly upstream commits is refused" 2 "gh pr create --repo yotamleo-org/graphify --base himmel-main --head himmel/sync -t x -b y"
if grepq "$LAST_ERR" -F "39 of 40"; then pass "mostly-upstream deny counts the upstream commits"; else fail "mostly-upstream deny must say 39 of 40: $LAST_ERR"; fi

# 5b. No --base: gh pr create targets the fork's default branch, so the total
#     is counted against it, not against himmel_branch.
GH_OURS=1 GH_TOTAL=40 run_hook "no --base: own mostly-upstream branch is refused" 2 "gh pr create --repo yotamleo-org/graphify --head himmel/sync -t x -b y"
if grep -qF "api repos/yotamleo-org/graphify/compare/main...himmel/sync" "$GH_LOG"; then pass "no --base: total counted against the fork default branch"; else fail "no --base must compare against the fork default branch: $(cat "$GH_LOG")"; fi

# 6. GitHub unreachable: a workflow guard fails open on its own infra error.
GH_FAIL=1 run_hook "compare unavailable fails open" 0 "gh pr create --repo yotamleo-org/graphify --base himmel-main --head himmel/fix-x -t x -b y"

# 7. Out of scope: himmel itself, a first-party repo, other commands.
run_hook "himmel's own PR is untouched" 0 "gh pr create --repo yotamleo-org/Himmel --head someone:feat -t x -b y"
if [ ! -s "$GH_LOG" ]; then pass "out-of-scope repo makes no gh call"; else fail "out-of-scope repo called gh: $(cat "$GH_LOG")"; fi
run_hook "first-party repo (upstream null) is not a fork" 0 "gh pr create --repo yotamleo-org/himmel-voice --head other:main -t x -b y"
run_hook "gh pr view is untouched" 0 "gh pr view 3 --repo yotamleo-org/core"
run_hook "a plain command is untouched" 0 "ls -la"

# 8. Bypass.
FORK_SYNC_PR_OK=1 run_hook "FORK_SYNC_PR_OK=1 bypasses" 0 "$CORE3"

# 9. Grep row: no doc or skill tells anyone to open a sync PR or to review
#    upstream code. A line that says never/refuse/not is the rule, not the ask.
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
SYNC_PR_RE='open (a|the) (re-?)?sync PR|one PR per fork|sync upstream first|re-?sync is captured in a (reviewable )?PR|synced with its upstream .{0,40}whenever a worker|review (the )?upstream(-authored)? (code|commits)'
hits="$(git -C "$REPO_ROOT" grep -n -i -E "$SYNC_PR_RE" -- \
    'docs/*.md' '.claude/commands/*.md' '.claude/skills/*.md' 'marketplace/plugins/*/skills/*.md' \
    ':!CHANGELOG.md' 2>/dev/null | grep -v -i -E '\bnever\b|\brefuse|\bnot\b|\bno\b' || true)"
if [ -z "$hits" ]; then pass "no doc or skill asks for a sync PR or an upstream review"; else fail "docs still ask for a sync PR or upstream review:
$hits"; fi

echo ""
echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
