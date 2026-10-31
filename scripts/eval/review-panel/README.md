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

## The merge gate (HIMMEL-8426)

`cbs.txt` lists the critic behaviour set: every path whose change can move what
the panel reports (a `dir/` prefix or a glob at the same `/` depth). A PR that
changes one of them, at its base or its head, merges only when the eval says the
change lost nothing.

1. The chief sweeps twice at the PR's base and twice at its head (`run.sh`,
   above), and records each sweep with
   `score.py export-row <outputs-dir>`: one `results.jsonl` row carrying the
   tree's `cbs_hash` and `confighash` and the `outputs_sha256` of the bundle.
   An `inconclusive` sweep is refused.
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
path, this directory and `scripts/eval/lib/eval_feedback.py` are trust paths
(`scripts/ci/ci-trust-paths.txt`), so a PR cannot weaken its own gate.
