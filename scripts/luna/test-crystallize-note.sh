#!/usr/bin/env bash
# test-crystallize-note.sh — hermetic smoke tests for crystallize-note.sh.
# A `claude` stub (CRYSTALLIZE_CLAUDE_BIN) keeps the suite offline:
# no real model call, no network, no billing.
#
# Run: bash scripts/luna/test-crystallize-note.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRYS="$SCRIPT_DIR/crystallize-note.sh"
STUB="$SCRIPT_DIR/../hooks/testdata/bin/claude-stub.sh"
[ -r "$CRYS" ] || { echo "FAIL: crystallize-note.sh not found"; exit 1; }
[ -r "$STUB" ] || { echo "FAIL: claude-stub.sh not found"; exit 1; }
chmod +x "$STUB" 2>/dev/null || true

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

# The suite exercises the native ambient path by default even when invoked from
# a live lane worker; the dedicated lane-config case below sets the variable back.
unset CLAUDE_CONFIG_DIR

# The crystallizer fails closed without the API lane; the stub stands in for the
# lane launcher, so every case below runs with the lane switched on (the refusal
# cases unset it explicitly).
export HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=A
unset ANTHROPIC_API_KEY CRYSTALLIZE_MODEL

# A launcher wrapper that records the lane env the crystallizer hands over, then
# runs the claude stub; the stub itself is shared with other suites.
LANE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-lane.XXXXXX")" || exit 1
trap 'rm -rf "$LANE_DIR"' EXIT
LANE_STUB="$LANE_DIR/lane-stub.sh"
cat > "$LANE_STUB" <<EOF
#!/usr/bin/env bash
[ -n "\${CRYSTALLIZE_LANE_DUMP:-}" ] && printf 'HIMMEL_API_TOOLS=%s\nHIMMEL_API_KIND=%s\n' "\${HIMMEL_API_TOOLS-<unset>}" "\${HIMMEL_API_KIND-<unset>}" > "\$CRYSTALLIZE_LANE_DUMP"
exec "$STUB" "\$@"
EOF
chmod +x "$LANE_STUB"
# The subscription fallback is gated on usage-preflight.sh; the suite never runs the
# real one. This stub prints the verdict token named in PF_VERDICT (default PROCEED).
PF_STUB="$LANE_DIR/preflight-stub.sh"
# shellcheck disable=SC2016  # the stub body is written literally; it expands when the stub runs
printf '#!/usr/bin/env bash\necho "${PF_VERDICT:-PROCEED}"\n' > "$PF_STUB"
chmod +x "$PF_STUB"
export CRYSTALLIZE_PREFLIGHT_BIN="$PF_STUB"

write_note() {
    # $1 = path
    cat > "$1" <<'EOF'
---
date: 2026-06-20T08:00:00Z
type: session
repo: himmel
branch: feat/x
worktree: /tmp/x
duration_minutes: 5
files_touched: 0
tags:
  - session
  - autocapture
ai-first: true
session_id: sess-abc
source: live
crystallized: false
crystallized_at:
---

Auto-captured session.

## Summary

_Transcript unavailable; auto-summary not generated._ (speculation)

## Decisions

_None._

## Files Touched

_None._

## Commands

```bash
```

## Follow-ups

_None._

## Raw Conversation

> [!note]- Raw conversation
> _Transcript unavailable._
EOF
}

identity_lines() { grep -E '^(date|session_id|repo|branch|worktree|source):' "$1"; }

