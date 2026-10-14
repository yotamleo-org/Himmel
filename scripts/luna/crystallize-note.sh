#!/usr/bin/env bash
# Usage: crystallize-note.sh <note_path> <transcript_path>
set -uo pipefail

NOTE_PATH="${1:-}"
TRANSCRIPT_PATH="${2:-}"
RULES_FILE="${CRYSTALLIZE_RULES_FILE:-${3:-}}"
[ -n "$NOTE_PATH" ] || exit 0

export CLAUDE_END_SESSION_WIKI=0
export HIMMEL_WHERE_ARE_WE=0

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _configured_claude_dir="$(cd "$CLAUDE_CONFIG_DIR" 2>/dev/null && pwd -P)" || exit 0
    _native_claude_dir="$(cd "${HOME}/.claude" 2>/dev/null && pwd -P)" || exit 0
    if [ "$_configured_claude_dir" != "$_native_claude_dir" ]; then
        echo "crystallize-note: DEFERRED (not failed) - CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR is not ~/.claude; the mechanical note is still written and stays crystallized: false; backfill-sessions.sh --reheal picks it up later once running on native auth." >&2
        exit 0
    fi
fi

CLAUDE_BIN="${CRYSTALLIZE_CLAUDE_BIN:-}"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -n "$CLAUDE_BIN" ] || exit 0

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
SETTINGS_TMP=""
SNAP_TMP=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
_cleanup() {
    rm -f "$MY_PID" 2>/dev/null || true
    if [ -n "$SETTINGS_TMP" ]; then rm -f "$SETTINGS_TMP" 2>/dev/null || true; fi
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

if [ "${CRYSTALLIZE_REFRESH:-}" != "1" ]; then
    grep -q '^crystallized: true$' "$NOTE_PATH" 2>/dev/null && exit 0
else
    SNAP_TMP="${NOTE_PATH}.snap.$$"
    if ! cp "$NOTE_PATH" "$SNAP_TMP" 2>/dev/null; then
        SNAP_TMP=""
        exit 0
    fi
fi

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
if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ]; then
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

if [ -n "$RULES_FILE" ] && [ -r "$RULES_FILE" ]; then
    _rules_content="$(cat "$RULES_FILE" 2>/dev/null)"
    _rules_trimmed="${_rules_content//[$'\t\r\n ']/}"
    if [ -n "$_rules_trimmed" ]; then
        PROMPT="$PROMPT

Additionally apply these operator rules when synthesizing:
--- begin operator rules ---
${_rules_content}
--- end operator rules ---"
    fi
fi

HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
AUTO_APPROVE_HOOK="$HIMMEL_ROOT/scripts/hooks/auto-approve-safe-bash.sh"

SETTINGS_TMP="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/crys-settings-$$.json")"
cat > "$SETTINGS_TMP" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash ${AUTO_APPROVE_HOOK}" }
        ]
      }
    ]
  }
}
JSON

# Optional model pin + transcript --add-dir. bash 3.2-safe empty-array guard.
EXTRA_ARGS=()
[ -n "${CRYSTALLIZE_MODEL:-}" ] && EXTRA_ARGS=(--model "$CRYSTALLIZE_MODEL")
NOTE_DIR="$(cd "$(dirname "$NOTE_PATH")" 2>/dev/null && pwd)"
TR_DIR=""
[ -n "$TRANSCRIPT_PATH" ] && TR_DIR="$(cd "$(dirname "$TRANSCRIPT_PATH")" 2>/dev/null && pwd)"
[ -n "$TR_DIR" ] && EXTRA_ARGS=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --add-dir "$TR_DIR")

_hash() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | awk '{print $1}'; }
HASH_BEFORE="$(_hash "$NOTE_PATH")"

# shellcheck source=scripts/lib/native-auth-pin.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/native-auth-pin.sh" || exit 0
native_auth_pin_env
(
    cd "$NOTE_DIR" 2>/dev/null || exit 0
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
        CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
            "$CLAUDE_BIN" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
            --settings "$SETTINGS_TMP" \
            --permission-mode acceptEdits "$PROMPT" </dev/null >/dev/null 2>&1
    else
        exit 0
    fi
) || true

HASH_AFTER="$(_hash "$NOTE_PATH")"
if [ -n "$HASH_BEFORE" ] && [ -n "$HASH_AFTER" ] && [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ] && ! _refresh_valid "$NOTE_PATH"; then
        if [ -n "$SNAP_TMP" ] && [ -r "$SNAP_TMP" ]; then
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
            mv -f "$STAMP_TMP" "$NOTE_PATH" 2>/dev/null || rm -f "$STAMP_TMP" 2>/dev/null || true
        else
            rm -f "$STAMP_TMP" 2>/dev/null || true
        fi
    fi
fi

exit 0
