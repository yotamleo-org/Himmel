#!/usr/bin/env bash
# Managed launch bridge. Every operation revalidates persisted state and identity.
_FLEET_LAUNCH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fleet_launch_op() {
    python3 -I "$_FLEET_LAUNCH_LIB/fleet_runtime.py" "$1" --doc "$FLEET_LAUNCH_DOC" \
        --manifest "$FLEET_LAUNCH_MANIFEST" --name "$FLEET_LAUNCH_NAME" \
        --attempt-id "$FLEET_LAUNCH_ATTEMPT" --pid "$$" --lane "${FLEET_LAUNCH_LANE:-native}" "${@:2}"
}

fleet_launch_prepare() {
    local scope
    FLEET_LAUNCH_DOC="$1" FLEET_LAUNCH_NAME="$2"
    FLEET_LAUNCH_LANE="${5:-${FLEET_LAUNCH_LANE:-${WORKER_SESSION_LANE:-native}}}"
    scope=$(python3 -I "$_FLEET_LAUNCH_LIB/fleet_runtime.py" resolve --doc "$1" --manifest "${3:-}") || return 10
    FLEET_LAUNCH_MANAGED=$(printf '%s\n' "$scope" | jq -r .managed) || return 10
    [ "$FLEET_LAUNCH_MANAGED" = true ] || return 0
    FLEET_LAUNCH_MANIFEST=$(printf '%s\n' "$scope" | jq -r .manifest) || return 10
    FLEET_LAUNCH_ATTEMPT="${4:-$(cat /proc/sys/kernel/random/uuid)}" || return 10
    fleet_launch_op begin >/dev/null || return 10
    export FLEET_LAUNCH_DOC FLEET_LAUNCH_NAME FLEET_LAUNCH_MANIFEST FLEET_LAUNCH_ATTEMPT
    export FLEET_LAUNCH_LANE WORKER_SESSION_DOC="$1" WORKER_SESSION_ATTEMPT_ID="$FLEET_LAUNCH_ATTEMPT"
    fleet_launch_op check >/dev/null
}

fleet_launch_commit() {
    [ "${FLEET_LAUNCH_MANAGED:-false}" = true ] || return 0
    local token
    token=$(CADENCE_USAGE_LAUNCH=1 CADENCE_USAGE_WORKER="$FLEET_LAUNCH_NAME" CADENCE_USAGE_CALLER_PID="$$" \
        CADENCE_USAGE_RECHECK_ATTEMPT="$FLEET_LAUNCH_ATTEMPT" bash "$_FLEET_LAUNCH_LIB/usage-preflight.sh") || return 10
    case "$token" in PROCEED|BANK-STALE|BANK-UNKNOWN) ;; *) return 10 ;; esac
    fleet_launch_op commit >/dev/null
}

fleet_launch_outcome() {
    [ "${FLEET_LAUNCH_MANAGED:-false}" = true ] || return 0
    fleet_launch_op outcome --phase "$1" >/dev/null
}

fleet_launch_finish() {
    [ "${FLEET_LAUNCH_MANAGED:-false}" = true ] || return 0
    local result
    result=$(fleet_launch_op finish) || return 10
    if [ "$(printf '%s\n' "$result" | jq -r .phase)" = refused ]; then fleet_launch_release; fi
}

fleet_launch_release() {
    [ "${FLEET_LAUNCH_MANAGED:-false}" = true ] || return 0
    python3 -I "$_FLEET_LAUNCH_LIB/fleet_runtime.py" release --attempt-id "$FLEET_LAUNCH_ATTEMPT" --pid "$$" >/dev/null
}
