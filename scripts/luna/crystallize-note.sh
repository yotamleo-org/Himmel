#!/usr/bin/env bash
# billed-exempt: subscription claude -p behind a usage-preflight PROCEED on native auth (scripts/lib/native-auth-pin.sh); the API lane runs when CRYSTALLIZE_BACKEND=claude-api or HIMMEL_API_LANE=on, refuses unless HIMMEL_API_ACCOUNT is A|B|C (never auto), and the API-credit ledger meters it
# crystallize-note.sh — upgrade a mechanical session note into an LLM synthesis.
# Reads the session transcript + the just-written note and asks a
# bounded `claude` run to rewrite the four body sections (Summary / Decisions /
# Files Touched / Follow-ups), preserving frontmatter identity and setting
# `crystallized: true`.
#
# Backend rule: an explicit CRYSTALLIZE_BACKEND wins, else HIMMEL_API_LANE=on means
# claude-api, else claude-cli. The value is resolved by scripts/lib/llm-backend.sh
# (aliases cli, api); an unknown value, and ollama, fail closed (exit 2). So a session
# that has the API lane on keeps the API path, and nothing moves silently.
#   claude-cli  the default with the lane off. One print-mode `claude -p` on the
#               subscription, behind scripts/lib/usage-preflight.sh pinned to the
#               native bank: anything but PROCEED is a quiet skip (exit 0, note
#               untouched; a later `backfill-sessions.sh --reheal` run recovers it
#               once the bank allows, since the sweep asks the same bank). The run is pinned to native
#               auth through scripts/lib/native-auth-pin.sh (every ANTHROPIC_* and
#               CLAUDE_CODE_USE_* variable, and every LQ_API_* one, is removed, so a
#               proxy base URL or a provider toggle cannot reroute it), under a
#               deadline (CRYSTALLIZE_TIMEOUT_SECS, default 600). Tools Read,Edit
#               only, --permission-mode acceptEdits.
#   claude-api  CRYSTALLIZE_BACKEND=claude-api, or HIMMEL_API_LANE=on with no explicit
#               backend. The launch path is scripts/api-lane/claude-api.sh (one
#               print-mode call, tools limited to Read,Edit, a per-call budget; its
#               own fallback covers an empty account). It needs HIMMEL_API_LANE=on and
#               HIMMEL_API_ACCOUNT=A|B|C (never auto) in the launching shell and fails closed
#               (exit 2) without them: there is no claude-cli fallback from here.
#
# Usage: crystallize-note.sh <note_path> <transcript_path>
#
# Model: CRYSTALLIZE_MODEL (the hook exports it from .claude/end-session-wiki.json),
# else DEFAULT_MODEL below, which that config value must equal.
# CRYSTALLIZE_MAX_BUDGET_USD bounds each call.
#
# Best-effort once launched: any unavailability after the backend gate (over the
# concurrency cap, note not yet on disk, a failed preflight, no claude binary, a
# lane refusal such as no credit) -> exit 0, leaving the mechanical note
# (`crystallized: false`). The reheal sweep (`backfill-sessions.sh --reheal`)
# recovers anything a backgrounded run missed.
#
# A claude run that exits non-zero, times out or reports is_error leaves one line on
# stderr; the hash comparison below, never the exit code, decides crystallized: true,
# so an edit made before the failure still counts, as on the API path. The deadline
# needs a timeout binary; without one only --max-budget-usd bounds the call.
#
# Test seams: CRYSTALLIZE_CLAUDE_BIN overrides the launcher (the claude binary, or
# the API-lane launcher) with a stub and CRYSTALLIZE_PREFLIGHT_CMD overrides the
# preflight, so the suite stays hermetic. CRYSTALLIZE_PID_DIR /
# CRYSTALLIZE_MAX_CONCURRENCY tune the concurrency cap. bash 3.2-safe.
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

# Backend gate. The one resolver (unknown value -> exit 2, nothing runs).
# shellcheck source=../lib/llm-backend.sh
{ [ -r "$HIMMEL_ROOT/scripts/lib/llm-backend.sh" ] && . "$HIMMEL_ROOT/scripts/lib/llm-backend.sh"; } 2>/dev/null \
    || { echo "crystallize-note: refusing: scripts/lib/llm-backend.sh is missing -- note untouched" >&2; exit 2; }
