# review-panel recall eval

How many real defects does the review panel (`scripts/cr/critic-panel.sh`, the
critic half of `/pr-check`) catch, and how often does it raise one that is not
there? The CR ledger only has agreed%, a precision proxy the PR author decides.
This eval feeds the panel frozen diffs with known injected defects and clean
twins of the same diffs, then scores what it reports against a key it never
sees.

| path | what |
|---|---|
| `fixtures/case-NN.patch` | 24 frozen one-file git diffs: 12 seeded, 12 clean twins. Ids are opaque and shuffled, so a case id says nothing about its class or its twin |
| `fixtures/real-NNN.patch`, `real-NNN-clean.patch` | 30 real review escapes and their clean twins, frozen from merged history, with `real-NNN*.intent.md` (below) |
| `fixtures/delta-NN.patch`, `delta-NN.delta.patch` | 10 delta cases: a round-1 diff and the fix delta, run with the delta as the diff (below) |
| `key/seeds.json` | the answer key: per case its twin `pair`, `kind` (seeded / clean), `split` (open / sealed) and `defects` (`id`, `class`, `file`, new-file `line`), plus a `canary` string |
| `score.py` | `lint` (fixture/key integrity + leak lint) and `score` (matcher, metrics, eval-runs row) |
| `run.sh` | one sweep: lint, panel per fixture, score, one ledger row |
| `test-review-panel.sh` | the suite: canned critic outputs and a stub panel, no model call |
| `cbs.txt`, `results.jsonl` | the critic behaviour set and the sweep rows the merge gate reads |
| `harvest.py` | candidate review escapes from merged-PR history |

Classes, two seeded cases each: `logic`, `quoting`, `fail-open`, `toctou`,
`test-cannot-fail`, `scope-creep` (the ledger's recurring finding classes).

## Running a sweep (chief only: draws codex usage)

Every fixture is one paid panel call (the codex row, `tier: paid`), so a sweep
is 24 calls; workers never run it. From the primary checkout, after
`bash scripts/lib/usage-preflight.sh` says PROCEED and with the codex
`used_percent` noted:

```bash
bash scripts/eval/review-panel/run.sh --out ~/.himmel/eval/review-panel/2026-10-07 --no-ledger
```

Then note codex `used_percent` again and record the row with the bank cost
(re-scoring is deterministic and free):

```bash
python3 scripts/eval/review-panel/score.py score --outputs ~/.himmel/eval/review-panel/2026-10-07 --critics codex --meta-json '{"codex_used_pct_before": 41, "codex_used_pct_after": 47}'
```

The table it prints is the result; the same command re-prints it from the
stored outputs at any time. `eval-compare review-panel` compares two sweeps
case by case (`hit` and `fp`, paired, with the detection floor the 24 cases
allow); the run-level metrics carry no bands yet, so they print as info.

## What the critic sees, and what keeps the key from it

- The diff alone, on stdin, from an empty scratch dir outside any git checkout
  (`run.sh`). Outside a checkout the panel also skips its CR-ledger self-append,
  so a sweep never pollutes `.git/cr-critic-scores.jsonl`.
- `CRITIC_KNOWN_FINDINGS=0`: himmel's own dispositioned findings are not
  injected into the prompt. `CR_TRIVIALITY_OVERRIDE=full`: the triviality gate
  would otherwise skip the paid tier on these small diffs. `CR_PROFILE` is
  dropped so `--tiers` decides the panel.
- `score.py lint` (run first by `run.sh`; a failure refuses the sweep before any
  panel call) refuses a fixture that carries the key canary, the key path, or a
  hint word (`seed`, `inject`, `planted`, `defect`, `canary`), and checks every
  seed line is an added line of its own diff.
- Leak flag: a case whose panel stdout or stderr carries the canary or the key
  path is reported as `LEAK <case>`, counted in `leaked`, and the row's status
  becomes `inconclusive`.

## Matching rules

A finding is a `- [<critic>-<n>]: <text> [<file>:<line>]` bullet under
Critical / Important / Suggestions; the critic is the id's slug. Re-raise and
dropped-citation bullets are not findings. A finding hits a defect when:

1. **location**: same file, and `|line - seed line| <= 3` (`--window`); and
2. **class**: its text matches the class's keyword pattern (`CLASS_PATTERNS` in
   `score.py`), so a style remark on the seeded line is not credited.

