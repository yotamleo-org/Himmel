#!/usr/bin/env bash
# scripts/hooks/lib/read-clamp-state.sh — SOURCED by read-clamp.sh,
# record-read-clamp.sh and read-clamp-failure.sh: the himmel-read-clamp/v2 state.
#
# A Read consumes its range only when it SUCCEEDED and returned the whole range:
#   PreToolUse  (read-clamp.sh)          writes a PENDING record keyed by tool_use_id
#                                        (actor, request key, pre-read content hash);
#   PostToolUse (record-read-clamp.sh)   moves it to DONE only for a complete text
#                                        result whose file hash is unchanged;
#   PostToolUseFailure (read-clamp-failure.sh) deletes it.
# A Pre with no Post (a later guard denied, the call was interrupted) never consumes.
#
# Layout, under ${XDG_RUNTIME_DIR:-/run/user/<uid>}/himmel-read-clamp/v2/:
#   <sha(session_id)>/<sha(actor)>/format       "himmel-read-clamp/v2"
#   <sha(session_id)>/<sha(actor)>/done.tsv     "<key>\t<content sha>\t<HH:MM:SS>", newest last
#   <sha(session_id)>/<sha(actor)>/pending/<sha(tool_use_id)>
#                                               "<key>\t<content sha>\t<epoch>"
# The actor is the payload's agent_id inside a subagent and "root" on the main
# thread (agent_id is absent there): siblings and the parent never share state.
# A malformed identity skips tracking. Hashed identifiers keep raw ids off disk.
#
# Bounds: 256 pending records per actor, each expiring after an hour; 2048 done
# keys per actor, oldest evicted. Overflow or any state error skips tracking: a
# bound loses only the optimization, never read access. Files over 1 MiB (and
# anything not a regular text file) are not hashed, so they skip duplicate
# enforcement while keeping the size clamp.
#
# bash 3.2-safe. Every function returns non-zero on doubt; callers allow.

RC_FORMAT="himmel-read-clamp/v2"
RC_PENDING_MAX=256
RC_PENDING_TTL=3600
RC_DONE_MAX=2048
RC_HASH_MAX_BYTES=1048576

_rc_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_rc_lib_dir" != "${BASH_SOURCE[0]}" ] || _rc_lib_dir=.
# shellcheck source=scripts/lib/sha256-bin.sh
# shellcheck disable=SC1091
if ! { [ -r "$_rc_lib_dir/../../lib/sha256-bin.sh" ] && . "$_rc_lib_dir/../../lib/sha256-bin.sh"; } 2>/dev/null; then
    _SHA256_CMD=""
fi

rc_id_ok() {  # $1 = an id from the payload: [A-Za-z0-9._:-], 1-128 chars
    case "$1" in
        ''|*[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}

rc_hash_str() {  # $1 = string -> 32 hex
    local h
    h=$(printf '%s' "$1" | sha256_hex 2>/dev/null) || return 1  # swallow-ok: no hash means no tracking, the caller allows
    [ "${#h}" -ge 32 ] || return 1
    printf '%s\n' "${h:0:32}"
}

# rc_state_init <session_id> <agent_id_type> <agent_id> -> sets RC_DIR.
# agent_id_type is jq's `type` of .agent_id: null (main thread) or string.
rc_state_init() {
    local sid="$1" atype="$2" aid="$3" actor sh ah root
    rc_id_ok "$sid" || return 1
    case "$atype" in
        null) actor="root" ;;
        string) rc_id_ok "$aid" || return 1; actor="agent:$aid" ;;
        *) return 1 ;;
    esac
    sh=$(rc_hash_str "$sid") || return 1
    ah=$(rc_hash_str "$actor") || return 1
    root="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/himmel-read-clamp/v2"
    RC_DIR="$root/$sh/$ah"
    mkdir -p "$RC_DIR/pending" 2>/dev/null || return 1
    [ -d "$RC_DIR/pending" ] || return 1
    if [ -f "$RC_DIR/format" ]; then
        [ "$(cat "$RC_DIR/format" 2>/dev/null)" = "$RC_FORMAT" ] || return 1  # swallow-ok: an unreadable format marker skips tracking
    else
        printf '%s\n' "$RC_FORMAT" > "$RC_DIR/format" 2>/dev/null || return 1
    fi
}

