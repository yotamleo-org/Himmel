# CLAUDE.md rule detail

The full text of every rule that root `CLAUDE.md` now carries condensed (HIMMEL-5512).
Root `CLAUDE.md` keeps each rule's directive and its enforcer; the prose below is
the prior wording, verbatim, kept for reference. It is not preloaded.

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
  [`docs/internals/stuck-playbook.md`](stuck-playbook.md). [enforced: security-reviewed]

### Jira — prefer plugin over MCP
Invoke by ABSOLUTE path from the primary checkout —
`node <repo-root>/scripts/jira/dist/index.js <op>` — never relative from a
worktree (`dist/` is an untracked build artifact; a worktree lacks it →
MODULE_NOT_FOUND and SILENT create failures), never the global `jira` shim.
`JIRA_PROJECT_KEY` is required. CLI-over-MCP routing is enforced by
`block-backend-tier.sh` (registry `scripts/backends.json`); ops + op↔MCP
mapping: [`docs/internals/jira-plugin.md`](jira-plugin.md).

### Claude invocation billing
Subscription-authenticated `claude -p`/`--print`/`--bg` draws the SAME 5-hour /
weekly subscription usage budget as interactive use. Unattended
sites preflight with `scripts/lib/bank-preflight.sh`, parse
`--output-format json`, and declare an
explicit `--permission-mode` (never `bypassPermissions`). Evidence, sources +
re-measure recipe:
[`docs/internals/enforcement.md`](enforcement.md#claude-invocation-billing).

### Subagent policy — delegation & escalation
**Delegate what is genuinely independent and sizeable — and only that.** Don't
delegate work you'd finish in a handful of tool calls, and never spawn a
subagent to verify your own work; both multiply cost without improving the
result. (Reviewing a diff you did not author is independent review, not
self-verification.) Brief every child fully — it inherits nothing.

**Every dispatch names an explicit model** (an unnamed one burns the scarcer parent quota); raise *effort* before tier. Tier semantics, effort and cost: `docs/internals/lane-calibration.md`; live inventory: `/lanes`.
A brief that is a specified edit list, comment or rename sweep, fixture regeneration or scoped extraction, ending in a named machine check (gate script, test, schema validator), names haiku at medium effort, not sonnet.

**Escalation over top-down:** an Opus parent spawns a Fable child for the one
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
[`docs/internals/context-architecture.md`](context-architecture.md).

### Honesty markers — `ponytail:`
`ponytail: <ceiling>, <upgrade path>` marks a known, deliberate simplification
(limitation AND the ticket or trigger to revisit it) →
[`docs/internals/ponytail-convention.md`](ponytail-convention.md).
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
`graphify explain` / `graphify path`) — only code files, `name()` symbols, glossary terms and `/command`/plugin/skill/hook names
merge across files; other same-name concepts, and code symbols defined in 2+ files, stay separate (pick one with `path::symbol`).
An hourly or incremental refresh can leave a merge stale (HIMMEL-6285), so confirm a `graphify path` miss with grep.
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
[`docs/internals/handover-system.md`](handover-system.md).

## ENFORCEMENT (runs automatically)

Enforced by PreToolUse/PostToolUse hooks plus **pre-commit/commit-msg/pre-push gates**. The live inventory is
`.claude/settings.json` and `.pre-commit-config.yaml` — read those, not a list
here (an enumeration drifts silently); the Codex lane re-wires the
same guardrails in `.codex/hooks.json`. Per-hook behaviour + guardrail matrix:
[`docs/internals/enforcement.md`](enforcement.md).

**Session-critical (kept inline — needed at a glance):** hook off switch = a session
env var set in the LAUNCHING shell (e.g. `EDIT_ON_MAIN_OK=1 claude`); a per-call
prefix does NOT work. Per-repo opt-out: a local gitignored `.single-writer` at a
repo root allows on-main edits there (single-writer repos — personal vaults,
state repos — that commit straight to main by design); clones without the marker
stay protected. Required environment:
[`docs/setup/new-machine.md`](../setup/new-machine.md#1-required-environment).

When a guardrail stops you — a denial, a permission prompt, a silent no-op at
rc=0, a failed attestation gate, a refused worktree — the recovery lives in
`himmel-ops:stuck-playbook` /
[`docs/internals/stuck-playbook.md`](stuck-playbook.md), which
also carries the Bash command shapes the native permission matcher refuses.

## REFERENCE INDEX

Docs not already linked from a rule above (relative to `docs/`):

| File | Covers |
|---|---|
| `internals/harness-compat.md` | himmel under Codex / other harnesses |
| `internals/testing.md` | non-guessable test invocations (`bash scripts/ci/run-shell-tests.sh`, lanes, bun) |
| `handover/afk-mode.md` | autonomous end-to-end execution of a well-scoped ticket |
| `glossary.md` | the one definition site: chief, judge, relay, worker, dependency chain, parallel wave, arming, manual override |
| `handover/running-a-console.md` | starting + handing over a console (`/console new\|next`), vs `/afk-shift` <!-- old-term-ok: console is renamed in slice V5 --> |
| `internals/prompt-cache.md` | the verified prompt-cache model, audit of every cache claim, the `scripts/eval/cache-probe.sh` re-run |
| `internals/headless-modes.md` | `claude -p` vs `claude --bg` vs headed — which fits which job, env/permission/confirm details |
