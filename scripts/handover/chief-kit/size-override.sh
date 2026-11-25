#!/usr/bin/env bash
# scripts/handover/chief-kit/size-override.sh - the size ledger: the SIZE-ESCALATE rows gen-briefs.py and
# worker-pr-open.sh write when a count passes a band, the chief-only signed size-override record, and the pending
# read the waiter turns into `WAKE size`.
#
# Usage:
#   size-override.sh note    refuse|bulk|estimate|real <KEY> <label> --files <n> [--trust yes|no|unknown] [--band soft|hard|coderabbit] [--ref <branch>] [--detail <text>] [--root <dir>]
#   size-override.sh record  <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]
#   size-override.sh check   <KEY> <label> --files <n> [--trust yes|no] [--root <dir>]
#   size-override.sh pending --since <n> [--root <dir>]
#
# One tab-separated ledger, <handover root>/.locks/size-escalate.tsv (the root: --root, else the
# GO root the anchor's .env configures, as go.sh resolves it):
#   SIZE-ESCALATE <epoch> <refuse|bulk|estimate|real> <KEY> <label> <files> <trust> <detail>
#   SIZE-OVERRIDE <epoch> <KEY> <label> <files> <lines> <trust> <source> <reason> <mac>
# The mac is go_msg_mac himmel-size-override-v1 over KEY|label|files|lines|trust|source|reason
# (the GO key), so a hand-written or edited row buys nothing.
#
# note    appends one SIZE-ESCALATE row: a brief estimate past a band (estimate), a bulk: mechanical brief (bulk),
#         the real count of an opened PR (real), or an old refusal (refuse). Every kind but refuse starts the detail
#         `band=<b> ref=<branch>` (the band may be empty), and a call whose kind, key, label, band and ref equal an earlier row's
#         appends nothing, so a re-run or a push past the same band wakes the chief once; a higher band, or another branch,
#         is a new row.
# record  appends one signed SIZE-OVERRIDE row for any case the chief keeps whole. Refuses a chief-spawned worker or relay (exit 3).
# check   exit 0 when a signed override for this KEY, label and file count exists, else exit 1.
# pending always prints `total=<n>` (the SIZE-ESCALATE rows), then the rows after the first <n>;
#         exit 0 when there are new rows, 1 when not.
#
# Exit codes: 0 done, 1 check found no override / pending found nothing, 2 usage or cannot evaluate,
# 3 record from a chief worker or relay.
#
# Platform guard: POSIX bash 3.2+.
set -u

usage() {
    echo "usage: size-override.sh note refuse|bulk|estimate|real <KEY> <label> --files <n> [--trust yes|no|unknown] [--band soft|hard|coderabbit] [--ref <branch>] [--detail <text>] [--root <dir>]" >&2
    echo "       size-override.sh record <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]" >&2
    echo "       size-override.sh check <KEY> <label> --files <n> [--trust yes|no] [--root <dir>]" >&2
    echo "       size-override.sh pending --since <n> [--root <dir>]" >&2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F go_msg_mac >/dev/null 2>&1 \
        || ! declare -F chief_worker >/dev/null 2>&1; then
    echo "size-override: cannot load scripts/lib/go-gate.sh" >&2
    exit 2
fi
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh" 2>/dev/null || { echo "size-override: cannot load scripts/lib/handover-path.sh" >&2; exit 2; }

VERB="${1:-}"; shift 2>/dev/null || true
KIND="" KEY="" LABEL="" FILES="" LINES=0 TRUST=no DETAIL="" REASON="" ROOT="" SINCE="" BAND="" REF=""
case "$VERB" in
    note) KIND="${1:-}"; shift 2>/dev/null || true ;;
    record|check|pending) ;;
    *) usage; exit 2 ;;
esac
if [ "$VERB" != pending ]; then
    KEY="${1:-}"; LABEL="${2:-}"; shift 2 2>/dev/null || { usage; exit 2; }
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --files) FILES="${2:-}" ;;
        --lines) LINES="${2:-}" ;;
        --trust) TRUST="${2:-}" ;;
        --detail) DETAIL="${2:-}" ;;
        --reason) REASON="${2:-}" ;;
        --root) ROOT="${2:-}" ;;
        --since) SINCE="${2:-}" ;;
        --band) BAND="${2:-}" ;;
        --ref) REF="${2:-}" ;;
        *) usage; exit 2 ;;
    esac
    shift 2 2>/dev/null || { usage; exit 2; }
done

if [ "$VERB" != pending ]; then
    printf '%s' "$KEY" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' || { echo "size-override: <KEY> must be a Jira key like PROJ-1 (got '$KEY')" >&2; exit 2; }
    printf '%s' "$LABEL" | grep -qE '^[A-Za-z0-9._-]+$' || { echo "size-override: <label> must be a worker label like N921 (got '$LABEL')" >&2; exit 2; }
    case "$FILES" in ''|*[!0123456789]*) echo "size-override: --files needs a whole number" >&2; exit 2 ;; esac
    case "$LINES" in ''|*[!0123456789]*) echo "size-override: --lines needs a whole number" >&2; exit 2 ;; esac
    if [ "$VERB" = note ]; then
        case "$TRUST" in yes|no|unknown) ;; *) echo "size-override: --trust is yes, no or unknown" >&2; exit 2 ;; esac
    else
        case "$TRUST" in yes|no) ;; *) echo "size-override: --trust is yes or no" >&2; exit 2 ;; esac
    fi
