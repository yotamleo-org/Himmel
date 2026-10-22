#!/usr/bin/env bash
# Retry a failing bun suite once, preserving the caller's working directory.
# Usage: run-bun-tests.sh <repo-relative-suite> [bun test arguments...]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$#" -lt 1 ]; then
  printf 'usage: run-bun-tests.sh <suite> [bun test arguments...]\n' >&2
  exit 2
fi
suite="$1"; shift
# shellcheck source=scripts/lib/prim.sh
. "$ROOT/scripts/lib/prim.sh" || exit 1
logs=$(tmpdir) || exit 1
trap 'rm -rf "$logs"' EXIT
run_attempt() {
  bun test "$@" 2>&1 | tee "$logs/$attempt.log"
}
attempt=1
if run_attempt "$@"; then
  printf '[PASS] %s\n' "$suite"
  exit 0
else
  first_rc=$?
fi
attempt=2
start=$SECONDS
if run_attempt "$@"; then
  retry_elapsed_ms=$(( (SECONDS - start) * 1000 ))
else
  rc=$?
  printf '[FAIL] %s — failed both attempts (first rc=%s, retry rc=%s)\n' "$suite" "$first_rc" "$rc"
  exit "$rc"
fi
printf '[FLAKE] %s — passed on single retry (first rc=%s, retry_ms=%s)\n' "$suite" "$first_rc" "$retry_elapsed_ms"
ledger="${SUITE_FLAKE_LEDGER:-${HOME:+$HOME/.himmel/suite-flake-ledger.jsonl}}"
repo="${SUITE_FLAKE_REPO_ID:-}"
if [ -z "$repo" ] && [ -r "$ROOT/scripts/lib/flake-repo-id.sh" ]; then
  # shellcheck source=scripts/lib/flake-repo-id.sh
  . "$ROOT/scripts/lib/flake-repo-id.sh"
  repo=$(_flake_repo_id "$ROOT")
fi
sha=$(git -C "$ROOT" rev-parse HEAD)
cases=$(awk '/\.test\.[cm]?[jt]sx?:/ {file=$0} /\(fail\)|^[[:space:]]*(not ok|FAIL|\[FAIL\])/ {print substr(file,1,300); print substr($0,1,300); if (++n == 3) exit}' "$logs/1.log")
if [ -n "$ledger" ] && [ -n "$repo" ] && [ ! -L "$ledger" ]; then
  if ! { mkdir -p "$(dirname "$ledger")" && jq -cn \
      --arg host "$(hostname)" --arg suite "$suite" --arg repo "$repo" \
      --arg case "${cases:0:1000}" --arg sha "$sha" --arg run "${GITHUB_RUN_ID:-}" \
      --argjson ts "$(date +%s)" --argjson rc "$first_rc" --argjson retry_elapsed_ms "$retry_elapsed_ms" \
      '{v:1,ts:$ts,host:$host,source:"run-bun-tests",kind:"flake",suite:$suite,repo:$repo,case:$case,rc:$rc,sha:$sha,run:$run,retry_elapsed_ms:$retry_elapsed_ms}' >> "$ledger"; }; then
    printf 'WARN: could not append flake ledger: %s\n' "$ledger" >&2
  fi
else
  printf 'WARN: flake not recorded: missing ledger/repo or symlink ledger\n' >&2
fi
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  escaped="${suite//%/%25}"
  escaped="${escaped//$'\r'/%0D}"
  escaped="${escaped//$'\n'/%0A}"
  printf '::warning title=FLAKE::%s\n' "$escaped"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ ! -L "$GITHUB_STEP_SUMMARY" ]; then
  # shellcheck disable=SC2016 # Markdown backticks are literal.
  printf '\n### FLAKE: suite passed on single retry\n\n- `%s` (first rc=%s, retry_ms=%s)\n' "$suite" "$first_rc" "$retry_elapsed_ms" >> "$GITHUB_STEP_SUMMARY" || true
fi
exit 0
