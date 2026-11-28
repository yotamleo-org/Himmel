#!/usr/bin/env bash
# Tests for generate.mjs — the CLAUDE.md -> AGENTS.md generator.
# Bash 3.2-safe. Uses temp fixtures + env path overrides; never WRITES the
# repo's real CLAUDE.md / AGENTS.md. One deliberate exception to fixture
# hermeticity: section 9b READS the real CLAUDE.md as a rewrap-drift guard
# so an unrelated CLAUDE.md edit can legitimately fail it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate.mjs"
PREAMBLE="$SCRIPT_DIR/preamble.md"
DEBRAND="$SCRIPT_DIR/debrand.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# Reliable CR detection (this platform's grep cannot match $'\r'): a file has CR
# iff stripping \r changes its byte count.
has_cr() { [ "$(wc -c < "$1")" -ne "$(tr -d '\r' < "$1" | wc -c)" ]; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <expected-rc> <description> -- <gen args...>  (env: SRC/TGT honored)
run() {
  local want="$1"; shift
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  AGENTS_MD_SOURCE="$SRC" AGENTS_MD_TARGET="$TGT" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$DEBRAND" \
    node "$GEN" "$@" >"$TMP/out" 2>"$TMP/err"
  local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (rc=$rc, want $want); stderr: $(cat "$TMP/err")"; fi
  return 0
}

# ---- fixtures -------------------------------------------------------------
SRC="$TMP/CLAUDE.md"; TGT="$TMP/AGENTS.md"
cat > "$SRC" <<'EOF'
# Fixture Rules

A live URL → `WebFetch` directly. Use judgement on trivial tasks.
EOF

# ---- 1. write: ladder before body, LF-only, debrand applied --------------
run 0 "write succeeds on small fixture" -- --write
out="$(cat "$TGT")"
case "$out" in
  "# AGENTS.md — himmel rules"*) ok "output starts with preamble title";;
  *) bad "output starts with preamble title";;
esac
prec_pos=$(grep -n "## Precedence — read this first" "$TGT" | head -1 | cut -d: -f1)
body_pos=$(grep -n "^# Fixture Rules" "$TGT" | head -1 | cut -d: -f1)
if [ -n "$prec_pos" ] && [ -n "$body_pos" ] && [ "$prec_pos" -lt "$body_pos" ]; then
  ok "precedence ladder appears before CLAUDE.md body"
else bad "precedence ladder appears before CLAUDE.md body (prec=$prec_pos body=$body_pos)"; fi
if has_cr "$TGT"; then bad "output is LF-only (found CR)"; else ok "output is LF-only"; fi
if grep -q "your web-fetch tool" "$TGT" && ! grep -q "WebFetch" "$TGT"; then
  ok "debrand substitution applied"
else bad "debrand substitution applied"; fi

# ---- 2. check: fresh = 0 --------------------------------------------------
run 0 "check exits 0 when AGENTS.md is fresh" -- --check

# ---- 3. check: stale = 1 (source edited, not regenerated) ----------------
printf '\nAn extra rule line.\n' >> "$SRC"
run 1 "check exits 1 when source edited without regenerating" -- --check
# regenerate to restore fresh state for later tests
run 0 "re-write after edit" -- --write
run 0 "check fresh again after re-write" -- --check

# ---- 4. CRLF-normalized compare (no false positive) ----------------------
# Rewrite the target with genuine CRLF endings; --check must still pass.
# awk reliably interprets the \r\n escapes (sed's \r handling is platform-variable).
awk 'BEGIN{ORS="\r\n"}{print}' "$TGT" > "$TGT.crlf" && mv "$TGT.crlf" "$TGT"
if has_cr "$TGT"; then ok "target now has CRLF endings (setup)"; else bad "CRLF setup failed"; fi
run 0 "check exits 0 despite CRLF target (normalized compare)" -- --check
run 0 "re-write restores LF target" -- --write

