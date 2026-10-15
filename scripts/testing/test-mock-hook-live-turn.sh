#!/usr/bin/env bash
# Live hook-wiring e2e under mock-anthropic.
#
# MOCK-BACKED: the model is scripts/testing/mock-anthropic. This proves that a
# REGISTERED project hook (the clone's own .claude/settings.json) fires inside a
# real claude turn and that its deny is HONOURED: the denied tool never executes.
# CI proves hook scripts in isolation; this proves the wiring (shipped
# bus hooks unwired for exactly this gap).
# mock-backed — fake key, loopback-only netns, zero spend; the claude launch is fakekey-claude.sh
#
# The deny case scripts a Bash call `touch <sentinel>; git stash drop` which
# block-git-stash.sh refuses. `--allowedTools` names both command shapes, which removes
# the permission prompt as an alternative reason the tool did not run, so the
# sentinel's absence can only come from the hook (D2 proves the allow rule works). Asserts are on files and the request log, never the rc:
#   D1 the deny sentinel is ABSENT, and the control sentinel is PRESENT (D2)
#   D3 the tool_result in the request log carries the hook's deny text
#   D4 the turn still ended with the scripted final text
#   B  the base URL the claude process saw points at the mock (loopback), the key is fake
# RED control (R1): the same deny run in a clone whose settings.json has NO hooks
# stanza must execute the command: sentinel PRESENT, no deny text. That is the
# "hook stanza removed" failure the positive cases must be able to see.
#
# Not in the per-PR shell-unit shards (needs the pinned `claude` CLI and unshare -rn).
#
# Usage: bash scripts/testing/test-mock-hook-live-turn.sh
# Exit: 0 all passed, 1 a case failed, 77 a prerequisite is missing (named).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/testing/fakekey-claude.sh
. "$HERE/fakekey-claude.sh"

for need in node jq git claude; do
  command -v "$need" >/dev/null 2>&1 || { echo "SKIP: no $need on PATH"; exit 77; }
done
fakekey_sandbox_available || { echo "FAIL: unshare -rn with loopback unavailable; refusing to run unsandboxed"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mock-hook-live.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK" 2>/dev/null || { sleep 1; rm -rf "$WORK"; }; }
trap cleanup EXIT
WORK=$(cd -P "$WORK" && pwd -P)

jsonl_q() { node -e 'const rows=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));process.stdout.write(String(eval(process.argv[2])))' "$1" "$2" 2>/dev/null; }
jsq() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(eval(process.argv[2])))' "$1" "$2" 2>/dev/null; }

# make_clone <dir> — a disposable clone of HEAD, instruction files removed.
make_clone() {
  git clone --local --no-hardlinks --quiet "$REPO" "$1" || { echo "FAIL: clone failed"; exit 1; }
  find "$1" \( -name 'CLAUDE.md' -o -name 'CLAUDE.local.md' -o -name 'AGENTS.md' -o -name 'AGENTS.local.md' \) -type f -delete 2>/dev/null
  rm -rf "$1/.claude/rules"
}

# run_bash_turn <clone> <command> — one scripted Bash call, then a final text.
run_bash_turn() {
  node -e '
const [fx,cmd]=process.argv.slice(1);
require("fs").writeFileSync(fx,JSON.stringify({turns:[
 {reply:[{type:"text",text:"LIVE-HOOK-1"},{type:"tool_use",name:"Bash",input:{command:cmd,description:"live hook turn"}}]},
 {match:"tool_result",reply:{type:"text",text:"LIVE-HOOK-DONE"}}]}))' "$1.fixture.json" "$2"
  # A bare `Bash` allow is ignored by claude ("dangerous permission Bash(*) from cliArg"), so allow
  # exactly the two command shapes the cases use: the permission layer then never denies them.
  FAKEKEY_MOCK_FIXTURE="$1.fixture.json" FAKEKEY_TIMEOUT_S=120 fakekey_run "$1" --permission-mode default \
    --allowedTools "Bash(touch:*)" "Bash(git stash:*)"
}

DENY_TEXT='block-git-stash: git stash MUTATION refused'

