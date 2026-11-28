#!/usr/bin/env bash
# scripts/handover/chief-kit/silent-worker-act.sh - act on a silent worker in code, so a WAKE
# worker-silent line is never the only thing that happens.
#
# Usage: silent-worker-act.sh --doc <chief doc> --fleet <manifest> --bucket <dir> --chief <name>
#                             [--signal <capped-waker|succession-partial>] <label> <silent-minutes>
#
# Output, one line, rc 0:
#   SILENT-ACT <label> none|fresh|done
#   SILENT-ACT <label> [nudged|nudge=no-window|nudge=failed] [relaunched|relaunch=failed|live-window|live-silent|census=unknown] [owed=<id>[,<id>]] [last="<text>"]
# last= follows live-silent: the last assistant text of the newest session transcript written
# since the worker's doc whose start names the worker (one line, at most 300 characters).
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
records="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs"
grace="${SILENT_ACT_NUDGE_GRACE_SECS:-300}"
case "$grace" in ''|*[!0-9]*|???????*) grace=300 ;; *) grace=$((10#$grace)) ;; esac
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

oneline() { printf '%s' "$1" | tr '\r\n\t<>' '    ' | tr -s ' ' | cut -c1-"${2:-160}"; }

last_words() {
    local projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" files f title n text
    [ -d "$projects" ] && [ -n "$wdoc" ] && [ -f "$wdoc" ] || return 0
    files="$(find "$projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$wdoc" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)"  # gnu-ok: Linux-only kit; swallow-ok: an unreadable projects dir yields no transcript and no last words
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        title="$(head -n 20 "$f" 2>/dev/null | jq -rR 'fromjson? | select(.type == "custom-title" or .type == "agent-name") | .customTitle // .agentName // empty' 2>/dev/null)"  # swallow-ok: an unreadable or non-JSON start names no worker, so the file is skipped  # read-sink-ok: the start of a session file, to match it to this worker's names
        for n in $(printf '%s' "$cands" | tr ',' ' '); do
            case $'\n'"$title"$'\n' in *$'\n'"$n"$'\n'*) ;; *) continue ;; esac
            text="$(tail -c 1048576 "$f" 2>/dev/null | jq -nrR '[inputs | fromjson? | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // empty' 2>/dev/null)"  # swallow-ok: an unreadable tail gives no last words and the line stays as before  # read-sink-ok: the tail of this worker's own transcript, for its last assistant text
            text="$(oneline "$text" 300 | tr '"' "'")"
            text="${text% }"
            [ -z "$text" ] || printf 'last="%s"' "$text"
            return 0
        done
    done <<EOF
$files
EOF
}

nudge_epoch() {
    [ -f "$state" ] || { echo 0; return; }
    awk -v k="$label nudge-at $mtime" '$1 " " $2 " " $3 == k { e = $4 } END { print e + 0 }' "$state" || date +%s
}
grace_left() { [ $(( $(date +%s) - $(nudge_epoch) )) -lt "$grace" ]; }
nothing_due() { done_stage nudge && { [ "$silent" -lt "$bound2" ] || done_stage relaunch || grace_left; }; }
if nothing_due; then echo "SILENT-ACT $label done"; exit 0; fi
if command -v flock >/dev/null 2>&1; then
    exec 8>>"$bucket/silent-act.$label.lock" || { echo "SILENT-ACT $label busy"; exit 0; }
    flock -n 8 || { echo "SILENT-ACT $label busy"; exit 0; }  # prim-ok: a per-worker lock on its own file, held by this process alone; a second helper for the same worker waits for the next call
    if nothing_due; then echo "SILENT-ACT $label done"; exit 0; fi
fi

census=""; census_ok=1
if [ -n "${SILENT_ACT_CENSUS:-}" ]; then
    census="$(bash "$SILENT_ACT_CENSUS" 2>/dev/null)" || census_ok=0  # swallow-ok: a failed census keeps its readable rows and is flagged unknown, which owes a row and never relaunches
else
    # shellcheck source=../../lanes/lib/claude-sessions.sh
    . "${SILENT_ACT_CENSUS_LIB:-$HERE/../../lanes/lib/claude-sessions.sh}" 2>/dev/null || census_ok=0  # swallow-ok: an unloadable census is flagged unknown, which owes a row and never relaunches  # read-sink-ok: the test seam beside SILENT_ACT_CENSUS, set only by the suite
    if declare -F claude_sessions >/dev/null 2>&1; then census="$(claude_sessions 2>/dev/null)" || census_ok=0; else census_ok=0; fi  # swallow-ok: a failed or partial census keeps its readable rows and is flagged unknown
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

owed=""; say=""; log=""; last=""
owe_row() {
    local id
    id="$(bash "$HERE/owe.sh" add --bucket "$bucket" --chief "$chief" --kind step \
        --text "silent worker $label ($signal, silent=${silent}m): $1 failed: $(oneline "$2")" \
        --metadata "$(jq -cn --arg l "$label" --arg d "$wdoc" '{source_label: $l, source_doc: $d}')" 2>/dev/null)" || id=FAILED  # swallow-ok: a ledger that cannot take the row is named FAILED in the output
    owed="${owed:+$owed,}$id"
}

