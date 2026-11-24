#!/usr/bin/env bash
# scripts/t3/relay-bind.sh - bind a T3 thread to a handover doc and a row in the chief's fleet manifest, so a worker in
# that thread reaches the chief through the marker bullets every other worker already writes (design r4).
#
#   relay-bind.sh prepare --manifest <m> --ticket <KEY-n> --label N<k> --slug <s> --writes <file>... [--completes yes|no]
#   relay-bind.sh attach  --manifest <m> --doc <d> --thread <threadId>
#   relay-bind.sh scan    --manifest <m>          the waiter's call: path B binding, notice re-sends, upkeep
#   relay-bind.sh unbind  --manifest <m> <threadId>
#
# OFF BY DEFAULT: the switch is `.t3.relay_instances` in $HOME/.himmel/config.json (read here and in provider-instances.sh,
# no env override). Absent or [], every verb exits 0 before any T3 call. Only `t3 thread list` and `t3-send.sh` (a send to
# a threadId this script selected) ever reach T3; nothing here starts a thread. A thread title is never read or printed.
#
# prepare   path A, before the chief launches: writes <manifest dir>/<KEY>-N<k>-t3-<slug>-<UTC date>.md, adds a lane-t3
#           lockless row with t3_thread: pending, prints the doc path and the command block for the brief.
# attach    path A, after the launch: sets the row's t3_thread to the threadId the launch tool returned.
# scan      path B: binds an idle (whitelisted status) unsettled thread on a `<id>_relay` instance whose base id is listed,
#           sends the fixed notice, re-sends pending notices (at most 3 sends a row), unbinds a row whose thread left the
#           list or settled for T3_RELAY_UNBIND_DAYS (default 3) with no READY/BLOCKED newest bullet, and keeps one owner
#           per bucket by the live chief's queue lock. Printed lines carry only threadIds, labels, counts and rc numbers:
#             BOUND <id> <label>  UNBOUND <id> <label>  ASK-THREAD-PR <id> <label> linked=<n>  BIND-REFUSED <id> <why>
#             BIND-SEND-FAILED <id> rc=<n>  BIND-GAVE-UP <id>  OWNER-TAKEN <old stem> rows=<copied|none>
# unbind    removes the row and records the tombstone in one write, so the thread is never bound again.
#
# Exit: 0 nothing new; 1 something was printed; 2 usage or config failure (also an unreadable owner status or a stuck
# owner lock); 4 `t3 thread list` failed or a field the pass reads is missing (stderr names it); 5 this manifest is not
# the owner and the owner is live (its own re-sends and upkeep still ran).
# Env seams: T3_SEND_BIN, T3_SEND_PROJECT (as t3-send.sh), T3_RELAY_UNBIND_DAYS. Siblings are found beside this file.
# Platform: Linux (util-linux flock, GNU timeout), bash 3.2+, jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KIT="$ROOT/scripts/handover/chief-kit"
FM="$KIT/fleet-manifest.sh"
GL="$KIT/bucket-gitleaks.sh"
APPEND="$KIT/append-results.sh"
SEND="$HERE/t3-send.sh"
QL="$ROOT/scripts/handover/queue-lock.sh"
BIN="${T3_SEND_BIN:-$HOME/.t3/bin/t3}"
PROJECT="${T3_SEND_PROJECT:-$ROOT}"
CFG="$HOME/.himmel/config.json"
IDLE_STATUSES='["completed","interrupted","cancelled","idle"]'
DEADLINE=24
MAX_BINDS=3
MAX_RESENDS=3
ID_RE='^[A-Za-z0-9:_-]{1,64}$'

