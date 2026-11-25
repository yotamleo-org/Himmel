# Chief section — the event waiter (ACTION ZERO step 10)

Read on demand from `chief-template.md` step 10. `<kit>` is the kit path in step 7. Moved verbatim from the template.

Stream mode (`--stream`) is implemented but production activation awaits the
parent's native Claude Monitor proof. Once approved, arm the step-10 command
with Monitor `timeout_ms: 1800000`, `--workers-from <manifest>` and
`--since <last WAKE# seen>` (or `prev-arm` when unsure). The same supervisor
services pending READY/cleanup through worker-event between full ticks and
continues while the chief is busy. It reconciles existing READY at startup;
replay never authorizes a second GO. Ambiguous exact-head GO delivery requires
chief reconciliation before any resend.

`WAKE#<seq>` names the saved block in `out=`; service continues while you
handle it. A WAKE may add an `absorbed since last wake:` wraps/merges line.
Dispatch and wrap reload the manifest: no re-arm.

Read each `out=` block. `REPLAY seqs=a-b n=k index=<file>` lists retained wakes;
`GAP` means the requested range was rotated away or the log reset: reconcile
that range. `W` rows record wakes, `P` rows record printing, and `D`/`K` rows
record an external delivery assertion and acknowledgment. Monitor offers no
automatic delivery receipt. After actually receiving a block, acknowledge with
`chief-wait.sh <inbox> --ack <seq> --receipt <delivery-reference>`. The live/next
supervisor consumes that request; it closes only chief notification actions
named by the block, never proof or source step decisions. Operator digest
actions close only after the existing chief-route `--owed` sender records a
Telegram `DELIVERED` receipt. Queue/drain success is insufficient; failures
stay open and retry on a bounded cadence.

Acknowledgement failures emit `waiter-error kind=ack-stuck` with the request
path and next retry time. This supervisor remains live: do not arm a second
one for `ack-stuck`. Requests persist across restart and retry after
30 seconds, doubling to at most 30 minutes; another queued acknowledgment
can still proceed. After repair, settlement takes at most the remaining
30-minute backoff plus one service pass. To retry sooner, preserve a copy of
the named `.json.retry` sidecar for diagnosis, then remove only that sidecar;
the next pass retries the existing acknowledgment. Corrupt/unreadable retry
state stays untouched and is named for explicit repair, with one warning per
request streak. Never close proof or source debt to suppress a warning.
An uncaught supervisor failure emits `waiter-error kind=supervisor` and
`REARM`; the owned child retains its watchdog/adoption bounds. If the same
fault recurs within five minutes, the arm ends with
`STOPPED reason=supervisor-repeat`. Unwritable supervisor fault state ends
with `STOPPED reason=supervisor-state-unwritable`. Reconcile the named state
before manually arming again; neither terminal outcome requests an automatic
re-arm. A malformed wake row stays for reconciliation: its first supervisor fault
emits REARM; a repeat within five minutes emits STOPPED reason=supervisor-repeat.
Repair the persisted state before re-arming after that stop; no row is discarded.

Owed operator sends reuse a stable outbox identity for the chief, document,
owed key and part number; conflicting content under that key is refused.
The raw owed text binds its content hash; mirror titles cannot change the
first enqueue's frozen parts. Only matching send receipts for every part
permit `DELIVERED`; unrelated replies never count. Service passes enqueue or
reconcile without waiting for the poller, with at most one send helper per
pass (two-second helper timeout). Receipt-only checks run each pass even
during send backoff. Ordinary in-flight delivery gets a 30-second grace
(`CHIEF_WAIT_OPERATOR_GRACE_SEC`); after that, pending debt wakes/reminds on
the existing notification cadence. Enqueueing alone never discharges debt.
Part i waits for part i-1's receipt. Failed/corrupt requests retain their
state for reconciliation while unrelated owed and ordinary replies proceed.
Ordinary replies preserve their own order, with local completion markers
preventing repeats while an earlier owed row remains unreceipted.

`REARM` requests the next stream arm. `STOPPED` is terminal; resume manually
only when intended and after resolving any named fault. `STREAM-REFUSED`
needs its refusal resolved; `live-supervisor` means keep the existing arm.
Inspect a `waiter-error` without arming again while its supervisor is live. A normal
`WAKE#` needs no re-arm, including a succession or relay-on-live block whose
legacy tail says to re-arm: the supervisor performs that relaunch and removes
`--succession`. Never mix a bare waiter into stream mode; `child=busy` requires
a stream arm to adopt the bounded child. `reason=repeat|rate` requires handling
the repeating cause first. A mistaken second arm is refused.
`waiter-error kind=hung` means the busy/orphan bound killed a stuck child;
inspect its saved output and step before re-arming.

Worker documents with read failures emit one actionable
`waiter-error worker-doc-unread` per unread streak, while healthy peers
continue. Repair the named document; a successful read resets that warning.
Handled READY identity follows the READY-event prefix, so atomic rewrites,
retitles and other prose edits do not replay it. First observation and genuine
READY replacement select the newest head; subsequent READY appends keep order.

To stop normally, touch `<inbox>.wait.stop`. The supervisor waits up to 60 s
for a safe point, prints `STOPPED`, and removes the request. A busy child stays
under its bounded watchdog until adoption or a safe stop. `TaskStop` is the
hard stop: native Monitor may kill the whole tree within about 2 s, including
a step in progress. Printed/partial blocks remain replayable; a kill between
an action's marker and its print retains the existing loss window. Session-end,
Remote-Control-only delivery and this adapter's runtime survival/receipt proof
are still owed. Offline fixtures do not establish them.

Per-field policy is `chief-wait.sh --rules` (`wake-rules.tsv`): station BEHIND
entry and 60-minute reminders, CLI repair-off states with the persisted remedy,
RM queue older than twice its launch gap, and `mon-down` once per down streak.
Open-count/residual-cap and persistent underfill retain their existing semantics.
`rm-blocked=` is a plain key field: one wake per distinct set of blocked unfinished
rulings, `?` keeps the last known set, and the wake is the shared `WAKE tick` line
naming it in `changed=` with the tick line after it. Like every key field it is
silent on a waiter's baseline: with no saved key, or a saved key taken under different
tick args or manifest worker set, the first sample only records what is on the line,
so a chief that starts or takes over reads the tick line for `rm-blocked=` (the
release-manager section, "A blocked ruling wakes you").
The detailed one-shot behavior below remains the default without `--stream`.
In one-shot mode a printed `WAKE owed-actions` also leaves its notification
open: after receipt the chief acknowledges with `owe.sh close --bucket <bucket>
--id <id> --key <delivery-reference>`.
The persisted notification observation marker suppresses immediate re-arms;
new notification ids wake immediately and pending debt reminds after 60 minutes
(`CHIEF_WAIT_NOTIFY_REWAKE_MIN`). Stream notifications use the same reminder
interval. Observation does not assert receipt or discharge any obligation.

