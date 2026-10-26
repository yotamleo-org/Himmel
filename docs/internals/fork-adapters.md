# Fork adapter standard

Every `yotamleo/*` fork is a himmel adapter (HIMMEL-5900): it is listed in
`scripts/guardrails/himmel-adapters.json`, and a change to it follows the himmel
flow (ticket ID on every commit and PR, judge, signed GO, chief merge). The
registry is read from the default branch of the harness repo, so a worktree edit
cannot widen it. Shape and coverage are checked by
`scripts/guardrails/test-himmel-adapters.sh`.

## Registry row

| Field | Meaning |
|---|---|
| `nwo` | `owner/name` of our fork; one row per fork, no duplicates |
| `upstream` | the repo the fork tracks, or `null` for a first-party repo |
| `himmel_branch` | the one branch a chief merge may land on; the fork's default branch where himmel carries no delta |
| `pin_site` | the himmel file that pins the fork, or `null` |
| `role` | `runtime-dependency`, `upstream-contribution`, `vendored-source`, `dormant` or `first-party` |
| `merge_allowed` | `true` only for a fork himmel carries a delta on and merges into itself, or a first-party repo himmel merges into |

Roles: a runtime dependency is installed or loaded by himmel; an upstream
contribution keeps the upstream PR flow (no upstream PRs where there are no
external contributors); a vendored source is copied into himmel; a dormant fork
is listed and marked, never deleted. Every fork is registered, archived or
not; only a fork himmel carries a delta on and merges into, or a first-party repo, has `merge_allowed`
true, so an archived or contribution-only fork stays false. A first-party repo
is a `yotamleo-org` repo that is not a fork (for example `himmel-voice`): it
follows the same himmel flow, has `upstream: null` and role `first-party`, and
is left out of the third-party credits page.

## Adding or changing a fork

1. Add the row in the same PR that creates the pin site or the fork.
2. Add the repo's `nwo` to `ROWS` in the registry test (and to `MERGE_TRUE` if it
   merges); the test fails on any fork or first-party repo without a row, or a
   row without a repo. A first-party repo is also added to
   `fixtures/himmel-adapters/yotamleo-org-first-party.json`.
3. Per-fork gates (commit-msg ticket check, judge gate, branch protection note)
   are the pre-commit core in `docs/internals/fork-precommit.md`; a gap is a
   follow-up ticket, not a registry field.

## Sync rule

A fork is synced with its upstream (`/fork-resync`) whenever a worker handles it,
before any work on it. A fork behind its upstream is resynced first.
