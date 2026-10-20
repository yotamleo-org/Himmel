# Known findings — the pre-panel self-review

CR rounds were being spent on finding classes the repo had already adjudicated:
CodeRabbit re-taught the same five corrections thousands of times, and the critic
panel kept raising the same portability / coverage / twin-parity shapes on fresh
diffs. This page indexes the one artifact that now holds those classes and the
three places it feeds. The JSON is the source of truth; this page is the map.

## The artifact

`scripts/cr/known-findings.json` — one entry per recurring class:

| field | meaning |
|---|---|
| `id` | stable slug, cited in PR bodies and adjudication reasons (`disproved: known class <id>`) |
| `kind` | `fix` = real defect with a canonical fix · `rebuttal` = false-premise class with a canonical rebuttal · `checklist` = judgment question the self-review asks |
| `rung` | required: the top rung of the correction ladder the class has reached — `design` (structure removes the defect) · `gate` (hook / pre-commit / CI blocks it) · `advisory` (detector or lint reports, nothing blocks) · `prompt` (critic-prompt text only) · `human` (judgment, no automation). A missing or unknown value exits 2 in `--list`, `--ladder` and `--refresh` (`--diff`/`--prompt` stay fail-soft on the critic path) |
| `globs` | which changed files the class applies to |
| `match` | optional: case-insensitive JS regex over the ledger finding text; with `globs` it decides which ledger findings the ladder attributes to the class (no `match` = skipped by the ladder proposals) |
| `platform` | optional: `"windows"` = never proposed for promotion |
| `detector` | deterministic matcher for `--diff` (added-line ERE, twin-missing, no-test-change, removed-flag-in-docs, md-fence-no-lang, hook-header-no-fail-direction, hook-no-bypass); `null` = prompt-only class |
| `canonical` | the fix, or the rebuttal to paste, in one paragraph |
| `coverage` | what already enforces it structurally (shell-lint rule, `.coderabbit.yaml` instruction, hook) and the gap, with ticket ids |
| `prompt` | `true` = rendered into every diff-mode critic prompt as "already adjudicated" |
| `evidence` | `learnings_uses` (CodeRabbit export), `cr_app_finding_comments_since_2026-08-10` (hand-measured from App review comments), `ledger` (rewritten by `--refresh`: verdict split of ledger findings whose file matches `globs` — the ledger stores no finding text, so this is the file-bucket's verdict history, not the class's) |

## Where it feeds

1. **`/pr-check` step 2.8** — `bash scripts/cr/known-findings.sh --diff --area`
   (a bare `--diff` resolves `<default-branch>...HEAD`; pass a range to
   override) prints the checklist for the diff with a `state=` per hit
   (`open`, `waived`, `checked`) and a closing `preflight: classes hit N · fixed F
   · waived W · checked C` line. Exit 3 while a hit is open: the session fixes,
   waives (with a reason) or checks each hit BEFORE step 3, then records the pass
   with `ledger-append.sh preflight --hit <class>=<fixed|checked|waived:reason>`
   (a `kind: preflight` ledger row; the latest row for the branch, recorded at
   the current head, is what closes a hit on the next run). Without `--area`, `--diff` stays advisory
   (always exit 0). After adjudication the session prints
   `known-findings: round-1 hits = N` — the acceptance metric. Fixed and
   deferred `amend` rows carry `class=` (auto-attributed from this catalog,
   `unattributed` when no class claims the finding).
2. **Critic prompts** — `scripts/cr/critic-first-pass.sh` appends
   `known-findings.sh --prompt` (the `prompt:true` classes) after the perspective
   block in diff mode: *do not re-raise unless the code regressed; if you do, cite
   why this instance differs*. `CRITIC_KNOWN_FINDINGS=0` opts out; artifact
   (charter) mode never carries it; a missing renderer is silently empty.
