# Slash Commands Catalog

Project-local slash commands in `.claude/commands/` (auto-discovered by
Claude Code). Each row's **Description** column is machine-generated from the
**verbatim** `description:` frontmatter of that command file; the **Notes**
column is hand-written why/when context and is never checked against the
frontmatter.

Operator-invokable commands shipped by **vendored plugins** under
`marketplace/plugins/` are also listed (see the
[Clipper pipeline](#clipper-pipeline-obsidian-triage-plugin) section) —
their source is the plugin's `commands/<name>.md`, not `.claude/commands/`,
and their rows are paraphrased one-liners rather than verbatim frontmatter
(the plugin descriptions are multi-sentence).

> **Not listed: `marketplace/plugins/claude-hud/commands/`**.
> claude-hud is vendored as the statusline **renderer only** — wired as
> `node …/claude-hud/dist/index.js`, never installed as a plugin (not
> registered in himmel's top-level registry
> `marketplace/.claude-plugin/marketplace.json`; the vendored tree's own
> `.claude-plugin/*` files are inert upstream artifacts), so its upstream
> `/claude-hud:setup` / `/claude-hud:configure` commands are not invokable here. See
> [marketplace/plugins/claude-hud/VENDORED.md](../marketplace/plugins/claude-hud/VENDORED.md).

> **Not itemized: `marketplace/plugins/lean-skills/skills/`**.
> 13 vendored workflow skills (11 from `obra/superpowers`, `grilling` from
> `mattpocock/skills`, plus himmel's own `context7-mcp`) invoked the normal
> Claude Code way — skill-name matching against the request — not via slash
> commands, and it ships no `commands/` directory at all. Itemizing all 13
> here would duplicate the inventory the plugin's own docs already own; see
> [marketplace/plugins/lean-skills/README.md](../marketplace/plugins/lean-skills/README.md)
> and its `VENDORED.md` instead. This carve-out covers every companion file
> under a vendored skill's own directory too (e.g. `executing-plans/scripts/`,
> `subagent-driven-development/scripts/`, `brainstorming/builder-check-prompt.md`) — an upstream re-vendor
> can add or remove one without a catalog edit, since none of them are himmel
> slash commands.

> **Not itemized: `marketplace/plugins/i-have-adhd/skills/`**.
> One vendored skill, `i-have-adhd` (`ayghri/i-have-adhd`, copied verbatim),
> with `disable-model-invocation: true`: the operator invokes it as the skill
> `/i-have-adhd`, it ships no `commands/` directory, and it stays on until
> "stop adhd mode". See
> [marketplace/plugins/i-have-adhd/README.md](../marketplace/plugins/i-have-adhd/README.md).

> **Not itemized: `marketplace/plugins/pstack/skills/`**.
> Seven vendored `cursor/plugins` pstack skills, all `disable-model-invocation: true`
> (`/correct`, `/blast-radius`, `/create-verification-skill`,
> `/maintain-verification-skill`, `/benchmark-checklist`,
> `principle-explain-the-number`, `/in-your-own-words`): typed by the operator,
> no `commands/` directory, on in the interactive `user` profile only. See
> [marketplace/plugins/pstack/README.md](../marketplace/plugins/pstack/README.md).

> **Not itemized: `marketplace/plugins/humanizer/skills/`**.
> One vendored `blader/humanizer` skill, `disable-model-invocation: true`
> (`/humanizer`): typed by the operator, no `commands/` directory, on in no
> profile. See
> [marketplace/plugins/humanizer/README.md](../marketplace/plugins/humanizer/README.md).

> **Not itemized: `marketplace/plugins/shadcn-mcp/skills/`**.
> One himmel-owned skill, `motion-budget`: the design core's short animation
> duration and frequency note, model-invoked (no slash command). See
> [marketplace/plugins/shadcn-mcp/README.md](../marketplace/plugins/shadcn-mcp/README.md).

> **Keep this current.** When a ticket adds, renames, removes, or re-describes
> a command under `.claude/commands/`, the Description column is regenerated
> for you — run `node scripts/lib/gen-commands-catalog.mjs write` and commit
> the result in the same PR (add a new row + Notes cell by hand for a brand
> new command). CI's `doc-invariants` job runs
> `node scripts/lib/gen-commands-catalog.mjs check` and fails on any row whose
> Description has drifted from its frontmatter.

## Worktree lifecycle

| Command | Description | Notes |
|---|---|---|
| /worktree | Create a new worktree under .claude/worktrees/ (no prune). Thin alias for /clean_garden --no-prune. |  |
| /clean | Prune merged-PR worktrees (no create). Thin alias for /clean_garden --prune-only. |  |
| /clean_garden | Prune merged-PR worktrees and (optionally) create a new one in the same shot |  |

## PR / code review

| Command | Description | Notes |
|---|---|---|
| /pr-check | Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output | Run the multi-agent CR review on the current branch and clear the pre-push marker on clean output. Its fenced awk/shell use `$(N)`/`${N}`, never a bare `$<digit>` — the Skill tool substitutes `$1`/`$2`/…/`$ARGUMENTS` throughout a command's whole body, args or not, and clobbers a bare positional/field ref; `command-positional-args` (pre-commit + CI) refuses a regression. |
| /check-ci | Token-free PR merge-gate watcher — loops gh pr checks --watch, verifies threads resolved, returns one exit code. | Token-free PR merge-gate watcher — one process loops inside gh pr checks --watch --fail-fast, then verifies zero unresolved review threads and no changes-requested review, and returns a single exit code (0=green+resolved, 1=red, 2=cannot evaluate/no PR, 3=unresolved threads or changes requested, 5=a required check never reported or the required set is unreadable, 64=usage error — no gate ran), so merge-on-green costs ~zero tokens. |
| /cr-scores | Print the per-critic agreed/availability scorecard and surface drop advice |  |
| /cr-tune | Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals. Never auto-applied. | Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals (.coderabbit.yaml / critics.json) — proposals only, never auto-applied |
| /cr-learnings-refresh | Refresh known-findings.json evidence from the CR ledger + a CodeRabbit learnings export; lists new-class candidates |  |
| /claude-md-audit | Audit changed CLAUDE.md files against the claude-md-improver rubric before PR — audit-only, applies no edits on its own |  |
| /shell-lint | Advisory shell lint (shellcheck + BOM + errexit-leak) on staged shell BEFORE the commit attempt, not after it. | Pre-emptive advisory shell lint — run shellcheck + UTF-8 BOM + errexit-leak checks on staged shell (or named files) BEFORE the commit attempt, so the loop fixes issues instead of bouncing off the pre-commit gate. |
| /backlog-reconcile | Classify the open Jira backlog against merged commits and propose batched closes. Read-only until the operator approves. | Lean-invoke wrapper over `scripts/jira/reconcile-backlog.mjs` (its pure-code classifier) — runs its default `--dry-run` mode, groups the CLOSE/RESCOPE candidates into the batched-close shape from the earlier close-sweep command (A shipped / D rescope partial; B superseded and C stale have no automated trigger in this engine and stay a manual call), and only re-invokes with `--apply --only <keys> --max-close <n> --hygiene-doc <path>` on explicit operator approval. Revives that command's surface, not its ~7-agent fan-out. |

## Handover

| Command | Description | Notes |
|---|---|---|
| /supervisor-session | Start a supervisor session (new) or hand it over (next) — writes the doc, takes the queue lock, prints the launch line. | A supervisor session dispatches implementation worker sessions as separate sessions, rules on their questions via the RETASK channel, gates merges with GO, and arms its successor at 45 % fill — it implements nothing itself. `new` writes the supervisor-session doc from the console template and acquires the queue lock on it; `next` writes the successor stub + this session's HANDOFF skeleton. Distinct from /overnight-shift (one session, in-process subagents, no lock or successor). Also shipped by the himmel-ops plugin so it runs from any repo (`--project`). |
| /console | Alias of /supervisor-session — start a supervisor session (new) or hand it over (next). | Thin alias kept for the old spelling (HIMMEL-5585); same arguments and behaviour as /supervisor-session. Telegram `/console` is a different command and is unchanged. |
| /handover-arm-resume | Arm the OS scheduler to relaunch claude at a given time with a given handover. Dedup-guarded. | Arm the OS scheduler to relaunch claude at the given time with the given handover. Dedup-guarded. Direct schtasks/at invoke. |
| /handover-commit | Auto-commit *.md changes in the handover root (Mode B / external HANDOVER_DIR only). MVP. |  |
| /handover-flush | Session-end consolidation sweep across handover/* branches. |  |
| /handover-link | Report or check where Claude is reading/writing handover state (inline ./handovers or external $HANDOVER_DIR) |  |
| /handover-pr-open | Open or update the PR for the current handover/<TICKET>-<slug> branch. |  |
| /handover-pr-merge | Squash-merge the PR for the current handover/<TICKET>-<slug> branch. |  |
| /handover-resume | Resume a tracked handover item — cold-start brief, latest session, open bugs, CR findings. No arg picks from active. | Chain-resume a tracked handover item to continue work — surfaces its cold-start (brief/context, latest session, open bugs, CR findings); no arg picks from active items; append `overnight` for overnight mode. Thin wrapper on the `handover:handover` skill's `handover-resume` op (the token-lean equivalent of "load <ID>"). Bare himmel-local command (mirrors /handover-resume-armed); adopters with only the plugin invoke the op via `/handover:handover-resume` or "load <ID>". Distinct from /handover-resume-armed (armed-session recovery). |
| /handover-resume-armed | Fast-resume from the last armed session — surface its transcript and stop-point, no manual JSONL archaeology. | Fast-resume from the last armed session — surface its transcript + stop-point (the answered AskUserQuestion = the agreed continuation) with no manual JSONL archaeology. |
| /handover-setup (handover plugin) | First-time handover bootstrap — asks where handover state should live, persists it to .env as HANDOVER_DIR, then runs init (new) or register (existing). Use on a fresh machine/repo before /handover new-epic etc. Plugin-sourced (`marketplace/plugins/handover/commands/handover-setup.md`), not `.claude/commands/` — grouped here with its sibling handover commands for discoverability. |  |
| /morning-report | Generate the dated Morning Report from live git/gh/jira/worktree state at ~zero tokens; --llm enriches it. | Generate the dated 🌅 Morning Report from live git/gh/jira/worktree state at ~zero Claude tokens (no-token default; opt-in --llm enriches TL;DR + Suggested order + theme-clustered Backlog). |

## Session / context

| Command | Description | Notes |
|---|---|---|
| /context-hop | Mid-session jump to a fresh claude session when the context window nears the soft budget. | Mid-session jump to a fresh claude session when context window is approaching the soft budget. Sibling of /handover-arm-resume. |
| /retitle | Infer a himmel-canonical session name from the current branch and print a ready-to-paste /rename line. | Infer a himmel-canonical session name (TICKET-ID + meaningful name) from the current branch and print a ready-to-paste built-in /rename line. |
| /overnight-shift | Auto-dispatch N tickets from Jira as parallel subagents — emits plan + confirms before fanout. |  |
| /pipeline-cadence | Arm/inspect/remove the recurring luna clip-pipeline cadence via schtasks or cron, per-leg --model pins. | Arm/inspect/remove the recurring clip-pipeline cadence (daily /harvest-clips + /triage-clips, daily /synthesize-clips + /archive-clips, daily vault-lint) via schtasks (Windows) or cron (POSIX), interactive-claude shaped with per-leg --model pins. Dedup-guarded. |
| /profile | Inspect or toggle the two-tier plugin profile (ALWAYS vs ON-DEMAND) — list, lean, full, enable/disable one. |  |
| /drift-fix | Resolve upstream fork-drift end-to-end — bump auto-bumpable pins, open a PR, and land it on main once approved. | Resolve upstream fork-drift end-to-end — run the drift guard, mechanically bump every auto-bumpable pin, open a PR, and land it on main once approved. The payload of the nightly drift-fix cadence. Step 1A first runs `scripts/himmel-update.sh` to catch THIS MACHINE up to what already landed on main — the staleness kind no `BEHIND` row can show — and step 2B confirms (a read, not a re-sync) that step 1A's advisory sweep already repaired the `mkt:*` marketplace rows the runbook used to ignore. Both are machine-local, produce no repo diff, and never open a PR. |
| /fork-resync | Re-sync a carried FORK onto a newer upstream base — rebase + audit the additive delta; pushing is operator-only. | Re-sync a carried FORK onto a newer upstream base — rebase the fork's additive delta and audit that it is still additive. An operator-run invocation may continue on to push the fork and move the pin; the nightly fork-resync cadence runs unattended and STOPS after the audit — it never pushes and never moves the pin. |
| /upstream-file | File verified findings upstream (issue / PR / advisory / documented skip) — dupe-gate first, leak-clean, repo-own gates. | The report-upstream half of the fork-maintenance loop (the converge-to-vendor half is /fork-resync, its sibling). The dupe gate (search issues AND PRs, open AND closed, plus security advisories) runs FIRST — before any drafting, cloning, or building — since a competing PR burns tokens and maintainer goodwill. Every finding resolves to one of four filing forms — **issue** (fix needs maintainer judgment), **PR** (unambiguous fix + test), a drafted **private security advisory** (channel choice and submission stay operator decisions, never auto-picked), **documented skip** (already covered by the repo's own automation) — plus two no-file outcomes (**dupe**, **already fixed at HEAD**) — plus a roster row on the tracking ticket. A mechanical leak grep runs on every commit message, title, body, and advisory draft before any push/create call. |
| /end-session-wiki-setup | Configure which Obsidian vault the end-session-wiki hook captures sessions into — by name, path, or LUNA_VAULT_PATH. | Configure which Obsidian vault the end-session-wiki hook captures sessions into — writes env.LUNA_VAULT_PATH into ~/.claude/settings.json (global) or the .claude/end-session-wiki.json vault or vault_path key (this repo only). |
| /speak | BETA — speak text aloud through the local voice daemon; the last reply by default, or whatever you pass. Detached. | **BETA** — speak text aloud through the local voice daemon; the last reply by default, or whatever you pass. Detached and on demand, needs no hook and no always-on state, and is NOT a `himmelctl` install item. Needs a local runtime that is not in the repo — see [`docs/voice.md`](voice.md). |
| /stop | Graceful-halt marker for in-progress /overnight-shift sessions. |  |

## Prompt / discovery

| Command | Description | Notes |
|---|---|---|
| /skill-find | Embedding-indexed lookup over installed skills/commands/agents — eliminates wrong-namespace mistakes. |  |
| /luna-backfill | Backfill old Claude session transcripts into the luna vault as session notes. TOKEN-INTENSIVE — --dry-run first. | Backfill old Claude session transcripts into the luna vault as structured session notes. TOKEN-INTENSIVE — warns before running and recommends --dry-run first. |
| /luna-ingest | Chain-following triage for a github repo URL. Thin wrapper over the obsidian-triage:luna-ingest skill. | Chain-following triage for a github repo URL. Thin wrapper that delegates to the obsidian-triage:luna-ingest skill (LUNA-9 skill conversion — see marketplace/plugins/obsidian-triage/skills/luna-ingest/SKILL.md for the runbook). |
| /telegram-clip | File a Telegram message (text, bare URL, or forward) as a harvest-ready LUNA-2 clip note in luna's Clippings/. | File a Telegram message (text / bare URL / forward) as a harvest-ready LUNA-2 clip note in the luna vault's Clippings/. Thin wrapper that delegates to the obsidian-triage:telegram-clip skill (LUNA-58 — see marketplace/plugins/obsidian-triage/skills/telegram-clip/SKILL.md for the runbook). |
| /roadmap-clips | Aggregate actionable items across the luna vault into a sequenced 60-Maps/ roadmap note. Proposals only. | Aggregate actionable items across the luna vault (daily action items, _deferred.md backlog, synthesis proposals, promotion candidates, component inventory), cluster into a sequenced roadmap mapped to tools, dedup candidate tickets against open Jira, and write a 60-Maps/ roadmap note. Proposals only. Thin wrapper that delegates to the obsidian-triage:roadmap-clips skill (LUNA-59 — see marketplace/plugins/obsidian-triage/skills/roadmap-clips/SKILL.md for the runbook). |
| /luna-upgrade | Content-preserving upgrade of a luna-second-brain vault to the current himmel template. --check just reports. | Content-preserving upgrade of an existing luna-second-brain vault to the current himmel template (dry-run → confirm → apply, or --check to just report whether an upgrade is available). Thin wrapper that delegates to the obsidian-triage:luna-upgrade skill (see marketplace/plugins/obsidian-triage/skills/luna-upgrade/SKILL.md for the runbook). |
| /luna-upgrade-all | Multi-vault luna upgrade sweep — dry-run first, per-vault confirmed apply, backup/restore, conflict-brainstorm. | Multi-vault upgrade sweep — discover all luna-second-brain vaults, dry-run-first, per-vault operator-confirmed apply, backup/restore safety net, and conflict-brainstorm on _CLAUDE.md conflicts. Thin wrapper that delegates to the obsidian-triage:luna-upgrade-all skill (see marketplace/plugins/obsidian-triage/skills/luna-upgrade-all/SKILL.md for the runbook). |

## Clipper pipeline (obsidian-triage plugin)

Four-stage pipeline over the luna vault's `Clippings/` inbox
(HARVEST → TRIAGE → SYNTHESIZE → ARCHIVE). Plugin-provided
(`marketplace/plugins/obsidian-triage/commands/`); full spec in that
plugin's `README.md`. `/luna-ingest` (under Prompt / discovery above) is
the github-repo ingest skill these dispatch to.

| Command | Description | Notes |
|---|---|---|
| /harvest-clips | Stage 1 — autonomous HARVEST pass: mark unharvested clips (`harvested_at:`), dispatch github URLs to `luna-ingest`, clip-body for the rest. Idempotent. |  |
| /ig-media-enrich | IG media rung (after ig-embed): download reel/carousel media via Scrapling (cookieless), local faster-whisper transcript for reels, copy carousel slides into Clippings/_media/ + agent-read slide digest via the mechanical --apply-digest applier. Lean-invoke. |  |
| /x-media-enrich | X/Twitter media rung (parity with ig-media-enrich): for X clips referencing video.twimg.com / pbs.twimg.com media with no media_enriched_at, download the tweet's video/GIF/images via Scrapling (cookieless), local faster-whisper transcript, first-frame screenshot for soundless GIF-like videos, copy images into Clippings/_media/ + agent-read slide digest via --apply-digest. --include-done drives the historical backfill. Lean-invoke. |  |
| /triage-clips | Stage 2 — autonomous triage: summarize, infer tags, suggest Related Notes, extract action items → daily note, annotate promotion candidate, mark `processed: true`. Idempotent. |  |
| /synthesize-clips | Stage 3 — cross-clip synthesis: find recurring patterns across processed clips, write proposal pages to `Clippings/_synthesis/` (proposals only, never restructures). |  |
| /archive-clips | Stage 4 (LUNA-55) — graduate fully-chained clips (harvested ∧ processed ∧ in-synthesis) to `Clippings/_done/<YYYY-MM>/`, rewrite inbound links (literal, boundary-safe), dedup by canonical URL, (re)generate `Clippings/_deferred.md`. |  |
| /synthesize-stubs | SYNTHESIZE stub mode (LUNA-87) — the generative path that compounds the evidence pool into early `status: stub` subject pages. |  |
| /deepen-subject | github source fan-out on promotion (LUNA-89) — fills the `## References` scaffold of a `deepen_pending: true` Tech subject page from its linked github sources. |  |
| /contra | CONTRA passes (LUNA-96/97): ghost-self — past-you (notes older than the `--min-age` duration, default 6m; age from frontmatter `date:`, daily notes falling back to the `YYYY-MM-DD.md` filename) reacting to current-you with verbatim-quote guard; --bridge — one forced cross-domain analogy (max one bridge/day). Appends to today's daily note `## Thinking`. Lean-invoke only. |  |

**One-time backfill (not a stage):** `/migrate-clip-lifecycle <vault> [--dry-run | --apply [--month YYYY-MM] | --rollback <manifest>]` (obsidian-triage, LUNA-86) — deterministic, reversible, resumable engine (`tools/migrate-clip-lifecycle.mjs`) that migrates the historical top-level `processed: true` clips into `Clippings/_evidence/`, stamping `evidence_kind:` and rewriting every inbound wikilink across SIX literal boundary forms (3 plain + 3 `.md`-suffixed, the silent-dangle guard). Folder-keyed idempotent; byte-identical rollback via the manifest. Run ONCE behind a mandatory staging gate — not a recurring pipeline stage.

**Companion (not a stage):** `/read-link <url>` (obsidian-triage, LUNA-78) — vault-first link reader: read an already-harvested clip for a URL before any live fetch; enrich a thin clip, else live-fetch (fxtwitter / WebFetch / luna-ingest) as the last resort. Never Grok. UX inspired by eugeniughelbur/obsidian-second-brain's `/x-read` (clean-room, no vendored fork).

**Companion (not a stage):** `/watch-youtube <url> [--visual]` (obsidian-triage, HIMMEL-5715) — on-demand cookieless YouTube watch/summarize: Scrapling metadata + yt-dlp transcript, optional ffmpeg scene frames (`-fps_mode vfr`); no Gemini/Grok key. Use it instead of the vault plugin's `/youtube`.

## Plugin skills & ops (himmel-ops, obsidian-triage)

Skills shipped by vendored plugins. Most trigger on a symptom or a slash
alias rather than a bare command; rows are paraphrased one-liners. Source
is the plugin's `skills/<name>/SKILL.md` (or `commands/<name>.md` where a
slash alias exists).

| Skill / command | What it does |
|---|---|
| /minerva (himmel-ops) | Run the grill→brainstorm→critic→spec→critic→plan pipeline as ONE pass with an adversarial critic loop between stages — one idea to a critic-hardened implementation plan. The single front door for grill / stress-test / brainstorm. Slash alias + dispatchable skill. |
| /fanout (himmel-ops) | Fan out N work items to the lane the invariant routing policy calls for (judgement/destructive → Fable; multi-step reasoning → Opus; well-specified implementation → Sonnet by default, never a dormant lane; scoped research → Sonnet; bulk mechanical → Haiku, never spawns further). `scripts/lanes/fanout-plan.mjs` validates every item against the LIVE roster (`scripts/lanes/resolve.mjs --json`) and refuses — no plan emitted — an unknown type, an unavailable or dormant lane, a bulk item requesting further spawn, or a destructive/irreversible item routed below judgement. Shows the plan, confirms before dispatching, enforces the context/why/done-looks-like + RETASK-block + attestation-trailer brief shape. |
| /cloud-route (himmel-ops) | Classify tickets CLOUD-OK / LOCAL-NATIVE / HOOK-BYPASS / BLOCKED from touched files vs the trust list and `scripts/hooks/`, run-time needs, ask count (more than 3 is not cloud) and held files (open PRs plus a console list); writes `cloud-brief-HIMMEL-<n>.md` from `docs/handover/cloud-brief-template.md` for each CLOUD-OK ticket, prints one `konsole --separate -e claude --cloud` launch line per brief (never launches) and logs every verdict to `cloud-route.jsonl` in the bucket. `scripts/lanes/cloud-route.mjs`. |
| stuck-playbook (himmel-ops) | Load-on-trigger guardrail-recovery escape-hatches — fires on a denial/friction symptom (auto-mode Bash/Jira write denied, hung permission prompt, missing attestation trailer). Surfaces escape-hatches kept out of the always-on root CLAUDE.md. |
| vm (himmel-ops) | Lean-invoke VM lifecycle + e2e runbook — front door to the central VM-control SDK (`scripts/lib/vmsdk.py`); covers up/down/snapshot/restore/baseline/clone/provision/e2e verbs, the engine pass + skill pass probes, and the `sync_repo`/`install_plugin`/`drive_claude` SDK primitives. |
| /memory-compound (himmel-ops) | Lean-invoke: losslessly compound the per-project auto-memory (`MEMORY.md` index + topic files) into qmd-searchable luna `30-Resources/Tech/` (or himmel `docs/internals/`) reference notes — read-many → write-once → qmd gate → slim index → delete sources. Run when `MEMORY.md` nears its ~24.4KB load budget. Slash alias + dispatchable skill. |
| test-audit (repo skill) | Authoring gate plus audit for low-value or coupled tests; invoke when writing, changing, reviewing or sweeping tests. Source: `.claude/skills/test-audit/SKILL.md`. |
| effort-assess (himmel-ops) | PILOT. Reference-class estimate for one ticket (median, sigma, mean, P80, P30..P70 band, alternatives) that refuses an estimate failing the DoD checklist, plus a version mode (Fenton-Wilkinson P80/P90 with a seeded Monte Carlo cross-check). All numbers in `effort-model.json`. |
| ticket-standard (himmel-ops) | Lean-invoke. Checks a ticket draft for Impact, What, Why, Plan, DoD, Proof and Agent detail; a Task, Story or Bug that fails is refused and parked in an intake queue, Epic, Subtask and a missing Sector only warn. |
| bus (himmel-bus) | Protocol card for himmel-bus messages: `send(to, b, re=n)` / `read(n)`, the `bus #n from <name>:` vs `bus #n data from <name>:` trust split, the 1500-byte ruling cap, and `bus wait` for holding. Bus wiring grants the MCP server and its tool permissions only; the skill itself loads when the himmel-bus@himmel plugin is enabled separately. |
| vault-lint (obsidian-triage) | Filesystem-only, report-only vault health lint — a single deterministic Python pass that converges on large PARA vaults (orphans, broken wikilinks, audit). Vault-agnostic. |
| luna-vitals-extract (obsidian-triage) | Backfill salus health series for one vault time-bucket — extracts (date, metric, value) tuples via the luna-vitals CLI + an LLM prose pass, writing one per-bucket review artifact. Single-writer; never writes 50-Vitals/ directly. |
| /grow-feed-log (obsidian-triage) | Extract a grow-tent feed/watering (free-form text, e.g. "added 5L + 2 caps to the mint") or a bare nutrient-label photo from a Telegram-shaped message and append it to the vault's `20-Areas/Grow/Grow-Feeding-Log.md` — a feed row to `## Log`, a new product to `## Products`. LLM-first (no rigid command grammar); idempotent per message-id; append-only. Telegram routing is LUNA-127 (separate, out of scope). Slash alias + dispatchable skill (LUNA-130). |

The long skills above (`vm`, `memory-compound`, `luna-ingest`) keep a short core `SKILL.md` and load their detail on demand from a `references/` directory next to it (`obsidian-triage/references/luna-ingest/` for `luna-ingest`).

## Utility

| Command | Description | Notes |
|---|---|---|
| /quiet-run | Run a noisy command quietly — one OK/ERR line + log path |  |
| /lanes | Print the delegation/critic/bulk lanes actually available on THIS machine (availability-aware). | Print the delegation/critic/bulk lanes actually available on THIS machine (availability-aware, derived from scripts/lanes/lanes.json + machine state; the invariant delegation policy stays in CLAUDE.md). |
| /himmel-doctor (himmel-ops) | Diagnose common harness health problems (stale guardrail-hook node path, shadowed claude-obsidian, dirty single-writer luna vault, bitbucket-vs-gh, handover-registry gaps, PATH-fragile bare-interpreter MCP servers); severity-grouped report; `--fix` re-bakes the guardrail node wiring; `--file-issue` files ONE consolidated public GitHub issue. |  |
| /himmel-update | Update this himmel checkout (harness) — pull, marketplace, jira CLI, qmd, hermes, luna template, plus advisories. | Update this himmel checkout (harness) — six-item dependency chain (pull, marketplace, jira CLI dist, qmd fork, hermes, luna template) with per-item status + abort-on-first-failure, plus best-effort advisory steps (codex plugin re-sync, statusLine re-wire, plugin gap report, plugin-set reconcile, cadence/guardrail drift checks) and the machine-local catch-up steps (graphify pin sync, cli-proxy-api host roll, installed-marketplaces re-sync, qmd daemon-restart notice). Those catch-up steps exist because a merged pin bump reaches the REPO but not the MACHINE, and that staleness is invisible to `check-plugin-drift.sh` (for a `mode: base` entry the guard reads `synced_base`, which the drift-bump script moved with the pin, never the installed artifact); `--only <item>` re-runs a single step without the full chain. `himmelctl update` runs the same engine. autoUpdate does NOT deliver the checkout (git pull) or the core hooks/slash-commands — it only re-syncs installed plugins from the on-disk dir. A configured LUNA_VAULT_PATH is already refreshed by step 6 of this chain; use /luna-upgrade only for an explicit Luna-only run, and /himmel-update-all for multi-vault workflows. |
| /himmel-update-all | Update BOTH surfaces in one shot — the himmel harness then the luna vault. Pass --check to dry-run both. | Update BOTH the himmel harness (/himmel-update) and the luna vault (/luna-upgrade) in one shot; `--check` dry-runs both. |
| /graph-publish | Publish a freshly-refreshed graphify graph — commit and open/refresh a PR against tracked graphify-out/ artifacts. | Publish a freshly-refreshed graphify graph — commits + opens/refreshes a PR against the tracked graphify-out/ artifacts. |
| /graph-refresh | One-shot operator refresh of the luna and/or himmel graphify graphs — one refresh-graph-map.sh run per corpus. | One-shot operator refresh of the luna and/or himmel graphify graphs — fires refresh-graph-map.sh per corpus serially with the cadence's argument sets. |
| /prose-audit | Find mechanical prose in commands and skills that should be a script call, ranked by candidate size. | Find mechanical prose in commands and skills that should be a script call, ranked by candidate size for inspection — flags files over a size threshold with a high fenced-code ratio; the session judges only the flagged set. |
| /plugin-eval | On-demand, bank-preflighted `claude plugin eval` run for one suite of one plugin | Runs exactly one eval suite for one plugin — never "all suites", never CI/cadence-wired. Bank-preflights via `scripts/plugin-eval-preflight.sh` and checks the `claude` version floor (2.1.269) before shelling out; resolves the narrowest per-suite `--allow-tools` grant (this subcommand has no `--permission-mode` flag). |