| metric | definition |
|---|---|
| `<c>.recall` | seeded defects with a location+class hit / seeded defects scored |
| `<c>.recall_loc` | the same with location only: the upper bound, so a keyword miss shows as a gap |
| `<c>.recall_gating` | hits at Critical or Important (what the CR gate blocks on) / defects |
| `<c>.precision` | findings that hit some defect / all findings (a lower bound: a real unseeded issue counts against it) |
| `<c>.fp_rate` | clean twins with >= 1 Critical/Important finding / clean twins scored |
| `<c>.class.<cls>.recall` | recall per class, with `.n` |
| `defects`, `cases`, `unscored`, `leaked` | run totals |

`<c>` is each critic slug plus `panel` (the union of all critics). A case whose
review was not performed (no output, `REVIEW NOT PERFORMED`, a transcript
missing any of the three severity headings or carrying fewer bullets than a
heading's `(N found)`, or a nonzero panel exit in
`<case>.rc`) is unscored;
a critic listed as unavailable in a case's Note block is dropped from that
case's denominators only. Recall, precision and fp_rate carry Wilson 95%
intervals in the row's `ci`. n is small (12 defects, 2 per class): a per-class
number is a direction, not a measurement.

## Open and sealed seeds

Half the pairs are sealed. Per class, `random.Random(7519)` picked one of its
two pairs (`a` or `b`) to seal, and a pair's seeded and clean twins share its
half, so each half holds one pair of every class: 6 pairs, 12 cases each. The
key records the seed and the method under `split`.

- `score.py` reports every metric per half as `open.<metric>` and
  `sealed.<metric>`, each with its own Wilson interval, beside the whole-set
  metric.
- Tuning reads the open half only: an `eval_feedback.py` rule on this eval sees
  the `open.` metrics, unprefixed, and never the `sealed.` metrics or the
  whole set (which contains the sealed half).
- The sealed half only grades the keep rule: a change is kept when the open
  (train) and the sealed (test) half both gain more than the rule's
  `min_gain`, and run-to-run noise is below it. Train up with test flat is
  reverted.
- `run.sh` sets `CRITIC_KNOWN_FINDINGS=0` and `CR_TRIVIALITY_OVERRIDE=full`,
  which production `/pr-check` does not, so both halves grade the panel as this
  eval runs it, not the production reviewer.

Adding the split changed the key, so it started a new eval-compare series.

## Adding a fixture

Write the seeded diff and its clean twin as two `case-NN.patch` files with new
opaque ids, add both to `key/seeds.json` under one `pair` with one `split`
(keep one pair of every class in each half), and run
`python3 scripts/eval/review-panel/score.py lint`. Changing any fixture or the
key changes `config.fixture_set`, and retuning the class keywords changes
`config.class_patterns`; either starts a new eval-compare series.

### Real-escape cases (`real-*`)

A `real-NN.patch` is a defect review let through, frozen from history. Its key
entry carries `base` (the commit the diff builds on), `fix` (the commit that
repaired it) and optionally `context_seed` (a file outside the diff the seed
sits in); an optional `real-NN.intent.md` holds the PR's frozen intent. `lint`
checks the diff applies to `base` and that a seeded case carries no line of its
`fix` (`--src <repo>` names the repo the commits live in; default this
checkout); `lint --min-real N` refuses a set with fewer than N real cases.

- `run.sh --case-repo <id> --out <dest>` builds the scratch repo a critic
  reviews: the `base` tree without `scripts/eval/review-panel/`, one commit,
  then the case diff as a second commit. No later history, no CR ledger, no key.
- `harvest.py --prs <gh pr list json>` lists candidate escapes (reverts,
  caused-by bugs, fix-forwards, judge NO-GOs, `deferred-escape` tickets), one
  JSON line each with the escaped `head`, its `base` and its `fix`. It builds no
  case: curating candidates into fixtures is a human step.

#### The shipped real corpus (HIMMEL-8427)

