#!/usr/bin/env bash
# scripts/ci/test-check-host-file-read-sinks.sh -- hermetic suite for
# scripts/ci/check-host-file-read-sinks.sh. Each case builds a throwaway git repo
# whose second commit ADDS a fixture, then runs the check over that range.
# Fixtures live in test-check-host-file-read-sinks-fixtures/*.fixture (not *.sh),
# so the check does not scan its own test cases.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, git.
# shellcheck disable=SC2015 # ok/bad never fail
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/ci/check-host-file-read-sinks.sh"
FIX="$ROOT/scripts/ci/test-check-host-file-read-sinks-fixtures"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

SCRATCH="$(mktemp -d)" || { echo "FAIL - cannot allocate scratch dir" >&2; exit 1; }
: "${SCRATCH:?}"
trap 'rm -rf "$SCRATCH"' EXIT

if [ ! -f "$CHECK" ]; then
  bad "scripts/ci/check-host-file-read-sinks.sh does not exist"
  echo "$fails failed" >&2
  exit 1
fi

# case_repo <base-fixture> <added-fixture>; leaves cwd in the repo.
n=0
case_repo() {
  n=$((n + 1))
  local d="$SCRATCH/r$n"
  {
    mkdir -p "$d" && cd "$d" &&
    git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false &&
    cp "$FIX/$1.fixture" launch.sh &&
    git add launch.sh && git commit -q -m base &&
    cp "$FIX/$2.fixture" launch.sh &&
    git add launch.sh && git commit -q -m change
  } || { echo "FAIL - fixture repo setup failed ($1, $2)" >&2; exit 1; }
}

run_check() { OUT="$(timeout 10 bash "$CHECK" --range HEAD~1 2>&1)"; RC=$?; }

# --- must-flag: the PR 2878 launcher shape (a host file read as a prompt) --------
case_repo base flag-argv-cat
run_check
[ "$RC" -eq 1 ] && ok "cat \"\$1\" is flagged" || bad "cat \"\$1\" not flagged (rc=$RC): $OUT"
case "$OUT" in *"launch.sh:3"*) ok "report names file:line" ;; *) bad "no file:line in: $OUT" ;; esac

case_repo base flag-input-redirect
run_check
[ "$RC" -eq 1 ] && ok "< \"\${1:-}\" redirect is flagged" || bad "redirect from \${1:-} not flagged (rc=$RC): $OUT"

case_repo base flag-env-source
run_check
[ "$RC" -eq 1 ] && ok "source of an env-var path is flagged" || bad "source \$CONFIG_FILE not flagged (rc=$RC): $OUT"

case_repo base flag-shifted-var
run_check
[ "$RC" -eq 1 ] && ok "path laundered through a variable assigned from \$1 is flagged" || bad "laundered path not flagged (rc=$RC): $OUT"

case_repo base flag-at
run_check
[ "$RC" -eq 1 ] && ok "head \"\$@\" is flagged" || bad "head \"\$@\" not flagged (rc=$RC): $OUT"

case_repo base flag-double-dash
run_check
[ "$RC" -eq 1 ] && ok "cat -- \"\$1\" is flagged" || bad "-- terminator not flagged (rc=$RC): $OUT"

# --- must-pass --------------------------------------------------------------------
case_repo base pass-allowlist
run_check
[ "$RC" -eq 0 ] && ok "a realpath prefix check on the next lines passes" || bad "allowlisted read flagged (rc=$RC): $OUT"

case_repo base pass-escape
run_check
[ "$RC" -eq 0 ] && ok "the read-sink-ok escape comment passes" || bad "escaped read flagged (rc=$RC): $OUT"

case_repo base pass-literal
run_check
[ "$RC" -eq 0 ] && ok "literal and script-relative paths pass" || bad "literal path flagged (rc=$RC): $OUT"

case_repo base pass-clean
run_check
[ "$RC" -eq 0 ] && ok "a clean diff passes" || bad "clean diff flagged (rc=$RC): $OUT"

# Only ADDED lines count: a pre-existing sink in the base must not block.
case_repo pass-preexisting.base pass-preexisting
run_check
[ "$RC" -eq 0 ] && ok "a pre-existing sink is not re-flagged" || bad "pre-existing sink flagged (rc=$RC): $OUT"

# --- a reader operand with no variable name must not hang the gate ------------------
case_repo base pass-length-control
run_check
[ "$RC" -eq 0 ] && ok "a C-style loop bounded by a plain variable passes" || bad "length-loop control rc=$RC: $OUT"

for f in nameless-length-loop nameless-indirect-redirect nameless-indirect-cat; do
  case_repo base "$f"
  run_check
  [ "$RC" -ne 124 ] && ok "$f terminates" || bad "$f hung (timeout 10)"
done
case_repo base nameless-length-loop
run_check
[ "$RC" -eq 0 ] && ok "a loop bounded by a length expansion passes" || bad "length-expansion loop rc=$RC: $OUT"

# --- fail-closed---------------------------------------------------------------------
OUT="$(timeout 10 bash "$CHECK" --range no-such-ref 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "an unresolvable base fails closed" || bad "unresolvable base passed"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
