#!/usr/bin/env bash
# console-wait.sh — The console's one event waiter.
#
#   console-wait.sh <inbox-file> [tick.sh args...]
#
# A console used to arm two `Monitor` loops (the Telegram inbox follower and
# tick.sh). The Monitor tool caps an arm at 30 min, so every expiry woke a
# full-context console turn only to re-arm. This replaces both: the console
# runs it ONCE with Bash `run_in_background` AND `timeout: 7200000` (both
# required: the default background limit is also 30 min and killed a waiter
# once); the harness re-invokes the session when the command
# exits. It stays silent while nothing
# happens and exits, printing one WAKE block, on the first real event:
#
#   WAKE telegram               unread lines in <inbox-file> (the bridge's
#   <line>...                   `/console <name>` appends), via inbox-follow.sh
#                               --once, so its byte cursor is shared and a
#                               re-arm replays nothing.
#   WAKE tick changed=<f,...>   the tick's ACTION KEY changed and the change
#     bank=<verdict>            held for two consecutive samples; bank= is the
#   TICK ...                    bank-preflight verdict word the key carries.
#   WAKE underfilled capacity=UNDERFILLED:<n> the tick's capacity
#   <tick line>                 field says live < cap with no launch for
#   <next-dispatchable.sh out>  TICK_UNDERFILL_MIN; once per streak, with the
#                               ranked dispatchable list (CONSOLE_WAIT_DISPATCH
#                               replaces the command, tests; it never launches).
#   WAKE tracker-stale tracker=<STALE:..>  tracker= stayed STALE past
#                               CONSOLE_WAIT_TRACKER_STALE_MIN (default 30); once
#                               per streak (the class-change wake fires only once).
#   WAKE predecessor-open rc=<n>  with --doc <console doc> whose first line says
#                               `successor to <doc>.md`: the waiter runs
#                               close-wrapped-leg.sh --console on that wrapped,
#                               lock-free predecessor once and logs a Results
#                               bullet; rc 3/4/6/7 retry silently next sample, and so does a
#                               hung close (rc 124/137) until CONSOLE_WAIT_CLOSE_HANGS
#                               (default 3) in a row, then it wakes (the streak shows
#                               in the heartbeat as pred_hangs=<n>); any other
#                               refusal wakes once (CONSOLE_WAIT_CLOSE = seam).
#   WAKE succession complete <k/n>   with --succession <successor> --doc <console doc>
#   <tracker output>            (the successor's waiter): every inherited leg quoted
#                               back; the block carries succession-tracker.sh's table
#                               and the printed append-results.sh line for the LIVE
#                               bullet. Once, and it prints only: nothing is sent.
#   WAKE succession partial <k/n> silent <T> min   the tally stayed short for
#   <tracker output>            --silent-min T minutes (default 20); the table names
#                               the legs still out. Once. CONSOLE_WAIT_SUCCESSION_SEC
#                               (default 15) paces the tally; CONSOLE_WAIT_TRACKER
#                               replaces the tracker (tests).
#   WAKE tick-fail samples=<n>  CONSOLE_WAIT_FAIL_WAKE consecutive samples
#                               failed (tick or bank read): the monitor is
#                               broken. Once per streak; the re-arm stays quiet
#                               until a sample succeeds.
#
# The action key is the tick fields a console acts on: legs=, livestate=,
# prs=, tails=, legset=, board= and tracker= (class only, the STALE
# age is dropped; tracker= is absent from an older tick line, never a failure),
# vault= (class only, wakes ONLY on a move to STALL or PUSH-LAG --
# never on a change of its age or count, nor a move back to ok/skip/unknown --
# and the wake adds a `vault: reproduce with git -C <vault> hook run pre-commit`
# line; absent from an older tick line, never a failure),
# cloud= (class only, wakes ONLY on a move to STALL -- never on a
# change of the ticket list, nor a move back to ok/skip; absent from an older
# tick line, never a failure),
# orphans-wip= (in-work tickets with no leg and no open PR; `n:KEY,...`, `?` or
# `skip`) is in the key whole, so any change of its value wakes; absent from an older
# tick line, never a failure.
# unowned-prs= is NOT in the action key (its minutes grow every tick): a
# non-empty list wakes on first sight (`WAKE unowned-prs <list>`), again at once when
# a PR joins it, and again every CONSOLE_WAIT_UNOWNED_REWAKE_MIN (default 60) while it
# stays non-empty. The marker `<inbox>.wait.unowned` (its body the PR numbers last
# woken for) outlives the waiter like the underfill one; it clears after two
# consecutive samples reading none, so one failed gh read is not an all-clear. A tick
# line without the field is skipped.
# vmrun= (class only, wakes ONLY on a move to DEAD or STUCK -- never
# on the busy count, nor a move back to ok/off; absent from an older tick line,
# never a failure),
# parked= (the legs sitting on an unanswered permission prompt, names only so the
# growing age never re-wakes; absent from the tick line when none is parked, never
# a failure; a leg joining or leaving the set wakes),
# denials= (a new leg, a higher count or a higher class
# (SHIP-STEP > PAUSE-RISK > REPEAT) is exactly the alert this exists to
# surface; the same denial ageing out of tick.sh's 30-min window, moving it to
# none or lowering a count, is NOT a wake, so one denial wakes once) and the
# bank-preflight verdict word.
#
# PAGE: when a wake's denials= change raised a leg's
# class to SHIP-STEP or PAUSE-RISK (a new leg, or a higher class; a count rising
# inside one class wakes but does not page), the waiter sends ONE operator
# Telegram message per rise through the kit's existing bridge path
# (scripts/lib/merge-block-alert.sh: first allowFrom of access.json ->
# console-route.ts reply):
#   DENIAL-PAGE <leg> <class> x<count> - a classifier denial parked this leg. ...
# The text is the leg label, count and class ONLY. It also writes a page record
# (denial-ack-lib.sh) BEFORE the send, which headed-arm-leg.sh reads to refuse
# re-dispatching the leg until `ack-denial.sh <leg>` is run. Both steps fail
# open; the sends of one wake share ONE CONSOLE_WAIT_PAGE_TIMEOUT budget (default
# 45 s, plus a 2 s kill grace), the most hung senders can delay the WAKE block;
# a leg past the budget still gets its page record, just no message. It pages what THIS
# waiter saw rise: a denial that lands while no waiter runs is not paged.
# closable=<n> (tick.sh: finished windows still open past
# TICK_CLOSABLE_MIN minutes) wakes when it appears or changes; absent means none.
# Everything else on the tick line (heartbeat, procs, fill, fleet, gql,
# orphans...) moves without needing a console act and never wakes. Two consecutive samples must differ from the saved key (not
# necessarily from each other), so one failed `gh` read (prs=none for a single
# tick) is not an event. The first sample with no saved
# key, or with a saved key taken under different tick args (a re-arm after a
# dispatch or wrap) -- or, with --legs-from, under a different manifest leg
# set -- is a silent baseline. A tick.sh that exits non-zero or
# prints no TICK line, or a bank read that fails or is not a verdict token, is
# a failed sample: never a change, and only a streak of them wakes.
#
# board= (and tracker=, the same way) is asymmetric: a class move TO ok is never itself a wake (the
# console just rendered its own board — nothing for it to act on), only a
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
#                      CONSOLE_WAIT_CLOSE_TIMEOUT once, then twice
#                      CONSOLE_WAIT_TICK_TIMEOUT (+5 s kill grace each), and a
#                      Telegram line waits for it. A heartbeat older than that
#                      plus a few polls, still
#                      waiting or sampling, is a waiter that died without
#                      trapping (SIGKILL).
#   <inbox>.wait.state   the saved action key (line 1: tick-args hash, line 2: key;
#                        line 3 `failwoke` once a failure streak has woken).
#                        Written atomically: temp file in the same dir, then
#                        `mv`, so a kill mid-write never leaves it torn.
#   <inbox>.wait.lock    the one-waiter flock (the file stays; the lock does not).
#   <inbox>.handover     handover mode: while it is fresh (younger
#                        than CONSOLE_WAIT_HANDOVER_MIN, default 60) the waiter
#                        skips tick/bank/page sampling and wakes only on Telegram.
#                        That mutes classifier-denial pages for up to that long;
#                        `rm <inbox>.handover` ends the mode early.
#   <inbox>.relay-on-live  (`console.sh next --relay-on-live`; needs --doc) line 1 the
#                        successor session, line 2 its doc. When that doc's queue lock
#                        is held fresh the waiter prints one `WAKE relay-on-live
#                        successor=<s>` block (relay-batch.sh's output), removes the
#                        marker and exits 0. It works in handover mode. Seams:
#                        CONSOLE_WAIT_LOCK_STATUS, CONSOLE_WAIT_RELAY (tests).
#
# Exit: 0 = a WAKE block was printed; 1 = the inbox could not be drained;
# 2 = usage; 3 = another waiter is already live on this inbox (its pid is named).
#
# Env: CONSOLE_WAIT_INTERVAL tick interval in seconds (default 180);
# CONSOLE_WAIT_POLL_SEC inbox poll (default 1); CONSOLE_WAIT_TICK_TIMEOUT
# seconds a tick may run before it counts as failed (default 120), so a hung
# tick cannot freeze the Telegram path; CONSOLE_WAIT_FAIL_WAKE consecutive
# failed samples before a tick-fail wake (default 3); CONSOLE_WAIT_TICK / CONSOLE_WAIT_BANK
# replace tick.sh / the bank verdict command (tests); CONSOLE_WAIT_PAGE_CMD
# replaces the Telegram sender (called as `$CMD <text>`, tests) and
# CONSOLE_WAIT_PAGE_TIMEOUT bounds it (seconds, default 45); HIMMEL_DENIAL_ACK_DIR
# relocates the page/ack records (default ~/.himmel/state/denial-acks).
#
# Leg messages (SendMessage) wake a console on their own; only the Telegram
# and tick paths depend on this waiter.
#
# ponytail: an external SIGKILL of the waiter re-invokes the session (task
# notification, measured HIMMEL-3509); the harness-internal "low memory" kill
# of a background task is unreproduced, so a waiter lost that way
# is visible only as a stale heartbeat, upgrade: HIMMEL-3510 (bridge-side
# stale-heartbeat alert).
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
# bash 3.2-safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ "$#" -lt 1 ] || [ -z "$1" ] || [ "${1#-}" != "$1" ]; then
    echo "usage: console-wait.sh <inbox-file> [tick.sh args...]" >&2
    exit 2
