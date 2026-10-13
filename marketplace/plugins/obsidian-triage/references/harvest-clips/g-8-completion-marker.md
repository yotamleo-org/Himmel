<!-- Moved verbatim out of harvest-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### G-8 — Completion marker (HIMMEL-1137) — write LAST, clean runs only

Downstream stages (`/triage-clips`, `/synthesize-clips`, `/archive-clips`) refuse to run against a harvest that never finished cleanly. This is the run's final step, after the Tracking append.

If this run is exiting 0 — a clean run: every unharvested clip landed at `ok`, was skipped, or is a **deferred** partial (the class table above: thin-body, enricher-gap, IG/X media-pending, firecrawl), with no blocking partial, no `failed`, no catastrophic abort — `<vault>/.harvest.done` must exist at exit.

**The batch tool writes it provisionally (HIMMEL-4684, HIMMEL-4707).** A non-dry run of `harvest-clip-body-batch.py` with no `FAIL` line writes `<vault>/.harvest.done.provisional` atomically, as `<ISO timestamp> <batch hash>` (the hash is over the clip paths it scanned), and prints `harvest-clip-body-batch: wrote .harvest.done.provisional (<hash>); G-8 renames it to .harvest.done`. A run with a `FAIL` (exit 4) removes both markers. Do NOT write either by hand after a batch-tool run.

Downstream stages trust only `.harvest.done`. As this run's final step, once no **blocking** class has occurred (a `stale-read`, a `rate-limited` dispatch, a catastrophic abort — see the class table), promote the marker with an atomic rename: `mv "<vault>/.harvest.done.provisional" "<vault>/.harvest.done"` (it fails when there is no provisional marker, so a blocked run cannot promote). A run that is killed, or aborts before this step, leaves only the provisional marker and downstream stays gated closed. If a blocking class happens, do not promote; remove the provisional marker: `rm -f "<vault>/.harvest.done.provisional"`. Only when this run harvested without the batch tool at all does the agent write `.harvest.done` itself, the same way:

```bash
marker_tmp="<vault>/.harvest.done.tmp.$$"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$batch_hash" > "$marker_tmp"
mv "$marker_tmp" "<vault>/.harvest.done"
```

`$batch_hash` is then the same clip-batch hash G-2 wrote into `<vault>/.harvest.lock` for this run.

On any other exit path (1/2/3/4/5) MUST NOT write the marker, and it must not exist at exit — it already stands invalidated from G-2's start-of-run deletion, so a partial/failed/interrupted run leaves downstream gated closed until a clean harvest completes. No operator override flag — keep it minimal.
