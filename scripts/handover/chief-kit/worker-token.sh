#!/usr/bin/env bash
# scripts/handover/chief-kit/worker-token.sh - the one writer of the record of each
# worker's current RETASK token generation, <bucket>/worker-tokens.jsonl, the bucket
# being the worker doc's directory. The record holds generations only, never a token
# or a digest of one: the token of generation g is <dispatch prefix>-<8 hex of
# go_msg_mac himmel-retask-v1 "<bucket key>/<doc stem>|<g>"> under the chief's GO key.
# The bucket key is the bucket's path under the handover root ($HANDOVER_DIR as the
# caller passes it), or its absolute path when it is outside the root.
#
#   mint <doc> <prefix>   gen 1, current at once (the brief delivers it). Repeats the
#                         token, writing nothing, while that row is the stem's only one
#                         and the doc does not exist yet; any other history is refused
#   rotate <doc> --to <S> the next generation, pending until the worker's handshake
#                         bullet names chief S; prints its token
#   current <doc>         the current token
#   gen <doc>             current=<n|-> pending=<n|->:<to|-> state=<state>, no token
#   tokens <doc>          <g> <token> per minted generation, for the recovery only
#   set <doc> <g>         the chief records a quote-back it saw: g is current and every
#                         earlier rotation is retired
#
# Every subcommand but mint first confirms a pending (or superseded, still newer than
# current) rotation whose chief a strict handshake bullet in the doc names
# (lib/succession-bullet.sh succession_names). One flock covers each read and append.
# State: ok, none (no rows), keymismatch (minted under another key, or no key; only
# mint ever creates one), bad (the record or the tools cannot be read).
#
# Exit: 0 ok; 1 none or keymismatch; 2 usage; 3 refused in a worker or relay;
# 4 refused transition; 6 bad; 96 the chokepoint seam guard refused or is missing.
# A reader falls back only on 1 or 3, so no internal failure may exit with either.
# PLATFORM GUARD: the chief kit is Linux-only, as its siblings. Needs jq, openssl, flock.
set -u
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "worker-token.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/chief-kit/worker-token.sh || exit 96

die() { echo "worker-token: $2" >&2; exit "$1"; }

unset -f chief_worker go_msg_mac go_key_file go_key_ensure handover_root succession_names 2>/dev/null || true
for _lib in go-gate.sh handover-path.sh succession-bullet.sh; do
    # shellcheck disable=SC1090
    { [ -r "$_csg_dir/../../lib/$_lib" ] && . "$_csg_dir/../../lib/$_lib"; } || die 6 "cannot load scripts/lib/$_lib"
done
{ declare -F chief_worker && declare -F go_msg_mac && declare -F go_key_ensure \
    && declare -F handover_root && declare -F succession_names; } >/dev/null || die 6 "a required library function is missing"

relay_env() {
    case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
if chief_worker || relay_env; then
    die 3 "refusing - this is a chief-spawned worker or relay; only the chief reads or writes the token record"
fi

usage() {
    echo "usage: worker-token.sh mint <doc> <prefix> | rotate <doc> --to <chief> | current <doc> | gen <doc> | tokens <doc> | set <doc> <generation>" >&2
    exit 2
}
safe_name() { case "$1" in ''|-*|*[!A-Za-z0-9_.-]*) return 1 ;; esac; return 0; }

sub="${1:-}"; doc="${2:-}"
[ -n "$doc" ] || usage
prefix=""; to=""; want=""
case "$sub" in
    mint) [ "$#" -eq 3 ] || usage; prefix="$3"; safe_name "$prefix" || usage ;;
    rotate) { [ "$#" -eq 4 ] && [ "$3" = --to ]; } || usage; to="$4"; safe_name "$to" || usage ;;
    set) [ "$#" -eq 3 ] || usage; want="$3"; case "$want" in ''|0*|*[!0-9]*) usage ;; esac ;;
    current|gen|tokens) [ "$#" -eq 2 ] || usage ;;
    *) usage ;;
esac

command -v jq >/dev/null 2>&1 || die 6 "jq is required"
command -v flock >/dev/null 2>&1 || die 6 "flock is required"  # prim-ok: presence check for the Linux-only kit's lock below

