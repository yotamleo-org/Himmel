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
#   WAKE underfilled capacity=UNDERFILLED:<n> the tick's capacity
#   <tick line>                 field says live < cap with no launch for
#   <next-dispatchable.sh out>  TICK_UNDERFILL_MIN; on the streak's first sample, and
#                               again once each time the pool's key set changes (re-probed
#                               every CHIEF_WAIT_UNDERFILL_REPOOL_SEC, default 1800; a pool
#                               that grows from empty counts, a failed probe or an emptied
#                               pool does not), with the
#                               priority-pool list (--priority-pool-only, plus
#                               --doc when given; POOL-EMPTY when nothing is in
#                               the pool), the earliest unreleased version's rows first under
#                               `# dispatchable in <version>`, other pool rows under
#                               `# dispatchable in other versions`, and no `# disposition`
#                               line for a listed row; versionless operator work adds the
#                               `# intake <m> for <version>: <keys>` line and an `# INTAKE:` line naming the
#                               command that files their INTAKE requests;
#                               a LOW, INTAKE or empty pool (short of its slots) adds a second pass
#                               without it, its rows not already in the pool under
#                               `# version backlog`, and the wake line then carries
#                               dispatchable=<n>, the count of dispatchable To Do
#                               rows (CHIEF_WAIT_DISPATCH
#                               replaces the command, tests; it never launches).
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
#   WAKE predecessor-open rc=<n>  with --doc <chief doc> whose first line says
#                               `successor to <doc>.md`: the waiter runs
#                               close-wrapped-worker.sh --chief on that wrapped,
#                               lock-free predecessor once and logs a Results
#                               bullet; rc 3/4/6/7 retry silently next sample, and so does a
#                               hung close (rc 124/137) until CHIEF_WAIT_CLOSE_HANGS
#                               (default 3) in a row, then it wakes (the streak shows
#                               in the heartbeat as pred_hangs=<n>); any other
#                               refusal wakes once (CHIEF_WAIT_CLOSE = seam).
#   WAKE worker-event <line> rc=<n> out=<file>  with --doc and --workers-from (the script relay,
#                               R0): a worker whose tails= is WRAPPED or acts= MERGED is
#                               wrapped by `timeout -k 5 240 worker-event.sh --doc --fleet` on
#                               a line built from its newest such bullet; HANDLED is a
#                               digest line, no wake; a lock-held / not-yet-WRAPPED /
#                               subtree-alive refusal retries next sample; any other
#                               ESCALATE or rc wakes once per bullet, <line> being
#                               worker-event's first non-blank output line (a silent failure
#                               gets an ESCALATE reason with its rc), the tick line after it
#                               (its key is saved) (CHIEF_WAIT_WORKER_EVENT = seam). Every WAKE block ends with `absorbed since last
#                               wake: wraps=<n> (<labels>) merged=<n> (#<pr>,...)` when
#                               the relay absorbed anything, and the digest clears.
#                               With the auto_go flag on, the relay also hands every new
#                               READY bullet of a manifest worker to worker-event once, after
#                               any wrap, even when a LIVE bullet follows it inside one
#                               sample: <inbox>.wait.ready keeps a line cursor per worker. A
#                               worker met for the first time starts after its existing READYs.
#   WAKE resolve <worker> pr=<n> threads=<id,...>  with --workers-from: a worker doc whose newest
#                               marker bullet is `BLOCKED resolve <pr> <PRRT_ ids>` (its
#                               resolve call was denied). Once per bullet; the chief
#                               resolves each thread itself, never the operator. The
#                               tick line follows and its key is saved.
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
#                               <the doc's basename> says HANDOVER (110 turns, 30M
#                               cache-read or 45 % context fill); the marker clears on OK
#                               and, while HANDOVER holds, the wake repeats (marked
#                               `repeat`) every CHIEF_WAIT_BUDGET_REPEAT_MIN minutes
#                               (default 30). CHIEF_WAIT_BUDGET replaces the command, tests.
#   WAKE status-sweep <line>    with --doc <chief doc>: status-sweep.sh every 15 min
#                               (WAIT_SWEEP_SEC), bounded at 60 s, woke only when it
#                               moved a ticket or its failure signature is new.
#   WAKE focus <state>          the same pass: focus-refresh.sh --status is FAILED:<stage>,
#                               or DIRTY:<n>m with n of 10 or more; once per state.
#                               Each tick also starts one background refresh of a
#                               DIRTY or FAILED page (none while one runs); no wake.
#   WAKE tick-fail samples=<n> step=<step>  CHIEF_WAIT_FAIL_WAKE consecutive samples
#                               failed (tick or bank read): the monitor is
#                               broken. step= names the last sample's failure:
#                               tick-timeout:<s>, tick-exit:<rc>, no-tick-line,
#                               usage-read or missing-field:<name>. Once per streak;
#                               the re-arm stays quiet until a sample succeeds.
#
# The action key is the tick fields a chief acts on: workers= (an older tick's legs=),
# livestate=, prs=, tails=, acts= (a worker's newest READY, BLOCKED, FINDING or MERGED bullet and a count:
# a repeat or a later LIVE bullet cannot hide it; absent when a worker has none), workerset= (an older
# tick's legset=), board= and tracker= (class only, the STALE
# age is dropped; tracker= is absent from an older tick line, never a failure),
# vault= (class only, wakes ONLY on a move to STALL or PUSH-LAG --
# never on a change of its age or count, nor a move back to ok/skip/unknown --
# and the wake adds a `vault: reproduce with git -C <vault> hook run pre-commit`
# line; absent from an older tick line, never a failure),
# cloud= (class only, wakes ONLY on a move to STALL -- never on a
# change of the ticket list, nor a move back to ok/skip; absent from an older
# tick line, never a failure),
# orphans-wip= (in-work tickets with no worker and no open PR; `n:KEY,...`, `?` or
# `skip`) is in the key whole, so any change of its value wakes; absent from an older
# tick line, never a failure.
# vmismatch= (tick.sh: RESET rows of the version-status audit) wakes while it is a positive
# count and on any change of that count; 0, ? and an absent field are left out of the key.
# wt-ceiling= (the live/cap alarm) is in the key whole: reaching the ceiling
# wakes once, while an unchanged alarm stays silent; absent is not a failure.
# unowned-prs= is NOT in the action key (its minutes grow every tick): a
# non-empty list wakes on first sight (`WAKE unowned-prs <list>`), again at once when
# a PR joins it, and again every CHIEF_WAIT_UNOWNED_REWAKE_MIN (default 60) while it
# stays non-empty. The marker `<inbox>.wait.unowned` (its body the PR numbers last
# woken for) outlives the waiter like the underfill one; it clears after two
# consecutive samples reading none, so one failed gh read is not an all-clear. A tick
# line without the field is skipped.
# pool-stale= (`n:KEY,...`, `?` for an unreadable blocker, never in the action key) wakes
# once per newly stale disposition key (`WAKE pool-stale <KEYS>`): the marker `<inbox>.wait.stale`
# holds the keys last seen, shrinks to the current set on a full read and has no re-wake
# window. A `?`-only value, a partial read (`1:KEY,?`, which only adds to the marker) and an
# absent or skip field keep it (a failed read is not an all-clear); an explicit 0 clears it,
# so a key that leaves and rejoins wakes again.
# procs=...,unwatched=N1+N2 (a live worker outside the fleet manifest; tick.sh drops other
# chiefs' workers) wakes the same way (`WAKE unwatched <labels>`): first sight, a label new
# to the marker `<inbox>.wait.unwatched`, or every CHIEF_WAIT_UNWATCHED_REWAKE_MIN (default
# 60) while it stays non-empty. The marker clears when the field is gone.
# vmrun= (class only, wakes ONLY on a move to DEAD, STUCK or DISAGREE -- never
# on the busy count, nor a move to ok/off/FAILING; absent from an older tick line,
# never a failure),
# parked= (the workers sitting on an unanswered permission prompt, names only so the
# growing age never re-wakes; absent from the tick line when none is parked, never
# a failure; a worker joining or leaving the set wakes),
# holds= (tick.sh: `<worker>:<age>m,...`, BLOCKED workers past TICK_HOLD_MIN; names only, so the
# age never re-wakes) wakes when a worker ENTERS the set, once per hold: a worker leaving or the
# set emptying wakes nothing; absent when no worker holds, never a failure),
# stall= (tick.sh: `<pr>:<class>,...` from pr-stall.sh) wakes ONCE per new
# conflict or no-ci token (a PR, a class): ci-slow and idle are report-only, an unchanged set
# and a stall resolving do not wake; stall=? (a probe outage) keeps the saved set; absent
# from an older tick line, never a failure),
# denials= (a new worker, a higher count or a higher class
# (SHIP-STEP > PAUSE-RISK > REPEAT) is exactly the alert this exists to
# surface; the same denial ageing out of tick.sh's 30-min window, moving it to
# none or lowering a count, is NOT a wake, so one denial wakes once) and the
# bank-preflight verdict word.
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
# Files next to the inbox:
#   <inbox>.wait       heartbeat, rewritten every poll:
#                      `hb=<epoch> pid=<pid> key=<sha16> tick=<ok|fail|-> state=waiting`,
#                      `state=sampling` while a tick runs, then on every
#                      catchable exit `... state=exited exit=<reason>`.
#                      A sample (a predecessor close, a tick, then bank) can take up to
#                      CHIEF_WAIT_CLOSE_TIMEOUT once, then twice
#                      CHIEF_WAIT_TICK_TIMEOUT (+5 s kill grace each), and a
#                      Telegram line waits for it. The relay adds at most one
#                      wrap attempt (240 s +5 s kill grace), refreshing the heartbeat
#                      before its call. Older than those bounds plus a few polls,
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
#   <inbox>.wait.ready   with auto_go on: `<label><TAB><line>`, the last READY bullet handed on.
#   <inbox>.handover     handover mode: while it is fresh (younger
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
#                        whose LIVE follows it), removes the marker and exits 0. It works in handover mode. Seams:
#                        CHIEF_WAIT_LOCK_STATUS, CHIEF_WAIT_RELAY (tests).
#
# Exit: 0 = a WAKE block was printed; 1 = the inbox could not be drained;
# 2 = usage or an inbox outside the */consoles/<name>.md layout; 3 = another waiter is already live on this inbox (its pid is named).
#
# Env: CHIEF_WAIT_INTERVAL tick interval in seconds (default 180);
# CHIEF_WAIT_POLL_SEC inbox poll (default 1); CHIEF_WAIT_TICK_TIMEOUT
# seconds a tick may run before it counts as failed (default 120), so a hung
# tick cannot freeze the Telegram path; CHIEF_WAIT_FAIL_WAKE consecutive
# failed samples before a tick-fail wake (default 3); CHIEF_WAIT_TICK / CHIEF_WAIT_USAGE
# replace tick.sh / the bank verdict command (tests); CHIEF_WAIT_PAGE_CMD
# replaces the Telegram sender (called as `$CMD <text>`, tests) and
# CHIEF_WAIT_PAGE_TIMEOUT bounds it (seconds, default 45); HIMMEL_DENIAL_ACK_DIR
# relocates the page/ack records (default ~/.himmel/state/denial-acks).
#
# Worker messages (SendMessage) wake a chief on their own; only the Telegram
# and tick paths depend on this waiter.
#
# ponytail: upgrade path HIMMEL-3510. An external SIGKILL of the waiter re-invokes the session (task
# notification, measured); the harness-internal "low memory" kill
# of a background task is unreproduced, so a waiter lost that way
# is visible only as a stale heartbeat, upgrade: a bridge-side
# stale-heartbeat alert.
#
# PLATFORM GUARD: the chief kit is Linux-only.
# bash 3.2-safe.
set -u
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/prim.sh
. "$REPO/scripts/lib/prim.sh" || exit 2

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
# ponytail: a swap between the check and inbox-follow.sh's open still reads
# the new target; upgrade path is handing inbox-follow.sh the checked fd.
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
# page/ack record helpers. A missing lib fails open: no records, the
# page still sends.
if [ -r "$HERE/denial-ack-lib.sh" ]; then . "$HERE/denial-ack-lib.sh"; else denial_page_write() { return 1; }; fi
hb_file="$inbox.wait"
key_file="$inbox.wait.state"
interval="${CHIEF_WAIT_INTERVAL:-180}"
poll="${CHIEF_WAIT_POLL_SEC:-1}"
tick_timeout="${CHIEF_WAIT_TICK_TIMEOUT:-120}"
tick_cmd="${CHIEF_WAIT_TICK:-$HERE/tick.sh}"

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
    awk '{ n++; l = l (n > 1 ? "," : "") $1; if ($3 != "-") { m++; p = p (m > 1 ? "," : "") "#" $3 } }
         END { printf "absorbed since last wake: wraps=%d (%s) merged=%d (%s)\n", n, l, m, p }' "$digest_file"
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
trap 'digest_flush; heartbeat exited "$exit_reason"' EXIT
trap "exit_reason='signal-TERM'; exit 143" TERM
trap "exit_reason='signal-INT'; exit 130" INT
trap "exit_reason='signal-HUP'; exit 129" HUP

# with --workers-from (or WORKERS_FROM) the argv never changes when the
# chief dispatches or wraps, so the manifest's worker list is folded into the
# args hash, re-read before every sample: a worker-set change made through the
# manifest is a silent baseline, the same as a re-arm with a new --workers. An
# unreadable manifest hashes as empty (its tick fails that sample anyway).
legs_from="${WORKERS_FROM:-}"
console_doc=""
prev_arg=""
# --succession / --silent-min belong to this waiter, not to tick.sh: take them out of
# the tick args before anything hashes or forwards them.
succession=""; silent_min=20
rest_args=()
for a in "$@"; do
    case "$prev_arg" in
        --succession) succession="$a"; prev_arg="$a"; continue ;;
        --silent-min) silent_min="$a"; prev_arg="$a"; continue ;;
    esac
    case "$a" in --succession|--silent-min) prev_arg="$a"; continue ;; esac
    [ "$prev_arg" = --workers-from ] && legs_from="$a"
    [ "$prev_arg" = --doc ] && console_doc="$a"
    prev_arg="$a"
    rest_args+=("$a")
done
set -- ${rest_args[@]+"${rest_args[@]}"}
case "$prev_arg" in --succession|--silent-min) echo "chief-wait: $prev_arg needs a value" >&2; exit 2 ;; esac
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