# Flip a crystallized:false note to crystallized:true with an OLD timestamp, in
# place (portable — no sed -i), so --refresh cases have an already-synthesized
# note to re-consolidate. Mirrors the backfill suite's helper of the same shape.
mark_crystallized() { # <note>
    awk '
        /^crystallized: false$/ { print "crystallized: true"; next }
        /^crystallized_at:$/ { print "crystallized_at: 2026-01-01T00:00:00Z"; next }
        { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# --- Case 0: a non-default CLAUDE_CONFIG_DIR no longer defers — the lane owns auth ---
SB="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-note.XXXXXX")" || exit 1
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; MARK="$SB/marker.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
mkdir -p "$SB/home/.claude" "$SB/lane-config"
STDERR_OUT="$SB/stderr.txt"
RC=0
env HOME="$SB/home" CLAUDE_CONFIG_DIR="$SB/lane-config" \
    CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success CRYSTALLIZE_MARKER="$MARK" \
    CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR" 2>"$STDERR_OUT" || RC=$?
if [ "$RC" = "0" ]; then pass "lane-config: exits 0"; else fail "lane-config: exit was $RC"; fi
if [ -s "$MARK" ]; then pass "lane-config: the launcher ran despite a non-default config dir"; else fail "lane-config: still deferring on CLAUDE_CONFIG_DIR"; fi
if grep -q '^crystallized: true$' "$NOTE"; then pass "lane-config: note crystallized"; else fail "lane-config: note not crystallized"; fi
if ! grep -q 'crystallize-note: DEFERRED' "$STDERR_OUT" 2>/dev/null; then pass "lane-config: no deferral line"; else fail "lane-config: emitted a deferral line"; fi
rm -rf "$SB"

# --- Case L1: no model env — the crystallizer passes the chosen model ------------
# The chosen model is the config's crystallize_model; the script's built-in default
# must agree with it, so the hook (config -> env) and a bare backfill run price alike.
CFG_MODEL="$(sed -n 's/.*"crystallize_model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPT_DIR/../../.claude/end-session-wiki.json")"
SB="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-model.XXXXXX")" || exit 1
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
env -u CRYSTALLIZE_MODEL CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" bash "$CRYS" "$NOTE" "$TR"
GOT_MODEL="$(awk '/^arg=/{if (prev=="arg=--model") print substr($0,5); prev=$0}' "$ARGVD" 2>/dev/null)"
if [ -n "$CFG_MODEL" ] && [ "$GOT_MODEL" = "$CFG_MODEL" ]; then pass "model: with no model env the crystallizer passes the config's chosen model ($GOT_MODEL)"; else fail "model: no-env model was '${GOT_MODEL:-<none>}', config says '${CFG_MODEL:-<none>}'"; fi
env CRYSTALLIZE_MODEL="env-switch-model" CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" CRYSTALLIZE_REFRESH=1 bash "$CRYS" "$NOTE" "$TR"
if grep -qxF 'arg=env-switch-model' "$ARGVD" 2>/dev/null; then pass "model: CRYSTALLIZE_MODEL still overrides the default"; else fail "model: CRYSTALLIZE_MODEL no longer reaches the launcher"; fi
rm -rf "$SB"

# --- Case L2: no API lane AND the usage preflight says stop — one skip line, never launch ---
lane_skip() { # <label> <verdict> <env-assignments...>
    local label="$1" verdict="$2"; shift 2
    local sb note tr mark err rc=0 before after
    sb="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-skip.XXXXXX")" || exit 1
    note="$sb/note.md"; tr="$sb/t.jsonl"; mark="$sb/marker.txt"; err="$sb/stderr.txt"
    write_note "$note"; printf '{}\n' > "$tr"
    before="$( { sha256sum "$note" 2>/dev/null || shasum -a 256 "$note"; } | awk '{print $1}')"
    env "$@" PF_VERDICT="$verdict" CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success CRYSTALLIZE_MARKER="$mark" \
        CRYSTALLIZE_PID_DIR="$sb/pids" bash "$CRYS" "$note" "$tr" 2>"$err" || rc=$?
    after="$( { sha256sum "$note" 2>/dev/null || shasum -a 256 "$note"; } | awk '{print $1}')"
    if [ "$rc" != "0" ]; then pass "$label: exits non-zero ($rc)"; else fail "$label: exited 0 although the preflight said $verdict"; fi
    if [ "$(grep -c '^crystallize-note: skipped' "$err" 2>/dev/null)" = "1" ] \
        && grep -q 'HIMMEL_API_LANE=on' "$err" && grep -q "$verdict" "$err"; then pass "$label: one skip line names the lane variables and the verdict"; else fail "$label: skip line missing or unclear"; fi
    if [ ! -s "$mark" ]; then pass "$label: the claude stub was never called (CRYSTALLIZE_CLAUDE_BIN does not bypass the gate)"; else fail "$label: claude launched past a $verdict verdict"; fi
    if [ "$before" = "$after" ] && grep -q '^crystallized: false$' "$note"; then pass "$label: mechanical note unchanged"; else fail "$label: note changed"; fi
    rm -rf "$sb"
}
lane_skip "lane-off+SKIPPED-BANK" SKIPPED-BANK -u HIMMEL_API_LANE
lane_skip "lane-no-account+SKIPPED-FLEET" SKIPPED-FLEET -u HIMMEL_API_ACCOUNT
lane_skip "lane-not-on+SKIPPED-BANK" SKIPPED-BANK HIMMEL_API_LANE=off
lane_skip "lane-bad-account+SKIPPED-FLEET" SKIPPED-FLEET HIMMEL_API_ACCOUNT=invalid

