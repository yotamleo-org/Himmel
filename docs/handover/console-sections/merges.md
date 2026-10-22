# Console section — trust-path PRs and cutting a pre-release tag

Read on demand from `console-template.md` `## Merges`. Moved verbatim from the template.

**Review threads a leg could not resolve.** A leg resolves each answered
thread itself with
`node plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner <o> --repo <r> --number <pr> --thread-id <PRRT_…> --reason "<reason>"`
(`fixed <sha>` | `followup HIMMEL-<n>` | `rejected <why>`). When that call is
denied the leg sends `BLOCKED resolve <pr> <thread ids>`. That is yours, never
an operator item: for each thread, check the fix, ticket or rejection against
the PR head, then run the same CLI with the matching reason, one literal call
per thread. A thread you cannot verify goes back to the leg as a finding.
When YOUR OWN resolve call is classifier-denied, that is still not an
operator item, and the playbook's defer-to-operator does not apply: write a
`BLOCKED resolve <pr> <thread ids>` bullet with the denial text. Retry once
only if the denied call was not already one literal call per thread; a
denied single-thread literal call is not retried. A thread still denied
stays open: reply with the reason if the reply goes through, and file a
ticket for it.
This is escalation, not permission laundering: the CLI posts its reason on
GitHub, so every resolve is auditable. It codifies console AS's 10-15 ruling
to leg N2224 (resolveReviewThread allowed, one literal call per thread, stop
on denial) and adds the console step that ruling lacked.

**Claudex PRs: the console merges.** A claudex leg's brief ends its Ship step <!-- old-term-ok: console runbook wording -->
at `READY <pr> <head> GREEN` and never runs `merge-on-green.sh` (its auto-mode
classifier refuses merge-path actions, HIMMEL-4097). On that READY run, from
the primary checkout and in this order: `ready-check.sh <pr> <head>`, the
judge or trust review the PR needs, then
`console-kit/go.sh [--trust-reviewed <qid>] <pr> <head>`, then
`bash scripts/handover/merge-on-green.sh <pr> [--jira-transition] --leg-doc <leg doc>`. <!-- old-term-ok: console runbook wording -->
Pass `--jira-transition` unless the leg doc's `Completes ticket:` line says no <!-- old-term-ok: console runbook wording -->
(a brief whose scope states neither value has no such line and takes the yes
wording, as the leg's own Ship step does); the `--leg-doc` line binds it either way. <!-- old-term-ok: console runbook wording -->
Then send the leg `MERGED #<pr> → <sha>` by SendMessage quoting its token; <!-- old-term-ok: console runbook wording -->
the leg `cd`s out, sends `WRAPPED` and releases its lock. A merge that exits <!-- old-term-ok: console runbook wording -->
non-zero is not `MERGED`: send the leg the exit and reason instead, and it <!-- old-term-ok: console runbook wording -->
stays held. Native legs are unchanged: they merge themselves on your GO. <!-- old-term-ok: console runbook wording -->

**Trust-path PRs.** A PR whose diff touches a pattern in
`scripts/ci/ci-trust-paths.txt` (CI workflows, `scripts/ci/`, the suite
selector and shared libs, the merge gate and GO writer — the list is read
from the default branch, never the PR head, so a PR cannot shrink it) does
not merge through `merge-on-green.sh` on an ordinary GO: it exits 21. Such a
PR needs an independent adversarial review first; only on the judge's GO for
that exact head run `console-kit/go.sh --trust-reviewed <qid> <pr>
<head>`, where `<qid>` is the judge question's id (`[A-Za-z0-9][A-Za-z0-9._-]*`).
`go.sh` refuses with exit 5 unless `<root>/<user>/<bucket>/verdicts/<qid>/`
holds a verdict whose first line under `## Verdict` is exactly
``**GO** for head `<head>`.``, with no NO-GO for that head and no unparsed
verdict beside it. Brief the judge to write that line. The id is
signed into the GO's mac, so it
cannot be added or edited after the fact, and a push after it needs a fresh
trust-reviewed GO. A trust-path PR also refuses while the anchor checkout is
behind `origin` (pull the primary first), so the gate it runs is current.

To cut a pre-release tag yourself, run
`bash scripts/handover/console-kit/cut-tag.sh <version> <sha>` (`--dry-run`
first to see the plan) — it creates the tag through the GitHub API, never
`git tag`, so it needs no operator `!` step. It refuses unless `<sha>` is an
ancestor of `origin/main`, every check-run at `<sha>` is green, the commit's
`CI` workflow run exists and completed green (never a vacuous pass on a
Pages-only commit whose `CI` run hasn't started), the tag
doesn't already exist, and `<version>` is the next `N` in sequence for its
own `v<X>.<Y>.<Z>-pre.` series — the series is derived from `<version>`
itself, not hardcoded to any one release line, so `v0.3.0-pre.9` and a future
`v0.4.0-pre.1` are each checked against their own prior tags — (or carries
`--version-override <reason>`).

To drain the hosted CI queue on an operator order, run
`bash scripts/handover/console-kit/cancel-runs.sh --keep-pr <n>` (repeat the
flag, or add `--keep-sha <sha>`) — a dry run that prints the count; add `--live`
to cancel. It cancels every non-completed run on the `origin` repo (not
overridable: a `--repo` that differs from origin refuses, as does an origin on
any host but github.com) except those on the
kept heads, and prints `cancelled=<n> failed=<n> kept=<list>`. A keep is
required; `--all` is the explicit way to keep nothing. A keep that cannot be
resolved refuses before anything is cancelled. Runs on `main`, and any run not
from a `pull_request` or `pull_request_target` (push, tag, schedule,
workflow_dispatch), are protected
and reported as `protected=<n>`; only `--include-protected` cancels them. At
most `--max-cancels` (default 100, up to 500) runs are cancelled per call, and
each cancel writes one stderr line with run, branch, sha, event and rc.
Cancels are paced at 10 per minute and 30 per 10 minutes (failed attempts
count): past a limit the verb waits and says so on stderr (`pacing - waiting
<n>s`), so a drain of 100 runs takes about half an hour; a dry run never waits.
The cancel times persist in the git common dir (`cancel-runs-pace`), so a
re-run after a tool timeout keeps the limits (a state file that cannot be
written stops a live run, exit 2, before the cancel it could not record). Two
drains running at once do not see each other's cancels live, so run one drain
at a time. A
listing that fills `CANCEL_RUNS_LIMIT` (500), or the cancel cap, exits 1 after
cancelling what it could: re-run until it exits 0. It refuses (exit 3) in a leg
or relay. Never hand-roll a `gh run cancel` loop: the classifier denies it as
Interfere With Workloads.
