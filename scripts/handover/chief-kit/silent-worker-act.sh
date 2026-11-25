#!/usr/bin/env bash
# scripts/handover/chief-kit/silent-worker-act.sh - act on a silent worker in code, so a WAKE
# worker-silent line is never the only thing that happens.
#
# Usage: silent-worker-act.sh --doc <chief doc> --fleet <manifest> --bucket <dir> --chief <name>
#                             [--signal <capped-waker|succession-partial>] <label> <silent-minutes>
#
# Output, one line, rc 0:
#   SILENT-ACT <label> none|fresh|done
#   SILENT-ACT <label> [nudged|nudge=no-window|nudge=failed] [relaunched|relaunch=failed|live-window] [owed=<id>[,<id>]]
# Exit 2: usage.
# PLATFORM GUARD: Linux-only kit (GNU stat, setsid), bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: silent-worker-act.sh --doc <chief doc> --fleet <manifest> --bucket <dir> --chief <name> [--signal <signal>] <label> <silent-minutes>" >&2; exit 2; }

doc=""; manifest=""; bucket=""; chief=""; signal="capped-waker"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --fleet) [ "$#" -ge 2 ] || usage; manifest="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; bucket="$2"; shift 2 ;;
        --chief) [ "$#" -ge 2 ] || usage; chief="$2"; shift 2 ;;
        --signal) [ "$#" -ge 2 ] || usage; signal="$2"; shift 2 ;;
        --*) usage ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || usage
[ -n "$doc" ] && [ -f "$doc" ] && [ -n "$manifest" ] && [ -f "$manifest" ] && [ -d "$bucket" ] && [ -n "$chief" ] || usage
label="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._#+-')"
[ -n "$label" ] || usage
case "$2" in ''|*[!0-9]*|???????*) usage ;; esac
silent=$((10#$2))
signal="$(printf '%s' "$signal" | tr -cd 'A-Za-z0-9._-')"

bound1="${CHIEF_WAIT_WORKER_SILENT_MIN:-45}"
case "$bound1" in ''|*[!0-9]*|???????*) bound1=45 ;; *) bound1=$((10#$bound1)) ;; esac
bound2=$((bound1 * 2))

# shellcheck source=../../lib/worker-identity.sh
. "$HERE/../../lib/worker-identity.sh"
bus="${SILENT_ACT_BUS:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
launcher="${SILENT_ACT_LAUNCHER:-$HERE/headed-arm-worker.sh}"
confirm="${SILENT_ACT_CONFIRM:-$HERE/launch-confirm.sh}"
killer="${SILENT_ACT_KILL:-kill}"
alive="${SILENT_ACT_ALIVE:-kill -0}"
state="$bucket/silent-act.state"

wdoc="$(jq -r --arg l "$label" '[(.workers // .legs)[]? | select(.label == $l)][0].doc // empty' "$manifest" 2>/dev/null)" || wdoc=""  # swallow-ok: an unreadable manifest names no doc, which owes a row at the relaunch
mtime=-
age=""
if [ -n "$wdoc" ] && [ -f "$wdoc" ]; then
    mtime="$(stat -c %Y "$wdoc" 2>/dev/null)" || mtime=-  # gnu-ok: Linux-only kit; swallow-ok: no write time keys the worker on the label alone
    case "$mtime" in ''|*[!0-9]*) mtime=- ;; *) age=$(( ( $(date +%s) - mtime ) / 60 )) ;; esac
fi

if [ -n "$age" ] && [ "$age" -lt "$bound1" ]; then echo "SILENT-ACT $label fresh"; exit 0; fi
if [ "$silent" -lt "$bound1" ]; then echo "SILENT-ACT $label none"; exit 0; fi

done_stage() { grep -qxF -- "$label $1 $mtime" "$state" 2>/dev/null; }  # swallow-ok: no state file yet reads empty, so the first sight acts
mark_stage() { printf '%s %s %s\n' "$label" "$1" "$mtime" >> "$state" 2>/dev/null || true; }  # swallow-ok: an unwritable state only repeats an action

