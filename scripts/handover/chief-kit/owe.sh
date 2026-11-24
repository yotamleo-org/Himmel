#!/usr/bin/env bash
# scripts/handover/chief-kit/owe.sh - the owed ledger: what a chief owes after a shift
# (a ticket to file, a proof to run, a ruling to ask for, a step a partial merge left owed), kept in <bucket>/owed.jsonl so
# the tick can age it, the HANDOFF carries it and the queue fold never moves it.
#
# Usage:
#   owe.sh add   --bucket <dir> --chief <name> --kind ticket|proof|ruling|step --text <one line> [--key <KEY>]
#   owe.sh close --bucket <dir> --id <oN> --key <ticket key | sha | decision id>
#   owe.sh list  --bucket <dir> [--all] [--json]
# add also accepts --identity <full sha256> and --metadata <allowlisted JSON>,
# or --metadata-stdin (one JSON value, at most 1 MiB, mutually exclusive).
# Replays return the original id, including closed actions; no row is reopened.
#
# <bucket>/owed.jsonl is append-only, one JSON object per line:
#   add   {op:"add", id, ts, epoch, chief, kind, text, key?}
#   close {op:"close", ref:<id>, ts, epoch, chief, key}
# A close appends a row; no row is ever rewritten. `add` prints the new id (o1, o2, ...).
# `list` prints each open row as TAB-separated id, kind, epoch, key, chief, text (a tab or
# newline in the text becomes a space); --all adds the closed rows, the key being the closing
# one. OWE_NOW_EPOCH replaces the clock and OWE_AFKSUDO_ROOT the / of the afk-sudo route probe (tests).
#
# Exit codes: 0 done, 1 close of an unknown or already closed id, 2 usage or a refused value,
# 3 the bucket directory is absent, 4 the ledger is unreadable, cannot be opened for append or cannot be flocked.
# Without flock (macOS) the ledger is locked by with_lock (scripts/lib/prim.sh) on <bucket>/owed.jsonl.lock,
# removed on release; a lock left by a killed run makes owe.sh exit 1 with a with_lock message until removed.
#
# Platform guard: bash, jq and python3 (fsync); flock when present.
set -u

usage() {
    echo "usage: owe.sh add --bucket <dir> --chief <name> --kind ticket|proof|ruling|step --text <text> [--key <KEY>] [--identity <sha256>] [--metadata <JSON> | --metadata-stdin]" >&2
    echo "       owe.sh close --bucket <dir> --id <oN> --key <key|sha|decision id>" >&2
    echo "       owe.sh list --bucket <dir> [--all] [--json]" >&2
    exit 2
}

[ "$#" -ge 1 ] || usage
OWE_ARGV=("$@")
CMD="$1"; shift
BUCKET=""; CHIEF=""; KIND=""; TEXT=""; KEY=""; ID=""; ALL=0; HAVE_TEXT=0; HAVE_KEY=0
IDENTITY=""; METADATA='{}'; JSON=0; METADATA_STDIN=0; HAVE_METADATA=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bucket) [ "$#" -ge 2 ] || usage; BUCKET="$2"; shift 2 ;;
        --chief) [ "$#" -ge 2 ] || usage; CHIEF="$2"; shift 2 ;;
        --kind) [ "$#" -ge 2 ] || usage; KIND="$2"; shift 2 ;;
        --text) [ "$#" -ge 2 ] || usage; TEXT="$2"; HAVE_TEXT=1; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; KEY="$2"; HAVE_KEY=1; shift 2 ;;
        --id) [ "$#" -ge 2 ] || usage; ID="$2"; shift 2 ;;
        --all) ALL=1; shift ;;
        --json) JSON=1; shift ;;
        --identity) [ "$#" -ge 2 ] || usage; IDENTITY="$2"; shift 2 ;;
        --metadata) [ "$#" -ge 2 ] || usage; METADATA="$2"; HAVE_METADATA=1; shift 2 ;;
        --metadata-stdin) [ "$METADATA_STDIN" -eq 0 ] || usage; METADATA_STDIN=1; shift ;;
        *) usage ;;
    esac
