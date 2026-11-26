# T3 tool call rules

Five call shapes made up nearly every T3 tool error in the 15 days to 2026-11-26 (about 75 errors; Tool health
page). Each error came from an input the caller could have known was wrong, and each cost an extra
turn. A chief or worker calling the `mcp__t3-code__*` tools follows these five rules.

| # | Tool | Errors | Rule |
|---|---|---|---|
| 1 | `t3_background_wait` | 39 | Pass only the id of a running background Bash command or Monitor. |
| 2 | `t3_thread_organize` | 12 | Settle only a thread with no running turn. |
| 3 | `t3_thread_send` | 10 | Use `mode: "steer"` only on a thread whose turn is running. |
| 4 | `t3_thread_launch` | 3 | Give `modelSelection` an `instanceId` whenever it names a model. |
| 5 | `link_issue` | 3 | Do not call it for a Jira ticket. |

## 1. `t3_background_wait` takes running background ids

The input is `{"taskIds": ["<id>", ...], "waiting": <bool>}`: `taskIds` is an array (one to twenty ids), not a
single `taskId`. An id is the one a background Bash command (`run_in_background`) or a Monitor printed when it
started; it starts with `b` (for example `b001oqmbs`).

These are the wrong ids, in the order the errors show them:

- **An Agent id** (starts with `a`, then hex). A subagent is not a background command: end the turn and its
  result arrives as a message.
- **A finished task.** A wait on a command that already exited returns an error; read the command's output file
  instead.
- **A placeholder** such as `PLACEHOLDER`, sent before the id existed. Start the command first, then pass the
  id it returned.

## 2. Settle only a thread with no running turn

`t3_thread_organize` with a settle on a thread that is still running is refused. Wait for the turn to end (or
for the thread to report idle) and settle then. Settling closes the thread's process at once and T3 settles its
subagent children too. A chief-role thread is never settled or organized at all:
[running-a-chief.md](../handover/running-a-chief.md#chief-threads-in-t3-code).

## 3. `mode: "steer"` needs a running turn

`t3_thread_send` with `mode: "steer"` redirects the turn that is running now. On an idle, finished or settled
thread there is no turn to steer and the call errors. For those, send the same message with **no `mode`**: it
starts a turn on an idle thread (and unsettles it) or queues behind a running one. Use `mode: "restart"` only
when the running turn itself must be thrown away.

## 4. `modelSelection` carries `instanceId`

In `t3_thread_launch`, a `modelSelection` object that names a `model` must also name the `instanceId` of the
provider instance that serves it (for example `claudeAgent`, or a `_relay` copy). `{"model": "claude-fable-5-2"}`
alone is refused with `Expected string at ["modelSelection"]["instanceId"]`. Instance ids come from
[t3-provider-instances.md](t3-provider-instances.md); a bypass or maintainer-profile instance is refused by the
thread-tools guard (`scripts/hooks/guard-t3-thread-tools.sh`).

## 5. No `link_issue` for Jira

T3's `link_issue` resolves its own issue links and does not resolve a Jira browse URL
(`https://<site>.atlassian.net/browse/<KEY-n>`). That is T3 behaviour, so the fix on our side is not to call it
for Jira: name the ticket key in the thread title and brief, and use the Jira plugin
(`scripts/jira/dist/index.js`) for anything on the ticket.

## The steer hook

`marketplace/plugins/himmel-ops/hooks/steer-t3-tool-calls.sh` (PreToolUse, plugin lane, suite
`test-steer-t3-tool-calls.sh` beside it) refuses the two commonest wrong calls before they are sent and names the
right one:

| Call | Refused when | The deny names |
|---|---|---|
| `t3_background_wait` | a `taskIds` entry is not a string starting with `b` (an Agent id, a placeholder, an empty or non-string entry) | waiting for the subagent's result message, or starting the command with `run_in_background` and passing its id |
| `t3_thread_send` | `mode` is `steer` and `t3 thread list --json` lists the target thread as anything but running | the same send with no `mode` |

It is a workflow nudge, so it fails **open**: no `jq`, input it cannot parse, a missing or failing `t3` CLI, or a
thread absent from the list all allow the call. It cannot see a finished task (rule 1) or a thread that ends
between the check and the send. Bypass for one session: `T3_STEER_BYPASS=1` in the launching shell. Test seams:
`T3_STEER_BIN` (the `t3` CLI) and `T3_STEER_PROJECT`.
