# Chief section — the release manager: routing every placement

Read on demand from `chief-template.md` `## Standing rules`. Applies while a
release is declared (`jira release state <R>` prints a status other than
`UNKNOWN: … is missing`). The release manager runs on demand, not as a standing session.

- **Every placement into, out of or within the release is a request.** You
  never write a release version's fixVersions yourself. Write the request(s),
  then rule the batch in one call:
  `jira release request <R> --verb INTAKE|REVERSION|DISCHARGE --key <KEY> --from <v|backlog> --to <v|backlog> --why "<one line>"`
  prints `REQ <id>`; a duplicate of an open request returns the open one. Then
  `jira release rm-run <R>` rules every pending request and exits. It takes
  the lease, finishes any older ruling, claims, rules each request by the door's
  fixed rules with no model call (the model judge is parked: only
  `HIMMEL_RM_JUDGE=model` reaches it, and nothing sets that by default), applies
  each request through the engine, releases the lease, and prints
  one line per request, then `RM-RUN <R> summary: N refused` when any request
  was refused. An empty queue prints `RM-RUN <R>: nothing pending`
  and writes nothing. The release manager keeps STATUS, BURN-DOWN and READY.
- **A request needs no words from you.** An INTAKE or REVERSION files for every
  filer with no `--decision`, an `operator-directed` or High ticket included, and
  the door rules it: an operator ask lands in the current version
  (`door:operator-ask`), and the newest operator record on the key is read by the
  door itself, so the request cites none. `--decision <n> --words "<the operator's
  exact words>"` still records the words when you have them. `--decision <n>` must match exactly one `verbatim-decision-<n>-*.txt` in the
  bucket's `specs/decisions`. `--words` must occur byte for byte in one paragraph
  of that file, never in a paragraph that opens with a gloss word (`Read`,
  `Reading`, `Chief`, `Asked`, `Answering`, `Note`, `Ruling`, `Relayed`, `Facts`
  and the rest of the list in `scripts/jira/src/release/verbatim.ts`), and be at
  least 20 characters or the whole paragraph (a bare "yes"). Your own reading of a
  ruling is never the operator's words. The same call writes one `O-` record with
  `words: 1` (or reuses the one an earlier call wrote), withdraws an open duplicate
  that cites no `O-` record, and files the request citing it; it prints
  `OPERATOR <O-id>`, `WITHDRAWN <req>` when there was one, and `REQ <id>`. An open
  duplicate that already cites an `O-` record is returned as it is, so its `REQ`
  may cite an older record than the `OPERATOR` line names; to file the request on
  the new words, `jira release withdraw <R> --req <id> --reason "<why>"` it first,
  then run the request again. `jira
  create`, `jira move` and the MCP `create` tool take the same `--decision` and
  `--words` and check them before anything is filed. A worker's request that the
  RM refuses comes back to you as a refusal.