3. **`/cr-learnings-refresh`** — `known-findings.sh --refresh [--learnings <csv>]`
   re-mines the ledger per class and re-imports a CodeRabbit learnings export,
   rewriting only `evidence` + `refreshed_at`, and lists the unmatched
   high-usage learnings as new-class candidates. Lean-invoke, no cadence.

   With `--learnings` it also prints a feed, one line per finding, after the
   `learnings_export: rows=… live_rows=… stale_rows=… unmatched_rows=…` summary
   (`unmatched_rows` counts every row that matched no class, stale or not):

   | Line | Meaning |
   |---|---|
   | `STALE row=N uses=U reason=<r> …` | delete the CodeRabbit learning. Reasons, first hit wins: `windows`, `glm`, `private-repo-propagation`, `file-gone` (the row's file is absent from `git ls-files`; rows from another repository, or with no repository, are skipped), `closed-deferral HIMMEL-n (<status>)` (it defers to a ticket now Done/Closed) |
   | `PONYTAIL row=N … ticket=HIMMEL-n status=<s>` | the row defers to a still-open ticket: keep it, it is a `ponytail:` marker |
   | `STATUS-UNKNOWN row=N ticket=HIMMEL-n` | Jira status unreachable: the row is NOT stale on that rule |
   | `DUPLICATE rows=a,b uses=U …` | live rows with the same file and the same normalized 12-token rule head; read the group, keep one only if the rows state the same rule |
   | `PROMOTE-HINT row=N uses=U near-duplicates=k …` | a live unmatched row with 100+ uses or 3+ near-duplicates |
   | `PROPOSE-CLASS id=… rows=N uses=U globs=… match=… kind=… canonical=…` | live unmatched rows sharing a file area (first two directories) and a rule 3-gram, with 2+ rows or 25+ uses: a draft class to review |

   Ticket status comes from the jira CLI; `KNOWN_FINDINGS_TICKET_STATUS=<file>`
   injects a `key<TAB>status` TSV instead (an unreadable file means all unknown).
   Nothing is deleted or written beyond the summary counts.

`known-findings.sh --list` prints the class table; `--json` on `--diff` gives
machine output. `known-findings.sh --ladder` prints the class count per rung,
then the promotion queue: `prompt`/`advisory` classes that carry a `match` and have
real recurrences (verdict `agreed`, `confirmed` or `fixed`) in the `evidence.ledger`
verdict history, most first, then the `PROPOSE` lines.

`scripts/cr/class-recurrence.sh` is the restructure trigger (operator-run; the
weekly cadence wiring is a separate slice). It reads the ledger over a rolling 14 days and acts on a class when one (directory cut to 3
segments, class) pair shows in 5 merged PRs with 2 deferring, or when 3 open
`residual` tickets share the class label. It comments on the class's
`restructure-class-<id>` ticket, labels the HIMMEL-6176 member that owns the fix,
or files one ticket under HIMMEL-6176 (at most 2 new a week), then folds each open
residual into it (Relates link, `folded-into-<KEY>` label, fixVersion removed). A
residual stays open until the restructure merges. `--dry-run` prints without
writing; exit 4 is a failed tracker lookup, 3 a failed Jira write, 2 a usage
error, a missing merged-PR list or a missing `JIRA_PROJECT_KEY`. Test:
`scripts/cr/test-class-recurrence.sh`.

Attribution and proposal rules (print-only; no rung is ever changed):

- A ledger finding counts toward a class only when its file hits the class `globs`
  AND its ledger `text` hits the class `match` (a case-insensitive JS regex). A class
  with no `match` is skipped by the queue and the proposals; `--refresh` stats fall
  back to the globs alone for it.
- Move to `advisory` or `prompt`: 3 recurrences across 2 branches. Move to the
  `gate` rung: 10 recurrences across 5 branches, counting only the last 30 days.
  `--min-recurrences` / `--min-branches` override both bars.
- A `rebuttal` class is never proposed above `prompt`. At 80 percent or more disproved
  of its adjudicated findings, with none real in the last 30 days, it gets
  `PROPOSE [id] retire`.
- A class with `platform: "windows"` is never proposed. Tests: `scripts/cr/test-known-findings.sh` (detectors on a
fixture repo, prompt/list/json shapes, refresh on a copy, usage contract) and the
prompt-injection block in `scripts/cr/test-critic-first-pass.sh`.

## The weekly standards cadence

`bash scripts/cr/standards-cadence.sh --since 7d` (run from `/cr-tune` step 5) reads
`known-findings.sh --ladder` and writes `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md`.
It is lean-invoke, not a hook, and changes nothing but that file. Tests:
`scripts/cr/test-standards-cadence.sh`.

- Only classes the ladder proposes AND that had a real recurrence in the window are listed.
  Each gets exactly one target, most to least preferred: lint or check · shared helper plus a
  check · standard line · critic rule · CodeRabbit rule · rebuttal. The script picks: `retire`
  is a rebuttal, a move to the gate rung or a `fix` class is a lint or check, a `checklist`
  class a standard line, a `rebuttal` class a CodeRabbit rule (source `coderabbit-learning`)
  or a critic rule.
- Approval: CodeRabbit rule and critic rule edit `.coderabbit.yaml` / `critics.json` and are
  operator-approved. Every other target goes through a console GO with an opus judge.
- Promoted classes (`rung_since` set) show real findings per week before and after promotion
  (the before span runs from the class's first finding, at least a week). A class whose rate
  does not fall is demoted to restructure (S5).
- A proposal expires after 14 days unbuilt. The next run lists `REFIRED [id]` when the class
  is proposed again, `EXPIRED [id]` when it is not, and `BUILT [id]` when the class was promoted
  or removed since the proposal.

## Classes (2026-09-02 snapshot — regenerate with `--list`)

| id | kind | rung | source | detector | title |
|---|---|---|---|---|---|
| `errexit-false-positive` | rebuttal | advisory | coderabbit-learning | added-line-regex | errexit hazards claimed in scripts that do not (or do not relevantly) use set -e |
| `octal-leading-zero` | rebuttal | advisory | coderabbit-learning | added-line-regex | leading-zero operands: decimal in `[ ]`, octal only in arithmetic contexts |
| `octal-arith-unnormalized` | fix | advisory | ledger | — | leading-zero operand (date +%m/%d/%H/%M/%S/%j) used in arithmetic without 10# normalization |
| `handover-root-bootstrap` | rebuttal | advisory | coderabbit-learning | added-line-regex | handover-path.sh / handover_root demanded of a script that touches no handover path |
| `mktemp-no-template` | fix | advisory | coderabbit-learning | added-line-regex | bare `mktemp` / `mktemp -d` without a template (BSD/macOS portability) |
| `gnu-only-utility` | fix | advisory | cr-app-comments | added-line-regex | GNU-only command or flag in cross-platform shell (timeout, find -maxdepth, sed -i, date -d, readlink -f, grep -P, \s, hardcoded /usr/bin/cat) |
| `bash32-portability` | fix | advisory | coderabbit-learning | added-line-regex | bash 4+ construct (mapfile/readarray, declare -A, ${v,,}, \|&, &>>) |
| `test-coverage-gap` | checklist | advisory | cr-app-comments | no-test-change | source changed, no test changed |
| `docs-flag-drift` | checklist | advisory | cr-app-comments | removed-flag-in-docs | a removed/renamed `--flag` is still documented |
| `grep-q-pipe-under-pipefail` | fix | advisory | ledger | added-line-regex | `<producer> \| grep -q` under `set -o pipefail` (early exit SIGPIPEs the producer; a negated guard inverts) |
| `jq-alternative-swallows-false` | fix | advisory | ledger | added-line-regex | jq's `//` swallows `false` as well as `null` — use has()/type for presence, not `// empty` |
| `non-ascii-bracket-expression` | fix | advisory | ledger | added-line-regex | non-ASCII literal inside a grep/sed/awk bracket expression never matches under the default locale — use an alternation |
| `md-fence-no-lang` | fix | advisory | cr-app-comments | md-fence-no-lang | fenced code block without a language tag (markdownlint MD040) |
| `hook-fail-direction` | checklist | advisory | ledger | hook-header-no-fail-direction | new hook without a stated fail-open/fail-closed direction + bypass |
| `test-fixture-stub-fidelity` | rebuttal | prompt | ledger | — | stub-fidelity / over-verification findings against a test fixture |
| `docs-prose-relitigation` | rebuttal | prompt | ledger | — | doc-wording findings that contradict the implementing script |
| `pr-check-anchor-handshake-escalation` | rebuttal | prompt | coderabbit-learning | — | PR_CHECK_ANCHOR_DELEGATED handshake called forgeable => privilege escalation |
| `cr-avail-artifact-perspective-scoping` | rebuttal | prompt | critic-panel | — | CR-ledger availability rows claimed to need artifact/perspective scoping |
| `test-setup-unchecked-vacuous-green` | checklist | prompt | cr-app-comments | — | test setup or child-process status unchecked — the suite cannot fail (vacuous green) |
| `exit-contract-drift` | checklist | prompt | cr-app-comments | — | an exit code gains a second meaning without its documented contract being updated |
| `suggestion-verdict-flow` | rebuttal | prompt | cr-app-comments | — | Suggestion findings need a verdict for the marker gate even though they never enter blocking counts — the flow is documented |

## What the 2026-08-23 measurement said (why these classes)

- CodeRabbit learnings export, 182 rows / 4,722 uses (up from 143 / 3,163 on
  2026-08-10): top 5 = 65 % of uses; errexit trio 1,786 (38 %), octal 552,
  handover-bootstrap 740 + 203 + 41, mktemp 220 (+ a contradicting 75-use entry),
  `\s` 199, PS1 BOM 91 (stale, contradicts a later decision).
- A learning **use** is CodeRabbit applying the learning, not re-raising the
  finding. Measured on the App's own review comments (703 finding-comments on
  225 PRs since 2026-07-01; 158 on 48 PRs since 08-10), the big-usage classes
  are now nearly silent (errexit 2, octal 2, bare wait 1, rm -f 1 since 08-10 —
  half of them legitimate). What still re-raises: stale docs prose (21),
  GNU-vs-BSD portability (20), test-coverage gaps (16), fail-open/closed on
  hooks (10), markdownlint MD040/MD051 (~8), bare `mktemp -d` in new tests (6),
  .sh/.ps1 twin drift (5). Those became the `fix` / `checklist` detectors; the
  high-usage learnings became `rebuttal` prompt classes.
- Our ledger (12,522 rows, 3,667 unique findings): 62 % agreed / 21 % disproved /
  14 % deferred of the adjudicated; 38 % of unique findings carry no verdict,
  88 % of those on a head that was superseded before adjudication was recorded.
  Retired open-weight critics (kimi, qwen, gptoss, laguna) disproved at 70-90 %
  and are already off the panel; codex 23 %, codex-adv 6 %, glm 17 %,
  coderabbit 24 %. Test-fixture bucket disproves at ~29-34 %, docs at ~25 %.
- **Before-metric for NOW-19:** rounds per branch (distinct reviewed heads) —
  all branches since 2026-08-01 mean 3.24 / median 2 (n = 348); last 30 branches
  mean 2.63 / median 2, 3.9 findings per branch, 1.17 round-1 Critical+Important
  per branch. CodeRabbit App: 3.3 finding-comments per PR since 08-10.
- Of the 2026-08-10 analysis, nothing had been integrated: the two
  `.coderabbit.yaml` carve-outs are still To Do, and no ledger mining beyond
  `cr-tune`'s per-model buckets had happened. Full numbers + method in the
  handover analysis note of 2026-08-23 (`cr-learnings-analysis`).

## What the 2026-09-02 refresh added

- **The export's high-usage tail is now fully covered, and that is the finding.**
  227 rows / 4,824 uses: all 13 rows at >= 50 uses already map to an existing
  class, and the 139 unmatched rows total 323 uses between them (largest single
  row: 37). On the `/cr-learnings-refresh` threshold the correct answer was
  **zero** new classes from the CSV — the bar was not lowered to manufacture any.
- New classes came instead from a fresh measurement of the CodeRabbit App's own
  review comments: 69 comments across 60 PRs since 2026-08-20, bucketed by hand.
  What that window says still recurs: `handover-root-bootstrap` **8 raises across
  6 PRs, every one withdrawn on rebuttal** — the most-raised class in the window
  despite being the #1 learning at 1,009 uses, which is why its rebuttal now
  enumerates the four sub-shapes (transitive, REPO_ROOT, git-common-dir, blanket)
  rather than restating the rule; unchecked test setup / ignored child status (3);
  macOS-BSD portability (3); exit-contract drift (2); Suggestion adjudication (2).
- **A detector's noise is measured before it ships, not estimated.** The obvious
  broad form of `jq-alternative-swallows-false` matches 147 lines repo-wide (293
  raw `// empty` occurrences), nearly all legitimate string defaults; the narrow
  boolean-ish-field form ships instead, at 5 repo-wide hits. A detector that fires
  on every PR buries the checklist it is meant to sharpen.
- **Declined, with the reason recorded so the next refresh does not re-litigate:**
  the `<gate> | tail` return-code loss is already structurally enforced by the
  registered PreToolUse hook `block-tail-pipe-on-gates.sh`, so it is
  coverage, not a class; the ledger's `--set reason=` vs `--reason` trap is a
  CLI-workflow shape, not something a critic raises on a diff; `command -v` as a
  runnability probe had no App or ledger evidence in the window.
- Detectors are validated through `known-findings.sh` itself on a planted fixture,
  never a hand-rolled regex replica — a replica's escaping differs from `ere()`'s
  and produced two false alarms during this refresh. Each new detector ships with
  a bait line and the correct spelling one line below it (see
  `testdata/known-findings/README.md`); against the pre-change 19-class JSON
  exactly the six positive assertions fail (**64 ok / 6 fail**), which is the
  red-first proof. **Re-measure this pair of numbers whenever an assertion is
  added** — it is an evidence claim, not a description, and it went stale once
  during this very refresh (a sixth assertion was added while the text still
  said 63/5; the critic panel caught it at the gate re-stamp).
- **A red-first pair must be DISCRIMINATING, not merely present.** The pairs
  shipped in the first commit all passed against both a correct and a broken
  detector, because each exercised only a string both versions matched — which
  is how two detector defects reached review. The round-3 pair is the model to
  copy: bait `change1.sh:22` (`.agent_id // empty | type`) against control
  `change1.sh:15` (`(.agent_id | type) == "string"`), where flipping the one
  token under test changes the verdict.

## Verdict labels: by-design vs disproved

`disproved` (the ledger's grammar — `scripts/cr/write-verdicts.sh`) means the
critic's factual claim was checked and found wrong. It does not fit a finding
whose claim is true but whose behavior is intended: a critic can correctly
describe a deliberate, non-regressing change and still get recorded as
`disproved` if the adjudicator reads "we're keeping this behavior" as "the
claim is false". That misreads the finding as noise rather than as a
documented tradeoff, and lets `cr-tune`'s per-critic scoring count an
accurate finding against the critic that raised it.

Independent judge J1407A (verdict:
`handovers/yotamleo/himmel/verdicts/J1407A/verdict.md`) found exactly this on
PR #1407: codex-1 (`headed-arm-leg.sh:468/469`) and codex-2
(`headed-arm-leg.sh:618`, same PR) were both ledger-recorded as `disproved`,
but both claims are factually true — the round adjudicated "keep the
behavior" as if it meant "the claim is wrong". The ledger rows are left
unrewritten (out of scope for a doc-only follow-up); the relabel is recorded
as a Jira comment instead, so a future `cr-tune` pass over this
window can read the correct label without a ledger rewrite.

Related: [`enforcement.md`](enforcement.md) (the CR gate), `/cr-tune` (per-model
tuning proposals — different question: *which critic* is miscalibrated; this
page answers *which finding class* keeps recurring), `/cr-scores`.