stem="${doc##*/}"; stem="${stem%.md}"
[ -n "$stem" ] || usage
case "$doc" in */*) docdir="${doc%/*}" ;; *) docdir=. ;; esac
bucket="$(cd "${docdir:-/}" 2>/dev/null && pwd -P)" || bucket=""  # swallow-ok: an empty bucket is handled just below, per subcommand
if [ -z "$bucket" ]; then
    [ ! -d "${docdir:-/}" ] || die 6 "cannot enter the doc's directory: $docdir"
    case "$sub" in
        mint) die 6 "the doc's directory does not exist: $docdir" ;;
        rotate|set) die 4 "no record for $stem (its directory does not exist)" ;;
        gen) echo "current=- pending=-:- state=none"; exit 1 ;;
        *) die 1 "no record for $stem (its directory does not exist)" ;;
    esac
fi
root="$(handover_root)" || die 6 "cannot resolve the handover root"
root="$(cd "$root" 2>/dev/null && pwd -P)" || die 6 "cannot enter the handover root"  # swallow-ok: a failed cd exits 6 with its own line
case "$bucket" in
    "$root") bkey=. ;;
    "$root"/*) bkey="${bucket#"$root"/}" ;;
    *) bkey="$bucket" ;;
esac
rec="$bucket/worker-tokens.jsonl"

exec 9>>"$rec.lock" || die 6 "cannot open $rec.lock"
flock -w 60 9 || die 6 "cannot lock $rec.lock"  # prim-ok: one lock spans each read, decide and append

key_id() {
    local h
    h="$(go_msg_mac himmel-retask-keyid-v1 "-")" || return 1
    printf '%s' "${h:0:8}"
}
token() {
    local h
    h="$(go_msg_mac himmel-retask-v1 "$bkey/$stem|$1")" || return 1
    printf '%s-%s\n' "$2" "${h:0:8}"
}
print_token() { token "$1" "$2" || die 6 "cannot derive the token (GO key or openssl)"; }

if [ "$sub" = mint ]; then
    go_key_ensure || die 6 "cannot mint or read the GO key"
fi
kid="$(key_id)" || kid=""

nrows=0; cur=""; pend=""; pto=""; maxg=0; dprefix=""; mkid=""; first=""; rotations=""; minted=""; bad=0
parsed=""
if [ -e "$rec" ]; then
    if [ -f "$rec" ] && [ -r "$rec" ]; then
        # shellcheck disable=SC2016  # a jq program, not shell
        parsed="$(jq -Rrn --arg s "$stem" '
            def name: type == "string" and test("^[A-Za-z0-9_.-]+$");
            def okrow: type == "object" and .v == 1 and (.stem | type) == "string"
                and (.gen | type) == "number" and .gen >= 1 and .gen == (.gen | floor)
                and (.keyid | type) == "string" and (.keyid | test("^[0-9a-f]{8}$"))
                and (.event == "confirm" or .event == "set"
                     or (.event == "mint" and (.kind == "dispatch" or .kind == "rotate")
                         and (.prefix | name) and (.to | name)));
            [inputs] | to_entries[]
            | (.key + 1) as $n
            | (.value | try fromjson catch null) as $o
            | if ($o | okrow) | not then "torn \($n)"
              elif $o.stem != $s then empty
              elif $o.event == "mint" then "mint \($o.gen) \($o.kind) \($o.prefix) \($o.to) \($o.keyid)"
              else "\($o.event) \($o.gen) - - - \($o.keyid)" end' "$rec")" || bad=1
    else
        bad=1
    fi
fi
while read -r ev g kind pfx rto rkid; do
    case "$ev" in
        '') continue ;;
        torn) echo "worker-token: skipping line $g of $rec: it does not parse" >&2; continue ;;
    esac
    nrows=$((nrows + 1))
    [ -n "$first" ] || first="$ev $g $kind $pfx $rkid"
    case "$ev" in
        mint)
            mkid="$rkid"
            [ "$g" -le "$maxg" ] || maxg="$g"
            minted="$minted$g $pfx $rkid
"
            if [ "$kind" = dispatch ]; then
                cur="$g"; dprefix="$pfx"
            else
                pend="$g"; pto="$rto"
                rotations="$rotations$g $rto $rkid
"
            fi ;;
        confirm)
            cur="$g"
            if [ "$pend" = "$g" ]; then pend=""; pto=""; fi ;;
        set)
            cur="$g"; pend=""; pto=""; rotations="" ;;
    esac
done <<EOF
$parsed
EOF

if [ "$bad" -eq 1 ]; then state=bad
elif [ "$nrows" -eq 0 ]; then state=none
elif [ -z "$cur" ] || [ -z "$dprefix" ]; then state=bad
elif [ -z "$kid" ] && grep -qxE '[0-9a-f]{64}' "$(go_key_file)" 2>/dev/null; then state=bad
elif [ -z "$kid" ] || [ "$mkid" != "$kid" ]; then state=keymismatch
else state=ok
fi

append() {
    local filter="$1" row
    shift
    row="$(jq -cn --arg s "$stem" --arg k "$kid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" "$filter")" \
        || die 6 "cannot build a record row"
    if [ -s "$rec" ] && [ -n "$(tail -c 1 "$rec")" ]; then
        printf '\n' >> "$rec" || die 6 "cannot write $rec"
    fi
    printf '%s\n' "$row" >> "$rec" || die 6 "cannot write $rec"
}

if [ "$sub" = mint ]; then
    [ "$state" != bad ] || die 6 "the record is unreadable: $rec"
    if [ "$nrows" -eq 0 ]; then
        out="$(print_token 1 "$prefix")" || exit 6
        # shellcheck disable=SC2016
        append '{v:1, stem:$s, gen:1, event:"mint", kind:"dispatch", prefix:$p, to:"-", keyid:$k, at:$at}' --arg p "$prefix"
        printf '%s\n' "$out"
        exit 0
    fi
    if [ "$nrows" -eq 1 ] && [ "$first" = "mint 1 dispatch $prefix $kid" ] && [ ! -e "$doc" ]; then
        print_token 1 "$prefix"
        exit 0
    fi
    die 4 "$stem already has a history; a minted stem is never minted again"
fi

if [ "$state" = ok ] && [ -f "$doc" ]; then
    pick=""
    while read -r g rto rkid; do
        [ -n "$g" ] || continue
        { [ "$g" -gt "$cur" ] && [ "$rkid" = "$kid" ]; } || continue
        if succession_names "$doc" "$rto"; then pick="$g"; fi
    done <<EOF
$rotations
EOF
    if [ -n "$pick" ]; then
        # shellcheck disable=SC2016
        append '{v:1, stem:$s, gen:$g, event:"confirm", keyid:$k, at:$at}' --argjson g "$pick"
        cur="$pick"
        if [ "$pend" = "$pick" ]; then pend=""; pto=""; fi
    fi
fi

case "$sub" in
    gen)
        if [ "$state" = bad ]; then echo "current=- pending=-:- state=bad"; exit 6; fi
        printf 'current=%s pending=%s:%s state=%s\n' "${cur:--}" "${pend:--}" "${pto:--}" "$state"
        [ "$state" = ok ] || exit 1
        exit 0 ;;
    current)
        [ "$state" != bad ] || die 6 "the record is unreadable: $rec"
        [ "$state" = ok ] || die 1 "no usable record for $stem ($state)"
        print_token "$cur" "$dprefix" ;;
    tokens)
        [ "$state" != bad ] || die 6 "the record is unreadable: $rec"
        [ "$state" = ok ] || die 1 "no usable record for $stem ($state)"
        while read -r g pfx rkid; do
            { [ -n "$g" ] && [ "$rkid" = "$kid" ]; } || continue
            t="$(print_token "$g" "$pfx")" || exit 6
            printf '%s %s\n' "$g" "$t"
        done <<EOF
$minted
EOF
        ;;
    rotate)
        [ "$state" != bad ] || die 6 "the record is unreadable: $rec"
        [ "$state" = ok ] || die 4 "no usable record for $stem ($state)"
        ! { [ -f "$doc" ] && succession_names "$doc" "$to"; } \
            || die 4 "a handshake bullet already names $to: the worker took that chief without a fresh token"
        if [ -n "$pend" ] && [ "$pto" = "$to" ]; then
            print_token "$pend" "$dprefix"
            exit 0
        fi
        next=$((maxg + 1))
        out="$(print_token "$next" "$dprefix")" || exit 6
        # shellcheck disable=SC2016
        append '{v:1, stem:$s, gen:$g, event:"mint", kind:"rotate", prefix:$p, to:$t, keyid:$k, at:$at}' \
            --argjson g "$next" --arg p "$dprefix" --arg t "$to"
        printf '%s\n' "$out" ;;
    set)
        [ "$state" != bad ] || die 6 "the record is unreadable: $rec"
        found=0
        while read -r g pfx rkid; do
            if [ "$g" = "$want" ] && [ "$rkid" = "$kid" ]; then found=1; fi
        done <<EOF
$minted
EOF
        [ "$found" -eq 1 ] || die 4 "generation $want of $stem was never minted under the present key"
        # shellcheck disable=SC2016
        append '{v:1, stem:$s, gen:$g, event:"set", by:$by, keyid:$k, at:$at}' \
            --argjson g "$want" --arg by "${HIMMEL_BUS_NAME:--}" ;;
esac
