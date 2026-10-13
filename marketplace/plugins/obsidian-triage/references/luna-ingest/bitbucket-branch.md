<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

## Bitbucket branch — bitbucket.org URLs (HIMMEL-329)

When the URL host is `bitbucket.org`, run THIS branch instead of the github
Phases 1–4 / issue branch. It dispatches to the himmel **bitbucket CLI** —
`node <himmel-root>/scripts/bitbucket/dist/index.js <verb> --repo <ws>/<repo>`
— the `gh` analogue for Bitbucket Cloud. `<himmel-root>` is the himmel primary
checkout; the CLI's `dist/` is gitignored, so it must be built once
(`cd scripts/bitbucket && npm i && npm run build`). Auth comes from the repo-root
env file (`BITBUCKET_EMAIL` / `BITBUCKET_API_TOKEN`); a missing build or missing
creds surfaces as a CLI error → rc=2 (env unusable).

**B-0 — Parse + route.** Strip protocol/query/fragment, then:
- `bitbucket.org/<ws>/<repo>/pull-requests/<n>` → **B-PR** sub-branch.
- `bitbucket.org/<ws>/<repo>/issues/<n>` → **B-issue** sub-branch.
- otherwise (`/<ws>/<repo>`, optionally `/src/<branch>/…`) → **B-repo** sub-branch.

Extract `<ws>/<repo>` by stripping any `/src/…`, `/pull-requests/…`, `/issues/…`
suffix and a trailing `/`. Validate `<ws>/<repo>` with the **same** Phase 1
regex (`^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$`, leading-char
rule rejecting `.`/`..`); else rc=1. The CLI receives it verbatim via `--repo`.

### B-repo — repository ingest

**B-repo-1 Fetch.** `bitbucket repo get --repo <ws>/<repo>` → JSON `{name,
full_name, description, language, default_branch, url, updated_on, is_private,
readme}`. CLI rc≠0 (network / auth / repo 404) → **rc=5**, nothing written
(same contract as github Phase 1 source-fetch failure). `readme: null` (no
`README.md` on the default branch) → record `README: missing`.

**B-repo-1.5 Safety pre-filter.** Run the **Phase 1.5** algorithm unchanged over
`name`, `description`, and the first 8 KB of `readme`. Bitbucket has **no
`topics[]`** — skip that field. Same rc=6 / `--allow-unsafe` semantics and the
same `safety_flag` propagation.

**B-repo-2 Reference extraction + classification.** Write `readme` to a temp file
and run the **existing Phase 2 + Phase 3 unchanged** — they extract `github.com`
refs and classify them via `gh api`. github refs in a Bitbucket README are the
common, supported case. **bitbucket.org refs are NOT followed in MVP**
(BB→BB ref-following is a v2 follow-up): extract them separately
(`grep -oE 'https://bitbucket\.org/[^ )]+'`) and list them under § Open questions
as `bitbucket.org refs not followed (HIMMEL-329 MVP — v2 follow-up)`. `--limit`
applies to the github refs as usual.

**B-repo-3 Trust tier (bitbucket variant).** Bitbucket Cloud exposes **no
`stargazers_count`**. Apply the Phase 4 "Trust-tier auto-classification" rules
with these deltas:
- rule 0 (safety short-circuit), rule 1 (`anthropic-official`), rule 2
  (`known-author`, owner = `<ws>` lowercased) — **unchanged**.
- rule 3 (`community-active`) — **cannot fire** (no star signal) → skip it.
- rule 4 (`community-thin`) — default for any non-allowlisted owner.

`trust_tier_reason` for the rule-4 case: `bitbucket: no star signal,
updated_on=<YYYY-MM-DD> → community-thin`.

**B-repo-4 Synthesis.** Write the **same Phase 4 note shape** under
`<vault>/<dest>/<ws>-<repo>.md` (same slugify + path-safety invariant + rc=3 on
existing), with these frontmatter deltas:
- `source_type: bitbucket` (not `github`).
- **Omit `stars:` and `topics:`** — no Bitbucket equivalent; do NOT emit a fake
  `0` / empty list.
