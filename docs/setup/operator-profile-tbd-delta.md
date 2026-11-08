# Operator profile: what the wizard does not set up

The install profile (`scripts/install/capture-operator-profile.mjs`) records
what the wizard's questions can express. This page lists what the operator's
reference machine actually **runs** that no wizard question produces today:
the gap between a fresh install and the operator's own machine. Each row is
one item from a live capture on that machine. To capture it again:

```bash
node scripts/install/capture-operator-profile.mjs --delta-out /tmp/operator-delta.json
```

When you move a setup to a new machine, check each row marked `planned` or
`not planned` on the old machine and set it up by hand on the new one. Do the
same for any part of a `covered by the wizard` row that its coverage cell
says the wizard does not offer, such as ggs in row 1.
`himmelctl gaps` lists the same rows with the same state.

State values: `covered by the wizard` (the wizard asks this now; the row
stays as a reminder to check it), `planned` (closing this gap is planned;
until then, set it up by hand), `not planned` (nothing is planned to close
it; set it up by hand).

| # | Item | Captured how | Wizard coverage today | State |
|---|------|--------------|------------------------|-------|
| 1 | Armed cadences beyond the pipeline family (graphmap, qmd, drift-fix, ggs) | `crontab` enumeration matched against 5 known cadence-id task groups (`delta.cadences.taskDetail`) | The wizard's cadence question selects each cadence on its own, graphmap, qmd and drift-fix among them; ggs drives the operator's own hardware and is not offered | covered by the wizard |
| 2 | Scheduled tasks that exist but aren't in any of the 5 cadence ids (`HIMMEL-BootPreflight`, `HIMMEL-ForkResync` when armed) | Membership check against a known-extra-tasks list, same scheduler enumeration as #1 (`delta.cadences.extraArmedTasks`) | None — these tasks aren't offered, selected, or even named anywhere in the wizard. `HIMMEL-ForkResync` belongs to the drift-fix cadence; `HIMMEL-BootPreflight` is planned as an always-on step the wizard can arm | planned |
| 3 | Observability registry stack (`~/.himmel/observability.json` — `flows[]`, `expected_tasks[]`, `expected_disabled_tasks[]`) | Direct read of `$HIMMEL_OBSERVABILITY_CONFIG` or the default path (`delta.observability`) | None — this registry is written by cadence *register* actions as a side effect; the wizard never surfaces or reconciles it | planned |
| 4 | Bridge persistence artifact detail (the actual `HimmelTelegramBridge` scheduled task / `telegram-bridge.service` unit, beyond the yes/no `installPersistence` answer) | Scheduler/systemd-unit presence check (`profile.bridge.installPersistence`, `delta.cadences.extraArmedTasks`) | The wizard asks a one-time consent to install persistence; it never re-verifies the artifact is still there on a later run | planned |
| 5 | Guardrail env posture — which SESSION-ONLY bypass/threshold vars (`EDIT_ON_MAIN_OK`, `AUTO_ARM_THRESHOLD`, ...) are set in the invoking shell | Presence check (boolean only, never the value) against the names documented in `.env.example`'s SESSION-ONLY section (`delta.envKeys.guardrailEnvPosture`) | None, and inherently shell-dependent (a launch-time export, not a durable answer) — noted explicitly as such | planned |
| 6 | Codex/hermes profile *install completion* (auth provisioned, model pulled) beyond the lane opt-in consent | Indirect — the live lane probe (`delta.lanes.liveLaneIds` containing `codex-exec`/`hermes-oneshot`) confirms the CLI is reachable, not that setup finished | `--with-codex`/`--with-hermes` record the opt-in *consent*; nothing tracks whether the follow-on install script (`install-himmel-codex.*`, `install-himmel-profile.*`) actually completed | planned |
| 7 | Handover registry entries — repo names + count in `~/.claude/handover/registry.json` (never paths) | Direct read (`delta.handover.registryEntryNames`, `registryEntryCount`) | When `HANDOVER_DIR` points at an external repo, the wizard asks whether to register this repo in the handover registry (the same step as `/handover-setup`) | covered by the wizard |
| 8 | HUD config (`claude-hud.json` presence, its top-level key names, whether `statusLine.command` references it) | Existence + `settings.json` substring check (`delta.hud`) | None — HUD setup isn't part of the wizard at all | planned |
| 9 | Repo-root `.env` key NAMES beyond the generated secrets-manifest block (dozens of personal/operator-only keys — home-network, VM, GGS/HA integrations, etc.) | Diff of the primary checkout's `.env` key names against `.env.example`'s generated block + SESSION-ONLY names (`delta.envKeys.keysBeyondGeneratedBlock`) | The wizard's secrets walk only walks the generated manifest; it has no concept of a key beyond that set | not planned |
| 10 | Lane readiness gates (`passesRequired` probation counters) and the full dormant-lane roster (opt-in env names) | Direct read of `scripts/lanes/lanes.json`'s `readiness`/`dormant` fields (`delta.lanes.readinessGates`, `dormantLanes`) | The wizard offers only the 4 wizard-askable lane ids (`ollama-local`, `copilot-cli`, `codex-exec`, `hermes-oneshot`); it never surfaces readiness-gate progress or the dormant-lane roster (`glm`, `openrouter-claude`) | planned |
| 11 | Plugin drift from the lean floor (`enabledBeyondTemplate` / `templateTrueButDisabled`) | Effective `enabledPlugins` (settings.json layered under settings.local.json) diffed against `docs/setup/settings-template.json` (`delta.plugins`) | `pluginSet` is fixed to `"lean"`; nothing re-verifies the LIVE enabled set still matches the floor after an ad hoc `/plugin` toggle | planned |
| 12 | `alwaysOn` inference gap — the capture INFERS `alwaysOn` from armed cadences/bridge persistence (`delta.alwaysOnInferred: true`); it is never an asked-and-recorded answer at capture time | Heuristic over the same cadence/bridge data as #1/#4 | The adopter wizard flow does ask an explicit always-on question, but nothing reconciles that stored answer against what's actually armed on a later run | planned |

## Regeneration

This page is a hand-written frame around rows taken from a capture. When the
capture's shape changes, run the command above again, compare it with the
table, and update the rows by hand. No generator writes this page; it is
meant to be read and judged, not templated. `scripts/himmelctl/tbd-delta.json`
mirrors the table for `himmelctl gaps`: keep each row's number, label, state
and paths the same in both (`scripts/himmelctl/test/test-wizard-gaps.sh`
checks them).
