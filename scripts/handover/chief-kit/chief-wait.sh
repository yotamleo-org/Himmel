#!/usr/bin/env bash
# chief-wait.sh — The chief's one event waiter.
#
#   chief-wait.sh <inbox-file> [tick.sh args...]
#
# A chief used to arm two `Monitor` loops (the Telegram inbox follower and
# tick.sh). The Monitor tool caps an arm at 30 min, so every expiry woke a
# full-context chief turn only to re-arm. This replaces both: the chief
# runs it ONCE with Bash `run_in_background` AND `timeout: 7200000` (both
# required: the default background limit is also 30 min and killed a waiter
# once); the harness re-invokes the session when the command
# exits. It stays silent while nothing
# happens and exits, printing one WAKE block, on an urgent event or when the
# housekeeping window ends. HOUSEKEEPING_DIGEST_SECS defaults to 900; 0 keeps
# the original unbatched output. Board changes, status sweeps and informational
# LIVE/ACK/WRAPPED/MERGED marker changes share a persisted housekeeping buffer.
# Telegram, actionable worker events, succession and handover-budget stay urgent.
# Exit-on-WAKE and re-arming remain; this does not provide persistent delivery.
#
#   WAKE housekeeping kinds=<sorted kinds>  one window of buffered housekeeping,
#   <kind> <detail>...                       no additional WAKE lines in its body.
#
#
#   WAKE telegram               unread lines in <inbox-file> (the bridge's
#   <line>...                   `/chief <name>` appends), via inbox-follow.sh
#                               --once, so its byte cursor is shared and a
#                               re-arm replays nothing.
#   WAKE tick changed=<f,...>   the tick's ACTION KEY changed and the change
#     usage=<verdict>           held for two consecutive samples; usage= is the
#   TICK ...                    usage-preflight verdict word the key carries.
#   WAKE budget-recovered from=<word> usage=PROCEED  a good sample reads PROCEED and
#   <budget-nudge.sh out>       <inbox>.wait.usage (the last decisive verdict word: PROCEED,
#   TICK ...                    SKIPPED-BANK or SKIPPED-FLEET; a BANK-STALE or BANK-UNKNOWN read
#                               leaves it) holds SKIPPED-BANK or SKIPPED-FLEET; no debounce, once
#                               per flip. The waiter runs budget-nudge.sh on the --workers-from
#                               manifest (one bus nudge attempt per live manifest worker) and
#                               folds usage=PROCEED into the saved key,
#                               so no WAKE tick changed=usage follows. Seam: CHIEF_WAIT_NUDGE.
#   WAKE underfilled capacity=UNDERFILLED:<n> the tick's capacity
#   <tick line>                 field says live < cap with no launch for
#   <next-dispatchable.sh out>  TICK_UNDERFILL_MIN; on the streak's first sample, and
#                               again once each time the pool's key set changes (re-probed
#                               every CHIEF_WAIT_UNDERFILL_REPOOL_SEC, default 1800; a pool
#                               that grows from empty counts, a failed probe or an emptied
#                               pool does not; a paused probe, one the dispatcher answered
#                               with `# quota-pause` / `# gh-stall` or one its outer timeout
#                               killed, wakes nothing, writes no marker and writes pool=paused
#                               to <inbox>.wait.poolpaused until a good probe removes it, so
#                               the next good reading wakes; while that file is younger than
#                               CHIEF_WAIT_PAUSED_REPROBE_SEC, default 300, the pool is not
#                               probed again, so a stalled dispatcher cannot block every
#                               sample. The one exception: a paused answer whose line 2 is
#                               `# stale-gh rows=<n>`, n above 0, is kept in <inbox>.wait.ghpausedrows
#                               and wakes `WAKE underfilled capacity=<cap> stale-gh rows=<n>
#                               prs=snapshot:<age>s|none keys=<KEYS>` with those rows, once per new
#                               key set (<inbox>.wait.ghpausedwake; exit wake-pool-ghpaused); it
#                               touches no underfill marker, sends no pool-unresolved wake and
#                               ignores a rows file older than CHIEF_WAIT_PAUSED_REPROBE_SEC. A
#                               pause with no such line deletes the rows file, an outer kill keeps
#                               it, and a good probe deletes both files. Each probe passes
#                               NEXT_DISPATCH_DEADLINE below its own bound (bound minus 20 above
#                               40 s, else half, never under 1; a smaller non-zero value in the
#                               environment wins)), with the
#                               priority-pool list (--priority-pool-only, plus
#                               --doc when given; POOL-EMPTY when nothing is in
#                               the pool), the earliest unreleased version's rows first under
#                               `# dispatchable in <version>`, other pool rows under
#                               `# dispatchable in other versions`, and no `# disposition`
#                               line for a listed row; versionless operator work adds the
#                               `# intake <m> for <version>: <keys>` line and an `# INTAKE:` line naming the
#                               command that files their INTAKE requests;
#                               a LOW, INTAKE or empty pool (short of its slots) with no declared
#                               release (no `# dropped from <version>:` line) adds a second pass
#                               without it, its rows not already in the pool under
#                               `# version backlog`; a declared release runs no second pass,
#                               offers no row of another version and prints the rows left in
#                               its version, each with its reason, under `# rows left in <version>`;
#                               the wake line carries
#                               dispatchable=<n> keys=<KEY>,..., the count and keys of
#                               the rows tick.sh --pool-dispositions calls dispatchable
#                               (LOCAL, CLOUD, RESUME, DESIGN rows and a series' tickets; also on a
#                               pool-unresolved wake; a pool that lists a row keeps
#                               this wake even when every key carries a
#                               pool-disposition: line), ` backlog=unread` when the
#                               second pass failed (CHIEF_WAIT_DISPATCH
#                               replaces the command, tests; it never launches).
#   WAKE resume-stale <KEY>,...  at an underfilled sample that probed the pool (the first sample and
#   <tick line>                 each re-probe, before the pool-signature check): a RESUME row the pool
#                               lists whose park start (ts_park_since_rows, the first D5c row at or
#                               after the key's newest anchor) is at least the resume wait old
#                               (ts_await_due <since> resume, 6 h unless
#                               TICKET_STATUS_AWAIT_TTL_RESUME) at ts_now (TICKET_STATUS_NOW, else
#                               the wall clock). One wake per CHIEF_WAIT_RESUME_STALE_REWAKE_MIN (default
#                               240) for an unchanged key set; marker <inbox>.wait.resume-stale, removed
#                               by a sample that read no stale key. The read runs in one subshell that
#                               sources scripts/lib/ticket-status.sh, with MERGE_ROWS_BUDGET_SECS
#                               (default 10 here) for the GitHub reads of the merge rows and the whole
#                               subshell under timeout -k 2 30. A non-zero rc, a timeout, a pool that
#                               read empty, a failed read of the rows (jq or the merge-row reader exiting
#                               non-zero) or a `merge-rows-effective: warn:` line (a pre-merge row the
#                               read could not settle) is an unread sample: no wake, the marker unchanged.
#                               The pool-wide wakes above take precedence at a sample that wakes on both.
#   WAKE pool-unresolved capacity=<value> pool=<open>/<in-flight>/<dispositioned>/<undispositioned>
#                               --dispositions still has unresolved tickets: list their keys
#                               by class, even at full capacity; re-wake on the bounded
#                               pool-probe cadence until every ticket has a disposition.
#                               tick.sh --pool-dispositions owns the interpretation.
#                               A failed tick sample still probes: capacity=? and a
#                               `tick-fail samples=<n> step=<step>` line stand in for the tick line.
#   WAKE tracker-stale tracker=<STALE:..>  tracker= stayed STALE past
#                               CHIEF_WAIT_TRACKER_STALE_MIN (default 30); once
#                               per streak (the class-change wake fires only once).
#   WAKE board-stale board=<STALE:..>  the same for board=, past
#                               CHIEF_WAIT_BOARD_STALE_MIN (default 10).
#   WAKE predecessor-open rc=<n>  with --doc <chief doc>: first in every sample the
#                               waiter closes the named predecessor and every wrapped,
#                               lock-free live session of the bucket through
#                               close-wrapped-worker.sh (see close_sweep_woke), once each, with a
#                               Results bullet; rc 3/4/6/7 retry silently next sample, and so does a
#                               hung close (rc 124/137) until CHIEF_WAIT_CLOSE_HANGS
#                               (default 3) in a row, then it wakes (the streak shows
#                               in the heartbeat as pred_hangs=<n>); any other
#                               refusal wakes once (CHIEF_WAIT_CLOSE = seam).
#   WAKE worker-event <line> rc=<n> out=<file>  with --doc and --workers-from (the script relay,
#                               R0): a worker whose tails= is WRAPPED or acts= MERGED is
#                               wrapped by `timeout -k 5 240 worker-event.sh --doc --fleet` on
#                               a line built from its newest such bullet; HANDLED is a
#                               digest line, no wake; a lock-held / not-yet-WRAPPED /
#                               subtree-alive refusal retries next sample, and so does a first
#                               timeout (rc 124/137; the second in a row wakes);
#                               any other ESCALATE or rc wakes once per bullet, <line> being
#                               worker-event's first non-blank output line (a silent failure
#                               gets an ESCALATE reason with its rc), the tick line after it
#                               (its key is saved) (CHIEF_WAIT_WORKER_EVENT = seam). Every WAKE block ends with `absorbed since last
#                               wake: wraps=<n> (<labels>) merged=<n> (#<pr>,...)` [+ ` auto-go=<n> (#<pr>,...)`
#                               for scripted GOs] when the relay absorbed anything, and the digest clears.
#                               The relay also hands every new READY bullet of a manifest
#                               worker to worker-event once, after any wrap, even when a LIVE
#                               bullet follows it inside one sample: <inbox>.wait.ready keeps a
#                               line cursor per worker. A worker met for the first time starts
#                               after its existing READYs. With the auto_go flag off only a
#                               `READY <pr> <head40>` bullet is handed on: worker-event starts
#                               its auto-go dry run and answers ESCALATE marker-READY,
#                               which wakes nothing (WAKE ready below is that READY's wake);
#                               any other answer wakes as above.
#   WAKE resolve <worker> pr=<n> threads=<id,...>  with --workers-from: a worker doc whose newest
#                               marker bullet is `BLOCKED resolve <pr> <PRRT_ ids>` (its
#                               resolve call was denied). Once per bullet; the chief
#                               resolves each thread itself, never the operator. The
#                               tick line follows and its key is saved.
#   WAKE worker-ready <label> pr=<n> head=<head40>   with --workers-from, one line per event, the
#   WAKE worker-blocked <label>  tick line after them (its key is not saved): a manifest worker
#   WAKE worker-finding <label>  whose newest marker bullet is a READY (auto_go on; off, WAKE ready
#                               below owns it; a READY with no head prints no pr=/head=), a BLOCKED
#                               that is not `BLOCKED resolve`, or a FINDING, and that no wake of this
#                               inbox named yet: a READY carried across a succession (the relay
#                               starts a worker it meets first after its existing READYs), one in the
#                               doc at the silent first sample, or one another wake folded into its
#                               saved key: only an event whose tails= token (<label>:<marker>) is in
#                               both the sample's key and the saved one, so a move the saved key lacks
#                               stays the tick change's wake. A READY past the relay's <inbox>.wait.ready
#                               cursor is the relay's: it wakes nothing here until the relay hands it on.
#                               The one-shot relay offers a newest-marker READY first (before any wrap); a
#                               retried candidate moves behind the others; a refused READY (auto-go
#                               refused it) wakes with this line first, then the WAKE worker-event line.
#                               Named = in <inbox>.wait.markerwoke: this wake, a WAKE tick
#                               whose tails=/acts= move is that worker's (only an event whose marker that
#                               tick's tails= token shows, so a READY written mid-tick under a FINDING token
#                               is not taken), and a READY the relay handed
#                               to worker-event all record it. Once per READY head or other bullet;
#                               a repeat READY of a named head folds like ready_fold. Checked after
#                               the tick key, so a tick change wakes first. The payload carries no
#                               bullet text. Any other wake of a sampled pass ends its block with the
#                               events no wake named yet whose token this sample's tails= shows, saved
#                               key or not (marker_carry), and records them.
#   WAKE worker-request <label>  the same, for a newest marker bullet led by any other marker that
#                               carries a REQUEST word (PUSH-REQUEST, JUDGE-REQUEST) or QUESTION; once
#                               per bullet, and a tails= move never names it.
#   WAKE t3-relay <kind> <id|list|stem>  with --workers-from (see t3_relay_step): once per
#                               CHIEF_WAIT_T3_RELAY_SEC (default 120) the waiter runs `relay-bind.sh scan --manifest
#                               <workers-from>` (seam CHIEF_WAIT_T3_RELAY, timeout CHIEF_WAIT_T3_RELAY_TIMEOUT, default 30;
#                               a no-op while `.t3.relay_instances` is off). kind ask-thread-pr, bind-gave-up and
#                               bind-refused carry a threadId, owner-taken the old chief doc stem, list-failed (the third
#                               `t3 thread list` failure in a row) `list`. BOUND and UNBOUND join the housekeeping buffer
#                               as kind t3-relay. rc 5 (another live chief owns binding) is silent. The tick line follows;
#                               its key is not saved. A run that stubs tick.sh (CHIEF_WAIT_TICK) calls the binder only
#                               through an explicit CHIEF_WAIT_T3_RELAY, so a test never binds against the real bucket.
#   WAKE t3-relay ask-ready <label>   a READY (any `READY ...` bullet), or `BLOCKED resolve`: ask-resolve, newest on a row whose
#   WAKE t3-relay ask-resolve <label> t3_kind is ask. The waiter takes no READY or resolve action on such a row (no worker-ready,
#                               ready or resolve wake, no ready-check, worker-event or auto-go; auto_go on or off), so the chief
#                               sees the attempt and nothing runs. Once per bullet; the tick line follows and its key is saved.
#   WAKE worker-renudge <label> <go-owed|answer-owed> waited=<m>m n=<k> hold=<hold id> [id=<id> head=<sha>] [t3=ask]
#                               with --workers-from: a worker still owed a GO or an answer (chief_owed_state, scripts/lib/
#                               chief-owed.sh), again once per 30-minute slot of this inbox, with no cap on k. A slot
#                               wakes at its first sampled pass, if that pass has an unheld item first seen 1800 s or more
#                               before; a slot is spent by its first sampled pass whether or not anything is due, at most
#                               once. It names every such item in one block, then the tick line; another wake of a sampled
#                               pass ends its block with the due lines. An item stops on a bullet that changes what the
#                               worker is owed, on a GO file for its READY id and head (not on a t3_kind ask row), on an
#                               open owe.sh `ruling` row whose source_label and source_id are its label and hold id, or
#                               when its row leaves the manifest; an unreadable doc or manifest drops nothing. Never in
#                               stream or handover mode. The line carries no bullet text. State: <inbox>.wait.renudge
#                               (line 1 `anchor <epoch> <last slot>`, then tab-separated hold id, label, kind, first-seen
#                               epoch, count); send log: <inbox>.wait.renudge.log (`<epoch> <hold id> n=<n> waited=<m>m`).
#                               A failed state write sends nothing. Test seams (HIMMEL_TEST_FIXTURE=1 only):
#                               CHIEF_WAIT_NOW, CHIEF_WAIT_NOW_FILE, CHIEF_OWED_GO_ROOT, CHIEF_WAIT_RENUDGE_KILL_AT.
#   WAKE worker-doc-missing <label> <path> [writes=<original>]  with --workers-from, once per path:
#                               a manifest row whose doc does not exist, or a -RESUME doc with no
#                               marker bullet whose original beside it holds a newer one.
#   WAKE ready-mismatch <value>  the tick's ready-mismatch= carries ALERT: on entering ALERT and
#                               when its flagged or NO-GO count rises (<inbox>.wait.readymismatch keeps
#                               `<flagged> <nogo>`, removed when ALERT leaves). The tick line follows.
#   WAKE ready <pr> <head40> ready-check=<PASS|FAIL> ci=<GREEN|RED|PENDING|PAUSED> coverage=<PASS|FAIL>
#        disposition=<ok|open:<n>|STALLED> out=<file> [after-quota=<caller>]
#   WAKE ready <pr> <head40> ready-check=STALLED out=<file> [after-quota=<caller>]
#                               with --workers-from and the auto_go flag off
#                               (on, the relay above routes READY to auto-go.sh): a worker doc
#                               whose newest marker bullet is `READY <pr> <head40> GREEN`. Before
#                               waking, the waiter runs `timeout -k 5 <READY_CHECK_DEADLINE + 15>
#                               ready-check.sh <pr> <head>` (165 s by default, so ready-check's own
#                               deadline speaks first), one CI read (`gh pr checks` on the read
#                               token through scripts/lib/gh-read.sh, main when none is set, under
#                               CHIEF_WAIT_READY_CI_TIMEOUT, default 30; a failed read is PENDING, a
#                               rate-limit refusal PAUSED) and `timeout -k 5 <CHIEF_WAIT_DISPOSITION_TIMEOUT,
#                               default 90> cr-disposition.sh check <pr> <head> --trust-path
#                               <ready-check's TRUST-PATH>` (read only; open:? = it could not
#                               evaluate). coverage= is ready-check's item 7. At quota out the READY
#                               is not spent: a head with a rate-limit marker (see quota-back below)
#                               runs no check; when every GraphQL route of quota.tsv reads 0 or refused
#                               the waiter marks the head itself (caller=chief-wait) and runs none; when
#                               every route timed out it runs none and marks nothing; a check that
#                               comes back QUOTA-PAUSE wakes nothing and records nothing. A check that
#                               stalls (GH-STALL, its deadline cut, or rc 124/137) wakes nothing on the
#                               first sample (<inbox>.wait.stall-<pr>.<head> counts it) and wakes
#                               STALLED, recorded, on the second in a row, clearing the count and the
#                               head's stall marker. One sample runs at most one head's checks. A
#                               READY the quota step re-armed carries `after-quota=<the refused gate>`.
#                               Once per (PR, head):
#                               <inbox>.wait.readywoke keeps `<pr> <head>`, and a repeat READY of
#                               a woken head folds that worker's tails=/acts= move into the
#                               saved key, so it wakes nothing. out= is <inbox>.wait.ready-<pr>,
#                               the three outputs, tokens scrubbed; the payload carries no
#                               bullet text. The tick line follows and its key is saved. The
#                               chief reads the diff and rules; GO stays go.sh. Seams (tests):
#                               CHIEF_WAIT_READY_CHECK, CHIEF_WAIT_CI (prints the CI word),
#                               CHIEF_WAIT_DISPOSITION.
#   quota-back <key> <ref> caller=<gate> [quota=unknown]   look-only (housekeeping digest; with
#                               HOUSEKEEPING_DIGEST_SECS=0 it is `WAKE quota-back ...`). Once per
#                               sample, before the READY checks and on a failed sample too, the
#                               waiter reads the markers a refused or stalled gate left
#                               (blocked/<key>.<ref> under HIMMEL_QUOTA_DIR; key a PR number or
#                               branch-<name>, ref a head or unknown). No marker: only the directory
#                               is read. A marker 24 h old is deleted with no line; while quota is
#                               out there is no line. Quota is back when every bucket the marker names
#                               reads state=ok at or above GH_BUDGET_FLOOR (200) on a token it rides,
#                               observed after its first_epoch; the first waiter to see that stamps
#                               back_epoch. 7200 s with no good reading counts too, as quota=unknown.
#                               The owner (the head is in its readywoke, a manifest worker's newest
#                               READY names it, or a worker doc names the branch) takes it at once;
#                               another waiter 900 s after back_epoch. One `mv` claims it. A
#                               rate-limit marker at a manifest worker's newest READY (auto_go off)
#                               unspends that head and leaves <inbox>.wait.readyhint, so the READY
#                               wake above re-runs on this or the next good sample with
#                               after-quota=; anything else is this line.
#   WAKE silent-go             with --doc and --workers-from: silent-go-merge.sh found a GO'd
#   <SILENT-WORKER-... line>... READY PR whose worker has been silent past
#                               CHIEF_WAIT_WORKER_SILENT_MIN (default 45) since its doc or GO
#                               was last written, and either merged it through
#                               merge-on-green.sh --go or says why not. It alerts the operator
#                               and writes a chief-doc bullet for each; once per (worker, PR,
#                               head, outcome), the keys in <inbox>.wait.silentgo. A merge is
#                               bounded by CHIEF_SILENT_GO_TIMEOUT (default 900 s) and
#                               ready-check by 90 s; the heartbeat says sampling meanwhile.
#                               Seam: CHIEF_WAIT_SILENT_GO.
#   WAKE hold-ask <KEY> wants <path> (held by <holder>). Grant: <command>   one line per trust-path
#                               ask the chief may grant (holds.py asks kind hold-ask-chief), on its first
#                               sight (record <inbox>.wait.holdwoke); the tick line follows. It pages
#                               nobody. A hold-ask-operator ask is paged to the operator instead, and
#                               again as hold-ask-stuck once after 30 min ungranted. holds.py drops an
#                               ask whose key has no live worker and no open PR in the tick's prs=.
#   WAKE size rows=<n>          gen-briefs.py refused an oversized brief or took a bulk: mechanical one
#                               : the new SIZE-ESCALATE rows of size-override.sh's ledger
#                               follow, once per row (marker <inbox>.wait.size). Seam: CHIEF_WAIT_SIZE.
#   WAKE pr-watch <pr> [repo=<owner/name>] <detail>  with --workers-from: a `watch` row of the fleet manifest
#                               (fleet-manifest.sh watch: a PR number and repo plus the head sha, comment
#                               count, review count and state last seen; a worker waiting on an outside
#                               event closes and the chief watches the PR instead). Every
#                               CHIEF_WAIT_PR_WATCH_SEC (default 120) the waiter reads each row over
#                               REST only (`gh api` on the pull request and its reviews: no GraphQL,
#                               no `gh pr view`, no model turn) and wakes ONCE when the head, the
#                               comment count (issue + review comments), the review count or the state
#                               (open, closed, merged) differs from the row, <detail> being `head
#                               <old7>→<new7> comments <o>→<n> reviews <o>→<n> state <o>→<n>` for what
#                               moved; it then `watch set`s the row, so the
#                               same change never wakes twice. No change is silent; a REST failure
#                               is silent and retried next interval; a field the row left unset is a
#                               silent baseline. Seams (tests): CHIEF_WAIT_GH replaces `gh`; CHIEF_WAIT_PR_WATCH_SEC=0
#                               polls every sample. The repository is the row's `repo` or the
#                               gated checkout's (HIMMEL_REPO, else this script's own primary
#                               checkout), never the waiter's cwd; so is `gh pr checks` below.
#   WAKE succession complete <k/n>   with --succession <successor> --doc <chief doc>
#   <tracker output>            (the successor's waiter): every inherited worker quoted
#                               back; the block carries succession-tracker.sh's table
#                               and the printed append-results.sh line for the LIVE
#                               bullet. Once, and it prints only: nothing is sent.
#                               An informational tally: LIVE follows the predecessor's
#                               `RELAYED <n> of <m>`, not this wake.
#   WAKE succession partial <k/n> silent <T> min   the tally stayed short for
#   <tracker output>            --silent-min T minutes (default 20); the table names
#                               the workers still out. Once. CHIEF_WAIT_SUCCESSION_SEC
#                               (default 15) paces the tally; CHIEF_WAIT_TRACKER
#                               replaces the tracker (tests).
#   WAKE handover-budget [repeat] <line>  with --doc <chief doc>: chief-budget.sh --title
#                               <the doc's basename> says HANDOVER (400 turns, 120M
#                               cache-read or 45 % context fill (chief-budget.sh defaults));
#                               the marker clears on OK
#                               and, while HANDOVER holds, the wake repeats (marked
#                               `repeat`) every CHIEF_WAIT_BUDGET_REPEAT_MIN minutes
#                               (default 30). CHIEF_WAIT_BUDGET replaces the command, tests.
#   WAKE status-sweep <line>    with --doc <chief doc>: status-sweep.sh every 15 min
#                               (WAIT_SWEEP_SEC), bounded at 60 s, woke only when it
#                               moved a ticket or its failure signature is new.
#   WAKE focus <state>          the same pass: focus-refresh.sh --status is FAILED:<stage>,
#                               or DIRTY:<n>m with n of 10 or more; once per state. It is also
#                               WARN:cycle <keys> or WARN:unknown <keys> (a Blocks loop or an
#                               unreadable link; alone or joined to another warning): once per
#                               distinct sorted key set, and the line names the fix (cut or
#                               justify the edge). Other WARN states wake nothing.
#                               Each tick also starts one background refresh of a
#                               DIRTY or FAILED page (none while one runs); no wake. A WARN
#                               page starts none.
#   WAKE cadence <workflow> run=<id> <RED|SKIP|MISSED> <run url> cause: <why>   the tick's
#                               cadence= field flags the last scheduled run of a workflow: RED (failure or
#                               timed_out), SKIP (concluded skipped) or MISSED (no scheduled run inside 1.5
#                               periods). Urgent, never digested. Once per run id: <inbox>.wait.cadence holds
#                               every run id woken or seen at the first sample (the baseline, so installing the
#                               field wakes nothing for runs that already finished), a MISSED one as
#                               missed-<last run id>; a re-armed waiter replays nothing. cadence=? wakes
#                               nothing. The cause line comes from `ci-cadence.sh cause` (the first failing job
#                               and step), CHIEF_WAIT_CADENCE replaces it (tests). More than one new run: one
#                               line each under one WAKE, then the tick line.
#   WAKE review <date> <reasons>  (decision 593) the tick's review= field, the daily failure review as one more
#                               scheduled row. Reasons: filed=<keys> (the router filed a ticket),
#                               new-classes-5+=<n>, and STALE (no review for 26 h). Once per
#                               review day (and once per last-review date for STALE): <inbox>.wait.review holds
#                               `<date>` and `stale-<date>`. A 1-count class never wakes; review=none or ? wakes nothing.
#   WAKE drift-actionable <n>   the tick's drift=<n> field counts actionable rows of the open nightly drift issue
#                               (Needs-update rows and held rows whose 72 h buffer has cleared). Once per UTC
#                               day per bucket: the atomic create of $TICK_STATE_DIR/drift-wake-<bucket>.<date> claims the
#                               wake, so a re-armed waiter and a new chief's waiter on a new inbox replay nothing, and a
#                               claim that cannot be made wakes nothing. A manifest worker whose doc is a drift brief of
#                               the day, or an open PR whose head is `...-drift-<date>`, holds the wake (no claim; the note
#                               `drift-actionable <n> held-by <label|PR>` goes to <inbox>.wait.drift.held). drift=0 or ? wakes nothing.
#   WAKE tick-usage rc=2 <line>  the first sample whose tick exited 2 (tick.sh's usage error: the
#                               arm forwarded a flag it refuses). <line> is tick's first stderr line.
#                               Never batched into the digest; every re-arm on a broken arm wakes again.
#   WAKE tick-fail samples=<n> step=<step>  CHIEF_WAIT_FAIL_WAKE consecutive samples
#                               failed (tick or bank read): the monitor is
#                               broken. step= names the last sample's failure:
#                               tick-timeout:<s>, tick-exit:<rc>, no-tick-line,
#                               usage-read or missing-field:<name>. Once per streak;
#                               the re-arm stays quiet until a sample succeeds. Look-only
#                               (8934): queued in the digest, a wake only with
#                               HOUSEKEEPING_DIGEST_SECS=0. The usual step is
#                               tick-timeout:120s under host load (the recorded ticks took up to 104 s
#                               of wall time and about 17 CPU-s at the median; 62 CPU-s was
#                               the figure before the refreshes were detached), not a broken monitor.
#   WAKE worker-silent <worker> signal=<capped-waker|succession-partial> [silent=<n>m]
#                               a worker went silent. capped-waker: with --workers-from, the
#                               tick lists wakerstate=<worker>:capped (its bus mail went unread) and the
#                               worker's doc has had no write for CHIEF_WAIT_WORKER_SILENT_MIN minutes
#                               (default 45); the doc's mtime stands in for its newest Results bullet, as
#                               the tick's hold and READY ages do. succession-partial: a --succession
#                               tally that stayed short names the worker (the line follows the partial
#                               block) and a manifest row of it does not have a free queue lock. A worker
#                               whose every row has a free lock is named by no line, bullet or page: it reads as
#                               closed, never launched or answering on another row's doc, so a live worker that
#                               lost its lock is not paged. One line per worker, once per (worker, signal, doc write time):
#                               <inbox>.wait.silent holds the keys, so a re-arm on an unchanged state is quiet
#                               and a worker that wrote and went quiet again wakes again. Each line also
#                               appends a `WORKER-SILENT` bullet to --doc and sends the operator ONE page
#                               (the worker, the signal and the action; same sender and budget as
#                               DENIAL-PAGE), then runs silent-worker-act.sh once for that same (worker, signal,
#                               doc write time): a nudge past bound one, the relaunch from the RESUME doc past
#                               twice it, an owed row for a failed step, in a succession as in any other wait.
#                               Its `SILENT-ACT <worker> ...` result line follows the WAKE line
#                               (CHIEF_WAIT_SILENT_ACT replaces the helper). What the helper left undone, the
#                               chief does and says which it did (chief-template.md). The tick line follows a
#                               capped-waker wake.
#
# Per-field key, entry and reminder policy: wake-rules.tsv, printed by --rules.
# Specialized readers below retain exact-head, set/rise and receipt semantics.
#
# PAGE: when a wake's denials= change raised a worker's
# class to SHIP-STEP or PAUSE-RISK (a new worker, or a higher class; a count rising
# inside one class wakes but does not page), the waiter sends ONE operator
# Telegram message per rise through the kit's existing bridge path
# (scripts/lib/merge-block-alert.sh: first allowFrom of access.json ->
# chief-route.ts reply):
#   DENIAL-PAGE <worker> <class> x<count> - a classifier denial parked this worker. ...
# The text is the worker label, count and class ONLY. It also writes a page record
# (denial-ack-lib.sh) BEFORE the send, which headed-arm-worker.sh reads to refuse
# re-dispatching the worker until `ack-denial.sh <worker>` is run. Both steps fail
# open; the sends of one wake share ONE CHIEF_WAIT_PAGE_TIMEOUT budget (default
# 45 s, plus a 2 s kill grace), the most hung senders can delay the WAKE block;
# a worker past the budget still gets its page record, just no message. It pages what THIS
# waiter saw rise: a denial that lands while no waiter runs is not paged.
# closable=<n> (tick.sh: finished windows still open past
# TICK_CLOSABLE_MIN minutes) wakes when it appears or changes; absent means none.
# deadwin=<label>:closed|held (tick.sh: a worker window whose session died) wakes
# when it appears or changes; absent means none.
# unclosed=<label>[,<label>] (tick.sh: a worker read CLOSABLE, or WRAPPED / NOLIVE with a
# live window, open on two ticks running with no DISPOSITION bullet in the chief doc) wakes
# `WAKE unclosed <labels>` for each worker new to the marker `<inbox>.wait.unclosed` (the
# labels printed are the new ones), again every CHIEF_WAIT_UNCLOSED_REWAKE_MIN (default 60)
# while it stays; the marker clears when the field is gone. It is not part of the action key.
# `WAKE owed-undelivered <keys>` (with --doc): the chief doc holds an owed-item
# bullet `- [HH:MM ]OWED <key> <what the operator must do>` (key = [A-Za-z0-9_.-]+) and no
# receipt bullet `- [HH:MM[Z] ]DELIVERED <key> msg=<telegram message id> chat=<chat id>` once the
# waiter has seen it for CHIEF_WAIT_OWED_SEC (default 300). Only
# `chief-route.ts reply --owed <key> --doc <chief doc> <chat> <text>` writes the DELIVERED
# bullet, from the bridge's send receipt, never by hand. Wakes once per key (marker
# `<inbox>.wait.owed`: `<key> <first-seen epoch> <woken 0|1>`); a receipt drops the key.
# `WAKE rm-lease-stale <epoch> <age>m` (with --doc whose `release:` line names a release): the release
# manager lease (`jira release state <R> --json`, read at most every CHIEF_WAIT_RMLEASE_SAMPLE_MIN, default 5)
# is held, its holder pid is not alive on this host, and its run doc is missing or untouched for
# CHIEF_WAIT_RMLEASE_STALE_MIN minutes (default 30; a missing doc counts from the lease's `acquired` time).
# The next line names the takeover command. Wakes once per epoch (marker `<inbox>.wait.rmlease`), again
# every CHIEF_WAIT_RMLEASE_REWAKE_MIN (default 60) while it stays; a released lease, a live holder, a fresh
# run doc or a takeover (a new epoch) clears the marker. A failed, timed-out or unparseable read wakes nothing and
# keeps it. CHIEF_WAIT_RMLEASE replaces the state reader with `<cmd> <R> --json` (tests); the CLI's exit 3 (not OK)
# still prints the state and is read.
# `WAKE rm-intake INTAKE=<n> since=<h>h capacity=UNDERFILLED:<m>` (with --doc whose `release:` line names a release):
# the tick's INTAKE=<n> (versionless work outside the pool) stood above 0 for more than
# CHIEF_WAIT_INTAKE_ARM_HOURS (default 6) while the fleet was UNDERFILLED. The next line names the rm-run command
# the chief runs; the waiter never launches anything. The clock is <inbox>.wait.intake (first-seen epoch, last-wake
# epoch), cleared when INTAKE returns to 0. One wake per CHIEF_WAIT_INTAKE_REWAKE_MIN (default 360); none while the
# rm lease is held or unreadable (the same CHIEF_WAIT_RMLEASE reader; sampled every CHIEF_WAIT_INTAKE_SAMPLE_MIN).
# Everything else on the tick line (heartbeat, procs, fill, fleet, gql,
# orphans...) moves without needing a chief act and never wakes. Two consecutive samples must differ from the saved key (not
# necessarily from each other), so one failed `gh` read (prs=none for a single
# tick) is not an event. The first sample with no saved
# key, or with a saved key taken under different tick args (a re-arm after a
# dispatch or wrap) -- or, with --workers-from, under a different manifest worker
# set -- is a silent baseline. A tick.sh that exits non-zero or
# prints no TICK line, or a bank read that fails or is not a verdict token, is
# a failed sample: never a change, and only a streak of them wakes.
#
# board= (and tracker=, the same way) is asymmetric: a class move TO ok is never itself a wake (the
# chief just rendered its own board — nothing for it to act on), only a
# move to STALE or MISSING is. The key still saves silently on a move to ok,
# so a later move to STALE wakes again. A sample where board moves to ok AND
# another action field changes still wakes, naming only the other field(s).
#
# Chief duties (needs --doc and --workers-from): after each successful sample's tick the waiter runs
# chief-duty-sweep.sh under `timeout -k 2 <bound>` with CHIEF_DUTY_AUTORUN=0, so it sends no rerun
# unless CHIEF_WAIT_DUTY_AUTORUN=1. Only an exit 0 replaces the list and state; a hang, crash or exit 2
# never fails the sample. When the last list holds a DUTY or DUTY-RAN line, or a source unread for 15
# minutes, a wake ends with that list under
#   chief-duty <n> as of <time>Z[ stale]:   (stale: a list older than 900 s)
# A wake also carries `chief-duty sweep failing rc=<rc> since <time>Z` while the sweep fails, and
# `chief-duty off: <reason>` when an input a named sweep needs is missing. The owed-stale lines are
# folded into one `DUTY owed-stale x<n> (not listed; run the sweep by hand)`; every other line printed
# is marked shown. A sample that no earlier rule woke on prints
#   WAKE chief-duty <n> new=<kind>:<id>[,...]
# when an id in its list is not shown, was on an earlier fresh list in the same phase and is past its
# kind's minimum age; guard-refusal, printed once, counts on its first list. An id that only leaves
# never wakes; one absent from every fresh list for 10 minutes is forgotten.
# Phase, read from the why text (first match wins):
#   ci-masked   `rerun sent` or `reserved by another sweep` = sent; `held: drain` = drain;
#               any other `held:` = held
#   judge-owed  `judge-pending:` = pending
#   anything else = -
# Minimum age:
#   go-owed 30 min; answer-owed 20 min; guard-refusal 0 (first list); ci-masked 0, never in phase
#   sent or drain; dispatch-owed, judge-running, owed-stale and an unread source never wake;
#   merge-owed, judge-owed and any other kind 0.
#
# Files next to the inbox:
#   <inbox>.wait.duty        the last fresh duty list, verbatim.
#   <inbox>.wait.duty-state  `<kind> <id> <phase> <first seen> <last seen> <shown 0|1>` per listed id
#                        and unread source (kind ?).
#   <inbox>.wait.duty-fail   `<rc> <first failure epoch>` while the sweep fails.
#   <inbox>.wait.duty-out, <inbox>.wait.duty-err  the last sweep's stdout and stderr.
#   <inbox>.wait       heartbeat, rewritten every poll:
#                      `hb=<epoch> pid=<pid> key=<sha16> tick=<ok|fail|-> state=waiting`,
#                      `state=sampling` while a tick runs, then on every
#                      catchable exit `... state=exited exit=<reason>`.
#                      A sample (closes, a tick, then bank) can take up to CHIEF_WAIT_CLOSE_TIMEOUT
#                      per close (1 + CHIEF_WAIT_SWEEP_MAX at most), then twice
#                      CHIEF_WAIT_TICK_TIMEOUT (+5 s kill grace each), and a
#                      Telegram line waits for it. The relay adds at most one
#                      wrap attempt (240 s +5 s kill grace), refreshing the heartbeat
#                      before its call; a READY wake's three checks (165 + 30 + 90 s by default,
#                      +5 s kill grace each) refresh it before each one. The duty sweep adds at most
#                      CHIEF_WAIT_DUTY_TIMEOUT +2 s and refreshes it first. Older than those bounds plus a few polls,
#                      waiting or sampling, means it died without trapping (SIGKILL).
#   <inbox>.wait.state   the saved action key (line 1: tick-args hash, line 2: key;
#                        line 3 `failwoke` once a failure streak has woken).
#                        Written atomically: temp file in the same dir, then
#                        `mv`, so a kill mid-write never leaves it torn.
#   <inbox>.wait.lock    the one-waiter flock (the file stays; the lock does not).
#   <inbox>.wait.digest  the relay's absorbed wraps since the last wake, one
#                        `<label> <wrap-merged|close-wrapped> <pr|->` line each.
#   <inbox>.wait.r0      the bullets the relay already handled or woke for
#                        (`<label> <marker> <cksum>`); <inbox>.wait.le-<label> holds
#                        worker-event's last output for that worker, tokens scrubbed.
#   <inbox>.wait.relaylog  one line per worker-event call, whether it handled, refused or woke:
#                        `start=<epoch> label=<l> marker=<m> pending=<s> handler=<s> rc=<rc>`. pending= is how
#                        long this waiter process had known the event when the call began (a waiter restart
#                        starts it again; time spent unseen while a sample held the loop is not in it), handler=
#                        how long worker-event ran. An idle pass writes nothing. Past 1 MiB (the cap of the
#                        classifier denial log) it is renamed to <inbox>.wait.relaylog.1, replacing the older
#                        copy, so at most two files exist; nothing the waiter decides from is in it.
#   <inbox>.wait.le-<label>.tries  stream mode: a refused cleanup's retry ladder, `<refusals in a row> <cksum of the
#                        bullet being retried> <cksum of the bullet already woken for or ->`. The relay owns the
#                        count; the collector reads it and holds the event back for the retry window times 1, 2,
#                        6, 24, 60 by it. A new or changed event (another bullet checksum) starts the count over;
#                        lines appended to the worker document do not. The refusal that reaches the top step wakes
#                        once per bullet. It only paces: nothing is closed, wrapped, reaped or recorded as handled.
#                        Removed when the cleanup succeeds or answers anything but a retryable refusal.
#   <inbox>.wait.ready   `<label><TAB><line>`, the last READY bullet handed on to worker-event.
#   <inbox>.wait.readywoke  with auto_go off: `<pr> <head40>`, each READY already woken for;
#                        <inbox>.wait.ready-<pr> holds that wake's checks, tokens scrubbed.
#   <inbox>.wait.markerwoke  the READY, BLOCKED and FINDING events a wake named (WAKE worker-ready above).
#   <inbox>.wait.readymismatch  `<flagged> <nogo>` of the last ready-mismatch ALERT seen.
#   <inbox>.wait.readyhint  `<pr> <head40> <gate>`: a READY the quota step unspent; its next wake
#                        carries after-quota=<gate> and drops the line (it survives failed samples).
#   <inbox>.wait.stall-<pr>.<head40>  that head's checks stalled once; the next stall wakes.
#   <inbox>.handover    handover mode: while it is fresh (younger
#                        than CHIEF_WAIT_HANDOVER_MIN, default 60) the waiter
#                        skips tick/bank/page sampling and wakes only on Telegram.
#                        That mutes classifier-denial pages for up to that long;
#                        `rm <inbox>.handover` ends the mode early.
#   <inbox>.relay-on-live  (`chief.sh next` defaults to relay-on-live unless
#                        --no-relay-on-live; needs --doc) line 1 the
#                        successor session, line 2 its doc. When that doc's queue lock
#                        is held fresh the waiter prints one `WAKE relay-on-live
#                        successor=<s>` block (relay-batch.sh's output, ending with
#                        `RELAYED <n> of <m>`: n counts the SENDMESSAGE lines, so the
#                        chief sends those first, then RELAYED to the successor,
#                        whose LIVE follows it), removes the marker and exits 0. Line 2 of the block
#                        is `AFTER RELAYED: re-arm this waiter once, read nothing, ...`: the chief
#                        re-arms once (muted, resumes after the marker's age bound), ends its turn,
#                        the successor's LIVE message wakes it, one `chief.sh wrap` ends it. It works in handover mode. Seams:
#                        CHIEF_WAIT_LOCK_STATUS, CHIEF_WAIT_RELAY (tests).
#
# Exit: 0 = a WAKE block was printed; 1 = the inbox could not be drained;
# 2 = usage or an inbox outside the */consoles/<name>.md layout; 3 = another waiter is already live on this inbox (its pid is named).
#
# Env: CHIEF_WAIT_DUTY_CMD names the duty sweep (empty: off; unset: chief-duty-sweep.sh, or off
# beside a CHIEF_WAIT_TICK replacement);
# CHIEF_WAIT_DUTY_TIMEOUT bounds one sweep in seconds (default 60);
# CHIEF_WAIT_DUTY_AUTORUN=1 lets that sweep send its CI rerun (the waiter's own CHIEF_DUTY_AUTORUN is
# not passed through).
# CHIEF_WAIT_INTERVAL tick interval in seconds (default 180);
# CHIEF_WAIT_POLL_SEC inbox poll (default 1); CHIEF_WAIT_IDLE_PASSES (default 10) and
# CHIEF_WAIT_IDLE_POLL_SEC (default 1, never below the poll; a value that is not a plain decimal number is the
# default): in stream mode the loop sleeps the idle poll
# instead of the poll after that many passes in a row that offered nothing, attempted nothing and ran no tick,
# and the first pass with an event or work puts the poll back; CHIEF_WAIT_TICK_TIMEOUT
# seconds a tick may run before it counts as failed (default 120), so a hung
# tick cannot freeze the Telegram path; CHIEF_WAIT_FAIL_WAKE consecutive
# failed samples before a tick-fail wake (default 3); CHIEF_WAIT_TICK / CHIEF_WAIT_USAGE
# replace tick.sh / the bank verdict command (tests); CHIEF_WAIT_PAGE_CMD
# replaces the Telegram sender (called as `$CMD <text>`, tests) and
# CHIEF_WAIT_PAGE_TIMEOUT bounds it (seconds, default 45); HIMMEL_DENIAL_ACK_DIR
# relocates the page/ack records (default ~/.himmel/state/denial-acks);
# CHIEF_WAIT_READY_CI_TIMEOUT (default 30) and CHIEF_WAIT_DISPOSITION_TIMEOUT (default 90)
# bound a READY's CI read and its cr-disposition check; READY_CHECK_DEADLINE (ready-check's,
# default 150) sets ready-check's bound 15 s above it; HIMMEL_QUOTA_DIR holds quota.tsv and the
# blocked/ markers (gh-quota.sh).
# An exported REPO naming a directory reaches the tick only (as its absolute path); the waiter's own reads keep its own checkout.
#
# Per-tick log: every tick the waiter runs appends one line to <inbox>.wait.ticklog:
#   start=<epoch> wall=<s> cpu=<children user+sys s> rc=<tick rc> timedout=<1|0>
# timedout=1 is the tick-timeout case (rc 124 or 137 under CHIEF_WAIT_TICK_TIMEOUT, the step a
# tick-fail wake names tick-timeout:<s>). The file is never trimmed by the waiter.
#   chief-wait.sh --tick-timeouts <inbox-file>
# prints `ticks=<n> tick-timeouts=<n> window=24h` for the last 24 h of that log and exits 0; it takes
# no lock and runs no tick, so it is safe beside a live waiter.
#
# Worker messages (SendMessage) wake a chief on their own; only the Telegram
# and tick paths depend on this waiter.
#
# Station heal (needs --doc): after three consecutive samples whose tick line reads station=BEHIND:<components>
# the waiter starts `station-sync.sh --heal` detached for the chief doc's bucket, at most once per 1800 s;
# the streak and the start time live in <inbox>.wait.station-heal. CHIEF_WAIT_STATION replaces
# station-sync.sh (tests).
#
# A pool-unresolved wake joins the housekeeping digest unless its value changed since the last
# one: the capacity, the dispatchable keys or the unresolved lines (marker <inbox>.wait.poolhk,
# cleared when the pool resolves). First sight and any change wake at once.
#
# Look-only kinds (8934) never wake the chief on their own: an unowned-prs sight, a tick-fail
# streak and a tick whose change is prs/board/tails-routine/acts only join the housekeeping buffer.
# The next real wake (Telegram, a worker event, succession, ...) ends with a `look-only since last
# wake:` block carrying those lines and empties them from the buffer; otherwise the window's own
# `WAKE housekeeping` prints them. READY, BLOCKED, FINDING, Telegram, succession, GO and rulings
# are never look-only. HOUSEKEEPING_DIGEST_SECS=0 keeps every look-only wake unbatched.
#
#
# PLATFORM GUARD: the chief kit is Linux-only.
# bash 3.2-safe.
set -u
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --rules ]; then cat "$HERE/wake-rules.tsv"; exit 0; fi
cw_tick_repo=""; [ -z "${REPO:-}" ] || cw_tick_repo="$(CDPATH='' cd -- "$REPO" 2>/dev/null && pwd)" || cw_tick_repo=""  # swallow-ok: a REPO that names no directory keeps the waiter's own checkout, as before
REPO="$(cd "$HERE/../../.." && pwd)"
GH_READ_BIN="$REPO/scripts/lib/gh-read.sh"; [ -f "$GH_READ_BIN" ] || GH_READ_BIN=gh
# shellcheck source=../../lib/prim.sh
. "$REPO/scripts/lib/prim.sh" || exit 2
# The gated checkout: HIMMEL_REPO, else the primary checkout of this script's own tree,
# never the waiter's cwd. ready-check.sh, cr-disposition.sh and every gh read of the
# PR run there, so the waiter reads the same repo from any directory.
# shellcheck source=../../lib/gate-repo-resolver.sh
. "$REPO/scripts/lib/gate-repo-resolver.sh" || { echo "chief-wait: cannot load scripts/lib/gate-repo-resolver.sh; nothing waited" >&2; exit 2; }
GATE_DIR=$(gate_repo_dir chief-wait "" "") || exit 2
# gate_nwo: the gated checkout's owner/name from its origin URL (empty when it has none).
gate_nwo() {
    (. "$REPO/scripts/lib/git-clean.sh" && git_env_scrub && git -C "$GATE_DIR" config --get remote.origin.url | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
}
# the manifest worker array is `workers`; a manifest not yet rewritten holds the pre-rename `legs`, read only while legacy names are on
# shellcheck source=../../lib/legacy-names.sh
. "$REPO/scripts/lib/legacy-names.sh" || exit 2
# shellcheck source=../../lib/gh-quota.sh
. "$REPO/scripts/lib/gh-quota.sh" || exit 2
# shellcheck source=../../lib/jira-project.sh
. "$REPO/scripts/lib/jira-project.sh" || exit 2
# shellcheck source=../../lib/chief-owed.sh
. "$REPO/scripts/lib/chief-owed.sh" || exit 2
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
if legacy_names_on; then JQ_WR='def W: [(.workers // .legs)[]? | select((.t3_kind // "") != "ask")];'; else JQ_WR='def W: [.workers[]? | select((.t3_kind // "") != "ask")];'; fi

tick_count_mode=0
if [ "${1:-}" = --tick-timeouts ]; then tick_count_mode=1; shift; fi
if [ "$#" -lt 1 ] || [ -z "$1" ] || [ "${1#-}" != "$1" ]; then
    echo "usage: chief-wait.sh <inbox-file> [tick.sh args...]" >&2
    exit 2
fi
inbox="$1"; shift
# The inbox's lines are printed to stdout, so only the bridge's inbox layout
# is read: its canonical path (symlinks resolved) must be
# */consoles/<name>.md, and an existing inbox a regular file with one link.
# A secret (the GO key, .env) never sits at that shape. Checked at start and
# again before each drain, so an inbox swapped for a link mid-wait is refused.
inbox_fence() {
    local canon name
    # prim-ok: canon_path resolves a directory only; the inbox is a file that may be a symlink or not exist yet
    canon="$(realpath -m -- "$inbox")" || canon=""  # gnu-ok: Linux-only kit (PLATFORM GUARD)
    name="${canon##*/}"
    case "$canon" in
        */consoles/*.md) ;;
        *) name="" ;;
    esac
    case "${name%.md}" in
        "" | *[!A-Za-z0-9._-]*) name="" ;;
    esac
    if [ -z "$name" ] || [ "${canon%/consoles/*}/consoles/$name" != "$canon" ] \
        || { [ -e "$inbox" ] && { [ ! -f "$canon" ] || [ "$(stat -c %h -- "$canon")" != 1 ]; }; }; then  # gnu-ok: Linux-only kit
        echo "chief-wait: refusing inbox '$inbox' - it must be a */consoles/<name>.md bridge inbox (a regular file with one link, no symlink out of the layout)" >&2
        return 1
    fi
}
inbox_fence || exit 2
tick_log="$inbox.wait.ticklog"
if [ "$tick_count_mode" = 1 ]; then
    now="$(date +%s)"
    [ -f "$tick_log" ] || tick_log=/dev/null
    awk -v since="$((now - 86400))" '
        { s = $1; sub(/^start=/, "", s); if (s + 0 < since) next; t++; if ($0 ~ / timedout=1$/) n++ }
        END { printf "ticks=%d tick-timeouts=%d window=24h\n", t, n }' "$tick_log"
    exit $?
fi
# Match mode flags only outside option values. Keep tick's value options here
# so a literal --stream token used as a value stays on the one-shot path.
mode_value=0
for mode_arg in "$@"; do
    if [ "$mode_value" = 1 ]; then mode_value=0; continue; fi
    case "$mode_arg" in
        --ack) exec python3 -I "$HERE/chief-wait-stream.py" --ack "$inbox" "$@" ;;
        --doc|--token|--workers|--workers-from|--handover-dir|--repo|--ready-dir|--prior|--succession|--silent-min|--since|--receipt) mode_value=1 ;;
        --stream) exec bash "$HERE/chief-wait-stream.sh" "$inbox" "$@" ;;
    esac
