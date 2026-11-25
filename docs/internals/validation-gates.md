# Validation / quality gates — placement doctrine

This page says WHERE himmel checks work before it advances or merges: which
review runs on which kind of change, what counts as PASS or FAIL, what a gate
report must name, where a human must sign off, and how a cheaper
implementation lane (a Codex worker) earns the right to have its branches
reviewed for merge. Every check it places already exists (the automated
review stack); this page places them, it does not redefine them.

Spec: `<state-repo>/handovers/<user>/himmel/specs/design/ws7-validation-gates.md`.
Where this doc and the spec disagree, the spec wins.

## 0. Two meanings of "gate" (read first)

- **Merge gate (this page):** "is this specific output correct enough to
  advance or merge?"
- **Adoption gate ([token economy](../token-economy.md)):** "is this tool
  change worth keeping?" (measured token delta + outcome-per-session verdict).

They compose: a new merge-gate *mechanism* is itself a tool and must pass the
adoption gate (license check first, then measured delta) before it is adopted.
Nothing here redefines the adoption bar.

`pre-commit run --all-files` must exit 0 on main; a red there is a regression, not a baseline.

## 1. The lane gate (merge review for Codex branches)

**Placement:** between a cheap-lane worker branch and PR creation — a
**validating-session review** run by a Claude-family session on the worker's
branch diff.

**Provenance precondition — positive markers, not inferred absence.** A branch
is cheap-lane IFF it carries a POSITIVE marker, classified by
`scripts/cr/lane-classify.sh`:

- `codex/*` → `cheap-codex` (the hermes-Codex convention, adopted in
  [`harness-compat.md`](harness-compat.md) §10);
- everything else → `claude`.

Absence is NEVER cheap-lane: an unmarked branch is indistinguishable from
ordinary Claude work, so it takes the Claude chain (an "unmarked ⇒ cheap" rule
is not mechanically actionable and would make the Claude chain unreachable). A
known-Codex branch not yet named `codex/*` is manually flagged cheap by the
operator/validating session (recorded in the lane-gate verdict PR-body snippet); Codex
work predating the convention does not ride this gate mechanically.

**Stated deviation:** `lane-classify.sh` is branch-string-only by design (pure,
no I/O). No session record corroborates a `codex/*` branch yet (§9).

**Chain:** the standard `/pr-check` full lane (panel + reviewer matrix + VERDICT
adjudication + marker clear) PLUS the lane rubric (R1-R4, §2) reviewed by the
validating session.

**Verdict owner:** the Claude-family validating session
applying the lane rubric owns the merge-trust verdict. Panel findings stay
ADVISORY blocking-candidates (junior models advise, Claude adjudicates; the
gate stays Claude-only). The chief re-checks the PR at the exact reviewed head
and writes a GO file with `chief-kit/go.sh` on the operator's authority. The
operator can tell the chief to hold any PR. A native worker then runs
`merge-on-green.sh --go <GO file>` (exit 17 without it). The chief merges a
claudex worker's PR with `merge-on-green.sh`. An adapter-repo worker stops at
`READY`; the chief merges its PR with `merge-fork-pr.sh`.

**PASS/FAIL semantics:** fail-closed on the verdict-presence axis. No
validating-session verdict ⇒ not PR-eligible. A worker self-report ("done") is
never a PASS input (a worker never grades its own work;
[orchestration patterns](../orchestration-patterns.md)).

**Verdict persistence:** the validating session writes a one-line verdict record
— `pass|fail (R1-R4)` — into the PR body. The trust-tier count (§5) reads that record
+ git history (NOT the CR ledger, which carries critic findings, not lane
verdicts).

**Enforcement honesty:** the review-owed marker hook
(`scripts/hooks/check-cr-before-push.sh` +
`scripts/hooks/check-cr-marker-on-pr-create.sh`) structurally enforces the
panel/automated review half. The R1-R4 lane-rubric verdict is BEHAVIORALLY enforced v1
(validating-session discipline); its structural enforcement is the deferred
lane-marker hook (§9), escalated on drift.

## 2. Rubric chains per artifact class

A gate chain = ordered rubric set + failure posture + report contract. Every
mechanic invoked is a shipped instrument.

