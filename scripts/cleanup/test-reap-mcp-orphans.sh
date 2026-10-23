#!/usr/bin/env bash
# Suite for scripts/cleanup/reap-mcp-orphans.sh.
#
# Drives the CLASSIFIER against a canned process table via REAP_ORPHANS_INPUT
# (pid|ppid|command line), and the KILL path against two real throwaway
# processes listed in a canned table (REAP_ORPHANS_TEST_KILL=1).
#
# Usage: bash scripts/cleanup/test-reap-mcp-orphans.sh
# Exit: 0 all passed, 1 at least one failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass() cannot fail
set -uo pipefail

REAPER="$(cd "$(dirname "$0")" && pwd)/reap-mcp-orphans.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"; [ -z "${P1:-}" ] || kill "$P1" 2>/dev/null; [ -z "${P2:-}" ] || kill "$P2" 2>/dev/null' EXIT
FIX="$WORK/procs.txt"
LOG="$WORK/reap.log"

cat > "$FIX" <<'T'
1|0|/sbin/init
100|1|claude --resume
101|100|node /home/u/.npm/_npx/x/node_modules/.bin/context7-mcp
102|101|node /usr/lib/node_modules/typescript/lib/tsserver.js
110|1|codex --model x
111|110|node /home/u/.npm/_npx/x/node_modules/.bin/context7-mcp
120|1|node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
121|120|node /home/u/.npm/_npx/x/node_modules/.bin/context7-mcp
130|1|/Applications/Claude.app/Contents/MacOS/claude --resume
131|130|node /home/u/.npm/_npx/x/node_modules/.bin/context7-mcp
200|1|node /home/u/.npm/_npx/y/node_modules/.bin/context7-mcp
201|200|node /usr/lib/node_modules/typescript/lib/typingsInstaller.js
300|1|bun run /home/u/graphify-mcp/server.ts
400|1|node /opt/qmd/dist/cli.js qmd --http /home/u/.claude/plugins/cache/qmd
401|400|node /home/u/.npm/_npx/q/node_modules/.bin/context7-mcp
500|1|bash scripts/foo.sh context7-mcp-docs-note
510|1|rg context7-mcp /home/u/notes
511|1|less /home/u/.claude/plugins/cache/x/README.md
512|1|vim /home/u/.claude/plugins/cache/x/a.ts
550|1|node /usr/bin/worker --note=context7-mcp
600|1|node /home/u/.claude/plugins/cache/x/typescript-language-server --stdio
700|1|code --folder /home/u/proj
701|700|node /usr/lib/node_modules/typescript/lib/tsserver.js
800|1|systemd --user
801|800|node /home/u/.npm/_npx/z/node_modules/.bin/context7-mcp
900|999|node /home/u/.npm/_npx/w/node_modules/.bin/context7-mcp
T

run() { REAP_ORPHANS_INPUT="$FIX" REAP_ORPHANS_LOG="$LOG" bash "$REAPER" 2>&1; }