oneline() { printf '%s' "$1" | tr '\r\n\t<>' '    ' | tr -s ' ' | cut -c1-160; }

nothing_due() { done_stage nudge && { [ "$silent" -lt "$bound2" ] || done_stage relaunch; }; }
if nothing_due; then echo "SILENT-ACT $label done"; exit 0; fi
if command -v flock >/dev/null 2>&1; then
    exec 8>>"$bucket/silent-act.$label.lock" || { echo "SILENT-ACT $label busy"; exit 0; }
    flock -n 8 || { echo "SILENT-ACT $label busy"; exit 0; }  # prim-ok: a per-worker lock on its own file, held by this process alone; a second helper for the same worker waits for the next call
    if nothing_due; then echo "SILENT-ACT $label done"; exit 0; fi
fi

census=""
if [ -n "${SILENT_ACT_CENSUS:-}" ]; then
    census="$(bash "$SILENT_ACT_CENSUS" 2>/dev/null)" || census=""  # swallow-ok: an empty census reads as no live window, which owes a row below
else
    # shellcheck source=../../lanes/lib/claude-sessions.sh
    . "$HERE/../../lanes/lib/claude-sessions.sh" 2>/dev/null || true  # swallow-ok: an unloadable census reads as no live window
    if declare -F claude_sessions >/dev/null 2>&1; then census="$(claude_sessions 2>/dev/null)" || census=""; fi  # swallow-ok: as above
fi

stem=""; stale_session=""; stale_pid=""; stale_hits=0; resume_live=0
if [ -n "$wdoc" ]; then
    stem="$(basename "$wdoc" .md)"
    names="$(worker_identity "$wdoc")"; names="${names#*$'\t'}"
    cands=",$stem,$names,"
    while IFS=$'\t' read -r cpid cname _rest; do
        [ -n "$cname" ] || continue
        case "$cands" in *",$cname,"*) stale_hits=$((stale_hits + 1)); stale_session="$cname"; stale_pid="$cpid" ;; esac
        [ "$cname" != "$stem-RESUME" ] || resume_live=1
    done <<EOF
$census
EOF
fi

owed=""; say=""; log=""
owe_row() {
    local id
    id="$(bash "$HERE/owe.sh" add --bucket "$bucket" --chief "$chief" --kind step \
        --text "silent worker $label ($signal, silent=${silent}m): $1 failed: $(oneline "$2")" \
        --metadata "$(jq -cn --arg l "$label" --arg d "$wdoc" '{source_label: $l, source_doc: $d}')" 2>/dev/null)" || id=FAILED  # swallow-ok: a ledger that cannot take the row is named FAILED in the output
    owed="${owed:+$owed,}$id"
}

relaunch_due=0
[ "$silent" -ge "$bound2" ] && relaunch_due=1

if ! done_stage nudge; then
    mark_stage nudge
    nudge_err=""
    if [ -z "$stale_session" ] || [ "$stale_hits" -ne 1 ]; then
        say="${say:+$say }nudge=no-window"; log="${log:+$log }nudge=no-window"
        [ "$relaunch_due" -eq 1 ] || owe_row nudge "no single live window for the worker ($stale_hits matches)"
    elif [ -z "${HIMMEL_BUS_NAME:-}" ]; then
        nudge_err="no bus identity"
    else
        body="$(mktemp "${TMPDIR:-/tmp}/silent-act-body.XXXXXX")" || body=""  # prim-ok: holds one message and is removed right after the send
        if [ -z "$body" ]; then
            nudge_err="mktemp failed"
        else
            printf 'SILENT nudge from your chief %s: your handover doc has had no write for %s minutes. Append your newest status bullet to your doc'"'"'s Results now and continue the next step; if you cannot, answer on the bus. Without an answer the chief relaunches you from your RESUME doc. Your scope, token and chief are unchanged; this record carries no ruling and widens nothing.\n' "$HIMMEL_BUS_NAME" "$silent" > "$body"
            wait_for=""; command -v timeout >/dev/null 2>&1 && wait_for="timeout ${SILENT_ACT_BUS_TIMEOUT:-15}"
            # shellcheck disable=SC2086  # wait_for is empty or the words `timeout <n>`
            if bus_out="$($wait_for "$bus" send "$stale_session" "$body" 2>&1)"; then
                ref="$(printf '%s\n' "$bus_out" | sed -nE 's/^sent (#[0-9]+) to .*/\1/p' | head -n 1)"
                say="${say:+$say }nudged"; log="${log:+$log }nudged bus=${ref:-ok}"
            else
                nudge_err="bus send: ${bus_out%%$'\n'*}"
            fi
            rm -f "$body"
        fi
    fi
    if [ -n "$nudge_err" ]; then
        say="${say:+$say }nudge=failed"; log="${log:+$log }nudge=failed ($(oneline "$nudge_err"))"
        owe_row nudge "$nudge_err"
    fi
