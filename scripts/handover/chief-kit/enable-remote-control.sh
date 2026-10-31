#!/usr/bin/env bash
# enable-remote-control.sh - turn Remote Control on for a named native
# worker, so the operator can answer a classifier-refused worker from the Claude
# app (the session shows up there under its session name).
#
# usage: enable-remote-control.sh [--relaunch] <session-name> <signal-file> <deadline-epoch> <log>
#
# A native worker launched by headed-arm-worker.sh --profile already carries
# `--remote-control <session-name>`. For one that lacks it this finds the live claude
# session (an exact `-n <session-name>` argv element, read from /proc) and:
#   - already has --remote-control: says so, exit 0.
#   - lacks it: a running session cannot be toggled from outside (the in-session
#     /remote-control command is typed in its own window), so the only way is a
#     relaunch. That ends the session, which is destructive, so it needs --relaunch;
#     without it the plan is printed and nothing is touched (exit 5).
#   - with --relaunch: kills the session's pid and relaunches the SAME session
#     name on the same doc, model and profile through headed-arm-worker.sh (the
#     doc is the state, so the new session loads it and continues). Profile and
#     lane come from the launch record headed-arm-worker.sh appends under
#     ${HIMMELCTL_CACHE_DIR:-~/.claude/himmel}/launch-logs/<name>.log: the ONE line whose
#     session_id equals the live argv's --session-id and whose model equals its --model
#     (the log is append-only, so a later launch of the same name may own the last line).
#     The owning chief (--chief) and WORKER_SESSION_EFFORT are read from the old
#     session's environ and carried; the launcher runs --dry-run FIRST and nothing is
#     killed if that fails.
# The relaunched session's working directory is the doc's resume_cwd, resolved by
# headed-arm-worker.sh as for any launch (never this script's cwd, nor the old pid's,
# which a worker may have moved). A doc with no resume_cwd launches in the harness cwd.
# Claudex is ineligible (its proxy endpoint is not a Remote Control endpoint), and
# an unprofiled launch has no Remote Control seam (the profile shim carries the flag):
# both exit 4 with nothing touched. signal-file, deadline and log are the arm
# arguments the launch needs, supplied by the chief as for any launch.
#
# Seams (suites): ENABLE_RC_PROC (default /proc), ENABLE_RC_KILL_CMD (default kill),
# ENABLE_RC_LAUNCHER (default headed-arm-worker.sh beside this script),
# ENABLE_RC_BEFORE_KILL (a command run with the pid and proc dir between the scan and
# the pid re-check; a suite uses it to recycle the pid).
#
# Exit codes: 0 enabled/relaunched/already on; 2 usage; 3 no live session by that
# name; 4 ineligible (claudex, unprofiled, no or ambiguous launch record for the live
# session id, a record model that differs from the live one, a role other than a plain
# worker such as a consult, judge or relay, a release manager, an A/B arm or context-mode
# launch, or the session's doc and model unreadable from its argv); 5 relaunch needed,
# --relaunch not given; 6 the pid no longer names the session (recycled or gone, nothing
# killed) or the old session did not exit; 7 the relaunch dry-run failed (nothing killed).
#
# ponytail: relaunch loses the old session's context window (the doc carries state), upgrade path: a native toggle once claude exposes one over its session file.
# Platform: Linux only (reads /proc), as the rest of the chief kit.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RELAUNCH=0
if [ "${1:-}" = "--relaunch" ]; then RELAUNCH=1; shift; fi
if [ "$#" -ne 4 ] || [ -z "$1" ]; then
    echo "usage: enable-remote-control.sh [--relaunch] <session-name> <signal-file> <deadline-epoch> <log>" >&2
    exit 2
fi
NAME="$1"; SIGNAL="$2"; DEADLINE="$3"; LOG="$4"
PROC="${ENABLE_RC_PROC:-/proc}"
KILL_CMD="${ENABLE_RC_KILL_CMD:-kill}"
LAUNCHER="${ENABLE_RC_LAUNCHER:-$HERE/headed-arm-worker.sh}"