# --- Case L3: no API lane, preflight not stopping — the subscription fallback crystallizes ---
# PROCEED, BANK-STALE and BANK-UNKNOWN all run it (the last two are fail-open by the
# preflight's contract). The call is print-mode, json output, explicit permission mode.
lane_fallback() { # <label> <verdict> <env-assignments...>
    local label="$1" verdict="$2"; shift 2
    local sb note tr mark argvd rc=0
    sb="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-sub.XXXXXX")" || exit 1
    note="$sb/note.md"; tr="$sb/t.jsonl"; mark="$sb/marker.txt"; argvd="$sb/argv.txt"
    write_note "$note"; printf '{}\n' > "$tr"
    env "$@" PF_VERDICT="$verdict" CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success CRYSTALLIZE_MARKER="$mark" \
        CRYSTALLIZE_ARGV_DUMP="$argvd" CRYSTALLIZE_PID_DIR="$sb/pids" bash "$CRYS" "$note" "$tr" 2>/dev/null || rc=$?
    if [ "$rc" = "0" ]; then pass "$label: exits 0"; else fail "$label: exit was $rc"; fi
    if [ -s "$mark" ]; then pass "$label: the subscription claude ran"; else fail "$label: claude never ran"; fi
    if grep -q '^crystallized: true$' "$note"; then pass "$label: note crystallized"; else fail "$label: note not crystallized"; fi
    if grep -qxF 'arg=-p' "$argvd" 2>/dev/null && grep -qxF 'arg=--output-format' "$argvd" 2>/dev/null \
        && grep -qxF 'arg=json' "$argvd" 2>/dev/null && grep -qxF 'arg=--permission-mode' "$argvd" 2>/dev/null \
        && grep -qxF 'arg=acceptEdits' "$argvd" 2>/dev/null; then pass "$label: print mode, json output, explicit permission mode"; else fail "$label: argv shape wrong"; fi
    rm -rf "$sb"
}
lane_fallback "no-lane+PROCEED" PROCEED -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT
lane_fallback "no-lane+BANK-STALE" BANK-STALE -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT
lane_fallback "no-lane+BANK-UNKNOWN" BANK-UNKNOWN -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT
lane_fallback "bad-account+PROCEED" PROCEED HIMMEL_API_ACCOUNT=invalid

# --- Case L4: lane ON but its call changes nothing (no credit) — the subscription takes over ---
# NOCREDIT_STUB plays both launchers: called the lane way (no --output-format) it does
# nothing, like a lane refusal; called the subscription way it runs the claude stub.
NOCREDIT_STUB="$LANE_DIR/nocredit-stub.sh"
cat > "$NOCREDIT_STUB" <<EOF
#!/usr/bin/env bash
case " \$* " in *" --output-format "*) exec "$STUB" "\$@" ;; esac
exit 0
EOF
chmod +x "$NOCREDIT_STUB"
lane_nocredit() { # <label> <verdict>
    local label="$1" verdict="$2"
    local sb note tr err rc=0
    sb="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-nocredit.XXXXXX")" || exit 1
    note="$sb/note.md"; tr="$sb/t.jsonl"; err="$sb/stderr.txt"
    write_note "$note"; printf '{}\n' > "$tr"
    env PF_VERDICT="$verdict" CRYSTALLIZE_CLAUDE_BIN="$NOCREDIT_STUB" STUB_MODE=success \
        CRYSTALLIZE_PID_DIR="$sb/pids" bash "$CRYS" "$note" "$tr" 2>"$err" || rc=$?
    case "$verdict" in
        SKIPPED-*)
            if [ "$rc" != "0" ] && [ "$(grep -c '^crystallize-note: skipped' "$err" 2>/dev/null)" = "1" ] \
                && grep -q '^crystallized: false$' "$note"; then pass "$label: lane call changed nothing + $verdict -> one skip line, note untouched"; else fail "$label: expected one skip line and an untouched note (rc $rc)"; fi ;;
        *)
            if [ "$rc" = "0" ] && grep -q '^crystallized: true$' "$note"; then pass "$label: lane call changed nothing + $verdict -> the subscription crystallized the note"; else fail "$label: subscription did not take over (rc $rc)"; fi ;;
    esac
    rm -rf "$sb"
}
lane_nocredit "lane-nocredit" PROCEED
lane_nocredit "lane-nocredit" BANK-STALE
lane_nocredit "lane-nocredit" SKIPPED-BANK

