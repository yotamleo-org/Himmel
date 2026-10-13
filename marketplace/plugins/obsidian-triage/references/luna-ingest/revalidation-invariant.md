<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Revalidation invariant (HIMMEL-3055)

A prose `## Re-validation` section (written by a future revalidation sweep, not by this MVP)
MUST rewrite every structured field it confirms — `stars`, `upstream_pushed_at`,
`upstream_commit`, `trust_tier`, `trust_tier_reason`, `readme_sha256` — not just narrate the
outcome. A note whose prose says "CONFIRMED alive" while its `stars:` frontmatter still holds a
three-week-old count is the same class of defect as a vacuous ledger: the structured fields are
what tooling reads, and prose that disagrees with them is worse than no prose at all. Every such
rewrite also sets `last_revalidated` to the check time and adds a `revalidation_delta:` one-liner
(stars delta, `upstream_pushed_at` delta, verdict delta) — this is the one case where writing
`last_revalidated` is correct, because a real check genuinely happened.
