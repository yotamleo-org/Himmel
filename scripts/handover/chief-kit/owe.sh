#!/usr/bin/env bash
# scripts/handover/chief-kit/owe.sh - the owed ledger: what a chief owes after a shift
# (a ticket to file, a proof to run, a ruling to ask for, a step a partial merge left owed), kept in <bucket>/owed.jsonl so
# the tick can age it, the HANDOFF carries it and the queue fold never moves it.
#
# Usage:
#   owe.sh add   --bucket <dir> --chief <name> --kind ticket|proof|ruling|step --text <one line> [--key <KEY>]
#   owe.sh close --bucket <dir> --id <oN> --key <ticket key | sha | decision id>
#   owe.sh list  --bucket <dir> [--all]
#
# <bucket>/owed.jsonl is append-only, one JSON object per line:
#   add   {op:"add", id, ts, epoch, chief, kind, text, key?}
#   close {op:"close", ref:<id>, ts, epoch, chief, key}
# A close appends a row; no row is ever rewritten. `add` prints the new id (o1, o2, ...).
# `list` prints each open row as TAB-separated id, kind, epoch, key, chief, text (a tab or
# newline in the text becomes a space); --all adds the closed rows, the key being the closing
# one. OWE_NOW_EPOCH replaces the clock (tests).
#
# Exit codes: 0 done, 1 close of an unknown or already closed id, 2 usage or a refused value,
# 3 the bucket directory is absent, 4 the ledger is unreadable or cannot be opened for append.
# Without flock (macOS) the ledger is locked by with_lock (scripts/lib/prim.sh) on <bucket>/owed.jsonl.lock,
# removed on release; a lock left by a killed run makes owe.sh exit 1 with a with_lock message until removed.
#
# Platform guard: bash and jq; flock when present.
set -u

usage() {
    echo "usage: owe.sh add --bucket <dir> --chief <name> --kind ticket|proof|ruling|step --text <text> [--key <KEY>]" >&2
    echo "       owe.sh close --bucket <dir> --id <oN> --key <key|sha|decision id>" >&2
    echo "       owe.sh list --bucket <dir> [--all]" >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
OWE_ARGV=("$@")
CMD="$1"; shift
BUCKET=""; CHIEF=""; KIND=""; TEXT=""; KEY=""; ID=""; ALL=0; HAVE_TEXT=0; HAVE_KEY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bucket) [ "$#" -ge 2 ] || usage; BUCKET="$2"; shift 2 ;;
        --chief) [ "$#" -ge 2 ] || usage; CHIEF="$2"; shift 2 ;;
        --kind) [ "$#" -ge 2 ] || usage; KIND="$2"; shift 2 ;;
        --text) [ "$#" -ge 2 ] || usage; TEXT="$2"; HAVE_TEXT=1; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; KEY="$2"; HAVE_KEY=1; shift 2 ;;
        --id) [ "$#" -ge 2 ] || usage; ID="$2"; shift 2 ;;
        --all) ALL=1; shift ;;
        *) usage ;;
    esac
done

[ -n "$BUCKET" ] || usage
[ -d "$BUCKET" ] || { echo "owe: bucket directory '$BUCKET' does not exist" >&2; exit 3; }
F="$BUCKET/owed.jsonl"
# shellcheck source=../../lib/prim.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../../lib/prim.sh" || { echo "owe: cannot load primitives" >&2; exit 4; }

NOW="${OWE_NOW_EPOCH:-}"
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s)" ;; esac

lock_ledger() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$F" || exit 4
        flock 9 || exit 4  # prim-ok: flock on the ledger itself leaves no lock file in the state bucket; with_lock below is the fallback
        return 0
    fi
    [ -z "${OWE_LEDGER_LOCKED:-}" ] || return 0
    OWE_LEDGER_LOCKED=1 with_lock "$F.lock" bash "$0" "${OWE_ARGV[@]}"
    exit "$?"
}

ledger_ok() { [ ! -s "$F" ] || jq -e -s 'all(.[]; type == "object" and (.op == "add" or .op == "close"))' "$F" >/dev/null 2>&1; }

case "$CMD" in
    add)
        [ -n "$CHIEF" ] || { echo "owe: add needs --chief" >&2; exit 2; }
        case "$CHIEF" in *$'\t'*|*$'\n'*|*$'\037'*) echo "owe: --chief must not hold a tab, newline or unit separator" >&2; exit 2 ;; esac
        case "$KIND" in ticket|proof|ruling|step) ;; *) echo "owe: --kind must be ticket, proof, ruling or step" >&2; exit 2 ;; esac
        [ "$HAVE_TEXT" -eq 1 ] && [ -n "$TEXT" ] || { echo "owe: add needs a non-empty --text" >&2; exit 2; }
        case "$TEXT" in *$'\n'*|*$'\037'*) echo "owe: --text must be one line with no unit separator" >&2; exit 2 ;; esac
        if [ "$HAVE_KEY" -eq 1 ]; then
            case "$KEY" in ''|*[[:space:]]*|*$'\037'*) echo "owe: --key must be one word" >&2; exit 2 ;; esac
        fi
        lock_ledger
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        n=1
        [ ! -s "$F" ] || n=$(( $(jq -s '[.[] | select(.op == "add")] | length' "$F") + 1 ))
        row="$(jq -cn --arg id "o$n" --argjson e "$NOW" --arg chief "$CHIEF" --arg kind "$KIND" --arg text "$TEXT" --arg key "$KEY" \
            '{op: "add", id: $id, ts: ($e | todate), epoch: $e, chief: $chief, kind: $kind, text: $text} + (if $key == "" then {} else {key: $key} end)')" || exit 4
        printf '%s\n' "$row" >> "$F" || exit 4
        printf 'o%s\n' "$n"
        ;;
    close)
        [ -n "$ID" ] || usage
        case "$KEY" in ''|*[[:space:]]*|*$'\037'*) echo "owe: close needs --key (a ticket key, sha or decision id), one word" >&2; exit 2 ;; esac
        [ ! -e "$F" ] || lock_ledger
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        [ -s "$F" ] || { echo "owe: no open row '$ID'" >&2; exit 1; }
        open="$(jq -s --arg id "$ID" '([.[] | select(.op == "close") | .ref]) as $c | [.[] | select(.op == "add" and .id == $id and ($c | index($id) | not))] | length' "$F")"
        [ "$open" = 1 ] || { echo "owe: no open row '$ID'" >&2; exit 1; }
        row="$(jq -cn --arg ref "$ID" --argjson e "$NOW" --arg chief "${CHIEF:-}" --arg key "$KEY" \
            '{op: "close", ref: $ref, ts: ($e | todate), epoch: $e, chief: $chief, key: $key}')" || exit 4
        printf '%s\n' "$row" >> "$F" || exit 4
        ;;
    list)
        [ -s "$F" ] || exit 0
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        jq -rs --argjson all "$ALL" '
            (reduce (.[] | select(.op == "close")) as $c ({}; .[$c.ref] = $c.key)) as $closed
            | .[] | select(.op == "add")
            | select($all == 1 or ($closed[.id] == null))
            | [.id, .kind, .epoch, (if $closed[.id] != null then $closed[.id] else (.key // "") end), .chief, (.text | gsub("[\t\n]"; " "))]
            | map(tostring) | join("\t")' "$F"
        ;;
    *) usage ;;
esac
