#!/usr/bin/env bash
# billed-exempt: API-lane launcher call; refuses unless HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT is A|B|auto, and the API-credit ledger meters it
# crystallize-note.sh — upgrade a mechanical session note into an LLM synthesis.
# Reads the session transcript + the just-written note and asks a
# bounded `claude` run to rewrite the four body sections (Summary / Decisions /
# Files Touched / Follow-ups), preserving frontmatter identity and setting
# `crystallized: true`. Billed to the API, never the subscription: the one launch
# path is scripts/api-lane/claude-api.sh (one print-mode call, tools limited to
# Read,Edit, a per-call budget). It needs HIMMEL_API_LANE=on and
# HIMMEL_API_ACCOUNT=A|B|auto in the launching shell and fails closed (exit 2)
# without them: there is no claude-cli fallback.
#
# Usage: crystallize-note.sh <note_path> <transcript_path>
#
# Model: CRYSTALLIZE_MODEL (the hook exports it from .claude/end-session-wiki.json),
# else DEFAULT_MODEL below, which that config value must equal.
# CRYSTALLIZE_MAX_BUDGET_USD bounds each call.
#
# Best-effort once launched: any unavailability after the lane gate (over the
# concurrency cap, note not yet on disk, a lane refusal such as no credit) ->
# exit 0, leaving the mechanical note (`crystallized: false`). The reheal sweep
# (`backfill-sessions.sh --reheal`) recovers anything a backgrounded run missed.
#
# Test seam: CRYSTALLIZE_CLAUDE_BIN overrides the lane launcher with a stub so
# the suite stays hermetic. CRYSTALLIZE_PID_DIR / CRYSTALLIZE_MAX_CONCURRENCY
# tune the concurrency cap. bash 3.2-safe.
set -uo pipefail

NOTE_PATH="${1:-}"
TRANSCRIPT_PATH="${2:-}"
# Optional operator rules/context file: 3rd positional arg, overridden by env
# CRYSTALLIZE_RULES_FILE (env wins — same precedence as CRYSTALLIZE_MODEL). When
# set and readable its content is appended to the crystallizer prompt; an
# unreadable / missing file appends nothing (fail-open, matches the contract).
RULES_FILE="${CRYSTALLIZE_RULES_FILE:-${3:-}}"
[ -n "$NOTE_PATH" ] || exit 0

# Recursion guards: the throwaway claude session we spawn must not itself re-fire
# the session-end hooks. CLAUDE_END_SESSION_WIKI=0 silences end-session-wiki;
# HIMMEL_WHERE_ARE_WE=0 silences the where-are-we session-end refresh
# (refresh-where-are-we-on-end.sh) so a crystallizer subsession does
# not kick off a synchronous jira/gh/git ledger refresh.
export CLAUDE_END_SESSION_WIKI=0
export HIMMEL_WHERE_ARE_WE=0

HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
DEFAULT_MODEL="claude-opus-4-8"
DEFAULT_BUDGET_USD="1.00"

# API lane only: a refusal leaves the mechanical note untouched and never falls
# back to the subscription. The test override replaces the launcher, not the gate.
{ [ "${HIMMEL_API_LANE:-}" = "on" ] && case "${HIMMEL_API_ACCOUNT:-}" in A|B|auto) true ;; *) false ;; esac; } \
    || { echo "crystallize-note: refusing claude-api: the API lane is off (HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT=A|B|auto are required) -- note untouched, no claude-cli fallback" >&2; exit 2; }
# shellcheck source=../lib/prim.sh
. "$HIMMEL_ROOT/scripts/lib/prim.sh" || exit 0
LAUNCHER="${CRYSTALLIZE_CLAUDE_BIN:-$HIMMEL_ROOT/scripts/api-lane/claude-api.sh}"
[ -r "$LAUNCHER" ] \
    || { echo "crystallize-note: refusing claude-api: $LAUNCHER is missing -- note untouched" >&2; exit 2; }

