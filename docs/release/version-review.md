# Version review

A version review reports how the fleet did against the previous version, not
only what shipped. The trend lines come from one weekly roll-up; the review
reads it and never recomputes.

## The roll-up

`scripts/eval/weekly-rollup.py write` keeps one row per ISO week and one per
stable version (`vX.Y.Z` tags) in `~/.himmel/state/rollup/weekly.jsonl`
(`WEEKLY_ROLLUP_FILE`). Run it before a review:

```
python3 scripts/eval/weekly-rollup.py write --ref origin/main --weeks 12 --versions 3
```

Each row holds the series below and `delta`, the change against the previous
row of the same kind. A series with no data is `null`, never 0. The week that
contains now is `partial`; do not read its delta as a trend.

| Series | Columns | Source |
|---|---|---|
| Velocity | `merges`, `tickets`, `fix_share_pct` | `scripts/insights/self-review.sh` (HIMMEL-6865) for the window; tickets from the merge subjects |
| Cost | `cost_eq`, `cost_eq_per_ticket`, `legs` | the `leg-burn:` PR-body lines (`cost-eq=`); per ticket is over the tickets that carry a burn line |
| Health | `red_main`, `cache_hit_pct`, `flake_rows` | self-review red-main; the cache-health rolling history (HIMMEL-5672); the run-shell-tests FLAKE ledger |

`failure_rate_pct`, `denial_rate_pct` and `ship_stage_median_min` have no
source yet and are `null` (listed in `no_source`). If `self-review.sh` is not
in the checkout, `merges`, `fix_share_pct` and `red_main` are `null` and
`sources.self_review` says `absent`.

## Checklist lines

1. Refresh the roll-up (command above).
2. Print the review lines for the version:
   `python3 scripts/eval/weekly-rollup.py review --version vX.Y.Z`
3. Paste the three lines (`velocity:`, `cost:`, `health:`) into the review. Each
   shows the value and its change against the previous version, and the
   velocity line shows the window length: compare totals only when the windows
   are similar.
4. A line that reads `no data yet` means the version row is missing: run step 1
   with `--versions` large enough to reach it.
