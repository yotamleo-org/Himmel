# Tool-adoption registry — every evaluated tool, recorded

> A dynamic index with two jobs: it records every tool that ran through
> the [tool-adoption rubric](rubric.md), **including rejected
> ones**, AND holds our own in-house borrow-candidates — items we like,
> parked, that won't necessarily ship. The rubric decides; this file
> records the decision so it isn't re-litigated, and keeps our own ideas
> searchable so we borrow rather than rebuild. Part of the tool-adoption
> framework.
>
> Rejected rows are the most valuable entries here — they stop a settled
> tool being re-evaluated from scratch next quarter (rubric §3).

## How to read this

- **Layer (A/B/C/D)** and **trust-tier** reuse the rubric's definitions
  verbatim — see [rubric §2](rubric.md#2-trust-posture-tiers) for tiers and
  the layer taxonomy below. Do not redefine them here.
- **Status** is one of the rubric's decision states ([rubric §3](rubric.md#3-decision-states)),
  mapped to a registry-friendly label:
  `in-use` = ADOPT, `pilot-pending` = PILOT-MEASURE (not yet run/closed),
  `rejected` = REJECT.
  - `parked-idea` is a fourth label, used only in the own-items index
    below: an in-house item we like and want searchable to borrow from —
    NOT a community ADOPT/REJECT decision, and NOT committed to ship.
  - `provisional` is a fifth label: not yet a rubric decision state — an
    ADR exists but awaits operator sign-off. The row must name the ADR.
  - A re-audited row adds its re-audit state in brackets, e.g.
    `rejected (KEEP-REMOVED)` ([rubric §5](rubric.md#5-per-sprint-re-audit));
    the [re-audit ledger](#re-audit-ledger) holds the
    measured-on models.
- **KPI** is the desired outcome-per-session, never %-tokens
  ([rubric §1](rubric.md#1-goal-articulation) — the vanity-metric trap).
- **Measuring `in-use` rows** — the before/after protocol only applies to
  net-new installs. For items already in the default path the accepted
  protocol is **measure-during**: 0-cost live telemetry captured while
  real work runs ([rubric §4](rubric.md#4-measurement-protocol);
  format + emit lib: [`telemetry.md`](telemetry.md)).
- **ADR link** — ADRs may not exist yet. `—` means no recorded ADR; the
  source column is the decision trail until one lands. Do
  not fabricate ADR paths.

## How to use this index

- **Search-first** — before building or evaluating anything, search this
  index. A settled REJECT or an existing borrow-candidate may already
  answer the question, no new eval needed.
- **Port-in** — found a community item whose use-case fits a real
  session? Don't adopt on the pitch — open a PILOT (rubric §3) and record
  it here.
- **Borrow** — the own-items `parked-idea` rows are a borrow-library:
  lift the idea, don't re-derive it.

### Layer taxonomy (from the luna synthesis)

Layers are from the 8-tool luna synthesis
(`30-Resources/Tech/token-optimizer-tools.md`): composing across layers is
additive, competing within a layer is substitutive.

- **Layer A** — prompt / response shape (output Claude generates per turn).
- **Layer B** — tool-output filtering (noise tool calls inject into context).
- **Layer C** — setup / scaffolding (how Claude reads the project once).
- **Layer D** — MCP / runtime (protocol-layer; needs MCP-compatible client).

## Registry

| Tool | Layer | Source | Status | Desired outcome (KPI) | Trust-tier | ADR |
|------|-------|--------|--------|-----------------------|------------|-----|
| rtk | B (tool-output filtering) | `luna 30-Resources/Tech/token-optimizer-tools.md`; `docs/tooling-catalog.md` | in-use | Less tool-output noise in context per session → longer useful context window, fewer re-launches on long sessions | `community-active → validate-before-adopt` (battle-tested, Rust binary, zero deps) | — |
| token-savior | D (MCP / runtime) | `luna 30-Resources/Tech/mibayy-token-savior.md` | rejected | (structural code-nav + persistent memory) — rejected 2026-06-13: its pitch is token-% (-77% active / -76% wall benchmark), but our KPI is outcome-per-session, NOT token-% (rubric §1 vanity-metric trap; @ashwingop's "Token Burn Is the New Vanity Metric", cited in the eval record itself). rtk already serves Layer-B tool-output noise reduction; a substitutive token-% optimizer buys no new outcome-per-session, only added MCP-runtime surface + an unreproducible benchmark. Verdict: REJECT | `source-read-mandatory` (claims a benchmark — 100% / -77% active / -76% wall on Opus 4.7 — we can't independently reproduce, so read the impl) | eval ADR comment |
| engram | memory layer (D-adjacent) | LUNA-44 | pilot-pending | Persistent memory survives across sessions → fewer "re-explain the same context" turns, work resumes faster | `source-read-mandatory` (persistent-memory store; touches what the agent remembers — read before it runs) | — |
| skill-factory / autoresearch | skill-quality | backlog item | pilot-pending | Higher-quality generated skills → fewer manual skill fix-ups, a research loop that actually files usable output | `community-active → validate-before-adopt` (sandbox-test generated skills in a throwaway worktree before any real use) | — |
| nizos/tdd-guard | PreToolUse hook | `luna 30-Resources/Tech/nizos-tdd-guard.md` | pilot-pending | TDD enforced structurally → fewer untested-code regressions slipping through | `source-read-mandatory` (touches the PreToolUse hook stack — sees/alters every tool call; rubric §2 makes impl-read non-negotiable) | — |
| hermes-agent (Nous) — junior + CR-critic + alpha main tier | agent runtime (D-adjacent — separate agent under himmel orchestration) | rubric pass + ADR comment, 2026-06-11; gemini-cli route spike (OAuth routes later VOIDED by operator); free routes WIRED 2026-06-12 (live route SUPERSEDED 2026-06-24 → Codex/`gpt-5.5`); additive `himmel_agent` main-tier profile (**alpha**, 2026-06-24); CR-critic lane wired into `/pr-check`; route table + new-user how-to `docs/hermes-runbook.md`; `luna 30-Resources/Tech/nousresearch-hermes-agent.md`; install `%LOCALAPPDATA%/hermes` | pilot-pending | Junior-shaped chores (vault inbox capture, note-taking, summaries) ship on free inference without burning Max quota or operator babysitting; zero write-fence violations | `source-read-mandatory` (free Nous endpoint — prompts leave the machine; mitigations: curated read tier hot.md/index/CLAUDE.md/synthesis/60-Maps, write fence `Clippings/hermes-*.md` only, in-house fail-closed `lunavaultguard.py` guard hook — self-protecting, authored + read locally) | rubric-pass ADR comment |
| mksglu/context-mode | B (tool-output filtering) | primary eval completed 2026-06-12; the token-savior eval's acceptance criteria (superseded passing rejection); `luna 30-Resources/Tech/mksglu-context-mode.md`, `…/token-optimizer-tools.md` | rejected | (tool-output sandboxing) — rejected ON-MERITS after full source read + sandbox test: 0% structural reduction on 4/5 noisiest himmel patterns (native Glob/Grep/Read/Bash pass through unchanged, advisory nudges only), net-negative always-on session overhead, 3 hook-stack interference vectors (deny short-circuits PreToolUse chain; unlocked settings.json read-modify-write; ~500-word Agent-prompt mutation per dispatch) | `source-read-mandatory` (98% claim measured: their own BENCHMARK.md says 96%, conditional on voluntary ctx_* routing — not interception) | context-mode eval ADR (operator's private handover repo) |
| lightpanda-io/browser | headless-browser backend (infra, D-adjacent) | Docker-on-Windows eval, completed 2026-06-12, 14 days inside timebox; hermes `AGENT_BROWSER_ENGINE=lightpanda` (wired-adjacent, auto-fallback to Chrome); `docs/hermes-runbook.md` | rejected | (lightweight headless browser) — rejected NO-WORKLOAD after live Docker probe: viability CONFIRMED (image 68.5 MB vs Chrome 281 MB; 40.5 vs 88.8 MiB RSS; 0.68 s startup; CDP + puppeteer-core worked first try on Windows Docker; GitHub/blog pages render full text) but every candidate slot fails today — IG `/embed/captioned/` returns a 114-char shell (the shipped plain-fetch rung gets full captions), clipper harvest needs no browser (LUNA-2 bodies), hermes junior-tier browsing is not yet a real workload. Re-open trigger: hermes browsing chores materialize → set `AGENT_BROWSER_ENGINE=lightpanda` (one env var, auto-fallback to Chrome) + PILOT-MEASURE. Beta caveats: CORS unimplemented, no screenshots, x.com loads shell-only pre-hydration, glibc-only binaries | `community-active → validate-before-adopt` (validated in throwaway Docker sandbox; no hook/secret surface, container-isolated; benchmark claims independently reproduced on memory, NOT on nav speed) | lightpanda eval (operator's private handover repo) |
| ooples/token-optimizer-mcp | D (MCP / runtime) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (MCP caching/compression) — rejected: no reproducible benchmark; relies on caching-style claims with no measured number we can verify | `source-read-mandatory` (claims -95%+, unverifiable) | — |
| drona23/claude-token-efficient | A (prompt / response shape) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (terse-response CLAUDE.md policy) — rejected: lower-leverage layer; overlaps existing CLAUDE.md hygiene, marginal outcome-per-session gain | `docs-claim-trusted` (drop-in CLAUDE.md, trivially reversible) | — |
| alexgreensh/token-optimizer | C (setup / scaffolding) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (ghost-token / compaction-drift audit) — rejected: lower-leverage layer; no benchmark, periodic-audit value unproven for this workload | `community-active → validate-before-adopt` | — |
| nadimtuhin/claude-token-optimizer | C (setup / scaffolding) | `luna 30-Resources/Tech/token-optimizer-tools.md` | rejected | (one-time project-doc rewrite) — rejected: lower-leverage layer; one-shot setup pass, marginal recurring outcome | `community-active → validate-before-adopt` | — |
| `/code-review ultra` (built-in) | CR toolkit (review subagents) | eval 2026-06-13, items 2–4 | in-use | Lower missed-critical on big/risky PRs — multi-agent **cloud** escalation tier for exactly the PRs where solo/holistic passes are weakest (the class where cavecrew-solo fabricated 2 Criticals). **MOST EXPENSIVE tier — costs MORE than the 6-reviewer heavy CR, so it sits ABOVE heavy CR on the cost ladder: reach it AFTER heavy CR for the biggest/riskiest PRs, never as a cheaper first escalation** (operator-conventions.md CR-sizing ladder). User-triggered + **billed**; the agent cannot launch it. Open follow-up (operator, billed, one action): a live calibration run on a recent real PR to confirm it adds catches over the solo pass without flooding noise | `docs-claim-trusted` (built-in Anthropic tool, zero install, trivially reversible — rubric §3 ADOPT-without-pre-measurement case) | CR-toolkit eval ADR comment |
| wshobson/agents code-reviewer | CR toolkit (review subagent) | eval 2026-06-13; `luna 30-Resources/Tech/wshobson-agents.md` | rejected | (CR subagent swap) — rejected: substitutive with the `pr-review-toolkit-himmel` fork AND lacks its confidence-gate + verify-before-critical discipline (verbatim source-read of `plugins/comprehensive-review/agents/code-reviewer.md` — "elite/comprehensive" maximalist posture, no threshold). Replayed-PR benchmark (#463 + #453): ties the fork on the KPI (0 false Criticals both) but +9 minor-noise findings across 2 PRs vs the fork's 0; only a marginal recall edge. Wrong direction for a fabricated-Critical failure mode. Scope: reviewer-as-toolkit-swap only — broader 192-agent marketplace not re-litigated | `community-active → validate-before-adopt` (validated: verbatim source-read + 2-PR replay) | CR-toolkit eval ADR comment |
| tirth8205/code-review-graph | CR toolkit / code-intelligence graph (MCP + CLI) | eval 2026-06-13; `luna 30-Resources/Tech/tirth8205-code-review-graph.md` | rejected | (repo-context graph for reviews) — rejected: its only benchmark is %-token-reduction (~82× median / 528× max), the vanity metric rubric §1 says to read-the-impl-not-adopt; its review-quality 0.71 F1 is **circular** by the author's own admission ("ground truth comes from the same graph edges the predictor walks … upper bound by construction"). Targets "reviewer lacks context" but the anchor's context-failure already self-corrects via grep + is cured by verify-before-critical (shipped, zero-cost), and the tool REDUCES files-read (wrong direction). No measured KPI benefit + MCP-runtime blast radius = REJECT. Parked-idea below | `source-read-mandatory` (claims benchmark numbers + MCP runtime — impl/claims read) | CR-toolkit eval ADR comment |
| firecrawl/firecrawl (`/v2/scrape` API) | D (runtime / external data-fetch) | thin-body escalation, 2026-06-16; clip `firecrawl-firecrawl.md` → `30-Resources/Tech/firecrawl-firecrawl.md` | in-use (opt-in escalation) | Thin-body **article/web** clips the Web Clipper captured poorly get clean markdown instead of being lost → the deferred LUNA-27 gap closes for non-X/non-github URLs, without a browser. **Escalation lane, not a default path** — gated behind `--firecrawl-thin`, budget-capped (`--firecrawl-budget`, default 20/run) to protect the 1000-credit/mo free tier; X/github/youtube excluded (owned by twitter-cli / luna-ingest / playwright-youtube). Self-host via `FIRECRAWL_BASE_URL` for operators with more budget. The hosted API SDKs are AGPL but we call the REST endpoint over stdlib urllib (no dep, no code lifted) | `docs-claim-trusted` (well-known hosted API; only public URLs + the page content transit firecrawl's servers — no secrets egress beyond the API key; trivially reversible — drop the flag). **Open: 1-credit live smoke** to confirm the documented `/v2/scrape` response shape against the live API | — |
| public-clis/twitter-cli (agent-reach X backend) | D (runtime / external data-fetch) | `feat/x-thread-reply-capture` bake-off 2026-06-14 | not integrated: the cookie-backed enrich rung was removed (HIMMEL-4709) | Capture X reply-thread + first-comment repo URL per flagged clip → clips whose payload lives in a reply/self-thread ("↓ repo in comment") get enriched, not lost. **Won the bake-off vs Playwright** (Playwright blocked at login by X/Google anti-automation; couldn't even capture a session). `twitter tweet <id> --json` returns focal + same-author self-thread + other-author replies + `quotedTweet`, each with pre-parsed `urls[]` (proven: extracted `github.com/Panniantong/Agent-Reach` from the example's first self-reply). Auth = explicit `TWITTER_AUTH_TOKEN`/`TWITTER_CT0` in gitignored `.env` (Chrome App-Bound-Encryption v127+ kills cookie auto-extraction). **BURNER account only, never the main.** Adoption decided; pipeline integration is the open implementation | `source-read-mandatory` (scrapes X with burner session cookies — ToS-gray, account-ban risk, reads the cookie DB; impl + auth read mandatory) | — |
| obsidian-second-brain research toolkit (`/x-read`, `/x-pulse`, `/research`, `/research-deep`, `/youtube`) | D (runtime / external data-fetch) | 2026-07-29 skill-hygiene audit (retroactive — installed 2026-05-16, no ADR filed until now); `docs/tooling-catalog.md` | provisional (pending operator sign-off) | (Grok/Perplexity-backed research commands) — provisional 2026-07-29, pending operator sign-off: no active XAI/Grok or Perplexity subscription behind the credentials file (a file's presence is not a working key), and the vault-first capture pipeline already covers X and YouTube content without any external API. `/notebooklm` (Gemini File Search, different key) is unaffected | `source-read-mandatory` (external API, secret + network egress — never independently evaluated at install time) | `specs/adr/adr-obsidian-second-brain-research-toolkit.md` in the handover state repo (DRAFT, pending operator sign-off) |
| unslop (`cursor/plugins` pstack) | A (prompt / response shape) | scoped-research leg + operator pilot decision, 2026-09-17 | pilot-pending | AI-tell removal in human-facing documents (PR bodies, ADRs, handovers, tickets) → fewer operator reword-passes per document. Rubric §1 does NOT pass on evidence (no CR finding/stuck loop/operator complaint about AI-sounding prose exists) — operator chose to pilot anyway given near-zero cost/blast-radius; close on operator-verdict outcome across 3-5 documents, never on rule-count applied | `community-active → validate-before-adopt` (33 numbered style rules, injection scan clean, Layer-A prompt content only — no hook/secret/network surface, reversible by deleting one file) | `specs/adr/adr-unslop-skill.md` in the handover state repo |
| test-audit (`openclaw/openclaw` `.agents/skills/test-audit`) | A (prompt / response shape) | operator request, 2026-09-24; folds the GPT-6 test-audit findings | adopted | Fewer tests that stay green when their subject breaks: an authoring gate at write time, plus a candidate-evidence record before any test is removed. Measured by the first audit pass shipped in the same PR (RED-at-base excerpt per repaired suite) | `community-active → validate-before-adopt` (read in full, no hook/secret/network surface, Layer-A prompt content only; adapted with deviations listed in the SKILL.md header, reversible by deleting one directory) | — (provenance header in `.claude/skills/test-audit/SKILL.md`) |
| caveman (`JuliusBrussee/caveman`) | A (prompt / response shape) | sprint-1 re-audit (2026-09-30, `claude-sonnet-5-5`) | rejected (KEEP-REMOVED) | (terse-output style) — upstream is alive again, but `skills_guard` (`ec5f441`) still flags `caveman-compress` dangerous, and a 3-prompt A/B showed -10% output tokens, roughly cost-neutral once the skill text is paid for; ponytail holds the terse-mode slot | `source-read-mandatory` (its compress skill rewrites `CLAUDE.md`) | state repo `specs/audit/reaudit-2026-09-sprint1.md` |
| agent-skills (`addyosmani/agent-skills`) | skills | sprint-1 re-audit (2026-09-30) | rejected (SKIP) | (engineering-workflow skill pack) — no himmel problem named; overlaps lean-skills/superpowers-derived skills and `test-audit`; scan criticals are false positives on defensive prose, but it ships PreToolUse-path hooks | `source-read-mandatory` if revisited (hooks) | state repo `specs/audit/reaudit-2026-09-sprint1.md` |
| Understand-Anything (`Egonex-AI/Understand-Anything`) | C (setup / scaffolding) | sprint-1 re-audit (2026-09-30) | rejected (SKIP) | (LLM-built codebase knowledge graph + dashboard) — duplicates graphify at comparable token cost, no himmel workflow consumes a dashboard | `community-active → validate-before-adopt` | state repo `specs/audit/reaudit-2026-09-sprint1.md` |
| OpenAI Evals (hosted Evals platform + API) | eval framework (external; outside layers A–D) | eval-tooling research Q4; read 2026-10-06 at `https://developers.openai.com/api/docs/deprecations` | rejected | (eval harness) — rejected 2026-10-06: deprecated and scheduled to shut down on 2026-11-30. OpenAI's deprecations page: deprecation announced 2026-06-03, existing evals read-only 2026-10-31, "Evals dashboard and API are scheduled to shut down" 2026-11-30, and it points users at promptfoo as the migration path. Nothing to adopt; the OSS repo's status was not verified and is not relied on | `docs-claim-trusted` (vendor deprecation notice; no install) | — |
| Langfuse (self-host) | eval / trace store (external) | eval-tooling research Q4; read 2026-10-06 at `https://langfuse.com/self-hosting` | rejected (single workstation) | (trace + eval store) — rejected 2026-10-06 for a single workstation on footprint: the self-hosting page lists PostgreSQL (transactional), Redis/Valkey (cache + queue), ClickHouse (observability data), S3/blob storage (raw events + attachments), plus a web and a worker container. Four backing stores plus two app containers for one operator's traces; Phoenix (below) needs one container. Re-open trigger: a multi-user deployment that already runs this stack | `source-read-mandatory` (holds secrets and prompts, opens network listeners) | — |
| promptfoo | eval runner (external) | eval-tooling research Q4; read 2026-10-06 at `https://www.promptfoo.dev/docs/configuration/telemetry/` and `https://www.promptfoo.dev/blog/promptfoo-joining-openai/` | rejected (for now) | (assertion-per-case eval runner) — rejected 2026-10-06 for now: telemetry is on by default ("collects basic usage telemetry by default"; off with `PROMPTFOO_DISABLE_TELEMETRY=1`), and the company announced 2026-03-09 that it "has agreed to be acquired by OpenAI" (it states it stays open source). A CLI-wrapping adapter would be easy, but it adds only a UI over the native runner; borrow its assertion-per-case + pass-threshold exit codes for `eval-compare` instead. Re-open trigger: a need for its red-team or UI features | `source-read-mandatory` (telemetry egress, ownership change) | — |
| Inspect (UK AISI, `inspect_ai`) | eval framework (external) | eval-tooling research Q4; read 2026-10-06 at `https://inspect.aisi.org.uk/agent-bridge.html` | rejected (DEFER) | (epochs + reducers, `.eval` logs + viewer) — deferred 2026-10-06: its sandbox agent bridge runs "a proxy server inside the sandbox container" that "relays requests to the current Inspect model provider", so a CLI agent's model calls go through Inspect's provider config instead of the Claude Code subscription session in a worktree with live hooks. The page does not specify the provider credential requirement; any API-key requirement remains an inference. Re-audit trigger: himmel runs evals on an API key. Borrow epochs/reducers and stderr for a planned follow-up | `source-read-mandatory` (proxies every model call; credential path) | — |
| Arize Phoenix | trace store (external, D-adjacent) | eval-tooling research Q4; read 2026-10-06 at `https://github.com/Arize-ai/phoenix` | pilot-pending | One local store for Claude Code OTel traces → an eval row links to its trace by session id. Scope: the trace store ONLY, not an eval runner. Facts read 2026-10-06: SQLite default storage, Docker ports 6006 (UI) and 4317 (traces), licensed under the Elastic License 2.0. Close the pilot on the trace-store work's measured outcome | `community-active → validate-before-adopt` (ELv2 is source-available, not OSI open source; local-only, no prompt egress if unexposed) | — |
| sybil-solutions/ai-data-extraction | C (session-transcript extraction, external) | `https://github.com/sybil-solutions/ai-data-extraction` pinned `9176c2dd81c8a101b52debd4cec88573284e2b30`, source read and run 2026-10-11 | rejected | (cross-tool Claude + Codex session metrics) — rejected 2026-10-11 after source read + run: no network egress, but the Codex extractor misses most tool and token records and its output is raw text, not the closed-vocabulary shape leg-digest ships. Re-open if upstream reads current Codex tool records | source-read-mandatory | `specs/adr/adr-ai-data-extraction.md` in the handover state repo |
| Pydantic AI | agent framework (external, library) | HIMMEL-4702; vendor docs read 2026-10-13 at `https://pydantic.dev/docs/ai/overview/` | rejected (for the himmel agent loop) | (typed-output agent library) — rejected 2026-10-13 as a replacement or strengthening of any himmel part. It is the best fit of the three agent frameworks (typed outputs, `anthropic:` model strings, OTel-native instrumentation, any OTLP backend, Temporal/DBOS/Prefect durable execution), but it drives model APIs from its own process: that draws an API key, not the Claude Code subscription session, and its tool calls never pass the PreToolUse hook stack, so "hooks govern every tool call" fails. The one overlap with a real himmel moment, parsing a judge verdict into a typed shape, is already served by the gate-parsed `READY` / `FINDING:` lines. Re-open trigger: himmel runs a non-Claude-Code agent on an API key, with its hooks re-wired in-process | `docs-claim-trusted` (vendor docs only, nothing installed; a rejection needs no impl read) | — |
| OpenAI Agents SDK | agent framework (external, library) | HIMMEL-4702; vendor docs read 2026-10-13 at `https://openai.github.io/openai-agents-python/` and `.../tracing/` | rejected | (handoffs + guardrails + tracing library) — rejected 2026-10-13: tracing is on by default and "exports them to the OpenAI backend" (off with `OPENAI_AGENTS_DISABLE_TRACING=1`), so the default violates no-prompt-egress; its guardrails run inside the SDK's loop, not at the Claude Code PreToolUse chokepoint; non-OpenAI models go through LiteLLM/Any-LLM adapters on an API key, off the subscription bank. Handoffs are what `SendMessage` plus the console/leg chain already do, with the RETASK token check. Re-open trigger: none foreseeable | `source-read-mandatory` (default egress of traces, credential path) | — |
| LangGraph | agent framework (external, library) | HIMMEL-4702; vendor docs read 2026-10-13 at `https://docs.langchain.com/oss/python/langgraph/overview` | rejected (for production); HIMMEL-4481 stays a portfolio demo | (stateful graph runtime) — rejected 2026-10-13 for the himmel loop. Durable execution, persistence and human-in-the-loop are real, and it runs standalone without LangSmith, but each is already carried by structure himmel owns: the handover doc is the checkpoint, `READY` then `GO` is the human-in-the-loop interrupt, and `merge-on-green.sh` is the gate. A graph of model calls needs API keys (bank) and has no PreToolUse chokepoint. HIMMEL-4481 (one review stage as a graph, stubbed model, N>=10 PR diffs) has no merit beyond the portfolio: it compares against the production panel with no ground truth, so it yields no recall number; the seeded-bug review-panel eval does. Keep it isolated and optional | `docs-claim-trusted` (vendor docs only, nothing installed) | — |
| LangSmith | trace + eval store (external) | HIMMEL-4702; vendor docs read 2026-10-13 at `https://docs.langchain.com/langsmith/self-hosted` | rejected (single workstation) | (trace + eval SaaS) — rejected 2026-10-13: self-hosting is "an add-on to the Enterprise plan" needing a license key and ClickHouse + PostgreSQL + Redis/Valkey (+ blob storage), the same footprint that rejected Langfuse, and the hosted tier sends prompts off the machine, which the egress matrix forbids. It is also LangChain-ecosystem-shaped; himmel's runs are Claude Code sessions, whose native OTel export the Phoenix pilot (HIMMEL-4484) targets. Re-open trigger: a multi-user deployment that already holds an Enterprise licence | `source-read-mandatory` (holds prompts, network egress) | — |
| Braintrust | eval + trace platform (external) | HIMMEL-4702; vendor docs read 2026-10-13 at `https://www.braintrust.dev/docs/guides/self-hosting` | rejected (single workstation) | (eval + observability SaaS) — rejected 2026-10-13: "Self-hosting is only available on the Enterprise plan"; the data plane is the customer's (API, PostgreSQL, Redis, object storage, Brainstore on high-IOPS NVMe) and the control plane stays Braintrust-hosted, so a workstation runs five components and still depends on an external plane. The hosted tier egresses prompts. Its experiment-compare value is already served by `eval-compare` over the eval-runs ledger. The docs read name no OSS licence for the platform; that was not verified. Re-open trigger: as LangSmith | `source-read-mandatory` (holds prompts, network egress) | — |
| OpenTelemetry GenAI semantic conventions | trace/metric format (external spec, not a vendor) | HIMMEL-4702; read 2026-10-13 at `https://github.com/open-telemetry/semantic-conventions-genai` (`docs/gen-ai/README.md`: stability "Development") | rejected (DEFER) | (`gen_ai.*` attribute names for spans, metrics, events, agent spans) — deferred 2026-10-13 as an emission target for himmel's ledgers: the spec's own stability is "Development", so attribute names can still change; the eval-runs ledger carries its own versioned v1 envelope and feeds the Prometheus exporter through `ledgers.json`; the AG-UI journal mapping targets the AG-UI event protocol, not OTel. Re-mapping three stable ledgers onto an unstable spec buys no reader that exists today. The useful OTel source is Claude Code's own export, which the HIMMEL-4484 pilot routes to Phoenix; use that as emitted. Re-audit trigger: the conventions leave Development AND the HIMMEL-4484 pilot needs `gen_ai.*` attributes on a Claude Code span that its own export lacks | `docs-claim-trusted` (public spec, nothing installed) | — |
| NVIDIA garak / NeMo Guardrails | LLM security scanner / runtime rails (external) | HIMMEL-703 audit, 2026-10-15; no install, no fresh vendor read | rejected (DEFER) | (scan for crawler-pulled content) — rejected 2026-10-15 for the follow-list crawler. garak probes a MODEL for vulnerabilities (injection, jailbreak, leak probes); it does not scan a piece of untrusted text, so it answers a different question than the crawler has. NeMo Guardrails wraps a model call in runtime rails and brings its own LLM-in-the-loop runtime, which the crawler does not have. The input side is already covered by `screenDossier` (`follow-screen.mjs`, fail-closed, ran before `verifyWebClaims` in `processHandle`) and `trimForJudge` redaction of bio, descriptions, tweets and claims (PR 233). Re-open trigger: the crawler gains an LLM-backed step whose model choice is in question (then garak against that model), or a source-read shows a text-scanning mode | `docs-claim-trusted` (nothing installed; claims from general knowledge, so a re-open starts with a source read) | — |
| mattpocock/skills `domain-modeling` (glossary skill) | C (setup / scaffolding, external skill) | HIMMEL-5498; `https://github.com/mattpocock/skills` pinned `49dd158d1076134a641b33efb035946536778336`, MIT, `skills/engineering/domain-modeling/{SKILL.md,GLOSSARY-FORMAT.md}`; `grill-with-docs` is a 2-line wrapper that calls `grilling` + `domain-modeling` | in-use (ADOPT verdict 2026-10-15; vendoring and plugin-profile registration are a follow-up, nothing is installed yet) | Terms a PR coins land in `docs/glossary.md` once, under the plain name, with the repo name as the alias, instead of drifting. **Pass bar, fixed before the arms run** (task: add the terms coined by merged PR #2669 / HIMMEL-5696 to a scratch copy of `docs/glossary.md`; arm A = glossary + PR text only, arm B = same plus the skill's `SKILL.md` and `GLOSSARY-FORMAT.md` text; n=1 per arm, so it can show "no clear win" or a regression, never an effect size). Score each arm 0/1 on six checks: C1 one definition per coined term (exactly one headword row each, no restatement elsewhere in the diff); C2 alias rule (plain name is the headword, repo identifier in code spans or the Avoid column, no old name as a headword); C3 no duplicate of an existing term (`Ready-check` is extended or linked, not redefined); C4 smallest diff (at most 12 added lines, no new file or section); C5 format fidelity (added rows keep the target section's table column count and order); C6 no implementation detail beyond what the neighbouring rows carry. Verdict rule: ADOPT only if arm B beats arm A on at least one check, loses on none, and the skill's listing costs under 100 tokens; REJECT if arm B loses on any check or only wins by overriding the glossary's own format; otherwise PILOT-MEASURE. **Result (2026-10-15, sonnet, n=1 per arm):** both arms passed C1-C5 (arm A: 1 glossary row + 1 overlap-map row; arm B: 1 glossary row + a one-word `Ready-check` extension); C6 arm A 0 (its row carries the `WIRING` list and the sourced-library rule), arm B 1 (it dropped the allowlist and per-kind rules, citing the skill's "glossary only, no implementation detail" rule). Arm B beats A on one check, loses none; listing is the `domain-modeling` description, about 40 tokens (`grill-with-docs` is `disable-model-invocation`, 0). The skill's `GLOSSARY.md` bullet format did not override the glossary's own table format. Caveats: the win is one judgement-scored check at n=1, and arm A's overlap-map row is coverage arm B skipped. Overlap: `lean-skills:grilling` is the same upstream `grilling` skill that `grill-with-docs` calls; `minerva` has no glossary step; the new part is only `domain-modeling`. Injection grep over the four files at the pin: no hits. Follow-up (not done here): vendor `domain-modeling` pinned (precedent: `writing-for-agents`, HIMMEL-5631), register it in one plugin profile, and point its target at `docs/glossary.md` instead of `GLOSSARY.md` | `community-active → validate-before-adopt` (markdown-only skill, no hooks, no scripts, no network; injection scan of the four files read at the pin) | — |

## Re-audit ledger

One row per re-audited verdict ([rubric §5](rubric.md#5-per-sprint-re-audit)).
Each sprint's re-audit item re-checks every row whose **Measured on** model
has since changed, plus up to 2 new candidates; it updates the row in place
and links the new evidence file.

| Tool | Verdict | Measured on | Date | Upstream alive | Scanner (`skills_guard`) | Tokens (fixed task set) | Quality for legs / review panel | Re-open trigger | Evidence |
|------|---------|-------------|------|----------------|--------------------------|-------------------------|---------------------------------|-----------------|----------|
| caveman | KEEP-REMOVED (removed; `caveman-statusline` stays opt-in) | `claude-sonnet-5-5`, Claude Code 2.1.286; Hermes `ec5f441` | 2026-09-30 | yes (the "dead upstream" premise no longer holds) | still trips: `caveman-compress` dangerous (rewrites `CLAUDE.md`) | -10% output tokens over 3 prompts, about cost-neutral once its ~2.6k-token skill text is paid; n=1 per cell | gate lines (`FINDING:`, `READY`) intact; diff review dropped 2 of 7 findings and downgraded a Critical (n=1) | `caveman-compress` split out and the rest scans `safe`, AND a measure-during shows an outcome gain; or the measured-on model changes | state repo `specs/audit/reaudit-2026-09-sprint1.md` (caveman section) |

## Dynamic index — our own items

In-house items we like but won't necessarily ship, kept here so they're
searchable and borrowable instead of rebuilt. Status is always
`parked-idea` — these aren't community ADOPT/REJECT decisions.

| Item | What we like | Status | Source |
|------|--------------|--------|--------|
| worktree-isolation plugin | Generic marketplace extraction of our worktree-isolation pattern (`/worktree` `/clean` `/clean_garden`) so it works for any repo — extraction filed, not built | parked-idea | backlog item |
| emergence→self-improvement crystallization | Triggered pass that crystallizes emerging vault clusters into derived self-improvement candidates — design parked-documented, won't necessarily build | parked-idea | `docs/luna/emergence-crystallization.md` |
| >100KB auto-externalize + BM25 retrieval | The one genuinely good context-mode pattern (its Part-3 design): oversized tool output auto-indexes into local FTS5 instead of truncating, model retrieves sections on demand — nothing lost, nothing flooding context. If himmel ever needs this shape, extend qmd (already local BM25+vec over markdown) rather than adopt context-mode | parked-idea | context-mode eval ADR (operator's private handover repo) |
| CR context-graph for large-repo reviews | The borrowable idea behind the rejected code-review-graph: a persistent codebase graph so a reviewer reads only the files that matter, for reviews whose context exceeds a single window. himmel is not large-repo today, so it was REJECTed on the KPI. If himmel ever hits large-repo review-context limits, extend qmd (already a local BM25+vec index over the repo) rather than adopt an MCP graph runtime — same reasoning as the >100KB row above | parked-idea | CR-toolkit eval ADR comment |

## Reconciliation notes

### context-mode — CLOSED `rejected` on-merits (eval, 2026-06-12)

The reopened eval ran 2026-06-12 (overnight), same-day as the reopen and
14 days before the 2026-06-26 timebox expiry: full source read of
v1.0.162 + sandbox test feeding
the 5 noisiest himmel tool patterns through the real `pretooluse.mjs` +
live-repo size measurement. Verdict **REJECT** — full evidence in the
context-mode eval ADR (operator's private handover repo).
Headline findings: the structural/interception layer reduces NOTHING on
Glob/Grep/Read/Bash (Glob unmatched; the rest get one-shot advisory
nudges while output passes through unchanged — the "98%" is their
fixture benchmark for data *voluntarily routed* through ctx_* MCP
tools, and their own BENCHMARK.md says 96%); always-on layers add ~1KB
of routing-block/nudge overhead per session; and three interference
vectors threaten the himmel guardrail stack (PreToolUse deny
short-circuits subsequent hooks; unlocked read-modify-write of
`~/.claude/settings.json` with a changelog-documented config-deletion
regression, #415; ~500-word prompt mutation on every Agent dispatch +
silent `subagent_type` rewrite, which fights the dispatch
discipline). The reopen itself was sound — rtk's corruption did
invalidate the substitutive shortcut — but the direct eval lands at the
same status for independent reasons. The rtk Layer-B reliability gap
REMAINS OPEN and is not solved by this rejection; if in-script
discipline keeps burning sessions, file a dedicated Layer-B eval.

### [SUPERSEDED by on-merits eval above] context-mode — REOPENED to `pilot-pending` (operator override, 2026-06-12)

*Decision-trail record only — the live status is `rejected` per the
closing note above; the `pilot-pending` this note argues for lasted from
the morning reopen to the same-day eval.*

**Operator decision 2026-06-12 (audit follow-up): the context-mode eval wins.**
The `rejected` resolution below is superseded. Basis for reconsideration: the
rejection rested on rtk being the battle-tested incumbent at Layer B, but rtk
has since shown measured output corruption inside Claude Bash sessions
(top-level `git diff` rewritten to a stat summary feeding garbage to a CR
pipeline; `grep`/`cat` file-redirects garbled even under
`rtk proxy` — see auto-memory `reference_rtk_rewrites_git_diff_in_bash`).
The substitutive-with-rtk argument assumed rtk reliably serves the Layer-B
KPI; that assumption no longer holds unqualified. the context-mode eval is reopened as
the primary eval, new timebox 2026-06-26 (ADR or Won't-Do). The original
reconciliation is preserved below for the decision trail.

### [SUPERSEDED 2026-06-12] context-mode — status RESOLVED to `rejected`

The spec flagged a contradiction over status. The two tickets are NOT
duplicates: one is the *primary* context-mode eval (timeboxed to
2026-06-10, Won't-Do if no ADR by then); the other is the *token-savior*
eval — its acceptance criteria record context-mode only in passing, as one of
six "other tools rejected" ("context-mode — substitutive with rtk, less
battle-tested"). So the substitutive-with-rtk judgment already exists (in
the token-savior eval's AC); the context-mode eval is the open eval that re-opens it. The registry
must resolve to one status — resolved to **`rejected`**.

Rationale, grounded in the luna synthesis
(`30-Resources/Tech/token-optimizer-tools.md`): context-mode sits at **Layer B
(tool-output filtering), substitutive with rtk** — they compete head-to-head at
the same layer. rtk is already **in-use** at Layer B and the synthesis
explicitly prefers it ("more battle-tested than context-mode; Rust binary, zero
deps"). Adopting a second, substitutive Layer-B tool buys no new outcome — the
KPI rtk already serves — while adding tool-output-path surface and an
unreproducible 98% benchmark claim. So context-mode is **rejected** on the
substitutive-with-rtk basis already captured in the token-savior eval's AC, and
**the context-mode eval should close Won't-Do on that basis** — it is re-litigating a
settled question, which is exactly what this registry exists to prevent.

Discrepancy noted (not blocking): the registry spec text describes
context-mode as a "Layer D hook," but its grounding luna doc classifies it as
**Layer B (tool-output, substitutive with rtk)**. The registry uses Layer B per
the grounding doc, since the substitutive-with-rtk relationship — the whole
basis of the REJECT — only holds at Layer B.

### Rejected-tool rationale source

`ooples` and the `drona23 / alexgreensh / nadimtuhin` lower-leverage trio are
recorded as `rejected` per the registry spec. Their layer classifications and
substitutive/leverage relationships are grounded in the luna 8-tool synthesis
(`30-Resources/Tech/token-optimizer-tools.md`). The response-mode compression
plugin that also sat here as `rejected` (default-path question:
compression conflicts with this repo's docs-quality bar) was removed from himmel
entirely — do not re-adopt it without re-running the gate.

### Luna sources read

All four cited luna docs were readable at
`~/Documents/luna/30-Resources/Tech/`:
`token-optimizer-tools.md`, `mibayy-token-savior.md`, `nizos-tdd-guard.md`,
`mksglu-context-mode.md`. The 8-tool comparison
(`token-optimizer-tools.md`) is the primary grounding for every Layer
assignment and the context-mode reconciliation.
