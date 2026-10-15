# memory-compound — propagation review + shape triage (step 3)

Moved verbatim out of `SKILL.md`.

**The propagation review is mandatory, per item, BEFORE writing.** Auto-memory
and the luna vault never reach another himmel user; anything true for other
users must land in the repo or it is lost to them. Defaulting everything to
luna is the documented failure mode — the 2026-07-11 pass did exactly that and
needed a follow-up PR (HIMMEL-900). Classify each durable item:

- **Operator-specific / vault-shaped** (this operator's machines, lane
  inventory, personal vaults, quota habits, personal workflow) → the luna
  vault under `30-Resources/Tech/` (or the theme note already used by the
  memory index's luna pointers — many entries already name a `[[luna note]]`).
  Resolve the luna vault from `$LUNA_VAULT_PATH` (configured via
  `/end-session-wiki-setup`), falling back to the operator's known luna path;
  **confirm the directory exists before writing** and never hardcode a home
  dir — a wrong/unset path would scatter the synthesized notes outside the
  vault and silently fail the qmd gate.
- **Adopter-generic** (true for anyone running himmel — OS/shell/tool traps,
  git behaviours, Claude Code quirks, dev-workflow conventions worth
  standardizing) → **himmel docs, via the normal worktree → PR flow** (himmel
  is PR-gated; the vault is not). Route by content: environment/OS/tool traps
  → `docs/internals/environment-gotchas.md`; operator working-habits →
  `docs/operator-conventions.md`; other-harness compat →
  `docs/internals/harness-compat.md`; hook/gate lore →
  `docs/internals/enforcement.md`. Batch all of the pass's doc landings into
  ONE docs PR at the end. A luna copy is optional; the himmel doc is the
  system of record for these.
  **When in doubt, land in himmel docs** (operator directive 2026-07-14):
  luna is not shared, so an adopter-relevant item that lands only in luna is
  silently dropped for every other user. Gotchas about himmel-SHIPPED tooling
  (`/luna-upgrade`, `propagate-public.sh`, `/pr-check` profiles, dispatch
  chokepoints, …) are adopter-relevant even when discovered on the operator's
  own vault — land them in the repo (`docs/` or the owning plugin's README).
- **Rule / restriction candidates.** An adopter-generic item that is
  frame-shaping or safety-critical deserves more than a doc: run it through
  the HIMMEL-177 layer test (default-hook / default-rule / lean-invoke /
  defer) and FILE A TICKET for the promotion (CLAUDE.md line, PreToolUse
  hook, pre-commit gate) — doc it now, ticket the escalation. (HIMMEL-195:
  prose that already drifted escalates to structural, not to more prose.)

Match each note's existing voice and structure. One writer, many readers.

**Triage by SHAPE before landing (D9, HIMMEL-570).** Orthogonal to the
propagation class above — decide *where recall happens*:

- **Fact-shaped** — looked up on a symptom ("rtk masks gitleaks blocks"). →
  evict to its theme topic file; the `MEMORY.md` line becomes a routing line
  (step 5).
- **Directive-shaped** — must fire *unprompted*; the model never queries for a
  rule it does not know it is breaking ("NEVER merge with open CR comments"). →
  **keep it resident** as a ≤200-char `MEMORY.md` line, **or** file a HIMMEL-195
  escalation for a structural hook. A directive behind a qmd query is dead.
- **Invocation-shaped** — fires only inside a named flow (a `/pr-check` gotcha, a
  codex-dispatch trap, a jira-CLI quirk). → land it in the **existing skill /
  command / script that owns that flow** (adopter-generic → the repo-tracked
  skill body, gated by the propagation review above; operator-private → a
  user-scope skill or a resident line). Do **not** mint a per-theme memory skill
  (rejected — ~516B/skill of always-loaded catalog re-creates the index-bloat
  problem in a worse surface).
