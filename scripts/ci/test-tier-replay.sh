#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-tier-replay.sh — suite for scripts/ci/tier-replay.sh.
#
#   TR1 the repo's suite-tiers.tsv replays clean over the real fixture (rc 0, PASS).
#   TR2 a catch suite demoted to local fails the replay and is named (rc 1).
#   TR3 a trust-owned suite that is no catch, demoted to local, fails and is named (rc 1).
#   TR4 an unknown argument is a usage error (rc 2).
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPLAY="$REPO_ROOT/scripts/ci/tier-replay.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-tier-replay.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# demote <suite> <out>: the repo tier file with one suite's row set to local
demote() { awk -F'\t' -v OFS='\t' -v s="$1" '$1 == s { $2 = "local"; $3 = "demoted" } { print }' \
  "$REPO_ROOT/scripts/ci/suite-tiers.tsv" > "$2"; }

# row <label> <want-rc> <want-text> [args...]
row() {
  local label="$1" want_rc="$2" want_text="$3" rc
  shift 3
  bash "$REPLAY" "$@" > "$tmp/out" 2>&1
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_text" "$tmp/out"; then
    pass "$label"
  else
    fail "$label (rc=$rc, want $want_rc and '$want_text')"
    tail -n 15 "$tmp/out"
  fi
}

echo "== tier-replay.sh"
row "TR1: the repo tier file selects every catch and trust-owned suite" 0 "tier-replay: PASS"

demote scripts/parity/test-ws5-invariants.sh "$tmp/catch.tsv"
row "TR2: a demoted catch suite is a miss" 1 \
  "catch suite not selected: scripts/parity/test-ws5-invariants.sh" --tiers "$tmp/catch.tsv"

demote scripts/ci/test-run-shell-tests.sh "$tmp/trust.tsv"
row "TR3: a demoted trust-owned suite is a miss" 1 \
  "trust-owned suite not selected: scripts/ci/test-run-shell-tests.sh" --tiers "$tmp/trust.tsv"

row "TR4: an unknown argument is a usage error" 2 "usage:" --bogus

echo
if [ "$failures" -gt 0 ]; then
  echo "test-tier-replay: $failures failure(s)"
  exit 1
fi
echo "test-tier-replay: all cases passed"