die() { echo "relay-bind: $2" >&2; exit "$1"; }
usage() { sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh" || die 2 "cannot load scripts/lib/prim.sh"
# shellcheck source=../lib/worker-identity.sh
. "$ROOT/scripts/lib/worker-identity.sh" || die 2 "cannot load worker-identity.sh"
# shellcheck source=../lib/worker-tail-status.sh
. "$ROOT/scripts/lib/worker-tail-status.sh" || die 2 "cannot load worker-tail-status.sh"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"
command -v flock >/dev/null 2>&1 || die 2 "flock is required (the chief kit is Linux-only)"   # prim-ok: only checks that flock exists; the lock below is a 5 s bounded flock

run_clean() (
    local d f n
    d=/proc/self/fd; [ -d "$d" ] || d=/dev/fd
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in 0|1|2|*[!0-9]*) ;; *) eval "exec $n>&-" 2>/dev/null ;; esac
    done
    exec "$@" </dev/null
)
fm() { run_clean timeout -k 1 5 bash "$FM" "$@"; }   # gnu-ok: Linux-only chief kit, GNU timeout

relay_ids=""
if [ -e "$CFG" ]; then
    jq -e . "$CFG" >/dev/null 2>&1 || die 2 "$CFG is not valid JSON"
    relay_ids="$(jq -c '(.t3.relay_instances // []) | if type == "array" then [.[] | select(type == "string")] else [] end' "$CFG")" || die 2 "cannot read $CFG"
fi
[ -n "$relay_ids" ] || relay_ids='[]'

verb="${1:-}"
[ -n "$verb" ] || usage
shift
case "$verb" in prepare|attach|scan|unbind) ;; *) usage ;; esac
[ "$relay_ids" != '[]' ] || exit 0

manifest=""; ticket=""; label=""; slug=""; completes=no; doc=""; thread=""; tid=""
writes=()
if [ "$verb" = prepare ]; then
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --manifest) [ "$#" -ge 2 ] || usage; manifest="$2"; shift 2 ;;
            --ticket)   [ "$#" -ge 2 ] || usage; ticket="$2"; shift 2 ;;
            --label)    [ "$#" -ge 2 ] || usage; label="$2"; shift 2 ;;
            --slug)     [ "$#" -ge 2 ] || usage; slug="$2"; shift 2 ;;
            --completes) [ "$#" -ge 2 ] || usage; completes="$2"; shift 2 ;;
            --writes)   shift
                        while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do writes+=("$1"); shift; done ;;
            *) usage ;;
        esac
    done
else
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --manifest) [ "$#" -ge 2 ] || usage; manifest="$2"; shift 2 ;;
            --doc)      [ "$verb" = attach ] && [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
            --thread)   [ "$verb" = attach ] && [ "$#" -ge 2 ] || usage; thread="$2"; shift 2 ;;
            --*) usage ;;
            *) [ "$verb" = unbind ] && [ -z "$tid" ] || usage; tid="$1"; shift ;;
        esac
    done
