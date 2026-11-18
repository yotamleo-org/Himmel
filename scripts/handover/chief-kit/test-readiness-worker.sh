#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is the check() shape of the sibling suites
# test-readiness-worker.sh - the readiness worker's code/fixture chain, end to end (C0s cycle 2).
#
#   bash test-readiness-worker.sh                 run the fixture chain below (no native claude, provider, VM or real config)
#   bash test-readiness-worker.sh --vm-capability the FUTURE C0v run: this cycle ships only its interface, so it prints
#                                                 BLOCKED and exits 3 without running or contacting anything
#
# The fixture chain drives the REAL pieces against a fake HOME, handover root, runtime directory and stub konsole:
#   headed-arm-worker.sh --profile readiness (mint, private startup config, real launcher render, C0p, on-behalf acquire)
#   -> the generated MCP config names the startup file -> readiness-session.sh startup (the actual session id equals the
#   minted scope; adopt; confirmation) -> the adapter's checkAdopted / guardedLabel / finishAttempt (a fresh ownership
#   check before every act) -> finish releases exactly the adopted lease. A last stage runs the adapter's own C0 envelope
#   suite (readiness-tools.test.mjs), which speaks MCP to the adapter started exactly as each GENERATED config starts it.
# It is NOT proof that Claude Code delivers the SessionStart hook or the PostToolUse self-heartbeat, that the native
# binary honours the generated argv, or that the worker's own heartbeat (not the launcher's) advances the lease: those are
# the parent-authorized VM run (C0v) and stay unproved here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
if [ "${1:-}" = --vm-capability ]; then
    echo "test-readiness-worker.sh: BLOCKED --vm-capability: the generated-role VM proof needs the parent's actual VM authorization and a verified self-heartbeat wiring (C0v). This cycle ships the code/fixture interface only; nothing was run." >&2
    exit 3
fi
[ "$#" -eq 0 ] || { echo "usage: test-readiness-worker.sh [--vm-capability]" >&2; exit 2; }

SCRIPT="$HERE/headed-arm-worker.sh"
HEADED_ARM="$HERE/../headed-arm.sh"
HOOK="$HERE/../../hooks/readiness-session.sh"
PROJ="$(cd "$HERE/../../.." && pwd -P)"   # the project root Claude Code exports to the session hook as CLAUDE_PROJECT_DIR
QL="$(cd "$HERE/.." && pwd -P)/queue-lock.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/readiness-worker-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
PAST=$(( $(date +%s) - 100 ))

# --- the fixture world: every path and variable the launch could reach is pinned inside $tmp
for v in WORKER_SESSION_LANE WORKER_SESSION_PROFILE WORKER_SESSION_ID WORKER_SESSION_CLAUDE_BIN HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV \
    IMPL_GUARD_OK INLINE_IMPL_OK HIMMEL_CONSOLE_LEG WORKER_SESSION_REPO QUEUE_LOCK_SESSION_SCOPE QUEUE_LOCK_ON_BEHALF QUEUE_LOCK_FORCE_RELEASE \
    QUEUE_LOCK_TAKEOVER CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR WORKER_SESSION_READINESS_PORT WORKER_SESSION_READINESS_PRIMARY_CLI WORKER_SESSION_READINESS_FIXTURE; do unset "$v"; done
export HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/home/.claude" HANDOVER_DIR="$tmp/hd" XDG_RUNTIME_DIR="$tmp/xdg"
export HIMMEL_FLEET_SLOTS="$tmp/fleet-slots" HIMMELCTL_CACHE_DIR="$tmp/cache" HIMMEL_CONFIG_DIR="$tmp/config" HIMMEL_DENIAL_ACK_DIR="$tmp/acks"
export WORKER_SESSION_PRETRUST_HOME="$tmp/pretrust" HIMMEL_POLICY_FOLLOWS_HOME=1 HEADED_ARM_UNAME=Linux UNGUARDED_LAUNCH_OK=1
mkdir -p "$HOME/.claude" "$HANDOVER_DIR/u/r" "$HIMMEL_FLEET_SLOTS" "$WORKER_SESSION_PRETRUST_HOME" "$tmp/repo" "$tmp/bin"
mkdir -m 700 "$XDG_RUNTIME_DIR"
# this chain's own fixture root: the wrapper launches the role (whose delivery is not registered) only when every root,
# binary and port it touches lives under a marked fixture root, and everything here lives under $tmp
printf 'himmel-readiness-fixture-v1' > "$tmp/.himmel-readiness-fixture"; chmod 600 "$tmp/.himmel-readiness-fixture"
printf '%s\n' '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash scripts/handover/queue-lock.sh self-heartbeat"}]}]}}' > "$HOME/.claude/settings.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/claude"; chmod 755 "$tmp/bin/claude"
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$tmp/preflight.sh"; chmod 755 "$tmp/preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp/waker.sh"; chmod 755 "$tmp/waker.sh"
printf '%s\n' "const a = process.argv.slice(2);" "if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);" \
    "else if (a[0] === 'release' && a[1] === 'bucket-check') for (const k of a.slice(a.indexOf('--mirror') + 2)) console.log('IN ' + k + ' current=v1.1.3 via=mirror');" \
    "else process.exit(2);" > "$tmp/notcore.js"
export BRIEF_LINT_JIRA_CLI="$tmp/notcore.js" HEADED_ARM_WORKER_WAKER="$tmp/waker.sh"
# no run opens a real systemd scope or a real setsid
mkdir -p "$tmp/sysd-bin"
# shellcheck disable=SC2016  # the literal $ belong to the generated stub, not to this script
printf '#!%s\nwhile [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done\nshift\nexec "$@"\n' "$(command -v bash)" > "$tmp/sysd-bin/systemd-run"
printf '#!%s\nexec "$@"\n' "$(command -v bash)" > "$tmp/sysd-bin/setsid"
chmod 755 "$tmp/sysd-bin/systemd-run" "$tmp/sysd-bin/setsid"
PATH="$tmp/sysd-bin:$PATH"