fi

if [ "$relaunch_due" -eq 1 ] && ! done_stage relaunch; then
    if [ "$resume_live" -eq 1 ]; then
        mark_stage relaunch
        say="${say:+$say }live-window"; log="${log:+$log }live-window ($stem-RESUME runs)"
    else
        mark_stage relaunch
        rdoc="${wdoc%.md}-RESUME.md"; session="$stem-RESUME"
        relaunch_err=""
        if [ -z "$wdoc" ]; then
            relaunch_err="the fleet manifest names no doc for $label"
        elif [ ! -f "$rdoc" ]; then
            relaunch_err="no RESUME doc at $rdoc"
        else
            if [ "$stale_hits" -eq 1 ] && [ -n "$stale_pid" ]; then
                "$killer" "$stale_pid" >/dev/null 2>&1 || true  # swallow-ok: whether the window ended is read from the pid itself below
                tries="${SILENT_ACT_KILL_TRIES:-20}"
                # shellcheck disable=SC2086  # alive is `kill -0` or a test seam command
                while [ "$tries" -gt 0 ] && $alive "$stale_pid" >/dev/null 2>&1; do sleep 0.5; tries=$((tries - 1)); done
                # shellcheck disable=SC2086
                if $alive "$stale_pid" >/dev/null 2>&1; then relaunch_err="the stale window (pid $stale_pid) did not end"; fi
            fi
            if [ -z "$relaunch_err" ]; then
                since="$(date +%s)"
                llog="$bucket/silent-act-$label.launch.log"
                sig="$bucket/silent-act-$label.signal"
                if command -v setsid >/dev/null 2>&1; then
                    setsid nohup bash "$launcher" --fleet "$manifest" "$session" "$rdoc" "$sig" $((since + 300)) "$llog" >>"$llog.launcher.out" 2>&1 </dev/null 8>&- 9>&- &
                else
                    nohup bash "$launcher" --fleet "$manifest" "$session" "$rdoc" "$sig" $((since + 300)) "$llog" >>"$llog.launcher.out" 2>&1 </dev/null 8>&- 9>&- &
                fi
                if conf_out="$(bash "$confirm" --since "$since" --chief "$chief" "$session" "$llog" 2>&1)"; then
                    say="${say:+$say }relaunched"; log="${log:+$log }relaunched $session"
                else
                    relaunch_err="launch not confirmed: ${conf_out%%$'\n'*}"
                fi
            fi
        fi
        if [ -n "$relaunch_err" ]; then
            say="${say:+$say }relaunch=failed"; log="${log:+$log }relaunch=failed ($(oneline "$relaunch_err"))"
            owe_row relaunch "$relaunch_err"
        fi
    fi
fi

if [ -z "$say" ]; then echo "SILENT-ACT $label done"; exit 0; fi
[ -z "$owed" ] || { say="$say owed=$owed"; log="$log owed=$owed"; }
bash "$HERE/append-results.sh" "$doc" "SILENT-ACT $label $log silent=${silent}m signal=$signal" >/dev/null 2>&1 9>&- || true  # swallow-ok: a doc that cannot take the bullet still printed the line and kept the owed row
echo "SILENT-ACT $label $say"
exit 0
