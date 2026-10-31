#!/usr/bin/env bash
# guard-agent-model.sh — PreToolUse hook (matcher "Agent"): denies an Agent
# dispatch whose `model` matches a blocked pattern (today: Fable), and a
# `judge` dispatch (any judge* agent, old ids console-judge*) that overrides `model` off its frontmatter tier
# (opus), unless the dispatch prompt carries a line `ESCALATION: <reason>` with a
# real reason. Fable is no longer the judge default: Opus
# 5.5 high measured ~2.7x cheaper per verdict ($8.23 vs $21.94) at
# comparable wall time and no missed finding, yet an in-process Agent call passing
# `model: fable` silently overrides .claude/agents/judge.md's
# `model: opus` (chief O did it three times on 2026-09-29). Fable stays
# available as the CLAUDE.md escalation target for ONE hard call — the marker is
# that lane.
#
# The blocked model patterns, the minimum reason length and the placeholder
# reasons live in scripts/guardrails/agent-model-policy.json, NOT here: unblocking
# a future Fable is a one-line reviewed change to that file. A reason that is
# empty, shorter than min_reason_chars or a listed placeholder ("test", "n/a")
# does not count. A marker that DOES rescue a would-be deny is echoed on stderr
# (`agent-model-escalation: …`, exit 0) so the override is auditable; the reason
# also stays in the dispatch prompt.
#
# TIER WARN (never a deny): a general-purpose (or untyped) dispatch whose
# `model` matches warn_model_patterns in the policy file (today: Opus) and whose
# prompt has no `TIER: <reason>` line (same reason-quality test as ESCALATION)
# gets one additionalContext line naming the cheaper tier per helper kind
# (chief Opus general-purpose helpers rose from $14 to $41-eq/day). Exit 0, no
# permissionDecision. It fires for any session, not only a chief: the payload
# carries no role, and a worker's Opus helper is the same spend.
# ponytail: any-session scope, chief-only needs a role probe like guard-chief-dispatch.sh.
#
# EFFORT WARN (never a deny): any Agent dispatch whose `effort` is
# high, xhigh or max and whose prompt has no `EFFORT: <reason>` line (same
# reason-quality test) gets one additionalContext line; it joins the TIER warn
# when both fire. A dispatch a deny or an ESCALATION rescue already handles gets
# no effort warn. A missing or non-string `effort` warns on nothing, and so does
# an effort equal to the named agent's own `effort:` frontmatter (judge at high).
# ponytail: the warned levels are hardcoded here, upgrade path a warn_effort_levels key in agent-model-policy.json.
#
# Allow prints NOTHING (no stdout, no stderr) unless a marker just rescued a
# deny or a WARN above fired: zero context cost. A missing `model` is always allowed (the agent's own
# frontmatter/default applies). The judge tier is hardcoded to opus;
# test-guard-agent-model.sh asserts the frontmatter still says so, so a tier
# change there fails the suite here.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): fails OPEN on anything it cannot parse (missing jq, missing or
# malformed policy file, an invalid policy regex, malformed or empty stdin,
# non-string fields), matching the sibling per-tool guards
# guard-worker-wakeup.sh / block-worker-askuserquestion.sh and the Agent watchdog
# auto-arm-on-subagent-cap.sh (exit 0 on an unparseable or non-Agent payload).
# The suite asserts the shipped policy file parses, so "fails open" cannot hide a
# broken policy.
#
# Bypass: the `ESCALATION: <reason>` prompt line is the per-dispatch bypass; it
# is a line of its own (a mid-sentence mention or an empty reason does not count).
#
# Platform guard: jq only, no git/path work beyond the sibling policy file; any
# POSIX bash 3.2+.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same
# belt-and-braces idiom as guard-worker-wakeup.sh).
#
# ponytail: covers the Agent tool only — a Workflow script's agent() dispatches
# run inside the one Workflow tool call and no per-dispatch hook seam is known,
# so they are not covered.
# ponytail: upgrade path HIMMEL-3849.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

policy="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/../guardrails/agent-model-policy.json"
[ -r "$policy" ] || exit 0

input=$(cat)

# The named agent's own `effort:` frontmatter (.claude/agents/<name>.md beside
# this hook): a dispatch passing that same effort is not an override, so no
# EFFORT warn. Only a plain [a-z0-9-] name is looked up (no path, no plugin ns).
agent_effort=""
agent_name=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type | strings' 2>/dev/null || true)  # swallow-ok: a failed read means no frontmatter lookup, so the warn still fires
case "$agent_name" in
    ''|*[!a-z0-9-]*) ;;
    *) agent_md="$(dirname "$0")/../../.claude/agents/$agent_name.md"
       [ -f "$agent_md" ] && [ -r "$agent_md" ] \
           && agent_effort=$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } /^effort:/ { sub(/^effort:[ \t]*/, ""); v = $0 } END { print v }' "$agent_md") ;;
esac