# bank_word: prints the bank-preflight verdict token; non-zero when the read
# failed, timed out, or its last line is not one of the verdict tokens.
bank_word() {
    local out
    if [ -n "${CHIEF_WAIT_USAGE:-}" ]; then
        out="$(bash "$CHIEF_WAIT_USAGE" 2>/dev/null)" || return 1
    else
        # gnu-ok: Linux-only kit (timeout). Same side-effect-free spelling tick.sh uses for its fleet census.
        out="$(CADENCE_USAGE_LAUNCH='' CADENCE_USAGE_LEDGER=/dev/null timeout -k 5 "$tick_timeout" \
            bash "$REPO/scripts/lib/usage-preflight.sh" 2>/dev/null)" || return 1
    fi
    out="$(printf '%s\n' "$out" | tail -n 1)"
    case "$out" in
        PROCEED|SKIPPED-BANK|SKIPPED-FLEET|BANK-STALE|BANK-UNKNOWN) printf '%s\n' "$out" ;;
        *) return 1 ;;
    esac
}

field() { # <name> <tick line>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

# old_key_names: a key saved under the old field names (legs=, legset=, bank=) reads
# as the same key under the new ones, so a restart over it is no change.
old_key_names() {
    printf '%s\n' "$1" | sed -E 's/(^|\|)legs=/\1workers=/; s/(^|\|)legset=/\1workerset=/; s/(^|\|)bank=/\1usage=/'
}

# sample: sets tick_line and key (empty on a failed tick, with fail_step naming why).
sample() {
    local f v raw bank rc
    key=""; cap_val=""; fail_step=""
    # A tick that exits non-zero failed, whatever it printed first.
    raw="$(timeout -k 5 "$tick_timeout" bash "$tick_cmd" "$@" 2>/dev/null)" || {  # gnu-ok: Linux-only kit
        rc=$?
        case "$rc" in 124|137) fail_step="tick-timeout:${tick_timeout}s" ;; *) fail_step="tick-exit:$rc" ;; esac
        tick_state=fail; return; }
    tick_line="$(printf '%s\n' "$raw" | grep '^TICK ' | head -n 1)"
    if [ -z "$tick_line" ]; then fail_step=no-tick-line; tick_state=fail; return; fi
    # A failed or garbled bank read is a failed sample, not a verdict.
    bank="$(bank_word)" || { fail_step=usage-read; tick_state=fail; return; }
    tick_state=ok
    cap_val="$(field capacity "$tick_line")"
    for f in workers livestate prs tails acts holds workerset board tracker vault cloud orphans-wip wt-ceiling vmismatch vmrun parked stall dispatch denials closable deadwin; do
        v="$(field "$f" "$tick_line")"
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
        if { [ "$f" = tracker ] || [ "$f" = acts ] || [ "$f" = holds ] || [ "$f" = vault ] || [ "$f" = cloud ] || [ "$f" = orphans-wip ] || [ "$f" = wt-ceiling ] || [ "$f" = vmismatch ] || [ "$f" = vmrun ] || [ "$f" = parked ] || [ "$f" = stall ] || [ "$f" = closable ] || [ "$f" = deadwin ] || [ "$f" = dispatch ]; } && [ -z "$v" ]; then continue; fi
        # A field missing from a malformed/partial tick line is a failed
        # sample, never a key with an empty value baked in.
        if [ -z "$v" ]; then fail_step="missing-field:$f"; tick_state=fail; key=""; return; fi
        case "$f" in board|tracker|vault|cloud|vmrun) v="${v%%:*}" ;; esac
        # vmrun= keeps its class only, not the counts.
        [ "$f" = vmrun ] && v="${v%%,*}"
        # vmismatch= stays in the key only as a positive count: 0 leaves it out, and ? (a failed
        # audit read) keeps the saved count, so a blip after a positive count is not a change.
        if [ "$f" = vmismatch ]; then
            [ "$v" != '?' ] || v="$(key_field vmismatch "$saved")"
            case "$v" in ''|0) continue ;; esac
        fi
        # parked= keeps the worker names only: the age grows every tick and must not re-wake.
        # The names are sorted: the doc order must not decide the key.
        [ "$f" = parked ] && v="$(printf '%s' "$v" | sed -E 's/:[0-9]+m(,|$)/\1/g' | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
        # holds= keeps the worker names only, sorted: the age grows every tick and must not re-wake.
        [ "$f" = holds ] && v="$(printf '%s' "$v" | sed -E 's/:[0-9]+m(,|$)/\1/g' | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
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
        case "$f" in board|tails|acts) ;; *) return 1 ;; esac
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
    local board_new tracker_new vault_new cloud_new vmrun_new
    vmrun_new="$(key_field vmrun "$2")"
    board_new="$(key_field board "$2")"
    tracker_new="$(key_field tracker "$2")"
    vault_new="$(key_field vault "$2")"
    cloud_new="$(key_field cloud "$2")"
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r f; do
        [ "$f" = board ] && [ "$board_new" = ok ] && continue
        [ "$f" = tracker ] && [ "$tracker_new" = ok ] && continue
        # vault= wakes only on a class move TO STALL / PUSH-LAG.
        if [ "$f" = vault ]; then
            case "$vault_new" in STALL|PUSH-LAG) ;; *) continue ;; esac
        fi
        # cloud= wakes only on a class move TO STALL, never back to ok/skip.
        [ "$f" = cloud ] && [ "$cloud_new" != STALL ] && continue
        # vmrun= wakes only on a class move TO DEAD / STUCK / DISAGREE.
        if [ "$f" = vmrun ]; then
            case "$vmrun_new" in DEAD|STUCK|DISAGREE) ;; *) continue ;; esac
        fi
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