fi
inbox="$1"; shift
# page/ack record helpers. A missing lib fails open: no records, the
# page still sends.
if [ -r "$HERE/denial-ack-lib.sh" ]; then . "$HERE/denial-ack-lib.sh"; else denial_page_write() { return 1; }; fi
hb_file="$inbox.wait"
key_file="$inbox.wait.state"
interval="${CONSOLE_WAIT_INTERVAL:-180}"
poll="${CONSOLE_WAIT_POLL_SEC:-1}"
tick_timeout="${CONSOLE_WAIT_TICK_TIMEOUT:-120}"
tick_cmd="${CONSOLE_WAIT_TICK:-$HERE/tick.sh}"

# One waiter per inbox: a second would double every wake. flock is atomic and
# the lock dies with the waiter; every child runs with fd 9 closed, so a killed
# waiter's tick or sleep cannot go on holding it. The inbox's directory may not
# exist yet on a first start; inbox-follow.sh creates the inbox itself.
if ! mkdir -p "$(dirname "$inbox")" || ! exec 9>>"$inbox.wait.lock"; then
    echo "console-wait: cannot open $inbox.wait.lock" >&2
    exit 1
fi
if ! flock -n 9; then  # gnu-ok: Linux-only kit (util-linux flock, PLATFORM GUARD)
    # swallow-ok: the pid only decorates the refusal message below; exit 3 does not depend on it
    other="$(sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' "$hb_file" 2>/dev/null | head -n 1)"
    echo "console-wait: a waiter is already live on $inbox (pid ${other:-?}) — not starting a second" >&2
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
trap 'heartbeat exited "$exit_reason"' EXIT
trap "exit_reason='signal-TERM'; exit 143" TERM
trap "exit_reason='signal-INT'; exit 130" INT
trap "exit_reason='signal-HUP'; exit 129" HUP

