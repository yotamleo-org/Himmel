#!/usr/bin/env bash
# scripts/handover/chief-kit/size-override.sh - the monitored escape from the brief
# size gate (pr_size_gate): the escalation ledger gen-briefs.py writes,
# the chief-only signed size-override record it accepts, and the pending read the
# waiter turns into `WAKE size`.
#
# Usage:
#   size-override.sh note    refuse|bulk <KEY> <label> --files <n> [--trust yes|no] [--detail <text>] [--root <dir>]
#   size-override.sh record  <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]
#   size-override.sh check   <KEY> <label> --files <n> [--trust yes|no] [--scope <hex>] [--root <dir>]
#   size-override.sh operator <KEY> <label> --files <n> --scope <hex> --reason <word>
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
#         exit 1 when there is no valid override. For a trust-path brief of 21 to 300 files, --trust yes and
#         --scope <32 hex> (the digest gen-briefs prints), it exits 0 on the operator's approval: the root-owned file
#         <SIZE_APPROVALS>/<KEY>.<label>.<files>.<scope> the size-approval station op writes after the operator's
#         NONCE CODE (scripts/station-ops/size-approval.sh), unexpired, in root directories nobody else can write.
# operator files that op through the afk-sudo helper (the terminal route; Telegram is `/op size-approval ...`), then
#         on a terminal runs `himmelctl approve <id>` for the nonce and code. A chief may run it: filing is harmless,
#         only the operator's code approves.
# pending always prints `total=<n>` (the SIZE-ESCALATE rows), then the rows after the first <n>;
#         exit 0 when there are new rows, 1 when not.
#
# The operator owns a trust-path brief over the soft file band, a brief past the CodeRabbit file
# cap, and one past the hard line max (all read from scripts/ci/pr-size-bands.tsv). The chief
# alone never overrides these.
#
# Exit codes: 0 done, 1 check found no override / pending found nothing, 2 usage or cannot
# evaluate (operator: the helper refused a param), 3 record from a chief worker or relay, 4 operator-owned or past
# the file cap, 5 operator: the helper is absent or refused, 75 operator: the request is pending its approval.
#
# Platform guard: POSIX bash 3.2+.
set -u

usage() {
    echo "usage: size-override.sh note refuse|bulk <KEY> <label> --files <n> [--trust yes|no] [--detail <text>] [--root <dir>]" >&2
    echo "       size-override.sh record <KEY> <label> --files <n> --reason <text> [--lines <n>] [--trust yes|no] [--root <dir>]" >&2
    echo "       size-override.sh check <KEY> <label> --files <n> [--trust yes|no] [--scope <hex>] [--root <dir>]" >&2
    echo "       size-override.sh operator <KEY> <label> --files <n> --scope <hex> --reason <word>" >&2
    echo "       size-override.sh pending --since <n> [--root <dir>]" >&2
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../../.." && pwd)"
BANDS="$ANCHOR/scripts/ci/pr-size-bands.tsv"
# The operator's approvals, the uid that must own them and the root helper the operator verb files through: constants,
# never read from the environment, so a same-uid session cannot point the reader elsewhere. The suite runs a copy of this
# script with these three lines rewritten.
SIZE_APPROVALS=/var/lib/himmel/size-approvals
SIZE_APPROVAL_UID=0
AFK_HELPER=/usr/local/libexec/himmel/afk-sudo
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
KIND="" KEY="" LABEL="" FILES="" LINES=0 TRUST=no DETAIL="" REASON="" ROOT="" SINCE="" SCOPE=""
case "$VERB" in
    note) KIND="${1:-}"; shift 2>/dev/null || true ;;
    record|check|pending|operator) ;;
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
        --scope) SCOPE="${2:-}" ;;
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
    [ -z "$SCOPE" ] || printf '%s' "$SCOPE" | grep -qE '^[0-9a-f]{32}$' || { echo "size-override: --scope is the 32-hex file-list digest gen-briefs prints (got '$SCOPE')" >&2; exit 2; }