fi
if [ "$VERB" = note ]; then
    case "$KIND" in refuse|bulk|estimate|real) ;; *) usage; exit 2 ;; esac
    case "$BAND" in ''|soft|hard|coderabbit) ;; *) echo "size-override: --band is soft, hard or coderabbit (got '$BAND')" >&2; exit 2 ;; esac
    case "$REF" in *[!A-Za-z0-9._/+-]*) false ;; *) true ;; esac || { echo "size-override: --ref is a branch name (got '$REF')" >&2; exit 2; }
fi
[ "$VERB" != pending ] || case "$SINCE" in ''|*[!0123456789]*) usage; exit 2 ;; esac

if [ -z "$ROOT" ]; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || { echo "size-override: cannot resolve the handover root; pass --root" >&2; exit 2; }  # swallow-ok: the failure is reported and exits 2 on this line
fi
LEDGER="$ROOT/.locks/size-escalate.tsv"

TAB=$(printf '\t')
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
override_mac() { go_msg_mac himmel-size-override-v1 "$KEY|$LABEL|$FILES|$LINES|$TRUST|$1|$2"; }
append() {
    if ! { mkdir -p "$ROOT/.locks" 2>/dev/null && printf '%s\n' "$1" >> "$LEDGER"; }; then
        echo "size-override: cannot append to $LEDGER" >&2; exit 2
    fi
}

case "$VERB" in
note)
    mkdir -p "$ROOT/.locks" 2>/dev/null
    tries=0 held=0
    while :; do
        if mkdir "$LEDGER.lk" 2>/dev/null; then held=1; break; fi
        [ -w "$ROOT/.locks" ] || break
        tries=$((tries + 1))
        [ "$tries" -le 50 ] || break
        sleep 0.1
    done
    [ "$held" -eq 0 ] || trap 'rmdir "$LEDGER.lk" 2>/dev/null' EXIT
    if [ -n "$BAND" ] || [ "$KIND" != refuse ]; then
        pfx="band=$BAND ref=$REF"
        if [ -f "$LEDGER" ] && awk -F'\t' -v k="$KIND" -v key="$KEY" -v l="$LABEL" -v p="$pfx " \
                '$1 == "SIZE-ESCALATE" && $3 == k && $4 == key && $5 == l && index($8, p) == 1 { f = 1 } END { exit f ? 0 : 1 }' "$LEDGER"; then
            exit 0
        fi
        DETAIL="$pfx $DETAIL"
    fi
    append "$(printf 'SIZE-ESCALATE\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$KIND" "$KEY" "$LABEL" "$FILES" "$TRUST" "$(clean "$DETAIL")")"
    ;;
record)
    if chief_worker; then
        echo "size-override: refusing - this is a chief-spawned worker; only the chief signs a size override" >&2
        exit 3
    fi
    case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) ;;
        *) echo "size-override: refusing - this is a chief relay; only the chief signs a size override" >&2; exit 3 ;;
    esac
    REASON=$(clean "$REASON")
    [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || { echo "size-override: --reason is required (why keep the brief whole)" >&2; exit 2; }
    SRC="console:$(printf '%s' "${CHIEF_SESSION_NAME:-${USER:-unknown}@$(hostname 2>/dev/null || uname -n)}" | tr -c 'A-Za-z0-9._@-' '_')"  # swallow-ok: hostname is only a label fallback
    MAC=$(override_mac "$SRC" "$REASON") || { echo "size-override: cannot sign the row (GO key at $(go_key_file) unreadable)" >&2; exit 2; }
    append "$(printf 'SIZE-OVERRIDE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$KEY" "$LABEL" "$FILES" "$LINES" "$TRUST" "$SRC" "$REASON" "$MAC")"
    echo "size-override: recorded for $KEY $LABEL ($FILES files) by $SRC"
    ;;
check)
    [ -f "$LEDGER" ] || exit 1
    row=$(awk -F'\t' -v k="$KEY" -v l="$LABEL" -v f="$FILES" '$1 == "SIZE-OVERRIDE" && $3 == k && $4 == l && $5 == f { r = $0 } END { print r }' "$LEDGER")
    [ -n "$row" ] || exit 1
    IFS="$TAB" read -r _ _ _ _ _ rlines rtrust rsrc rreason rmac <<EOF
$row
EOF
    LINES="$rlines"; TRUST="$rtrust"
    case "$rsrc" in console:*) ;; *) exit 1 ;; esac
    want=$(override_mac "$rsrc" "$rreason") || { echo "size-override: cannot verify the row (GO key unreadable)" >&2; exit 2; }
    [ "$want" = "$rmac" ] || { echo "size-override: the override row for $KEY $LABEL carries no valid mac" >&2; exit 1; }
    echo "size-override: $KEY $LABEL ($FILES files) kept whole by $rsrc: $rreason"
    ;;
pending)
    # one snapshot of the ledger, so the total and the rows printed always agree under a concurrent append
    rows="" total=0
    [ ! -f "$LEDGER" ] || rows=$(grep '^SIZE-ESCALATE'"$(printf '\t')" "$LEDGER" 2>/dev/null)  # swallow-ok: grep exits 1 when there are no rows
    [ -z "$rows" ] || total=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    echo "total=$total"
    [ "$total" -gt "$SINCE" ] || exit 1
    printf '%s\n' "$rows" | tail -n +"$((10#$SINCE + 1))"
    ;;
esac
