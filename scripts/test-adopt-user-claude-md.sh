#!/usr/bin/env bash
# Smoke test for scripts/lib/user-claude-md.sh's wire_user_claude_md
# (the user-scope "working principles" CLAUDE.md installer
# wired into adopt.sh's/adopt.ps1's do_core(), user-scope branch only).
#
# Every case runs against its own TEMP HOME fixture (mktemp -d) and an
# explicit --target path under it -- this NEVER reads or writes the real
# ~/.claude/CLAUDE.md.
#
# Usage: bash scripts/test-adopt-user-claude-md.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline, so a match under `set -o pipefail` can't be reported as a
# pipeline failure (same helper as test-check-no-secrets.sh).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/user-claude-md.sh"
TEMPLATE="$REPO_ROOT/docs/setup/user-scope-claude-md-template.md"
MARKER="HIMMEL:working-principles"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB"
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "FAIL: template not found at $TEMPLATE"
  exit 1
fi

# shellcheck source=lib/user-claude-md.sh
# shellcheck disable=SC1091
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# ── Case 1: fresh HOME (no target file) → created, both markers + payload ──
echo "== Case 1: fresh HOME, no target file =="
home1="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
target1="$home1/.claude/CLAUDE.md"
out1="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target1" 2>&1)"

if [ -f "$target1" ]; then pass "target created"; else fail "target NOT created"; fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$target1" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$target1" 2>/dev/null; then
  pass "both marker lines present"
else
  fail "marker lines missing in created file"
fi
if grep -qi "simplicity first" "$target1" 2>/dev/null; then
  pass "payload text present"
else
  fail "payload text missing"
fi
if grepq "$out1" -F "created"; then pass "create status line printed"; else fail "no create status line, got: $out1"; fi
rm -rf "$home1"

# ── Case 2: existing file, unrelated content → payload appended, original
#            content preserved as an exact byte-for-byte prefix ──
echo "== Case 2: existing file, unrelated content =="
home2="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
mkdir -p "$home2/.claude"
target2="$home2/.claude/CLAUDE.md"
orig2="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
printf '# my own notes\nsome unrelated content\n' > "$orig2"
cp "$orig2" "$target2"
orig2_bytes="$(wc -c < "$orig2" | tr -d '[:space:]')"

out2="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target2" 2>&1)"

prefix2="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
head -c "$orig2_bytes" "$target2" > "$prefix2"
if cmp -s "$orig2" "$prefix2"; then
  pass "original content preserved as exact prefix"
else
  fail "original content prefix does NOT match"
fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$target2" 2>/dev/null; then
  pass "marker appended"
else
  fail "marker not appended"
fi
if grepq "$out2" -F "appended"; then pass "append status line printed"; else fail "no append status line, got: $out2"; fi
rm -f "$orig2" "$prefix2"

# ── Case 3: re-run over case 2's result → byte-identical, skip line printed ──
echo "== Case 3: re-run over an already-wired file =="
before3="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
cp "$target2" "$before3"

out3="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target2" 2>&1)"

if cmp -s "$before3" "$target2"; then
  pass "file unchanged (byte-identical) on re-run"
else
  fail "file CHANGED on a re-run — not idempotent"
fi
if grepq "$out3" -F "already present"; then
  pass "skip line printed"
else
  fail "no skip line on re-run, got: $out3"
fi
rm -f "$before3"
rm -rf "$home2"

# ── Case 4: heuristic — existing file has "Simplicity first" but no marker
#            → left unchanged, heuristic skip line printed ──
echo "== Case 4: heuristic match (hand-written principles, no marker) =="
home4="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
mkdir -p "$home4/.claude"
target4="$home4/.claude/CLAUDE.md"
printf '# My principles\n\n1. Simplicity first — do the minimum.\n' > "$target4"
before4="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
cp "$target4" "$before4"

out4="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target4" 2>&1)"

if cmp -s "$before4" "$target4"; then
  pass "file unchanged (heuristic match — no marker duplicated)"
else
  fail "file CHANGED despite heuristic match"