fi
[ "$VERB" != note ] || case "$KIND" in refuse|bulk) ;; *) usage; exit 2 ;; esac
[ "$VERB" != pending ] || case "$SINCE" in ''|*[!0123456789]*) usage; exit 2 ;; esac

if [ -z "$ROOT" ] && [ "$VERB" != operator ]; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || { echo "size-override: cannot resolve the handover root; pass --root" >&2; exit 2; }  # swallow-ok: the failure is reported and exits 2 on this line
fi
LEDGER="$ROOT/.locks/size-escalate.tsv"

# band <row> <column> - one number from pr-size-bands.tsv (a "-" or a missing row is empty).
band() { awk -F'\t' -v r="$1" -v c="$2" '$1 == r { print $c; exit }' "$BANDS" 2>/dev/null; }

# The bands are read here, at top level, so an unreadable file exits 2 before anything is signed or read:
# an exit inside operator_owned's command substitution would only end the subshell and read as "not operator-owned".
if [ "$VERB" = record ] || [ "$VERB" = check ] || [ "$VERB" = operator ]; then
    SOFT=$(band soft 3); CAP=$(band coderabbit 3); HARDL=$(band hard 2)
    if [ -z "$SOFT" ] || [ -z "$CAP" ] || [ -z "$HARDL" ]; then
        echo "size-override: cannot read the size bands from $BANDS" >&2; exit 2
    fi
    case "$SOFT$CAP$HARDL" in *[!0123456789]*) echo "size-override: cannot read the size bands from $BANDS" >&2; exit 2 ;; esac
fi

# operator_owned <files> <lines> <trust> - prints why, and succeeds, when the operator owns the case.
operator_owned() {
    if [ "$1" -gt "$CAP" ]; then echo "$1 files is past the $CAP-file CodeRabbit cap"; return 0; fi
    if [ "$2" -gt "$HARDL" ]; then echo "$2 lines is past the $HARDL-line hard max"; return 0; fi
    if [ "$3" = yes ] && [ "$1" -gt "$SOFT" ]; then echo "a trust-path brief over the $SOFT-file soft band ($1 files)"; return 0; fi
    return 1
}

OPERATOR_ROUTE="this routes to the operator: they approve it with size-override.sh operator or /op size-approval (the gen-briefs refusal prints both lines)"
SPLIT="this cannot open as one PR, split; there is nothing to approve"
TAB=$(printf '\t')

