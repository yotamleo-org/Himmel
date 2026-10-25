# Review panel — what the CR ledger says about its critics

> Evaluation write-up, read off the production ledger. The headline numbers are
> regenerated from the live ledger by `scripts/eval/review-page.py --panel`, which
> counts each finding once and states its own cut. The sections after it are a
> fixed cut (`--until 2026-10-06T20:00:00Z`) and re-run byte-for-byte with the
> command at the end. The controlled complement — seeded defects with a hidden key, which
> measures recall — is [`scripts/eval/review-panel/`](../../scripts/eval/review-panel/README.md).
> This page measures what that one cannot: how the panel behaves
> on real PRs, and why its findings get thrown out.

## What is being measured

Every himmel PR goes through `/pr-check`, whose critic half
(`scripts/cr/critic-panel.sh`) sends the diff to one or more model critics.
Each finding they raise is written to an append-only ledger
(`<git common dir>/cr-critic-scores.jsonl`). The PR author (in practice a
Claude session) then records a verdict on every finding as a later `amend`
record:

| Verdict | Meaning | Counted as |
|---|---|---|
| `agreed`, `fixed` | the finding is real; the code changed or will | **agreed** |
| `disproved` | the finding is wrong, with a written reason | **disproved** |
| `deferred` | real or plausible, filed as a follow-up ticket, not fixed in this PR | **deferred** |
| *(none)* | no verdict was ever recorded | **unadjudicated** |