- **A ruled-away ask wakes you once.** A refused ask is a key whose latest
  receipted ruling, on a request from the backlog into a version, left it outside
  that version (`BACKLOG`, or `KEEP` on such a REVERSION); a demotion is never one.
  `jira release state <R> --json` lists them under `refused_asks` until a newer
  request for the key, a later `O-` record naming it, the ticket closing, or your
  ack ends one. The tick prints `rm-refused=<n>:<KEY>@<ruling>,...` (n counts all,
  the list names the operator-asked ones) and writes them to
  `rm-refused-<doc stem>.tsv` in its state dir; the waiter wakes you once per new
  operator-asked pair (`WAKE rm-refused <KEY>@<ruling> — fix: <reason> — ground: <ground> — remedy: <the exact command>`)
  and sends the rest as one digest a day (`WAKE rm-refused-digest <n> new: ... — remedy: <the first command>`). The tsv
  rows carry the ground and remedy (bounded, control characters flattened); an older four-column row wakes as before.
  A changed ruling is a new pair and wakes again; the same pair wakes once. Answer an
  operator-asked one by asking again with the operator's words (`--decision
  --words`), recording an `O-` record, or closing the ticket. A refusal you hold
  right on any other key ends with `jira release ack <R> --ruling <R-id> --reason
  "<why the refusal is right>"`; the ack is refused for an operator-asked key, for a
  key the mirror does not hold, and inside a worker you spawned. With the mirror
  unreadable a refused ask's `asks_operator` reads `null`, and the tick skips the field.
- **The door's placements come to you as three lists.** `jira release state <R> --json`
  lists each receipted door ruling you have not yet cleared: `priority_review` (a priority
  or carry-over placement: serious, mild, rest-of, operator-ask, started, undeclared, with
  its ground), `chief_placements` (a `door:chief` placement, with its reason) and
  `asks_apart` (an operator ask placed apart from its parent, one entry per key, version,
  parent and parent version; a second ruling of the same tuple adds none). The tick prints
  `prio-review=<n>:<oldest KEY>`, `chief-placed=<n>:<KEY>,...` and `ask-apart=<n>:<KEY>,...`,
  each absent at zero and outside the waiter's action key. The waiter wakes you once per new
  chief placement (`WAKE chief-placed <KEY> <reason>`) and once per new ask apart
  (`WAKE ask-apart <KEY> <version> parent <P> <parent version>`); a priority entry wakes
  nothing and waits for your next tick. What each list asks of you: for a priority entry,
  check the ground fits the ticket and relay it to the operator only when it does not; for
  a chief placement, tell the operator the key and your reason; for an ask apart, tell the
  operator the ask and its version, the parent and its version, and the two choices: move
  the parent with `jira release operator decision`, or leave the parts split. Check or relay
  an entry, then clear it with `jira release reviewed <R> --ruling <R-id> --reason "<what you checked>"`,
  or clear a list up to one entry with `--through <R-id>`: it clears only that entry's own
  list, so a priority sweep never closes a chief placement or an ask apart. The verb is
  refused inside a worker you spawned. The `reviewed` row changes no placement.
- **Explicit changes and blocked recovery.**

  A pending request keeps its known required-parent relation when a repeat omits
  `--required-by`; forgetting the flag does not withdraw a requirement. To record
  an explicit removal, repeat the request with `--evidence '{"remainder":false}'`
  after deciding the parent can finish independently. To change the parent, use
  `--required-by <new-parent>`. These append the changed evidence through the
  normal request writer; they do not admit the child or close the parent.

  An unfinished move marked `blocked` belongs to the chief (the tick and the waiter
  tell you: see "A blocked ruling wakes you" below). Read its observed
  membership and actual finish/restore remedy before running another batch;
  `rm-run` alone cannot resolve conflicting membership. A read-only release
  directory or unavailable repair-state lock is an explicit read/attempt failure,
  not a successful scheduled repair. Keep the last verified record and use the
  normal lock/storage recovery path; do not invent a launch timestamp or claim
  an unpersisted state is authoritative.

- **The batch reads only disk.** The door reads no `--why` text and nothing said in a
  message. It reads the declared current version and version order; the request (its key,
  verb, `--from` and `--to`, and its evidence: a chief placement, a rule, an operator
  record); the ticket's snapshot (status, priority, labels, the versions it holds, its
  sector); its required parent's snapshot; the key's earlier rulings and ledger records;
  and the operator's decision records that name the key. It reads no blocker record and
  no text of the release rules. To steer a placement, record an operator decision on the
  key or pass the request flag that carries it (`--chief-reason`, `--required-by`).
- **A priority raise on a ticket in a later version is yours to place.** The door
  never moves a key out of a version it holds, so a ticket raised to High or Highest
  that sits in a version after the current one stays there. The tick's
  `serious-later=<n>:<oldest KEY>` counts those tickets (absent at zero, no wake, no
  doctor WARN). Place one with a REVERSION request that carries your reason:
  `jira release request <R> --verb REVERSION --key <KEY> --from <later v> --to <current v> --why "<line>" --chief-reason "<reason>"`.
  A priority lowering is not a placement; only an operator record moves a key out.
- **Unplaced tickets show in the tick.** `unplaced=<new>[,pending=<n>][,legacy=<n>][,stale-label=<n>]`
  counts the open tickets with no version and no backlog label (`intake-backfill.sh --unplaced --list --since-door --state <state.json>`,
  with the output of `jira release state <R> --json` as the state file, shows each key and bucket as the tick sees it). `new` is a ticket filed since the door shipped: it needs your look,
  because the door should have placed it. `pending` has an open request, `legacy` predates the door,
  `stale-label` holds a version and the backlog label. The field is absent at zero and never wakes you.
- **A worker's FINDING that asks "file it where?"** is a request. So is a
  follow-up you file yourself: file it to backlog, then request its INTAKE.
- **A launch on a ticket outside the current version is refused** (`brief-lint.sh`
  `bucket_rule`, exit 3; `--no-prior-art-check` does not skip it). The refusal names
  the key, its version, current and the open count, and asks why this ticket and not
  the bucket. Your routes: place it in the bucket with a request and `rm-run`
  (above); or, if the operator approved it as out of version, record that with
  `jira release operator out-of-version` (the operator's words, 14 days, a phone line
  for each; never for parallel work outside the bucket); at 0 open the version is
  done, so run READY and the operator releases it in Jira. A Done ticket needs a new
  ticket with `--follow-up-of` or a reopen; a relaunch of a doc that has already
  reported (a `## Results` bullet) passes. A project with no versions file passes. Both
  passes print a `bypass=` line on the launch. A failed Jira read refuses by name
  (rebuild the jira CLI, refresh the mirror, retry), because this gate fails shut.
  No launcher switch passes it (`--skip-bucket` is the generator's flag, and the
  launcher never passes it). Only the test seams remain (`BRIEF_LINT_JIRA_CLI`,
  `BRIEF_LINT_MIRROR` and `HOME`, which picks the default mirror; spec row 12 accepts
  them), and `BRIEF_LINT_VERDICT_TIMEOUT` can only shorten the wait. A judge, consult or
  relay launch is not asked.
