#!/usr/bin/env bash
# cadence-runner-exec.sh — test helper: fire a GENERATED POSIX cadence runner
# against a stub payload and a stub alert sink. Sourced, not
# executed; bash 3.2-safe. Used by the cadence arm suites to prove that a runner
# of each kind alerts on a failed leg and clears on a completed one, without
# running the real payload or arming anything on the station.
#
#   cadence_exec_runner <runner-file> <payload-path-in-runner> <payload-rc> <scratch-dir> [alert-path-in-runner]
# (alert-path-in-runner defaults to this checkout's scripts/luna/cadence-alert.sh)
#
# The runner's baked absolute payload path is replaced with a stub that exits
# <payload-rc>, and its baked cadence-alert.sh with a stub that logs its argv.
# Afterwards: <scratch>/alerts holds one line per cadence-alert call, and
# <scratch>/flow-runs.jsonl the ledger rows; the runner's own exit code is
# returned.
cadence_exec_runner() {
    local runner="$1" from="$2" rc="$3" scr="$4" alert_from="${5:-}" root text
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    [ -n "$alert_from" ] || alert_from="$root/scripts/luna/cadence-alert.sh"
    mkdir -p "$scr"
    : > "$scr/alerts"
    rm -f "$scr/flow-runs.jsonl"
    printf '#!/bin/sh\nexit %s\n' "$rc" > "$scr/payload.sh"
    printf '#!/bin/sh\necho "$*" >> %s/alerts\n' "$scr" > "$scr/alert.sh"
    chmod 755 "$scr/payload.sh" "$scr/alert.sh"
    text=$(cat "$runner")
    text=${text//"$from"/$scr/payload.sh}
    text=${text//"$alert_from"/$scr/alert.sh}
    printf '%s\n' "$text" > "$scr/run.sh"
    HIMMEL_FLOW_RUNS_LEDGER="$scr/flow-runs.jsonl" sh "$scr/run.sh" >/dev/null 2>&1
}