# A pinned proxy variable must not ride into the subscription run: the run is skipped, not proxied.
SB="$(mktemp -d "${TMPDIR:-/tmp}/crystallize-pin.XXXXXX")" || exit 1
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; MARK="$SB/marker.txt"; ENVD="$SB/env.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
env -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT ANTHROPIC_BASE_URL="http://127.0.0.1:9" PF_VERDICT=PROCEED \
    CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_ENV_DUMP="$ENVD" \
    CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR" 2>/dev/null
if grep -qxF 'ANTHROPIC_BASE_URL=<unset>' "$ENVD" 2>/dev/null; then pass "subscription: ambient ANTHROPIC_BASE_URL is cleared before the launch"; else fail "subscription: ambient proxy variable reached claude"; fi
rm -rf "$SB"

# --- Case 1: success — sections filled, crystallized true, identity preserved --
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
ID_BEFORE="$(identity_lines "$NOTE")"
ENVD="$SB/env.txt"
# CRYSTALLIZE_NOW pins the stamp time so the assertion below is deterministic
# (the script — not the stub — now owns the flag + timestamp).
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ENV_DUMP="$ENVD" \
    CRYSTALLIZE_NOW="2026-06-28T12:00:00Z" \
    bash "$CRYS" "$NOTE" "$TR"
if grep -q '^crystallized: true$' "$NOTE"; then pass "success: crystallized: true set (by script, from body diff)"; else fail "success: crystallized not flipped"; fi
if grep -q '_Crystallized by stub' "$NOTE"; then pass "success: Summary section rewritten"; else fail "success: Summary not rewritten"; fi
if grep -q '^crystallized_at: 2026-06-28T12:00:00Z$' "$NOTE"; then pass "success: crystallized_at set"; else fail "success: crystallized_at not set"; fi
if [ "$ID_BEFORE" = "$(identity_lines "$NOTE")" ]; then pass "success: identity frontmatter byte-stable"; else fail "success: identity frontmatter changed"; fi
if grep -q '^CLAUDE_END_SESSION_WIKI=0$' "$ENVD" 2>/dev/null; then pass "recursion-guard: CLAUDE_END_SESSION_WIKI=0 exported to claude"; else fail "recursion-guard: end-session-wiki env not set"; fi
if grep -q '^HIMMEL_WHERE_ARE_WE=0$' "$ENVD" 2>/dev/null; then pass "recursion-guard: HIMMEL_WHERE_ARE_WE=0 exported (HIMMEL-572 fold-in)"; else fail "recursion-guard: where-are-we env not set"; fi
rm -rf "$SB"

# --- Case 2: fail — note unchanged, crystallized stays false -----------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=fail CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "fail: note byte-unchanged"; else fail "fail: note was modified on claude failure"; fi
if grep -q '^crystallized: false$' "$NOTE"; then pass "fail: crystallized stays false"; else fail "fail: crystallized wrongly changed"; fi
rm -rf "$SB"

# --- Case 3: noop — note unchanged -------------------------------------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=noop CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "noop: note byte-unchanged"; else fail "noop: note modified on no-op"; fi
rm -rf "$SB"

