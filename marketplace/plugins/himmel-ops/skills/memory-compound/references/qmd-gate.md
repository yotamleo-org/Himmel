# memory-compound — scoping the qmd gate + branch caveat (step 4)

Moved verbatim out of `SKILL.md`.

**Scope the gate to the curated collection (D8, HIMMEL-570).** The
`luna-curated` collection is ~351 docs (the `30-Resources/Tech/**` scope that
holds the ~17 theme notes the index routes to); an **unscoped** memory query
instead searches the full `luna` collection's ~13,253 docs — a **~38:1**
dilution (13,253 : 351) that sank the 2026-07-16 recall probes.
Query `-c luna-curated` **first** (the `30-Resources/Tech/**` scope; keep it
fresh with `qmd_cmd update -c luna-curated`), full `luna` only as a fallback on
a miss. **⚠ The flag is `-c` / `--collection` (singular) — `--collections`
(plural) is NOT a qmd flag and is SILENTLY IGNORED**, so a gate run with
`--collections luna-curated` searches *everything* while looking scoped and
"confirms" a false pass. Set a minimum score of 0.5 and an intent: on the CLI pass `--min-score 0.5` and `--intent "<what you are looking for>"`; on the MCP `query` tool set the JSON fields `"minScore": 0.5` and `"intent": "<what you are looking for>"`.

**Branch caveat (BOTH collections):** qmd indexes the PRIMARY checkouts, not
worktrees — a doc landed on a himmel PR branch AND a vault note landed on a
vault branch are not qmd-findable until their branches merge. For everything
landed on a branch (which, per rail 1, is everything), the gate splits:
verify the content sits in the pushed branch/PR now; run the re-index +
findability spot-check AFTER the merges land in the primary checkouts, and
only then delete the source topic files. Steps 5–6 of a fully-branched pass
therefore run as a short POST-MERGE follow-up, not in the landing session.
