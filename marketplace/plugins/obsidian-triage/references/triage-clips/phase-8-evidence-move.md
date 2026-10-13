<!-- Moved verbatim out of triage-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

**Phase 8 — Move to evidence pool (runs ONLY after Phase 7 successfully marked `processed: true`) — inside the same `triage-mark-processed.py` call.**

The Phase 7 call continues straight into Phase 8; the Phase-8 debt drain runs
the same code with `--drain`. What it does, so the result lines make sense
(the code and its comments in `tools/triage-mark-processed.py` are the
specification; `tests/test-triage-mark-processed.sh` pins it):

When `DRY_RUN=1`, the call carries `--dry-run`: it checks the SHA, computes
the destination and the link count, and writes nothing. The clip emits a `⊘`
skip line (`⊘ <clip> — skipped (phase-8-move): dry-run — would move → _evidence/<basename>.md, {L} links would be rewritten`), so it counts toward `M skipped`, not `N processed`.

Phase 8 is **forward-only** (HIMMEL-1713): Phase 7 has already recorded the
debt (`evidence_pending: true`), so any failure leaves the marker set and
stops — never revert, never move the file back, never delete frontmatter keys.
The Phase-8 debt drain resumes the clip on the next run.

0. **`ig_media_pending` hold (HIMMEL-770).** A frontmatter `ig_media_pending: true`
   (read from the leading `---` block only, so a body-forged hold cannot park a
   clip) holds the move: exit 10. Phases 1-7 ran, so the clip IS triaged. Emit
   `✓ <clip-filename.md> — {summary-len}c summary, {N} tags, {M} related, {K} actions → daily, promotion → <folder> → stays in inbox (ig_media_pending), evidence_pending set, 0 links rewritten`.
   The `evidence_pending set` segment is required: this ✓ does NOT mean the
   clip is finished. Count it as processed (`N`). When `/ig-media-enrich`
   clears the hold, the debt drain moves it on the next run.

1. **`evidence_kind:` + `evidence_origin:` (one edit, idempotent).** If absent,
   `evidence_kind` comes from `tools/lib/evidence-kind.mjs` (type, URL, tags) as
   a zero-indent block list, and `evidence_origin` records the clip's current
   path relative to `Clippings/` without `.md` — the only record of a date
   subfolder once the flat move happens. It is written as
   `evidence_origin: '<OLD>'`, single-quoted with every internal `'` doubled
   (clip ids open with `@` and can contain ` #`), and re-read to assert it
   equals `<OLD>` byte for byte before anything moves. An existing
   `evidence_kind:` or `evidence_origin:` is authoritative and never rewritten.

2. **The `<OLD>` identifier set.** `evidence_origin:` when present, plus the
   current inbox id when it differs (a clip renamed after the record); a clip
   already in `_evidence/` with no `evidence_origin:` stops with
   `evidence_origin missing; needs a manual Phase 8`. `<NEW>` =
   `_evidence/<basename>` is never a member. **Ambiguity guard:** when
   `[[Clippings/<member>.md]]` is claimed by two real clips (`foo` and
   `foo.md.md`) the tool refuses — `rename one of them`.

3. **Move.** `ln` the clip to `_evidence/<basename>.md`, then unlink the source:
   `link()` fails when the destination exists, so the claim and the check are
   one atomic step and an existing evidence note is never overwritten
   (`COLLISION` → `_evidence/<basename>.md already holds a different clip; needs an operator rename`).
   A same-inode resume left by an interrupted `ln`+unlink is completed, a
   surviving alias is reported (`source alias survived unlink`), and a
   filesystem that cannot hard-link degrades to `mv -n` with a postcondition
   check.

4. **Rewrite + verify.** Six literal (never regex) link forms per `<OLD>`
   member — `[[Clippings/<OLD>]]`, `|`, `#`, and the three `.md` forms — are
   rewritten across the vault's `*.md`, the moved clip's own Phase 6 self-ref
   included, then re-counted. Any left: `<N> links pending; will resume next run (evidence_pending set)`.

5. **Commit point.** Zero left: the tool deletes `evidence_pending:` and
   `evidence_origin:` from the moved clip, and only now prints `OK`.

6. **Emit the per-clip success line** (ONLY on `OK`): `✓ <clip-filename.md> — {summary-len}c summary, {N} tags, {M} related, {K} actions → daily, promotion → <folder> → _evidence/, {L} links rewritten`.
