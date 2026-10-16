#!/usr/bin/env bash
# Suite for scripts/cleanup/reap-mcp-orphans.sh.
#
# Drives the CLASSIFIER against a canned process table via REAP_ORPHANS_INPUT
# (pid|ppid|comm|command line) — nothing is spawned or signalled.
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
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/procs.txt"
LOG="$WORK/reap.log"

cat > "$FIX" <<'T'
1|0|systemd|/sbin/init
100|1|claude|claude --resume
101|100|node|node /home/u/.npm/_npx/x/node_modules/.bin/context7-mcp
102|101|node|node /usr/lib/node_modules/typescript/lib/tsserver.js
200|1|node|node /home/u/.npm/_npx/y/node_modules/.bin/context7-mcp
201|200|node|node /usr/lib/node_modules/typescript/lib/typingsInstaller.js
300|1|bun|bun run /home/u/graphify-mcp/server.ts
400|1|node|node /opt/qmd/dist/cli.js qmd --http /home/u/.claude/plugins/cache/qmd
700|1|code|code --folder /home/u/proj
701|700|node|node /usr/lib/node_modules/typescript/lib/tsserver.js
500|1|bash|bash scripts/foo.sh context7-mcp-docs-note
600|1|node|node /home/u/.claude/plugins/cache/x/typescript-language-server --stdio
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
! grep -q 'ORPHAN 400 ' <<< "$out" && pass "qmd --http daemon whitelisted" || fail "qmd flagged"
! grep -q 'ORPHAN 701 ' <<< "$out" && pass "editor-owned tsserver spared" || fail "editor tsserver flagged"
! grep -q 'ORPHAN 500 ' <<< "$out" && pass "non-MCP argv0 not matched" || fail "bash note flagged"
grep -q 'would kill' <<< "$out" && pass "report-only says would kill" || fail "no would-kill wording"
[ -s "$LOG" ] && pass "log appended" || fail "log empty"

out=$(REAP_ORPHANS_INPUT="$FIX" bash "$REAPER" --kill 2>&1); rc=$?
[ "$rc" -eq 2 ] && pass "--kill refuses the canned-table seam" || fail "--kill on seam rc=$rc"

[ "$failures" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$failures failed"; exit 1
