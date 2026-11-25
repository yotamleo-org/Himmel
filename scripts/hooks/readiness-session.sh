#!/usr/bin/env bash
# readiness-session.sh - the readiness role's trusted, session-side lease owner (C0s cycle 2).
#
# The launcher (headed-arm-worker.sh --profile readiness) acquires the version's queue lease ON BEHALF of the session it
# is about to start, registers nothing for itself, and leaves two private files in a mode-0700 attempt directory named
# for the session id it minted: startup.json (the immutable session scope, doc, version, attempt id) and lease-token
# (the token transport). This script is the only reader of that pair after the launch:
#
#   startup              SessionStart hook (hook JSON on stdin). Silent no-op for any session that has no attempt
#                        directory. Otherwise: the ACTUAL startup session id (hook JSON session_id, and
#                        CLAUDE_CODE_SESSION_ID when set) must equal the minted scope, and the payload's transcript_path
#                        must be this session's own existing <session id>.jsonl; the transport is read through
#                        a private-file check; the lease is adopted with QUEUE_LOCK_SESSION_SCOPE set explicitly to
#                        that scope and that transcript is recorded as the lease's liveness marker (no ambient session
#                        id or config directory is consulted); the same-scope token file, .doc sidecar, CURRENT holder
#                        and liveness marker are verified; only
#                        then the private AttemptConfirmation is published and the transport removed. Any failure
#                        publishes nothing, so every act and finish refuses. Always exits 0 and prints nothing on
#                        stdout (a hook must never block or inject text); a refusal is one reason code on stderr.
#   verify <attempt-dir> exit 0 only if the confirmation is fresh and consistent with the startup config AND the
#                        adopted registration still names the current holder, whose heartbeat is fresh or, when the heartbeat
#                        cannot be read as a time, whose own transcript is young. The adapter runs it before EVERY act,
#                        finish included. Prints nothing; exit 1 = not adopted.
#   finish <attempt-dir> verify, then release exactly the token this session adopted (a successor's lock refuses it),
#                        then remove the attempt directory (the credential file included). Exit 0 only if released and
#                        the directory is gone.
#   cleanup              SessionEnd hook (hook JSON on stdin). Releases this session's own lease (the adopted token,
#                        also when the attempt no longer verifies, or the still-unadopted transport token) and removes its
#                        attempt directory; silent, exit 0. The host
#                        gives a SessionEnd hook a short shared budget and cancels what has not returned, so the verb returns
#                        at once and a detached copy of itself does the release (see the cleanup block below). A cleanup that
#                        is cut off, fails or is refused leaves the lease held and the attempt directory in place; the
#                        directory then carries a one-line cleanup-failed file, and `queue-lock.sh status --sweep` (the
#                        chief's LOCKS check) lists the lease.
#
# No token or credential is ever printed, logged or placed in an argument list of this script; queue-lock.sh is
# SOURCED (not run), so the token only moves between shell variables and its own private files. Its own output is
# discarded because adopt/acquire/release echo the token. queue-lock.sh itself is unchanged. The library that is sourced
# is the project's own scripts/handover/queue-lock.sh, spelled from CLAUDE_PROJECT_DIR (Claude Code exports the project
# root to a hook; the adapter exports its own checkout's root to the child it runs) so the hook-integrity walk can resolve
# and verify its bytes in every layout this file is installed in, the plugin copy included. The startup config the trusted
# launcher wrote names the library it acquired the lease with (queue_lock) and is only checked for EQUALITY with it, so the
# private config can refuse a session but can never choose what code runs. A project root that is missing, empty, relative
# or another checkout than the launcher's refuses every verb (fail closed).
#
# Platform: bash 3.2+, Linux/macOS (stat -c with a stat -f fallback).
set -u
umask 077

RS_WHY="" RS_HOOK_SID="" RS_HOOK_TR=""
RS_SCOPE="" RS_DOC="" RS_VERSION="" RS_ATTEMPT_ID="" RS_QL="" RS_XDG="" RS_HDIR=""
RS_QL_LIB="${CLAUDE_PROJECT_DIR:-}/scripts/handover/queue-lock.sh"
RS_DETACH_LIB="${CLAUDE_PROJECT_DIR:-}/scripts/lib/detach.sh"
RS_TIMEOUT_LIB="${CLAUDE_PROJECT_DIR:-}/scripts/lib/timeout-bin.sh"
# the one-shot bound of the detached cleanup, in seconds: a release takes a fraction of a second and the longest wait inside the
# queue library is its own 15 s bound on the close-evidence call, so 30 s stops only a cleanup that is wedged
RS_CLEANUP_BOUND_SECS=30
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
TOKEN_RE='^[A-Za-z0-9._-]+$'

