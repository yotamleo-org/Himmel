# pstack integration map (HIMMEL-5851)

The seven vendored pstack skills (`marketplace/plugins/pstack`, pinned
`99743e9c`, [`VENDORED.md`](../../marketplace/plugins/pstack/VENDORED.md)) are
installed for interactive sessions only (route and per-skill adopt decisions: the
HIMMEL-5802 audit, follow-ups HIMMEL-5803 to HIMMEL-5807). This page maps each one onto the himmel
flow it should strengthen, names the overlap, and records which one gets the
measured POC. Verdicts live in [`registry.md`](registry.md) once the POC has run.

## Mapping table

| Skill | Target flow | Value hypothesis | Overlap | POC? |
|---|---|---|---|---|
| `blast-radius` | `/pr-check` step 3.5 (reviewer stage), opt-in | Surfaces breakage outside the diff by running real code; the CR panel reads the diff, so cross-file breakage is its blind spot | CR panel and `pr-review-toolkit` `code-reviewer` (diff-scoped); `impacted-suites.sh` finds suites by text reference, not by behaviour | **Yes** |
| `correct` | Review-fix round; repeated-mistake classes become gates | Turns a class of repeated review findings into a lint or test instead of prose | CR learnings refresh (`cr-learnings-refresh`), the "second drift escalates to a hook" rule in `CLAUDE.md` | No: process skill, no single flow to wire |
| `create-verification-skill` | RED-first worker contract; `docs/internals/testing.md` | A project-local skill that drives the harness like a user gives workers a scripted way to prove behaviour | `scripts/ci/run-shell-tests.sh`, `quiet-run` | No: needs a target app; himmel has no single target app |
| `maintain-verification-skill` | Periodic upkeep of the above | Keeps the feature map honest | Only meaningful once `create-verification-skill` has a target | No: depends on the row above |
| `benchmark-checklist` | Eval scorecards, cost reports, leg-digest | Stops an unvetted number reaching a report | Rubric measurement protocol (`rubric.md` §4), `docs/tool-adoption/telemetry.md` | No: candidate for a later wiring into the A/B scorecard |
| `principle-explain-the-number` | Same as `benchmark-checklist` (its shorter principle form) | Names the limiter before a number is trusted | `benchmark-checklist` (it points to it for perf numbers) | No: fold with `benchmark-checklist` |
| `in-your-own-words` | `brainstorming` and `minerva` grill stages | Forces a restatement of the goal | `lean-skills:brainstorming`, `grilling` already open with goal restatement; one line of text, no leverage | No |

## Related take-parts tickets (not duplicated here)

Four pstack skills outside the seven are being taken in part, nothing installed;
their scope stays in their own tickets: HIMMEL-5808 (`interrogate` verdict
buckets into adversarial-verify), HIMMEL-5809 (`reflect` routing step into the
wrap flow), HIMMEL-5810 (six-principle digest), HIMMEL-5811 (`arena` base
selection and graft rule). The unvendored `poteto-mode` and the fork's
SessionStart hook stay out: they grant autonomy the chief, RETASK and GO rails
own (HIMMEL-5697, A1).

No overlap with `unslop`, `no-comments` or `comment-sicko`: those edit prose and
comments, while the seven review behaviour, vet numbers or generate
verification skills. `correct` is the nearest neighbour to `no-comments` (both
remove a repeated mistake class) but acts on process, not on text.

## Why `blast-radius` is the POC

It is the only skill with a flow that already has a defined slot, a measurable
outcome (does it flag a defect the panel missed?) and a cheap opt-in switch. The
others are process skills with no gate to wire into, or need a target that does
not exist yet.

## The wiring

`/pr-check` step 3.5 gains one opt-in bullet: with `CR_CLAUDE_AGENTS=blast-radius`
(the one variable the existing resolver and allow rule already cover) the
orchestrating session applies the `blast-radius` procedure to the diff after
adjudicating the panel, and records any proven breakage as a normal `[claude-N]`
finding. That value runs no agent matrix. Default off: the unset path is
unchanged. Follow-up on the default: HIMMEL-5855. Nothing
in `scripts/lanes/plugin-profiles.json` changes; the procedure is read from the
vendored skill file, so it works in a worker that has pstack disabled.

## A/B result (2026-10-16)

Method: for each merged guard PR that a later fix PR repaired, a fresh sonnet
agent applied `blast-radius` to the ORIGIN commit blind (no later commit, PR text
or issue), running extracted copies of the files at that commit. Success means
the later-fixed defect was surfaced. Sample: 3 pairs, 218k tokens total (about
0.7 USD at sonnet rates), under the 2 USD cap.

| Origin | Later defect (fix PR) | Surfaced? | Tokens | Wall | Other proven findings |
|---|---|---|---|---|---|
| 420e7acfd (#2506) empty-expansion guards | A default word holding the protected command, `${V:-git} stash drop`, passed (#2614) | n: only empty defaults were probed | 67k | 75 s | `git "$@" stash` allowed (rc=0); over-denies on `${X:-$(date)}` in messages |
| a1377cb54 (#2544) shell-trace deny | Tracing word denied in data positions such as commit messages (#2658) | y (class): `git commit -m "fix xtrace handling"` and `grep xtrace file` proven denied | 72k | 101 s | Brace-subsequence false denies; bypasses via variable-built flag, versioned shell names, stdin |
| 419260add (#2527) pipe-to-shell re-read | The hook's own file name counted as a gate mention, over-denying readers (#2660) | n | 79k | 147 s | Heredoc body feeding a shell not scanned; wide over-denies on unresolvable `env -S` writers |

Reading: 1 of 3 later defects caught, but every run proved real defects the
shipped suites did not cover (bypasses and over-denies alike) at about 70-80k
tokens and 1-2.5 minutes. Not measured: the CR panel's findings on the same
origin diffs, so "caught beyond the panel" is unproven, and the sample is three
guard PRs by one author type. Treat the result as promising, not conclusive.