| Artifact class | Chain (shipped instruments only) | Posture (panel avail. / verdict presence) | Human checkpoint |
|---|---|---|---|
| Code diff (Claude lane) | pre-push deterministic gates → `/pr-check` full lane → chief GO at the reviewed head → `merge-on-green.sh` | panel fail-open; verdict/marker fail-closed | chief's GO (on the operator's authority) |
| Code diff (Codex lane) | lane gate = full lane + lane rubric, validating session adjudicates → chief GO at the reviewed head → `merge-on-green.sh` | panel fail-open; verdict/marker fail-closed (verdict-presence axis — §3) | chief's GO (on the operator's authority) |
| Docs-only diff | docs-audit lane (never-zero-CR) → chief GO at the reviewed head → `merge-on-green.sh` | verdict/marker fail-closed | chief's GO (on the operator's authority) |
| Spec/plan artifacts (minerva) | Stage-2/4 adversarial critics (same-family today — known blind spot; a cross-model artifact critic is not built yet) | critics advisory; orchestrator gates advance (fail-closed on a missing critic round) | operator ratifies open design choices |
| Handover state | exempt — no gate | exempt — no gate | none |

**Lane rubric (the lane-gate extension, applied to cheap-lane diffs on top of the full
lane):**

- **R1 scope adherence:** the diff touches only what the task named (worker
  prompt contract).
- **R2 attestation honesty:** trailers/claims in commits are backed by
  observable evidence (tests actually run in the transcript, etc.).
- **R3 convention conformance:** conventional commits, worktree discipline, no
  external writes from the worker (tripwire + transcript check).
- **R4 self-report cross-check:** the worker's outbox/context summary matches
  the actual diff (catches "confidently wrong done").

**Behavioral-degradation checks** are part of the lane rubric — the failure
surface of a cheaper model (attestation honesty, scope adherence, convention drift) that
structural guards do not catch.

**Gate-report contract (all chains):** a FAIL names the exact failing item —
`file:line`, rubric ID, and for agentic/test gates the exact tool-call/fixture
that triggered the miss. This preserves the `[<slug>-N]` bullet contract and the
`(N found)` heading/count contracts untouched.

**Validity-regime line (scale discipline):** every chain declares what regime
its evidence covers (e.g. "reviewed at diff scale; no production-scale claim").
Small-set green ≠ production green (benchmark-saturation lesson).

## 3. Degradation posture

**Posture axes, stated once:** panel availability is fail-open; verdict presence
is fail-closed. "Fail-closed" anywhere in this doc refers to the verdict/marker
axis (no verdict ⇒ no advance), never to panel availability.

**Default:** **critic-panel UNAVAILABILITY** ⇒ degrade fail-open to
Claude-only adjudication, for ALL chains including the lane gate.
"Unavailable" is the runbook's own umbrella for BOTH shapes: the panel runs and
every critic errors/times out (`panel_rc=1`), OR the panel cannot be run at all
(e.g. the diff could not be produced — `pr-check.md:99`). `CR_PROFILE=none` is
the explicit opt-out and also lands Claude-only; an empty diff simply skips the
panel.

The clarification this needs: a **registry fallback is NOT
unavailability** — the panel RAN, on the paid anchor. Of the four shapes below,
only 3 and 4 reach Claude-only; 1 and 2 BILL:

1. **Registry missing / invalid / empty** (`critic-panel.sh` node parse exits 7)
   ⇒ **paid** codex anchor-only. The stderr line says so verbatim:
   `registry <path> missing/invalid/empty — anchor-only (codex)`.
2. **Registry present and valid, but no row matches the tier filter** (exit 8)
   ⇒ **paid** codex anchor-only, via the same fallback. This is the shipped
   default: `critics.json` holds no free-tier row (its rows are `codex` and
   `claude`, both tier `paid`, plus the `coderabbit` App), so an unset `CR_PROFILE` (tier filter `free`)
   matches nothing and lands here.
   The free lane was REMOVED DELIBERATELY (operator decision): the free
   critics made more trouble than they were worth — gptoss+kimi were
   dropped on a 12%/13% agreed-rate (noise), and the surviving qwen3coder
   anchor kept erroring rc=1. This is a decision, not drift; the
   panel is paid-by-default on purpose and only the docs had lagged.
