<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Tags derivation (HIMMEL-247)

`tags:` is REQUIRED in every emitted note's frontmatter — the vault's Tech
notes are tag-queried (Dataview / triage tooling), and an untagged note is
invisible to those queries. The original Phase 4 / I-3 templates never
emitted it — every pre-fix tech-ingest note shipped untagged (all 29
`type: tech-ingest` notes as of 2026-06-11; HIMMEL-247 backfilled them).
The "~90 earlier Tech notes that carry tags" in the ticket are
clipper-pipeline `type: tech-resource` notes — a different emitter, not
luna-ingest output. Never omit it.

Rules (repo notes):

1. First tag is always `github` — matches the existing `30-Resources/Tech/`
   scheme (the dominant tag in that folder).
2. Then the repo's `topics[]` from the Phase 1 metadata, each normalized the
   Phase 1.5 way (lowercase, runs of `[-_\s]+` → a single `-`), deduped,
   capped at **5** topic tags. When more than 5 topics exist, pick the most
   content-salient ones (what the repo IS, not its stack minutiae), preferring
   topics that already appear in the vault's tag vocabulary — NOT blind
   API/alphabetical order.
3. If the repo has no topics (or fewer than 2 survive normalization), infer
   2–4 domain tags from the name + description + README — prefer the vault's
   existing tag vocabulary (e.g. `claude-code`, `ai-agents`, `mcp`,
   `obsidian`, `cli`, `automation`, `memory`, `skills`) over minting a new
   term; check existing Tech-note tags before coining one.
4. Minimum 2 tags total — never a bare `tags:` with no entries, never
   `github` alone.

Issue notes (I-3) use the variant: `github`, `github-issue`, then up to 3
topic tags derived the same way (repo `topics[]` when the I-1 repo-metadata
fetch succeeded; else inferred from the issue labels + title).

Write the file. Structure:
