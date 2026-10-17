#!/usr/bin/env bash
# qmd-daemon-switch.sh - operator on/off for the shared qmd daemon.
#
#   qmd-daemon-switch.sh off   create the opt-out flag and stop the daemon
#   qmd-daemon-switch.sh on    remove the flag and run ensure-qmd-daemon.sh
#
# While the flag exists, ensure-qmd-daemon.sh (the SessionStart hook) exits 0
# without launching. Flag path: $QMD_DAEMON_OFF_FLAG (default
# ~/.himmel/state/qmd-daemon.off). The daemon pid comes from qmd's own pidfile
# ($XDG_CACHE_HOME or ~/.cache)/qmd/mcp.pid, the same one ensure-qmd-daemon.sh
# reads. bash 3.2-safe, ASCII-only.
set -u

QMD_DAEMON_OFF_FLAG="${QMD_DAEMON_OFF_FLAG:-$HOME/.himmel/state/qmd-daemon.off}"
pidfile="${XDG_CACHE_HOME:-$HOME/.cache}/qmd/mcp.pid"
# The lock ensure-qmd-daemon.sh holds around the daemon launch (shared with the
# embed-model swap; its role file says who holds it).
launch_lock="${XDG_CACHE_HOME:-$HOME/.cache}/qmd/embed-swap.lock"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  off)
    mkdir -p "$(dirname -- "$QMD_DAEMON_OFF_FLAG")" || exit 1
    : > "$QMD_DAEMON_OFF_FLAG" || exit 1
    # Flag first, then wait out a launch already past its own flag check: ensure
    # holds the lock until its start returns, so the pidfile read below sees the
    # daemon it started. Bounded (ensure's worst case is ~59s); a dead holder's
    # lock is cleared.
    mkdir -p "$(dirname -- "$launch_lock")" 2>/dev/null
    have_lock=0
    lock_i=0
    while [ "$lock_i" -lt 65 ]; do
      if mkdir "$launch_lock" 2>/dev/null; then have_lock=1; break; fi
      holder="$(cat "$launch_lock/pid" 2>/dev/null)"
      case "$holder" in
        ''|*[!0-9]*) ;;
        *)
          # Clearing is serialized by a second mkdir lock and the holder is
          # re-read inside it, as ensure's swap_lock_reclaim does: two waiters
          # that both saw a dead holder must not delete a fresh lock.
          if ! kill -0 "$holder" 2>/dev/null && mkdir "$launch_lock.reclaim" 2>/dev/null; then
            [ "$(cat "$launch_lock/pid" 2>/dev/null)" != "$holder" ] || rm -rf "$launch_lock"
            rmdir "$launch_lock.reclaim" 2>/dev/null
          fi
          ;;
      esac
      lock_i=$((lock_i + 1))
      sleep 1
    done
    if [ "$have_lock" -eq 1 ]; then
      echo off > "$launch_lock/role"
      echo "$$" > "$launch_lock/pid"
      trap 'rm -rf "$launch_lock"' EXIT
    else
      echo "qmd-daemon-switch: could not take $launch_lock in 65s; a launch may still be in flight - run off again to be sure" >&2
    fi
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*|0) echo "qmd-daemon-switch: flag set; no running daemon found (no pid in $pidfile)" ;;
      *)
        # Same identity check as ensure-qmd-daemon.sh's recycler: a stale pid
        # may now belong to an unrelated process, so only a qmd mcp one is stopped.
        row="$("${QMD_PS:-ps}" -o args= -p "$pid" 2>/dev/null || true)"
        case "$row" in
          *qmd*mcp*)
            if kill -TERM "$pid" 2>/dev/null; then
              echo "qmd-daemon-switch: flag set; sent SIGTERM to daemon pid $pid"
            else
              echo "qmd-daemon-switch: flag set, but could not signal daemon pid $pid (permission?); it may still be running" >&2
              exit 1
            fi
            ;;
          *) echo "qmd-daemon-switch: flag set; pid $pid in $pidfile is not a qmd mcp process, left alone" ;;
        esac
        ;;
    esac
    echo "qmd stays off across sessions until: bash \"$here/qmd-daemon-switch.sh\" on"
    ;;
  on)
    rm -f "$QMD_DAEMON_OFF_FLAG" || exit 1
    if [ "${QMD_DAEMON_DISABLED:-}" = "1" ]; then
      echo "qmd-daemon-switch: flag removed, but QMD_DAEMON_DISABLED=1 is still set in this environment; the daemon will not start until it is unset"
    else
      echo "qmd-daemon-switch: flag removed; starting the daemon"
    fi
    exec bash "$here/ensure-qmd-daemon.sh"
    ;;
  *)
    echo "usage: qmd-daemon-switch.sh on|off" >&2
    exit 2
    ;;
esac