# --- Case 5: concurrency cap — over cap, no spawn (T2.7) ----------------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; PIDS="$SB/pids"; MARK="$SB/marker.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"; mkdir -p "$PIDS"
# Seed >= MAX (2) live pidfiles using THIS test's own pid (kill -0 succeeds).
printf '%s' "$$" > "$PIDS/a.pid"; printf '%s' "$$" > "$PIDS/b.pid"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$PIDS" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_MAX_CONCURRENCY=2 \
    bash "$CRYS" "$NOTE" "$TR"
if [ ! -s "$MARK" ]; then pass "cap: no claude spawned when at/over cap"; else fail "cap: claude spawned despite cap"; fi
if grep -q '^crystallized: false$' "$NOTE"; then pass "cap: note stays crystallized: false"; else fail "cap: note wrongly crystallized"; fi
rm -rf "$SB"

# --- Case 6: detach survival — child outlives a process-group kill (T2.5) -----
# The `slow` stub sleeps 1s BEFORE touching its marker. We launch the crystallizer
# detached (setsid / double-fork) inside a subshell, kill that subshell's process
# group well within the 1s window, then wait past it: a surviving (truly detached)
# child still writes the marker; a child that died with the group does not.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; MARK="$SB/marker.txt"; PIDS="$SB/pids"
write_note "$NOTE"; printf '{}\n' > "$TR"
(
    if command -v setsid >/dev/null 2>&1; then
        env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=slow CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$PIDS" \
            setsid bash "$CRYS" "$NOTE" "$TR" </dev/null >/dev/null 2>&1 &
    else
        ( env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=slow CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$PIDS" \
            bash "$CRYS" "$NOTE" "$TR" </dev/null >/dev/null 2>&1 & )
    fi
) &
subpid=$!
sleep 0.3
# Kill the launching subshell's process group (negative pid) — within the slow
# stub's 1s pre-marker window.
kill -- "-${subpid}" 2>/dev/null || kill "$subpid" 2>/dev/null || true
if [ -s "$MARK" ]; then fail "detach: marker already present before window (test invalid)"; fi
i=0; while [ ! -s "$MARK" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$MARK" ]; then pass "detach: crystallizer survived the process-group kill"; else fail "detach: child died with the hook's process group"; fi
rm -rf "$SB"

# --- Case 7: workspace guard — the spawn puts the note-dir in the workspace -----
# The real-claude no-op was an OUT-OF-WORKSPACE edit (cwd=himmel,
# note in vault) that acceptEdits could not auto-approve. This hermetic guard
# asserts the fix shape directly from the spawned argv/cwd dump: the run's cwd is
# the note's directory, and the launch is the API lane's: the lane allows no
# --add-dir or --settings, so the transcript is read through the granted Read tool
# and the only tools are Read and Edit, a bounded budget, an explicit permission mode.
SB="$(mktemp -d)"
mkdir -p "$SB/vault/sessions" "$SB/proj"
NOTE="$SB/vault/sessions/note.md"; TR="$SB/proj/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
ARGVD="$SB/argv.txt"; LANED="$SB/lane.txt"
env CRYSTALLIZE_CLAUDE_BIN="$LANE_STUB" STUB_MODE=success CRYSTALLIZE_LANE_DUMP="$LANED" \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    bash "$CRYS" "$NOTE" "$TR"
NOTE_DIR_REAL="$(cd "$(dirname "$NOTE")" && pwd)"
if grep -qF "cwd=$NOTE_DIR_REAL" "$ARGVD" 2>/dev/null; then pass "workspace: spawn cwd is the note's directory"; else fail "workspace: spawn cwd is NOT the note-dir (out-of-workspace edit risk)"; fi
if grep -qxF 'arg=-p' "$ARGVD" 2>/dev/null; then pass "lane: print-mode call (-p)"; else fail "lane: not a -p call"; fi
if ! grep -qxF 'arg=--add-dir' "$ARGVD" 2>/dev/null && ! grep -qxF 'arg=--settings' "$ARGVD" 2>/dev/null; then pass "lane: no --add-dir / --settings (the lane refuses both)"; else fail "lane: passes a flag the lane refuses"; fi
if grep -qxF 'HIMMEL_API_TOOLS=Read,Edit' "$LANED" 2>/dev/null; then pass "lane: tool grant is exactly Read,Edit"; else fail "lane: tool grant is not Read,Edit ($(cat "$LANED" 2>/dev/null))"; fi # read-sink-ok: LANED is the suite's own temp dump
if grep -qxF 'HIMMEL_API_KIND=bulk' "$LANED" 2>/dev/null; then pass "lane: run kind is bulk"; else fail "lane: run kind is not bulk"; fi
BUDGET="$(awk '/^arg=/{if (prev=="arg=--max-budget-usd") print substr($0,5); prev=$0}' "$ARGVD")"
if grep -Eq '^[0-9]+(\.[0-9]+)?$' <<< "$BUDGET"; then pass "lane: bounded --max-budget-usd ($BUDGET)"; else fail "lane: no numeric --max-budget-usd"; fi
# acceptEdits must survive — it's what auto-approves the in-workspace note edit.
if grep -qxF 'arg=acceptEdits' "$ARGVD" 2>/dev/null; then pass "workspace: --permission-mode acceptEdits passed"; else fail "workspace: acceptEdits not passed (out-of-workspace edit would prompt)"; fi
rm -rf "$SB"

# --- Case 8: edit-confirmed flag — no body change => crystallized stays false ---
# T1d: the script owns the flag from the body diff. A noop run (claude wrote
# nothing) must leave crystallized:false; a real body change must flip it (Case 1).
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=noop CRYSTALLIZE_PID_DIR="$SB/pids" \
    CRYSTALLIZE_NOW="2026-06-28T12:00:00Z" bash "$CRYS" "$NOTE" "$TR"
if grep -q '^crystallized: false$' "$NOTE"; then pass "edit-confirmed: noop leaves crystallized: false"; else fail "edit-confirmed: noop wrongly flagged crystallized"; fi
if grep -q '^crystallized_at:$' "$NOTE"; then pass "edit-confirmed: noop leaves crystallized_at empty"; else fail "edit-confirmed: noop wrongly stamped crystallized_at"; fi
rm -rf "$SB"

# --- Case R1: rules injection — rules file content reaches the claude prompt ---
# The stub records the spawn's argv (incl. the prompt) to CRYSTALLIZE_ARGV_DUMP;
# the prompt is one argv entry, so the rules content appears verbatim there.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; RULES="$SB/rules.txt"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
printf 'PREFER_ACTIVE_VOICE_MARKER\n' > "$RULES"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    CRYSTALLIZE_RULES_FILE="$RULES" bash "$CRYS" "$NOTE" "$TR"
if grep -qF 'PREFER_ACTIVE_VOICE_MARKER' "$ARGVD" 2>/dev/null; then pass "rules: rules content reaches the claude prompt"; else fail "rules: rules content not in prompt"; fi
if grep -qF 'begin operator rules' "$ARGVD" 2>/dev/null; then pass "rules: delimited operator-rules block present"; else fail "rules: no operator-rules delimiter"; fi
# Lesson-provenance prompt pin: a heredoc-escaping break must not
# silently drop the ## Lessons instruction block from the spawned prompt.
if grep -qF '## Lessons' "$ARGVD" 2>/dev/null; then pass "lessons: ## Lessons instruction present in prompt"; else fail "lessons: ## Lessons instruction missing from prompt"; fi
if grep -qF 'validate-lesson.mjs --capture' "$ARGVD" 2>/dev/null; then pass "lessons: validate-lesson.mjs --capture pointer present in prompt"; else fail "lessons: validator pointer missing from prompt"; fi
rm -rf "$SB"

# --- Case R2: missing/unreadable rules file — run proceeds, no rules block ------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    CRYSTALLIZE_RULES_FILE="$SB/does-not-exist.txt" bash "$CRYS" "$NOTE" "$TR"
if grep -q '^crystallized: true$' "$NOTE"; then pass "rules(missing): run still proceeds (fail-open)"; else fail "rules(missing): run did not proceed"; fi
if ! grep -qF 'begin operator rules' "$ARGVD" 2>/dev/null; then pass "rules(missing): no rules block in prompt"; else fail "rules(missing): rules block wrongly present"; fi
rm -rf "$SB"

# --- Case R3: env CRYSTALLIZE_RULES_FILE beats the 3rd positional arg -----------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; ARGVD="$SB/argv.txt"
RULES_ENV="$SB/env-rules.txt"; RULES_POS="$SB/pos-rules.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
printf 'ENV_RULES_MARKER\n' > "$RULES_ENV"
printf 'POSITIONAL_RULES_MARKER\n' > "$RULES_POS"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    CRYSTALLIZE_RULES_FILE="$RULES_ENV" bash "$CRYS" "$NOTE" "$TR" "$RULES_POS"
if grep -qF 'ENV_RULES_MARKER' "$ARGVD" 2>/dev/null; then pass "rules(precedence): env CRYSTALLIZE_RULES_FILE used"; else fail "rules(precedence): env rules not used"; fi
if ! grep -qF 'POSITIONAL_RULES_MARKER' "$ARGVD" 2>/dev/null; then pass "rules(precedence): positional arg ignored when env set"; else fail "rules(precedence): positional wrongly used over env"; fi
rm -rf "$SB"

# --- Case R4: refresh bypasses crystallized:true and re-stamps on a real change -
# An already-crystallized note (crystallized:true + an OLD crystallized_at) would
# early-exit without refresh; with CRYSTALLIZE_REFRESH=1 + a real body change
# (stub rewrites Summary) it must stay true and re-stamp crystallized_at.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
mark_crystallized "$NOTE"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success CRYSTALLIZE_REFRESH=1 \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T09:00:00Z" \
    bash "$CRYS" "$NOTE" "$TR"
if grep -q '^crystallized: true$' "$NOTE"; then pass "refresh: crystallized stays true"; else fail "refresh: crystallized flag lost"; fi
if grep -q '_Crystallized by stub' "$NOTE"; then pass "refresh: Summary re-consolidated (bypassed early-exit)"; else fail "refresh: Summary not updated (early-exit not bypassed?)"; fi
if grep -q '^crystallized_at: 2026-06-30T09:00:00Z$' "$NOTE"; then pass "refresh: crystallized_at re-stamped on a real change"; else fail "refresh: crystallized_at not re-stamped"; fi
rm -rf "$SB"

# --- Case R5: no-op refresh leaves the note byte-identical, no re-stamp ---------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
mark_crystallized "$NOTE"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=noop CRYSTALLIZE_REFRESH=1 \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T09:00:00Z" \
    bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "refresh(noop): note byte-identical"; else fail "refresh(noop): note modified on no-op refresh"; fi
if grep -q '^crystallized_at: 2026-01-01T00:00:00Z$' "$NOTE"; then pass "refresh(noop): crystallized_at NOT re-stamped"; else fail "refresh(noop): crystallized_at wrongly changed"; fi
rm -rf "$SB"

# --- Case R6: corrupting refresh — result rolled back, nothing re-stamped -------
# A half-applied edit (quota kill / permission-EOF: the `corrupt` stub truncates
# the note, losing frontmatter + sections) changes the hash, but the refresh
# validator must REJECT it: restore the pre-run snapshot (byte-identical note),
# keep the OLD crystallized_at, and leave no snapshot temp file behind.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
mark_crystallized "$NOTE"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=corrupt CRYSTALLIZE_REFRESH=1 \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T09:00:00Z" \
    bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "refresh(corrupt): note restored byte-identical"; else fail "refresh(corrupt): corrupted result was ACCEPTED (prior synthesis lost)"; fi
if grep -q '^crystallized_at: 2026-01-01T00:00:00Z$' "$NOTE"; then pass "refresh(corrupt): crystallized_at NOT re-stamped"; else fail "refresh(corrupt): crystallized_at wrongly re-stamped"; fi
if grep -q '^crystallized: true$' "$NOTE"; then pass "refresh(corrupt): crystallized still true after rollback"; else fail "refresh(corrupt): crystallized flag lost in rollback"; fi
if [ -z "$(find "$SB" -name '*.snap.*' 2>/dev/null)" ]; then pass "refresh(corrupt): no snapshot temp left behind"; else fail "refresh(corrupt): snapshot temp leaked"; fi
rm -rf "$SB"

# --- Case R7: 3rd positional rules arg ALONE (env unset) reaches the prompt -----
# R3 proves env beats positional; this proves the positional fallback works on its
# own when CRYSTALLIZE_RULES_FILE is unset.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; RULES="$SB/pos-only-rules.txt"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
printf 'POSITIONAL_ONLY_RULES_MARKER\n' > "$RULES"
env -u CRYSTALLIZE_RULES_FILE CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    bash "$CRYS" "$NOTE" "$TR" "$RULES"
if grep -qF 'POSITIONAL_ONLY_RULES_MARKER' "$ARGVD" 2>/dev/null; then pass "rules(positional): 3rd positional rules arg reaches the prompt"; else fail "rules(positional): positional rules not in prompt"; fi
if grep -qF 'begin operator rules' "$ARGVD" 2>/dev/null; then pass "rules(positional): delimited operator-rules block present"; else fail "rules(positional): no operator-rules delimiter"; fi
rm -rf "$SB"

# --- Case R8: existing but EMPTY rules file — no rules block, run still proceeds -
# The empty-content guard ([ -n "$_rules_content" ]) must skip the block for a
# zero-byte rules file while the crystallize run itself proceeds normally.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; RULES="$SB/empty-rules.txt"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
: > "$RULES"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    CRYSTALLIZE_RULES_FILE="$RULES" bash "$CRYS" "$NOTE" "$TR"
if ! grep -qF 'begin operator rules' "$ARGVD" 2>/dev/null; then pass "rules(empty): no operator-rules block for a zero-byte rules file"; else fail "rules(empty): rules block wrongly present for empty file"; fi
if grep -q '^crystallized: true$' "$NOTE"; then pass "rules(empty): run still proceeds normally"; else fail "rules(empty): run did not proceed"; fi
rm -rf "$SB"

# --- Case R9: whitespace-only rules file — parity test (bash vs ps1 divergence) --
# bash `$(cat file)` strips trailing newline; PS `Get-Content -Raw`
# keeps it. A file with ONLY a newline must NOT append a rules block in BOTH.
# This tests the trimmed check for parity.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; RULES="$SB/ws-only-rules.txt"; ARGVD="$SB/argv.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"
printf '\n' > "$RULES"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD" \
    CRYSTALLIZE_RULES_FILE="$RULES" bash "$CRYS" "$NOTE" "$TR"
if ! grep -qF 'begin operator rules' "$ARGVD" 2>/dev/null; then pass "rules(ws-only): no operator-rules block for whitespace-only file (parity with ps1)"; else fail "rules(ws-only): rules block wrongly present for whitespace-only file"; fi
if grep -q '^crystallized: true$' "$NOTE"; then pass "rules(ws-only): run still proceeds normally"; else fail "rules(ws-only): run did not proceed"; fi
rm -rf "$SB"

# --- Case 9: real-claude smoke (OPT-IN: CRYSTALLIZE_REAL_CLAUDE=1) --------------
# The whole point is that the STUB hides the real-claude no-op.
# This case runs the genuine `claude` across the himmel-cwd -> vault-note boundary
# and proves a real edit lands + the flag flips. Skipped by default (billing /
# no claude in CI); run manually with CRYSTALLIZE_REAL_CLAUDE=1.
if [ "${CRYSTALLIZE_REAL_CLAUDE:-0}" = "1" ] && command -v claude >/dev/null 2>&1; then
    SB="$(mktemp -d)"
    mkdir -p "$SB/vault/sessions" "$SB/proj"
    NOTE="$SB/vault/sessions/note.md"; TR="$SB/proj/t.jsonl"
    write_note "$NOTE"
    # A minimal but content-bearing transcript so the model has something to distil.
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Fix the parser bug in foo.c"},"timestamp":"2026-06-20T08:00:00Z"}' > "$TR"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed the off-by-one in the parser and added a regression test."}]},"timestamp":"2026-06-20T08:05:00Z"}' >> "$TR"
    SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
    env -u CRYSTALLIZE_CLAUDE_BIN CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR"
    SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
    if [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then pass "real-claude: note body changed (edit landed across the cwd->vault boundary)"; else fail "real-claude: note byte-unchanged (the F1 no-op is back)"; fi
    if grep -q '^crystallized: true$' "$NOTE"; then pass "real-claude: crystallized: true set"; else fail "real-claude: crystallized not flipped"; fi
    rm -rf "$SB"
else
    echo "SKIP: real-claude smoke (set CRYSTALLIZE_REAL_CLAUDE=1 with claude installed to run)"
fi

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
