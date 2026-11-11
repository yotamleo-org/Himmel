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
  the lease, finishes any older ruling, claims, makes one bounded model call
  (no tools, one turn, JSON out; on the subscription, and on the API lane only in
  the himmel repo with `judge` mapped in `roles.json`; there the launcher's own
  fallback is off, so a failed lane call alerts as `docs/internals/api-lane.md` says
  (a policy refusal does not) and `rm-run` itself then rules the batch once on the
  subscription, while a stopped run or a timed-out call ends the run), rules
  and applies each request through the engine, releases the lease, and prints
  one line per request, then `RM-RUN <R> summary: N refused` when any request
  was refused. An empty queue prints `RM-RUN <R>: nothing pending`
  and writes nothing.
- **A request for operator work carries the operator's words.** An INTAKE or
  REVERSION into a version, for an open ticket labelled `operator-directed` or of
  priority High or Highest, is refused before it is filed unless it names the
  decision and the operator's exact words in it:
  ```text
  release request: <KEY> is operator-directed and High; a request that places it needs a record of the operator's words.
    jira release request <R> --verb INTAKE --key <KEY> --from backlog --to <v> --why "<why>" --decision <n> --words "<the operator's exact words>"
    (<n>: specs/decisions/verbatim-decision-<n>-*.txt)
  ```
  `--decision <n>` must match exactly one `verbatim-decision-<n>-*.txt` in the
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
  then run the request again. The
  gate reads the ticket from the mirror, else from one live read; a ticket neither
  can read is refused with both fixes (`jira mirror`, or `--decision`). `jira
  create`, `jira move` and the MCP `create` tool take the same `--decision` and
  `--words` and check them before anything is filed. A backlog target, a closed
  ticket, a request filed inside a worker you spawned, the close-time Done fold and
  the version repair are not gated; a worker's request that the RM refuses comes
  back to you as a refusal.
- **The batch reads only disk.** Anything the RM must weigh goes in the
  request's `--why` or in an operator `O-` record; nothing said in a message
  reaches it.
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
  request you wrote. `REFUSED <req>: <why>` is an engine refusal: the request
  stays claimed, so fix the cause (a missing sector, an uncovered authority)
  and run `rm-run` again. `PENDING <id>` is a ruling Jira did not fully take. If
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
  `rm-queue=<n>,<oldest age>m` and, when the oldest open request is older than
  `TICK_RMRUN_MIN` minutes (default 30), the lease is free and no run started in
  the last `TICK_RMRUN_MIN_SECS` seconds (default 600), it launches one detached
  `jira release rm-run <R>` for the `release:` line of the chief's doc
  (`,run` on the field marks the launch; the log is `tick-rm-run.log` in the
  tick state dir). `rm-queue=off` means a declared release has no usable doc line,
  or the state read failed or returned non-OK; repair the wiring/read, not the lease.
  Claimed requests append `,claimed=<n>`, including `0,0m,claimed=<n>` when no open
  requests remain. Claimed-only work never launches an RM: inspect the held ruling
  instead of re-billing it. An empty open-and-claimed queue, no declaration,
  explicit `release: none`, or an unreadable doc shows no field.
- **Version drift is repaired by the tick, not alerted.** Three fields follow
  `rm-queue=`, each elided when empty, none in the wake key, none a message.
  `held=<n>:<sig8>` is the count of keys the repair cannot place on its own and
  the first 8 hex of the held signature, which moves only when the held set moves.
  `unfiled=<n>` counts signed operator records no request carries yet. Both read
  `release/<R>/repair-held.json`. `repair=off:<why>` shows while the repair cannot
  run: `mirror-unknown` or `bad-input` (a stop), `error` (a run that reported an
  error, retried on the `TICK_RMRUN_MIN_SECS` gap), `lost` (a launched run
  left no end record: it failed to start or died mid-run; the tick retries it on a
  backoff from `TICK_RMRUN_MIN_SECS`, capped at 6 h, and `repair-run.log` holds its
  stderr), or `unreviewed` (no `repair-reviewed` marker,
  so the first `jira release repair <R> --apply --repo <owner/name>` is yours, after
  a dry run). With the marker the tick launches the apply itself, detached, only when
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
