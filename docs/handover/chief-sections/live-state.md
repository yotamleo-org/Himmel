# Chief section — Live state entry format and optional fields

Read on demand from `chief-template.md` `## Live state`. Moved verbatim from the template, whose two-line preamble points here.

> **Authority-bearing state — not a summary.** Per-worker RETASK nonces, lock
> release tokens, the held queue and the last GO live HERE, on disk, not only
> in this context window: `SessionStart:compact` re-injects
> exactly this section after an autocompact, and `<kit>/tick.sh` flags
> `livestate=DRIFT:<worker>[,…]` when it disagrees with the worker locks actually
> held (and `livestate=MALFORMED:<worker>[,…]` for a malformed entry, below). Update this section on every dispatch, ruling, wrap and GO — not only
> at handover; `chief.sh next` seeds its `legs:` block, `queue:`, `last GO:` and
> `acked:` into the successor's own Live state (the HANDOFF holds only
> the pointer `Live state: seeded into <successor doc>`, never a nonce), so a
> stale line here is a stale line there too, and the successor's
> `action-zero.sh --render-workers` keeps the seeded nonces. **Only the open workers
> and the last GO are seeded:** a `legs:` span whose label is no longer in the fleet
> manifest (`fleet-manifest.sh remove` at the wrap), the shift prose on that line
> and the `prior …` chain after the first GO stay behind. `next` appends them
> byte for byte, under a dated header, to `specs/history/chief-live-state-<your doc stem>.md`
> in the successor's bucket (earlier content in that file stays) and the HANDOFF names
> it; with no readable manifest the block is seeded whole. A malformed span of an open
> worker is kept, so the tick reads MALFORMED. A `pool-disposition:` line inside the block is kept. Keep your own Live
> state that lean: the tick prints `ACTION livestate-over-budget=<bytes>/<limit>`
> past `LIVESTATE_BUDGET_BYTES` (default 12000). A per-worker detail line
> past the `legs:` block is not seeded: put what the successor needs in the
> HANDOFF's judgement notes. A worker's nonce is
> updated **only after** that worker's quote-back (of the fresh nonce, when one
> was issued): until then the line still names the predecessor's. A relay may hand out no fresh token,
> so a worker can stay on the predecessor's nonce for good and be fully
> authenticated; the tick tells that apart from a worker that never accepted
> (`nonces=RELAYED:<worker>` needs the worker's own `SUCCESSION accepted` bullet,
> else `UNCONFIRMED:<worker>`).
>
> **Every nonce and lock token is a single backtick span, one per worker, with no
> trailing punctuation inside or directly after the span** — bare
> token-shaped text stalls the vault's gitleaks pre-commit scanners. Format:
> `` `<worker>:<nonce>:<lock-token>:<pid>` ``. Anything comparing these values
> strips backticks before comparing.
>
> **`<worker>` is the worker's label, `N<k>`** (`N191` for
> `HIMMEL-3269-N191-scorecard-discovery-…`) — the same label
> `tick.sh` prints in `workers=`. A label may contain letters, digits, `_`, `.`
> and `-`, so a full doc stem also parses.
>
> **Prose is permitted on the `legs:` line, and the tick reads it as prose**. Only a backtick span of exactly four non-empty colon-separated
> fields under a label is an entry. A span with whitespace, no colon, or a first
> field that is not a worker label (`` `legs:` ``, `` `procs:2` ``,
> `` `livestate=DRIFT:N192` ``, `` `N191` ``) is ignored, so a note may quote
> tick fields and name workers freely. **A span that looks like an entry but is not
> one** — a label (`N<k>` or a worker doc stem) with a colon and not four non-empty
> fields (`` `N191:<nonce>:<lock-token>` ``, a trailing or doubled colon) — is
> never dropped: the tick reads `livestate=MALFORMED:<label>[,…]` (by label
> only; the span carries a nonce and a lock token), and any real drift on the
> same line follows as `;DRIFT:<worker>[,…]`. Fix the span, or if it was meant as
> prose, drop the colon. A label that is neither `N<k>` nor a worker doc stem is
> treated as prose even when malformed, so a truncated entry under such a label
> reads as absent (`DRIFT`) rather than `MALFORMED`.
>
> **Write the `legs:` line by script, not by hand:** `action-zero.sh --render-workers`
> renders only before the chief takes its own lock (ACTION ZERO); a chief that
> already holds its lock re-renders with `live-state.sh <this doc>`. Either rebuilds
> it from the fleet manifest, with lock tokens read from the held locks and the
> nonces kept.
>
> **The `legs:` block may wrap**. The tick reads the whole block:
> every line that starts with `legs:`, plus the lines wrapped directly under it,
> up to the first blank line or the next `field:` line (`queue:`, `last GO:`,
> `acked:` — any line starting with a word and a colon) or the first list-marker
> line (`- `, `* `, `+ `, `1. `, or a line starting `>` or `#`). A span anywhere
> in that block is an entry, judged exactly as above. **A span past the block's
> end is not an entry** — a per-worker detail bullet may quote a span freely — so a
> held worker named only there reads `DRIFT`. Put every worker's span in the block;
> **the blank line before the per-worker detail is load-bearing**: a wrapped line
> never starts with a list marker, so a marker ends the block, but prose
> written straight under `legs:` without one is read as part of it.
> `board:` is the published chief board artifact URL (ACTION ZERO step 12);
> `chief.sh next` carries it to your successor with the rest of this section.
> `tracker:` is the roadmap-tracker artifact URL; `none` (the
> default) turns the tick's `tracker=` field off (`skip`), and `chief.sh next`
> carries the URL too. An optional `tracker-plan: <dir>` line overrides the plan
> directory (default `<handover bucket>/specs/plan/HIMMEL-3882`).
> `epics: <KEY>=<total>[, <KEY>=<total>]` (the total is yours; the board counts
> merged PRs citing `[<KEY>]`) and `decisions: <first?>; <second?>` (open
> operator decisions) are optional and render on the board; `none` shows none.
> `versions: <v>[, <v>]` (e.g. `v1.0.0, v1.0.1`; omit the line for none) adds one
> `Release <v>` panel per Jira fixVersion: done/total (Done, Closed and Resolved
> count as done) plus the open tickets labelled `v1-blocker`. It costs one Jira CLI
> call per version per render; a failing or missing CLI reads `unavailable` and the
> render still succeeds. The counts fold into `board.mjs --changed`, not into the
> tick's `board=` (tick.sh never sees Jira).
> `release: <R>` (a declared release, `chief-sections/release-manager.md`) adds
> a `Release manager <R>` panel from one `jira release state <R> --json` call: M4
> burn-down per version, the leaks and the M1 trend for the last 7 days; a failing
> CLI reads `unavailable`. `rm: <session> <doc> epoch=<n>` names the live RM.
> `focus-version: <v>|auto|none` picks the FOCUS tracker page's version
> (`chief-sections/board-tracker.md`): `auto`, or no line beside `release: <R>`,
> follows R's current version.
> `chief.sh next` copies `epics:`, `decisions:`, `priority:`, `versions:`,
> `tracker-plan:`, `release:`, `rm:`, `focus-version:` and `focus-plan:` verbatim into the successor's own Live state. It refuses to
> hand over when your `decisions:` or `priority:` line is missing or a
> placeholder while your predecessor's was real (`decisions:` also when shorter),
> unless a Results bullet carries `DECISIONS-DROP: <reason>` or
> `PRIORITY-DROP: <reason>` (or `PRIORITY-PRUNE: <keys>`).
> **Prune closed keys** (tick prints `pool-closed=<closed>/<total>` when the Jira mirror
> reads any key on your `priority:` line closed): `bash scripts/handover/chief-kit/priority-prune.sh --doc <your doc>`
> prints the line without them, the rest in order; with an operator OK run it with
> `--apply` and log `PRIORITY-PRUNE: <the dropped keys it names>` in Results.
> **Bound `decisions:`** (tick prints `ACTION decisions-over-budget=<bytes>/<limit>`
> past `DECISIONS_BUDGET_BYTES`, default 4000, and `ACTION handoff-over-budget` when
> your HANDOFF is past `HANDOFF_BUDGET_BYTES`, default 6000): copy each superseded
> `(N) …` ruling **verbatim**, number included, into
> `specs/decisions/chief-decisions-<date>.md` in the bucket, then keep only the
> active rulings plus that path on the line, e.g. `decisions:
> specs/decisions/chief-decisions-2026-10-20.md holds #1-#60; active: (61) …`.
> `next` accepts the shorter line only when it names at least one decisions file
> and every numbered entry of your predecessor's line, and of any decisions file
> that line names, is found verbatim in your line or the files it names; a missing
> file, a changed word or words appended to an entry read `DECISIONS-DROP`. Once your predecessor's line names
> a decisions file, `next` runs this check whatever your line's length. An entry
> runs from its `(N) ` to the next `(N) ` or the end of its line, so a heading in a
> decisions file is fine; text before the first `(N) ` is not checked, so number
> every ruling. Name every older decisions file on the line, or copy its entries
> into today's.
> The chief board's `Open operator decisions` panel reads the `(N) ` entries
> of every decisions file the line names, plus any written on the line itself.
>
> **One-time migration to the decisions file.** The first chief that hands
> over after `next` started seeding (HIMMEL-6498), if its `decisions:` line
> still carries the rulings inline:
>
> 1. Append each numbered ruling verbatim, number included, to the bucket's
>    `specs/decisions/chief-decisions-<date>.md`, one
>    `append-results.sh <that file> "(N) <ruling>"` per ruling (a new file
>    needs its `## Results` heading line first; the script refuses without one).
> 2. Set the line to `decisions: specs/decisions/chief-decisions-<date>.md
>    (latest #<n>)`, `<n>` the highest number, naming any older decisions file
>    too.
> 3. Run `chief.sh next` as usual: the check above finds every predecessor
>    entry in the file and passes the shorter line with no `DECISIONS-DROP`.
