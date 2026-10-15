# luna-ingest — Exit codes

Moved verbatim out of `SKILL.md`.

- 0: synthesized + written (or dry-run completed) — all refs classified
- 1: usage / input error (bad URL, missing required arg)
- 2: env unusable (vault not found, gh api / bitbucket CLI unreachable or unbuilt for source repo, dest category invalid)
- 3: target file exists (no overwrite in MVP)
- 4: **partial run** — synthesis written but ≥1 ref was marked `api_failure` (rate-limit / network / auth). Re-run later to retry the failed refs; the dedup-by-existing-file invariant means a re-run exits rc=3 while the synthesis file exists. `--force` is NOT supported in the MVP, so to retry, delete the existing synthesis and rerun. (LUNA-6)
- 4 (extended): also returned when `--deep` component scan reported ≥1
  component-fetch failure (partial inventory). Synthesis is still written.
- 5: source fetch failed — `gh api` (github Phase 1) or the `bitbucket` CLI (HIMMEL-329 Bitbucket branch) failed for the SOURCE repo / PR / issue (network / rate limit / 404 / issues-disabled) — nothing written, retry the whole call
- 6: **safety-blocked** — Phase 1.5 matched a red-flag keyword in name/description/topics/README (github) or name/description/README (bitbucket — no topics), and `--allow-unsafe` was NOT passed. Nothing written. Re-run with `--allow-unsafe` to ingest with `safety_flag` annotation (which exits rc=0, NOT rc=6, on success — `--allow-unsafe` plus a match is a known-risk acknowledged ingest, not an error). (LUNA-43)

`--research` (LUNA-64) never changes the exit code: a web-search failure
degrades gracefully (annotated section + § Open questions note) and the
synthesis is still written at the rc the rest of the run would have produced.
