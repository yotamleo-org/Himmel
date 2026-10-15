#!/usr/bin/env bash
# scripts/cr/test-live-gate-e2e.sh — offline guard rows for live-gate-e2e.sh
# The live run itself is on-demand and never runs here; these
# rows only prove the runner refuses to run where it must not.
# Platform guard: bash 3.2+.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/live-gate-e2e.sh"
fail=0
row() { # <label> <want-rc> <got-rc> [<want-stderr-fragment> <stderr-file>]
    if [ "$2" != "$3" ]; then echo "FAIL $1: want rc=$2 got $3"; fail=1; return; fi
    if [ -n "${4:-}" ] && ! grep -q -- "$4" "$5"; then echo "FAIL $1: stderr lacks '$4'"; fail=1; return; fi
    echo "ok   $1"
}
err=$(mktemp "${TMPDIR:-/tmp}/live-e2e-test.XXXXXX") || exit 1
trap 'rm -f "$err"' EXIT

CI=true HIMMEL_REPO=/nonexistent bash "$SELF" 2>"$err"; row "refuses under CI" 2 $? "in CI" "$err"
GITHUB_ACTIONS=true HIMMEL_REPO=/nonexistent bash "$SELF" 2>"$err"; row "refuses under GITHUB_ACTIONS" 2 $? "in CI" "$err"
# The next rows must reach their own guard, so they run with CI cleared (this
# suite itself runs under CI=true in the shell-unit shards).
env -u CI -u GITHUB_ACTIONS HIMMEL_REPO=/nonexistent bash "$SELF" --repo yotamleo/Himmel 2>"$err"; row "refuses to target himmel" 2 $? "himmel itself" "$err"
env -u CI -u GITHUB_ACTIONS HIMMEL_REPO=/nonexistent bash "$SELF" --repo not-a-repo 2>"$err"; row "refuses a malformed repo" 2 $? "owner/name" "$err"
env -u CI -u GITHUB_ACTIONS HIMMEL_REPO=/nonexistent bash "$SELF" --repo yotamleo/x 2>"$err"; row "refuses without an anchor" 2 $? "HIMMEL_REPO" "$err"
env -u CI -u GITHUB_ACTIONS HIMMEL_REPO=/nonexistent bash "$SELF" --repo 2>"$err"; row "refuses --repo with no value" 2 $? "needs owner/name" "$err"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL"; exit 1; fi
