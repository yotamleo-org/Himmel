#!/usr/bin/env bash
# crontab-locked-rmw.sh — one locked read-modify-write of the user crontab.
#
# WHY: a cadence arm or disarm read the whole table, edited the text and wrote it back with no
# lock, so two runs at the same moment each started from the old table and the later write dropped
# the other's change or an unrelated job.
#
# Source it, then:  crontab_locked_rmw <crontab-bin> <edit-fn>
#   <crontab-bin>  the stub-aware crontab command (CRONTAB_BIN in the cadence scripts).
#   <edit-fn>      a shell function run UNDER the lock. It sees the table it just read in
#                  $CRON_TAB, prints the new table on stdout and returns 0. A nonzero return
#                  writes nothing and is passed back unchanged (arm uses 3 for "already armed").
#                  Messages go to stderr: stdout is the table.
# Returns: 0 written; 4 the read or the write failed (a failed read writes nothing); else the
# edit function's code. "no crontab for <user>" reads as an empty table. The lock is held for the
# whole read, edit and write and is released on every exit path.
#
# One lock for every cadence: they all rewrite the same crontab, so a per-script lock would let
# two different scripts lose each other's change. Seam: HIMMEL_CRONTAB_LOCK (default
# $HOME/.himmel/state/crontab.lock; a suite's temp $HOME keeps it off the real home).
# A second run waits for the holder; it never skips. Waiting is unbounded (with_lock): a caller that
# needs a deadline wraps the call.
#
# ponytail: the lock is flock where it exists, else prim.sh's PID file (macOS). A SIGKILLed holder
# leaves the PID file and the next run fails closed until it is removed by hand. Upgrade path: a
# lease with a timestamp if a Mac ever arms these unattended.

# shellcheck source=prim.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prim.sh" || return 1

# Runs inside with_lock's subshell, so CRON_TAB stays private to the locked section.
_crmw_locked() { # <crontab-bin> <edit-fn>
    local bin="$1" edit="$2" err new rc=0
    CRON_TAB=""
    if command -v "$bin" >/dev/null 2>&1; then
        if ! CRON_TAB="$(LC_ALL=C "$bin" -l 2>&1)"; then
            err="$CRON_TAB"; CRON_TAB=""
            case "$err" in
                *"no crontab"*) ;;
                *) echo "ERR crontab-locked-rmw: cannot read the crontab: $err" >&2; return 4 ;;
            esac
        fi
    fi
    new="$(mktemp "${TMPDIR:-/tmp}/crontab-rmw.XXXXXX")" || return 4
    "$edit" > "$new" || rc=$?
    if [ "$rc" -eq 0 ] && ! "$bin" - < "$new"; then
        echo "ERR crontab-locked-rmw: crontab install failed" >&2
        rc=4
    fi
    rm -f "$new"
    return "$rc"
}

crontab_locked_rmw() { # <crontab-bin> <edit-fn>
    local lock="${HIMMEL_CRONTAB_LOCK:-}"
    [ "$#" -eq 2 ] || { echo "usage: crontab_locked_rmw <crontab-bin> <edit-fn>" >&2; return 2; }
    if [ -z "$lock" ]; then
        [ -n "${HOME:-}" ] || { echo "ERR crontab-locked-rmw: no HOME for the lock file" >&2; return 4; }
        lock="$HOME/.himmel/state/crontab.lock"
    fi
    mkdir -p "$(dirname "$lock")" || return 4
    with_lock "$lock" _crmw_locked "$1" "$2"
}
