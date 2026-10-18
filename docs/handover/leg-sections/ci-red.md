# Leg preface section — CI red, merge-forward, suite coverage

Read on demand: `leg-preface.md` names this file when a required CI job goes red or a PR claims CI coverage. Moved verbatim from the preface.

## CI red and merge-forward

- **A red CI job on your PR is yours to triage — and you never
  tell the console about it, unless it is not the PR's fault.** The moment ONE
  required job fails, do not wait for the run to end and do not report the red.
  `scripts/check-ci.sh` prints each failed Actions job's log command; if it did
  not, take the job id from `gh pr checks` and pull the log yourself:
  `gh api --allow-escape-sequences repos/<o>/<r>/actions/jobs/<job-id>/logs > <scratch>`
  (`gh run view --log-failed` refuses until the whole run ends). Then decide
  BEFORE touching code whether the PR caused it, from data that already exists
  (never re-run the failing job or main's): the failed job's log, your own diff
  (does it touch or reference the failing case, or change a dependency
  manifest or lockfile?), main's latest completed run of the same job
  (`gh run list -b main -w <workflow> -L 1`, then that run's job log), and the
  same job in other open PRs' check-runs. If the PR caused it, or you cannot
  show otherwise, fix it at once; escalate only if the fix is outside your brief.
  If the evidence shows a GENERAL red (an advisory, an outage, a runner or
  registry failure, the same case failing on main or on unrelated PRs), do NOT
  fix it in your PR and do not loop on it. Send the console one
  `MAIN-RED <job> <failing case>` with that evidence, then carry on with
  whatever does not depend on it; the console has it fixed once, and after that
  merges you merge forward per the merge-forward rule below (never rebase, never force-push). If you suspect it is general but the data
  does not settle it, report `MAIN-RED? <job> <case> inconclusive` with what you
  saw.
- **Merge-forward.** A leg never merges,
  or merges forward past, a red its own change introduced. Merge-forward cures
  ONLY a red inherited from a broken base — one already red when you were cut
  and green on main now. Anything you cannot prove inherited is yours to fix
  (the "A red CI job on your PR is yours to triage" default above). Prove it
  with three job files, each `<job><TAB><conclusion>` (from
  `gh run view <id> --json jobs`): `--pr` your PR's run; `--main-base` main's
  CI run (cron or dispatch; main no longer runs per merge) AT YOUR
  MERGE-BASE (`git merge-base origin/main HEAD`, then
  `gh run list --commit <sha>`; no run there, the usual case, means an EMPTY
  regular file plus the cover trio below); `--main-latest` main's latest
  completed CI run, which is usually behind the tip. Two
  more files list the FAILING CASES, one `<job><TAB><case>` per line, read from
  the failed-job logs: `--pr-cases` (your PR run) and `--base-cases` (the base
  run). Your PR's shards run only the impacted suites while main's run the full
  sweep, so a matching job name proves nothing: EVERY failing case of your PR's
  job must appear among the base run's failing cases, and any extra failing case
  is your own red. Run
  `bash scripts/handover/merge-forward-check.sh --pr <f> --main-base <f> --main-latest <f> --pr-cases <f> --base-cases <f> --base-sha <merge-base> --main-base-sha <the base run's headSha> --latest-sha <the latest run's headSha> --pr-sha <the PR run's headSha, must be your HEAD> --main-base-conclusion <c>`
  (every flag is required; `<c>` is that run's `gh run view <id> --json conclusion`
  value, or `none` when no run exists at the merge-base, in which case pass the
  merge-base itself as `--main-base-sha`, with `--main-base` the empty file;
  the job files carry no sha, so the script refuses a
  base run that is not your merge-base and a latest run that is not on
  origin/main, or that predates the base verdict run (the covering run, else the
  merge-base), after its own fetch). Exit 0
  `ALLOW` (every red job was red at the base with the same failing cases AND is
  green on latest) lets you,
  once, `git merge <the tip sha the ALLOW line prints>` (not `origin/main`, which
  may have moved since the check) — a merge commit;
  never rebase, never force-push — citing both main run ids in a Results
  bullet (plus the local reproduction command and log path when the ALLOW line
  names `--base-cases-local`, below). Exit 1 `REFUSE` (a job green or absent at the base, or a failing case
  the base did not fail, is your own red; a job red or absent on latest main,
  or a latest run that is off origin/main or older than the base verdict, is unproven) = do NOT merge forward; fix it, or
  report `BLOCKED` / `MAIN-RED` per the rule above. If your merge-base has no
  completed main run — none at that commit (the usual case), or its run was
  cancelled (conclusion `cancelled`, whatever finished rows it kept: its aggregator
  row reads red only because the shards were cancelled, so the script takes the
  conclusion, never the rows, as the verdict) —
  a bare check REFUSEs; add the all-or-none group
  `--base-cover <f> --base-cover-sha <sha> --base-cover-from <sha> --base-cover-conclusion <c>`. The cover is
  the next COMPLETED main run (cron or dispatch) on origin/main whose range
  (from, cover] contains your merge-base (`gh run list -w CI -b main`):
  `--base-cover` its job file, `--base-cover-sha` its headSha, `--base-cover-conclusion`
  its conclusion (a cancelled cover REFUSEs), `--base-cover-from`
  the previous completed run's headSha (a strict ancestor of the merge-base). No
  such run yet means wait for the next cron or dispatch run, never merge forward.
  `--base-cases` are then
  the cover's failing cases, and every file arg must be a regular file. Polarity
  is unchanged: the job red on the cover with the same failing cases AND green on
  latest = `ALLOW`; green on the cover = `REFUSE`. Two accepted ceilings: the
  script takes "next" and "latest" from you and cannot see another completed run
  inside (from, cover] or newer than the latest you pass, and a red cover proves the failure existed somewhere in that
  range, not at the merge-base itself (green on latest bounds it). When the
  covering run already holds the fix (the red reads green there), the check
  REFUSEs; reproduce the PR's failing case at the merge-base in a scratch
  worktree and pass `--base-cases-local <f>`: a file with the headers
  `# merge-base <40-hex sha>` (must equal `--base-sha`), `# command <the
  reproduction command>` and `# log <path of the local log>` (the log must
  exist and be non-empty), then one `<job><TAB><case><TAB><exit status>` row per
  case that failed there (a zero status is no reproduction). Every failing case
  of the PR's job must be listed, the job must be green on latest, and a
  completed run at the merge-base itself is never overridden; any missing or
  mismatched header exits 2. Cite the command and log path in your Results
  bullet beside both main run ids: the file is self-reported and the console
  reviews that log before it grants the merge-forward. Exit 3 = nothing red. Once
  per PR: a second merge-forward goes to the console. After it, `/pr-check` and
  CI run again at the new head.
- **Never write "CI verifies" for a suite you have not looked up.** `bash scripts/handover/suite-coverage.sh <suite>...` reads
  `scripts/ci/run-shell-tests.sh` itself and says per suite: runs in PR CI /
  nightly only / not run in CI (SKIP_LIST) / superseded by its wrappers. A
  SKIP_LIST suite is **uncovered** — name it that, and say what you ran by hand
  instead. Run it for every suite your PR claims CI covers.
- **A timing-sensitive suite gets a loaded budget, not an idle one.** A suite that times out only under fleet load is a budget
  defect: measure it alone and as concurrent runs, set the budget to the
  loaded figure x2 (the `run-shell-tests.sh` rule), and record the numbers in
  a Results bullet. Never retry it until it passes.
- **After the review-round cap, only a priority finding earns a commit.** A Critical, Important or priority-pool finding is
  fixed and run through the delta round. Anything else is deferred to a ticket
  with no commit and no round. A change that does land after the cap is cleared
  by a signed judge GO at the exact head (`review-round.sh judge-go`,
  HIMMEL-6303): ask the console for it in a `FINDING`, never for a new full round.
