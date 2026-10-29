# Routing eval, phase 2: climb and trim (HIMMEL-8088)

Means over reps. Sealed is aggregate only. Tokens are chars/4 over the whole listing.

| arm | listing tokens | model | reps | open | sealed | false pick | cost/run |
|---|---|---|---|---|---|---|---|
| baseline | 4711 | haiku | 1 | 0.87 | 0.75 | 0.04 | $0.012 |
| baseline | 4711 | sonnet | 1 | 0.96 | 0.75 | 0.00 | $0.203 |
| baseline | 4711 | opus | 1 | 0.96 | 0.88 | 0.00 | $0.387 |
| before | 4688 | haiku | 2 | 0.96 | 0.73 | 0.00 | $0.012 |
| before | 4688 | sonnet | 1 | 0.91 | 0.83 | 0.00 | $0.201 |
| before | 4688 | opus | 1 | 0.96 | 0.88 | 0.00 | $0.396 |
| climb | 4668 | haiku | 8 | 0.99 | 0.83 | 0.00 | $0.010 |
| climb | 4668 | sonnet | 3 | 1.00 | 0.88 | 0.00 | $0.135 |
| climb | 4668 | opus | 3 | 1.00 | 0.92 | 0.00 | $0.289 |
| trim | 3257 | haiku | 5 | 0.98 | 0.86 | 0.01 | $0.009 |
| trim | 3257 | sonnet | 3 | 1.00 | 0.89 | 0.00 | $0.135 |
| trim | 3257 | opus | 3 | 1.00 | 0.93 | 0.00 | $0.269 |
| shipped | 3261 | haiku | 10 | 0.96 | 0.84 | 0.02 | $0.010 |
| final | 3282 | haiku | 5 | 0.96 | 0.84 | 0.03 | $0.010 |

`shipped` is the trim with the vendored qmd skill line restored to its upstream text. `final` is this PR's head: `shipped` with three description lines (himmel-report, release-manager, vm) restored after review. Only haiku was re-scored on those two; sonnet and opus were scored on the 3257-token trim listing and not re-run.

Seeded-broken control (`--seed-broken pr-check,check-ci`, climb listing, haiku, 1 rep): open 0.96, sealed 0.75.
