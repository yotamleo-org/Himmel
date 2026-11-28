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
# OWNERSHIP: this hook owns "a model must be named" and "a Haiku child is a
# leaf" (the named model fits the subagent_type); guard-agent-model.sh owns
# "the named model must not be a blocked one". Neither duplicates the other's
# check.
#
# DENY CONDITION 1, unnamed model (both must hold):
#   1. tool_input.model is absent, null, empty, or whitespace-only
# (explicit null counts as absent).
#   2. tool_input.subagent_type is anything but "fork". A fork always inherits
#      the parent model and ignores `model`, so a missing one says nothing.
#
# DENY CONDITION 2, Haiku is a leaf (both must hold):
#   1. tool_input.model names Haiku: the word haiku, bounded by a
#      non-alphanumeric or an end of the value, any case (haiku,
#      claude-haiku-5-5, claude-3-5-haiku-20241022).
#   2. tool_input.subagent_type keeps the Agent tool, so the Haiku child could
#      spawn (and a built-in Explore it calls runs on the MAIN session's model,
#      a tier up): it is absent, null, empty, "general-purpose" or "claude", or
#      it names an agent definition, a *.md anywhere under $CLAUDE_PROJECT_DIR/
#      .claude/agents/ first, then $HOME/.claude/agents/ (subfolders included),
#      whose frontmatter `name:` (the file name when it has none) is the type
#      and leaves Agent available: no `tools:` key, or one listing Agent, the
#      old name Task or the `*` wildcard, and no `disallowedTools:` naming it.
#      A `#` inside quotes is not a comment. A key's value is its own line plus every
#      indented or `- ` continuation line up to the next top-level key, read
#      as one value (a specifier wrapped over lines stays one specifier), so
#      inline, quoted, flow, block-scalar and list forms all count; comments
#      and blank lines are skipped. The deny names
#      haiku-worker (.claude/agents/haiku-worker.md, Agent disallowed). A type
#      whose definition omits Agent (edit-runner, haiku-worker), and a type with
#      no readable definition file (built-ins such as Explore, plugin agents,
#      a name outside [A-Za-z0-9_-]), passes. A hook cannot see the CALLER's model, so
#      a Haiku main session is the launcher's half: scripts/lib/subagent-caps.sh.
#
# Escape hatch (set in the shell that LAUNCHED Claude Code; session-sticky):
#   SUBAGENT_MODEL_OK=1   lets either deny through.
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
# Platform guard: any POSIX bash 3.2+. Reads the hook payload from stdin and
# shells out to jq; hooks.json invokes this script through
# hooks/run-hook-with-bash.js, so it runs under bash on every platform himmel
# supports.
set -uo pipefail

warn() { echo "guard-subagent-model: $*" >&2; }

