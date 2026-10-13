<!-- Moved verbatim out of triage-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Daily timeline (LUNA-90 — runs ONCE after the per-clip loop)

After the whole pass completes (NOT per-clip), refresh today's `## Clip pipeline`
section so the daily note is a timeline of pipeline activity, not just capture
(design §9). This is a **state recount** — it recomputes captured → inbox /
reviewed → evidence (by kind) / promoted → subjects / densified subjects from
vault state + the synthesize-stubs ledger and upserts ONE section. It is
idempotent (re-running the same day updates the one section, never appends a
second or double-counts), so run it unconditionally at end-of-pass:

```bash
node <plugin>/tools/daily-timeline.mjs --vault "$VAULT" --date "$TODAY"
```

`<plugin>` is this runbook's plugin root (`marketplace/plugins/obsidian-triage`).
**File-level single-writer (plan-critic #4):** Phase 5 already wrote
`## Actions from clips` to this same note in this run; run this AFTER Phase 5 has
finished so the two writes are sequential full read-modify-writes, never
interleaved. A missing daily note is created from `_Templates/Daily-Note.md`
(HIMMEL-4182), and the same run upserts the `## Daily report` section (sources,
suggested actions, carry-over). Skip when `DRY_RUN=1`.
