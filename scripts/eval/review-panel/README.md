# review-panel recall eval

How many real defects does the review panel (`scripts/cr/critic-panel.sh`, the
critic half of `/pr-check`) catch, and how often does it raise one that is not
there? The CR ledger only has agreed%, a precision proxy the PR author decides.
This eval feeds the panel frozen diffs with labelled target defects (synthetic,
historical and delta cases) and clean twins of the same diffs, then scores what
it reports against a key it never sees. Its numbers are automated key-match
proxies, not verified accuracy. It measures the codex and Claude
critics only: CodeRabbit history is reported separately; controlled recall is
not measured here.

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

The `paid` tier holds two critics: `codex` (bank) and `claude` (provider
`claude-api`, billed per API token). `--critics` cuts the roster the panel runs
(the swept tree's `critics.json` minus every other slug), so `--critics codex` is
a codex-only sweep. A roster that still holds the claude row refuses before the
first case unless `--allow-claude-api` is passed (operator decision 525). Every
case in the key is one panel call per critic in the roster, so a codex-only sweep
is 94 panel calls; that is a floor, because each critic can take up to 3 attempts.
Workers never run it. From the primary checkout, after
`bash scripts/lib/usage-preflight.sh` says PROCEED and with the codex
`used_percent` noted:

```bash
bash scripts/eval/review-panel/run.sh --out ~/.himmel/eval/review-panel/2026-10-07 --no-ledger --critics codex
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

| metric (legacy alias) | definition |
|---|---|
| `<c>.key_match_recall` (`<c>.recall`) | labelled defects with a location+class hit / labelled defects in the cases the critic answered |
| `<c>.location_match_recall` (`<c>.recall_loc`) | the same with location only: the upper bound, so a keyword miss shows as a gap, not semantic recall |
| `<c>.key_match_recall_gating` (`<c>.recall_gating`) | hits at Critical or Important (what the CR gate blocks on) / the same defects |
| `<c>.key_match_precision` (`<c>.precision`) | findings that key-match some labelled defect / all parsed findings: a match fraction, not "was right" (a real unlabelled issue counts against it) |
| `<c>.labelled_clean_block_rate` (`<c>.fp_rate`) | answered labelled-clean twins with >= 1 Critical/Important finding / answered labelled-clean twins: it does not say the blocker is false |
| `<c>.class.<cls>.recall` | recall per class, with `.n` |
| `defects`, `cases`, `unscored`, `leaked` | run totals |

`<c>` is each rostered critic slug plus `panel` (the union of all critics). Each
legacy key keeps its formula and is written beside its explicit name; new
readers use the explicit name. A case whose
review was not performed (no output, `REVIEW NOT PERFORMED`, a transcript
missing any of the three severity headings or carrying fewer bullets than a
heading's `(N found)`, a nonzero panel exit in
`<case>.rc`, or a finding of a critic the roster does not name) is unscored.
Recall, precision and the blocking rate carry Wilson 95% intervals in the row's
`ci`; a zero denominator is null, not 0.

### Participation

`case_participation()` gives every rostered critic one record per case, and
every per-critic denominator and the `responded` counts read only it:
`{state, category, effective, header_included, reason, evidence,
responding_model}` under `case_evidence[<case>].critics[<critic>]` of the
`--json` output. `state` is `answered`, `unavailable` or `unknown`.

- **answered**: a valid finding, an `ok` / `fallback(<model>)` receipt on
  stderr, or a header `N/M` that reconciles (M is exactly the header-counted
  critics and the N answer slots left are exactly the unaccounted ones, so a
  2/2 empty review is two zero-finding answers). `responding_model` comes from
  the receipt, else null.
- **protocol skip** (`effective` false, outside denominators and failure
  counts): `tier-excluded` and `keep-one-skipped` never ran and hold no header
  slot; `critic-skipped` (an api lane off) holds its slot.
- **failure** (`effective` true, `unavailable`): timeout, a nonzero rc,
  malformed output, a panel deadline. A deadline before launch holds no header
  slot; one inside a counted fallback chain does.
- **unknown**: nothing names the critic and the header does not settle it (a
  1/2 header with only the other critic's findings infers no failure for this
  one; a roster member beyond the header's M is never a phantom answer).
  An answer beside an unavailable receipt, receipts that disagree, impossible
  counts or a non-rostered slug are `inconsistent`.

The panel metrics count every completed case; a critic counts only the cases
it answered. `coverage` counts each category per critic. `decision_eligible`
and `ineligibility_reasons` follow the execution provenance rules under "The
merge gate". n is small (12 defects, 2 per class): a per-class
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

## Validated corpus and adjudication

The proxy metrics above are keyword matching. Verified correctness is a separate
family, built from two sidecars, and the two families are never merged. A
paraphrased correct finding is a verified hit, though it fails the keyword
match. A wrong claim that happens to contain the class words keyword-matches,
but is never a verified hit.

- **`key/validation.json`** (the reviewed gold, v1) has one entry per key case
  id: `state` (pending | validated | excluded), `effective_kind` (seeded |
  clean | excluded), `mechanism`, `trigger`, `expected_behavior`, `target_ids`
  (key defect ids, or `added_targets` `{id, file, line, description}` for a
  relabelled clean twin), `repair_evidence`, `evidence_refs`, `curator`,
  `reviewer`, `reviewed_at`, and an optional `curation` note. A clean entry
  states its `contract` and lists explicit `residuals` (`{id, description}`
  only). A residual carrying a pattern or match rule fails lint. A validated or
  excluded entry needs a `reviewer` who is not its `curator`, a `reviewed_at`
  date and evidence. `score.py lint` checks the sidecar beside `--key` (or
  `--validation FILE`). seeds.json and the fixtures stay the execution corpus,
  so relabelling needs no new run; a changed diff or context does.
- **gold_revision** is the sha256 of the exact sidecar bytes. Score rows carry
  it outside the stamp's `confighash`, so a gold edit changes the gold revision,
  never the stamp. `verify-row --validation FILE` checks a claimed
  gold_revision against the sidecar it reads. The default is the running
  scorer checkout's `key/validation.json`, never the `--tree` one. A row with
  no gold_revision (proxy only) needs no sidecar.
- **Adjudications** live in a private JSONL kept outside the raw bundles, one
  label per line: `v`, `case_id`, `case_input_sha256` (the case's diff,
  context, intent and base digests), `gold_revision`, `finding_sha256` (the
  finding's severity, file, line and text, never its bullet id, critic or
  model), `observed_execution_ids`, `correctness` (correct | incorrect |
  unresolved), `target_ids`, `scope` (in | out | unknown), `severity_valid`
  (true | false | null), `rationale`, `evidence_refs`, `adjudicator`,
  `reviewed_by`, `adjudicated_at`. A target ruling (`"kind": "target"`,
  `target_id`, `ruling: "missed"`, `reviewed_findings`) settles a miss while
  unrelated claims stay unresolved.

  An identical finding in a repeated execution reuses its label. A changed case
  input, gold revision or finding text voids it, and so does missing evidence or
  a label its own adjudicator reviewed; each shows as a diagnostic. Two labels
  of one identity that disagree refuse the run (exit 2).

`score --adjudications FILE` adds `verified` to the JSON and a verified block
to the report. The cohort holds whole twin pairs whose entries are all
validated: a sealed or open pair with a pending twin leaves together, and its
name is listed. A relabelled twin is named too. Per critic and for the panel,
the block reports:

| metric | definition |
|---|---|
| `verified_defect_recall_lo` / `_hi` | targets with a correct attributed finding / validated targets. hi also counts each target still possibly covered by an undecided finding. The point value `verified_defect_recall` is given only when lo equals hi |
| `verified_gating_recall_lo` / `_hi` | the same at Critical/Important; an unknown `severity_valid` counts as uncertainty |
| `adjudicated_precision` | correct / (correct + incorrect) findings, with `adjudication_coverage` and the unlabelled and out-of-scope counts |
| `verified_false_block_rate` | validated clean twins with an unjustified blocker / validated clean twins |

A target is missed when a target ruling covers every finding of the case, or
when every one of the critic's findings in it is decided. A blocker is
unjustified when it is labelled incorrect, out of contract, or
`severity_valid` false. A correct concern that is out of contract, or rated
above its weight, stays correct for precision. A correct, in-contract,
rightly rated blocker disputes its clean control instead: the rate is
withheld until the case is curated. Any undecided blocker also withholds it.
Every rate carries exact k/n under `counts`.

None of this is a decision by itself. The shipped sidecar is all pending
(curated, not independently reviewed), so the benchmark is **not
decision-ready**. Readiness needs a validated cohort and a pre-registered
decision margin.

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
citation guard drops its finding, and the gate ignores partial rows. The baseline
rows are `8429-head-b` and `8429-head-e` at `status=ok`: the partial bundles of those
runs, re-scored after HIMMEL-8596 made the scorer count that finding. A sweep can
still go partial on a nonzero panel exit.

**Spend note, 2026-11-04 (HIMMEL-9214).** The four PR 4690 sweeps
(`~/.himmel/eval/review-panel/2026-11-04-pr4690-{base,head}-r{1,2}`) were meant as
codex only (decision 557) but ran **claude plus codex**: `--critics codex` then only
filtered scoring, and the panel ran the whole paid tier. They made about 375
claude-opus-5-5 API calls against decision 525. Their rows are claude plus codex,
not codex-only, and the cost reports must count that spend; operator decision 571
has the rows re-run codex-only after the HIMMEL-9214 fix.

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

1. The chief sweeps twice at the tree the gate compares against (on CI's merge
   ref, main as that ref was built) and twice at the PR's head (`run.sh`,
   above), and records each sweep with
   `score.py export-row <outputs-dir>`: one `results.jsonl` row carrying the
   tree's `cbs_hash` and `confighash`, the `outputs_sha256` of the bundle and
   the `scorer_sha256` of the scorer that ran (below).
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
   the bundle it claims. A legacy row with no `scorer_sha256` is compared on
   the fields and metrics it claims and printed `scorer identity unverified`; a
   value a scoring repair moved still differs. A row naming a scorer must name
   the running one.
3. CI runs `scripts/ci/check-critic-eval.sh <base> HEAD` (the ci-quick
   secret-scan step). HEAD is the PR's merge ref, so the gate's diff base is
   `HEAD^1`, the main that ref was built on, not the event's `<base>`, which
   stays at the main the PR opened on; elsewhere the diff base is `<base>`.
   With no CBS path changed it passes; otherwise it runs
   `score.py gate`, which reads the head tree's `results.jsonl`:
   - **unmeasured** (fail): the running scorer has no clean identity, no row
     carries its `scorer_sha256`, or fewer than 2 distinct rows (by `run_id`
     and bundle) of it at the base or the head `cbs_hash` for the head tree's
     `confighash`.
   - **loss** (fail): `panel.recall_gating` fell, or `panel.fp_rate` rose, by
     more than the baseline rows' spread (max minus min).
   - **no-loss** / **keep** (pass): within noise; `keep` when every
     `--target-class` recall also beats the baseline maximum.

**Execution provenance.** `run.sh`'s first `stamp` also writes
`<outputs>/run-manifest.json` (v1): a stable `execution_id`, `started_at`, the
`code_under_test_sha` and `cbs_hash` of the swept tree, `corpus_sha256`, the
requested and the effective (tier-filtered) roster, each critic's provider,
requested and resolved model and effort, the protocol (tiers, `--only`,
context mode, known-findings and triviality settings, the runner digest and the
recorded panel overrides `CRITIC_TIMEOUT_SECS`,
`CRITIC_PANEL_TOTAL_TIMEOUT_SECS`, `CRITIC_KILL_GRACE_SECS`, `CRITIC_PARALLEL`,
`CRITIC_FIRST_PASS_CAP_BYTES`) and the input digests of every case (diff,
context, intent, base). `stamp --recheck` completes it: `finished_at`, each
case's responding models from its `ok responding-model(...)` or `fallback(...)`
receipts, the run's observed set per critic, and each case's anomalies (an
error line on stderr, such as an unbound variable, from a case whose panel
exited 0). No credentials or prompt bodies are stored. `run.sh` drops an
inherited `CRITIC_FIRST_PASS` or `CRITIC_INVOKE` before it calls the panel, and
`stamp` and `score` refuse a `--model` the effective roster does not run (or
cannot be checked against, when no `critics.run.json` exists): `--model` labels
the run, it cannot relabel it. The score row never records the scoring
session's own model, effort or CLI version as the critic's.

`outputs_sha256` keeps its legacy formula over the case md/err/rc files.
`bundle_sha256_v2` covers those files plus `critics.run.json` and
`run-manifest.json`, so an edited roster or manifest is a different bundle.
export-row also writes `execution_id`, `code_under_test_sha` (the swept tree,
kept on a later re-score; `scorer_gitsha` is the scoring tree), `scored_at`,
`provenance_status` (`recorded`, `reconstructed`, `missing` or `unreadable`),
`decision_eligible` and `ineligibility_reasons`. A row is eligible only when
its execution is a recorded, finished one with a recorded roster and no
anomaly, its status is `ok`, every critic's participation is consistent and
known, and its scorer identity is clean. `sweep_roster` reads only the rows in
the swept tiers; a missing, malformed or empty `critics.run.json` falls back to
the tree's roster with a warning that it is reconstructed. Eligibility is not
yet a gate condition: the shared selector comes with M3.

**Scorer identity.** A row names the scorer that produced it,
never one in the gate's `--repo` or `--tree`: `score.py scorer-identity --json`
is `score.py`'s own checkout, its HEAD and the `score.py`,
`scripts/eval/lib/wilson.py` and `adjudication.py` actually loaded, each checked
byte for byte against that HEAD before and after scoring
(`scorer_digest(repo, rev)` hashes those three blobs). An edited, untracked or foreign scorer file gives
`scorer_sha256` null and a diagnostic-only row. The gate drops every row of
another or no scorer (named in its output) before the roster check and
before the first-row-wins selection, so a re-score of a retained sweep by the
running scorer replaces its older row, and a null identity matches nothing.
`scorer_sha256` is kept apart from `confighash` and `swept.json`, so a stamp
from before it still exports. Old rows carry no `scorer_sha256`: until rows of
the current scorer are promoted, every critic-behaviour PR is unmeasured.

Two rules sit in front of that eval check. Neither reads its input from the
PR's own tree, so a PR cannot retag its own files or add its own bypass. The
`# unexecuted:` tags are read at the diff base, which a push rebuilds on newer
main. The bypass file is read at the default branch's tip as CI's checkout
fetched it (`refs/remotes/origin/<base branch>`); when that cannot be read the
gate falls back to the diff base and prints one line naming the missing input.
A tag or row a change needs must be on main, and needs no merge into the
branch. So a merged tag exempts every open PR whose merge ref is rebuilt after
it lands, not only PRs opened later: a tag-only `cbs.txt` change needs a
trust-reviewed GO (this directory is a trust path).

4. **A path the sweep never executes needs no eval rows.** `run.sh` feeds
   `critic-panel.sh` directly, so a change to a file the sweep never runs gives
   the base and head sweeps identical critics and the eval can only read noise.
   `cbs.txt` marks each such path with a comment line `# unexecuted: <path>`
   (`score.py` ignores comments, so the hash and the path list are unchanged).
   When every changed CBS path is tagged, the gate passes and prints "only paths
   the sweep never executes changed: ...; a judge GO covers them": the review is
   a judge GO, not eval rows. One changed CBS path that is not tagged puts the
   whole diff back on the eval check. Tag a path only after tracing that no
   sweep call reaches it.
5. **An operator bypass is a recorded row.** `gate-bypass.tsv` holds one row per
   bypass: `pr`, a `head` sha prefix of 7 or more hex digits (a new row writes
   the full 40-hex head), the `decision` id, and the `reason`, separated by
   tabs. The gate reads the file at the default branch's tip (else at the diff
   base), never from the PR's own tree, so a row landed on main after the PR
   opened counts without being merged into the branch. The gate honours a row only for its PR
   number (`CHECK_CRITIC_EVAL_PR`, else the `refs/pull/<n>/merge` of
   `GITHUB_REF`) at its head (the head given; on CI's `refs/pull/<n>/merge`
   also the merge ref's second parent, which is the PR head), and prints a `BYPASS honoured` line with the decision and reason. A row
   for another PR or another head does nothing. A malformed row (wrong column
   count, a non-numeric PR, a prefix under 7 hex digits, an empty decision or
   reason) fails the gate closed. A row lands by a chief-ruled change of its own.

The hashes are of the merge ref: a later critic change on main changes the head
`cbs_hash`, and also the base rows' `cbs_hash`, which is the diff base's
(`HEAD^1` on CI's merge ref), so the rows no longer count and the PR is swept
again; the base sweeps run at main as the merge ref was built, not at the main
the PR opened on. Every CBS path, this directory and `scripts/eval/lib/` (every
module `score.py` can import) are trust paths (`scripts/ci/ci-trust-paths.txt`),
as are `scripts/ci/` and `.github/`, since `ci.yml` runs the gate script from
the PR's merge ref, so a PR cannot weaken its own gate.