launch() { # launch <n> [ENV=val ...]: one real readiness launch; sets D DOC RC SID A
    n="$1"; shift
    D="$tmp/run$n"; mkdir -p "$D/proc/9001" "$D/xdg-unused"
    DOC="$HANDOVER_DIR/u/r/readiness-v2.$n.0.md"
    printf '%s\n' '---' 'description: fixture readiness doc' '---' '> **Prior art:** none found (qmd -c jira-himmel "fixture")' '' '# fixture' > "$DOC"
    cat > "$D/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
: > "$(dirname "$0")/confirmable"
sleep 3
KONSOLE_EOF
    # shellcheck disable=SC2016  # the literal $ belong to the generated stub, not to this script
    printf '#!/usr/bin/env bash\n[ -e "$(dirname "$0")/confirmable" ] && { echo 9001; exit 0; }\nexit 1\n' > "$D/pgrep"
    chmod 755 "$D/konsole" "$D/pgrep"
    echo claude > "$D/proc/9001/comm"
    printf 'claude\0--model\0x\0-n\0PROJ-9999-rw%s\0load doc and continue\0' "$n" > "$D/proc/9001/cmdline"
    RC=0
    env IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HEADED_ARM_WORKER_CLAUDE_BIN="$tmp/bin/claude" HEADED_ARM_WORKER_TARGET="$HEADED_ARM" \
        HEADED_ARM_WORKER_PREFLIGHT="$tmp/preflight.sh" KONSOLE_CMD="$D/konsole" PGREP_CMD="$D/pgrep" WORKER_SESSION_REPO="$tmp/repo" \
        HEADED_ARM_LOCK_DIR="$D/locks" HEADED_ARM_PROC="$D/proc" CLAUDE_CODE_SESSION_ID="launcher-$n" WORKER_SESSION_READINESS_FIXTURE="$tmp" "$@" \
        bash "$SCRIPT" --profile readiness "PROJ-9999-rw$n" "$DOC" "$D/signal-never" "$PAST" "$D/log" claude-sonnet-5-5 > "$D/out" 2>&1 || RC=$?
    [ -z "${RW_DEBUG:-}" ] || { echo "--- launch $n rc=$RC"; cat "$D/out"; }
    local w=0; while [ "$w" -lt 60 ] && [ ! -s "$D/record" ] && [ "$RC" -eq 0 ]; do sleep 0.05; w=$((w + 1)); done
    SID="$(grep -oE 'WORKER_SESSION_ID=[0-9a-f-]{36}' "$D/record" 2>/dev/null | head -n 1 | cut -d= -f2)"
    A="$XDG_RUNTIME_DIR/himmel-readiness/$SID"
}
attempts() { find "$XDG_RUNTIME_DIR/himmel-readiness" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tr '\n' ' '; }
lock_status() { bash "$QL" status "$1" 2>/dev/null | tail -n 1; }
session_start() { # session_start <id> [-]: the actual SessionStart: the hook JSON, with the session's own transcript unless "-", and the env a real session carries
    local tr="$HOME/.claude/projects/p/$1.jsonl"
    if [ "${2-}" = - ]; then tr=""; else mkdir -p "$HOME/.claude/projects/p"; : > "$tr"; fi
    jq -cn --arg sid "$1" --arg tr "$tr" '{session_id:$sid,hook_event_name:"SessionStart",source:"startup"} + (if $tr == "" then {} else {transcript_path:$tr} end)' \
        | CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" startup > "$tmp/hook.out" 2> "$tmp/hook.err"
    HOOK_RC=$?
}
DRIVER="$tmp/driver.mjs"
cat > "$DRIVER" <<'DRIVER_EOF'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const [kit, mcpPath, mode] = process.argv.slice(2);
const t = await import(pathToFileURL(`${kit}/readiness-tools.mjs`).href);
const mcp = JSON.parse(fs.readFileSync(mcpPath, 'utf8'));
const startup = t.loadStartup(mcp.mcpServers.readiness.args[2]); // the adapter finds its private config ONLY through the generated MCP config
const calls = [];
const port = { addReadinessLabel: async (key, present) => { calls.push([key, present]); return { outcome: 'ok' }; } };
const out = { check: await t.checkAdopted(startup) };
out.label = await t.guardedLabel(startup, port, 'HIMMEL-1', true, Date.now() + 20000);
out.port_calls = calls.length;
if (mode === 'finish') out.finish = await t.finishAttempt(startup);
process.stdout.write(`${JSON.stringify(out)}\n`);
DRIVER_EOF
adapter() { env -i PATH="$PATH" HOME="$HOME" node "$DRIVER" "$HERE" "$D/PROJ-9999-rw$n.leg-mcp.json" "$1" 2>"$tmp/adapter.err"; }

# --- 1. the launch: minted id, private config, real render, C0p, on-behalf acquire
launch 1
check "launch: exit 0 and the launch reached konsole" "$RC:$([ -s "$D/record" ] && echo yes)" "0:yes"
check "launch: the lease is held on behalf, fresh, before any session exists" "$(lock_status "$DOC")" "status: FRESH"
check "launch: the attempt directory holds only the private startup config and the transport" \
    "$(find "$A" -mindepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')" "lease-token startup.json "
TOKEN="$(cat "$A/lease-token" 2>/dev/null || true)"
check "launch: the token reached no launch output, record, settings, MCP config, startup config, doc or launch log" \
    "$(grep -rlF -- "$TOKEN" "$D" "$HIMMELCTL_CACHE_DIR" "$A/startup.json" "$DOC" 2>/dev/null | tr '\n' ' ')" ""
adapter check > "$tmp/a0.json"
check "before the session starts: every act is refused and the port is never touched" \
    "$(jq -c '[.check.code, .label.code, .port_calls]' "$tmp/a0.json" 2>/dev/null)" '["not-adopted","not-adopted",0]'

# --- 2. a session that starts under ANOTHER id adopts nothing
session_start "$(cat /proc/sys/kernel/random/uuid)"
check "another session id: the hook exits 0, silent" "$HOOK_RC:$(cat "$tmp/hook.out"):$(cat "$tmp/hook.err")" "0::"
check "another session id: the lease is still the launcher's on-behalf lease and nothing is confirmed" \
    "$([ -e "$A/confirmation.json" ] && echo confirmed || echo none):$([ -e "$A/lease-token" ] && echo transport)" "none:transport"

