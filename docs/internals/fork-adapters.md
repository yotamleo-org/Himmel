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

Syncing a fork with its upstream is upkeep, never a PR (HIMMEL-8334):

- **No carried commits** → keep no fork: point pins and installs at the
  upstream. The nightly drift issue says `use-upstream <upstream>` for it.
- **Carried commits** → `bash scripts/upstreams/resync-fork.sh --sync <fork>`:
  `gh repo sync` of the fork's default branch, then our commits rebased onto the
  upstream default branch and pushed to the himmel branch (the old tip kept as
  `himmel-presync/<branch>-<sha12>`). A conflict stops, names the paths and
  pushes nothing; nobody opens a PR to finish it.
- `block-fork-sync-pr.sh` refuses a `gh pr create` whose base is a fork and
  whose head is an upstream branch, or a branch of ours that is mostly upstream
  commits.
- The judge, the signed GO and CodeRabbit cover only our carried changes. A PR
  to a fork carries only our own authored delta, and the critic panel diffs a
  fork PR from its merge-base with the upstream default branch, so
  upstream-authored commits are never reviewed. The panel reads that branch
  from `refs/remotes/<upstream>/HEAD` (`git remote set-head upstream -a`);
  without it the whole PR is reviewed.
