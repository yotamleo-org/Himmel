#!/usr/bin/env bash
# peer-taint-gate.sh — PreToolUse hook (matcher "*") for the peer bridge.
#
# A session that has read peer text (a taint file under the bridge state dir) or
# runs as a peer desk (PEER_DESK set) may only run the two peer-bridge command
# shapes: read.ts to print digests, and send.ts with one single-quoted line of
# text. Every other tool call is denied. Any session, tainted or not, is denied a
# file tool or command that names the bridge state dir or key dir.
#
# Delivered by the himmel-ops PLUGIN lane so it also runs in a desk, whose cwd is
# an empty dir outside every checkout. scripts/hooks/peer-taint-gate.sh is a
# byte-identical copy for the Codex lane. Self-contained: sources nothing.
#
# Decision order:
#   1. Neither ~/.himmel/peer-bridge nor ~/.config/himmel/peer-bridge exists:
#      exit 0 before reading stdin. No bridge, nothing to guard, jq not needed.
#   2. jq missing or failing, stdin unparsable, a field of the wrong type, a NUL
#      in a field, or a non-empty session_id outside ^[A-Za-z0-9-]{1,64}$: deny.
#   3. Path floor, every session: a file tool path, or a Glob pattern, that
#      canonicalizes under either dir (or whose raw spelling starts with either
#      dir when its parent cannot be canonicalized), and a Bash or Monitor
#      command that names either dir, are denied.
#   4. Restricted = taint/<sid> exists, or any taint/<sid>.pending.* exists, or
#      PEER_DESK is set. A taint dir that exists but cannot be listed denies.
#   5. Restricted: allow only Bash or Monitor whose command has no control byte
#      and wholly matches one of the two shapes, under the himmelRoot that
#      peers.json records (never CLAUDE_PROJECT_DIR):
#        bun <root>/scripts/peer-bridge/read.ts <peer>( --thread N)?( --ack TOKEN)?
#        bun <root>/scripts/peer-bridge/send.ts <peer> (--kind (status|info) |--kind answer --reply-to N )--text '<text>'
#   6. Otherwise exit 0.
# A read-shape command writes the stamp hooked/<sid> (epoch seconds), tainted or
# not. In a desk the read shape also prints an explicit allow, so no permission
# prompt sits between the stamp and the run; the send shape gets no allow, so
# the operator still approves every message to a peer.
#
# The grammar is finite: bash expands nothing inside single quotes, history
# expansion is off in non-interactive bash, and the control-byte check rules
# out a multi-line command. Length is the egress gate's rule, not this one.
#
# Exit codes: 0 allow, 2 deny with a one-line reason on stderr. Any other
# outcome of the body also exits 2 (ERR trap plus the rc check at the end).
# Clearing a taint: a human at a terminal runs scripts/peer-bridge/untaint.sh <session_id>.
#
# ponytail: a harness timeout kill allows the call, so the gate stays small enough to finish far inside its timeout, upgrade path the harness denies a PreToolUse call whose hook was killed.
# ponytail: the path floor is an accidental-leak floor, the same ceiling as block-read-secrets; a relative path from a cwd outside both dirs evades it, upgrade path the bridge state is owned by its own sandboxed user.
#
# Bash 3.2-compatible.

S="${HOME:-}/.himmel/peer-bridge"
C="${HOME:-}/.config/himmel/peer-bridge"
if [ ! -e "$S" ] && [ ! -e "$C" ]; then exit 0; fi # guard:inert

LC_ALL=C
export LC_ALL
set -E
trap 'exit 2' ERR

deny() {
    printf 'peer-taint-gate: %s\n' "$1" >&2
    exit 2
}

canon_dir() {
    # canon_dir DIR: the physical path of an existing dir, or nothing.
    (cd -P "$1" 2>/dev/null && pwd -P) || true
}

under() {
    # under PATH PREFIX: PATH is PREFIX or below it. An empty PREFIX matches nothing.
    [ -n "$2" ] || return 1
    case "$1" in "$2"|"$2"/*) return 0 ;; esac
    return 1
}

floor_path() {
    # floor_path VALUE: deny when VALUE names either bridge dir.
    local v="$1" d b cd
    [ -n "$v" ] || return 0
    case "$v" in \~) v="${HOME:-}" ;; \~/*) v="${HOME:-}/${v#\~/}" ;; esac
    while :; do
        case "$v" in ?*/) v="${v%/}" ;; *) break ;; esac
    done
    if under "$v" "$S" || under "$v" "$C" || under "$v" "$Sc" || under "$v" "$Cc"; then
        deny "the peer-bridge state and key dirs are off limits to every session ($1)"
    fi
    case "$v" in */*) d="${v%/*}"; b="${v##*/}"; [ -n "$d" ] || d=/ ;; *) d=.; b="$v" ;; esac
    cd=$(canon_dir "$d")
    [ -n "$cd" ] || return 0
    case "$cd" in /) cd="/$b" ;; *) cd="$cd/$b" ;; esac
    if under "$cd" "$Sc" || under "$cd" "$Cc"; then
        deny "the peer-bridge state and key dirs are off limits to every session ($1)"
    fi
    return 0
}

