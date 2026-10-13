<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

## Issue branch — github issue URLs (HIMMEL-239)

When `<github-url>` matches `^https?://(www\.)?github\.com/<owner>/<repo>/issues/(\d+)$` (query/fragment stripped first), run THIS branch instead of Phases 1–3.6 and the Phase 4 repo synthesis. The repo phases assume a README + 1-hop ref pool; an issue has neither, so this branch is deliberately flat: fetch → safety-filter → write. `--deep`, `--research`, and `--limit` are repo-only flags — if passed alongside an issue URL, ignore them with one stderr line: `WARN luna-ingest: --deep/--research/--limit are repo-only; ignored for issue URLs.`

**I-1 — Fetch.** Extract `<owner>/<repo>` + `<n>`. Validate `<owner>/<repo>` with the same Phase 1 regex (leading-char rule included). Then:

```bash
gh api "repos/${owner_repo}/issues/${n}" --jq '{title, state, body, user: .user.login, labels: [.labels[].name], comments, created_at, closed_at, html_url}'
```

- 404 → rc=5, nothing written (issue deleted or repo private/renamed).
- Other `gh api` failure → rc=2 with stderr inlined.
- Also fetch repo metadata (`gh api "repos/${owner_repo}"` — same Phase 1 jq) for the trust-tier inputs. If THIS call fails but the issue call succeeded, continue with `trust_tier: community-thin`, `trust_tier_reason: repo metadata unavailable → conservative default`.

Comments (skip when the issue's `comments` count is 0):

```bash
gh api "repos/${owner_repo}/issues/${n}/comments" --paginate --jq '.[] | {user: .user.login, created_at, body}'
```

Cap at the **30 most-reacted-or-earliest** comments (take the first 30 returned; the API returns oldest-first). If more existed, record `tail-skipped: <N-30> comments` in § Audit log.

**I-2 — Safety pre-filter.** Run the Phase 1.5 algorithm unchanged over: issue `title`, joined `labels[]`, and the first 8 KB of the issue `body`. Same rc=6 / `--allow-unsafe` semantics.

**I-3 — Write.** Destination: `<vault>/<dest-category>/<owner>-<repo>-issue-<n>.md` (Phase 4 slugify on `<owner>-<repo>`; same path-safety invariant; rc=3 if the file exists). Compute `trust_tier` from the REPO owner via the Phase 4 rules (the issue author does not affect the tier). Structure:

```markdown
---
type: tech-ingest
source: <issue html_url>
source_type: github-issue
ingested_at: <UTC ISO-8601>
ingest_spec_version: 1   # HIMMEL-3055 — see Phase 4 "Identity" fields; same versioning rule applies here
# last_revalidated OMITTED on a fresh ingest (HIMMEL-3055) — see Phase 4 for the full rule
ingest_command: /luna-ingest
issue_state: <open|closed>
issue_author: <user.login>
issue_labels:
  - <label>
comment_count: <N>
tags:                # HIMMEL-247: REQUIRED — Phase 4 "Tags derivation", issue variant
  - github
  - github-issue
  - <tag>
trust_tier: <tier>
trust_tier_reason: <text>
safety_flag: <term-or-blank>
---

# <repo-name> issue #<n> — <issue title>

## Source

[<owner>/<repo>#<n>](<html_url>) — <state>, opened <created_at> by @<user.login><", closed <closed_at>" when closed>

## Summary

<3-5 bullet TL;DR: what the issue reports, root cause if identified, resolution state>

## Issue body

<the issue body as markdown, verbatim — trim only trailing template boilerplate>

## Key comments

<for each kept comment with substance (skip "+1"/"same here" noise): `> **@<user>** · <created_at>` followed by the comment body or its load-bearing excerpt. If none: `_(no substantive comments)_`>

## Audit log

- Comments fetched: <K> of <N> (tail-skipped: <T>)
- API calls: <2-or-3>
- Trust tier: <tier> (<reason>)
- Safety flag: <term-or-none>
```

Exit codes are the standard set (0 written, 2 env, 3 exists, 5 source fetch failed, 6 safety-blocked). The harvest-clips github dispatch needs no change: issue clips it dispatches here now land an issue note, and its rc=3 dedup contract holds (back-reference the existing `<owner>-<repo>-issue-<n>` note).
