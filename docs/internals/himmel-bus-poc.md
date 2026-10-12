# himmel-bus live POC (HIMMEL-4838)

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

| # | Failing step | Ticket |
|---|---|---|
| 1 | `bus peers` refuses a 755 shared state dir | HIMMEL-5221 |
| 2 | leg never registered (profile not opted in; skipped without a log line) | HIMMEL-5223 (+ comment on HIMMEL-5221) |
| 3 | no `bus wait` verb | HIMMEL-4831 (T8) |
| 4 | delivery hooks never installed | HIMMEL-5030 |
| 5 | MCP server deps absent | HIMMEL-5222 |

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
- Ticket: HIMMEL-5223 (bus-enabled profile + catalog entry; builds on HIMMEL-4830),
  with the silent skip noted on HIMMEL-5221.
- Re-run: launch a leg with a profile that lists `himmel-bus`; `echo
  $HIMMEL_BUS_NAME` is its own name and `bus status <name>` prints `live`.

### FAIL 3: no `bus wait` verb

- Step: look for a CLI verb that blocks until mail arrives.
- Evidence: `bin/bus` accepts register|bind|rebind|adopt|status|peers|send|gc;
  `store.pending` is commented "Shared predicate for the wait CLI" but no CLI verb calls it.
- Ticket: HIMMEL-4831 (T8 ask 2).
- Re-run: `bus wait --for <name>` exits within 2 s of an append (today: usage, exit 64).

### FAIL 4: delivery hooks not installed

- Step: check that a bound session would be shown mail.
- Evidence: `grep -c bus-deliver ~/.claude/settings.json` prints 0; no entry in
  the repo `.claude/settings.json`; the hooks exist only in the
  `wire-hook-bash.mjs` inventory.
- Ticket: HIMMEL-5030.
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
- Ticket: HIMMEL-5222.
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
never registers it. Ticket: HIMMEL-5241.

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
run 2 needed a hand-registered console (fixed by HIMMEL-5241, see run 3); leg <-> leg
needs a pair edge if wanted.

### Run 3: PASS (leg <-> console, console registered by its launcher; HIMMEL-5241, 2026-10-11)

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
4. Console `bus wait` printed `bus #1 data from HIMMEL-5241-N1790-bus-probe-2026-10-11:`
   then `| probe leg to console ping HIMMEL-5241`.
5. Console `bus send <leg> <body> --re 1` printed `sent #1`; the leg's `bus wait`
   returned `poc console reply`.

Result: a fresh console is on the bus from launch; leg -> console send, receive and
reply all worked live. Both sessions were closed afterwards (`bus status` then
prints `gone`).

First attempt note: a console armed with `--deadline-min 40` registers at arm time
but does not launch (and so never binds) until the deadline; killed and re-armed
with `--deadline-min 0`. That abandoned name stays `unbound` in the registry.

## Phase B: native console <-> claudex leg (HIMMEL-5320, 2026-10-12, base 65506b960)

Status: **PASS for send, foreground wait and background wait; FAIL for an idle
leg with nothing running** (the case that failed in N1864b the same day).

Setup, under a scratch handover root (not the operator bucket), nothing
registered by hand:

1. `console.sh new --name bus5320poc-console --bucket buspoc5320 --model claude-sonnet-5-5 --context standard --deadline-min 0 --arm`
   (throwaway native console). `bus status` printed `live` after 4 s.
2. `headed-arm-leg.sh --no-prior-art-check --lane claudex --profile leg-bus --console <that console> <leg> <doc> ...`
   (default claudex model). `bus status <leg>` printed `live` after 6 s.
   `--no-prior-art-check` was needed only because the throwaway brief has no
   prior-art line.

Edge note: a leg <-> leg send has no edge (only leg <-> console and the
judge/consult pair), so the native sender is a console.

