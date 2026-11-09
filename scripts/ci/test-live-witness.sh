#!/usr/bin/env bash
# shellcheck disable=SC2016  # wrapped command bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-live-witness.sh — scripts/ci/live-witness.sh keeps a wrapped
# command off the station's live state and says which path it wrote.
#
#   W1. `run` fails a command that writes a live-shaped path under its HOME
#       (exit 86), naming the label and the path, and prints its summary line.
#   W2. A command that writes only under its own temp dir passes.
#   W3. A command's own exit code passes through when it wrote nothing.
#   W4. A hit wins over the command's rc: exit 86, the summary keeps the rc.
#   W5. live_witness_reset refuses a home outside its lane root and removes nothing.
#   W6. A write into the account's passwd home (the test seam) exits 86 and an
#       exempt line never turns it into a WARN.
#   W7. An XDG variable the host sets is unset for the command, so the XDG route
#       lands in the decoy, not the host's directory.
#
# Platform guard: bash-only, like every suite in this family; Linux/macOS.
#
# Usage: bash scripts/ci/test-live-witness.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

LW="$(cd "$(dirname "$0")" && pwd)/live-witness.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

sb=$(mktemp -d "${TMPDIR:-/tmp}/lw-test.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$sb"' EXIT
# A row that drops its env prefix, or a CLI that does not yet move HOME, writes
# this sandbox and never the station's real ~/.himmel or ~/.claude.
export HOME="$sb/outer-home"
mkdir -p "$HOME"
: > "$sb/exempt-none"
export SUITE_LIVE_EXEMPT="$sb/exempt-none"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME LIVE_WITNESS_ACCOUNT_HOME

echo "== W1: a write under the decoy HOME exits 86 and names the label and the path =="
out=$(bash "$LW" run --label x -- bash -c 'mkdir -p "$HOME/.claude/p"' 2>&1)
rc=$?
if [ "$rc" -eq 86 ]; then pass "W1: exit 86"; else fail "W1: expected 86, got $rc; out: $out"; fi
if grepq "$out" -E '\[LIVE-STATE\] x — .*\.claude/p'; then pass "W1: the line names x and .claude/p"; else fail "W1: no [LIVE-STATE] line naming x and .claude/p; out: $out"; fi
if grepq "$out" -x 'live-witness: on, x, 1 hits, cmd rc=0'; then pass "W1: the summary line"; else fail "W1: no summary line; out: $out"; fi
if [ ! -e "$HOME/.claude" ]; then pass "W1: the outer HOME is untouched"; else fail "W1: the command wrote the outer HOME"; fi

echo "== W2: a write under the command's own temp dir passes =="
out=$(bash "$LW" run --label x -- bash -c 'd=$(mktemp -d "${TMPDIR:-/tmp}/lw-own.XXXXXX") && mkdir -p "$d/.claude/p" && rm -rf "$d"' 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "W2: exit 0"; else fail "W2: expected 0, got $rc; out: $out"; fi
if grepq "$out" -x 'live-witness: on, x, 0 hits, cmd rc=0'; then pass "W2: the summary line"; else fail "W2: no summary line; out: $out"; fi
if grepq "$out" -F '[LIVE-STATE]'; then fail "W2: a clean command got a [LIVE-STATE] line; out: $out"; else pass "W2: no [LIVE-STATE] line"; fi

echo "== W3: the command's rc passes through =="
out=$(bash "$LW" run --label x -- bash -c 'exit 3' 2>&1)
rc=$?
if [ "$rc" -eq 3 ]; then pass "W3: exit 3"; else fail "W3: expected 3, got $rc; out: $out"; fi
if grepq "$out" -x 'live-witness: on, x, 0 hits, cmd rc=3'; then pass "W3: the summary keeps rc=3"; else fail "W3: no summary line; out: $out"; fi

echo "== W4: a hit wins over the command's rc =="
out=$(bash "$LW" run --label x -- bash -c 'mkdir -p "$HOME/.claude/p"; exit 3' 2>&1)
rc=$?
if [ "$rc" -eq 86 ]; then pass "W4: exit 86"; else fail "W4: expected 86, got $rc; out: $out"; fi
if grepq "$out" -x 'live-witness: on, x, 1 hits, cmd rc=3'; then pass "W4: the summary keeps rc=3"; else fail "W4: no summary line with rc=3; out: $out"; fi

echo "== W5: live_witness_reset refuses a home outside its lane root =="
mkdir -p "$sb/lane" "$sb/elsewhere/home" "$sb/elsewhere/hroot"
: > "$sb/elsewhere/home/keep"
(
  # shellcheck source=live-witness.sh
  . "$LW"
  live_witness_reset "$sb/lane" "$sb/elsewhere/home" "$sb/elsewhere/hroot"
)
rc=$?
if [ "$rc" -eq 2 ]; then pass "W5: returns 2"; else fail "W5: expected 2, got $rc"; fi
if [ -e "$sb/elsewhere/home/keep" ]; then pass "W5: removes nothing"; else fail "W5: removed a file outside the lane root"; fi

echo "== W6: an account-home write exits 86 and no exempt line makes it a WARN =="
mkdir -p "$sb/acct"
printf 'x HIMMEL-1 measured\n' > "$sb/exempt-x"
out=$(env HIMMEL_TEST_FIXTURE=1 LIVE_WITNESS_ACCOUNT_HOME="$sb/acct" SUITE_LIVE_EXEMPT="$sb/exempt-x" \
  bash "$LW" run --label x -- bash -c 'mkdir -p "'"$sb"'/acct/.himmel/state/api-credit" && : > "'"$sb"'/acct/.himmel/state/api-credit/x"' 2>&1)
rc=$?
if [ "$rc" -eq 86 ]; then pass "W6: exit 86"; else fail "W6: expected 86, got $rc; out: $out"; fi
if grepq "$out" -E '\[LIVE-STATE\] x — .*api-credit/x.*account home'; then pass "W6: the line names the account-home path"; else fail "W6: no account-home line; out: $out"; fi
if grepq "$out" -F 'WARN'; then fail "W6: the account-home hit was a WARN; out: $out"; else pass "W6: never a WARN"; fi
if grepq "$out" -x 'live-witness: on, x, 1 hits, cmd rc=0'; then pass "W6: the summary says 1 hits"; else fail "W6: no 1-hit summary; out: $out"; fi

echo "== W7: the XDG route lands in the decoy, never the host's directory =="
mkdir -p "$sb/xdg"
out=$(env XDG_STATE_HOME="$sb/xdg" bash "$LW" run --label x -- bash -c 'd="${XDG_STATE_HOME:-$HOME/.local/state}/himmel"; mkdir -p "$d" && : > "$d/x"' 2>&1)
rc=$?
if [ "$rc" -eq 86 ]; then pass "W7: exit 86"; else fail "W7: expected 86, got $rc; out: $out"; fi
if grepq "$out" -E '\[LIVE-STATE\] x — .*\.local/state/himmel/x'; then pass "W7: the line names .local/state/himmel/x"; else fail "W7: no line naming .local/state/himmel/x; out: $out"; fi
if [ -z "$(ls -A "$sb/xdg")" ]; then pass "W7: the host XDG_STATE_HOME stays empty"; else fail "W7: the command wrote the host XDG_STATE_HOME: $(ls -A "$sb/xdg")"; fi

echo "== W8: an existing .claude.json does not make an absent .claude look removed =="
mkdir -p "$sb/acct8"
printf '{}\n' > "$sb/acct8/.claude.json"
out=$(env HIMMEL_TEST_FIXTURE=1 LIVE_WITNESS_ACCOUNT_HOME="$sb/acct8" bash "$LW" run --label x -- true 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "W8: a clean command exits 0"; else fail "W8: expected 0, got $rc; out: $out"; fi
if grepq "$out" -F '[LIVE-STATE]'; then fail "W8: a clean command got a [LIVE-STATE] line; out: $out"; else pass "W8: no [LIVE-STATE] line"; fi

echo "== W9: the exempt loader has no all-suites form =="
printf '* HIMMEL-1 measurement\n' > "$sb/exempt-star"
out=$(env SUITE_LIVE_EXEMPT="$sb/exempt-star" bash "$LW" run --label x -- true 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then pass "W9: a '*' glob line exits 2"; else fail "W9: expected 2, got $rc; out: $out"; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
fi
echo "FAIL: $failures case(s) failed"
exit 1
