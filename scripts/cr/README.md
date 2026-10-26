# scripts/cr

Review-gate scripts (review rounds, verdict ledger, CR marker).

## Live review-gate e2e

`scripts/cr/live-gate-e2e.sh` drives one canned PR through the gate against a
REAL throwaway private repo, because the shell suites only ever see a stubbed
`gh`. It runs on demand and refuses under `CI` / `GITHUB_ACTIONS`; it is not in
any workflow.

```bash
HIMMEL_REPO=<primary checkout> bash scripts/cr/live-gate-e2e.sh [--repo owner/name]
```

Default repo: `yotamleo/himmel-gate-e2e` (created private when absent, reused
after). It refuses a repo named Himmel, the anchor's own origin, or a public repo.

What it asserts, in order:

1. `ready-check.sh` FAILs on check 4 (no CR ledger row yet).
2. A posted inline review finding plus a ledger row: FAILs on check 3 (open thread).
3. After the thread is resolved and the repo's own status context settles:
   `ready-check.sh` PASSes.
4. `merge-on-green.sh --dry-run` as a chief worker (`HIMMEL_CONSOLE_LEG=1`) refuses
   (rc 17 or 18) and the PR stays OPEN.

Each run closes its canned PR and any leftover `test/e2e-*` PRs. The repo is
kept; delete it with `gh repo delete yotamleo/himmel-gate-e2e --yes`.

Notes:

- **cwd binding.** `merge-on-green.sh` and `ready-check.sh` resolve the repo from
  the current directory (`gh repo view`). The runner clones the throwaway repo to
  `<worktree>/.himmel-scratch/gate-e2e` and runs from there; a clone outside the
  project dir resets the shell cwd, and one on `main` trips the edit-on-main guards.
- **No operator alerts.** `merge-on-green.sh` is only ever run with `--dry-run`,
  no auto-merge or merge-watch is armed, and `MERGE_BLOCK_ALERT_CMD` points at a
  recorder so the MERGE-BLOCKED Telegram DM is intercepted, never sent.
- **Snapshot cache.** `ready-check.sh` reads a head-keyed 60 s PR snapshot; the
  runner gives each call a fresh `GH_PR_SNAPSHOT_CACHE_DIR` so a thread resolve
  is visible on the next read.
- **Known ceiling.** On a free-plan private repo both required-check reads return
  HTTP 403, so `check-ci.sh` fails closed and the merge refuses at exit 18 before
  the GO gate; the merge-with-GO worker is not reachable.

`scripts/cr/test-live-gate-e2e.sh` holds the offline rows (the refusals only).