# with --legs-from (or LEGS_FROM) the argv never changes when the
# console dispatches or wraps, so the manifest's leg list is folded into the
# args hash, re-read before every sample: a leg-set change made through the
# manifest is a silent baseline, the same as a re-arm with a new --legs. An
# unreadable manifest hashes as empty (its tick fails that sample anyway).
legs_from="${LEGS_FROM:-}"
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
    [ "$prev_arg" = --legs-from ] && legs_from="$a"
    [ "$prev_arg" = --doc ] && console_doc="$a"
    prev_arg="$a"
    rest_args+=("$a")
done
set -- ${rest_args[@]+"${rest_args[@]}"}
case "$prev_arg" in --succession|--silent-min) echo "console-wait: $prev_arg needs a value" >&2; exit 2 ;; esac
case "$succession" in -*) echo "console-wait: --succession needs a session name, got a flag" >&2; exit 2 ;; esac
if [ -n "$succession" ]; then
    case "$succession" in *[!A-Za-z0-9_.-]*) echo "console-wait: --succession must be a session name" >&2; exit 2 ;; esac
    case "$silent_min" in ''|*[!0-9]*) echo "console-wait: --silent-min must be whole minutes" >&2; exit 2 ;; esac
    if [ -z "$console_doc" ] || [ ! -f "$console_doc" ]; then
        echo "console-wait: --succession needs --doc <console doc>" >&2; exit 2
    fi
