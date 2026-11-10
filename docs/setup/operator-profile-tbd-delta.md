# Operator profile: the gap to a fresh install

Use this page when you move a setup to a new machine. It lists what the
operator's reference machine actually **runs** beyond what a fresh install
sets up. Check each row marked `planned` or `not planned` on the old machine
and set it up by hand on the new one. Do the same for any part of a
`covered by the wizard` row that its coverage cell says the wizard does not
offer, such as ggs in row 1. `himmelctl gaps` lists the same rows with the
same state when it compares against the operator profile, its default; with
any other `--preset` it leaves these rows out, since they were measured on
the operator's machine only.

The install profile (`scripts/install/capture-operator-profile.mjs`) records
what the wizard's questions can express. Each row below is one item from a
live capture on the operator's machine; its State says whether the wizard
covers it or you set it up by hand. To capture it again:

```bash
node scripts/install/capture-operator-profile.mjs --delta-out /tmp/operator-delta.json
```

State values: `covered by the wizard` (the wizard asks this now; the row
stays as a reminder to check it), `planned` (closing this gap is planned;
until then, set it up by hand), `not planned` (nothing is planned to close
it; set it up by hand).

| # | Item | Captured how | Wizard coverage today | State |
|---|------|--------------|------------------------|-------|
| 1 | Armed cadences beyond the pipeline family (graphmap, qmd, drift-fix, ggs) | `crontab` enumeration matched against 5 known cadence-id task groups (`delta.cadences.taskDetail`) | The wizard's cadence question selects each cadence on its own, graphmap, qmd and drift-fix among them; ggs drives the operator's own hardware and is not offered | covered by the wizard |
| 2 | Scheduled tasks that exist but aren't in any of the 5 cadence ids (`HIMMEL-ForkResync` when armed) | Membership check against a known-extra-tasks list, same scheduler enumeration as #1 (`delta.cadences.extraArmedTasks`) | `HIMMEL-ForkResync` is armed together with the drift-fix cadence, which the wizard's cadence question offers (row 1) | planned |
| 3 | Observability registry stack (`~/.himmel/observability.json` — `flows[]`, `expected_tasks[]`, `expected_disabled_tasks[]`) | Direct read of `$HIMMEL_OBSERVABILITY_CONFIG` or the default path (`delta.observability`) | None — this registry is written by cadence *register* actions as a side effect; the wizard never surfaces or reconciles it | planned |
| 4 | Bridge persistence artifact detail (the actual `telegram-bridge.service` systemd user unit, beyond the yes/no `installPersistence` answer) | Systemd user unit presence check (`profile.bridge.installPersistence`, `delta.cadences.extraArmedTasks`) | The wizard asks a one-time consent to install persistence; it never re-verifies the artifact is still there on a later run | planned |
| 5 | Guardrail env posture — which SESSION-ONLY bypass/threshold vars (`EDIT_ON_MAIN_OK`, `AUTO_ARM_THRESHOLD`, ...) are set in the invoking shell | Presence check (boolean only, never the value) against the names documented in `.env.example`'s SESSION-ONLY section (`delta.envKeys.guardrailEnvPosture`) | None: each is set in the shell that launches Claude, for that one launch, and is never saved as an answer. Carrying the names you set to a new machine is planned; until then, note which ones you set on the old machine and set one again only for a launch that needs it | planned |
| 6 | Codex/hermes profile *install completion* (auth provisioned, model pulled) beyond the lane opt-in consent | Indirect — the live lane probe (`delta.lanes.liveLaneIds` containing `codex-exec`/`hermes-oneshot`) confirms the CLI is reachable, not that setup finished | `--with-codex`/`--with-hermes` record the opt-in *consent*; nothing tracks whether the follow-on install script (`install-himmel-codex.sh`, `install-himmel-profile.sh`) actually completed | planned |
| 7 | Handover registry entries — repo names + count in `~/.claude/handover/registry.json` (never paths) | Direct read (`delta.handover.registryEntryNames`, `registryEntryCount`) | When you choose external handover and this repo is not registered yet, the wizard asks whether to register it in the handover registry (the same step as `/handover-setup`) | covered by the wizard |
| 8 | HUD config (`claude-hud.json` presence, its top-level key names, whether `statusLine.command` references it) | Existence + `settings.json` substring check (`delta.hud`) | None — HUD setup isn't part of the wizard at all | planned |
| 9 | Repo-root `.env` key names beyond the generated secrets-manifest block (dozens of personal/operator-only keys — home-network, VM, GGS/HA integrations, etc.) | Diff of the primary checkout's `.env` key names against `.env.example`'s generated block + SESSION-ONLY names (`delta.envKeys.keysBeyondGeneratedBlock`) | The wizard's secrets walk only walks the generated manifest; it has no concept of a key beyond that set | not planned |
| 10 | Lane readiness gates (`passesRequired` probation counters) and the full dormant-lane roster (opt-in env names) | Direct read of `scripts/lanes/lanes.json`'s `readiness`/`dormant` fields (`delta.lanes.readinessGates`, `dormantLanes`) | The wizard offers only two lanes, `codex` and `hermes`, both opt-in; it never surfaces readiness-gate progress or the dormant-lane roster (`copilot-cli`, `ollama-local`, `openrouter-claude` and the other opt-in lanes in `lanes.json`) | planned |
| 11 | Plugin drift from the lean floor (`enabledBeyondTemplate` / `templateTrueButDisabled`) | Effective `enabledPlugins` (settings.json layered under settings.local.json) diffed against `docs/setup/settings-template.json` (`delta.plugins`) | `pluginSet` is fixed to `"lean"`; nothing re-verifies the live enabled set still matches the floor after an ad hoc `/plugin` toggle | planned |
| 12 | `alwaysOn` inference gap — the capture infers `alwaysOn` from armed cadences/bridge persistence (`delta.alwaysOnInferred: true`); it is never an asked-and-recorded answer at capture time | Heuristic over the same cadence/bridge data as #1/#4 | The wizard asks an explicit always-on question, but nothing reconciles that stored answer against what's actually armed on a later run | planned |

## Regeneration

Maintainers: this page is a hand-written frame around rows taken from a
capture. When the capture's shape changes, run the command above again and
compare it with the table. No generator writes this page; edit the rows by
hand. `scripts/himmelctl/tbd-delta.json` mirrors the table for
`himmelctl gaps`: keep each row's number, state and paths the same in both,
and build each JSON label from the words of the row's Item cell; it may be
shorter (`scripts/himmelctl/test/test-wizard-gaps.sh` checks all four).