30 escapes and their 30 clean twins, each pair with an intent file:
`real-NNN.patch`, `real-NNN-clean.patch`, `real-NNN.intent.md` and
`real-NNN-clean.intent.md` (the same text in both). Each pair is one `pair` in
the key; every class has an open and a sealed pair, and each half holds 15 pairs.
`lint --min-real N` counts case files, so the 30 pairs are 60 real cases and
the full set passes `--min-real 60`. By class: logic 8, fail-open 5,
test-cannot-fail 5, cross-file 4, spec-miss 4, quoting 2, toctou 2. Slice 1
(PR 4424) shipped `real-001` to `real-010`; the remainder PR shipped
`real-011` to `real-030`. The 30 count has no shortfall.

| pair | class | split | PR | ticket | seed site |
|---|---|---|---|---|---|
| `real-001` | logic | open | 2454 | HIMMEL-5385 | `scripts/hooks/block-destructive-commands.sh:1037` |
| `real-002` | logic | sealed | 3115 | HIMMEL-6402 | `scripts/handover/console-kit/board.mjs:340` |
| `real-003` | fail-open | open | 2231 | HIMMEL-5034 | `scripts/hooks/auto-approve-safe-bash.sh:1774` |
| `real-004` | fail-open | sealed | 2427 | HIMMEL-5350 | `scripts/codex/dispatch-codex-exec.sh:568` |
| `real-005` | test-cannot-fail | open | 4267 | HIMMEL-8008 | `scripts/hooks/test-block-write-into-main-checkout-evaldata.sh:186` |
| `real-006` | test-cannot-fail | sealed | 3738 | HIMMEL-7345 | `scripts/cr/test-pr-check-rounds.sh:346` |
| `real-007` | cross-file | open | 4386 | HIMMEL-8304 | `scripts/handover/chief/chief.sh:376` (judge LT-j4386-1: the bus reader and the chief writers change in one diff) |
| `real-008` | cross-file | sealed | 3618 | HIMMEL-7061 | `scripts/handover/console-kit/action-zero.sh:127` (the re-render path is documented in `docs/handover/console-sections/live-state.md`) |
| `real-009` | spec-miss | open | 4364 | HIMMEL-8365 | `scripts/telegram/afk-sudo-route.ts:161` |
| `real-010` | spec-miss | sealed | 4186 | HIMMEL-8028 | `scripts/handover/chief-kit/next-dispatchable.sh:900` |
| `real-011` | logic | open | 3617 | HIMMEL-7064 | `scripts/handover/console-kit/next-dispatchable.sh:501` (a Story is admitted to RESUME while the IN CI merged-PR lookup still excludes it) |
| `real-012` | logic | sealed | 4297 | HIMMEL-8238 | `scripts/handover/chief-kit/ready-check.sh:307` |
| `real-013` | logic | open | 4357 | HIMMEL-8348 | `scripts/jira/src/release/engine.ts:507` |
| `real-014` | logic | sealed | 4188 | HIMMEL-6829 | `scripts/handover/chief-kit/status-drift.sh:194` |
| `real-015` | logic | open | 3978 | HIMMEL-6415 | `scripts/cr/install-cr-gate.sh:385` |
| `real-016` | logic | sealed | 3713 | HIMMEL-7045 | `scripts/lib/gh-ci-cache.sh:351` |
| `real-017` | fail-open | open | 3975 | HIMMEL-6347 | `scripts/hooks/block-read-secrets.sh:1021` |
| `real-018` | fail-open | sealed | 4306 | HIMMEL-8200 | `scripts/hooks/block-write-into-main-checkout.sh:2813` |
| `real-019` | fail-open | open | 3047 | HIMMEL-6256 | `scripts/ci/shellcheck-pr-range.sh:53` |
| `real-020` | test-cannot-fail | sealed | 3035 | HIMMEL-6113 | `scripts/config-ui/tests/agui-fleet.test.ts:196` |
| `real-021` | test-cannot-fail | open | 4098 | HIMMEL-7912 | `scripts/hooks/test-block-edit-live-settings.sh:1368` |
| `real-022` | test-cannot-fail | sealed | 3646 | HIMMEL-7145 | `scripts/handover/console-kit/ready-check.sh:449` |
| `real-023` | toctou | open | 2827 | HIMMEL-5882 | `scripts/luna/qmd-embed-model.sh:418` |
| `real-024` | toctou | sealed | 3152 | HIMMEL-6422 | `scripts/lib/bank-preflight.sh:559` |
| `real-025` | quoting | open | 3620 | HIMMEL-7009 | `scripts/hooks/block-chokepoint-env-prefix.sh:306` |
| `real-026` | quoting | sealed | 2528 | HIMMEL-3655 | `scripts/hooks/auto-approve-safe-bash.sh:1230` |
| `real-027` | cross-file | open | 3420 | HIMMEL-6666 | `scripts/ci/queue-latency.sh:129` (the only reader of the probe line is `tick.sh`, outside the diff) |
| `real-028` | cross-file | sealed | 2768 | HIMMEL-1332 | `scripts/handover/arm-resume.sh:2758` (`hop.sh` and the auto-arm snapshots still decline the default) |
| `real-029` | spec-miss | open | 4461 | HIMMEL-8197 | `scripts/handover/chief-kit/chief-wait.sh:850` |
| `real-030` | spec-miss | sealed | 4314 | HIMMEL-8206 | `scripts/telegram/afk-sudo-route.ts:167` |