fi
args_hash_of() { # <tick args...>
    local set=""
    # In manifest order, not sorted: tick prints legs in that order, so a
    # reorder (remove + re-add) moves legs= and must re-baseline too.
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
    if [ -n "${CONSOLE_WAIT_BANK:-}" ]; then
        out="$(bash "$CONSOLE_WAIT_BANK" 2>/dev/null)" || return 1
    else
        # gnu-ok: Linux-only kit (timeout). Same side-effect-free spelling tick.sh uses for its fleet census.
        out="$(CADENCE_BANK_LAUNCH='' CADENCE_BANK_LEDGER=/dev/null timeout -k 5 "$tick_timeout" \
            bash "$REPO/scripts/lib/bank-preflight.sh" 2>/dev/null)" || return 1
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

# sample: sets tick_line and key (empty on a failed tick).
sample() {
    local f v raw bank
    key=""; cap_val=""
    # A tick that exits non-zero failed, whatever it printed first.
    raw="$(timeout -k 5 "$tick_timeout" bash "$tick_cmd" "$@" 2>/dev/null)" || { tick_state=fail; return; }  # gnu-ok: Linux-only kit
    tick_line="$(printf '%s\n' "$raw" | grep '^TICK ' | head -n 1)"
    if [ -z "$tick_line" ]; then tick_state=fail; return; fi
    # A failed or garbled bank read is a failed sample, not a verdict.
    bank="$(bank_word)" || { tick_state=fail; return; }
    tick_state=ok
    cap_val="$(field capacity "$tick_line")"
    for f in legs livestate prs tails legset board tracker vault cloud orphans-wip vmrun parked denials closable; do
        v="$(field "$f" "$tick_line")"
        # tracker= is newer than the other fields; a tick line
        # without it (an older kit) just has no tracker key, not a failed sample.
        # vault= is newer still, the same way.
        if { [ "$f" = tracker ] || [ "$f" = vault ] || [ "$f" = cloud ] || [ "$f" = orphans-wip ] || [ "$f" = vmrun ] || [ "$f" = parked ] || [ "$f" = closable ]; } && [ -z "$v" ]; then continue; fi
        # A field missing from a malformed/partial tick line is a failed
        # sample, never a key with an empty value baked in.
        if [ -z "$v" ]; then tick_state=fail; key=""; return; fi
        case "$f" in board|tracker|vault|cloud|vmrun) v="${v%%:*}" ;; esac
        # vmrun= keeps its class only (off|ok|DEAD|STUCK), not the counts.
        [ "$f" = vmrun ] && v="${v%%,*}"
        # parked= keeps the leg names only: the age grows every tick and must not re-wake.
        # The names are sorted: the doc order must not decide the key.
        [ "$f" = parked ] && v="$(printf '%s' "$v" | sed -E 's/:[0-9]+m(,|$)/\1/g' | tr ',' '\n' | LC_ALL=C sort | paste -sd, -)"
        key="$key$f=$v|"
    done
    key="${key}bank=$bank"
}