# denials_rose: <old key> <new key> — succeeds only when the denials= value got
# WORSE: a worker the old value lacked, a higher count, or a higher class
# (SHIP-STEP > PAUSE-RISK > REPEAT > none). tick.sh's denials= is a trailing
# window, so a lone denial ageing out (30 min later) moves it to none or
# lowers a count; that is the window closing, not an event.
denial_rank() { case "$1" in SHIP-STEP) echo 3 ;; PAUSE-RISK) echo 2 ;; REPEAT) echo 1 ;; *) echo 0 ;; esac; }
denials_rose() {
    local old new tok otok leg rest n cls on ocls found
    old="$(key_field denials "$1")"; new="$(key_field denials "$2")"
    for tok in $(printf '%s' "$new" | tr ',' ' '); do
        leg="${tok%%:*}"
        case "$leg" in none|skip) continue ;; esac
        rest="${tok#*:}"; n="${rest%%:*}"; cls=""
        case "$rest" in *:*) cls="${rest#*:}" ;; esac
        found=""
        for otok in $(printf '%s' "$old" | tr ',' ' '); do
            [ "${otok%%:*}" = "$leg" ] || continue
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
    local old new tok otok leg rest n cls ocls
    old="$(key_field denials "$1")"; new="$(key_field denials "$2")"
    for tok in $(printf '%s' "$new" | tr ',' ' '); do
        leg="$(printf '%s' "${tok%%:*}" | tr -cd 'A-Za-z0-9._#+-')"
        case "$leg" in ''|none|skip) continue ;; esac
        rest="${tok#*:}"; n="${rest%%:*}"; cls=""
        case "$rest" in *:*) cls="${rest#*:}" ;; esac
        [ "$(denial_rank "$cls")" -ge 2 ] || continue
        ocls=""
        for otok in $(printf '%s' "$old" | tr ',' ' '); do
            [ "${otok%%:*}" = "${tok%%:*}" ] || continue
            rest="${otok#*:}"; ocls=""
            case "$rest" in *:*) ocls="${rest#*:}" ;; esac
        done
        [ "$(denial_rank "$cls")" -gt "$(denial_rank "$ocls")" ] && printf '%s %s %s\n' "$leg" "$cls" "$n"
    done
}

# page_send: <text> — ONE operator Telegram message via the bridge path the kit
# already uses (merge-block-alert.sh: the first positive allowFrom of access.json,
# chief-route.ts reply). CHIEF_WAIT_PAGE_CMD replaces it (tests; called as
# `$CMD <text>`). Bounded by CHIEF_WAIT_PAGE_TIMEOUT (default 45 s) and always
# rc 0: a failed or hung send never breaks the waiter or delays the wake past
# the bound.
page_timeout="${CHIEF_WAIT_PAGE_TIMEOUT:-45}"
page_send() {  # <text> <deadline epoch>: the timeout is what is left of the batch budget
    local left=$(( $2 - $(date +%s) ))
    [ "$left" -ge 1 ] || return 0
    if [ -n "${CHIEF_WAIT_PAGE_CMD:-}" ]; then
        timeout -k 2 "$left" "$CHIEF_WAIT_PAGE_CMD" "$1" </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    else
        # shellcheck disable=SC2016  # $1/$2 expand in the child bash, not here
        timeout -k 2 "$left" bash -c '. "$1" && chat="$(_mba_operator_chat)" && [ -n "$chat" ] && _mba_send "$chat" "$2"' \
            _ "$REPO/scripts/lib/merge-block-alert.sh" "$1" </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    fi
    return 0
}

# page_denials: <old key> <new key> — page each denial_pages worker. The page
# record is written FIRST, so the re-dispatch refusal holds even when the send
# fails; both steps fail open. The page text is the worker label, count and class
# only: this file never reads the denial log, only tick.sh's denials= field.
page_denials() {
    local leg cls n end
    end=$(( $(date +%s) + page_timeout ))  # one budget for the whole batch, not one per leg
    denial_pages "$1" "$2" | while read -r leg cls n; do
        denial_page_write "$leg" "$n" "$cls" || true
        page_send "DENIAL-PAGE $leg $cls x$n - a classifier denial parked this worker. Review it, then: ack-denial.sh $leg" "$end"
    done
}

