#!/usr/bin/env bash
# Test for scripts/hooks/refresh-statusline-caches-periodic.sh.
# Hermetic: seeded projects dir + rollup stub; no network. Asserts the hook
# writes no all-sessions index and invokes the rollup for the
# branch key — synchronously, exit 0, no orphan.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/refresh-statusline-caches-periodic.sh"

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seeded transcript history (proj_root/<dir>/<file>.jsonl, one level down).
PROJ="$TMP/projects"; mkdir -p "$PROJ/sess-a" "$PROJ/sess-b"
printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1000000,"cache_creation_input_tokens":50000,"input_tokens":10000}}}' > "$PROJ/sess-a/t.jsonl"
printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":3000000,"cache_creation_input_tokens":100000,"input_tokens":20000}}}' > "$PROJ/sess-b/t.jsonl"
# Totals: reads 4,000,000  writes 150,000  inputs 30,000.

ECON="$TMP/econ"; mkdir -p "$ECON"
ROLLDIR="$TMP/roll"; mkdir -p "$ROLLDIR"

# Rollup stub records that it was called with the right --key/--out.
rollup_marker="$TMP/rollup-called"
rollup_stub="$TMP/rollup-stub.sh"
cat > "$rollup_stub" <<STUB
#!/usr/bin/env bash
echo "\$*" > "$rollup_marker"
# Emulate statusline-rollup.sh: write the --out cache so TTL-freshness is testable.
out=""
while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2"; shift 2;; *) shift;; esac; done
[ -n "\$out" ] && printf '%s\n' '{"epic":"HIMMEL-999","done":1,"total":3}' > "\$out"
STUB
chmod +x "$rollup_stub"

# A temp git repo on a ticket branch so the hook derives a key.
GITDIR="$TMP/repo"; mkdir -p "$GITDIR"
git -C "$GITDIR" init -q 2>/dev/null
git -C "$GITDIR" checkout -q -b feat/HIMMEL-999-demo 2>/dev/null

# ── Case 0: the refresh writes the epic rollup and NO all-sessions index
ECON0="$TMP/econ0"; mkdir -p "$ECON0"; ROLLDIR0="$ROLLDIR"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON0" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR0" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$ROLLDIR0/where-are-we-rollup-HIMMEL-999.json" ] \
   && [ -z "$(find "$ECON0" -name 'cache-*-index.json' 2>/dev/null)" ]; then
    pass "refresh writes the epic rollup and no all-sessions index"
else
    fail "refresh -> rc=$rc rollup=$([ -f "$ROLLDIR0/where-are-we-rollup-HIMMEL-999.json" ] && echo yes || echo no) index=$(find "$ECON0" -name 'cache-*-index.json' 2>/dev/null)"
fi

# ── Case 2: rollup invoked for the branch key ───────────────────────────────
if [ -f "$rollup_marker" ] && grep -qF -- '--key HIMMEL-999' "$rollup_marker"; then
    pass "rollup invoked with --key HIMMEL-999"
else
    fail "rollup not invoked for key: $(cat "$rollup_marker" 2>/dev/null || echo '(no marker)')"
fi

# ── Case 2.5: TTL-throttle — a second call within TTL skips the fresh refresh ─
# After Case 0 the rollup cache is fresh (<900s); a repeat call must NOT invoke
# the rollup stub (a per-turn UserPromptSubmit trigger stays a cheap no-op).
rm -f "$rollup_marker"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
if [ ! -f "$rollup_marker" ]; then
    pass "TTL-throttle -> fresh rollup cache skips refresh (no stub call)"
else
    fail "TTL-throttle -> refreshed despite fresh cache"
fi
# And with TTL=0 the throttle is bypassed → refresh runs again.
rm -f "$rollup_marker"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_TTL=0 \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
if [ -f "$rollup_marker" ] && grep -qF -- '--key HIMMEL-999' "$rollup_marker"; then
    pass "TTL=0 -> throttle bypassed, refresh runs"
else
    fail "TTL=0 -> refresh did not run"
fi

# ── Case 3: no key branch (main) → no rollup call, still exits 0
git -C "$GITDIR" checkout -q -B main 2>/dev/null
rm -f "$rollup_marker"
ECON2="$TMP/econ2"; mkdir -p "$ECON2"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON2" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$rollup_marker" ]; then
    pass "main branch -> no rollup call, exit 0"
else
    fail "main branch -> rc=$rc rollup_called=$([ -f "$rollup_marker" ] && echo yes || echo no)"
fi

# ── Case 4: static no-spawn — the hook itself carries no detached-fork pattern
strip_comments() { sed -E 's/^[[:space:]]*#.*//; s/([[:space:]])#.*/\1/' "$1"; }
if [ -z "$(strip_comments "$HOOK" | grep -nE '&[[:space:]]*disown|\([^)]*&[[:space:]]*\)|[^&>|]&[[:space:]]*$' || true)" ]; then
    pass "static no-spawn: hook carries no detached-fork pattern"
else
    fail "static no-spawn: hook carries a detached-fork pattern"
fi

echo "---"
echo "hook: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
