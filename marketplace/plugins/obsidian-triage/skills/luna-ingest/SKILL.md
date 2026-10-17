---
name: luna-ingest
description: Save GitHub repositories or issues, or Bitbucket repositories, issues or PRs, as structured luna notes.
---

# luna-ingest — chain-following triage (LUNA-5 Wedge B, MVP; skill conversion LUNA-9)

You are running LUNA-5 Wedge B. Take a github OR bitbucket.org URL, follow its README references one hop (github sources only — see below), classify each, and produce a structured tech-ref note in the luna vault.

**Scope:** github + bitbucket.org URLs. Twitter (`x.com/...`) and article URLs raise an explicit "not yet" error and point at LUNA-5 v2.
- **github.com:** repo URLs run Phases 1–4; issue URLs (`/issues/<n>`) take the issue branch (HIMMEL-239); PR (`/pull/<n>`) and discussion URLs remain out of scope.
- **bitbucket.org (HIMMEL-329):** repo, PR (`/pull-requests/<n>`), and issue (`/issues/<n>`) URLs take the **Bitbucket branch** below. They dispatch to the himmel bitbucket CLI (`node scripts/bitbucket/dist/index.js …`) instead of `gh`.

**Forge routing (HIMMEL-329):** the URL **host** selects the path — parallel to how the dev-loop routes on the git origin. `github.com` (or bare `<owner>/<repo>`) → the github Phases below, unchanged. `bitbucket.org` → the **Bitbucket branch**. Everything in Phases 1–4 and the issue branch is the github path; the Bitbucket branch reuses the shared Phase 1.5 safety pre-filter and Phase 3/4 heuristics but swaps the fetch transport.

**Invocation surfaces (LUNA-9):**

- **User prompt:** `/luna-ingest <github-url> [--vault <path>] [--dest <category>] [--limit <N>] [--deep] [--research] [--dry-run]` — handled by the thin wrapper at `.claude/commands/luna-ingest.md` which delegates here.
- **Programmatic Skill-tool dispatch (HIMMEL-128 compliant — no headless claude):** `Skill { skill: "obsidian-triage:luna-ingest", args: "<github-url> [<flags...>]" }` from inside another runbook (e.g. `/harvest-clips` github-URL branch).

Both surfaces feed the same argument shape into the runbook below. Wherever this document references `$ARGUMENTS`, treat it as the literal arg string supplied via either invocation path.

## Inputs

`$ARGUMENTS` is `<url> [--vault <path>] [--dest <category>] [--limit <N>] [--dry-run]`.

Parse:
- `<url>` — required. Accepted shapes:
  - `https://github.com/<owner>/<repo>` (+ `/`, `/tree/<branch>`, `/blob/<branch>/<path>`)
  - `https://github.com/<owner>/<repo>/issues/<n>` — routes to the github issue branch (HIMMEL-239)
  - bare `<owner>/<repo>` — treated as github
  - `https://bitbucket.org/<ws>/<repo>` (+ `/`, `/src/<branch>/...`) — routes to the **Bitbucket branch** (HIMMEL-329)
  - `https://bitbucket.org/<ws>/<repo>/pull-requests/<n>` — Bitbucket PR branch
  - `https://bitbucket.org/<ws>/<repo>/issues/<n>` — Bitbucket issue branch
- `--vault <path>` — luna vault root. Default: `$HOME/Documents/luna`. Refuse with rc=2 if the dir does not exist OR is not an Obsidian vault (no `.obsidian/` dir).
- `--dest <category>` — vault destination category override. Default: `30-Resources/Tech`. Validate against the vault's PARA folders (`00-Inbox`, `10-Projects/*`, `20-Areas/*`, `30-Resources/Tech`, `30-Resources/Concepts`, `30-Resources/Components`). Anything else → rc=2.
- `--limit <N>` — max 1-hop refs to follow. Default `250` (LUNA-92: capture all refs by default — the prior `[1,25]` clamp left high-fanout awesome-lists partial and silently dropped sources). No upper clamp; reject `< 1` with rc=1. `250` is a generous safety ceiling for unattended `harvest-clips` dispatch (which passes no `--limit`), not a quality cap — the largest list we have hit is 188 refs. Pass `--limit <N>` to bound a noisy meta-list downward. The LUNA-6 rate-limit contract (api_failure verdict + rc=4 resume) is the backstop if a pathological list exceeds the gh-api hourly budget.
- `--dry-run` — print what would be written + verdicts, touch no files. rc=0.
- `--allow-unsafe` — opt-in flag to ingest a repo flagged by the LUNA-43 safety-keyword pre-filter (Phase 1.5). Without this flag, repos whose name/description/topics match red-flag terms exit rc=6 before fetching the README.
- `--repo <ws/repo>` is NOT a luna-ingest flag — it is the bitbucket CLI's own override, set internally by the Bitbucket branch from the parsed URL. Operators pass the bitbucket.org URL, not `--repo`.
- `--deep` — LUNA-57: after classification, run the component scan
  (`tools/component-scan.mjs`) over the source repo (always) and over each
  1-hop ref verdicted `integrate` or `take-parts`. Inventories reusable
  components (skills/commands/agents/tools/plugin manifests) into a
  `## Reusable components` section of the Tech note AND a cross-repo-deduped
  `30-Resources/Components/` library. Off by default (MVP keeps the light path).