- `language:` from `repo get`; `license: unknown` (`repo get` returns no SPDX).
- `tags:` — first tag is `bitbucket` (parallel to github's first-tag `github`);
  since there are no `topics[]`, infer 2–4 domain tags from name + description +
  README per the Tags-derivation **rule 3** fallback (prefer the vault's existing
  tag vocabulary). Minimum 2 tags.
- The `## Referenced repos (1-hop)` section lists the **github** refs only;
  the `## Open questions` section carries the unfollowed-bitbucket-refs note.
- **Omit `upstream_commit`** (HIMMEL-3055) — `bitbucket repo get` returns no default-branch HEAD
  SHA and there is no cheap CLI call for one; do NOT emit a fake or stale value. `upstream_pushed_at`
  comes from `updated_on`; `readme_sha256` hashes `readme` the same way as the github path (omit if
  `readme: missing`); `ingest_spec_version` and `ingest_scope` are populated the same as Phase 4.

`--deep` source-scan is **skipped on a Bitbucket source** (the LUNA-57
`component-scan.mjs` is `gh`-API-only and cannot scan a Bitbucket repo) — emit a
one-line stderr warn and continue; integrate/take-parts **github** refs are still
scanned. `--research` (LUNA-64) is forge-agnostic (WebSearch) and runs normally.

### B-PR — pull-request ingest

`bitbucket.org/<ws>/<repo>/pull-requests/<n>`. Flat fetch → write (like the
github issue branch — a PR has no README + ref pool).

**B-PR-1 Fetch.** `bitbucket pr get <n> --repo <ws>/<repo>` → `{id, title, state,
description, author, source_branch, destination_branch, url, created_on,
updated_on}`. CLI rc≠0 → rc=5, nothing written. Also fetch `bitbucket repo get
--repo <ws>/<repo>` for the trust-tier owner input; if THAT fails but the PR
fetch succeeded, continue with `trust_tier: community-thin`,
`trust_tier_reason: repo metadata unavailable → conservative default`.

**B-PR-2 Safety pre-filter.** Phase 1.5 algorithm over PR `title` +
`description` (first 8 KB). Same rc=6 / `--allow-unsafe` semantics.

**B-PR-3 Write.** `<vault>/<dest>/<ws>-<repo>-pr-<n>.md` (slugify `<ws>-<repo>`;
rc=3 if it exists). Compute `trust_tier` from the repo owner via B-repo-3.
Frontmatter mirrors the github issue note with `source_type: bitbucket-pr`,
`pr_state`, `pr_author`, `source_branch`, `destination_branch`; `tags:`
`bitbucket`, `bitbucket-pr`, then up to 3 inferred domain tags. Body:

```markdown
# <repo> PR #<n> — <title>

## Source
[<ws>/<repo> PR #<n>](<url>) — <state>, opened <created_on> by @<author>; <source_branch> → <destination_branch>

## Summary
<3-5 bullet TL;DR of what the PR changes, derived from title + description>

## Description
<the PR description verbatim as markdown; `_(no description)_` if empty>

## Audit log
- API calls: <1-or-2>
- Trust tier: <tier> (<reason>)
- Safety flag: <term-or-none>
```

### B-issue — issue ingest

`bitbucket.org/<ws>/<repo>/issues/<n>`.

**B-issue-1 Fetch.** `bitbucket issue get <n> --repo <ws>/<repo>` → `{id, title,
state, kind, content, reporter, url, created_on, updated_on}`. The CLI exits **3**
when the issue tracker is disabled OR the issue is gone (404) → map to **rc=5**,
nothing written (parallel to the github issue branch's 404 → rc=5). Other CLI
rc≠0 → rc=2. Also fetch `repo get` for the trust-tier owner (same degrade as
B-PR-1 on failure).

**B-issue-2 Safety pre-filter.** Phase 1.5 over issue `title` + `content`
(first 8 KB). Same rc=6 / `--allow-unsafe` semantics.

**B-issue-3 Write.** `<vault>/<dest>/<ws>-<repo>-issue-<n>.md` (rc=3 if exists).
Frontmatter mirrors the github issue note with `source_type: bitbucket-issue`,
`issue_state`, `issue_kind`, `issue_reporter`; `tags:` `bitbucket`,
`bitbucket-issue`, then up to 3 inferred domain tags. Body mirrors the github
issue note's `# … issue #<n>`, `## Source`, `## Summary`, `## Issue body`,
`## Audit log` (drop `## Key comments` — the MVP bitbucket issue read fetches no
comment thread; note that under § Audit log as `Comments: not fetched (MVP)`).

The harvest-clips dispatch contract is unchanged: a bitbucket.org clip dispatched
here now lands the matching note, and the rc=3 dedup invariant holds (back-ref
the existing `<ws>-<repo>[-pr|-issue]-<n>` note).