done
# page/ack record helpers. A missing lib fails open: no records, the
# page still sends.
if [ -r "$HERE/denial-ack-lib.sh" ]; then . "$HERE/denial-ack-lib.sh"; else denial_page_write() { return 1; }; denial_key() { return 1; }; denial_unacked() { return 1; }; fi
hb_file="$inbox.wait"
key_file="$inbox.wait.state"
interval="${CHIEF_WAIT_INTERVAL:-180}"
poll="${CHIEF_WAIT_POLL_SEC:-1}"
# Stream service only: after CHIEF_WAIT_IDLE_PASSES passes in a row with nothing offered, nothing attempted and no tick
# the loop sleeps CHIEF_WAIT_IDLE_POLL_SEC (never less than the poll) instead of the poll, and the first pass with an
# event or work puts the poll back. It only paces: nothing is decided, dropped or marked by it.
idle_poll="${CHIEF_WAIT_IDLE_POLL_SEC:-1}"
idle_poll_re='^([0-9]+\.?[0-9]*|\.[0-9]+)$'  # a plain non-negative decimal number; anything else (1.2.3, text) is the default
[[ $idle_poll =~ $idle_poll_re ]] || idle_poll=1
idle_runs="${CHIEF_WAIT_IDLE_PASSES:-10}"
case "$idle_runs" in ''|0|*[!0-9]*) idle_runs=10 ;; esac
awk -v a="$idle_poll" -v b="$poll" 'BEGIN { exit !(a + 0 > b + 0) }' || idle_poll="$poll"
idle_passes=0
tick_timeout="${CHIEF_WAIT_TICK_TIMEOUT:-120}"
tick_cmd="${CHIEF_WAIT_TICK:-$HERE/tick.sh}"
duty_default="$HERE/chief-duty-sweep.sh"
[ -z "${CHIEF_WAIT_TICK:-}" ] || duty_default=""
duty_cmd="${CHIEF_WAIT_DUTY_CMD-$duty_default}"
duty_timeout="${CHIEF_WAIT_DUTY_TIMEOUT:-60}"
case "$duty_timeout" in ''|*[!0-9]*|??????????*) duty_timeout=60 ;; esac
[ $((10#$duty_timeout)) -gt 0 ] || duty_timeout=60
duty_autorun=0
[ "${CHIEF_WAIT_DUTY_AUTORUN:-}" != 1 ] || duty_autorun=1
duty_file="$inbox.wait.duty"; duty_state="$inbox.wait.duty-state"; duty_fail="$inbox.wait.duty-fail"
duty_t=""

# One waiter per inbox: a second would double every wake. flock is atomic and
# the lock dies with the waiter; every child runs with fd 9 closed, so a killed
# waiter's tick or sleep cannot go on holding it. The inbox's directory may not
# exist yet on a first start; inbox-follow.sh creates the inbox itself.
if ! mkdir -p "$(dirname "$inbox")" || ! exec 9>>"$inbox.wait.lock"; then
    echo "chief-wait: cannot open $inbox.wait.lock" >&2
    exit 1
fi
if ! flock -n 9; then  # gnu-ok: Linux-only kit (util-linux flock, PLATFORM GUARD)  # prim-ok: a non-blocking try-lock held on fd 9 for the waiter's whole life; with_lock blocks and scopes to one command
    # swallow-ok: the pid only decorates the refusal message below; exit 3 does not depend on it
    other="$(sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' "$hb_file" 2>/dev/null | head -n 1)"
    echo "chief-wait: a waiter is already live on $inbox (pid ${other:-?}) — not starting a second" >&2
    exit 3
fi

cur_hash=""; tick_state="-"; exit_reason="unknown"
heartbeat() { # <state> [exit reason]
    local line
    line="hb=$(date +%s) pid=$$ key=${cur_hash:--} tick=$tick_state state=$1"
    [ "${pred_hangs:-0}" -gt 0 ] && line="$line pred_hangs=$pred_hangs"
    [ -n "${2:-}" ] && line="$line exit=$2"
    printf '%s\n' "$line" > "$hb_file.tmp" 2>/dev/null && mv -f "$hb_file.tmp" "$hb_file" 2>/dev/null
}
# digest_flush: every WAKE block ends with what the relay absorbed since the last
# wake (labels and PR numbers only), then the digest starts over.
digest_file="$inbox.wait.digest"
digest_flush() {
    case "$exit_reason" in wake-*) ;; *) return 0 ;; esac
    [ -s "$digest_file" ] || return 0
    # a scripted GO (`<label> auto-go <pr>`) is counted on its own, never as a wrap
    awk '$2 == "auto-go" { g++; a = a (g > 1 ? "," : "") "#" $3; next }
         { n++; l = l (n > 1 ? "," : "") $1; if ($3 != "-") { m++; p = p (m > 1 ? "," : "") "#" $3 } }
         END { printf "absorbed since last wake: wraps=%d (%s) merged=%d (%s)%s\n", n, l, m, p, (g ? sprintf(" auto-go=%d (%s)", g, a) : "") }' "$digest_file" || return 1  # a failed write keeps the digest
    : > "$digest_file"
}
# Housekeeping has its own persisted buffer: an urgent wake must not discard
# events already waiting for their window. Zero retains the pre-digest output.
housekeeping_file="$inbox.wait.housekeeping"
housekeeping_secs="${HOUSEKEEPING_DIGEST_SECS:-900}"
case "$housekeeping_secs" in ''|*[!0-9]*|??????????*) housekeeping_secs=900 ;; esac
housekeeping_secs=$((10#$housekeeping_secs))
housekeeping_add() { # <kind> <detail> [payload]; success means an immediate wake was printed
    if [ "$housekeeping_secs" -ne 0 ] &&
       { [ -f "$housekeeping_file.since" ] || date +%s > "$housekeeping_file.since"; } &&
       printf '%s %s%s\n' "$1" "$2" "${3:+ $3}" >> "$housekeeping_file"; then
        return 1
    fi
    printf 'WAKE %s %s\n' "$1" "$2"
    [ -z "${3:-}" ] || printf '%s\n' "$3"
    return 0
}
housekeeping_flush() {
    local since kinds payload
    [ -s "$housekeeping_file" ] || return 1
    since="$(cat "$housekeeping_file.since" 2>/dev/null)"  # swallow-ok: a torn first write restarts the window
    case "$since" in ''|*[!0-9]*) date +%s > "$housekeeping_file.since"; return 1 ;; esac
    [ $(( $(date +%s) - since )) -ge "$housekeeping_secs" ] || return 1
    payload="$(cat "$housekeeping_file")" || return 1
    kinds="$(printf '%s\n' "$payload" | cut -d' ' -f1 | LC_ALL=C sort -u | paste -sd, -)"
    printf 'WAKE housekeeping kinds=%s\n' "$kinds" || return 1
    printf '%s\n' "$payload" || return 1
    rm -f "$housekeeping_file" "$housekeeping_file.since"
    return 0
}
# lookonly_carry (8934): the next real wake ends with the buffered look-only lines (tick, tick-fail,
# unowned-prs: kind and detail, not the tick payload) and takes them out of the buffer; other
# housekeeping stays queued for its own window. The window's own wake prints the whole buffer.
lookonly_carry() {
    local carried keep
    case "$exit_reason" in wake-housekeeping) return 0 ;; wake-*) ;; *) return 0 ;; esac
    [ -s "$housekeeping_file" ] || return 0
    carried="$(grep -E '^(tick|tick-fail|unowned-prs) ' "$housekeeping_file" | sed 's/ TICK .*//' | awk '!seen[$0]++')"  # swallow-ok: no match reads empty, nothing to carry
    [ -n "$carried" ] || return 0
    printf 'look-only since last wake:\n%s\n' "$carried" || return 1  # a failed write keeps the entries queued
    keep="$(grep -vE '^(tick|tick-fail|unowned-prs) ' "$housekeeping_file")"  # swallow-ok: no other line reads empty
    if [ -n "$keep" ]; then
        printf '%s\n' "$keep" > "$housekeeping_file.tmp" && mv -f "$housekeeping_file.tmp" "$housekeeping_file"
    else
        rm -f "$housekeeping_file" "$housekeeping_file.since"
    fi
}
# Bash holds a trapped signal until the foreground command it is running exits, and a `$(...)` counts as
# one: a stop signal that lands during the poll sleep, a slow tick or the bank read ends the waiter only
# when that step does. The steps that wait on a child (the poll sleep, the tick, the bank read) therefore
# run it in the background and `wait` on it, which a trapped signal interrupts at once, and the stop
# traps TERM that child without waiting for it (a `timeout`-wrapped child then ends itself within its
# own kill grace).
child_pid=""
stoppable() {
    local out="$1" err="$2" rc
    shift 2
    "$@" > "$out" 2> "$err" 9>&- &
    child_pid=$!
    wait "$child_pid"; rc=$?
    child_pid=""
    return "$rc"
}
nap() {
    sleep "$1" 9>&- &
    child_pid=$!
    wait "$child_pid"
    child_pid=""
}
duty_run() {
    duty_t=""
    [ -n "$duty_cmd" ] && [ -n "$console_doc" ] && [ -n "$legs_from" ] || return 0
    local rc t since
    heartbeat sampling
    stoppable "$hb_file.duty-out" "$hb_file.duty-err" env CHIEF_DUTY_AUTORUN="$duty_autorun" \
        timeout -k 2 "$duty_timeout" bash "$duty_cmd" --doc "$console_doc" --workers-from "$legs_from"  # gnu-ok: Linux-only kit (timeout)
    rc=$?
    t="$(date +%s)"
    if [ "$rc" -eq 0 ]; then
        atomic_write "$duty_file" < "$hb_file.duty-out" || return 0
        duty_state_update "$t" && duty_t="$t"
        rm -f "$duty_fail"
    else
        since=""
        [ ! -f "$duty_fail" ] || since="$(awk 'NR == 1 { print $2 }' "$duty_fail")"
        case "$since" in ''|*[!0-9]*) since="$t" ;; esac
        printf '%s %s\n' "$rc" "$since" | atomic_write "$duty_fail"
    fi
    return 0
}
# shellcheck disable=SC2016  # awk source, not shell
duty_id_awk='function duty_id(   i, s) { s = $3; if ($2 == "guard-refusal") for (i = 4; i <= NF && $i != "::"; i++) s = s ":" $i; return s }'
duty_state_update() {
    local old="$duty_state" new
    [ -f "$old" ] || old=/dev/null
    new="$(awk -v t="$1" "$duty_id_awk"'
        FILENAME == ARGV[1] { if (NF == 6) { k = $1 " " $2; ph[k] = $3; first[k] = $4; last[k] = $5; shown[k] = $6 } next }
        $1 == "DUTY?" || $1 == "DUTY" {
            p = "-"
            if ($1 == "DUTY?") {
                id = $2
                for (i = 3; i < NF; i++) id = id ":" $i
                k = "? " id
            } else {
                k = $2 " " duty_id()
                why = substr($0, index($0, " :: ") + 4)
                if ((c = index(why, " :: next: ")) > 0) why = substr(why, 1, c - 1)
                if ($2 == "ci-masked") {
                    if (index(why, "rerun sent") || index(why, "reserved by another sweep")) p = "sent"
                    else if (index(why, "held: drain")) p = "drain"
                    else if (index(why, "held:")) p = "held"
                } else if ($2 == "judge-owed" && index(why, "judge-pending:")) p = "pending"
            }
            if (!(k in ph) || ph[k] != p) { ph[k] = p; first[k] = t; shown[k] = 0 }
            last[k] = t
        }
        $1 == "DUTY-RAN" && / rc=0$/ { done_id[$2 " " $3] = 1 }
        END {
            for (k in done_id) if (k in ph) shown[k] = 1
            for (k in ph) if (t - last[k] < 600) print k, ph[k], first[k], last[k], shown[k]
        }' "$old" "$duty_file" | LC_ALL=C sort)" || return 1
    printf '%s' "${new:+$new
}" | atomic_write "$duty_state"
}
duty_wake() {
    [ -n "$duty_t" ] || return 1
    local ids
    ids="$(awk -v t="$duty_t" '
        $5 == t && $6 == 0 && ($4 < t || $1 == "guard-refusal") {
            age = 0
            if ($1 == "go-owed") age = 1800
            else if ($1 == "answer-owed") age = 1200
            else if ($1 == "dispatch-owed" || $1 == "judge-running" || $1 == "owed-stale" || $1 == "?") age = -1
            else if ($1 == "ci-masked" && ($3 == "sent" || $3 == "drain")) age = -1
            if (age >= 0 && t - $4 >= age) print $1 ":" $2
        }' "$duty_state" | LC_ALL=C sort)"
    [ -n "$ids" ] || return 1
    printf 'WAKE chief-duty %s new=%s\n' "$(printf '%s\n' "$ids" | grep -c .)" "$(printf '%s\n' "$ids" | paste -sd, -)"
}
duty_carry() {
    case "$exit_reason" in wake-*) ;; *) return 0 ;; esac
    [ -n "$duty_cmd" ] || return 0
    if [ -z "$console_doc" ]; then printf 'chief-duty off: no --doc\n'; return 0; fi
    if [ -z "$legs_from" ]; then printf 'chief-duty off: no --workers-from\n'; return 0; fi
    local state="$duty_state" at stale="" body marked rc since
    [ -f "$state" ] || state=/dev/null
    if [ -f "$duty_file" ] && awk '
        FILENAME == ARGV[1] { if ($1 == "?" && $5 - $4 >= 900) old[$2] = 1; next }
        $1 == "DUTY" || $1 == "DUTY-RAN" { found = 1 }
        $1 == "DUTY?" { id = $2; for (i = 3; i < NF; i++) id = id ":" $i; if (id in old) found = 1 }
        END { exit !found }' "$state" "$duty_file"; then
        at="$(stat -c %Y "$duty_file")" || return 1  # gnu-ok: Linux-only kit
        [ $(( $(date +%s) - at )) -le 900 ] || stale=" stale"
        body="$(awk '
            $1 == "DUTY" && $2 == "owed-stale" { n++; if (!slot) slot = ++m; next }
            $1 == "DUTY?" || $1 == "DUTY" || $1 == "DUTY-RAN" { out[++m] = $0 }
            END {
                if (slot) out[slot] = "DUTY owed-stale x" n " (not listed; run the sweep by hand)"
                for (i = 1; i <= m; i++) print out[i]
            }' "$duty_file")" || return 1
        printf 'chief-duty %s as of %sZ%s:\n%s\n' "$(grep -c '^DUTY ' "$duty_file")" \
            "$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%S)" "$stale" "$body" || return 1  # gnu-ok: Linux-only kit
        if [ -f "$duty_state" ]; then
            marked="$(awk "$duty_id_awk"'
                FILENAME == ARGV[1] { if ($1 == "DUTY" && $2 != "owed-stale") printed[$2 " " duty_id()] = 1; next }
                { if (($1 " " $2) in printed) $6 = 1; print }' "$duty_file" "$duty_state")" || return 1
            printf '%s' "${marked:+$marked
}" | atomic_write "$duty_state"
        fi
    fi
    [ -f "$duty_fail" ] || return 0
    read -r rc since < "$duty_fail" || return 0
    printf 'chief-duty sweep failing rc=%s since %sZ\n' "$rc" "$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%S)"  # gnu-ok: Linux-only kit
}
child_stop() { [ -z "$child_pid" ] || kill "$child_pid" 2>/dev/null; return 0; }  # swallow-ok: a child that already ended needs no kill
trap '[ -z "${marker_carry_on:-}" ] || marker_carry; [ -z "${renudge_sampled:-}" ] || renudge_carry; duty_carry; lookonly_carry; digest_flush; heartbeat exited "$exit_reason"' EXIT
trap "exit_reason='signal-TERM'; child_stop; exit 143" TERM
trap "exit_reason='signal-INT'; child_stop; exit 130" INT
trap "exit_reason='signal-HUP'; child_stop; exit 129" HUP
# The supervisor only samples for a safe point, so a stream child honours a stop request at each one itself.
stream_stop_point() {
    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] || return 0
    if [ -e "$inbox.wait.stop" ]; then exit_reason='stream-stop'; exit 143; fi
    [ -e "$inbox.wait.reap" ] || return 0
    local reap=""
    IFS= read -r reap 2>/dev/null < "$inbox.wait.reap"
    [ "$reap" = "pid=$$" ] || return 0
    exit_reason='stream-reap'; exit 143
}

# with --workers-from (or WORKERS_FROM) the argv never changes when the
# chief dispatches or wraps, so the manifest's worker list is folded into the
# args hash, re-read before every sample: a worker-set change made through the
# manifest is a silent baseline, the same as a re-arm with a new --workers. An
# unreadable manifest hashes as empty (its tick fails that sample anyway).
legs_from="${WORKERS_FROM:-}"
console_doc=""
prev_arg=""
succession=""; silent_min=20
rest_args=()
for a in "$@"; do
    case "$prev_arg" in
        --succession) succession="$a"; prev_arg="$a"; continue ;;
        --silent-min) silent_min="$a"; prev_arg="$a"; continue ;;
        --since|--receipt) prev_arg="$a"; continue ;;
    esac
    case "$a" in --succession|--silent-min|--since|--receipt) prev_arg="$a"; continue ;; esac
    [ "$prev_arg" = --workers-from ] && legs_from="$a"
    [ "$prev_arg" = --doc ] && console_doc="$a"
    prev_arg="$a"
    rest_args+=("$a")
