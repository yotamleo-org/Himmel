---
name: memory-compound
description: Use when the per-project auto-memory nears its ~24.4KB budget — compound durable gotchas into qmd-searchable notes.
---

# memory-compound — distil auto-memory into searchable substrate (HIMMEL-569)

Lean-invoke skill. Run it when `MEMORY.md` approaches its load budget (~24.4KB)
— the session-load size-limit warning (e.g. "MEMORY.md is NN KB (limit 24.4KB)")
is the natural cue. It encodes the HIMMEL-564 compaction as ONE pass. Do **not**
wire this as an
always-on hook — the classification (durable vs disposable), dedupe, and
placement are judgement-heavy, which is exactly why HIMMEL-177 puts it at the
lean-invoke layer.

The documented move it automates: [`docs/luna/compounding.md` §"A second loop:
auto-memory → vault"](../../../../../docs/luna/compounding.md#a-second-loop-auto-memory--vault).

## Safety rails — read first

These are non-negotiable. The pass is zero-loss **only** if you keep this order.

1. **Read-many, write-once (single-writer rule).** Fan out reader subagents
   **READ-ONLY** to mine the topic files in parallel. Exactly ONE writer (you,
   the parent) appends synthesized content to the vault. Never fan parallel
   writes at a shared note. (Single-writer rule: HIMMEL-166 / root `CLAUDE.md`.)
   **All landings go on a BRANCH in a worktree — vault AND repo** (operator
   directive 2026-07-14): himmel docs through the normal worktree → PR flow,
   and vault notes via a vault worktree on a `chore/memory-compound-<date>`
   branch (`git -C <vault> worktree add <path-outside-vault> -b <branch>`),
   committed + pushed, and merged by the OPERATOR after review. The vault is
   a single-writer personal repo with no PR gate by design (the
   `.single-writer` convention in root `CLAUDE.md`) — the branch + operator
   merge IS its review step; himmel-side landings keep the full PR + approval
   flow. Never write the live vault checkout or main directly — the branch is
   about trackability and reviewable merges, not parallelism.
2. **Land before you trim.** Append the durable learning to its vault note
   BEFORE you touch `MEMORY.md`, and trim `MEMORY.md` BEFORE deleting any topic
   file.
3. **qmd gate before any deletion.** Re-index (`qmd update` + `qmd embed`) and
   spot-check that the moved content is findable. Delete a topic file **only**
   after its content is confirmed searchable in the vault. No gate pass → no
   deletion.
4. **Back up `MEMORY.md` first.** Copy it aside before the first edit so the
   index is recoverable if the pass is interrupted.
5. **Status is disposable, not durable.** PR numbers, "merged", ticket state,
   dates → drop them (already recoverable from Jira, git history, and the
   `sessions/` captures). Only the reusable gotcha / decision compounds.
6. **Run in a DEDICATED session.** A hurried inline trim loses recall hooks,
   and the judgement (what compounds, what is disposable) deserves its own
   context. When the size warning fires mid-task: note it, finish the task,
   run `/memory-compound` in its own session. (Adding a genuinely NEW entry
   mid-task stays fine.) **Cache cost is small, not a reason to defer:**
   `MEMORY.md` is read at session start and after compaction and lives in
   that session's message history, so an edit on disk does NOT invalidate a
   running session's prompt cache — measured over 15 live sessions straddling
   a real edit: 14 kept, 1 compacted, 0 invalidated. The cost is one extra cache write
   (an estimate of ~4k tokens, not yet measured) per session started or
   compacted afterwards, so still batch
   the edits into ONE pass. Evidence and re-run:
   `docs/internals/prompt-cache.md` (eval `no-invalidation`).
7. **Memory does not propagate — adopter-generic learnings MUST land in
   himmel docs.** Auto-memory and the luna vault are operator-side only; a
   generic gotcha compounded only into luna is invisible to every other
   himmel user. The propagation review in step 3 is a gate, not a suggestion.

## Resolve the memory dir (step 0)

The auto-memory lives at `~/.claude/projects/<project-slug>/memory/`. The
`MEMORY.md` already injected into THIS session is the authoritative target —
do not guess a different store. Locate the directory:

```bash
ls -1 ~/.claude/projects/*/memory/MEMORY.md
```

If more than one matches, pick the store whose `MEMORY.md` matches the index
loaded in this session (same entries). Export it for the steps below:

```bash
MEMDIR="$HOME/.claude/projects/<project-slug>/memory"
```

Confirm the budget before doing work — if it is comfortably under ~24.4KB there
may be nothing to compound:

```bash
wc -c "$MEMDIR/MEMORY.md"
ls -1 "$MEMDIR"/*.md | wc -l
```

Also inventory stale `*.bak` backups, orphaned sibling stores and remote
stations in the same pass. **Read [references/inventory.md](references/inventory.md)**
for the procedure (a remote host that is unreachable is a WARN, never a
silent skip; skip cleanly when the station registry is absent).

## Runbook

### 1. Inventory
Read `$MEMDIR/MEMORY.md` and list the topic files (`$MEMDIR/*.md`, excluding
`MEMORY.md`). Each topic file is one fact with frontmatter (`type:` =
`user|feedback|project|reference`). Group the files by theme — environment
traps, harness gotchas, operator conventions, project status, … — so each
reader gets a coherent batch.

### 2. Mine (READ-ONLY fan-out)
Dispatch one **read-only** reader subagent per theme group. Each reads its
topic files and returns, per file, a structured verdict:

- **durable gotcha / decision** — the reusable learning, distilled to 1–3
  lines, plus the theme it belongs to, any `[[wikilinks]]` it already
  carries, and its **propagation class** — operator-specific vs
  adopter-generic (the step-3 review makes the final call). (Compoundable.)
- **pure status** — ephemeral (PR/ticket/date/"merged"). (Droppable, no
  synthesis.)
- **mixed** — durable core + status chrome; return only the durable core.

Readers do not write anything. The parent owns synthesis across all of them.

### 3. Propagation review + Land (single-writer synthesis)
You (the one writer) append each durable learning to the matching reference
note, **deduping against existing curated content** — extend or sharpen an
existing line rather than appending a near-duplicate.

**The propagation review is mandatory, per item, BEFORE writing.** Auto-memory
and the luna vault never reach another himmel user; defaulting everything to
luna is the documented failure mode (HIMMEL-900). Classify each durable item:
operator-specific → luna vault; adopter-generic → himmel docs via the normal
worktree → PR flow (**when in doubt, himmel docs**); rule/restriction
candidate → file a ticket for the promotion. Then triage by SHAPE (fact /
directive / invocation) to decide where recall happens. **Read
[references/propagation-review.md](references/propagation-review.md) before
landing anything** — it carries the routing table, the luna-path rules and
the shape triage.

### 4. qmd gate — THE GATE
Re-index the vault and confirm findability **before** any deletion. Run from the
himmel repo root (the `source` path is repo-root-relative):

```bash
source scripts/lib/qmd-bin.sh
qmd_cmd update
qmd_cmd embed
```

Then spot-check that each landed learning is retrievable — query the collection
you wrote to (`luna` for vault notes, `himmel` for `docs/internals/`) for a
phrase unique to the moved content and confirm it returns the new note. Use the
qmd MCP `query` tool, or `qmd_cmd query`. A learning that does not surface is
**not** compounded — fix the note (or its frontmatter) and re-index before
proceeding. No findability → no deletion.

Query `-c luna-curated` first, full `luna` only on a miss. **The flag is
`-c` / `--collection` (singular) — `--collections` is NOT a qmd flag and is
silently ignored**, so a gate run with it searches everything and "confirms" a
false pass. qmd indexes the PRIMARY checkouts, not worktrees: content landed
on a branch is findable only after the merges, so steps 5–6 of a fully-branched
pass run as a post-merge follow-up. **Read [references/qmd-gate.md](references/qmd-gate.md)**
for the dilution numbers and the split gate.

### 5. Slim `MEMORY.md`
Back it up first (a single `.bak`, removed in step 6 once the next session loads
cleanly — it is a transient safety copy, not a kept history). **Abort the slim if
the backup did not write** — same land-before-trim discipline: never edit the
index without a recoverable copy:

```bash
cp "$MEMDIR/MEMORY.md" "$MEMDIR/MEMORY.md.bak" || { echo "backup failed — aborting slim"; exit 1; }
```

Then, in the index — matching the shipped post-migration format (`- [Title](topic.md) — <keyword hooks>` for facts; a bare `- <directive>` line for directives):
- **Drop** pure-status entries outright.
- **Fact-shaped** entry → collapse to a **routing line ≤200 chars**:
  `- [Title](topic.md) — <keyword hooks>`. **KEEP the `[Title](topic.md)`
  link** — it is the native route to the tier-2 topic file the D7 read-protocol
  reads first (root `CLAUDE.md`: "read the theme topic file its keyword names").
  The hooks are a short comma-list of symptom keywords, **not** inlined bodies —
  bodies live in the topic file, never in the index line.
  **If the keyword-hook list would push the line past 200 chars, SPLIT the
  theme** — carve the overflowing domain into its OWN topic file + routing line;
  do NOT drop keywords and do NOT chain ~24 gotchas onto one fat line. This binds
  compound's OWN output: the 2026-07-16 pass emitted a 1,472-char line — that
  line *is* the store, which `context-architecture.md` forbids.
- **Fact-shaped, graduated to an adopter himmel doc** (its topic file is deleted
  in step 6) → `- <keyword hooks> → docs/internals/<doc>.md`. Use a **bare
  repo-relative path, NOT `[…](topic.md)` link form** — the step-6 dangling-link
  scanner greps `](…md)`, so a bare path is (correctly) ignored, and there is no
  local topic file for it to point at.
- **Directive-shaped** entry → a resident bare `- <directive> …` line ≤200 chars
  (no topic-file link; it must fire unprompted — see the shape triage in step 3).
- **Compound is NOT exempt from `guard-memory-capture.sh`** (HIMMEL-1088) and
  must **not** be launched with its bypass (`MEMORY_CAPTURE_OK=1`) set — that
  would reduce it to prose-governed, the layer this design rejects. `*.bak` is
  exempt by scope. If a legitimate multi-host fold exceeds the 400B growth cap
  in one write, use the narrow waiver (growth cap relaxed only when *every* line
  passes the 200-char rule), never a blanket bypass.

The goal is an index back under budget where every routing line is ≤200 chars
and resolves to where the fact lives: a kept, trimmed topic file (the common,
deterministic recall path), or — for an adopter-graduated fact — the himmel doc
that now carries it. Durable content is additionally graduated to luna/himmel
for durability + reach.

### 6. Trim topic files; delete only when fully graduated (after the gate)

**Graduate, do NOT delete a fact you can only recall by symptom (spike
HIMMEL-1086).** The 2026-07-17 spike measured symptom-shaped qmd recall at
**4/10** even inside the scoped `luna-curated` collection, while reading the
theme topic file the routing line names is **3/3 deterministic**. So the topic
file is the primary (tier-2) recall path, and folding a fact to luna is a
tier-3 durability/propagation copy — **not** a reason to delete its topic file.
Delete a topic file **only** when its content is reachable *without* a symptom
qmd query: it graduated to an **adopter-generic himmel doc** (qmd-findable in
the `himmel` collection *and* path-addressable), or its fact is fully carried by
a **resident** directive line. For a fact whose only home is a `luna` note,
**keep a trimmed topic file** (routing line + the distilled body) rather than
deleting it. (The full fold-and-trim semantics + the inverted orphan-topic-file
audit ride **HIMMEL-1090**; this guard is the safe floor until then.)

For each remaining topic file whose durable content is **confirmed findable**
(step 4), whose index entry is now a pointer (step 5), AND which has **fully
graduated to an adopter-generic himmel doc or resident directive** per the guard
above, delete it:

```bash
rm "$MEMDIR/<compounded-topic>.md"
```

**Post-slim gate — no dangling links.** Same discipline as the step-4 qmd gate:
a check, not a hope. After the deletions, every `[Title](file.md)` link in
`MEMORY.md` must point at a file that still exists — a link to a just-deleted
topic file is exactly the drift this guard catches (HIMMEL-641). Scan the index
for any `](…md)` whose target is now missing:

```bash
grep -oE '\]\(([^)]+\.md)\)' "$MEMDIR/MEMORY.md" | sed -E 's/^\]\(//; s/\)$//' | while read -r link; do
  [ -e "$MEMDIR/$link" ] || echo "DANGLING: $link"
done
```

Any `DANGLING:` line means a topic file was deleted (fully graduated) but its
index entry still links it — rewrite that entry to point at where the fact now
lives: `- <hook> → docs/internals/<doc>.md` for an adopter-graduated fact (a bare
repo-relative path, **not** in `[…](…)` link form, so this scanner ignores it),
or fold it into a resident directive line (drop the dead `[…](file.md)` link),
then re-run the scan. No clean scan → the pass is not done.

Leave any file you could not confidently compound (ambiguous, still-active
project state) in place — partial progress is fine and safe. Adopter-generic
items whose docs PR has not merged yet also stay (topic file or collapsed
pointer line) until the post-merge `himmel`-collection re-index finds them
(step 4 caveat). Keep
`MEMORY.md.bak` until the operator confirms the next session loads cleanly under
budget, then it can be removed.

## Lesson provenance carry (HIMMEL-767)

A mined memory that qualifies as a **lesson** carries its provenance forward:
a trailing `^lesson:<id>` anchor on the landed line, a record appended to the
vault's `lessons.jsonl`, and a `validate-lesson.mjs --capture` PASS **before
step 6 deletes any source topic file** (no PASS, no deletion). **Read
[references/lesson-provenance.md](references/lesson-provenance.md)** for the
exact fields and command.

## When you are BUILDING this skill vs RUNNING it

This SKILL.md *defines* the compaction. When you are developing the skill (not
running a real compaction), do **not** delete or rewrite any real `MEMORY.md`
topic file — you are shipping the runbook, not executing it.

## Optional: monthly safety-net nudge

The over-budget load warning is the primary trigger. As a backstop you can have
the OS scheduler NUDGE monthly (a reminder to consider running `/memory-compound`)
— it must **nudge, never auto-run**, since the pass needs judgement. The generic
`/schedule` and `/loop` drivers can carry such a reminder; do not arm an
unattended auto-compaction.

## Reference

- Documented pass: [`docs/luna/compounding.md`](../../../../../docs/luna/compounding.md#a-second-loop-auto-memory--vault).
- Worked precedent: HIMMEL-564 (the by-hand 56KB → 16KB compaction this automates).
- Lesson provenance schema + validator: [`docs/internals/lesson-provenance.md`](../../../../../docs/internals/lesson-provenance.md) (HIMMEL-767).
- Layer choice (lean-invoke, not a hook): HIMMEL-177; single-writer rule: HIMMEL-166.