changed_fields() { # <old key> <new key>
    printf '%s\n' "$1" | tr '|' '\n' > "$hb_file.old"
    {
        printf '%s\n' "$2" | tr '|' '\n' | while IFS= read -r kv; do
            grep -qxF -- "$kv" "$hb_file.old" || printf '%s\n' "${kv%%=*}"
        done
        # parked= is absent when no leg is parked, so a set that empties is a
        # field missing from the new key, not one that differs.
        if grep -q '^parked=' "$hb_file.old" && ! printf '%s\n' "$2" | tr '|' '\n' | grep -q '^parked='; then
            printf 'parked\n'
        fi
    } | paste -sd, -
    rm -f "$hb_file.old"
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
        # vmrun= wakes only on a class move TO DEAD / STUCK.
        if [ "$f" = vmrun ]; then
            case "$vmrun_new" in DEAD|STUCK) ;; *) continue ;; esac
        fi
        printf '%s\n' "$f"
    done | paste -sd, -
}

# denials_rose: <old key> <new key> — succeeds only when the denials= value got
# WORSE: a leg the old value lacked, a higher count, or a higher class
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

# denial_pages: <old key> <new key> — one `<leg> <class> <count>` line per leg
# whose denials= class ROSE to SHIP-STEP or PAUSE-RISK between the two keys (a
# new leg, or a higher class). A count rising inside one class is a wake but not
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
# console-route.ts reply). CONSOLE_WAIT_PAGE_CMD replaces it (tests; called as
# `$CMD <text>`). Bounded by CONSOLE_WAIT_PAGE_TIMEOUT (default 45 s) and always
# rc 0: a failed or hung send never breaks the waiter or delays the wake past
# the bound.
page_timeout="${CONSOLE_WAIT_PAGE_TIMEOUT:-45}"
page_send() {  # <text> <deadline epoch>: the timeout is what is left of the batch budget
    local left=$(( $2 - $(date +%s) ))
    [ "$left" -ge 1 ] || return 0
    if [ -n "${CONSOLE_WAIT_PAGE_CMD:-}" ]; then
        timeout -k 2 "$left" "$CONSOLE_WAIT_PAGE_CMD" "$1" </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    else
        # shellcheck disable=SC2016  # $1/$2 expand in the child bash, not here
        timeout -k 2 "$left" bash -c '. "$1" && chat="$(_mba_operator_chat)" && [ -n "$chat" ] && _mba_send "$chat" "$2"' \
            _ "$REPO/scripts/lib/merge-block-alert.sh" "$1" </dev/null >/dev/null 2>&1 9>&-  # gnu-ok: Linux-only kit
    fi
    return 0
}

# page_denials: <old key> <new key> — page each denial_pages leg. The page
# record is written FIRST, so the re-dispatch refusal holds even when the send
# fails; both steps fail open. The page text is the leg label, count and class
# only: this file never reads the denial log, only tick.sh's denials= field.
page_denials() {
    local leg cls n end
    end=$(( $(date +%s) + page_timeout ))  # one budget for the whole batch, not one per leg
    denial_pages "$1" "$2" | while read -r leg cls n; do
        denial_page_write "$leg" "$n" "$cls" || true
        page_send "DENIAL-PAGE $leg $cls x$n - a classifier denial parked this leg. Review it, then: ack-denial.sh $leg" "$end"
    done
}

# capacity=UNDERFILLED:<n> (tick.sh already folds TICK_UNDERFILL_MIN
# into it) wakes once per streak. The marker file outlives the waiter, so a
# re-arm inside the same streak stays quiet; capacity=ok removes it.
underfill_file="$inbox.wait.underfill"
unowned_file="$inbox.wait.unowned"
unowned_none_streak=0
dispatch_cmd="${CONSOLE_WAIT_DISPATCH:-$HERE/next-dispatchable.sh}"
underfill_wake() { # prints the WAKE block; fail-open on the dispatchable list
    printf 'WAKE underfilled capacity=%s\n%s\n' "$cap_val" "$tick_line"
    [ -r "$dispatch_cmd" ] || return 0
    local lf=()
    [ -z "$legs_from" ] || lf=(--legs-from "$legs_from")  # live legs' files must reach the collision check
    timeout -k 2 "${CONSOLE_WAIT_DISPATCH_TIMEOUT:-420}" bash "$dispatch_cmd" ${lf[@]+"${lf[@]}"} </dev/null 2>/dev/null 9>&- || true  # gnu-ok: Linux-only kit
}