fi
if grepq "$out4" -F "heuristic"; then
  pass "heuristic skip line printed"
else
  fail "no heuristic skip line, got: $out4"
fi
rm -f "$before4"
rm -rf "$home4"

# ── Case 5: template has a BEGIN marker but no END marker → refuse.
#            A sed range with an unmatched END address prints through EOF, so
#            without the guard the whole rest of the template would be appended
#            to the user's CLAUDE.md. ──
echo "== Case 5: unterminated marker range is refused =="
home5="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
bad_template="$home5/bad-template.md"
printf '# doc\n\n<!-- BEGIN HIMMEL:working-principles -->\npayload line\n\nunrelated trailing prose that must NOT be installed\n' > "$bad_template"
target5="$home5/.claude/CLAUDE.md"

out5="$(DRY_RUN=0 wire_user_claude_md "$bad_template" "$target5" 2>&1)"

if [ ! -e "$target5" ]; then
  pass "target NOT created from an unterminated marker range"
else
  fail "target was created from an unterminated marker range: $(cat "$target5")"
fi
if grepq "$out5" -F "no END marker"; then
  pass "unterminated-range refusal line printed"
else
  fail "no unterminated-range refusal line, got: $out5"
fi
rm -rf "$home5"

# ── Case 6: two-target install -- adopt.sh/adopt.ps1 call
#            wire_user_claude_md once per user-scope rule file (Claude Code's
#            ~/.claude/CLAUDE.md AND Codex's ~/.codex/AGENTS.md) so a Codex
#            adopter isn't left with the principles nowhere. Fresh HOME -> both
#            created with the marker; re-run -> both byte-identical ──
echo "== Case 6: two-target install (Claude CLAUDE.md + Codex AGENTS.md) =="
home6="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
claude_target6="$home6/.claude/CLAUDE.md"
codex_target6="$home6/.codex/AGENTS.md"

out6a="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$claude_target6" 2>&1)"
out6b="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$codex_target6" 2>&1)"

if [ -f "$claude_target6" ]; then pass "Claude target created"; else fail "Claude target NOT created"; fi
if [ -f "$codex_target6" ]; then pass "Codex target created"; else fail "Codex target NOT created"; fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$claude_target6" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$claude_target6" 2>/dev/null; then
  pass "Claude target has both marker lines"
else
  fail "Claude target missing marker lines"
fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$codex_target6" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$codex_target6" 2>/dev/null; then
  pass "Codex target has both marker lines"
else
  fail "Codex target missing marker lines"
fi
if grepq "$out6a" -F "created"; then pass "Claude create status line printed"; else fail "no Claude create status line, got: $out6a"; fi
if grepq "$out6b" -F "created"; then pass "Codex create status line printed"; else fail "no Codex create status line, got: $out6b"; fi

before6a="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"; cp "$claude_target6" "$before6a"
before6b="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"; cp "$codex_target6" "$before6b"

DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$claude_target6" >/dev/null 2>&1
DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$codex_target6" >/dev/null 2>&1

if cmp -s "$before6a" "$claude_target6"; then
  pass "Claude target unchanged (byte-identical) on re-run"
else
  fail "Claude target CHANGED on a re-run — not idempotent"
fi
if cmp -s "$before6b" "$codex_target6"; then
  pass "Codex target unchanged (byte-identical) on re-run"
else
  fail "Codex target CHANGED on a re-run — not idempotent"
fi
rm -f "$before6a" "$before6b"
rm -rf "$home6"