# --- 2b. the right id but no transcript adopts nothing: liveness comes from the session's own transcript
session_start "$SID" -
check "no transcript in the payload: the hook exits 0 and nothing is confirmed (the transport waits for the session or its cleanup)" \
    "$HOOK_RC:$([ -e "$A/confirmation.json" ] && echo confirmed || echo none):$([ -e "$A/lease-token" ] && echo transport)" "0:none:transport"

# --- 3. the actual session start adopts: the same id the launcher minted
session_start "$SID"
check "session start: the hook exits 0 and prints nothing" "$HOOK_RC:$(cat "$tmp/hook.out"):$(cat "$tmp/hook.err")" "0::"
check "session start: the private confirmation exists and the transport is gone" \
    "$([ -e "$A/confirmation.json" ] && echo confirmed):$([ -e "$A/lease-token" ] && echo transport || echo gone)" "confirmed:gone"
check "session start: the adopted lease is still fresh and the token never reached the hook output" \
    "$(lock_status "$DOC"):$(cat "$tmp/hook.out" "$tmp/hook.err" | grep -cF -- "$TOKEN" || true)" "status: FRESH:0"

# --- 4. the adapter's acts and finish, each verified afresh
adapter finish > "$tmp/a.json"
check "adopted: the act reaches the port once, then finish succeeds" \
    "$(jq -c '[.check.ok, .label.outcome, .port_calls, .finish.outcome]' "$tmp/a.json")" '[true,"updated",1,"finished"]'
check "finish: the lease is released and the attempt directory is gone" "$(lock_status "$DOC"):$([ -e "$A" ] && echo present || echo gone)" "free:gone"
check "no token or credential appears in any adapter result or error output" "$(cat "$tmp/a.json" "$tmp/adapter.err" | grep -cF -- "$TOKEN" || true)" "0"

# --- 5. a lost lease stops the next act before its effect, and finish never releases the successor
launch 2
session_start "$SID"
TOKEN2="$(bash "$QL" status "$DOC" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p' | head -n 1)"
bash "$QL" release "$DOC" "$TOKEN2" >/dev/null 2>&1; bash "$QL" acquire "$DOC" successor-token-rw2 >/dev/null 2>&1
adapter finish > "$tmp/b.json"
check "a successor took the lease: the act and finish are both refused, the port is untouched" \
    "$(jq -c '[.check.code, .label.code, .port_calls, .finish.code]' "$tmp/b.json")" '["not-adopted","not-adopted",0,"not-adopted"]'
check "a successor took the lease: it still holds it" "$(bash "$QL" status "$DOC" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p' | head -n 1)" "successor-token-rw2"
bash "$QL" release "$DOC" successor-token-rw2 >/dev/null 2>&1

# --- 6. a failed hand-off after the acquire releases the launcher's own token and leaves nothing adoptable
printf '%s\n' '#!/usr/bin/env bash' 'exit 5' > "$tmp/fail-target.sh"; chmod 755 "$tmp/fail-target.sh"
attempts_before="$(attempts)"
launch 3 HEADED_ARM_WORKER_TARGET="$tmp/fail-target.sh"
check "a failed hand-off: the wrapper returns its status, the lease is free and no new attempt directory remains" \
    "$RC:$(lock_status "$DOC"):$([ "$(attempts)" = "$attempts_before" ] && echo unchanged || echo changed)" "5:free:unchanged"

# --- 7. the launcher never refuses a session that did not start: the unadopted lease is released by the SessionEnd cleanup
launch 4
printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$SID" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" cleanup > "$tmp/hook.out" 2> "$tmp/hook.err"
check "cleanup of a session that never adopted releases the transported token and removes the attempt" \
    "$(lock_status "$DOC"):$([ -e "$A" ] && echo present || echo gone)" "free:gone"

# --- 8. the future VM run stays blocked here
rc=0; bash "$0" --vm-capability > "$tmp/vm.out" 2> "$tmp/vm.err" || rc=$?
check "--vm-capability is BLOCKED (exit 3) and runs nothing" "$rc:$(grep -c 'BLOCKED' "$tmp/vm.err")" "3:1"

