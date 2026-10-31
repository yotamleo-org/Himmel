#!/usr/bin/env bash
# claudex-inbox.sh — cursor bookkeeping shared by the two claudex-inbox hook
# scripts (PostToolUse and the SessionStart mirror) and exercised directly by
# scripts/hooks/test-inbox-hook.sh.
#
# PLATFORM GUARD: Linux-only (the claudex lane).
# Source scripts/lib/handover-path.sh before this file for handover_root().
#
# Delivery transaction: inbox_with_lock holds a session-keyed
# flock across peek, caller delivery, and commit. Call peek in the SAME shell,
# not command substitution: it sets inbox_bullets and a pending cursor without
# writing it. Commit only after successful serialization/stdout. The legacy
# inbox_new_bullets entry point follows the same contract for raw stdout.
# Missing flock retains unlocked delivery; other lock failures leave pending
# content untouched. Hooks remain fail-open. Absent inboxes need no lock.
#
# RETASK model (docs/internals/retask-channel.md): paths come ONLY from
# handover_root() + a validated session name, never from reviewed repo content.
inbox_with_lock() (
    local name="$1" root cursor_dir
    shift
    case "$name" in ''|*/*|*..*|*[[:space:]]*) return 0 ;; esac
    root="$(handover_root 2>/dev/null)" || return 0
    [ -n "$root" ] && [ -f "$root/inbox/$name.md" ] || return 0
    cursor_dir="$root/inbox/.cursor"
    mkdir -p "$cursor_dir" 2>/dev/null || return 0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$cursor_dir/$name.lock" || return 0
        # prim-ok: hook-sourced and fail-open (a lock failure returns 0 and skips the callback); with_lock would add a prim.sh load to the hook path and fail closed.
        flock -x 9 || return 0
    fi
    # The subshell owns descriptor 9, so every exit releases the lock.
    "$@" "$name"
)

# Provenance gate: anyone who can append the synced vault can
# write an inbox line and copy a RETASK token into it, so a line is delivered
# only when its sha256 is in a chief sent-record ledger inbox-send.sh wrote
# before appending it, on a record naming this session as the recipient. A
# ledger is trusted only when it, its directory and its base are owned by this
# uid, none is a symlink, and neither the file nor its directory is group- or
# world-writable. Exit 1 when a trusted ledger cannot be read. The bases are
# HIMMEL_CONSOLE_RUNDIR, $XDG_RUNTIME_DIR/himmel-chief and
# ${TMPDIR:-/tmp}/himmel-chief-<uid>, so a sender whose environment picked
# another default (cron has no XDG_RUNTIME_DIR) is still found.
# ponytail: same-uid local writers can still write the ledger; HMAC with a key outside reach of the session would close it.
inbox_ledger_shas() { # <session>
    local base f d rc=0
    for base in "${HIMMEL_CONSOLE_RUNDIR:-}" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/himmel-chief}" "${TMPDIR:-/tmp}/himmel-chief-$(id -u)"; do
        [ -n "$base" ] && [ -d "$base" ] && [ ! -L "$base" ] && [ -O "$base" ] || continue
        for f in "$base"/inbox-sent.log "$base"/*/inbox-sent.log; do
            d="${f%/*}"
            [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
            # Both paths must print; a failed probe trusts nothing.
            [ "$(find "$f" "$d" -maxdepth 0 ! -perm /022 2>/dev/null | wc -l)" -eq 2 ] || continue
            INBOX_LEDGER_TO="$1" awk '$5 == ENVIRON["INBOX_LEDGER_TO"] { print $4 }' "$f" 2>/dev/null || rc=1
        done
    done
    return "$rc"
}

# Alerts the chief (cadence-alert.sh's chief-readable alert file, plus one
# operator Telegram per session until cleared). Never fails the delivery.
inbox_alert() { # <summary> <inbox> <cause> <do>
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
    bash "$here/../luna/cadence-alert.sh" fail claudex-inbox "$1" "$2" "$3" "$4" \
        </dev/null >/dev/null 2>&1 || true
}

inbox_peek() {
    local name="$1" root inbox size cursor raw partial line sha pool kept refused nl
    inbox_bullets=""
    inbox_cursor_file=""
    inbox_cursor_size=""
    inbox_refused=0
    inbox_name="$name"
    inbox_path=""
    root="$(handover_root 2>/dev/null)" || return 1
    inbox="$root/inbox/$name.md"
    inbox_path="$inbox"
    size="$(wc -c < "$inbox" 2>/dev/null | tr -d '[:space:]')"
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    inbox_cursor_file="$root/inbox/.cursor/$name"
    cursor=0
    if [ -f "$inbox_cursor_file" ]; then
        cursor="$(cat "$inbox_cursor_file" 2>/dev/null)"
        case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    fi
    [ "$size" -ne "$cursor" ] || return 0
    inbox_cursor_size="$size"
    # Rotation/corruption: resync without replaying stale rulings.
    [ "$size" -gt "$cursor" ] || return 0
    # Bound to the snapshot, keeping concurrent appends for the next call.
    # Read the prefix first so a large delta cannot SIGPIPE an upstream tail.
    # 10# forces base-10: a leading-zero value (e.g. "08") in a corrupted or
    # hand-recovered cursor file would otherwise be misparsed as an invalid
    # octal literal and abort delivery (CodeRabbit). The trailing x keeps the
    # final newline that command substitution would strip.
    raw="$(head -c "$size" "$inbox" 2>/dev/null | tail -c "$((10#$size - 10#$cursor))" && printf x)" || return 1
    raw="${raw%x}"
    nl='
'
    # A line still being written stays pending: its hash would not match yet,
    # and dropping it would lose the genuine ruling for good.
    case "$raw" in
        *"$nl") ;;
        *)
            partial="${raw##*"$nl"}"
            raw="${raw%"$partial"}"
            inbox_cursor_size="$(( 10#$size - $(printf '%s' "$partial" | wc -c) ))"
            if [ -z "$raw" ]; then
                inbox_cursor_size=""
                return 0
            fi
            ;;
    esac
    if ! pool="$nl$(inbox_ledger_shas "$name")$nl"; then
        # An unreadable ledger proves nothing either way: hold every line.
        inbox_cursor_size=""
        inbox_alert "holding inbox delivery for $name: a chief sent-ledger is unreadable" "$inbox" \
            "an inbox-sent.log under the ledger bases cannot be read" \
            "restore the ledger's read access (chmod 600); held rulings then deliver"
        return 0
    fi
    kept=""
    refused=0
    while IFS= read -r line; do
        [ -n "${line//[[:space:]]/}" ] || continue
        sha="$(printf '%s' "$line" | sha256sum)" || return 1
        case "$pool" in
            *"$nl${sha%% *}$nl"*) kept="${kept:+$kept$nl}$line" ;;
            *) refused=$((refused + 1)) ;;
        esac
    done <<EOF
