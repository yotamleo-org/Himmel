<!-- Moved verbatim out of harvest-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

**Phase 5 — G-3 single-section-add invariant + write (atomic sequence).**

The write sequence is **atomic** — all steps must succeed OR the clip is reverted to the Phase 1 baseline. Path-specific behavior:

1. **Stale-read guard (both paths).** Re-read the clip; recompute SHA256. If different from Phase 1 baseline: log `~ <clip> — partial (stale-read): operator-edit detected mid-pass`. Skip mutation entirely. State-file: `harvest_status: partial`.
2. **Body write (github-ingest path ONLY).** For the github-ingest path, find the line `^## Source$` in the body (the part of the file BELOW the closing `---` frontmatter delimiter). Insert a new `## Harvested content` section IMMEDIATELY BEFORE it. Body:
   ```markdown
   ## Harvested content
   <!-- harvest-clips $TODAY via obsidian-triage:luna-ingest -->
   <skill output verbatim — typically a back-reference [[30-Resources/Tech/<slug>]] or a brief synthesis>
   ```
   **For the clip-body path: SKIP this step entirely.** The clip body already IS the harvest; no new section is added. Frontmatter mark is the only write.
3. **G-3 invariant check (BODY-ONLY SCOPE, both paths — assertion differs).** Both paths run this check; the assertion shape differs:
   - **github-ingest:** re-diff the file's BODY against the Phase 1 body baseline (everything from the closing `---` to EOF). Assert exactly ONE new H2-level section was added; no existing body sections were modified.
   - **clip-body:** re-diff the body against the Phase 1 baseline; assert ZERO body changes (byte-identical). The body should be untouched because step 2 was skipped for this path — this check is the defensive backstop against an accidental write.
   - **Both paths:** the G-3 diff scope is body-only. Frontmatter mutation in step 4 is whitelisted (only the `harvest_*` keys — the four below plus the optional `harvest_flag` + `harvest_flag_detail` pair from Phase 4.5 — may be added; no existing frontmatter keys may be modified).
   - On failure (either assertion): revert the file via the Phase 1 baseline content; log `✗ <clip> — failed (G-3): single-section-add invariant violated`. State-file: `harvest_status: failed`, `last_error: g3_invariant`. Stop.
4. **Frontmatter write (both paths).** Add these four keys as top-level zero-indent YAML entries, after every existing top-level key + block-list (Phase 7 placement contract from `/triage-clips`):
   ```yaml
   harvested_at: $TODAY
   harvest_skill: clip-body | obsidian-triage:luna-ingest
   harvest_url_canonical: <canonical>
   harvest_status: ok | partial | failed
   ```
   If Phase 4.5 flagged the clip (or fail-closed on a screen error), add two more keys: `harvest_flag: injection-suspect` + `harvest_flag_detail: <class1>,<class2>` (comma-joined scanner classes; `screen-error` on the fail-closed path). For clip-body path, `harvest_skill: clip-body`. For github-ingest, `harvest_skill: obsidian-triage:luna-ingest`. No other frontmatter keys are touched. If an existing `harvest_*` key is present (from a prior partial run): replace it in place; do NOT duplicate.
5. **Final parse-validate.** Re-parse the full frontmatter as YAML. If invalid: revert to Phase 1 baseline; log `✗ <clip> — failed (frontmatter-yaml-write): proposed frontmatter unparseable`. State-file: `harvest_status: failed`, `last_error: frontmatter_yaml`.

Order matters (github-ingest): body write → G-3 body-diff → frontmatter write → final parse. Order for clip-body: G-3 body-identity → frontmatter write → final parse. Reverting on any failure restores the Phase 1 baseline — partial mutation is never observable. (CR M2 + M3.)
