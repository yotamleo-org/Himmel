#!/usr/bin/env bash
# qmd-bounded.sh — run qmd under a deadline that kills its WHOLE process tree
#
# Run it:   bash qmd-bounded.sh <qmd verb> [args...]
#   runs qmd (resolved as qmd-bin.sh's qmd_cmd does) under a deadline of
#   $QMD_TIMEOUT_SECS, else 300 s — the ad-hoc path block-bare-qmd-query.sh
#   sends agents to. A query or search question is first asked in both fleet
#   vocabularies by scripts/qmd/vocab-expand.py (an expanded search runs as a
#   lex-only query with --no-rerank); QMD_VOCAB_EXPAND=0 turns that off.
#   Flags: qmd's lex parser reads a bare leading dash as a NOT, so a search
#   for "claude -p" would return every doc except the ones about -p. The same
#   step quotes each bare dash word ("-p", "--bg"), which qmd then matches as
#   the literal term, expanded or not. A leading dash is therefore never a NOT
#   here; a deliberate one is written -"term", which is passed on as typed.
#   A query or search that finds the index locked by another qmd process exits
#   75 with one plain line on stderr instead of the fork's schema SQL excerpt
#   (a deadline 124 or a signal rc above 128 passes through unchanged);
#   qmd's stderr is held until it exits so it can be read (stdout stays live).
# Source it, then: qmd_bounded <secs> <cmd> [args...]
#   rc      the command's own rc, or 124 when the deadline fired (as timeout(1))
#   <secs>  whole seconds; 0 runs the command unbounded
#   QMD_KILL_GRACE_SECS  seconds between the group SIGTERM and the SIGKILL (5)
#
# qmd_timeout_secs prints the SOURCED callers' default (qmd_cmd, qmd-reindex,
# qmd-staleness): $QMD_TIMEOUT_SECS, else 3600 - longer than the executed
# path's 300 s because those run embeds. An embed cut short by it is
# resumable; the next run carries on.
#
# Why not plain `timeout N qmd …`: the qmd launcher (bin/qmd in the fork) is a
# node trampoline that spawns `bun src/cli/qmd.ts` and forwards no signals.
# GNU timeout SIGTERMs its process group, node dies, and timeout returns at
# once — so its `-k` SIGKILL never fires. bun catches SIGTERM in a JS handler
# that cannot run while its main thread is blocked in native llama.cpp, so it
# lives on, reparented to init. Five such `qmd query` orphans ran at ~99 % CPU
# for ~15 h. Here the command gets its own process group (`set -m`) and a
# watchdog outside it SIGTERMs, then SIGKILLs, the whole group — whatever the
# direct child did. The watchdog is also its own group, so it still enforces
# the deadline if the caller itself is killed. When the direct child ends
# first, anything it left in the group is reaped the same way before return.
#
#
# Platform guard: POSIX bash 3.2+.

qmd_timeout_secs() {
  printf '%s\n' "${QMD_TIMEOUT_SECS:-3600}"
}