# capacity=UNDERFILLED:<n> (tick.sh already folds TICK_UNDERFILL_MIN
# into it) wakes on the streak's first sample. The marker file outlives the waiter, so a
# re-arm inside the same streak stays quiet; capacity=ok removes it. Its first line is the
# pool's dispatchable key set at the last wake; once the marker is
# CHIEF_WAIT_UNDERFILL_REPOOL_SEC old (default 1800) the pool is probed again and a changed,
# non-empty key set wakes once more (a pool that grew from empty, or moved): the first
# probe may have read a transient empty pool, and the streak never re-woke on it.
underfill_file="$inbox.wait.underfill"
unowned_file="$inbox.wait.unowned"
unowned_none_streak=0
dispatch_cmd="${CHIEF_WAIT_DISPATCH:-$HERE/next-dispatchable.sh}"
pool_probe() { # [timeout secs] sets pool_lf (the dispatch flags), pool_out (the priority-pool pass) and pool_sig (its sorted key set)
    local budget="${1:-${CHIEF_WAIT_DISPATCH_TIMEOUT:-420}}"
    pool_lf=(); pool_out=""; pool_sig=""; pool_summary=""; pool_counts=""; pool_unresolved=""
    [ -r "$dispatch_cmd" ] || return 0
    case "${cap_val#UNDERFILLED:}" in ''|*[!0-9]*) ;; *) pool_lf+=(--top "${cap_val#UNDERFILLED:}") ;; esac  # the slack is the slot count pool=<n>/<slots> reads against
    [ -z "$console_doc" ] || pool_lf+=(--doc "$console_doc")  # its Live state `priority:` line ranks tier 1
    [ -z "$legs_from" ] || pool_lf+=(--workers-from "$legs_from")  # live legs' files must reach the collision check
    pool_out="$(timeout -k 2 "$budget" bash "$dispatch_cmd" --priority-pool-only --dispositions "${pool_lf[@]}" </dev/null 2>/dev/null 9>&-)" || pool_out=""  # gnu-ok: Linux-only kit; swallow-ok: a failed or timed-out dispatch drops its partial rows, the wake block still prints
    pool_sig="$(printf '%s\n' "$pool_out" | awk '$1 != "NEXT-TIER" && $1 != "RESUME-HELD" && $2 ~ /^[A-Z]+-[0-9]+$/ { print $2 }' | sort -u | paste -sd, -)"
    pool_summary="$(printf '%s\n' "$pool_out" | DOC='' bash "$HERE/tick.sh" --pool-dispositions --doc "$console_doc" 2>/dev/null)" || pool_summary=""  # swallow-ok: an unavailable interpreter keeps the legacy underfill wake, never an all-clear
    pool_counts="$(printf '%s\n' "$pool_summary" | sed -n 's/^# pool-counts //p')"
    pool_unresolved="$(printf '%s\n' "$pool_summary" | sed -n '/^# pool-unresolved /p')"
}
pool_view() { # stdin: the pool pass; stdout: its ticket rows grouped under a '# dispatchable in <version>' heading (the version of its '# dropped from' line), then the rest; a listed row's '# disposition' line is dropped, the row already says it
    awk -F'\t' '
        /^# dropped from / { ver = $0; sub(/^# dropped from /, "", ver); sub(/:.*/, "", ver) }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                n = split(line[i], f, "\t")
                if (f[1] ~ /^(LOCAL\??|CLOUD|RESUME|MERGED-NOT-CLOSED)$/ && f[2] ~ /^[A-Z]+-[0-9]+$/) {
                    is_cur = 0
                    m = split(f[4], v, ",")
                    for (j = 1; j <= m; j++) if (ver != "" && v[j] == ver) is_cur = 1
                    kind[i] = is_cur ? "cur" : "other"
                } else if (line[i] ~ /^# disposition [A-Z]+-[0-9]+ listed /) kind[i] = "drop"
                else kind[i] = "rest"
            }
            for (i = 1; i <= NR && kind[i] != "cur" && kind[i] != "other"; i++) if (kind[i] == "rest") print line[i]  # the header lines before the first row stay first
            first = i
            for (i = 1; i <= NR; i++) if (kind[i] == "cur") { if (!hc++) print "# dispatchable in " ver; print line[i] }
            for (i = 1; i <= NR; i++) if (kind[i] == "other") { if (!ho++ && ver != "") print "# dispatchable in other versions"; print line[i] }
            for (i = first; i <= NR; i++) if (kind[i] == "rest") print line[i]
        }'
}
underfill_wake() { # prints the WAKE block for the pool pool_probe just read; fail-open on the dispatchable list
    local back="" extra="" count="" intake_ver="" wake=underfilled
    if [ -n "$pool_unresolved" ]; then wake=pool-unresolved
    else
        case "$pool_counts" in ''|'?') ;; *) return 1 ;; esac
    fi
    # a LOW or empty pool leaves slots idle: a second pass without --priority-pool-only lists the version
    # backlog (later versions included); its rows already in the pool are printed once, under their own heading
    if printf '%s\n' "$pool_out" | awk -F'[=/,]' '/^# pool=/ && ($2 + 0) < ($3 + 0) { f = 1 } $0 == "POOL-EMPTY" { f = 1 } END { exit !f }'; then  # a pool short of its slots, whether the line says LOW or INTAKE:<m>
        heartbeat sampling
        back="$(timeout -k 2 "${CHIEF_WAIT_DISPATCH_TIMEOUT:-420}" bash "$dispatch_cmd" "${pool_lf[@]}" </dev/null 2>/dev/null 9>&-)" || back=""  # gnu-ok: Linux-only kit; swallow-ok: a failed or timed-out second pass drops its partial rows, the pool list still prints
        extra="$(printf '%s\n' "$back" | awk -v pool="$pool_out" '
            BEGIN { n = split(pool, p, "\n"); for (i = 1; i <= n; i++) { split(p[i], f, "\t"); if (f[1] != "NEXT-TIER" && f[2] ~ /^[A-Z]+-[0-9]+$/) seen[f[2]] = 1 } }
            $0 == "" || seen[$2] { next }
            { print }')"
        count="$(printf '%s\n%s\n' "$pool_out" "$back" | awk -F'\t' '$1 ~ /^(LOCAL\??|CLOUD)$/ && $2 ~ /^[A-Z]+-[0-9]+$/ { k[$2] = 1 } END { n = 0; for (i in k) n++; print n }')"
    fi
    if [ "$wake" = pool-unresolved ]; then
        printf 'WAKE pool-unresolved capacity=%s%s%s\n%s\n' "$cap_val" "${pool_counts:+ pool=$pool_counts}" "${count:+ dispatchable=$count}" "$tick_line"
    else
        printf 'WAKE underfilled capacity=%s%s%s\n%s\n' "$cap_val" "${pool_counts:+ pool=$pool_counts}" "${count:+ dispatchable=$count}" "$tick_line"
    fi
    [ -z "$pool_out" ] || printf '%s\n' "$pool_out" | pool_view
    [ -z "$pool_unresolved" ] || printf '%s\n' "$pool_unresolved"
    intake_ver="$(printf '%s\n' "$pool_out" | sed -n 's/^# intake [0-9][0-9]* for \([^:]*\):.*/\1/p' | head -n 1)"  # the line's candidates already printed with the pool; this names the way to file them
    [ "$intake_ver" != "no open version" ] || intake_ver=""  # an older dispatcher's line for no open version: nothing to file into
    [ -z "$intake_ver" ] || printf '%s\n' "# INTAKE: versionless operator work is not in the pool; file each key above with \`jira release request <release> --verb INTAKE --key <KEY> --to $(printf '%q' "$intake_ver") --why <why>\`, then run the rm-run once for the batch"
    [ -z "$extra" ] || printf '# version backlog (second pass without --priority-pool-only; rows already in the pool omitted):\n%s\n' "$extra"
}
# pool_watch_wake: even a full fleet, or a failed tick sample, may have silently dropped
# version tickets. On the CHIEF_WAIT_UNDERFILL_REPOOL_SEC cadence (marker <inbox>.wait.pool)
# probe the pool; an unresolved key prints the pool-unresolved wake and succeeds.
pool_watch_wake() {
    local pool_watch="$inbox.wait.pool"
    if [ ! -e "$pool_watch" ] || [ "$(( $(date +%s) - $(stat -c %Y "$pool_watch" 2>/dev/null || echo 0) ))" -ge "${CHIEF_WAIT_UNDERFILL_REPOOL_SEC:-1800}" ]; then  # gnu-ok: chief kit is Linux-only; swallow-ok: an unreadable marker is due
        pool_probe "${CHIEF_WAIT_REPOOL_TIMEOUT:-120}"
        touch "$pool_watch" 2>/dev/null
        if [ -n "$pool_unresolved" ]; then
            underfill_wake
            return 0
        fi
    fi
    return 1
}
# underfill_repool: succeeds (and saves the new key set) when the marker is due for a re-probe
# and the pool's non-empty key set differs from the saved one. A failed probe reads no output and
# never counts; every due probe restarts the cadence clock. The probe blocks the Telegram path
# and the heartbeat like a tick does, so it gets CHIEF_WAIT_REPOOL_TIMEOUT (default 120), well
# inside the five-minute stale-heartbeat window.
underfill_repool() {
    local age saved_sig
    age=$(( $(date +%s) - $(stat -c %Y "$underfill_file" 2>/dev/null || echo 0) ))  # gnu-ok: Linux-only kit; swallow-ok: a failed stat reads epoch 0, so the probe is simply due
    [ "$age" -ge "${CHIEF_WAIT_UNDERFILL_REPOOL_SEC:-1800}" ] || return 1
    saved_sig="$(sed -n 1p "$underfill_file" 2>/dev/null)"  # swallow-ok: an unreadable marker reads no saved set, so a non-empty pool wakes
    heartbeat sampling
    pool_probe "${CHIEF_WAIT_REPOOL_TIMEOUT:-120}"
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
    return 1
}

