# Review by a second model

Audience: an adopter or contributor who wants to know what reviews a change, what a finding can stop, and how to answer one.

> **Where it runs:** the merge gate's reviewer check and CodeRabbit run in your
> own project. The `/pr-check` review runs from your himmel checkout: its
> scripts can review a branch of your project, but the command itself is not
> installed into your project. Details in [Where it runs](#where-it-runs).

Every change is reviewed twice. `/pr-check` reviews the branch before its pull
request opens, and the merge gate checks the reviewers again at the pull
request's head before `gh pr merge` goes through. A second model family (OpenAI GPT through Codex) is what makes the review a
cross-check rather than Claude grading its own work.

## What reviews your change

The reviewers are the rows of `scripts/cr/critics.json`. As shipped:
<!-- source: scripts/cr/critics.json -->

- **codex**: an OpenAI GPT model through the Codex CLI (the row's `model`
  field pins which one). Mode `hard`, `required`. This is the second model
  family and, as shipped, the only one.
- **claude**: a Claude model through the Claude API lane. Mode `hard`, but
  absent while that lane is off, so it leaves the set. It is the same model
  family as the author, so it never counts as cross-model evidence.
- **coderabbit**: the CodeRabbit GitHub app on your repo. It reviews the pull
  request once it opens and posts threads and a commit status. Mode
  `best-effort`.

The critic tier, `CR_PROFILE`, picks which rows `/pr-check` dispatches:
<!-- source: scripts/cr/critic-panel.sh -->

- `none`: Claude only, no external spend.
- `free` (the default when unset): the free rows. The shipped file has none,
  so the panel falls back to the paid codex critic, which spends on your
  OpenAI account.
- `paid`: the paid rows, codex and claude.

If every critic fails, `/pr-check` falls back to a Claude-only review.

## What a finding does

A finding has a severity: Critical, Important or Suggestion. Critical and
Important findings block; a Suggestion is a note. A reviewer that cannot run
blocks or is a note depending on its mode.

**Before the pull request opens** (`/pr-check`, in a himmel checkout):

- A push leaves a review-owed marker on the branch, and `gh pr create` is refused while it is there. <!-- source: scripts/hooks/check-cr-before-push.sh, scripts/hooks/check-cr-marker-on-pr-create.sh -->
- The marker clears only when a critic actually responded at the branch tip; zero responders is a missing review, not a clean one. <!-- source: scripts/cr/clear-review-marker.sh -->
- A Critical or Important finding blocks the clear until it is ruled `disproved`, or `deferred` with a ticket key and a reason. <!-- source: scripts/cr/clear-review-marker.sh -->
- Every finding, a Suggestion too, needs a ruling before the marker clears. <!-- source: scripts/cr/clear-review-marker.sh -->
- With `CR_REQUIRE_CROSS_MODEL=1`, at least one responder must be a non-Claude critic. <!-- source: scripts/cr/clear-review-marker.sh -->
- A branch gets three full review rounds, then one delta round over only what changed since the last review. A fourth full round is refused. <!-- source: scripts/cr/review-round.sh -->

**At the merge** (in your project and in a himmel checkout):

- A `hard` reviewer must pass at the pull request's head. Anything else (in progress, not yet run, rate limited, unavailable, an open finding) holds the merge. <!-- source: scripts/lib/review-merge-gate.sh -->
- A `best-effort` reviewer holds only on an open finding. Otherwise it prints a NOTE and the merge goes on. <!-- source: scripts/lib/review-merge-gate.sh -->
- A reviewer set with no `hard` reviewer left is a config error and blocks, unless the repo says `"review": "no_code_review"`; then CI alone decides. <!-- source: scripts/lib/review-merge-gate.sh -->
- Every review thread on the pull request, CodeRabbit's included, must be resolved: `check-ci.sh` does not pass while one is open. <!-- source: scripts/check-ci.sh -->

## Answering a finding

Each finding gets one of three answers:

1. **Fix it.** Change the code and push. The fix is reviewed in the next
   round, at the new head. The finding is ruled `fixed`.
2. **Dispute it.** Rule it `disproved` with a written reason, when the
   finding is wrong.
3. **Defer it.** Rule it `deferred` with a ticket key and a reason, when it is
   real but belongs in a follow-up. A `deferred` ruling with no ticket key
   still blocks.

`/pr-check` records each ruling in the review ledger for you. A CodeRabbit
thread is answered on the pull request: fix it, or reply with why, then resolve
the thread.

When a `hard` reviewer is unavailable (out of credit, rate limited), the merge
holds until it can review. Re-run it, or change its mode in your
`critics.local.json` overlay.

## Settings

The settings that change the review are in the
[Review by a second model](../configuration.md#review-by-a-second-model) group
of the configuration page:

- `CR_PROFILE`: the critic tier.
- `CR_REQUIRE_CROSS_MODEL`: require a non-Claude critic.
- `critics.local.json`: add, change or drop a reviewer on your machine. Its
  field rules are in [Reviewer modes](../configuration.md#reviewer-modes).

`bash scripts/cr/critic-panel.sh --check` prints every reviewer with its mode
and state.

## Where it runs

- **In your own project.** The install copies in the merge gate's reviewer
  check and the reviewer list, so `gh pr merge` holds there on the same rules.
  CodeRabbit reviews pull requests on your repo once you add the app.
  <!-- source: scripts/adopt.sh -->
- **From your himmel checkout.** The `/pr-check` command ships with the himmel
  checkout, not your project. Its scripts take the repo from the working
  directory and the himmel scripts from the checkout that `HIMMEL_REPO`
  names, so they can review a branch of your project.
  <!-- source: scripts/cr/pr-check-context.sh -->

Your project has no review-owed marker, so nothing there refuses
`gh pr create` before a review.