fi
case "$manifest" in /*) ;; *) die 2 "--manifest must be an absolute path" ;; esac
mdir="${manifest%/*}"
[ -d "$mdir" ] || die 2 "manifest directory missing: $mdir"
today="$(date -u +%Y-%m-%d)"

if [ "$verb" = prepare ]; then
    [[ $ticket =~ ^[A-Za-z]+-[0-9]+$ ]] || die 2 "--ticket must look like ABC-123"
    [[ $label =~ ^N[0-9]+[a-z]*$ ]] || die 2 "--label must look like N12 or N12b"
    [[ $slug =~ ^[a-z0-9-]{1,32}$ ]] || die 2 "--slug must match [a-z0-9-]{1,32}"
    case "$completes" in yes|no) ;; *) die 2 "--completes must be yes or no" ;; esac
    [ "${#writes[@]}" -ge 1 ] || die 2 "--writes needs at least one file"
    for w in "${writes[@]}"; do [[ $w =~ ^[A-Za-z0-9._/@+-]+$ ]] || die 2 "a --writes path has a character outside [A-Za-z0-9._/@+-]"; done
    doc="$mdir/$ticket-$label-t3-$slug-$today.md"
    [ ! -e "$doc" ] || die 2 "doc exists: $doc"
    tmp="$(mktemp "$mdir/.t3prep.XXXXXX")" || die 2 "mktemp failed"
    trap 'rm -f "$tmp"' EXIT
    {
        printf '# %s - a T3 thread bound to the chief - worker %s (t3)\n\n' "$ticket" "$label"
        printf '> **Writes:** %s\n\n' "${writes[*]}"
        printf '> **Completes ticket:** %s\n\n' "$completes"
        printf '## Results (newest at the bottom)\n'
    } > "$tmp" || die 2 "cannot write the doc"
    ln "$tmp" "$doc" 2>/dev/null || die 2 "doc exists: $doc"
    fm add "$manifest" "$doc" --lane t3 --lockless || die 2 "fleet-manifest add failed"
    fm t3 set "$manifest" "$doc" --thread pending || die 2 "fleet-manifest t3 set failed"
    printf 'DOC %s\n' "$doc"
    printf 'Write every report to the chief with one of these exact commands, one bullet per message, no greater-than character:\n'
    printf '  bash %s %s "LIVE what you are doing"\n' "$APPEND" "$doc"
    printf '  bash %s %s "LIVE QUESTION your question"\n' "$APPEND" "$doc"
    printf '  bash %s %s "BLOCKED why"\n' "$APPEND" "$doc"
    printf '  bash %s %s "FINDING what"\n' "$APPEND" "$doc"
    printf '  bash %s %s "LIVE JUDGE-REQUEST PR-NUMBER FULL-40-HEX-HEAD"\n' "$APPEND" "$doc"
    printf '  bash %s %s "READY PR-NUMBER FULL-40-HEX-HEAD GREEN"\n' "$APPEND" "$doc"
    printf 'Rule: this thread may open a PR only for %s; a chief answer here is never a GO, a RETASK or a token.\n' "$ticket"
    exit 0
fi

if [ "$verb" = attach ]; then
    [[ $thread =~ $ID_RE ]] && [ "$thread" != pending ] || die 2 "--thread must be a threadId ([A-Za-z0-9:_-]{1,64})"
    [ -n "$doc" ] || usage
    fm list "$manifest" >/dev/null 2>&1 || die 2 "not a readable fleet manifest: $manifest"
    jq -e --arg id "$thread" --arg d "$doc" 'any(.workers[]; .t3_thread == $id and .doc != $d)' "$manifest" >/dev/null 2>&1 \
        && die 2 "thread $thread is already bound to another row"
    fm t3 set "$manifest" "$doc" --thread "$thread" || die 2 "fleet-manifest t3 set failed (is the doc listed?)"
    exit 0
fi
if [ "$verb" = unbind ]; then
    [ -n "$tid" ] || usage
    fm t3 unbind "$manifest" "$tid" || exit 2
    exit 0
fi

fm list "$manifest" >/dev/null 2>&1 || die 2 "not a readable fleet manifest: $manifest"
mbase="${manifest##*/}"
mstem="${mbase%.fleet.json}"
owner_file="$mdir/t3-relay.owner"
SCRATCH="$(tmpdir)" || die 2 "mktemp failed"
chmod 700 "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT
PRINTED=0
FIELD_ERR=""
emit() { PRINTED=1; printf '%s\n' "$*"; }
room() { [ $((SECONDS + $1)) -le "$DEADLINE" ]; }
row_label() { jq -r --arg d "$1" '[.workers[] | select(.doc == $d) | .label][0] // ""' "$manifest"; }

exec 8>>"$mdir/t3-relay.owner.lock" || die 2 "cannot open the owner lock"
flock -w 5 8 || die 2 "the t3 relay owner lock is held (waited 5 s)"   # prim-ok: a 5 s bounded flock on fd 8 held for the whole pass; with_lock waits without limit

