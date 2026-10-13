<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

## Phase 3.6 — Research enrichment (LUNA-64, `--research` only)

Skip this entire phase unless `--research` was passed. Orthogonal to
Phase 3.5 — if both `--deep` and `--research` were passed, both phases run
(Phase 3.5 first, then this one).

This is the **lightweight inline** research path: you (Claude) run the web
research yourself via the WebSearch / WebFetch tools. Do NOT shell out to the
obsidian-second-brain `research_deep.py` script, and do NOT call Perplexity /
Grok — those (plus vault-wide `/obsidian-save` propagation) are the full
`/research-deep` command, deferred to a later LUNA-64 follow-up. Scope here:
**the SOURCE repo only** (1-hop refs are not researched in MVP — keeps the
tool-call budget bounded).

1. **Dry-run short-circuit.** If `--dry-run` was passed, skip the web queries
   entirely (avoids spending tool calls on a no-write run); print
   `DRY luna-ingest: would run research enrichment for <owner_repo>` to stderr
   and continue to Phase 4 (the `## Research enrichment` section is then
   rendered as `_(dry-run — research not executed)_`; do NOT set
   `research_enriched` — this is a degraded branch).
2. **Run 3–5 WebSearch queries** about the source repo. Seed them from the
   repo name + description + primary topics, covering these axes (drop any axis
   the repo metadata makes irrelevant):
   - maturity / adoption (is it actively used in production? release cadence?)
   - notable alternatives / what people compare it to
   - known limitations, gotchas, or common complaints
   - community sentiment + recency (how recent is the discourse?)
   Use WebFetch to pull a specific source when a search result needs
   confirmation. Keep total fetches modest (≤5) — this is enrichment, not a
   full research report.
3. **Synthesize** the findings into 4–8 bullets for the `## Research
   enrichment` section (rendered in Phase 4). Every external claim carries a
   recency marker (the source's date, or "as of <month YYYY>") and a source
   URL inline — consistent with the luna vault's AI-first sourcing rule.
4. **Graceful degradation.** If WebSearch/WebFetch is unavailable or returns
   nothing usable, do NOT fail the ingest: render the section as `_(research
   enrichment requested but web search returned no usable results)_`, add a
   one-line note under § Open questions, and continue. Do NOT set
   `research_enriched` (the note is not enriched). A partial note is better
   than no note — same rule as the component-scan partial path. No new exit
   code: `--research` failure never changes rc.
