# himmel docs

Map of the `docs/` tree. New here? Start at **[getting-started.md](getting-started.md)**.

## Start here

- [why-himmel.md](why-himmel.md) — the case for the harness: the five failure modes it exists for, the evidence, and what it costs you.
- [adoption-trail.html](adoption-trail.html) — the eight-level adoption trail, as a page you open in a browser: what each level turns on, what it changes, and what it does not. Public URL: https://yotamleo.github.io/Himmel/adoption-trail.html ([how the site is published](#publishing-these-docs-github-pages))
- [system-design.md](system-design.md) — the narrative design document: goals, the parts, one ticket's flow from file to merge, the trust and safety model, and the trade-offs behind the key decisions.
- [architecture.md](architecture.md) — five diagrams: the enforcement layers, the handover system, the fleet/supervisor session model, the Jira seam, the observability chain.
- [getting-started.md](getting-started.md) — clone to your first PR-gated loop in ~15 minutes.
- [daily-loop.md](daily-loop.md) — one full loop (worktree → PR → merge → clean → handover), with every hook and gate explained where it fires.
- [configuration.md](configuration.md) — the canonical configuration + control-surface reference: the chains (mermaid), every gate classified HARD / auth-gated / warn-only, every knob by surface, and the off-switches. Pairs with [.env.example](../.env.example), the per-key flag map.
- [ui.md](ui.md) — the UI surfaces: the `himmelctl ui` config console, the console board, and the roadmap tracker; what each is, how to start it, where it opens.

## Setup

- [setup/new-machine.md](setup/new-machine.md) — fresh-machine setup: required tools + per-platform (Linux / macOS / Windows Git Bash) install.
- [setup/install.md](setup/install.md) — install himmel into an existing repo with `himmelctl`: scopes, install profiles, and the adaptation checklist.
- [setup/migrating.md](setup/migrating.md) — converge an older himmel install (old `adopt.sh`, hand-wired, or a pre-`himmelctl` station) onto the current installer.
- [setup/updating.md](setup/updating.md) — update the harness (`/himmel-update`) and upgrade luna vaults (`/luna-upgrade`); also points to the symmetric `scripts/uninstall.sh` teardown.
- [setup/global-claude-md.md](setup/global-claude-md.md) — Claude Code global config (`~/.claude/`).
- [setup/vms.md](setup/vms.md) — VM-based dev machines for cross-platform testing.
- [setup/rtk-md.md](setup/rtk-md.md) — the rtk token-cost proxy.

## Daily use & reference

- [glossary.md](glossary.md) — the one definition site for the handover vocabulary: console, judge, relay, leg, chain, wave, arming, manual override.
- [commands-catalog.md](commands-catalog.md) — every project-local slash command.
- [tooling-catalog.md](tooling-catalog.md) — every tool, script, and plugin in active use.
- [himmelctl.md](himmelctl.md) — every `himmelctl` verb (status, ensure, update, scope, profile, config, deps, gaps, trust, `--version --all`) with its exit codes.
- [cadences.md](cadences.md) — every recurring job you can arm: what it does, when the wizard offers it, how to arm, status and disarm it.
- [launchers.md](launchers.md) — the `claude-codex`, `claude-openrouter` and `claude-deepseek` launchers, their gates and exit codes; the GLM lane is removed.
- [himmel-bus.md](himmel-bus.md) — **early.** The local session-to-session message bus: CLI, MCP tools, identity, delivery guarantees.
- [jarvis-subsystems.md](jarvis-subsystems.md) — adopter usage map of the optional agentic-OS subsystems (GLM lane, quota-gauge, escalation channel, statusline, clipper pipeline).
- [voice.md](voice.md) — **BETA.** Local speech I/O: `/speak`, the off-by-default `Stop` hook, the daemon, wake word and push-to-talk. Detached and hand-launched — not a `himmelctl` install item, not in the adopter template, and it needs a local runtime that is not in the repo.
- [operator-conventions.md](operator-conventions.md) — durable operator working-habits.
- [contributing.md](contributing.md) — the contribution workflow.
- [token-economy.md](token-economy.md) — per-boundary token-optimizer policy — who owns which token cost and where it's paid.

## How enforcement works (internals)

- [internals/enforcement.md](internals/enforcement.md) — every hook, the pre-commit/pre-push gates, the guardrail matrix, and Claude-invocation billing.
- [internals/handover-system.md](internals/handover-system.md) — the full cross-session handover system + user-slug resolution.
- [internals/jira-plugin.md](internals/jira-plugin.md) — the local Jira CLI ↔ Atlassian MCP op mapping.
- [internals/stuck-playbook.md](internals/stuck-playbook.md) — guardrail-recovery escape hatches.
- [handover/overnight-mode.md](handover/overnight-mode.md) — the unattended overnight pipeline (11 phases, attestation, block criteria).
- [handover/running-a-console.md](handover/running-a-console.md) — starting and handing over a supervisor session with `/console new|next`; the supervisor session + worker-session-brief templates.
- [internals/context-architecture.md](internals/context-architecture.md) — the lean-surface doctrine: where knowledge lives (layering model, the nesting trap, memory-as-map).
- [internals/harness-compat.md](internals/harness-compat.md) — running himmel under Codex / other harnesses — the compatibility matrix + per-feature port/guard/accept decisions.
- [internals/environment-gotchas.md](internals/environment-gotchas.md) — Windows / Git-Bash / git-worktree / scheduler / Bash-tool / content-filter environment traps.
- [internals/egress-matrix.md](internals/egress-matrix.md) — the data-egress policy (owned corpus × provider × purpose) enforced by `scripts/guardrails/egress-matrix.json`.
- [internals/lesson-audit.md](internals/lesson-audit.md) · [internals/lesson-provenance.md](internals/lesson-provenance.md) — the self-evolving lessons-loop precision gate + provenance schema.

