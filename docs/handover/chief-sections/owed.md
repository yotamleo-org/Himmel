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
- **A proof result lands on its ticket, where the gate reads it.** A live proof that ran is one
  machine-readable ticket comment tied to its owed row: `PROOF <row-id> PASS|FAIL <YYYY-MM-DD> <artifact>`
  (row id `o<n>`, artifact one word: a path or `doc:line`). Closing a `proof` row (no `action`) needs
  `--proof-result PASS|FAIL --proof-artifact <path|doc:line>` (and `--ticket <KEY>` when the row has no
  key): the close writes that comment itself through `proof-comment.sh`, reads it back, and only then
  appends the close row; a comment that cannot be written or read back exits 5 and the row stays open.
  A `validate-proof` row and a decision close with `outcome` metadata are the chief's decision path
  and need none; a `step` row owed to `proof` takes the same flags. A Results bullet
  `PROOF <KEY> <row-id> PASS|FAIL <YYYY-MM-DD> <artifact> [note]` (or `LIVE-PROOF`) written with
  `append-results.sh` in a chief doc is posted to `<KEY>` the same way before it is written (a malformed
  one exits 8, a ticket write that fails exits 9, and neither writes the bullet). **A plan or spec gate that
  waits on a live result names the owed row id, and its check reads `PROOF <row-id>` on the ticket**
  (`jira comments <KEY>`), never free text such as "passed" or a result worded another way. Asked
  "did X run", search `PROOF <row-id>` first.
- **The tick ages it.** `owed=<n>:<oldest-age>` counts the open rows (hidden at 0; `?` when
  the ledger cannot be read). A `ticket` row with no key after 4 hours (`OWED_STALE_SECS`), and a
  keyed `step` past its due date, add `ACTION owed-stale=<n>:<ids>`, then one clause per kind naming
  its own ids. A ticket row: file the ticket, then close the row with its key. A step row: do the
  step and close the row with its evidence (a commit sha or a decision id), or re-date it with a new
  `owe.sh add` row and close this one with the decision id. A step stays in the stale count until
  its `step-due` wake is delivered (one wake per due date; a re-dated step gets a new one), and stays
  in `owed=` while it is open. The waiter wakes you once (`WAKE tick changed=owed`) when that stale
  count rises; closing the row ends it, and the age or an open row that is not stale never wakes.
