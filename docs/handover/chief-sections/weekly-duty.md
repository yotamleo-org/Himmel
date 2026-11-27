# Chief section — the weekly standards duty

Read on demand from `chief-template.md` `## Standing rules`. The review loop
collects findings; this duty is how it learns from them. Owner: the chief
(O4 (a)). A separate dedicated weekly run is still to be built and
does not replace this.

- **When it is due:** the board's CR loop line reads `cadence <N>d (stale)`
  (newest `cr-tune/proposals-*.md` older than 8 days, or `cadence never (stale)`)
  or `restructure seen <N>d (stale)` (newest `restructure-class-*` ticket created
  or updated more than 8 days ago). A stale `cadence` is a skipped duty; a stale
  `restructure seen` beside a fresh `cadence` only means the last detector run had
  nothing to file. A chief on a quiet board still runs the duty once a week.
- **Run the detector first, then the cadence, then the conflicts line**, from the
  primary checkout, each as one bare command:
  `bash scripts/cr/class-recurrence.sh --days 14` then
  `bash scripts/cr/standards-cadence.sh --since 7d` then
  `python3 -I scripts/eval/conflicts/conflicts.py week --days 7`.
  `class-recurrence.sh` files or folds `restructure-class-*` tickets;
  `standards-cadence.sh` writes `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md`;
  `conflicts.py week` prints two lines (the count line and `harm:`), computed from
  the conflicts ledger, git and gh, never typed by hand.
- **Record the result** as one `LIVE` bullet: the classes filed or folded, the
  proposals file path, and the two conflicts lines verbatim. At the second weekly
  conflicts line after S4 (the merge-on-green writer) merged, run the design's
  14-day review (the no-file-holds design's Revisit rule, in the state repo bucket
  under `specs/designs/`).
  A proposal is a request, never a change: a CodeRabbit or
  critic rule goes to the operator, every other target to a chief GO with an
  opus judge.
- **Re-read the board** afterwards: `cadence` must read fresh, since the cadence
  run always writes a proposals file. `restructure seen` only moves when the
  detector filed or commented on a ticket, so it stays stale after a clean run
  that found no recurring class; that is not a failure. A stale `cadence` after a
  clean run is a bug in the run, not a reason to repeat it.

## Daily drift duty

Every tick counts the rows of the open nightly drift issue (its body is re-read at most once an hour; no open issue reads 0) and prints `drift=<n>` on the TICK
line: its Needs-update rows plus the held rows whose 72 hour buffer has cleared (`?` when the
read failed, never a wake). The first tick of each UTC day that sees a positive count prints one
`WAKE drift-actionable <n>`: once per station per UTC day, shared by every chief of the bucket
(the claim is one file under the tick state dir, not a file beside your inbox), so a chief handover
does not wake it again. While a drift worker of the day is in the fleet manifest or a drift PR of the day is open, the
wake is held and `<inbox>.wait.drift.held` says `held-by <label|PR>`.
On that wake, if an undispatched drift brief of the day already exists in the bucket, reuse it; do not write a second; unless a drift or combined leg is already out, whatever its date: then dispatch nothing; its WRAPPED leaves the rest for the next wake. Otherwise, from the primary checkout, write the worker brief for exactly those rows with
`python3 -I scripts/handover/chief-kit/drift-brief.py brief --body-file <issue body> --holds scripts/upstreams/pin-holds.json --out <bucket> --worktree <new worktree> --chief <you> --worker <label> --date <today>`
(the issue body is `gh issue list --label fork-drift --state open --limit 1 --json body --jq '.[0].body'` run in the primary checkout), run
`bash scripts/handover/chief-kit/brief-lint.sh` on it, and dispatch it as one small worker.
No row, no wake, no brief.

**Dependabot PRs (decision 1243).** `WAKE dependabot <prs> oldest=<age>` names every open
Dependabot PR. In that turn, dispatch ONE combined bump leg written with
`drift-brief.py brief --dependabot-prs <prs> --prs-file <file>`, where the file is
`gh pr list --state open --limit 200 --json number,title,headRefName,body,files`, run in the primary checkout.
The leg lands every named PR and the drift issue's actionable rows in one bump PR. A CI image
digest repin PR follows when a bump touches `.github/ci-image/`. Station-tool rows are listed apart
and go to a VM first. The leg supersedes and closes every PR it was given. A PR the brief
reports as touching a core path stays open and goes the core-path route: an emergency Bug if it
closes an advisory, else a ticket that owes a spec. A drift or combined leg is out,
whatever its date, until its WRAPPED, repin PR included. While one is out, dispatch no second leg. On its
WRAPPED, dispatch one combined leg only for the Dependabot PRs the tick line shows that its brief
did not name: not those in its Dependabot PRs block, and not those in its core-path line. Until the
nightly drift scan has run again, write that leg with an empty issue body (`--body-file /dev/null`),
so it takes the new PRs and none of the rows the out leg already landed.
