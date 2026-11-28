# Claude Operating Manual — Vault Skeleton

> Read this file before doing anything in this vault.
> This is the single source of truth for how Claude operates here.

This file is the **luna-brain skeleton version**. When a vault is
instantiated from this repo, the operator should edit this file in
place to fill the `{{PLACEHOLDER}}` fields below and tune sections to
match their workflow.

## Section 0 — AI-First Vault Rule (read first, applies to every note)

This vault is designed for **future-Claude** to read and reason over, not
for human review. The owner rarely reads notes directly — they call
Claude to retrieve, synthesize, and connect dots across accumulated
knowledge.

**Every note Claude writes to this vault must follow these rules:**

1. **Self-contained context** — Each note must explain itself.
   Future-Claude may pull this single note via search with no
   surrounding context.
2. **"For future Claude" preamble** — Every note begins with a 2–3
   sentence summary so Claude can decide relevance in 10 seconds.
3. **Rich, consistent frontmatter** — `type`, `date`, `tags`,
   `ai-first: true`, plus type-specific fields.
4. **Recency markers per claim** — Attach dates to external facts:
   "X raised $24M (as of 2026-04)".
5. **Sources preserved verbatim** — Every external claim has its source
   URL inline.
6. **Cross-links are mandatory** — Every person, project, idea,
   decision, or concept uses `[[wikilinks]]`.
7. **Confidence levels** — Mark claims as
   `stated | high | medium | speculation`.
8. **Preserve the graph** — never break a `[[wikilink]]`. When you move
   or rename a note, rewrite every inbound link so none dangle (a
   relocation skill like `/archive-clips` does this on move; a manual
   move must do the same by hand). Ask before any restructuring that
   relinks many notes at once.

## Retrieval Routing — which organ answers what

- **Content lookup** ("find my notes on X", "what did I save about Y") →
  text/semantic search (qmd or your search tool) first.
