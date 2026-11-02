# Chief section — the release manager: routing every placement

Read on demand from `chief-template.md` `## Standing rules`. Applies while a
release is declared (`jira release state <R>` prints a status other than
`UNKNOWN: … is missing`). Design: HIMMEL-6796; on demand since HIMMEL-7201.

- **Every placement into, out of or within the release is a request.** You
  never write a release version's fixVersions yourself. Write the request(s),
  then rule the batch in one call:
  `jira release request <R> --verb INTAKE|REVERSION|DISCHARGE --key <KEY> --from <v|backlog> --to <v|backlog> --why "<one line>"`
  prints `REQ <id>`; a duplicate of an open request returns the open one. Then
  `jira release rm-run <R>` rules every pending request and exits. It takes
  the lease, finishes any older ruling, claims, makes one bounded model call
  (through `scripts/api-lane/claude-api.sh`, so it bills API credit: lane on and
  account `auto` unless you set them, no tools, one turn, JSON out; a refusal
  or a failed call sends one Telegram alert and re-runs once on the subscription behind the usage
  preflight, unless `HIMMEL_API_FALLBACK=off`, see `docs/internals/api-lane.md`), rules
  and applies each request through the engine, releases the lease, and prints
  one line per request. An empty queue prints `RM-RUN <R>: nothing pending`
  and writes nothing.
- **The batch reads only disk.** Anything the RM must weigh goes in the
  request's `--why` or in an operator `O-` record; nothing said in a message
  reaches it.
- **A worker's FINDING that asks "file it where?"** is a request. So is a
  follow-up you file yourself: file it to backlog, then request its INTAKE.
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
  `jira release operator decision <R> --decision <n> --keys <k1,k2> --op add|remove|move|keep|discharge --from <v|backlog> --to <v|backlog> --verbatim-file <f>`.
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
  or the state read failed; repair the wiring/read, not the lease. An empty queue,
  no declaration, explicit `release: none`, or an unreadable doc shows no field.
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
  tick's RM drain it, then file the next. `proposed-*` is not proof of a request:
  those keys remain candidates; the request CLI deduplicates matching pending
  requests. The RM still decides version versus backlog; no fixVersion is written
  by this tool and there is no bulk override.
- **STATUS, BURN-DOWN and READY** remain release-manager verbs, run by an
  on-demand session armed from `docs/handover/rm-brief-template.md` only when
  you need one of them. That session does the verb, reports, releases the
  lease and wraps.
- **The board's release manager panel** (`board.mjs`, from the `release:`
  line) shows M4 burn-down per version, the leaks and the M1 trend; a leak (`leaks:` non-empty) is a mismatch to request a ruling
  for, never a number to manage down. No line is a count gate (decision 104).