# One line: kind <TAB> eflag <TAB> status <TAB> model <TAB> effort <TAB> reason.
# eflag: effort = the EFFORT warn applies, - = it does not. status: none = no
# ESCALATION line, weak = only unusable reasons, ok = a usable reason. Fields
# before the last are never empty (an empty model/effort is "-"; read collapses
# empty tabs). A plain allow is the single word "allow".
verdict=$(printf '%s' "$input" | jq -r --slurpfile pol "$policy" --arg fe "$agent_effort" '
    def s: if type == "string" then . else "" end;
    def clean: gsub("[\\p{Cc}]"; " ") | gsub("^ +| +$"; "");
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | gsub("^ +| +$"; "");
    (($pol[0] // {}) | if type == "object" then . else {} end) as $p
    | [$p.blocked_model_patterns | arrays[] | strings] as $pats
    | [$p.warn_model_patterns | arrays[] | strings] as $wpats
    | (($p.min_reason_chars | numbers) // 10) as $min
    | [$p.placeholder_reasons | arrays[] | strings | norm] as $ph
    | (.tool_name | s) as $tool
    | (.tool_input | if type == "object" then . else {} end) as $ti
    | ($ti.model | s | ascii_downcase | clean) as $m
    | ($ti.subagent_type | s | ascii_downcase) as $t
    | [$ti.prompt | s | split("\n")[] | capture("^[ \\t]*ESCALATION:[ \\t]*(?<r>.*)$")? | .r | clean] as $rs
    | [$rs[] | select(length >= $min and norm != "" and (norm as $n | $ph | any(. == $n) | not))] as $good
    | (if ($rs | length) == 0 then "none" elif ($good | length) > 0 then "ok" else "weak" end) as $status
    | (if $status == "ok" then $good[0] else ($rs[0] // "") end) as $reason
    | [$ti.prompt | s | split("\n")[] | capture("^[ \\t]*TIER:[ \\t]*(?<r>.*)$")? | .r | clean
       | select(length >= $min and norm != "" and (norm as $n | $ph | any(. == $n) | not))] as $tgood
    | ($ti.effort | s | ascii_downcase | clean) as $e
    | [$ti.prompt | s | split("\n")[] | capture("^[ \\t]*EFFORT:[ \\t]*(?<r>.*)$")? | .r | clean
       | select(length >= $min and norm != "" and (norm as $n | $ph | any(. == $n) | not))] as $egood
    | ($tool == "Agent" and ($e | test("^(high|xhigh|max)$")) and ($egood | length) == 0
       and $e != ($fe | ascii_downcase | clean)) as $ewarn
    | (if $tool != "Agent" or $m == "" then "allow"
       elif ($pats | any(. as $r | $m | test($r))) then "blocked"
       elif ($t | test("(^|:)(console-)?judge(-[a-z0-9-]+)?$")) and ($m | test("^(claude-)?opus(-[0-9][0-9a-z.-]*)?(\\[[^\\]]*\\])?$") | not) then "judge"
       elif ($t == "" or $t == "general-purpose") and ($tgood | length) == 0 and ($wpats | any(. as $r | $m | test($r))) then "warn"
       else "allow" end) as $kind
    | if $kind == "allow" and ($ewarn | not) then "allow"
      else [$kind, (if $ewarn then "effort" else "-" end), $status,
            (if $m == "" then "-" else $m end), (if $e == "" then "-" else $e end), $reason] | join("\t") end' 2>/dev/null) || exit 0

IFS=$'\t' read -r kind eflag status model effort reason <<EOF
$verdict
EOF

if [ "$kind" = "warn" ] || [ "$kind" = "allow" ]; then
    # Warn only: additionalContext, NO permissionDecision (that would also skip a
    # permission prompt), exit 0. Allow stays silent for every other dispatch.
    warn_msg=""
    [ "$kind" = "warn" ] && warn_msg="agent-model-warn: a general-purpose helper on '${model}' with no TIER: line. Name the cheapest tier that can do the job (CLAUDE.md: raise effort before tier): sonnet for legs.json drafting, wave prep, ticket audits and per-page docs reviews; haiku at medium effort for a specified edit list ending in a machine check. Opus only for the one hard call: re-dispatch on a cheaper model, or add a prompt line 'TIER: <reason>' with a real reason (docs/handover/running-a-chief.md, helper table)."
    [ "$eflag" = "effort" ] && warn_msg="${warn_msg:+$warn_msg }agent-model-effort-warn: a dispatch at effort '${effort}' with no EFFORT: line. Each helper kind has a default effort (docs/handover/running-a-chief.md, helper table): drop the effort override, or add a prompt line 'EFFORT: <reason>' with a real reason."
    [ -n "$warn_msg" ] || exit 0
    jq -nc --arg ctx "$warn_msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}' 2>/dev/null
    exit 0
fi

case "$kind" in
    blocked) what="model '$model' (blocked by scripts/guardrails/agent-model-policy.json)" ;;
    judge) what="a judge model override '$model' off its frontmatter tier (opus)" ;;
    *) exit 0 ;;
esac

if [ "$status" = "ok" ]; then
    printf 'agent-model-escalation: %s allowed by ESCALATION reason: %s\n' "$what" "$reason" >&2
    exit 0
fi

if [ "$status" = "weak" ]; then
    lead="${what} with an ESCALATION reason that is empty, a placeholder or too short (min_reason_chars / placeholder_reasons in the policy file)"
else
    lead="${what} without an escalation marker"
fi
deny_msg="agent-model-deny: ${lead} — Fable is retired as the judge default (Opus 5.5 high measured ~2.7x cheaper per verdict, \$8.23 vs \$21.94, with no missed finding). Drop the model override, or for ONE genuinely hard call add a prompt line 'ESCALATION: <reason>' with a real reason and re-dispatch. To unblock a model for good, edit scripts/guardrails/agent-model-policy.json."

reason_json=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason_json='"agent-model-deny: model override denied without a usable ESCALATION: marker"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason_json"
printf '%s\n' "$deny_msg" >&2
exit 2
