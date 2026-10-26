# docs-review eval

Does the `docs-reviewer` skill
(`marketplace/plugins/himmel-ops/skills/docs-reviewer/`) find what the operator
found, and name the code a docs finding implies? Each case is a frozen docs
change and a cut of the remarks table that leaves out the remarks which would
give the answer away. The pass bars are held out in `key/`.

| path | what |
|---|---|
| `cases.json` | per case: the PR, base and head shas, which remark rows the run may see, and whether it may read the PR comments (`comments_before`: only those made before this time, or `none` for all) |
| `key/bars.json` | the held-out pass bars and, where one exists, the ground truth (a later fix commit, or a ruling) |

| case | change | tests |
|---|---|---|
| A | PR 3865 | the remark pass: the 7 points of decision 270, from remarks made before it |
| B | PR 3892 | the code-changes section: a CodeRabbit comment whose fix is in the generator, still open at the head |
| C | `docs/jarvis-subsystems.md` | the learn step: add decision 284 as a candidate, then apply it |
| D | PR 3910 | severity: BLOCKING findings on a reviewed, merged page, true against false |
| E | PR 3851 | the clean control: a page no later commit corrected should draw no BLOCKING finding and no code change |

## Running a case (opus high, one run per case)

`run.sh --out <dir> A B D E` runs each case once on the api lane
(`scripts/api-lane/claude-api.sh`, account `auto`, `$6` cap per run, `$24` per
batch). The reviewer gets Read, Glob and Grep only, over a `git archive` export
of the head with every `CLAUDE.md`, `AGENTS.md`, `.claude/` and `.agents/`
removed, and an empty `CLAUDE_CONFIG_DIR`, so no hook, plugin or memory file
loads. It has no git and no gh: the diff, the cut remarks table and the PR
comments up to the case's `comments_before` (B stops before its fix commit
537d0f2a8) sit in `REVIEW-INPUT/`, replies and bot "addressed" lines removed. A free canary
checks that isolation before each billed call and stops the batch if it fails.
`--canary-only` runs the canaries and never bills. Case C stays manual: its
learn step needs Edit.

Each case leaves `review.md`, `review.json` and `audit.txt` (tool calls whose
path left the fixture) under `<dir>/<case>/`. Score `review.md` against
`key/bars.json` by hand, and say which bars it met.

Before you trust a run, check that the case's code gap is still open at the
head: a bar that names a fix already in the base cannot be met.
