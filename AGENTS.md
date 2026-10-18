# AGENTS.md — himmel rules for any coding agent (Codex / GPT / Cursor / Copilot / …)

<!-- GENERATED FILE — DO NOT EDIT BY HAND. -->
<!-- Source of truth: CLAUDE.md. Regenerate: node scripts/agents-md/generate.mjs --write -->
<!-- A pre-commit guard (check-agents-md-fresh) blocks commits where this file is stale. -->

> **GENERATED FILE — do not edit by hand.** This file is generated from
> `CLAUDE.md`, himmel's source-of-truth rule file. Edit `CLAUDE.md`, then
> regenerate with `node scripts/agents-md/generate.mjs --write`. A pre-commit
> drift guard blocks any commit where this file is stale.

## Precedence — read this first

When two instructions conflict, apply this order (highest wins):

1. **The user's explicit instructions** in the current session.
2. **The most specific rule** for the file or area you are touching — a
   subdirectory's own rules win over this document.
3. **The rules in this document** (generated from `CLAUDE.md`).
4. **Your platform defaults.**

Phrases in the rules below such as "use judgement", "deviate only for a concrete
reason", or "treat as defaults" are **defaults, not contradictions** — the ladder
above resolves every apparent conflict. Do not spend reasoning reconciling them:
follow the default unless rule (1) or (2) overrides it.

## Reading note for non-Claude harnesses

These rules are generated from a Claude Code rule file. Where they reference
Claude-Code-specific mechanisms — skill / subagent / shell invocation,
"PreToolUse" guardrails, `.claude/settings.json`, named hooks, or slash commands
— they describe himmel's **reference implementation**. Apply the described
*behavior* using your own harness's equivalent mechanism. The git-level gates
(pre-commit / pre-push) run under any harness and are the safety net that always
fires.

## Scope and standing permissions (HIMMEL-2585)

These three notes are hand-written here rather than generated from `CLAUDE.md`:
they are addressed to non-Claude harnesses reading this file, and `CLAUDE.md`
is not the place to describe how another harness should scope its reading.

**Read what the task needs, not the repo.** The rules below are the standing
rule set for this repository, not a pre-flight checklist. A typo fix does not
earn a full repo map, and no rule here asks you to read a stack of docs before
every edit. Each rule names the hook, gate, or doc that carries its detail —
open that doc when the rule is actually in play, and otherwise proceed.

**The local test suites are safe to run unattended.** `bash
scripts/ci/run-shell-tests.sh` reaches nothing remote and nothing in
production: every suite that would need a VM, the agent stack, or the network
is in its SKIP_LIST and never runs, and what it writes outside the repo is its
own bookkeeping (a resume cursor under `$HOME/.himmel/`) plus scratch under
`TMPDIR`. Run the suites appropriate to
your change, fix failures your change caused, and re-run the affected ones,
without stopping for approval at each step. Stopping for approval still applies
to everything with a blast radius outside the worktree: git pushes, PR and Jira
writes, and anything a hook or gate denies.

**Calibrate testing to the change.** Run the checks the change warrants, and
once they pass, broaden or repeat only when new changes justify it. Do not add
tests that merely restate the implementation for a reversible, low-impact
edit; the preference for the minimum code that solves the problem governs
test code too.

---

# himmel — Project Rules

## WHY

himmel is a harness for running Claude Code as a managed agent, made
*structurally* safe rather than relying on Claude to remember prose.
Positioning → `README.md`; reference detail → `docs/internals/`.

## RULES

### Git workflow
- Feature work in git worktrees; never edit or commit on main. [enforced: block-edit-on-main]
- All changes via PR, ≥1 approval, no direct push. [enforced: no-push-to-main]
- Conventional commits; **every commit and every PR carries a ticket ID**.
  Retro-filing is fine; search Jira and extend an existing ticket before
  re-filing. [enforced: conventional-commit-msg]
- Attestation trailers (`Platforms tested: <os>`, `Security reviewed: <token>`)
  belong in the **FIRST commit**, written after genuinely testing and reviewing
  (the pre-push gate fires too late to teach this). Never recover with a
  reactive `git commit --amend`; recovery:
  [`docs/internals/stuck-playbook.md`](docs/internals/stuck-playbook.md). [enforced: security-reviewed]