# unowned_wake: <unowned-prs value> — succeeds (and refreshes the marker) when the list is
# new to the marker, holds a PR the marker lacks, or the marker is older than the re-wake
# window.
unowned_wake() {
    set_wake "$(printf '%s\n' "$1" | tr ',' '\n' | sed 's/:.*//')" "$unowned_file" "${CHIEF_WAIT_UNOWNED_REWAKE_MIN:-60}"
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
# unwatched_wake: <unwatched= labels, `+`-joined> — a live worker the manifest does not list
# (tick.sh already drops other chiefs' workers). Same marker logic, own marker, own window.
unwatched_file="$inbox.wait.unwatched"
unwatched_wake() {
    set_wake "$(printf '%s\n' "$1" | tr '+' '\n')" "$unwatched_file" "${CHIEF_WAIT_UNWATCHED_REWAKE_MIN:-60}"
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
# tracker_stale_wake: <tracker= value> — a tracker that STAYS stale. A class change
# wakes once (above); after the first STALE the class never moves again, so the
# marker holds the epoch the streak was first seen and the wake fires once the
# streak passes CHIEF_WAIT_TRACKER_STALE_MIN (default 30). Any other value ends
# the streak. The marker outlives the waiter, so a re-arm inside a streak stays quiet.
tracker_stale_file="$inbox.wait.trackerstale"
tracker_stale_wake() { stale_streak_wake "$1" "$tracker_stale_file" "${CHIEF_WAIT_TRACKER_STALE_MIN:-30}" 30; }
# board_stale_wake: <board= value> — the same for a board that stays stale, marker
# <inbox>.wait.boardstale, threshold CHIEF_WAIT_BOARD_STALE_MIN (default 10).
board_stale_file="$inbox.wait.boardstale"
board_stale_wake() { stale_streak_wake "$1" "$board_stale_file" "${CHIEF_WAIT_BOARD_STALE_MIN:-10}" 10; }
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
        DIRTY:*m)
            age="${fstat#DIRTY:}"; age="${age%m}"
            case "$age" in ''|*[!0-9]*) rm -f "$sweep_focus_file"; return 1 ;; esac
            [ "$age" -ge 10 ] || return 1 ;;
        *) rm -f "$sweep_focus_file"; return 1 ;;
    esac
    fkey="$fstat"
    case "$fstat" in DIRTY:*) fkey=DIRTY ;; esac
    [ "$(cat "$sweep_focus_file" 2>/dev/null)" != "$fkey" ] || return 1  # swallow-ok: no marker reads empty, so the first sight wakes
    printf '%s\n' "$fkey" > "$sweep_focus_file" 2>/dev/null
    printf 'WAKE focus %s\n' "$fstat"
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