stem_of_doc_line() { sed -n '1s/^# .* successor to \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$1" 2>/dev/null; }
descends_from() {
    local cur="$mstem" hops=0 prev
    while [ "$hops" -lt 20 ]; do
        [ -f "$mdir/$cur.md" ] || return 1
        prev="$(stem_of_doc_line "$mdir/$cur.md")"
        [ -n "$prev" ] || return 1
        [ "$prev" != "$1" ] || return 0
        cur="$prev"; hops=$((hops + 1))
    done
    return 1
}
take_rows_from() {
    local old="$1" d th kd nt line
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        room 6 || break
        jq -e --arg d "$d" 'any(.workers[]; .doc == $d)' "$manifest" >/dev/null 2>&1 && continue
        fm add "$manifest" "$d" --lane t3 --lockless || continue
        th="$(jq -r --arg d "$d" '[.workers[] | select(.doc == $d) | .t3_thread // ""][0]' "$old")"
        kd="$(jq -r --arg d "$d" '[.workers[] | select(.doc == $d) | .t3_kind // ""][0]' "$old")"
        nt="$(jq -r --arg d "$d" '[.workers[] | select(.doc == $d) | .t3_notice // ""][0]' "$old")"
        set -- "$manifest" "$d"
        [ -z "$th" ] || set -- "$@" --thread "$th"
        [ -z "$kd" ] || set -- "$@" --kind "$kd"
        [ -z "$nt" ] || set -- "$@" --notice "$nt"
        [ "$#" -le 2 ] || fm t3 set "$@" || true
    done <<EOF1
$(jq -r '.workers[] | select(.lane == "t3") | .doc' "$old")
EOF1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        room 6 || break
        th="${line%%$'\t'*}"; nt="${line#*$'\t'}"
        [[ $th =~ $ID_RE ]] && [[ $nt =~ ^[a-z0-9:_-]{1,40}$ ]] && fm t3 unbind "$manifest" "$th" --reason "$nt" || true
    done <<EOF2
$(jq -r '(.t3_tombstones // [])[] | "\(.thread)\t\(.reason // "unbound")"' "$old")
EOF2
}

IS_OWNER=0
if [ ! -e "$owner_file" ]; then
    printf '%s\n' "$manifest" | atomic_write "$owner_file" || die 2 "cannot write the owner file"
    IS_OWNER=1
else
    owner="$(head -n 1 "$owner_file" 2>/dev/null)"
    if [ "$owner" = "$manifest" ]; then
        IS_OWNER=1
    else
        case "$owner" in /*) ;; *) die 2 "the owner file does not hold an absolute manifest path" ;; esac
        odir="${owner%/*}"; obase="${owner##*/}"; ostem="${obase%.fleet.json}"
        takeover=0
        if [ ! -f "$owner" ] || [ ! -f "$odir/$ostem.md" ]; then
            takeover=1
        else
            run_clean timeout -k 1 2 bash "$QL" status "$odir/$ostem.md" >/dev/null 2>&1; qrc=$?   # gnu-ok: Linux-only chief kit, GNU timeout
            case "$qrc" in
                0) takeover=1 ;;
                11|12) IS_OWNER=0 ;;
                *) die 2 "cannot read the owner's queue-lock status (rc $qrc); nothing taken" ;;
            esac
        fi
        if [ "$takeover" = 1 ]; then
            rows=none
            if [ -f "$owner" ] && descends_from "$ostem"; then take_rows_from "$owner"; rows=copied; fi
            printf '%s\n' "$manifest" | atomic_write "$owner_file" || die 2 "cannot write the owner file"
            IS_OWNER=1
            emit "OWNER-TAKEN $ostem rows=$rows"
        fi
    fi
fi

