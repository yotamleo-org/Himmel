## Impact
Suggestion and nit findings from a code review were left unfixed so a pull request could merge; without a ticket they are forgotten.

## What
Track those deferred findings in one place and fix them when convenient.

## Why
The review cap stops after three rounds; the leftovers need an owner so they are not lost.

## Plan
1. Add the PR number and the finding ids in a comment, then fix each deferred finding or close it as won't-fix.

## DoD
- Every deferred finding is fixed or closed with a reason, and this ticket is moved to Done.

## Agent detail
Filed from `scripts/cr/review-round.sh` when `/pr-check` hits the round cap with only suggestion/nit rows. Add the PR number and the finding ids in a comment, then resume with `CR_DEFER_TO=<this ticket>`.