# Concurrency cap — never pile up N full claude processes for N simultaneous
# session-ends. Best-effort pidfile counting; stale entries are pruned.
MAX="${CRYSTALLIZE_MAX_CONCURRENCY:-2}"
PID_DIR="${CRYSTALLIZE_PID_DIR:-${TMPDIR:-/tmp}/himmel-crystallize}"
mkdir -p "$PID_DIR" 2>/dev/null || true
live=0
for pf in "$PID_DIR"/*.pid; do
    [ -e "$pf" ] || continue
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        live=$((live + 1))
    else
        rm -f "$pf" 2>/dev/null || true
    fi
done
[ "$live" -ge "$MAX" ] && exit 0
MY_PID="$PID_DIR/$$.pid"
printf '%s' "$$" > "$MY_PID" 2>/dev/null || true
# SNAP_TMP is the refresh-mode pre-run snapshot, cleaned up here so it never
# leaks even on early exit.
SNAP_TMP=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
_cleanup() {
    rm -f "$MY_PID" 2>/dev/null || true
    if [ -n "$SNAP_TMP" ]; then rm -f "$SNAP_TMP" 2>/dev/null || true; fi
}
trap _cleanup EXIT

# Retry-read: the live hook may have just written the note via the Obsidian REST
# API, which flushes to disk asynchronously.
i=0
while [ ! -r "$NOTE_PATH" ] && [ "$i" -lt 3 ]; do
    sleep 1
    i=$((i + 1))
done
[ -r "$NOTE_PATH" ] || exit 0

# Already crystallized -> nothing to do, UNLESS refresh (re-consolidation) mode
# (CRYSTALLIZE_REFRESH=1) deliberately re-runs an already-synthesized note.
if [ "${CRYSTALLIZE_REFRESH:-}" != "1" ]; then
    grep -q '^crystallized: true$' "$NOTE_PATH" 2>/dev/null && exit 0
else
    # Loss-proofing (refresh only): a refresh rewrites PREVIOUSLY-GOOD synthesis,
    # so a partial/failed claude edit (quota kill, permission-EOF) must never be
    # accepted as a "refresh". Snapshot the note pre-run; the result is validated
    # structurally below and restored from this snapshot if it fails. Can't
    # snapshot -> can't roll back -> don't run (fail-open, note untouched).
    SNAP_TMP="${NOTE_PATH}.snap.$$"
    if ! cp "$NOTE_PATH" "$SNAP_TMP" 2>/dev/null; then
        SNAP_TMP=""
        exit 0
    fi
fi

# Structural validity of a refreshed note: frontmatter intact (first line is
# `---` and a second `---` delimiter exists), all four body section headers
# present, and the Raw Conversation callout the renderer emits
# (scripts/lib/session-note.sh) still there. Refresh-mode only.
# shellcheck disable=SC2317,SC2329  # invoked only on the refresh path
_refresh_valid() { # <note>
    [ "$(head -n 1 "$1" 2>/dev/null)" = "---" ] || return 1
    [ "$(grep -c '^---$' "$1" 2>/dev/null)" -ge 2 ] || return 1
    grep -q '^## Summary$' "$1" 2>/dev/null || return 1
    grep -q '^## Decisions$' "$1" 2>/dev/null || return 1
    grep -q '^## Files Touched$' "$1" 2>/dev/null || return 1
    grep -q '^## Follow-ups$' "$1" 2>/dev/null || return 1
    grep -qF '> [!note]- Raw conversation' "$1" 2>/dev/null || return 1
    return 0
}

# The note lives in the luna vault, OUTSIDE the himmel repo. The original
# crystallizer ran `claude` in HIMMEL_ROOT, but `--permission-mode acceptEdits`
# only auto-approves edits to files INSIDE the spawned run's workspace — so the
# out-of-workspace note Edit fell through to a permission prompt, `</dev/null`
# EOFed it, and the note was left BYTE-UNCHANGED with `crystallized: false`
# (confirmed by capturing the spawned run's stdout: "each write to
# the note is waiting on your permission grant"). The stub-based suite masked it
# because the stub edits the note directly.
#
# Fix: put the note's directory in the workspace by running `claude` with
# cwd = the note's directory (Edit is also pre-granted on the lane). The LLM rewrites only the four body sections;
# the `crystallized` flag is owned DETERMINISTICALLY by this script, set only
# when the note body actually changed (T1d) — so a no-op never falsely flags and
# a real synthesis always does, regardless of what the model touched.
if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ]; then
    # Refresh (re-consolidation): the note was already synthesized. CONSOLIDATE —
    # update/extend the four sections, preserving prior synthesis still correct.
    PROMPT="You are re-consolidating an already-synthesized Claude Code session note for an Obsidian vault.
Read the session transcript at: ${TRANSCRIPT_PATH}
Read the note at: ${NOTE_PATH}
This note was already synthesized. Re-read the transcript and the existing sections;
UPDATE/EXTEND the four sections below, preserving prior synthesis content that is
still correct — do not discard it:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {\"id\": \"YYYY-MM-DD-<kebab-slug>\", \"claim\": \"<the lesson, 1-3 lines, self-contained>\", \"source\": {\"type\": \"session\", \"ref\": \"<this note's vault-relative path>#Lessons\"}, \"captured_at\": \"<UTC ISO-8601 now>\", \"captured_by\": \"end-session-wiki\", \"confidence\": \"<see below>\", \"scope\": [\"<see below>\"], \"status\": \"<see below>\"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time."
else
    PROMPT="You are crystallizing a Claude Code session note for an Obsidian vault.
Read the session transcript at: ${TRANSCRIPT_PATH}
Read the note at: ${NOTE_PATH}
Rewrite ONLY these sections of that note, in place, distilling the session:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {\"id\": \"YYYY-MM-DD-<kebab-slug>\", \"claim\": \"<the lesson, 1-3 lines, self-contained>\", \"source\": {\"type\": \"session\", \"ref\": \"<this note's vault-relative path>#Lessons\"}, \"captured_at\": \"<UTC ISO-8601 now>\", \"captured_by\": \"end-session-wiki\", \"confidence\": \"<see below>\", \"scope\": [\"<see below>\"], \"status\": \"<see below>\"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time."
fi

# Operator rules/context injection: when a readable rules file was supplied,
# append its content as a clearly delimited block. Unreadable / missing / empty
# -> append nothing (fail-open). Trim whitespace before the emptiness guard to
# ensure parity with PowerShell (Get-Content -Raw keeps trailing newline, but
# bash `$(cat)` strips it; both must skip on whitespace-only files).
if [ -n "$RULES_FILE" ] && [ -r "$RULES_FILE" ]; then
    _rules_content="$(cat "$RULES_FILE" 2>/dev/null)"
    # Trim whitespace (spaces, tabs, newlines) before the emptiness check
    _rules_trimmed="${_rules_content//[$'\t\r\n ']/}"
    if [ -n "$_rules_trimmed" ]; then
        PROMPT="$PROMPT

Additionally apply these operator rules when synthesizing:
--- begin operator rules ---
${_rules_content}
--- end operator rules ---"
    fi
fi

MODEL="${CRYSTALLIZE_MODEL:-$DEFAULT_MODEL}"
BUDGET_USD="${CRYSTALLIZE_MAX_BUDGET_USD:-$DEFAULT_BUDGET_USD}"
NOTE_DIR="$(cd "$(dirname "$NOTE_PATH")" 2>/dev/null && pwd)"

# Pre-hash: the edit-confirmed flag-set keys off whether the body actually moved.
_hash() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | awk '{print $1}'; }
HASH_BEFORE="$(_hash "$NOTE_PATH")"

# The lane removes the other credential sources itself and pins its own endpoint,
# so there is no native-auth pin here. It allows no --add-dir or --settings: the
# transcript is read through the granted Read tool, and Read,Edit are the only
# tools (hooks are off on the lane, so a Bash grant would be unguarded).
# Subshell function: its `exit 0` ends only the launch.
launch_api_lane() {
    cd "$NOTE_DIR" 2>/dev/null || exit 0
    CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
        HIMMEL_API_TOOLS=Read,Edit HIMMEL_API_KIND=bulk \
        bash "$LAUNCHER" -p "$PROMPT" --model "$MODEL" \
        --permission-mode acceptEdits --max-budget-usd "$BUDGET_USD" </dev/null >/dev/null
}
( launch_api_lane ) || true

# Edit-confirmed flag-set (T1d): only stamp crystallized:true when the note body
# actually changed. A failed/no-op run leaves the note byte-unchanged and the
# flag stays false; a real synthesis always flips it, with a deterministic UTC
# timestamp this script owns (CRYSTALLIZE_NOW overridable for hermetic tests).
HASH_AFTER="$(_hash "$NOTE_PATH")"
# Both hashes must be measurable (errs toward leaving the flag false when a hash
# can't be taken — never fabricates a crystallized:true) — matches the .ps1 twin.
if [ -n "$HASH_BEFORE" ] && [ -n "$HASH_AFTER" ] && [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    # Refresh loss-proofing: a changed-but-structurally-broken result (truncated
    # note, lost frontmatter/sections — the shape of a half-applied edit) is
    # ROLLED BACK to the pre-run snapshot and NOT re-stamped. The note ends
    # byte-identical to before, so a hash-based caller naturally counts a skip.
    # Non-refresh runs are untouched by this branch (no snapshot exists).
    if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ] && ! _refresh_valid "$NOTE_PATH"; then
        if [ -n "$SNAP_TMP" ] && [ -r "$SNAP_TMP" ]; then
            # prim-ok: rollback reuses the saved inode when no space remains for atomic_write's extra copy.
            mv -f "$SNAP_TMP" "$NOTE_PATH" 2>/dev/null || true
            SNAP_TMP=""
        fi
    else
        NOW="${CRYSTALLIZE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
        STAMP_TMP="${NOTE_PATH}.stamp.$$"
        if awk -v now="$NOW" '
            /^---$/ { fmc++; print; next }
            fmc==1 && /^crystallized: / { print "crystallized: true"; next }
            fmc==1 && /^crystallized_at:/ { print "crystallized_at: " now; next }
            { print }
        ' "$NOTE_PATH" > "$STAMP_TMP" 2>/dev/null; then
            atomic_write "$NOTE_PATH" < "$STAMP_TMP" 2>/dev/null || true
            rm -f "$STAMP_TMP" 2>/dev/null || true
        else
            rm -f "$STAMP_TMP" 2>/dev/null || true
        fi
    fi
fi

exit 0
