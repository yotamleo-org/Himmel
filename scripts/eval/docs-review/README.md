# docs-review eval

Does the `docs-reviewer` skill
(`marketplace/plugins/himmel-ops/skills/docs-reviewer/`) find what the operator
found, and name the code a docs finding implies? Each case is a frozen docs
change and a cut of the remarks table that leaves out the remarks which would
give the answer away. The pass bars are held out in `key/`.

| path | what |
|---|---|
| `cases.json` | per case: the PR, base and head shas, which remark rows the run may see, and whether it may read the PR comments |
| `key/bars.json` | the held-out pass bars and, where one exists, the ground truth (a later fix commit, or a ruling) |

| case | change | tests |
|---|---|---|
| A | PR 3865 | the remark pass: the 7 points of decision 270, from remarks made before it |
| B | PR 3892 | the code-changes section: a CodeRabbit comment whose fix is in the generator, still open at the head |
| C | `docs/jarvis-subsystems.md` | the learn step: add decision 284 as a candidate, then apply it |
| D | PR 3910 | severity: BLOCKING findings on a reviewed, merged page, true against false |

## Running a case (opus high, one run per case)

There is no runner. For each case, give a fresh read-only opus subagent
(`judge-ro`) the skill's `SKILL.md`, a copy of `remarks.tsv` cut to the case's
`remarks` filter, and the case's PR and shas. The brief says: read nothing
after the head, no `specs/decisions/`, no handovers, and never `key/`. Score its
output against `key/bars.json` by hand, and say which bars it met.

Before you trust a run, check that the case's code gap is still open at the
head: a bar that names a fix already in the base cannot be met.
