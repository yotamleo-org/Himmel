#!/usr/bin/env bash
# Tests for pointers.sh and the repo-wide CLAUDE.md/AGENTS.md drift check.
# Fixture rows use a throwaway git repo; the last rows check the
# REAL repo, so an unregenerated AGENTS.md anywhere fails CI. Bash 3.2-safe.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PTR="$SCRIPT_DIR/pointers.sh"
GEN="$SCRIPT_DIR/generate.mjs"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
expect() { # <want-rc> <desc> <cmd...>
  local want="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (rc=$rc, want $want)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-pointers.XXXXXX")" || exit 1; trap 'rm -rf "$TMP"' EXIT
F="$TMP/repo"; mkdir -p "$F/sub" "$F/tpl" "$F/marketplace/plugins/claude-hud"
git -C "$F" init -q
printf '# root\n' > "$F/CLAUDE.md"
printf '# sub\n' > "$F/sub/CLAUDE.md"
printf '# manual\n' > "$F/tpl/_CLAUDE.md"
printf '# vendored\n' > "$F/marketplace/plugins/claude-hud/CLAUDE.md"
git -C "$F" add -A

export POINTERS_ROOT="$F"
expect 1 "check fails when a subdir pointer is missing" bash "$PTR" --check
expect 0 "write succeeds" bash "$PTR" --write
expect 0 "check passes after write" bash "$PTR" --check
if grep -q '_CLAUDE.md' "$F/tpl/AGENTS.md" 2>/dev/null; then ok "_CLAUDE.md dir gets a pointer naming _CLAUDE.md"; else bad "_CLAUDE.md dir pointer"; fi
if [ -f "$F/AGENTS.md" ]; then bad "repo root untouched"; else ok "repo root is left to generate.mjs"; fi
if [ -f "$F/marketplace/plugins/claude-hud/AGENTS.md" ]; then bad "vendored tree excluded"; else ok "vendored tree excluded"; fi
printf 'hand edit\n' >> "$F/sub/AGENTS.md"
expect 1 "check fails on a hand-edited pointer" bash "$PTR" --check
bash "$PTR" --write >/dev/null 2>&1
expect 0 "check passes after re-write" bash "$PTR" --check
mkdir -p "$F/has space"; printf '# sp\n' > "$F/has space/CLAUDE.md"; git -C "$F" add -A
expect 1 "check fails on a directory name with a space" bash "$PTR" --check
bash "$PTR" --write >/dev/null 2>&1
if [ -f "$F/has space/AGENTS.md" ]; then ok "directory with a space gets its pointer"; else bad "directory with a space gets its pointer"; fi
printf 'stale\n' > "$F/sub/AGENTS.md"; chmod a-w "$F/sub/AGENTS.md"
if [ -w "$F/sub/AGENTS.md" ]; then ok "write-failure row skipped (running as a user that ignores modes)"
else expect 1 "write fails loudly when a pointer cannot be written" bash "$PTR" --write; fi
chmod u+w "$F/sub/AGENTS.md"
mkdir -p "$TMP/notgit"
expect 2 "check refuses a root where git ls-files fails" env POINTERS_ROOT="$TMP/notgit" bash "$PTR" --check
E="$TMP/rootonly"; mkdir -p "$E"; git -C "$E" init -q; printf '# root\n' > "$E/CLAUDE.md"; git -C "$E" add -A
expect 0 "write with no non-root manuals succeeds" env POINTERS_ROOT="$E" bash "$PTR" --write
if [ -f "$E/AGENTS.md" ]; then bad "write never creates the root AGENTS.md"; else ok "write never creates the root AGENTS.md"; fi
mkdir -p "$F/café"; printf '# u\n' > "$F/café/CLAUDE.md"; git -C "$F" add -A
bash "$PTR" --write >/dev/null 2>&1
if [ -f "$F/café/AGENTS.md" ]; then ok "non-ASCII directory gets its pointer"; else bad "non-ASCII directory gets its pointer"; fi
unset POINTERS_ROOT

# ---- the real repo ---------------------------------------------------------
expect 0 "real repo: every non-root CLAUDE.md has a fresh AGENTS.md pointer" bash "$PTR" --check
expect 0 "real repo: root AGENTS.md is fresh vs CLAUDE.md" node "$GEN" --check

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
