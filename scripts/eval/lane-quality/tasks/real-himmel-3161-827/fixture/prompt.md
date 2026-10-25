# cr-scores.sh agreed% excludes 'fixed', so drop-advice flags ~100%-accepted critics as <40%

Symptom
scripts/cr/cr-scores.sh computes agreed% as agreed / total (~:315, :334). Findings with verdict fixed count in total but not in agreed. So the drop-advice (agreedPct < DROP_BELOW over >= MIN_N) flags both live critics as below 40 %, even though both are about 100 % accepted once fixed counts as acceptance. Source: fleet-v1-join design §11, 2026-09-17.
Fix
Count fixed as agreement in both the column and the drop-advice. fixed means the finding was accepted and acted on. First read how the ledger verdicts are tallied, and list every verdict value seen in the aggregator. If a separate fixed column is clearer than folding it in, say so. Either way, the drop-advice must not treat fixed as disagreement.
Acceptance
RED in scripts/cr/test-cr-scores.sh: a critic whose findings are all fixed gets no drop advice. This fails today. Existing cases stay green.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/cr/test-cr-scores.sh`

The checks it must pass include:

- `scripts/cr/test-cr-scores.sh`: all-fixed critic gets NO drop advice
- `scripts/cr/test-cr-scores.sh`: all-fixed critic shows 100% agreed

Run the tests you touch before you finish. Report what you changed and what you checked.
