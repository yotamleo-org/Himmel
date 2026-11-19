# Chief section — the owed ledger

Read on demand from `chief-template.md` `## Standing rules`. What you owe after a
shift (a ticket to file, a proof to run, a ruling to ask for) is a row in
`<bucket>/owed.jsonl`, never only prose in this doc: prose gets folded, trimmed and lost
at a handover; the ledger is carried by the tick, the HANDOFF and the queue fold.

- **Owed means a row.** The moment you say "ticket owed", "proof owed" or "ruling owed",
  write it: `bash <kit>/owe.sh add --bucket <dir of this doc> --chief <letter> --kind ticket|proof|ruling|step --text "<one line>"`.
  It prints the row id (`o1`, `o2`, ...). `--key <KEY>` is for a row that already has one.
- **Close it with what proves it.** `bash <kit>/owe.sh close --bucket <dir> --id <id> --key <key>`:
  a ticket key for a `ticket`, a commit sha for a `proof`, a decision id for a `ruling`. A close
  without a key is refused. The file is append-only: a close adds a row, nothing is rewritten.
  `owe.sh list --bucket <dir>` prints the open rows (`--all` adds the closed ones).
- **The tick ages it.** `owed=<n>:<oldest-age>` counts the open rows (hidden at 0; `?` when
  the ledger cannot be read). A `ticket` row with no key after 4 hours (`OWED_STALE_SECS`) adds
  `ACTION owed-stale=<n>:<ids>`: file the ticket, then close the row with its key. The waiter
  wakes you once (`WAKE tick changed=owed`) when that stale count rises; closing the row with a key
  ends it, and the age or an open row that is not stale never wakes.
- **The handover keeps it.** `chief.sh next` refuses (exit 9) while a `ticket` row has no key
  after one shift (`OWED_SHIFT_SECS`, default 21600 = 6 h, the queue lock's TTL), naming each row.
  File the ticket and close the row, then retry. The HANDOFF gets an `## Owed` section listing
  every open row: the successor starts with all of them.
- **The fold never moves it.** An older `queue:` segment that contains `owed`, `HOLD` or
  `to file` stays on the live `queue:` line; only plain segments go to the chief-history file.
