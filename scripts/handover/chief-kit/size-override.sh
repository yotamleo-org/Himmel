#!/usr/bin/env bash
# scripts/handover/chief-kit/size-override.sh - the monitored escape from the brief
# size gate (pr_size_gate): the escalation ledger gen-briefs.py writes,
# the chief-only signed size-override record it accepts, and the pending read the
# waiter turns into `WAKE size`.
#
# Usage:
#   size-override.sh note    refuse|bulk <KEY> <label> --files <n> [--trust yes|no] [--detail <text>] [--root <dir>]
#   size-override.sh record  <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]
#   size-override.sh check   <KEY> <label> --files <n> [--trust yes|no] [--root <dir>]
#   size-override.sh pending --since <n> [--root <dir>]
#
# One tab-separated ledger, <handover root>/.locks/size-escalate.tsv (the root: --root, else the
# GO root the anchor's .env configures, as go.sh resolves it):
#   SIZE-ESCALATE <epoch> <refuse|bulk> <KEY> <label> <files> <trust> <detail>
#   SIZE-OVERRIDE <epoch> <KEY> <label> <files> <lines> <trust> <source> <reason> <mac>
# The mac is go_msg_mac himmel-size-override-v1 over KEY|label|files|lines|trust|source|reason
# (the GO key), so a hand-written or edited row buys nothing.
#
# note    appends one SIZE-ESCALATE row: a brief the gate refused, or one that used bulk: mechanical.
# record  appends one signed SIZE-OVERRIDE row. Refuses a chief-spawned worker or relay (exit 3),
#         and a case the operator owns (exit 4).
# check   exit 0 when a signed override for this KEY, label and file count exists and the case is
#         the chief's to decide; exit 4 when the operator owns it (see below), whatever rows exist;
#         exit 1 when there is no valid override.
# pending always prints `total=<n>` (the SIZE-ESCALATE rows), then the rows after the first <n>;
#         exit 0 when there are new rows, 1 when not.
#
# The operator owns a trust-path brief over the soft file band, a brief past the CodeRabbit file
# cap, and one past the hard line max (all read from scripts/ci/pr-size-bands.tsv). The chief
# alone never overrides these.
#
# Exit codes: 0 done, 1 check found no override / pending found nothing, 2 usage or cannot
# evaluate, 3 record from a chief worker or relay, 4 operator-owned.
#
# Platform guard: POSIX bash 3.2+.
set -u

usage() {
    echo "usage: size-override.sh note refuse|bulk <KEY> <label> --files <n> [--trust yes|no] [--detail <text>] [--root <dir>]" >&2
    echo "       size-override.sh record <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]" >&2
    echo "       size-override.sh check <KEY> <label> --files <n> [--trust yes|no] [--root <dir>]" >&2
    echo "       size-override.sh pending --since <n> [--root <dir>]" >&2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../../.." && pwd)"
BANDS="$ANCHOR/scripts/ci/pr-size-bands.tsv"
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
KIND="" KEY="" LABEL="" FILES="" LINES=0 TRUST=no DETAIL="" REASON="" ROOT="" SINCE=""
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
        *) usage; exit 2 ;;
    esac
    shift 2 2>/dev/null || { usage; exit 2; }
done

if [ "$VERB" != pending ]; then
    printf '%s' "$KEY" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' || { echo "size-override: <KEY> must be a Jira key like PROJ-1 (got '$KEY')" >&2; exit 2; }
    printf '%s' "$LABEL" | grep -qE '^[A-Za-z0-9._-]+$' || { echo "size-override: <label> must be a worker label like N921 (got '$LABEL')" >&2; exit 2; }
    case "$FILES" in ''|*[!0123456789]*) echo "size-override: --files needs a whole number" >&2; exit 2 ;; esac
    case "$LINES" in ''|*[!0123456789]*) echo "size-override: --lines needs a whole number" >&2; exit 2 ;; esac
    case "$TRUST" in yes|no) ;; *) echo "size-override: --trust is yes or no" >&2; exit 2 ;; esac
fi
[ "$VERB" != note ] || case "$KIND" in refuse|bulk) ;; *) usage; exit 2 ;; esac
[ "$VERB" != pending ] || case "$SINCE" in ''|*[!0123456789]*) usage; exit 2 ;; esac

if [ -z "$ROOT" ]; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || { echo "size-override: cannot resolve the handover root; pass --root" >&2; exit 2; }  # swallow-ok: the failure is reported and exits 2 on this line
fi
LEDGER="$ROOT/.locks/size-escalate.tsv"

