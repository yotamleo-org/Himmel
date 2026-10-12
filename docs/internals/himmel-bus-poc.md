# himmel-bus live POC

Result log for the first live run of himmel-bus between two real sessions.
Until this passes, the bus is unit-tested only (store, identity, MCP send/read,
delivery hook, send CLI, launcher register/bind).

Surfaces under test: `marketplace/plugins/himmel-bus/bin/bus` (`send`, `peers`,
`status`) and the bus MCP server (`send`, `read`). Store files are never read or
written directly, and a session never registers or binds itself: that is the
launcher's job (headed-arm-leg.sh, PR 2360).

## Phase A: native leg <-> console

Status: **FAIL (five failures; the exchange never started)**.

**Verdict:** send works via CLI once registered; NO working receive path on main
(no wait verb, delivery hooks not installed, MCP server deps absent);
registration is opt-in by profile and no profile opts in.

| # | Failing step |
|---|---|
| 1 | `bus peers` refuses a 755 shared state dir |
| 2 | leg never registered (profile not opted in; skipped without a log line) |
| 3 | no `bus wait` verb |
| 4 | delivery hooks never installed |
| 5 | MCP server deps absent |

### FAIL 1: bus CLI refuses the shared state directory (2026-10-11, base 07f052394)

- Step: `node marketplace/plugins/himmel-bus/bin/bus peers`, as the leg, before any send.
- Error (exit 1), same for `bus status <own name>`:
  `bus: unsafe directory permissions: <HOME>/.local/state/himmel`
- Evidence: `stat -c '%a %U' ~/.local/state/himmel` is `755 overlord`; the
  directory holds only `fleet-recover/`; no `~/.local/state/himmel/bus` exists;
  `XDG_STATE_HOME` is unset.
- Cause: `busRoot()` in `lib/store.mjs` requires 0700 and own uid on every
  directory at or under the state home, including shared parents another tool
  created with a normal umask.
- Consequence: launcher `bus register` has never succeeded on this station. It is
  fail-open and only writes `WARN bus register failed ... launching unbound` to
  the launch log, so nothing surfaced it.
- Follow-up: the fix scope includes making the launcher failure visible.
- Unblock used for the re-run: operator `chmod 700 ~/.local/state/himmel`
  (done 2026-10-11; `stat` shows `700 overlord`).

### FAIL 2: the leg was never registered (2026-10-11, after the chmod)

- Step: `bus peers` and `bus status <own name>` as the leg, state dir now 0700.
- Error (exit 1): `bus: identity unbound`; `bus: unknown session: <own name>`.
- Evidence: `HIMMEL_BUS_NAME` is not in the leg environment; the launch log has
  no `bus register` line at all, not even the fail-open WARN; the leg's
  generated settings contain no `himmel-bus`.
- Cause: the launcher only registers when the leg profile lists `himmel-bus` in
  mcpServers (the `MCP_NAMES_JSON` case in headed-arm-leg.sh); the `leg-impl`
  profile does not, so the register block is skipped without a log line. The
  bus was opted in on no leg profile at the time of this run (the catalog entry was
  a separate follow-up; the `console` profile has since listed `himmel-bus`).
- Not done on purpose: registering by hand.
- Follow-up: a bus-enabled profile + catalog entry, and the silent skip noted under FAIL 1.
- Re-run: launch a leg with a profile that lists `himmel-bus`; `echo
  $HIMMEL_BUS_NAME` is its own name and `bus status <name>` prints `live`.

### FAIL 3: no `bus wait` verb

- Step: look for a CLI verb that blocks until mail arrives.
- Evidence: `bin/bus` accepts register|bind|rebind|adopt|status|peers|send|gc;
  `store.pending` is commented "Shared predicate for the wait CLI" but no CLI verb calls it.
- Re-run: `bus wait --for <name>` exits within 2 s of an append (today: usage, exit 64).

### FAIL 4: delivery hooks not installed

- Step: check that a bound session would be shown mail.
- Evidence: `grep -c bus-deliver ~/.claude/settings.json` prints 0; no entry in
  the repo `.claude/settings.json`; the hooks exist only in the
  `wire-hook-bash.mjs` inventory.
- Re-run: `grep -c bus-deliver` on the leg's effective settings prints 2, and a
  message sent to a bound leg shows as `bus #n from <name>:` in its context.

### FAIL 5: MCP server cannot start