- **A RULING is a `RULING <id> <req> …` line printed by `rm-run`** for a
  request you wrote. `REFUSED <req>: <why>` is an engine refusal: the request is
  closed, so fix the cause (a missing sector, an uncovered authority) and file it
  again, which opens a new request id. The door rules or refuses; it never
  holds a request. `REFUSED <req>: the judge returned no decision` and `HELD <req>: <why>`
  are the parked judge's results (the first leaves the request claimed for the next
  `rm-run`; `HELD` means nothing was ruled): a version-repair request
  is set aside as held and leaves the queue, and any other request stays claimed. A held one
  shows in the repair's held list until an operator record answers it or the
  key's Fix Version changes again, and then a repair run withdraws it; you can
  also withdraw it with `jira release withdraw`. `PENDING <id>` is a ruling Jira did not fully take. If
  Jira took none of it, the next run finishes it by readback. If Jira took part
  of it, the ruling stays `PENDING` on every run until the key's fixVersions
  are fixed by hand in Jira. A run that dies (bank-preflight not
  `PROCEED`, a failed model call) rules nothing and releases the lease.
- **Disputes go to the operator, not back to the RM.** Relay both reasons;
  the ruling stands until an operator record supersedes it. Never re-run a
  ruled request to get a different answer.
- **An operator ruling is a scoped record.** Write it before `rm-run` rules
  on it, then quote the printed `O-` id in the request's `--why`:
  `jira release operator decision <R> --decision <n> --keys <k1,k2> --op add|remove|move|keep|discharge|none --from <v|backlog> --to <v|backlog> --words "<the operator's exact words>"`.
  `--words` is checked against the decision's verbatim file as above and marks the
  record `words: 1`; `--op none` records words that place nothing and withdraw no
  request. `--verbatim-file <f>` is the legacy form, exactly one of the two: it
  stores the file unchecked, without `words: 1`, and the RM reads it as before.
  The writer refuses inside any worker the chief spawned. A bare decision number
  authorizes nothing.
