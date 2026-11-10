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