room 6 || exit 1
run_clean timeout -k 1 5 "$BIN" thread list --json --project "$PROJECT" > "$SCRATCH/list" 2> "$SCRATCH/list.err"   # gnu-ok: Linux-only chief kit, GNU timeout
lrc=$?
if [ "$lrc" -ne 0 ] || ! jq -e 'type == "array"' "$SCRATCH/list" >/dev/null 2>&1; then
    echo "relay-bind: t3 thread list failed (rc $lrc)" >&2
    exit 4
fi

UNBIND_DAYS="${T3_RELAY_UNBIND_DAYS:-3}"
case "$UNBIND_DAYS" in ''|*[!0-9]*) die 2 "T3_RELAY_UNBIND_DAYS must be a whole number" ;; esac
now_epoch="$(date -u +%s)"

bound_json="$(jq -c '[.workers[] | select((.t3_thread // "pending") != "pending") | .t3_thread]' "$manifest")"
tomb_json="$(jq -c '[(.t3_tombstones // [])[] | .thread]' "$manifest")"
jq -r --argjson relay "$relay_ids" --argjson bound "$bound_json" --argjson tomb "$tomb_json" --argjson idle "$IDLE_STATUSES" --arg idre "$ID_RE" '
  def okid: (.threadId | type == "string") and (.threadId | test($idre));
  def has($a; $x): ($a | index($x)) != null;
  . as $all
  | ($all | map(select(type == "object" and okid))) as $ts
  | ($ts[] | select(has($bound; .threadId))
      | if (.settled | type) != "boolean" then "ERR\t\(.threadId)\tsettled"
        elif (.status | type) != "string" then "ERR\t\(.threadId)\tstatus"
        elif (.providerInstanceId | type) != "string" then "ERR\t\(.threadId)\tproviderInstanceId"
        else "T\t\(.threadId)\t\(.status)\t\(.settled)\t\(.settledAt // "-")\t\(.pullRequestCount // 0)" end),
    ($ts[] | select((.providerInstanceId | type) == "string" and (.providerInstanceId | endswith("_relay"))
          and has($relay; .providerInstanceId[:-6])
          and (.threadId | startswith("import:") | not)
          and (has($bound; .threadId) | not) and (has($tomb; .threadId) | not))
      | if (.settled | type) != "boolean" then "ERR\t\(.threadId)\tsettled"
        elif .settled then empty
        elif (.status | type) != "string" then "ERR\t\(.threadId)\tstatus"
        elif has($idle; .status) then "C\t\(.threadId)\t\(.providerInstanceId)"
        else empty end)
' "$SCRATCH/list" > "$SCRATCH/rows" 2>"$SCRATCH/rows.err" || { echo "relay-bind: cannot read the thread list: $(head -c 200 "$SCRATCH/rows.err")" >&2; exit 4; }

while IFS=$'\t' read -r kind a b _; do
    [ "$kind" = ERR ] && [ -z "$FIELD_ERR" ] && FIELD_ERR="$a missing field $b"
done < "$SCRATCH/rows"

bound_status() { awk -F'\t' -v id="$1" '$1 == "T" && $2 == id { print $3 }' "$SCRATCH/rows" | head -n 1; }

