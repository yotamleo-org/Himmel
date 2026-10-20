---
description: Refresh known-findings.json evidence from the CR ledger + a CodeRabbit learnings export; lists new-class candidates
---

Lean-invoke — run after a CodeRabbit learnings export lands in Downloads, or
when `/pr-check` step 2.8 keeps printing `known-findings: round-1 hits = N` with
N > 0. The export is a manual download, so the refresh itself has no cadence;
the weekly cadence is `bash scripts/cr/standards-cadence.sh --since 7d` (see
`/cr-tune` step 5), whose proposals file you read BEFORE this refresh so a lesson
already learned is not paid for again. Approval split: `.coderabbit.yaml` and
`critics.json` changes are operator-approved; catalog, lint and standard-line
changes go through a console GO with an opus judge.

1. Refresh evidence (ledger always; the export when you have one):
   ```bash
   bash scripts/cr/known-findings.sh --refresh --learnings "<path-to-export>.csv"
   ```
   (`--refresh` alone re-mines only the ledger.) This rewrites ONLY each class's
   `evidence` block, `refreshed_at`, and (with `--learnings`) the top-level
   `learnings_export` summary; titles, globs, detectors and canonical
   texts are hand-curated and untouched.
2. Build ONE checklist from the feed lines it printed (field meanings:
   [`docs/internals/known-findings.md`](../../docs/internals/known-findings.md)),
   one item per line, in this order:
   - `STALE` — the CodeRabbit learning must be deleted in the CodeRabbit UI.
   - `DUPLICATE` — read the group (it matches on the first 12 words only); if
     the rows state the same rule keep one and delete the rest, else keep all.
   - `PONYTAIL` — keep; confirm the row's ticket still matches its text.
   - `PROPOSE-CLASS` / `PROMOTE-HINT` — judgment layer (step 3).
   - `STATUS-UNKNOWN` — re-run once Jira is reachable; never delete on it.
3. Judgment layer (the session): a `PROPOSE-CLASS` draft, a `PROMOTE-HINT` row,
   a "Top unmatched" learning with ≥ 50 uses, or any class the step-2.8 hit
   counter keeps naming, becomes a new entry in `scripts/cr/known-findings.json`
   — pick `kind` (fix / rebuttal / checklist), a deterministic `detector` where
   one exists, and a `learning_match` regex so the next refresh attributes it. A
   learning that merely restates a rule a shell-lint check or `.coderabbit.yaml`
   instruction already enforces is NOT a new class — note the coverage instead.
4. Do not finish while any `STALE` row is undeleted. Record each row's decision
   (deleted / kept with reason / new class id) in the leg doc, not in the CSV or
   the JSON. Deleting in the CodeRabbit UI does not change the CSV you already
   have: download a fresh export, re-run step 1 with it, and check that
   `stale_rows` has dropped to what you kept.
5. `bash scripts/cr/test-known-findings.sh` must stay green; if ids changed,
   paste the output of `bash scripts/cr/known-findings.sh --list` over the class
   table in [`docs/internals/known-findings.md`](../../docs/internals/known-findings.md)
   (it prints the table; nothing edits the doc for you). Land it as a normal
   branch + PR (the JSON is versioned; it feeds every critic prompt).
