# Chief section — the scope helper (no-scope tickets, batched)

Read on demand when the chief clears a no-scope batch. A To Do ticket that names no file it writes prints
`NEEDS-CHIEF-NOTE <KEY>: no readable scope` and is not listed. This section clears a batch of them with
one helper and one approving call instead of one chief note per ticket. It does not touch tickets that
are also partial-merge rows (`NEEDS-CHIEF-NOTE … merged PR`): those stay hand work.

## The flow

1. **Batch.** The dispatcher's scope-batch output (a separate slice of the same ticket; until it has merged,
   make the file by hand) writes the best-ranked no-scope tickets (25 by default) to `<FILE>`, one JSON
   object per line: `batch` (`<UTC yyyymmddThhmm>-<first key>`, the same on every row), `key`, `rank`,
   `title`, `excerpt`. Put `<FILE>` in your scratch or bucket, never in the repo.
2. **Helper.** Spawn one Agent per batch, `model: sonnet`, medium effort, with this section as its brief and
   `<FILE>` as its input. It adds five fields to each row and writes nothing else (below).
3. **Review.** Every row defaults to `"approve": "yes"`. Edit a row's `writes`, set its `approve` to anything
   else, or delete the line. That edit and the next call are your review: an approved row is posted.
4. **Dry run.** `bash <kit>/scope-approve.sh --dry-run --chief <session> <FILE>` prints each comment it would
   post and posts, records and refreshes nothing.
5. **Approve.** `bash <kit>/scope-approve.sh --chief <session> <FILE>` posts one Jira comment per passing
   row (`readiness: scope-batch <id> approved by <session>`, then one `Writes: <path>` line per file),
   refreshes the mirror once, and asks `next-dispatchable.sh` again.
6. **After an `UNKNOWN`.** Jira's search lags a fresh comment. Wait, then run
   `bash <kit>/scope-approve.sh --verify --chief <session> <FILE>`: it re-checks only the keys already
   posted (the sidecar `<FILE>.posted`) and never posts again.

`<kit>` is `scripts/handover/chief-kit` of the primary checkout. Usage line, as the script prints it:
`scope-approve.sh [--dry-run | --verify] --chief <session> <batch-file>`.

## What the helper does, per row

- Read the ticket's mirror file (`<mirror>/<KEY>.md`: description and comments).
- Run `bash scripts/graphify/worker-graph.sh explain "<symbol>"` (or `path "<a>" "<b>"`) on each symbol,
  script or doc the ticket names.
- Run one bounded qmd query on the title: `bash scripts/lib/qmd-bounded.sh query -c himmel "<title>"`.
- Propose the files the ticket's next step edits and write these fields on the row, and no others:
  - `writes`: the repo-relative paths, as files, never directories; leave it `[]` when it is not sure.
  - `new`: the subset of `writes` that does not exist yet (its parent directory must exist).
  - `core`: `true` when a path is on `scripts/ci/core-paths.txt`, else `false`. This is advisory: the
    approve step asks the release CLI itself and never trusts it.
  - `why`: one line saying what in the ticket names these files.
  - `approve`: leave it at `"yes"`.

## Limits

- Files, never directories; never a no-write statement (`no code`), and never a path it did not see in
  the repo or in the ticket: an invented path is refused by the approve step and the row stays.
- A ticket whose change is core is the chief's by hand. The release CLI decides, not the helper:
  a Bug reads BYPASS only when a core path is proposed, and a ticket labelled `core` reads CORE with none.
- The helper runs no Jira call, no git write and no repo write; its only write is the batch file. That is a
  prose limit: the helper has Bash and could run the Jira CLI, so nothing here stops it. What the approve
  step does see: a ticket that gained scope before the call prints `SKIPPED <KEY> scoped (<source>)`, and a
  key is never `CLEARED` unless the mirror holds the approve step's own marker line.

## What each word means

One line per key, `<WORD> <KEY> <reason>`:

| Word | Meaning |
|---|---|
| `CLEARED` | `next-dispatchable.sh` now reads the batch's paths as the ticket's scope and no longer gates it on no-scope. Not "dispatchable": proof, a blocker or a core spec can still gate it. |
| `STAYS` | The comment arrived and ND still does not read it that way (another comment, or a merged PR that records no remainder). |
| `UNKNOWN` | The mirror has not caught up, a refresh failed, a post timed out, or ND could not judge. Run `--verify` later. |
| `SKIPPED` | Posted nothing: `empty`, `approve`, `posted` (this key was posted before, in any batch beside this file) or `scoped`. |
| `REFUSED` | Posted nothing: `shape`, `path`, `core` or `unknown`. |
| `FAILED` | Jira refused the post; no sidecar line, the next rows go on. |

The last line is `scope-approve: batch <id> cleared=<a> stays=<b> unknown=<c> skipped=<d> refused=<e>
failed=<f>`. Exit 0 only when every posted key is `CLEARED`; `STAYS`, `UNKNOWN` or `FAILED` exit 1.
A wrong line that was posted is undone by a newer `readiness:` comment on the ticket (the newest wins).
