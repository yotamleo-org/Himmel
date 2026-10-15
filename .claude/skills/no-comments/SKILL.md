---
name: no-comments
description: "Spawn Comment Sicko, fix accepted findings, and offer encodings for claimed constraints."
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
> 4. `ponytail:` markers (`docs/internals/ponytail-convention.md`) join the keep
>    list. This is also in the agent file.
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
