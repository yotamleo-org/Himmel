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
This is escalation, not permission laundering: the CLI posts its reason on
GitHub, so every resolve is auditable. It codifies console AS's 10-15 ruling
to leg N2224 (resolveReviewThread allowed, one literal call per thread, stop
on denial) and adds the console step that ruling lacked.

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