_rs_stat() { stat -c "$1" -- "$3" 2>/dev/null || stat -f "$2" -- "$3" 2>/dev/null; }
_rs_private_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(_rs_stat %u %u "$1")" = "$(id -u)" ] && [ "$(_rs_stat %a %Lp "$1")" = 700 ]
}
_rs_private_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(_rs_stat %u %u "$1")" = "$(id -u)" ] && [ "$(_rs_stat %a %Lp "$1")" = 600 ] && [ "$(_rs_stat %h %l "$1")" = 1 ]
}
_rs_refuse() { echo "readiness-session: $*" >&2; }
_rs_root() {
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then printf '%s/himmel-readiness' "$XDG_RUNTIME_DIR"; else printf '/tmp/himmel-readiness-%s' "$(id -u)"; fi
}
# the session id and transcript path out of the hook JSON on stdin (a hook payload is small): RS_HOOK_SID, RS_HOOK_TR
_rs_hook_read() {
    local raw
    RS_HOOK_SID="" RS_HOOK_TR=""
    raw="$(head -c 65536)" || return 1
    RS_HOOK_SID="$(printf '%s' "$raw" | jq -r 'select(type == "object") | .session_id // empty' 2>/dev/null)"  # swallow-ok: an unparsable payload reads as no session id and the hook is a no-op
    RS_HOOK_TR="$(printf '%s' "$raw" | jq -r 'select(type == "object") | .transcript_path // empty | select(type == "string")' 2>/dev/null)"  # swallow-ok: an unparsable or non-string path reads empty and refuses at adoption
}
# a session's own transcript: an absolute path to a regular, non-symlink file named <session id>.jsonl
_rs_transcript_ok() { # <path> <session id>
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *$'\n'*) return 1 ;; esac
    [ "${1##*/}" = "$2.jsonl" ] && [ -f "$1" ] && [ ! -L "$1" ]
}

# the startup-bound queue_lock must be exactly the library this script sources: the same physical directory and the same
# name, both existing, under an absolute project root. Compared as resolved directories (cd -P), so neither a relative
# spelling nor a symlinked directory can make two different files look equal.
_rs_ql_bound() {
    local bound lib
    case "${CLAUDE_PROJECT_DIR:-}" in /*) ;; *) return 1 ;; esac
    [ -f "$RS_QL_LIB" ] || return 1
    bound="$(cd -P "$(dirname "$RS_QL")" 2>/dev/null && pwd -P)" || return 1  # swallow-ok: a directory that cannot be entered fails this assignment and refuses
    lib="$(cd -P "$(dirname "$RS_QL_LIB")" 2>/dev/null && pwd -P)" || return 1  # swallow-ok: a directory that cannot be entered fails this assignment and refuses
    [ -n "$bound" ] && [ "$bound" = "$lib" ] && [ "${RS_QL##*/}" = "${RS_QL_LIB##*/}" ]
}