# band <row> <column> - one number from pr-size-bands.tsv (a "-" or a missing row is empty).
band() { awk -F'\t' -v r="$1" -v c="$2" '$1 == r { print $c; exit }' "$BANDS" 2>/dev/null; }

# operator_owned <files> <lines> <trust> - prints why, and succeeds, when the operator owns the case.
operator_owned() {
    local soft cap hardl
    soft=$(band soft 3); cap=$(band coderabbit 3); hardl=$(band hard 2)
    case "$soft$cap$hardl" in *[!0123456789]*|'') echo "size-override: cannot read the size bands from $BANDS" >&2; exit 2 ;; esac
    if [ "$1" -gt "$cap" ]; then echo "$1 files is past the $cap-file CodeRabbit cap"; return 0; fi
    if [ "$2" -gt "$hardl" ]; then echo "$2 lines is past the $hardl-line hard max"; return 0; fi
    if [ "$3" = yes ] && [ "$1" -gt "$soft" ]; then echo "a trust-path brief over the $soft-file soft band ($1 files)"; return 0; fi
    return 1
}

clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
override_mac() { go_msg_mac himmel-size-override-v1 "$KEY|$LABEL|$FILES|$LINES|$TRUST|$1|$2"; }
append() {
    if ! { mkdir -p "$ROOT/.locks" 2>/dev/null && printf '%s\n' "$1" >> "$LEDGER"; }; then
        echo "size-override: cannot append to $LEDGER" >&2; exit 2
    fi
}

case "$VERB" in
note)
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
    if why=$(operator_owned "$FILES" "$LINES" "$TRUST"); then
        echo "size-override: refused - $why; this routes to the operator, not the chief alone" >&2
        exit 4
    fi
    SRC="console:$(printf '%s' "${CHIEF_SESSION_NAME:-${USER:-unknown}@$(hostname 2>/dev/null || uname -n)}" | tr -c 'A-Za-z0-9._@-' '_')"  # swallow-ok: hostname is only a label fallback
    MAC=$(override_mac "$SRC" "$REASON") || { echo "size-override: cannot sign the row (GO key at $(go_key_file) unreadable)" >&2; exit 2; }
    append "$(printf 'SIZE-OVERRIDE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$KEY" "$LABEL" "$FILES" "$LINES" "$TRUST" "$SRC" "$REASON" "$MAC")"
    echo "size-override: recorded for $KEY $LABEL ($FILES files) by $SRC"
    ;;
check)
    # the operator's cases come first: no row, signed or not, lifts them
    if why=$(operator_owned "$FILES" 0 "$TRUST"); then
        echo "size-override: $why; this routes to the operator, a chief override does not apply" >&2
        exit 4
    fi
    [ -f "$LEDGER" ] || exit 1
    TAB=$(printf '\t')
    row=$(awk -F'\t' -v k="$KEY" -v l="$LABEL" -v f="$FILES" '$1 == "SIZE-OVERRIDE" && $3 == k && $4 == l && $5 == f { r = $0 } END { print r }' "$LEDGER")
    [ -n "$row" ] || exit 1
    IFS="$TAB" read -r _ _ _ _ _ rlines rtrust rsrc rreason rmac <<EOF
$row
EOF
    LINES="$rlines"; TRUST="$rtrust"
    case "$rsrc" in console:*) ;; *) exit 1 ;; esac
    want=$(override_mac "$rsrc" "$rreason") || { echo "size-override: cannot verify the row (GO key unreadable)" >&2; exit 2; }
    [ "$want" = "$rmac" ] || { echo "size-override: the override row for $KEY $LABEL carries no valid mac" >&2; exit 1; }
    if why=$(operator_owned "$FILES" "$rlines" "$rtrust"); then
        echo "size-override: $why; this routes to the operator, a chief override does not apply" >&2
        exit 4
    fi
    echo "size-override: $KEY $LABEL ($FILES files) kept whole by $rsrc: $rreason"
    ;;
pending)
    total=0
    [ ! -f "$LEDGER" ] || total=$(grep -c '^SIZE-ESCALATE'"$(printf '\t')" "$LEDGER" 2>/dev/null)  # swallow-ok: grep -c prints 0 and exits 1 for none
    echo "total=${total:-0}"
    [ "${total:-0}" -gt "$SINCE" ] || exit 1
    grep '^SIZE-ESCALATE'"$(printf '\t')" "$LEDGER" | tail -n +"$((10#$SINCE + 1))"
    ;;
esac
