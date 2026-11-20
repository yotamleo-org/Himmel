---
allowed-tools: Bash, Read
description: SYNTHESIZE stub mode — compound the evidence pool into early stub subject pages; ledgered, --revert undoes it.
argument-hint: "[vault-path] [--dry-run | --apply [--limit N] | --revert <ledger.jsonl>]"
---

## Your task

Turn accumulated evidence into compounding subjects. The existing
`/synthesize-clips` writes advisory `_synthesis/` **proposal** pages behind a
deliberately suppressive substance floor — correct for *structural* proposals,
but exactly what blocks the compounding loop. This command is the **separate,
lower-bar generative path**: when the evidence pool holds >=2 clips that
genuinely converge on a topic, it auto-creates a thin, clearly-marked
`status: stub` subject page in `30-Resources/Concepts/` (or `30-Resources/Tech/`)
and stamps the contributing clips `promoted_to:`.

The deterministic work is done by the node engine `tools/synthesize-stubs.mjs`
(no LLM judgement, no npm deps — reuses `tools/lib/{url-canonical,evidence-kind,
frontmatter,stub-synthesis}.mjs`). Your job is to drive it through the staging
gate below and never skip a step.

### The trigger (anti-sprawl — the BLOCKER the critics flagged)

A stub fires for a topical tag **T** only when ALL hold:
1. >=2 evidence clips carry **T** (structural tags like `concepts`/`tools`/
   `article` are excluded from being a concept key, in their singular and plural
   form — see `STRUCTURAL_TAGS`).
2. **After canonical-URL dedup** of the contributors (one article clipped twice
   collapses to a single contributor — reuses the dedup sweep's `canonicalize()`), the
   distinct-contributor count is still >=2.
3. Those contributors span **>=2 distinct domains OR >=2 distinct authors** (the
   OR arm lets single-platform authors — every X clip is `x.com` — still pass).

Anything short of all three is logged `⊘ <tag> — skipped (<reason>)` and writes
nothing. A single article clipped twice produces **0 stubs**, by construction.

**Singular and plural are one tag.** `workflow` and `workflows` count as one tag
and make one subject: the clips of both spellings are pooled, and the page is
named for the spelling more clips use (the shorter on a tie). Only the last word
of a tag is folded (`api-keys` = `api-key`), only regular English plurals fold
(`dependencies`, `caches`, `boxes`), and words that merely end like a plural keep
their form (`class`, `status`, `analysis`, `news`), while their own plurals
(`statuses`, `biases`, `lenses`) still meet them. Different words never merge:
`workflow` and `workload` stay two subjects.

### Existing-subject match → densify, never duplicate

Before creating a stub the engine scans existing subjects in
`30-Resources/{Concepts,Tech}` and `60-Maps/*-MOC` and matches by **normalised
name** (case/punctuation-insensitive, `-MOC` suffix stripped — so the tag
`context-windows` matches a `Context-Windows-MOC`) **or** a declared `aliases:`
entry (so a `self-hosted` group densifies an existing `Local First` page that
lists `self-hosted` as an alias), or by the **exact file name** (so a page whose
name has no Latin letter or digit, such as `Агенты.md`, is densified and not
refused). The singular/plural fold applies here too: a
`workflow` group densifies an existing `Workflows` page. On a match it **densifies** — appends the
fresh contributors to the subject's `## Evidence` section and stamps them —
and creates **0** new pages. Matching is BOUNDED (exact normalised equality +
operator aliases), never an open-ended similarity guess. A densify is recorded
in the ledger with the appended block, so `--revert` removes exactly that block
(or refuses if the page diverged).

A subject name holding `/` or `..` (a tag such as `ai/agents`) is skipped with
that reason and counted in `skipped`: it would be a page in a folder the index
never reads, or one outside `30-Resources/`. A subject path that already holds
anything is never written to: a symbolic link (dangling or not), a directory or
another non-regular file is refused before a write, and a regular file the index
did not list is refused by the exclusive create itself. The engine prints
`⊘ <path> — refused: an existing symbolic link sits there, nothing written`,
stamps none of its clips, writes no ledger entry, and counts it on the summary
as `N refused (path taken)`. The dry run prints the same refusal, in the same
order and with the same counts, instead of `would create`. The subject index
lists regular files only, so a link is never matched for a densify either.

A subject name is written into each stamped clip's header as the double-quoted
`promoted_to:` value with `"` and `\` escaped, so a tag holding a quote leaves
the header parseable. `Clippings/_deferred.md` is written only when it is a
plain file: a link, a directory or a special file there is refused with the same
line, once per run, in the dry run, the apply and the revert alike.

### Resolve vault path

Same as `/triage-clips`: `$1`, then `$OBSIDIAN_VAULT_PATH`, then
`~/Documents/luna`. Verify `<vault>/Clippings/_evidence/` exists; if not, there
is no evidence pool yet (run Phase-1 migration first) — exit 0.

### Default is `--dry-run` (writes nothing)

```bash
node tools/synthesize-stubs.mjs <vault>            # dry-run: report decisions only
```
Read the `✓ would create …` / `⊘ … skipped` lines and the summary. Nothing is
written, no clip is stamped.

### Per-run limit

`--apply --limit N` writes at most N pages in the run, creates and densifies
together, in the order the dry run lists them. The rest are counted as pending
and come up on later runs; a page that already cites its clips costs no slot.
Obsidian hangs on bulk file churn, so the nightly run always passes a limit.
The last line of the run is the summary, for example
`synthesize-stubs.mjs: 5 created, 0 densified, 3 skipped, 2 unchanged, 40 pending (limit 5)`.
A limit of 0, a negative one or a non-number is a usage error (exit 1).

### Live run = MANDATORY staging gate (irreversible-ish — operator-gated)

This gate covers every live apply you run yourself. The one exception is the
nightly run (`scripts/luna/pipeline-cadence.sh`), which applies without an
operator: it passes `--limit` and `--no-telegram-digest`, holds the vault's git
index lock for the apply so a git-based sync cannot commit a half-written
state, and relies on the staging and divergence proofs below having been done
once on a sample copy. It writes the same ledger, so `--revert` undoes it.

A stub auto-creates real pages and stamps clips. Unlike a `_synthesis/` proposal
it is NOT advisory. Before any `--apply` against the real `~/Documents/luna`:

1. **Stage on a copy first.** `cp -r ~/Documents/luna /tmp/luna-stage` and run
   `node tools/synthesize-stubs.mjs /tmp/luna-stage --apply`. Assert: same-URL
   dups produce 0 stubs; distinct-author pairs produce 1 stub each with
   `promoted_to:` stamped and a ledger line; an existing subject is densified,
   not duplicated.
2. **Prove the divergence guard.** Touch one generated page, then
   `--revert <ledger>` — it must REFUSE the touched page and revert only
   untouched ones.
3. **Pause Obsidian-GitHub-Sync, sole-writer, operator-confirmed**, then run
   `--apply` live. The operator's backup is the safety net, not a substitute for
   staging.

### Reversibility — the generation-ledger + divergence guard (HARD GUARDRAIL)

Every `--apply` appends to `<vault>/.synthesize-stubs.ledger.jsonl` one line per
created page: the page path, its **sha256 at generation**, the contributing
clip paths, and which clips it stamped. To undo a run:

```bash
node tools/synthesize-stubs.mjs <vault> --revert <vault>/.synthesize-stubs.ledger.jsonl
```

`--revert` deletes a generated stub and clears the `promoted_to:` it stamped
**only when the page is byte-identical to generation**. A page whose hash has
diverged (the operator opened, edited, or densified it) is **REFUSED** and left
untouched — "delete to undo" is forbidden once a stub has been hand-edited. That
refusal IS the Phase-2 rollback contract.

### Daily timeline (after a live `--apply`)

A successful `--apply` promotes/densifies subjects, which is pipeline activity
the daily note should record. After the apply against the live vault, refresh
today's `## Clip pipeline` section (state recount — idempotent, one section, no
double-count):

