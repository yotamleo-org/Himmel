# {{PREDECESSOR_LETTER}} → {{LETTER}} handoff state

> **This file wins over the {{PREDECESSOR_LETTER}} Results tail**; use that tail
> only where a section here is empty.

**Head:** {{HEAD_LINE}}
**Usage at write:** {{BANK_LINE}}
**Operator:** `<at the station / away / asleep>`.

## How {{LETTER}} starts

Run ACTION ZERO from `{{SUCCESSOR_DOC}}` unchanged; expect at the root sweep
`<the locks the successor should find>`. Kit: `{{KIT}}`. Its `workers:` line holds
the predecessor's workers and tokens; a worker is yours only once it has quoted back.
A relay MAY keep a worker's token (a `{{LETTER}}-<worker>-<hex>` rotation is optional).
Ask `{{PREDECESSOR}}` (minus `.md`) to re-brief each worker from its own socket,
naming you and quoting the worker's token (and your fresh one, if issued).
Arm `chief-wait.sh --succession <your session name>` before you wait (ACTION
ZERO step 9); a quote-back is the worker's `SUCCESSION accepted` bullet. On
that session's `RELAYED <n> of <m>` send it **`{{LETTER}} LIVE`**, naming each
worker it could not relay (`LIVE` before `RELAYED` strands every worker not yet
re-briefed). The tally is informational: on `WAKE succession partial` name each
worker that did not quote back, and why, in a Results bullet; never resend LIVE.
Then re-arm without `--succession`.

If this note has a `## Start, plan and design in flight` section, read its
pointers at takeover and name them in your first status; open an item only when you act on it.

## Current direction

{{CURRENT_DIRECTION}}

## In flight

> Facts cap at ~1.5k tokens (`over the HANDOFF size budget — run: …` is a
> pointer); rulings are never trimmed.

{{LIVE_STATE}}; never retype a worker's nonce, lock token or pid. A worker not on its
`workers:` line is not alive (confirm with ListAgents).

**Workers** (fleet manifest, last Results marker of each):

{{WORKER_SESSION_LIST}}

**Open PRs:**

{{OPEN_PRS}}

**Held queue:** {{QUEUE_LINE}}
**Last GO:** {{LAST_GO}}

**Open judge subagents** (running when `chief.sh next` ran):

{{JUDGE_CALLS}}

<Per qid: `<qid> — pending | GO | NO-GO` from `verdicts/<qid>/` (no file =
pending); never re-run a written verdict.>

## This shift (last Results bullets)

{{SHIFT_SUMMARY}}

## Rulings and judgement notes — the only part the chief writes

<Numbered, one line each: binding rulings, each worker's model, brief and
debt, the queue's tiers and owned files. One Edit replaces this block.>

## Wrapped this shift

<Closed workers (locks free) and their PRs.>

## Open operator items

<What only the operator can do: a merge, a credential, a dashboard flip.>

<!-- digest-template: everything below renders the -DIGEST.md, never the HANDOFF -->
# {{PREDECESSOR_LETTER}} → {{LETTER}} successor digest

> Bounded: `chief.sh next` caps this file (`DIGEST_BUDGET_BYTES`, default 8000) and a
> capped list ends in a `+N more` pointer. Read it instead of the predecessor's doc; the
> HANDOFF's hand-filled sections are read before your first dispatch (named at the end).

**Head:** {{HEAD_LINE}}
**Usage at write:** {{BANK_LINE}}
**Start:** run ACTION ZERO from `{{SUCCESSOR_DOC}}`; the predecessor `{{PREDECESSOR}}` relays once (relay-on-live), you send `{{LETTER}} LIVE` on its `RELAYED <n> of <m>`.
**Workers** (a worker is yours only once it has quoted back):

{{WORKER_SESSION_LIST}}

**Open PRs:**

{{OPEN_PRS}}

**Held queue:** {{QUEUE_LINE}}
**Last GO:** {{LAST_GO}}
**Open judge subagents:**

{{JUDGE_CALLS}}

**Rulings:** in `{{SUCCESSOR_DOC}}` `## Current direction` (read the files it names).
**Chain order:** {{CHAIN_ORDER}}

**READ BEFORE YOUR FIRST DISPATCH.** Each part is a HANDOFF section you act on; a list here is capped and `{{HANDOFF_REF}}` holds the rest.

Wrapped with open PR (disposition each: relaunch, GO or close):

{{WRAPPED_PRS}}

Owed (open `owed.jsonl` rows):

{{OWED}}

Start, plan and design in flight (open an item only when you act on it):

{{INFLIGHT}}

Orphan gate: {{ORPHAN_NOTE}}

The predecessor fills three sections by hand in `{{HANDOFF_REF}}`: `## Rulings and judgement notes`, `## Wrapped this shift`, `## Open operator items`. Read those three before your first dispatch.
**Predecessor doc** `{{PREDECESSOR}}`: open only for the one thing a pointer names.
