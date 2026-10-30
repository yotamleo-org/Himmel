# Routing eval, phase 2 climb: sealed targets not met (HIMMEL-8088)

Means over reps: 5 for haiku, 3 for sonnet and opus. Sealed is aggregate only.

## Enlarged case set: 55 open, 38 sealed

| arm | listing tokens | model | reps | open | sealed | sealed target |
|---|---|---|---|---|---|---|
| pre-climb (554788cd) | 4688 | haiku | 5 | 0.756 | 0.668 | 0.768 |
| pre-climb (554788cd) | 4688 | sonnet | 3 | 0.721 | 0.746 | 0.846 |
| pre-climb (554788cd) | 4688 | opus | 3 | 0.758 | 0.702 | 0.851 |
| before (main + 3 lines) | 3296 | haiku | 4 | 0.845 | 0.651 | |
| before (main + 3 lines) | 3296 | sonnet | 3 | 0.794 | 0.737 | |
| before (main + 3 lines) | 3296 | opus | 3 | 0.806 | 0.719 | |
| final candidate (+ 7 lines) | 3294 | haiku | 5 | 0.840 | 0.658 | |
| final candidate (+ 7 lines) | 3294 | sonnet | 3 | 0.836 | 0.728 | |
| final candidate (+ 7 lines) | 3294 | opus | 3 | 0.824 | 0.719 | |

Targets come from the pre-climb row: +10 sealed points for haiku and sonnet, and half the sealed misses for opus. No arm meets any of them.

How many sealed cases the final candidate loses, counted as a flip from majority-exact to majority-miss:
- against `before`: haiku 2 lost and 1 gained, sonnet 1 and 1, opus 0 and 0.
- against `pre-climb`: haiku 0 lost and 1 gained, sonnet 2 and 2, opus 0 and 2.

Every flip is noise-sized, so no description edit from this phase ships. The listing stays as it is on main (3296 tokens). The `before` haiku row has 4 reps: a fifth was voided because an edit landed while it ran.

The listing tokens column is the whole-listing chars/4 figure. Eval spend for the phase was 19.92 USD, against a 45 USD line. The sealed targets move to HIMMEL-8158.

## History

The phase-1 rows are **burned**: a tuner climbed against that sealed half, so it was rotated out. The round-1 rows were measured on 24 of the current 38 sealed cases, before the miner grew the half. Neither is comparable with the table above.

| arm | sealed cases | haiku | sonnet | opus |
|---|---|---|---|---|
| phase-1 baseline (PR 4222), burned | 24 | 0.75 | 0.75 | 0.875 |
| phase-1 shipped (PR 4236), burned | 24 | 0.84 | 0.89 | 0.93 |
| phase-2 round 1, pre-climb | 24 | 0.667 | 0.764 | 0.708 |
| phase-2 round 1, before (1502be8b) | 24 | 0.642 | 0.750 | 0.792 |
| phase-2 round 1, last candidate | 24 | 0.717 | 0.792 | 0.736 |

## Correction

The check behind the earlier "0 sealed brainstorming/writing-plans cases regressed" figure was vacuous: it read `results.json`, which carries open cases only. The count was rebuilt on `score.py`'s own scorer over the raw envelopes and prints counts only. No sealed case in the enlarged half expects either skill, and the brainstorming line stays at its upstream text.
