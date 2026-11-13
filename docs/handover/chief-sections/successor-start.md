# Chief section — after the successor LIVE: close the predecessor, re-ask judges

Read on demand from `chief-template.md` ACTION ZERO step 9. Moved verbatim from the template.
ACTION ZERO step 1 is one batched turn (`ListAgents`, `ToolSearch` for `SendMessage`,
the decisions `Read`, and a foreground `action-zero.sh --acquire --render-workers`);
the relays below follow in the very next turn.

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
   them (their files stay). A ruling the ledger does not hold keeps its reading line and
   its read-in-the-first-turn duty. `rulings-in-force.sh check --bucket <bucket>` on the
   block proves every ruling in force is named once with its date, path and a reading.
   Before you act on a ruling, read its verbatim file: the index line is not the ruling. The HANDOFF points at it (and gets the `focus-chains.json` dependency-chain order). Keep the block current on
   every ruling and wrap: `next` refuses (exit 7) an absent, empty or placeholder
   block, and (exit 6) while a Results bullet quotes an `OPERATOR ... (verbatim)`
   ruling that `decisions:` and its decisions files do not hold.