- **Declaring a release and freezing a baseline are operator acts**, done by
  you on an operator decision: `jira release operator declare <R> --versions
  <current>,<next> --decision <n> --verbatim-file <f>` (mode `observe` by
  default; `live` only after the activation barrier's signed row), and
  `jira release operator freeze <R> --version <v> --keys <list> --decision <n>
  --verbatim-file <f>`. A frozen baseline is immutable; a new freeze is a new
  generation.
- **Emergencies are always current** (decision 109): an evidenced emergency
  (Highest or Blocker, a red main run, a regression of a merged PR) is placed
  in the current version under `O-<R>-emergency`, and repair starts at once.
  The next `rm-run` records its class and sector.
- **Open requests are ruled without you.** The waiter's tick shows
  `rm-queue=<n>,<oldest age>m[,claimed=<n>][,replay=<n>][,run]` and, when the oldest open request is older than
  `TICK_RMRUN_MIN` minutes (default 2), the lease is free and no run started in
  the last `TICK_RMRUN_MIN_SECS` seconds (default 600), it launches one detached
  `jira release rm-run <R>` for the `release:` line of the chief's doc
  (`,run` on the field marks the launch; the log is `tick-rm-run.log` in the
  tick state dir). `rm-queue=off` means a declared release has no usable doc line,
  or the state read failed or returned non-OK; repair the wiring/read, not the lease.
  `rm-queue=?` means the tick's deadline cut the state read: it says nothing about
  the wiring, so retry on the next tick.
  Claimed requests append `,claimed=<n>`, including `0,0m,claimed=<n>` when no open
  requests remain. Claimed-only work never launches an RM: inspect the held ruling
  instead of re-billing it. An empty open-and-claimed queue with no ruling to replay,
  no declaration, explicit `release: none`, or an unreadable doc shows no field.
- **An interrupted ruling is replayed without you.** A ruling interrupted after its
  Jira write (the admissions row or the receipt still owed) leaves its request in
  `ruled:<R>`, not open, so the open count never shows it. The tick reads the state's
  `unfinished_rulings`, counts those with `status: replay` and appends `,replay=<n>`
  (`0,0m,replay=<n>` when the queue is empty). With one to replay, a free lease, an OK
  state and no run launched in the last `TICK_RMRUN_MIN_SECS` seconds (default 600),
  it launches the same one detached `jira release rm-run <R>` as for an aged request
  and marks it `,run`; there is no age gate, because the state carries no age for a
  ruling. The lease also counts as free when the state says `lease.owner_gone`: the
  jira CLI found the recorded owner pid absent on this host (a run killed hard), the
  same proof `rm-run`'s own reclaim uses; the tick judges no pid itself, and a live or
  reused pid keeps the lease held. A replay `rm-run` cannot finish is retried at most
  once per that interval, never on every tick, and `replay=<n>` stays on the line until
  `jira release state <R> --json` lists no `unfinished_rulings` for it; nothing
  wakes the chief for a replay that never finishes, so read that list when
  `replay=<n>` lingers on the line. The tick never launches for a `status: blocked`
  move (not counted in `replay=<n>`: it wakes the chief instead, see the next
  bullet), for claimed-only work, behind a held lease whose owner is not
  proven gone, or on a state that is not OK, and it writes no release state (the
  `rm-run` it starts does).
- **A blocked ruling wakes you.** An unfinished move with `status: blocked` is
  yours: `rm-run` never repairs one and the replay launch above never counts it. From
  the same state read as `rm-queue=`, the tick prints `rm-blocked=<n>:<KEY>@<ruling>,...`
  after `rm-refused=`: n counts the blocked rulings, the pairs are sorted, and the
  field is absent when none is blocked or the chief doc declares no release. It reads
  `?` when the tick cannot tell: the state read failed or is not OK, the state's
  mirror input is `UNKNOWN` (the engine then lists every unfinished ruling as
  `replay`, a blocked one too), or `unfinished_rulings` is not a list of rows that
  each carry a key and a ruling id. The field is in the waiter's key, so it wakes you
  once for a set (a `WAKE tick` naming `rm-blocked` in `changed=`, the tick line
  follows) and again only when the set changes: a ruling joins, leaves or is swapped
  for another. A `?` keeps the last known set and wakes nobody, so the same set coming
  back after one wakes nobody and a different set wakes once; a set that empties
  wakes nobody. Nothing reminds you while a set stands, and nothing stores it: the
  tick derives it from the state on every tick. A set already on the tick line when a
  waiter has no saved key, or a saved key taken under different tick args or manifest
  worker set, is that waiter's silent baseline, so a chief that starts or takes over
  reads `rm-blocked=` on the tick line. To act, read `jira release state <R> --json`,
  find each listed ruling under `unfinished_rulings`, and follow its `observed` and
  `next` (finish or restore the move with `jira fix-version`); then
  `jira release rm-run <R>` writes the row and receipt once. A ruling stuck in
  `replay` still wakes nobody.
- **Version drift is repaired by the tick, not alerted.** Three fields follow
  `rm-queue=`, each elided when empty, none in the wake key, none a message.
  `held=<n>:<sig8>` is the count of keys the repair cannot place on its own and
  the first 8 hex of the held signature, which moves only when the held set moves.
  `unfiled=<n>` counts signed operator records no request carries yet. All three
  read `release/<R>/repair-state.json`, the one record the jira CLI writes
  (`jira release repair-state <R> --json` prints it; `operator_command` is stored in
  the record itself while no review marker exists and the state is `off:unreviewed`,
  `off:error` or `lost`: the first apply, the one permitted act); the tick reads it and writes no repair file. Every writer of the record (the read, `--attempt`, the run's
  begin and end) takes the short `repair-state.lock.d` lock and re-reads under it, always
  after `repair.lock` (the run's lifetime lock) and never the other way.
  `repair-held.json` and the other repair files stay as written copies for now.
  `repair=off:<why>` shows while the repair cannot
  run: `mirror-unknown` or `bad-input` (a stop), `error` (a run that reported an
  error, retried on the `TICK_RMRUN_MIN_SECS` gap), `lost` (a launched run
  left no end record: it failed to start or died mid-run, or its owner cannot be bound
  to its process: a pid counts as live only while it shows the recorded process
  identity; the tick retries it on a
  backoff from `TICK_RMRUN_MIN_SECS`, capped at 6 h, and `repair-run.log` holds its
  stderr; it shows before any review too, but nothing launches without the marker),
  `unavailable` (the tick wanted to launch and no launch attempt could be recorded:
  the CLI is absent, refused it or a run is alive), `unread` (no record can be read
  even through the CLI). Before each detached start the tick asks the CLI to record the
  attempt (`repair-state <R> --attempt`); the record's attempt time and count time the
  next try at the gap, doubling to 6 h, so a launcher that never starts the CLI is not
  retried every tick. `unreviewed` (no review marker in the record,
  so the first `jira release repair <R> --apply --repo <owner/name>` is yours, after
  a dry run). That first apply is the station's first repair run. Run the same
  command without `--apply` first: the dry run writes nothing, prints the lanes and
  looks up at most 20 merged PRs, so `capped: true` means some keys wait for a later
  run. The apply files at most 20 requests and 20 folds per run, each only after a
  live Jira read agrees with the mirror, so a long fold lane takes many runs. It
  writes `repair-held.json`, and on a clean finish the `repair-reviewed` marker,
  which turns the tick's own runs on. Run it from your console: a worker you
  spawned is refused. With the marker the tick launches the apply itself, detached, only when
  the run signature (leak set plus the operator, requests, journal and mirror
  heads) changed, or when the last launch left no end record; it never writes a Fix Version. What you do: put the held batch
  in one line of the milestone report's "Blocked on you" list (the path, the
  default per class, the paste-ready commands from `repair-held.json`), and repeat
  that line only when the `<sig8>` changes. The board's repair panel lists the
  same classes, one row each.
- **A worked ticket folds into the current version on its own.** A merge
  (`merge-on-green.sh`, any path that does not stamp the ticket) and a worker's LIVE
  bullet (`worker-jira-status.sh`) file one INTAKE request to the current
  version (the earliest unreleased, unarchived one) when the ticket still holds a
  later unreleased version; the CLI dedups an open request, the LIVE path keeps
  one stamp per key, and the merge prints `intake=<REQ>` (or `intake=failed`) on
  its audit line. An unversioned or already-current ticket files nothing.
- **Live state** carries `release: <R>` and the lease line. `chief.sh new` and
  `next` seed a missing release line from the unique `release/<R>/release.json`
  under `<handover root>/<user>/<primary repo>/` (or `HIMMEL_RELEASE_STATE_DIR`).
  This is not the chief's arbitrary `--bucket`, nor the first open fixVersion.
  Foreign `--project` chiefs do not inherit this checkout's declaration or warning.
  Existing lines, including `release: none`, are preserved. Multiple declarations
  are never guessed: choose one explicitly. No release-manager
  session waits between batches: each `rm-run` takes the lease as its own run
  record under `release/<R>/rm-runs/` and releases it, and a held lease refuses
  a second batch. A run that crashed while holding the lease needs
  `jira release operator takeover <R> --epoch <n> --doc <absolute run doc>`,
  then `jira release rm-run <R> --doc <that doc>`.
- **Backfill unplaced tickets without bypassing the RM.**
  `bash scripts/handover/chief-kit/intake-backfill.sh --mirror <snapshot> --commands --release <R> --batch <n>`
  prints, never executes, reasoned INTAKE requests for at most 20 keys per batch.
  Keep the same mirror snapshot for stable batch offsets; file one batch, let the
  tick's RM drain it, checking both open and claimed requests before the next batch;
  a claimed request can be held, not completed. `proposed-*` is not proof of a request:
  those keys remain candidates; the request CLI deduplicates matching pending
  requests, not ruled ones. Review request/ruling history before running printed
  commands: an already-ruled BACKLOG key can reappear in this mirror-only plan.
  The RM still decides version versus backlog; no fixVersion is written by this
  tool and there is no bulk override.
- **STATUS, BURN-DOWN and READY** remain release-manager verbs, run by an
  on-demand session armed from `docs/handover/rm-brief-template.md` only when
  you need one of them. That session does the verb, reports, releases the
  lease and wraps.
- **The board's release manager panel** (`board.mjs`, from the `release:`
  line) shows M4 burn-down per version, the leaks and the M1 trend; a leak (`leaks:` non-empty) is a mismatch to request a ruling
  for, never a number to manage down. No line is a count gate (decision 104).