pr_seen="$manifest.t3-pr-seen"
pr_new="$SCRATCH/pr-seen.new"
: > "$pr_new"
while IFS=$'\t' read -r id d; do
    [ -n "$id" ] || continue
    room 6 || break
    lbl="$(row_label "$d")"
    line="$(awk -F'\t' -v id="$id" '$1 == "T" && $2 == id { print }' "$SCRATCH/rows" | head -n 1)"
    if [ -z "$line" ]; then
        grep -q "^ERR	$id	" "$SCRATCH/rows" && continue
        fm t3 unbind "$manifest" "$id" --reason gone && emit "UNBOUND $id $lbl"
        continue
    fi
    IFS=$'\t' read -r _ _ st settled sat prc <<<"$line"
    if [ "$settled" = true ]; then
        age_ok=""
        if [ "$sat" != "-" ]; then
            sat_epoch="$(jq -nr --arg s "$sat" '$s | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null)" || sat_epoch=""
            [[ $sat_epoch =~ ^[0-9]+$ ]] || { [ -n "$FIELD_ERR" ] || FIELD_ERR="$id bad field settledAt"; continue; }
            [ $((now_epoch - sat_epoch)) -gt $((10#$UNBIND_DAYS * 86400)) ] && age_ok=yes
        fi
        if [ -n "$age_ok" ]; then
            tail_m="$(worker_tail_status "$d" 2>/dev/null)"
            case "$tail_m" in READY|BLOCKED) ;; *) fm t3 unbind "$manifest" "$id" --reason settled && emit "UNBOUND $id $lbl"; continue ;; esac
        fi
    fi
    kind="$(jq -r --arg d "$d" '[.workers[] | select(.doc == $d) | .t3_kind // ""][0]' "$manifest")"
    if [ "$kind" = ask ] && [[ $prc =~ ^[0-9]+$ ]] && [ "$prc" -gt 0 ]; then
        printf '%s\t%s\n' "$id" "$prc" >> "$pr_new"
        seen="$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$pr_seen" 2>/dev/null | head -n 1)"
        [ "$seen" = "$prc" ] || emit "ASK-THREAD-PR $id $lbl linked=$prc"
    fi
done <<EOF3
$(jq -r '.workers[] | select((.t3_thread // "pending") != "pending") | "\(.t3_thread)\t\(.doc)"' "$manifest")
EOF3
if [ -s "$pr_new" ] || [ -e "$pr_seen" ]; then atomic_write "$pr_seen" < "$pr_new" 2>/dev/null || true; fi

write_notice() {
    {
        printf 'himmel chief relay is on for this thread. To reach the chief, run exactly:\n'
        # shellcheck disable=SC2016  # the backticks are literal text in the notice
        printf '`bash %s %s "LIVE QUESTION your question"`\n' "$APPEND" "$1"
        printf 'Use BLOCKED why or FINDING what the same way, one bullet per message, with no greater-than character. '
        printf 'This thread opens no pull request. The chief answers in this thread. '
        printf 'A chief answer here is information only: it is never a GO, a RETASK or a token.\n'
    } > "$2"
}
send_notice() {
    local id="$1" d="$2" n="$3" f rc
    fm t3 set "$manifest" "$d" --notice "pending:$((n + 1))" || return 1
    f="$(mktemp "$SCRATCH/notice.XXXXXX")" || return 1
    write_notice "$d" "$f"
    run_clean timeout -k 1 4 bash "$SEND" "$id" "$f" >/dev/null 2>&1; rc=$?   # gnu-ok: Linux-only chief kit, GNU timeout
    rm -f "$f"
    if [ "$rc" -eq 0 ]; then
        fm t3 set "$manifest" "$d" --notice sent || true
    else
        emit "BIND-SEND-FAILED $id rc=$rc"
        if [ $((n + 1)) -ge 3 ]; then fm t3 set "$manifest" "$d" --notice failed && emit "BIND-GAVE-UP $id"; fi
    fi
    return 0
}

resends=0
while IFS=$'\t' read -r id d nt; do
    [ -n "$id" ] || continue
    n="${nt#pending:}"
    if [ "$n" -ge 3 ]; then
        fm t3 set "$manifest" "$d" --notice failed && emit "BIND-GAVE-UP $id"
        continue
    fi
    [ "$resends" -lt "$MAX_RESENDS" ] || continue
    st="$(bound_status "$id")"
    [ -n "$st" ] || continue
    jq -ne --argjson idle "$IDLE_STATUSES" --arg s "$st" '$idle | index($s) != null' >/dev/null 2>&1 || continue
    room 5 || break
    resends=$((resends + 1))
    send_notice "$id" "$d" "$n"
