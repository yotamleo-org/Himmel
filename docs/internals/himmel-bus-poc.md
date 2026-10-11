# himmel-bus live POC (HIMMEL-4838)

Result log for the first live run of himmel-bus between two real sessions.
Until this passes, the bus is unit-tested only (store, identity, MCP send/read,
delivery hook, send CLI, launcher register/bind).

Surfaces under test: `marketplace/plugins/himmel-bus/bin/bus` (`send`, `peers`,
`status`) and the bus MCP server (`send`, `read`). Store files are never read or
written directly, and a session never registers or binds itself: that is the
launcher's job (headed-arm-leg.sh, PR 2360).

## Phase A: native leg <-> console

Status: **FAIL (blocked at step 1)**, re-run pending.

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
- Ticket: HIMMEL-5221 (fix scope includes making the launcher failure visible).
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
  bus is opted in on no profile today (HIMMEL-4830 owns the catalog entry).
- Not done on purpose: registering by hand.

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