# ── Case 7: a real install records a provenance block row ──
# Only a write that happened is recorded: not a dry run, not an idempotent
# re-run. Runs in a subshell so the sourced provenance lib does not leak.
echo "== Case 7: provenance block row =="
home7="$(mktemp -d "${TMPDIR:-/tmp}/h3787.XXXXXX")"
ledger7="$home7/prov/provenance.jsonl"
rows7() { jq -c 'select(.kind=="block")' "$ledger7" 2>/dev/null | grep -c .; }
(
  # shellcheck disable=SC2030  # the ledger dir is deliberately subshell-local
  export HIMMEL_PROVENANCE_DIR="$home7/prov"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/provenance.sh"
  prov_begin --writer adopt.sh -- case7 >/dev/null
  DRY_RUN=1 wire_user_claude_md "$TEMPLATE" "$home7/.claude/CLAUDE.md" >/dev/null 2>&1
  prov_end ok >/dev/null
)
if [ "$(rows7)" = "0" ] && [ ! -e "$home7/.claude/CLAUDE.md" ]; then pass "dry run: no file, no block row"; else fail "dry run wrote a file or a row"; fi
(
  # shellcheck disable=SC2031  # the ledger dir is deliberately subshell-local
  export HIMMEL_PROVENANCE_DIR="$home7/prov"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/provenance.sh"
  prov_begin --writer adopt.sh -- case7 >/dev/null
  wire_user_claude_md "$TEMPLATE" "$home7/.claude/CLAUDE.md" >/dev/null 2>&1
  wire_user_claude_md "$TEMPLATE" "$home7/.claude/CLAUDE.md" >/dev/null 2>&1
  prov_end ok >/dev/null
)
if [ "$(rows7)" = "1" ]; then pass "create + idempotent re-run: exactly one block row"; else fail "expected 1 block row, got $(rows7)"; fi
row7="$(jq -c 'select(.kind=="block")' "$ledger7" 2>/dev/null | head -n 1)"
if [ "$(jq -r '[.op,.manifest_row,.marker,(.file_created|tostring)]|join(" ")' <<< "$row7")" = "insert user-claude-md $MARKER true" ]; then
  pass "row: insert / user-claude-md / marker id / file_created=true"; else fail "row shape wrong: $row7"; fi
rm -rf "$home7"

# ── Case 8: an older himmel block between the markers is refreshed in place
#            (u1), and a second run changes nothing (u2) ──
echo "== Case 8: older block between the markers is refreshed in place =="
home8="$(mktemp -d "${TMPDIR:-/tmp}/h8010.XXXXXX")" || exit 1
mkdir -p "$home8/.claude"
target8="$home8/.claude/CLAUDE.md"
head8="$home8/head.txt"; tail8="$home8/tail.txt"; want8="$home8/want.txt"
printf '# my own notes\nbefore the block\n\n' > "$head8"
printf '\nafter the block\nlast line\n' > "$tail8"
{ cat "$head8"
  printf '<!-- BEGIN %s -->\nan older principle line\n<!-- END %s -->\n' "$MARKER" "$MARKER"
  cat "$tail8"; } > "$target8"
sed -n "/<!-- BEGIN $MARKER -->/,/<!-- END $MARKER -->/p" "$TEMPLATE" > "$home8/block.txt"
{ cat "$head8"; cat "$home8/block.txt"; cat "$tail8"; } > "$want8"

out8="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target8" 2>&1)"
if cmp -s "$want8" "$target8"; then
  pass "u1: block replaced by the template's, text outside the markers byte-identical"
else
  fail "u1: target is not head + template block + tail"
fi
if grepq "$out8" -F "refreshed"; then pass "refresh status line printed"; else fail "no refresh status line, got: $out8"; fi

before8="$home8/before.txt"; cp "$target8" "$before8"
out8b="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target8" 2>&1)"
if cmp -s "$before8" "$target8" && cmp -s "$want8" "$target8"; then pass "u2: second run changes nothing"; else fail "u2: second run CHANGED the file or the first never refreshed it"; fi
if grepq "$out8b" -F "already present"; then pass "second run prints the skip line"; else fail "no skip line on second run, got: $out8b"; fi
rm -rf "$home8"

