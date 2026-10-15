#!/usr/bin/env bash
# parked-on-prompt.sh — name the legs whose newest trust-ledger row is an
# unanswered permission prompt.
#
# A headed leg that trips the auto-mode "3 consecutive actions were blocked"
# dialog sits on a modal nobody can see: its lock heartbeat stays fresh and
# ListAgents reads it as busy. The PermissionRequest / Notification hooks
# (scripts/trust/shadow-ledger.mjs) already write a row when the dialog
# opens, and every later tool call writes another, so a session whose LAST row
# is a prompt and is older than the floor is parked on it.
#
# usage: parked-on-prompt.sh [--min MINUTES] [--ledger FILE] LEG_DOC...
# output (one line): parked=none | parked=<leg>:<age>m[,<leg>:<age>m...]
# <leg> is the doc's basename without .md. A leg is matched by the session ids
# in its doc's frontmatter (`session_ids:`); a doc without any is skipped.
# env: TICK_PARKED_MIN (default 5), TICK_PARKED_TAIL_BYTES (ledger tail
# read, default 16777216), HIMMEL_TRUST_LEDGER_DIR (the ledger's own seam).
#
# ponytail: a parked session whose last row sank past the tail window reads as
# not parked, bump TICK_PARKED_TAIL_BYTES, or index the ledger by session.
#
# READ-ONLY. Bash 3.2-compatible. PLATFORM GUARD: no .ps1 twin, by design —
# Linux-only console kit (GNU date -d).
set -uo pipefail

min="${TICK_PARKED_MIN:-5}"
tail_bytes="${TICK_PARKED_TAIL_BYTES:-16777216}"
ledger="${HIMMEL_TRUST_LEDGER_DIR:-$HOME/.claude/himmel/trust}/ledger.jsonl"
docs=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --min) min="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --ledger) ledger="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) docs+=("$1"); shift ;;
    esac
done
case "$min" in ''|*[!0-9]*) min=5 ;; esac
case "$tail_bytes" in ''|*[!0-9]*) tail_bytes=16777216 ;; esac

if [ ! -r "$ledger" ] || [ "${#docs[@]}" -eq 0 ]; then
    echo 'parked=none'
    exit 0
fi

window="$(mktemp "${TMPDIR:-/tmp}/parked-on-prompt.XXXXXX")" || { echo 'parked=?'; exit 0; }
trap 'rm -f "$window"' EXIT
tail -c "$tail_bytes" "$ledger" > "$window" 2>/dev/null || { echo 'parked=?'; exit 0; }

now="$(date +%s)"
out=""
for doc in "${docs[@]}"; do
    [ -r "$doc" ] || continue
    sids="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} /^session_ids:/{print;exit}' "$doc" 2>/dev/null | grep -oE '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')"
    [ -n "$sids" ] || continue
    for sid in $sids; do
        last="$(grep -F "\"session_id\":\"$sid\"" "$window" | tail -n 1)"
        [ -n "$last" ] || continue
        case "$last" in
            *'"kind":"permission_request"'*|*'"kind":"notification"'*'"notification_type":"permission_prompt"'*) ;;
            *) continue ;;
        esac
        ts="$(printf '%s' "$last" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
        epoch="$(date -d "$ts" +%s 2>/dev/null)" || continue  # gnu-ok: Linux-only kit
        age=$(( (now - epoch) / 60 ))
        [ "$age" -ge "$min" ] || continue
        label="$(basename "$doc" .md)"
        out="${out:+$out,}$label:${age}m"
        break
    done
done

echo "parked=${out:-none}"
