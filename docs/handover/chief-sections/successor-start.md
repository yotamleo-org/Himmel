# Chief section — after the successor LIVE: close the predecessor, re-ask judges

Read on demand from `chief-template.md` ACTION ZERO step 9. Moved verbatim from the template.
ACTION ZERO step 1 is one batched turn (`ListAgents`, `ToolSearch` for `SendMessage`,
the decisions `Read`, and a foreground `action-zero.sh --acquire --render-workers`);
the relays below follow in the very next turn.

   **Boot from the digest.** `chief.sh next` writes `<predecessor>-DIGEST.md` beside the
   predecessor's HANDOFF (budget `DIGEST_BUDGET_BYTES`, default 8000: head, usage, workers,
   open PRs, queue, last GO, judge subagents, chain order, and the wrapped-with-open-PR,
   owed, in-flight and orphan-gate parts; a capped list ends in `+N more`) and the preface
   of your doc names it. Read the digest and your own doc first, never the predecessor's
   doc. Then, before your first dispatch, read the HANDOFF's hand-filled sections
   (`## Rulings and judgement notes`, `## Wrapped this shift`, `## Open operator items`)
   and any HANDOFF section the digest marks `over the digest budget` or `+N more`.
   The predecessor sends exactly one relay at hand-over (the relay-on-live wake, or
   `relay-batch.sh` once); a worker it names as not relayed is the by-hand case below.

   **Wake-once succession (step 9).** A worker's quote-back is its own `SUCCESSION
   accepted` Results bullet (no token in it); it sends a `SendMessage` only on a
   timeout or a decline. Add `--succession <your session> [--silent-min T]` (T
   whole minutes, default 20) to the step-10 waiter line on its first arm. Send
   LIVE to the predecessor once it reports `RELAYED <n> of <m>`, so it can wrap;
   until a worker's bullet lands the tick reads `nonces=UNCONFIRMED:<worker>`. The
   tally is informational: on `WAKE succession complete <n/n>` write each worker's
   nonce into `## Live state` (the fresh one if issued, else the unchanged one)
   and run the printed bullet command; on `WAKE succession partial <k/n> silent
   <T> min` name the workers still out. Neither wake resends LIVE. Then
   `TaskStop` the waiter and re-arm it without `--succession`.
   n counts only the batch's own deliveries, so n below m names nobody: LIVE
   repeats the workers the predecessor's `RELAYED` message names as still unrelayed;
   the predecessor relays each by hand before it wraps. If it is already gone, send each the token-chain form yourself.
   Take the current token from `worker-token.sh current <doc>` and the fresh one from
   `worker-token.sh rotate <doc> --to <itself>` (your own session name); the only other
   source of a fresh token is `relay-batch.sh --fresh <label>`.
   **Then close the predecessor's window.** Once its doc's lock is
   free and its last Results bullet reads `WRAPPED`, run
   `bash scripts/handover/chief-kit/close-wrapped-worker.sh --chief <predecessor doc>`
   (same checks as a worker: it refuses while the lock is held, the tail is not
   `WRAPPED`, or not exactly one live session carries its name; exit 6 means
   retry shortly; exit 7 means it still has a live subagent, a judge subagent
   whose verdict would die with it: retry once it finishes).
   Left open, the wrapped session is idle-compacted at full cost.
   **Before you re-dispatch any judge the predecessor asked**, read the
   HANDOFF's open judge subagents and each qid's `verdicts/<qid>/` file: a written
   verdict is the answer; only a qid with no file and no running child is
   re-asked.

   **Restate the direction.** The successor's `LIVE` restates the first rulings of
   its own doc's `## Current direction` (the lines after the `Full original text` pointer
   line, never that line itself), so the outgoing chief can catch a misread
   before it wraps. `chief.sh next` carries that block verbatim into the successor doc
   when it is short; over `CHIEF_DIRECTION_SPILL_BYTES` (12000) it carries one reading line per ruling
   and writes the full text of every ruling to companion files, which the block's line beginning `Full original text` names and
   the successor reads in its first turn, in the same batch as the doc.
   With a rulings ledger in the bucket (`specs/decisions/rulings-in-force.jsonl`,
   kept with `chief-kit/rulings-in-force.sh record`), `next` puts the rulings in force
   first as one index: a `<MM-DD> <shift>:` head per verbatim shift (the head names the
   verbatim file), then `<id> <reading>` rows, and an `Other verbatim paths:` part for
   files of another shape. Every reading is the start of its ledger line, cut at one cap
   shared by all rows; `rulings-in-force.sh find --bucket <bucket> <id or word>` prints
   the whole line. Superseded and done rulings are left out, and the index head counts
   them (their files stay). `next` lists only the `Standing rules:` lines (topic folds) and
   the rulings dated within the last 7 days (UTC); every older ruling in force that no
   standing rule folds is named on one `Older in force:` line, by id and the first word of its
   line (the head counts them, `, <O> older than 7 days`), and stays in the ledger. Before you
   act on a topic, run `rulings-in-force.sh find --bucket <bucket> <id or word>` for it:
   an older ruling still binds. To read an old ruling in the block, fold it:
   `rulings-in-force.sh record --bucket <bucket> --id <N> --status in-force --topic <word>`
   on each ruling that says one thing. A ruling the ledger does not hold keeps its reading line and
   its read-in-the-first-turn duty. `rulings-in-force.sh check --bucket <bucket>` on the
   block proves every ruling in force is a row, in a standing rule or on the `Older in force:` line, once.
   Before you act on a ruling, read its verbatim file: the index line is not the ruling. The HANDOFF points at it (and gets the `focus-chains.json` dependency-chain order). Keep the block current on
   every ruling and wrap: `next` refuses (exit 7) an absent, empty or placeholder
   block, and (exit 6) while a Results bullet quotes an `OPERATOR ... (verbatim)`
   ruling that `decisions:` and its decisions files do not hold.
