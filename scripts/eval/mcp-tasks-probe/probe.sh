#!/usr/bin/env bash
# scripts/eval/mcp-tasks-probe/probe.sh - which Claude launch modes get MCP tasks and
# elicitation. RUN ON THE TEST VM ONLY (risky-commands rule); the host
# only runs `summarize`.
#
#   probe.sh summarize <log>                     one row from a server.mjs log
#   probe.sh handshake <dir>                     `claude mcp list` against the probe server:
#                                                the client's initialize capabilities, no model call
#   probe.sh run <mode> <dir> --billed [--timeout N] [--model M]
#                                                one launch mode, bounded by timeout (default 120s),
#                                                model default haiku. Every `run` is a real model call.
#       mode: headed | bg | p | p-stream | openrouter
#
# tier: paid. `run` is on-demand only (docs/internals/testing.md "Plugin evals (on-demand,
# billed)"): never wired into CI, a cadence or run-shell-tests, and it refuses without --billed.
# The unit suite (test-probe.sh) uses scripted clients and makes no model call.
#
# Credentials come from the environment of the call and are never written to disk:
#   headed/bg/p/p-stream use whatever auth the claude client already has (or ANTHROPIC_API_KEY);
#   openrouter needs OPENROUTER_API_KEY and sets ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN itself.
# Row format: mode=<m> client=<name/version> client_tasks=yes|no client_elicit=yes|no
#             task=yes|no|not-called elicit=accept|decline|cancel|parked|not-offered|not-called
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROMPT='Call the MCP tool probe_task, then the MCP tool probe_elicit, then reply DONE.'

summarize() {
  local log="$1" mode="${2:-unknown}"
  [ -s "$log" ] || { echo "probe.sh: no server log at $log (the client never started the server)" >&2; return 2; }
  jq -rs --arg mode "$mode" '
    (map(select(.ev == "initialize")) | first) as $i
    | (map(select(.ev == "call" and .tool == "probe_task")) | last) as $t
    | ([.[] | select(.ev == "elicit_unavailable" or .ev == "elicit_sent" or .ev == "elicit_result" or .ev == "elicit_timeout")]) as $e
    | "mode=\($mode) client=\(($i.client.name // "?") + "/" + ($i.client.version // "?"))"
      + " client_tasks=\(if $i.caps.tasks then "yes" else "no" end)"
      + " client_elicit=\(if $i.caps.elicitation then "yes" else "no" end)"
      + " task=\(if $t == null then "not-called" elif $t.task then "yes" else "no" end)"
      + " elicit=\(
          if ($e | map(select(.ev == "elicit_result")) | length) > 0 then ($e | map(select(.ev == "elicit_result")) | last | .action)
          elif ($e | map(select(.ev == "elicit_timeout")) | length) > 0 then "parked"
          elif ($e | map(select(.ev == "elicit_unavailable")) | length) > 0 then "not-offered"
          else "not-called" end)"
  ' "$log"
}

write_config() { # <dir> : MCP config naming the probe server and its log
  jq -n --arg s "$HERE/server.mjs" --arg l "$1/server.log" \
    '{mcpServers: {probe: {command: "node", args: [$s], env: {MCP_PROBE_LOG: $l, MCP_PROBE_ELICIT_TIMEOUT_MS: "30000"}}}}' > "$1/mcp.json"
}

run_mode() {
  local mode="$1" dir="$2" tmo="$3" model="$4"
  mkdir -p "$dir" || return 2
  : > "$dir/server.log"
  write_config "$dir"
  local base=(--mcp-config "$dir/mcp.json" --strict-mcp-config --allowedTools 'mcp__probe__*' --model "$model")
  case "$mode" in
    headed)     script -qec "timeout $tmo claude ${base[*]} '$PROMPT'" /dev/null > "$dir/client.out" 2>&1 < /dev/null ;;
    bg)         timeout "$tmo" claude --bg "${base[@]}" "$PROMPT" > "$dir/client.out" 2>&1 ; sleep "$tmo" ;;
    p)          timeout "$tmo" claude -p "${base[@]}" "$PROMPT" > "$dir/client.out" 2>&1 ;;
    p-stream)   timeout "$tmo" claude -p --output-format stream-json --verbose "${base[@]}" "$PROMPT" > "$dir/client.out" 2>&1 ;;
    openrouter) [ -n "${OPENROUTER_API_KEY:-}" ] || { echo "probe.sh: OPENROUTER_API_KEY not set" >&2; return 2; }
                ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" ANTHROPIC_API_KEY='' \
                  timeout "$tmo" claude -p "${base[@]}" "$PROMPT" > "$dir/client.out" 2>&1 ;;
    *) echo "probe.sh: unknown mode '$mode'" >&2; return 2 ;;
  esac
  echo "client_rc=$?" >> "$dir/client.out"
  summarize "$dir/server.log" "$mode"
}

handshake() {
  local dir="$1"
  mkdir -p "$dir" || return 2
  : > "$dir/server.log"
  # a project .mcp.json waits for interactive approval, so register at user scope on the VM and remove after
  claude mcp remove probe -s user > /dev/null 2>&1
  claude mcp add probe -s user -e "MCP_PROBE_LOG=$dir/server.log" -- node "$HERE/server.mjs" > "$dir/client.out" 2>&1
  timeout 60 claude mcp list >> "$dir/client.out" 2>&1
  claude mcp remove probe -s user >> "$dir/client.out" 2>&1
  summarize "$dir/server.log" handshake
}

cmd="${1:-}"
case "$cmd" in
  summarize) [ $# -ge 2 ] || { echo "usage: probe.sh summarize <log>" >&2; exit 2; }; summarize "$2" ;;
  handshake) [ $# -ge 2 ] || { echo "usage: probe.sh handshake <dir>" >&2; exit 2; }; handshake "$2" ;;
  run) [ $# -ge 3 ] || { echo "usage: probe.sh run <mode> <dir> --billed [--timeout N] [--model M]" >&2; exit 2; }
       mode="$2"; dir="$3"; shift 3
       tmo=120; model=haiku; billed=0
       while [ $# -gt 0 ]; do
         case "$1" in
           --billed) billed=1; shift ;;
           --timeout) tmo="${2:-120}"; shift 2 ;;
           --model) model="${2:-haiku}"; shift 2 ;;
           *) echo "probe.sh: unknown flag '$1'" >&2; exit 2 ;;
         esac
       done
       [ "$billed" -eq 1 ] || { echo "probe.sh: run makes a real, billed model call; pass --billed (on-demand only, see the header)" >&2; exit 2; }
       run_mode "$mode" "$dir" "$tmo" "$model" ;;
  *) echo "usage: probe.sh summarize|handshake|run ..." >&2; exit 2 ;;
esac