# The reader's safety check runs in a bash with an empty environment and PATH=/usr/bin:/bin, so no exported function,
# BASH_ENV or earlier PATH entry of the caller's stands in for stat or date. Args: <file> <approvals dir> <owner uid>.
# It prints `<now> TAB <expiry as a date> TAB <the file's first line>`, or one reason and exits 1.
# shellcheck disable=SC2016
APPROVAL_READ_SH='f=$1 d=$2 u=$3
[ -f "$f" ] && [ ! -L "$f" ] || { echo "it is not a regular file"; exit 1; }
for p in "$f" "$d" "${d%/*}"; do
    s=$(stat -c "%u %a" -- "$p" 2>/dev/null) || { echo "cannot stat $p"; exit 1; }  # gnu-ok: Linux; elsewhere it fails closed # swallow-ok: a failed stat rejects the file
    [ "${s% *}" = "$u" ] || { echo "$p is owned by uid ${s% *}, not $u"; exit 1; }
    [ $((8#${s#* } & 8#022)) -eq 0 ] || { echo "$p is group- or other-writable (mode ${s#* })"; exit 1; }
done
IFS= read -r line < "$f" || { echo "it holds no complete line"; exit 1; }
tab=$(printf "\t"); exp=${line#*"$tab"}; exp=${exp%%"$tab"*}
case $exp in ""|*[!0-9]*) till="-" ;; *) till=$(date -u -d "@$exp" "+%Y-%m-%d %H:%MZ" 2>/dev/null) || till="epoch $exp" ;; esac  # gnu-ok: display only # swallow-ok: the expiry date is display only, the epoch stands in
printf "%s\t%s\t%s\n" "$(date +%s)" "$till" "$line"'

# approval_read <file> - the safety check: a safe, well-formed, unexpired approval file. Sets A_TILL, A_ID, A_REASON and
# the four fields approval_fields compares; on a failure A_WHY names it and it returns 1.
approval_read() {
    local out now tag exp extra
    A_WHY="" A_KEY="" A_LABEL="" A_FILES="" A_SCOPE=""
    if ! out=$(/usr/bin/env -i PATH=/usr/bin:/bin /bin/bash --norc --noprofile -c "$APPROVAL_READ_SH" approval-read "$1" "$SIZE_APPROVALS" "$SIZE_APPROVAL_UID" 2>/dev/null); then  # swallow-ok: a failed read rejects the file, its reason is on stdout
        A_WHY=${out:-the reader could not run}; return 1
    fi
    IFS="$TAB" read -r now A_TILL tag exp A_KEY A_LABEL A_FILES A_SCOPE A_ID A_REASON extra <<EOF
$out
EOF
    if [ "$tag" != SIZE-APPROVAL ] || [ -z "$A_REASON" ] || [ -n "$extra" ]; then A_WHY="it is not one 8-field SIZE-APPROVAL line"; return 1; fi
    case "$exp$now" in ''|*[!0123456789]*) A_WHY="its expiry is not a number"; return 1 ;; esac
    [ "$exp" -gt "$now" ] || { A_WHY="it expired $A_TILL"; return 1; }
}
# approval_fields <file> <files> <scope> - the field match: the approval approval_read last read is for this KEY and
# label and these files and scope, and the file's own name says the same.
approval_fields() {
    [ "$1" = "$SIZE_APPROVALS/$KEY.$LABEL.$2.$3" ] && [ "$A_KEY" = "$KEY" ] && [ "$A_LABEL" = "$LABEL" ] \
        && [ "$A_FILES" = "$2" ] && [ "$A_SCOPE" = "$3" ]
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
        if [ "$FILES" -gt "$CAP" ]; then
            echo "size-override: refused - $why: $SPLIT" >&2
        elif [ "$LINES" -gt "$HARDL" ]; then
            echo "size-override: refused - $why; this routes to the operator, not the chief alone" >&2
        else
            echo "size-override: refused - $why; $OPERATOR_ROUTE" >&2
        fi
        exit 4
    fi
    SRC="console:$(printf '%s' "${CHIEF_SESSION_NAME:-${USER:-unknown}@$(hostname 2>/dev/null || uname -n)}" | tr -c 'A-Za-z0-9._@-' '_')"  # swallow-ok: hostname is only a label fallback
    MAC=$(override_mac "$SRC" "$REASON") || { echo "size-override: cannot sign the row (GO key at $(go_key_file) unreadable)" >&2; exit 2; }
    append "$(printf 'SIZE-OVERRIDE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$KEY" "$LABEL" "$FILES" "$LINES" "$TRUST" "$SRC" "$REASON" "$MAC")"
    echo "size-override: recorded for $KEY $LABEL ($FILES files) by $SRC"
    ;;
check)
    # the operator's cases come first: no chief row, signed or not, lifts them; only the operator's approval does
    if why=$(operator_owned "$FILES" 0 "$TRUST"); then
        if [ "$FILES" -gt "$CAP" ]; then
            echo "size-override: $why: $SPLIT" >&2
            exit 4
        fi
        if [ "$TRUST" = yes ] && [ -n "$SCOPE" ]; then
            f="$SIZE_APPROVALS/$KEY.$LABEL.$FILES.$SCOPE"
            if [ -e "$f" ] || [ -L "$f" ]; then
                if approval_read "$f" && approval_fields "$f" "$FILES" "$SCOPE"; then
                    echo "size-override: $KEY $LABEL ($FILES files, scope $SCOPE) kept whole by the operator (afk $A_ID, until $A_TILL): $A_REASON"
                    exit 0
                fi
                echo "size-override: the operator approval $f is no approval: ${A_WHY:-its body does not match its name}" >&2
            else
                for g in "$SIZE_APPROVALS/$KEY.$LABEL".*; do
                    { approval_read "$g" && approval_fields "$g" "$A_FILES" "$A_SCOPE"; } || continue
                    echo "size-override: an operator approval for $KEY $LABEL covers $A_FILES files, scope $A_SCOPE (until $A_TILL); this run projects $FILES files, scope $SCOPE: re-approve this list, or re-run at the base the approval was given for" >&2
                    break
                done
            fi
        fi
        echo "size-override: $why; $OPERATOR_ROUTE" >&2
        exit 4
    fi
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
    if why=$(operator_owned "$FILES" "$rlines" "$rtrust"); then
        echo "size-override: $why; this routes to the operator, a chief override does not apply" >&2
        exit 4
    fi
    echo "size-override: $KEY $LABEL ($FILES files) kept whole by $rsrc: $rreason"
    ;;
