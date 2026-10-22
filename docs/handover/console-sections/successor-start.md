# Console section — after the successor LIVE: close the predecessor, re-ask judges

Read on demand from `console-template.md` ACTION ZERO step 9. Moved verbatim from the template.
ACTION ZERO step 1 is one batched turn (`ListAgents`, `ToolSearch` for `SendMessage`,
the decisions `Read`, and a foreground `action-zero.sh --acquire --render-legs`);
the relays below follow in the very next turn.

   **Wake-once succession (step 9).** A leg's quote-back is its own `SUCCESSION
   accepted` Results bullet (no token in it); it sends a `SendMessage` only on a
   timeout or a decline. Add `--succession <your session> [--silent-min T]` (T
   whole minutes, default 20) to the step-10 waiter line on its first arm. On
   `WAKE succession complete <n/n>` write each leg's nonce into `## Live state`
   (the fresh one if issued, else the unchanged one) and run the printed LIVE
   command; on `WAKE succession partial <k/n> silent <T> min` name the legs
   still out. Sending LIVE earlier reads `nonces=UNCONFIRMED:<leg>`. Then
   `TaskStop` the waiter and re-arm it without `--succession`.
   **Then close the predecessor's window.** Once its doc's lock is
   free and its last Results bullet reads `WRAPPED`, run
   `bash scripts/handover/console-kit/close-wrapped-leg.sh --console <predecessor doc>`
   (same checks as a leg: it refuses while the lock is held, the tail is not
   `WRAPPED`, or not exactly one live session carries its name; exit 6 means
   retry shortly; exit 7 means it still has a live subagent, a judge call
   whose verdict would die with it: retry once it finishes).
   Left open, the wrapped session is idle-compacted at full cost.
   **Before you re-dispatch any judge the predecessor asked**, read the
   HANDOFF's open judge calls and each qid's `verdicts/<qid>/` file: a written
   verdict is the answer; only a qid with no file and no running child is
   re-asked.

   **Restate the direction.** The successor's `LIVE` restates the first lines of
   the HANDOFF's `## Current direction`, so the outgoing chief can catch a misread
   before it wraps. `chief.sh next` carries that block (and the `focus-chains.json`
   chain order) into the successor doc and the HANDOFF. Keep the block current on
   every ruling and wrap: `next` refuses (exit 7) an absent, empty or placeholder
   block, and (exit 6) while a Results bullet quotes an `OPERATOR ... (verbatim)`
   ruling that `decisions:` and its decisions files do not hold.
