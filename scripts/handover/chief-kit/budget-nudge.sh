#!/usr/bin/env bash
# budget-nudge.sh — One token-free himmel-bus nudge to every live worker in a fleet manifest,
# sent when the weekly budget comes back (chief-wait.sh runs it on WAKE budget-recovered).
#
#   budget-nudge.sh <fleet manifest>
#
# A live worker is a manifest row that is not lockless and not WRAPPED (queue lock free and
# its newest marker bullet WRAPPED, or replaced by a named successor), the fleet relay-batch.sh
# counts. A native row is sent to its one live `claude -n <name>` session (candidates: its full
# doc stem, then worker_identity's names), a claudex row to its doc stem. Each gets ONE record
# with a fixed text: the budget is back, continue the next step of your own handover doc; scope,
# token and chief are unchanged. It carries no token and widens nothing: the bus proves the sender.
# Per worker: `BUS-NUDGE <label> ok`, `BUS-NUDGE-FAIL <label> (<reason>)` or
# `UNRESOLVED <label> (...)`; the last line is `NUDGED <n> of <m>` (m the live fleet).
# Fail-soft: a failed worker never stops the rest. Exit: 0 ok; 2 usage.
# Seams (tests): BUDGET_NUDGE_BUS replaces the bus CLI; BUDGET_NUDGE_CENSUS is a script printing
# claude_sessions-format census lines; BUDGET_NUDGE_BUS_TIMEOUT is the one deadline for all sends
# (seconds, default 15).
# PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then echo "usage: budget-nudge.sh <fleet manifest>" >&2; exit 2; fi
manifest="$1"
# shellcheck source=../../lib/worker-identity.sh
. "$HERE/../../lib/worker-identity.sh"
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
# shellcheck source=../../lib/worker-tail-status.sh
. "$HERE/../../lib/worker-tail-status.sh"
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh"
# shellcheck source=../../lib/worker-successor.sh
. "$HERE/../../lib/worker-successor.sh"
wrapped() {
    [ -n "$(worker_named_successor "$1")" ] && bash "$HERE/../queue-lock.sh" status "$1" >/dev/null 2>&1 && return 0
    bash "$HERE/../queue-lock.sh" status "$1" >/dev/null 2>&1 && [ "$(worker_tail_status "$1")" = WRAPPED ]
}
bus="${BUDGET_NUDGE_BUS:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"

resolve_session() {
    local lnames dlabel clabel back
    lstem="$(basename "$1" .md)"
    lnames="$(worker_identity "$1")"; lnames="${lnames#*$'\t'}"
    cands=",$lstem,$lnames,"
    hits=0; lsession=""
    while IFS=$'\t' read -r _cpid cname _rest; do
        [ -n "$cname" ] || continue
        case "$cands" in *",$cname,"*) hits=$((hits + 1)); lsession="$cname" ;; esac
    done <<EOC
$census_lines
EOC
    [ "$hits" -eq 0 ] || return 0
    dlabel="$(worker_label "$1")"
    [[ $dlabel =~ ^N[0-9]+$ ]] || return 0
    while IFS=$'\t' read -r _cpid cname _rest; do
        [ -n "$cname" ] || continue
        clabel="$(worker_label "$cname")"
        [[ $clabel =~ ^${dlabel}[a-z]+$ ]] || continue
        back="$(printf '%s' "$cname" | sed -E "s/-${clabel}(-|\$)/-${dlabel}\\1/")"
        case "$cands" in *",$back,"*) hits=$((hits + 1)); lsession="$cname" ;; esac
    done <<EOC
$census_lines
EOC
}

if [ -n "${BUDGET_NUDGE_CENSUS:-}" ]; then
    census_lines="$(bash "$BUDGET_NUDGE_CENSUS")" || { echo "budget-nudge: census failed" >&2; census_lines=""; }
else
    # shellcheck source=../../lanes/lib/claude-sessions.sh
    . "$HERE/../../lanes/lib/claude-sessions.sh"
    census_lines="$(claude_sessions)"; crc=$?
    [ "$crc" -le 1 ] || { echo "budget-nudge: process census failed (rc=$crc)" >&2; census_lines=""; }
fi

body=""
if [ -n "${HIMMEL_BUS_NAME:-}" ]; then
    dir="$(tmpdir)" || dir=""
    if [ -n "$dir" ]; then
        trap 'rm -rf "$dir"' EXIT
        body="$dir/nudge"
        printf 'BUDGET nudge from your chief %s: the weekly budget is back. Continue the next step of your own handover doc'"'"'s Results where you stopped. Your scope, token and chief are unchanged; this record carries no ruling and widens nothing.\n' "$HIMMEL_BUS_NAME" > "$body"
    fi
fi

limit="${BUDGET_NUDGE_BUS_TIMEOUT:-15}"; t0=$SECONDS
wait_for=""; command -v timeout >/dev/null 2>&1 && wait_for=timeout
sent=0; total=0
rows="$(jq -r "$JQ_W"'W[] | select(.lockless == true | not) | [.label, ((.lane // "") | if . == "" then "unknown" else . end), .doc] | @tsv' "$manifest")" || { echo "budget-nudge: unreadable fleet manifest $manifest" >&2; exit 2; }
while IFS=$'\t' read -r label lane ldoc; do
    [ -n "$label" ] || continue
    if wrapped "$ldoc"; then continue; fi
    total=$((total + 1))
    case "$lane" in
        claudex) lsession="$(basename "$ldoc" .md)"; hits=1 ;;
        native) resolve_session "$ldoc" ;;
        *) echo "UNRESOLVED $label (lane $lane has no nudge path, nothing sent)"; continue ;;
    esac
    if [ "$hits" -ne 1 ]; then
        echo "UNRESOLVED $label (candidates: ${cands#,}; $hits live match(es), nothing sent)"
        continue
    fi
    if [ -z "${HIMMEL_BUS_NAME:-}" ]; then echo "BUS-NUDGE-FAIL $label (no bus identity)"; continue; fi
    if [ -z "$body" ]; then echo "BUS-NUDGE-FAIL $label (mktemp failed)"; continue; fi
    rem=$((10#$limit - (SECONDS - t0)))
    [ "$rem" -ge 1 ] || { echo "BUS-NUDGE-FAIL $label (bus deadline spent)"; continue; }
    if err="$(${wait_for:+$wait_for "$rem"} "$bus" send "$lsession" "$body" 2>&1 >/dev/null)"; then
        echo "BUS-NUDGE $label ok"; sent=$((sent + 1))
    else
        [ "$?" -eq 124 ] && [ -n "$wait_for" ] && err="timed out after ${rem}s"
        echo "BUS-NUDGE-FAIL $label (${err%%$'\n'*})"
    fi
done <<EOF
$rows
EOF
echo "NUDGED $sent of $total"
exit 0