if [ -n "${CRYSTALLIZE_BACKEND:-}" ]; then WANT_BACKEND="$CRYSTALLIZE_BACKEND"
elif [ "${HIMMEL_API_LANE:-}" = "on" ]; then WANT_BACKEND=claude-api
else WANT_BACKEND=claude-cli; fi
BACKEND="$(llm_backend_resolve "$WANT_BACKEND")" \
    || { echo "crystallize-note: refusing: CRYSTALLIZE_BACKEND='$WANT_BACKEND' is not accepted (claude-cli or claude-api) -- note untouched" >&2; exit 2; }
case "$BACKEND" in
    claude-api)
        # Explicit opt-in. A refusal leaves the mechanical note untouched and never falls
        # back to the subscription. The test override replaces the launcher, not the gate.
        llm_backend_api_ready \
            || { echo "crystallize-note: refusing claude-api: the API lane is off (HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT=A|B|C are required; auto is not accepted) -- note untouched, no claude-cli fallback" >&2; exit 2; }
        LAUNCHER="${CRYSTALLIZE_CLAUDE_BIN:-$HIMMEL_ROOT/scripts/api-lane/claude-api.sh}"
        [ -r "$LAUNCHER" ] \
            || { echo "crystallize-note: refusing claude-api: $LAUNCHER is missing -- note untouched" >&2; exit 2; }
        ;;
    claude-cli)
        # The preflight runs just before the launch (below), so a skipped note costs nothing.
        LAUNCHER="${CRYSTALLIZE_CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"
        ;;
    *)
        echo "crystallize-note: refusing: backend '$BACKEND' is not supported here (claude-cli or claude-api) -- note untouched" >&2
        exit 2
        ;;
esac

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
# -> append nothing (fail-open). Trim whitespace before the emptiness guard
# so whitespace-only files are skipped.
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

# The API lane removes the other credential sources itself and pins its own endpoint.
# It allows no --add-dir or --settings: the transcript is read through the granted Read
# tool, and Read,Edit are the only tools (hooks are off on the lane, so a Bash grant
# would be unguarded). Subshell function: its `exit 0` ends only the launch.
launch_api_lane() {
    cd "$NOTE_DIR" 2>/dev/null || exit 0
    CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
        HIMMEL_API_TOOLS=Read,Edit HIMMEL_API_KIND=bulk \
        bash "$LAUNCHER" -p "$PROMPT" --model "$MODEL" \
        --permission-mode acceptEdits --max-budget-usd "$BUDGET_USD" </dev/null >/dev/null
}

# The bank preflight, pinned to the native bank (the subscription this call draws on)
# whatever lane the session runs in, as scripts/api-lane/claude-api.sh pins its own.
crystallize_preflight() {
    if [ -n "${CRYSTALLIZE_PREFLIGHT_CMD:-}" ]; then
        env -u ANTHROPIC_API_KEY -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY -u ANTHROPIC_ORG_C_KEY -u LQ_API_KEY \
            -u CADENCE_USAGE_LAUNCH -u CADENCE_USAGE_CALLER_PID -u WORKER_SESSION_LANE \
            CADENCE_USAGE_LANE=native CADENCE_USAGE_WORKER="crystallize:$$" \
            "$CRYSTALLIZE_PREFLIGHT_CMD" </dev/null 2>/dev/null | tail -n 1
    else
        env -u ANTHROPIC_API_KEY -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY -u ANTHROPIC_ORG_C_KEY -u LQ_API_KEY \
            -u CADENCE_USAGE_LAUNCH -u CADENCE_USAGE_CALLER_PID -u WORKER_SESSION_LANE \
            CADENCE_USAGE_LANE=native CADENCE_USAGE_WORKER="crystallize:$$" \
            bash "$HIMMEL_ROOT/scripts/lib/usage-preflight.sh" </dev/null 2>/dev/null | tail -n 1
    fi
}