# unowned_wake: <unowned-prs value> — succeeds (and refreshes the marker) when the list is
# new to the marker, holds a PR the marker lacks, or the marker is older than the re-wake
# window.
unowned_wake() {
    local nums num wake=""
    nums="$(printf '%s\n' "$1" | tr ',' '\n' | sed 's/:.*//')"
    if [ ! -e "$unowned_file" ]; then
        wake=1
    elif [ -z "$(find "$unowned_file" -mmin "-${CONSOLE_WAIT_UNOWNED_REWAKE_MIN:-60}" 2>/dev/null)" ]; then
        wake=1
    else
        for num in $nums; do
            grep -qxF -- "$num" "$unowned_file" 2>/dev/null || { wake=1; break; }
        done
    fi
    if [ -z "$wake" ]; then
        # Shrink the marker to the current set, keeping its mtime (the re-wake clock), so a PR
        # that leaves and rejoins is new to the marker and wakes at once.
        touch -r "$unowned_file" "$unowned_file.ref" 2>/dev/null &&
            printf '%s\n' "$nums" > "$unowned_file" 2>/dev/null &&
            touch -r "$unowned_file.ref" "$unowned_file" 2>/dev/null
        rm -f "$unowned_file.ref"
        return 1
    fi
    printf '%s\n' "$nums" > "$unowned_file" 2>/dev/null
    return 0
}