```bash
node tools/daily-timeline.mjs --vault <vault> --date "$(date +%Y-%m-%d)"
```

It reads the promoted/densified counts from the same
`.synthesize-stubs.ledger.jsonl` this run appended (and captured/reviewed from
clip state). A missing daily note is a no-op. Skip after a `--dry-run` (nothing
was promoted) and after `--revert`.

### Telegram promotion feedback (after a live `--apply`)

When a promoted clip was **captured via telegram**, let the operator see the
vault compounding from the same surface they captured on (design §8). The engine
already did the work: on `--apply` it writes a **batched digest** to
`<vault>/.synthesize-stubs.telegram-digest.json` — **ONE reply per originating
chat** (not one per promotion; §12.F), filtered to telegram-origin clips, and it
**removes** that file when a run promoted nothing new (so nothing stale is
re-sent). Pass `--no-telegram-digest` to suppress entirely (the first big
synthesize run after the one-time `_evidence/` migration backfill).

After a live `--apply`, if the digest file exists, send it (operator-gated — the
live telegram send is the irreversible step, HARD GUARDRAIL #4):

1. Read `<vault>/.synthesize-stubs.telegram-digest.json`. Its `replies` array is
   `[{ chat_id, reply_to, text }, …]`.
2. For each entry, send ONE message through the **telegram bridge `reply` tool**
   (NOT a raw API call — the bridge is the only sanctioned send path): pass
   `chat_id`, `text`, and `reply_to`. The bridge enforces its own outbound gate.
3. After all replies send successfully, **delete the digest file** so a later run
   never re-sends it.

Do this only against the live bridge with operator confirmation; in staging,
inspect the JSON and do not send.

### Headless refusal (the no-headless-claude rule)

This command makes no `claude -p` / `--print` / `--bg` / API calls. The engine
is a deterministic node tool — never wrap it in a headless invocation.

### Tests

Hermetic acceptance test (run locally — CI does not run `marketplace/**`):
```bash
bash marketplace/plugins/obsidian-triage/tests/test-synthesize-stubs.sh
```