# inject_markers <clone> — add PostToolUse:Bash, SessionStart and Stop stanzas that touch a marker file in the
# clone, beside the shipped hooks. The marker can only come from the event firing in the real turn.
inject_markers() {
  # shellcheck disable=SC2016  # the JS body is deliberately single-quoted, no shell expansion wanted
  node -e '
const fs=require("fs");const p=process.argv[1];
const s=JSON.parse(fs.readFileSync(p,"utf8"));
s.hooks=s.hooks||{};
const add=(ev,m,f)=>{const e={hooks:[{type:"command",command:"touch \"$CLAUDE_PROJECT_DIR/"+f+"\"",timeout:10}]};if(m)e.matcher=m;s.hooks[ev]=(s.hooks[ev]||[]).concat([e])};
add("PostToolUse","Bash","post-sentinel");add("SessionStart","","ss-sentinel");add("Stop","","stop-sentinel");
fs.writeFileSync(p,JSON.stringify(s,null,2))' "$1/.claude/settings.json"
}

echo "== D deny: a registered PreToolUse hook refuses the Bash call; the tool never runs =="
D="$WORK/deny"; make_clone "$D"; inject_markers "$D"
SENT_DENY="$D/sentinel-deny"; SENT_OK="$WORK/ctl/sentinel-ok"
run_bash_turn "$D" "touch $SENT_DENY; git stash drop"
if [ ! -e "$SENT_DENY" ]; then pass "D1 the denied command's sentinel is absent"; else fail "D1 the denied command RAN (sentinel exists)"; fi
RL="$D/mock.log"
if [ -s "$RL" ] && [ "$(jsonl_q "$RL" 'rows.some(r=>r.turn===1&&JSON.stringify(r.body).includes("'"$DENY_TEXT"'"))')" = true ]; then
  pass "D3 the tool_result in the second request carries the hook's deny text"
else fail "D3 no deny text in the request log ($RL)"; fi
if [ "$(jsq "$D/out.json" 'String(d.result).includes("LIVE-HOOK-DONE")')" = true ]; then pass "D4 the turn ended with the scripted final text"; else fail "D4 result: $(head -c 300 "$D/out.json" 2>/dev/null)"; fi

echo "== C control: the same turn shape with an allowed command DOES execute =="
C="$WORK/ctl"; make_clone "$C"; inject_markers "$C"
run_bash_turn "$C" "touch $SENT_OK"
if [ -e "$SENT_OK" ]; then pass "D2 the allowed command's sentinel is present (the absence in D1 is the hook, not the harness)"; else fail "D2 the allowed command did not run: the harness cannot execute tools, D1 is vacuous"; fi

echo "== E per-class: each hook class the project registers fired in the real turn =="
# hook_ran <clone> <event-pattern> <script> <status> — the debug log has the PreToolUse deny line naming <script>:
# `Hooks: <event> [<cmd>] finished with status <n>` (newer CLI) or `Hook <event> (<Class>) error: status code <n>`
# followed by the hook's stderr (CLI 2.1.289, the CI pin). A chain is one line naming every member.
hook_ran() {
  local f; f=$(fakekey_debuglog "$1") || return 1
  grep -qE "Hooks: $2 \[.*$3.*\] finished with status ${4:-0}( |$)|Hook $2 \([A-Za-z]+\) error: status code ${4:-0}.*$3" "$f"
}
if hook_ran "$D" 'PreToolUse:Bash' 'block-git-stash' 2; then pass "E1 PreToolUse: the Bash chain naming block-git-stash finished with the deny status"; else fail "E1 no PreToolUse:Bash chain line with status 2 in the deny run's debug log"; fi
# PostToolUse, SessionStart and Stop log no completion line the pinned CLI (2.1.289) reliably prints, so each class
# is proven by a marker stanza injected into the clone (inject_markers): a file only the event firing can create.
if [ -e "$C/post-sentinel" ]; then pass "E2 PostToolUse: the hook ran after the allowed Bash call"; else fail "E2 no PostToolUse marker in the control clone"; fi
# Negative: the deny run loaded the same stanzas (its SessionStart marker exists) and the tool never ran, so no PostToolUse.
if [ -e "$D/ss-sentinel" ] && [ ! -e "$D/post-sentinel" ]; then pass "E2b PostToolUse did NOT run for the denied call (the deny stopped the tool)"; else fail "E2b post marker present for a denied call, or the deny clone never loaded the stanzas"; fi
if [ -e "$C/ss-sentinel" ]; then pass "E3 SessionStart: the startup hook ran"; else fail "E3 no SessionStart marker in the control clone"; fi
if [ -e "$C/stop-sentinel" ]; then pass "E4 Stop: the stop hook ran at the end of the turn"; else fail "E4 no Stop marker in the control clone"; fi