3. **The selected panel runs but every critic errors/times out** (panel rc=1)
   ⇒ Claude-only fail-open. Observed live 2026-07-17: the sole registered
   critic (paid codex) returned rc=1 for a whole run once its weekly usage was
   exhausted — with no free row registered, that is 0/1 panel critics.
   **This does NOT by itself block the automated review gate.** `clear-review-marker.sh` counts
   ANY ledger `avail … status=ok` as a responder (`:176`), so the interactive
   lane's own Claude floor review can still certify the HEAD while every panel
   critic is down. What a single-critic roster costs is the panel's own
   cross-model redundancy, not the gate's ability to certify. Accepted
   knowingly.

   The Claude floor is the only responder outside the panel (CodeRabbit runs
   as the GitHub App only). Under `CR_REQUIRE_CROSS_MODEL=1` a panel-wide
   outage keeps the gate closed: gate 3b requires a non-Claude `avail … ok` at
   the SHA, only the panel can supply one, and a Claude-only floor keeps the
   marker closed (exit 14) until a panel critic responds.

   The caveat that survives: the panel's non-Claude rows can share a provider.
   An OpenAI-side outage or a usage budget that has run out takes the `codex` row out, and
   then nothing can satisfy gate 3b. That single point of failure is a known
   limitation.
4. **The panel cannot be run at all** — e.g. the diff could not be produced
   (`pr-check.md:99`, "critic panel unavailable — claude-only review (git diff
   failed …)") ⇒ Claude-only fail-open. `CR_PROFILE=none` is the explicit
   operator opt-out onto the same path; an empty diff skips the panel outright.

Operator-relevant consequence: cases 1 and 2 both draw on the OpenAI usage budget for the
paid anchor (paid usage is user-enabled by design). Do not read "the panel was
unavailable" as "nothing was billed" — only 3 and 4 reach zero panel members.

So the rationale below holds for cases 3-4; cases 1-2 reach a paid critic
rather than zero panel members.
Rationale: for Codex-origin artifacts the adjudicator is already a DIFFERENT
family than the implementer — the "evaluator = different family, never self-grading"
invariant holds even with zero panel members. The known residual
blind spot is Claude-reviewing-Claude (same-family) on Claude-lane diffs — that
is today's shipped posture, not worsened by this default.

Alternative rejected by default: hard-block on anchor death (turns a free
third-party outage into a repo-wide merge freeze — disproportionate).
`CR_PROFILE=paid` (codex) remains the operator escalation. No per-token critic
joins any panel until the operator enables per-token billing.

## 4. Human checkpoints (first-class, bounded)

- **Merge needs the chief's GO on the operator's authority** (§1). The lane-gate verdict feeds it, never replaces it.
  `--admin` and any gate bypass remain HARD-vetoed.
- **`/code-review ultra`** stays the operator-triggered top escalation, recorded
  as a one-action operator step.
- **Batching bound:** the review surface batches into the consolidated morning
  report; fan-out ceiling ≈6-8 tickets/shift (rubber-stamp threshold) — a
  checkpoint property, owned operationally by the AFK (unattended) mode doc.
- **Checkpoint placement rule:** a human checkpoint is REQUIRED where a verdict
  is (a) irreversible outward (merge, publish, external write) or (b) a
  trust-tier promotion (§5). Everything else is agent-adjudicated.

## 5. Trust-tier promotion

Unquarantine is not binary-forever; it is a per-lane trust ledger.

- **Tier 0 (today, executable):** every cheap-lane output passes the lane gate.
- **Tier 1 (earned — default N=10):** after ≥N gated merges with zero
  post-merge reverts/regressions attributable to the lane (counted from the
  verdict records + git history), the operator MAY relax the lane rubric to
  sampled application. **No sampling harness exists today.** Tier 1 is a reserved slot, not executable now.
- **Demotion:** any lane-attributed regression that reaches main returns the
  lane to Tier 0 (full gating) until N accrues again.
- Promotion/demotion are **operator actions** (§4 checkpoint rule b); this doc
  only defines the ledger evidence that justifies them.

## 6. Trace→regression loop (placement only)

The record for a blocking automated review FAIL on a cheap-lane branch is a
machine-findable line stored with the run artifacts. The emit-gate-fail script can write it to
`<session-dir>/gate-report.jsonl`, but no review step calls it yet. A lane-rubric FAIL is recorded only in the
PR-body verdict (§1).

This is the ONE added emission this page places: today `file-deferred-issues.sh`
captures ONLY deferred low-severity findings; blocking Critical/High/Important
automated review fails are NOT persisted (they block the marker and get fixed in place), so
the corpus was missing the failures that matter. Nothing reads these records
yet: this page places only the emission points, and the lessons loop
([lesson-audit.md](lesson-audit.md)) samples lesson files, not this corpus.
No new storage system (YAGNI) — session
dirs + issues are the corpus v1, with the one added write above.