- **The handover keeps it.** `chief.sh next` refuses (exit 9) while a `ticket` row has no key
  after one shift (`OWED_SHIFT_SECS`, default 21600 = 6 h, the queue lock's TTL), naming each row.
  File the ticket and close the row, then retry. The HANDOFF gets an `## Owed` section listing
  every open row: the successor starts with all of them.
- **The fold never moves it.** An older `queue:` segment that contains `owed`, `HOLD` or
  `to file` stays on the live `queue:` line; only plain segments go to the chief-history file.
- **The Shift list and your asks must agree.** `bash <kit>/waiting-ask-drift.sh --doc <this doc>` prints
  one line per open operator row with no delivered `OWED <key>` ask (the key is the row id or its ticket
  key; a ticket key a closed row also carried is used up, so a new row with it needs an ask keyed by its
  own id), and one per delivered ask whose key names no open operator row (an ask keyed to a closed row
  or a used-up key is skipped); it prints nothing and exits 0 when they agree, 1 on drift, 2 on an
  unreadable input or a `--bucket` that is not a directory. Run it before you tell the operator nothing
  is waiting on them.

Wrapped proof workers record a `kind: proof`, `action: validate-proof`, `actor: chief`
obligation before worker-event cleanup or direct/sweep close. A writer failure refuses
cleanup (direct close exit 9); `--check` and recorder `--dry-run` write nothing. The
shared `proof-validate.py --bucket <dir> --doc <worker doc>` only records observations.
`CLOSE` and `KEEP` are worker recommendations; `validation: pending` never authorizes
a Jira transition or discharges the action. Coverage, positive controls and candidate
ancestry remain chief work, even when every observed row says MET.

`owe.sh add` accepts `--identity <64 lowercase hex sha256>` and `--metadata <JSON>`.
Alternatively, `--metadata-stdin` reads one JSON value of at most 1 MiB (including
its compact ASCII encoding); it is mutually exclusive with `--metadata`. Metadata
passes to jq through stdin, so a large observation never occupies one OS argument.
The existing flock serializes lookup/append; file and directory fsync precede the
response. An identical identity returns its original id, even after closure. Existing
six-column `list` output stays unchanged; `list --json [--all]` returns an array with
additive metadata and a `closed` boolean. Allowed metadata fields are `actor`, `action`,
`validation`, `source_doc`, `source_label`, `evidence_path`, `evidence_hash`,
`requirements_digest`, `original_requirements_digest`, `binding`, `recommendation`,
`issues`, `proof_rows`, `executed_shas`, `required_shas`, `next_action`, `wake`, and
`evidence_records` (multiple artifact paths with their full sha256 when readable),
and `observation_counts` (per observation field: nonnegative integer `total`,
`omitted`, `truncated_chars`, with omitted no greater than total).
Each proof result records one action per covered ticket, including multiple artifacts;
conflicting artifact recommendations remain unknown with explicit reconciliation.
Unknown fields or invalid types refuse. None of these fields grants authority.

The recorder recognizes the explicit `> **Proof leg:**` header or an actual
WRAPPED proof-key tail, including the event's optional worker/ticket prefix.
Ordinary prose mentioning a proof worker does not create debt. The artifacts are the
`evidence=<path>` values of that tail or message, which name them exactly; with none
declared, every `specs/audits/....md` path the worker document names is read as evidence
by the rule below, so a file that is not the ticket's is judged as its evidence and a
missing or unreadable one refuses the CLOSE.

A covered ticket reads every declared artifact whose file name contains its key and
every one whose name contains none of the declared keys (with one declared ticket,
every declared path); an artifact named only for another declared ticket is read by
that ticket. `artifact-attribution-unvalidated` is set when a covered key has neither
a named nor an unnamed artifact among the declared paths (all of them are then
retained for it; with no path at all, none declared and none named in the worker
document, the flag is not set and `evidence-unreadable` is recorded), and when several
tickets are declared and a ticket reads an unnamed artifact beside one named for it.
It refuses a CLOSE; chief attribution remains pending.

Proof inputs are opened nonblocking and without following a final symlink. The
descriptor must be a regular file no larger than 8 MiB; bounded reads and matching
descriptor/path identity, size and modification/change times must establish one
complete snapshot before hashing. Refused, changed, unreadable or oversize evidence
records stable reconciliation debt without an evidence hash. The same text-input
bound applies to the source brief and mirrored requirements. A real writer failure
still prevents cleanup.

Artifact paths and full accepted hashes are retained. Observation previews retain
at most 64 proof rows, 32 issues, 64 executed and 64 required SHA entries; row/issue
strings retain at most 512 characters, and next-action/wake text 1024 characters.
`observation_counts` exposes the original item count and omitted item count, plus
characters removed from retained strings. For scalar text these counts are in
characters. These previews are observations, not semantic coverage; the chief
reads the full hashed artifact. Reconciliation flags precede malformed-row previews.

The recorder hashes actual artifact bytes and each key's mirrored Description DoD
and Proof sections. Requirement identity hashes compact UTF-8 JSON pairs in DoD,
Proof order, retaining body lines, indentation, fences and blank lines; only CRLF
becomes LF. Comments are excluded. It uses the local project mirror (test seam:
`PROOF_MIRROR_DIR`), never refreshes it, and cannot certify live requirement freshness.
An optional exact `requirements-sha256 <KEY>=<full hash>` line in the generated brief
above `## Results` records the original binding; absent/unreadable binding, or a stamp
only the worker wrote (artifact or Results), stays unknown. Matching
stamps mean matching observed bytes, not semantic validation. Optional `required-sha
main=<sha>` or `required-sha station=<sha>` records a candidate basis; main and station
may differ. `next-action: <text>` and `wake: <text>` are carried when supplied.
Missing/unreadable artifacts keep stable reconciliation identities from the originating
doc (label when unavailable), ticket, path and recommendation, without inventing an
evidence hash. Changed real evidence or requirement identity creates separate review work.

Chief decisions use the normal Jira `transition` with `--proof <id>`,
`--proof-bucket <dir>` and `--proof-decision <JSON file>`; see
[proof rows](proof-rows.md). The existing close row and `list --all --json` carry `outcome` with the
bound `identity`, `decision_hash`, `verdict`, actual `status`, `version_pending`
and chief `rationale`, plus exact data-only `decision_json` bytes for later review.
This records a decision, never grants permission. The CLI
reads live requirements before and after the transition; the proof helper checks
hashes and quoted citations but leaves semantic coverage to the chief. KEEP
first appends an idempotent next step with `actor`, `capability`, `due` and `wake`.
The dispatcher reads settled KEEP `source_id` references to the newest validation,
routes code to workers and read-only actions to proof, and retains operator staging.
Pending validation never activates a replacement. The recorder binds exact open
proof-step IDs in `owed_refs`; later steps, including those in the same clock second,
are excluded. Those `actor=proof` steps are discharged only after the chief's
outcome; chief/operator exceptions and later steps remain owned. A confirmed Done
with unstamped version preserves a chief `action=version-reconciliation` step; a confirmed Done
whose DoD/Proof changed before settlement preserves a chief `action=requirements-reconciliation`
step (`actual_status`, old and new digests) and leaves the validation open.

Partial merge `owed → proof by YYYY-MM-DD` steps preserve the actual proof actor
and due date, list as executable proof rows, and leave the ticket To Do. Chief
steps use the closed list `sign the spec`, `sign the GO`, `sign the release`,
`signature`, `chief signature`, `release operator step`, or `station step a worker
is refused`. Code remains `Remaining:` work. Operator staging stays operator-owned.

A partial merge never writes those steps into a chief's ledger itself. `merge-on-green.sh`
appends one row per owed line to the station spool, `<state dir>/owe-spool.jsonl`
(`TICKET_STATUS_STATE_DIR`, default `~/.himmel/state`), with
`owed-events.py spool --key <KEY> --pr <n> --repo <owner/name> --spool <spool>`, and records
the outcome on its MERGED audit line as `owe=`: `none` (no owed line), `spooled:<n>`,
`unread` (the PR body's owed lines could not be read: one `unread` row stands in for them,
due the day before the merge), or `miss:<n|?>:write` (the spool could not be written: the
lines go to stderr and the status log gets an `owe-miss` row for that key and PR). The
next tick of a chief whose doc sits inside the handover root drains the spool: for each row
of its own project it appends a `claim` row naming its bucket, then adds the step to its
ledger under the row's identity, with the draining chief's name on the row. A row
another live bucket has claimed is that chief's; a row already in the ledger only gets its
claim, so re-spooling a PR is safe. Rows never leave the spool on their own.

A spool line the drain cannot read or add prints
`ACTION owed-spool-bad=<line numbers>` (`=file` when the spool itself cannot be read or
locked). `owed-events.py spool --check --spool <spool>` lists the bad lines. Rebuild a lost
row from the PR body: `gh pr view <n> --repo <owner/name> --json body -q .body` piped
through `scripts/lib/pr_remainder.py --owed-lines` into the `spool` call above. Then remove
the bad line with `owed-events.py spool --drop <line> --spool <spool>`, which takes the
spool lock and renames a rewritten copy over the spool, so an interrupted drop leaves it
whole; it is the only way a line leaves the spool.

Tick projects keyed step dates and readiness reminders into the same owed ledger.
A step expires after its accepted UTC by-date; missing/invalid evidence emits
`ACTION owed-invalid=<source ids>` and never means Done. Keyless ticket filing debt
keeps its existing four-hour clock. A live readiness decision `d` emits
`# readiness-clock <JSON {version,key,stamp,since,age_s}>`; each elapsed 24-hour
interval creates a distinct chief reminder, with one operator digest item per
unchanged ruling. These reminders have no dispatch or hold effect.

Notification rows are `kind=ruling`, `action=notify`, with `actor`, `event`
(`step-due`, `step-due-invalid`, `readiness-d24h`, `operator-digest`), `source_id`,
`capability` and `wake`; their normal identity prevents reopening after acknowledgement.
Tick emits `ACTION owed-notify=<chief notification ids>`, `ACTION readiness-d24h=<ids>`
and one `ACTION operator-digest=<ids>` input. The waiter prints `WAKE owed-actions`
then acknowledges chief delivery through `owe.sh close --key wake-delivered`.
The operator delivery service closes digest ids only after delivery; this unit
does not send messages. Pending/acknowledged state survives chief succession in
`owed.jsonl`; no parallel queue or attempt history is introduced.
