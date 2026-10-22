---
description: Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals. Never auto-applied.
---

1. Run the mechanical miner and the scorecard:
   ```bash
   bash scripts/cr/cr-tune.sh
   bash scripts/cr/cr-scores.sh
   ```
2. Judgment layer (the session): map each disproved cluster / calibration flag / re-litigation signal to a named concept class (e.g. "test-fixture over-verification", "CR-round re-litigation", "docs-mirror noise"). Evidence bar: a proposal needs ≥3 supporting disproved rows from ONE cluster OR an operator-confirmed known-limitation pattern; anything thinner is listed under "weak signals — do not tune yet".
3. Draft proposals — each citing its ledger rows (`ts head finding_id file:line`):
   - `.coderabbit.yaml`: `reviews.path_instructions` additions/edits (path_instructions outrank CodeRabbit "learnings", so the yaml is the durable channel).
   - `$HIMMEL_REPO/scripts/cr/critics.json`: per-critic prompt/routing adjustments; confirm or contradict `cr-scores.sh` drop advice.
4. Write the proposals to `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md` — resolve the root via `scripts/lib/handover-path.sh` using `handover_root_ensure` (NOT plain `handover_root`, which never mkdirs), then `mkdir -p "<root>/cr-tune"` before writing, and `test -f` the resulting file before surfacing the path. NEVER edit `.coderabbit.yaml` or `critics.json` in the same run — config changes are operator-approved PRs that cite the proposal file.
5. Weekly standards cadence (run it once a week, before spending CR rounds on a recurring class):
   ```bash
   bash scripts/cr/standards-cadence.sh --since 7d
   ```
   It writes `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md` (when step 4 already wrote that name today it writes `proposals-YYYY-MM-DD-standards.md` instead; a re-run replaces its own file). Read it first: review the lessons already learned (known-findings, this file) before a CR round re-finds them. Each class that recurred in the window gets exactly ONE target (lint or check, standard line, critic rule, CodeRabbit rule, rebuttal), and each promoted class shows its findings per week before and after promotion. A class whose rate did not fall is demoted to restructure (S5).
   Approval: `.coderabbit.yaml` and `critics.json` changes (the CodeRabbit rule and critic rule targets) are operator-approved; the catalog, lint and standard-line targets go through a chief GO with an opus judge. A proposal expires after 14 days unbuilt and is REFIRED by the next run while its class keeps recurring. Detail: [`docs/internals/known-findings.md`](../../docs/internals/known-findings.md).
6. Deferred-escape classes: fixes whose root cause was a deferred review residual carry the `deferred-escape` label and the residual's `class-<id>` (written by himmel's `scripts/cr/mark-deferred-escape.sh`, not shipped to adopted projects). Tally them:
   ```bash
   bash "$HIMMEL_REPO/scripts/cr/escape-classes.sh"
   ```
   Read the `top escape class:` line and propose ONE calibration change for that class: a tighter defer rule in `$HIMMEL_REPO/scripts/cr/critics.json` or `.coderabbit.yaml`, or a promotion on the known-findings ladder. When it says `none`, report the unclassified tickets and propose nothing until they carry a class label. When stderr carries `WARN escape-classes` (the 500-row cap), the tally is partial: get complete counts before choosing a class. A ticket listed as `unclassified` is reported as such and never assigned a class. Approval follows step 5: critic and CodeRabbit rules are operator-approved, a ladder promotion takes the catalog/lint/standard-line route (GO with an opus judge); write the proposal into the step 4 file, never apply it in this run.
7. Re-run note: the miner is read-only and idempotent; re-running after new /pr-check rounds refreshes the clusters.