done
if [ "$METADATA_STDIN" -eq 1 ]; then
    { [ "$CMD" = add ] || [ "$CMD" = close ]; } && [ "$HAVE_METADATA" -eq 0 ] || usage
    if ! METADATA=$(python3 -c 'import json,sys
raw=sys.stdin.buffer.read(1048577)
if len(raw)>1048576: raise ValueError("metadata exceeds 1 MiB")
value=json.dumps(json.loads(raw), ensure_ascii=True, separators=(",",":"))
if len(value.encode())>1048576: raise ValueError("encoded metadata exceeds 1 MiB")
print(value)'); then
        echo 'owe: invalid or oversize metadata stdin' >&2
        exit 2
    fi
fi

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
# Keep the existing append/flock protocol; acknowledge only durable rows, including
# a retry after the append succeeded but its response or sync was lost.
persist() {
    python3 -c 'import os,sys
for p in sys.argv[1:]:
    d = os.open(p, os.O_RDONLY); os.fsync(d); os.close(d)' "$F" "$BUCKET" || exit 4
}

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
        if [ -n "$IDENTITY" ] && ! [[ $IDENTITY =~ ^[0-9a-f]{64}$ ]]; then
            echo "owe: --identity must be a full sha256" >&2; exit 2
        fi
        # Additive fields only: never let metadata replace ledger authority/keys.
        # Structured observations are data; their consumers still validate evidence.
        printf '%s' "$METADATA" | jq -e -s --arg kind "$KIND" '
              length == 1 and (.[0] | type == "object" and all(to_entries[];
                . as $e | if (["evidence_path","source_doc","source_label","next_action","wake","capability","source_id","actual_status"] | index($e.key)) then ($e.value | type == "string")
                elif $e.key == "event" then (["step-due","step-due-invalid","proof-wake","readiness-d24h","operator-digest"] | index($e.value)) != null
                elif $e.key == "due" then ($e.value | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
                elif (["issues","proof_rows"] | index($e.key)) then ($e.value | type == "array" and all(.[]; type == "string"))
                elif $e.key == "owed_refs" then ($e.value | type == "array" and all(.[]; type == "string" and test("^o[1-9][0-9]*$")))
                elif $e.key == "evidence_records" then ($e.value | type == "array" and all(.[];
                  type == "object" and (keys - ["path","sha256"] | length) == 0 and (.path | type == "string")
                  and (if has("sha256") then (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) else true end)))
                elif (["executed_shas","required_shas"] | index($e.key)) then ($e.value | type == "array" and all(.[]; type == "object" and (keys | sort) == ["basis","sha"] and (.basis == "main" or .basis == "station") and (.sha | type == "string" and test("^[0-9a-f]{7,40}$"))))
                elif $e.key == "observation_counts" then ($e.value | type == "object" and all(to_entries[];
                  (.key as $k | ["issues","proof_rows","executed_shas","required_shas","next_action","wake"] | index($k)) != null
                  and (.value | type == "object" and (keys | sort) == ["omitted","total","truncated_chars"]
                    and all(.[]; type == "number" and . >= 0 and . <= 9007199254740990 and floor == .)
                    and .omitted <= .total)))
                elif $e.key == "actor" then ($e.value == "chief" or ($kind != "proof" and (["operator","proof","worker"] | index($e.value)) != null))
                elif $e.key == "action" then ($e.value == "validate-proof" and $kind == "proof") or
                    ((["next-step","version-reconciliation","requirements-reconciliation"] | index($e.value)) != null and $kind == "step") or ($e.value == "notify" and $kind == "ruling")
                elif $e.key == "validation" then $e.value == "pending"
                elif $e.key == "recommendation" then (["CLOSE","KEEP","unknown"] | index($e.value)) != null
                elif $e.key == "binding" then (["matched","unknown","mismatch"] | index($e.value)) != null
                elif (["evidence_hash","requirements_digest","original_requirements_digest"] | index($e.key)) then ($e.value | type == "string" and test("^[0-9a-f]{64}$"))
                else false end))' >/dev/null 2>&1 || { echo "owe: refused metadata field or value" >&2; exit 2; }
        lock_ledger
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        if [ -n "$IDENTITY" ]; then
            existing=$(jq -r -s --arg identity "$IDENTITY" --arg key "$KEY" --arg kind "$KIND" \
                '[.[] | select(.op == "add" and .identity == $identity)] | if length == 0 then "" elif length == 1 and (.[0].key // "") == $key and .[0].kind == $kind then .[0].id else error("identity conflict") end' "$F") || exit 4
            if [ -n "$existing" ]; then persist; printf '%s\n' "$existing"; exit 0; fi
        fi
        route_ops=()
        if [ "$(printf '%s' "$METADATA" | jq -r '.actor // ""')" = operator ]; then
            read -r -a words <<< "$(printf '%s' "$TEXT" | sed 's/[][()`'"'"'",;:]/ ; /g')"
            for ((i = 0; i < ${#words[@]}; i++)); do
                [ "${words[i]}" = op-request ] || continue
                k=$((i + 1))
                while [ "$k" -lt "${#words[@]}" ]; do
                    case "${words[k]}" in
                        --) k=$((k + 1)); break ;;
                        --session|--ticket) k=$((k + 2)) ;;
                        -*) k=$((k + 1)) ;;
                        *) break ;;
                    esac
                done
                cand="${words[k]:-}"; after="${words[k+1]:-}"
                if [[ $cand =~ ^[a-z][a-z0-9-]{0,30}$ ]] && { [ -z "$after" ] || [ "$after" = ';' ] || [[ $after == *=* ]]; }; then route_ops+=("$cand"); fi
            done
        fi
        if [ "${#route_ops[@]}" -gt 0 ]; then
            cfg="${OWE_AFKSUDO_ROOT:-}/etc/himmel/afk-sudo.json"
            ops="${OWE_AFKSUDO_ROOT:-}/usr/local/libexec/himmel/ops"
            enable="run sudoedit /etc/himmel/afk-sudo.json, set helper_update.repo, helper_update.checkout and helper_update.enabled (docs/internals/afk-sudo.md), then send /op helper-update commit=<sha> to install the op"
            if ! cfgv=$(jq -c '[(.ops.enabled == true), (.helper_update.enabled == true)]' "$cfg") || [ -z "$cfgv" ]; then
                echo "owe: afk-sudo route unknown: cannot read $cfg; the owed row for op '${route_ops[0]}' was not filed" >&2
                exit 2
            fi
            if [ "$cfgv" = '[false,false]' ] || [ "$cfgv" = '[false,true]' ]; then
                echo "owe: ops is not enabled in the config; the owed row for op '${route_ops[0]}' was not filed; to unblock: set ops.enabled to true with sudoedit /etc/himmel/afk-sudo.json" >&2
                exit 2
            fi
            for op in "${route_ops[@]}"; do
                if [ "$op" = helper-update ] && [ "$cfgv" = '[true,false]' ]; then
                    echo "owe: helper_update is not enabled in the config; op 'helper-update' cannot run, so no approval code can reach the operator; the row was not filed; to unblock: $enable" >&2
                    exit 2
                fi
                if [ ! -e "$ops/$op.sh" ]; then
                    if [ "$cfgv" = '[true,false]' ]; then
                        echo "owe: helper_update is not enabled in the config; op '$op' is not installed, so no approval code can reach the operator; the row was not filed; to unblock: $enable" >&2
                    else
                        echo "owe: op '$op' is not installed under $ops; the row was not filed; to unblock: send /op helper-update commit=<sha> for the main sha that ships it" >&2
                    fi
                    exit 2
                fi
            done
        fi
        n=1
        [ ! -s "$F" ] || n=$(( $(jq -s '[.[] | select(.op == "add")] | length' "$F") + 1 ))
        row="$(printf '%s' "$METADATA" | jq -c --arg id "o$n" --argjson e "$NOW" --arg chief "$CHIEF" --arg kind "$KIND" --arg text "$TEXT" --arg key "$KEY" --arg identity "$IDENTITY" \
            '{op: "add", id: $id, ts: ($e | todate), epoch: $e, chief: $chief, kind: $kind, text: $text} + (if $key == "" then {} else {key: $key} end) + (if $identity == "" then {} else {identity: $identity} end) + .')" || exit 4
        printf '%s\n' "$row" >> "$F" || exit 4
        persist
        printf 'o%s\n' "$n"
        ;;
    close)
        printf '%s' "$METADATA" | jq -e '
            type == "object" and (keys - ["outcome"] | length) == 0 and
            (if has("outcome") then .outcome | type == "object" and
              (keys | sort) == ["decision_hash","decision_json","identity","rationale","status","verdict","version_pending"] and
              (.identity | test("^[0-9a-f]{64}$")) and (.decision_hash | test("^[0-9a-f]{64}$")) and
              (.verdict == "CLOSE" or .verdict == "KEEP") and (.status | type == "string") and
              (.rationale | type == "string") and (.decision_json | type == "string") and (.version_pending | type == "boolean") else true end)
        ' >/dev/null 2>&1 || { echo 'owe: refused close metadata' >&2; exit 2; }
        [ -n "$ID" ] || usage
        case "$KEY" in ''|*[[:space:]]*|*$'\037'*) echo "owe: close needs --key (a ticket key, sha or decision id), one word" >&2; exit 2 ;; esac
        [ ! -e "$F" ] || lock_ledger
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        [ -s "$F" ] || { echo "owe: no open row '$ID'" >&2; exit 1; }
        open="$(jq -s --arg id "$ID" '([.[] | select(.op == "close") | .ref]) as $c | [.[] | select(.op == "add" and .id == $id and ($c | index($id) | not))] | length' "$F")"
        [ "$open" = 1 ] || { echo "owe: no open row '$ID'" >&2; exit 1; }
        row="$(printf '%s' "$METADATA" | jq -c --arg ref "$ID" --argjson e "$NOW" --arg chief "${CHIEF:-}" --arg key "$KEY" \
            '{op: "close", ref: $ref, ts: ($e | todate), epoch: $e, chief: $chief, key: $key} + .')" || exit 4
        printf '%s\n' "$row" >> "$F" || exit 4
        persist
        ;;
    list)
        if [ ! -e "$F" ] && [ ! -L "$F" ]; then
            if [ "$JSON" -eq 1 ]; then echo '[]'; fi
            exit 0
        fi
        [ -f "$F" ] && [ -r "$F" ] || { echo "owe: $F is unreadable" >&2; exit 4; }
        ledger_ok || { echo "owe: $F is unreadable" >&2; exit 4; }
        if [ "$JSON" -eq 1 ]; then
            jq -s --argjson all "$ALL" '
                (reduce (.[] | select(.op == "close")) as $c ({}; .[$c.ref] = $c)) as $closed
                | [.[] | select(.op == "add") | .id as $id | . + {closed: ($closed | has($id))}
                   + (if $closed[$id].outcome then {outcome: $closed[$id].outcome} else {} end)
                   | select($all == 1 or (.closed | not))]' "$F"
            exit $?
        fi
        jq -rs --argjson all "$ALL" '
            (reduce (.[] | select(.op == "close")) as $c ({}; .[$c.ref] = $c.key)) as $closed
            | .[] | select(.op == "add")
            | select($all == 1 or ($closed[.id] == null))
            | [.id, .kind, .epoch, (if $closed[.id] != null then $closed[.id] else (.key // "") end), .chief, (.text | gsub("[\t\n]"; " "))]
            | map(tostring) | join("\t")' "$F"
        ;;
    *) usage ;;
esac
