---
description: Halt a running /afk-shift.
argument-hint: [--hard | --reset]
---

Sets the current project's stop marker: `~/.claude/.overnight-stop` in the
himmel clone, `~/.claude/afk/<project key>/.overnight-stop` in an adopted
project, so a stop there halts only that project's shift. The clone's marker
also halts every adopted project's shift, so `--reset` in an adopted project
does not lift a stop set from the clone: run `/stop --reset` in the clone too.
`/afk-shift`'s dispatch
loop (`.claude/commands/afk-shift.md` step 4, and the fix-dispatch
loop in step 5c) polls it before every subagent dispatch — HIMMEL-2724
lead 4. When set, the dispatcher finishes the in-flight subagent(s) +
halts gracefully before starting the next one — no partial state, and the
tickets not yet started are reported, never silently dropped.

## Modes

| Flag       | Behavior                                                                            |
|------------|-------------------------------------------------------------------------------------|
| _(no flag)_| Soft stop. `bash scripts/afk/stop-marker.sh set` — touches the marker.        |
| `--hard`   | Soft stop + invoke `TaskStop` on every running Task subagent in this session.       |
| `--reset`  | `bash scripts/afk/stop-marker.sh clear` — removes the marker.                 |

## Workflow

1. Parse `$ARGUMENTS` for `--hard`, `--reset`, or none.
2. Run the literal form for the parsed mode — no command substitution
   (HIMMEL-203 bash-shape rule: `$(…)` makes the permission matcher bail):

   - No args (soft stop) or `--hard`: `bash scripts/afk/stop-marker.sh set`
   - `--reset`: `bash scripts/afk/stop-marker.sh clear`

3. **Only when `--hard` is passed:** after setting the marker, walk
   the current session's active Task tool agents (via `TaskList`) and
   invoke `TaskStop` on each one whose status is `in_progress`. This
   kills the in-flight subagent rather than waiting for it to return.

4. Report status to the operator:
   - Soft stop: `Soft stop armed. Current subagent will finish; no new dispatches.`
   - Hard stop: `Hard stop armed. N in-flight subagents stopped.`
   - Reset: `Stop marker cleared. Next /afk-shift will run normally.` If
     `bash scripts/afk/stop-marker.sh status` still shows the global marker
     SET, say instead: `Project stop marker cleared, but the clone's global
     stop is still set; run /stop --reset in the clone to lift it.`

## Dispatcher contract (consumers)

`/afk-shift`'s dispatch loop polls the marker between dispatches
(HIMMEL-2724 lead 4) — this is the reference implementation. Any other
long-running dispatch loop (AFK-mode Phase 3's manual runbook,
autonomous loops) MUST poll the marker the same way, between dispatches:

```bash
if bash scripts/afk/stop-marker.sh check; then
    echo "stop marker set — halting before next dispatch"
    exit 0
fi
```

`check` is silent (no stdout/stderr) and exits 0 when the project's
marker or the clone's global marker exists, 1 when neither does. Cheap to call.

## Status inspection

`bash scripts/afk/stop-marker.sh status` prints human-readable
state (SET with timestamp, or CLEAR) regardless of marker presence.
Always exits 0.

## Smoke test

`bash scripts/afk/test-stop-marker.sh` — 9-scenario test (set,
check, clear, aliases, idempotence, status, unknown-subcommand,
filesystem-error). All pass.
