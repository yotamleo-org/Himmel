# Console section — wrapping a leg by hand, and the digest line

Read on demand from `console-template.md` `## Wrapping a leg`. Moved verbatim from the template.

## Wrapping a leg

**The waiter wraps workers; do not run `leg-event` / `close-wrapped-leg` by hand;
run any other bounded script as `timeout 90` in the foreground.** A waiter armed
with `--doc` and `--legs-from` runs `leg-event.sh` itself on every new `WRAPPED`
or `MERGED` worker (`waiter.md`, the script relay) and wakes you only with
`WAKE leg-event <line> out=<file>` when it could not. A `leg-event.sh` re-run on a
worker already closed prints `HANDLED noop <label>`. The paths below are for that
wake, or a chief armed without `--legs-from`.

**One call per message.** Write the worker's `MERGED` or
`WRAPPED` message to a file and run
`bash scripts/handover/console-kit/leg-event.sh --doc <console doc> --fleet <manifest> <message-file>`.
It finds the leg doc by the message's `N<k>` label and runs
`console-kit/wrap-merged.sh` (PR state, close, pull, Results bullet, board). `HANDLED ...`
means done; `ESCALATE <reason>` means do the steps below by hand. After a `MERGED` it
also starts `console-kit/station-sync.sh --pr <n>` detached (HIMMEL-5945): the
`himmel-update.sh --only` steps for the paths the PR touched, then `--versions`. The line
ends `station=pending log=<file>` at once; the tick carries the verdict as `station=`
(`BEHIND:pending` while it runs, `BEHIND:<components>` when behind, nothing when current)
until the next sync. A station-local edit against the shipped version is printed in the
log as `LOCAL-DIFF <component> <file>` and the template apply is refused for it:
upstream the edit or drop it, never discard it silently. You can run
`wrap-merged.sh --doc <console doc> --fleet <manifest> <leg doc> [--pr <n>]`
directly when you already hold the leg doc. The hand sequence below is the
fallback, not the default: a measured console spent 7 to 9 full-context turns
per MERGED/WRAPPED on it (HIMMEL-5592).

For a batch close, run `bash scripts/handover/console-kit/close-wrapped-leg.sh --sweep --fleet <manifest>`: it closes only WRAPPED, lock-free workers, skips held or live workers, and continues after an already-pruned worktree.
To close every finished window across chiefs, run
`bash scripts/handover/console-kit/close-wrapped-legs.sh [--check] [<manifest>...]`.
It runs that sweep once per manifest and goes on after a failed one. With no
manifest it sweeps every `*.fleet.json` in the bucket changed in the last 24 h
(`CLOSE_WRAPPED_LEGS_MAX_AGE_MIN`), predecessor chiefs' manifests included.
It ends with `sweeps: manifests=<n> failed=<n> gone=<n>`, where `gone` counts
WRAPPED workers with no live session left to close.

### One-line forms for operator commands

When the operator has to run a command for you, hand them one literal line,
never a chain or a `VAR=` prefix:

| Instead of | Hand the operator |
|---|---|
| closing wrapped windows one by one | `! bash scripts/handover/console-kit/close-wrapped-legs.sh` |
| `HANDOVER_DIR=… JIRA_PROJECT_KEY=… node …/dist/index.js <op> …` | `! node <primary>/scripts/jira/dist/index.js <op> …`, run from any himmel checkout: the CLI resolves both keys itself from the primary checkout's config (its `.env` today) |
| `for id in …; do gh run cancel $id; done` | `! bash scripts/handover/console-kit/cancel-runs.sh --keep-pr <n> --live` (or `--all --live`; a dry run without `--live`) |
| `cd <worktree> && bash scripts/<x>.sh …` | `! bash <worktree>/scripts/<x>.sh …` (the script finds its own checkout) |
| a scratchpad prune script for merged worktrees | `! bash scripts/clean.sh` |

A chain that skips a gate, such as a vault commit with `SKIP=gitleaks`, gets no
wrapper: hand the operator the steps and the reason the gate refused.

On `WRAPPED`: confirm the lock is free at the ROOT sweep, then close the
leg's window with `bash scripts/handover/console-kit/close-wrapped-leg.sh
<leg-doc>` — it verifies the lock is free and the doc's last
Results marker is `WRAPPED`, signals the exactly-one live session that
matches the leg (never a guess), and prunes ITS worktree once the PR is
merged, all with no operator `!` step. Never run the
bare `clean.sh` sweep for one leg — it is fleet-wide and removes every merged
worktree, including another leg's that has merged but not yet wrapped (a live
`claude` process's cwd is the primary checkout, so nothing marks that
worktree as in use). `--only` exits non-zero when the target is not a prune
candidate. A worktree reported "in use" immediately after a wrap is the leg's
own end-of-session hook still writing — re-run `--only` on it shortly.

After the signal the close also digests the leg's session into the
failure-loop ledgers (`console-kit/leg-digest-step.sh`) and
prints exactly one line about it. The line is informational: it never changes
the close's exit code or any other output line, and it never delays the close
past its hard timeout (`CLOSE_WRAPPED_LEG_DIGEST_TIMEOUT`, default 120 s).

| `digest=` line | Meaning |
|---|---|
| `digest=ok fails=<n> classes=<k> traj=rbg:<0\|1\|->,dr:<x\|->,idr:<n\|->,vbc:<0\|1\|->` | rows written (or already present: a re-run writes none) |
| `digest=partial …` | same, but the session never settled; the row says `partial` |
| `digest=failed:<timeout\|crash\|no-journal\|bad-json>` | an `inconclusive` row with `meta.digest_error` was written |
| `digest=failed:inconclusive` | the digest itself said inconclusive (e.g. too big) |
| `digest=failed:ledger` / `digest=failed:step` | the ledger writer, or the step itself, did not complete; nothing to act on |
| `digest=skipped:no-session` | no session id could be read; nothing written |

A leg closed without the script (or a failed digest you want retried) is
digested afterwards with `bash scripts/handover/console-kit/leg-digest-step.sh
--doc <leg-doc>` (spec §1.2 fallback): it finds the leg's sessions by name,
`resume_cwd` and the doc's LIVE..WRAPPED window and prints one
`<session> digest=…` line per session, or `digest=skipped:no-chain`. The
`traj=` fields are recorded only — `rbg` and `vbc` are unreliable,
never act on them.