qmd_bounded() {
  local secs="$1"
  shift
  case "$secs" in
    '' | *[!0-9]*)
      echo "qmd_bounded: deadline must be whole seconds, got '$secs'" >&2
      return 2
      ;;
  esac
  if [ "$secs" -eq 0 ]; then
    "$@"
    return $?
  fi
  # No watchdog is possible without these (a hermetic test PATH); a sleep that
  # fails at once would fire the deadline immediately. Run unbounded instead.
  if ! command -v sleep >/dev/null 2>&1 || ! command -v mktemp >/dev/null 2>&1; then
    echo "qmd_bounded: sleep/mktemp not on PATH - running unbounded" >&2
    "$@"
    return $?
  fi
  (
    # Sourced by errexit callers: a non-zero `wait` must not abort this
    # subshell before the rc is mapped and the watchdog is cancelled.
    set +e
    grace="${QMD_KILL_GRACE_SECS:-5}"
    # The watchdog creates the marker; it never exists before, so a failed
    # cleanup (no rm on a hermetic PATH) cannot read as a fired deadline.
    # prim-ok: this sourced lib runs under a hermetic PATH and errexit callers and sources nothing; the qmd-bounded. prefix names the leak
    fdir="$(mktemp -d "${TMPDIR:-/tmp}/qmd-bounded.XXXXXX")" || exit 2
    fired="$fdir/fired"
    # bash hands a background job /dev/null for stdin; keep the caller's on fd
    # 3 so a piped input still reaches the command. A CLOSED stdin becomes
    # /dev/null: a closed fd 0 lets the command's own pipes land on it.
    { exec 3<&0; } 2>/dev/null || exec 3</dev/null
    set -m
    "$@" <&3 3<&- &
    pid=$!
    exec 3<&-
    # Output to /dev/null: a watchdog left holding the caller's stdout would
    # keep a `$(qmd_bounded …)` capture open until the deadline.
    (
      sleep "$secs"
      : >"$fired"
      kill -TERM -- "-$pid" 2>/dev/null || exit 0
      n=0
      while [ "$n" -lt "$grace" ]; do
        sleep 1
        kill -0 -- "-$pid" 2>/dev/null || exit 0
        n=$((n + 1))
      done
      kill -KILL -- "-$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wd=$!
    # Both groups exist now; job control off again silences bash's "[1] Exit"
    # job notices on the caller's stderr.
    set +m
    trap 'kill -TERM -- "-$pid" 2>/dev/null' TERM INT HUP
    wait "$pid"
    rc=$?
    # A trapped signal interrupts wait with rc > 128; wait again for the real rc.
    while kill -0 "$pid" 2>/dev/null; do
      wait "$pid"
      rc=$?
    done
    if [ -e "$fired" ]; then
      # The direct child is gone; the watchdog is still reaping the rest of
      # the group (bun, in the qmd case). Return only once it has.
      wait "$wd"
      rm -rf "$fdir"
      exit 124
    fi
    # The direct child is gone before the deadline - it exited, was killed by
    # someone else, or took a forwarded caller signal - but a TERM-ignoring
    # descendant (bun) may not be. Escalate as the watchdog would before
    # cancelling it; an empty group costs one kill -0.
    if kill -0 -- "-$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null
      n=0
      while kill -0 -- "-$pid" 2>/dev/null && [ "$n" -lt "$grace" ]; do
        sleep 1
        n=$((n + 1))
      done
      kill -KILL -- "-$pid" 2>/dev/null
    fi
    kill -- "-$wd" 2>/dev/null
    rm -rf "$fdir" 2>/dev/null
    exit "$rc"
  )
}

# Executed rather than sourced: run qmd bounded. The guard stops the re-source
# from qmd-bin.sh (which sources this file) from re-entering this block.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${_QMD_BOUNDED_MAIN:-}" ]; then
  _QMD_BOUNDED_MAIN=1
  if [ "$#" -eq 0 ]; then
    echo "usage: bash qmd-bounded.sh <qmd verb> [args...]  (deadline: \$QMD_TIMEOUT_SECS, else 300 s)" >&2
    exit 2
  fi
  export QMD_TIMEOUT_SECS="${QMD_TIMEOUT_SECS:-300}"
  # no python3, or no output from it, runs the argv as given
  case "$1" in
    query | search)
      if [ "${QMD_VOCAB_EXPAND:-1}" != 0 ] && command -v python3 >/dev/null 2>&1; then
        _qmd_vx=()
        while IFS= read -r -d '' _qmd_a; do _qmd_vx+=("$_qmd_a"); done \
          < <(python3 -I "$(dirname "${BASH_SOURCE[0]}")/../qmd/vocab-expand.py" argv "$@" 2>/dev/null)
        [ "${#_qmd_vx[@]}" -gt 0 ] && set -- "${_qmd_vx[@]}"
      fi ;;
  esac
  # shellcheck source=scripts/lib/qmd-bin.sh
  . "$(dirname "${BASH_SOURCE[0]}")/qmd-bin.sh"
  case "$1" in
    query | search)
      { _qmd_err=$(qmd_cmd "$@" 2>&1 1>&3 3>&-); _qmd_rc=$?; } 3>&1
      if [ "$_qmd_rc" -ne 0 ] && [ "$_qmd_rc" -ne 124 ] && [ "$_qmd_rc" -le 128 ] && qmd_output_is_busy "$_qmd_err"; then
        echo "qmd-bounded: qmd index busy (another qmd process holds the database lock); no search ran, this is not 'no results' - retry in a few seconds" >&2
        exit 75
      fi
      [ -n "$_qmd_err" ] && printf '%s\n' "$_qmd_err" >&2
      exit "$_qmd_rc" ;;
  esac
  qmd_cmd "$@"
  exit $?
fi