- `--components-dir <rel>` — vault-relative Components library root.
  Default `30-Resources/Components`. Only meaningful with `--deep`.
- `--max-components <N>` — per-repo component cap (tail-skip beyond). Default 60.
- `--research` — LUNA-64: after classification, web-research the SOURCE repo
  (maturity/adoption, notable alternatives, known limitations, community
  sentiment, recency) using Claude's own WebSearch/WebFetch tools and inject a
  `## Research enrichment` section into the Tech note. Off by default.
  **Orthogonal to `--deep`** — they enrich different axes (`--deep` = reusable
  components inventoried from the code; `--research` = external context about
  the repo) and may be combined (`--deep --research` runs both). This is the
  lightweight inline path: NO external Python (`research_deep.py`), NO
  Perplexity/Grok keys, NO vault-wide propagation — those belong to the full
  `/research-deep` command, deferred to a later LUNA-64 follow-up. Source repo
  only in MVP (1-hop refs are not researched). The harvest-clips github
  dispatch MUST NOT pass `--research` (cost + scope safety).

Reject `x.com/`, `twitter.com/`, or any host that is neither `github.com` nor `bitbucket.org` with:

```
ERR luna-ingest: only github.com and bitbucket.org URLs supported. Twitter + article inputs ship in LUNA-5 v2.
```

## Issue branch — github issue URLs (HIMMEL-239)

**Read on demand:** When the URL is a github issue URL (`/issues/<n>`) — before doing anything else for it. Read `<plugin>/references/luna-ingest/issue-branch.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Bitbucket branch — bitbucket.org URLs (HIMMEL-329)

**Read on demand:** When the URL host is `bitbucket.org` (repo, PR or issue) — before doing anything else for it. Read `<plugin>/references/luna-ingest/bitbucket-branch.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 1 — Source fetch (github URL)
**Read on demand:** Whenever the source is a github repo URL (every github run); before fetching. Read `<plugin>/references/luna-ingest/phase-1-source-fetch.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 1.5 — Safety pre-filter (LUNA-43)
**Read on demand:** After Phase 1, before Phase 2, on every github run; the matching algorithm and rc=6 behaviour live there. Read `<plugin>/references/luna-ingest/phase-1-5-safety-prefilter.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 2 — Reference extraction
**Read on demand:** When extracting refs from the README (Phase 2) and applying the `--limit` cap and the README-size warning. Read `<plugin>/references/luna-ingest/phase-2-reference-extraction.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 3 — Per-ref classification
**Read on demand:** When classifying each ref (Phase 3): the failure classes, the verdict heuristics and the confidence floor. Read `<plugin>/references/luna-ingest/phase-3-classification.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 3.5 — Deep component scan (LUNA-57, `--deep` only)

**Read on demand:** Only when `--deep` was passed; skip otherwise. Read `<plugin>/references/luna-ingest/phase-3-5-deep-scan.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 3.6 — Research enrichment (LUNA-64, `--research` only)

**Read on demand:** Only when `--research` was passed; skip otherwise. Read `<plugin>/references/luna-ingest/phase-3-6-research.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 4 — Synthesis

Compute a destination path under `<vault>/<dest-category>/<repo-slug>.md` where:
- `<repo-slug>` = lowercase, hyphens, max 60 chars. e.g. `kepano/obsidian-skills` → `kepano-obsidian-skills`. Slugify: replace any non-`[a-z0-9-]` with `-`, collapse repeats, strip leading/trailing `-`.
- If `<dest-category>` was passed via `--dest`, use it verbatim. Else default `30-Resources/Tech`.