# --- 9. the adapter's MCP envelope, over the configuration this very launcher generates (and the registration of its suite)
# readiness-tools.test.mjs runs the real launcher in its own contained fixture worlds, then spawns the adapter with exactly the
# command and argv of each GENERATED strict MCP config and speaks MCP to it. The WHOLE file runs here, no name filter: the
# C0 envelope group and the credential, port and adoption groups (those drive a private byte-copy of the built primary Jira CLI
# against a loopback fixture with fake credentials, so they need the primary checkout's untracked build; without it the file
# FAILS loudly in its own setup - there is no stand-in client and no skip). Its summary must show real passes and no skip.
rc=0
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" node --test "$HERE/readiness-tools.test.mjs" > "$tmp/envelope.out" 2>&1 || rc=$?
env_pass="$(sed -n 's/^ℹ pass \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
env_fail="$(sed -n 's/^ℹ fail \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
env_skip="$(sed -n 's/^ℹ skipped \([0-9]*\)$/\1/p' "$tmp/envelope.out" | tail -n 1)"
[ "$rc" -eq 0 ] || tail -n 30 "$tmp/envelope.out"
check "the adapter suite exits 0 with no failure and no skip" "$rc:${env_fail:-?}:${env_skip:-?}" "0:0:0"
check "the adapter suite really ran its rows (not a vacuous pass)" "$([ "${env_pass:-0}" -ge 20 ] && echo ran || echo "only:${env_pass:-0}")" "ran"
# The registration runs the WHOLE adapter suite. What the file declares is derived from the file itself and checked against what the
# runner printed, so the credential, port and adoption rows cannot go unrun behind a green exit:
#   groups  every top-level group the file declares, whatever its modifier (describe, describe.skip, ...), must report passed;
#           a top-level opener whose name this derivation cannot read is itself a miss, never silently dropped
#   skips   the runner's SKIP and TODO lines at any depth (its own `skipped` counter does not see a skipped group)
#   rows    the passes are at least the file's own test( count (loops only add rows, so this is a floor, never the proof)
adapter_fact() { # <groups|skips|rows> <test file> <node --test output>
    local fact="$1" file="$2" out="$3" grp missing="" named=0 openers declared pass
    case "$fact" in
        groups)
            openers="$(grep -cE "^describe(\.[a-z]+)?\(" "$file")"
            while IFS= read -r grp; do
                [ -n "$grp" ] || continue
                named=$((named + 1))
                grep -qF -- "✔ $grp (" "$out" || missing="${missing}[$grp]"
            done < <(sed -nE "s/^describe(\.[a-z]+)?\('([^']*)'.*/\2/p" "$file")
            [ "$named" -eq "$openers" ] || missing="${missing}[${openers}-openers-but-${named}-named]"
            printf '%s' "${missing:-none}" ;;
        skips) grep -cE ' # (SKIP|TODO)$' "$out" || true ;;
        rows)
            declared="$(grep -cE '^[[:space:]]*test\(' "$file")"
            pass="$(sed -n 's/^ℹ pass \([0-9]*\)$/\1/p' "$out" | tail -n 1)"
            [ "${pass:-0}" -ge "$declared" ] && printf enough || printf 'pass:%s declared:%s' "${pass:-0}" "$declared" ;;
    esac
}
check "every top-level group of the adapter suite ran and passed (the credential, port and adoption rows included)" "$(adapter_fact groups "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "none"
check "no group, test or todo of the adapter suite was skipped, at any depth" "$(adapter_fact skips "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "0"
check "the adapter suite passed at least as many rows as the file declares" "$(adapter_fact rows "$HERE/readiness-tools.test.mjs" "$tmp/envelope.out")" "enough"
# The prerequisite of the credential and port groups is the primary checkout's untracked build of the Jira CLI (scripts/jira, npm run
# build): a clean checkout has none, and then these rows fail by name - they are never stood in for, skipped or run against a host.
check "the adapter suite's named prerequisite is present: the built primary Jira CLI (no PREREQUISITE-ABSENT in the run)" "$(grep -c 'PREREQUISITE-ABSENT' "$tmp/envelope.out" || true)" "0"
rc=0
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" READINESS_PRIMARY_CLI="$tmp/no-such-build/index.js" node --test --test-name-pattern='C0 fixture sanity' "$HERE/readiness-tools.test.mjs" > "$tmp/prereq.out" 2>&1 || rc=$?
check "prerequisite control: with no build the sanity row fails (rc != 0) and names PREREQUISITE-ABSENT and the missing path" "$([ "$rc" -ne 0 ] && echo failed):$(grep -c "PREREQUISITE-ABSENT: the built primary Jira CLI is required at $tmp/no-such-build/index.js" "$tmp/prereq.out" | sed 's/^[1-9][0-9]*$/named/')" "failed:named"

