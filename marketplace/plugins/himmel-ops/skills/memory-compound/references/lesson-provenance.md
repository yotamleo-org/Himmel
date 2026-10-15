# memory-compound — lesson provenance carry (HIMMEL-767)

Moved verbatim out of `SKILL.md`.

When a mined memory qualifies as a **lesson** (a feedback/reference gotcha,
not pure status), carry its provenance forward instead of laundering it away
— this is the piece that stops compounding from losing the evidence trail.
Schema: [`docs/internals/lesson-provenance.md`](../../../../../../docs/internals/lesson-provenance.md).

- **Source topic files.** A topic file that records a lesson should include
  the `lesson:` YAML frontmatter block (files without it remain valid memory
  but are excluded from the self-evolving pipeline — the pipeline consumes
  only schema-carrying records).
- **Landing (step 3, above).** When you append the durable learning to its
  theme note, give the landed line a trailing `^lesson:<id>` anchor (mint a
  fresh `YYYY-MM-DD-<kebab-slug>` id if the source topic file carried none),
  then write the full record (JSONL) to that vault's `lessons.jsonl` ledger
  (one append-only file at the vault root) with `source.type: compound`,
  `source.ref` = the list of source memory topic-file paths distilled from,
  and `captured_by: memory-compound`.
- **Validate before delete.** Before step 6 deletes any source topic file,
  run `node scripts/lessons/validate-lesson.mjs --capture <vault>/lessons.jsonl`
  (from the himmel repo root; `--capture` = capture-time mode — any `audit`
  block fails, since the capture path never writes one) and confirm the new
  record(s) PASS. This rides alongside the qmd gate (step 4), not instead of
  it — no PASS, no deletion.