# _rs_load <attempt-dir> [<expected session id>]: validate the private directory and its startup config and load it
# into RS_*. The directory is named for the minted id and the file must say the same, so a copied or renamed
# directory never binds another session.
_rs_load() {
    local dir="$1" want="${2:-}"
    command -v jq >/dev/null 2>&1 || { RS_WHY=no-jq; return 1; }
    case "$dir" in /*) ;; *) RS_WHY=attempt-path; return 1 ;; esac
    _rs_private_dir "$dir" || { RS_WHY=attempt-dir; return 1; }
    _rs_private_file "$dir/startup.json" || { RS_WHY=startup-file; return 1; }
    jq -e 'type == "object" and .schema == "readiness-startup-v1" and .lane == "native"' "$dir/startup.json" >/dev/null 2>&1 || { RS_WHY=startup-schema; return 1; }
    RS_SCOPE="$(jq -r '.session_scope // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    RS_DOC="$(jq -r '.doc // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    RS_VERSION="$(jq -r '.version // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    RS_ATTEMPT_ID="$(jq -r '.attempt_id // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    RS_QL="$(jq -r '.queue_lock // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    # the launcher's own queue environment, so the hook and the adapter (whose MCP environment is minimal) resolve the
    # same token directory and handover root the lease was acquired under
    RS_XDG="$(jq -r '.runtime_dir // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    RS_HDIR="$(jq -r '.handover_dir // empty' "$dir/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty and every required field is refused when empty
    [[ "$RS_SCOPE" =~ $UUID_RE ]] || { RS_WHY=startup-scope; return 1; }
    [ "${dir##*/}" = "$RS_SCOPE" ] || { RS_WHY=scope-dir-mismatch; return 1; }
    [ -z "$want" ] || [ "$want" = "$RS_SCOPE" ] || { RS_WHY=scope-mismatch; return 1; }
    case "$RS_DOC" in /*) { [ -f "$RS_DOC" ] && [ -r "$RS_DOC" ]; } || { RS_WHY=startup-doc; return 1; } ;; *) RS_WHY=startup-doc; return 1 ;; esac
    [ -n "$RS_VERSION" ] && [ -n "$RS_ATTEMPT_ID" ] || { RS_WHY=startup-fields; return 1; }
    case "$RS_QL" in /*/queue-lock.sh) [ -f "$RS_QL" ] || { RS_WHY=startup-queue-lock; return 1; } ;; *) RS_WHY=startup-queue-lock; return 1 ;; esac
    _rs_ql_bound || { RS_WHY=startup-queue-lock; return 1; }
    case "$RS_XDG" in ''|/*) ;; *) RS_WHY=startup-env; return 1 ;; esac
    case "$RS_HDIR" in ''|/*) ;; *) RS_WHY=startup-env; return 1 ;; esac
    return 0
}

# the queue environment of the launch that acquired this lease, applied inside each queue-lock subshell
_rs_queue_env() {
    # no ambient session id: the queue helpers' own transcript lookup stays inert, so the liveness marker comes only from
    # the SessionStart payload this script validated
    unset QUEUE_LOCK_FORCE_RELEASE QUEUE_LOCK_TAKEOVER QUEUE_LOCK_ON_BEHALF CLAUDE_CODE_SESSION_ID
    if [ -n "$RS_XDG" ]; then XDG_RUNTIME_DIR="$RS_XDG"; export XDG_RUNTIME_DIR; else unset XDG_RUNTIME_DIR; fi
    if [ -n "$RS_HDIR" ]; then HANDOVER_DIR="$RS_HDIR"; export HANDOVER_DIR; else unset HANDOVER_DIR; fi
    QUEUE_LOCK_SESSION_SCOPE="$RS_SCOPE"; export QUEUE_LOCK_SESSION_SCOPE
}

# the adopted registration: this scope's own token file and .doc sidecar name the doc and its lock, the lock's current
# holder is that token, and the lock is fresh. Runs queue-lock.sh in a subshell with the scope set explicitly.
_rs_registration_ok() {
    (
        _rs_queue_env
        # shellcheck source=/dev/null
        . "$RS_QL_LIB" >/dev/null 2>&1 || exit 1
        _ql_enter "$RS_DOC" x >/dev/null 2>&1 || exit 1
        lock="$_QL_LOCKDIR"; doc="$_QL_DOC"
        tok="$(_ql_token_recall "$doc" 2>/dev/null)" || exit 1  # swallow-ok: the recall note names the token file; a failed recall exits 1
        [ -n "$tok" ] || exit 1
        _ql_owner_matches "$lock" "$tok" || exit 1
        tf="$(_ql_token_file "$doc" "$tok")" || exit 1
        sdir="$(_ql_sidecar_dir)" || exit 1
        sc="$sdir/${tf##*/}.doc"
        { [ -f "$sc" ] && [ -r "$sc" ]; } || exit 1
        { IFS= read -r sc_doc; IFS= read -r sc_lock; } < "$sc"
        [ "$sc_doc" = "$doc" ] && [ "$sc_lock" = "$lock" ] || exit 1
        hb="$(_ql_json_field "$lock/owner.json" heartbeat)"
        if [ -n "$hb" ] && [ -n "$(_ql_epoch_of_iso "$hb")" ]; then
            _ql_lock_is_fresh "$lock" || exit 1
        else
            _ql_holder_live "$lock" "${QUEUE_LOCK_TTL_SECONDS:-21600}" || exit 1
        fi
        # liveness: this host and this session's OWN existing transcript, so an idle-but-alive session outlives an old heartbeat
        lv="$lock/liveness"
        { [ -f "$lv" ] && [ -r "$lv" ] && [ ! -L "$lv" ]; } || exit 1
        lv_host="$(sed -n 's/^host=//p' "$lv" | head -n 1)"
        lv_tr="$(sed -n 's/^transcript=//p' "$lv" | head -n 1)"
        { [ -n "$lv_host" ] && [ "$lv_host" = "$(_ql_hostname)" ]; } || exit 1
        _rs_transcript_ok "$lv_tr" "$RS_SCOPE" || exit 1
    ) >/dev/null 2>&1
}

