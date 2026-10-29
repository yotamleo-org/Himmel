# memory-compound — scoping the qmd gate + branch caveat (step 4)

Moved verbatim out of `SKILL.md`.

**Scope the gate to the collection you wrote to (D8, HIMMEL-570).** The qmd
index holds many collections; an **unscoped** memory query searches all of them
and dilutes a hit on a freshly landed note, which sank the 2026-07-16 recall
probes. The collections that matter here are `luna` (vault notes landed from
memory) and `himmel` (graduated `docs/internals/` pages). Query `-c luna` for a
vault note and `-c himmel` for a himmel doc; keep the one you wrote to fresh with
`qmd_cmd update -c <name>`. Name only collections `qmd status` lists. **⚠ The flag
is `-c` / `--collection` (singular) — `--collections` (plural) is NOT a qmd flag
and is SILENTLY IGNORED**, so a gate run with `--collections luna` searches
*everything* while looking scoped and "confirms" a false pass. Set a minimum score of 0.5 and an intent: on the CLI pass `--min-score 0.5` and `--intent "<what you are looking for>"`; on the MCP `query` tool set the JSON fields `"minScore": 0.5` and `"intent": "<what you are looking for>"`.

**Branch caveat (BOTH collections):** qmd indexes the PRIMARY checkouts, not
worktrees — a doc landed on a himmel PR branch AND a vault note landed on a
vault branch are not qmd-findable until their branches merge. For everything
landed on a branch (which, per rail 1, is everything), the gate splits:
verify the content sits in the pushed branch/PR now; run the re-index +
findability spot-check AFTER the merges land in the primary checkouts, and
only then delete the source topic files. Steps 5–6 of a fully-branched pass
therefore run as a short POST-MERGE follow-up, not in the landing session.
