#!/usr/bin/env bash
# selector: tree-scan
# check-windows-leftovers.sh passes on this tree and fails on a planted
# Windows-only branch, a grown baseline row and a live voice reference.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/scripts/lint/check-windows-leftovers.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

if out=$(bash "$CHECK" 2>&1); then
  pass "T1 the tree matches the baseline"
else
  fail "T1 the tree does not match the baseline:"
  printf '%s\n' "$out"
fi

tmp=$(mktemp -d -t winleft.XXXXXX) || exit 1
trap 'rm -rf "$tmp"' EXIT
fixture() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/lint" "$tmp/repo/archive/voice/scripts/voice"
  git -C "$tmp/repo" init -q
  printf 'win\t1\tscripts/old.sh\n' > "$tmp/repo/scripts/lint/windows-leftovers-baseline.tsv"
  printf 'schtasks /query\n' > "$tmp/repo/scripts/old.sh"
  printf 'bash scripts/voice/speak.sh\n' > "$tmp/repo/archive/voice/scripts/voice/speak.sh"
}
add_all() { git -C "$tmp/repo" add -A; }

fixture; add_all
if bash "$CHECK" --root "$tmp/repo" >/dev/null 2>&1; then
  pass "T2 a baselined file and the archive pass"
else
  fail "T2 a baselined file or the archive was flagged"
fi

fixture
printf 'case "%sOSTYPE" in msys*) schtasks /create /tn x ;; esac\n' "\$" > "$tmp/repo/scripts/new-cadence.sh"
add_all
if bash "$CHECK" --root "$tmp/repo" >/dev/null 2>&1; then
  fail "T3 a planted schtasks branch outside the archive passed"
else
  pass "T3 a planted schtasks branch outside the archive fails"
fi

fixture
printf 'schtasks /query\nschtasks /delete\n' > "$tmp/repo/scripts/old.sh"
add_all
if bash "$CHECK" --root "$tmp/repo" >/dev/null 2>&1; then
  fail "T4 a baselined file that grew passed"
else
  pass "T4 a baselined file that grew fails"
fi

fixture
printf 'see docs/voice.md\n' > "$tmp/repo/README.md"
add_all
if bash "$CHECK" --root "$tmp/repo" >/dev/null 2>&1; then
  fail "T5 a live voice reference passed"
else
  pass "T5 a live voice reference fails"
fi

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
