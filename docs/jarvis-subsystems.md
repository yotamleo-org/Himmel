# Jarvis: the command layer of the agentic OS

himmel is an agentic OS: a harness on top of Claude Code that runs a fleet of
agent sessions as one software factory. **Jarvis** is its command layer: the
chief plans the work, hands each ticket to a worker in its own worktree, has
the result judged, and merges it. **Mission Control** is the
surface where you watch and steer Jarvis.

This page lists what you can use today, how to start each part, and where its
deep doc lives.

| Part | What it is | Default | Start it with |
|---|---|---|---|
| [Mission Control](#mission-control-the-surface) | the Fleet page, the chief's board, Telegram, the statusline, the morning report and the metrics | each piece opt-in | `himmelctl ui`, `board.mjs`, `bun supervisor.ts` |
| [The fleet](#the-fleet-the-engine) | the chief, its workers, the judge and the GO that gates a merge | opt-in | `/chief new` |
| [Unattended runs](#unattended-runs-the-driver) | arming, relaunch on a usage cap, AFK and overnight shifts | off | `/afk-shift`, `/overnight-shift` |
| [Quota-gauge](#quota-gauge--cross-lane-quota-observability) | how much quota each lane has left | **on** (passive) | no setup, reads only |
| [Escalation channel](#escalation-channel) | a scoped grant for a sandboxed worker | **off** (no lane writes to it) | a sandboxed worker lane |
| [Statusline](#statusline) | session context in the terminal | opt-in | `scripts/lib/wire-statusline.sh` |

> **Default posture: every optional lane is OFF until you configure it.** The
> root `CLAUDE.md` delegation rules skip a lane that is absent. Enable only the
> parts you want.

---

## Mission Control: the surface

Mission Control is several views of one fleet. None of them gives orders: you
steer the fleet by messaging the chief.

- **The Fleet page** of the config UI. `himmelctl ui` serves it at `/agui/`.
  It lists every live Claude session, with a run view per session.
  Detail: [ui.md](ui.md).
- **The chief's board.**
  `node scripts/handover/chief-kit/board.mjs --doc <chief doc> --changed`
  renders the fleet size against the cap, each worker's phase, and what waits
  on whom. The Fleet page shows the same board, read-only, at
  `/agui/#t=<token>&console=<chief doc name>`. Detail:
  [ui.md](ui.md#the-chiefs-board-and-roadmap-tracker).
- **Telegram.** `cd scripts/telegram && bun supervisor.ts` runs the bridge.
  `/chiefs` lists the live chiefs, and `/chief <text>` sends a message to the
  live chief. Detail: [telegram-bridge.md](telegram-bridge.md).
- **The statusline** in each terminal ([below](#statusline)).
- **The morning report.** `/morning-report` summarises an unattended run as
  one page, and you drill into its PRs from there.
- **Metrics.** The Prometheus and Grafana stack charts session and fleet
  numbers: [architecture.md](architecture.md#5-the-observability-chain).

`scripts/fleet-control/` is an older read-only pane, superseded by the Fleet
page. `bun scripts/fleet-control/server.ts serve` binds `127.0.0.1:7350`
(`FLEET_CONTROL_PORT` overrides the port) and serves `/` (the pane), `/fleet`
and `/escalations` (JSON) and `/events` (SSE).

## The fleet: the engine

- **The chief** is one session that holds the plan. It writes a brief for
  each ticket, launches a worker, rules on the worker's questions, and merges.
  You start one with `/chief new`. Detail:
  [handover/running-a-console.md](handover/running-a-console.md).
- **Workers.** Each worker owns one ticket, one worktree and one PR. Its lane
  (native Claude, or a Codex lane) and its model come from
  `scripts/lanes/lanes.json`. Detail:
  [internals/lane-calibration.md](internals/lane-calibration.md).
- **The fleet cap** bounds how many workers run at once (1 to 50, default 4).
  Set it on the Settings page or with `HIMMEL_FLEET_CAP`.
- **The judge.** Before a merge, the chief has the diff judged at the
  cheapest tier that can rule on it (`scripts/handover/chief-kit/judge-ladder.sh`).
  A worker merges only on the chief's signed `GO`, through
  `scripts/handover/merge-on-green.sh`.
- **The RETASK channel.** The chief changes a worker's scope only by a direct
  message that quotes the worker's token, and a change never widens the
  worker's permissions: [internals/retask-channel.md](internals/retask-channel.md).
- **himmel-bus** carries messages between sessions. It is early:
  [himmel-bus.md](himmel-bus.md).

## Unattended runs: the driver

- **Arming.** `scripts/handover/arm-resume.sh` starts a session from its
  handover doc at a set time.
- **Usage caps.** When a session nears its usage cap,
  `scripts/hooks/auto-arm-on-cap.sh` arms it again for the reset.
- **Shifts.** `/afk-shift` and `/overnight-shift` run the fleet with nobody at
  the keyboard and stop only on the block-only criteria:
  [handover/afk-mode.md](handover/afk-mode.md).
- **Initiative.** With `HIMMEL_INITIATIVE` set, a session runs the ship steps
  (review, PR, ticket, merge, handover) at a completion point without being
  asked. The steps and their rails: `scripts/hooks/initiative-runbook.md`.
- **Lessons.** Review findings become proposed lessons. A lesson is only
  proposed, and it is adopted only after its audit passes:
  [internals/lesson-audit.md](internals/lesson-audit.md).

## Quota-gauge — cross-lane quota observability

**What it is.** A passive observability layer that answers "how much quota is
left, per lane (Claude / Codex / Alibaba)?" It is an append-only JSONL
ledger. It fails open, so a write failure never breaks a session. It **never**
routes, arms, spawns or blocks.

**Where it lives.** The ledger, the path resolver and the row-builders are in
**`scripts/telegram/quota-gauge.ts`** (the TS twin) and
**`scripts/lib/quota-gauge-ledger.sh`** (the bash twin, which writes the
byte-identical canonical record). The shared path resolver is
**`scripts/lib/quota-gauge-ledger-path.sh`**. Lane writers ride on existing
touchpoints, such as a lane's cap-guard, with no new fetch and no new poll.
There is no separate enable step: the ledger fills as those touchpoints run.

## Escalation channel

**What it is.** A sandboxed worker can hit a gated capability, for example a
push that the deny hook blocks. The channel lets that worker **ask** the
parent or operator for a scoped grant, instead of deadlocking or running under
a blanket bypass.

**How it works.** Workers only ever **append** an escalation request to their
session's `outbox.jsonl`. The parent or operator is the single adjudicator per
session, and responds with a lean CLI:

```sh
bun scripts/telegram/adjudicate.ts list                    # surface pending escalations
bun scripts/telegram/adjudicate.ts grant  <sessionDir> --arm <arm> --pattern <re> [--ttl m] [--uses n]
bun scripts/telegram/adjudicate.ts refuse <sessionDir> <index>
```

A **grant** whitelists exactly one command shape on one deny arm
(`git-push` / `git-url` / `gh` / `network`). Each grant has a TTL and a use
limit. The deny hook folds valid grant patterns into its allowed-count, so a
grant re-enables one narrow capability without lifting the wall. A refusal
clears the escalation.

**Enable.** It needs a sandboxed worker lane that appends to `outbox.jsonl`.
The only such lane, GLM (see [tooling-catalog](tooling-catalog.md#claude-glm-scriptsclaude-glm)),
is dormant, so the channel stays off until that lane is enabled again.

## Statusline

**What it is.** A terminal statusline for Claude Code. It shows the session
context: the usage window, the ledger segment and a configurable bottom-row
period. The default renderer is **claude-hud**
(`marketplace/plugins/claude-hud/dist/index.js`), a forked Node renderer. The
vendored bash bar in **`scripts/statusline/`** is the rollback fallback.

**Use it.** Wire it into `~/.claude/settings.json` with
**`scripts/lib/wire-statusline.sh`**. To roll back, run
**`scripts/lib/unwire-statusline.sh`**. It repoints `.statusLine` to the bash
wrapper `scripts/where-are-we/statusline.sh`, which composes the vendored
`scripts/statusline/` bar with a where-are-we ledger line. See
**[../scripts/statusline/README.md](../scripts/statusline/README.md)** for the
vendored bar's options, and
**[../scripts/statusline/VENDORED.md](../scripts/statusline/VENDORED.md)**
for the fork-sync provenance. If the configured statusline command path is
removed or absent, the statusline silently disappears and reports no error.

## What Jarvis does not do today

- **No commands from the UI.** Mission Control shows the fleet. You steer it
  by messaging the chief, from a terminal or from Telegram.
- **One harness.** The fleet runs Claude Code sessions plus Codex lanes. A
  bridge that drives other agent harnesses is planned.
- **No single autonomy loop.** Arming, cap relaunch, shifts, initiative and
  lessons are separate parts that you turn on one by one. A unified loop is
  planned.

Clipping and triage of captured web pages belong to the luna vault, not to
Jarvis: see the `obsidian-triage` plugin.

---

*Deep-dive docs:* [token-economy.md](token-economy.md) · [hermes-runbook.md](hermes-runbook.md) ·
[internals/enforcement.md](internals/enforcement.md) (the hooks that gate these
lanes) · [internals/telegram-bridge.md](internals/telegram-bridge.md) ·
[orchestration-patterns.md](orchestration-patterns.md).