path_floor() {
    floor_path "$fp"
    floor_path "$pth"
    floor_path "$nbp"
    if [ "$tool" = Glob ]; then floor_path "$pat"; fi
    if [ "$tool" = Bash ] || [ "$tool" = Monitor ]; then
        case "$cmd" in
            *.himmel/peer-bridge*|*.config/himmel/peer-bridge*)
                deny "the peer-bridge state and key dirs are off limits to every session (command names one)" ;;
        esac
    fi
    return 0
}

himmel_root() {
    # The primary checkout peers.json records; empty when absent or not a plain absolute path.
    local r
    r=$(jq -r '.himmelRoot | if type == "string" then . else empty end' "$C/peers.json" 2>/dev/null) || r="" # swallow-ok: no readable root means no shape matches, the deny side
    case "$r" in /*) ;; *) r="" ;; esac
    case "$r" in *[[:cntrl:]]*) r="" ;; esac
    printf '%s' "$r"
}

shape() {
    # shape: prints read, send or nothing for $cmd under $root.
    local rest pre_r pre_s
    local re_read='^[a-z0-9-]+( --thread [0-9]+)?( --ack [A-Za-z0-9]+)?$'
    local re_send="^[a-z0-9-]+ (--kind (status|info) |--kind answer --reply-to [0-9]+ )--text '[^']+'\$"
    [ -n "$root" ] || return 0
    case "$cmd" in *[[:cntrl:]]*) return 0 ;; esac # guard:ctl
    pre_r="bun $root/scripts/peer-bridge/read.ts "
    pre_s="bun $root/scripts/peer-bridge/send.ts "
    case "$cmd" in
        "$pre_r"*)
            rest="${cmd#"$pre_r"}"
            if [[ $rest =~ $re_read ]]; then printf read; fi ;;
        "$pre_s"*)
            rest="${cmd#"$pre_s"}"
            if [[ $rest =~ $re_send ]]; then printf send; fi ;;
    esac
    return 0
}

main() {
    local parsed restricted=0 f kind=""
    if ! command -v jq >/dev/null 2>&1; then deny "jq is required once a peer bridge exists"; fi
    # shellcheck disable=SC2016 # jq program, not shell
    parsed=$(jq -r '
        def s: if . == null then "" elif type == "string" then . else error("field type") end;
        (.tool_input // {}) as $ti
        | if ($ti | type) != "object" then error("tool_input type") else . end
        | [(.session_id | s), (.tool_name | s), ($ti.command | s), ($ti.file_path | s),
           ($ti.path | s), ($ti.notebook_path | s), ($ti.pattern | s)] as $v
        | ($v | map(index("\u0000")) | any(. != null)) as $nul
        | @sh "sid=\($v[0]) tool=\($v[1]) cmd=\($v[2]) fp=\($v[3]) pth=\($v[4]) nbp=\($v[5]) pat=\($v[6]) nul=\($nul)"
    ' 2>/dev/null) || deny "unparsable hook input" # guard:failclosed
    sid="" tool="" cmd="" fp="" pth="" nbp="" pat="" nul=""
    eval "$parsed"
    if [ "$nul" != false ]; then deny "a NUL byte in the hook input"; fi
    if [ -n "$sid" ]; then
        if [ "${#sid}" -gt 64 ]; then deny "invalid session_id"; fi
        case "$sid" in *[!A-Za-z0-9-]*) deny "invalid session_id" ;; esac
    fi

    Sc=$(canon_dir "$S")
    Cc=$(canon_dir "$C")
    path_floor # guard:floor

    root=""
    if [ "$tool" = Bash ] || [ "$tool" = Monitor ]; then
        case "$cmd" in bun\ *) root=$(himmel_root) ;; esac
    fi
    kind=$(shape)

    if [ "$kind" = read ] && [ -n "$sid" ] && [ -d "$S" ]; then
        if [ ! -d "$S/hooked" ]; then mkdir -m 700 "$S/hooked"; fi
        date +%s > "$S/hooked/$sid"
    fi

    if [ -n "$sid" ] && [ -e "$S/taint" ]; then
        if [ ! -d "$S/taint" ] || [ ! -r "$S/taint" ] || [ ! -x "$S/taint" ]; then
            deny "cannot read the taint state"
        fi
        if [ -e "$S/taint/$sid" ]; then restricted=1; fi
        for f in "$S/taint/$sid".pending.*; do
            if [ -e "$f" ]; then restricted=1; fi
        done
    fi
    if [ -n "${PEER_DESK:-}" ]; then restricted=1; fi # guard:desk

    if [ "$restricted" = 1 ]; then
        case "$kind" in
            read)
                if [ -n "${PEER_DESK:-}" ]; then
                    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
                fi
                exit 0 ;;
            send) exit 0 ;;
        esac
        deny "this session has read peer text or is a peer desk: only read.ts and one-line send.ts commands run (a human clears it with scripts/peer-bridge/untaint.sh)"
    fi
    exit 0
}

main
# shellcheck disable=SC2317 # reached when main returns instead of exiting
rc=$?
[ "$rc" = 0 ] || exit 2
