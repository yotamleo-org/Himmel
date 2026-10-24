# himmel — Project Rules

## WHY

himmel is a harness for running Claude Code as a managed agent, made
*structurally* safe rather than relying on Claude to remember prose.
Positioning → `README.md`; reference detail → `docs/internals/`.

## RULES

### Git workflow
- Feature work in git worktrees; never edit or commit on main. [enforced: block-edit-on-main]
- All changes via PR, ≥1 approval, no direct push. [enforced: no-push-to-main]
- Conventional commits; **every commit and every PR carries a ticket ID**
  (search Jira and extend an existing ticket before re-filing). [enforced: conventional-commit-msg]
- Attestation trailers (`Platforms tested: <os>`, `Security reviewed: <token>`)
  go in the **FIRST commit**; never `git commit --amend`. Recovery:
  `docs/internals/stuck-playbook.md`. [enforced: security-reviewed]

### Jira — prefer plugin over MCP
Never reach for the Atlassian MCP first. Invoke by ABSOLUTE path from the
primary checkout — `node <repo-root>/scripts/jira/dist/index.js <op>` — never
relative from a worktree (`dist/` is an untracked build artifact; a worktree
lacks it → MODULE_NOT_FOUND), never the global `jira` shim.
`JIRA_PROJECT_KEY` is required. CLI-over-MCP routing is enforced by
`block-backend-tier.sh`; ops + op↔MCP mapping: `docs/internals/jira-plugin.md`.

### Claude invocation billing
Subscription-authenticated `claude -p`/`--print`/`--bg` draws the SAME 5-hour /
weekly budget as interactive use. Unattended sites preflight with
`scripts/lib/bank-preflight.sh`, parse `--output-format json`, and declare an
explicit `--permission-mode` (never `bypassPermissions`).
Detail: `docs/internals/enforcement.md#claude-invocation-billing`.

### Subagent policy
Delegate only what is independent and sizeable; never spawn a subagent to verify
your own work (reviewing a diff you did not author is independent review). Brief
every child fully — it inherits nothing. **Every dispatch
names an explicit model**; raise *effort* before tier. A specified edit list
ending in a machine check names haiku at medium effort. Inline implementation
on a top-tier parent is the anti-pattern. [enforced: orchestrator-inline-guard]
Escalate, not top-down: an Opus parent spawns a Fable child for the one hard
call; work above your tier is returned.

Invariants: spawn depth and concurrency are capped by
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` / `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`;
haiku does NOT spawn; single-writer (many readers, ONE writer); salus dev/impl
work routes to Claude tiers + Codex lanes only (never GLM), while salus PHI
egress is governed by `scripts/guardrails/egress-matrix.json`. Every dispatch
carries a RETASK block with a fresh nonce; a revision arrives only as a direct
message quoting it (a narrowing or halt needs no token), never widens
permissions. Tiers, cost, live inventory:
`docs/internals/lane-calibration.md`, `/lanes`, `docs/internals/retask-channel.md`.

### Adding a rule — pick the cheapest layer
Default to lean-invoke (a slash command). Escalate to always-on only for
safety-critical (hook/gate) or frame-shaping (this file). **Structural >
instructional**: on the second drift escalate to a hook or gate, never stronger
prose. `docs/internals/context-architecture.md`.

### Honesty markers and artifacts
- `ponytail: <ceiling>, <upgrade path>` marks a deliberate simplification →
  `docs/internals/ponytail-convention.md`. [prose]
- Other code comments: keep list only, no ticket/review history. [enforced: no-history-comments]
- Operator reference docs → the owning repo's `docs/`; internal specs, plans
  and decision records → the state repo bucket `specs/<type>/`, never himmel
  `docs/`; vault content stays in luna. [prose]

### Retrieval routing
`MEMORY.md` routes, it does not store: on a surprising symptom read the theme
file its keyword names. qmd finds content (scope with `-c <name>`; a miss is
not proof of absence). graphify explains structure (`graphify query|explain|path`).
Extraction runs on scratchpad copies, never live vaults. A live URL → `WebFetch`
directly.

## WORKFLOWS

**Compact instructions:** carry ship state forward verbatim — ticket ID, branch,
worktree path, committed-vs-dirty, trailers-in-first-commit, review-owed marker
and unresolved findings, remaining ordered steps. Drop tool dumps.

**Handover:** state lives in `$HANDOVER_DIR`; use `/handover`, never edit docs;
scripts call `handover_root` (`scripts/lib/handover-path.sh`).
`docs/internals/handover-system.md`.

## ENFORCEMENT (runs automatically)

Hooks plus pre-commit/commit-msg/pre-push gates; the live inventory is
`.claude/settings.json` and `.pre-commit-config.yaml`. Hook off switch = a
session env var set in the LAUNCHING shell (e.g. `EDIT_ON_MAIN_OK=1 claude`).
Per-repo opt-out: a gitignored `.single-writer` marker. Environment:
`docs/setup/new-machine.md`. When a guardrail stops you, use
`himmel-ops:stuck-playbook` (`docs/internals/stuck-playbook.md`).

## REFERENCE INDEX

All under `docs/`: `internals/claude-md-detail.md` (full wording of every
rule condensed above), `internals/harness-compat.md`, `internals/testing.md`,
`handover/afk-mode.md`, `glossary.md`, `handover/running-a-console.md`,
`internals/prompt-cache.md`, `internals/headless-modes.md`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
