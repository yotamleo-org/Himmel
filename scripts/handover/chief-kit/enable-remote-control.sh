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
#     ${HIMMELCTL_CACHE_DIR:-~/.claude/himmel}/launch-logs/<name>.log (last line).
# Claudex is ineligible (its proxy endpoint is not a Remote Control endpoint), and
# an unprofiled launch has no Remote Control seam (the profile shim carries the flag):
# both exit 4 with nothing touched. signal-file, deadline and log are the arm
# arguments the launch needs, supplied by the chief as for any launch.
#
# Seams (suites): ENABLE_RC_PROC (default /proc), ENABLE_RC_KILL_CMD (default kill),
# ENABLE_RC_LAUNCHER (default headed-arm-worker.sh beside this script).
#
# Exit codes: 0 enabled/relaunched/already on; 2 usage; 3 no live session by that
# name; 4 ineligible (claudex, unprofiled or no launch record); 5 relaunch needed,
# --relaunch not given; 6 the old session did not exit.
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
pid=""; has_rc=0; model=""; doc=""
for cmdline in "$PROC"/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done < "$cmdline"
    [ "${#argv[@]}" -gt 0 ] || continue
    [ "${argv[0]##*/}" = "claude" ] || continue
    hit=0; rc_on=0; m=""; d=""; i=1
    while [ "$i" -lt "${#argv[@]}" ]; do
        case "${argv[$i]}" in
            -n) [ "${argv[$((i + 1))]:-}" = "$NAME" ] && hit=1 ;;
            --model) m="${argv[$((i + 1))]:-}" ;;
            --remote-control|--remote-control=*) rc_on=1 ;;
        esac
        i=$((i + 1))
    done
    [ "$hit" -eq 1 ] || continue
    last="${argv[$((${#argv[@]} - 1))]}"
    case "$last" in "load "*" and continue") d="${last#load }"; d="${d% and continue}" ;; esac
    pid="${cmdline%/cmdline}"; pid="${pid##*/}"; has_rc="$rc_on"; model="$m"; doc="$d"
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
line=""
[ -r "$rec" ] && line="$(tail -n 1 "$rec")"
profile="$(printf '%s\n' "$line" | sed -n 's/.* profile=\([^ ]*\).*/\1/p')"
lane="$(printf '%s\n' "$line" | sed -n 's/.* lane=\([^ ]*\).*/\1/p')"
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

if [ "$RELAUNCH" -ne 1 ]; then
    echo "enable-remote-control: $NAME (pid $pid) lacks Remote Control and cannot be toggled from outside; rerun with --relaunch to end it and relaunch the same name on $doc (model $model, profile $profile)" >&2
    exit 5
fi

"$KILL_CMD" "$pid" || true
n=0
while [ "$n" -lt 30 ] && [ -d "$PROC/$pid" ] && [ "$PROC" = "/proc" ]; do sleep 1; n=$((n + 1)); done
if [ "$PROC" = "/proc" ] && [ -d "$PROC/$pid" ]; then
    echo "enable-remote-control: pid $pid did not exit after 30s; not relaunching" >&2
    exit 6
fi
exec "$LAUNCHER" --profile "$profile" --lane native "$NAME" "$doc" "$SIGNAL" "$DEADLINE" "$LOG" "$model"
