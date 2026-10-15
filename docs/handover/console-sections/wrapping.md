# Console section — wrapping a leg by hand, and the digest line

Read on demand from `console-template.md` `## Wrapping a leg`. Moved verbatim from the template.

## Wrapping a leg

**Default path: one call per leg message.** Write the leg's `MERGED` or
`WRAPPED` message to a file and run
`bash scripts/handover/console-kit/leg-event.sh --doc <console doc> --fleet <manifest> <message-file>`.
It finds the leg doc by the message's `N<k>` label and runs
`console-kit/wrap-merged.sh` (PR state, close, pull, Results bullet, board). `HANDLED ...`
means done; `ESCALATE <reason>` means do the steps below by hand. You can run
`wrap-merged.sh --doc <console doc> --fleet <manifest> <leg doc> [--pr <n>]`
directly when you already hold the leg doc. The hand sequence below is the
fallback, not the default: a measured console spent 7 to 9 full-context turns
per MERGED/WRAPPED on it (HIMMEL-5592).

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
