# luna-ingest — Phase 3 — Per-ref classification

Moved verbatim out of `SKILL.md`.

For each ref `<o>/<r>` in the cleaned ref list:

1. Fetch lightweight metadata: `gh api "repos/${ref}" --jq '{description, language, stargazers_count, pushed_at, topics, license: .license.spdx_id}'`. On failure, distinguish the failure class (LUNA-6):
   - **404 / "Not Found"** → verdict `skip`, `verdict_reason: ref_not_found`. Continue scanning the rest.
   - **403 / 429 / "rate limit" / "API rate limit exceeded"** → verdict `api_failure`, `verdict_reason: rate_limited`. Continue scanning; the run will exit rc=4 at the end so the operator knows to retry, but partial progress is preserved.
   - Other network/auth errors → verdict `api_failure`, `verdict_reason: <stderr-short>`. Continue; exit rc=4 at end.

   `api_failure` is NOT one of `integrate/take-parts/inspire/skip` — it's a SEPARATE verdict that exists only to keep partial runs honest. Refs with `verdict: api_failure` go under § Unclassified (transient) in the synthesis, never § Skip (which implies a deliberate heuristic decision).
2. Assign a verdict per these heuristics (apply in order; first match wins):
   - `skip` (stale) — the ref's `pushed_at` is more than 24 months old. Checked BEFORE the positive verdict rules, so a stale repo under "Dependencies" is `skip`, never `integrate`.
   - `integrate` — the ref appears in a parent README section titled "Dependencies", "Requires", "Built on", "Uses" OR the topics overlap explicitly with a "package" or "library" tag AND the ref has an SPDX license that's MIT / Apache-2.0 / BSD-3-Clause (permissive).
   - `take-parts` — the ref appears under "Related", "Inspired by", "See also", "Forked from" sections AND the ref has ≥10 stars AND its language matches one of the parent's top 2 languages.
   - `inspire` — the ref appears under "Reading", "Articles", "Background", "Prior art" OR the ref's language differs from the parent's primary language but its topics overlap.
   - `skip` — everything else, OR license is restrictive (AGPL, BSL) and the parent suggests integration.
3. Capture a 1-3 sentence rationale citing which README section / topic / license / staleness drove the verdict.
4. Record confidence `0.0–1.0`: high (≥0.8) when section heading is unambiguous; medium (0.6 to below 0.8) when section is implied by surrounding prose; low (<0.6) when no section context exists (verdict is best-guess from topics/license alone).
5. Refs with confidence <0.6 are listed in the synthesis under § Weak refs (appendix) instead of the main § Referenced repos section.
