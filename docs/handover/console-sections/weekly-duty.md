# Chief section — the weekly standards duty

Read on demand from `console-template.md` `## Standing rules`. The review loop
collects findings; this duty is how it learns from them. Owner: the chief
(O4 (a), HIMMEL-6371 R5a). A separate dedicated weekly run is HIMMEL-6914 and
does not replace this.

- **When it is due:** the board's CR loop line reads `cadence <N>d (stale)`
  (newest `cr-tune/proposals-*.md` older than 8 days, or `cadence never (stale)`)
  or `restructure seen <N>d (stale)` (newest `restructure-class-*` ticket created
  or updated more than 8 days ago). Either flag is a skipped duty; a chief on a
  quiet board still runs it once a week.
- **Run the detector first, then the cadence**, from the primary checkout, each
  as one bare command:
  `bash scripts/cr/class-recurrence.sh --days 14` then
  `bash scripts/cr/standards-cadence.sh --since 7d`.
  `class-recurrence.sh` files or folds `restructure-class-*` tickets;
  `standards-cadence.sh` writes `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md`.
- **Record the result** as one `LIVE` bullet: the classes filed or folded and the
  proposals file path. A proposal is a request, never a change: a CodeRabbit or
  critic rule goes to the operator, every other target to a chief GO with an
  opus judge.
- **Re-read the board** afterwards: both cadence fields must read fresh. A field
  that stays stale after a clean run is a bug in the run, not a reason to repeat it.
