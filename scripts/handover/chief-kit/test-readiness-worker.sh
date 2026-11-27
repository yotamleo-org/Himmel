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
#   check before every act) -> finish releases exactly the adopted lease. The adapter's own suite (readiness-tools.test.mjs, which
#   speaks MCP to the adapter started exactly as each GENERATED config starts it) is run by readiness-adapter-suite.sh: it needs
#   the built Jira CLI, which this suite never does.
# The launcher runs from a tree copy that is not a primary checkout (see TREE below): every launch passes a Claude Code marker beside
# seams, which the seam guard refuses on a primary checkout with no claude ancestor, and a CI checkout is one.
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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/readiness-worker-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# TREE: a copy of the repo's scripts tree that is not a primary checkout. Its launcher, adapter and the seam guard are COPIES of the
# real files (the same bytes); every other entry is a symlink, and scripts/lib is a real directory of symlinks, because the guard
# resolves its root from its own lib directory. The adapter derives the project root the session hook binds its queue library to from
# where it lives, and the launcher writes its own queue-lock path into the startup config, so all of them are the tree's; from here
# HERE names the tree's chief-kit directory.
TREE="$tmp/tree"; REAL_ROOT="$(cd "$HERE/../../.." && pwd -P)"
mkdir -p "$TREE/scripts/handover/chief-kit" "$TREE/scripts/lib"
for e in "$REAL_ROOT"/*; do b="${e##*/}"; [ "$b" = scripts ] || ln -s "$e" "$TREE/$b"; done
for e in "$REAL_ROOT"/scripts/*; do b="${e##*/}"; case "$b" in handover|lib) ;; *) ln -s "$e" "$TREE/scripts/$b" ;; esac; done
for e in "$REAL_ROOT"/scripts/handover/*; do b="${e##*/}"; [ "$b" = chief-kit ] || ln -s "$e" "$TREE/scripts/handover/$b"; done
for e in "$REAL_ROOT"/scripts/handover/chief-kit/*; do b="${e##*/}"; case "$b" in headed-arm-worker.sh|readiness-tools.mjs) ;; *) ln -s "$e" "$TREE/scripts/handover/chief-kit/$b" ;; esac; done
for e in "$REAL_ROOT"/scripts/lib/*; do b="${e##*/}"; [ "$b" = chokepoint-seam-guard.sh ] || ln -s "$e" "$TREE/scripts/lib/$b"; done
cp "$HERE/headed-arm-worker.sh" "$HERE/readiness-tools.mjs" "$TREE/scripts/handover/chief-kit/"
cp "$REAL_ROOT/scripts/lib/chokepoint-seam-guard.sh" "$TREE/scripts/lib/chokepoint-seam-guard.sh"
HERE="$TREE/scripts/handover/chief-kit"

SCRIPT="$HERE/headed-arm-worker.sh"
HEADED_ARM="$HERE/../headed-arm.sh"
HOOK="$HERE/../../hooks/readiness-session.sh"
PROJ="$(cd "$HERE/../../.." && pwd -P)"   # the project root Claude Code exports to the session hook as CLAUDE_PROJECT_DIR
QL="$(cd "$HERE/.." && pwd -P)/queue-lock.sh"

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
adapter() { env -i PATH="$PATH" HOME="$HOME" node "$DRIVER" "$HERE" "$A/leg-mcp.json" "$1" 2>"$tmp/adapter.err"; }

launch 1
check "launch: exit 0 and the launch reached konsole" "$RC:$([ -s "$D/record" ] && echo yes)" "0:yes"
check "launch: the lease is held on behalf, fresh, before any session exists" "$(lock_status "$DOC")" "status: FRESH"
check "launch: the attempt directory holds the private configs and the transport" \
    "$(find "$A" -mindepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')" "lease-token leg-mcp.json leg-settings.json startup.json "
TOKEN="$(cat "$A/lease-token" 2>/dev/null || true)"
check "launch: the token reached no launch output, record, settings, MCP config, startup config, doc or launch log" \
    "$(grep -rlF -- "$TOKEN" "$D" "$HIMMELCTL_CACHE_DIR" "$A/startup.json" "$A/leg-settings.json" "$A/leg-mcp.json" "$DOC" 2>/dev/null | tr '\n' ' ')" ""
adapter check > "$tmp/a0.json"
check "before the session starts: every act is refused and the port is never touched" \
    "$(jq -c '[.check.code, .label.code, .port_calls]' "$tmp/a0.json" 2>/dev/null)" '["not-adopted","not-adopted",0]'