# rc_key <absolute path> <offset> <limit> -> the request key (canonical text path + range).
rc_key() {
    local p="$1" d b canon
    case "$p" in /*) ;; *) return 1 ;; esac
    d="${p%/*}"; b="${p##*/}"
    [ -n "$d" ] || d=/
    [ -n "$b" ] || return 1
    canon="$(cd "$d" 2>/dev/null && pwd -P)" || return 1  # swallow-ok: an unresolvable dir skips tracking
    canon="${canon%/}/$b"
    rc_hash_str "$canon"$'\037'"$2"$'\037'"$3"
}

# rc_content_hash <path> -> sha of a regular text file up to 1 MiB, else fails.
rc_content_hash() {
    local f="$1" size
    [ -f "$f" ] && [ -r "$f" ] || return 1
    size=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || return 1  # swallow-ok: an unreadable size skips tracking
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -le "$RC_HASH_MAX_BYTES" ] || return 1
    if [ "$size" -gt 0 ]; then
        LC_ALL=C grep -qI -e '' "$f" 2>/dev/null || return 1
    fi
    sha256_hex "$f" 2>/dev/null
}

rc_extension_native() {  # $1 = path: image, PDF and notebook reads stay native
    case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
        png|jpg|jpeg|gif|webp|bmp|ico|pdf|ipynb) return 0 ;;
    esac
    return 1
}

# rc_done_lookup <key> <content sha> -> prints the stamp of a matching done row.
rc_done_lookup() {
    [ -f "$RC_DIR/done.tsv" ] || return 1
    awk -F '\t' -v k="$1" -v h="$2" '$1 == k && $2 == h { s = $3; f = 1 } END { if (f) print s; exit !f }' \
        "$RC_DIR/done.tsv" 2>/dev/null
}

rc_done_add() {  # <key> <content sha>
    local f="$RC_DIR/done.tsv" n
    printf '%s\t%s\t%s\n' "$1" "$2" "$(date '+%H:%M:%S')" >> "$f" 2>/dev/null || return 1
    n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')  # swallow-ok: an unreadable count skips eviction only
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$n" -gt "$RC_DONE_MAX" ]; then
        tail -n "$RC_DONE_MAX" "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
        rm -f "$f.tmp.$$" 2>/dev/null
    fi
    return 0
}

# rc_pending_add <tool_use_id> <key> <content sha>: prunes expired records, refuses past the cap.
rc_pending_add() {
    local tid="$1" th now f e n=0
    rc_id_ok "$tid" || return 1
    th=$(rc_hash_str "$tid") || return 1
    now=$(date +%s)
    for f in "$RC_DIR"/pending/*; do
        [ -f "$f" ] || continue
        e=$(cut -f3 < "$f" 2>/dev/null)  # swallow-ok: an unreadable record is checked as non-numeric and removed
        case "$e" in
            ''|*[!0-9]*) rm -f "$f"; continue ;;
        esac
        if [ $((now - e)) -ge "$RC_PENDING_TTL" ]; then rm -f "$f"; continue; fi
        n=$((n + 1))
    done
    [ "$n" -lt "$RC_PENDING_MAX" ] || return 1
    printf '%s\t%s\t%s\n' "$2" "$3" "$now" > "$RC_DIR/pending/$th.tmp.$$" 2>/dev/null || return 1
    mv -f "$RC_DIR/pending/$th.tmp.$$" "$RC_DIR/pending/$th" 2>/dev/null
}

# rc_pending_take <tool_use_id> -> prints "<key>\t<content sha>" and deletes the record.
rc_pending_take() {
    local tid="$1" th f row e
    rc_id_ok "$tid" || return 1
    th=$(rc_hash_str "$tid") || return 1
    f="$RC_DIR/pending/$th"
    [ -f "$f" ] || return 1
    row=$(cat "$f" 2>/dev/null)  # swallow-ok: an empty record fails the epoch check below
    rm -f "$f"
    e=$(printf '%s' "$row" | cut -f3)
    case "$e" in ''|*[!0-9]*) return 1 ;; esac
    [ $(($(date +%s) - e)) -lt "$RC_PENDING_TTL" ] || return 1
    printf '%s\n' "$row" | cut -f1,2
}