## 7. Shell-unit CI

Shell-unit CI runs on every pull request and is a required check (it starts with the push, in the same run as every other job: a PR's CI starts every job at once and the first failing job cancels the rest of the run; the `ci:go` label gate is retired, and the trade-off is that heavy runner minutes are spent before review);
`ready-check.sh` item 19 reads its shard manifests as suite proof (see
item 19 below).

**A time-cap overrun alerts; an assertion failure fails.** A suite whose first
run and retry each end on its time cap or on a timed-out row (rc 124), with no
FAIL row of its own in either run, is a `CAP-ALERT`: `run-shell-tests.sh` prints
the line, counts the suite `ran 0` in the shard manifest and does not fail the
run. CI uploads the lines as a `cap-alerts-*` artifact and writes a job-summary
line for each shard that raised one. A suite that prints a FAIL row of its own
still exits 1, cap hit or not. For a suite on a trust path
(`scripts/ci/ci-trust-paths.txt`), a timed-out row (`got 124`) counts as a FAIL
row of its own, so the run exits 1.

## 8. Data-egress-safe gate lane

Sensitive (Salus/PHI/secret-touching) artifacts NEVER route through cloud
critics — the panel is cloud (NIM/hermes), so their chains are
Claude-session-local review only, today.

**Signal honesty:** the mechanically-testable guard covers PATH/REPO signals
only (diffs in Salus-profile vaults, or matching sensitive-path
patterns); PHI/secret CONTENT in an otherwise-ordinary diff is
operator/adjudicator judgment, not a mechanical gate — content scanning is
runtime DLP, explicitly out of scope. This is a
**placement rule**, not a gate: no sensitive-path diff on a cloud critic lane.

DeepEval (local-execution, Apache-2.0 — license to be verified at adoption) is
the named candidate engine for a future local assertion gate; adopting it is
an adoption-gate decision, not a build item here.

## 9. Deferred structural enforcement

The live claudex implementation lane runs through the Claude Code harness
([lane calibration](lane-calibration.md#claudex-worker--implementor-default-operating-model)),
with publication subject to its permission classifier. The chief's
`scripts/handover/chief-kit/ready-check.sh` separately refuses a head without
an `ok` CR-ledger row. These cover publication authorization and automated review readiness.

**16. outside-PR full review.** For an outside PR (a fork, a deleted author, or
an author not on `scripts/ci/ticket-id-internal-authors.txt`; a same-repo Bot is
not outside), `ready-check.sh` item 16 needs every record at the exact head, so
a new head starts over:

| Row | Passes when |
|---|---|
| 16b | a `round-scope` row with scope `full` for this branch and head (a delta or post-cap delta row FAILs) |
| 16c | the latest `lint` run of workflow `CI` at the head is `SUCCESS` |
| 16d | no changed path (either side of a rename) starts with a line of `scripts/ci/outside-lint-surface.txt` |
| 16e | zero unresolved threads, each resolved by a maintainer, and `check-ci.sh --threads-only` exits 0 within 20 s |
| 16f | the newest `impacted` row at the head reads exit 0 with no SKIP |
| 16g | a diff touching the blast scope (`scripts/cr/blast-scope.cjs`) has a `blast` row with status `ran` |
| 16h | no CodeRabbit commit status of `failure` or `error` at the head, read within 20 s; a running, missing, skipped, rate-limited or unreadable status passes with a note |
| 16i | a passed (or flagged) `security-audit` row for this PR and head whose report hash and perspective hash still match |

16h and 16i apply only to an author not in `~/.himmel/outside-contributors.json`
by login and id; a listed author prints `[SKIP] 16h/16i listed author <login>`.
16e and 16h run with the `CR_*` overrides unset, so no env widens them. Item 16
reads its lists from the script's own checkout and fails closed when it cannot
read one. It is outside `--only 7`, and an org-member PR's output is unchanged.
The operator's GitHub code-owner approval comes last, after item 16 passes.

**Stage 1 writes no record** (16h reads its CodeRabbit half). It is recomputed at the head wherever it is needed: CodeRabbit's
status is `success` (read in a fresh child with the four `CR_*` pattern overrides unset), no changed
path is on the lint surface, and `check-ci.sh <n> --max-wait 120 --except-context codeowner-review-gate`
exits 0 with `CR_APP`, `CR_PROFILE`, `CR_BOT_USER_ID` and `CHECK_CI_DISTINCT_DEADLINE` unset.

**Stage 2 (16i) is the `security-audit` row**, written only by
`scripts/cr/outside-security-audit.sh --pr <n> --head <40-hex>`, run from the primary checkout. The
script reads the PR's full diff from its merge base as text (fetched through
`pr-check-outside.sh --fetch-only`) and runs none of its files. It runs five hard checks: H1 a bidi or
invisible character on an added line, H2 a git, install or tool-run file, H3 a changed package
lifecycle script, H4 a lockfile source off the default registry, and H5 a symlink or gitlink. Then it
makes one codex critic call under `scripts/cr/perspectives/outside-security.md`. The counts come from
the score row that call wrote. Trust-path hits and binary files are flagged in the report and never
set the verdict. The verdict is `fail` on any hard hit or a Critical, `flagged` on an Important, a
dropped citation or critic exit 4, else `pass`. The row carries the hash of a report under
`<git-common-dir>/outside-audits/`. Exit 0 wrote a row, whatever its verdict; 2 the PR is not open,
not outside or not at that head; 6 stage 1 is incomplete; 7 no verdict (the fixed 192 KiB cap, a
critic with no answer, no score row, a trust-path refusal); 8 the head already has a fail row, or an
ok row under the current perspective. A `fail` is sticky at its head, and no verdict is re-rolled.

**The no-checkout route.** An outside PR is reviewed from its diff at its head, with no checkout
of its code on the station, so none of its files run there. `scripts/cr/pr-check-outside.sh`
with `--pr <n> --head <40-hex>` refuses unless the PR is outside, open and at that head, asks
`review-round.sh check --pr` whether the author may be reviewed, refuses a local branch of the
PR's head name, and fetches the head into `refs/himmel/outside/<n>`. `outside_pr_authorize`
(`scripts/lib/outside-contributors.sh`) reads the author, node id, head branch and head from
the forge itself and decides: a listed author gets 3 full rounds; any other round needs an
approval row for exactly that PR and head with stage `review` in
`~/.himmel/outside-pr-approvals.jsonl` and, for an unlisted author, a `security-audit` pass at
that head. `review-round.sh start --pr` owns the cap (state `outside-<n>`, no delta round).
`panel-first-pass.sh --pr` and `pr-check-context.sh --pr` then run on the ref; the panel must be
pinned to it, and a panel without a pin option is refused before a round is spent,
so item 16b never passes on a review of a tree the panel did not pin. A diff over the 204800
bytes the critics read, counted as they count it, is refused before a round starts, and so is an
over-cap diff from the rtk retry (that round stays counted), so a full-scope row never covers text
nobody read. Each of the four `--pr` entries (`pr-check-outside.sh`, `pr-check-context.sh`,
`panel-first-pass.sh` and `outside-security-audit.sh`) runs only as the copy in the primary
checkout that the call's HIMMEL_REPO names, refusing a branch copy, a linked worktree or an unset
HIMMEL_REPO, and refuses a PR head name that collides with a local branch (compared without case)
before it writes anything keyed on that name, the audit through its `pr-check-outside.sh
--fetch-only` call. **Status: runs on main, not yet proved on a real PR.** `critic-panel.sh
--pin-ref` (PR 5234) pins the panel to the fetched ref, so `panel-first-pass.sh --pr` writes its
review row; the Telegram approve reply writes the approval row, and hook rows protect both
files. Steps 2 to 2.8 read the fetched ref (`scripts/cr/pr-check-ref/20-step2-lanes.md`); no step
file from step 3 on describes the route. A live run on a real outside PR is still owed.

**19. suite evidence.** A suite CI runs is run once, in CI: pr-check
step 3.6 records it `SUITE <p> = CI` (`scripts/cr/pr-check-ref/33-step3-impacted.md`),
and `ready-check.sh` item 19 needs proof for every impacted suite of
`origin/main..<head>` at the exact head. A worker runs on the station only the
suite its PR changed, with its failing-first proof; a suite CI does not run needs no local run (the
tier-skipped row below). `impacted-suites.sh --plan <base>..<head>` prints that split (`LOCAL <p> (<reason>)`
or `CI <p>`; the failing-first proof is an instruction the plan prints, no gate checks it) (operator decision 775).
A JS/TS suite follows the same rule: it is `CI` when the PR did not change it, `--runner` maps it, it is not
on the CI-skips list and, for a vitest suite, the diff's node_suites gate is on. A typical PR plans 5 or fewer
`LOCAL` lines:

| Proof | Counts when |
|---|---|
| local | the head's `impacted` ledger row lists the suite in `local_pass` |
| ruled SKIP | that row lists it in `ruled_skip` (`SUITE <p> = SKIP ruled <chief-session> <reason>`); the PASS line counts and names it apart from the local count. Only a hand GO reads that line: `auto-go.sh` does not stop on a ruled SKIP |
| tier-skipped | a suite CI does not run needs no local run: the CI manifest lists it as `skip`, or it has no `ran 0` row and its tier in `scripts/ci/suite-tiers.tsv` (the anchor's copy, never the PR's) is `daily`, `local` or `quarantine`. The PASS line names each one with its tier (`<p> (daily)`) or `(CI skip)`. A `pr`-tier or `flow`-tier suite (CI runs both on every PR; a suite with no table row reads as `pr`, as does an unknown tier) with no `ran 0` row still FAILs, and so does a suite CI ran red, whatever its tier |
| CI | an exact `ran 0 <path>` line in a manifest of the run behind the latest `SUCCESS` `shell-unit (ubuntu-latest)` check-run of workflow `CI`, whose `head_sha` is the head: a shell shard manifest (artifacts `shell-unit-manifest-ubuntu-latest-shard*`, files `manifest-shard*.txt`), or, for a suite no shard line proves, a JS suite manifest (artifacts `js-suite-manifest-*`, files `manifest-js-*.txt`) whose producing job concluded `success` in that run. A nonzero `ran` line in any JS manifest is red even if another job wrote `ran 0` |

A suite the PR changed (it is on the PR's file list) needs the local proof or a
ruled SKIP even when CI proved it: `<p> (the PR changed it: a CI line does not count, run it locally)`.
With any impacted suite, an unreadable file list FAILs item 19.
A PR-body `Local suites: <path>` line needs the local proof even when CI proved
the suite. The subprocess and network reads (`gh`, `impacted-suites.sh`) are bounded, and one that fails
or times out FAILs item 19. Reads of local files (the ledger, the manifests once downloaded) are not
bounded; a ledger that cannot be read means no `impacted` row, so no local proof.
The JS manifests are downloaded only when some suite still needs CI proof after the shard manifests,
and then the run's jobs are read (`gh api .../actions/runs/<run>/jobs`). A JS artifact
`js-suite-manifest-<job>` belongs to the job whose name is `<job>` or `<job> (<matrix values>)`, or, for a matrix
artifact `js-suite-manifest-<job>-<value>`, `<job> (<value>[, ...])`. A manifest whose job is not `success`, or
is not in the list, proves nothing, and its suites read `CI job <job> did not succeed`. A JS
download that fails for any reason other than `no valid artifacts found`, or a jobs list that cannot be read,
FAILs item 19. Under the verdict, PASS or FAIL, `note: from JS manifests: <paths>` names every suite a JS
manifest proved.

Who can fake a CI line: item 19 reads one only from the artifacts of the run it picked, and takes the head
from the run through the API, never from the file.

| Route | Result |
|---|---|
| A worker uploads an artifact or writes a local file | Not read: an upload needs a running job's token, and item 19 reads CI proof only from the run's artifacts |
| A manifest from an older head | That run's `head_sha` differs, so item 19 refuses it |
| A `workflow_dispatch` run on the branch | Its aggregator is `shell-unit (dispatch verify) (...)`, which the pick never selects |
| A PR edits `ci.yml`, a CI script, the JS reporter or writer, `check-hook-lib-suites.sh` or the reader | Trust paths (`scripts/ci/ci-trust-paths.txt`, read from main): the merge needs a trust-reviewed GO |
| A second writer inside `shell-unit-manifest-*`: the `claude-startup` job publishes its suites' manifest there | CI writes it, but item 19 reads every artifact the glob matches, so a PR's own code could add one more (an open follow-up narrows the read to the artifacts the run expects) |
| A vitest failure not tied to one file (an unhandled error, a crash after the report) leaves `ran 0` for the files that passed | **Closed:** a JS manifest counts only when its producing job concluded `success` |
| A PR's own code writes a false line from a test or a source file a job runs | **Open**, ceiling row C-0039 |
| A PR changes a package's `test` script, `vitest.config.*` or `bunfig.toml`, so a step runs less and stays green | **Open**, ceiling row C-0039 |

A red CI run at the head appends one `fail` row per failed suite left to CI to
`~/.himmel/state/suite-evidence/ci-failures.jsonl`, and a later head of that PR one
`round` row; `scripts/cr/suite-fail-ledger.sh` prints the failure count and the
extra-round rate. `scripts/check-ci.sh` writes those rows the moment it sees the red
(through `scripts/cr/ci-fail-record.sh`, which reads the run's shard and JS manifests apart), so a red
that goes green on a re-run still leaves its row. Item 19 writes the same rows, keyed alike, for a shell suite
only, if it reads a red later; a JS suite's row comes only from `ci-fail-record.sh`.
The ledger never changes a verdict.

Lane-rubric verdict persistence remains behavioral (validating-session
discipline); structural `cheap-codex` provenance enforcement waits on a hermes
task→branch record. See §1 enforcement-honesty.

## Review rounds

`/pr-check` counts a review round only when a panel reviewed new work. The first round reviews the whole PR. Every
later round reviews only the increment since the head the last counted round ran on (`review-round.sh start` prints
it; the whole PR rides along as context). The increment's class decides what the round costs:

- **carried**: a clean merge of the base into the reviewed head. No panel, nothing counted.
- **free** (`tests`, `comments`, `merge-resolution`, `fix`): the panel runs, nothing is counted. A free increment is
  at most 80 diff lines, a PR gets at most five, and past the cap the round blocks only on Critical or escape-class
  findings. `tests` is test paths only; `comments` is comment or blank lines only (a `#` line inside a heredoc counts
  too, which is why the panel still runs); `merge-resolution` is a merge whose own lines only resolve its conflicts;
  `fix` touches only files that an open critic finding cites, at the reviewed head or at a head a free round followed.
- **work**: anything else. It spends a round. After round 3 it runs only as the one delta round (a finding still open
  at the reviewed head, or a judge NO-GO), as `postcap-fixed` (also reached through free rounds), after a red CI, or
  on a judge or chief grant.

A round whose panel wrote no row is given back. A refusal past the cap (exit 8) names the rethink first: split the
PR or narrow the change, then ask the chief for a judge NO-GO or a grant. Detail: `scripts/cr/pr-check-ref/30-step3-panel.md`.

## Correcting a finding's line token in the ledger

`ledger-append.sh rekey --head <sha> --id <finding-id> --line <token> [--file <path>] --reason <text>`
fixes a finding row recorded with the wrong line (or file) token. It appends one
correction row (an `amend` whose `set` carries `rekey: true`, the new line
token and, with `--file`, the new file) and leaves the finding row untouched. The
token is a line or a range such as `1331` or `1331-1340`. The disposition reader
(`scripts/lib/review-ledger-evidence.sh`) matches the original token or the token
of the latest rekey row, so a second rekey replaces the first. A rekey that names
a head or finding id with no finding row is refused and writes nothing. It never
moves the finding to another head. A plain `amend` cannot stand in for it: the
reader ignores an amend's `--set head`, `file` or `line`, and `amend --set
rekey=true` is refused. Signing follows the amend rule in
[enforcement](enforcement.md#cr-ledger-amends--only-a-signed-adjudication-lowers-a-finding).

## Defaults you can change

Each default above is one knob; changing it touches only the named sentence.

- **Verdict owner (§1):** the Claude-family validating session owns the
  merge-trust verdict (the operator owns the merge action). Changing it edits
  §1's owner sentence; the record format stays.
- **Panel-outage posture (§3):** fail-open to Claude-only adjudication; the
  alternative is a hard block.
- **Tier-1 threshold (§5):** N=10 gated merges (Tier 1 is not executable yet).

## Not built yet

- **Gate state on the Fleet page:** the himmel UI's Fleet page
  (see [Jarvis](../jarvis-subsystems.md#the-surface-the-himmel-ui-and-other-views)) shows
  each worker's stage, but not gate verdicts or trust-tier state.
- **Cross-model artifact critic:** when it exists, minerva Stage-2/4 chains
  gain a cross-model lane in the §2 spec/plan row.
- **Codex work outside Claude Code:** the lane-gate rubric applies to any
  Codex-driven himmel work whatever the harness (the `AGENTS.md` surface;
  [lane parity](lane-parity.md)).
