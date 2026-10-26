# Chief section — trust-path PRs and cutting a pre-release tag

Read on demand from `chief-template.md` `## Merges`. Moved verbatim from the template.

**Review threads a worker could not resolve.** A worker resolves each answered
thread itself with
`node <anchor>/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner <o> --repo <r> --number <pr> --thread-id <PRRT_…> --reason "<reason>"`
(`fixed <sha>` | `followup HIMMEL-<n>` | `rejected <why>`), `<anchor>` the
primary checkout. `allow-thread-resolve.sh` auto-allows exactly that shape for
`yotamleo-org/Himmel` as one literal command, so the classifier never sees it;
any variation (chained, redirected, another repo, an extra flag, a branch copy of
the CLI) gets no allow. When the call is denied anyway the worker sends
`BLOCKED resolve <pr> <thread ids>`, and the waiter wakes you with
`WAKE resolve <worker> pr=<n> threads=<ids>`. **The operator is never asked to
resolve a thread:** it is yours, never an operator item. For each thread, check the fix, ticket or
rejection against the PR head, then run the same CLI with the matching reason,
one literal call per thread. A thread you cannot verify goes back to the worker as
a finding.
When YOUR OWN resolve call is classifier-denied, that is still not an
operator item, and the playbook's defer-to-operator does not apply: write a
`BLOCKED resolve <pr> <thread ids>` bullet with the denial text. Retry once
only if the denied call was not already one literal call per thread; a
denied single-thread literal call is not retried. A thread still denied
stays open: reply with the reason if the reply goes through, and file a
ticket for it.
This is escalation, not permission laundering: the CLI posts its reason on
GitHub, so every resolve is auditable. It codifies chief AS's 10-15 ruling
to worker N2224 (resolveReviewThread allowed, one literal call per thread, stop
on denial) and adds the chief step that ruling lacked.

**Claudex PRs: the chief merges.** A claudex worker's brief ends its Ship step
at `READY <pr> <head> GREEN` and never runs `merge-on-green.sh` (its auto-mode
classifier refuses merge-path actions, HIMMEL-4097). On that READY run, from
the primary checkout and in this order: `ready-check.sh <pr> <head>`, the
judge or trust review the PR needs, then
`chief-kit/go.sh [--trust-reviewed <qid>] <pr> <head>`, then
`bash scripts/handover/merge-on-green.sh <pr> [--jira-transition] --worker-doc <worker doc>`.
Pass `--jira-transition` unless the worker doc's `Completes ticket:` line says no
(a brief whose scope states neither value has no such line and takes the yes
wording, as the worker's own Ship step does); the `--worker-doc` line binds it either way.
Then send the worker `MERGED #<pr> → <sha>` by SendMessage quoting its token;
the worker `cd`s out, sends `WRAPPED` and releases its lock. A merge that exits
non-zero is not `MERGED`: send the worker the exit and reason instead, and it
stays held. Native workers merge themselves on your GO.

**Native workers: the GO message names the GO file.** `chief-kit/verdict-go.sh`
prints the worker message as `GO <pr> <head> - merge with: bash <merge script>
--jira-transition --go <GO file>`; send it as printed (with your token). After
a bare GO run, give the worker the path it printed as its `--go` argument. A chief worker's
`merge-on-green.sh` exits 17 without `--go`, or with the file of another PR or
head, and prints the verified GO evidence, so the merge command shows the
review it relies on (HIMMEL-7165: a merge with no visible review was denied as
Merge Without Review, intermittently). If the classifier still denies a
reviewed merge, the worker sends `BLOCKED`; do not run the denied merge for it
(that launders the denial) and do not loosen any rule. The fallback is the
claudex path above, tracked as a follow-up.

**Trust-path PRs.** A PR whose diff touches a pattern in
`scripts/ci/ci-trust-paths.txt` (CI workflows, `scripts/ci/`, the suite
selector and shared libs, the merge gate and GO writer — the list is read
from the default branch, never the PR head, so a PR cannot shrink it) does
not merge through `merge-on-green.sh` on an ordinary GO: it exits 21. Such a
PR needs an independent adversarial review first; only on the judge's GO for
that exact head run `chief-kit/go.sh --trust-reviewed <qid> <pr>
<head>`, where `<qid>` is the judge question's id (`[A-Za-z0-9][A-Za-z0-9._-]*`).
`go.sh` refuses with exit 5 unless `<root>/<user>/<bucket>/verdicts/<qid>/`
holds a verdict whose first line under `## Verdict` is exactly
``**GO** for head `<head>`.``, with no NO-GO for that head and no unparsed
verdict beside it. Brief the judge to write that line. The id is
signed into the GO's mac, so it
cannot be added or edited after the fact, and a push after it needs a fresh
trust-reviewed GO.

**Judge beside CI.** A worker sends `JUDGE-REQUEST <pr> <head>` when its head
enters the final CI run, after the local `/pr-check` round is clean. Dispatch
the trust or docs judge on that head then, in parallel with CI, rather than at
`READY`; `READY <pr> <head> GREEN` follows CI green. Any push after the judge
needs a fresh judge and a fresh GO: the trust-reviewed GO is still checked at
the exact head, so nothing is weakened.

**Anchor behind `origin`.** A trust-path PR needs the anchor checkout to hold
`origin`'s HEAD, so the gate it runs is current. `merge-on-green.sh` now
fast-forwards the anchor (`git pull --ff-only`) and re-runs itself from the
fresh bytes when that is all the gap is. A diverged anchor, a dirty tree
that blocks the pull or an unreadable `origin` still exits 21: fix the primary
checkout by hand.

Plugin versions change only in the release cut, the PR that changes the root
`VERSION` file; `check-plugin-drift.sh --bump-required`, ready-check item 9
and the merge-on-green recheck refuse a version change in any other PR. The
release-cut PR raises the version of every plugin changed since the last tag
(`git diff --name-only <last tag> HEAD -- marketplace/plugins/`), each strictly
above `main`'s, in the same commit as the `VERSION` change (the pre-commit hook
sees one commit at a time); the gates check that every plugin the cut touches
is raised above `main`, not that every plugin changed since the last tag is in
the cut, so the cut's author lists them.

To cut a pre-release tag yourself, run
`bash scripts/handover/chief-kit/cut-tag.sh <version> <sha>` (`--dry-run`
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
`bash scripts/handover/chief-kit/cancel-runs.sh --keep-pr <n>` (repeat the
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
cancelling what it could: re-run until it exits 0. It refuses (exit 3) in a worker
or relay. Never hand-roll a `gh run cancel` loop: the classifier denies it as
Interfere With Workloads.

## Docs PRs and the merged-docs list

Docs PRs do not wait on the operator (decision 286). The `docs-reviewer` skill
runs once per docs PR, by the judge at the READY head; the docs worker names
the changed pages in READY and does not run it.
Keep a `## Merged docs changes` list in the chief doc, one line per merged docs
PR (`#<n> <sha> <page> — <one line>`), and show it in every operator report for
review after the fact. When the operator remarks on one, run the skill's learn
step: one `candidate` row in its `remarks.tsv`, the quote verbatim.