agent_def_keeps_agent() {
    local root f rc
    case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    for root in "${CLAUDE_PROJECT_DIR:-}" "${HOME:-}"; do
        [ -n "$root" ] && [ -d "$root/.claude/agents" ] || continue
        while IFS= read -r f; do
            [ -f "$f" ] || continue  # fail-open-ok: a workflow nudge (header FAIL-OPEN); an unreadable definition is skipped like a missing one
            rc=0
            awk -v want="$1" -v stem="$(basename "$f" .md)" '
                function uncomment(v,   i, c, q, p) {
                    q = ""; p = " "
                    for (i = 1; i <= length(v); i++) {
                        c = substr(v, i, 1)
                        if (q != "") { if (c == q) q = "" }
                        else if ((c == "\"" || c == "\047") && p ~ /[[:space:],[{(:]/) q = c
                        else if (c == "#" && p ~ /[[:space:]]/) return substr(v, 1, i - 1)
                        p = c
                    }
                    return v
                }
                function has_agent(v, k,   n, a, i, t) {
                    gsub(/\([^)]*\)/, "", v)
                    gsub(/["'\''\[\]{}>|]/, " ", v)
                    n = split(v, a, /[[:space:],]+/)
                    for (i = 1; i <= n; i++) { t = a[i]; sub(/\(.*$/, "", t); if (t == "Agent" || t == "Task" || (t == "*" && k == "tools")) return 1 }
                    return 0
                }
                function take(v) {
                    if (key == "tools") tval = tval " " uncomment(v)
                    if (key == "drop") dval = dval " " uncomment(v)
                }
                NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
                /^---[[:space:]]*$/ { done = 1; exit }
                /^[[:space:]]*(#|$)/ { next }
                /^[[:space:]]/ || /^-([[:space:]]|$)/ { take($0); next }
                { key = "" }
                /^name:/ { v = $0; sub(/^name:/, "", v); sub(/[[:space:]]+#.*$/, "", v); gsub(/["'\''[:space:]]/, "", v); name = v }
                /^tools:/ { tools = 1; key = "tools"; v = $0; sub(/^tools:/, "", v); take(v); next }
                /^disallowedTools:/ { key = "drop"; v = $0; sub(/^disallowedTools:/, "", v); take(v); next }
                END {
                    if (!done || (name == "" ? stem : name) != want) exit 2
                    exit (has_agent(dval, "drop") || (tools && !has_agent(tval, "tools"))) ? 1 : 0
                }
            ' "$f" || rc=$?
            case "$rc" in
                0) return 0 ;;
                1) return 1 ;;
            esac
        done < <(find -L "$root/.claude/agents" -type f -name '*.md')
    done
    return 1
}

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

if [ -n "$model_trimmed" ]; then
    model_lc=$(printf '%s' "$model_trimmed" | tr '[:upper:]' '[:lower:]')
    case "$model_lc" in
        haiku|haiku[!a-z0-9]*|*[!a-z0-9]haiku|*[!a-z0-9]haiku[!a-z0-9]*) ;;
        *) exit 0 ;;
    esac
    case "$subagent_type" in
        ''|general-purpose|claude) ;;
        *) agent_def_keeps_agent "$subagent_type" || exit 0 ;;
    esac
    shape="${subagent_type:-<no-subagent_type>}/$model_trimmed"
    deny_msg="guard-subagent-model: Haiku child on a spawning type DENIED ($shape) — a Haiku child is a leaf and never spawns (root CLAUDE.md Subagent policy), but subagent_type \"${subagent_type:-<none>}\" keeps the Agent tool, and a built-in Explore it calls runs on the MAIN session's model, a tier up. Use subagent_type \"haiku-worker\" (model haiku, Agent disallowed), or a typed agent with no Agent tool such as edit-runner. Deliberate override: relaunch with SUBAGENT_MODEL_OK=1 in the launching shell."
    short_msg="guard-subagent-model: Haiku child on a spawning type DENIED — use subagent_type haiku-worker (SUBAGENT_MODEL_OK=1 to override)"
else
    # fork inherits the parent model and ignores `model`.
    [ "$subagent_type" != "fork" ] || exit 0
    shape="${subagent_type:-<no-subagent_type>}/<no-model>"
    deny_msg="guard-subagent-model: unnamed-model Agent dispatch DENIED ($shape) — an Agent dispatch with no model silently inherits the PARENT session's model, billing the scarcer parent tier for work that may not need it (root CLAUDE.md: \"Every dispatch names an explicit model\"). Pass an explicit model on this dispatch; /lanes lists the live tiers/lanes available on this machine. subagent_type \"fork\" is exempt (it inherits the parent model). Deliberate override: relaunch with SUBAGENT_MODEL_OK=1 in the launching shell."
    short_msg="guard-subagent-model: unnamed-model Agent dispatch DENIED — pass an explicit model (SUBAGENT_MODEL_OK=1 to override)"
fi

reason_json=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason_json="\"$short_msg\""
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason_json"
printf '%s\n' "$deny_msg" >&2
exit 2
