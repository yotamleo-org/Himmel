---
name: no-comments
description: "Run comment-sicko and fix its findings."
disable-model-invocation: true
---

> **Vendored, pinned to a commit (HIMMEL-5630).** Source: `cursor/plugins`
> (pstack), commit `99743e9c151c8537cbbf1f98bb38f34ef3368453`, path
> `pstack/skills/no-comments/SKILL.md`. License: MIT, (c) 2026 Lauren Tan
> (`LICENSE` beside this file is the verbatim `pstack/LICENSE` at that commit).
> Pairs with `.claude/agents/comment-sicko.md`.
>
> **Deviations from upstream** (re-check each before re-syncing a future revision):
> 1. Step 1: the `poteto-mode` subagent-sizing reference is replaced by himmel's
>    rule (explicit model on every dispatch; `docs/internals/lane-calibration.md`).
> 2. Step 2: the `/how` and `/why` hunts are replaced by plain reading of the
>    named symbol and its callers (`git grep`); neither skill ships in himmel.
> 3. Steps 3 and 4: `/architect` and the `principle-*` skills are not shipped;
>    the sketch is a short inline note, and "intent only" guidance is kept as prose.
> 4. The keep list has no himmel addition: an accepted limitation is a
>    ceilings-ledger row (`scripts/ledger/ceiling-add.sh`,
>    `docs/internals/code-comments.md`), never a comment. The agent file says
>    the same.
> 5. The "Sweep and the gate" section at the end is himmel's: the new-comment
>    gate and the repeatable sweep of the comments already in the tree.
>
> No other wording differs from the pinned commit.

# No comments

Spawn Comment Sicko. Act on accepted findings.

Defer to Comment Sicko's fresh perspective.

## Scope

Use the caller's files or diff. Otherwise use the current diff against the base branch, default `main`, including the working tree.

## Steps

1. Spawn the `Agent` tool with `subagent_type: "comment-sicko"` and an explicit `model` (`sonnet` unless the scope is unusually subtle; raise effort before tier). Pass the scope.
2. Inspect its report and diff. Reject application-code edits, scope escapes, exception-protected deletions, misstated `MUST KILL` reasons, and flags that treat kept intentional code as guilty. Reshape flags on our-code surprises stay actionable. Do not restore those comments. A keep survives only with proof it is about something we cannot change. Audit missed scoped lint and TypeScript suppressions. Correctness or safety suppressions stay actionable `MUST KILL`s. Restore deletions only with exact exceptions and scoped proof. Before accepting thin `IMPORTANT` or `do not remove` kills or keeps, read the named symbol and its callers (`git grep`). If a kill is ambiguous, do not restore. If a keep is refuted or still ambiguous, delete it. Revert and rerun one rejected report with the failure named. Reject a second, report it open, and fail `/no-comments`.
3. Fix trivial accepted flags directly by deleting a dead path, dropping a parameter, or using the real API. If any fix needs a shape, write a short sketch for the accepted set and surrounding code. Stop at the sketch. Step 4 implements.
4. Implement the smallest root-cause fix in scope. Remove every named workaround. If the root cause is out of scope, land the smallest in-scope fix and report the rest open. Fix root causes and redesign from first principles, but never widen the fence nor fix instances outside it. Never bolt on symptom guards.
5. Constraint comments say `do not remove`, `do not change wording`, or `talk to X before changing`. Leave keeps about things we cannot change. Offer the cheapest in-scope type, runtime, test, or CI lint. Wait for interactive approval. Unattended and eval require caller pre-approval. If approved, encode then delete. Otherwise delete, report the constraint open, and sketch out-of-scope work.
6. Report the deletion count, restored comments, reruns, sketch, fixes, encoding offers, encodings, unenforced constraints, and other open work.

## Sweep and the gate

`scripts/lint/check-new-comments.sh` refuses a new comment outside the keep list at pre-commit and in CI. Each code file's count of such comments is a row of `scripts/lint/comment-baseline.tsv`, keyed by a hash of the path, and a row only goes down (`docs/internals/code-comments.md`, which also gives the command that lists the counts by path). A touched file is held to the lower of its row and the count of its version on the base, so a sweep lowers the limit by deleting comments and never writes the baseline:

1. Pick a slice of at most 40 files from that list, none of them changed by an open PR (`gh pr diff <n> --name-only` for each open PR).
2. Run the steps above with the slice as the scope.
3. Sort what Comment Sicko kills. A comment that restates the code or names code that is gone is deleted. A comment that excuses a workaround is deleted and one ticket is filed to fix the code. A decision worth keeping becomes a short record in the state repo bucket `specs/decisions/`. A known limitation becomes a ceilings row (`scripts/ledger/ceiling-add.sh add`).
4. Leave `scripts/lint/comment-baseline.tsv` alone, so two sweep PRs on different files share no file. Run `bash scripts/lint/check-new-comments.sh --range <base>` as the proof of the slice; a separate PR rewrites the baseline with `--write-baseline` after sweeps merge.