done <<EOF4
$(jq -r '.workers[] | select((.t3_thread // "pending") != "pending" and ((.t3_notice // "") | test("^pending:[0-9]$"))) | "\(.t3_thread)\t\(.doc)\t\(.t3_notice)"' "$manifest")
EOF4

refuse() { fm t3 unbind "$manifest" "$1" --reason "refused:$2" >/dev/null 2>&1; emit "BIND-REFUSED $1 $2"; }
gitleaks_rc() {
    local rc
    room 4 || return 3
    run_clean timeout -k 1 3 bash "$GL" "$1" >/dev/null 2>&1; rc=$?   # gnu-ok: Linux-only chief kit, GNU timeout
    case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 3 ;; esac
}
listed_elsewhere() {
    local f
    for f in "$mdir"/*.fleet.json; do
        [ -e "$f" ] && [ "$f" != "$manifest" ] || continue
        jq -e --arg d "$1" 'any((.workers // .legs // [])[]; .doc == $d)' "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}
bind_one() {
    ASK_TMP=""
    bind_attempt "$@"
    [ -z "$ASK_TMP" ] || rm -f "$ASK_TMP"
    return 0
}
bind_attempt() {
    local id="$1" inst="$2" short d dtmp ntmp g1 g2 lbl
    short="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-8)"
    [ -n "$short" ] || short=thread
    d="$mdir/T3ASK-$short-$today.md"
    dtmp="$(mktemp "$mdir/.t3ask.XXXXXX")" || return 0
    ASK_TMP="$dtmp"
    ntmp="$(mktemp "$SCRATCH/ask.notice.XXXXXX")" || return 0
    {
        printf '# T3 relay ask thread\n\n'
        printf '> **T3 thread:** %s\n' "$id"
        [[ $inst =~ ^[A-Za-z0-9_.:-]{1,80}$ ]] && printf '> **Provider instance:** %s\n' "$inst"
        printf '> **Writes:** none (this thread opens no PR)\n\n'
        printf '## Results (newest at the bottom)\n'
    } > "$dtmp"
    write_notice "$d" "$ntmp"
    gitleaks_rc "$dtmp"; g1=$?
    [ "$g1" -ne 3 ] || return 0
    [ "$g1" -eq 0 ] || { refuse "$id" gitleaks; return 0; }
    gitleaks_rc "$ntmp"; g2=$?
    [ "$g2" -ne 3 ] || return 0
    [ "$g2" -eq 0 ] || { refuse "$id" gitleaks; return 0; }
    if [ -e "$d" ]; then
        listed_elsewhere "$d" && return 0
        grep -qxF "> **T3 thread:** $id" "$d" 2>/dev/null || { refuse "$id" exists; return 0; }
    else
        ln "$dtmp" "$d" 2>/dev/null || { refuse "$id" exists; return 0; }
    fi
    room 6 || return 0
    fm add "$manifest" "$d" --lane t3 --lockless || return 0
    room 6 || return 0
    fm t3 set "$manifest" "$d" --thread "$id" --kind ask --notice pending:0 || return 0
    lbl="$(jq -r --arg d "$d" '[.workers[] | select(.doc == $d) | .label][0] // ""' "$manifest")"
    emit "BOUND $id $lbl"
    send_notice "$id" "$d" 0
    return 0
}
if [ "$IS_OWNER" = 1 ]; then
    binds=0
    while IFS=$'\t' read -r kind id inst; do
        [ "$kind" = C ] || continue
        [ "$binds" -lt "$MAX_BINDS" ] || break
        room 13 || break
        binds=$((binds + 1))
        bind_one "$id" "$inst"
    done < "$SCRATCH/rows"
fi

if [ -n "$FIELD_ERR" ]; then echo "relay-bind: $FIELD_ERR" >&2; exit 4; fi
[ "$IS_OWNER" = 1 ] || exit 5
[ "$PRINTED" = 0 ] || exit 1
exit 0