How a pair is built. The escaped case is the diff from the PR's merge-base with
main to the head the judge ruled NO-GO on. Its clean twin is that same diff plus
the one commit that repaired the finding, so the twin differs from the escape by
the repair only. Both apply to the merge-base (`base` in the key). The repairing
commit is the first commit after the NO-GO head that touches the diff's files
(a PR's merged head can carry later work too, so the harvest `fix` is too wide
for this); for `real-007` it is the bus fix commit, and its clean twin leaves
out `scripts/config-ui/tests/agui-fleet-bus.test.ts`, whose context carries the
hint word `seed` that `lint` refuses.

The shipped key has no `fix`. The repairing commits lived on branches that were
squash-merged, so they are in no ref a CI checkout fetches, and a `fix` there
would make `lint` fail with "not a commit". The leak check ran at curation
against each repairing commit (0 shared lines for `real-001` to `real-010`; for
`real-007` against the PR's merged head, since the repairing commit's test lines
recur in the escaped diff). For `real-011` to `real-030` the lines a repair adds
that also stand in the escaped diff are test scaffolding only (a `rc=$?`
capture, a loop header, a `settle()` call), never the repairing logic: at most 5
such lines per pair, 14 for `real-030` whose repair adds a short test beside an
existing one. A later pair whose repair is reachable from main should carry
`fix` again.

Harvest at curation (merged-PR history plus judge verdicts, 2026-10-31): 1378
candidates: judge NO-GO 913, fix-forward 462, revert 2, `deferred-escape` 1,
caused-by 0; 1335 carry a `base` and a `fix`. The 30 pairs come from the NO-GO
and small-diff end of that list (diffs of at most 5 files and about 120 added
lines, except `real-007`, the required cross-file case, which touches 16 files).
The remainder pass re-ran the harvest (1357 candidates since 2026-09-01) and kept
the NO-GO verdicts with a repairing commit still in the local clone; every pair
was read against its judge verdict, and a candidate whose diff carries a hint
word (`seed`, `inject`, `planted`, `defect`, `canary`) was dropped for another.

A patch is written with the smallest context (3, else 2, else 1 lines) that does
not end it in a blank line, because `end-of-file-fixer` strips that line and
breaks the last hunk; `trailing-whitespace` also empties blank context lines,
which `git apply` still accepts.

The suite rows cover the corpus shape (30 and 30, the class counts with at least
4 cross-file and 4 spec-miss, 15 open and 15 sealed pairs, an open and a sealed
pair per class), `lint --min-real 60` (the flag counts case files, so 30 pairs
are 60) and, for every shipped case, the case-repo isolation row: two commits,
nothing under `scripts/eval/review-panel/`, no `cr-*` state under `.git`, no key
canary, and the head commit is exactly the case diff. The integrity, split and
sweep rows run on the 24 synthetic cases only.

The two baseline sweeps over the grown corpus are the chief's; their
`results.jsonl` rows (runs `2026-11-01-8427-mw1` and `-mw2`) are committed with the
remainder PR. Both are `status=partial`: delta-06 is unscored in each because the
citation guard drops its finding, and the gate ignores partial rows, so RL4 reads no
ok row until that case scores (HIMMEL-8570).

### Delta cases (`delta-*`, HIMMEL-8429)

Review rounds 2 and 3 will review only what changed since the last round, so
the eval grades that: a delta case is a round-1 diff plus the fix delta that
follows it, with the defect in the delta.

