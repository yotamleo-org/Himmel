# MCP tasks and elicitation launch-mode probe (HIMMEL-7304)

Records, per Claude launch mode, whether the client advertises the MCP tasks
capability and task-augments a `tools/call`, and what happens to an
`elicitation/create` request: answered (`accept`/`decline`/`cancel`) or parked.
Spec: MCP 2025-11-25 (tasks are experimental).

| File | Role |
|---|---|
| `server.mjs` | zero-dep stdio MCP server: `probe_task` (taskSupport optional), `probe_elicit`; logs JSONL to `MCP_PROBE_LOG` |
| `probe.sh` | `summarize` a log into one row, `handshake` a no-model `claude mcp list`, `run` one billed mode |
| `test-probe.sh` | the suite: scripted clients plus the real handshake fixture, no model call |
| `fixtures/claude-initialize.json` | the `initialize` request Claude Code 2.1.309 sent on the test VM (no tasks capability) |
| `fixtures/claude-initialize-2.1.310.json` | the same from 2.1.310, which declares tasks as the `io.modelcontextprotocol/tasks` extension |

## Tier: paid, on-demand only

`probe.sh run` is a real billed model call per run (see "Plugin evals (on-demand,
billed)" in `docs/internals/testing.md`). It is never wired into CI, a cadence or
`run-shell-tests.sh`, refuses without `--billed`, and defaults to `--model haiku`.
`handshake` and `summarize` make no model call. Run it on the test VM only
(risky-commands rule), through `scripts/vm/guest-exec.sh`, with credentials passed
in the call's environment and never written to the guest disk.

Row format: `mode= client= client_tasks= client_elicit= task= elicit=`.