### Jira — prefer plugin over MCP
Invoke by ABSOLUTE path from the primary checkout —
`node <repo-root>/scripts/jira/dist/index.js <op>` — never relative from a
worktree (`dist/` is an untracked build artifact; a worktree lacks it →
MODULE_NOT_FOUND and SILENT create failures), never the global `jira` shim.
`JIRA_PROJECT_KEY` is required. CLI-over-MCP routing is enforced by
`block-backend-tier.sh` (registry `scripts/backends.json`); ops + op↔MCP
mapping: [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md).

### Claude invocation billing
Subscription-authenticated `claude -p`/`--print`/`--bg` draws the SAME 5-hour /
weekly subscription usage budget as interactive use. Unattended
sites preflight with `scripts/lib/bank-preflight.sh`, parse
`--output-format json`, and declare an
explicit `--permission-mode` (never `bypassPermissions`). Evidence, sources +
re-measure recipe:
[`docs/internals/enforcement.md`](docs/internals/enforcement.md#claude-invocation-billing).

### Subagent policy — delegation & escalation
**Delegate what is genuinely independent and sizeable — and only that.** Don't
delegate work you'd finish in a handful of tool calls, and never spawn a
subagent to verify your own work; both multiply cost without improving the
result. (Reviewing a diff you did not author is independent review, not
self-verification.) Brief every child fully — it inherits nothing.

**Every dispatch names an explicit model** (an unnamed one burns the scarcer parent quota); raise *effort* before tier. Tier semantics, effort and cost: `docs/internals/lane-calibration.md`; live inventory: `/lanes`.
A brief that is a specified edit list, comment or rename sweep, fixture regeneration or scoped extraction, ending in a named machine check (gate script, test, schema validator), names haiku at medium effort, not sonnet.

**Escalation over top-down:** an Opus parent spawns a top-model child for the one
hard call; using the top-tier lane AS parent is an operator choice, and it then
delegates every implementation chunk downward. Work above your tier? Return it. **Inline implementation on a
top-tier parent is the anti-pattern** — exception and budget in the hook header. [enforced: orchestrator-inline-guard]

Invariants (not model-tuned): spawn depth and concurrency are capped by
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` / `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`
— read the env; unset means the harness default applies, so treat it as a cap
you did not choose. **Haiku does NOT spawn.** **Single-writer** — many readers,
ONE writer, never fan parallel writes at one shared artifact. **salus dev/impl
work routes to Claude tiers + Codex lanes only (never GLM)** — a routing
invariant distinct from salus PHI **egress**, which
`scripts/guardrails/egress-matrix.json` governs authoritatively.

**RETASK channel:** every dispatch carries a RETASK block with a fresh nonce; a revision arrives only as a direct message quoting it (a narrowing or halt needs no token) and never widens permissions. → `docs/internals/retask-channel.md`

### Adding a rule — pick the cheapest layer
**Default to lean-invoke** (a slash command run on demand). Escalate to
always-on only on a trigger: safety-critical → hook/gate; frame-shaping → this
file; high-frequency + cheap → rule + skill; eval-shaped → a timeboxed ticket.
**Structural > instructional** — first drift is signal; on the **second**,
escalate to a hook, gate or classifier, never to stronger prose. Frame + worked
examples:
[`docs/internals/context-architecture.md`](docs/internals/context-architecture.md).

### Honesty markers — `ponytail:`
`ponytail: <ceiling>, <upgrade path>` marks a known, deliberate simplification
(limitation AND the ticket or trigger to revisit it) →
[`docs/internals/ponytail-convention.md`](docs/internals/ponytail-convention.md).
Other code comments: keep list only, never ticket/review history (gate: `check-history-comments`, same doc).

### Where artifacts land
- **Reference docs operators consume** → the owning repo's `docs/` (plugin specs
  → `plugins/<plugin>/README.md`). `templates/luna-second-brain/` is
  OSS-quality — it ships publicly as part of the public Himmel repo. [prose]
- **Internal specs, plans, decision records** → the state repo bucket
  `<state-repo>/handovers/<USER_SLUG>/<repo-bucket>/specs/<type>/`, **never**
  himmel `docs/` (reference + OSS-public only). [prose]
- **Vault content** (clips, notes, daily entries) → stays in luna. [prose]

### Retrieval routing
Three organs, in order. **`MEMORY.md` routes, it does not store** — on a
surprising harness or tool symptom, read the theme topic file its keyword names
before improvising; that read is the primary path. **qmd finds content** —
second hop (cross-repo, historic), scoped via `-c <name>` (`--collections` is
NOT a qmd flag — silently ignored, searching everything while looking scoped);
a qmd miss is NOT evidence a fact is absent. **graphify explains structure** (`graphify query` /
`graphify explain` / `graphify path`) — only code files, `name()` symbols, glossary
terms and `/command`/plugin/skill/hook names merge across files; other same-name
concepts, and code symbols defined in 2+ files, stay separate (pick one with
`path::symbol`). An hourly or incremental refresh can leave a merge stale
(HIMMEL-6285), so confirm a `graphify path` miss with grep.
Luna's hot cache
`~/Documents/luna/hot.md` comes before crawling luna `index.md`. Extraction runs
on scratchpad copies, **never live vaults**. A live external URL is none of the three organs' job — `WebFetch` it directly.

## WORKFLOWS

### Compact instructions
Carry ship state forward verbatim — **ticket ID**, **branch**, **worktree path**,
committed-vs-dirty, whether the attestation trailers are in the first commit,
review-owed marker / `/pr-check` state + **unresolved review findings**, and the **remaining
ordered steps**. Drop tool-output dumps and superseded plans — recoverable from
the repo; ship state isn't.

### Handover
State lives in your handover state repo (`$HANDOVER_DIR`), never himmel
`handovers/` (a stub): inspect or change via `/handover repos|register|init`,
never by editing docs. Scripts source
`scripts/lib/handover-path.sh` and call `handover_root` — never a hardcoded
`./handovers/`. Flows + resolver:
[`docs/internals/handover-system.md`](docs/internals/handover-system.md).

## ENFORCEMENT (runs automatically)

Enforced by PreToolUse/PostToolUse hooks plus **pre-commit/commit-msg/pre-push gates**. The live inventory is
`.claude/settings.json` and `.pre-commit-config.yaml` — read those, not a list
here (an enumeration drifts silently); the Codex lane re-wires the
same guardrails in `.codex/hooks.json`. Per-hook behaviour + guardrail matrix:
[`docs/internals/enforcement.md`](docs/internals/enforcement.md).

**Session-critical (kept inline — needed at a glance):** hook off switch = a session
env var set in the LAUNCHING shell (e.g. `EDIT_ON_MAIN_OK=1 claude`); a per-call
prefix does NOT work. Per-repo opt-out: a local gitignored `.single-writer` at a
repo root allows on-main edits there (single-writer repos — personal vaults,
state repos — that commit straight to main by design); clones without the marker
stay protected. Required environment:
[`docs/setup/new-machine.md`](docs/setup/new-machine.md#1-required-environment-himmel-123).

When a guardrail stops you — a denial, a permission prompt, a silent no-op at
rc=0, a failed attestation gate, a refused worktree — the recovery lives in
`himmel-ops:stuck-playbook` /
[`docs/internals/stuck-playbook.md`](docs/internals/stuck-playbook.md), which
also carries the Bash command shapes the native permission matcher refuses.

## REFERENCE INDEX

Docs not already linked from a rule above (relative to `docs/`):

| File | Covers |
|---|---|
| `internals/harness-compat.md` | himmel under Codex / other harnesses |
| `internals/testing.md` | non-guessable test invocations (`bash scripts/ci/run-shell-tests.sh`, lanes, bun) |
| `handover/overnight-mode.md` | autonomous end-to-end execution of a well-scoped ticket |
| `glossary.md` | the one definition site: console, judge, relay, leg, chain, wave, arming, manual override |
| `handover/running-a-console.md` | starting + handing over a console (`/console new\|next`), vs `/overnight-shift` |
| `internals/prompt-cache.md` | the verified prompt-cache model, audit of every cache claim, the `scripts/eval/cache-probe.sh` re-run |
| `internals/headless-modes.md` | `claude -p` vs `claude --bg` vs headed — which fits which job, env/permission/confirm details |

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