On startup or document replacement, the stream collector selects only the
newest READY per worker; normal appended READY entries retain their order.
Unreadable worker documents are diagnosed in `<inbox>.wait.pending-diagnostic`
without stalling healthy workers. A manifest/cursor failure wakes once per
continuous failure streak, resetting after a successful read.

Printed replay advances the next `REARM since=` cursor. Replay indexes are
arm-scoped: the current and preceding advertised indexes remain available;
older indexes are pruned on a new arm. Read the current index before re-arming.
Retained wake rows/blocks still govern replay and `GAP` reconciliation.

10. **Start the event waiter now** (it replaces the `tick` and
    `telegram` Monitor loops). Loops are pure code, never model turns: a
    `Monitor` arm is capped at 30 min, and every expiry woke this full-context
    session only to re-arm it. Instead, run `chief-wait.sh` **once** with the
    **Bash tool's `run_in_background: true` AND `timeout: 7200000`** — both
    are required: the default background limit (30 min) killed a waiter once. Never add `&`, `nohup` or `setsid` to the arm: the harness wakes you only when this command exits, and the guard refuses a detached arm. The harness re-invokes you when the command exits:
    `bash scripts/handover/chief-kit/chief-wait.sh "<inbox>" --doc "<this file>" --token <your token> --workers-from "<manifest>"`
    (everything after the inbox path is passed to `tick.sh` unchanged). It is
    silent while nothing happens and **exits on an urgent event or a due
    housekeeping digest**, printing one block: `WAKE telegram` plus the operator's line(s), or
    `WAKE tick changed=<fields> usage=<verdict>` plus the tick line, or
    `WAKE budget-recovered from=<word> usage=PROCEED` once when the last decisive usage verdict flips from `SKIPPED-BANK` or `SKIPPED-FLEET` to `PROCEED`, a reset included (a `BANK-STALE` or `BANK-UNKNOWN` read in between counts for neither side); live workers on the `--workers-from` manifest were nudged, one token-free bus record each (`budget-nudge.sh`, one `BUS-NUDGE` / `BUS-NUDGE-FAIL` / `UNRESOLVED` line per worker under the wake): confirm each one resumed, and relaunch or message any that did not, or
    `WAKE underfilled capacity=UNDERFILLED:<slack>` (with `dispatchable=<n> keys=<KEY>,...` when the count is above 0, on this wake and on `WAKE pool-unresolved` alike, and ` backlog=unread` when the second pass failed, which then never prints `dispatchable=0`; `dispatchable` is one meaning in the tick and the waiter: the LOCAL, CLOUD, RESUME and DESIGN rows of the pool and a series' tickets (`tick.sh --pool-dispositions` prints them as `# pool-dispatchable <KEY>`), so a pool of only RESUME rows reads above zero; parked rows stay in that count and are named by `# pool-parked <KEY>` (`# pool-chief-owed <KEY>` when the line names a proof, signature, critic round or go code), and the tick carries `pool-parked=<n>`, `chief-owed=<m>` and `supply=SHORT:<free>` beside `capacity=UNDERFILLED:<slack>` when fewer unparked rows than slots remain; a short pool runs the second pass only when no release is declared (no `# dropped from <version>:` line): a declared release offers no row of another version, and the wake prints `# rows left in <version>` with a `# pool-left-out <KEY> <reason>` line for every other open ticket of that version; a carried `pool-disposition:` line does not silence this wake while the pool lists a row: those keys are the set to dispatch or disposition from a fresh read, never a carried pool list; when the version's readiness record (`release/<version>/readiness.jsonl`) holds a live c or d row, this wake and `WAKE pool-unresolved` print `# readiness rows in <version>` after the unresolved lines, then one `# readiness-held c|d <KEY> blocker=<blocker|-> age=<age>` line per row, and no wake fires because of those lines; `next-dispatchable.sh --doc <doc> --workers-from <fleet manifest> --why` prints a `# why <KEY> listed <lane> tier <n>` line per key, and without `--priority-pool-only` it can list keys the wake lacks when more tickets qualify than free slots (it lists up to 50 rows when no `--top` is given); on the streak's first sample, and again once each time the pool's key set changes: it is re-probed every 30 min, `CHIEF_WAIT_UNDERFILL_REPOOL_SEC`, each probe cut at `CHIEF_WAIT_REPOOL_TIMEOUT` (120 s), and a pool that grows from empty counts, while a pool that empties or a failed probe does not wake; plus the tick line and `next-dispatchable.sh --priority-pool-only`'s
    ranked list (the pool: the `priority:` line in Live state, labels `ps3-blocker` / `must-<current version>` (the earliest unreleased version) / `operator-directed`, High+ bugs, security and data-integrity; per tier its `RESUME` rows, In Progress with no worker and no open PR, lead the To Do rows, only when a worker source (`--owners` / `--workers-from`) is given, and they are kept in `--priority-pool-only` by design (operator decision 29: drain In Progress work with no worker first): the waiter passes its own `--workers-from` file when it was started with one, and no `--owners`;
    a closing `# pool=<rows>/<slack>` line, `,LOW` when the pool fills fewer slots than the slack, and `POOL-EMPTY` when it has nothing, followed by the next tier (tier-4 To Do rows in rank order) as `NEXT-TIER` rows: then unblock collisions, draft specs for the next priority items, or fill from the NEXT-TIER rows when the operator has ruled so); dispatch it with `gen-briefs.py`; both refuse Windows/WSL work per `chief-kit/platform-dropped.re` unless the ticket is labelled `windows-removal` / the worker sets `platform_removal` and its title says remove/drop/delete/retire/sweep/clean), or
    `WAKE tick-usage rc=2 <line>` on the first sample whose tick exited 2, never batched: the status check
    refused a flag the arm line carries, so fix the arm line, then re-arm,
    `WAKE tick-fail samples=<n>` when 3 samples in a row failed (the tick or
    the usage read is broken: fix it, then restart the waiter; it wakes once per
    failure streak; look-only, so it joins the housekeeping digest and rides the next
    wake as a `look-only since last wake:` block, as do `unowned-prs` and a prs-only tick change),
    or, on a successor's first arm only (ACTION ZERO step 9,
    `--succession <your session> [--silent-min T]`), `WAKE succession complete
    <k/n>` plus the printed LIVE bullet command when every inherited worker's `SUCCESSION
    accepted` bullet is in, or `WAKE succession partial <k/n> silent <T> min`
    naming the workers still out. Both are informational (LIVE went on the
    predecessor's `RELAYED` line). Each fires once; **re-arm without `--succession`**
    (a re-arm that keeps it after a complete wake stays quiet). An outgoing
    chief using `chief.sh next` (relay-on-live by default unless
    `--no-relay-on-live`, and it needs `--doc`) gets `WAKE relay-on-live
    successor=<session>`, then `relay-batch.sh`'s SENDMESSAGE lines and its
    closing `RELAYED <n> of <m>` line, once the successor's lock is held fresh;
    send each SENDMESSAGE line first (n counts them), then the `RELAYED` line to
    the successor, naming every worker still unrelayed. A batch that fails or
    times out wakes `relay-failed rc=<n>` with its partial output and no
    `RELAYED` line, and is never re-run. On `relay-failed`, relay by hand every worker with no `BUS-RELAY <label> ok` or `SENT-INBOX` line,
    then send `RELAYED <n> of <m>` yourself (n the delivered lines). Once the successor validated, `<your inbox>.handover` mutes
    your waiter for `CHIEF_WAIT_HANDOVER_MIN` (default 60); `rm` it to end the
    mute early. It runs `tick.sh` every
    180 s and wakes only when two consecutive samples differ from the action
    key you last saw: `workers=` (a worker FRESH → STALE / FREE / WRAPPED …),
    `livestate=` (DRIFT / MALFORMED), `prs=` (the repo's open-PR set — any
    PR opening or merging, yours or not), `orphans-wip=` (an In Progress /
    In Review ticket nobody holds — no worker, no open PR: dispatch it as a RESUME
    row of `next-dispatchable.sh`), `tails=` (a worker's marker: FINDING, READY …),
    `workerset=`, `dispatch=` (a workflow_dispatch run a worker started by hand that is `late` past
    80 % of its job timeout, `idle` with no job changing state for 30 min, or `orphan` because
    its worker wrapped: the wake is `WAKE tick changed=dispatch` and the tick line carries one
    `ACTION dispatch-stall <run> <worker> (<branch>): <reasons>` line per run; look with
    `gh run view <run>`, cancel it or tell the worker. Elapsed time, job counts and `stale-head` never
    wake, and a run leaving the set does not), `owed=` (the `ACTION owed-stale=<n>:<ids>` count of keyless
    ticket rows of the owed ledger past 4 h and keyed steps past their due date until the step-due wake is delivered: the wake is `WAKE tick changed=owed` when that count rises;
    the age, an open row that is not stale and a row closed with a key never wake, and `owed=?` keeps
    the saved count; see `owed.md`), `board=` (its class — the STALE age alone does not wake, and a
    move TO `ok` never wakes on its own either, since that's just the chief's
    own render; the key still saves, so a later move to STALE/MISSING wakes
    again) and the
    `usage-preflight.sh` verdict word. Heartbeat, procs, fill, fleet, gql and
    orphans never wake (`capacity=` wakes only through `WAKE underfilled`). An idle chief therefore takes **zero** turns.

    **`WAKE doctor <new ids>`**: the tick runs `himmel-doctor.sh`
    about every 30 min (cached; `TICK_DOCTOR_TTL_MIN`, 0 = off) and reports the
    WARN/FAIL check ids as `doctor=<id,id>`. The waiter wakes only when that set
    gains an id it has not shown you, naming just the new ones; an unchanged or
    shrinking set never wakes, and an id that leaves and comes back wakes again.
    `doctor=?` (the doctor failed with nothing cached) keeps the saved set. A WARN
    usually means a real issue, so work each new id the turn it wakes you: **fix
    it, ticket it, or record a ruling** that it is acceptable. Never leave it
    unread because the next wake will not repeat it.

    **`WAKE cadence <workflow> run=<id> <RED|SKIP|MISSED> <run url> cause: <why>`**: the
    tick reads the last *scheduled* run of every workflow with a `schedule:` trigger (about every 30 min,
    cached; `CI_CADENCE_INTERVAL_SEC`) and prints them as `cadence=<name>:<state>:<age>:<run id>[:flag],...`.
    The waiter wakes once per run id that is RED (failure or timed_out), SKIP (concluded skipped) or
    MISSED (no scheduled run inside 1.5 periods), with the run link and the first failing job and step.
    The first sample is a baseline, so a run that already finished never wakes you, and a re-armed
    waiter replays nothing (`<inbox>.wait.cadence`). `cadence=?` (gh unreadable) wakes nothing. A red
    here is yours to triage: open the link, fix or ticket it, never leave it for the next wake.

    **`WAKE review <date> <reasons>`** (decision 593): the tick prints the daily failure
    review as `review=<date>:<age>:<failures>:<new>:<new5+>:<filed>[:STALE]` (`none` is left off
    the line). The waiter wakes once per review day when the router filed a ticket or a new class has 5 or
    more failures, and once per last-review date when the review is STALE (no
    review for 26 h). A class with a single failure never wakes you (`<inbox>.wait.review`).

    **`WAKE rm-intake INTAKE=<n> since=<h>h capacity=UNDERFILLED:<m>`**: with `--doc` whose
    `release:` line names a release, the tick's `INTAKE=<n>` (versionless work outside the pool) has stood
    above 0 for more than 6 h (`CHIEF_WAIT_INTAKE_ARM_HOURS`) while the fleet is UNDERFILLED. The next line
    names the `rm-run` command: file each INTAKE key, then run the pass; the waiter launches nothing. The
    clock is `<inbox>.wait.intake` and resets when INTAKE returns to 0. One wake per 6 h
    (`CHIEF_WAIT_INTAKE_REWAKE_MIN`), none while the release manager lease is held or unreadable.

    **`WAKE rm-refused <KEY>@<ruling> — fix: <reason>`** and **`WAKE rm-refused-digest <n> new: <KEY>@<ruling>,...`**:
    with `--doc` and the tick's `rm-refused=` field on the line, the waiter reads the tick's
    `rm-refused-<doc stem>.tsv` (KEY, ruling, reason, asks_operator) from `$TICK_STATE_DIR`. Each new
    operator-asked pair wakes you once, one line each, with the ruling's reason cut to 200 characters; the
    other new pairs arrive as one digest a day (the first 20 listed), never sooner. A pair whose operator status
    reads `?` (the mirror does not hold the key) waits, neither woken nor digested, until a tick knows it; a tick
    whose mirror is unreadable prints no `rm-refused=` and keeps the last tsv. The marker
    `<inbox>.wait.refused` holds the pairs already reported and keeps only those the tsv still lists;
    `<inbox>.wait.refused.day` holds the digest's UTC day. A line without the field reads nothing.
    Act on it as release-manager.md says: ask again with the operator's words, or ack a right refusal.

    **`WAKE relaunch-owed <PR> <resume doc>`** (one line per entry, then the tick line): a HELD `queue:`
    entry's trigger fired (`live-state.md`: `wake=pr:<n>` merged or closed, `wake=done:<KEY>` Done,
    `wake=file:<path>` present), read from the tick's `relaunch=`. Relaunch the worker from the resume doc,
    then take the entry off the `queue:` line. It wakes once per entry under `<inbox>.wait.relaunch`
    (again after `CHIEF_WAIT_RELAUNCH_REWAKE_MIN`, default 60, while the entry stays); `relaunch=?`
    (a failed read) keeps the marker, and `relaunch=none` or no field clears it.

    **`WAKE pool-stale <KEYS>`**: the tick re-checks every Live-state
    `pool-disposition: KEY slice|close|question|hold|park <target>` line whose target names a
    ticket key of the mirror's project or `PR <n>` and reports `pool-stale=<n>:<KEY>,...` when every named
    blocker is Done (Jira mirror) or its PR merged or closed, or when its hold line's wake fired or it waits on
    an outside PR (below). The PR states come from the pool-holds file, filled by one GraphQL
    query that names exactly the cited PR numbers, however old, on the read token; a wave label such as
    `ZA-1` is text, not a ticket. `?` in the list marks a target it could not read (an issue number, a
    number GitHub cannot resolve, a failed read), never a stale one. `tick.sh --pool-stale --doc <doc>`
    also prints one `STALE-DISPOSITION <KEY> line=<hash> <target>=<state> ...` line per stale key,
    naming every target of the line, so you can see what is gone. End a ruling with
    `@<sha>`, the head you ruled at: once origin/main is more than
    `TICK_POOL_MAX_MERGES` (30) commits past it, the line is stale whatever its blockers say,
    so a ruling copied forward from a predecessor expires; an unknown sha prints `?`. The waiter wakes once
    per newly stale key (marker `<inbox>.wait.stale`; the tick prints `pool-stale=0` on
    every compact line that read a doc and found nothing stale, and that explicit `0`
    clears the marker, so a key that leaves and comes back wakes again; an absent or `skip`
    field, `?`-only, or a partial read like `1:KEY,?` keeps it and never shrinks it).
    A `pool-disposition:` line counts as handled only when its target starts with a reference: another ticket
    key of the project, `PR <n>` or `decision <n>` (optionally after `operator`, `waits on`, `blocked by` or `after`). The
    check is reference-shaped: it does not read the ticket, PR or decision, and there is no ask-record form because no store
    exists. A worker counts only through the dispatcher's own reason (`owned by` or `held by worker <name>`), so a made-up
    `N<n>` in a target is refused. A free-text promise ("will look at it after the release") stays in the pool as
    `# pool-unresolved unowned <KEY> ...`; the tick still prints and never fails on it. When the tick cannot read the pool at
    all, the wake says `backlog=unread` instead of `dispatchable=0`.
    A live c or d row for the key in the version's readiness record counts as a ruling too: the key leaves `# pool-unresolved`,
    and the wake lists the record's rows under `# readiness rows in <version>` (`# readiness-held`), so a ruling that outlives
    its chief stays in view.
    A stale key (every target gone, per `pool-stale=`) is `# pool-unresolved stale <KEY> its pool-disposition target is gone: <targets>; ...`
    until the line is rewritten, unless the key is owned, held or blocked (the line is then not its only reason); a failed or
    paused read keeps that verdict while the line is unchanged and no target reads open, so the wake fires once, not per read.
    A changed key (its open parent ticket merged since the line was written, per `pool-changed=<n>:<KEY>,...`) is
    `# pool-unresolved changed <KEY> <target> merged <sha> since the line was written: re-read and stamp (<LL> <MM-DD> <HH:MM>Z)`
    under the same rules. The tick compares first-parent merges whose subject carries `[<target>]` with the line's anchor,
    the later of its `@<sha>` commit time and its newest `(<LL>[-n] <MM-DD>[ <HH:MM>Z]` stamp (the year from the date
    in the doc's file name); `tick.sh --pool-stale --doc <doc>` prints one `CHANGED-DISPOSITION <KEY> ... via <target> <sha> <subject>`
    line per changed key, naming the newest merge, while the unresolved text names the oldest, so further merges do not
    wake you again. The bracket is printed as written, never filled in. Clear it by re-reading the line and adding a timed
    stamp, `(<LL> <MM-DD> <HH:MM>Z re-read)`, dropping any `@<sha>` the line carries: the line's hash changes, so the old
    verdict goes at once, and a timed stamp never expires. Re-stamping with `@<sha>` is not the way: it starts the
    `TICK_POOL_MAX_MERGES` expiry, and main takes about 80 merges a day. A failed git read keeps a changed verdict
    while the line is unchanged and its parent is not Done.
    The line is never rewritten:
    re-rule it (dispatch the held ticket, or write a fresh `pool-disposition:`),
    then the key leaves the field. The tick also prints
    `residual-unversioned=<n>:<KEY>,...` (open residuals of an open focus-version
    ticket with no fixVersion, other than a To Do ticket below High whose latest release ruling is a backlog ruling, invisible to every version count): it never wakes;
    give each a fixVersion or a disposition.

    **Hold lines (`pool_holds`).** In a bucket that declares a release, a give-up line needs the
    operator's words or a near wake the tick checks:
    `pool-disposition: <KEY> <verb> <free text> [authority=<ref>] [wake=<event>[,<event>...]] [@<sha>]`.
    A give-up line is a `question`, `close`, `hold` or `park` line, or a `slice` naming no key, PR or `@sha`,
    on a pool key or on a key of `asks_operator_keys` (other off-pool keys stay invalid; a `slice` with a
    target keeps the rule above).
    - `authority=O-<R>-<nnnn>` or `authority=decision-<n>` is valid only when a words record (`words: 1`,
      or the high-admit record) of the doc's `release:` names the key, and for `decision-<n>` carries that
      decision. A decision file alone, or a legacy O- row, is not authority.
    - `wake=pr:<n>` (or `pr-<n>-merge`) fires when the PR merges or closes and is valid while it is open;
      a PR GitHub cannot resolve is invalid, a failed or paused read is unchecked. `wake=done:<KEY2>` fires
      when KEY2 is Done and is valid while an open PR's head branch or a worker names it, or it is in the
      current version. `wake=date:<YYYY-MM-DD>` (or `<YYYY-MM-DDTHH:MMZ>`, UTC) is valid at most 7 days
      ahead; a later date is a park and needs authority. `wake=file:<path>` fires when the file exists and
      is valid only as an absolute path under the handover root or `TICK_STATE_DIR` with no `..`. A list
      fires when any event fires.
    - Counting, in order: any invalid part makes the line `invalid` (with the reason); a valid authority
      dispositions it; a valid wake that has not fired dispositions it; otherwise it is unhandled,
      `no-authority` (`unchecked` when an input could not be read). Each shows as
      `# pool-unresolved <class> <KEY> <reason>: <line>`; none of them fails the tick.
    The tick runs `tick.sh --pool-holds --doc <doc>` under the pool-stale lock, before `pool-stale=`; it writes
    `pool-holds-<doc stem>.json` in `TICK_STATE_DIR` (rows with class, reason, words, `fired`, `outside`
    and the age, and the PR state map) and nothing else, and `--pool-dispositions` (the tick's and the
    waiter's) and `--pool-stale` read it. A missing holds file, or one over 30 minutes old, reads every
    give-up line `unchecked`: never an all-clear. With no release declared in the bucket (`release: none`,
    or no `release/*/release.json`) the lines keep the rule above and the tick prints
    `pool-holds=off:no-ledger`; a doc with no `release:` line in a bucket that declares one reads its give-up
    lines `unchecked`.
    Stale causes: a line whose wake fired (`wake=<event>=fired`), or that waits on an outside PR
    (`isCrossRepository`) with no manifest `watch` row (`outside-PR=unwatched`), is stale, one wake per
    newly stale key.
    Lineage age: the step appends to the shared `pool-lines.tsv` when a stem's set of give-up lines
    changes. A line's `age_gen` counts the consecutive stems of its lineage (the stem after
    `HIMMEL-nextleg-<date><gen>-`) that carried it; another lineage never resets it, and stems unseen for
    14 days are pruned. `age_days` is the time since its first-seen stamp. `tick.sh --pool-holds --seed-age
    <list of docs in order>` seeds the file from old docs, stamped with each doc's filename date. Blocked on
    you (the board and the tracker) shows every unhandled line with its age, every line held on authority
    with the operator's words, and a `pr:` or `done:` hold once `age_days` reaches 7.

    **Housekeeping digest.** Board class changes and `board-stale`,
    `status-sweep`, and informational `tails=`/`acts=` changes to LIVE, ACK,
    WRAPPED or MERGED wait in `<inbox>.wait.housekeeping`. The first buffered
    event starts a `HOUSEKEEPING_DIGEST_SECS` window (default **900 seconds**).
    When it ends, one `WAKE housekeeping kinds=<sorted kinds>` block carries
    the buffered `<kind> <detail>` lines. `HOUSEKEEPING_DIGEST_SECS=0` disables
    batching and preserves the original wake lines. An urgent wake leaves the
    buffer and its original deadline intact for the next arm; a due digest can
    still emit when a tick fails. Handover mode mutes the digest with the tick.
    **Telegram, actionable worker events (including READY, FINDING and BLOCKED),
    succession, and handover-budget remain immediate**; a new actionable worker
    marker bypasses the two-sample debounce. Unknown marker changes are never
    treated as housekeeping. Handover-budget repeats are unchanged.

    This is digest-only: the waiter still exits on WAKE. Persistent delivery and
    tick-side suppression of changes authored by the chief are deferred to
    the ticket for keeping the chief waiter armed across events; no authorship is inferred from worker marker text.

    **Re-start it at the end of the turn that handles each wake** — the waiter
    has exited, so a turn that does not re-start it leaves you deaf to Telegram
    and to the tick. Start it in the same turn as your other work, never as a
    turn of its own. A re-start with changed tick args (a dispatch or wrap
    changed `--workers`) takes a silent baseline instead of waking you for your own
    act. Worker messages (`SendMessage`) wake you on their own; only the Telegram
    and tick paths depend on the waiter.

    **Verify it is live** — record in your first bullet the background task id
    the Bash tool returned, and read the heartbeat next to the inbox:
    `cat "<inbox>.wait"` → `hb=<epoch> pid=<pid> key=<hash> tick=ok state=waiting`,
    rewritten every second between samples. `state=sampling` is a tick in
    progress: a sample (tick, then usage) can take about 4 min (twice the 120 s
    timeout, plus a 5 s kill grace each), and a Telegram line waits for it. The
    wrap relay refreshes the heartbeat before each `worker-event.sh` call (up to
    245 s including kill grace). It attempts at most one wrap per sample before
    servicing the inbox; later workers wait for the next sample. This keeps each
    relay call under the heartbeat consumers' 300 s floor. `state=exited
    exit=<reason>` is a waiter that stopped (`wake-telegram`, `wake-tick`,
    `signal-TERM` …); a `state=waiting` or `state=sampling` heartbeat older than
    about 5 min is one that was SIGKILLed (untrappable). `tick=fail` means `tick.sh` exited
    non-zero or produced no TICK line (it runs under a 120 s timeout, so a hung
    tick cannot hold the Telegram path forever). A second waiter on the same
    inbox is refused (exit 3, naming the live pid). Measured: a
    background task that exits, or that is SIGKILLed from outside, re-invokes
    the idle session. **Not reproduced:** the harness-internal "low memory" kill
    of a background task — a waiter lost that way is visible only
    as a stale heartbeat; a bridge-side stale-heartbeat
    alert is a planned follow-up.

    **Re-start the waiter on every dispatch and every wrap, with absolute worker
    doc paths**: stop the running one with `TaskStop` and start a
    fresh one. The tick judges only the workers `--workers` names; a worker you
    dispatched after starting it is not in it. The tick says so rather than
    guessing: `workerset=STALE:unarmed=<worker,…>` (in `## Live state`, not in the
    arm) and `procs=<n>,unwatched=<worker,…>` (a live worker the arm does not
    name) both mean **your arm is out of date, not that a worker is in trouble** —
    re-start with the current worker docs. `workerset=STALE:…;unlisted=<worker,…>` is the
    reverse: an armed worker that is no longer held and not in `## Live state`,
    i.e. a wrapped worker to drop from the arm. `unwatched=` reads the whole
    process census, so with more than one chief on the host it can name
    another chief's workers. `tick.sh`'s own `tick=` field still reads `UNKNOWN`
    (see its ceilings-ledger row); the heartbeat above is the liveness signal.

    **Or arm from a fleet manifest and skip the re-starts**:
    keep the worker set in `<this file's stem>.fleet.json` next to this doc and
    start the waiter with `--workers-from "<that file>"` in place of `--workers`.
    On each dispatch run `bash "<kit>/fleet-manifest.sh" add "<manifest>"
    "<absolute worker doc>" --lane <lane>` (`--lane` is required: the lane
    the worker was launched on, the same value as `headed-arm-worker.sh --lane`:
    native, claudex, openrouter or deepseek; `relay-batch.sh` relays only native
    and claudex rows); on each wrap, `… remove "<manifest>" <N-label>`.
    The tick re-reads the manifest every sample and the waiter takes a silent
    baseline when its worker set changes, so neither needs a re-start; the
    `workerset=`/`unwatched=` checks above then compare against the manifest.
    Then render the `## Live state` worker entries from it instead of editing
    them: `bash "<kit>/live-state.sh" "<this doc>" [--nonce <N-label>=<nonce>]`.
    It reads each worker's lock token from its held lock and keeps the nonce and
    pid already on the line; a worker not yet listed needs `--nonce` (the nonce is
    yours, never read from the worker or the manifest). A manifest worker holding no
    lock is left out. The rest of `## Live state` is still yours to edit.
    **Your manifest:** `<your manifest>` — <note>.

    **The waiter wraps workers; do not run `worker-event` / `close-wrapped-worker` by
    hand; run any other bounded script as `timeout 90` in the foreground.** Armed
    with both `--doc` and `--workers-from`, the waiter is the script relay (R0): a
    worker whose `tails=` turns `WRAPPED` or whose `acts=` turns `MERGED` is
    wrapped by `timeout -k 5 240 worker-event.sh --doc --fleet` on a line built from
    that worker's bullet, with no wake. The 240 s bound allows a slow close and
    refresh without exceeding heartbeat consumers' limits; tracker/focus work
    that exceeds it escalates. WRAPPED workers with a PR take the wrap path too.
    A Telegram line waits for at most one relay attempt (including a retryable
    refusal) before the inbox is serviced.
    `HANDLED` lands in `<inbox>.wait.digest`; a
    refusal that only means "not yet" (lock still held, tail not yet `WRAPPED`,
    subtree alive) stays retryable. The next sample starts after that worker,
    using an atomically saved label in `<inbox>.wait.r0-next` even after a
    waiter re-arm; a missing or stale label leaves plain candidate order.
    A standing refusal cannot starve later workers. In stream mode it is also paced, so a
    stacked series waiting on a live worker does not read GitHub every few seconds: each refusal
    in a row of the same cleanup event holds that event back longer, the retry window
    (`CHIEF_WAIT_SERVICE_RETRY_SEC`, 5 s) times 1, 2, 6, 24 and 60, that is 5, 10, 30, 120, then
    300 s. The relay owns the count, in `<inbox>.wait.le-<label>.tries` (`<refusals in a row>
    <checksum of the bullet being retried> <checksum of the bullet already woken for>`); the
    collector only reads it. The count belongs to the event, not to the document: a new or changed
    cleanup event (another bullet checksum, for example a WRAPPED after a MERGED) starts the
    ladder over, while the lines a live worker keeps appending do not, so a refusal that persists
    reaches the top step however busy the document is. A restarted waiter reads the same file and
    keeps its step. A file written by the earlier format (count, mtime, size, woke) reads as another
    event, so after an upgrade an event already woken before it is woken once more, at its next
    fifth refusal. The refusal that reaches the top step wakes you once per bullet with
    `WAKE worker-event ESCALATE cleanup-still-refused worker=<label> event=<marker> tries=<n>
    next-try-in=<s>s refusal=<its first line> out=<file>`, and the waiter goes on trying at the
    top pace until the cleanup succeeds or the event changes. A refusal record dated in the
    future (a clock stepped back) is offered, not held. The ladder only spaces the attempts: it
    never closes, wraps, reaps or frees anything and never records the bullet as
    handled. `wrap-merged.sh` also exits 6 or 7 when its own log or board step fails; those run
    after the window is closed and the worker retired, so asking again would find nothing and
    the failure would be lost. They wake at once instead, with `wrap-merged: step log failed` or
    `step board failed` in the line: finish by hand (`wrapping.md`). A refused close inside the
    wrap (`step close-wrapped-worker failed`) stays retryable. Anything else wakes you once per
    bullet with `WAKE worker-event <its first non-blank line> rc=<n> out=<file>` plus the
    tick line. A silent timeout writes `ESCALATE relay-timeout <label> rc=<n>
    limit=240s` to both the wake and the out file; another silent failure names
    `relay-failed`, its label and rc. Read the out file and finish that wrap by hand
    (`wrapping.md`). Every WAKE block
    ends with `absorbed since last wake: wraps=<n> (<labels>) merged=<n> (#<pr>,…)`, plus ` auto-go=<n> (#<pr>,…)` for scripted GOs,
    when the relay absorbed anything (labels and PR numbers only), and the
    digest starts over. The relay takes no lock and sends nothing to a worker;
    the chief keeps every authority write (GO, judge, dispatch, Jira).

    **How long an event waits, and where to read it.** The waiter is one foreground loop. While a
    sample runs nothing reads the inbox or the worker documents, so an event that lands mid-sample
    is relayed only when the loop is back at its service pass. **The bound stated here covers the
    sample alone**: its two bounded reads (`tick.sh`, then the usage read, each under
    `CHIEF_WAIT_TICK_TIMEOUT`, 120 s plus a 5 s kill grace) allow about 250 s. It leaves out three
    things that add to a wait. First, what the loop does after a sample before it serves events
    again: the focus rebuild after every sample (a status read bounded at 60 s plus a 2 s grace),
    the status sweep when it is due (every 15 minutes by default, 60 s plus a grace, and a second
    focus read), and the chain of wake checks that follows, each under its own bound if it has one
    and several of them reading GitHub or Jira; with the `auto_go` flag off that includes a READY's
    own checks (165 + 30 + 90 s and a 5 s grace each). Second, the events queued ahead: one handler
    call per pass, each up to 245 s. Third, the ticks that interleave between queued events: a due
    tick takes the next turn after a handler call, so a queue can meet a full sample after each
    handler. None of these is added up here, so 250 s is the sample's share of a wait, not the
    whole path. Once the loop is back at its service pass an event waits one poll: 0.2 s while the
    loop is busy, and up to one idle interval (`CHIEF_WAIT_IDLE_POLL_SEC`, 1 s, never below the
    poll) after `CHIEF_WAIT_IDLE_PASSES` (10) passes in a row that offered nothing, attempted
    nothing and ran no tick. The first pass that offers an event, attempts a relay or runs a tick
    goes back to the poll at once; the backoff is in stream mode only and only paces the loop. What a real sample takes is the
    host's: a station's recorded per-tick log (62 ticks) shows a median of about 36 s of wall time
    and a maximum of 104 s. A tick starts every 180 s counted from the start of the previous one,
    so a busy loop answers within a poll, a loop that has been quiet for ten passes within one idle
    interval plus the pass (and starts a tick that fell due within the same), and a loop inside a
    sample after the rest of the sample in progress.
    The master plan's 30-second bar is the bar of the stubbed 50-event test, where the tick is
    instant; it is not a promise about a real wave. The waiter records the real numbers: every
    `worker-event` call appends one line to `<inbox>.wait.relaylog`
    (`start=<epoch> label=<l> marker=<m> pending=<s> handler=<s> rc=<rc>`), also for a refused
    attempt that will be retried; an idle pass writes nothing, and past 1 MiB the file is renamed
    to `<inbox>.wait.relaylog.1`, replacing the older copy. `pending=` counts from the moment
    this waiter process first saw the event, so it does not include the time the event sat unseen
    while a sample held the loop (a waiter restart starts it again); read that part from the
    sample's `wall=` in `<inbox>.wait.ticklog`.

    **A successor replays the newest READY per worker.** The cursors, the handled set and the snapshots
    are per inbox, so a chief that takes over on a new inbox meets every worker as new and relays that
    worker's newest READY once more. That is a repeated message and one more `AUTO-GO` bullet, never a
    second GO: `auto-go.sh` takes `.auto-go-<pr>.<head>.lock`, and when `.locks/go/<pr>.<head>` exists it
    returns the recorded `GO-SENT` without writing or sending anything, or fails closed (`fail 9`, an
    ESCALATE) when no audit row matches. With `auto_go` off, `<inbox>.wait.readywoke` is per inbox as
    well, so the successor is woken once more for a READY its predecessor already woke for; a GO still
    happens only by the chief's hand.

    **A READY wakes you once, already checked**. Armed with
    `--workers-from` and the `auto_go` flag off, a worker whose newest marker bullet
    is `READY <pr> <head40> GREEN` wakes you with one line:
    `WAKE ready <pr> <head40> ready-check=<PASS|FAIL> ci=<GREEN|RED|PENDING|PAUSED> coverage=<PASS|FAIL> disposition=<ok|open:<n>|STALLED> out=<file>`,
    plus the tick line. Before waking, the waiter ran `ready-check.sh <pr> <head>`
    (bounded 15 s above `READY_CHECK_DEADLINE`, 165 s by default), one bounded
    `gh pr checks` read (a failed read is `PENDING`, never `GREEN`; a rate-limit
    refusal is `PAUSED`: ready-check already judged CI) and `cr-disposition.sh check
    <pr> <head>` (read only; `open:?` = it could not evaluate); `coverage=` is
    ready-check's item 7. The line may end in `after-quota=<gate>` (below), so read
    `out=` as a field, not as the last word.

    **At quota out a READY stays unspent.** A READY whose checks cannot read wakes
    nothing and is not recorded: a gate's rate-limit marker stands at its head, every
    GraphQL route reads 0 (the waiter marks the head itself), or a check came back
    `QUOTA-PAUSE`. A check that stalls (`GH-STALL`, its deadline, or killed) wakes
    nothing the first sample and `WAKE ready <pr> <head40> ready-check=STALLED
    out=<file>` (or `disposition=STALLED`) the second: a slow read is reported, never
    hidden. One sample checks one head at most.

    **An underfill wake never rests on a paused pool.** When the dispatcher answers the pool probe with
    `# quota-pause` or `# gh-stall`, or the probe's outer timeout kills it, the waiter wakes nothing, writes
    no pool marker and leaves `<inbox>.wait.poolpaused` (`pool=paused`) until a good probe removes it, so
    the next good reading wakes once. While that file is younger than `CHIEF_WAIT_PAUSED_REPROBE_SEC`
    (default 300) the pool is not probed again. A real empty pool still wakes as before.

    **A gate refused at quota out wakes you once when quota is back.** `go.sh`,
    `ready-check`, `cr-disposition` and `check-ci` leave a marker when GitHub refuses
    or stalls a read (`blocked/<key>.<ref>` under the quota dir). The waiter reads
    them each sample and says nothing while quota is out (the tick's `quota=` shows
    it). When every bucket the marker names reads healthy again, the owning waiter
    (the PR's head is in its `readywoke`, or a manifest worker's READY or doc names it)
    takes it at once and any other 900 s later. If that worker's newest bullet is
    still READY at the head, you get the normal `WAKE ready … after-quota=<gate>`
    with fresh checks: rerun `go.sh`. Otherwise one look-only line rides the
    housekeeping digest: `quota-back <pr|branch-<name>> <head|unknown>
    caller=<gate>`, plus `quota=unknown` when 2 h passed with no good reading.
    Resume the BLOCKED worker or rerun the gate it names. The out file
    (`<inbox>.wait.ready-<pr>`) holds the READY bullet (any note the worker wrote in it: a trust path, suite rows) and the three outputs, tokens scrubbed. Do not
    re-run ready-check or poll CI: read the diff, rule, and GO through `go.sh` or
    `verdict-go.sh` as before, which run their own gates. It wakes once per (PR,
    head) (`<inbox>.wait.readywoke`): the same head written again wakes nothing,
    a new head wakes again. A READY that is not the newest bullet, or does not
    carry a 40-hex head, still wakes as `WAKE tick changed=tails,acts`. Workers
    write READY as a bullet only, never a message.

    **A READY, BLOCKED, FINDING or request no wake named yet wakes you once.** With
    `--workers-from`, a worker whose newest marker bullet is a `READY <pr> <head40>`
    (auto_go on; off, `WAKE ready` above owns it), a `BLOCKED` (not `BLOCKED resolve`),
    a `FINDING`, or any other marker bullet carrying a `REQUEST` word (`PUSH-REQUEST`,
    `JUDGE-REQUEST`) or `QUESTION`, and that no wake of this inbox has named, wakes you with one line
    each, `WAKE worker-ready <label> pr=<pr> head=<head40>`, `WAKE worker-blocked <label>`,
    `WAKE worker-finding <label>` or `WAKE worker-request <label>`, plus the tick line.
    When another wake fires on the same sample, its block ends with these lines too, so
    no other wake folds one away. It catches what the other
    wakes miss: a READY carried across a succession (the relay starts a worker it meets
    first after its existing READYs), one already in the doc at the first sample (a
    silent baseline), and one another wake folded into its saved key; the tick's tails=
    must already show it in the saved key, so a fresh move still wakes as `WAKE tick`, and a READY
    the relay has not yet handed on (past its `.wait.ready` cursor) is left to the relay. A `WAKE tick` on
    that worker's tails= or acts=, a READY the relay handed to worker-event, and the
    earlier wake itself count as named (`<inbox>.wait.markerwoke`): the same head or
    bullet never wakes twice, and a successor's new inbox wakes once more (a tails= move
    never names a request). Read the worker's doc and act as on its message.

    **A manifest row that reads no doc wakes you once per path.** A row whose doc does
    not exist wakes `WAKE worker-doc-missing <label> <path>`; a row naming a `-RESUME`
    brief with no marker bullet, while the original doc beside it holds a newer one, wakes
    `WAKE worker-doc-missing <label> <path> writes=<original>`: that worker writes the
    original, so its markers never reach the tick. `fleet-manifest.sh remove` the row and
    `add` the doc the worker writes; `chief.sh next` re-points such a row when it carries the manifest.

    **A ready-mismatch ALERT wakes you.** The tick's `ready-mismatch=<flagged>/<ready>,nogo=<k>/<judged>,ALERT`
    wakes `WAKE ready-mismatch <value>` plus the tick line when ALERT appears and again
    when the flagged or NO-GO count rises (`<inbox>.wait.readymismatch`; cleared when
    ALERT leaves). `tick.sh --ready-mismatch --ready-dir <doc dir>` lists the rows.

    **A GO'd PR whose worker went silent merges without it**: with `--doc` and `--workers-from`, a READY worker that has had a GO file and no doc write for `CHIEF_WAIT_WORKER_SILENT_MIN` minutes (default 45), and no live process unless its last bullet names its resume brief (`RESUME written: <…-RESUME.md>`) with no FINDING, HALTED, BLOCKED, PARKED-*, WRAPPED or MERGED newer than its READY, is merged by `silent-go-merge.sh` through ready-check at the GO head and `merge-on-green.sh --go`; you wake as `WAKE silent-go` with one `SILENT-WORKER-MERGE`, `-MERGE-FAILED` or `-HELD reason=<why>` line; the operator was already paged with it and your doc carries it as a bullet.

    **A watched outside PR that moved wakes you once.** A worker waiting on an outside event
    does not keep a window open: it writes `LIVE — HOLD-OUTSIDE pr=<n> owes: <what>` and WRAPs
    (the tick flags an idle window left on that bullet as `holdout=<label>:<pr>` and prints the
    command). You record the PR in the fleet manifest and close the window:
    `bash scripts/handover/chief-kit/fleet-manifest.sh watch <manifest> add <pr> --head <sha> --comments <n> --reviews <n>`
    (the values the worker last saw, plus `--state open|closed|merged`; `--repo owner/name` for a repository
    other than the waiter's cwd; a value left off is a silent baseline). With `--workers-from`, the waiter then reads each row every
    `CHIEF_WAIT_PR_WATCH_SEC` (default 120) over REST only (`gh api` on the pull request and its
    reviews: no GraphQL, no model turn) and wakes `WAKE pr-watch <pr> [repo=<owner/name>] head <old7>→<new7> comments
    <o>→<n> reviews <o>→<n> state <o>→<n>` (only what moved) when the head, the comment count (issue
    and review comments), the review count or the state (open, closed, merged: a merge or a close
    moves none of the others) differs from the row. A row is keyed by PR number and `--repo`, so the
    same number in two repositories is two rows. It writes the new values back first, so the
    same change never wakes twice; no change is silent, a failed read is silent and retried next
    interval. The rows live in the manifest, so a successor's waiter on the inherited manifest
    watches them with no re-arm. Read the PR, relaunch the worker from its resume brief or act, and
    `fleet-manifest.sh watch <manifest> remove <pr> [--repo owner/name]` when the event is over (the
    `--repo` the wake line names as `repo=`; a row watched without one is removed without one).

    **An oversized brief or PR wakes you once.** `WAKE size rows=<total>` followed by
    `SIZE-ESCALATE<TAB>epoch<TAB>estimate|bulk|real|refuse<TAB>KEY<TAB>label<TAB>files<TAB>trust<TAB>detail` lines
    means `gen-briefs.py` wrote a brief whose Writes project past a size band (`estimate`) or took a
    `bulk: mechanical` one (`bulk`), or `worker-pr-open.sh` measured a real PR past the hard or CodeRabbit
    band (`real`; `refuse` is an old row). The detail starts `band=<band> ref=<branch>`, and a row for the same
    kind, key, label, band and branch is written once. Each new row shows once (`<inbox>.wait.size` holds the
    total shown, and a waiter's first sample on a new inbox is a silent baseline). Nothing is refused: every
    size case is yours. Split the ticket or the PR, or keep it whole and sign `size-override.sh record`.

    **A file ask you can grant wakes you once.**
    `WAKE hold-ask <key> wants <path> (held by <holder>). Grant: <command>`, then the tick line,
    means a worker's write on a `ci-trust-paths.txt` path was denied and no grant answers it
    (`holds.py asks`, kind `hold-ask-chief`). The operator is not paged for it, at first sight or
    later. Grant it in that turn: run `<command>` plus `--chief-doc <your doc>` with your own
    queue lock held. Or rule it out: tell the worker to wait for the holder's release or to drop
    the path. Each ask wakes once (`<inbox>.wait.holdwoke`), an ask an older waiter already
recorded included. An ask on settings or `.github/`
    (`hold-ask-operator`) wakes nothing. It pages the operator at first sight, and again once
    (`hold-ask-stuck`) if it is still ungranted 30 minutes later. An ask whose key has no live
    worker (no held queue lock names it) and no open PR (no register row of the key on a PR in
    the tick's `prs=`) is dropped before any wake or page. A `prs=?` keeps every ask.

    **A hold wakes you once.** `WAKE tick changed=holds` means a worker entered the
    `holds=` set (`BLOCKED`, or a `FINDING` awaiting a ruling, untouched for
    `TICK_HOLD_MIN` minutes, default 20): read its newest bullet and answer it. It
    does not repeat while the hold stands.

    **A silent worker wakes you once, and the operator is already told**.
    `WAKE worker-silent <worker> signal=<capped-waker|succession-partial> [silent=<n>m]`
    means no turn is coming from that worker: the tick lists `wakerstate=<worker>:capped`
    (its bus mail went unread) and, with `--workers-from`, its doc has had no write for
    `CHIEF_WAIT_WORKER_SILENT_MIN` minutes (default 45; the doc's mtime stands in for its
    newest Results bullet), or a `--succession` tally still waits on it (the line follows
    the partial block). The waiter already appended a `WORKER-SILENT` bullet to your doc and
    sent the operator one page naming the worker, the signal and the action; it repeats
    neither while the worker's doc is unchanged (`<inbox>.wait.silent`). Recover the worker
    in that turn, never wait on it. First confirm it is not working (`queue-lock.sh status
    <worker doc>`, `ListAgents`, its newest Results bullet). Then do ONE of: **relaunch** it:
    write a RESUME doc from the worker's doc (`worker-resume-brief.sh <worker doc>` supplies
    the git facts; name it per `worker-brief-template.md`, and keep the `description:` line
    double-quoted, on one line), end its stale session (one pid per call), release its lock with the worker's token, launch `chief-kit/headed-arm-worker.sh --fleet <your manifest>`
    on the RESUME doc (same branch, worktree and PR; the launcher adds the manifest row), then confirm it with
    `chief-kit/launch-confirm.sh --since <epoch taken just before the launch> <session> <log>`; or
    **take over** its one blocked step yourself (a merge after your GO runs as a claudex PR's
    does, `merges.md`). Then send the operator one message saying which you did, for which worker.

    **Permission.** The tracked `.claude/settings.json` allows exactly the
    step-10 launch shape `bash scripts/handover/chief-kit/chief-wait.sh …`
    (`Bash(bash scripts/handover/chief-kit/chief-wait.sh:*)`) and nothing
    wider: no glob before the path, because a glob can span quotes and would let
    `bash "-c" "<cmd>" "…/chief-wait.sh"` match. The harness refuses any
    command containing a `$VAR` expansion before it reads the allow list, so the
    command is spelled relative, never with `$HIMMEL_REPO`. The chief runs it with
    its cwd at the primary checkout root (a separate `cd` call first, never a
    `cd … &&` prefix), so it runs the primary's copy of the waiter. The
    operator's local Bash-wrapped absolute rule (`Bash(bash "<abs kit>/chief-wait.sh" *)`,
    added through `/permissions`; a bare path with a wildcard is skipped as
    invalid) stays as the fallback for an absolute spelling. The chief never
    re-spells the command to dodge a refusal: it sends the operator the exact
    line and holds.

    **A classifier-refused native worker.** The `DENIAL-PAGE` Telegram names the Remote Control session to open (the worker's session name) when that worker runs with `--remote-control`: the operator answers from the Claude app, in the worker's own window. A native plain-worker `--profile` launch carries the flag by default; claudex (the shim refuses the flag on a lane launcher), a judge, a relay, a release manager, a consult and a headless session never do. For a native worker that lacks it, `bash <kit>/enable-remote-control.sh [--relaunch] <session-name> <signal-file> <deadline-epoch> <log>` reports it (exit 5 plans the relaunch and ends nothing; `--relaunch` runs the launcher `--dry-run` first and ends nothing if that fails (exit 7), then ends that session and relaunches the same name on the same doc, model, profile, owning chief and `WORKER_SESSION_EFFORT`, destroying its context window; the profile comes from the launch record line whose `session_id` is the live session's own; a consult, judge, relay, release manager, A/B-arm or context-mode launch is refused, exit 4, since a relaunch would not restore it).