| # | Step | Result | Exact output |
|---|---|---|---|
| B1 | launcher joins the claudex leg, `peers` lists the console | PASS | `live`; console `peers` listed the leg |
| B2 | leg `bus send <console> <body>` | PASS | `sent #1 to <console>`; console `bus wait`: `bus #1 data from <leg>:` / `claudex leg ready` |
| B3 | console sends while the leg is blocked in a foreground `bus wait` | PASS | leg printed `bus #1 from <console>:` / `ping-1 FG` 5 s after the send |
| B4 | console sends while the leg is idle at its prompt with a `bus wait` running in the background | PASS | console sent #2 at 20:51:09; the background task exited 0 and woke the leg at 20:51:24 (15 s), printing `bus #2 from <console>:` / `ping-2 BG` |
| B5 | console sends while the leg is idle at its prompt with nothing running | FAIL (not woken) | console sent #3 at 20:51:52; the leg's doc stayed at 30 lines for 120 s; `bus status --unacked` still listed #1 #2 #3 |

Reading of B5: the message sits in the store until something in the leg calls
`bus wait` or reads. Nothing delivers into an idle claudex session: the delivery
hooks are not registered in the repo settings file (HIMMEL-5030, FAIL 4 above,
still open), and a hook only fires on the leg's own next tool call anyway. The
bus fixes the gap only for a leg that is already holding a `bus wait`.

Finding (not fixed here): B4 contradicts the leg preface rule "never end a turn
waiting on a background job, it never wakes up". On the claudex lane with this
launcher a background `bus wait` did wake the leg. The preface and the skill's
"Holding" protocol (a single `bus wait` with `run_in_background`) disagree, and
legs are not briefed to hold one.

No hang: every bus CLI call ran under `timeout 30` and none tripped it. Both
scratch sessions were killed afterwards, the scratch console's lock released,
`bus status` prints `gone` for both names, and the `/tmp/b5320-*` body files
were removed.

## Usage, last 14 days (HIMMEL-5320, counted 2026-10-12)

Source: every transcript under `~/.claude/projects`, `~/.claude-codex`,
`~/.claude-deepseek` and `~/.claude-openrouter` (4694 files), counting executed
`bus status|peers|send|wait|adopt` Bash invocations and `mcp__*himmel-bus*` tool
calls (not text that merely mentions them).

| Surface | Calls |
|---|---|
| `bus status` | 15 |
| `bus peers` | 9 |
| `bus send` | 7 |
| `bus wait` | 4 |
| other CLI verbs | 1 |
| MCP `send` / `read` | 0 |

36 CLI calls and 0 MCP calls. All 36 are POC or probe legs (HIMMEL-4838, 4831,
5241 and this ticket) plus two console `status`/`peers` checks on 2026-10-12.
No organic use.

## Token cost

| Item | Size | Approx tokens |
|---|---|---|
| MCP server `tools/list` (`send`, `read`: name, description, input schema) | 945 bytes model-visible (1416 raw) | ~270 |
| Skill `bus` listing line | ~125 bytes | ~35 |
| Skill body | 961 bytes, loaded only on use | 0 until used |

About 300 tokens per session, against a first-turn floor of roughly 74k: the
listing cost is not the reason to drop it.

## Verdict: fix-adoption

The transport works end to end: send, receive, reply and a foreground or
background `wait` all passed live between a native console and a claudex leg
(Phase A runs 2 and 3, Phase B B1 to B4) at about 300 tokens per session. It has
had 0 organic calls in 14 days, and the one case that motivated it, an idle
claudex leg that is not running anything, is not woken (B5). Dropping it would
discard a working transport that costs almost nothing; keeping it as is leaves
the motivating case unsolved. So: fix adoption, not the code. The gaps are
rollout, not mechanism: only the `leg-bus` profile joins the bus (HIMMEL-4841),
the delivery hooks are not registered (HIMMEL-5030), legs are not told to hold a
background `bus wait` (and the preface says the opposite), and the console still
reaches legs through SendMessage and the file inbox. Re-evaluate after those
land: the bar is organic `bus send`/`bus wait` calls in a 14-day window and B5
passing.

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
6. Phase B (claudex leg): launch with `--lane claudex --profile leg-bus`, then
   repeat 3 to 5 once per receive state, each as its own run: leg blocked in a
   foreground `bus wait`; leg idle with a background `bus wait`; leg idle with
   nothing running. Time-box every bus call with `timeout 30`.
