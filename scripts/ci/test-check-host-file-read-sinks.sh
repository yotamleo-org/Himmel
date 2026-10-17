#!/usr/bin/env bash
# scripts/ci/test-check-host-file-read-sinks.sh -- hermetic suite for
# scripts/ci/check-host-file-read-sinks.sh. Each case builds a throwaway git repo
# whose second commit ADDS the fixture lines, then runs the check over that range.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, git.
# shellcheck disable=SC2015,SC2016 # fixtures are literal shell text; ok/bad never fail
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/ci/check-host-file-read-sinks.sh"
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

# case_repo <name> <base-file-content> <added-file-content>; leaves cwd in the repo.
n=0
case_repo() {
  n=$((n + 1))
  local d="$SCRATCH/r$n"
  mkdir -p "$d" || return 1
  cd "$d" || return 1
  git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  printf '%s\n' "$2" > launch.sh
  git add launch.sh && git commit -q -m base
  printf '%s\n' "$3" > launch.sh
  git add launch.sh && git commit -q -m change
}

run_check() { OUT="$(bash "$CHECK" --range HEAD~1 2>&1)"; RC=$?; }

BASE='#!/usr/bin/env bash
echo hi'

# --- must-flag: the PR 2878 launcher shape (a host file read as a prompt) --------
case_repo flag-argv-cat "$BASE" '#!/usr/bin/env bash
echo hi
prompt="$(cat "$1")"'
run_check
[ "$RC" -eq 1 ] && ok "cat \"\$1\" is flagged" || bad "cat \"\$1\" not flagged (rc=$RC): $OUT"
case "$OUT" in *"launch.sh:3"*) ok "report names file:line" ;; *) bad "no file:line in: $OUT" ;; esac

case_repo flag-input-redirect "$BASE" '#!/usr/bin/env bash
echo hi
prompt=$(< "${1:-}")'
run_check
[ "$RC" -eq 1 ] && ok "< \"\${1:-}\" redirect is flagged" || bad "redirect from \${1:-} not flagged (rc=$RC): $OUT"

case_repo flag-env-source "$BASE" '#!/usr/bin/env bash
echo hi
. "$CONFIG_FILE"
source "$CONFIG_FILE"'
run_check
[ "$RC" -eq 1 ] && ok "source of an env-var path is flagged" || bad "source \$CONFIG_FILE not flagged (rc=$RC): $OUT"

case_repo flag-shifted-var "$BASE" '#!/usr/bin/env bash
echo hi
prompt_file="$1"
body="$(cat "$prompt_file")"'
run_check
[ "$RC" -eq 1 ] && ok "path laundered through a variable assigned from \$1 is flagged" || bad "laundered path not flagged (rc=$RC): $OUT"

case_repo flag-at "$BASE" '#!/usr/bin/env bash
echo hi
head -n 5 "$@"'
run_check
[ "$RC" -eq 1 ] && ok "head \"\$@\" is flagged" || bad "head \"\$@\" not flagged (rc=$RC): $OUT"

# --- must-pass --------------------------------------------------------------------
case_repo pass-allowlist "$BASE" '#!/usr/bin/env bash
echo hi
real="$(realpath "$1")"
case "$real" in "$REPO_ROOT"/*) ;; *) exit 2 ;; esac
prompt="$(cat "$real")"'
run_check
[ "$RC" -eq 0 ] && ok "a realpath prefix check on the next lines passes" || bad "allowlisted read flagged (rc=$RC): $OUT"

case_repo pass-escape "$BASE" '#!/usr/bin/env bash
echo hi
prompt="$(cat "$1")" # read-sink-ok: operator-supplied brief path, console-only entry point'
run_check
[ "$RC" -eq 0 ] && ok "the read-sink-ok escape comment passes" || bad "escaped read flagged (rc=$RC): $OUT"

case_repo pass-literal "$BASE" '#!/usr/bin/env bash
echo hi
prompt="$(cat /etc/hostname)"
. "$(dirname "$0")/lib.sh"'
run_check
[ "$RC" -eq 0 ] && ok "literal and script-relative paths pass" || bad "literal path flagged (rc=$RC): $OUT"

case_repo pass-clean "$BASE" '#!/usr/bin/env bash
echo hi
echo "arg is $1"'
run_check
[ "$RC" -eq 0 ] && ok "a clean diff passes" || bad "clean diff flagged (rc=$RC): $OUT"

# Only ADDED lines count: a pre-existing sink in the base must not block.
case_repo pass-preexisting '#!/usr/bin/env bash
prompt="$(cat "$1")"' '#!/usr/bin/env bash
prompt="$(cat "$1")"
echo added'
run_check
[ "$RC" -eq 0 ] && ok "a pre-existing sink is not re-flagged" || bad "pre-existing sink flagged (rc=$RC): $OUT"

# --- fail-closed ---------------------------------------------------------------------
OUT="$(bash "$CHECK" --range no-such-ref 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "an unresolvable base fails closed" || bad "unresolvable base passed"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