# the private AttemptConfirmation must agree with the startup config on every field
_rs_confirmation_ok() {
    local dir="$1"
    _rs_private_file "$dir/confirmation.json" || return 1
    jq -e --arg sid "$RS_SCOPE" --arg doc "$RS_DOC" --arg ver "$RS_VERSION" --arg att "$RS_ATTEMPT_ID" \
        'type == "object" and (keys | length) == 7 and .schema == "readiness-attempt-v1" and .attempt_id == $att and .doc == $doc
         and .version == $ver and .session_scope == $sid and .startup_session_id == $sid and .adopted == true' \
        "$dir/confirmation.json" >/dev/null 2>&1
}

# release <token or empty = the one this scope adopted>; a token that is not the holder's refuses, nothing is forced
_rs_release() {
    (
        _rs_queue_env
        # shellcheck source=/dev/null
        . "$RS_QL_LIB" >/dev/null 2>&1 || exit 1
        tok="${1:-}"
        [ -n "$tok" ] || tok="$(_ql_token_recall "$RS_DOC" 2>/dev/null)" || exit 1  # swallow-ok: the recall note names the token file; a failed recall exits 1
        [ -n "$tok" ] || exit 1
        queue_lock_release "$RS_DOC" "$tok" >/dev/null 2>&1
    ) >/dev/null 2>&1
}

# the attempt directory is removed only when it is exactly the directory this script validated
_rs_remove_attempt() {
    [ "${1##*/}" = "$RS_SCOPE" ] && [ -f "$1/startup.json" ] && rm -rf -- "$1"
}

_rs_transport_token() {
    local f="$1/lease-token" tok
    _rs_private_file "$f" || return 1
    tok="$(head -c 256 "$f")" || return 1  # read-sink-ok: the lease-token file in this session's own attempt directory, which _rs_load validated; the line above admits only a regular, non-symlink, own-uid, mode-600, single-link file
    tok="${tok%%$'\n'*}"
    [[ "$tok" =~ $TOKEN_RE ]] || return 1
    printf '%s' "$tok"
}

_rs_verify() { # <attempt-dir>
    _rs_load "$1" "" || return 1
    _rs_confirmation_ok "$1" || { RS_WHY=confirmation; return 1; }
    [ ! -e "$1/lease-token" ] || { RS_WHY=transport-present; return 1; }
    _rs_registration_ok || { RS_WHY=registration; return 1; }
}

