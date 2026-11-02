#!/usr/bin/env bash
# scripts/lib/test-clear-stale-claude-marker.sh -- suite for
# scripts/lib/clear-stale-claude-marker.sh (SCRUM-2).
#
# Pins the one rule: the claude session marker survives only while CLAUDE_PID
# is an ancestor of the sourcing shell. A dead or unrelated CLAUDE_PID is
# cleared; a live ancestor is kept; no marker means nothing changes.
#
# Platform guard: bash + ps + sleep; zsh case runs only where zsh exists.
# SC2016: the single-quoted bodies expand in the CHILD shell, on purpose.
# SC2015: pass never fails, so `cond && pass || fail` is a safe if/else.
# shellcheck disable=SC2016,SC2015
set -uo pipefail

# shellcheck source=../ci/run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../ci/run-shell-tests-fixture.sh"

LIB="$(cd "$(dirname "$0")" && pwd)/clear-stale-claude-marker.sh"

# probe <shell> -- source the lib in a fresh child shell and print what is left.
# The child's environment is whatever the caller exported.
probe() {
  "$1" -c '. "$1"; printf "%s|%s|%s|%s|%s" "${CLAUDE_CODE_CHILD_SESSION:-unset}" "${CLAUDE_PID:-unset}" "${CLAUDECODE:-unset}" "${CLAUDE_CODE_MESSAGING_TOKEN:-unset}" "${CLAUDE_CODE_MESSAGING_SOCKET:-unset}"' probe "$LIB"
}

# A pid that has certainly exited.
sleep 0 & dead=$!; wait "$dead"

echo "== Case 1: dead CLAUDE_PID is cleared =="
got=$(CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PID=$dead CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_CODE_MESSAGING_SOCKET=/tmp/sock probe bash)
[ "$got" = "unset|unset|unset|unset|unset" ] && pass "dead pid: all markers and messaging vars dropped" || fail "dead pid: got [$got]"

echo "== Case 2: live but non-ancestor CLAUDE_PID is cleared (the iTerm case) =="
sleep 30 & other=$!
got=$(CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PID=$other CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_CODE_MESSAGING_SOCKET=/tmp/sock probe bash)
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
[ "$got" = "unset|unset|unset|unset|unset" ] && pass "unrelated live pid: all markers and messaging vars dropped" || fail "unrelated live pid: got [$got]"

echo "== Case 3: live ancestor CLAUDE_PID is kept (a real claude child) =="
# The outer bash stands in for claude: it exports its own pid, like claude does.
got=$(bash -c 'export CLAUDE_PID=$$ CLAUDE_CODE_CHILD_SESSION=1 CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_CODE_MESSAGING_SOCKET=/tmp/sock; bash -c ". \"\$1\"; printf \"%s|%s|%s|%s\" \"\${CLAUDE_CODE_CHILD_SESSION:-unset}\" \"\${CLAUDE_PID:-unset}\" \"\${CLAUDE_CODE_MESSAGING_TOKEN:-unset}\" \"\${CLAUDE_CODE_MESSAGING_SOCKET:-unset}\"" x "$1"; echo "|$$"' outer "$LIB")
want_pid=${got##*|}
[ "$got" = "1|$want_pid|tok|/tmp/sock|$want_pid" ] && pass "ancestor pid: marker and messaging vars kept" || fail "ancestor pid: got [$got]"

echo "== Case 4: marker without CLAUDE_PID is cleared =="
got=$(env -u CLAUDE_PID CLAUDE_CODE_CHILD_SESSION=1 bash -c '. "$1"; printf "%s" "${CLAUDE_CODE_CHILD_SESSION:-unset}"' x "$LIB")
[ "$got" = "unset" ] && pass "no CLAUDE_PID: marker dropped" || fail "no CLAUDE_PID: got [$got]"

echo "== Case 5: no marker, no change, no output, no leaked helpers =="
got=$(env -u CLAUDE_PID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE KEEP=me bash -c '. "$1"; printf "%s|%s|%s" "$KEEP" "$(type -t _himmel_claude_marker_live || echo none)" "${_hcm_p:-none}"' x "$LIB" 2>&1)
[ "$got" = "me|none|none" ] && pass "no marker: untouched, helpers removed" || fail "no marker: got [$got]"

echo "== Case 6: zsh sources it the same way =="
if command -v zsh >/dev/null 2>&1; then
  got=$(CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_PID=$dead CLAUDECODE=1 CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_CODE_MESSAGING_SOCKET=/tmp/sock probe zsh)
  [ "$got" = "unset|unset|unset|unset|unset" ] && pass "zsh: dead pid dropped" || fail "zsh: got [$got]"
else
  pass "zsh absent: skipped"
fi

rst_tally
