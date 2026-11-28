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

## Coordinator schedules and wakes

A T3 coordinator runs as short fresh sessions that read a state file, act, checkpoint and end
([running-a-chief.md](../handover/running-a-chief.md#a-t3-coordinator-runs-as-fresh-short-sessions)).
A schedule it needs starts a fresh session on every run:

```json
{"prompt":"Read <absolute coordinator state file>. Use coordinator owner generation <generation>, act, checkpoint, then end.","schedule":{"type":"interval","everyMs":1800000},"bindToCurrentThread":true,"freshSession":true}
```

The thread-tools guard (`scripts/hooks/guard-t3-thread-tools.sh`) refuses an agent's `schedule_task` that
creates (no `scheduledTaskId`, or `null`) an `interval` schedule, as an object or as one level of JSON text,
with `bindToCurrentThread` true or omitted and `freshSession` false or omitted. The rule is
`non-fresh-bound-interval`; the deny prints the form above and never the caller's prompt. Omitted binding
counts as bound, because T3 binds it to the caller's thread in the caller's own project: a schedule meant to
run unbound passes `bindToCurrentThread: false`. One-shot, fixed-time and webhook schedules and updates keep
their existing route. The operator override is `T3_THREAD_TOOLS_OK=1` in the launching shell.

A peer, or the owner of a delegated worker, wakes the coordinator with a queued fresh send. The stable event id
comes first in the message, so the coordinator's bounded activity read can find it:

```json
{"threadId":"<coordinator thread id>","message":"Event <stable event id>. Read <absolute coordinator state file>. Use coordinator owner generation <generation>. <one-line result or status>","mode":"queue","freshContext":true}
```

- **One bounded sweep per scheduled run.** A scheduled fresh run spends one of its four lookups on its own inbound T3
  activity: one messages page (at most 20 items, at most 300 characters per item) plus the recent run ids and
  statuses. It compares the terminal event ids with the consumed ids in the state file and sends each missing
  event id and its run id to the chief for replay. If the page or the run metadata cannot cover every delivery
  since the last completed sweep, it reports the unresolved interval to the chief.
- **Event-only coordinators.** A coordinator with no fresh schedule has no automatic recovery in a quiet
  period. The next relay or an explicit recovery request from the chief runs the same comparison.
- **Operator requests go through the chief**, which sends them on the queued fresh route above. A raw T3 UI
  wake that reuses the provider session invalidates a cost or freshness sample.
- **A stale, retired or missing generation** in the brief makes the turn send the chief a blocker and end
  before it acts or writes. An event id the state file already lists as consumed is a duplicate delivery: the
  turn ends without acting.

## Pull-request tools

T3 gives every session `pull_request_*` tools and tells it to prefer them over `gh`. Three of them would skip
himmel's gates, which all sit on the shell route: the review marker a push writes and `/pr-check` clears, the
chief's GO, the trust-reviewed GO for a CI trust path, and `merge-on-green.sh` with its ledger and chief-doc
records. `scripts/hooks/guard-t3-thread-tools.sh` therefore refuses these three on every harness, under rule
`t3-pr-route`, whatever their input holds:

| Tool | Why it is refused | The route the deny names |
|---|---|---|
| `pull_request_create` | it pushes the thread's branch and opens the PR in one call, so no review marker is checked | push, `/pr-check`, then from the worktree root `bash scripts/lanes/worker-pr-open.sh <title-file> <body-file>` (a chief's worker) or `gh pr create` (any other session) |
| `pull_request_review` | it submits a review outside himmel's routes | `gh pr review <pr> ...` |
| `pull_request_merge` | it merges without the merge gates; `auto` merges at a later head and `stack` merges other PRs | a chief's worker does not merge: it sends READY and its chief merges the PR. A chief runs `bash scripts/handover/merge-on-green.sh <pr> --go <GO file>` from the worktree root. Any other session leaves the merge to the operator |

After a shell `gh pr create`, link the PR to the thread with `link_pull_request` and the PR's URL, in any thread.
`watch_pull_request` also links, but it tells the thread to end its turn, so keep it for T3's own PR monitoring,
not for the step between opening the PR and READY.

The other pull-request tools stay allowed. No shell hook refuses `gh pr edit`, a thread resolve or `gh run
rerun`, so `pull_request_update`, `pull_request_respond` and `ci_rerun` keep parity with the shell route. The read,
list, link and watch tools change nothing a gate guards. `scripts/guardrails/mcp-policy.json` lists the three T3
server keys with the same 18-tool map, so audit rows carry a class; its destructive tools are all in
`allow_destructive`, so the guard, not the policy, decides.

**Bypass.** `T3_THREAD_TOOLS_OK=1` lifts the refusal, as it does every rule of the guard, and prints the allow to
stderr. It also lifts a merge that the shell route's GO and trust-path gates would refuse. It reaches a hook three
ways: the T3 app's own launching shell (every thread of that T3 run on Claude, Codex, Grok and Cursor), a provider
instance whose environment carries it (picked by the operator in the T3 UI, never by an agent), and a terminal
session launched with it. The Antigravity adapter scrubs every `*_OK` variable, so there nothing lifts it.

**What the rule does not see.** A call to the T3 MCP endpoint made with a credential the agent can read is not a
tool call, so no tool-name rule judges it. Two sources exist today: the ACP terminal fallback, where T3 puts the
endpoint and its authorization in an Antigravity agent's environment and the agent can run
`acp-mcp-call <tool> '<json>'` or a plain HTTP call; and a Claude session, where T3 passes the authorization header
in the `--mcp-config` argument, which the process list shows. A text rule on the command would not converge, so
this is a recorded ceiling, and the structural fix is to keep the credential out of the agent's reach or disable
the pull-request tools for agent sessions on T3's side. The rule also reaches only sessions that run himmel's
project hooks: a repo with the plugin-lane merge gate and no project hooks has the gap too, also a recorded ceiling.

## The steer hook

`marketplace/plugins/himmel-ops/hooks/steer-t3-tool-calls.sh` (PreToolUse, plugin lane, suite
`test-steer-t3-tool-calls.sh` beside it) refuses the two commonest wrong calls before they are sent and names the
right one:

| Call | Refused when | The deny names |
|---|---|---|
| `t3_background_wait` | a `taskIds` entry is an Agent id (`a` plus at least sixteen hex digits), contains `placeholder` in any case, is blank, or is not a string (any other form passes, since only these are known to fail) | waiting for the subagent's result message, or starting the command with `run_in_background` and passing its id |
| `t3_thread_send` | `mode` is `steer` and `t3 thread list --json` lists the target thread as idle, completed, interrupted, cancelled, error or failed (any other status passes) | the same send with no `mode` |

It is a workflow nudge, so it fails **open**: no `jq`, input it cannot parse, a missing or failing `t3` CLI, or a
thread absent from the list all allow the call. It cannot see a finished task (rule 1) or a thread that ends
between the check and the send. Bypass for one session: `T3_STEER_BYPASS=1` in the launching shell. Test seams:
`T3_STEER_BIN` (the `t3` CLI; default `$HOME/.t3/bin/t3`) and `T3_STEER_PROJECT` (the project the thread list is
read for; default the Git top-level of the payload's working directory).
