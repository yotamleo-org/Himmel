# Chief section — the owed ledger

Read on demand from `chief-template.md` `## Standing rules`. What you owe after a
shift (a ticket to file, a proof to run, a ruling to ask for) is a row in
`<bucket>/owed.jsonl`, never only prose in this doc: prose gets folded, trimmed and lost
at a handover; the ledger is carried by the tick, the HANDOFF and the queue fold.

- **Owed means a row.** The moment you say "ticket owed", "proof owed" or "ruling owed",
  write it: `bash <kit>/owe.sh add --bucket <dir of this doc> --chief <letter> --kind ticket|proof|ruling --text "<one line>"`.
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

Wrapped proof workers record a `kind: proof`, `action: validate-proof`, `actor: chief`
obligation before worker-event cleanup or direct/sweep close. A writer failure refuses
cleanup (direct close exit 9); `--check` and recorder `--dry-run` write nothing. The
shared `proof-validate.py --bucket <dir> --doc <worker doc>` only records observations.
`CLOSE` and `KEEP` are worker recommendations; `validation: pending` never authorizes
a Jira transition or discharges the action. Coverage, positive controls and candidate
ancestry remain chief work, even when every observed row says MET.

`owe.sh add` accepts `--identity <64 lowercase hex sha256>` and `--metadata <JSON>`.
The existing flock serializes lookup/append; file and directory fsync precede the
response. An identical identity returns its original id, even after closure. Existing
six-column `list` output stays unchanged; `list --json [--all]` returns an array with
additive metadata and a `closed` boolean. Allowed metadata fields are `actor`, `action`,
`validation`, `source_doc`, `source_label`, `evidence_path`, `evidence_hash`,
`requirements_digest`, `original_requirements_digest`, `binding`, `recommendation`,
`issues`, `proof_rows`, `executed_shas`, `required_shas`, `next_action`, `wake`, and
`evidence_records` (multiple artifact paths with their full sha256 when readable).
Each proof result records one action per covered ticket, including multiple artifacts;
conflicting artifact recommendations remain unknown with explicit reconciliation.
Unknown fields or invalid types refuse. None of these fields grants authority.

The recorder hashes actual artifact bytes and each key's mirrored Description DoD
and Proof sections. Requirement identity hashes compact UTF-8 JSON pairs in DoD,
Proof order, retaining body lines, indentation, fences and blank lines; only CRLF
becomes LF. Comments are excluded. It uses the local project mirror (test seam:
`PROOF_MIRROR_DIR`), never refreshes it, and cannot certify live requirement freshness.
An optional exact `requirements-sha256 <KEY>=<full hash>` line in the artifact or
brief records the original binding; absent/unreadable binding stays unknown. Matching
stamps mean matching observed bytes, not semantic validation. Optional `required-sha
main=<sha>` or `required-sha station=<sha>` records a candidate basis; main and station
may differ. `next-action: <text>` and `wake: <text>` are carried when supplied.
Missing/unreadable artifacts keep stable reconciliation identities from the originating
doc (label when unavailable), ticket, path and recommendation, without inventing an
evidence hash. Changed real evidence or requirement identity creates separate review work.