$raw
EOF
    inbox_bullets="$kept"
    inbox_refused="$refused"
}

inbox_commit() {
    [ -n "$inbox_cursor_size" ] || return 0
    local tmp
    tmp="$(mktemp "$inbox_cursor_file.tmp.XXXXXX")" || return 1
    # prim-ok: already a same-directory mktemp + rename with the rc checked; the hook-sourced lib stays free of a prim.sh dependency.
    if printf '%s\n' "$inbox_cursor_size" > "$tmp" && mv -f "$tmp" "$inbox_cursor_file"; then
        inbox_cursor_size=""
        # Alert once per committed drop, never on a delivery that will retry.
        if [ "${inbox_refused:-0}" -gt 0 ]; then
            inbox_alert "refused $inbox_refused unrecorded inbox line(s) for $inbox_name" "$inbox_path" \
                "no chief sent-ledger record for this session: forged, copied from another inbox, or older than the ledger" \
                "run inbox-audit.sh on the inbox; resend a genuine ruling with inbox-send.sh"
            inbox_refused=0
        fi
    else
        rm -f "$tmp"
        return 1
    fi
}

inbox_deliver_stdout() {
    inbox_peek "$1" || return 1
    if [ -n "$inbox_bullets" ]; then
        printf '%s\n' "$inbox_bullets" || return 1
    fi
    inbox_commit
}

inbox_new_bullets() {
    inbox_with_lock "$1" inbox_deliver_stdout
    return 0
}
