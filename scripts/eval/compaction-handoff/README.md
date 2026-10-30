# compaction-handoff - does a 450k ceiling with a hand-off beat the 200k compaction loop? (HIMMEL-7667)

Phase 1, `compaction-defects.py`: counts the defects (re-reads, repeated denied calls, misquoted nonces, verdict slips, redone work) in the turns after each compaction of a real transcript, against a control window. Unbilled, runs on `~/.claude/projects`.

Phase 2, `ab.py` + `ab_tasks.py`: a bounded, billed A/B of three launch shapes on three generated tasks.

| arm | launch | what happens at the limit |
|---|---|---|
| a | `--autocompact 200000` | compaction (today's worker) |
| b | `--autocompact 450000` + hand-off | the driver stops the session once its context passes 75 % of 450k (337500), resumes it to write `HANDOFF.md`, and starts a fresh session whose only prompt is "Load HANDOFF.md and continue" (what `--context-guard handoff` does, done from outside; up to 3 hand-offs) |
| c | `--autocompact 450000` | compaction |

Tasks (`ab_tasks.py gen|solve|check|brief`, seeded, a hidden check per task; the chief's "rulings" live only in the brief, so a hand-off must carry them):

| task | profile | work | scale unit |
|---|---|---|---|
| `docs` | docs | replace the word "leg" on every page, footer `ref: <token>-NNN`, leave `docs/frozen/` alone, write `REPORT.md` | 1.0 = 100 pages |
| `impl` | impl | implement one function per module from its spec (a superseded decoy; a late ruling changes the constant for the later modules), write `NOTES.md` | 1.0 = 60 modules |
| `audit` | eval | compare source and report figures, write `findings.jsonl` with a severity per finding, none for withdrawn pairs | 1.0 = 80 pairs |

## Method

- Each run is a `claude -p --output-format stream-json --verbose` session on a scratch copy (a plain directory, not a git repo: the user-scope edit-on-main hook refuses edits in a checkout), the Agent tool denied, `--max-budget-usd 20`.
- cost-eq = input + 1.25 x cache-write + 0.1 x cache-read + 5 x output, deduped by message id; each compaction is added as pre_tokens x 0.1 + 5000 x 5 (the compaction call is not in the stream).
- **A run is valid only if it reached its trigger, counted from the stream-json:** a and c need a `compact_boundary`; b needs a hand-off with `HANDOFF.md` written and a fresh session after it. A run that errored, timed out or ended early is INVALID: it is priced and kept (`<rep>.invalid-N`), never scored, and re-run with `sweep --rerun-invalid`.
- Contamination: the Phase 1 classifier over a 40-turn window after every compaction and every hand-off.
- Quality: the check fraction from the hidden check, and a blind opus judge (`ab.py judge`; the prompt names neither the arm nor the ceiling and drops hand-off lines).
- `ab.py score` prints one row per task and arm (n, check, judge, cost_eq, wall, turns, compactions, hand-offs, peak context, defects), the invalid runs, and a recommended arm per profile: among arms within 0.05 check share and 1 judge point of the best, the cheapest.
- The sweep resumes (a cell with a `summary.json` is skipped), runs `usage-preflight.sh` before each task (must print PROCEED, else exit 3) and stops before the cell that would pass `--ceiling`.

## Run

```
HIMMEL_BILLED_OK=1 python3 ab.py sweep --out <scratch dir> --ceiling 40000000 \
    --scales docs=1.75,impl=2.7,audit=4.3 [--rerun-invalid]
HIMMEL_BILLED_OK=1 python3 ab.py judge --out <scratch dir>
python3 ab.py score --out <scratch dir>
```

`--out` must be outside the checkout. Tests: `bash test-compaction-ab.sh` (stub claude and stub bank preflight, no model call).

One rep per cell is a noisy sample; raise `--reps` when the weekly budget allows.