echo "== U UserPromptSubmit: no project hook is registered for it, so the class is proven with an injected stanza =="
# The shipped config has no UserPromptSubmit hook (that is a fact, asserted below, not a gap to paper over:
# if one is added this case keeps the injection and E5 starts covering the real one too).
U="$WORK/ups"; make_clone "$U"
# shellcheck disable=SC2016  # the JS body is deliberately single-quoted, no shell expansion wanted
node -e '
const fs=require("fs");const p=process.argv[1];
const s=JSON.parse(fs.readFileSync(p,"utf8"));
s.hooks=s.hooks||{};
s.hooks.UserPromptSubmit=(s.hooks.UserPromptSubmit||[]).concat([{hooks:[{type:"command",command:"touch \"$CLAUDE_PROJECT_DIR/ups-sentinel\"",timeout:10}]}]);
fs.writeFileSync(p,JSON.stringify(s,null,2))' "$U/.claude/settings.json"
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({turns:[{reply:{type:"text",text:"UPS-DONE"}}]}))' "$U.fixture.json"
FAKEKEY_MOCK_FIXTURE="$U.fixture.json" FAKEKEY_TIMEOUT_S=120 fakekey_run "$U" --permission-mode default
if [ -e "$U/ups-sentinel" ]; then pass "E5 UserPromptSubmit: the registered hook ran on the prompt"; else fail "E5 the UserPromptSubmit hook did not run"; fi
if [ "$(jq -r '.hooks|has("UserPromptSubmit")' "$C/.claude/settings.json")" = false ]; then pass "E5b the shipped project config registers no UserPromptSubmit hook (the injection above is the only one)"; else fail "E5b the shipped config now has a UserPromptSubmit hook: assert on it directly"; fi

echo "== B billing: the run could only reach the mock =="
if [ -s "$RL" ] && [ "$(jsonl_q "$RL" 'rows.length>0&&rows.every(r=>r.path==="/v1/messages"||r.path==="/v1/messages/count_tokens"||r.status===404)')" = true ]; then
  pass "B1 every request hit the mock's own surface"
else fail "B1 request log odd or empty ($RL)"; fi
if grep -qE '^FAKEKEY_KEY="sk-ant-fake-' "$HERE/fakekey-claude.sh" && fakekey_loopback_url "http://127.0.0.1:1" && ! fakekey_loopback_url "https://api.anthropic.com"; then
  pass "B2 harness key is the fake and only loopback base URLs are accepted"
else fail "B2 harness key/base-URL guard changed"; fi

echo "== R1 RED control: the deny case with the hooks stanza removed executes the command =="
R="$WORK/red"; make_clone "$R"
SENT_RED="$R/sentinel-red"
node -e '
const fs=require("fs");const p=process.argv[1];
const s=JSON.parse(fs.readFileSync(p,"utf8"));delete s.hooks;fs.writeFileSync(p,JSON.stringify(s,null,2))' "$R/.claude/settings.json"
run_bash_turn "$R" "touch $SENT_RED; git stash drop"
if [ -e "$SENT_RED" ] && [ -s "$R/mock.log" ] && [ "$(jsonl_q "$R/mock.log" 'rows.some(r=>JSON.stringify(r.body).includes("'"$DENY_TEXT"'"))')" = false ]; then
  pass "R1 with no hook stanza the command ran and no deny text appeared: D1/D3 can fail"
else fail "R1 the stanza-less clone still looked denied (D1/D3 are vacuous)"; fi
if ! hook_ran "$R" 'PreToolUse:Bash' 'block-git-stash' 2 && [ ! -e "$R/post-sentinel" ] && [ ! -e "$R/ss-sentinel" ] && [ ! -e "$R/stop-sentinel" ]; then
  pass "R1b with no hook stanza no hook line or marker appears: E1 can fail (E2-E4 markers come only from the injected stanzas)"
else fail "R1b a hook line or marker appeared with the stanza removed (E1-E4 are vacuous)"; fi

echo
echo "NOTE: mock-backed result - proves registered hooks fire and a deny is honoured in a real turn, not real-model behaviour."
if [ "$failures" = 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $failures"
exit 1