# predecessor_close: the chief doc's first line names its predecessor
# (`successor to <doc>.md`). Once that doc is WRAPPED and lock-free with exactly one
# live session, close-wrapped-worker.sh --chief closes it, once, and a Results bullet
# says so. close-wrapped-worker.sh owns every check; this only reads its exit code:
# 0 closed; 3/4 the predecessor is not done (lock held / tail not WRAPPED) and 6/7 its
# subtree or a subagent is still alive: left alone, asked again next sample; 5 with
# "0 live session" means the window is already gone; any other refusal sets the
# marker and prints the wake (rc 0). The marker `<inbox>.wait.predecessor` (body:
# `<state>:<doc>`) outlives the waiter, so a done predecessor is never asked twice.
pred_file="$inbox.wait.predecessor"
close_cmd="${CHIEF_WAIT_CLOSE:-$HERE/close-wrapped-worker.sh}"
pred_hangs=0
pred_hang_max="${CHIEF_WAIT_CLOSE_HANGS:-3}"
case "$pred_hang_max" in ''|*[!0-9]*|0) pred_hang_max=3 ;; esac
pred_hang_max=$((10#$pred_hang_max))
predecessor_close() { # prints the WAKE block and returns 0 only for an unexpected refusal
    local pred pdoc errf rc prev_hangs="$pred_hangs"
    pred_hangs=0
    [ -n "$console_doc" ] && [ -f "$console_doc" ] || return 1
    pred="$(sed -n '1s/.* successor to \([^ ]*\.md\).*/\1/p' "$console_doc")"
    [ -n "$pred" ] || return 1
    pdoc="$(dirname "$console_doc")/$pred"
    [ -f "$pdoc" ] || return 1
    [ "$(sed 's/^[a-z]*://' "$pred_file" 2>/dev/null)" = "$pdoc" ] && return 1
    errf="$(mktemp "$pred_file.XXXXXX" 2>/dev/null)" || return 1
    timeout -k 5 "${CHIEF_WAIT_CLOSE_TIMEOUT:-60}" bash "$close_cmd" --chief "$pdoc" </dev/null >/dev/null 2>"$errf" 9>&-; rc=$?  # gnu-ok: Linux-only kit
    case "$rc" in
        0) printf 'closed:%s\n' "$pdoc" > "$pred_file"
           bash "$HERE/append-results.sh" "$console_doc" "LIVE — predecessor console ${pred%.md} was WRAPPED and lock-free; the waiter closed its window" >/dev/null 2>&1 || true ;;
        3|4|6|7) ;;
        124|137) pred_hangs=$((prev_hangs + 1))  # the close hung past its timeout: retry, but only so many times in a row
           if [ "$pred_hangs" -ge "$pred_hang_max" ]; then
               printf 'woke:%s\n' "$pdoc" > "$pred_file"; printf 'WAKE predecessor-open rc=%s\n%s\n' "$rc" "close hung $pred_hangs samples in a row"; rm -f "$errf"; return 0
           fi ;;
        5) if grep -Fq 'refusing - 0 live session' "$errf"; then printf 'gone:%s\n' "$pdoc" > "$pred_file"
           else printf 'woke:%s\n' "$pdoc" > "$pred_file"; printf 'WAKE predecessor-open rc=5\n%s\n' "$(head -n 1 "$errf")"; rm -f "$errf"; return 0; fi ;;
        *) printf 'woke:%s\n' "$pdoc" > "$pred_file"; printf 'WAKE predecessor-open rc=%s\n%s\n' "$rc" "$(head -n 1 "$errf")"; rm -f "$errf"; return 0 ;;
    esac
    rm -f "$errf"
    return 1
}

# r0_relay (the script relay, R0): with --doc and --workers-from, a worker whose tails= is
# WRAPPED or whose acts= is MERGED#<n> is wrapped here instead of waking the console:
# worker-event.sh runs once on a line built from the worker doc's newest bullet of that
# marker (labelled with N<k>, else the doc stem; a WRAPPED is preferred, its residual
# check runs). HANDLED appends `<label> <what> <pr|->` to the digest and sets
# r0_handled; rc 10 with a `-failed rc=3/4/6/7` that is not `step pr-state` (lock held,
# tail not WRAPPED, subtree or subagent alive) stays retryable; anything else
# prints `WAKE worker-event <first line> rc=<n> out=<file>` and returns 0. After one
# call the relay yields to the inbox; the next sample starts after a retryable worker
# so its standing refusal cannot starve later workers. HANDLED and WAKE record
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

# The READY cursor. With the auto_go flag on, every READY bullet a worker
# writes reaches worker-event once, even when a LIVE bullet follows inside the same sample (tails=
# then never shows the READY). $ready_file holds one `<label><TAB><line>` row per worker: the line
# of the last READY bullet already handed on. A worker met for the first time starts after the
# READY bullets it already has, so a waiter never replays history. The flag is read every sample
# (an unregistered flag reads as off). Flag off: nothing here reads or writes a file.
ready_file="$inbox.wait.ready"
ready_re='^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY([^A-Za-z]|$)'
ready_label=""; ready_line=""; ready_bullet=""
auto_go_on() { ( . "$HERE/../../lib/flags.sh" && himmel_flag auto_go ) >/dev/null 2>&1; }
ready_pick() { # sets ready_label/line/bullet to the oldest READY bullet past its worker's cursor
    local label ldoc cur last entry
    ready_label=""
    auto_go_on || return 1
    while IFS=$'\t' read -r label ldoc; do
        [ -n "$label" ] && [ -f "$ldoc" ] || continue
        entry="$(grep -nE "$ready_re" "$ldoc")"
        cur="$(awk -F'\t' -v l="$label" '$1 == l { c = $2 } END { print c }' "$ready_file" 2>/dev/null)"
        # a doc shorter than its cursor was replaced: start over as a worker met for the first time
        if [ -n "$cur" ] && [ "$cur" -gt "$(wc -l < "$ldoc")" ]; then cur=""; fi
        if [ -z "$cur" ]; then
            last="$(printf '%s\n' "$entry" | tail -n 1 | cut -d: -f1)"
            printf '%s\t%s\n' "$label" "${last:-0}" >> "$ready_file"
            continue
        fi
        # one pick per call, but every later worker is still visited so its cursor is set
        [ -z "$ready_label" ] || continue
        entry="$(printf '%s\n' "$entry" | awk -F: -v c="$cur" '$1 + 0 > c { print; exit }')"
        [ -n "$entry" ] || continue
        ready_label="$label"; ready_line="${entry%%:*}"; ready_bullet="${entry#*:}"
    done <<EOF
$(jq -r '.legs[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
    [ -n "$ready_label" ]
}
ready_advance() { # <label> <line>: the cursor moves once the bullet was handed on
    { awk -F'\t' -v l="$1" '$1 != l' "$ready_file" 2>/dev/null; printf '%s\t%s\n' "$1" "$2"; } | atomic_write "$ready_file"
}

r0_relay() { # prints the WAKE block and returns 0 only for a worker-event wake
    local cands label marker ldoc bullet sum line stem out rc outf what pr
    r0_handled=""
    [ -n "$console_doc" ] && [ -n "$legs_from" ] || return 1
    # Prefer WRAPPED once per label, then start after the last retryable worker.
    cands="$( { field tails "$tick_line" | tr ',' '\n' | sed -n 's/^\(.*\):WRAPPED$/\1 WRAPPED/p'
                field acts "$tick_line" | tr ',' '\n' | sed -n 's/^\(.*\):MERGED#[0-9]*$/\1 MERGED/p'; } |
        awk -v last="$r0_retry" '
            !NF || seen[$1]++ { next }
            past { print; next }
            { before = before $0 "\n" }
            $1 == last { past = 1 }
            END { printf "%s", before }
        ' )"
    # a READY past its cursor comes after any WRAPPED or MERGED worker
    if ready_pick; then cands="${cands:+$cands$'\n'}$ready_label READY"; fi
    while read -r label marker; do
        [ -n "$label" ] || continue
        ldoc="$(jq -r --arg l "$label" '.legs[]? | select(.label == $l) | .doc' "$legs_from" 2>/dev/null | head -n 1)"
        [ -n "$ldoc" ] && [ -f "$ldoc" ] || continue
        if [ "$marker" = READY ]; then
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
        heartbeat sampling
        # Allow a slow close and refresh, but stay below heartbeat consumers' 300s
        # floor. Capture the rc: an empty result alone does not prove a timeout.
        out="$(printf '%s\n' "$line" | timeout -k 5 240 bash "$leg_event_cmd" --doc "$console_doc" --fleet "$legs_from" - 2>&1 9>&-)"; rc=$?  # gnu-ok: Linux-only kit
        out="$(printf '%s\n' "$out" | r0_scrub)"
        if [ "$rc" -ne 0 ] && ! [[ $out =~ [^[:space:]] ]]; then
            case "$rc" in
                124|137) out="ESCALATE relay-timeout $label rc=$rc limit=240s" ;;
                *) out="ESCALATE relay-failed $label rc=$rc no-output" ;;
            esac
        fi
        printf '%s\n' "$out" > "$outf" 2>/dev/null
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$sum" >> "$r0_file"
            [ "$marker" != READY ] || ready_advance "$label" "$ready_line"
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
        case "$rc:$out" in
            *"step pr-state"*) ;;
            10:*-failed\ rc=[3467]\ *)
                r0_retry="$label"
                printf '%s\n' "$label" | atomic_write "$inbox.wait.r0-next"
                break ;;
        esac
        printf '%s\n' "$sum" >> "$r0_file"
        [ "$marker" != READY ] || ready_advance "$label" "$ready_line"
        printf 'WAKE worker-event %s rc=%s out=%s\n' "$(printf '%s\n' "$out" | grep -m 1 '[^[:space:]]')" "$rc" "$outf"
        return 0
    done <<EOF
