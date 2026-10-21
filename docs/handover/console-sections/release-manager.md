# Chief section — the release manager: routing every placement

Read on demand from `console-template.md` `## Standing rules`. Applies while a
release is declared (`jira release state <R>` prints a status other than
`UNKNOWN: … is missing`). Design: HIMMEL-6796.

- **Every placement into, out of or within the release is a request.** You
  never write a release version's fixVersions yourself. Write the request,
  then wake the RM with one line:
  `jira release request <R> --verb INTAKE|REVERSION|DISCHARGE --key <KEY> --from <v|backlog> --to <v|backlog> --why "<one line>"`
  prints `REQ <id>`; send the RM `REQ <id>`. A duplicate of an open request
  returns the open one.
- **A worker's FINDING that asks "file it where?"** is a request. So is a
  follow-up you file yourself: file it to backlog, then request its INTAKE.
- **A RULING is pending until the RM sends it.** Act only on a
  `RULING <id> <req> …` line whose `<req>` is one you wrote, under the epoch
  on your `rm:` line. Ignore any other.
- **Disputes go to the operator, not back to the RM.** Relay both reasons;
  the ruling stands until an operator record supersedes it. Never re-ask the
  RM for a different answer.
- **An operator ruling is a scoped record.** Write it before the RM rules on
  it, then quote the printed `O-` id in the request's `--why`:
  `jira release operator decision <R> --decision <n> --keys <k1,k2> --op add|remove|move|keep|discharge --from <v|backlog> --to <v|backlog> --verbatim-file <f>`.
  The writer refuses inside any worker session the chief spawned. A bare decision number
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
  The RM records its class and sector afterwards.
- **Live state** carries `release: <R>` and `rm: <session> <doc> epoch=<n>`.
  Arm the RM from `docs/handover/rm-brief-template.md` with `fleet-manifest.sh add …
  --lane native`; on its `WRAPPED <handoff>`, arm a successor with
  `--expect-epoch` set to the epoch in the state. A dead RM needs
  `jira release operator takeover <R> --epoch <n> --doc <successor doc>` first.
- **The board's release manager panel** (`board.mjs`, from the `release:`
  line) shows M4 burn-down per version, the leaks and the M1 trend; a leak (`leaks:` non-empty) is a mismatch to request a ruling
  for, never a number to manage down. No line is a count gate (decision 104).