relaunch_due=0; nudged_now=0
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
            printf 'SILENT nudge from your chief %s: your handover doc has had no write for %s minutes. Append your newest status bullet to your doc'"'"'s Results now and continue the next step; if you cannot, answer on the bus. Without an answer the chief is told you are blocked. Your scope, token and chief are unchanged; this record carries no ruling and widens nothing.\n' "$HIMMEL_BUS_NAME" "$silent" > "$body"
            wait_for=""; command -v timeout >/dev/null 2>&1 && wait_for="timeout ${SILENT_ACT_BUS_TIMEOUT:-15}"
            # shellcheck disable=SC2086  # wait_for is empty or the words `timeout <n>`
            if bus_out="$($wait_for "$bus" send "$stale_session" "$body" 2>&1)"; then
                ref="$(printf '%s\n' "$bus_out" | sed -nE 's/^sent (#[0-9]+) to .*/\1/p' | head -n 1)"
                say="${say:+$say }nudged"; log="${log:+$log }nudged bus=${ref:-ok}"; nudged_now=1
                printf '%s nudge-at %s %s\n' "$label" "$mtime" "$(date +%s)" >> "$state" 2>/dev/null || owe_row nudge "the nudge time could not be recorded in $state, so the grace before a relaunch cannot be kept"
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

if [ "$relaunch_due" -eq 1 ] && [ "$nudged_now" -eq 0 ] && ! done_stage relaunch && ! grace_left; then
    mark_stage relaunch
    rdoc="${wdoc%.md}-RESUME.md"; session="$stem-RESUME"
    relaunch_err=""
    if [ "$resume_live" -eq 1 ]; then
        say="${say:+$say }live-window"; log="${log:+$log }live-window ($stem-RESUME runs)"
    elif [ "$stale_hits" -ge 1 ]; then
        say="${say:+$say }live-silent"; log="${log:+$log }live-silent (pid $stale_pid, never ended)"
        owe_row relaunch "the worker still has a live window (pid $stale_pid), silent past bound two after the nudge; it is not ended and not relaunched, its blocked step needs the chief"
        last="$(last_words)"
    elif [ "$census_ok" -eq 0 ]; then
        say="${say:+$say }census=unknown"; log="${log:+$log }census=unknown (not relaunched)"
        owe_row relaunch "the process census failed or was incomplete, so a live window cannot be ruled out; the worker is not relaunched, its blocked step needs the chief"
    else
        if [ -z "$wdoc" ]; then
            relaunch_err="the fleet manifest names no doc for $label"
        elif [ ! -f "$rdoc" ]; then
            relaunch_err="no RESUME doc at $rdoc"
        else
            rec=""
            for n in "$stem" ${names//,/ }; do
                [ -r "$records/$n.log" ] || continue
                rec="$(awk '/ role=worker( |$)/ { l = $0 } END { print l }' "$records/$n.log")"
                [ -z "$rec" ] || break
            done
            rprofile="$(printf '%s\n' "$rec" | sed -n 's/.* profile=\([^ ]*\).*/\1/p')"
            rlane="$(printf '%s\n' "$rec" | sed -n 's/.* lane=\([^ ]*\).*/\1/p')"
            rmodel="$(printf '%s\n' "$rec" | sed -n 's/.* model=\([^ ]*\).*/\1/p')"
            if [ -z "$rprofile" ] || [ "$rprofile" = none ] || [ -z "$rlane" ] || [ -z "$rmodel" ]; then
                relaunch_err="no launch record under $records names this worker's profile, lane and model"
            else
                since="$(date +%s)"
                llog="$bucket/silent-act-$label.launch.log"
                sig="$bucket/silent-act-$label.signal"
                if command -v setsid >/dev/null 2>&1; then
                    setsid nohup bash "$launcher" --fleet "$manifest" --profile "$rprofile" --lane "$rlane" "$session" "$rdoc" "$sig" $((since + 300)) "$llog" "$rmodel" >>"$llog.launcher.out" 2>&1 </dev/null 8>&- 9>&- &  # t13b-ok: one relaunch of a dead worker, bounded by the launcher deadline, not a service
                else
                    nohup bash "$launcher" --fleet "$manifest" --profile "$rprofile" --lane "$rlane" "$session" "$rdoc" "$sig" $((since + 300)) "$llog" "$rmodel" >>"$llog.launcher.out" 2>&1 </dev/null 8>&- 9>&- &  # t13b-ok: one relaunch of a dead worker, bounded by the launcher deadline, not a service
                fi
                if conf_out="$(bash "$confirm" --since "$since" --chief "$chief" --secs 60 "$session" "$llog" 2>&1)"; then
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
[ -z "$last" ] || { say="$say $last"; log="$log $last"; }
bash "$HERE/append-results.sh" "$doc" "SILENT-ACT $label $log silent=${silent}m signal=$signal" >/dev/null 2>&1 9>&- || true  # swallow-ok: a doc that cannot take the bullet still printed the line and kept the owed row
echo "SILENT-ACT $label $say"
exit 0