cmd_startup() {
    local sid dir tok pub
    _rs_hook_read || exit 0
    sid="$RS_HOOK_SID"
    [[ "$sid" =~ $UUID_RE ]] || exit 0
    dir="$(_rs_root)/$sid"
    [ -e "$dir" ] || exit 0
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$CLAUDE_CODE_SESSION_ID" != "$sid" ]; then
        _rs_refuse "session-id-mismatch"
        exit 0
    fi
    _rs_load "$dir" "$sid" || { _rs_refuse "$RS_WHY"; exit 0; }
    # a repeat of the hook (a resume or compaction) after a good adoption changes nothing
    if _rs_verify "$dir"; then exit 0; fi
    # the session's own transcript, from the payload, must exist before anything is adopted
    _rs_transcript_ok "$RS_HOOK_TR" "$sid" || { _rs_refuse "no-transcript"; exit 0; }
    tok="$(_rs_transport_token "$dir")" || { _rs_refuse "no-transport"; exit 0; }
    if ! (
        _rs_queue_env
        # shellcheck source=/dev/null
        . "$RS_QL_LIB" >/dev/null 2>&1 || exit 1
        queue_lock_adopt "$RS_DOC" "$tok" >/dev/null 2>&1 || exit 1
        # the liveness marker, written only while this token still holds the lock, names the payload's transcript
        _ql_owner_matches "$_QL_LOCKDIR" "$tok" || exit 1
        _ql_write_liveness "$_QL_LOCKDIR" "$RS_HOOK_TR"
    ); then
        _rs_refuse "adopt-refused"
        exit 0
    fi
    _rs_registration_ok || { _rs_refuse "adopted-registration-unverified"; exit 0; }
    pub="$(mktemp "$dir/.confirmation.XXXXXX")" || { _rs_refuse "confirmation-not-published"; exit 0; }
    if ! jq -cn --arg att "$RS_ATTEMPT_ID" --arg doc "$RS_DOC" --arg ver "$RS_VERSION" --arg sid "$sid" \
        '{schema:"readiness-attempt-v1",attempt_id:$att,doc:$doc,version:$ver,session_scope:$sid,startup_session_id:$sid,adopted:true}' > "$pub" 2>/dev/null \
        || ! mv -f -- "$pub" "$dir/confirmation.json" 2>/dev/null; then
        rm -f -- "$pub"
        _rs_refuse "confirmation-not-published"
        exit 0
    fi
    _rs_confirmation_ok "$dir" || { rm -f -- "$dir/confirmation.json"; _rs_refuse "confirmation-invalid"; exit 0; }
    rm -f -- "$dir/lease-token"
    exit 0
}

cmd_verify() {
    [ "$#" -eq 1 ] || exit 2
    _rs_verify "$1" || { _rs_refuse "not adopted ($RS_WHY)"; exit 1; }
    exit 0
}

cmd_finish() {
    [ "$#" -eq 1 ] || exit 2
    _rs_verify "$1" || { _rs_refuse "not adopted ($RS_WHY)"; exit 1; }
    _rs_release "" || { _rs_refuse "release refused (the lock is not this session's)"; exit 1; }
    _rs_remove_attempt "$1" 2>/dev/null
    [ ! -e "$1" ] || { _rs_refuse "attempt-dir-kept"; exit 1; }
    exit 0
}

cmd_cleanup() {
    local sid dir tok=""
    _rs_hook_read || exit 0
    sid="$RS_HOOK_SID"
    [[ "$sid" =~ $UUID_RE ]] || exit 0
    dir="$(_rs_root)/$sid"
    [ -e "$dir" ] || exit 0
    _rs_load "$dir" "$sid" || { _rs_refuse "$RS_WHY"; exit 0; }
    _rs_verify "$dir" || tok="$(_rs_transport_token "$dir")" || tok=""
    _rs_release "$tok" || { _rs_refuse "release refused (the lock is not this session's)"; exit 0; }
    _rs_remove_attempt "$dir"
    exit 0
}