out=$(run)
rc=$?
[ "$rc" -eq 0 ] && pass "report-only exits 0" || fail "report-only rc=$rc"
grep -q 'ORPHAN 200 ' <<< "$out" && pass "orphan context7 flagged" || fail "orphan context7 not flagged"
grep -q 'ORPHAN 201 ' <<< "$out" && pass "orphan child of orphan flagged" || fail "201 not flagged"
grep -q 'ORPHAN 300 ' <<< "$out" && pass "orphan graphify-mcp flagged" || fail "300 not flagged"
grep -q 'ORPHAN 600 ' <<< "$out" && pass "orphan plugin-cache LSP flagged" || fail "600 not flagged"
! grep -q 'ORPHAN 101 \|ORPHAN 102 ' <<< "$out" && pass "claude-descended MCP/LSP spared" || fail "live-claude child flagged"
! grep -q 'ORPHAN 111 ' <<< "$out" && pass "codex-owned MCP spared" || fail "codex child flagged"
! grep -q 'ORPHAN 121 ' <<< "$out" && pass "npm-claude (node) owned MCP spared" || fail "npm claude child flagged"
! grep -q 'ORPHAN 131 ' <<< "$out" && pass "full-path claude owned MCP spared" || fail "full-path claude child flagged"
! grep -q 'ORPHAN 400 ' <<< "$out" && pass "qmd --http daemon whitelisted" || fail "qmd flagged"
! grep -q 'ORPHAN 701 ' <<< "$out" && pass "editor-owned tsserver spared" || fail "editor tsserver flagged"
! grep -q 'ORPHAN 801 ' <<< "$out" && pass "user-systemd-owned service spared" || fail "systemd --user child flagged"
! grep -q 'ORPHAN 401 ' <<< "$out" && pass "child of a whitelisted daemon spared" || fail "whitelisted daemon child flagged"
! grep -q 'ORPHAN 900 ' <<< "$out" && pass "unknown parent chain spared" || fail "unresolved chain flagged"
! grep -q 'ORPHAN 500 ' <<< "$out" && pass "non-MCP argv0 not matched" || fail "bash note flagged"
! grep -q 'ORPHAN 510 ' <<< "$out" && pass "rg naming an MCP server not matched" || fail "rg flagged"
! grep -q 'ORPHAN 511 ' <<< "$out" && pass "less on a plugin-cache file not matched" || fail "less flagged"
! grep -q 'ORPHAN 512 ' <<< "$out" && pass "vim on a plugin-cache file not matched" || fail "vim flagged"
! grep -q 'ORPHAN 550 ' <<< "$out" && pass "signature in an option argument not matched" || fail "option-argument mention flagged"
grep -q 'would kill' <<< "$out" && pass "report-only says would kill" || fail "no would-kill wording"
[ -s "$LOG" ] && pass "log appended" || fail "log empty"

out=$(REAP_ORPHANS_INPUT="$FIX" bash "$REAPER" --kill 2>&1); rc=$?
[ "$rc" -eq 2 ] && pass "--kill refuses the canned-table seam" || fail "--kill on seam rc=$rc"

out=$(REAP_ORPHANS_INPUT="$FIX" REAP_ORPHANS_LOG="/proc/no-such-dir/x.log" bash "$REAPER" 2>&1); rc=$?
[ "$rc" -eq 1 ] && pass "unwritable log exits 1" || fail "unwritable log rc=$rc"

# Kill path: two real processes, both listed as orphans. P1 matches its table
# row and must die; P2 is listed with a different command line (a recycled
# PID) and must survive.
# The identity re-check reads /proc, and with no /proc the reaper refuses to
# signal anything (by design), so there is no kill path to exercise on macOS.
if [ ! -r /proc/self/stat ]; then
    echo "  SKIP  kill path: no /proc on this host, the reaper never signals an unverifiable process"
    [ "$failures" -eq 0 ] && { echo "all passed"; exit 0; }
    echo "$failures failed"; exit 1
fi
cp "$(command -v sleep)" "$WORK/context7-mcp"
"$WORK/context7-mcp" 300 & P1=$!
"$WORK/context7-mcp" 301 & P2=$!
KFIX="$WORK/kill.txt"
printf '%s|1|%s 300\n%s|1|%s 999\n' "$P1" "$WORK/context7-mcp" "$P2" "$WORK/context7-mcp" > "$KFIX"
out=$(REAP_ORPHANS_INPUT="$KFIX" REAP_ORPHANS_TEST_KILL=1 REAP_ORPHANS_LOG="$LOG" bash "$REAPER" --kill 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "--kill run exits 0" || fail "--kill rc=$rc"
sleep 0.5
# A killed child of this shell lingers as a zombie (state Z) until reaped.
st1=$(ps -o stat= -p "$P1" 2>/dev/null); st2=$(ps -o stat= -p "$P2" 2>/dev/null)
case "$st1" in ""|Z*) pass "matching orphan killed" ;; *) fail "matching orphan survived --kill" ;; esac
case "$st2" in ""|Z*) fail "recycled-pid stand-in was killed" ;; *) pass "pid with a changed command line spared" ;; esac
grep -q '1 signalled, 1 skipped, 0 failed' <<< "$out" && pass "kill summary counts signalled and skipped" || fail "kill summary wrong: $out"

[ "$failures" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$failures failed"; exit 1
