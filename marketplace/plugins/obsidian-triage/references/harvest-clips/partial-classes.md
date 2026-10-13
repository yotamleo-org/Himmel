<!-- Moved verbatim out of harvest-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Partial classes (HIMMEL-4675) — deferred vs blocking

A source-level, per-clip partial (the source cannot give more today) is **deferred**: it does NOT block `.harvest.done`, so `/triage-clips` and `/synthesize-clips` still run on the rest. A partial or failure that means this run's own view is unreliable **blocks**: G-8 writes no marker.

| Class | Where it comes from | Verdict | Counted |
|---|---|---|---|
| `thin-body` skeleton | batch tool, clipper captured only placeholders | deferred | yes |
| `enricher-gap` (`harvest_enricher_gap`) | batch tool, known platform with no enricher | deferred | yes |
| `ig_media_pending` | batch tool / IG routing row, media rung pending | deferred | yes |
| `x_media_pending` | `/x-media-enrich` parks a retryable X media failure | deferred | yes (when the clip is also a harvest partial) |
| `firecrawl` fetch failed | batch tool `--firecrawl-thin`, one URL failed | deferred | yes |
| `firecrawl` budget exhausted / unavailable (parked) | run-level credit cap or outage, not the clip's fault | deferred | no |
| `stale-read` mid-pass | the clip changed under the run | **blocking** | — |
| `rate-limited` mid-batch | a dispatched skill was throttled | **blocking** | — |
| `failed` (`✗`, batch tool `FAIL`) | read, canonicalize or G-3 failure | **blocking** | — |
| `catastrophic` abort | exit 5 | **blocking** | — |

**Retry count.** Each deferred, counted partial increments `harvest_defer_count` in the clip's own frontmatter — not the daily G-5 state file, which rotates at midnight and would reset it. At `harvest_defer_count: 5` the batch tool also writes `harvest_needs_attention: true`, and from then on the clip is skipped (`⊘ skipped (needs-attention)`) instead of re-read every night. Five nights covers a work-week of transient outages before a human looks. A needs-attention clip is never silently dropped: it stays listed. To retry it, fix the source or clip and delete `harvest_needs_attention`.

**Pending report.** Every non-dry run of `harvest-clip-body-batch.py` rebuilds `<vault>/.harvest-pending.md` from the clips' frontmatter: a `## Deferred` list (reason, count) and a `## Needs attention` bucket. The batch summary adds `harvest-clip-body-batch: D deferred (non-blocking), A needs-attention; pending report: .harvest-pending.md`. Every `PART` line the batch tool prints is deferred-class; only its `FAIL` lines (exit 4) block. The batch tool also owns `.harvest.done` (G-8, HIMMEL-4684): a non-dry run with no `FAIL` writes it, a run with a `FAIL` removes it.