# The subscription launch. Native auth only: the pin removes every ANTHROPIC_* and
# CLAUDE_CODE_USE_* variable and the launch is gated on a keyword-only test that none
# survives (the native-auth-pin.sh LAUNCH GATE). Tools are Read,Edit only (no Bash),
# the permission mode is explicit, stdout is the JSON result, and a deadline bounds it.
# The exit code and an is_error result are reported on stderr; the hash comparison
# below decides the flag. Subshell function.
launch_subscription() {
    cd "$NOTE_DIR" 2>/dev/null || exit 0
    # shellcheck source=../lib/native-auth-pin.sh
    { [ -r "$HIMMEL_ROOT/scripts/lib/native-auth-pin.sh" ] && . "$HIMMEL_ROOT/scripts/lib/native-auth-pin.sh"; } 2>/dev/null \
        || { echo "crystallize-note: skipped, scripts/lib/native-auth-pin.sh is missing -- note untouched" >&2; exit 0; }
    native_auth_pin_env \
        || { echo "crystallize-note: skipped, native auth could not be pinned -- note untouched" >&2; exit 0; }
    local v out rc=0 secs="${CRYSTALLIZE_TIMEOUT_SECS:-600}"
    for v in $(compgen -e); do
        case "$v" in
            CLAUDE_CODE_OAUTH_TOKEN) ;;
            # the calling session's markers, plugin toggles and API-lane variables stay out of a child that reads untrusted transcripts
            # CLAUDE_CONFIG_DIR too: the preflight read the native bank, so the call must spend that login, not another directory's
            CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_CONFIG_DIR|CLAUDE_CODE_*|HIMMEL_API_*|LQ_API_*) unset "$v" ;;
        esac
    done
    case "$secs" in ''|*[!0-9]*|0) secs=600 ;; esac
    local -a deadline=()
    if command -v timeout >/dev/null 2>&1; then deadline=(timeout -k 10 "$secs"); fi
    out="$(mktemp "${TMPDIR:-/tmp}/crystallize-cli.XXXXXX" 2>/dev/null)" || out=/dev/null
    # launch-profile-ok: a throwaway one-shot note edit, tools Read,Edit only, no plugin session needed
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}${!LQ_API_*}" ]]; then
        CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
            ${deadline[@]+"${deadline[@]}"} "$LAUNCHER" -p "$PROMPT" --model "$MODEL" --output-format json \
            --permission-mode acceptEdits --tools Read,Edit --allowedTools Read,Edit --strict-mcp-config \
            --max-budget-usd "$BUDGET_USD" </dev/null >"$out" 2>/dev/null
        rc=$?
    else
        echo "crystallize-note: skipped, an API-key variable survived the native-auth pin -- note untouched" >&2
        [ "$out" = /dev/null ] || rm -f "$out" 2>/dev/null || true
        exit 0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "crystallize-note: claude exited rc=$rc -- note left to the reheal sweep" >&2
    fi
    if grep -Eq '"is_error"[[:space:]]*:[[:space:]]*true' "$out" 2>/dev/null; then
        echo "crystallize-note: claude reported is_error=true -- note left to the reheal sweep" >&2
    fi
    [ "$out" = /dev/null ] || rm -f "$out" 2>/dev/null || true
}
if [ "$BACKEND" = "claude-cli" ]; then
    PREFLIGHT="$(crystallize_preflight)"
    case "$PREFLIGHT" in
        PROCEED*) ;;
        *) echo "crystallize-note: skipped, bank-preflight said: ${PREFLIGHT:-<nothing>} -- note untouched" >&2; exit 0 ;;
    esac
    if [ -z "$LAUNCHER" ] || { [ ! -x "$LAUNCHER" ] && ! command -v "$LAUNCHER" >/dev/null 2>&1; }; then
        echo "crystallize-note: skipped, claude not found -- note untouched" >&2
        exit 0
    fi
    ( launch_subscription ) || true
else
    ( launch_api_lane ) || true
fi

# Edit-confirmed flag-set (T1d): only stamp crystallized:true when the note body
# actually changed. A failed/no-op run leaves the note byte-unchanged and the
# flag stays false; a real synthesis always flips it, with a deterministic UTC
# timestamp this script owns (CRYSTALLIZE_NOW overridable for hermetic tests).
HASH_AFTER="$(_hash "$NOTE_PATH")"
# Both hashes must be measurable (errs toward leaving the flag false when a hash
# can't be taken — never fabricates a crystallized:true).
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
            # prim-ok: publish the completed stamp without another allocation and retain its umask-derived mode.
            mv -f "$STAMP_TMP" "$NOTE_PATH" 2>/dev/null || rm -f "$STAMP_TMP" 2>/dev/null || true
        else
            rm -f "$STAMP_TMP" 2>/dev/null || true
        fi
    fi
fi

exit 0
