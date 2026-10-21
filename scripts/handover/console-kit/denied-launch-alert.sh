#!/usr/bin/env bash
# denied-launch-alert.sh — ONE operator Telegram alert per classifier-denied leg
# launch (headed-arm-leg.sh / headed-arm.sh), so a console whose launch the
# auto-mode classifier denied does not idle until the fleet drains to zero.
#
# usage: denied-launch-alert.sh
#
# Scans the denial log scripts/hooks/log-classifier-denial.sh writes
# (${HIMMEL_CLASSIFIER_DENIALS_LOG:-~/.himmel/state/classifier-denials.jsonl}) for
# Bash rows inside a trailing window (DENIED_LAUNCH_WINDOW_MIN, default 30) whose
# command is a leg launch, and sends:
#   DENIED-LAUNCH <leg> - Bash launch denied by the classifier. Details stay on the station: <log path>
#
# HARD RULE (log-classifier-denial.sh): the denied command and the denial reason
# never leave this host. They classify HERE and are never printed into the
# alert; the text is the leg label, the tool and the local log path only.
#
# Dedupe: one sentinel per denial row (session_id, ts, input_sha) in
# ${HIMMEL_DENIAL_ALERT_DIR:-~/.himmel/state/denied-launch-alerts} (dir 0700),
# created atomically BEFORE the send and removed again if the send fails, so a
# later scan retries and the operator still gets at most one. A delivered row's
# sentinel is non-empty; an empty one older than 5 min is a scan killed mid-send
# and is reclaimed under a lock in the same dir (with_lock), so two scans racing
# on one stale claim cannot both reclaim it. A launch denied again later is a new
# row and alerts again.
#
# Always exits 0: the alert is an addition, never a gate. Sender and operator
# lookup are merge-block-alert.sh's (MERGE_BLOCK_ALERT_CMD,
# TELEGRAM_ACCESS_PATH seams).
#
# ponytail: detects headed-arm launch rows only, a denied brief write is not one, add the Write tool's brief-path shape once observed
# ponytail: nothing calls this yet, upgrade path is one call next to page_denials in console-wait.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

command -v jq >/dev/null 2>&1 || exit 0
log="${HIMMEL_CLASSIFIER_DENIALS_LOG:-$HOME/.himmel/state/classifier-denials.jsonl}"
[ -f "$log" ] || exit 0

# shellcheck source=scripts/lib/merge-block-alert.sh
. "$REPO/scripts/lib/merge-block-alert.sh" 2>/dev/null || exit 0

win="${DENIED_LAUNCH_WINDOW_MIN:-30}"
case "$win" in ''|*[!0-9]*) win=30 ;; esac
cutoff="$(date -u -d "-${win} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"  # gnu-ok: Linux-only kit  # swallow-ok: an empty cutoff exits 0 on the next line, no alert
[ -n "$cutoff" ] || exit 0

dir="${HIMMEL_DENIAL_ALERT_DIR:-$HOME/.himmel/state/denied-launch-alerts}"
[ -d "$dir" ] || { ( umask 077; mkdir -p "$dir" ) 2>/dev/null && chmod 700 "$dir" 2>/dev/null; } || exit 0

chat="$(_mba_operator_chat)" || chat=""
stale=5  # minutes before an empty claim (a scan killed mid-send) is reclaimed

# shellcheck source=scripts/lib/prim.sh
. "$REPO/scripts/lib/prim.sh" 2>/dev/null || exit 0

# Runs under with_lock: staleness is re-checked once the lock is held, so of two
# scans that both saw the stale claim only the first removes and recreates it.
# shellcheck disable=SC2329  # invoked through with_lock's "$@"
reclaim_claim() { # <claim path>
    [ -s "$1" ] && return 1
    [ -n "$(find "$1" -mmin "+$stale" 2>/dev/null)" ] || return 1  # swallow-ok: a failed find skips the reclaim, the claim stays held
    rm -f "$1" 2>/dev/null
    ( set -o noclobber; : > "$1" ) 2>/dev/null
}

# One TSV line per matching row: <leg>\t<tool>\t<row id>. The leg label and tool
# are the only row fields that reach the alert.
{ [ -r "$log.1" ] && cat "$log.1"; cat "$log"; } 2>/dev/null | tail -n 2000 \
    | jq -R -r --arg cutoff "$cutoff" 'fromjson?
        | select(type == "object" and (.ts // "") >= $cutoff and (.tool // "") == "Bash"
                 and ((.input_head // "") | type == "string")
                 and ((.input_head // "") | test("headed-arm(-leg)?\\.sh")))
        | [(.session_title // "unknown"), .tool,
           "\(.session_id // "")|\(.ts)|\(.input_sha // "")"] | @tsv' 2>/dev/null \
    | while IFS="$(printf '\t')" read -r leg tool rowid; do
        key="$(printf '%s' "$rowid" | sha256sum | cut -c1-40)"  # gnu-ok: Linux-only kit
        if ! ( set -o noclobber; : > "$dir/$key" ) 2>/dev/null; then
            [ -s "$dir/$key" ] && continue
            with_lock "$dir/.reclaim.lock" reclaim_claim "$dir/$key" || continue
        fi
        if [ -z "$chat" ]; then
            rm -f "$dir/$key" 2>/dev/null
            continue
        fi
        if _mba_send "$chat" "DENIED-LAUNCH $leg - $tool launch denied by the classifier. Details stay on the station: $log" </dev/null; then
            printf 'sent\n' > "$dir/$key" 2>/dev/null
        else
            rm -f "$dir/$key" 2>/dev/null
        fi
    done
exit 0
