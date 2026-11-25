# Worker preface section — the live proof runs in this session

Read on demand: `worker-preface.md` names this file in "Wrapping up".

After the merge, before `WRAPPED`:

1. Run `himmel-update` when the ticket's proof needs your change on the station.
2. Run the brief's live-proof rows now, and quote their output on the ticket.

A proof is owed past `WRAPPED` only in one of two shapes:

- `owed → proof by YYYY-MM-DD`, for a real window (a 5-day count, the next
  nightly). Its owed row wakes a proof worker on that date: `owed-events.py`
  writes a read-only proof brief and a `proof-wake` notification for the chief.
- `owed → operator`, `owed → Mac` or `owed → VM`, for an outside actor.

The wrap gate (`wrap-subtree-check.sh --queue-doc <doc>`) refuses any other
owed proof, in your `WRAPPED` bullet or in the ledger, and prints no
`CLOSABLE:` line until it is run or reshaped.