done
set -- ${rest_args[@]+"${rest_args[@]}"}
case "$prev_arg" in --succession|--silent-min|--since|--receipt) echo "chief-wait: $prev_arg needs a value" >&2; exit 2 ;; esac
case "$succession" in -*) echo "chief-wait: --succession needs a session name, got a flag" >&2; exit 2 ;; esac
if [ -n "$succession" ]; then
    case "$succession" in *[!A-Za-z0-9_.-]*) echo "chief-wait: --succession must be a session name" >&2; exit 2 ;; esac
    case "$silent_min" in ''|*[!0-9]*) echo "chief-wait: --silent-min must be whole minutes" >&2; exit 2 ;; esac
    if [ -z "$console_doc" ] || [ ! -f "$console_doc" ]; then
        echo "chief-wait: --succession needs --doc <console doc>" >&2; exit 2
    fi
fi
args_hash_of() { # <tick args...>
    local set=""
    # In manifest order, not sorted: tick prints workers in that order, so a
    # reorder (remove + re-add) moves workers= and must re-baseline too.
    [ -z "$legs_from" ] || set="$(bash "$HERE/fleet-manifest.sh" list "$legs_from" 2>/dev/null)"
    printf '%s\n%s\n' "$*" "$set" | sha256sum | cut -c1-16  # gnu-ok: Linux-only kit (PLATFORM GUARD)
}
if [ -n "$legs_from" ]; then
    args_hash="$(args_hash_of "$@")"
else
    args_hash="$(printf '%s\n' "$*" | sha256sum | cut -c1-16)"  # gnu-ok: Linux-only kit (PLATFORM GUARD)
fi

# bank_word: sets bank_val to the bank-preflight verdict token; non-zero when the read
# failed, timed out, or its last line is not one of the verdict tokens.
bank_word() {
    local out
    bank_val=""
    if [ -n "${CHIEF_WAIT_USAGE:-}" ]; then
        stoppable "$hb_file.bankout" /dev/null bash "$CHIEF_WAIT_USAGE" || return 1
    else
        # gnu-ok: Linux-only kit (timeout). Same side-effect-free spelling tick.sh uses for its fleet census.
        stoppable "$hb_file.bankout" /dev/null env CADENCE_USAGE_LAUNCH='' CADENCE_USAGE_LEDGER=/dev/null \
            timeout -k 5 "$tick_timeout" bash "$REPO/scripts/lib/usage-preflight.sh" || return 1
    fi
    out="$(tail -n 1 "$hb_file.bankout")"
    case "$out" in
        PROCEED|SKIPPED-BANK|SKIPPED-FLEET|BANK-STALE|BANK-UNKNOWN) bank_val="$out" ;;
        *) return 1 ;;
    esac
}

usage_file="$inbox.wait.usage"
record_usage_word_and_detect_recovery() {
    local now="${key##*usage=}" was
    case "$now" in PROCEED|SKIPPED-BANK|SKIPPED-FLEET) ;; *) return 1 ;; esac
    was="$(sed -n 1p "$usage_file" 2>/dev/null)"  # swallow-ok: no file is no saved word
    [ "$now" != "$was" ] || return 1
    printf '%s\n' "$now" | atomic_write "$usage_file" 2>/dev/null || return 1  # swallow-ok: an unwritable marker wakes nothing, never twice
    [ "$now" = PROCEED ] || return 1
    case "$was" in SKIPPED-BANK|SKIPPED-FLEET) recovered_from="$was" ;; *) return 1 ;; esac
}

field() { # <name> <tick line>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
rule_rewake() { awk -F'\t' -v f="$1" '$1 == f { print $4; exit }' "$HERE/wake-rules.tsv"; }
table_wake_read() {
    local root="${HIMMEL_RELEASE_STATE_DIR:-}" anchor hr
    if [ -z "$root" ] && [ -n "${USER_SLUG:-}" ] && [ -n "$(field repair "$tick_line")" ]; then
        anchor="$(cd "$REPO" && . "$REPO/scripts/lib/git-clean.sh" && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || anchor=""  # swallow-ok: an unresolved root is reported as an unavailable remedy, never an invented command
        if [ -n "$anchor" ]; then
            hr="$(cd "${anchor%/.git}" && . "$REPO/scripts/lib/handover-path.sh" && handover_root 2>/dev/null)" || hr=""  # swallow-ok: an unreadable state root keeps the repair wake with remedy unavailable
            [ -z "$hr" ] || root="$hr/$USER_SLUG/$(basename "${anchor%/.git}")/release"
        fi
    fi
    printf '%s\n' "$tick_line" | python3 -I "$HERE/wake-rules.py" --inbox "$inbox" --doc "$console_doc" --release-root "$root" 9>&-
}

# old_key_names: a key saved under the old field names (legs=, legset=, bank=) reads
# as the same key under the new ones, so a restart over it is no change.
old_key_names() {
    printf '%s\n' "$1" | sed -E 's/(^|\|)legs=/\1workers=/; s/(^|\|)legset=/\1workerset=/; s/(^|\|)bank=/\1usage=/; s/(^|\|)cap=/\1residual-cap=/'
}

# tick_stamp: `<epoch.nanos> <children user> <children sys>`; the `times` builtin's second line is
# the CPU of every child this shell has reaped, so two stamps around a tick bracket the tick's own CPU.
# `times` runs in this shell, never in a $(...) or a pipe: a subshell has reaped no children. Sets ts.
tick_stamp() {
    ts="$(date +%s.%N)"  # gnu-ok: Linux-only kit (%N)
    LC_ALL=C times > "$hb_file.times" 2>/dev/null  # C locale: a comma-decimal locale prints 0m0,5s, which awk reads as 0
    ts="$ts $(sed -n 2p "$hb_file.times" 2>/dev/null)"  # swallow-ok: an unreadable stamp logs a zero CPU, never fails the tick
}
tick_log_add() {
    local to=0
    case "$1" in 124|137) to=1 ;; esac
    printf '%s %s\n' "$2" "$3" | LC_ALL=C awk -v rc="$1" -v to="$to" '
        function secs(t,   m, s) { m = t; sub(/m.*/, "", m); s = t; sub(/^[0-9]+m/, "", s); sub(/s$/, "", s); return m * 60 + s }
        { b = $1; e = $4
          cb = secs($2) + secs($3); ce = secs($5) + secs($6)
          printf "start=%d wall=%.2f cpu=%.2f rc=%s timedout=%s\n", b, e - b, ce - cb, rc, to }' >> "$tick_log" 2>/dev/null || true  # swallow-ok: a log that cannot be written loses its line, never the tick
}

# sample: sets tick_line and key (empty on a failed tick, with fail_step naming why).
sample() {
    local f v raw bank rc owed_n t0 t1 extract
    key=""; cap_val=""; fail_step=""
    tick_stamp; t0="$ts"
    stoppable "$hb_file.tickout" "$hb_file.tickerr" timeout -k 5 "$tick_timeout" ${cw_tick_repo:+env "REPO=$cw_tick_repo"} bash "$tick_cmd" "$@"; rc=$?  # gnu-ok: Linux-only kit
    raw="$(<"$hb_file.tickout")"
    tick_stamp; t1="$ts"
    tick_log_add "$rc" "$t0" "$t1"
    # A tick that exits non-zero failed, whatever it printed first.
    if [ "$rc" -ne 0 ]; then
        case "$rc" in 124|137) fail_step="tick-timeout:${tick_timeout}s" ;; *) fail_step="tick-exit:$rc" ;; esac
        tick_err="$(head -n 1 "$hb_file.tickerr" 2>/dev/null | cut -c1-200)"  # swallow-ok: an unreadable stderr file reads empty, the wake still fires
        tick_state=fail; return
    fi
    tick_line="$(printf '%s\n' "$raw" | grep '^TICK ' | head -n 1)"
    owed_notifications="$(printf '%s\n' "$raw" | sed -n 's/^ACTION owed-notify=//p' | head -n 1)"
    if [ -z "$tick_line" ]; then fail_step=no-tick-line; tick_state=fail; return; fi
    # A failed or garbled bank read is a failed sample, not a verdict.
    bank_word || { fail_step=usage-read; tick_state=fail; return; }
    bank="$bank_val"
    tick_state=ok
    cap_val="$(field capacity "$tick_line")"
    # shellcheck disable=SC2013  # table field names are single words, never paths or free text
    for f in $(awk -F'\t' '$0 !~ /^#/ && $5 == "key" && $1 != "usage" { print $1 }' "$HERE/wake-rules.tsv"); do
        v="$(field "$f" "$tick_line")"
        extract="$(awk -F'\t' -v f="$f" '$1 == f {print $2}' "$HERE/wake-rules.tsv")"
        # An older tick.sh prints legs= and legset=; field() matches whole tokens, so max_workers= is never workers=.
        if [ -z "$v" ]; then
            case "$f" in
                workers) v="$(field legs "$tick_line")" ;;
                workerset) v="$(field legset "$tick_line")" ;;
            esac
        fi
        # tracker= is newer than the other fields; a tick line
        # without it (an older kit) just has no tracker key, not a failed sample.
        # vault= is newer still, the same way.
        case "$extract" in *!) ;; *) [ -n "$v" ] || continue ;; esac
        # A field missing from a malformed/partial tick line is a failed
        # sample, never a key with an empty value baked in.
        if [ -z "$v" ]; then fail_step="missing-field:$f"; tick_state=fail; key=""; return; fi
        case "$extract" in class:*) v="${v%%:*}" ;; esac
        # vmrun= keeps its class only, not the counts.
        [ "$f" = vmrun ] && v="${v%%,*}"
        # vmismatch= stays in the key only as a positive count: 0 leaves it out, and ? (a failed
        # audit read) keeps the saved count, so a blip after a positive count is not a change.
        if [ "$f" = vmismatch ]; then
            [ "$v" != '?' ] || v="$(key_field vmismatch "$saved")"
            case "$v" in ''|0) continue ;; esac
        fi
        # hreg= stays in the key whole; hreg=? (a failed read) keeps the saved value, so a blip is no change.
        if [ "$extract" = whole-retain-unknown ]; then
            [ "$v" != '?' ] || v="$(key_field "$f" "$saved")"
            [ -n "$v" ] || continue
        fi
        # parked= keeps the worker names only: the age grows every tick and must not re-wake.
        # The names are sorted: the doc order must not decide the key.
        [ "$extract" = names ] && v="$(printf '%s' "$v" | sed -E 's/:[0-9]+m(,|$)/\1/g' | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
        # holds= keeps the worker names only, sorted: the age grows every tick and must not re-wake.
        # stall= keeps the actionable tokens (conflict, no-ci) only, sorted: ci-slow and idle are
        # report-only. A set with none is left out of the key altogether. stall=? (a probe
        # outage) keeps the saved set, so the same conflict returning is not a new one.
        if [ "$f" = stall ]; then
            if [ "$v" = '?' ]; then
                v="$(key_field stall "$saved")"
            else
                v="$(printf '%s' "$v" | tr ',' '\n' | grep -E ':(conflict|no-ci)$' | LC_ALL=C sort | paste -sd, -)"  # swallow-ok: no match is the empty set
            fi
            [ -n "$v" ] || continue
        fi
        # dispatch= keeps one <run>:<flag> token per late, idle or orphan flag, sorted: the
        # elapsed time and job counts grow every tick and must not wake, nor must stale-head
        # (report-only), and a run losing a flag is no new token. A set with none is left out
        # of the key; dispatch=? keeps the saved set.
        if [ "$f" = dispatch ]; then
            if [ "$v" = '?' ]; then
                v="$(key_field dispatch "$saved")"
            else
                v="$(printf '%s' "$v" | tr ',' '\n' | awk -F: '{ for (i = 2; i <= NF; i++) if ($i == "late" || $i == "idle" || $i == "orphan") print $1 ":" $i }' | LC_ALL=C sort | paste -sd, -)"
            fi
            [ -n "$v" ] || continue
        fi
        key="$key$f=$v|"
    done
    owed_n="$(stale_owed_count "$raw" "$tick_line" "$saved")"
    [ -z "$owed_n" ] || key="${key}owed=$owed_n|"
    key="${key}usage=$bank"
}

changed_fields() { # <old key> <new key>
    printf '%s\n' "$1" | tr '|' '\n' > "$hb_file.old"
    {
        printf '%s\n' "$2" | tr '|' '\n' | while IFS= read -r kv; do
            grep -qxF -- "$kv" "$hb_file.old" || printf '%s\n' "${kv%%=*}"
        done
        # parked= is absent when no worker is parked, so a set that empties is a
        # field missing from the new key, not one that differs.
        if grep -q '^parked=' "$hb_file.old" && ! printf '%s\n' "$2" | tr '|' '\n' | grep -q '^parked='; then
            printf 'parked\n'
        fi
    } | paste -sd, -
    rm -f "$hb_file.old"
}

# Only the closed informational marker list may wait. A new READY, BLOCKED,
# FINDING or unknown marker is an immediate worker event, even on one sample.
worker_changes_routine() { # <old key> <new key>
    awk -v old="$1" -v new="$2" '
    function collect(k, before,   n,a,i,f,v,m,t,j) {
        n = split(k, a, "|")
        for (i = 1; i <= n; i++) {
            f = a[i]; sub(/=.*/, "", f)
            if (f != "tails" && f != "acts") continue
            v = substr(a[i], length(f) + 2); m = split(v, t, ",")
            for (j = 1; j <= m; j++) {
                if (before) seen[f SUBSEP t[j]] = 1
                else if (t[j] != "none" && !((f SUBSEP t[j]) in seen) &&
                         t[j] !~ /:(MERGED|WRAPPED|LIVE|ACK)(#[0-9]+)?$/) urgent = 1
            }
        }
    }
    BEGIN { collect(old, 1); collect(new, 0); exit urgent ? 1 : 0 }'
}
tick_housekeeping() { # <changed fields> <old key> <new key>
    local f
    for f in $(printf '%s' "$1" | tr ',' ' '); do
        case "$f" in board|tails|acts|prs) ;; *) return 1 ;; esac  # 8934: a moved PR set is look-only (a new unowned PR has its own wake)
    done
    worker_changes_routine "$2" "$3"
}

# key_field: <name> <key> — the value of one field inside a pipe-joined key
# (see sample()), the same encoding changed_fields() splits on.
key_field() {
    printf '%s\n' "$2" | tr '|' '\n' | sed -n "s/^$1=//p" | head -n 1
}

# drop_board_ok: <changed csv> <new key> — a board class move TO ok is never
# itself a wake (only a move to STALE/MISSING is); strip it from a changed=
# list so a combined change still names its other real fields.
drop_board_ok() {
    local extract targets value
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r f; do
        extract="$(awk -F'\t' -v f="$f" '$1 == f {print $2}' "$HERE/wake-rules.tsv")"
        case "$extract" in class:*)
            targets="${extract#class:}"; targets="${targets%!}"
            value="$(key_field "$f" "$2")"
            case "$targets" in
                !*) [ "$value" != "${targets#!}" ] || continue ;;
                *) case ",$targets," in *",$value,"*) ;; *) continue ;; esac ;;
            esac ;;
        esac
        printf '%s\n' "$f"
    done | paste -sd, -
}

# drop_holds_left: <changed csv> <old key> <new key> — strips holds from a changed= list
# unless a worker joined the set: a hold that ends (the worker answered) is not an event, and
# the set emptying never shows in changed= at all (the field is simply absent).
drop_holds_left() {
    local old new n joined=""
    old=",$(key_field holds "$2"),"; new="$(key_field holds "$3")"
    for n in $(printf '%s' "$new" | tr ',' ' '); do
        case "$old" in *",$n,"*) ;; *) joined=1 ;; esac
    done
    if [ -n "$joined" ]; then printf '%s\n' "$1"; return; fi
    printf '%s\n' "$1" | tr ',' '\n' | while read -r f; do
        [ "$f" = holds ] && continue
        printf '%s\n' "$f"
    done | paste -sd, -
}

stale_owed_count() {
    local raw="$1" line="$2" saved_key="$3" n
    n="$(printf '%s\n' "$raw" | sed -n 's/^ACTION owed-stale=\([0-9][0-9]*\):.*/\1/p' | head -n 1)"
    [ "$(field owed "$line")" != '?' ] || n="$(key_field owed "$saved_key")"
    case "$n" in ''|*[!0-9]*|0) ;; *) printf '%s' "$n" ;; esac
}

drop_owed_fall() {
    local old new
    old="$(key_field owed "$2")"; new="$(key_field owed "$3")"
    if [ -n "$new" ] && [ "$new" -gt "${old:-0}" ] 2>/dev/null; then printf '%s\n' "$1"; return; fi
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r f; do
        [ "$f" = owed ] && continue
        printf '%s\n' "$f"
    done | paste -sd, -
}

# denials_rose: <old key> <new key> — succeeds only when the denials= value got
# WORSE: a worker the old value lacked, a higher count, or a higher class
# (SHIP-STEP > PAUSE-RISK > REPEAT > none). tick.sh's denials= is a trailing
# window, so a lone denial ageing out (30 min later) moves it to none or
# lowers a count; that is the window closing, not an event.
denial_rank() { case "$1" in SHIP-STEP) echo 3 ;; PAUSE-RISK) echo 2 ;; REPEAT) echo 1 ;; *) echo 0 ;; esac; }
denials_rose() {
    local old new tok otok worker rest n cls on ocls found
    old="$(key_field denials "$1")"; new="$(key_field denials "$2")"
    for tok in $(printf '%s' "$new" | tr ',' ' '); do
        worker="${tok%%:*}"
        case "$worker" in none|skip) continue ;; esac
        rest="${tok#*:}"; n="${rest%%:*}"; cls=""
        case "$rest" in *:*) cls="${rest#*:}" ;; esac
        found=""
        for otok in $(printf '%s' "$old" | tr ',' ' '); do
            [ "${otok%%:*}" = "$worker" ] || continue
            found=1; rest="${otok#*:}"; on="${rest%%:*}"; ocls=""
            case "$rest" in *:*) ocls="${rest#*:}" ;; esac
            [ "$n" -gt "$on" ] 2>/dev/null && return 0
            [ "$(denial_rank "$cls")" -gt "$(denial_rank "$ocls")" ] && return 0
        done
        [ -n "$found" ] || return 0
    done
    return 1
}

# drop_denials_expiry: <changed csv> <old key> <new key> — strips denials from
# a changed= list unless denials_rose; a combined change keeps its other fields.
drop_denials_expiry() {
    if denials_rose "$2" "$3"; then printf '%s\n' "$1"; return; fi
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r f; do
        [ "$f" = denials ] && continue
        printf '%s\n' "$f"
    done | paste -sd, -
}

# drop_stall_resolved: <changed csv> <old key> <new key> [field] — stall= (or dispatch=) wakes
# only when the new value holds a token the old one lacked; a stall resolving is not an event.
drop_stall_resolved() {
    local old new tok fresh="" fld="${4:-stall}"
    old=",$(key_field "$fld" "$2"),"; new="$(key_field "$fld" "$3")"
    for tok in $(printf '%s' "$new" | tr ',' ' '); do
        case "$old" in *",$tok,"*) ;; *) fresh=1 ;; esac
    done
    if [ -n "$fresh" ]; then printf '%s\n' "$1"; return; fi
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r f; do
        [ "$f" = "$fld" ] && continue
        printf '%s\n' "$f"
    done | paste -sd, -
}

# denial_pages: <old key> <new key> — one `<worker> <class> <count>` line per worker
# whose denials= class ROSE to SHIP-STEP or PAUSE-RISK between the two keys (a
# new worker, or a higher class). A count rising inside one class is a wake but not
# a page, so one class rise is one page. The label is reduced to a safe charset:
# it goes into an operator message and a record filename.
denial_pages() {
    local old new tok otok worker rest n cls ocls
    old="$(key_field denials "$1")"; new="$(key_field denials "$2")"
    for tok in $(printf '%s' "$new" | tr ',' ' '); do
        worker="$(printf '%s' "${tok%%:*}" | tr -cd 'A-Za-z0-9._#+-')"
        case "$worker" in ''|none|skip) continue ;; esac
        rest="${tok#*:}"; n="${rest%%:*}"; cls=""
        case "$rest" in *:*) cls="${rest#*:}" ;; esac
        [ "$(denial_rank "$cls")" -ge 2 ] || continue
        ocls=""
        for otok in $(printf '%s' "$old" | tr ',' ' '); do
            [ "${otok%%:*}" = "${tok%%:*}" ] || continue
            rest="${otok#*:}"; ocls=""
            case "$rest" in *:*) ocls="${rest#*:}" ;; esac
        done
        [ "$(denial_rank "$cls")" -gt "$(denial_rank "$ocls")" ] && printf '%s %s %s\n' "$worker" "$cls" "$n"
    done
}

# page_send: <text> — ONE operator Telegram message via the bridge path the kit
# already uses (merge-block-alert.sh: the first positive allowFrom of access.json,
# chief-route.ts reply). CHIEF_WAIT_PAGE_CMD replaces it (tests; called as
# `$CMD <text>`, plus the kind as a second argument only when the page has one).
# Bounded by CHIEF_WAIT_PAGE_TIMEOUT (default 45 s) and always
# rc 0: a failed or hung send never breaks the waiter or delays the wake past
# the bound.
page_timeout="${CHIEF_WAIT_PAGE_TIMEOUT:-45}"
page_send() {  # <text> <deadline epoch> [route kind]: the timeout is what is left of the batch budget
    local left=$(( $2 - $(date +%s) ))
    [ "$left" -ge 1 ] || return 0
    if [ -n "${CHIEF_WAIT_PAGE_CMD:-}" ]; then
        timeout -k 2 "$left" "$CHIEF_WAIT_PAGE_CMD" "$1" ${3:+"$3"} </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    else
        # shellcheck disable=SC2016  # $1/$2/$3 expand in the child bash, not here
        timeout -k 2 "$left" bash -c '. "$1" && chat="$(_mba_operator_chat)" && [ -n "$chat" ] && _mba_send "$chat" "$2" "$3"' \
            _ "$REPO/scripts/lib/merge-block-alert.sh" "$1" "${3:-}" </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    fi
    return 0
}

# page_denials: <old key> <new key> — page each denial_pages worker. The page
# record is written FIRST, so the re-dispatch refusal holds even when the send
# fails; both steps fail open. The page text is the worker label, count and class
# only: this file never reads the denial log, only tick.sh's denials= field.
denial_still_parked() {
    local pg pts label ldoc
    pg="$(denial_ack_dir)/$1.page"
    pts="$(denial_field "$pg" ts)"
    label="$(denial_field "$pg" leg | tr -cd 'A-Za-z0-9._#+-')"
    [ -n "$label" ] || label="$1"
    ldoc="$(worker_doc_of "$label")"
    if [ -z "$ldoc" ]; then [ $(( $(stuck_now) - pts )) -le "$stuck_bound_secs" ]; return; fi
    ! doc_written_since "$ldoc" "$pts"
}
page_denials() {
    local worker cls n end rc_name kind held key
    end=$(( $(date +%s) + page_timeout ))  # one budget for the whole batch, not one per worker
    denial_pages "$1" "$2" | while read -r worker cls n; do
        key="$(denial_key "$worker")"
        held="$(denial_unacked "$key" 2>/dev/null)" && [ "$(denial_rank "${held%% *}")" -ge "$(denial_rank "$cls")" ] && denial_still_parked "$key" && continue
        kind=denial-page
        denial_page_write "$worker" "$n" "$cls" || kind=""
        # A native worker launched with Remote Control is answered from the
        # Claude app; name its session. No such session found (claudex, unprofiled): the plain text.
        rc_name="$(rc_session_for "$worker")"
        if [ -n "$rc_name" ]; then
            page_send "DENIAL-PAGE $worker $cls x$n - a classifier denial parked this worker. Open the Remote Control session $rc_name in the Claude app and answer there, or review it and: ack-denial.sh $worker" "$end" $kind
        else
            page_send "DENIAL-PAGE $worker $cls x$n - a classifier denial parked this worker. Review it, then: ack-denial.sh $worker" "$end" $kind
        fi
    done
}

stuck_secs=1800
stuck_bound_secs=86400
stuck_now() {
    local filenow=""
    if [ "${HIMMEL_TEST_FIXTURE:-}" = 1 ] && [ -n "${CHIEF_WAIT_NOW_FILE:-}" ] && [ -r "$CHIEF_WAIT_NOW_FILE" ]; then
        read -r filenow < "$CHIEF_WAIT_NOW_FILE"
        case "$filenow" in ''|*[!0-9]*) ;; *) printf '%s' "$filenow"; return 0 ;; esac
    fi
    case "${CHIEF_WAIT_NOW:-}" in ''|*[!0-9]*) ;; *) [ "${HIMMEL_TEST_FIXTURE:-}" = 1 ] && { printf '%s' "$CHIEF_WAIT_NOW"; return 0; } ;; esac
    date +%s
}

holdask_file="$inbox.wait.holdasks"
holdstuck_file="$inbox.wait.holdstuck"
holdwoke_file="$inbox.wait.holdwoke"
page_hold_asks() {
    local asks key path holder cmd kind end now ptime first woke=1
    asks="$(timeout -k 2 20 python3 -I "$HERE/holds.py" asks --repo "$REPO" --open-prs "$(field prs "$tick_line")" 2>/dev/null </dev/null 9>&-)" || return 1  # gnu-ok: Linux-only kit; swallow-ok: an unreadable register wakes and pages nothing this sample, the next one asks again
    end=$(( $(date +%s) + page_timeout ))
    now="$(stuck_now)"
    while IFS=$'\t' read -r key path holder cmd kind; do
        [ -n "$cmd" ] || continue
        case "$kind" in hold-ask-chief) ;; *) kind=hold-ask-operator ;; esac
        ptime=""
        [ ! -f "$holdask_file" ] || ptime="$(awk -F'\t' -v k="$key" -v p="$path" '$1 == k && $2 == p { print ($3 ~ /^[0-9]+$/ ? $3 : 0); exit }' "$holdask_file")"
        first=""
        if [ -z "$ptime" ]; then
            printf '%s\t%s\t%s\n' "$key" "$path" "$(date +%s)" >> "$holdask_file"
            first=1
        fi
        if [ "$kind" = hold-ask-chief ]; then
            ! grep -qxF -- "$key"$'\t'"$path" "$holdwoke_file" 2>/dev/null || continue
            printf '%s\t%s\n' "$key" "$path" >> "$holdwoke_file"
            printf 'WAKE hold-ask %s wants %s (held by %s). Grant: %s\n' "$key" "$path" "$holder" "$cmd"
            woke=0
            continue
        fi
        if [ -n "$first" ]; then
            page_send "HOLD-ASK $key wants $path (held by $holder). Paste in a real terminal, not a Claude window, and type the path back: $cmd" "$end" "$kind"
            continue
        fi
        [ $(( now - ptime )) -ge "$stuck_secs" ] || continue
        ! grep -qxF -- "$key"$'\t'"$path" "$holdstuck_file" 2>/dev/null || continue
        printf '%s\t%s\n' "$key" "$path" >> "$holdstuck_file"
        page_send "A file ask waited 30 min: $key wants $path, held by $holder. Blocks: that worker. Do: in a real terminal, run: $cmd" "$end" hold-ask-stuck
    done <<< "$asks"
    return "$woke"
}

