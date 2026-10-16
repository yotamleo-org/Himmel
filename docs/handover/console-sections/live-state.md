# Console section — Live state entry format and optional fields

Read on demand from `console-template.md` `## Live state`. Moved verbatim from the template; the core keeps one sentence per rule.

> **Authority-bearing state — not a summary.** Per-leg RETASK nonces, lock
> release tokens, the held queue and the last GO live HERE, on disk, not only
> in this context window: `SessionStart:compact` re-injects
> exactly this section after an autocompact, and `<kit>/tick.sh` flags
> `livestate=DRIFT:<leg>[,…]` when it disagrees with the leg locks actually
> held (and `livestate=MALFORMED:<leg>[,…]` for a malformed entry, below). Update this section on every dispatch, ruling, wrap and GO — not only
> at handover; `console.sh next` copies it verbatim into the successor's
> HANDOFF, so a stale line here is a stale line there too. A leg's nonce is
> updated **only after** that leg's quote-back (of the fresh nonce, when one
> was issued): until then the line still names the predecessor's. A relay may hand out no fresh token,
> so a leg can stay on the predecessor's nonce for good and be fully
> authenticated; the tick tells that apart from a leg that never accepted
> (`nonces=RELAYED:<leg>` needs the leg's own `SUCCESSION accepted` bullet,
> else `UNCONFIRMED:<leg>`).
>
> **Every nonce and lock token is a single backtick span, one per leg, with no
> trailing punctuation inside or directly after the span** — bare
> token-shaped text stalls the vault's gitleaks pre-commit scanners. Format:
> `` `<leg>:<nonce>:<lock-token>:<pid>` ``. Anything comparing these values
> strips backticks before comparing.
>
> **`<leg>` is the leg's label, `N<k>`** (`N191` for
> `HIMMEL-3269-N191-scorecard-discovery-…`) — the same label
> `tick.sh` prints in `legs=`. A label may contain letters, digits, `_`, `.`
> and `-`, so a full doc stem also parses.
>
> **Prose is permitted on the `legs:` line, and the tick reads it as prose**. Only a backtick span of exactly four non-empty colon-separated
> fields under a label is an entry. A span with whitespace, no colon, or a first
> field that is not a leg label (`` `legs:` ``, `` `procs:2` ``,
> `` `livestate=DRIFT:N192` ``, `` `N191` ``) is ignored, so a note may quote
> tick fields and name legs freely. **A span that looks like an entry but is not
> one** — a label (`N<k>` or a leg doc stem) with a colon and not four non-empty
> fields (`` `N191:<nonce>:<lock-token>` ``, a trailing or doubled colon) — is
> never dropped: the tick reads `livestate=MALFORMED:<label>[,…]` (by label
> only; the span carries a nonce and a lock token), and any real drift on the
> same line follows as `;DRIFT:<leg>[,…]`. Fix the span, or if it was meant as
> prose, drop the colon. A label that is neither `N<k>` nor a leg doc stem is
> treated as prose even when malformed, so a truncated entry under such a label
> reads as absent (`DRIFT`) rather than `MALFORMED`.
>
> **Write the `legs:` line by script, not by hand:** `action-zero.sh --render-legs`
> (or `live-state.sh <this doc>`) rebuilds it from the fleet manifest, with lock
> tokens read from the held locks and the nonces kept.
>
> **The `legs:` block may wrap**. The tick reads the whole block:
> every line that starts with `legs:`, plus the lines wrapped directly under it,
> up to the first blank line or the next `field:` line (`queue:`, `last GO:`,
> `acked:` — any line starting with a word and a colon) or the first list-marker
> line (`- `, `* `, `+ `, `1. `, or a line starting `>` or `#`). A span anywhere
> in that block is an entry, judged exactly as above. **A span past the block's
> end is not an entry** — a per-leg detail bullet may quote a span freely — so a
> held leg named only there reads `DRIFT`. Put every leg's span in the block;
> **the blank line before the per-leg detail is load-bearing**: a wrapped line
> never starts with a list marker, so a marker ends the block, but prose
> written straight under `legs:` without one is read as part of it.
> `board:` is the published console-board artifact URL (ACTION ZERO step 12);
> `console.sh next` carries it to your successor with the rest of this section.
> `tracker:` is the roadmap-tracker artifact URL; `none` (the
> default) turns the tick's `tracker=` field off (`skip`), and `console.sh next`
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
