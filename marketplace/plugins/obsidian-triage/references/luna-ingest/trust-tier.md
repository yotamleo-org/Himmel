<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Trust-tier auto-classification (LUNA-43)

Compute the synthesis's `trust_tier` field from the source repo's `owner` (extracted as `owner = owner_repo.split('/')[0]`, then lowercased) before the Write step. All allowlist + literal comparisons in this section are **case-insensitive** — both sides lowercased before equality.

**Apply rules in this order, top-to-bottom, first match wins — do NOT reorder. Every rule short-circuits all later rules; rules 3 and 4 are NOT mutually exclusive on their own (both could match a given repo), but the "first match wins" semantic resolves the ambiguity in favour of rule 3 when both fire.**

0. **Safety short-circuit — `unknown-risk`.** If `safety_flag` (populated by Phase 1.5) is non-blank → `trust_tier = unknown-risk`, skip rules 1-4. This MUST execute before the owner-based rules so the audit-log `Trust tier: unknown-risk (reason: safety_flag=<term>)` is consistent regardless of who owns the repo.
1. **`anthropic-official`** — lowercased `owner` ∈ {`anthropics`, `anthropic`}.
2. **`known-author`** — lowercased `owner` ∈ the curated allowlist below. Default allowlist (all entries already lowercase):
   - Individual authors: `kepano`, `mattpocock`, `karpathy`, `obra`, `wshobson`, `everyinc`, `nizos`, `letta-ai`
   - Orgs: `microsoft`, `vercel`, `vercel-labs`, `github`, `browser-use`, `hkuds`, `smtg-ai`, `nousresearch`, `zilliztech`, `topoteretes`, `mksglu`
   - Operator extension: `LUNA_INGEST_TRUSTED_AUTHORS=<comma-separated owners>` adds to the allowlist (additions are lowercased before comparison; no removals).
3. **`community-active`** — none of the above matched AND `stargazers_count ≥ 100` AND `pushed_at` within the last 180 days.
4. **`community-thin`** — none of the above matched (default fallback for any non-allowlisted owner that did not satisfy rule 3).

(`stargazers_count` is the field name returned by `gh api repos/<owner_repo>` in Phase 1 — do NOT alias it to `stars` in the rule logic; the frontmatter `stars:` field is the rendered value, the gh-api source name stays canonical in code paths.)

Populate `trust_tier_reason` with a 1-line justification matching the tier:
- rule 0 → `safety_flag=<term> → unknown-risk`
- rule 1 → `owner=<owner-as-fetched> → anthropic-official`
- rule 2 → `owner=<owner-as-fetched> in known-author allowlist`
- rule 3 → `stargazers_count=<N>, pushed_at=<YYYY-MM-DD> → community-active`
- rule 4 → `stargazers_count=<N>, pushed_at=<YYYY-MM-DD> → community-thin`

Operators retro-tagging older Tech pages should rely on the Phase 4 § Audit log row `Trust tier: <tier> (<reason>)` rather than re-deriving manually.