$cands
EOF
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
$(jq -r '.legs[]? | [.label, .doc] | @tsv' "$legs_from")
EOF
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

succ_file="$inbox.wait.succession"
pending=""
r0_fold=""; r0_refold=""
fail_streak=0
fail_wake="${CHIEF_WAIT_FAIL_WAKE:-3}"
next_tick=0
heartbeat sampling
# Announce once per inbox identity, not per waiter process (each wake re-arms).
# The CLI only queues into this inbox's bridge root; it never sends Telegram.
if [ ! -e "$inbox.announced" ] && command -v bun >/dev/null 2>&1; then
    : >> "$inbox"
    timeout -k 2 15 bun "$REPO/scripts/telegram/chief-route.ts" announce "$inbox" 9>&- >/dev/null 2>&1 || true  # gnu-ok: Linux-only kit
fi
while :; do
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
                if [ "$rol_brc" -eq 0 ]; then
                    printf 'WAKE relay-on-live successor=%s\n%s\n' "$rol_succ" "$rol_out"
                else
                    printf 'WAKE relay-on-live successor=%s relay-failed rc=%s\n%s\n' "$rol_succ" "$rol_brc" "$rol_out"
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
    if [ -z "$handover_live" ] && [ "$(date +%s)" -ge "$next_tick" ]; then
        next_tick=$(( $(date +%s) + interval ))
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
        sample "$@" 9>&-
        focus_rebuild
        if [ -n "$key" ]; then
            fail_streak=0
            fail_woke && save_key "${saved:-$key}"
            # the worker-event wake carries the tick line and saves its key, so a re-arm
            # does not wake again on the same tails=/acts= move
            if r0_relay; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-worker-event'; exit 0; fi
            # a denied thread resolve is the chief's job; its acts= move is folded like the worker-event wake's
            if resolve_wake; then printf '%s\n' "$tick_line"; save_key "$key"; exit_reason='wake-resolve'; exit 0; fi
            # a wrap the relay absorbed folds only that worker into the baseline
            if [ -n "$saved" ] && { [ -n "$r0_handled" ] || [ -n "$r0_refold" ]; }; then
                saved="$(r0_fold_key "$saved" "$key" "$r0_fold")"; save_key "$saved"
            fi
            r0_refold=""
            case "$cap_val" in
                UNDERFILLED:*)
                    if [ ! -e "$underfill_file" ]; then
                        pool_probe
                        printf '%s\n' "$pool_sig" > "$underfill_file" 2>/dev/null
                        if underfill_wake; then exit_reason='wake-pool'; exit 0; fi
                    elif underfill_repool; then
                        if underfill_wake; then exit_reason='wake-pool'; exit 0; fi
                    fi ;;
                *)
                    rm -f "$underfill_file"
                    if pool_watch_wake; then exit_reason='wake-pool-unresolved'; exit 0; fi ;;
            esac
            case "$cap_val" in UNDERFILLED:*) rm -f "$inbox.wait.pool" ;; esac
            unowned_val="$(field unowned-prs "$tick_line")"
            case "$unowned_val" in
                '') unowned_none_streak=0 ;;
                '?') unowned_none_streak=0 ;;
                none)
                    unowned_none_streak=$((unowned_none_streak + 1))
                    [ "$unowned_none_streak" -lt 2 ] || rm -f "$unowned_file" ;;
                *)
                    unowned_none_streak=0
                    if unowned_wake "$unowned_val"; then
                        printf 'WAKE unowned-prs %s\n%s\n' "$unowned_val" "$tick_line"
                        exit_reason='wake-unowned-prs'; exit 0
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
            if predecessor_close; then exit_reason='wake-predecessor-open'; exit 0; fi
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
                printf 'WAKE tick-fail samples=%s step=%s\n' "$fail_streak" "$fail_step"
                exit_reason='wake-tick-fail'; exit 0
            fi
        fi
    fi
    if [ -z "$handover_live" ] && housekeeping_flush; then
        exit_reason='wake-housekeeping'; exit 0
    fi
    heartbeat waiting
    sleep "$poll" 9>&-
done