# tracker_stale_wake: <tracker= value> — a tracker that STAYS stale. A class change
# wakes once (above); after the first STALE the class never moves again, so the
# marker holds the epoch the streak was first seen and the wake fires once the
# streak passes CONSOLE_WAIT_TRACKER_STALE_MIN (default 30). Any other value ends
# the streak. The marker outlives the waiter, so a re-arm inside a streak stays quiet.
tracker_stale_file="$inbox.wait.trackerstale"
tracker_stale_wake() {
    local since
    case "$1" in
        STALE*) ;;
        '') return 1 ;;
        *) rm -f "$tracker_stale_file"; return 1 ;;
    esac
    if [ ! -e "$tracker_stale_file" ]; then date +%s > "$tracker_stale_file" 2>/dev/null; return 1; fi
    [ "$(sed -n 2p "$tracker_stale_file" 2>/dev/null)" = woke ] && return 1
    since="$(sed -n 1p "$tracker_stale_file" 2>/dev/null)"
    case "$since" in ''|*[!0-9]*) return 1 ;; esac
    stale_min="${CONSOLE_WAIT_TRACKER_STALE_MIN:-30}"
    case "$stale_min" in ''|*[!0-9]*) stale_min=30 ;; esac
    [ $(( $(date +%s) - since )) -ge $(( 10#$stale_min * 60 )) ] || return 1
    printf '%s\nwoke\n' "$since" > "$tracker_stale_file" 2>/dev/null
    return 0
}

# predecessor_close: the console doc's first line names its predecessor
# (`successor to <doc>.md`). Once that doc is WRAPPED and lock-free with exactly one
# live session, close-wrapped-leg.sh --console closes it, once, and a Results bullet
# says so. close-wrapped-leg.sh owns every check; this only reads its exit code:
# 0 closed; 3/4 the predecessor is not done (lock held / tail not WRAPPED) and 6/7 its
# subtree or a subagent is still alive: left alone, asked again next sample; 5 with
# "0 live session" means the window is already gone; any other refusal sets the
# marker and prints the wake (rc 0). The marker `<inbox>.wait.predecessor` (body:
# `<state>:<doc>`) outlives the waiter, so a done predecessor is never asked twice.
pred_file="$inbox.wait.predecessor"
close_cmd="${CONSOLE_WAIT_CLOSE:-$HERE/close-wrapped-leg.sh}"
pred_hangs=0
pred_hang_max="${CONSOLE_WAIT_CLOSE_HANGS:-3}"
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
    [ "$(cat "$pred_file" 2>/dev/null | sed 's/^[a-z]*://')" = "$pdoc" ] && return 1
    errf="$(mktemp "$pred_file.XXXXXX" 2>/dev/null)" || return 1
    timeout -k 5 "${CONSOLE_WAIT_CLOSE_TIMEOUT:-60}" bash "$close_cmd" --console "$pdoc" </dev/null >/dev/null 2>"$errf" 9>&-; rc=$?  # gnu-ok: Linux-only kit
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

saved=""
if [ -f "$key_file" ] && [ "$(sed -n 1p "$key_file")" = "$args_hash" ]; then
    saved="$(sed -n 2p "$key_file")"
fi
save_key() {
    tmp="$(mktemp "$key_file.XXXXXX" 2>/dev/null)" || return 0
    if printf '%s\n%s\n' "$args_hash" "$1" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$key_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
# Line 3 `failwoke` = this failure streak already woke the console once.
fail_woke() {
    [ "$(sed -n 1p "$key_file" 2>/dev/null)" = "$args_hash" ] && [ "$(sed -n 3p "$key_file" 2>/dev/null)" = failwoke ]
}

succ_file="$inbox.wait.succession"
pending=""
fail_streak=0
fail_wake="${CONSOLE_WAIT_FAIL_WAKE:-3}"
next_tick=0
heartbeat sampling
# Announce once per inbox identity, not per waiter process (each wake re-arms).
# The CLI only queues into this inbox's bridge root; it never sends Telegram.
if [ ! -e "$inbox.announced" ] && command -v bun >/dev/null 2>&1; then
    : >> "$inbox"
    timeout -k 2 15 bun "$REPO/scripts/telegram/console-route.ts" announce "$inbox" 9>&- >/dev/null 2>&1 || true  # gnu-ok: Linux-only kit
fi
while :; do
    # Telegram first: it is the cheap check and the operator's line. Peek, print
    # the header, then let --once stream the lines: each line is on stdout
    # before its cursor moves, so a kill mid-wake replays, never drops.
    bash "$HERE/inbox-follow.sh" --peek "$inbox" 9>&-; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'WAKE telegram\n'
        bash "$HERE/inbox-follow.sh" --once "$inbox" 9>&- || { exit_reason='inbox-error'; exit 1; }
        exit_reason='wake-telegram'; exit 0
    elif [ "$rc" -ne 1 ]; then
        exit_reason='inbox-error'; exit 1
    fi
    # --succession: the successor's one wake. Tally the inherited legs' quote-backs
    # (succession-tracker.sh); wake once when all are in, or once when the tally has
    # sat short for --silent-min minutes, naming the legs still out.
    # A COMPLETE wake leaves $succ_file.woke naming the successor, so a re-arm with the same
    # --succession (the console forgot to drop it) does not wake again at once.
    # swallow-ok: a missing .woke marker reads empty, so the wake is simply not suppressed
    if [ -n "$succession" ] && [ "$(sed -n 1p "$succ_file.woke" 2>/dev/null)" != "$succession" ] && [ "$(date +%s)" -ge "${next_succ:-0}" ]; then
        next_succ=$(( $(date +%s) + ${CONSOLE_WAIT_SUCCESSION_SEC:-15} ))
        [ -s "$succ_file" ] || date +%s > "$succ_file" 2>/dev/null
        succ_out="$(timeout -k 2 30 bash "${CONSOLE_WAIT_TRACKER:-$HERE/succession-tracker.sh}" "$console_doc" --successor "$succession" </dev/null 2>/dev/null 9>&-)"  # gnu-ok: Linux-only kit; swallow-ok: a tracker failure prints no summary and takes the INCOMPLETE branch below
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
    # <inbox>.relay-on-live (written by `console.sh next --relay-on-live`; line 1 the
    # successor session, line 2 its doc): once the successor's queue lock is held
    # fresh it is live, so wake this console ONCE with relay-batch.sh's lines. The
    # waiter sends no SendMessage (relay-batch writes a claudex leg's inbox itself, as it
    # does when the console runs it); the console sends each SENDMESSAGE line.
    if [ -n "$console_doc" ] && [ -s "$inbox.relay-on-live" ] && [ "$(date +%s)" -ge "${next_rol:-0}" ]; then
        next_rol=$(( $(date +%s) + ${CONSOLE_WAIT_SUCCESSION_SEC:-15} ))
        rol_succ="$(sed -n 1p "$inbox.relay-on-live" 2>/dev/null)"  # swallow-ok: an empty value skips the relay below
        rol_doc="$(sed -n 2p "$inbox.relay-on-live" 2>/dev/null)"  # swallow-ok: an empty value skips the relay below
        if [ -n "$rol_succ" ] && [ -n "$rol_doc" ]; then
            bash "${CONSOLE_WAIT_LOCK_STATUS:-$HERE/../queue-lock.sh}" status "$rol_doc" </dev/null >/dev/null 2>&1 9>&-; rol_rc=$?
            if [ "$rol_rc" -eq 11 ]; then
                # relay-batch may deliver a claudex leg by inbox-send (never re-run it: a retry
                # would resend), so a failure still wakes, carrying its rc and output for the console.
                rol_out="$(timeout -k 2 60 bash "${CONSOLE_WAIT_RELAY:-$HERE/relay-batch.sh}" "$console_doc" --successor "$rol_succ" </dev/null 2>&1 9>&-)"; rol_brc=$?  # gnu-ok: Linux-only kit
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
    # <inbox>.handover (written by `console.sh next` once the
    # successor validated) puts this waiter in handover mode: no tick, bank or
    # page work (an outgoing console only waits for LIVE; a tick wake costs it
    # a full-context turn), while the Telegram check above still wakes it.
    # The marker only counts while fresh (CONSOLE_WAIT_HANDOVER_MIN, default 60):
    # a launch that failed or never ran must not leave this console unmonitored.
    handover_live=""
    [ -e "$inbox.handover" ] && handover_live="$(find "$inbox.handover" -mmin "-${CONSOLE_WAIT_HANDOVER_MIN:-60}" 2>/dev/null)"
    if [ -z "$handover_live" ] && [ "$(date +%s)" -ge "$next_tick" ]; then
        next_tick=$(( $(date +%s) + interval ))
        # The Telegram path is blocked while a tick runs (up to twice
        # CONSOLE_WAIT_TICK_TIMEOUT with the bank read); say so in the heartbeat.
        heartbeat sampling
        if [ -n "$legs_from" ]; then
            new_hash="$(args_hash_of "$@" 9>&-)"
            if [ "$new_hash" != "$args_hash" ]; then
                args_hash="$new_hash"; saved=""; pending=""
            fi
        fi
        sample "$@" 9>&-
        if [ -n "$key" ]; then
            fail_streak=0
            fail_woke && save_key "${saved:-$key}"
            case "$cap_val" in
                UNDERFILLED:*)
                    if [ ! -e "$underfill_file" ]; then
                        : > "$underfill_file" 2>/dev/null
                        underfill_wake
                        exit_reason='wake-underfilled'; exit 0
                    fi ;;
                ok) rm -f "$underfill_file" ;;
            esac
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
            if tracker_stale_wake "$(field tracker "$tick_line")"; then
                printf 'WAKE tracker-stale tracker=%s\n%s\n' "$(field tracker "$tick_line")" "$tick_line"
                exit_reason='wake-tracker-stale'; exit 0
            fi
            if predecessor_close; then exit_reason='wake-predecessor-open'; exit 0; fi
            cur_hash="$(printf '%s' "$key" | sha256sum | cut -c1-16)"  # gnu-ok: Linux-only kit
            if [ -z "$saved" ]; then
                saved="$key"; save_key "$key"
            elif [ "$key" = "$saved" ]; then
                pending=""
            elif [ -n "$pending" ]; then
                # Two consecutive samples off the saved key, equal or not: a
                # key that moves on every sample (a busy repo's PR set) is
                # still a change, not a blip. A board class move TO ok is
                # never itself a wake (only a move to STALE/MISSING is), so
                # it never appears in changed=; the key still saves.
                real_changed="$(drop_board_ok "$(changed_fields "$saved" "$key")" "$key")"
                real_changed="$(drop_denials_expiry "$real_changed" "$saved" "$key")"
                if [ -z "$real_changed" ]; then
                    saved="$key"; save_key "$key"; pending=""
                else
                    page_denials "$saved" "$key"
                    printf 'WAKE tick changed=%s bank=%s\n%s\n' "$real_changed" "${key##*|bank=}" "$tick_line"
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
            # A monitor that stays broken is an event too, but only once per
            # streak: the re-arm stays quiet until a sample succeeds.
            if [ "$fail_streak" -ge "$fail_wake" ] && ! fail_woke; then
                if tmp="$(mktemp "$key_file.XXXXXX" 2>/dev/null)"; then
                    if printf '%s\n%s\nfailwoke\n' "$args_hash" "$saved" > "$tmp" 2>/dev/null; then
                        mv -f "$tmp" "$key_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
                    else
                        rm -f "$tmp" 2>/dev/null
                    fi
                fi
                printf 'WAKE tick-fail samples=%s\n' "$fail_streak"
                exit_reason='wake-tick-fail'; exit 0
            fi
        fi
    fi
    heartbeat waiting
    sleep "$poll" 9>&-
done
