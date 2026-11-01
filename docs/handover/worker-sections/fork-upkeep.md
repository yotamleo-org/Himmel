# Worker section — fork upkeep

Read on demand: a brief that has you rebase, sync or patch a fork (graphify, an
adapter, any repo we own outside the himmel checkout) names this file.

## Where the fork clone lives

A clone in your session scratchpad (`/tmp/claude-<uid>/<project>/<session>/scratchpad/`)
is deleted when the session ends. Work in it is safe only until you wrap.

Fork pushes are chief-owned, so finished work often waits for a consent between
two sessions. Work that must wait lives in one of two places, never in the scratchpad:

1. **The persistent root `~/.himmel/scratch/<clone>`** (any depth below it, for
   example `~/.himmel/scratch/gfork/graphify`). The main-checkout write guard
   treats a standalone clone there like a scratchpad clone: no `.single-writer`
   marker needed. The refusals stay for the primary checkout, a linked worktree,
   an adopted primary and a `.himmel-dev` checkout. Clone from a URL or with
   `--no-hardlinks`; a hard-linked local clone is refused.
2. **A non-protected staging branch on the fork**, pushed before you wrap
   (for example `staging/<ticket>-<slug>`; never the fork's default or any
   protected branch). Push the branch only; the chief owns the push to the
   protected branch.

Name the clone path and the staging branch in your `WRAPPED` or `RESUME` doc.

## The wrap check

`close-wrapped-worker.sh` refuses (exit 8) to close a worker whose doc names a
session-scratchpad clone that holds commits on no remote. Fix it by pushing the
commits to the staging branch, or by moving the clone under `~/.himmel/scratch/`,
then re-run.