doc_written_since() {
    local m
    m="$(stat -c %Y "$1")" || return 1  # gnu-ok: Linux-only kit
    [ "$m" -gt "$2" ]
}
ticket_of_doc() {
    local t
    t="$(basename "${1:-x}" | grep -oE '^[A-Z][A-Z0-9]*-[0-9]+')" || t="its ticket"
    printf '%s' "$t"
}
page_denials_stuck() {
    local d pg key label pts now end ldoc ticket rc_name act cutover
    declare -F denial_stuck_claim >/dev/null || return 0
    d="$(denial_ack_dir)"
    [ -d "$d" ] || return 0
    cutover="$(denial_stuck_cutover)"
    now="$(stuck_now)"
    for pg in "$d"/*.page; do
        [ -r "$pg" ] || continue
        key="$(basename "$pg" .page)"
        denial_unacked "$key" >/dev/null || continue
        pts="$(denial_field "$pg" ts)"
        [ -z "$cutover" ] || [ "$pts" -gt "$cutover" ] || continue
        [ $(( now - pts )) -ge "$stuck_secs" ] || continue
        denial_still_parked "$key" || continue
        label="$(denial_field "$pg" leg | tr -cd 'A-Za-z0-9._#+-')"
        [ -n "$label" ] || label="$key"
        ldoc="$(worker_doc_of "$label")"
        ticket="$(ticket_of_doc "$ldoc")"
        rc_name="$(rc_session_for "$label")"
        act="run ack-denial.sh $label"
        [ -z "$rc_name" ] || act="open the Remote Control session $rc_name in the Claude app, or run ack-denial.sh $label"
        denial_stuck_claim "$key" "$pts" || continue
        end=$(( $(date +%s) + page_timeout ))
        page_send "Worker $label on $ticket has been parked 30 min by a classifier denial ($(denial_field "$pg" class)). Blocks: $ticket. Do: $act" "$end" denial-stuck
    done
    return 0
}

# rc_session_for: <worker label> - prints the Remote Control session name of the live
# claude whose cwd is in worktree <label> (the page label is the worktree slug), or
# nothing. Reads /proc only (CHIEF_WAIT_PROC for a suite); the name is session text
# from a process argv, kept to a safe charset before it goes into a message.
rc_session_for() {
    local p cwd name
    for p in "${CHIEF_WAIT_PROC:-/proc}"/[0-9]*; do
        cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue  # swallow-ok: a proc entry that exited or is not ours is skipped
        case "$cwd" in */worktrees/"$1"|*/worktrees/"$1"/*) ;; *) continue ;; esac
        name="$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | awk 'prev == "--remote-control" { print; exit } { prev = $0 }')"  # swallow-ok: an unreadable cmdline names no session, the plain page text goes out
        case "$name" in ''|*[!A-Za-z0-9._#+-]*) continue ;; esac
        printf '%s' "$name"
        return 0
    done
    return 0
}

# capacity=UNDERFILLED:<n> (tick.sh already folds TICK_UNDERFILL_MIN
# into it) wakes on the streak's first sample. The marker file outlives the waiter, so a
# re-arm inside the same streak stays quiet; capacity=ok removes it. Its first line is the
# pool's dispatchable key set at the last wake; once the marker is
# CHIEF_WAIT_UNDERFILL_REPOOL_SEC old (default 1800) the pool is probed again and a changed,
# non-empty key set wakes once more (a pool that grew from empty, or moved): the first
# probe may have read a transient empty pool, and the streak never re-woke on it.
underfill_file="$inbox.wait.underfill"
pool_paused_file="$inbox.wait.poolpaused"
ghpaused_rows_file="$inbox.wait.ghpausedrows"
ghpaused_seen_file="$inbox.wait.ghpausedwake"
ghpaused_fresh=""
unowned_file="$inbox.wait.unowned"
unowned_none_streak=0
dispatch_cmd="${CHIEF_WAIT_DISPATCH:-$HERE/next-dispatchable.sh}"
pool_probe() { # [timeout secs] sets pool_lf (the dispatch flags), pool_out (the priority-pool pass) and pool_sig (its sorted key set)
    local budget="${1:-${CHIEF_WAIT_DISPATCH_TIMEOUT:-420}}" paused_age deadline=() secs
    ghpaused_fresh=""
    pool_lf=(); pool_out=""; pool_sig=""; pool_summary=""; pool_counts=""; pool_unresolved=""; pool_keys=""; pool_dispatch=""; pool_left=""
    [ -r "$dispatch_cmd" ] || return 0
    if [ -e "$pool_paused_file" ]; then
        paused_age=$(( $(date +%s) - $(stat -c %Y "$pool_paused_file" 2>/dev/null || echo 0) ))  # gnu-ok: Linux-only kit; swallow-ok: a failed stat reads epoch 0, so the probe is due
        if [ "$paused_age" -lt "${CHIEF_WAIT_PAUSED_REPROBE_SEC:-300}" ]; then pool_paused=1; return 1; fi
    fi
    case "${cap_val#UNDERFILLED:}" in ''|*[!0-9]*) ;; *) pool_lf+=(--top "${cap_val#UNDERFILLED:}") ;; esac  # the slack is the slot count pool=<n>/<slots> reads against
    [ -z "$console_doc" ] || pool_lf+=(--doc "$console_doc")  # its Live state `priority:` line ranks tier 1
    [ -z "$legs_from" ] || pool_lf+=(--workers-from "$legs_from")  # live workers' files must reach the collision check
    pool_paused=""
    case "$budget" in
        ''|0|*[!0-9]*) ;;
        *)  secs=$((10#$budget / 2)); [ "$((10#$budget))" -le 40 ] || secs=$((10#$budget - 20))
            [ "$secs" -ge 1 ] || secs=1
            case "${NEXT_DISPATCH_DEADLINE:-}" in ''|*[!0-9]*) ;; *) [ "$((10#$NEXT_DISPATCH_DEADLINE))" -eq 0 ] || [ "$((10#$NEXT_DISPATCH_DEADLINE))" -ge "$secs" ] || secs=$((10#$NEXT_DISPATCH_DEADLINE)) ;; esac
            deadline=(env "NEXT_DISPATCH_DEADLINE=$secs") ;;
    esac
    pool_out="$(${deadline[@]+"${deadline[@]}"} timeout -k 2 "$budget" bash "$dispatch_cmd" --priority-pool-only --dispositions "${pool_lf[@]}" </dev/null 2>/dev/null 9>&-)"; pool_rc=$?  # gnu-ok: Linux-only kit; swallow-ok: the rc is kept and read below, a pause or a timeout is paused, any other failure drops its rows
    case "$pool_rc" in 124|137) pool_paused=1 ;; esac
    case "$pool_out" in '# quota-pause '*|'# gh-stall '*) pool_paused=1 ;; esac
    if [ -n "$pool_paused" ]; then
        case "$pool_rc" in
            124|137) ;;
            *)  case "$(printf '%s\n' "$pool_out" | sed -n 2p)" in
                    '# stale-gh rows='[1-9]*) printf '%s\n' "$pool_out" > "$ghpaused_rows_file" 2>/dev/null && ghpaused_fresh=1 ;;
                    *) rm -f "$ghpaused_rows_file" ;;
                esac ;;
        esac
        pool_out=""
        printf 'pool=paused\n' > "$pool_paused_file" 2>/dev/null  # swallow-ok: the marker is informational, the pause holds without it
        return 1
    fi
    if [ "$pool_rc" -eq 0 ]; then rm -f "$pool_paused_file" "$ghpaused_rows_file" "$ghpaused_seen_file"; else pool_out=""; fi
    pool_summary="$(printf '%s\n' "$pool_out" | DOC='' bash "$HERE/tick.sh" --pool-dispositions --doc "$console_doc" 2>/dev/null)" || pool_summary=""  # swallow-ok: an unavailable interpreter keeps the legacy underfill wake, never an all-clear
    pool_keys="$(printf '%s\n' "$pool_summary" | sed -n 's/^# pool-keys //p')"  # a stacked-series row names its tickets here, joined to its row by line number
    pool_sig="$(printf '%s\n' "$pool_out" | awk -v pk="$pool_keys" '
        BEGIN { n = split(pk, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, " "); if (f[2] == "SERIES") sk[f[1]] = f[3] } }
        NR in sk { m = split(sk[NR], a, ","); for (j = 1; j <= m; j++) print a[j]; next }
        $1 != "NEXT-TIER" && $1 != "RESUME-HELD" && $2 ~ /^[A-Z]+-[0-9]+$/ { print $2 }' | sort -u | paste -sd, -)"
    pool_counts="$(printf '%s\n' "$pool_summary" | sed -n 's/^# pool-counts //p')"
    pool_unresolved="$(printf '%s\n' "$pool_summary" | sed -n '/^# pool-unresolved /p')"
    pool_dispatch="$(printf '%s\n' "$pool_summary" | sed -n 's/^# pool-dispatchable //p')"
    pool_left="$(printf '%s\n' "$pool_summary" | sed -n '/^# pool-left-out /p')"
    # a probe that read the pool and found nothing unresolved ends the streak: a set that returns is a change
    [ -z "$pool_out" ] || [ -n "$pool_unresolved" ] || rm -f "$pool_sig_file"
    return 0
}
pool_view() { # stdin: the pool pass; stdout: its ticket rows grouped under a '# dispatchable in <version>' heading (the version of its '# dropped from' line), then the rest; a listed row's '# disposition' line is dropped, the row already says it
    awk -F'\t' -v pk="$pool_keys" '
        BEGIN { n = split(pk, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, " "); if (f[2] == "SERIES") sk[f[1]] = 1 } }
        /^# dropped from / { ver = $0; sub(/^# dropped from /, "", ver); sub(/:.*/, "", ver) }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                n = split(line[i], f, "\t")
                if (i in sk) kind[i] = "series"
                else if (f[1] ~ /^(LOCAL\??|CLOUD|RESUME|MERGED-NOT-CLOSED)$/ && f[2] ~ /^[A-Z]+-[0-9]+$/) {
                    is_cur = 0
                    m = split(f[4], v, ",")
                    for (j = 1; j <= m; j++) if (ver != "" && v[j] == ver) is_cur = 1
                    kind[i] = is_cur ? "cur" : "other"
                } else if (line[i] ~ /^# disposition [A-Z]+-[0-9]+ listed /) kind[i] = "drop"
                else kind[i] = "rest"
            }
            for (i = 1; i <= NR && kind[i] != "cur" && kind[i] != "other" && kind[i] != "series"; i++) if (kind[i] == "rest") print line[i]  # the header lines before the first row stay first
            first = i
            for (i = 1; i <= NR; i++) if (kind[i] == "cur") { if (!hc++) print "# dispatchable in " ver; print line[i] }
            for (i = 1; i <= NR; i++) if (kind[i] == "other") { if (!ho++ && ver != "") print "# dispatchable in other versions"; print line[i] }
            for (i = 1; i <= NR; i++) if (kind[i] == "series") { if (!hs++) print "# dispatchable as one series worker"; print line[i] }
            for (i = first; i <= NR; i++) if (kind[i] == "rest") print line[i]
        }'
}
ghpaused_wake() {
    local age mtime keys head
    [ -n "${pool_paused:-}" ] && [ -e "$ghpaused_rows_file" ] || return 1
    if [ -z "$ghpaused_fresh" ]; then
        mtime="$(stat -c %Y "$ghpaused_rows_file")" || return 1  # gnu-ok: Linux-only kit
        age=$(( $(date +%s) - mtime ))
        [ "$age" -le "${CHIEF_WAIT_PAUSED_REPROBE_SEC:-300}" ] || return 1
    fi
    keys="$(awk -F'\t' '$NF == "stale-gh" { print $2 }' "$ghpaused_rows_file" | sort -u)"
    [ -n "$keys" ] || return 1
    set_wake "$keys" "$ghpaused_seen_file" 10080 || return 1
    head="$(sed -n 2p "$ghpaused_rows_file")"
    printf 'WAKE underfilled capacity=%s stale-gh rows=%s prs=%s keys=%s\n%s\n' "$cap_val" "$(printf '%s\n' "$head" | sed -n 's/^# stale-gh rows=\([0-9]*\).*/\1/p')" "${head##* prs=}" "$(printf '%s\n' "$keys" | paste -sd, -)" "$tick_line"
    cat "$ghpaused_rows_file"
    printf '# stale-gh rows are read from the Jira mirror while GitHub is paused: a hint, not a launch order; with prs=none no open PR was checked\n'
}
# underfill_wake: prints the WAKE block for the pool pool_probe just read and succeeds. A
# pool-unresolved block whose unresolved lines match the last one woken (or digested) is
# housekeeping: it joins the digest as one line and the call fails; the first sight and any
# change wake at once. HOUSEKEEPING_DIGEST_SECS=0 keeps every block.
pool_sig_file="$inbox.wait.poolhk"
underfill_wake() {
    local blk sum line
    blk="$(underfill_block)" || return 1
    if [ -n "$pool_unresolved" ] && [ "$housekeeping_secs" -gt 0 ]; then
        sum="$(printf '%s|%s|%s\n' "$cap_val" "$pool_sig" "$pool_unresolved" | cksum)"  # capacity and the dispatchable keys count as a change too: an underfilled fleet with new work wakes at once
        if [ "$sum" = "$(cat "$pool_sig_file" 2>/dev/null)" ]; then  # swallow-ok: no marker reads empty, so the first sight wakes
            line="capacity=$cap_val${pool_counts:+ pool=$pool_counts} $(printf '%s' "$pool_unresolved" | tr '\n' ';')"
            grep -qxF -- "pool-unresolved $line" "$housekeeping_file" 2>/dev/null && return 1  # swallow-ok: no buffer yet reads as not queued; the same line queues once per window
            housekeeping_add pool-unresolved "$line" || return 1
            return 0
        fi
        printf '%s\n' "$sum" > "$pool_sig_file" 2>/dev/null
    fi
    printf '%s\n' "$blk"
}
underfill_block() { # prints the WAKE block for the pool pool_probe just read; fail-open on the dispatchable list
    local back="" back_keys="" back_dispatch="" back_summary="" extra="" count="" dkeys="" intake_ver="" wake=underfilled short="" listed="" back_failed="" tail="" declared="" left="" ready_held="" ready_ver=""
    if [ -n "$pool_unresolved" ]; then wake=pool-unresolved
    else
        case "$pool_counts" in
            ''|'?') ;;
            # counted and nothing unresolved: every listed key carries a disposition, yet the slots are idle while the pool lists work
            *) listed="$pool_dispatch"; [ -n "$listed" ] || return 1 ;;
        esac
    fi
    declared="$(printf '%s\n' "$pool_out" | sed -n 's/^# dropped from \([^:]*\):.*/\1/p' | head -n 1)"
    if printf '%s\n' "$pool_out" | awk -F'[=/,]' '/^# pool=/ && ($2 + 0) < ($3 + 0) { f = 1 } $0 == "POOL-EMPTY" { f = 1 } END { exit !f }'; then short=1; fi  # a pool short of its slots, whether the line says LOW or INTAKE:<m>
    [ -z "$short" ] || [ -z "$declared" ] || left="$pool_left"
    [ -n "$pool_summary" ] || [ -z "$pool_out" ] || back_failed=1
    if [ -n "$short" ] && [ -z "$declared" ]; then
        heartbeat sampling
        back="$(timeout -k 2 "${CHIEF_WAIT_DISPATCH_TIMEOUT:-420}" bash "$dispatch_cmd" "${pool_lf[@]}" </dev/null 2>/dev/null 9>&-)" || { back=""; back_failed=1; }  # gnu-ok: Linux-only kit; swallow-ok: a failed or timed-out second pass drops its partial rows and the wake line says backlog=unread, the pool list still prints
        back_summary="$(printf '%s\n' "$back" | DOC='' bash "$HERE/tick.sh" --pool-dispositions 2>/dev/null)" || back_summary=""  # swallow-ok: no keys reads a series row as an unknown row, never a wrong count
        back_keys="$(printf '%s\n' "$back_summary" | sed -n 's/^# pool-keys //p')"
        back_dispatch="$(printf '%s\n' "$back_summary" | sed -n 's/^# pool-dispatchable //p')"
        [ -n "$back_summary" ] || [ -z "$back" ] || back_failed=1
        extra="$(printf '%s\n' "$back" | awk -v pool="$pool_out" -v pk="$pool_keys" -v bk="$back_keys" '
            BEGIN {
                n = split(pool, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, "\t"); if (f[1] != "NEXT-TIER" && f[2] ~ /^[A-Z]+-[0-9]+$/) seen[f[2]] = 1 }
                n = split(pk, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, " "); if (f[2] == "SERIES") { m = split(f[3], a, ","); for (j = 1; j <= m; j++) seen[a[j]] = 1 } }
                n = split(bk, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, " "); if (f[2] == "SERIES") sk[f[1]] = f[3] }
            }
            NR in sk { m = split(sk[NR], a, ","); all = 1; for (j = 1; j <= m; j++) if (!seen[a[j]]) all = 0; if (all) next; print; next }
            $0 == "" || seen[$2] { next }
            { print }')"
    fi
    if [ -n "$short" ] || [ -n "$listed" ]; then
        dkeys="$({ printf '%s\n' "$pool_dispatch"; printf '%s\n' "$back_dispatch"; } | sed '/^$/d' | sort -u)"
        count="$(printf '%s\n' "$dkeys" | grep -c . || true)"  # swallow-ok: grep -c prints 0 and exits 1 on no key
        # the wake line names the keys the count is of, so the chief acts on the tick's own set, never a carried list
        [ "$count" = 0 ] || dkeys="$(printf '%s\n' "$dkeys" | paste -sd, -)"
        [ "$count" != 0 ] || [ -z "$back_failed" ] || count=""  # a failed read is not an empty backlog: no dispatchable=0
    fi
    # one tail on both wakes: dispatchable=<n> keys=<KEYS> backlog=unread (a partial count stays, marked)
    tail="${count:+ dispatchable=$count}${dkeys:+ keys=$dkeys}${back_failed:+ backlog=unread}"
    if [ "$wake" = pool-unresolved ]; then
        printf 'WAKE pool-unresolved capacity=%s%s%s\n%s\n' "$cap_val" "${pool_counts:+ pool=$pool_counts}" "$tail" "$tick_line"
    else
        printf 'WAKE underfilled capacity=%s%s%s\n%s\n' "$cap_val" "${pool_counts:+ pool=$pool_counts}" "$tail" "$tick_line"
    fi
    [ -z "$pool_out" ] || printf '%s\n' "$pool_out" | pool_view
    [ -z "$pool_unresolved" ] || printf '%s\n' "$pool_unresolved"
    ready_held="$(printf '%s\n' "$pool_summary" | sed -n '/^# readiness-held /p')"
    if [ -n "$ready_held" ]; then  # no sum or wake key reads these lines: the record adds no wake
        ready_ver="$(printf '%s\n' "$pool_summary" | sed -n 's/^# readiness \([^ ][^ ]*\) blocked=.*/\1/p' | head -n 1)"
        printf '# readiness rows in %s (c blocked on, d chief-only; release/%s/readiness.jsonl):\n%s\n' "${ready_ver:-$declared}" "${ready_ver:-$declared}" "$ready_held"
    fi
    intake_ver="$(printf '%s\n' "$pool_out" | sed -n 's/^# intake [0-9][0-9]* for \([^:]*\):.*/\1/p' | head -n 1)"  # the line's candidates already printed with the pool; this names the way to file them
    [ "$intake_ver" != "no open version" ] || intake_ver=""  # an older dispatcher's line for no open version: nothing to file into
    [ -z "$intake_ver" ] || printf '%s\n' "# INTAKE: versionless operator work is not in the pool; file each key above with \`jira release request <release> --verb INTAKE --key <KEY> --to $(printf '%q' "$intake_ver") --why <why>\`, then run the rm-run once for the batch"
    [ -z "$extra" ] || printf '# version backlog (second pass without --priority-pool-only; rows already in the pool omitted):\n%s\n' "$extra"
    [ -z "$left" ] || printf '# rows left in %s (not dispatchable, with the reason; a declared release offers no row of another version):\n%s\n' "$declared" "$left"
}
# pool_watch_wake: even a full fleet, or a failed tick sample, may have silently dropped
# version tickets. On the CHIEF_WAIT_UNDERFILL_REPOOL_SEC cadence (marker <inbox>.wait.pool)
# probe the pool; an unresolved key prints the pool-unresolved wake and succeeds.
pool_watch_wake() {
    local pool_watch="$inbox.wait.pool"
    if [ ! -e "$pool_watch" ] || [ "$(( $(date +%s) - $(stat -c %Y "$pool_watch" 2>/dev/null || echo 0) ))" -ge "${CHIEF_WAIT_UNDERFILL_REPOOL_SEC:-$(( $(rule_rewake capacity) * 60 ))}" ]; then  # gnu-ok: chief kit is Linux-only; swallow-ok: an unreadable marker is due
        pool_probe "${CHIEF_WAIT_REPOOL_TIMEOUT:-120}" || return 1
        touch "$pool_watch" 2>/dev/null
        if [ -n "$pool_unresolved" ] && underfill_wake; then
            return 0
        fi
    fi
    return 1
}
# underfill_repool: succeeds (and saves the new key set) when the marker is due for a re-probe
# and the pool's non-empty key set differs from the saved one. A failed probe reads no output and
# never counts. The probe blocks the Telegram path
# and the heartbeat like a tick does, so it gets CHIEF_WAIT_REPOOL_TIMEOUT (default 120), well
# inside the five-minute stale-heartbeat window.
underfill_repool() {
    local age saved_sig
    age=$(( $(date +%s) - $(stat -c %Y "$underfill_file" 2>/dev/null || echo 0) ))  # gnu-ok: Linux-only kit; swallow-ok: a failed stat reads epoch 0, so the probe is simply due
    [ "$age" -ge "${CHIEF_WAIT_UNDERFILL_REPOOL_SEC:-$(( $(rule_rewake capacity) * 60 ))}" ] || return 1
    saved_sig="$(sed -n 1p "$underfill_file" 2>/dev/null)"  # swallow-ok: an unreadable marker reads no saved set, so a non-empty pool wakes
    heartbeat sampling
    pool_probe "${CHIEF_WAIT_REPOOL_TIMEOUT:-120}" || return 1
    resume_stale_scan
    if [ -n "$pool_unresolved" ]; then
        printf '%s\n' "$pool_sig" > "$underfill_file" 2>/dev/null
        return 0
    fi
    if [ -n "$pool_out" ] && [ "$pool_sig" != "$saved_sig" ]; then
        printf '%s\n' "$pool_sig" > "$underfill_file" 2>/dev/null
        [ -n "$pool_sig" ] && return 0
        return 1
    fi
    touch "$underfill_file" 2>/dev/null
    # A successful unchanged/empty pool read does not resolve idle capacity.
    # Stream service reminds on the bounded probe cadence; T5 consumes the
    # same observation without introducing another supervisor.
    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] || return 0
    return 1
}

resume_stale_file="$inbox.wait.resume-stale"
resume_stale_read=""
resume_stale_keys=""
# shellcheck disable=SC2016
resume_stale_body='
. "$1/ticket-status.sh" || exit 70
declare -F ts_park_since_rows >/dev/null || exit 70
log="$(ts_state_dir)/status-events.jsonl"
: > "$3/stale"
[ -e "$log" ] || exit 0
[ -r "$log" ] || exit 70
warn="$3/warn"
ts_merge_rows() { GH_READ_NO_MAIN_FALLBACK=1 python3 -I "$_TS_LIB_DIR/merge-rows-effective.py" "$@" 2>>"$warn" || echo "merge-rows-effective: warn: the read failed" >> "$warn"; }
jq() { command jq "$@" || echo "merge-rows-effective: warn: the park rows could not be read" >> "$warn"; }
printf "%s\n" "$2" > "$3/keys"
grep -F -f "$3/keys" "$log" > "$3/rows"; found=$?
[ "$found" -le 1 ] || exit 70
[ "$found" -eq 0 ] || exit 0
now="$(ts_now)" || exit 70
ts_park_since_rows "$3/rows" | while IFS="$(printf "\t")" read -r k rule since; do
    [ "$rule" = D5c ] || continue
    grep -qxF -- "$k" "$3/keys" || continue
    due="$(ts_await_due "$since" resume)" || continue
    due_e="$(_ts_epoch_of_iso "$due")" || continue
    [ "$now" -lt "$due_e" ] || printf "%s\n" "$k" >> "$3/stale"
done
! grep -q "merge-rows-effective: warn:" "$warn" 2>/dev/null
'
resume_stale_scan() {
    local keys dir
    resume_stale_read=""; resume_stale_keys=""
    [ -n "$pool_out" ] || return 0
    keys="$(printf '%s\n' "$pool_out" | awk -F'\t' '$1 == "RESUME" && $2 ~ /^[A-Z][A-Z0-9]*-[0-9]+$/ { print $2 }' | sort -u)"
    if [ -z "$keys" ]; then resume_stale_read=1; return 0; fi
    [ -r "$HERE/../../lib/ticket-status.sh" ] || return 0
    dir="$(tmpdir 2>/dev/null)" || return 0  # swallow-ok: no scratch dir is an unread sample
    if MERGE_ROWS_BUDGET_SECS="${MERGE_ROWS_BUDGET_SECS:-10}" timeout -k 2 30 bash -c "$resume_stale_body" _ "$HERE/../../lib" "$keys" "$dir" </dev/null >/dev/null 2>&1 9>&-; then  # gnu-ok: Linux-only kit; swallow-ok: a non-zero rc or a timeout is an unread sample, read below
        resume_stale_read=1
        resume_stale_keys="$(sort -u "$dir/stale" 2>/dev/null | paste -sd, -)"  # swallow-ok: an unreadable result file reads no stale key
    fi
    rm -rf "$dir"
}
resume_stale_wake() {
    [ -n "$resume_stale_read" ] || return 1
    if [ -z "$resume_stale_keys" ]; then rm -f "$resume_stale_file"; return 1; fi
    set_wake "$(printf '%s\n' "$resume_stale_keys" | tr ',' '\n')" "$resume_stale_file" "${CHIEF_WAIT_RESUME_STALE_REWAKE_MIN:-$(rule_rewake resume-stale)}" || return 1
    printf '%s\n' "$resume_stale_keys"
}

# unowned_wake: <unowned-prs value> — succeeds (and refreshes the marker) when the list is
# new to the marker, holds a PR the marker lacks, or the marker is older than the re-wake
# window.
unowned_wake() {
    local nums
    nums="$(printf '%s\n' "$1" | tr ',' '\n' | sed 's/:.*//')"
    set_wake "$nums" "$unowned_file" "${CHIEF_WAIT_UNOWNED_REWAKE_MIN:-$(rule_rewake unowned-prs)}"
}
relaunch_file="$inbox.wait.relaunch"
relaunch_wake() {
    local fired items
    case "$1" in
        ''|none) rm -f "$relaunch_file"; return 1 ;;
    esac
    fired="$(printf '%s\n' "$1" | tr ',' '\n' | sed 's/^#//' | grep -vx '?')"
    [ -n "$fired" ] || return 1
    items="$fired"
    case ",$1," in *',?,'*) items="$(printf '%s\n' "$fired" "$(cat "$relaunch_file" 2>/dev/null)" | awk 'NF && !seen[$0]++')" ;; esac  # swallow-ok: no marker yet adds nothing to keep
    set_wake "$items" "$relaunch_file" "${CHIEF_WAIT_RELAUNCH_REWAKE_MIN:-60}" || return 1
    printf '%s\n' "$fired" | awk 'NF { i = index($0, ":"); print "WAKE relaunch-owed " substr($0, 1, i - 1) " " substr($0, i + 1) }'
}
heldhi_file="$inbox.wait.heldhi"
held_hi_wake() {
    local keys n shown
    case "$1" in
        '?') return 1 ;;
        '') rm -f "$heldhi_file"; return 1 ;;
    esac
    keys="$(printf '%s\n' "$1" | tr ',' '\n')"
    set_wake "$keys" "$heldhi_file" "${CHIEF_WAIT_HELDHI_REWAKE_MIN:-$(rule_rewake held-hi)}" || return 1
    n="$(printf '%s\n' "$keys" | grep -c .)"
    shown="$(printf '%s\n' "$keys" | head -n 10 | paste -sd, -)"
    [ "$n" -le 10 ] || shown="$shown +$((n - 10)) more"
    printf 'WAKE held-priority n=%s %s\n' "$n" "$shown"
    if grep -q '^# held-hi [^ ]* no-scope ' "$hb_file.tickout"; then
        printf 'fix no-scope: a readiness: comment with a Writes: line, or close; --why-ticket <KEY> names every gate\n'
    fi
    if grep -q '^# held-hi [^ ]* merged-no-remainder ' "$hb_file.tickout"; then
        printf "fix merged-no-remainder: a Remaining: or deferred line in the merged PR's body, or close\n"
    fi
    return 0
}
closecand_file="$inbox.wait.closecand"
close_cand_note() {
    [ -n "$1" ] && [ "$housekeeping_secs" -ne 0 ] || return 1
    [ ! -f "$closecand_file" ] || [ "$1" != "$(cat "$closecand_file")" ] || return 1
    if housekeeping_add close-candidate "$1"; then return 0; fi
    printf '%s\n' "$1" > "$closecand_file"
    return 1
}
unowned_aged_file="$inbox.wait.unowned-aged"
unowned_aged_wake() {
    local aged
    aged="$(printf '%s\n' "$1" | tr ',' '\n' | sed -n 's/^#\([0-9][0-9]*\):\([0-9][0-9]*\)m.*/\1 \2/p' | awk -v m="${CHIEF_WAIT_UNOWNED_WAKE_MIN:-30}" '$2 + 0 >= m + 0 { print $1 }')"
    [ -n "$aged" ] || { rm -f "$unowned_aged_file"; return 1; }
    set_wake "$aged" "$unowned_aged_file" "${CHIEF_WAIT_UNOWNED_REWAKE_MIN:-$(rule_rewake unowned-prs)}" || return 1
    printf '%s\n' "$aged" | paste -sd, -
}
# set_wake: <newline-separated items> <marker file> <re-wake minutes> — the shared marker
# logic: succeeds (and refreshes the marker) when the marker is missing, holds none of
# an item, or is older than the re-wake window.
set_wake() {
    local nums="$1" file="$2" min="$3" num wake=""
    if [ ! -e "$file" ]; then
        wake=1
    elif [ -z "$(find "$file" -mmin "-$min" 2>/dev/null)" ]; then
        wake=1
    else
        for num in $nums; do
            grep -qxF -- "$num" "$file" 2>/dev/null || { wake=1; break; }
        done
    fi
    if [ -z "$wake" ]; then
        # Shrink the marker to the current set, keeping its mtime (the re-wake clock), so an
        # item that leaves and rejoins is new to the marker and wakes at once.
        touch -r "$file" "$file.ref" 2>/dev/null &&
            printf '%s\n' "$nums" > "$file" 2>/dev/null &&
            touch -r "$file.ref" "$file" 2>/dev/null
        rm -f "$file.ref"
        return 1
    fi
    printf '%s\n' "$nums" > "$file" 2>/dev/null
    return 0
}
unclosed_file="$inbox.wait.unclosed"
unclosed_wake() {
    local items l fresh=""
    items="$(printf '%s\n' "$1" | tr ',' '\n')"
    for l in $items; do
        if [ ! -f "$unclosed_file" ] || ! grep -qxF -- "$l" "$unclosed_file"; then fresh="${fresh:+$fresh,}$l"; fi
    done
    set_wake "$items" "$unclosed_file" "${CHIEF_WAIT_UNCLOSED_REWAKE_MIN:-$(rule_rewake unclosed)}" || return 1
    printf '%s\n' "${fresh:-$1}"
}
owed_file="$inbox.wait.owed"
notify_file="$inbox.wait.notify"
notification_wake() {
    if [ -z "$owed_notifications" ]; then
        rm -f "$notify_file"
        return 1
    fi
    # Observation is only the reminder clock. Debt stays in the owed ledger
    # until a real receipt or an explicit chief acknowledgment closes it.
    set_wake "$(printf '%s\n' "$owed_notifications" | tr ',' '\n')" "$notify_file" "${CHIEF_WAIT_NOTIFY_REWAKE_MIN:-60}"
}
owed_wake() {
    local now keys k st first woken new="" out=""
    [ -n "$console_doc" ] && [ -r "$console_doc" ] || return 1
    now="$(date +%s)"
    keys="$(sed -nE 's/^- ([0-9]{1,2}:[0-9]{2} )?OWED ([A-Za-z0-9_.-]+)( .*)?$/\2/p' "$console_doc" | awk '!seen[$0]++')"
    for k in $keys; do
        grep -qE "^- ([0-9]{1,2}:[0-9]{2}Z? )?DELIVERED ${k//./\\.} msg=[0-9]+ chat=-?[0-9]+( .*)?$" "$console_doc" && continue
        st=""
        [ ! -r "$owed_file" ] || st="$(awk -v k="$k" '$1 == k { print $2, $3; exit }' "$owed_file")"
        first="${st% *}"; woken="${st#* }"
        case "$first" in ''|*[!0-9]*) first="$now"; woken=0 ;; esac
        if [ "$woken" != 1 ] && [ $((now - first)) -ge "${CHIEF_WAIT_OWED_SEC:-300}" ]; then
            woken=1; out="${out:+$out,}$k"
        fi
        [ "$woken" = 1 ] || woken=0
        new="$new$k $first $woken"$'\n'
    done
    if [ -n "$new" ]; then printf '%s' "$new" > "$owed_file" 2>/dev/null; else rm -f "$owed_file"; fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}
rmlease_file="$inbox.wait.rmlease"
rmlease_at_file="$inbox.wait.rmlease.at"
rmlease_wake() {
    local rel out rc=0 rc_not_ok=3 anchor cli pk epoch released doc acq pid host now age mt win
    [ -n "$console_doc" ] && [ -r "$console_doc" ] || return 1
    rel="$(sed -n 's/^release:[[:space:]]*//p' "$console_doc" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')"  # swallow-ok: an unreadable doc reads no release
    [[ "$rel" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [ "$rel" != none ] || return 1
    if [ -e "$rmlease_at_file" ] && [ -n "$(find "$rmlease_at_file" -mmin "-${CHIEF_WAIT_RMLEASE_SAMPLE_MIN:-5}" 2>/dev/null)" ]; then return 1; fi  # swallow-ok: an unreadable marker reads as stale, so the read runs
    : > "$rmlease_at_file" 2>/dev/null
    pk="$(jira_project_key)"
    anchor="$(cd "$REPO" && . "$REPO/scripts/lib/git-clean.sh" && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || anchor=""  # swallow-ok: no anchor leaves the CLI unavailable, which reads as an unreadable state
    cli="${anchor%/.git}/scripts/jira/dist/index.js"
    if [ -n "${CHIEF_WAIT_RMLEASE:-}" ]; then
        out="$(timeout -k 2 "${CHIEF_WAIT_RMLEASE_TIMEOUT:-30}" bash "$CHIEF_WAIT_RMLEASE" "$rel" --json </dev/null 2>/dev/null 9>&-)" || rc=$?  # gnu-ok: Linux-only kit; swallow-ok: the rc is kept and read below
    elif [ -n "$anchor" ] && [ -f "$cli" ]; then
        out="$(JIRA_PROJECT_KEY="$pk" timeout -k 2 "${CHIEF_WAIT_RMLEASE_TIMEOUT:-30}" node "$cli" release state "$rel" --json </dev/null 2>/dev/null 9>&-)" || rc=$?  # gnu-ok: Linux-only kit; swallow-ok: the rc is kept and read below
    else
        return 1
    fi
    [ "$rc" -eq 0 ] || [ "$rc" -eq "$rc_not_ok" ] || return 1
    # shellcheck disable=SC2016  # the python program is single-quoted on purpose
    IFS=$'\t' read -r epoch released doc acq pid host < <(printf '%s' "$out" | python3 -I -c '
import datetime, json, sys
try:
    ls = json.load(sys.stdin)["lease"]
    if ls is None:
        print("0\t1\t-\t0\t-\t-")
    else:
        acq = int(datetime.datetime.fromisoformat(ls["acquired"].replace("Z", "+00:00")).timestamp()) if ls.get("acquired") else 0
        print("\t".join([str(int(ls["epoch"])), "1" if ls.get("released") else "0", ls.get("owner_doc") or "-", str(acq), str(ls.get("owner_pid") or "-"), ls.get("owner_host") or "-"]))
except Exception:
    pass
' 2>/dev/null)  # swallow-ok: an unparseable state leaves the fields empty and reads as unreadable
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$released" != 0 ] || [ "$doc" = - ]; then rm -f "$rmlease_file"; return 1; fi
    if [ "$pid" != - ] && [ "$host" = "$(uname -n)" ] && kill -0 "$pid" 2>/dev/null; then rm -f "$rmlease_file"; return 1; fi  # swallow-ok: a gone pid is the stale case
    now="$(date +%s)"
    if [ -e "$doc" ] && mt="$(stat -c %Y "$doc" 2>/dev/null)"; then  # gnu-ok: Linux-only kit; swallow-ok: a failed stat falls back to the lease's acquired time
        age=$(( (now - mt) / 60 ))
    else
        case "$acq" in ''|*[!0-9]*|0) return 1 ;; esac
        age=$(( (now - acq) / 60 ))
    fi
    win="${CHIEF_WAIT_RMLEASE_STALE_MIN:-30}"
    if [ "$age" -lt "$win" ]; then rm -f "$rmlease_file"; return 1; fi
    set_wake "$rel:$epoch" "$rmlease_file" "${CHIEF_WAIT_RMLEASE_REWAKE_MIN:-$(rule_rewake rm-lease)}" || return 1
    printf 'WAKE rm-lease-stale %s %sm\ntakeover: JIRA_PROJECT_KEY=%s node %s release operator takeover %s --epoch %s --doc <absolute successor run doc>, then rm-run %s --doc <the same doc>\n' \
        "$epoch" "$age" "$pk" "$cli" "$rel" "$epoch" "$rel"
}
intake_file="$inbox.wait.intake"
intake_at_file="$inbox.wait.intake.at"
intake_clock() {
    local first
    case "$1" in ''|0|*[!0-9]*) rm -f "$intake_file" "$intake_at_file"; return 1 ;; esac
    first="$(sed -n 1p "$intake_file" 2>/dev/null)"  # swallow-ok: no file reads empty, so the clock starts now
    case "$first" in ''|*[!0-9]*) printf '%s\n0\n' "$(date +%s)" > "$intake_file" 2>/dev/null ;; esac
}
intake_wake() {
    local n="$1" now first last rel pk anchor cli out held
    now="$(date +%s)"
    intake_clock "$n" || return 1
    first="$(sed -n 1p "$intake_file" 2>/dev/null)"  # swallow-ok: an unwritable file leaves no clock, so nothing arms
    case "$first" in ''|*[!0-9]*) return 1 ;; esac
    case "$cap_val" in UNDERFILLED:*) ;; *) return 1 ;; esac
    [ $(( now - 10#$first )) -gt $(( 10#${CHIEF_WAIT_INTAKE_ARM_HOURS:-6} * 3600 )) ] || return 1
    last="$(sed -n 2p "$intake_file" 2>/dev/null)"  # swallow-ok: a missing second line reads as never woken
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - 10#$last )) -ge $(( 10#${CHIEF_WAIT_INTAKE_REWAKE_MIN:-$(rule_rewake INTAKE)} * 60 )) ] || return 1
    [ -n "$console_doc" ] && [ -r "$console_doc" ] || return 1
    rel="$(sed -n 's/^release:[[:space:]]*//p' "$console_doc" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')"  # swallow-ok: an unreadable doc reads no release
    [[ "$rel" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [ "$rel" != none ] || return 1
    if [ -e "$intake_at_file" ] && [ -n "$(find "$intake_at_file" -mmin "-${CHIEF_WAIT_INTAKE_SAMPLE_MIN:-5}" 2>/dev/null)" ]; then return 1; fi  # swallow-ok: an unreadable marker reads as stale, so the read runs
    : > "$intake_at_file" 2>/dev/null
    pk="$(jira_project_key)"
    anchor="$(cd "$REPO" && . "$REPO/scripts/lib/git-clean.sh" && git_env_scrub && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || anchor=""  # swallow-ok: no anchor leaves the CLI unavailable, which reads as an unreadable lease
    cli="${anchor%/.git}/scripts/jira/dist/index.js"
    if [ -n "${CHIEF_WAIT_RMLEASE:-}" ]; then
        out="$(timeout -k 2 "${CHIEF_WAIT_RMLEASE_TIMEOUT:-30}" bash "$CHIEF_WAIT_RMLEASE" "$rel" --json </dev/null 2>/dev/null 9>&-)" || true  # gnu-ok: Linux-only kit; swallow-ok: the CLI's exit 3 still prints the state, a failed read parses to nothing below
    elif [ -n "$anchor" ] && [ -f "$cli" ]; then
        out="$(JIRA_PROJECT_KEY="$pk" timeout -k 2 "${CHIEF_WAIT_RMLEASE_TIMEOUT:-30}" node "$cli" release state "$rel" --json </dev/null 2>/dev/null 9>&-)" || true  # gnu-ok: Linux-only kit; swallow-ok: as above
    else
        return 1
    fi
    held="$(printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    ls = json.load(sys.stdin)["lease"]
    print("no" if ls is None or ls.get("released") else "yes")
except Exception:
    pass
' 2>/dev/null)"  # swallow-ok: an unparseable state prints nothing and arms nothing
    [ "$held" = no ] || return 1
    printf '%s\n%s\n' "$first" "$now" > "$intake_file" 2>/dev/null
    # shellcheck disable=SC2016  # the backticks in the wake text are literal
    printf 'WAKE rm-intake INTAKE=%s since=%sh capacity=%s\nrun: file each INTAKE key (the `# intake` line of the pool, `jira release request %s --verb INTAKE --key <KEY> --to %s --why <why>`), then JIRA_PROJECT_KEY=%s node %s release rm-run %s --doc <absolute run doc>\n' \
        "$n" "$(( (now - 10#$first) / 3600 ))" "$cap_val" "$rel" "$rel" "$pk" "$cli" "$rel"
}
# unwatched_wake: <unwatched= labels, `+`-joined> — a live worker the manifest does not list
# (tick.sh already drops other chiefs' workers). Same marker logic, own marker, own window.
unwatched_file="$inbox.wait.unwatched"
unwatched_wake() {
    set_wake "$(printf '%s\n' "$1" | tr '+' '\n')" "$unwatched_file" "${CHIEF_WAIT_UNWATCHED_REWAKE_MIN:-$(rule_rewake procs)}"
}
# orphan_wake: at an underfilled sample, with --doc, an open PR whose ticket's worker record reads
# wrapped or none (or is absent) and that the doc's `queue:` line does not name wakes (`WAKE orphan-pr <n,...>`
# then its UNMAPPED lines). The check runs gh, so it samples at most every
# CHIEF_WAIT_ORPHAN_SAMPLE_MIN (default 5) minutes; the wake follows the unowned-prs marker
# logic (first sight, a PR new to the marker, CHIEF_WAIT_ORPHAN_REWAKE_MIN, default 60). A clean
# read clears the marker `<inbox>.wait.orphan`; a failed or timed-out read leaves it (not an
# all-clear). CHIEF_WAIT_ORPHAN replaces the check command (tests).
orphan_file="$inbox.wait.orphan"
orphan_at_file="$inbox.wait.orphan.at"
orphan_cmd="${CHIEF_WAIT_ORPHAN:-$HERE/orphan-pr-check.sh}"
orphan_wake() { # prints the WAKE block and returns 0 on a wake
    local out rc=0 nums
    [ -n "$console_doc" ] && [ -f "$console_doc" ] && [ -r "$orphan_cmd" ] || return 1
    if [ -e "$orphan_at_file" ] && [ -n "$(find "$orphan_at_file" -mmin "-${CHIEF_WAIT_ORPHAN_SAMPLE_MIN:-5}" 2>/dev/null)" ]; then return 1; fi  # swallow-ok: an unreadable marker reads as stale, so the check runs
    : > "$orphan_at_file" 2>/dev/null
    out="$(timeout -k 2 "${CHIEF_WAIT_ORPHAN_TIMEOUT:-60}" bash "$orphan_cmd" --doc "$console_doc" </dev/null 2>/dev/null 9>&-)" || rc=$?  # gnu-ok: Linux-only kit; swallow-ok: the rc is kept and only 0 or 1 acts, any other rc is no wake and no all-clear
    case "$rc" in
        0) rm -f "$orphan_file"; return 1 ;;
        1) ;;
        *) return 1 ;;
    esac
    nums="$(printf '%s\n' "$out" | sed -n 's/^UNMAPPED \([0-9][0-9]*\) .*/\1/p')"
    [ -n "$nums" ] || return 1
    set_wake "$nums" "$orphan_file" "${CHIEF_WAIT_ORPHAN_REWAKE_MIN:-$(rule_rewake orphan-pr)}" || return 1
    printf 'WAKE orphan-pr %s\n%s\n%s\n' "$(printf '%s\n' "$nums" | paste -sd, -)" "$out" "$tick_line"
}

stale_file="$inbox.wait.stale"
# stale_wake: <pool-stale= value, `n:KEY,...` with an optional `?`> — prints the keys the marker does
# not hold yet (comma-joined) and succeeds. A full read leaves the marker holding the current set;
# a partial read (a `?` among the keys) only adds to it, so a key already reported never re-wakes.
stale_wake() {
    local keys new
    keys="$(printf '%s\n' "${1#*:}" | tr ',' '\n' | grep -E '^[A-Z]+-[0-9]+$')"  # swallow-ok: no key is an empty list, grep's no-match rc
    [ -n "$keys" ] || return 1
    if [ -e "$stale_file" ]; then
        new="$(printf '%s\n' "$keys" | grep -vxFf "$stale_file" | paste -sd, -)"  # swallow-ok: no new key is an empty list, grep's no-match rc
    else
        new="$(printf '%s\n' "$keys" | paste -sd, -)"
    fi
    case "$1" in
        *'?'*) printf '%s\n' "$keys" >> "$stale_file" 2>/dev/null ;;
        *) printf '%s\n' "$keys" > "$stale_file" 2>/dev/null ;;
    esac
    [ -n "$new" ] || return 1
    printf '%s\n' "$new"
}