# --- cleanup as the SessionEnd hook: it returns at once and a detached, bounded copy of cmd_cleanup does the release ---------
# The host gives a SessionEnd hook one short budget (a plugin cannot raise it) and cancels what has not returned; a cancel
# before the release finishes leaves the lease held and the attempt directory behind. Three forms of the verb, one body:
#   cleanup                          the hook: reads the payload, starts the next form in a new session (lib/detach.sh, as the
#                                    other SessionEnd hooks do) and exits 0 at once. A session with no attempt directory
#                                    starts nothing.
#   cleanup __himmel_detached <sid>  the detached copy: runs the next form under a one-shot timeout (lib/timeout-bin.sh) of
#                                    RS_CLEANUP_BOUND_SECS. When the attempt directory is still there afterwards (the cleanup
#                                    was cut off, failed or was refused) it writes one line, cleanup-failed, into it.
#   cleanup __himmel_bounded <sid>   the unchanged cmd_cleanup, fed a payload that names the session.
# A project root that is not the checkout the launcher bound runs cmd_cleanup in place, which refuses (fail closed): the two
# libraries are sourced only from the bound root. Nothing here frees a lease by age or runs more than once.
_rs_cleanup_inplace() { # <session id>
    cmd_cleanup <<< "{\"session_id\":\"$1\"}"
}
# the project root is the checkout the launcher bound: the startup config's queue_lock names this root's library
_rs_project_bound() { # <attempt-dir>
    RS_QL="$(jq -r '.queue_lock // empty' "$1/startup.json" 2>/dev/null)"  # swallow-ok: an unreadable field reads empty, which is not bound
    _rs_ql_bound
}
_rs_cleanup_bound() {
    local v="${READINESS_SESSION_CLEANUP_BOUND_SECS:-}"
    case "$v" in ''|*[!0-9]*|?????*) v="$RS_CLEANUP_BOUND_SECS" ;; esac
    { [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 120 ]; } || v="$RS_CLEANUP_BOUND_SECS"
    printf '%s' "$((10#$v))"
}
_rs_cleanup_start() {
    local sid dir
    _rs_hook_read || exit 0
    sid="$RS_HOOK_SID"
    [[ "$sid" =~ $UUID_RE ]] || exit 0
    dir="$(_rs_root)/$sid"
    [ -e "$dir" ] || exit 0
    if _rs_project_bound "$dir" && [ -r "$RS_DETACH_LIB" ]; then
        # shellcheck source=/dev/null
        . "$RS_DETACH_LIB" >/dev/null 2>&1 || _rs_cleanup_inplace "$sid"
        detach_run bash "${BASH_SOURCE[0]}" cleanup __himmel_detached "$sid"
        exit 0
    fi
    _rs_cleanup_inplace "$sid"
}
_rs_cleanup_supervise() { # <session id>
    local sid="${1:-}" dir bound err="" rc=0 why
    [[ "$sid" =~ $UUID_RE ]] || exit 0
    dir="$(_rs_root)/$sid"
    [ -e "$dir" ] || exit 0
    bound="$(_rs_cleanup_bound)"
    _TIMEOUT_BIN=""
    if _rs_project_bound "$dir" && [ -r "$RS_TIMEOUT_LIB" ]; then
        # shellcheck source=/dev/null
        . "$RS_TIMEOUT_LIB" >/dev/null 2>&1 || _TIMEOUT_BIN=""
    fi
    err="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 "$bound"} bash "${BASH_SOURCE[0]}" cleanup __himmel_bounded "$sid" 2>&1 >/dev/null)" || rc=$?
    if { [ "$rc" -ne 0 ] || [ -n "$err" ]; } && [ -f "$dir/startup.json" ] && _rs_private_dir "$dir"; then
        case "$rc" in
            124|137) why="did not finish within ${bound}s and was stopped" ;;
            0) why="refused: $(printf '%s' "$err" | tr '\n' ' ' | head -c 200)" ;;
            *) why="exited $rc: $(printf '%s' "$err" | tr '\n' ' ' | head -c 200)" ;;
        esac
        printf '%s cleanup %s; the lease and this directory remain (queue-lock.sh status --sweep)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$why" > "$dir/cleanup-failed" 2>/dev/null  # swallow-ok: the marker is a courtesy; the lease and the directory themselves are the record
    fi
    exit 0
}
_rs_cleanup_worker() { # <session id>
    local sid="${1:-}"
    [[ "$sid" =~ $UUID_RE ]] || exit 0
    # test seam: seconds to wait before the release, so a row can see the hook return while the lease is still held
    case "${READINESS_SESSION_TEST_DELAY:-}" in ''|*[!0-9]*) ;; *) sleep "$READINESS_SESSION_TEST_DELAY" ;; esac
    _rs_cleanup_inplace "$sid"
}
# each of the three ends the process
cmd_cleanup_hook() {
    if [ "${1:-}" = "__himmel_bounded" ]; then _rs_cleanup_worker "${2:-}"; fi
    if [ "${1:-}" != "__himmel_detached" ]; then _rs_cleanup_start; fi
    _rs_cleanup_supervise "${2:-}"
}

case "${1:-}" in
    startup) shift; cmd_startup "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    finish) shift; cmd_finish "$@" ;;
    cleanup) shift; cmd_cleanup_hook "$@" ;;
    *) echo "usage: readiness-session.sh startup|cleanup (hook JSON on stdin) | verify|finish <attempt-dir>" >&2; exit 2 ;;
esac