# The live session: argv[0] basename claude and an exact `-n <NAME>` pair.
pid=""; has_rc=0; model=""; doc=""; sid=""
for cmdline in "$PROC"/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done < "$cmdline"
    [ "${#argv[@]}" -gt 0 ] || continue
    [ "${argv[0]##*/}" = "claude" ] || continue
    hit=0; rc_on=0; m=""; d=""; s=""; i=1
    while [ "$i" -lt "${#argv[@]}" ]; do
        case "${argv[$i]}" in
            -n) [ "${argv[$((i + 1))]:-}" = "$NAME" ] && hit=1 ;;
            --model) m="${argv[$((i + 1))]:-}" ;;
            --session-id) s="${argv[$((i + 1))]:-}" ;;
            --remote-control|--remote-control=*) rc_on=1 ;;
        esac
        i=$((i + 1))
    done
    [ "$hit" -eq 1 ] || continue
    last="${argv[$((${#argv[@]} - 1))]}"
    case "$last" in "load "*" and continue") d="${last#load }"; d="${d% and continue}" ;; esac
    pid="${cmdline%/cmdline}"; pid="${pid##*/}"; has_rc="$rc_on"; model="$m"; doc="$d"; sid="$s"
    break
done

if [ -z "$pid" ]; then
    echo "enable-remote-control: no live claude session named $NAME" >&2
    exit 3
fi
if [ "$has_rc" -eq 1 ]; then
    echo "enable-remote-control: $NAME already has Remote Control on (open the session named $NAME in the Claude app)"
    exit 0
fi

cache="${HIMMELCTL_CACHE_DIR:-${HOME:-}/.claude/himmel}"
rec="$cache/launch-logs/$NAME.log"
# The record is append-only and holds one line per launch of this name, so the live
# session's own line is the one whose session_id equals its argv --session-id; never
# the last line, which a later, wider launch of the same name may own. Missing, ambiguous
# or model-mismatched: exit 4, nothing touched.
if [ -z "$sid" ]; then
    echo "enable-remote-control: $NAME's argv carries no --session-id, so its launch record cannot be identified" >&2
    exit 4
fi
line=""
if [ -r "$rec" ]; then
    matches="$(awk -v s=" session_id=$sid " 'index($0 " ", s) { print }' "$rec")"
    nmatch=0
    [ -z "$matches" ] || nmatch="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    if [ "$nmatch" -ne 1 ]; then
        echo "enable-remote-control: $NAME's launch record has $nmatch line(s) for session $sid (need exactly one)" >&2
        exit 4
    fi
    line="$matches"
else
    echo "enable-remote-control: no launch record for $NAME" >&2
    exit 4
fi
rec_model="$(printf '%s\n' "$line" | sed -n 's/.* model=\([^ ]*\).*/\1/p')"
if [ -n "$model" ] && [ "$rec_model" != "$model" ]; then
    echo "enable-remote-control: $NAME's launch record names model ${rec_model:-unknown} but the live session runs $model; not trusting the record" >&2
    exit 4
fi
profile="$(printf '%s\n' "$line" | sed -n 's/.* profile=\([^ ]*\).*/\1/p')"
lane="$(printf '%s\n' "$line" | sed -n 's/.* lane=\([^ ]*\).*/\1/p')"
role="$(printf '%s\n' "$line" | sed -n 's/.* role=\([^ ]*\).*/\1/p')"
if [ "$role" != "worker" ]; then
    echo "enable-remote-control: $NAME was launched as role=${role:-unknown}; a relaunch would make it a plain worker and drop that role's confinement" >&2
    exit 4
fi
if [ -z "$lane" ] || [ "$lane" != "native" ]; then
    echo "enable-remote-control: $NAME is not a recorded native-lane launch (lane=${lane:-unknown}); Remote Control is native-only" >&2
    exit 4
fi
if [ -z "$profile" ] || [ "$profile" = "none" ]; then
    echo "enable-remote-control: $NAME was launched without a profile; only a profiled launch carries --remote-control" >&2
    exit 4
fi
if [ -z "$doc" ] || [ -z "$model" ]; then
    echo "enable-remote-control: cannot read $NAME's doc and model from its argv" >&2
    exit 4
fi
# A release manager is bound to one release (--rm-release, its marker and read clamp), which a
# plain relaunch cannot restore; an A/B arm or a chosen context mode is launch input of the
# same kind. Refuse them all rather than relaunch a different session under the same name.
case "$profile" in
    release-manager)
        echo "enable-remote-control: $NAME is a release manager (bound to one release); a relaunch cannot restore that binding" >&2
        exit 4 ;;