## Orchestration & lanes

- [orchestration-patterns.md](orchestration-patterns.md) — coordination doctrine for fan-outs, verify loops, and overnight shifts.
- [internals/ci-orchestrator.md](internals/ci-orchestrator.md) — the queue/scheduling layer over himmel's scarce CI compute.
- [internals/ci-image.md](internals/ci-image.md) — the prebuilt GHCR CI tooling image: contents, build, what ci.yml would change.
- [internals/lane-parity.md](internals/lane-parity.md) — the living compatibility index across delegation lanes.
- [internals/validation-gates.md](internals/validation-gates.md) — placement doctrine for validation/quality gates across workflows.
- [internals/worker-spawn-matrix.md](internals/worker-spawn-matrix.md) — native Hermes subagents vs. external lane workers.

## Integrations

- [jira-projects.md](jira-projects.md) — Jira project setup + conventions.
- [telegram-bridge.md](telegram-bridge.md) · [internals/telegram-bridge.md](internals/telegram-bridge.md) — the Telegram bridge.
- [hermes-runbook.md](hermes-runbook.md) — the hermes junior-tier model lane.
- [luna/README.md](luna/README.md) — the luna companion second-brain vault guides (incl. [end-session-wiki](luna/end-session-wiki.md) + its [schema](luna/end-session-wiki-schema.md), [pr-lane-guard](luna/pr-lane-guard.md), [compounding](luna/compounding.md), [google-health-connector-setup](luna/google-health-connector-setup.md)).

## Setup (continued)

- [setup/cli-proxy-lane.md](setup/cli-proxy-lane.md) — the `cc-codex` CLIProxyAPI lane per-host bring-up checksheet.
- [setup/codex.md](setup/codex.md) — running himmel under OpenAI Codex (`codex-cli`) — step-by-step setup.

## Process, security & audits

- [security-review.md](security-review.md) — the security-review playbook.
- [security/npm-policy.md](security/npm-policy.md) · [security/python-policy.md](security/python-policy.md) — supply-chain hygiene policy.
- [tool-adoption/rubric.md](tool-adoption/rubric.md) — the decision method every community-tool eval runs through.
- [tool-adoption/registry.md](tool-adoption/registry.md) — every evaluated tool, recorded.
- [tool-adoption/telemetry.md](tool-adoption/telemetry.md) — adoption-outcome telemetry for the registry.
- [license-audit.md](license-audit.md) — the license audit.
- [third-party-licenses.md](third-party-licenses.md) — the third-party license audit of direct npm dependencies.

## Publishing these docs (GitHub Pages)

The public repo serves a built docs site at `https://yotamleo.github.io/Himmel/`
(sidebar, search, readable pages). Raw files stay at their old paths, for
example `/Himmel/setup/install.md` and `/Himmel/setup/settings-template.json`,
and `/Himmel/adoption-trail.html` is unchanged.

- **Source.** `site/` is the Starlight workspace and `docs/` is its content.
  `.github/workflows/pages.yml` runs `npm ci` and `npm run build` in `site/`,
  uploads `site/dist` and deploys it. It runs once a day (cron `17 3 * * *`,
  03:17 UTC) and on demand with `gh workflow run pages.yml`; a push that
  changes `docs/**` does not redeploy, so the change goes live at the next
  daily run or on the manual command. `site/allowlist.txt` lists the pages and
  `site/astro.config.mjs` holds the sidebar; a page in `docs/` that is on
  neither list is not on the site. `docs/.nojekyll` stays so a plain static
  serve of `docs/` matches the raw files.
- **Preview locally.** `bash scripts/docs-site/serve.sh` builds the site and
  serves it at `http://127.0.0.1:4321/Himmel/`. The raw files alone:
  `python3 -m http.server 8000 --directory docs`.
- **Check before you merge.** `bash scripts/docs-site/test-site-build.sh`
  builds the site and checks titles, links (a broken link fails the build),
  search and the raw files. `bash scripts/docs/test-adoption-trail.sh`
  resolves every link on the trail page and pins the claims that have drifted
  before (cadence count, lanes menu, plugin provenance) to the tree.
- **Check after.** Once the `Pages` run succeeds,
  `curl -s https://yotamleo.github.io/Himmel/adoption-trail.html | cmp - docs/adoption-trail.html`
  prints nothing when the live page matches your checkout.

## Historical / working records (not a navigation target)

`patches/` (dated point-fix logs) holds dated, single-purpose artifacts kept
for provenance rather than day-to-day reference — browse the directory rather
than looking for an index here.

---

Working as an LLM in this repo? The machine-readable map is [`../llms.txt`](../llms.txt).
