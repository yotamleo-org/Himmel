#!/usr/bin/env bash
# gemini-quota-probe.sh — is the Gemini quota group (Antigravity lane) empty?
# headless-gemini-ok: /usage runs no agent turn and spends no quota
#   gemini-quota-probe.sh                 probe `agy -p "/usage" --output-format json`
#   gemini-quota-probe.sh --record "<line>"
#                                         backstop: parse "Individual quota
#                                         reached ... Resets in 3h26m16s" from a
#                                         thread's output and mark the group empty
#                                         until the reset
#
# `/usage` runs no agent turn and spends no quota. All Gemini models (Neon,
# Carbon, Argon, Hydrogen, Orchestrators, 3.8 Flash) share ONE group with a
# weekly and a 5-hour bucket, so this keys on the group, not on a pool.
#
# Prints one line per bucket (`bucket=<id> remaining_fraction=<f> reset_time=<iso>
# state=ok|empty`), then ONE verdict token, and exits:
#   0  GEMINI-ADMIT                  every bucket has quota, or its window has reset
#   1  GEMINI-EMPTY until=<iso>      a bucket is empty (or a recorded cap is live)
#   2  GEMINI-UNKNOWN reason=<why>   agy missing, unreadable JSON, probe timed out
# A caller that cannot tell must treat 2 like 1: refusing is the default.
# `--record` is the one exception: a successful write prints GEMINI-EMPTY and
# exits 0, which records a cap and is not an admission. It keeps the later of the
# new and any live recorded deadline.
#
# A bucket is empty when remaining_fraction <= GEMINI_QUOTA_FLOOR (default 0.02)
# AND its reset_time is in the future; an epoch reset means no window is running.
#
# Env: GEMINI_QUOTA_AGY (agy binary, default agy), GEMINI_QUOTA_TIMEOUT (seconds,
# default 20), GEMINI_QUOTA_FLOOR, GEMINI_QUOTA_STATE_FILE (backstop; default
# ~/.himmel/gemini-quota-empty-until), GEMINI_QUOTA_NOW (epoch, tests only).
set -uo pipefail

AGY="${GEMINI_QUOTA_AGY:-agy}"
TMO="${GEMINI_QUOTA_TIMEOUT:-20}"
FLOOR="${GEMINI_QUOTA_FLOOR:-0.02}"
STATE="${GEMINI_QUOTA_STATE_FILE:-$HOME/.himmel/gemini-quota-empty-until}"
NOW="${GEMINI_QUOTA_NOW:-$(date +%s)}"

unknown() { echo "GEMINI-UNKNOWN reason=$1"; exit 2; }
iso() { jq -nr --argjson e "$1" '$e | todate'; }

command -v jq >/dev/null 2>&1 || unknown "jq-missing"
case "$FLOOR$TMO$NOW" in *[!0-9.]*) unknown "bad-env" ;; esac

if [ "${1:-}" = "--record" ]; then
    line="${2:-}"
    re='Individual quota reached.*Resets in[[:space:]]+(([0-9]+)d)?(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?'
    [[ "$line" =~ $re ]] || unknown "not-the-quota-line"
    d="${BASH_REMATCH[2]}"; h="${BASH_REMATCH[4]}"; m="${BASH_REMATCH[6]}"; s="${BASH_REMATCH[8]}"
    [ -n "$d$h$m$s" ] || unknown "no-duration"
    until_epoch=$((NOW + 10#${d:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0}))
    old="$(head -n1 "$STATE" 2>/dev/null)"
    case "$old" in ''|*[!0-9]*) ;; *) [ "$old" -gt "$until_epoch" ] && until_epoch="$old" ;; esac
    # shellcheck source=scripts/lib/prim.sh
    . "$(dirname "${BASH_SOURCE[0]}")/prim.sh" || unknown "prim-missing"
    if ! { mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$until_epoch" | atomic_write "$STATE"; }; then
        unknown "state-unwritable"
    fi
    echo "GEMINI-EMPTY until=$(iso "$until_epoch")"
    exit 0
fi

if [ -r "$STATE" ]; then
    rec="$(head -n1 "$STATE" 2>/dev/null)"
    case "$rec" in ''|*[!0-9]*) ;; *)
        if [ "$rec" -gt "$NOW" ]; then echo "GEMINI-EMPTY until=$(iso "$rec") source=output-line"; exit 1; fi ;;
    esac
fi

# shellcheck source=scripts/lib/timeout-bin.sh
. "$(dirname "${BASH_SOURCE[0]}")/timeout-bin.sh" 2>/dev/null
[ -n "${_TIMEOUT_BIN:-}" ] || unknown "no-timeout-binary"
command -v "$AGY" >/dev/null 2>&1 || unknown "agy-missing"

raw="$("$_TIMEOUT_BIN" -k 2 "$TMO" "$AGY" -p "/usage" --output-format json 2>/dev/null)" \
    || unknown "probe-failed-or-timed-out"

rows="$(jq -r --argjson now "$NOW" --argjson floor "$FLOOR" '
  if .status != "SUCCESS" then error("status")
  else [.command.data.groups[]? | select(.name == "Gemini Models") | .buckets[]?] as $b
  | if ($b | length) == 0 then error("no-buckets") else $b[] end
  | (.remaining_fraction | if type == "number" then . else error("fraction") end) as $f
  | (try (.reset_time | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $r0
  | (if $r0 == null and $f <= $floor then error("reset_time") else ($r0 // 0) end) as $r
  | [.id, $f, .reset_time, $r, (if $f <= $floor and $r > $now then "empty" else "ok" end)] | @tsv
  end' <<<"$raw" 2>/dev/null)" || unknown "unreadable-usage-json"
[ -n "$rows" ] || unknown "unreadable-usage-json"

empty_until=0
while IFS=$'\t' read -r id f reset r st; do
    echo "bucket=$id remaining_fraction=$f reset_time=$reset state=$st"
    [ "$st" = "empty" ] && [ "$r" -gt "$empty_until" ] && empty_until="$r"
done <<<"$rows"

if [ "$empty_until" -gt 0 ]; then echo "GEMINI-EMPTY until=$(iso "$empty_until")"; exit 1; fi
echo "GEMINI-ADMIT"