**Path safety invariant:** before any Write, canonicalise the resolved destination via `realpath -m` and verify it starts with the canonicalised vault root. Refuse with rc=2 if a `..` traversal or symlink escape would land outside the vault. This guards against malformed `--dest` or weirdly-named refs.

If the target file already exists: refuse with rc=3 unless `--force` was passed (NOT supported in MVP — rc=3 with a hint to delete + retry).

### Trust-tier auto-classification (LUNA-43)

**Read on demand:** Always, in Phase 4 before the Write step, to compute `trust_tier` and `trust_tier_reason` (the Bitbucket branch's B-repo-3 deltas and the issue branch's I-3 also apply these rules). Read `<plugin>/references/luna-ingest/trust-tier.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

### Tags derivation (HIMMEL-247)

**Read on demand:** Always, in Phase 4 before building the frontmatter (every emitted note needs `tags:`). Read `<plugin>/references/luna-ingest/tags-derivation.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

```markdown
---
type: tech-ingest
source: <URL>
source_type: github
ingested_at: <UTC ISO-8601>
ingest_spec_version: 1        # HIMMEL-3055: version of OUR OWN extraction rules, independent of upstream movement. Bump this when the extraction rules change so old notes are known-truncated/known-stale on our side even if upstream hasn't moved (e.g. notes written before the --limit/tail-skip work are truncated and nothing else says so).
ingest_scope:                 # HIMMEL-3055: machine-readable, not a line in the body
  limit: <effective --limit used for this ingest>
  tail_skipped: <count, 0 if none>
upstream_commit: <default-branch HEAD SHA at fetch time, or omit on fetch failure>   # HIMMEL-3055
upstream_pushed_at: <repo pushed_at, ISO-8601>   # HIMMEL-3055: parseable duplicate of the value also folded into trust_tier_reason prose below
readme_sha256: <sha256 of the decoded README bytes, or omit if README missing>   # HIMMEL-3055: replaces README-byte-count as the change-detection proxy
# last_revalidated is OMITTED here — never default it to ingested_at (HIMMEL-3055). "Never
# checked" and "checked, unchanged" must not write the same value. It is written ONLY when a
# real revalidation sweep runs later (see "Revalidation invariant" below), paired with a
# revalidation_delta line.
ingest_command: /luna-ingest
verdict_summary:
  integrate: <count>
  take-parts: <count>
  inspire: <count>
  skip: <count>
  api_failure: <count>   # LUNA-6: refs we couldn't classify due to rate-limit / network / auth. NON-ZERO means partial run.
license: <SPDX or unknown>
stars: <N>
language: <primary>
topics:
  - <topic>
tags:                       # HIMMEL-247: REQUIRED — never omit. Derivation rules in "Tags derivation" above.
  - github
  - <tag>
trust_tier: <tier>          # LUNA-43: anthropic-official | known-author | community-active | community-thin | unknown-risk
trust_tier_reason: <text>   # LUNA-43: 1-line justification (e.g. "owner=anthropics → anthropic-official"; "owner=kepano in allowlist → known-author"; "stargazers_count=12, pushed_at=2025-04-01 → community-thin"). Field name is `owner=` (the lowercased value extracted in trust-tier rule logic), matching the trust-tier rule wording — NOT `owner_org=`.
safety_flag: <term-or-blank> # LUNA-43: blank if Phase 1.5 found no red-flag terms; matched term otherwise. NON-BLANK forces trust_tier=unknown-risk via rule 0 short-circuit in trust-tier classification.
research_enriched: <true-or-omit>  # LUNA-64: set true ONLY when --research ran (Phase 3.6) AND produced real findings. Omit the field entirely when --research was not passed OR enrichment degraded (dry-run short-circuit / web-failure placeholder) — a degraded note must not advertise itself as enriched to downstream readers (/synthesize-clips, revalidation tooling).
---

# <repo-name>

## Source

[<full_name>](<URL>) — <description from gh api>

- **Language:** <language> | **Stars:** <N> | **License:** <SPDX>
- **Last push:** <pushed_at>
- **Topics:** <topics joined by ", ">

## Summary

<3-5 bullet TL;DR derived from README + repo metadata>

## Referenced repos (1-hop)

<for each ref with confidence ≥0.6, sorted by verdict severity integrate > take-parts > inspire > skip>

### <ref-full-name> — <verdict>

- URL: https://github.com/<ref>
- Language: <lang> | Stars: <N> | License: <SPDX>
- **Rationale:** <1-3 sentences>
<if verdict == take-parts>
- **What to lift:** <file/path/area to inspect first>
</if>

## Research enrichment

<Only present when --research was passed (Phase 3.6). 4–8 bullets synthesizing
the WebSearch findings about the SOURCE repo — maturity/adoption, notable
alternatives, known limitations, community sentiment. Each external claim ends
with a recency marker + source URL inline, e.g.:
`- Actively maintained; v2.3 released as of Mar 2026 ([release notes](https://…)).`
On dry-run, render `_(dry-run — research not executed)_`. On web failure,
render `_(research enrichment requested but web search returned no usable
results)_`. If --research was NOT passed, omit this section entirely.>

## Reusable components

<Only present when --deep was passed. Compose from the source-repo scan
JSON. For each component in `components[]`, one bullet:
`- **<name>** (<type>) — <description>. _Reuse:_ <1-2 line how-to-rephrase
for himmel/luna — YOUR judgment from the description + type>.`
Then, for each integrate/take-parts ref that was scanned, one summary line:
`- _Ref <o>/<r>: N components inventoried → see [[30-Resources/Components/]]._`
If --deep was NOT passed, omit this section entirely.>

## Weak refs (low-confidence, appendix)

<for each ref with confidence <0.6 — same structure, condensed>

## Unclassified (transient — re-run to retry)

<for each ref with `verdict: api_failure` — list URL + verdict_reason. LUNA-6: surfaces rate-limited / network-failed refs distinctly from § Skip so operator knows what to retry. Empty section reads `_(none — all refs classified)_`.>

## Action items

<extracted from README headings like "TODO", "Roadmap", "Known issues" — convert each to `- [ ] <item>`. If none found: `_(none — repo README has no TODO/Roadmap section)_`>

## Open questions

<gaps the chain-follow could not resolve. Always include: "Verify integrate-verdict refs by reading their root README before taking a dep on any of them.">

## Audit log

- Refs scanned: <N>
- Refs above confidence floor (0.6): <K>
- Refs marked api_failure (LUNA-6): <F> (if >0: rc=4; re-run to retry classification)
- Tail-skipped: <T> (set if more refs existed than --limit)
- API calls: <N+2> (HIMMEL-3055: +1 over the prior count for the `upstream_commit` fetch)
- README size: <bytes> (LUNA-7: warn if >512 KB; --limit caps API-call count, not text size)
- Trust tier: <tier> (<reason>)   (LUNA-43)
- Safety flag: <term-or-none>   (LUNA-43: non-blank value reached rc=6 unless --allow-unsafe; document the term in this row regardless)
```

### Revalidation invariant (HIMMEL-3055)

**Read on demand:** Only when writing or reviewing a `## Re-validation` section; a fresh ingest never does. Read `<plugin>/references/luna-ingest/revalidation-invariant.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

### Semantic layer (HIMMEL-3055 — schema defined, NOT yet populated)

**Read on demand:** Only when touching the not-yet-populated semantic fields (`concepts`, `solves`, `maps_to`, `value_tier`, `value_reason`); this MVP never writes them. Read `<plugin>/references/luna-ingest/semantic-layer.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Phase 5 — Daily-note backref (deferred to v2)

MVP does NOT touch the daily note. v2 picks up the obsidian-triage Phase 5 dedup-by-backreference contract.

## Phase 6 — Promotion candidate (deferred to v2)

MVP does NOT write `00-Inbox/promote-<slug>.md`. v2 adds this when any verdict ∈ {integrate, take-parts}.

## Dry-run mode

When `--dry-run` is passed:
- Print "DRY luna-ingest: would write <full-path>"
- Print the synthesized markdown body to stdout, prefixed with 4 spaces
- Print per-ref verdict summary table
- With `--research`: skip the Phase 3.6 web queries (print `DRY luna-ingest:
  would run research enrichment for <owner_repo>`); the `## Research
  enrichment` section renders `_(dry-run — research not executed)_`.
- rc=0, touch no files in the vault

## Exit codes

**Read on demand:** Before choosing or interpreting an exit code (0 ok, 1 usage, 2 env, 3 target exists, 4 partial, 5 source fetch failed, 6 safety-blocked). Read `<plugin>/references/luna-ingest/exit-codes.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.

## Out of scope (v2 follow-ups)

**Read on demand:** Only when asked whether an input form or feature is supported. Read `<plugin>/references/luna-ingest/out-of-scope.md` (`<plugin>` is the plugin root, two directories above this skill's directory) in full and follow it exactly as if it were inlined here; do not work from memory of it.