refused_file="$inbox.wait.refused"
refused_wake() {
    local stem
    [ -n "$console_doc" ] || return 1
    stem="${console_doc##*/}"
    stem="${stem%.md}"
    # shellcheck disable=SC2016  # the python program is single-quoted on purpose
    python3 -I -c '
import os, re, sys
tsv, marker, today = sys.argv[1:4]
try:
    rows = [l.rstrip("\n").split("\t") for l in open(tsv) if l.strip()]
except OSError:
    sys.exit(1)
# a row is key, ruling, reason, asks_operator and, from a newer tick, ground and remedy; an older four-column row has neither
rows = [r + ["", ""] if len(r) == 4 else r for r in rows if len(r) in (4, 6)]
cl = lambda s: " ".join(re.sub(r"[\x00-\x1f\x7f]", " ", s).split())
try:
    seen = set(l.strip() for l in open(marker))
except OSError:
    seen = set()
try:
    day = open(marker + ".day").read().strip()
except OSError:
    day = ""
pair = lambda r: "%s@%s" % (r[0], r[1])
fresh = [r for r in rows if pair(r) not in seen]
def extra(r):
    g, m = cl(r[4])[:60], cl(r[5])[:500]
    return (" — ground: " + g if g else "") + (" — remedy: " + m if m else "")
lines = ["WAKE rm-refused %s — fix: %s%s" % (pair(r), cl(r[2])[:200], extra(r)) for r in fresh if r[3] == "1"]
woke = [pair(r) for r in fresh if r[3] == "1"]
other = [pair(r) for r in fresh if r[3] == "0"]
if other and day != today:
    first = next((cl(r[5])[:300] for r in fresh if r[3] == "0" and r[5]), "")
    lines.append("WAKE rm-refused-digest %d new: %s%s" % (len(other), ",".join(other[:20]), " — remedy: " + first if first else ""))
    woke += other
    with open(marker + ".day", "w") as f:
        f.write(today + "\n")
keep = [pair(r) for r in rows if pair(r) in seen or pair(r) in woke]
with open(marker + ".tmp", "w") as f:
    f.write("".join(p + "\n" for p in keep))
os.replace(marker + ".tmp", marker)
if not lines:
    sys.exit(1)
print("\n".join(lines))
' "${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/rm-refused-$stem.tsv" "$refused_file" "$(date -u +%Y-%m-%d)" 2>/dev/null
}

lists_file="$inbox.wait.lists"
lists_wake() {
    local stem
    [ -n "$console_doc" ] || return 1
    stem="${console_doc##*/}"
    stem="${stem%.md}"
    python3 -I -c '
import os, re, sys
tsv, marker = sys.argv[1:3]
try:
    rows = [l.rstrip("\n").split("\t") for l in open(tsv) if l.strip()]
except OSError:
    sys.exit(1)
rows = [r for r in rows if len(r) == 6 and r[0] in ("chief", "apart")]
cl = lambda s: " ".join(re.sub(r"[\x00-\x1f\x7f]", " ", s).split())
ident = lambda r: "chief@%s" % r[2] if r[0] == "chief" else "apart@%s@%s@%s@%s" % (r[1], r[3], r[4], r[5])
try:
    seen = set(l.strip() for l in open(marker))
except OSError:
    seen = set()
lines, cur = [], []
for r in rows:
    i = ident(r)
    if i in cur:
        continue
    cur.append(i)
    if i in seen:
        continue
    if r[0] == "chief":
        lines.append("WAKE chief-placed %s %s" % (r[1], cl(r[3])[:200]))
    else:
        lines.append("WAKE ask-apart %s %s parent %s %s" % (r[1], r[3], r[4], r[5]))
with open(marker + ".tmp", "w") as f:
    f.write("".join(i + "\n" for i in cur))
os.replace(marker + ".tmp", marker)
if not lines:
    sys.exit(1)
print("\n".join(lines))
' "${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/rm-lists-$stem.tsv" "$lists_file" 2>/dev/null
}

doctor_file="$inbox.wait.doctor"
# doctor_wake: <doctor= ids, comma-joined> — a doctor WARN/FAIL id the marker does not hold. Prints
# the new ids (comma-joined) and succeeds; the marker then holds the whole current set. No re-wake
# window: an unchanged set never wakes however old the marker. An id that leaves and rejoins is new
# again, because the marker shrinks to the current set on every sample.
doctor_wake() {
    local ids new
    ids="$(printf '%s\n' "$1" | tr ',' '\n')"
    if [ -e "$doctor_file" ]; then
        new="$(printf '%s\n' "$ids" | grep -vxFf "$doctor_file" | paste -sd, -)"  # swallow-ok: no new id is an empty list, grep's no-match rc
    else
        new="$1"
    fi
    printf '%s\n' "$ids" > "$doctor_file" 2>/dev/null
    [ -n "$new" ] || return 1
    printf '%s\n' "$new"
}
cadence_file="$inbox.wait.cadence"
# cadence_wake: <cadence= value, comma-joined entries name:state:age:id[:flag]> — a flagged run id the
# marker does not hold. The first sample (no marker yet) records every run id and wakes nothing. Prints one
# cause line per new flagged run and succeeds; the marker then holds the id (missed-<id> for MISSED), so the
# same run never wakes twice, not even after a re-arm.
cadence_wake() {
    local e name state id flag key base=0 out="" line
    [ -e "$cadence_file" ] || { base=1; : > "$cadence_file" 2>/dev/null; }
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        IFS=: read -r name state _ id flag <<< "$e"
        case "$id" in ''|0|*[!0-9]*) continue ;; esac
        # a run still in flight at the baseline has not finished: leave it out so a red end still wakes
        if [ "$base" -eq 1 ] && [ "$state" = running ]; then continue; fi
        key="$id"; [ "$flag" != MISSED ] || key="missed-$id"
        grep -qxF -- "$key" "$cadence_file" 2>/dev/null && continue
        if [ "$base" -eq 0 ] && [ -z "$flag" ]; then continue; fi
        printf '%s\n' "$key" >> "$cadence_file" 2>/dev/null
        [ "$base" -eq 0 ] || continue
        if [ -n "${CHIEF_WAIT_CADENCE:-}" ]; then
            line="$(timeout -k 2 30 "$CHIEF_WAIT_CADENCE" "$name" "$id" "$flag" 2>/dev/null)"  # gnu-ok: Linux-only kit # swallow-ok: an unreadable cause still wakes, with the fallback line below
        else
            line="$(timeout -k 2 30 bash "$HERE/ci-cadence.sh" cause "$name" "$id" "$flag" 2>/dev/null)"  # gnu-ok: Linux-only kit # swallow-ok: an unreadable cause still wakes, with the fallback line below
        fi || true  # swallow-ok: a cause that cannot be read still wakes, with the line below
        [ -n "$line" ] || line="$name run=$id $flag cause: unreadable, open the run"
        out="${out:+$out
}$line"
    done <<< "$(printf '%s\n' "$1" | tr ',' '\n')"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}
review_file="$inbox.wait.review"
# review_wake: <review= value date:age:failures:new:new5+:filed[:STALE]> — the daily failure review
# (decision 593). Wakes once per review day when the router filed a ticket or a new class has 5 or more
# failures; and once per last-review date when the review is STALE (26 h).
# A 1-count class never wakes. The marker <inbox>.wait.review holds `<date>` and `stale-<date>`, so a
# re-armed waiter replays nothing. Prints `review <date> <reasons>` and succeeds when something is new.
review_wake() {
    local day age big filed f1 f2 reasons="" stale=""
    IFS=: read -r day age _ _ big filed f1 f2 <<< "$1"
    case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
    case ":$f1:$f2:" in *:STALE:*) stale=1 ;; esac
    if [ -n "$stale" ] && ! grep -qxF -- "stale-$day" "$review_file" 2>/dev/null; then
        printf '%s\n' "stale-$day" >> "$review_file" 2>/dev/null
        reasons="STALE (no review for 26 h, last $day, age $age)"
    fi
    if ! grep -qxF -- "$day" "$review_file" 2>/dev/null; then
        local r=""
        case "$filed" in ''|-|'?') ;; *) r="$r filed=$filed" ;; esac
        case "$big" in ''|0|*[!0-9]*) ;; *) r="$r new-classes-5+=$big" ;; esac
        if [ -n "$r" ]; then
            printf '%s\n' "$day" >> "$review_file" 2>/dev/null
            reasons="${reasons:+$reasons }${r# }"
        fi
    fi
    [ -n "$reasons" ] || return 1
    printf 'review %s %s\n' "$day" "$reasons"
}
drift_held() {
    local by="" heads gh_cmd="${CHIEF_WAIT_GH:-$GH_READ_BIN}" re="-drift-([0-9]+-)?$1"
    if [ -n "$legs_from" ] && [ -r "$legs_from" ]; then
        by="$(jq -r --arg re "$re\\.md\$" "$JQ_W"'[W[]? | select((.doc // "") | test($re)) | (.label // "drift")][0] // empty' "$legs_from" 2>/dev/null)"  # swallow-ok: an unreadable manifest holds nothing
    fi
    if [ -z "$by" ]; then
        heads="$(cd "$GATE_DIR" && timeout -k 2 20 env GH_READ_NO_MAIN_FALLBACK=1 "$gh_cmd" pr list --state open --limit 1000 --json number,headRefName -q '.[] | "#\(.number) \(.headRefName)"' </dev/null 2>/dev/null 9>&-)" || heads=""  # gnu-ok: Linux-only kit; swallow-ok: as above
        by="$(printf '%s\n' "$heads" | grep -E -m1 -e "$re\$" | cut -d' ' -f1)"
    fi
    [ -n "$by" ] || return 1
    printf '%s\n' "$by"
}
drift_file="$inbox.wait.drift"
drift_claim_key() { printf '%s-%s' "${1//[!A-Za-z0-9._-]/_}" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
drift_wake() {
    local today dir claim by bucket
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$((10#$1))" -gt 0 ] || return 1
    today="$(date -u +%F)"
    # prim-ok: the inbox was fenced at start; realpath -m resolves the bucket directory the claim is keyed on
    bucket="$(realpath -m -- "$inbox")"; bucket="${bucket%/consoles/*}"  # gnu-ok: Linux-only kit (PLATFORM GUARD)
    dir="${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}"
    claim="$dir/drift-wake-$(drift_claim_key "$bucket")"
    [ ! -e "$claim.$today" ] || return 1
    if by="$(drift_held "$today")"; then
        printf 'drift-actionable %s held-by %s\n' "$1" "$by" > "$drift_file.held" 2>/dev/null  # swallow-ok: the hold note is a diagnostic
        return 1
    fi
    mkdir -p "$dir" 2>/dev/null  # swallow-ok: an unmakable state dir fails the claim below
    (set -C; : > "$claim.$today") 2>/dev/null || return 1  # swallow-ok: a claimed or unclaimable day wakes nothing
    find "$dir" -maxdepth 1 -name "${claim##*/}.*" -mtime +7 -delete 2>/dev/null  # gnu-ok: console kit is Linux-only # swallow-ok: an unprunable old claim is harmless
    printf 'drift-actionable %s\n' "$1"
}
# tracker_stale_wake: <tracker= value> — a tracker that STAYS stale. A class change
# wakes once (above); after the first STALE the class never moves again, so the
# marker holds the epoch the streak was first seen and the wake fires once the
# streak passes CHIEF_WAIT_TRACKER_STALE_MIN (default 30). Any other value ends
# the streak. The marker outlives the waiter, so a re-arm inside a streak stays quiet.
tracker_stale_file="$inbox.wait.trackerstale"
tracker_stale_wake() { stale_streak_wake "$1" "$tracker_stale_file" "${CHIEF_WAIT_TRACKER_STALE_MIN:-$(rule_rewake tracker)}" "$(rule_rewake tracker)"; }
# board_stale_wake: <board= value> — the same for a board that stays stale, marker
# <inbox>.wait.boardstale, threshold CHIEF_WAIT_BOARD_STALE_MIN (default 10).
board_stale_file="$inbox.wait.boardstale"
board_stale_wake() { stale_streak_wake "$1" "$board_stale_file" "${CHIEF_WAIT_BOARD_STALE_MIN:-$(rule_rewake board)}" "$(rule_rewake board)"; }
# stale_streak_wake: <value> <marker> <minutes> <default minutes>
stale_streak_wake() {
    local since stale_min
    case "$1" in
        STALE*) ;;
        '') return 1 ;;
        *) rm -f "$2"; return 1 ;;
    esac
    if [ ! -e "$2" ]; then date +%s > "$2" 2>/dev/null; return 1; fi
    [ "$(sed -n 2p "$2" 2>/dev/null)" = woke ] && return 1
    since="$(sed -n 1p "$2" 2>/dev/null)"
    case "$since" in ''|*[!0-9]*) return 1 ;; esac
    stale_min="$3"
    case "$stale_min" in ''|*[!0-9]*) stale_min="$4" ;; esac
    [ $(( $(date +%s) - since )) -ge $(( 10#$stale_min * 60 )) ] || return 1
    printf '%s\nwoke\n' "$since" > "$2" 2>/dev/null
    return 0
}

# budget_wake: the chief's handover budget (chief-budget.sh, via --doc). Finding the
# transcript scans every recent one, so it is resolved once per waiter run (--resolve);
# each sample then reads that one file. An unresolved chief is not measured this run.
# Exit 3 (HANDOVER) wakes and sets the marker `<inbox>.wait.budget`, which outlives the
# waiter; 0 (OK) clears it; 2 (unreadable) does neither. While the verdict stays HANDOVER
# the wake repeats (`WAKE handover-budget repeat ...`) once the marker is older than
# CHIEF_WAIT_BUDGET_REPEAT_MIN minutes (default 30), so a wake the chief absorbed mid-turn
# is not lost; the repeat renews the marker.
budget_file="$inbox.wait.budget"
budget_cmd="${CHIEF_WAIT_BUDGET:-$HERE/chief-budget.sh}"
budget_timeout="${CHIEF_WAIT_BUDGET_TIMEOUT:-30}"
budget_repeat_min="${CHIEF_WAIT_BUDGET_REPEAT_MIN:-30}"
case "$budget_repeat_min" in ''|*[!0-9]*|???????*) budget_repeat_min=30 ;; *) budget_repeat_min=$((10#$budget_repeat_min)) ;; esac  # 7+ digits would overflow the *60 below
[ "$budget_repeat_min" -gt 0 ] || budget_repeat_min=30
budget_transcript=""; budget_resolved=""
budget_wake() {
    local out rc title kind=""
    [ -n "$console_doc" ] || return 1
    title="$(basename "$console_doc" .md)"
    if [ -z "$budget_resolved" ]; then
        budget_resolved=1
        budget_transcript="$(timeout -k 2 "$budget_timeout" bash "$budget_cmd" --title "$title" --resolve 2>/dev/null 9>&-)" || budget_transcript=""  # gnu-ok: Linux-only kit; swallow-ok: a failed resolve leaves the path empty, so the run is not measured
        [ -n "$budget_transcript" ] || echo "chief-wait: budget not measured: cannot resolve the transcript of $title (no recent session carries that customTitle)" >&2
    fi
    [ -n "$budget_transcript" ] || return 1
    out="$(CONTEXT_FILL_TRANSCRIPT="$budget_transcript" timeout -k 2 "$budget_timeout" bash "$budget_cmd" --title "$title" 2>/dev/null 9>&-)"; rc=$?  # gnu-ok: Linux-only kit; swallow-ok: the exit code below decides, only exit 3 reads the output
    if [ "$rc" -ne 3 ]; then
        case "$out" in *" fill="*) [ "$rc" -ne 0 ] || rm -f "$budget_file" ;; esac  # an OK with no fill= is an unmeasured fill: it must not reset the repeat
        return 1
    fi
    if [ -e "$budget_file" ]; then
        [ "$(( $(date +%s) - $(stat -c %Y "$budget_file" 2>/dev/null || echo 0) ))" -ge $(( budget_repeat_min * 60 )) ] || return 1  # gnu-ok: Linux-only kit; swallow-ok: an unreadable marker counts as old, so the wake repeats
        kind="repeat "
    fi
    : > "$budget_file" 2>/dev/null
    printf 'WAKE handover-budget %s%s\n' "$kind" "$out"
}

# sweep_wake: with --doc, the status sweep (status-sweep.sh) runs every WAIT_SWEEP_SEC
# (default 900), bounded at WAIT_SWEEP_TIMEOUT (default 60; the sweep gets a 50 s budget so
# it stops and logs its own miss first). It wakes only when the sweep moved a ticket or reports a
# new failure signature (its own wake=1), never for an unchanged standing problem. The same pass
# reads the FOCUS refresh state (focus-refresh.sh --status) and wakes once per state on FAILED or on
# DIRTY for 10 minutes or more. The last-run stamp `<inbox>.wait.sweep` outlives the waiter; with no
# stamp the first sweep is one interval away. WAIT_SWEEP_CMD and WAIT_FOCUS_CMD replace the
# commands (tests).
sweep_file="$inbox.wait.sweep"
sweep_focus_file="$inbox.wait.focus"
sweep_cmd="${WAIT_SWEEP_CMD:-$HERE/status-sweep.sh}"
focus_cmd="${WAIT_FOCUS_CMD:-$HERE/focus-refresh.sh}"
sweep_sec="${WAIT_SWEEP_SEC:-900}"
sweep_timeout="${WAIT_SWEEP_TIMEOUT:-60}"
warn_loop_key_set() { printf '%s\n' "${1#WARN:}" | sed 's/, /\n/g' | grep -E '^(cycle|unknown) ' | paste -sd, -; }
sweep_wake() {
    local last now out moved fstat age
    [ -n "$console_doc" ] || return 1
    now="$(date +%s)"
    last="$(cat "$sweep_file" 2>/dev/null)"  # swallow-ok: no stamp yet reads empty and starts the interval
    case "$last" in ''|*[!0-9]*) printf '%s\n' "$now" > "$sweep_file" 2>/dev/null; return 1 ;; esac
    [ $((now - last)) -ge "$sweep_sec" ] || return 1
    printf '%s\n' "$now" > "$sweep_file" 2>/dev/null
    out="$(TICKET_STATUS_SWEEP_BUDGET=50 TICKET_STATUS_SWEEP_GRACE=5 timeout -k 2 "$sweep_timeout" bash "$sweep_cmd" 2>/dev/null 9>&-)" || out=""  # gnu-ok: Linux-only kit; swallow-ok: a cut-off or failed sweep logs its own miss row and wakes nothing here
    out="$(printf '%s\n' "$out" | tail -n 1)"
    moved="$(printf '%s\n' "$out" | sed -n 's/.* moved=\([0-9][0-9]*\).*/\1/p')"
    case "$out" in *"wake=1"*) moved=1 ;; esac
    if [ "${moved:-0}" -gt 0 ]; then
        if [ "$housekeeping_secs" -eq 0 ]; then printf 'WAKE status-sweep %s\n' "$out"; return 0; fi
        if housekeeping_add status-sweep "$out"; then return 0; fi
    fi
    fstat="$(timeout -k 2 "$sweep_timeout" bash "$focus_cmd" --doc "$console_doc" --status 2>/dev/null 9>&-)" || fstat=""  # gnu-ok: Linux-only kit; swallow-ok: an unreadable focus state wakes nothing
    fstat="${fstat#focus=}"
    case "$fstat" in
        FAILED:* | DIRTY:unknown) ;;
        WARN:cycle\ * | WARN:unknown\ * | WARN:*,\ cycle\ * | WARN:*,\ unknown\ *) ;;
        DIRTY:*m)
            age="${fstat#DIRTY:}"; age="${age%m}"
            case "$age" in ''|*[!0-9]*) rm -f "$sweep_focus_file"; return 1 ;; esac
            [ "$age" -ge 10 ] || return 1 ;;
        *) rm -f "$sweep_focus_file"; return 1 ;;
    esac
    fkey="$fstat"
    case "$fstat" in DIRTY:*) fkey=DIRTY ;; FAILED:*) fkey=FAILED ;; esac # the marker keys on the state, not the stage: a failure that flips its stage name (timeout, drift:budget) is one failure
    case "$fstat" in WARN:*) fkey="WARN:$(warn_loop_key_set "$fstat")" ;; esac
    [ "$(cat "$sweep_focus_file" 2>/dev/null)" != "$fkey" ] || return 1  # swallow-ok: no marker reads empty, so the first sight wakes
    printf '%s\n' "$fkey" > "$sweep_focus_file" 2>/dev/null
    case "$fstat" in WARN:*) printf 'WAKE focus %s — fix: cut or justify each Blocks edge in the loop, or make the unreadable link readable\n' "$fstat" ;; *) printf 'WAKE focus %s\n' "$fstat" ;; esac
}

# focus_rebuild: with --doc, each tick reads the FOCUS state and, when a status write marked it
# DIRTY or the last refresh FAILED, starts one focus-refresh.sh in the background (detached, so
# the waiter never blocks on it); a refresh of the same doc still running from an earlier tick is left alone.
focus_pid_file="$inbox.wait.focus-pid"
focus_rebuild() {
    local fstat pid
    [ -n "$console_doc" ] || return 0
    pid="$(cat "$focus_pid_file" 2>/dev/null)"  # swallow-ok: no pid file reads empty, so no refresh is running
    case "$pid" in ''|*[!0-9]*) ;; *) ps -ww -p "$pid" -o args= 2>/dev/null | grep -qxF -- "bash $focus_cmd --doc $console_doc" && return 0 ;; esac
    fstat="$(timeout -k 2 "$sweep_timeout" bash "$focus_cmd" --doc "$console_doc" --status 2>/dev/null 9>&-)" || fstat=""  # gnu-ok: Linux-only kit; swallow-ok: an unreadable focus state starts nothing
    case "$fstat" in focus=DIRTY:* | focus=FAILED:*) ;; *) return 0 ;; esac
    setsid bash "$focus_cmd" --doc "$console_doc" </dev/null >/dev/null 2>&1 9>&- &
    printf '%s\n' "$!" > "$focus_pid_file" 2>/dev/null
}

