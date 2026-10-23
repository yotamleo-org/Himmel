#!/usr/bin/env bash
# scripts/eval/mcp-tasks-probe/test-probe.sh - suite for server.mjs + probe.sh.
# Scripted JSON-RPC clients stand in for each launch mode's client behaviour; the
# summary row per client is what the VM run records per mode. The handshake fixture
# (fixtures/claude-initialize.json) is the real `initialize` request Claude Code
# sent to the probe server on the test VM.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/server.mjs"
PROBE="$HERE/probe.sh"
FIX="$HERE/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mcp-tasks-probe-test.XXXXXX")" || { echo "test-probe: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

init_line() { # <caps json>
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":%s,"clientInfo":{"name":"stub","version":"0"}}}\n' "$1"
  printf '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
}
call_line() { # <id> <tool> [task json]
  if [ -n "${3:-}" ]; then
    printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{},"task":%s}}\n' "$1" "$2" "$3"
  else
    printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "$1" "$2"
  fi
}
# run_server <name> <timeout ms> : stdin = client lines; log in $TMP/<name>.log, wire out in $TMP/<name>.out
run_server() {
  MCP_PROBE_LOG="$TMP/$1.log" MCP_PROBE_ELICIT_TIMEOUT_MS="$2" timeout 20 node "$SERVER" > "$TMP/$1.out" 2>/dev/null
}
row() { bash "$PROBE" summarize "$TMP/$1.log" 2>&1; }

# 1. no tasks or elicitation capability, plain calls (the shape of a non-interactive client)
{ init_line '{}'; call_line 2 probe_task; call_line 3 probe_elicit; } | run_server plain 1000
r=$(row plain)
has "plain client: tasks capability no" "$r" "client_tasks=no"
has "plain client: task not returned" "$r" "task=no"
has "plain client: elicitation not offered" "$r" "elicit=not-offered"

# 2. a client that declares both and task-augments the call gets a CreateTaskResult
{ init_line '{"tasks":{"requests":{"tools":{"call":{}}}},"elicitation":{"form":{}}}'; call_line 2 probe_task '{"ttl":60000}'; } | run_server task 1000
r=$(row task)
has "task client: tasks capability yes" "$r" "client_tasks=yes"
has "task client: task returned" "$r" "task=yes"
has "task client: CreateTaskResult on the wire" "$(cat "$TMP/task.out")" '"taskId"'

# 3. elicitation answered with each action, and left unanswered
for act in accept decline cancel; do
  { init_line '{"elicitation":{}}'; call_line 2 probe_elicit; sleep 1
    printf '{"jsonrpc":"2.0","id":"probe-elicit-1","result":{"action":"%s"}}\n' "$act"; } | run_server "e-$act" 5000
  has "elicit $act: recorded" "$(row "e-$act")" "elicit=$act"
done
{ init_line '{"elicitation":{}}'; call_line 2 probe_elicit; sleep 3; } | run_server park 1000
has "silent client: parked" "$(row park)" "elicit=parked"

# 4. the real Claude Code handshake (captured on the VM) is summarised
if [ -s "$FIX/claude-initialize.json" ]; then
  { cat "$FIX/claude-initialize.json"; printf '\n'; } | run_server real 1000
  r=$(row real)
  has "real handshake: client named" "$r" "client=claude-code/2.1.309"
  has "real handshake: no tasks capability" "$r" "client_tasks=no"
  has "real handshake: elicitation capability" "$r" "client_elicit=yes"
else
  fail "real handshake fixture missing"
fi

# 4b. Claude Code 2.1.310 declares tasks as the io.modelcontextprotocol/tasks extension, not a top-level capability
if [ -s "$FIX/claude-initialize-2.1.310.json" ]; then
  { cat "$FIX/claude-initialize-2.1.310.json"; printf '\n'; } | run_server real310 1000
  r=$(row real310)
  has "2.1.310 handshake: client named" "$r" "client=claude-code/2.1.310"
  has "2.1.310 handshake: tasks extension seen" "$r" "client_tasks=yes"
  has "2.1.310 handshake: elicitation capability" "$r" "client_elicit=yes"
else
  fail "2.1.310 handshake fixture missing"
fi

# 5. summarize on an empty log is a refusal, not a vacuous pass
: > "$TMP/empty.log"
bash "$PROBE" summarize "$TMP/empty.log" > /dev/null 2>&1; rc=$?
eq "empty log: refused" "$rc" "2"

# 6. a billed run refuses without --billed, before any client starts (this suite makes no model call)
out=$(bash "$PROBE" run p "$TMP/billed" 2>&1); rc=$?
eq "run without --billed: refused" "$rc" "2"
has "run without --billed: says billed" "$out" "billed"
eq "run without --billed: no client started" "$([ -e "$TMP/billed/server.log" ] && echo started || echo none)" "none"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
