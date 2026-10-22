# Eval case study: prompt cache and the harness runner

What himmel measures about the prompt cache, how, and what the numbers say.
Everything here was re-run on 2026-10-06 at commit `321346770`; the table is
that run, not a copy of an older one. The audit of each cache claim and the
fixture-by-claim map stay in
[`docs/internals/prompt-cache.md`](../internals/prompt-cache.md); this page is
the method, results and re-run command.

## Method

A prompt-cache claim counts only once a probe shows it. The probe is
`scripts/eval/cache-probe.sh`. It is read-only: it reads the `usage` rows
(`input`, `cache_read`, `cache_creation`) and timestamps from Claude Code
session transcripts (JSONL), and prints a deterministic report and a verdict
exit code. It makes **no model call**, so a run costs nothing from the
subscription bank. It needs bash 3.2+ and `jq`.

- Rows are deduplicated by `message.id` (one message streams as several rows
  that repeat one usage object) and sorted by timestamp.
- A **full-prefix rewrite** is a turn whose `cache_read` falls below half the
  previous turn's while `cache_creation` carries the load.
- A rewrite is explained away as `compacted` (a compaction row between the
  turns, or the context shrank by more than 25 %) or `ttl` (the gap reached the
  session's cache TTL). Only an unexplained rewrite is `invalidated`.
- The TTL is per session: 3600 s when the last cache write used the 1-hour tier,
  else 300 s.
- `read-ratio` is `cache_read / (input + cache_read + cache_creation)` over
  every counted turn of every file given.

## What each probe measures

| Probe | Question | Verdict | Exit codes |
|---|---|---|---|
| `invalidation --event <time>` | Did an event (an edit, a bank reset) rewrite the cache of sessions live across it? Only the first turn after the event is judged. | `not-invalidated` / `invalidated` / `inconclusive` | 0 / 1 / 2 |
| `idle-gap` | Does an idle gap at or past the TTL re-pay the prefix, and a shorter one not? | `ttl-consistent` / `ttl-inconsistent` / `inconclusive` | 0 / 1 / 2 |
| `first-turn` | Does a session's first request read a warm shared prefix, or start cold? | `warm-start` / `cold-start` | 0 / 1 (2 = no sessions) |
| `scripts/eval/harness-run.py` | Does a judge or differential harness leave **no** descendant process behind, under a hard deadline? (Not a cache probe: it shares the `scripts/eval/` home and the "no claim without a check" rule.) | fixture suite pass/fail | 124 deadline, 125 survivor |

Exit code 64 is a usage error for `cache-probe.sh`.

## Results (2026-10-06)

Input: 2,019 session transcripts of one project (about 51 billion tokens
counted), read from `~/.claude/projects/<project-dir>/*.jsonl`. No transcript
content is in this repo; the probe prints only ids, counts and token totals.

| Probe | Command | Result |
|---|---|---|
| `first-turn` | `first-turn <all sessions>` | `warm-start warm=1966 cold=19`, read-ratio 98.3 % |
| `idle-gap` | `idle-gap <all sessions>` | `ttl-consistent`: cold-expected=172, cold-rewrote=155; warm-expected=25056, warm-rewrote=46; read-ratio 98.3 % |
| `invalidation` | `--event 2026-10-05T16:00:00Z <all sessions>` (a weekly-bank reset at 100 %, same account) | `not-invalidated kept=2 invalidated=0 compacted=0 ttl=0 inconclusive=0`, read-ratio 98.1 % |
| `test-cache-probe.sh` | fixture suite | 59 passed, 0 failed |
| `test-harness-run.sh` | fixture suite | PASS |

How to read it (the 2026-10-22 audit below recounts these and adds intervals):

- A new session starts warm in 1,966 of 1,985 cases (99.0 %, 95 % interval
  98.5 to 99.4). The 19 cold ones are sessions whose first request found no
  warm prefix. The 1,985 are the transcripts with a usable assistant turn; the
  other 34 of the 2,019 (1.7 %) have none and are in no count.
- Gaps past the TTL rewrote the prefix in 155 of 172 cases (90.1 %, interval
  84.7 to 93.7); gaps from 60 s up to the TTL rewrote it in 46 of 25,056
  (0.18 %, interval 0.14 to 0.24). Gaps under 60 s are in neither count. That is the
  cost of a parked session: the wake re-pays the prefix, and an idle one costs
  nothing.
- The read-ratio is one number per run, the token-weighted ratio over every
  counted turn of every file. The `first-turn` and `idle-gap` rows share it
  because they read the same files, not because it is a first-turn figure.
- The 2026-10-05 bank reset did not invalidate the two sessions live across it
  (317.5k to 319.5k read over a 2,101 s gap; 155.0k to 119.1k read with a 15.8k
  write over 1,605 s, still above half).
- Compared with the 2026-09-29 run in the internals doc, the counts grew with
  the transcripts (1,210 to 1,985 first turns, 98.2 % to 98.3 %), and the
  `invalidation` result is the same as the earlier L5 row to the token.

## Audit (2026-10-22)

`cache-probe.sh` was read end to end and the headline figures recounted by a
second implementation (a Python script written from the definitions in
Method, not from the jq program), on a seeded sample of live transcripts.

How the probe counts:

- **Turn:** a deduplicated `assistant` row with a usage object, a timestamp and
  a model other than `<synthetic>`. A file with no such row is in no count.
- **First turn:** the earliest turn of a file; warm when `cache_read > 0`.
- **Gap:** the time between two consecutive turns of one file. A pair that
  crosses a compaction (a `compact_boundary` row, or the context shrinking by
  more than 25 %) is dropped.
- **Long pause (cold-expected):** a gap at or past the file's TTL. It `rewrote`
  when the later turn's `cache_read` is below half the earlier one's and its
  `cache_creation` exceeds its `cache_read`. An earlier turn with `cache_read`
  0 cannot rewrite, so such a gap counts as expected, not as a rewrite.
- **Idle gap inside the TTL (warm-expected):** 60 s up to the TTL. Gaps under
  60 s are not counted at all.

Sample: 1,000 of the 4,073 transcripts of the himmel project (seeded draw,
seed 6993, each under 30 MB, 4.8 GB in all; 990 have a usable turn). A second
draw of 200 agrees too. Both counts are over the same files.

| Figure | Probe | Recount | Share (95 % interval) | Published 2026-10-06 |
|---|---|---|---|---|
| First turn warm / cold | 974 / 16 | 974 / 16 | 98.4 % (97.4 to 99.0) | 1,966 / 19, 99.0 % (98.5 to 99.4) |
| Past the TTL, rewrote | 70 of 75 | 70 of 75 | 93.3 % (85.3 to 97.1) | 155 of 172, 90.1 % (84.7 to 93.7) |
| 60 s to the TTL, rewrote | 36 of 15,738 | 36 of 15,738 | 0.23 % (0.17 to 0.32) | 46 of 25,056, 0.18 % (0.14 to 0.24) |
| Under 60 s, rewrote | not counted | 11 of 129,599 | 0.01 % (0.00 to 0.02) | not counted |
| Read-ratio | 98.3 % | 98.3 % | over 22.68 billion tokens | 98.3 % |

Findings:

- **No miscount.** The probe and the recount agree on every count. Each
  published figure falls inside, or overlaps, the interval of its recount.
  The intervals treat each file or gap as independent, which understates the
  spread because gaps within one session are correlated.
- **Two denominators were under-described, now corrected above.** The "inside
  the TTL" count leaves out the 89 % of gaps that are under 60 s, and the
  1,985 first turns leave out the 1.7 % of transcripts with no usable turn.
  The figures themselves are unchanged.
- **The bank-reset row reproduces.** The 2026-10-05T16:00:00Z event, over the
  transcripts live across it: 317,534 to 319,536 read over 2,101 s, and
  154,984 to 119,075 read with a 15,783 write over 1,605 s, both `kept`,
  read-ratio 98.1 %.
- **Totals drift, verdicts do not.** Live sessions append between runs, so a
  token total moved by 0.01 % between two runs a minute apart; no count did.
- **Review-panel page re-checked.** `docs/evals/review-panel.md` re-run with
  its pinned cut (`cr_ledger_eval.py --until 2026-10-06T20:00:00Z`) reproduces
  every table, share and interval. One sentence was wrong and is fixed there:
  the bare `codex` row has 89 findings, not under 40.

`test-cache-probe.sh` now holds a hand-counted fixture (`count-audit`) that
prints known first-turn and gap counts, and rows that edit one counting rule at
a time in a copy of the probe and require the counts to move. The run was
recorded in the eval-runs ledger as eval `cache-probe`.

## Cost

Zero model calls. `cache-probe.sh` and both fixture suites read local files
only; a probe over all 2,019 transcripts took roughly one to two minutes per mode on one
core, and the fixture suites take under 10 s. Bank preflight
(`bash scripts/lib/bank-preflight.sh`) printed `PROCEED` at 18 % of the 5-hour
and 45 % of the weekly bank before the runs, which only matters for the other
evals in this directory that do call a model.

## Limitations

- The rewrite and compaction thresholds are fixed (read below 0.5x the previous
  turn, create above read, context drop above 25 %). They separate the fixtures
  and these measurements; a workload with a much smaller prefix could sit near
  them.
- One TTL tier per session, inferred from `usage` and not from the request. A
  session that mixes tiers can read as over-flagged, never as hidden.
- A partial-prefix invalidation that keeps at least half the previous read looks
  like `kept`. The probe rules out a full rewrite, not a partial one.
- Only the first transition after the event is judged; timestamps are whole
  seconds (a gap is plus or minus 1 s).
- Helper calls that never reach the transcript are invisible, so `first-turn`
  can read warm from a call the file does not show.
- Single project, single account, one host. No account switch has been measured.
  Four audit claims remain UNVERIFIED (see the internals doc).
- Counts depend on which transcripts exist on the machine; re-running later or
  elsewhere gives different totals. The verdicts, not the totals, are the
  stable part.

## Re-run

```bash
# fixture suites (deterministic, no live data)
bash scripts/quiet-run.sh suite -- bash scripts/eval/test-cache-probe.sh
bash scripts/quiet-run.sh suite -- bash scripts/eval/test-harness-run.sh

# live probes over your own transcripts (read-only, no model call)
P=~/.claude/projects/<project-dir>
bash scripts/eval/cache-probe.sh first-turn $P/*.jsonl
bash scripts/eval/cache-probe.sh idle-gap $P/*.jsonl
bash scripts/eval/cache-probe.sh invalidation --event 2026-10-05T16:00:00Z $P/*.jsonl
```

To record a run, append one row with `python3 scripts/eval/lib/eval_runs.py
append --eval cache-probe --source scripts/eval/cache-probe.sh ...` (see
[the ledger section of the eval README](../../scripts/eval/README.md)); the
2026-10-22 audit row is the first of that eval.

For `--event`, give an epoch, an ISO time, or `@<file>` to use that file's
mtime. Sessions not live on both sides of the event are skipped.