pred_file="$inbox.wait.predecessor"
sweep_turn_file="$inbox.wait.sweep-turn"
close_cmd="${CHIEF_WAIT_CLOSE:-$HERE/close-wrapped-worker.sh}"
pred_hangs=0
pred_hang_list=""; pred_hang_old=""; pred_tried=""
pred_hang_max="${CHIEF_WAIT_CLOSE_HANGS:-3}"
case "$pred_hang_max" in ''|*[!0-9]*|0) pred_hang_max=3 ;; esac
pred_hang_max=$((10#$pred_hang_max))
sweep_close_max="${CHIEF_WAIT_SWEEP_MAX:-4}"
case "$sweep_close_max" in ''|*[!0-9]*) sweep_close_max=4 ;; esac
sweep_close_max=$((10#$sweep_close_max))
sweep_close_min="${CHIEF_WAIT_SWEEP_MIN:-5}"
case "$sweep_close_min" in ''|*[!0-9]*) sweep_close_min=5 ;; esac
sweep_close_min=$((10#$sweep_close_min))
# shellcheck source=../../lanes/lib/claude-sessions.sh
. "$REPO/scripts/lanes/lib/claude-sessions.sh" || exit 2
pred_mark() {
    { PRED_DOC="$2" awk '{ s = $0; sub(/^[a-z]*:/, "", s) } s != ENVIRON["PRED_DOC"]' "$pred_file" 2>/dev/null; printf '%s:%s\n' "$1" "$2"; } | atomic_write "$pred_file"  # swallow-ok: no marker file yet reads empty
}
close_doc_woke() {
    local doc="$1" errf rc n out
    pred_tried="$pred_tried$doc"$'\n'
    heartbeat sampling
    errf="$(mktemp "$pred_file.XXXXXX" 2>/dev/null)" || return 1
    if [ "$2" = --chief ]; then
        out="$(timeout -k 5 "${CHIEF_WAIT_CLOSE_TIMEOUT:-60}" bash "$close_cmd" --chief "$doc" </dev/null 2>"$errf" 9>&-)"; rc=$?
    else
        out="$(timeout -k 5 "${CHIEF_WAIT_CLOSE_TIMEOUT:-60}" bash "$close_cmd" "$doc" </dev/null 2>"$errf" 9>&-)"; rc=$?
    fi
    case "$rc" in
        0) if [[ $out == *CLOSED-ALREADY* ]]; then pred_mark gone "$doc"
           else pred_mark closed "$doc"
               bash "$HERE/append-results.sh" "$console_doc" "$3" </dev/null >/dev/null 2>&1 || true
           fi ;;
        3|4|6|7) ;;
        124|137)
           n="$(printf '%s\n' "$pred_hang_old" | PRED_DOC="$doc" awk -F'\t' '$2 == ENVIRON["PRED_DOC"] { print $1 }')"
           n=$(( ${n:-0} + 1 ))
           pred_hang_list="$pred_hang_list$n	$doc"$'\n'
           [ "$n" -le "$pred_hangs" ] || pred_hangs="$n"
           if [ "$n" -ge "$pred_hang_max" ]; then
               pred_mark woke "$doc"; printf 'WAKE predecessor-open rc=%s\n%s\n%s\n' "$rc" "close hung $n samples in a row" "doc: $doc"; rm -f "$errf"; return 0
           fi ;;
        5) if grep -Fq 'refusing - 0 live session' "$errf"; then pred_mark gone "$doc"
           else pred_mark woke "$doc"; printf 'WAKE predecessor-open rc=5\n%s\n%s\n' "$(head -n 1 "$errf")" "doc: $doc"; rm -f "$errf"; return 0; fi ;;
        *) pred_mark woke "$doc"; printf 'WAKE predecessor-open rc=%s\n%s\n%s\n' "$rc" "$(head -n 1 "$errf")" "doc: $doc"; rm -f "$errf"; return 0 ;;
    esac
    rm -f "$errf"
    return 1
}
sweep_candidates() {
    local dir="$1" skip="$2" rows name pid marked docs=() dated=() g doc now mt stats
    rows="$(claude_sessions 2>/dev/null)"  # swallow-ok: a census that fails or is partial sweeps only the rows it read
    marked=$'\n'"$(sed 's/^[a-z]*://' "$pred_file" 2>/dev/null)"$'\n'  # swallow-ok: no marker file means no doc is done yet
    while IFS=$'\t' read -r pid name _; do
        case "$pid" in ''|'#'*) continue ;; esac
        [[ $name =~ ^(.+)-r[0-9]+$ ]] && name="${BASH_REMATCH[1]}"
        case "$name" in ''|.*|*[!A-Za-z0-9._#+-]*) continue ;; esac
        doc="$dir/$name.md"
        if [ ! -f "$doc" ]; then
            dated=()
            for g in "$dir/$name"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do [ ! -f "$g" ] || dated+=("$g"); done
            [ "${#dated[@]}" -ne 1 ] || doc="${dated[0]}"
        fi
        ! [ "$doc" -ef "$console_doc" ] && ! [ "$doc" -ef "$skip" ] && [ -f "$doc" ] && [ ! -L "$doc" ] || continue
        case "$marked" in *$'\n'"$doc"$'\n'*) continue ;; esac
        case " ${docs[*]-} " in *" $doc "*) continue ;; esac
        docs+=("$doc")
    done <<< "$rows"
    [ "${#docs[@]}" -gt 0 ] || return 0
    now="$(date +%s)"
    stats="$(stat --printf '%Y\t%n\n' -- "${docs[@]}" 2>/dev/null)"  # swallow-ok: a doc gone since the census prints no line
    docs=()
    while IFS=$'\t' read -r mt doc; do
        case "$mt" in ''|*[!0-9]*) continue ;; esac
        [ $(( now - mt )) -lt $(( sweep_close_min * 60 )) ] || docs+=("$doc")
    done <<< "$stats"
    [ "${#docs[@]}" -gt 0 ] || return 0
    awk '
        function emit() { if (l ~ /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?WRAPPED([^A-Za-z0-9_]|$)/) print kind "\t" f }
        FNR == 1 { if (f != "") emit(); f = FILENAME; kind = ($0 ~ / — CHIEF — /) ? "chief" : "worker"; r = 0; seen = 0; fence = ""; l = "" }
        /^ {0,3}(```|~~~)/ { d = $0; sub(/^ */, "", d); d = substr(d, 1, 3); if (fence == "") fence = d; else if (d == fence) fence = ""; next }
        fence != "" { next }
        /^## Results([ \t]|$)/ { r = 1; seen = 1; next }
        /^## / { r = seen && ($0 ~ /^## (Chief|Console) Rulings([ \t]|$)/); next }
        r && /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/ { l = $0 }
        END { if (f != "") emit() }' "${docs[@]}" 2>/dev/null  # swallow-ok: an unreadable doc is no candidate
}
close_sweep_woke() {
    local pred pdoc="" dir l lines=() total start i kind doc n
    pred_hang_old="$pred_hang_list"; pred_hang_list=""; pred_hangs=0; pred_tried=$'\n'
    [ -n "$console_doc" ] && [ -f "$console_doc" ] || return 1
    dir="$(dirname "$console_doc")"
    pred="$(sed -n '1s/.* successor to \([^ ]*\.md\).*/\1/p' "$console_doc")"
    [ -z "$pred" ] || [ ! -f "$dir/$pred" ] || pdoc="$dir/$pred"
    l=$'\n'"$(sed 's/^[a-z]*://' "$pred_file" 2>/dev/null)"$'\n'  # swallow-ok: no marker file means not asked yet
    if [ -n "$pdoc" ] && case "$l" in *$'\n'"$pdoc"$'\n'*) false ;; *) true ;; esac; then
        close_doc_woke "$pdoc" --chief "LIVE — predecessor console ${pred%.md} was WRAPPED and lock-free; the waiter closed its window" && return 0
    fi
    while IFS= read -r l; do [ -z "$l" ] || lines+=("$l"); done <<< "$(sweep_candidates "$dir" "$pdoc")"
    total="${#lines[@]}"
    [ "$total" -gt 0 ] || return 1
    start=0
    if [ "$total" -gt "$sweep_close_max" ]; then
        start="$(cat "$sweep_turn_file" 2>/dev/null)"  # swallow-ok: no turn file starts at the first candidate
        case "$start" in ''|*[!0-9]*) start=0 ;; esac
        start=$(( 10#$start % total ))
        printf '%s\n' "$(( start + sweep_close_max ))" | atomic_write "$sweep_turn_file"
    fi
    for (( i = 0; i < total && i < sweep_close_max; i++ )); do
        l="${lines[$(( (start + i) % total ))]}"; kind="${l%%$'\t'*}"; doc="${l#*$'\t'}"
        close_doc_woke "$doc" "--$kind" "LIVE — wrapped $kind $(basename "$doc" .md) was WRAPPED and lock-free; the waiter closed its window" && return 0
    done
    while IFS=$'\t' read -r n doc; do
        [ -n "$doc" ] || continue
        case "$pred_tried" in *$'\n'"$doc"$'\n'*) ;; *) pred_hang_list="$pred_hang_list$n	$doc"$'\n' ;; esac
    done <<< "$pred_hang_old"
    return 1
}

# r0_relay (the script relay, R0): with --doc and --workers-from, a worker whose tails= is
# WRAPPED or whose acts= is MERGED#<n> is wrapped here instead of waking the console:
# worker-event.sh runs once on a line built from the worker doc's newest bullet of that
# marker (labelled with N<k>, else the doc stem; a WRAPPED is preferred, its residual
# check runs). HANDLED appends `<label> <what> <pr|->` to the digest and sets
# r0_handled; rc 10 with a `-failed rc=3/4/6/7` that is not `step pr-state` (lock held,
# tail not WRAPPED, subtree or subagent alive) stays retryable, except the wrap's own log and board
# steps (they run after the window is closed and the worker retired, so there is nothing to ask
# again); anything else
# prints `WAKE worker-event <first line> rc=<n> out=<file>` and returns 0. After one
# call the relay yields to the inbox; the next sample starts after a retryable worker
# so its standing refusal cannot starve later workers. One-shot, auto_go on: a newest-marker READY
# (tails= READY or READY!stale) goes before any wrap, a retried candidate moves behind the others
# (label plus marker), a READY its own wrap follows stays after the wraps, and a refused READY
# (ESCALATE auto-go or auto-go-error, rc 10) prints `WAKE worker-ready` first. HANDLED and WAKE record
# `<label> <marker> <cksum>` in $r0_file, so one bullet is never run or woken twice.
# R0 takes no lock and sends nothing; RETASK-token-shaped strings are scrubbed from the
# line it passes and the output it keeps.
r0_file="$inbox.wait.r0"
r0_retry=""
if [ -r "$inbox.wait.r0-next" ]; then
    IFS= read -r r0_retry 2>/dev/null < "$inbox.wait.r0-next" || r0_retry=""  # swallow-ok: an unreadable cursor falls back to plain candidate order
fi
leg_event_cmd="${CHIEF_WAIT_WORKER_EVENT:-$HERE/worker-event.sh}"
r0_scrub() { sed -E 's/(^|[^A-Za-z0-9])[A-Z]{1,3}-N[0-9]+-[0-9a-f]{6,}/\1<token>/g'; }

ready_file="$inbox.wait.ready"
ready_re='^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY([^A-Za-z]|$)'
ready_dry_re='^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY[[:space:]]+#?[0-9]+[[:space:]]+[0-9a-f]{40}([^0-9a-f]|$)'
ready_label=""; ready_line=""; ready_bullet=""; ready_off=""
auto_go_on() { ( . "$HERE/../../lib/flags.sh" && himmel_flag auto_go ) >/dev/null 2>&1; }
dry_run_ready_answer() { [ "$1" -eq 10 ] && [ "$2" = "ESCALATE marker-READY" ]; }
ready_newest() {
    case "$(field tails "$tick_line" | tr ',' '\n' | awk -v l="$1" 'index($0, l ":") == 1 { print substr($0, length(l) + 2); exit }')" in
        READY|READY!stale) return 0 ;;
    esac
    return 1
}
ready_pick() {
    local label ldoc cur last entry re="$ready_re" rk="${1:-}" skip="" pass i pick=-1
    local -a pl=() pn=() pb=()
    ready_label=""; ready_off=""
    auto_go_on || { ready_off=1; re="$ready_dry_re"; }
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        entry="$(grep -nE "$re" "$ldoc")"
        cur="$(awk -F'\t' -v l="$label" '$1 == l { c = $2 } END { print c }' "$ready_file" 2>/dev/null)"
        # a doc shorter than its cursor was replaced: start over as a worker met for the first time
        if [ -n "$cur" ] && [ "$cur" -gt "$(wc -l < "$ldoc")" ]; then cur=""; fi
        if [ -z "$cur" ]; then
            last="$(printf '%s\n' "$entry" | tail -n 1 | cut -d: -f1)"
            printf '%s\t%s\n' "$label" "${last:-0}" >> "$ready_file"
            continue
        fi
        entry="$(printf '%s\n' "$entry" | awk -F: -v c="$cur" '$1 + 0 > c { print; exit }')"
        [ -n "$entry" ] || continue
        pl+=("$label"); pn+=("${entry%%:*}"); pb+=("${entry#*:}")
    done <<EOF
$(jq -r "$JQ_WR"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    [ "${#pl[@]}" -gt 0 ] || return 1
    if [ -n "$ready_off" ]; then
        pick=0
    else
        case "$rk" in *" READY") skip="${rk% READY}" ;; esac
        for pass in newest other last; do
            for ((i = 0; i < ${#pl[@]}; i++)); do
                case "$pass" in
                    newest) if [ "${pl[i]}" = "$skip" ] || ! ready_newest "${pl[i]}"; then continue; fi ;;
                    other) [ "${pl[i]}" != "$skip" ] || continue ;;
                esac
                pick=$i; break 2
            done
        done
    fi
    ready_label="${pl[pick]}"; ready_line="${pn[pick]}"; ready_bullet="${pb[pick]}"
}
ready_advance() { # <label> <line>: the cursor moves once the bullet was handed on
    { awk -F'\t' -v l="$1" '$1 != l' "$ready_file" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; } | atomic_write "$ready_file"
}

r0_seen=""
r0_stamp_seen() { # <candidate lines>: when this process first saw each offered event
    local l m n now
    [ -n "$1" ] || return 0
    now="$(date +%s%N)"  # gnu-ok: Linux-only kit (%N)
    while read -r l m n; do
        [ -n "$l" ] && [ "$l" != WARN ] || continue
        case $'\n'"$r0_seen" in *$'\n'"$l $m $n "*) ;; *) r0_seen="${r0_seen:+$r0_seen$'\n'}$l $m $n $now" ;; esac
    done <<EOF
$1
EOF
}
r0_ladder() { # <label> <event cksum> <marker> <out>: space a refused cleanup's retries; returns 0 after printing the top-step wake
    local f="$inbox.wait.le-$1.tries" count="" k="" w="" top=""
    IFS=' ' read -r count k w 2>/dev/null < "$f" || true  # swallow-ok: no file or a torn one starts the count again
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    [ "$k" = "$2" ] || count=0  # another event, or one that changed, starts over; lines appended to the document do not
    count=$(( 10#$count + 1 )); [ "$count" -le 999 ] || count=999
    if [ "$count" -ge 5 ] && [ "${w:--}" != "$2" ]; then
        printf 'WAKE worker-event ESCALATE cleanup-still-refused worker=%s event=%s tries=%s next-try-in=%ss refusal=%s out=%s\n' \
            "$1" "$3" "$count" "$(awk -v b="${CHIEF_WAIT_SERVICE_RETRY_SEC:-5}" 'BEGIN { printf "%g", b * 60 }')" \
            "$(printf '%s\n' "$4" | grep -m 1 '[^[:space:]]')" "$inbox.wait.le-$1"
        w="$2"; top=1
    fi
    printf '%s %s %s\n' "$count" "$2" "${w:--}" | atomic_write "$f"
    [ -n "$top" ]
}
r0_log_attempt() { # <label> <marker> <event line> <call start ns> <call end ns> <rc>: one relaylog line per worker-event call
    local first pend wall size
    # past 1 MiB (the cap of the kit's denial log) the log is renamed to <log>.1, replacing the older copy; one line is one append
    size="$(wc -c 2>/dev/null < "$inbox.wait.relaylog" | tr -d '[:space:]')"  # swallow-ok: a missing log reads size 0 and only skips the rotation
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    [ "$size" -le 1048576 ] || mv -f "$inbox.wait.relaylog" "$inbox.wait.relaylog.1" 2>/dev/null || true  # swallow-ok: a failed rename keeps appending to the old log
    first="$(printf '%s' "$r0_seen" | awk -v k="$1 $2 $3 " 'index($0, k) == 1 { print $NF; exit }')"
    pend=$(( ($4 - ${first:-$4}) / 1000000 )); wall=$(( ($5 - $4) / 10000000 ))
    printf 'start=%s label=%s marker=%s pending=%d.%02d handler=%d.%02d rc=%s\n' "$(( $4 / 1000000000 ))" "$1" "$2" \
        "$(( pend / 1000 ))" "$(( pend % 1000 / 10 ))" "$(( wall / 100 ))" "$(( wall % 100 ))" "$6" >> "$inbox.wait.relaylog" 2>/dev/null || true  # swallow-ok: a log that cannot be written loses its line, never the relay
    [ "$6" -ne 0 ] || r0_seen="$(printf '%s' "$r0_seen" | awk -v k="$1 $2 $3 " 'index($0, k) != 1')"
}

r0_retry_set() {
    if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then r0_retry="$1"; else r0_retry="$1 $2"; fi
    printf '%s\n' "$r0_retry" | atomic_write "$inbox.wait.r0-next"
}
r0_retry_clear() {
    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] || return 0
    [ "$r0_retry" = "$1 $2" ] || [ "$r0_retry" = "$1" ] || return 0
    r0_retry=""
    rm -f "$inbox.wait.r0-next"
}
r0_relay() { # prints the WAKE block and returns 0 only for a worker-event wake
    local cands label marker ldoc bullet sum line stem out rc outf what pr wake_line pending_slow pending_to pending_rc h0 h1 rin ready_first="" ready_picked="" ready_wake_line
    r0_handled=""
    [ -n "$console_doc" ] && [ -n "$legs_from" ] || return 1
    rin="$( { field tails "$tick_line" | tr ',' '\n' | sed -n 's/^\(.*\):WRAPPED$/\1 WRAPPED/p'
              field acts "$tick_line" | tr ',' '\n' | sed -n 's/^\(.*\):MERGED#[0-9]*$/\1 MERGED/p'; } )"
    if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && ready_pick "$r0_retry"; then
        ready_picked=1
        if [ -z "$ready_off" ] && ready_newest "$ready_label"; then
            ready_first=1
            rin="$ready_label READY${rin:+$'\n'$rin}"
        fi
    fi
    cands="$(printf '%s\n' "$rin" | awk -v last="$r0_retry" '
            !NF { next }
            { k = ($2 == "READY") ? $1 " READY" : $1 }
            seen[k]++ { next }
            past { print; next }
            { before = before $0 "\n" }
            (index(last, " ") ? $1 " " $2 : $1) == last { past = 1 }
            END { printf "%s", before }
        ' )"
    if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then
        # Read local pending markers, never an expensive tick, for the stream
        # service pass. The existing relay remains the only action route.
        pending_to="${CHIEF_WAIT_PENDING_TIMEOUT:-20}"
        # Output goes to a file, not a command substitution: the substitution's forked shell would
        # hold the one-waiter lock (fd 9) for as long as the helper runs.
        timeout -k 2 "$pending_to" python3 -I "$HERE/pending-events.py" "$legs_from" "$inbox" "$r0_retry" \
            > "$inbox.wait.pending-out" 2> "$inbox.wait.pending-diagnostic" 9>&-; pending_rc=$?  # gnu-ok: Linux-only kit
        cands=""
        IFS= read -r -d '' cands < "$inbox.wait.pending-out" || true  # swallow-ok: read reports the missing NUL at end of file; the text is already in cands
        case "$pending_rc" in
            0) rm -f "$inbox.wait.pending-error" "$inbox.wait.pending-timeouts" ;;
            124|137)
                # A read that never returns is no answer: no events this pass, try again. The
                # helper writes its cursors only after it has read every document, so nothing
                # moved and no worker was read as having nothing pending.
                printf 'pending-events: no answer within %ss; no events this pass, retrying\n' "$pending_to" >> "$inbox.wait.pending-diagnostic"
                # The streak is counted in a file, so a re-arm over the same hang does not start it
                # again: the third timeout in a row wakes the chief once, and only a pass that
                # answers (above) ends the streak.
                pending_slow="$(sed -n 1p "$inbox.wait.pending-timeouts" 2>/dev/null)"  # swallow-ok: no file or a torn count reads as no streak yet
                case "$pending_slow" in ''|*[!0-9]*) pending_slow=0 ;; esac
                pending_slow=$((10#$pending_slow + 1))
                printf '%s\npending-events: no answer within %ss; %s passes in a row timed out\n' "$pending_slow" "$pending_to" "$pending_slow" > "$inbox.wait.pending-timeouts"
                if [ "$pending_slow" -eq 3 ]; then
                    printf 'WAKE waiter-error pending-events timed-out passes=%s limit=%ss diagnostic=%s\n' "$pending_slow" "$pending_to" "$inbox.wait.pending-timeouts"
                    return 0
                fi
                return 1 ;;
            *)
                if [ ! -e "$inbox.wait.pending-error" ]; then
                    touch "$inbox.wait.pending-error"
                    printf 'WAKE waiter-error pending-events reconcile manifest/cursors diagnostic=%s\n' "$inbox.wait.pending-diagnostic"
                    return 0
                fi
                return 1 ;;
        esac
    else
        if [ -n "$ready_picked" ] && [ -z "$ready_first" ]; then cands="${cands:+$cands$'\n'}$ready_label READY"; fi
    fi
    r0_stamp_seen "$cands"
    [ -z "$cands" ] || r0_offered=1
    local r0_warned="" r0_warning_lines=""
    r0_attempted=""
    while read -r label marker event_line; do
        [ -n "$label" ] || continue
        if [ "$label" = WARN ]; then
            r0_warning_lines+="$(printf 'WAKE waiter-error worker-doc-unread worker=%s reconcile=%s diagnostic=%s' "$marker" "$event_line" "$inbox.wait.pending-diagnostic")"$'\n'
            r0_warned=1
            continue
        fi
        ldoc="$(jq -r --arg l "$label" "$JQ_W"'W[]? | select(.label == $l) | .doc' "$legs_from" 2>/dev/null | head -n 1)"
        [ -n "$ldoc" ] && [ -f "$ldoc" ] || continue
        if [ "$marker" = READY ]; then
            if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then
                ready_line="$event_line"; ready_bullet="$(sed -n "${event_line}p" "$ldoc")"
                # the document may have moved since the collector numbered it: only a READY is relayed
                [[ $ready_bullet =~ $ready_re ]] || continue
                ready_off=""; auto_go_on || ready_off=1
            fi
            bullet="$ready_bullet"
        else
            bullet="$(grep -E "^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?$marker([^A-Za-z]|$)" "$ldoc" | tail -n 1)"
        fi
        [ -n "$bullet" ] || continue
        sum="$label $marker $(printf '%s\n' "$bullet" | cksum | cut -d' ' -f1)"
        # a READY is keyed by its cursor line, not by $r0_file
        [ "$marker" = READY ] || { grep -qxF "$sum" "$r0_file" 2>/dev/null && continue; }
        line="$(printf '%s\n' "$bullet" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?//; s/^\*\*//' | r0_scrub)"
        if [[ $label =~ ^N[0-9]+$ ]]; then
            line="$label $line"
        else
            stem="${ldoc##*/}"; line="$line ${stem%.md}"
        fi
        outf="$inbox.wait.le-$label"
        if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then
            r0_retry="$label"
            printf '%s\n' "$label" | atomic_write "$inbox.wait.r0-next"
        fi
        r0_attempted=1
        heartbeat sampling
        # Allow a slow close and refresh, but stay below heartbeat consumers' 300s
        # floor. Capture the rc: an empty result alone does not prove a timeout.
        h0="$(date +%s%N)"  # gnu-ok: Linux-only kit (%N)
        out="$(printf '%s\n' "$line" | timeout -k 5 240 bash "$leg_event_cmd" --doc "$console_doc" --fleet "$legs_from" - 2>&1 9>&-)"; rc=$?  # gnu-ok: Linux-only kit
        h1="$(date +%s%N)"  # gnu-ok: Linux-only kit (%N)
        r0_log_attempt "$label" "$marker" "$event_line" "$h0" "$h1" "$rc"
        out="$(printf '%s\n' "$out" | r0_scrub)"
        if [ "$rc" -ne 0 ] && ! [[ $out =~ [^[:space:]] ]]; then
            case "$rc" in
                124|137) out="ESCALATE relay-timeout $label rc=$rc limit=240s" ;;
                *) out="ESCALATE relay-failed $label rc=$rc no-output" ;;
            esac
        fi
        printf '%s\n' "$out" > "$outf" 2>/dev/null
        if [ "$marker" = READY ] && [ -n "$ready_off" ] && dry_run_ready_answer "$rc" "$out"; then
            rm -f "$outf.tries"
            printf '%s\n' "$sum" >> "$r0_file"
            ready_advance "$label" "$ready_line"
            r0_retry_clear "$label" "$marker"
            break
        fi
        if [ "$rc" -eq 0 ]; then
            rm -f "$outf.tries" "$outf.slow"
            r0_retry_clear "$label" "$marker"
            printf '%s\n' "$sum" >> "$r0_file"
            [ "$marker" != READY ] || { ready_advance "$label" "$ready_line"; marker_note_bullet "$label" "$bullet"; }
            r0_handled=1
            r0_fold="$r0_fold $label"
            what="$(printf '%s\n' "$out" | sed -n 's/^HANDLED \([a-z-]*\).*/\1/p' | head -n 1)"
            [ "$what" = noop ] && break
            pr=""
            if [ "$what" != close-wrapped ]; then
                pr="$(printf '%s\n' "$line" | grep -oE '(MERGED|READY) #?[0-9]+' | grep -oE '[0-9]+' | head -n 1)"
                [ -n "$pr" ] || pr="$(grep -oE '^- .*(READY|PR) #?[0-9]+' "$ldoc" | tail -n 1 | grep -oE '[0-9]+$')"
            fi
            [ -z "$pr" ] || r0_fold="$r0_fold #$pr"
            printf '%s %s %s\n' "$label" "${what:-handled}" "${pr:--}" >> "$digest_file"
            break  # service the inbox before another slow wrap, next sample
        fi
        if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && [ "$(cat "$outf.slow" 2>/dev/null)" != "${sum##* }" ]; then  # swallow-ok: no marker file reads empty, a first timeout
            printf '%s\n' "${sum##* }" > "$outf.slow"
            r0_retry_set "$label" "$marker"
            break
        fi
        case "$rc:$out" in
            *"step pr-state"*) ;;
            *"wrap-merged: step log failed"*|*"wrap-merged: step board failed"*) ;;
            10:*-failed\ rc=[3467]\ *)
                r0_retry_set "$label" "$marker"
                if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] && r0_ladder "$label" "${sum##* }" "$marker" "$out"; then
                    printf '%s' "$r0_warning_lines"
                    return 0
                fi
                break ;;
        esac
        rm -f "$outf.tries" "$outf.slow"
        r0_retry_clear "$label" "$marker"
        # Print the wake before recording it: a kill between the two leaves the READY or
        # bullet unrecorded, so it is relayed once more (idempotent) and woken again,
        # never recorded and lost.
        wake_line="$(printf 'WAKE worker-event %s rc=%s out=%s' "$(printf '%s\n' "$out" | grep -m 1 '[^[:space:]]')" "$rc" "$outf")"
        if [ "$marker" = READY ] && [ -z "$ready_off" ] && [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && [ "$rc" -eq 10 ]; then
            case "$(printf '%s\n' "$out" | grep -m 1 '[^[:space:]]')" in
                "ESCALATE auto-go "*|"ESCALATE auto-go-error "*)
                    ready_wake_line="$(marker_key "$label" "$bullet")" && printf '%s\n' "${ready_wake_line#*$'\t'}" ;;
            esac
        fi
        printf '%s\n' "$wake_line"
        printf '%s' "$r0_warning_lines"
        printf '%s\n' "$sum" >> "$r0_file"
        [ "$marker" != READY ] || { ready_advance "$label" "$ready_line"; marker_note_bullet "$label" "$bullet"; }
        return 0
    done <<EOF
$cands
EOF
    if [ -n "$r0_warned" ]; then printf '%s' "$r0_warning_lines"; return 0; fi
    return 1
}

# resolve_wake: with --workers-from, a worker doc whose NEWEST marker-bearing bullet is
# `BLOCKED resolve <pr> <thread ids>` wakes the chief once per bullet (a worker whose
# resolve call was denied: the chief resolves the threads itself, never the
# operator). Prints the WAKE block and returns 0; the bullet's line number and text
# go in $resolve_file, so a re-arm or a repeat of the same bullet stays quiet. Only
# the PR number and PRRT_ ids are read out of the bullet; the denial text is not echoed.
resolve_file="$inbox.wait.resolve"
resolve_wake() {
    local label ldoc bullet rest pr ids
    [ -n "$legs_from" ] || return 1
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        bullet="$(grep -nE '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?(LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED|MERGED)([^A-Za-z0-9_]|$)' "$ldoc" | tail -n 1)"
        rest="$(printf '%s\n' "${bullet#*:}" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')"
        [[ $rest =~ ^BLOCKED\ resolve\ ([0-9]+)\ (PRRT_[A-Za-z0-9_-]+([\ ,]+PRRT_[A-Za-z0-9_-]+)*) ]] || continue
        pr="${BASH_REMATCH[1]}"
        ids="$(printf '%s\n' "${BASH_REMATCH[2]}" | tr -s ' ,' ',')"
        grep -qxF -- "$label $bullet" "$resolve_file" 2>/dev/null && continue
        printf '%s\n' "$label $bullet" >> "$resolve_file"
        printf 'WAKE resolve %s pr=%s threads=%s\n' "$label" "$pr" "$ids"
        return 0
    done <<EOF
$(jq -r "$JQ_WR"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    return 1
}

# ready_wake: with --workers-from and auto_go off, a worker doc whose newest marker bullet
# is `READY <pr> <head40> GREEN` wakes the chief once per (PR, head), the checks already
# run (see the header). A head already woken adds its worker's label to $ready_fold.
ready_woke_file="$inbox.wait.readywoke"
ready_hint_file="$inbox.wait.readyhint"
quota_blocked="$(_ghq_dir)/blocked"
ready_check_grace=15
quota_owner_lead=900
quota_backstop_secs=7200
quota_expire_secs=86400
newest_marker_bullet() {
    grep -E '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?(LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED|MERGED)([^A-Za-z0-9_]|$)' "$1" | tail -n 1
}
ready_bullet_of() {
    local rest
    rest="$(newest_marker_bullet "$1" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')"
    [[ $rest =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+GREEN([^A-Za-z0-9_]|$) ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
checks_word() {
    case "$1" in 124|137) echo stall; return ;; esac
    if [ "$1" -eq 2 ] && printf '%s\n' "$2" | grep -q '^QUOTA-PAUSE '; then echo pause
    elif [ "$1" -eq 2 ] && printf '%s\n' "$2" | grep -qE '^GH-STALL |no verdict within the '; then echo stall
    else echo verdict; fi
}
ready_graphql() {
    local t n=0 out=0 tmo=0
    for t in $(ghq_routes ready-check | tr ',' ' '); do
        ghq_read "$t" graphql || continue
        n=$((n + 1))
        case "$GHQ_STATE" in
            refused) out=$((out + 1)) ;;
            timed-out) tmo=$((tmo + 1)) ;;
            ok) [ "$GHQ_REMAINING" != 0 ] || out=$((out + 1)) ;;
        esac
    done
    if [ "$n" -gt 0 ] && [ "$out" -eq "$n" ]; then echo out
    elif [ "$n" -gt 0 ] && [ "$tmo" -eq "$n" ]; then echo stalled
    else echo go; fi
}
stall_clear() {
    rm -f "$inbox.wait.stall-$1.$2"
    [ "$(_ghq_field "$quota_blocked/$1.$2" reason)" != stall ] || rm -f "$quota_blocked/$1.$2"
}
ready_wake() {
    local label ldoc bullet rb pr head rc_out rc trust ci disp drc cov rck dsp outf word aq rcd ci_t disp_t
    ready_fold=""
    [ -n "$legs_from" ] || return 1
    if auto_go_on; then
        [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] || ready_fold="$(marker_ready_fold)"
        return 1
    fi
    rcd="${READY_CHECK_DEADLINE:-150}"; case "$rcd" in ''|0|*[!0-9]*) rcd=150 ;; esac
    ci_t="${CHIEF_WAIT_READY_CI_TIMEOUT:-30}"; case "$ci_t" in ''|0|*[!0-9]*) ci_t=30 ;; esac
    disp_t="${CHIEF_WAIT_DISPOSITION_TIMEOUT:-90}"; case "$disp_t" in ''|0|*[!0-9]*) disp_t=90 ;; esac
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        rb="$(ready_bullet_of "$ldoc")" || continue
        pr="${rb% *}"; head="${rb#* }"; bullet="$(newest_marker_bullet "$ldoc")"
        if grep -qxF -- "$pr $head" "$ready_woke_file" 2>/dev/null; then
            ready_fold="$ready_fold $label"; continue
        fi
        [ "$(_ghq_field "$quota_blocked/$pr.$head" reason)" != rate-limit ] || continue
        case "$(ready_graphql)" in
            out) ghq_mark_blocked "$pr" "$head" chief-wait graphql rate-limit; continue ;;
            stalled) continue ;;
        esac
        aq=""
        [ ! -s "$ready_hint_file" ] || aq="$(awk -v k="$pr $head" '$1 " " $2 == k { c = $3 } END { print c }' "$ready_hint_file")"
        heartbeat sampling
        rc_out="$(cd "$GATE_DIR" && timeout -k 5 $((rcd + ready_check_grace)) bash "${CHIEF_WAIT_READY_CHECK:-$HERE/ready-check.sh}" --observe "$pr" "$head" </dev/null 2>&1 9>&-)"; rc=$?  # gnu-ok: Linux-only kit
        word="$(checks_word "$rc" "$rc_out")"
        if [ "$word" = pause ]; then return 1; fi
        outf="$inbox.wait.ready-$pr"
        if [ "$word" = stall ]; then
            [ -e "$inbox.wait.stall-$pr.$head" ] || { : > "$inbox.wait.stall-$pr.$head"; return 1; }
            printf '%s READY %s %s\n== bullet\n%s\n== ready-check rc=%s\n%s\n' \
                "$label" "$pr" "$head" "$bullet" "$rc" "$rc_out" | r0_scrub > "$outf" 2>/dev/null
            printf '%s %s\n' "$pr" "$head" >> "$ready_woke_file"
            stall_clear "$pr" "$head"
            ready_hint_drop "$pr" "$head"
            printf 'WAKE ready %s %s ready-check=STALLED out=%s%s\n' "$pr" "$head" "$outf" "${aq:+ after-quota=$aq}"
            return 0
        fi
        if [ "$rc" -eq 0 ]; then rck=PASS; else rck=FAIL; fi
        if printf '%s\n' "$rc_out" | grep -q '^\[PASS\] 7\.'; then cov=PASS; else cov=FAIL; fi
        if printf '%s\n' "$rc_out" | grep -qx 'TRUST-PATH: yes'; then trust=yes; else trust=no; fi
        heartbeat sampling
        ci="$(ready_ci "$pr" "$head" "$ci_t")"
        heartbeat sampling
        disp="$(cd "$GATE_DIR" && timeout -k 5 "$disp_t" bash "${CHIEF_WAIT_DISPOSITION:-$HERE/cr-disposition.sh}" check "$pr" "$head" --trust-path "$trust" </dev/null 2>&1 9>&-)"; drc=$?  # gnu-ok: Linux-only kit
        word="$(checks_word "$drc" "$disp")"
        if [ "$word" = pause ]; then return 1; fi
        if [ "$word" = stall ]; then
            [ -e "$inbox.wait.stall-$pr.$head" ] || { : > "$inbox.wait.stall-$pr.$head"; return 1; }
            dsp=STALLED
        else
            case "$drc" in
                0) dsp=ok ;;
                1) dsp="open:$(printf '%s\n' "$disp" | sed -nE 's/^DISPOSITION FAIL \(([0-9]+) of .*/\1/p' | head -n 1)"
                   [ "$dsp" != open: ] || dsp='open:?' ;;
                *) dsp='open:?' ;;
            esac
        fi
        printf '%s READY %s %s\n== bullet\n%s\n== ready-check rc=%s\n%s\n== ci %s\n== cr-disposition check rc=%s\n%s\n' \
            "$label" "$pr" "$head" "$bullet" "$rc" "$rc_out" "$ci" "$drc" "$disp" | r0_scrub > "$outf" 2>/dev/null
        printf '%s %s\n' "$pr" "$head" >> "$ready_woke_file"
        stall_clear "$pr" "$head"
        ready_hint_drop "$pr" "$head"
        printf 'WAKE ready %s %s ready-check=%s ci=%s coverage=%s disposition=%s out=%s%s\n' "$pr" "$head" "$rck" "$ci" "$cov" "$dsp" "$outf" "${aq:+ after-quota=$aq}"
        return 0
    done <<EOF
$(jq -r "$JQ_WR"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    return 1
}
ready_hint_drop() {
    [ -s "$ready_hint_file" ] || return 0
    awk -v k="$1 $2" '$1 " " $2 != k' "$ready_hint_file" | atomic_write "$ready_hint_file"
    [ -s "$ready_hint_file" ] || rm -f "$ready_hint_file"
}

quota_waiter_repo=""
quota_repo() {
    [ -z "$quota_waiter_repo" ] || { printf '%s' "$quota_waiter_repo"; return; }
    quota_waiter_repo="${GHQ_REPO:-$(gate_nwo)}"
    printf '%s' "$quota_waiter_repo"
}
quota_field() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}
quota_back() {
    local b t ok floor="${GH_BUDGET_FLOOR:-200}" buckets routes
    case "$floor" in ''|*[!0-9]*) floor=200 ;; esac
    buckets="$(quota_field "$1" buckets | tr ',' ' ')"; routes="$(quota_field "$1" routes | tr ',' ' ')"
    [ -n "$buckets" ] && [ -n "$routes" ] || return 1
    for b in $buckets; do
        ok=""
        for t in $routes; do
            ghq_read "$t" "$b" || continue
            [ "$GHQ_STATE" = ok ] && [ -n "$GHQ_REMAINING" ] && [ "$GHQ_REMAINING" -ge "$floor" ] && [ "$GHQ_OBSERVED" -gt "$2" ] && { ok=1; break; }
        done
        [ -n "$ok" ] || return 1
    done
}
quota_ready_head() {
    local label ldoc rb
    [ -n "$legs_from" ] || return 1
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        rb="$(ready_bullet_of "$ldoc")" || continue
        [ "${rb% *}" = "$1" ] && { [ "$2" = unknown ] || [ "${rb#* }" = "$2" ]; } && { printf '%s\n' "${rb#* }"; return 0; }
    done <<EOF
$(jq -r "$JQ_W"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    return 1
}
quota_owner() {
    local label ldoc branch=""
    [ -z "$3" ] || [ -z "$(quota_repo)" ] || [ "$3" = "$(quota_repo)" ] || return 1
    if [ "$2" = unknown ]; then
        grep -q "^$1 " "$ready_woke_file" 2>/dev/null && return 0
    else
        grep -qxF -- "$1 $2" "$ready_woke_file" 2>/dev/null && return 0
    fi
    quota_ready_head "$1" "$2" >/dev/null && return 0
    case "$1" in branch-*) branch="$(printf '%s' "${1#branch-}" | sed 's#%2F#/#g')" ;; *) return 1 ;; esac
    [ -n "$legs_from" ] || return 1
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        grep -qwF -- "$branch" "$ldoc" && return 0
    done <<EOF
$(jq -r "$JQ_W"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    return 1
}
quota_stamp_back() {
    [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] || return 1  # read-sink-ok: $1 is a marker quota_step globbed under quota_blocked
    { printf '%s\n' "$2"; printf 'back_epoch=%s\n' "$3"; } | atomic_write "$1"
}
quota_claim() {
    [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] || return 1  # read-sink-ok: $1 is a marker quota_step globbed under quota_blocked
    mv "$1" "$3"
}
quota_rearm() {
    if [ -s "$ready_woke_file" ]; then
        awk -v k="$1 $2" '$0 != k' "$ready_woke_file" | atomic_write "$ready_woke_file"
    fi
    ready_hint_drop "$1" "$2"
    printf '%s %s %s\n' "$1" "$2" "$3" >> "$ready_hint_file"
}
quota_step() {
    local m name key ref first back now unknown claimed caller reason snap head
    [ -d "$quota_blocked" ] || return 1
    now="$(date +%s)"
    for m in "$quota_blocked"/*; do
        [ -f "$m" ] || continue
        name="${m##*/}"; ref="${name##*.}"; key="${name%.*}"
        [ -n "$key" ] && [ "$key" != "$name" ] || continue
        [ ! -e "$inbox.wait.stall-$key.$ref" ] || continue
        snap="$(cat "$m")" || continue
        first="$(quota_field "$snap" first_epoch)"
        case "$first" in ''|*[!0-9]*) continue ;; esac
        if [ $((now - first)) -ge "$quota_expire_secs" ]; then rm -f "$m"; continue; fi
        back="$(quota_field "$snap" back_epoch)"; case "$back" in *[!0-9]*) back="" ;; esac
        unknown=""
        if quota_back "$snap" "$first"; then
            if [ -z "$back" ]; then
                with_lock "$quota_blocked/.lock" quota_stamp_back "$m" "$snap" "$now" || continue
                back="$now"; snap="$snap"$'\n'"back_epoch=$now"
            fi
        elif [ $((now - first)) -ge "$quota_backstop_secs" ]; then
            unknown=1; back=$((first + quota_backstop_secs))
        else
            continue
        fi
        if ! quota_owner "$key" "$ref" "$(quota_field "$snap" repo)"; then
            [ -n "$back" ] && [ $((now - back)) -ge "$quota_owner_lead" ] || continue
        fi
        claimed="$quota_blocked/.claim.$$.$name"
        with_lock "$quota_blocked/.lock" quota_claim "$m" "$snap" "$claimed" || continue
        caller="$(quota_field "$snap" caller)"; reason="$(quota_field "$snap" reason)"
        rm -f "$claimed"
        if [ -z "$unknown" ] && [ "$reason" = rate-limit ] && ! auto_go_on && head="$(quota_ready_head "$key" "$ref")"; then
            quota_rearm "$key" "$head" "${caller:-unknown}"
            continue
        fi
        if housekeeping_add quota-back "$(printf '%s' "$key" | sed 's#%2F#/#g') $ref caller=${caller:-unknown}${unknown:+ quota=unknown}"; then
            return 0
        fi
    done
    return 1
}
# silent_go_wake: with --doc and --workers-from, silent-go-merge.sh merges a GO'd READY PR
# whose worker went silent past CHIEF_WAIT_WORKER_SILENT_MIN (or alerts why not), once per
# (worker, PR, head, outcome); its lines follow `WAKE silent-go`. Seam: CHIEF_WAIT_SILENT_GO.
silent_go_wake() {
    local out
    [ -n "$legs_from" ] && [ -n "$console_doc" ] || return 1
    heartbeat sampling
    out="$(bash "${CHIEF_WAIT_SILENT_GO:-$HERE/silent-go-merge.sh}" --doc "$console_doc" --workers-from "$legs_from" --state "$inbox.wait.silentgo" </dev/null 2>/dev/null 9>&-)" || return 1  # swallow-ok: a failed run reads as no wake; the helper alerts on its own outcomes
    printf 'WAKE silent-go\n%s\n' "$out"
}
# size_wake: a SIZE-ESCALATE row gen-briefs.py wrote (a refused oversized brief, or a bulk: mechanical use)
# that this inbox has not woken for yet. Prints `WAKE size rows=<total>` then the new rows and succeeds. The
# marker `<inbox>.wait.size` holds the row total already shown. Like the tick key, the first sample with no
# marker is a silent baseline (rows from before this inbox existed belong to a predecessor). Reads through
# size-override.sh pending, which exits 1 when nothing is new (CHIEF_WAIT_SIZE replaces it, tests); an
# unreadable total is no wake.
size_file="$inbox.wait.size"
size_wake() {
    local out seen total rc=0
    seen="$(cat "$size_file" 2>/dev/null)"; case "$seen" in ''|*[!0-9]*) seen=0 ;; esac  # swallow-ok: an unreadable marker reads as 0 and re-baselines below
    out="$(bash "${CHIEF_WAIT_SIZE:-$HERE/size-override.sh}" pending --since "$seen" </dev/null 2>/dev/null 9>&-)" || rc=$?  # swallow-ok: rc 1 is "nothing new"; the total decides
    total="$(printf '%s\n' "$out" | sed -n '1s/^total=\([0-9][0-9]*\)$/\1/p')"
    [ -n "$total" ] || return 1
    if [ ! -f "$size_file" ]; then printf '%s\n' "$total" > "$size_file"; return 1; fi
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$total" > "$size_file.tmp" && mv -f "$size_file.tmp" "$size_file"
    printf 'WAKE size rows=%s\n%s\n' "$total" "$(printf '%s\n' "$out" | tail -n +2)"
}
prwatch_at_file="$inbox.wait.prwatch.at"
pr_watch_wake() {
    local rows now last pr head com rev repo st pj rj nh nc nr ns detail repo_arg repo_tag gh_cmd="${CHIEF_WAIT_GH:-$GH_READ_BIN}"
    [ -n "$legs_from" ] && [ -r "$legs_from" ] || return 1
    rows="$(jq -r '(.watch // [])[]? | [.pr, (.head // "-"), (.comments // "-"), (.reviews // "-"), (.repo // "{owner}/{repo}"), (.state // "-")] | @tsv' "$legs_from" 2>/dev/null)" || return 1  # swallow-ok: an unreadable manifest has no rows to poll
    [ -n "$rows" ] || return 1
    now="$(date +%s)"
    last="$(cat "$prwatch_at_file" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac  # swallow-ok: no stamp reads as never polled
    [ $(( now - last )) -ge "${CHIEF_WAIT_PR_WATCH_SEC:-120}" ] || return 1
    printf '%s\n' "$now" > "$prwatch_at_file" 2>/dev/null
    heartbeat sampling
    while IFS=$'\t' read -r pr head com rev repo st; do
        [ -n "$pr" ] || continue
        pj="$(cd "$GATE_DIR" && timeout -k 2 20 env GH_READ_NO_MAIN_FALLBACK=1 "$gh_cmd" api "repos/$repo/pulls/$pr" </dev/null 2>/dev/null 9>&-)" || continue  # gnu-ok: Linux-only kit; swallow-ok: a failed read is retried next interval, never a wake
        rj="$(cd "$GATE_DIR" && timeout -k 2 20 env GH_READ_NO_MAIN_FALLBACK=1 "$gh_cmd" api "repos/$repo/pulls/$pr/reviews?per_page=100" </dev/null 2>/dev/null 9>&-)" || continue  # gnu-ok: Linux-only kit; swallow-ok: as above
        nh="$(printf '%s' "$pj" | jq -r '.head.sha // empty' 2>/dev/null)"  # swallow-ok: an unparsed reply fails the checks below
        nc="$(printf '%s' "$pj" | jq -r 'if (.comments | type) == "number" and (.review_comments | type) == "number" then .comments + .review_comments else empty end' 2>/dev/null)"  # swallow-ok: as above
        nr="$(printf '%s' "$rj" | jq -r 'if type == "array" then length else empty end' 2>/dev/null)"  # swallow-ok: as above
        ns="$(printf '%s' "$pj" | jq -r 'if .merged == true then "merged" elif .state == "closed" then "closed" elif .state == "open" then "open" else empty end' 2>/dev/null)"  # swallow-ok: as above
        case "$nh" in ''|*[!0-9a-f]*) continue ;; esac
        case "$nc" in ''|*[!0-9]*) continue ;; esac
        case "$nr" in ''|*[!0-9]*) continue ;; esac
        [ -n "$ns" ] || continue
        detail=""
        [ "$head" = - ] || [ "$head" = "$nh" ] || detail="$detail head ${head:0:7}→${nh:0:7}"
        [ "$com" = - ] || [ "$com" = "$nc" ] || detail="$detail comments $com→$nc"
        [ "$rev" = - ] || [ "$rev" = "$nr" ] || detail="$detail reviews $rev→$nr"
        [ "$st" = - ] || [ "$st" = "$ns" ] || detail="$detail state $st→$ns"
        repo_arg=(); repo_tag=""
        [ "$repo" = '{owner}/{repo}' ] || { repo_arg=(--repo "$repo"); repo_tag=" repo=$repo"; }
        timeout -k 2 40 bash "$HERE/fleet-manifest.sh" watch "$legs_from" set "$pr" ${repo_arg[@]+"${repo_arg[@]}"} --head "$nh" --comments "$nc" --reviews "$nr" --state "$ns" </dev/null >/dev/null 2>&1 9>&- || continue  # gnu-ok: Linux-only kit; swallow-ok: as above
        [ -n "$detail" ] || continue
        printf 'WAKE pr-watch %s%s%s\n' "$pr" "$repo_tag" "$detail"
        return 0
    done <<EOF
$rows
EOF
    return 1
}
t3_stamp_file="$inbox.wait.t3relay.at"
t3_rc4_file="$inbox.wait.t3relay.rc4"
t3_tok() { case "$1" in ''|*[!A-Za-z0-9:._-]*) return 1 ;; esac; [ "${#1}" -le 80 ]; }
t3_relay_step() {
    local out rc now last secs tmo n kind a b c woke=""
    [ -n "$legs_from" ] && [ -r "$legs_from" ] || return 1
    [ -z "${CHIEF_WAIT_TICK:-}" ] || [ -n "${CHIEF_WAIT_T3_RELAY:-}" ] || return 1
    secs="${CHIEF_WAIT_T3_RELAY_SEC:-120}"; case "$secs" in ''|*[!0-9]*) secs=120 ;; esac
    tmo="${CHIEF_WAIT_T3_RELAY_TIMEOUT:-30}"; case "$tmo" in ''|0|*[!0-9]*) tmo=30 ;; esac
    now="$(date +%s)"
    last=""; [ ! -r "$t3_stamp_file" ] || IFS= read -r last < "$t3_stamp_file"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -ge "$secs" ] || return 1
    printf '%s\n' "$now" > "$t3_stamp_file" 2>/dev/null
    heartbeat sampling
    out="$(timeout -k 2 "$tmo" bash "${CHIEF_WAIT_T3_RELAY:-$REPO/scripts/t3/relay-bind.sh}" scan --manifest "$legs_from" </dev/null 2>/dev/null 9>&-)"; rc=$?  # gnu-ok: Linux-only kit
    case "$rc" in
        0|1|5) rm -f "$t3_rc4_file" ;;
        4)
            n=""; [ ! -r "$t3_rc4_file" ] || IFS= read -r n < "$t3_rc4_file"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
            n=$(( 10#$n + 1 )); printf '%s\n' "$n" > "$t3_rc4_file" 2>/dev/null
            if [ "$n" -eq 3 ]; then printf 'WAKE t3-relay list-failed list\n'; woke=1; fi ;;
        *) rm -f "$t3_rc4_file"; return 1 ;;
    esac
    while IFS=' ' read -r kind a b c; do
        case "$kind" in
            BOUND|UNBOUND) [ -z "$c" ] && t3_tok "$a" && t3_tok "$b" && housekeeping_add t3-relay "$kind $a $b" && woke=1 ;;
            ASK-THREAD-PR) t3_tok "$a" && { printf 'WAKE t3-relay ask-thread-pr %s\n' "$a"; woke=1; } ;;
            BIND-GAVE-UP) t3_tok "$a" && { printf 'WAKE t3-relay bind-gave-up %s\n' "$a"; woke=1; } ;;
            BIND-REFUSED) t3_tok "$a" && { printf 'WAKE t3-relay bind-refused %s\n' "$a"; woke=1; } ;;
            OWNER-TAKEN) t3_tok "$a" && { printf 'WAKE t3-relay owner-taken %s\n' "$a"; woke=1; } ;;
        esac
    done <<EOF
$out
EOF
    [ -n "$woke" ]
}
ask_file="$inbox.wait.askrow"
ask_row_wake() {
    local label ldoc bullet rest kind sum
    [ -n "$legs_from" ] || return 1
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        t3_tok "$label" || continue
        bullet="$(newest_marker_bullet "$ldoc")"
        rest="$(printf '%s\n' "$bullet" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')"
        case "$rest" in
            READY|READY[!A-Za-z]*) kind=ask-ready ;;
            BLOCKED\ resolve\ *) kind=ask-resolve ;;
            *) continue ;;
        esac
        sum="$label $kind $(printf '%s\n' "$bullet" | cksum | cut -d' ' -f1)"
        grep -qxF -- "$sum" "$ask_file" 2>/dev/null && continue
        printf '%s\n' "$sum" >> "$ask_file"
        printf 'WAKE t3-relay %s %s\n' "$kind" "$label"
        return 0
    done <<EOF
$(jq -r "$JQ_W"'W[]? | select((.t3_kind // "") == "ask") | [.label, .doc] | @tsv' "$legs_from")
EOF
    return 1
}
ready_ci() {
    local b rc nwo err="$inbox.wait.ci-err"
    case "$err" in /*) ;; *) err="$PWD/$err" ;; esac
    if [ -n "${CHIEF_WAIT_CI:-}" ]; then
        b="$(timeout -k 5 "$3" bash "$CHIEF_WAIT_CI" "$1" "$2" </dev/null 2>/dev/null 9>&- | head -n 1)"  # gnu-ok: Linux-only kit
        case "$b" in GREEN|RED|PENDING|PAUSED) printf '%s\n' "$b" ;; *) printf 'PENDING\n' ;; esac
        return
    fi
    nwo="$(gate_nwo)"
    b="$(cd "$GATE_DIR" && timeout -k 5 "$3" bash "$REPO/scripts/lib/gh-read.sh" pr checks "$1" ${nwo:+-R "$nwo"} --json bucket -q '.[].bucket' </dev/null 2>"$err" 9>&-)"; rc=$?  # gnu-ok: Linux-only kit
    # a refusal exits 1 like a failed check, so its stderr decides (stdout is check names)
    if [ -z "$b" ] && [ "$rc" -ne 0 ] && ghq_is_rate_limited "$(cat "$err")"; then
        rm -f "$err"; printf 'PAUSED\n'; return
    fi
    rm -f "$err"
    # gh exits 1 on a failed check and 8 on a pending one; any other non-zero is a failed read
    case $rc in 0|1|8) ;; *) printf 'PENDING\n'; return ;; esac
    if printf '%s\n' "$b" | grep -qE '^(fail|cancel)$'; then printf 'RED\n'
    elif [ -z "$b" ] || printf '%s\n' "$b" | grep -qx pending; then printf 'PENDING\n'
    else printf 'GREEN\n'; fi
}
# ready_fold_key <saved key> <new key> <labels>: tails= and acts= take the new value when
# they differ from the saved one only in those labels' tokens; every other field keeps
# the saved value. A repeat READY of a head already woken is not a new event.
ready_fold_key() {
    awk -v s="$1" -v k="$2" -v a=" $3 " '
    function strip(v,   n, t, i, l, o) {
        n = split(v, t, ","); o = ""
        for (i = 1; i <= n; i++) {
            l = t[i]; sub(/:.*/, "", l)
            if (t[i] == "none" || index(a, " " l " ")) continue
            o = o "," t[i]
        }
        return o
    }
    BEGIN {
        nk = split(k, kp, "|")
        for (i = 1; i <= nk; i++) { f = kp[i]; sub(/=.*/, "", f); kv[f] = substr(kp[i], length(f) + 2) }
        ns = split(s, sp, "|"); out = ""
        for (i = 1; i <= ns; i++) {
            f = sp[i]; sub(/=.*/, "", f); v = substr(sp[i], length(f) + 2)
            if ((f == "tails" || f == "acts") && (f in kv) && strip(kv[f]) == strip(v)) v = kv[f]
            out = out "|" f "=" v
        }
        print substr(out, 2)
    }'
}

marker_woke_file="$inbox.wait.markerwoke"
marker_key() {
    local rest m
    rest="$(printf '%s\n' "$2" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')"
    case "$rest" in
        BLOCKED\ resolve\ *) return 1 ;;
        READY*)
            if [[ $rest =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})([^0-9a-f]|$) ]]; then
                printf 'READY %s %s\tWAKE worker-ready %s pr=%s head=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$1" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                return 0
            fi
            m=READY ;;
        BLOCKED*) m=BLOCKED ;;
        FINDING*) m=FINDING ;;
        *) [[ $rest =~ (^|[^A-Za-z0-9_])([A-Z]+-)*(REQUEST|QUESTION)([^A-Za-z0-9_]|$) ]] || return 1
           m=REQUEST ;;
    esac
    printf '%s %s %s\tWAKE worker-%s %s\n' "$1" "$m" "$(printf '%s\n' "$2" | cksum | cut -d' ' -f1)" "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" "$1"
}
worker_marker_events() {
    local label ldoc kind ev ready_on=""
    [ -n "$legs_from" ] || return 0
    auto_go_on && ready_on=1
    while IFS=$'\t' read -r label ldoc kind; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        ev="$(marker_key "$label" "$(newest_marker_bullet "$ldoc")")" || continue
        case "$ev" in *$'\t'"WAKE worker-ready "*) [ -n "$ready_on" ] && [ "$kind" != ask ] || continue ;; esac
        printf '%s\t%s\n' "$label" "$ev"
    done <<EOF
$(jq -r "$JQ_W"'W[]? | [.label, .doc, (.t3_kind // "-")] | @tsv' "$legs_from")
EOF
}
marker_tok() {
    local m
    m="$(printf '%s' "${2#WAKE worker-}" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
    if [ "$m" = REQUEST ]; then
        printf '%s\n' "$3" | tr ',' '\n' | awk -v p="$1:" 'index($0, p) == 1 { t = substr($0, length(p) + 1); sub(/[^A-Za-z0-9_-].*/, "", t)
            if (t != "" && t != "READY" && t != "BLOCKED" && t != "FINDING") { print; exit } }'
        return
    fi
    printf '%s\n' "$3" | tr ',' '\n' | awk -v p="$1:$m" 'index($0, p) == 1 && substr($0, length(p) + 1, 1) !~ /[A-Za-z0-9_]/ { print; exit }'
}
worker_doc_events() {
    local label ldoc sib
    [ -n "$legs_from" ] || return 0
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -n "$ldoc" ] || continue
        if [ ! -f "$ldoc" ]; then
            printf '%s\tDOC-MISSING %s\tWAKE worker-doc-missing %s %s\n' "$label" "$ldoc" "$label" "$ldoc"
            continue
        fi
        case "$ldoc" in *-RESUME.md) ;; *) continue ;; esac
        sib="${ldoc%-RESUME.md}.md"
        [ -f "$sib" ] && [ "$sib" -nt "$ldoc" ] || continue
        [ -z "$(newest_marker_bullet "$ldoc")" ] && [ -n "$(newest_marker_bullet "$sib")" ] || continue
        printf '%s\tDOC-MISSING %s\tWAKE worker-doc-missing %s %s writes=%s\n' "$label" "$ldoc" "$label" "$ldoc" "$sib"
    done <<EOF
$(jq -r "$JQ_W"'W[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
}
worker_marker_wake() {
    local ev label k w m tok keys="" out="" st ct ldoc cur last any="${1:-}"
    ev="$(worker_marker_events)"
    st=",$(key_field tails "$saved"),"; ct=",$(key_field tails "$key"),"
    while IFS=$'\t' read -r label k w; do
        [ -n "$k" ] || continue
        grep -qxF -- "$k" "$marker_woke_file" 2>/dev/null && continue
        m="$(printf '%s' "${w#WAKE worker-}" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
        tok="$(marker_tok "$label" "$w" "$ct")"
        [ -n "$tok" ] || continue
        [ -n "$any" ] || case "$st" in *",$tok,"*) ;; *) continue ;; esac
        if [ "$m" = READY ]; then
            cur=""; last=""
            [ ! -f "$ready_file" ] || cur="$(awk -F'\t' -v l="$label" '$1 == l { c = $2 } END { print c }' "$ready_file")"
            ldoc="$(jq -r --arg l "$label" "$JQ_W"'W[]? | select(.label == $l) | .doc' "$legs_from" | head -n 1)"
            [ ! -f "$ldoc" ] || last="$(grep -nE "$ready_re" "$ldoc" | tail -n 1 | cut -d: -f1)"
            case "$cur:$last" in *[!0-9:]*|:*|*:) ;; *) [ "$last" -le "$cur" ] || continue ;; esac
        fi
        out="$out$w"$'\n'; keys="$keys$k"$'\n'
    done <<EOF
$ev
EOF
    while IFS=$'\t' read -r label k w; do
        [ -n "$k" ] || continue
        grep -qxF -- "$k" "$marker_woke_file" 2>/dev/null && continue
        out="$out$w"$'\n'; keys="$keys$k"$'\n'
    done <<EOF
$(worker_doc_events)
EOF
    [ -n "$out" ] || return 1
    printf '%s' "$out"
    printf '%s' "$keys" >> "$marker_woke_file"
}
marker_carry_on=""
marker_carry() {
    [ -n "$marker_carry_on" ] && [ -n "$key" ] || return 0
    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] || return 0
    case "$exit_reason" in wake-worker-marker) return 0 ;; wake-*) ;; *) return 0 ;; esac
    worker_marker_wake any || return 0
}
renudge_file="$inbox.wait.renudge"; renudge_log="$inbox.wait.renudge.log"; renudge_secs=1800
renudge_go_root="$(chief_owed_go_root "$REPO")" || renudge_go_root=""
[ -n "$renudge_go_root" ] || echo "renudge: no GO root resolved; no GO file stops a re-nudge" >&2
renudge_sampled=""
renudge_items() {
    [ -n "$legs_from" ] || return 3
    local rows label ldoc kind f1 f2 f3 f4 t3 st
    rows="$(jq -r "$JQ_W"'if (W | type) == "array" then W[] | [(.label // "?"), (.doc // "?"), (.t3_kind // "-")] | @tsv else error("no workers array") end' "$legs_from" 2>/dev/null)" || return 2  # swallow-ok: an unreadable manifest is rc 2, which keeps the state
    while IFS=$'\t' read -r label ldoc kind; do
        [[ $label =~ ^[A-Za-z0-9._#+-]+$ ]] || continue
        if ! { [ -f "$ldoc" ] && [ -r "$ldoc" ] && st="$(chief_owed_state "$ldoc" --gen)"; }; then printf 'KEEP\t%s\n' "$label"; continue; fi
        t3=-; [ "$kind" != ask ] || t3=ask
        while read -r f1 f2 f3 f4; do
            case "$f1" in
                ready)
                    [[ $f2 =~ ^[0-9a-z._-]+$ && $f3 =~ ^[0-9a-f]{7,40}$ && $f4 =~ ^[0-9]+$ ]] || continue
                    [ "$t3" = ask ] || [ -z "$renudge_go_root" ] || [ ! -e "$renudge_go_root/.locks/go/$f2.$f3" ] || continue
                    printf '%s:go:%s:%s:%s\t%s\tgo-owed\t%s\t%s\t%s\n' "$label" "$f2" "$f3" "$f4" "$label" "$f2" "$f3" "$t3" ;;
                ask)
                    [[ $f2 =~ ^(BLOCKED|FINDING)$ && $f3 =~ ^[0-9]+$ ]] || continue
                    printf '%s:ask:%s:%s\t%s\tanswer-owed\t-\t-\t%s\n' "$label" "$f2" "$f3" "$label" "$t3" ;;
            esac
        done <<EOF
$st
EOF
    done <<EOF
$rows
EOF
}
renudge_write() {
    printf 'anchor %s %s\n%s\n' "$1" "$2" "$3" | atomic_write "$renudge_file" 2>/dev/null ||
        { echo "renudge: state write failed" >&2; return 1; }
}
renudge_step() {
    local now items rows="" anchor="" last="" new slot due out held="" listed
    now="$(stuck_now)"
    items="$(renudge_items)" || return 1
    if [ -f "$renudge_file" ]; then
        read -r _ anchor last < "$renudge_file"
        rows="$(sed 1d "$renudge_file")"
    fi
    case "$anchor:$last" in *[!0-9:]*|:*|*:) anchor=""; last="" ;; esac
    new="$(RN_ITEMS="$items" RN_ROWS="$rows" awk -F'\t' -v now="$now" 'BEGIN {
        n = split(ENVIRON["RN_ITEMS"], it, "\n")
        for (i = 1; i <= n; i++) {
            split(it[i], f, "\t")
            if (f[1] == "KEEP") keep[f[2]] = 1
            else if (f[1] != "") { have[f[1]] = 1; order[++m] = f[1] "\t" f[2] "\t" f[3] }
        }
        n = split(ENVIRON["RN_ROWS"], r, "\n")
        for (i = 1; i <= n; i++) {
            split(r[i], f, "\t")
            if (f[1] != "" && ((f[1] in have) || (f[2] in keep))) { print r[i]; seen[f[1]] = 1 }
        }
        for (i = 1; i <= m; i++) { split(order[i], f, "\t"); if (!(f[1] in seen)) { print order[i] "\t" now "\t0"; seen[f[1]] = 1 } }
    }')" || return 1
    if [ "$new" != "$rows" ] || { [ -n "$new" ] && [ -z "$anchor" ]; }; then
        if [ -z "$new" ]; then rm -f "$renudge_file"; return 1; fi
        [ -n "$anchor" ] || { anchor="$now"; last=0; }
        renudge_write "$anchor" "$last" "$new" || return 1
    fi
    [ -n "$new" ] || return 1
    [ "$now" -ge "$anchor" ] || return 1
    slot=$(( (now - anchor) / renudge_secs ))
    [ "$slot" -gt "$last" ] || return 1
    due="$(RN_ITEMS="$items" awk -F'\t' -v now="$now" -v secs="$renudge_secs" '
        BEGIN { n = split(ENVIRON["RN_ITEMS"], it, "\n"); for (i = 1; i <= n; i++) { split(it[i], f, "\t"); if (f[1] == "KEEP") keep[f[2]] = 1 } }
        !($2 in keep) && now - $4 >= secs { print $2 "\t" $1 }' <<EOF
$new
EOF
)" || return 1
    if [ -n "$due" ] && [ -n "$console_doc" ]; then
        if listed="$(bash "$HERE/owe.sh" list --bucket "${console_doc%/*}" --json 2>/dev/null)" &&  # swallow-ok: the else branch reports the failed read
           held="$(printf '%s' "$listed" | jq -r '.[] | select(.kind == "ruling" and .source_label and .source_id) | .source_label + "\t" + .source_id' 2>/dev/null)"; then  # swallow-ok: the else branch reports the failed parse
            :
        else
            held=""; echo "renudge: owed ledger unread" >&2
        fi
    fi
    out="$(RN_ITEMS="$items" RN_DUE="$due" RN_HELD="$held" awk -F'\t' -v now="$now" '
        BEGIN {
            n = split(ENVIRON["RN_ITEMS"], it, "\n")
            for (i = 1; i <= n; i++) { split(it[i], f, "\t"); if (f[1] != "KEEP") { cid[f[1]] = f[4]; sha[f[1]] = f[5]; t3[f[1]] = f[6] } }
            n = split(ENVIRON["RN_HELD"], h, "\n"); for (i = 1; i <= n; i++) if (h[i] != "") held[h[i]] = 1
            n = split(ENVIRON["RN_DUE"], d, "\n"); for (i = 1; i <= n; i++) { split(d[i], f, "\t"); if (d[i] != "" && !(d[i] in held)) send[f[2]] = 1 }
        }
        {
            if ($1 in send) {
                $5 = $5 + 1; w = int((now - $4) / 60)
                print "L\t" now " " $1 " n=" $5 " waited=" w "m"
                line = "WAKE worker-renudge " $2 " " $3 " waited=" w "m n=" $5 " hold=" $1
                if ($3 == "go-owed") line = line " id=" cid[$1] " head=" sha[$1]
                if (t3[$1] == "ask") line = line " t3=ask"
                print "W\t" line
            }
            print "S\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
        }' OFS='\t' <<EOF
$new
EOF
)" || return 1
    new="$(printf '%s\n' "$out" | sed -n $'s/^S\t//p')"
    renudge_write "$anchor" "$slot" "$new" || return 1
    [ "${HIMMEL_TEST_FIXTURE:-}" != 1 ] || [ "${CHIEF_WAIT_RENUDGE_KILL_AT:-}" != state ] || exit 137
    printf '%s\n' "$out" | sed -n $'s/^L\t//p' >> "$renudge_log"
    [ "${HIMMEL_TEST_FIXTURE:-}" != 1 ] || [ "${CHIEF_WAIT_RENUDGE_KILL_AT:-}" != log ] || exit 137
    out="$(printf '%s\n' "$out" | sed -n $'s/^W\t//p')"
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}
renudge_carry() {
    case "$exit_reason" in wake-worker-renudge) return 0 ;; wake-*) ;; *) return 0 ;; esac
    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && [ -z "$handover_live" ] || return 0
    local out rc
    out="$(renudge_step)"; rc=$?
    [ "$rc" != 137 ] || kill -KILL $$
    [ -z "$out" ] || printf '%s\n' "$out"
}
marker_note() {
    local ev label k w ct
    [ -n "$1" ] || return 0
    ev="$(worker_marker_events)"
    ct=",$(key_field tails "$key"),"
    while IFS=$'\t' read -r label k w; do
        [ -n "$k" ] || continue
        case " $1 " in *" $label "*) ;; *) continue ;; esac
        case "$w" in "WAKE worker-request "*) continue ;; esac
        [ -n "$(marker_tok "$label" "$w" "$ct")" ] || continue
        grep -qxF -- "$k" "$marker_woke_file" 2>/dev/null || printf '%s\n' "$k" >> "$marker_woke_file"
    done <<EOF
$ev
EOF
}
marker_note_bullet() {
    local ev
    ev="$(marker_key "$1" "$2")" || return 0
    grep -qxF -- "${ev%%$'\t'*}" "$marker_woke_file" 2>/dev/null || printf '%s\n' "${ev%%$'\t'*}" >> "$marker_woke_file"
}
marker_ready_fold() {
    local ev label k w out=""
    ev="$(worker_marker_events)"
    while IFS=$'\t' read -r label k w; do
        case "$k" in "READY "*) grep -qxF -- "$k" "$marker_woke_file" 2>/dev/null && out="$out $label" ;; esac
    done <<EOF
$ev
EOF
    printf '%s\n' "$out"
}
moved_labels() {
    awk -v old="$1" -v new="$2" '
    function collect(k, before,   n, a, i, f, v, m, t, j, l) {
        n = split(k, a, "|")
        for (i = 1; i <= n; i++) {
            f = a[i]; sub(/=.*/, "", f)
            if (f != "tails" && f != "acts") continue
            v = substr(a[i], length(f) + 2); m = split(v, t, ",")
            for (j = 1; j <= m; j++) {
                if (before) seen[f SUBSEP t[j]] = 1
                else if (t[j] != "none" && !((f SUBSEP t[j]) in seen)) { l = t[j]; sub(/:.*/, "", l); moved[l] = 1 }
            }
        }
    }
    BEGIN { collect(old, 1); collect(new, 0); for (l in moved) printf "%s ", l }'
}

readymm_file="$inbox.wait.readymismatch"
ready_mismatch_wake() {
    local v="$1" f k mf="" mk=""
    case ",$v," in *,ALERT,*) ;; *) rm -f "$readymm_file"; return 1 ;; esac
    f="${v%%/*}"; k="${v#*nogo=}"; k="${k%%/*}"
    case "$f" in ''|*[!0-9]*) return 1 ;; esac
    case "$k" in ''|*[!0-9]*) return 1 ;; esac
    if [ -r "$readymm_file" ] && read -r mf mk < "$readymm_file"; then :; else mf=""; mk=0; fi
    case "$mf" in ''|*[!0-9]*) mf="" ;; esac
    case "$mk" in ''|*[!0-9]*) mk=0 ;; esac
    if [ -z "$mf" ] || [ "$f" -gt "$mf" ] || [ "$k" -gt "$mk" ]; then
        printf 'WAKE ready-mismatch %s\n' "$v"
        printf '%s %s\n' "$f" "$k" > "$readymm_file"
        return 0
    fi
    printf '%s %s\n' "$f" "$k" > "$readymm_file"
    return 1
}

# r0_fold_key: <saved key> <new key> <absorbed words> — the baseline after the relay
# absorbed those workers' wraps (words: labels and #<pr>). A field whose only difference
# is absorbed tokens (`<word>`, `<word>:…`; `none` counts as empty) takes the new
# value, and so do the derived worker-set fields livestate workerset board (each worker's own
# state is in workers=/tails=/acts=). closable= moves with time alone, so it takes the
# new value only when it did not rise. Any other difference keeps the saved value,
# so another worker's pending change still wakes.
r0_fold_key() {
    awk -v s="$1" -v k="$2" -v a=" $3 " '
    function num(v) { return v == "" ? 0 : v + 0 }
    function strip(v,   n, t, i, l, o) {
        n = split(v, t, ","); o = ""
        for (i = 1; i <= n; i++) {
            l = t[i]; sub(/:.*/, "", l)
            if (t[i] == "none" || index(a, " " l " ")) continue
            o = o "," t[i]
        }
        return o
    }
    BEGIN {
        ns = split(s, sp, "|")
        for (i = 1; i <= ns; i++) { f = sp[i]; sub(/=.*/, "", f); sv[f] = substr(sp[i], length(f) + 2) }
        nk = split(k, kp, "|"); out = ""
        for (i = 1; i <= nk; i++) {
            f = kp[i]; sub(/=.*/, "", f); v = substr(kp[i], length(f) + 2); seen[f] = 1
            if (f == "closable" ? num(v) <= num(sv[f]) : f ~ /^(livestate|workerset|board)$/ || strip(v) == ((f in sv) ? strip(sv[f]) : "")) out = out "|" f "=" v
            else if (f in sv) out = out "|" f "=" sv[f]
        }
        for (i = 1; i <= ns; i++) { f = sp[i]; sub(/=.*/, "", f); if (!(f in seen) && f != "closable" && strip(sv[f]) != "") out = out "|" sp[i] }
        print substr(out, 2)
    }'
}

# worker_silent: a worker the chief would otherwise wait on forever. Two signals:
# the tick lists wakerstate=<worker>:capped (the bus waker typed its cap for mail nobody read) and
# the worker's doc has had no write for CHIEF_WAIT_WORKER_SILENT_MIN minutes, or a --succession
# tally that stayed short names it. silent_emit does the three acts once per (worker, signal,
# doc write time): the WAKE line, a `WORKER-SILENT` bullet in --doc, one operator page.
silent_file="$inbox.wait.silent"
silent_worker_min="${CHIEF_WAIT_WORKER_SILENT_MIN:-45}"
case "$silent_worker_min" in ''|*[!0-9]*|???????*) silent_worker_min=45 ;; *) silent_worker_min=$((10#$silent_worker_min)) ;; esac  # 7+ digits would overflow the *60 a caller may add
worker_doc_of() { # <label>: the worker's doc from the fleet manifest (--workers-from, else the chief doc's own)
    local mf="${legs_from:-${console_doc%.md}.fleet.json}"
    [ -f "$mf" ] || return 0
    jq -r --arg l "$1" "$JQ_W"'[W[]? | select(.label == $l)][0].doc // empty' "$mf" 2>/dev/null || true  # swallow-ok: an unreadable manifest names no doc, the worker is then keyed without a write time
}
silent_emit() { # <label> <signal> <detail>: prints the WAKE line and succeeds when this (worker, signal, doc write time) is new
    local label signal="$2" detail="$3" ldoc m key act act_line
    label="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._#+-')"  # the label goes into an operator message and a marker line
    [ -n "$label" ] || return 1
    ldoc="$(worker_doc_of "$label")"
    m=-
    [ -z "$ldoc" ] || m="$(stat -c %Y "$ldoc" 2>/dev/null)" || m=-  # gnu-ok: Linux-only kit; swallow-ok: no write time keys the worker on the signal alone
    key="$label $signal $m"
    if grep -qxF -- "$key" "$silent_file" 2>/dev/null; then  # swallow-ok: no marker yet reads empty, so the first sight wakes
        act_line="$(silent_act "$label" "$signal" "$m")"
        case "$act_line" in ''|*' done'|*' none'|*' fresh'|*' busy') return 1 ;; esac
        printf 'WAKE worker-silent %s signal=%s silent=%sm\n' "$label" "$signal" "$(( ( $(date +%s) - m ) / 60 ))"
        printf '%s\n' "$act_line"
        silent_failed_note "$label" "$m" "$act_line"
        return 0
    fi
    printf '%s\n' "$key" >> "$silent_file" 2>/dev/null
    act="the chief relaunches it from a RESUME doc or runs its blocked step itself, and will say which it did"
    heartbeat sampling
    [ -z "$console_doc" ] || bash "$HERE/append-results.sh" "$console_doc" "WORKER-SILENT $label signal=$signal$detail: $act; the chief was woken" >/dev/null 2>&1 9>&- || true  # swallow-ok: a doc that cannot take the bullet still wakes and pages
    page_send "WORKER-SILENT $label signal=$signal$detail - $act" $(( $(date +%s) + page_timeout )) worker-silent
    act_line="$(silent_act "$label" "$signal" "$m")"
    printf 'WAKE worker-silent %s signal=%s%s\n' "$label" "$signal" "$detail"
    [ -z "$act_line" ] || printf '%s\n' "$act_line"
    silent_failed_note "$label" "$m" "$act_line"
}
silent_failed_note() {
    case "$3" in *' helper-failed '*) printf '%s helper-failed %s\n' "$1" "$2" >> "$silent_file" 2>/dev/null ;; esac
}
silent_act() {
    local rc=0 out
    { [ -n "$console_doc" ] && [ "$3" != - ]; } || return 0
    out="$(bash "${CHIEF_WAIT_SILENT_ACT:-$HERE/silent-worker-act.sh}" --doc "$console_doc" --fleet "${legs_from:-${console_doc%.md}.fleet.json}" --bucket "$(dirname "$console_doc")" --chief "$(basename "$console_doc" .md)" --signal "$2" "$1" $(( ( $(date +%s) - $3 ) / 60 )) 2>/dev/null 9>&-)" || rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
    grep -qxF -- "$1 helper-failed $3" "$silent_file" 2>/dev/null && return 0  # swallow-ok: no marker yet reads empty, so the first failure is named
    printf 'SILENT-ACT %s helper-failed rc=%s\n' "$1" "$rc"
}
succ_row_live() {
    local mf="${legs_from:-${console_doc%.md}.fleet.json}" docs d
    [ -f "$mf" ] || return 0
    docs="$(jq -r --arg l "$1" "$JQ_W"'[W[]? | select(.label == $l)] | if length == 0 or any(.[]; .lockless == true or (.doc // "") == "") then empty else .[].doc end' "$mf" 2>/dev/null)" || return 0  # swallow-ok: an unreadable manifest proves nothing, so the worker pages
    [ -n "$docs" ] || return 0
    while IFS= read -r d; do
        bash "${CHIEF_WAIT_LOCK_STATUS:-$HERE/../queue-lock.sh}" status "$d" </dev/null >/dev/null 2>&1 9>&- || return 0
    done <<EOF
$docs
EOF
    return 1
}
silent_wake() { # prints one WAKE line per worker newly silent and succeeds when there is one
    local tok label ldoc m age line out=""
    [ -n "$legs_from" ] || return 1
    for tok in $(field wakerstate "$tick_line" | tr ',' ' '); do
        case "$tok" in *:capped) ;; *) continue ;; esac
        label="${tok%:capped}"
        ldoc="$(worker_doc_of "$label")"
        [ -n "$ldoc" ] && [ -f "$ldoc" ] || continue
        m="$(stat -c %Y "$ldoc" 2>/dev/null)" || continue  # gnu-ok: Linux-only kit; swallow-ok: an unreadable write time cannot show a silence
        age=$(( ( $(date +%s) - m ) / 60 ))
        [ "$age" -ge "$silent_worker_min" ] || continue
        line="$(silent_emit "$label" capped-waker " silent=${age}m")" || continue
        out="$out$line"$'\n'
    done
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

saved=""
if [ -f "$key_file" ] && [ "$(sed -n 1p "$key_file")" = "$args_hash" ]; then
    saved="$(old_key_names "$(sed -n 2p "$key_file")")"
fi
save_key() {
    printf '%s\n%s\n' "$args_hash" "$1" | atomic_write "$key_file" 2>/dev/null || return 0  # swallow-ok: a key file that cannot be written only re-arms the next start
}
# Line 3 `failwoke` = this failure streak already woke the chief once.
fail_woke() {
    [ "$(sed -n 1p "$key_file" 2>/dev/null)" = "$args_hash" ] && [ "$(sed -n 3p "$key_file" 2>/dev/null)" = failwoke ]
}

STATION_HEAL_SAMPLES=3
STATION_HEAL_WINDOW=1800
station_heal_file="$inbox.wait.station-heal"
if [ -n "${CHIEF_WAIT_STATION:-}" ]; then station_cmd=("$CHIEF_WAIT_STATION"); else station_cmd=(bash "$HERE/station-sync.sh"); fi
station_heal_step() {
    local val="$1" streak last now hlog
    [ -n "$console_doc" ] || return 0
    streak=0; last=0
    [ ! -f "$station_heal_file" ] || { IFS= read -r streak; IFS= read -r last; } < "$station_heal_file"
    case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    case "$val" in
        BEHIND:pending|BEHIND:) streak=0 ;;
        BEHIND:*) streak=$((streak + 1)) ;;
        *) streak=0 ;;
    esac
    now="$(date +%s)"
    if [ "$streak" -ge "$STATION_HEAL_SAMPLES" ] && [ $((now - last)) -ge "$STATION_HEAL_WINDOW" ]; then
        printf '0\n%s\n' "$now" | atomic_write "$station_heal_file" 2>/dev/null || return 0
        hlog="$HOME/.himmel/state/station-sync.out"
        mkdir -p "$(dirname "$hlog")" 2>/dev/null
        if command -v setsid >/dev/null 2>&1; then
            setsid "${station_cmd[@]}" --heal --bucket "$(dirname "$console_doc")" --chief "$(basename "$console_doc" .md)" 9>&- >>"$hlog" 2>&1 </dev/null &
        else
            "${station_cmd[@]}" --heal --bucket "$(dirname "$console_doc")" --chief "$(basename "$console_doc" .md)" 9>&- >>"$hlog" 2>&1 </dev/null &
        fi
        return 0
    fi
    printf '%s\n%s\n' "$streak" "$last" | atomic_write "$station_heal_file" 2>/dev/null || true
    return 0
}

succ_file="$inbox.wait.succession"
pending=""
r0_fold=""; r0_refold=""
fail_streak=0
fail_wake="${CHIEF_WAIT_FAIL_WAKE:-3}"
next_tick=0
stream_tick_turn=""
if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then
    next_tick="$(cat "$inbox.wait.next-tick" 2>/dev/null)" || next_tick=0  # swallow-ok: no persisted deadline schedules an immediate full sample
    case "$next_tick" in ''|*[!0-9]*) next_tick=0 ;; esac
fi
tick_line=""; key=""; owed_notifications=""
heartbeat sampling
# Announce once per inbox identity, not per waiter process (each wake re-arms).
# The CLI only queues into this inbox's bridge root; it never sends Telegram.
if [ ! -e "$inbox.announced" ] && command -v bun >/dev/null 2>&1; then
    : >> "$inbox"
    timeout -k 2 15 bun "$REPO/scripts/telegram/chief-route.ts" announce "$inbox" 9>&- >/dev/null 2>&1 || true  # gnu-ok: Linux-only kit
fi
while :; do
    marker_carry_on=""
    renudge_sampled=""
    # Telegram first: it is the cheap check and the operator's line. Peek, print
    # the header, then let --once stream the lines: each line is on stdout
    # before its cursor moves, so a kill mid-wake replays, never drops.
    inbox_fence || { exit_reason='inbox-error'; exit 1; }
    bash "$HERE/inbox-follow.sh" --peek "$inbox" 9>&-; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'WAKE telegram\n'
        bash "$HERE/inbox-follow.sh" --once "$inbox" 9>&- || { exit_reason='inbox-error'; exit 1; }
        exit_reason='wake-telegram'; exit 0
    elif [ "$rc" -ne 1 ]; then
        exit_reason='inbox-error'; exit 1
    fi
    # --succession: the successor's one wake. Tally the inherited workers' quote-backs
    # (succession-tracker.sh); wake once when all are in, or once when the tally has
    # sat short for --silent-min minutes, naming the workers still out.
    # A COMPLETE wake leaves $succ_file.woke naming the successor, so a re-arm with the same
    # --succession (the chief forgot to drop it) does not wake again at once.
    # swallow-ok: a missing .woke marker reads empty, so the wake is simply not suppressed
    if [ -n "$succession" ] && [ "$(sed -n 1p "$succ_file.woke" 2>/dev/null)" != "$succession" ] && [ "$(date +%s)" -ge "${next_succ:-0}" ]; then
        next_succ=$(( $(date +%s) + ${CHIEF_WAIT_SUCCESSION_SEC:-15} ))
        [ -s "$succ_file" ] || date +%s > "$succ_file" 2>/dev/null
        succ_out="$(timeout -k 2 30 bash "${CHIEF_WAIT_TRACKER:-$HERE/succession-tracker.sh}" "$console_doc" --successor "$succession" </dev/null 2>/dev/null 9>&-)"  # gnu-ok: Linux-only kit; swallow-ok: a tracker failure prints no summary and takes the INCOMPLETE branch below
        succ_sum="$(printf '%s\n' "$succ_out" | grep -E '^(COMPLETE|INCOMPLETE) ' | head -n 1)"
        case "$succ_sum" in
            COMPLETE*)
                printf 'WAKE succession complete %s\n%s\n' "${succ_sum#COMPLETE }" "$succ_out"
                printf '%s\n' "$succession" > "$succ_file.woke" 2>/dev/null
                rm -f "$succ_file"; exit_reason='wake-succession'; exit 0 ;;
            *)  # INCOMPLETE, or a tracker that printed no summary: both age toward the silence wake
                succ_since="$(sed -n 1p "$succ_file" 2>/dev/null)"  # swallow-ok: empty or non-numeric falls back to now on the next line
                case "$succ_since" in ''|*[!0-9]*) succ_since="$(date +%s)" ;; esac
                if [ $(( $(date +%s) - succ_since )) -ge $(( 10#$silent_min * 60 )) ]; then
                    succ_tally="$(printf '%s' "$succ_sum" | sed -nE 's/^INCOMPLETE ([0-9]+\/[0-9]+).*/\1/p')"
                    printf 'WAKE succession partial %s silent %s min\n%s\n' "${succ_tally:-tracker-error}" "$silent_min" "$succ_out"
                    # the workers the tally still waits on are silent: one worker-silent line each
                    printf '%s\n' "$succ_sum" | sed -nE 's/^INCOMPLETE [0-9]+\/[0-9]+ \(waiting on: ([^)]*)\).*/\1/p' | tr ',' '\n' |
                        while IFS= read -r succ_w; do succ_row_live "$succ_w" && { silent_emit "$succ_w" succession-partial "" || true; }; done  # swallow-ok: an already-woken worker prints nothing
                    rm -f "$succ_file"; exit_reason='wake-succession-partial'; exit 0
                fi ;;
        esac
    fi
    # <inbox>.relay-on-live (`chief.sh next` defaults to relay-on-live unless
    # --no-relay-on-live; needs --doc; line 1 the
    # successor session, line 2 its doc): once the successor's queue lock is held
    # fresh it is live, so wake this chief ONCE with relay-batch.sh's lines. The
    # waiter sends no SendMessage (relay-batch writes a claudex worker's inbox itself, as it
    # does when the chief runs it); the chief sends each SENDMESSAGE line.
    if [ -n "$console_doc" ] && [ -s "$inbox.relay-on-live" ] && [ "$(date +%s)" -ge "${next_rol:-0}" ]; then
        next_rol=$(( $(date +%s) + ${CHIEF_WAIT_SUCCESSION_SEC:-15} ))
        rol_succ="$(sed -n 1p "$inbox.relay-on-live" 2>/dev/null)"  # swallow-ok: an empty value skips the relay below
        rol_doc="$(sed -n 2p "$inbox.relay-on-live" 2>/dev/null)"  # swallow-ok: an empty value skips the relay below
        if [ -n "$rol_succ" ] && [ -n "$rol_doc" ]; then
            bash "${CHIEF_WAIT_LOCK_STATUS:-$HERE/../queue-lock.sh}" status "$rol_doc" </dev/null >/dev/null 2>&1 9>&-; rol_rc=$?
            if [ "$rol_rc" -eq 11 ]; then
                # relay-batch may deliver a claudex worker by inbox-send (never re-run it: a retry
                # would resend), so a failure still wakes, carrying its rc and output for the chief.
                rol_out="$(timeout -k 2 60 bash "${CHIEF_WAIT_RELAY:-$HERE/relay-batch.sh}" "$console_doc" --successor "$rol_succ" </dev/null 2>&1 9>&-)"; rol_brc=$?  # gnu-ok: Linux-only kit
                # The second line is the whole tail: one muted re-arm (bounded by the handover marker's age,
                # so a successor that dies before LIVE cannot leave this chief unmonitored), then the successor's
                # LIVE message wakes the chief and the wrap is one command.
                rol_tail="AFTER RELAYED: re-arm this waiter once with no --succession (handover mode keeps it silent; it resumes after CHIEF_WAIT_HANDOVER_MIN minutes if the successor never goes live), read nothing and end your turn; on the successor's LIVE relay any worker it names as not relayed, then run chief.sh wrap <your doc> <release-token> '<one line>', then stop"
                if [ "$rol_brc" -eq 0 ]; then
                    printf 'WAKE relay-on-live successor=%s\n%s\n%s\n' "$rol_succ" "$rol_tail" "$rol_out"
                else
                    printf 'WAKE relay-on-live successor=%s relay-failed rc=%s\n%s\n%s\n' "$rol_succ" "$rol_brc" "$rol_tail" "$rol_out"
                fi
                rm -f "$inbox.relay-on-live"; exit_reason='wake-relay-on-live'; exit 0
            fi
        else
            rm -f "$inbox.relay-on-live"
        fi
    fi
    # <inbox>.handover (written by `chief.sh next` once the
    # successor validated) puts this waiter in handover mode: no tick, bank or
    # page work (an outgoing chief only waits for LIVE; a tick wake costs it
    # a full-context turn), while the Telegram check above still wakes it.
    # The marker only counts while fresh (CHIEF_WAIT_HANDOVER_MIN, default 60):
    # a launch that failed or never ran must not leave this chief unmonitored.
    handover_live=""
    [ -e "$inbox.handover" ] && handover_live="$(find "$inbox.handover" -mmin "-${CHIEF_WAIT_HANDOVER_MIN:-60}" 2>/dev/null)"
    if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] && [ -z "$handover_live" ]; then
        if [ -n "$console_doc" ] && [ -e "${console_doc%/*}/owed.jsonl" ] && [ "$(date +%s)" -ge "${next_owed_service:-0}" ]; then
            next_owed_service=$(( $(date +%s) + 1 ))
            heartbeat sampling
            service_chief="${inbox##*/}"; service_chief="${service_chief%.md}"
            if owed_service_out="$(python3 -I "$HERE/owed-service.py" --inbox "$inbox" --doc "$console_doc" --chief "$service_chief" 9>&-)"; then
                printf '%s\n' "$owed_service_out"
                exit_reason='wake-owed-actions'; exit 0
            fi
        fi
        r0_attempted=""; r0_offered=""
        if [ -z "$stream_tick_turn" ] && r0_relay; then exit_reason='wake-worker-event'; exit 0; fi
        # A completed or retryable action yields through inbox/control before
        # the next local event; it does not incur the full tick interval.
        if [ -n "${r0_attempted:-}" ]; then
            [ "$(date +%s)" -lt "$next_tick" ] || stream_tick_turn=1
            idle_passes=0
            heartbeat waiting
            stream_stop_point
            nap "$poll"
            continue
        fi
    fi
    if [ -z "$handover_live" ] && [ "$(date +%s)" -ge "$next_tick" ]; then
        stream_tick_turn=""
        idle_passes=0
        next_tick=$(( $(date +%s) + interval ))
        if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ]; then
            printf '%s\n' "$next_tick" | atomic_write "$inbox.wait.next-tick"
        fi
        # The Telegram path is blocked while a tick runs (up to twice
        # CHIEF_WAIT_TICK_TIMEOUT with the bank read); say so in the heartbeat.
        heartbeat sampling
        if [ -n "$legs_from" ]; then
            new_hash="$(args_hash_of "$@" 9>&-)"
            if [ "$new_hash" != "$args_hash" ]; then
                args_hash="$new_hash"
                # a manifest move after a wrap the relay absorbed folds like the wrap
                if [ -n "$r0_fold" ]; then r0_refold=1; else saved=""; pending=""; fi
            fi
        fi
        if close_sweep_woke; then exit_reason='wake-predecessor-open'; exit 0; fi
        sample "$@" 9>&-
        marker_carry_on=1
        renudge_sampled=1
        if [ -z "$key" ] && [ "$fail_step" = "tick-exit:2" ]; then
            printf 'WAKE tick-usage rc=2%s\n' "${tick_err:+ $tick_err}"
            exit_reason='wake-tick-usage'; exit 0
        fi
        focus_rebuild
        if quota_step; then exit_reason='wake-quota-back'; exit 0; fi
        if [ -n "$key" ]; then
            duty_run
            fail_streak=0
            fail_woke && save_key "${saved:-$key}"
            station_heal_step "$(field station "$tick_line")"
            if record_usage_word_and_detect_recovery; then
                printf 'WAKE budget-recovered from=%s usage=PROCEED\n' "$recovered_from"
                [ -z "$legs_from" ] || timeout -k 5 60 bash "${CHIEF_WAIT_NUDGE:-$HERE/budget-nudge.sh}" "$legs_from" 2>&1 9>&- || true  # gnu-ok: Linux-only kit (timeout); swallow-ok: a failed or hung nudge never suppresses the wake
                printf '%s\n' "$tick_line"
                [ -z "$saved" ] || { saved="${saved%usage=*}usage=PROCEED"; save_key "$saved"; }
                exit_reason='wake-budget-recovered'; exit 0
            fi
            # the worker-event wake carries the tick line and saves its key, so a re-arm
            # does not wake again on the same tails=/acts= move
            intake_clock "$(field INTAKE "$tick_line")" || true  # swallow-ok: rc 1 only says INTAKE is zero (the clock was cleared)
            if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && r0_relay; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-worker-event'; exit 0; fi
            # a denied thread resolve is the chief's job; its acts= move is folded like the worker-event wake's
            if resolve_wake; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-resolve'; exit 0; fi
            if ask_out="$(ask_row_wake)"; then printf '%s\n%s\n' "$ask_out" "$tick_line"; save_key "$key"; exit_reason='wake-t3-relay'; exit 0; fi
            # a READY is checked before it wakes; a repeat of a woken head folds into the baseline
            if ready_wake; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-ready'; exit 0; fi
            if silent_go_wake; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-silent-go'; exit 0; fi
            if size_wake; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-size'; exit 0; fi
            if pr_watch_wake_out="$(pr_watch_wake)"; then printf '%s\n%s\n' "$pr_watch_wake_out" "$tick_line"; save_key "$key"; exit_reason='wake-pr-watch'; exit 0; fi
            if t3_relay_out="$(t3_relay_step)"; then printf '%s\n%s\n' "$t3_relay_out" "$tick_line"; exit_reason='wake-t3-relay'; exit 0; fi
            if [ -n "$ready_fold" ] && [ -n "$saved" ]; then
                ready_new="$(ready_fold_key "$saved" "$key" "$ready_fold")"
                [ "$ready_new" = "$saved" ] || { saved="$ready_new"; save_key "$saved"; }
            fi
            # a wrap the relay absorbed folds only that worker into the baseline
            if [ -n "$saved" ] && { [ -n "$r0_handled" ] || [ -n "$r0_refold" ]; }; then
                saved="$(r0_fold_key "$saved" "$key" "$r0_fold")"; save_key "$saved"
            fi
            r0_refold=""
            hold_out=""
            case "$(field hreg "$tick_line")" in ''|'?'|*/*/0) ;; *) hold_out="$(page_hold_asks)" || hold_out="" ;; esac
            if [ -n "$hold_out" ]; then printf '%s\n%s\n' "$hold_out" "$tick_line"; exit_reason='wake-hold-ask'; exit 0; fi
            page_denials_stuck
            # a capped waker on a doc quiet past the bound: wake the chief, alert the operator
            if silent_out="$(silent_wake)"; then
                printf '%s\n%s\n' "$silent_out" "$tick_line"
                exit_reason='wake-worker-silent'; exit 0
            fi
            if relaunch_out="$(relaunch_wake "$(field relaunch "$tick_line")")"; then
                printf '%s\n%s\n' "$relaunch_out" "$tick_line"
                exit_reason='wake-relaunch-owed'; exit 0
            fi
            if close_cand_note "$(field close-cand "$tick_line")"; then exit_reason='wake-close-candidate'; exit 0; fi
            if held_hi_out="$(held_hi_wake "$(field held-hi "$tick_line")")"; then
                printf '%s\n%s\n' "$held_hi_out" "$tick_line"
                exit_reason='wake-held-priority'; exit 0
            fi
            resume_stale_read="" resume_stale_keys="" pool_paused=""
            case "$cap_val" in
                UNDERFILLED:*)
                    if [ ! -e "$underfill_file" ]; then
                        if pool_probe; then
                            printf '%s\n' "$pool_sig" > "$underfill_file" 2>/dev/null
                            resume_stale_scan
                            if underfill_wake; then exit_reason='wake-pool'; exit 0; fi
                        fi
                    elif underfill_repool; then
                        if underfill_wake; then exit_reason='wake-pool'; exit 0; fi
                    fi
                    if ghpaused_wake; then exit_reason='wake-pool-ghpaused'; exit 0; fi
                    if resume_stale_out="$(resume_stale_wake)"; then
                        printf 'WAKE resume-stale %s\n%s\n' "$resume_stale_out" "$tick_line"
                        exit_reason='wake-resume-stale'; exit 0
                    fi ;;
                *)
                    rm -f "$underfill_file"
                    if pool_watch_wake; then exit_reason='wake-pool-unresolved'; exit 0; fi ;;
            esac
            case "$cap_val" in UNDERFILLED:*) rm -f "$inbox.wait.pool" ;; esac
            case "$cap_val" in
                UNDERFILLED:*)
                    if orphan_wake; then exit_reason='wake-orphan-pr'; exit 0; fi ;;
            esac
            unowned_val="$(field unowned-prs "$tick_line")"
            case "$unowned_val" in
                '') unowned_none_streak=0 ;;
                '?') unowned_none_streak=0 ;;
                none)
                    unowned_none_streak=$((unowned_none_streak + 1))
                    [ "$unowned_none_streak" -lt 2 ] || rm -f "$unowned_file" "$unowned_aged_file" ;;
                *)
                    unowned_none_streak=0
                    if [ "$housekeeping_secs" -ne 0 ] && unowned_aged="$(unowned_aged_wake "$unowned_val")"; then
                        printf 'WAKE unowned-pr %s\n%s\n' "$unowned_aged" "$tick_line"
                        exit_reason='wake-unowned-pr'; exit 0
                    fi
                    if unowned_wake "$unowned_val"; then
                        # 8934: an unowned PR is look-only (the chief reads it, a worker owns the fix): every sight joins the
                        # digest and rides the next real wake; HOUSEKEEPING_DIGEST_SECS=0 keeps the unbatched wake
                        if [ "$housekeeping_secs" -eq 0 ]; then
                            printf 'WAKE unowned-prs %s\n%s\n' "$unowned_val" "$tick_line"
                            exit_reason='wake-unowned-prs'; exit 0
                        fi
                        if housekeeping_add unowned-prs "$unowned_val" "$tick_line"; then
                            exit_reason='wake-unowned-prs'; exit 0
                        fi
                    fi ;;
            esac
            unwatched_val="$(printf '%s\n' "$tick_line" | sed -n 's/.* procs=[^ ]*unwatched=\([^ ,]*\).*/\1/p')"
            if [ -z "$unwatched_val" ]; then
                # procs=unknown is a failed census, not "nothing unwatched": keep the marker
                case "$tick_line" in *" procs=unknown"*) ;; *) rm -f "$unwatched_file" ;; esac
            elif unwatched_wake "$unwatched_val"; then
                printf 'WAKE unwatched %s\n%s\n' "$unwatched_val" "$tick_line"
                exit_reason='wake-unwatched'; exit 0
            fi
            unclosed_val="$(field unclosed "$tick_line")"
            if [ -z "$unclosed_val" ]; then
                rm -f "$unclosed_file"
            elif unclosed_new="$(unclosed_wake "$unclosed_val")"; then
                printf 'WAKE unclosed %s\n%s\n' "$unclosed_new" "$tick_line"
                exit_reason='wake-unclosed'; exit 0
            fi
            if owed_new="$(owed_wake)"; then
                printf 'WAKE owed-undelivered %s\n%s\n' "$owed_new" "$tick_line"
                exit_reason='wake-owed-undelivered'; exit 0
            fi
            if table_wake="$(table_wake_read)"; then
                printf '%s\n%s\n' "$table_wake" "$tick_line"
                exit_reason='wake-table'; exit 0
            fi
            if [ -n "$console_doc" ] && [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && notification_wake; then
                printf 'WAKE owed-actions %s\n%s\n' "$owed_notifications" "$tick_line"
                # A printed wake is not a delivery receipt. Stream mode closes
                # only these notification actions through its explicit ack route;
                # proof and source step obligations remain open for the chief.
                exit_reason='wake-owed-actions'; exit 0
            fi
            if rmlease_new="$(rmlease_wake)"; then
                printf '%s\n%s\n' "$rmlease_new" "$tick_line"
                exit_reason='wake-rm-lease-stale'; exit 0
            fi
            if intake_new="$(intake_wake "$(field INTAKE "$tick_line")")"; then
                printf '%s\n%s\n' "$intake_new" "$tick_line"
                exit_reason='wake-rm-intake'; exit 0
            fi
            doctor_val="$(field doctor "$tick_line")"
            case "$doctor_val" in
                '') rm -f "$doctor_file" ;;
                '?') ;;
                *)
                    if doctor_new="$(doctor_wake "$doctor_val")"; then
                        printf 'WAKE doctor %s\n%s\n' "$doctor_new" "$tick_line"
                        exit_reason='wake-doctor'; exit 0
                    fi ;;
            esac
            cadence_val="$(field cadence "$tick_line")"
            case "$cadence_val" in
                ''|'?') ;;
                *)
                    if cadence_out="$(cadence_wake "$cadence_val")"; then
                        printf '%s\n%s\n' "$(printf '%s\n' "$cadence_out" | sed '1s/^/WAKE cadence /')" "$tick_line"
                        exit_reason='wake-cadence'; exit 0
                    fi ;;
            esac
            review_val="$(field review "$tick_line")"
            case "$review_val" in
                ''|none|'?') ;;
                *)
                    if review_out="$(review_wake "$review_val")"; then
                        printf 'WAKE %s\n%s\n' "$review_out" "$tick_line"
                        exit_reason='wake-review'; exit 0
                    fi ;;
            esac
            if drift_out="$(drift_wake "$(field drift "$tick_line")")"; then
                printf 'WAKE %s\n%s\n' "$drift_out" "$tick_line"
                exit_reason='wake-drift'; exit 0
            fi
            stale_val="$(field pool-stale "$tick_line")"
            case "$stale_val" in
                0) rm -f "$stale_file" ;;
                ''|skip|'?') ;;  # an absent or skipped field is a timeout or a failed read, never an all-clear
                *)
                    if stale_new="$(stale_wake "$stale_val")"; then
                        printf 'WAKE pool-stale %s\n%s\n' "$stale_new" "$tick_line"
                        exit_reason='wake-pool-stale'; exit 0
                    fi ;;
            esac
            if [ -n "$(field rm-refused "$tick_line")" ] && refused_out="$(refused_wake)"; then
                printf '%s\n%s\n' "$refused_out" "$tick_line"
                exit_reason='wake-rm-refused'; exit 0
            fi
            if { [ -n "$(field chief-placed "$tick_line")" ] || [ -n "$(field ask-apart "$tick_line")" ]; } && lists_out="$(lists_wake)"; then
                printf '%s\n%s\n' "$lists_out" "$tick_line"
                exit_reason='wake-rm-lists'; exit 0
            fi
            if tracker_stale_wake "$(field tracker "$tick_line")"; then
                printf 'WAKE tracker-stale tracker=%s\n%s\n' "$(field tracker "$tick_line")" "$tick_line"
                exit_reason='wake-tracker-stale'; exit 0
            fi
            if board_stale_wake "$(field board "$tick_line")"; then
                if [ "$housekeeping_secs" -eq 0 ]; then
                    printf 'WAKE board-stale board=%s\n%s\n' "$(field board "$tick_line")" "$tick_line"
                    exit_reason='wake-board-stale'; exit 0
                fi
                if housekeeping_add board-stale "board=$(field board "$tick_line")"; then
                    printf '%s\n' "$tick_line"
                    exit_reason='wake-board-stale'; exit 0
                fi
            fi
            if budget_wake; then exit_reason='wake-handover-budget'; exit 0; fi
            if sweep_out="$(sweep_wake)"; then
                printf '%s\n' "$sweep_out"
                case "$sweep_out" in
                    WAKE\ status-sweep\ *) exit_reason='wake-status-sweep' ;;
                    *) exit_reason='wake-focus' ;;
                esac
                exit 0
            fi
            cur_hash="$(printf '%s' "$key" | sha256sum | cut -c1-16)"  # gnu-ok: Linux-only kit
            if [ -z "$saved" ]; then
                saved="$key"; save_key "$key"
            elif [ "$key" = "$saved" ]; then
                pending=""
            elif [ -n "$pending" ] || ! worker_changes_routine "$saved" "$key"; then
                # Worker requests bypass debounce; other changes require
                # two consecutive samples off the saved key, equal or not: a
                # key that moves on every sample (a busy repo's PR set) is
                # still a change, not a blip. A board class move TO ok is
                # never itself a wake (only a move to STALE/MISSING is), so
                # it never appears in changed=; the key still saves.
                real_changed="$(drop_board_ok "$(changed_fields "$saved" "$key")" "$key")"
                real_changed="$(drop_denials_expiry "$real_changed" "$saved" "$key")"
                real_changed="$(drop_holds_left "$real_changed" "$saved" "$key")"
                real_changed="$(drop_owed_fall "$real_changed" "$saved" "$key")"
                real_changed="$(drop_stall_resolved "$real_changed" "$saved" "$key")"
                real_changed="$(drop_stall_resolved "$real_changed" "$saved" "$key" dispatch)"
                if [ -z "$real_changed" ]; then
                    saved="$key"; save_key "$key"; pending=""
                elif [ "$housekeeping_secs" -gt 0 ] && tick_housekeeping "$real_changed" "$saved" "$key"; then
                    if housekeeping_add tick "changed=$real_changed usage=${key##*|usage=}" "$tick_line"; then
                        exit_reason='wake-tick'; exit 0
                    fi
                    saved="$key"; save_key "$key"; pending=""
                else
                    page_denials "$saved" "$key"
                    printf 'WAKE tick changed=%s usage=%s\n%s\n' "$real_changed" "${key##*|usage=}" "$tick_line"
                    [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] || marker_note "$(moved_labels "$saved" "$key")"
                    # a vault wake names how to reproduce the stuck commit.
                    case ",$real_changed," in *,vault,*)
                        vault_dir="$(bash "$HERE/vault-status.sh" --path 2>/dev/null)" || vault_dir=""
                        printf 'vault: reproduce with git -C %s hook run pre-commit\n' "${vault_dir:-<vault>}" ;;
                    esac
                    save_key "$key"
                    exit_reason='wake-tick'; exit 0
                fi
            else
                pending=1
            fi
            if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && worker_marker_wake; then
                printf '%s\n' "$tick_line"
                exit_reason='wake-worker-marker'; exit 0
            fi
            if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && rmm_out="$(ready_mismatch_wake "$(field ready-mismatch "$tick_line")")"; then
                printf '%s\n%s\n' "$rmm_out" "$tick_line"
                exit_reason='wake-ready-mismatch'; exit 0
            fi
            if duty_out="$(duty_wake)"; then
                printf '%s\n%s\n' "$duty_out" "$tick_line"
                exit_reason='wake-chief-duty'; exit 0
            fi
        else
            pending=""
            fail_streak=$((fail_streak + 1))
            # A failed sample never masks the pool: the wake line reads
            # capacity=? and the failure in place of a tick line.
            cap_val='?'; tick_line="tick-fail samples=$fail_streak step=$fail_step"
            if pool_watch_wake; then exit_reason='wake-pool-unresolved'; exit 0; fi
            # A monitor that stays broken is an event too, but only once per
            # streak: the re-arm stays quiet until a sample succeeds.
            if [ "$fail_streak" -ge "$fail_wake" ] && ! fail_woke; then
                printf '%s\n%s\nfailwoke\n' "$args_hash" "$saved" | atomic_write "$key_file" 2>/dev/null  # swallow-ok: a key file that cannot be written only repeats the wake once
                # 8934: a failed monitor is look-only (the usual step is tick-timeout under host load): it joins the digest
                if [ "$housekeeping_secs" -eq 0 ]; then
                    printf 'WAKE tick-fail samples=%s step=%s\n' "$fail_streak" "$fail_step"
                    exit_reason='wake-tick-fail'; exit 0
                fi
                if housekeeping_add tick-fail "samples=$fail_streak step=$fail_step"; then
                    exit_reason='wake-tick-fail'; exit 0
                fi
            fi
        fi
        if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" != 1 ] && [ -z "$handover_live" ]; then
            rn_out="$(renudge_step)"; rn_rc=$?
            [ "$rn_rc" != 137 ] || kill -KILL $$
            if [ "$rn_rc" = 0 ]; then
                printf '%s\n%s\n' "$rn_out" "$tick_line"
                exit_reason='wake-worker-renudge'; exit 0
            fi
        fi
    fi
    if [ -z "$handover_live" ] && housekeeping_flush; then
        exit_reason='wake-housekeeping'; exit 0
    fi
    heartbeat waiting
    stream_stop_point
    # an offer is work of the pass that saw it only: read and cleared here, so a pass that skips the service block
    # (handover mode) never counts an earlier pass's offer as its own
    [ -z "${r0_offered:-}" ] || idle_passes=0
    r0_offered=""
    idle_passes=$(( idle_passes + 1 ))
    if [ "${CHIEF_WAIT_STREAM_SERVICE:-0}" = 1 ] && [ "$idle_passes" -gt "$idle_runs" ]; then
        nap "$idle_poll"
    else
        nap "$poll"
    fi
done
