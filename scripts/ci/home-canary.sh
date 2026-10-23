#!/usr/bin/env bash
# scripts/ci/home-canary.sh -- run the shell suites with HOME pointed at a
# sandbox that holds a honeytoken .env, and fail when a suite touches it.
#
# A suite that reads the real $HOME/.env (the PR 2883 shape) is caught only by
# judge luck today. Here HOME and USERPROFILE point at a mktemp -d directory
# whose .env carries a unique random token, so:
#   1. the token reaching the captured output is a leak           (log scan)
#   2. the .env being read at all is a leak, even a silent one    (atime check)
# The .env is pre-aged (atime 1970, mtime 1970+1000s) so a read moves its atime
# under relatime and strictatime mounts. A noatime mount cannot show a silent
# read; a probe file says whether this one can, and HOME_CANARY_REQUIRE_ATIME=1
# turns "cannot" into a failure so CI never degrades quietly.
#
# Usage: home-canary.sh [--runner <script>] [runner args...]
#   default runner: scripts/ci/run-shell-tests.sh (args pass through, e.g.
#   --impacted <base>..<head>). HOME_CANARY_TIMEOUT bounds the runner (seconds,
#   default 1500). HOME_CANARY_RUNNER_FAIL_OK=1 downgrades only a suite-failure
#   exit (rc 1) to a note, for a job that lacks the tools the real shard job
#   installs; a timeout (124, or 137 after timeout -k) and the runner's refused
#   or aborted codes (2-6, 96) still fail.
#   The sandbox is removed on every exit path.
# Exit: 0 clean; 1 leak, runner failure or timeout; 2 usage / setup error.
#
# ponytail: only $HOME and $USERPROFILE are redirected, so a suite that reads a
# literal /home/<user>/.env bypasses the canary; check-host-file-read-sinks.sh
# and the judge cover that route, upgrade path is an fanotify/strace watch on
# the real home.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, GNU/BSD coreutils.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/scripts/ci/run-shell-tests.sh"
if [ "${1:-}" = "--runner" ]; then
  [ -n "${2:-}" ] || { echo "home-canary: --runner needs a script path" >&2; exit 2; }
  RUNNER="$2"
  shift 2
fi
[ -f "$RUNNER" ] || { echo "home-canary: runner not found: $RUNNER" >&2; exit 2; }

TIMEOUT_S="${HOME_CANARY_TIMEOUT:-1500}"
case "$TIMEOUT_S" in ''|*[!0-9]*) echo "home-canary: HOME_CANARY_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
[ "$((10#$TIMEOUT_S))" -gt 0 ] || { echo "home-canary: HOME_CANARY_TIMEOUT must be a positive integer" >&2; exit 2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/home-canary.XXXXXX")" || { echo "home-canary: cannot allocate sandbox" >&2; exit 2; }
: "${SANDBOX:?}"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_HOME="$SANDBOX/home"
LOG="$SANDBOX/runner.log"
mkdir -p "$FAKE_HOME" || exit 2

rand="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
[ "${#rand}" -eq 24 ] || { echo "home-canary: cannot draw a random token" >&2; exit 2; }
TOKEN="hc-$rand"
printf 'HIMMEL_HONEYTOKEN=%s\n' "$TOKEN" > "$FAKE_HOME/.env"
chmod 600 "$FAKE_HOME/.env"

atime_of() { stat -c %X "$1" 2>/dev/null || stat -f %a "$1"; }
age() { TZ=UTC touch -m -t 197001010016.40 "$1" && TZ=UTC touch -a -t 197001010000.00 "$1"; }

age "$FAKE_HOME/.env" || { echo "home-canary: cannot age the honeytoken .env" >&2; exit 2; }

# Does this filesystem move atime on a read?
probe="$SANDBOX/atime-probe"
{ : > "$probe" && age "$probe" && cat "$probe" > /dev/null; } || { echo "home-canary: cannot create the atime probe" >&2; exit 2; }
probe_atime="$(atime_of "$probe")"
case "$probe_atime" in ''|*[!0-9]*) echo "home-canary: cannot read the atime probe" >&2; exit 2 ;; esac
if [ "$probe_atime" = 0 ]; then
  ATIME_TRACKED=0
  echo "home-canary: NOTE this filesystem does not track atime; a silent read of .env is invisible, only the log scan applies"
  if [ "${HOME_CANARY_REQUIRE_ATIME:-}" = 1 ]; then
    echo "home-canary: FAIL HOME_CANARY_REQUIRE_ATIME=1 but atime is not tracked here" >&2
    exit 1
  fi
else
  ATIME_TRACKED=1
fi
env_atime_before="$(atime_of "$FAKE_HOME/.env")"

# Output goes to a file, not a pipe: an orphaned suite child holding a pipe open would
# keep the step alive past the timeout. The redacted log is printed after the run.
timeout -k 30 "$TIMEOUT_S" env HOME="$FAKE_HOME" USERPROFILE="$FAKE_HOME" bash "$RUNNER" "$@" > "$LOG" 2>&1
rc=$?
sed "s/$TOKEN/<honeytoken>/g" "$LOG"

fail=0
if grep -qF "$TOKEN" "$LOG"; then
  fail=1
  echo "home-canary: FAIL honeytoken reached the runner output (a suite printed the sandbox .env); lines:" >&2
  grep -nF "$TOKEN" "$LOG" | sed "s/$TOKEN/<honeytoken>/g" | head -5 >&2
fi
if [ "$(atime_of "$FAKE_HOME/.env")" != "$env_atime_before" ]; then
  fail=1
  echo "home-canary: FAIL honeytoken .env was read (access time moved) -- a suite opened \$HOME/.env" >&2
fi
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  fail=1
  echo "home-canary: FAIL runner timed out after ${TIMEOUT_S}s (rc=$rc)" >&2
elif [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 1 ] && [ "${HOME_CANARY_RUNNER_FAIL_OK:-}" = 1 ]; then
    echo "home-canary: NOTE runner exited rc=$rc; suite results are gated by the shell-unit shards, only a leak, a read, a timeout or an aborted runner fails here"
  else
    fail=1
    echo "home-canary: FAIL runner exited rc=$rc" >&2
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "home-canary: OK no honeytoken leak (atime tracked: $ATIME_TRACKED)"
  exit 0
fi
exit 1
