# Fork adapter standard

Every `yotamleo/*` fork is a himmel adapter (HIMMEL-5900): it is listed in
`scripts/guardrails/himmel-adapters.json`, and a change to it follows the himmel
flow (ticket ID on every commit and PR, judge, signed GO, console merge). The
registry is read from the default branch of the harness repo, so a worktree edit
cannot widen it. Shape and coverage are checked by
`scripts/guardrails/test-himmel-adapters.sh`.

## Registry row

| Field | Meaning |
|---|---|
| `nwo` | `owner/name` of our fork; one row per fork, no duplicates |
| `upstream` | the repo the fork tracks |
| `himmel_branch` | the one branch a console merge may land on; the fork's default branch where himmel carries no delta |
| `pin_site` | the himmel file that pins the fork, or `null` |
| `role` | `runtime-dependency`, `upstream-contribution`, `vendored-source` or `dormant` |
| `merge_allowed` | `true` only for a fork himmel carries a delta on and merges into itself |

Roles: a runtime dependency is installed or loaded by himmel; an upstream
contribution keeps the upstream PR flow (no upstream PRs where there are no
external contributors); a vendored source is copied into himmel; a dormant fork
is listed and marked, never deleted. Archived forks are not merge targets; an
unarchived one is registered with `merge_allowed` true.

## Adding or changing a fork

1. Add the row in the same PR that creates the pin site or the fork.
2. Add the fork's `nwo` to `FORKS` in the registry test (and to `MERGE_TRUE` if it
   merges); the test fails on any fork without a row or a row without a fork.
3. Per-fork gates (commit-msg ticket check, judge gate, branch protection note)
   are the pre-commit core in `docs/internals/fork-precommit.md`; a gap is a
   follow-up ticket, not a registry field.

## Sync rule

A fork is synced with its upstream (`/fork-resync`) whenever a leg handles it,
before any work on it. A fork behind its upstream is resynced first.