- **Structure & neighborhoods** ("how does X relate to Y", "what clusters
  around Z") → the graphify graph, but only when it is on and fresh. It is
  **off by default**; how to turn it on, where it lives and how to query it:
  [`docs/retrieval-routing.md`](docs/retrieval-routing.md). Otherwise use qmd only.
- A **search miss is not evidence of absence** — structural connections
  often live only in the graph; when the graph is on and fresh, try graphify
  before concluding a relation doesn't exist.

## Tooling and provenance

- **Access paths in use:** read the vault with grep, qmd and the graphify
  CLI (see Retrieval Routing above); write notes as plain files. No vault
  MCP server or claude-obsidian skill is loaded in a default session, so do
  not assume one is there. obsidian-second-brain is no longer part of himmel.
- **Session capture:** a himmel `SessionEnd` hook writes eligible session
  notes under `sessions/YYYY/MM/` in the target vault. Opt out by setting
  `CLAUDE_END_SESSION_WIKI=0`, or `"enabled": false` in
  `.claude/end-session-wiki.json`. Targeting, schema and every option:
  `docs/luna/end-session-wiki.md` in the himmel repo.
- **Where the structure came from:** a custom PARA tree, the
  obsidian-second-brain manual pattern, and the claude-obsidian hot cache
  (`hot.md`).

## Vault Identity

- **Owner:** {{OWNER_NAME}}
- **Vault name:** {{VAULT_NAME}}
- **Primary purpose:** {{VAULT_PURPOSE}}
- **Instantiated from:** [luna-brain](https://github.com/yotamleo/Himmel/tree/main/templates/luna-second-brain) skeleton <!-- leak-allow: hostname template doc pointing at the public skeleton repo -->
- **Created:** {{CREATED_DATE}}

## Folder Map

| Folder | Purpose |
|--------|---------|
| `00-Inbox/` | Capture everything first. Process weekly — triage to other folders |
| `10-Projects/` | Active work with a clear outcome and deadline |
| `20-Areas/Life/` | Ongoing responsibilities: health, finance, relationships, home, goals |
| `20-Areas/Work/` | Career, skills, side projects |
| `30-Resources/Tech/` | Tools, languages, frameworks, systems reference |
| `30-Resources/Concepts/` | Mental models, ideas, frameworks |
| `30-Resources/Books/` | Reading tracker with ratings and notes |
| `40-Archive/` | Completed projects, inactive areas, outdated resources |
| `50-Journal/Daily/` | Daily notes — format: `YYYY-MM-DD.md` |
| `50-Journal/Weekly/` | Weekly reviews — format: `YYYY-WW.md` |
| `60-Maps/` | Maps of Content (MOCs) — high-level indexes and topic clusters |
| `_Templates/` | Note templates — never modify during normal vault ops |

## Key Files

- **Dashboard / Home:** `[[60-Maps/Home]]` — vault entry point, all navigation
- **Vault index:** `[[index]]` — catalog of all notes; add a line when you create a note
- **Activity log:** `[[log]]` — chronological log of all vault changes

## Active Context

> Update this section at the start of each major project or focus period.

**Current top priority:** [update me]
**Active projects:** See `[[10-Projects/_index]]`

## Auto-Save Rules

Claude should auto-save the following **without asking**:
- Decisions made in conversation → relevant project note + today's daily note
- New people mentioned → create person stub in `20-Areas/`
- Tasks assigned or committed to → `10-Projects/` relevant note
- Knowledge learned → `30-Resources/` appropriate subfolder
- Dev/work sessions → today's daily note + project note
- A substantial Claude output worth reusing (research brief, synthesis,
  strategy doc) → save it as a file, don't leave it in chat. Route per
  the Folder Map (synthesis/concept → `30-Resources/`; cross-topic map →
  `60-Maps/`).

Claude should **ask before saving**:
- Anything touching finances or private personal data
- Anything that involves deleting or archiving an existing note

## Contradiction-Resolution Policy

Resolving contradicting notes is **propose-only** — never auto-merge. They may cover different
contexts or phases; auto-merging destroys the reasoning that made each right at the time.

- **Clear winner found:** do NOT rewrite the outdated page. Write the proposed rewrite to
  `00-Inbox/Conflict (proposed) — <topic>.md` (`status: proposed`) with both sides, the evidence,
  and the full proposed text. The operator applies or rejects.
- **Genuinely ambiguous:** write `00-Inbox/Conflict (open) — <topic>.md` (`status: open`).
- Conflict notes carry the base frontmatter (`type: conflict`, `tags:` incl. `conflict`) plus
  `status:`. Rewrite the losing note in place only when the operator asks for it.

**Shared daily-note heading:** thinking-type passes such as `/contra` append to today's daily note
under the exact H2 heading `## Thinking` — one heading, no per-command variants.

## Naming Conventions

- Daily notes: `YYYY-MM-DD.md` in `50-Journal/Daily/`
- Weekly reviews: `YYYY-WW.md` in `50-Journal/Weekly/`
- Projects: descriptive title (e.g. `Launch Personal Site.md`)
- People: full name (e.g. `Jane Smith.md`)
- Resources: descriptive title with source context

## Frontmatter Requirements

Every note must have at minimum:
```yaml
---
date: YYYY-MM-DD
type: [note-type]
tags:
  - [category]
ai-first: true
---
```

Note types: `daily` | `weekly` | `project` | `area` | `resource` | `person` | `concept` | `book` | `decision` | `conflict`

A `type: decision` note also carries quoted `claim:` and `assumption:` fields and is made from
`[[_Templates/Decision]]`. The template catalogue and the full decision contract:
[`docs/note-templates.md`](docs/note-templates.md).

## Do Not Touch

- `_Templates/` — Never modify templates during normal vault ops
- `.pre-commit-config.yaml` + `scripts/` — repo infrastructure; treat
  edits the same as code changes (PR review, conventional commit).

## Repo conventions (inherited from luna-brain skeleton)

- **Single-writer vaults:** a vault with a `.single-writer` marker at its root commits straight
  to `main` by design; the two bullets below do not apply to it (deleting them survives upgrades).
- **Git workflow:** all changes via PR; main is protected. Conventional
  commit format `type(scope): [TICKET-N ]message` is a convention, not
  enforced by a hook.
- **Branch isolation:** never commit on `main`; the pre-commit hook refuses a commit when
  `HEAD == main`. A branch is enough (`git switch -c feat/<slug>`); a worktree is not required.
- **Force-push blocked:** `scripts/hooks/check-no-force-push.sh` refuses
  force-push to `main`. CR follow-ups must be new commits.
- **Handover state:** `<repo>/handovers/` by default, or `$HANDOVER_DIR`
  when set in the launching shell. See `scripts/lib/handover-path.sh`.

## pre-commit trap

<!-- mem:49268e70dd6e -->
<!-- mem:99f1b1f48ac5 -->
- **Never `pre-commit install` for the pre-commit stage in this vault**
  (`scripts/setup.sh` installs only `--hook-type pre-push`). That hook
  stashes unstaged changes and, with Obsidian rewriting `.obsidian/plugins/*`
  mid-hook, rolls back OTHER sessions' unstaged work. Run
  `bash scripts/hooks/install-nostash-hooks.sh` once per clone instead.
- Recovery from a rollback, and other vault traps (commit STALLs,
  upgrade-withheld edits, clip audits, search quirks):
  [`docs/vault-troubleshooting.md`](docs/vault-troubleshooting.md).

*Generated by the luna-brain skeleton.*