# ---- 5. @include rejection = 2 -------------------------------------------
SAVED_SRC="$SRC"; SRC="$TMP/with-include.md"; TGT="$TMP/AGENTS-inc.md"
printf '# Has include\n@RTK.md\nmore\n' > "$SRC"
run 2 "write rejects @include line (cannot-evaluate)" -- --write
run 2 "check rejects @include line (cannot-evaluate)" -- --check
SRC="$SAVED_SRC"; TGT="$TMP/AGENTS.md"

# ---- 6. >32 KiB hard-fail = 2 --------------------------------------------
BIG="$TMP/big.md"; TGTBIG="$TMP/AGENTS-big.md"
{ printf '# Big Rules\n'; head -c 36000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BIG"
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$BIG"; TGT="$TGTBIG"
run 2 "write hard-fails when assembled output > 32 KiB" -- --write
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- 7. 24-32 KiB warn band (exit 0 + stderr warning) --------------------
WARN="$TMP/warn.md"; TGTWARN="$TMP/AGENTS-warn.md"
{ printf '# Warn Rules\n'; head -c 25000 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$WARN"
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$WARN"; TGT="$TGTWARN"
AGENTS_MD_SOURCE="$SRC" AGENTS_MD_TARGET="$TGT" AGENTS_MD_PREAMBLE="$PREAMBLE" \
  AGENTS_MD_DEBRAND="$DEBRAND" node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ]; then ok "warn-band write exits 0"; else bad "warn-band write exits 0 (rc=$rc)"; fi
if grep -qi "warn" "$TMP/err"; then ok "warn-band emits stderr warning"; else bad "warn-band emits stderr warning"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- 8. idempotency -------------------------------------------------------
run 0 "idempotency write #1" -- --write
cp "$TGT" "$TMP/first"
run 0 "idempotency write #2" -- --write
if cmp -s "$TMP/first" "$TGT"; then ok "two writes are byte-identical"; else bad "two writes are byte-identical"; fi

# ---- 9. Fable debrand ----------------------------------------
FAB="$TMP/fable.md"; TGTFAB="$TMP/AGENTS-fable.md"
cat > "$FAB" <<'EOF'
# Fixture Rules

Escalate, not top-down: an Opus parent spawns a Fable child for the one hard
call; work above your tier is returned.
EOF
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$FAB"; TGT="$TGTFAB"
run 0 "fable fixture write succeeds" -- --write
if grep -qF 'a mid-tier parent spawns a top-model child' "$TGT" && ! grep -qE 'Fable|Opus' "$TGT"; then
  ok "escalation dispatch neutralized"
else bad "escalation dispatch neutralized"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# b) real-CLAUDE.md leak check: after generation, no identity-claiming Fable
# text may survive outside HTML comments (FABLE-WINDOW provenance comments are
# documentary and allowed). This is the guard that catches a CLAUDE.md rewrap
# silently breaking the newline-embedded debrand entries. Reads the repo's
# real CLAUDE.md; writes only to a temp target.
strip_html_comments() {   # <in> <out>
  # Two-pass on purpose: a bare sed RANGE ('/<!--/,/-->/d') treats a
  # SINGLE-LINE '<!-- ... -->' as an unterminated range START (addr2 is only
  # tested from the NEXT line) and deletes everything to the next '-->' or
  # EOF — the preamble's single-line comments would swallow the whole body
  # and make the leak check vacuously pass. So: drop inline comment spans
  # first, then range-drop the remaining true multi-line blocks.
  sed 's/<!--.*-->//g' "$1" | sed '/<!--/,/-->/d' > "$2"
}
REAL_SRC="$SCRIPT_DIR/../../CLAUDE.md"; TGTREAL="$TMP/AGENTS-real.md"
if [ -f "$REAL_SRC" ]; then
  SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$REAL_SRC"; TGT="$TGTREAL"
  run 0 "real-CLAUDE.md write succeeds" -- --write
  stripped="$TMP/real-stripped.md"
  strip_html_comments "$TGTREAL" "$stripped"
  # Guard the guard: the strip must not have eaten the body (a regression back
  # to the vacuous strip would silently green-light every leak).
  if grep -q 'Subagent policy' "$stripped"; then
    ok "comment-strip preserves the body (leak check is non-vacuous)"
  else bad "comment-strip preserves the body (leak check is non-vacuous)"; fi
  # A leak = ANY 'Fable' text outside comments, wrap-split fragments included.
  leaks="$(grep -n 'Fable' "$stripped" || true)"
  if [ -z "$leaks" ]; then
    ok "no Fable text outside comments (real CLAUDE.md)"
  else bad "no Fable text outside comments (real CLAUDE.md): $leaks"; fi
  SRC="$SAVED_SRC"; TGT="$SAVED_TGT"
fi

# c) RED PATH: prove the leak check actually fires when a rewrap breaks an
# entry: re-wrapping 'an Opus parent spawns a Fable child' stops the rule matching.
BROKEN="$TMP/fable-rewrap.md"; TGTBROKEN="$TMP/AGENTS-broken.md"
cat > "$BROKEN" <<'EOF'
# Fixture Rules

Escalate, not top-down: an Opus parent spawns a
Fable child for the one hard call.
EOF
SAVED_SRC="$SRC"; SAVED_TGT="$TGT"; SRC="$BROKEN"; TGT="$TGTBROKEN"
run 0 "rewrap red-path fixture write succeeds" -- --write
broken_stripped="$TMP/broken-stripped.md"
strip_html_comments "$TGTBROKEN" "$broken_stripped"
if grep -q 'Fable' "$broken_stripped"; then
  ok "leak check fires on a rewrap-broken entry (red path)"
else bad "leak check fires on a rewrap-broken entry (red path)"; fi
SRC="$SAVED_SRC"; TGT="$SAVED_TGT"

# ---- 10. debrand coverage enforcement ------------------------
# Coverage is OPT-IN (AGENTS_MD_ENFORCE_COVERAGE=1) and enforced by the
# dedicated gate scripts/hooks/check-debrand-coverage.sh. It must fire on ANY
# source the gate hands it — including a staged temp copy, which is what
# check-agents-md-fresh.sh generates from. Keying enforcement on "SOURCE looks
# like the canonical CLAUDE.md" would leave it dead in exactly that path.
COVSRC="$TMP/staged-copy/CLAUDE.md"; mkdir -p "$TMP/staged-copy"
# A source containing NONE of the live debrand phrases -> every live rule orphaned.
printf '# Staged copy\n\nNo branded phrases here at all.\n' > "$COVSRC"
AGENTS_MD_ENFORCE_COVERAGE=1 \
AGENTS_MD_SOURCE="$COVSRC" AGENTS_MD_TARGET="$TMP/AGENTS-cov.md" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$SCRIPT_DIR/debrand.json" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
covrc=$?
if [ "$covrc" -eq 2 ]; then
  ok "coverage fires on a staged temp copy when enforced (rc=2)"
else bad "coverage fires on a staged temp copy when enforced (rc=$covrc, want 2); stderr: $(cat "$TMP/err")"; fi
if grep -q 'no longer match' "$TMP/err"; then
  ok "coverage error names the dead rules"
else bad "coverage error names the dead rules"; fi
# Without the opt-in, the same partial source must generate cleanly — that is
# what keeps the freshness hook and both fixture suites working.
AGENTS_MD_SOURCE="$COVSRC" AGENTS_MD_TARGET="$TMP/AGENTS-cov.md" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$SCRIPT_DIR/debrand.json" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
nooptrc=$?
if [ "$nooptrc" -eq 0 ]; then ok "partial source generates cleanly without the opt-in"
else bad "partial source generates cleanly without the opt-in (rc=$nooptrc); stderr: $(cat "$TMP/err")"; fi
# The real CLAUDE.md must PASS coverage — this is the live-repo assertion.
AGENTS_MD_ENFORCE_COVERAGE=1 \
AGENTS_MD_SOURCE="$SCRIPT_DIR/../../CLAUDE.md" AGENTS_MD_TARGET="$TMP/AGENTS-live.md" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$SCRIPT_DIR/debrand.json" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
livercv=$?
if [ "$livercv" -eq 0 ]; then ok "live CLAUDE.md passes debrand coverage"
else bad "live CLAUDE.md passes debrand coverage (rc=$livercv); stderr: $(cat "$TMP/err")"; fi
# Malformed entries must be FATAL, not skipped.
# A skipped entry never reaches the orphan calculation, so a one-character schema
# typo would silently disable a live rule while both gates stayed green. Each
# case is checked WITHOUT the coverage opt-in, proving the guard is unconditional.
malformed_case() {
  local desc="$1" json="$2" want="$3"
  local f="$TMP/debrand-malformed.json"
  printf '%s\n' "$json" > "$f"
  AGENTS_MD_SOURCE="$COVSRC" AGENTS_MD_TARGET="$TMP/AGENTS-cov.md" \
    AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$f" \
    node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
  local mrc=$?
  if [ "$mrc" -eq "$want" ]; then ok "$desc"
  else bad "$desc (rc=$mrc, want $want)"; fi
}
malformed_case "missing 'from' is fatal"      '[{"to":"x"}]'                       2
malformed_case "empty 'from' is fatal"        '[{"from":"","to":"x"}]'             2
malformed_case "non-string 'from' is fatal"   '[{"from":123,"to":"x"}]'            2
malformed_case "missing 'to' is fatal"        '[{"from":"spawns a Fable child"}]'  2
malformed_case "null 'to' is fatal"           '[{"from":"a","to":null}]'           2
malformed_case "same 'from' and 'to' is fatal" '[{"from":"a","to":"a"}]'            2
malformed_case "duplicate 'from' is fatal"    '[{"from":"duplicate-phrase","to":"x"},{"from":"duplicate-phrase","to":"y"}]' 2
malformed_case "an earlier overlapping rule cannot consume a live source" '[{"from":"branded phrases","to":"neutral text"},{"from":"branded","to":"generic"}]' 2
malformed_case "non-array table is fatal"     '{"from":"a","to":"b"}'              2

# A dormant rule with no note is rejected — independent of the coverage opt-in.
NONOTE="$TMP/debrand-nonote.json"
printf '[{"from":"zzz-absent-phrase","to":"x","dormant":true}]\n' > "$NONOTE"
AGENTS_MD_SOURCE="$COVSRC" AGENTS_MD_TARGET="$TMP/AGENTS-cov.md" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$NONOTE" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
nonotercv=$?
if [ "$nonotercv" -eq 2 ]; then ok "dormant rule without a note is rejected"
else bad "dormant rule without a note is rejected (rc=$nonotercv)"; fi

# ---- 11. Astra-facing preamble elements survive the render ---
# The RED control for the GPT-6 Astra prompting changes: these three elements
# live ONLY in preamble.md (they are addressed to non-Claude harnesses, so
# CLAUDE.md is deliberately not their source), and AGENTS.md is the file a
# codex/hermes lane actually reads. Rendering the REAL preamble over the small
# fixture source proves each element reaches the generated file rather than
# being dropped by the ladder assembly, the rewrap, or a debrand rule. Every
# assertion below fails on a preamble lacking them — that is the point.
run 0 "re-write before the Astra-element assertions" -- --write
astra_has() {
  local desc="$1" pat="$2"
  if grep -qF "$pat" "$TGT"; then ok "$desc"
  else bad "$desc — not found in the generated AGENTS.md"; fi
}
astra_has "read-what-the-task-needs scoping reaches AGENTS.md" \
  "not a pre-flight checklist"
astra_has "standing test-suite permission reaches AGENTS.md" \
  "without stopping for approval at each step"
astra_has "the approval carve-out survives beside that permission" \
  "blast radius outside the worktree"
astra_has "testing calibration reaches AGENTS.md" \
  "broaden or repeat only when new changes justify it"

gemini_repo="$TMP/gemini-repo"
mkdir -p "$gemini_repo/scripts/agents-md"
cp "$GEN" "$gemini_repo/scripts/agents-md/generate.mjs"
git -C "$gemini_repo" init -q
SAVED_GEN="$GEN"; GEN="$gemini_repo/scripts/agents-md/generate.mjs"
run 0 "Gemini clean fixture write succeeds" -- --write
run 0 "Gemini clean fixture check succeeds" -- --check
printf '# Duplicate instructions\n' > "$gemini_repo/GEMINI.md"
run 0 "untracked root GEMINI.md does not block check" -- --check
git -C "$gemini_repo" add GEMINI.md
run 2 "tracked root GEMINI.md refuses check" -- --check
if grep -q 'GEMINI.md' "$TMP/err"; then ok "duplicate gate identifies GEMINI.md"
else bad "duplicate gate identifies GEMINI.md"; fi
mkdir -p "$TMP/failed-git"
printf '#!/bin/sh\nexit 128\n' > "$TMP/failed-git/git"
chmod +x "$TMP/failed-git/git"
PATH="$TMP/failed-git:$PATH" run 2 "check refuses when tracked-root inventory cannot be read" -- --check
GEN="$SAVED_GEN"

printf '' > "$TMP/empty-preamble.md"
head -c 23999 /dev/zero | tr '\0' 'x' > "$TMP/decimal-budget.md"
AGENTS_MD_SOURCE="$TMP/decimal-budget.md" AGENTS_MD_TARGET="$TMP/decimal-agents.md" \
  AGENTS_MD_PREAMBLE="$TMP/empty-preamble.md" AGENTS_MD_DEBRAND="$DEBRAND" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
if grep -q '24000 budget' "$TMP/err"; then ok "24002-byte output warns at the 24000-byte budget"
else bad "24002-byte output warns at the 24000-byte budget"; fi

# ---- 12. harness-neutral body, folder table, truthful header ----
# The REAL CLAUDE.md over an EMPTY preamble, so the preamble's own reading note
# (which names Claude Code on purpose) cannot trip the term check.
REAL_CLAUDE="$SCRIPT_DIR/../../CLAUDE.md"
BODY12="$TMP/AGENTS-body12.md"
AGENTS_MD_SOURCE="$REAL_CLAUDE" AGENTS_MD_TARGET="$BODY12" \
  AGENTS_MD_PREAMBLE="$TMP/empty-preamble.md" AGENTS_MD_DEBRAND="$DEBRAND" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
# Each term is a Claude-only tool, command, env name or model name an agent on
# another harness cannot act on. Facts ABOUT Claude (e.g. `claude -p` billing)
# are not instructions and stay.
for term in 'WebFetch' 'EDIT_ON_MAIN_OK=1 claude' 'CLAUDE_CODE_MAX_' 'haiku' 'Opus' \
            'himmel-ops:' "\`/lanes\`" "\`/handover\`"; do
  if grep -qF -- "$term" "$BODY12"; then bad "generated body holds the Claude-only term: $term"
  else ok "generated body is free of the Claude-only term: $term"; fi
done

AGENTS12="$TMP/AGENTS-real12.md"
AGENTS_MD_SOURCE="$REAL_CLAUDE" AGENTS_MD_TARGET="$AGENTS12" \
  AGENTS_MD_PREAMBLE="$PREAMBLE" AGENTS_MD_DEBRAND="$DEBRAND" \
  node "$GEN" --write >"$TMP/out" 2>"$TMP/err"
# The folder table must name every nested rule file git tracks.
missing12=""
while IFS= read -r rf; do
  [ -n "$rf" ] || continue
  grep -qF -- "$rf" "$AGENTS12" || missing12="$missing12 $rf"
done <<EOF
$(git -C "$SCRIPT_DIR/../.." ls-files | grep -E '(^|/)_?CLAUDE\.md$' | grep -v '^CLAUDE\.md$')
EOF
if [ -z "$missing12" ]; then ok "folder table names every nested rule file"
else bad "folder table names every nested rule file; missing:$missing12"; fi

# The title names only harnesses that load AGENTS.md on a fresh clone: Gemini CLI
# reads GEMINI.md, so a bare Gemini is a false claim; Antigravity is the Gemini surface.
title12="$(grep -m1 '^# AGENTS.md' "$AGENTS12")"
case "$title12" in *Antigravity*) ok "title names Antigravity";; *) bad "title names Antigravity: $title12";; esac
if grep -qE '(^|[^(])Gemini' <<< "$title12"; then bad "title names a bare Gemini: $title12"
else ok "title never names Gemini CLI as a reader"; fi

# ---- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