**Precision** here is `agreed / (agreed + disproved)`: of the findings the
author ruled on as true or false, the share ruled true. It leaves deferred and
unadjudicated findings out of both sides. It is a *precision proxy*, not
precision: the author who rules is also the party that has to fix the finding
(see [Limitations](#limitations)).

A **critic** is the panel slug plus the model that actually answered, joined
from the ledger's `avail` row for the same branch, head and slug. That makes a
model re-pin of the same slug show up as a new critic (`codex:gpt-6-sol`,
`codex:gpt-6.1-sol`). A slug with no responding model on record stays bare
(`codex`, `claude`).

Intervals are 95% percentile bootstrap intervals (2,000 resamples, seed 0,
`bootstrap_ci` in `scripts/eval/lib/eval_runs.py`) that **resample whole PRs**,
not findings. Findings on one PR share an author, a diff and a review loop, so
they are not independent; resampling findings one by one would give intervals
too narrow by roughly the square root of findings-per-PR. "PR" here means a
branch: almost every branch is one PR, but a few are not.

<!-- review-page.py --panel: start -->
## Headline numbers

As of 25 Oct 2026 (CR ledger cut `2026-10-25T02:30:00Z`): 11,646 distinct findings across 2,147 PRs, 2026-09-04 to 2026-10-25.

The ledger holds 11,720 finding rows. 74 of them repeat a finding already counted here: the same claim on the same file and line of the same PR, raised again in a later round or by another critic. A merged finding takes the verdict of its earliest raise that has one. A finding with no recorded text is never merged.

Per PR: 3,322 PRs reviewed, 2,147 with at least one finding; median 3 and mean 5.4 distinct findings per PR with findings, at most 87 on one PR.

| Critic | Findings | PRs | Agreed | Disproved | Deferred | Unadjudicated | Precision | 95% CI |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `codex:gpt-5.6-sol` | 231 | 27 | 95 | 18 | 35 | 83 | 84.1% | 74.2–91.7 |
| `citation-guard` | 15 | 15 | 7 | 6 | 1 | 1 | 53.8% | 30.8–76.9 |
| `codex:gpt-6-astra` | 2,435 | 362 | 1,099 | 132 | 697 | 507 | 89.3% | 86.1–92.0 |
| `codex` | 109 | 8 | 100 | 2 | 7 | 0 | 98.0% | 95.8–100.0 |
| `coderabbit` | 87 | 52 | 57 | 5 | 25 | 0 | 91.9% | 82.6–100.0 |
| `sonnet` | 24 | 1 | 22 | 1 | 1 | 0 | 95.7% | — |
| `unlabelled` | 48 | 11 | 0 | 0 | 47 | 1 | — | — |
| `claude` | 130 | 58 | 24 | 0 | 106 | 0 | 100.0% | 100.0–100.0 |
| `coderabbit-outside` | 216 | 119 | 67 | 54 | 95 | 0 | 55.4% | 44.1–65.1 |
| `codex:gpt-6-sol` | 872 | 169 | 443 | 184 | 234 | 11 | 70.7% | 64.8–76.2 |
| `codex:gpt-6.1-sol` | 7,079 | 1,500 | 3,996 | 1,026 | 2,016 | 41 | 79.6% | 77.9–81.2 |
| `claude:claude-opus-5-5` | 341 | 36 | 93 | 100 | 138 | 10 | 48.2% | 36.5–59.2 |
| `disposition-carry-forward` | 13 | 2 | 0 | 0 | 13 | 0 | — | — |
| other (25 slugs under 10 findings each) | 50 | 34 | 10 | 0 | 40 | 0 | 100.0% | 100.0–100.0 |
| **All** | **11,646** | **2,147** | **6,012** | **1,528** | **3,452** | **654** | **79.7%** | 78.3–81.2 |

A finding raised by two critics counts once in each critic's row and once in **All**. Precision is agreed / (agreed + disproved); the interval resamples whole PRs.

- Of the 11,646 distinct findings, 51.6% were agreed, 13.1% disproved, 29.6% deferred and 5.6% never ruled on.
- Precision by severity: Critical 78.1% (276 findings, CI 70.6–84.9); Important 82.8% (4,962 findings, CI 80.8–84.5); Suggestion 76.4% (6,345 findings, CI 74.4–78.2).
- 2,284 of the 3,452 deferred findings carry a follow-up class: 1,407 `polish`, 808 `hardening`, 69 `escape`.

Regenerate this section from a himmel checkout (the cut makes it re-run exactly):

```bash
python3 scripts/eval/review-page.py --panel --until 2026-10-25T02:30:00Z --out docs/evals/review-panel.md
```
<!-- review-page.py --panel: end -->

## Before and after: the gpt-6.1-sol re-pin

The panel's critic model is pinned in `scripts/cr/critics.json`. The ledger
window covers three re-pins of the `codex` slug: gpt-5.6-sol → gpt-6-astra,
→ gpt-6-sol on 2026-09-23 (#1155), → gpt-6.1-sol on
2026-09-29 (#1462). The last one is the cleanest comparison: the
two eras sit back to back, both have complete verdicts, and the change was
model-only ("logic unchanged" in the PR).

| | gpt-6-sol (09-23 → 09-29) | gpt-6.1-sol (09-29 → 10-06) |
|---|---:|---:|
| Findings / PRs | 873 / 169 | 1,980 / 330 |
| Findings per PR | 5.2 | 6.0 |
| Disproved share | 21.1% | 10.8% |
| Precision (95% CI) | 70.7% (64.8–76.2) | 83.0% (79.8–86.1) |
| Share flagged Critical | 12.6% | 1.3% |
| Precision, Important only | 69.6% (62.1–77.3) | 87.8% (84.0–91.2) |
| Precision, Suggestion only | 67.2% (60.4–74.9) | 76.4% (71.5–80.6) |

The re-pin **halved the disproved rate** (21.1% → 10.8%) and lifted precision
by 12 points, with intervals that do not overlap. gpt-6-sol also called one
finding in eight Critical, against one in eighty for its successor, so the
first check was that the gain was not a severity-mix artefact. It holds within
a severity: on Important findings precision rose from 69.6% to 87.8%, intervals
again disjoint. Suggestions improved less, and their intervals touch.

What could still confound it: the PRs differ between the eras (no PR was
reviewed by both models), and `/pr-check` changed in the same fortnight. The
process changes that bear on verdicts were checked against the eras. The
disproval evidence bar (2026-09-21) predates both, so it applies
to both. The follow-up-class change (2026-10-01) touches only
deferrals. The removal of the dormant adversarial pass (09-29)
affected a different slug with three rows. So the comparison is
observational, not controlled, but nothing found in the window explains a
halving of disproved findings except the model. The recall side, whether
gpt-6.1-sol also *misses* more, is not visible here at all; it is what the
seeded eval is for.

## Why findings get disproved: a failure taxonomy

The 558 disproved finding rows of the 2026-10-06 cut each carry the author's written reason. A seeded
sample of 80 (seed 4482, drawn by the script; 73 distinct PRs) was hand-coded
into the classes below. The classes were derived from the sample, not decided
in advance. Each row is coded by the **first** rule that matches, in this order:

| Class | Coding rule | n | Share | 95% CI |
|---|---|---:|---:|---|
| `no-rationale` | the reason gives no grounds: only boilerplate such as "adjudicated by /pr-check step 4.5" | 20 | 25.0% | 15.0–35.5 |
| `re-raise` | the reason rests on an earlier ruling on the same PR ("same claim as round 2", "third occurrence") | 9 | 11.2% | 4.9–18.8 |
| `wrong-claim` | the finding states something false about the code or a tool, refuted by reading the code or measuring it (the panel's form of a hallucinated finding) | 21 | 26.2% | 16.9–37.0 |
| `unreachable` | the mechanism is real in the abstract, but the triggering input or state cannot occur in this system, or lies outside its threat model | 8 | 10.0% | 3.8–16.9 |
| `intent-blind` | the behaviour is real and reachable, but it is a documented design choice, a ticket's explicit requirement, a ruled convention or a deliberate fail-safe direction | 21 | 26.2% | 16.7–36.8 |
| `stale-head` | the finding row points at code or a commit that is not the reviewed one | 1 | 1.2% | 0.0–3.9 |

The coded sample, one row per finding with a one-line note, is committed at
[`scripts/eval/cr-ledger/coded-sample.tsv`](../../scripts/eval/cr-ledger/coded-sample.tsv).
Rows carry only a hashed finding id, the critic, the class and a paraphrase.
The script refuses the file if any id is not a disproved finding in the cut,
if a critic does not match the ledger, or if a class is undeclared.

What the classes say:

- **Only a quarter of disproved findings are outright wrong.** `wrong-claim` is
  the hallucination class: an apostrophe "breaking" a quoted heredoc that
  passes its body through untouched, `git -C<path>` treated as valid when git
  rejects it, a macOS `date -r` claim refuted on a macOS runner. The shared
  shape is a confident statement about shell, git or platform semantics.
  Most of these were refuted by a measurement, which is what the disproval
  evidence bar requires.
- **Another quarter are right about the code and wrong about the intent.**
  `intent-blind` findings describe real behaviour that was chosen: a fence
  that over-denies on purpose, a ratio whose formula a ticket fixes, a race
  already accepted in a `ponytail:` comment. The critic sees the diff, not the
  ticket, the brief or the design note, so it cannot tell a deliberate choice
  from a bug. Giving the critic the ticket's acceptance criteria is the obvious
  lever. `unreachable` (10%) is the same blindness one level down: the critic
  cannot see that every caller passes an absolute path, or that only one
  process ever closes a worker.
- **Paraphrased re-raises leak past deduplication.** The panel suppresses a
  finding whose fingerprint matches an earlier disposition on the branch
  (`scripts/cr/finding-reraise.js`), and the ledger confirms that holds: 0 of
  4,383 fingerprinted findings repeat a fingerprint already raised at an
  earlier head. Yet 11% of disproved findings are re-raises in substance: the
  same claim, worded differently, so the fingerprint differs.
- **A quarter of disproved verdicts cannot be audited.** `no-rationale` is a
  finding about the *author*, not the critic: the verdict was recorded with a
  boilerplate reason, so nobody can now say whether the finding was wrong. The
  CR gate checks that a verdict exists, and that a disproval of a claim about
  a shell version names the version it measured, but not that a reason was
  given.

## Limitations

- **The author grades their own homework.** Verdicts come from the session
  that has to fix the finding, which has a motive to disprove or defer. The
  `no-rationale` share is the visible part of that risk. Precision here is
  biased in an unknown direction: down where authors wave off real findings,
  up where they accept wrong ones to end the review loop. The seeded recall eval, with a
  hidden key, is the unbiased check.
- **Observational, not controlled.** No PR was reviewed by two critic models,
  so a before/after compares different PRs at different times.
- **One coder.** The taxonomy was coded once, by one coder, with no second
  coder and no agreement statistic. The rules and every coded row are
  committed so that a second pass can be scored against the first.
- **The ledger is local.** It lives in a checkout's git directory and is not
  published (finding text quotes private artifacts as well as public code). The script, the
  cut and the coded sample are public; the rows they read are not. Anyone with
  their own ledger can run the same analysis on it.
- **Small critics are anecdotes.** In the 2026-10-06 cut every critic other
  than the four codex models and the bare `codex` row (89 findings on three
  PRs) had under 40 findings; a critic with a wide interval cannot be ranked.
- **A branch is not exactly a PR.** The resampling unit is the branch, which
  is a PR in all but a handful of cases.

## Re-running it

From any himmel checkout (the default ledger is the git common directory's,
shared by every worktree):

```bash
python3 scripts/eval/cr-ledger/cr_ledger_eval.py \
  --until 2026-10-06T20:00:00Z \
  --coded scripts/eval/cr-ledger/coded-sample.tsv
```

Add `--json` for the full structure (per critic, per severity, critic ×
severity, deferral classes, re-raise counts, taxonomy). Drop `--until` for the
current ledger. `--sample 80 --seed 4482` prints the sample that was coded
(locally only: that output carries finding and verdict text). `--ledger PATH`
or `CR_LEDGER` points it at another ledger. The script makes no model or
network call and writes nothing. Its suite is
`scripts/eval/cr-ledger/test-cr-ledger.sh`, on a fixture ledger.

The headline section counts a finding once however often it was raised: the
same claim on the same file and line of the same PR, raised again in a later
round or by another critic, is one finding. `cr_ledger_eval.py` above counts
ledger rows. Regenerate the headline in place with:

```bash
python3 scripts/eval/review-page.py --panel --out docs/evals/review-panel.md
```

It rewrites only the block between the two `review-page.py --panel` comments,
and prints the `--until` command that re-runs its cut. Its suite is
`scripts/eval/test-review-page.sh`.

`/cr-scores` (`scripts/cr/cr-scores.sh`) is the operational view of the same
ledger: per-slug agreed%, availability and drop advice over a recent window.
This script differs in three ways: it splits a slug by responding model, it
reports the interval, and it pins a cut.

## The judges: the weekly judge-accuracy job

The judges are the third measured reviewer. `scripts/eval/judge-accuracy/judge_accuracy.py`
joins the persisted verdict records to PR state, main CI and caused-by bugs, and
appends one `judge-accuracy` row to the eval-runs ledger. Run it weekly from a
himmel checkout, with `gh` snapshots taken first:

```bash
gh pr list --state all --limit 1000 --json number,state,mergedAt,headRefOid,mergeCommit > prs.json
gh run list --branch main --limit 1000 --json databaseId,headSha,conclusion,createdAt > runs.json
python3 scripts/eval/judge-accuracy/judge_accuracy.py run \
  --verdicts <handover root>/<user>/<bucket>/verdicts --prs prs.json --main-runs runs.json
python3 scripts/eval/judge-accuracy/judge_accuracy.py queue
```

`queue` lists the escape candidates no caused-by line settles. The chief rules
each one once with a judge-ro call (opus, high; about 15 a week) and
records it with `judge_accuracy.py rule <id> S|P|N --evidence <text>`. A row stays
`partial` until every candidate in its window is ruled. Then
`python3 scripts/eval/lib/eval_feedback.py run` raises at most one change per critic
from the rules in `scripts/eval/feedback-rules.json`, and the next run of the same
series re-measures it. The suite is
`scripts/eval/judge-accuracy/test-judge-accuracy.sh`, on fixture verdicts.
