# The on-demand T3 relay

A T3 relay is a thread that wakes other T3 threads, relays a ruling into one, creates or settles a thread
on the chief's word. It sits idle between messages, so it is launched **when the chief needs one** (or when
the last one has gone silent) on a very slim profile, and it is never kept alive (operator decision 1219,
11-22). This replaces the earlier plan to keep a relay alive under T3's 2-hour limit.

## The profile

`t3-relay` in `scripts/lanes/plugin-profiles.json`:

| What | Value |
|---|---|
| Plugins | the floor only (`handover`, `himmel-ops`, `qmd`); `lean-skills` dropped, nothing enabled |
| MCP servers | `himmel-bus` (its `send` and `read` tools) |
| T3 tools | served by T3 itself to every thread, not by this profile |
| Model | `claude-sonnet-5-5` (the launch block names it) |
| Background work | none: no keepalive, no Monitor, no polling loop, no scheduled wakeup |

`scripts/t3/provider-instances.sh` turns the entry into the T3 provider instance `claudeAgent_t3-relay`
([`t3-provider-instances.md`](t3-provider-instances.md)); `himmel-update --only t3_providers` applies it.
`scripts/t3/test-relay-launch.sh` pins the allow-list: the resolved profile enables exactly the floor
plugins and allow-lists exactly `himmel-bus`.

## Launching one

```bash
bash scripts/t3/relay-launch.sh [--brief <file>] [--title <title>]
```

It prints a launch block: `provider:`, `model:`, `title:`, `project:`, `brief:`, then `--- first message ---`
and the brief. The chief sends that through the guarded `mcp__t3-code__` launch tool, with the brief as the
thread's first message. The script itself never starts, sends to or settles a thread; its only T3 call is the
read-only `t3 thread list`.

- The brief is `specs/status/t3-relay-brief.md` in the state repo bucket (the one match under
  `$HANDOVER_DIR/<user>/<project>/`; pass `--brief` when there are none or several).
- A second live relay is refused (rc 3, the live thread id printed): a live relay is a thread with the relay's
  exact title that is not settled. If `t3 thread list` fails the script refuses too (rc 4), because "no live
  relay" is then unproven.

## No keepalive

T3 closes a thread's claude process 30 minutes after its last turn unless it has background work running.
The relay runs none, so an idle relay costs nothing and the chief launches a fresh one. `scripts/t3/keepalive.sh`
is retired from the relay contract and from `docs/handover/running-a-chief.md`; it stays in the tree only for a
session an operator pins by hand.
