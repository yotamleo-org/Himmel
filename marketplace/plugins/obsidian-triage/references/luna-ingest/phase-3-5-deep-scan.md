<!-- Moved verbatim out of SKILL.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

## Phase 3.5 — Deep component scan (LUNA-57, `--deep` only)

Skip this entire phase unless `--deep` was passed.

Run the component scanner once per repo, gh-API only (no clone). The source
repo is ALWAYS scanned; a 1-hop ref is scanned ONLY when its Phase-3 verdict
is `integrate` or `take-parts` (the repos actually worth lifting from — refs
verdicted `inspire`/`skip`/`api_failure` are not scanned). Propagate the
source's `trust_tier` + `safety_flag` into the scan so every Components/ note
inherits the parent's risk annotation. Compute the source `trust_tier` inline
here using the Phase-4 "Trust-tier auto-classification" rules — all their
inputs (`owner`, `stargazers_count`, `pushed_at`, plus the `safety_flag` set
in Phase 1.5) are already available at this point, so there is no need to wait
for the Phase-4 Write step.

For the SOURCE repo (writes the deduped library + returns JSON for the
Tech-note section):
```bash
bun "$TOOLS/component-scan.mjs" --repo "$owner_repo" --vault "$VAULT" \
  --components-dir "$COMPONENTS_DIR" --trust-tier "$trust_tier" \
  --safety-flag "$safety_flag" --max-components "$MAX_COMPONENTS" --emit json \
  [--dry-run]
```
Capture the JSON — its `components[]` array feeds the Phase-4
`## Reusable components` section.

For each ref `<o>/<r>` with verdict ∈ {integrate, take-parts} (library
dedup only; the Tech-note section summarises ref scans by count + link):
```bash
bun "$TOOLS/component-scan.mjs" --repo "<o>/<r>" --vault "$VAULT" \
  --components-dir "$COMPONENTS_DIR" --trust-tier "$ref_trust_tier" \
  --safety-flag "$safety_flag" --max-components "$MAX_COMPONENTS" --emit json \
  [--dry-run]
```
`$ref_trust_tier` is computed per-ref from that ref's OWN Phase-3 metadata
(description / language / stars / pushed_at / license / topics already
fetched in Phase 3) via the same Phase-4 "Trust-tier auto-classification"
rules; `$safety_flag` here is the SOURCE's Phase-1.5 flag — refs are not run
through the Phase-1.5 pre-filter, so they conservatively inherit the parent
source's flag.

When the skill was invoked with `--dry-run`, pass `--dry-run` to
component-scan too (it then prints the JSON inventory + would-write notes
without touching the vault, rc=0).

`$TOOLS` = `<plugin-root>/tools`. The tool is HIMMEL-128 compliant (no
headless claude — it shells `gh`, not `claude`). A non-zero exit (rc=4)
means ≥1 component file failed to fetch; record the count under § Open
questions and continue — partial inventories are honest, not fatal.
