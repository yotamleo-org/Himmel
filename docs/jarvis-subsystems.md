# Jarvis subsystems — adopter usage reference

himmel is evolving into an "agentic OS": Claude-main orchestrates a fleet across
model backends, routes each task to the right model, validates with diverse
critics, under a command-and-control surface, on a token-economical footing
(the Jarvis epic). This page is the **adopter-facing** map of the optional
subsystems that make that up — what each is, whether it's on by default, how to
enable it, and where the deep docs live.

> **Default posture: every optional *lane* is OFF until you configure it** —
> the escalation channel, the statusline, and the clipper pipeline each
> need a key, flag, or vault before they do anything. The root `CLAUDE.md`
> delegation table directs skipping absent lanes. Enable only the subsystems
> you want.

| Subsystem | Status | Default | Enable with |
|---|---|---|---|
| [Quota-gauge (cross-lane quota observability)](#quota-gauge--cross-lane-quota-observability) | shipped | **on** (passive) | no setup — reads only |
| [Escalation channel](#escalation-channel) | shipped | **off** | needs a sandboxed worker lane (the GLM lane, dormant) |
| [Statusline](#statusline) | shipped | opt-in | `scripts/lib/wire-statusline.sh` |
| [Clipper pipeline](#clipper-pipeline) | shipped | opt-in | luna vault + `/harvest-clips` |
| [Mission Control / C&C](#mission-control--cc) | shipped (Phase 1, read-only) | opt-in | `bun scripts/fleet-control/server.ts serve` |

---

## Quota-gauge — cross-lane quota observability

**What it is.** A passive observability layer that answers "how much quota is
left, per lane (Claude / Codex / Alibaba)?" — an append-only JSONL
ledger, fail-open (a write failure never breaks a session), that **never**
routes, arms, spawns, or blocks.

**Status: shipped** (#873/#877). The ledger, path resolver, and row-builders
live in **`scripts/telegram/quota-gauge.ts`** (TS twin) and
**`scripts/lib/quota-gauge-ledger.sh`** (bash twin, byte-identical canonical
record), with the shared path resolver in
**`scripts/lib/quota-gauge-ledger-path.sh`**. Lane writers piggyback existing
touchpoints (e.g. a lane's cap-guard) — no new fetch, no new poll — so there is
no separate enable step; the ledger just accumulates as those touchpoints run.

**Name history.** Originally shipped as "headroom" (WS9). Renamed
`headroom` → `quota-gauge` to free the "Headroom" name for an
unrelated tool-adoption candidate.

## Escalation channel

**What it is.** A way for a sandboxed worker that hits a gated capability
(e.g. it needs a push the deny hook blocks) to **ask** the parent/operator for a
scoped grant instead of deadlocking or running under blanket bypass.

**How it works.** Workers only ever **append** an escalation request to their
session's `outbox.jsonl`. The parent/operator is the single adjudicator per
session and responds via a lean CLI:

```sh
bun scripts/telegram/adjudicate.ts list                    # surface pending escalations
bun scripts/telegram/adjudicate.ts grant  <sessionDir> --arm <arm> --pattern <re> [--ttl m] [--uses n]
bun scripts/telegram/adjudicate.ts refuse <sessionDir> <index>
```

A **grant** whitelists exactly one command shape on one deny arm
(`git-push` / `git-url` / `gh` / `network`), TTL- and use-bounded. The deny hook
folds valid grant patterns into its allowed-count, so a grant re-enables one
narrow capability without lifting the wall. A refusal clears the escalation.

**Enable.** It needs a sandboxed worker lane that appends to `outbox.jsonl`;
the only such lane, GLM (see [tooling-catalog](tooling-catalog.md#claude-glm-scriptsclaude-glm)),
is dormant, so the channel stays off until it is re-enabled.

## Statusline

**What it is.** A terminal statusline for Claude Code showing session context
(usage window, ledger segment, configurable bottom-row period). The current
default renderer is **claude-hud**
(`marketplace/plugins/claude-hud/dist/index.js`), a forked Node
renderer; the vendored bash bar in **`scripts/statusline/`** is retained as
the rollback fallback.

**Use it.** Wire it into `~/.claude/settings.json` via
**`scripts/lib/wire-statusline.sh`** (roll back via
**`scripts/lib/unwire-statusline.sh`**, which repoints `.statusLine` to the
bash wrapper `scripts/where-are-we/statusline.sh` — this composes the
vendored `scripts/statusline/` bar with a where-are-we ledger line). See
**[../scripts/statusline/README.md](../scripts/statusline/README.md)** for the
vendored bar's options and
**[../scripts/statusline/VENDORED.md](../scripts/statusline/VENDORED.md)**
for the fork-sync provenance. If the configured statusline command path is
removed or absent, the statusline silently disappears instead of reporting an
error.

## Clipper pipeline

**What it is.** An autonomous, staged pipeline that turns raw clips (web
captures, Telegram forwards) dropped into a luna vault's `Clippings/` into
triaged, synthesized, filed knowledge — the capture arm of the luna second-brain.

**The stages** (each an idempotent `obsidian-triage` skill, safe to re-run):

1. **`/harvest-clips`** — marks each clip harvest-ready; GitHub URLs are
   dispatched to repo synthesis.
2. **`/triage-clips`** — summarizes, infers tags against the vault tag set,
   suggests related notes, extracts action items to the daily note.
3. **`/synthesize-clips`** — cross-clip synthesis: recurring themes → synthesis
   pages + proposed vault restructuring.
4. **`/archive-clips`** — graduates fully-processed clips out of the inbox into
   `Clippings/_done/`, rewriting inbound links.

**Enable.** Requires a luna second-brain vault — scaffold one via the
`obsidian-second-brain` skill (or the `templates/luna-second-brain` template),
then keep it current with `/luna-upgrade`. Run the stages on demand, or arm them
on a cadence.

## Mission Control / C&C

**What it is.** A read-only web dashboard for observing the fleet — worker
status per lane (Codex / Hermes / armed slots), pending escalations, and
quota/posture gauges, with live updates over SSE so the page refetches as
state changes.

**Status: shipped (WS8 Phase 1, read-only).** Lives at
**`scripts/fleet-control/`**. There is no dispatch or adjudication in the UI
yet — the page's own banner says it plainly: "Read-only Phase 1 pane. Dispatch
and adjudication controls remain disabled until Phase 2." Fleet state also
remains available the older way, through the `where-are-we` ledger and the
`/morning-report` command; the dashboard reads that same ledger rather than
replacing it. The adoptable, productized judge module is tracked separately
as a planned follow-up.

**Use it.** `bun scripts/fleet-control/server.ts serve` starts the server,
binding **loopback only** (`127.0.0.1:7350` by default, override with
`FLEET_CONTROL_PORT`). It serves `/` (the dashboard), `/fleet` and
`/escalations` (JSON) and `/events` (SSE); state and bridge roots resolve from
`FLEET_CONTROL_STATE_ROOT` / `FLEET_CONTROL_BRIDGE_ROOT` (`BRIDGE_ROOT`),
defaulting under `~/.claude/handover/bridge`.

---

*Deep-dive docs:* [token-economy.md](token-economy.md) · [hermes-runbook.md](hermes-runbook.md) ·
[internals/enforcement.md](internals/enforcement.md) (the hooks that gate these
lanes) · [internals/telegram-bridge.md](internals/telegram-bridge.md).