- Step: check the `read <n>` receive path (bus MCP server).
- Evidence: `marketplace/plugins/himmel-bus/node_modules` did not exist in the
  primary checkout or in the POC worktree; the server imports
  `@modelcontextprotocol/server`. Update 13:45 CEST: a `node_modules` (gitignored)
  appeared in the POC worktree at 13:44, installed by nothing this leg ran, and
  the server then started and exited cleanly on stdin EOF. The primary checkout
  still has none, so a fresh clone still hits the failure; nothing in the repo
  installs the deps, and who or what installed them here is unidentified.
- Re-run: `node marketplace/plugins/himmel-bus/server/index.mjs` stays up on
  stdio (today: ERR_MODULE_NOT_FOUND).

### Caveat on the verdict's "send works"

That clause rests on code reading and the unit tests, not on a live run: no
session was registered, so the CLI sender path (identity stamp, edge check,
store append) was never exercised live. The first live `sent #n` is still owed.

## Phase A re-run (2026-10-11, PR 2378: `bus wait`, `leg-bus` profile, server deps)

Probes P1 (`bus-probe-p1-2026-10-11`) and P2 (`bus-probe-p2-2026-10-11`) were
launched on `--profile leg-bus` from the PR's worktree launcher (dry-run showed
`mcp ["qmd","himmel-bus"]`).

### Run 1: FAIL (leg <-> leg)

P1 and P2 both got `no edge ... your edges: (none)`. By design the edge table
allows only leg <-> console and a leg <-> judge/consult pair. The console was
not on the bus either: the console profile lacks `himmel-bus`, so `console.sh`
never registers it.

### Run 2: PASS (leg <-> console)

The console was registered and bound by hand (`bus register <console> --role
console`, bind pid 1852149).

- P2 `peers` listed the console.
- P2 sent #1; the console's `bus wait` printed
  `bus #1 data from bus-probe-p2-2026-10-11: | P2 to console ping 2026-10-11`.
- The console replied with `send ... --re 1` and got `sent #1`.
- P2's `wait` received `console to P2 reply 2026-10-11 re #1` verbatim.

Result: register, send, `bus wait` receive, and reply `--re` all worked live
through `bin/bus` and the `leg-bus` profile with installed server deps. Caveat:
run 2 needed a hand-registered console (fixed since, see run 3); leg <-> leg
needs a pair edge if wanted.

### Run 3: PASS (leg <-> console, console registered by its launcher; 2026-10-11)

No hand registration. Under a scratch handover root (not the operator console's
bucket), with the `console` profile now listing `himmel-bus`:

1. `console.sh new --name bus5241probetwo-console --arm` (throwaway console, haiku,
   scratch template). `bus status <console>` printed `live` with nothing run by
   hand: `console.sh` registered it (`--role console`) and `headed-arm.sh` bound
   the claude pid.
2. `headed-arm-leg.sh --profile leg-bus --console <that console>` launched the probe
   leg. `bus status <leg>` printed `live`.
3. Leg `bus peers` listed the console. Leg `bus send <console> <body>` printed
   `sent #1` (no `no edge` refusal; run 1's failure).
4. Console `bus wait` printed `bus #1 data from <ticket-id>-N1790-bus-probe-2026-10-11:`
   then `| probe leg to console ping <ticket-id>`.
5. Console `bus send <leg> <body> --re 1` printed `sent #1`; the leg's `bus wait`
   returned `poc console reply`.

Result: a fresh console is on the bus from launch; leg -> console send, receive and
reply all worked live. Both sessions were closed afterwards (`bus status` then
prints `gone`).

First attempt note: a console armed with `--deadline-min 40` registers at arm time
but does not launch (and so never binds) until the deadline; killed and re-armed
with `--deadline-min 0`. That abandoned name stays `unbound` in the registry.

## Phase B: native leg <-> claudex (codex) leg

Status: not started (waits on Phase A).

## Re-run recipe

1. Launch the leg with `headed-arm-leg.sh` under a profile that lists
   `himmel-bus` (the launcher registers and binds it). Do not register by hand.
2. From the leg: `bus peers` should list the console edge; `bus status <own name>`
   should print `live`.
3. Leg: write a body file, `bus send <console> <body-file>`; note `sent #n`.
4. Console side: receive via the delivery hook or the bus MCP `read` tool for `#n`;
   reply with `bus send <leg> <body-file> --re <n>`.
5. Leg confirms the reply arrives (hook output `bus #m from <console>`), then
   record PASS/FAIL per step here with the exact error text.
