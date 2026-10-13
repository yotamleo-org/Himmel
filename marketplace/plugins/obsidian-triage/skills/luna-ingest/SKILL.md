---
name: luna-ingest
description: Use when ingesting a github or bitbucket.org repo / issue / PR URL into the luna vault as a note. /luna-ingest.
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

Normalize to `<owner>/<repo>`:

```bash
# strip protocol, trim trailing /, strip /tree/* and /blob/* suffix
owner_repo=$(printf '%s' "$URL" | sed -E 's|^https?://github\.com/||; s|/(tree|blob)/.*$||; s|/$||')
```

Validate it matches `^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$` — the leading char rejects `.` or `..` as owner or repo (which would otherwise survive the looser `[A-Za-z0-9_.-]+` form and let `gh api "repos/../foo"` flow through). Else rc=1.

Fetch:

```bash
gh api "repos/${owner_repo}" --jq '{name, full_name, description, html_url, language, stargazers_count, topics, default_branch, pushed_at, license: .license.spdx_id}' > /tmp/luna-ingest-meta.$$.json
```

If `gh api` fails (rc≠0): exit 2 with the stderr inlined.

**Identity (HIMMEL-3055).** Fetch the default-branch HEAD SHA — this is `upstream_commit` in the synthesis, the field that lets later tooling tell whether upstream moved since ingest without re-fetching the whole repo:

```bash
default_branch=$(jq -r '.default_branch' /tmp/luna-ingest-meta.$$.json)
gh api "repos/${owner_repo}/commits/${default_branch}" --jq '.sha' > /tmp/luna-ingest-commit.$$.txt
```

On failure, continue with `upstream_commit` omitted from the synthesis rather than failing the ingest — the repo metadata and README are still useful without it.

Read README via:

```bash
# Strip the API's embedded newlines BEFORE base64-decoding. macOS
# base64 errors on newline-padded input without -i; GNU silently
# accepts it. Trim makes the decode portable across both.
gh api "repos/${owner_repo}/readme" --jq '.content' \
  | tr -d '\n' \
  | base64 -d > /tmp/luna-ingest-readme.$$.md
```

If the README endpoint returns 404 (some repos have none): proceed with an empty README; record `README: missing` in the synthesis; omit `readme_sha256` (a hash of an absent README is an absent field, not a hash of empty bytes).

Otherwise hash the decoded bytes for `readme_sha256` — this is the identity check for "did the README change since ingest", replacing the byte-count-in-prose proxy the audit log used before:

```bash
sha256sum /tmp/luna-ingest-readme.$$.md | cut -d' ' -f1   # macOS: shasum -a 256
```

## Phase 1.5 — Safety pre-filter (LUNA-43)

Before continuing to Phase 2, scan the metadata captured in Phase 1 (`name`, `description`, `topics[]`) plus the decoded README for red-flag keywords.

**Matching algorithm (single canonical form — pin this exactly, no variants):**

1. **Normalize the searched field first.** For each of `name`, `description`, joined `topics[]`, and the first 8 KB of decoded README (interpret 8 KB as 8192 *bytes* of the UTF-8-encoded slice — truncate at a byte boundary, do not split a multibyte rune), lowercase the text and replace any run of one-or-more `[-_\s]+` characters with a single hyphen (`-`). This canonicalises `red_team`, `red team`, `red--team`, and `Red-Team` all to `red-team`.
2. **Apply each rule below as a case-insensitive substring search** against the normalized text. Whichever rule's substring (or AND-pair) appears first → set `safety_flag: <matched-term>` (use the first-listed canonical form from the rule). Word-boundary regex (`\b`) is NOT used — substring after normalization is the only form.
3. **AND-pair rules require both substrings to appear within 80 normalized characters** of each other in the same field (e.g. `red-team .{0,80} agent` or `agent .{0,80} red-team`).

**Single-term rules (substring matches alone trigger):**

- `abliteration` (also catches `abliterated`, `abliterationist`)
- `censorship-removal`
- `uncensored-model`
- `autonomous-hacking`
- `auto-hack`
- `exploit-kit`
- `malware-as-a-service`
- `maas-toolkit`

**AND-pair rules (BOTH substrings must appear in the same field within 80 chars):**

- `red-team` AND (`agent` OR `framework`) — avoids false-positives on legit security-research repos that mention red-team work
- `jailbreak` AND (`model` OR `llm` OR `bypass-safety`) — avoids false-positives on iOS jailbreak tooling

Match rule: if ANY of the rules above (or operator-curated additions, see below) trigger against `name` OR `description` OR `topics[]` OR the first 8 KB of decoded README → set `safety_flag: <matched-term>` (use the first-listed canonical form of the matched rule, e.g. `red-team+agent` for the AND-pair) and one of:

- Without `--allow-unsafe`: exit rc=6 with message `ERR luna-ingest: safety pre-filter matched <term> in <field>. Pass --allow-unsafe to ingest with safety_flag annotation, or skip this repo.` — no synthesis written.
- With `--allow-unsafe`: continue to Phase 2 but propagate `safety_flag` into the synthesis frontmatter so downstream readers (and `/synthesize-clips`) know to treat the page as `unknown-risk` regardless of license / star count.

**Operator customisation:** the keyword list above is the LUNA-43 default. Operators can extend it by setting `LUNA_INGEST_SAFETY_KEYWORDS=<comma-separated terms>` in their shell — additions ONLY (no removal of defaults). Removed defaults require an explicit SKILL.md edit + PR review, by design.

Log line: `[safety] matched=<term> field=<name|description|topics|readme> action=<refused|annotated>` to stderr regardless of action.

## Phase 2 — Reference extraction

Parse the README for github URLs that point at OTHER repos:

```bash
grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?' /tmp/luna-ingest-readme.$$.md \
  | sed -E 's|^https://github\.com/||; s|\.git$||; s|/$||' \
  | sort -u \
  | grep -v "^${owner_repo}$" \
  > /tmp/luna-ingest-refs.$$.txt || true
```

The `(\.git)?` suffix on the regex plus the `s|\.git$||` substitution dedupes `<owner>/<repo>` with `<owner>/<repo>.git` (a common README link form).

Strip refs whose path has more than one `/` (sub-paths inside the same repo — keep the bare owner/repo only), AND reject any segment that is purely `.` or `..` (would survive the looser ref regex and lead to `gh api repos/../something` calls that pollute the audit log):

```bash
awk -F/ 'NF==2 && $1 !~ /^\.+$/ && $2 !~ /^\.+$/' /tmp/luna-ingest-refs.$$.txt > /tmp/luna-ingest-refs.clean.$$.txt
```

Apply the `--limit` cap (the explicit `--limit <N>` if passed, else the default `250`). If more refs exist than the cap, log "tail-skipped: N refs" in the synthesis under § Open questions. With the default `250`, a tail-skip now signals a genuinely huge meta-list (re-run with an explicit higher `--limit`), not the old routine `[1,25]`-clamp truncation.

**LUNA-7 size telemetry:** measure the decoded README size with `wc -c < /tmp/luna-ingest-readme.$$.md` and record it in the synthesis § Audit log. If the size exceeds **512 KB**, emit a single stderr warning before Phase 3 starts:

```
WARN luna-ingest: README is <N> KB (>512 KB threshold). --limit caps API-call count, NOT text size; large monorepo/awesome-list READMEs may produce a noisy ref pool.
```

Continue regardless — the warning is informational. `--limit` already bounds the per-ref API-call cost; the size warning just flags "expect noisy classification" for the operator.

## Phase 3 — Per-ref classification

For each ref `<o>/<r>` in the cleaned ref list:

1. Fetch lightweight metadata: `gh api "repos/${ref}" --jq '{description, language, stargazers_count, pushed_at, topics, license: .license.spdx_id}'`. On failure, distinguish the failure class (LUNA-6):
   - **404 / "Not Found"** → verdict `skip`, `verdict_reason: ref_not_found`. Continue scanning the rest.
   - **403 / 429 / "rate limit" / "API rate limit exceeded"** → verdict `api_failure`, `verdict_reason: rate_limited`. Continue scanning; the run will exit rc=4 at the end so the operator knows to retry, but partial progress is preserved.
   - Other network/auth errors → verdict `api_failure`, `verdict_reason: <stderr-short>`. Continue; exit rc=4 at end.

   `api_failure` is NOT one of `integrate/take-parts/inspire/skip` — it's a SEPARATE verdict that exists only to keep partial runs honest. Refs with `verdict: api_failure` go under § Unclassified (transient) in the synthesis, never § Skip (which implies a deliberate heuristic decision).
2. Assign a verdict per these heuristics (apply in order; first match wins):
   - `integrate` — the ref appears in a parent README section titled "Dependencies", "Requires", "Built on", "Uses" OR the topics overlap explicitly with a "package" or "library" tag AND the ref has an SPDX license that's MIT / Apache-2.0 / BSD-3-Clause (permissive).
   - `take-parts` — the ref appears under "Related", "Inspired by", "See also", "Forked from" sections AND the ref has ≥10 stars AND its language matches one of the parent's top 2 languages.
   - `inspire` — the ref appears under "Reading", "Articles", "Background", "Prior art" OR the ref's language differs from the parent's primary language but its topics overlap.
   - `skip` — everything else, OR the ref's `pushed_at` is more than 24 months old (stale), OR license is restrictive (AGPL, BSL) and the parent suggests integration.
3. Capture a 1-3 sentence rationale citing which README section / topic / license / staleness drove the verdict.
4. Record confidence `0.0–1.0`: high (≥0.8) when section heading is unambiguous; medium (0.6–0.8) when section is implied by surrounding prose; low (<0.6) when no section context exists (verdict is best-guess from topics/license alone).
5. Refs with confidence <0.6 are listed in the synthesis under § Weak refs (appendix) instead of the main § Referenced repos section.

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

- 0: synthesized + written (or dry-run completed) — all refs classified
- 1: usage / input error (bad URL, missing required arg)
- 2: env unusable (vault not found, gh api / bitbucket CLI unreachable or unbuilt for source repo, dest category invalid)
- 3: target file exists (no overwrite in MVP)
- 4: **partial run** — synthesis written but ≥1 ref was marked `api_failure` (rate-limit / network / auth). Re-run later to retry the failed refs; the dedup-by-existing-file invariant means the existing synthesis stays unless `--force`. (LUNA-6)
- 4 (extended): also returned when `--deep` component scan reported ≥1
  component-fetch failure (partial inventory). Synthesis is still written.
- 5: source fetch failed — `gh api` (github Phase 1) or the `bitbucket` CLI (HIMMEL-329 Bitbucket branch) failed for the SOURCE repo / PR / issue (network / rate limit / 404 / issues-disabled) — nothing written, retry the whole call
- 6: **safety-blocked** — Phase 1.5 matched a red-flag keyword in name/description/topics/README (github) or name/description/README (bitbucket — no topics), and `--allow-unsafe` was NOT passed. Nothing written. Re-run with `--allow-unsafe` to ingest with `safety_flag` annotation (which exits rc=0, NOT rc=6, on success — `--allow-unsafe` plus a match is a known-risk acknowledged ingest, not an error). (LUNA-43)

`--research` (LUNA-64) never changes the exit code: a web-search failure
degrades gracefully (annotated section + § Open questions note) and the
synthesis is still written at the rc the rest of the run would have produced.

## Out of scope (v2 follow-ups)

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