session_start "$(cat /proc/sys/kernel/random/uuid)"
check "another session id: the hook exits 0, silent" "$HOOK_RC:$(cat "$tmp/hook.out"):$(cat "$tmp/hook.err")" "0::"
check "another session id: the lease is still the launcher's on-behalf lease and nothing is confirmed" \
    "$([ -e "$A/confirmation.json" ] && echo confirmed || echo none):$([ -e "$A/lease-token" ] && echo transport)" "none:transport"

# --- 2b. the right id but no transcript adopts nothing: liveness comes from the session's own transcript
session_start "$SID" -
check "no transcript in the payload: the hook exits 0 and nothing is confirmed (the transport waits for the session or its cleanup)" \
    "$HOOK_RC:$([ -e "$A/confirmation.json" ] && echo confirmed || echo none):$([ -e "$A/lease-token" ] && echo transport)" "0:none:transport"

session_start "$SID"
check "session start: the hook exits 0 and prints nothing" "$HOOK_RC:$(cat "$tmp/hook.out"):$(cat "$tmp/hook.err")" "0::"
check "session start: the private confirmation exists and the transport is gone" \
    "$([ -e "$A/confirmation.json" ] && echo confirmed):$([ -e "$A/lease-token" ] && echo transport || echo gone)" "confirmed:gone"
check "session start: the adopted lease is still fresh and the token never reached the hook output" \
    "$(lock_status "$DOC"):$(cat "$tmp/hook.out" "$tmp/hook.err" | grep -cF -- "$TOKEN" || true)" "status: FRESH:0"

adapter finish > "$tmp/a.json"
check "adopted: the act reaches the port once, then finish succeeds" \
    "$(jq -c '[.check.ok, .label.outcome, .port_calls, .finish.outcome]' "$tmp/a.json")" '[true,"updated",1,"finished"]'
check "finish: the lease is released and the attempt directory is gone" "$(lock_status "$DOC"):$([ -e "$A" ] && echo present || echo gone)" "free:gone"
check "no token or credential appears in any adapter result or error output" "$(cat "$tmp/a.json" "$tmp/adapter.err" | grep -cF -- "$TOKEN" || true)" "0"

launch 2
session_start "$SID"
TOKEN2="$(bash "$QL" status "$DOC" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p' | head -n 1)"
bash "$QL" release "$DOC" "$TOKEN2" >/dev/null 2>&1; bash "$QL" acquire "$DOC" successor-token-rw2 >/dev/null 2>&1
adapter finish > "$tmp/b.json"
check "a successor took the lease: the act and finish are both refused, the port is untouched" \
    "$(jq -c '[.check.code, .label.code, .port_calls, .finish.code]' "$tmp/b.json")" '["not-adopted","not-adopted",0,"not-adopted"]'
check "a successor took the lease: it still holds it" "$(bash "$QL" status "$DOC" 2>/dev/null | sed -n 's/.*"session":"\([^"]*\)".*/\1/p' | head -n 1)" "successor-token-rw2"
bash "$QL" release "$DOC" successor-token-rw2 >/dev/null 2>&1

printf '%s\n' '#!/usr/bin/env bash' 'exit 5' > "$tmp/fail-target.sh"; chmod 755 "$tmp/fail-target.sh"
attempts_before="$(attempts)"
launch 3 HEADED_ARM_WORKER_TARGET="$tmp/fail-target.sh"
check "a failed hand-off: the wrapper returns its status, the lease is free and no new attempt directory remains" \
    "$RC:$(lock_status "$DOC"):$([ "$(attempts)" = "$attempts_before" ] && echo unchanged || echo changed)" "5:free:unchanged"

# --- 7. the launcher never refuses a session that did not start: the unadopted lease is released by the SessionEnd cleanup
launch 4
printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$SID" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" cleanup > "$tmp/hook.out" 2> "$tmp/hook.err"
# the verb returns at once and a detached copy releases: wait for the removal with a bounded poll (20 s), never a fixed sleep
w=0; while [ -e "$A" ] && [ "$w" -lt 200 ]; do sleep 0.1; w=$((w + 1)); done
check "cleanup of a session that never adopted releases the transported token and removes the attempt" \
    "$(lock_status "$DOC"):$([ -e "$A" ] && echo present || echo gone)" "free:gone"

rc=0; bash "$0" --vm-capability > "$tmp/vm.out" 2> "$tmp/vm.err" || rc=$?
check "--vm-capability is BLOCKED (exit 3) and runs nothing" "$rc:$(grep -c 'BLOCKED' "$tmp/vm.err")" "3:1"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-readiness-worker.sh"; exit 0; fi
echo "FAIL - test-readiness-worker.sh ($fails failure(s))"; exit 1