| file | what |
|---|---|
| `delta-NN.patch` | the round-1 diff (a new-file diff, like a `case-NN`) |
| `delta-NN.delta.patch` | the fix delta on top of it; the seeded twin's delta holds the defect, the clean twin's delta is the correct fix |
| `key/seeds.json` entry | the usual case entry plus `"delta": true`; `defects[].file`/`line` are a file and a new-file line of the delta |

`score.py lint` refuses a key entry marked `delta` with no `<id>.delta.patch`, a
`*.delta.patch` whose case the key does not mark delta, a delta that does not
apply on the tree its round-1 diff builds (cases with a `base` skip that check),
a seed line that is not an added line of the delta, and a delta patch carrying
the canary, the key path or a hint word. The twin rule reads the deltas.

`run.sh` feeds a delta case to the panel with the **delta as the diff** (stdin)
and `--context-file context.patch` (the round-1 diff then the delta) in the
critic's scratch dir; the critic sees nothing else. Any sweep does this for the
key's delta cases; `run.sh --delta` sweeps only them (a subset sweep like
`--only`, exclusive with it, not gate-eligible).

The shipped 10 are 5 pairs, split by hand (3 open, 2 sealed): `logic` (the delta
inverts `is_stale`, the unchanged caller keeps the old sense), `fail-open` (an
unreadable commit-message file allows the commit), `scope-creep` (a dry-run fix
that also lowers the retention default), `test-cannot-fail` (an assertion that
compares a call with itself) and `quoting` (an unquoted exclude argument). The
pairs add to the 22 + 22 above; adding them changed `config.fixture_set`, so
they start a new eval-compare series and need the base re-baseline sweeps.

## The merge gate (HIMMEL-8426)

`cbs.txt` lists the critic behaviour set: every path whose change can move what
the panel reports (a `dir/` prefix or a glob at the same `/` depth). A PR that
changes one of them, at its base or its head, merges only when the eval says the
change lost nothing.

1. The chief sweeps twice at the PR's base and twice at its head (`run.sh`,
   above), and records each sweep with
   `score.py export-row <outputs-dir>`: one `results.jsonl` row carrying the
   tree's `cbs_hash` and `confighash` and the `outputs_sha256` of the bundle.
   `run.sh` stamps the swept tree into `<outputs-dir>/swept.json`; export-row
   refuses outputs with no stamp, a stamp of other hashes, or a sweep run from a
   working tree that differed from its HEAD on a gate input (a CBS path,
   `critics.json`, or any file here but `results.jsonl`), through a
   `REVIEW_PANEL_CMD` other than the tree's `critic-panel.sh`, or with
   `--tiers` other than `paid`, or over an `--only` subset. `run.sh` re-stamps
   after the panel loop (`stamp --recheck`), so a gate input edited during the
   sweep, or a moved HEAD, also leaves it unclean, and a sweep interrupted before
   that re-stamp is refused. An `inconclusive` sweep is
   refused, and the gate ignores any row whose status is not `ok`: a `partial`
   sweep scores fewer cases, so its rates are not comparable.
2. `score.py verify-row '<row-json>' <outputs-dir>` re-derives a row from its
   outputs (exit 1 on any mismatch), so a committed row can be checked against
   the bundle it claims.
3. CI runs `scripts/ci/check-critic-eval.sh <base> HEAD` (the ci-quick
   secret-scan step). With no CBS path changed it passes; otherwise it runs
   `score.py gate`, which reads the head tree's `results.jsonl`:
   - **unmeasured** (fail): fewer than 2 distinct rows (by `run_id` and bundle)
     at the base or the head `cbs_hash` for the head tree's `confighash`.
   - **loss** (fail): `panel.recall_gating` fell, or `panel.fp_rate` rose, by
     more than the baseline rows' spread (max minus min).
   - **no-loss** / **keep** (pass): within noise; `keep` when every
     `--target-class` recall also beats the baseline maximum.

The hashes are of the merge ref: a later critic change on main changes the head
`cbs_hash`, so the rows no longer count and the PR is swept again. Every CBS
path, this directory and `scripts/eval/lib/` (every module `score.py` can import) are trust paths
(`scripts/ci/ci-trust-paths.txt`), so a PR cannot weaken its own gate.