operator)
    # the terminal route: file the size-approval op; the operator approves with the nonce and code root's notice bot sends
    case "$FILES" in [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;; *) echo "size-override: --files needs 1 to 3 digits" >&2; exit 2 ;; esac
    printf '%s' "$REASON" | grep -qE '^[A-Za-z0-9,.:_-]{3,80}$' || { echo "size-override: --reason is one word of 3 to 80 characters from A-Za-z0-9,.:_- (got '$REASON')" >&2; exit 2; }
    [ -n "$SCOPE" ] || { echo "size-override: --scope is required (the digest gen-briefs prints)" >&2; exit 2; }
    if [ "$FILES" -gt "$CAP" ]; then
        echo "size-override: $FILES files is past the $CAP-file CodeRabbit cap: $SPLIT" >&2
        exit 4
    fi
    if [ ! -e "$AFK_HELPER" ]; then
        echo "size-override: the operator route needs the afk-sudo station ops, and $AFK_HELPER is absent here (docs/internals/afk-sudo.md)" >&2
        exit 5
    fi
    res=$(sudo -n "$AFK_HELPER" op-request --session "terminal-$$" --ticket "$KEY" -- size-approval \
        "key=$KEY" "label=$LABEL" "files=$FILES" "scope=$SCOPE" "reason=$REASON" </dev/null 2>&1)
    printf '%s\n' "$res"
    line=$(printf '%s\n' "$res" | grep -m1 '^result=')
    case "$line" in
        "result=pending "*) ;;
        result=bad-param*) exit 2 ;;
        result=ops-disabled*) echo "size-override: station ops are off: the operator sets \"ops\": {\"enabled\": true} (ops.enabled) with sudoedit /etc/himmel/afk-sudo.json" >&2; exit 5 ;;
        *) exit 5 ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^result=pending id=\([a-z2-7]*\).*/\1/p')
    [ -n "$id" ] || exit 5
    if [ -t 0 ] && command -v himmelctl >/dev/null 2>&1; then
        # himmelctl writes its masked prompt to stdout, so that stdout goes on to the terminal as well as into $out
        out=$(himmelctl approve "$id" | tee /dev/tty; exit "${PIPESTATUS[0]}"); rc=$?
        case "$out" in *op_result=changed*) exit 0 ;; esac
        echo "size-override: approve $id did not run the op (himmelctl exit $rc)" >&2
        exit 5
    fi
    echo "approve with: himmelctl approve $id in a plain terminal, or tap Approve on the Telegram notice for request $id"
    exit 75
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
