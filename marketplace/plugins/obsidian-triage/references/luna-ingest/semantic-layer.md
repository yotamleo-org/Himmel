<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### Semantic layer (HIMMEL-3055 — schema defined, NOT yet populated)

Identity (`upstream_commit`, `readme_sha256`, …) answers "did the repo move". It says nothing
about what the repo is *for* — the layer that makes the corpus clusterable and searchable rather
than a bare list of URLs. That is a **model pass**, so it does not run over all 443 repos in this
MVP — it only earns its cost on a ranked slice a later session selects (see the staleness report's
ranking). This section defines the fields so a future ingest/backfill pass has a fixed target;
it does **not** populate them, and no code in this skill writes them yet.

Proposed fields, on the same `tech-ingest` frontmatter:

- `concepts:` — 3-8 normalised concept tags describing what the repo *does*, drawn from a
  controlled vocabulary (free text defeats clustering). Seed vocabulary: `agent-harness`,
  `cost-optimization`, `model-routing`, `guardrails`, `orchestration`, `retrieval`, `installer`,
  `observability`, `review-gate`, `memory`, `sandboxing`, `eval`. Extend deliberately when a repo
  genuinely doesn't fit (e.g. `browser-automation` for an anti-detect browser agent) — record the
  addition and why in the note that first needed it, don't mint terms ad hoc per-repo.
- `solves:` — one sentence, the problem it solves, in the repo's own terms.
- `maps_to:` — which himmel surface it bears on, if any: `chief/worker`, `lane-registry`,
  `hooks/gates`, `cost-programme`, `installer`, `cr-panel`, `vault`, or `none`. `none` is the
  common, legitimate answer — a field that always finds a connection means nothing.
- `value_tier:` — `integrate` / `take-parts` / `inspire` / `skip` (reuses `verdict_summary`'s
  vocabulary for the repo itself rather than inventing a second scale).
- `value_reason:` — one line justifying the tier, so it can be audited or disagreed with later.

**Every semantic field carries the `ingest_spec_version` and `upstream_commit` it was derived
against.** These are judgements, not facts — they can be wrong, and they go stale when a repo
changes direction (a repo in this corpus was ingested as a job-application tool and is now an
anti-bot browser agent: `feder-cr/AIHawk`, formerly `jobs_applier_ai_agent_aihawk` — see the
HIMMEL-3055 staleness report for the worked example). Without the commit anchor, nobody can tell
whether a stored judgement still applies to the code it was made about.

Five hand-derived examples proving this schema resolves without contradiction across a job-search
bot turned browser agent, a vendored proxy, an Electron orchestrator, a second-brain plugin, and
an unrelated SaaS product are in the HIMMEL-3055 staleness report (`§ Semantic layer hand-proof`),
not applied to any vault note — this is a schema proof, not a backfill.
