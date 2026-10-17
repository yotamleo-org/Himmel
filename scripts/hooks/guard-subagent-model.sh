#!/usr/bin/env bash
# guard-subagent-model.sh — PreToolUse hook (matcher "Agent"):
# structural enforcement of root CLAUDE.md's "Every dispatch names an explicit
# model" rule. An Agent dispatch with no `model` inherits the PARENT session's
# model (or falls to the agent definition's default) — silently billing the
# scarcer parent tier for work that could have run on a cheaper one. Nothing
# enforced this before; it was prose only, then a WARN for untyped dispatches.
#
# WHY NOW: a 24h/4.40e9-token measurement found subagents at
# 50.06% of raw spend, with subagent_type "general-purpose" alone at 49.85% —
# the dominant shape is exactly the unnamed-model, generic-worker dispatch
# this hook targets. The deny covers every typed agent too: a typed agent
# with no model would otherwise pass with no signal at all.
#
# OWNERSHIP: this hook owns "a model must be named";
# guard-agent-model.sh owns "the named model must not be a blocked one".
# Neither duplicates the other's check.
#
# DENY CONDITION (both must hold):
#   1. tool_input.model is absent, null, empty, or whitespace-only
# (explicit null counts as absent).
#   2. tool_input.subagent_type is anything but "fork". A fork always inherits
#      the parent model and ignores `model`, so a missing one says nothing.
#
# Escape hatch (set in the shell that LAUNCHED Claude Code; session-sticky):
#   SUBAGENT_MODEL_OK=1   lets an unnamed-model dispatch through.
#
# FAIL-OPEN ON EVERYTHING ELSE: unreadable/unparseable stdin, a non-Agent
# tool, missing tool_input, a wrong-typed model/subagent_type, any jq failure —
# all exit 0 silently. This is a workflow nudge (scripts/hooks/CLAUDE.md's
# fail-open-vs-closed rule), not a security fence: a guard that blocks dispatch
# because it could not parse a payload is worse than the drift it prevents.
# Purely structural on two payload fields — no transcript read, no prompt-text
# intent detection.
#
# Bash 3.2-compatible. Exit codes: 0 allow; 2 deny.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Reads the hook payload from stdin and shells out to jq; NOT ported to native
# PowerShell, and deliberately shipped without a .ps1 twin — hooks.json invokes
# this script through hooks/run-hook-with-bash.js, so it runs under bash on
# every platform himmel supports and a twin would be dead code. A real Windows
# port (only needed if that wiring ever changes) would have to read the same
# stdin JSON, reproduce the fail-open contract above exactly — absent
# tool_input, wrong-typed fields and any parse failure all allow — and emit the
# same permissionDecision object and 0/2 exit codes.
set -uo pipefail

warn() { echo "guard-subagent-model: $*" >&2; }

input=$(cat 2>/dev/null || true)

if [ "${SUBAGENT_MODEL_OK:-0}" = "1" ]; then
    warn "SUBAGENT_MODEL_OK=1 — allowing by explicit session override"
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -n "$input" ] || exit 0

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    exit 0
fi
[ "$tool" = "Agent" ] || exit 0

# a missing/non-object tool_input, or a model/subagent_type
# field present with a non-null, non-string JSON type (number, object, array,
# boolean), must fail open like any other unparseable payload — it must NOT be
# treated as the field being genuinely omitted (which trips the guard). An
# explicit JSON null is NOT wrong-typed: it means "names no model" and trips
# exactly like an absent field (the case arms below admit `null`). A null
# model that failed open would be a real hole. `select(type == "string") //
# empty` alone cannot tell those apart: a truly-absent field, a null and a
# present-but-wrong-type field all collapse to the empty string. That collapse is exactly
# what let a payload with no `tool_input` at all read as empty model + empty
# subagent_type and get DENIED instead of failing open. So check .tool_input's
# type first, then each field's type, before ever reading a value.
tool_input_type=$(printf '%s' "$input" | jq -r '.tool_input | type' 2>/dev/null) || exit 0
[ "$tool_input_type" = "object" ] || exit 0

model_type=$(printf '%s' "$input" | jq -r '.tool_input.model | type' 2>/dev/null) || exit 0
case "$model_type" in
    null|string) ;;
    *) exit 0 ;;
esac
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null) || exit 0

subagent_type_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type | type' 2>/dev/null) || exit 0
case "$subagent_type_type" in
    null|string) ;;
    *) exit 0 ;;
esac
subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0

# Whitespace-only counts as absent — a model field carrying only spaces names
# nothing runnable.
model_trimmed=$(printf '%s' "$model" | tr -d '[:space:]')
[ -z "$model_trimmed" ] || exit 0

# fork inherits the parent model and ignores `model`.
[ "$subagent_type" != "fork" ] || exit 0

shape="${subagent_type:-<no-subagent_type>}/<no-model>"

deny_msg="guard-subagent-model: unnamed-model Agent dispatch DENIED ($shape) — an Agent dispatch with no model silently inherits the PARENT session's model, billing the scarcer parent tier for work that may not need it (root CLAUDE.md: \"Every dispatch names an explicit model\"). Pass an explicit model on this dispatch; /lanes lists the live tiers/lanes available on this machine. subagent_type \"fork\" is exempt (it inherits the parent model). Deliberate override: relaunch with SUBAGENT_MODEL_OK=1 in the launching shell."

reason_json=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason_json='"guard-subagent-model: unnamed-model Agent dispatch DENIED — pass an explicit model (SUBAGENT_MODEL_OK=1 to override)"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason_json"
printf '%s\n' "$deny_msg" >&2
exit 2