# The accounting is itself checked on tiny fixtures run by the same runner (no adapter, no primary CLI, nothing of the file above):
# a valid file is accounted clean, and each way a group or row stops running behind a green exit is seen. The fixture keeps more
# passing rows than it declares, as the real file does, so the row floor alone could never notice a skipped group.
fx_write() { # <file> <legacy suffix> <nested suffix> <last-test suffix>: each '' or .skip or .todo
    cat > "$1" <<FX_EOF
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
describe$2('legacy group', () => {
  test('legacy row one', () => assert.ok(true));
  test('legacy row two', () => assert.ok(true));
});
describe('envelope group', () => {
  for (const n of [1, 2, 3, 4, 5, 6]) test(\`envelope row \${n}\`, () => assert.ok(n));
  describe$3('nested group', () => { test('nested row', () => assert.ok(true)); });
  test$4('last row', () => assert.ok(true));
});
FX_EOF
}
fx_facts() { # <name> <legacy> <nested> <test> [double-quote the legacy group name]: groups|skips|rows|runner's own skipped count
    local f="$tmp/acct-$1.test.mjs" o="$tmp/acct-$1.out"
    fx_write "$f" "$2" "$3" "$4"
    [ -z "${5:-}" ] || sed -i.bak "s/'legacy group'/\"legacy group\"/" "$f"
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" node --test "$f" > "$o" 2>&1 || true
    printf '%s|%s|%s|%s' "$(adapter_fact groups "$f" "$o")" "$(adapter_fact skips "$f" "$o")" "$(adapter_fact rows "$f" "$o")" "$(sed -n 's/^ℹ skipped \([0-9]*\)$/\1/p' "$o" | tail -n 1)"
}
check "accounting control: a valid full file is accounted clean (every group passed, nothing skipped, enough rows)" "$(fx_facts valid '' '' '')" "none|0|enough|0"
check "accounting control: a skipped top-level group is a missing group and a skip even though the runner's own skipped count stays 0 and the row floor still holds" "$(fx_facts legacy-skipped .skip '' '')" "[legacy group]|1|enough|0"
check "accounting control: a skipped nested group is a skip at depth although every top-level group still passed" "$(fx_facts nested-skipped '' .skip '')" "none|1|enough|0"
check "accounting control: a skipped test is a skip" "$(fx_facts test-skipped '' '' .skip)" "none|1|enough|1"
check "accounting control: a todo test is a skip" "$(fx_facts test-todo '' '' .todo)" "none|1|enough|0"
# and on the REAL file: its legacy adoption/ownership group skipped in a copy of the text, with the real run's own output rewritten
# the way the runner prints a skipped suite; the unmodified pair is the valid full-file control (the three checks above)
sed "s/^describe('C0s2 adopted ownership'/describe.skip('C0s2 adopted ownership'/" "$HERE/readiness-tools.test.mjs" > "$tmp/real-skipped.test.mjs"
sed "s/^✔ \(C0s2 adopted ownership ([0-9.]*ms)\)$/﹣ \1 # SKIP/" "$tmp/envelope.out" > "$tmp/real-skipped.out"
check "accounting control (the real file): its skipped C0s2 adopted ownership group is a missing group and a skip" "$(adapter_fact groups "$tmp/real-skipped.test.mjs" "$tmp/real-skipped.out")|$(adapter_fact skips "$tmp/real-skipped.test.mjs" "$tmp/real-skipped.out")" "[C0s2 adopted ownership]|1"
check "accounting control: a top-level group whose name the derivation cannot read is a miss, not dropped" "$(fx_facts unnamed '' '' '' dq)" "[2-openers-but-1-named]|0|enough|0"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-readiness-worker.sh"; exit 0; fi
echo "FAIL - test-readiness-worker.sh ($fails failure(s))"; exit 1