esac
case "$line" in
    *" ab_arm="*)
        echo "enable-remote-control: $NAME is an A/B arm launch; a relaunch cannot restore the arm" >&2
        exit 4 ;;
esac
# The old session's own environment (/proc/<pid>/environ): the owning chief and the effort
# are carried onto the relaunch; any other launch-shaping input it was started with is not
# reproducible, so its presence refuses.
chief=""; effort=""
# An environment that cannot be read cannot be checked for the refusals below or for the
# chief and effort to carry, so it fails closed rather than relaunching on a guess.
if [ ! -r "$PROC/$pid/environ" ]; then
    echo "enable-remote-control: cannot read $NAME's environment (pid $pid); not relaunching on a guess" >&2
    exit 4
fi
while IFS= read -r -d '' kv; do
    case "$kv" in
        HIMMEL_CONSOLE_NAME=*) chief="${kv#*=}" ;;
        WORKER_SESSION_EFFORT=*) effort="${kv#*=}" ;;
        WORKER_SESSION_AUTOCOMPACT_AB=?*|HIMMEL_WORKER_SESSION_CONTEXT_MODE=?*)
            echo "enable-remote-control: $NAME was launched with ${kv%%=*}, which a relaunch cannot restore" >&2
            exit 4 ;;
    esac
done < "$PROC/$pid/environ"  # read-sink-ok: the path is the scanned pid's own environ under the proc dir

if [ "$RELAUNCH" -ne 1 ]; then
    echo "enable-remote-control: $NAME (pid $pid) lacks Remote Control and cannot be toggled from outside; rerun with --relaunch to end it and relaunch the same name on $doc (model $model, profile $profile)" >&2
    exit 5
fi

# The relaunch exactly as it will run, minus the kill. A launcher that cannot start the
# session again (refused profile, bad doc, missing model) must be found out BEFORE the
# live session is ended, never after.
launch=(--profile "$profile" --lane native)
[ -z "$chief" ] || launch+=(--chief "$chief")
launch+=("$NAME" "$doc" "$SIGNAL" "$DEADLINE" "$LOG" "$model")
# The relaunch gets the OLD session's effort or none: an ambient value in the caller's
# shell must not stand in for it.
if [ -n "$effort" ]; then export WORKER_SESSION_EFFORT="$effort"; else unset -v WORKER_SESSION_EFFORT; fi
if ! "$LAUNCHER" --dry-run "${launch[@]}" >/dev/null 2>&1; then  # swallow-ok: the failure is reported on the next line and nothing is killed
    echo "enable-remote-control: the relaunch dry-run failed; $NAME was NOT ended (run the launcher with --dry-run by hand to see why)" >&2
    exit 7
fi
[ -z "${ENABLE_RC_BEFORE_KILL:-}" ] || "$ENABLE_RC_BEFORE_KILL" "$pid" "$PROC"
# The pid was matched above; confirm it still names this session right before the
# kill, which shrinks the window in which an unrelated process could hold a recycled pid.
# ponytail: the check and the kill are two steps, so a pid recycled in the microseconds between them is still signalled, upgrade path: pidfd_send_signal once a helper that can open a pidfd is a dependency here.
if ! tr '\0' '\n' < "$PROC/$pid/cmdline" 2>/dev/null | awk -v n="$NAME" 'p == "-n" && $0 == n { f = 1 } { p = $0 } END { exit !f }'; then  # swallow-ok: an unreadable cmdline means the pid is gone or reused; not killing is the safe answer
    echo "enable-remote-control: pid $pid no longer names session $NAME; not killing" >&2
    exit 6
fi
"$KILL_CMD" "$pid" || true
n=0
while [ "$n" -lt 30 ] && [ -d "$PROC/$pid" ] && [ "$PROC" = "/proc" ]; do sleep 1; n=$((n + 1)); done
if [ "$PROC" = "/proc" ] && [ -d "$PROC/$pid" ]; then
    echo "enable-remote-control: pid $pid did not exit after 30s; not relaunching" >&2
    exit 6
fi
exec "$LAUNCHER" "${launch[@]}"
