# luna-ingest — Out of scope (v2 follow-ups)

Moved verbatim out of `SKILL.md`.

- Twitter URL input via `/x-read`
- Article URL input via `/defuddle` + `/research`
- github PR (`/pull/<n>`) + discussion URL ingestion (github issue URLs landed in HIMMEL-239; bitbucket repo/PR/issue landed in HIMMEL-329)
- bitbucket-source → bitbucket-ref 1-hop following (HIMMEL-329 MVP follows only github refs from a bitbucket README)
- bitbucket PR comment-thread + issue comment ingestion (the MVP bitbucket PR/issue notes carry no comment thread)
- `--deep` component scan of a bitbucket SOURCE repo (component-scan is `gh`-API-only)
- Dynamic destination routing based on verdict mix
- Daily-note backref (Phase 5)
- Promotion candidate (Phase 6)
- Refs-of-refs (hop ≥2)
- Batch input (`@file-of-urls.txt`)
- Reverse-chain lookup

Each is a separate ticket under LUNA-5 (file as sub-tasks before starting v2).