# ── Case 9: heuristic-only target (u3) stays unchanged; the one advisory
#            names the template path ──
echo "== Case 9: heuristic-only target, advisory names the template =="
home9="$(mktemp -d "${TMPDIR:-/tmp}/h8010.XXXXXX")" || exit 1
mkdir -p "$home9/.claude"
target9="$home9/.claude/CLAUDE.md"
printf '# My principles\n\n1. Simplicity first — do the minimum.\n' > "$target9"
before9="$home9/before.txt"; cp "$target9" "$before9"
out9="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target9" 2>&1)"
if cmp -s "$before9" "$target9"; then pass "u3: heuristic-only target unchanged"; else fail "u3: heuristic-only target CHANGED"; fi
if grepq "$out9" -F "$TEMPLATE"; then pass "u3: advisory names the template path"; else fail "u3: advisory does not name the template, got: $out9"; fi
rm -rf "$home9"

# ── Case 10: BEGIN without END (u4) is left unchanged ──
echo "== Case 10: BEGIN marker with no END marker =="
home10="$(mktemp -d "${TMPDIR:-/tmp}/h8010.XXXXXX")" || exit 1
mkdir -p "$home10/.claude"
target10="$home10/.claude/CLAUDE.md"
printf 'intro\n<!-- BEGIN %s -->\nan older principle line\ntrailing operator text\n' "$MARKER" > "$target10"
before10="$home10/before.txt"; cp "$target10" "$before10"
DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target10" >/dev/null 2>&1
if cmp -s "$before10" "$target10"; then pass "u4: BEGIN-without-END target unchanged"; else fail "u4: BEGIN-without-END target CHANGED"; fi
rm -rf "$home10"

# ── Case 11: the callers (adopt.sh, himmel-update.sh) run under
#             `set -euo pipefail`, so the append path of a marker-less target
#             must survive errexit ──
echo "== Case 11: marker-less target under set -euo pipefail =="
home11="$(mktemp -d "${TMPDIR:-/tmp}/h8010.XXXXXX")" || exit 1
mkdir -p "$home11/.claude"
target11="$home11/.claude/CLAUDE.md"
printf '# my own notes\nsome unrelated content\n' > "$target11"
# shellcheck source=lib/user-claude-md.sh
# shellcheck disable=SC1091
( set -euo pipefail; . "$LIB"; wire_user_claude_md "$TEMPLATE" "$target11" ) >/dev/null 2>&1
rc11=$?
if [ "$rc11" -eq 0 ] && grep -q -- "<!-- BEGIN $MARKER -->" "$target11"; then
  pass "append path survives errexit (rc 0, block appended)"
else
  fail "append path died under errexit (rc $rc11)"
fi
sed -i.bak 's/^Use judgement on trivial tasks\.$/Use an older line./' "$target11" && rm -f "$target11.bak"
# shellcheck source=lib/user-claude-md.sh
# shellcheck disable=SC1091
( set -euo pipefail; . "$LIB"; wire_user_claude_md "$TEMPLATE" "$target11" ) >/dev/null 2>&1
rc11=$?
if [ "$rc11" -eq 0 ] && ! grep -q "Use an older line" "$target11"; then
  pass "refresh path survives errexit (rc 0, older line replaced)"
else
  fail "refresh path died or did not refresh under errexit (rc $rc11)"
fi
rm -rf "$home11"

# ── Case 12: prose that merely quotes the marker text inside a line is not a
#             marker line -- the refresh must not overwrite it ──
echo "== Case 12: quoted marker text in prose is not a block =="
home12="$(mktemp -d "${TMPDIR:-/tmp}/h8010.XXXXXX")" || exit 1
mkdir -p "$home12/.claude"
target12="$home12/.claude/CLAUDE.md"
orig12="$home12/orig.txt"
printf "Notes: wrap it as '<!-- BEGIN %s -->' ... '<!-- END %s -->'.\nkeep this operator line\n" "$MARKER" "$MARKER" > "$orig12"
cp "$orig12" "$target12"
DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target12" >/dev/null 2>&1
prefix12="$home12/prefix.txt"
head -c "$(wc -c < "$orig12" | tr -d '[:space:]')" "$target12" > "$prefix12"
if cmp -s "$orig12" "$prefix12"; then pass "quoting prose kept byte-identical"; else fail "prose quoting the markers was overwritten"; fi
rm -rf "$home12"

# Final tally
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
