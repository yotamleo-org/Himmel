<!-- Moved verbatim out of triage-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

**Phase 7 — Mark processed (with stale-read guard + placement contract) — through `tools/triage-mark-processed.py`, never by hand.**

Phase 7 and Phase 8 are ONE tool call (HIMMEL-4685). The stale-read guard, the
mark and the atomic move are code, so there is no prose for a caller to skip:

```bash
python3 "<plugin>/tools/triage-mark-processed.py" "<vault>" "$clip" --expect-sha "$LAST_WRITE_SHA"
# add --summary-basis url-only when Phase 2's summary is URL-only (see Phase 2)
# add --dry-run under DRY_RUN=1
```

**This call is the only sanctioned way to write `processed: true` or to move a
clip.** Never write `processed:`, `triaged_at:`, `evidence_pending:`,
`evidence_kind:` or `evidence_origin:` with `Edit`/`Write`, never `mv`/`ln`/`cp`
a clip into `_evidence/`, and never write a helper script that does either. A
mark or move that does not go through this call has skipped the stale-read
guard and the atomic move — the 2026-10-07 regression, where parallel triage
subagents marked and moved 86 clips through their own helpers.

- **Stale-read guard:** the tool re-reads the clip and compares its SHA256 with `LAST_WRITE_SHA` (the hash recorded after this run's own most recent write in Phases 2-6 — NOT the Phase 1 pre-mutation baseline, which Phases 2-6 legitimately diverge from). A mismatch means the user edited the clip mid-pass (Obsidian sync, manual edit, another tool): the tool exits 3, writes nothing, and prints `SKIP phase-7-mark: user-edit detected mid-pass (stale read), skipping to avoid clobbering manual edits`. It checks again immediately before its write. A missing or malformed `--expect-sha` exits 2 — the guard cannot be skipped by leaving the hash out.

- **Placement contract:** in ONE edit the tool inserts `processed: true`, `triaged_at: TODAY` and `evidence_pending: true` (plus `summary_basis: url-only` when asked) as zero-indent top-level keys immediately before the closing `---`, after every existing key and every block list — never inside a list, never between a key and its items — and parses the result before writing. `evidence_pending: true` is the recorded Phase-8 debt (HIMMEL-1713); only Phase 8's commit point removes it.

  ```yaml
  ---
  title: ...
  tags:
    - article
    - focus
  status: unread
  processed: true
  triaged_at: 2026-05-25
  evidence_pending: true
  ---
  ```

- **Outcomes.** The tool prints exactly one result line. Map it to the Logging contract:

  | exit | line | log |
  |---|---|---|
  | 0 | `OK moved → _evidence/<basename>.md, <L> links rewritten` | the ✓ line, `{L}` from the tool |
  | 10 | `HELD stays in inbox (ig_media_pending), evidence_pending set` | the held ✓ line (Phase 8 step 0) |
  | 0 | `DRY-RUN …` (only with `--dry-run`) | `⊘ <clip> — skipped (phase-8-move): dry-run — would move → …` |
  | 2 | `USAGE <reason>` | a runbook bug: stop and report it, never work around it |
  | 3, 4 | `SKIP phase-7-mark: <reason>` | `⊘ <clip> — skipped (phase-7-mark): <reason>`; nothing was written |
  | 5 | `SKIP phase-8-move: <reason>` | `⊘ <clip> — skipped (phase-8-move): <reason>`; forward-only |

  If Phase 5 already wrote action items and the mark is refused, they stay in today's daily note without a processed marker on the clip; the Phase 5 dedup-by-backreference rule prevents duplicates on the next run.

- Idempotency contract: after Phase 8, a successfully processed clip lives in `Clippings/_evidence/<basename>.md` and is excluded from future triage scans by the `-not -path '*/_evidence/*'` flag. To re-trigger triage on a clip, the user must (1) delete `processed: true`, `triaged_at:`, `evidence_kind:`, `summary_basis:` and `evidence_pending:` / `evidence_origin:` (if present) from the clip's frontmatter AND (2) move the clip back to `Clippings/<basename>.md` (top-level inbox). Deleting only the frontmatter markers while the clip remains in `_evidence/` is insufficient — the scan excludes that folder entirely. (Re-triage is an operator act, outside this command.)
