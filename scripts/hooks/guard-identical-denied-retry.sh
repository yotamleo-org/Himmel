#!/usr/bin/env bash
# guard-identical-denied-retry.sh — PreToolUse hook (matcher "Bash"): deny a THIRD
# byte-identical Bash command once two earlier attempts of it were refused in this
# session, and point at the way out (himmel-ops:stuck-playbook).
#
# WHY: "two refusals of one command, then the stuck-playbook" is prose, and agents
# retry the same refused bytes anyway (traj/identical-retry telemetry). A third
# identical retry burns a turn and teaches nothing, so the harness refuses it.
#
# DETECTION: scans only the TAIL of the session transcript (last 4 MiB, last 400
# lines) for Bash tool_use rows whose input.command is byte-identical to the current
# command, and pairs each with its tool_result (same tool_use_id). A result counts as
# a denial when it is_error, does not start with "Exit code" (that is a command that
# ran and failed) and matches DENIAL_RE. DENIAL_RE and the "Exit code" rule are the
# ones in scripts/eval/lane-quality/trajectory.py (DENIAL_RE, denied()); the
# identical-retry meaning is denial_list() there. A result that is NOT a denial means
# the command ran, so it resets the count. Deny when the count is 2 or more.
#
# FAIL-OPEN: it runs on every Bash call and may only ever deny the precisely detected
# third identical command. Missing jq, an empty or unparseable payload, a missing or
# unreadable transcript, a tail window with no parseable rows (e.g. one oversized
# line) and every jq error all exit 0 silently.
#
# No single-run bypass yet: it needs an entry in scripts/himmelctl/lib/bypass-flags.json.
#
# bash 3.2-compatible (no mapfile, no associative arrays).
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0 # swallow-ok: fail-open hook, an unreadable payload allows
[ -n "$input" ] || exit 0

fields=$(printf '%s' "$input" | jq -r '[.tool_name // "", .transcript_path // ""] | @tsv' 2>/dev/null) || exit 0 # swallow-ok: fail-open hook, an unparseable payload allows
tool=${fields%%$'\t'*}
transcript=${fields#*$'\t'}
[ "$tool" = "Bash" ] || exit 0
[ -n "$transcript" ] && [ -r "$transcript" ] && [ -f "$transcript" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0 # swallow-ok: fail-open hook, an unparseable payload allows
[ -n "$cmd" ] || exit 0

count=$(
    tail -c 4194304 "$transcript" 2>/dev/null | tail -n 400 2>/dev/null |
    jq -Rsr --arg cmd "$cmd" '
      def txt: if (.content|type) == "string" then .content
               elif (.content|type) == "array" then ([.content[]? | .text? // ""] | join(""))
               else "" end;
      def denied:
        (.is_error == true)
        and ((txt | ltrimstr(" ") | startswith("Exit code")) | not)
        and (txt | test("requires? approval|needs approval|hook error|PreToolUse|permission|denied|refus|blocked|can'"'"'t be checked before it runs|did not consume"; "i"));
      [ split("\n")[] | (try fromjson catch empty) | .message.content? | arrays | .[] ] as $items
      | reduce $items[] as $it ({ids: {}, n: 0};
          if ($it.type? == "tool_use") and ($it.name? == "Bash") and (($it.input.command? // null) == $cmd)
          then .ids[$it.id] = true
          elif ($it.type? == "tool_result") and (.ids[$it.tool_use_id? // ""] // false)
          then (if ($it | denied) then .n += 1 else .n = 0 end)
          else . end)
      | .n' 2>/dev/null
) || exit 0
case "$count" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$count" -ge 2 ] || exit 0

msg="Refusing a repeat: this exact command was already denied $count times in this session. Retrying the same bytes will be denied again. Stop and use the stuck-playbook instead (skill himmel-ops:stuck-playbook, docs/internals/stuck-playbook.md): rewrite the command as one different literal command, or route the blocker to the console."
reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) || exit 0 # swallow-ok: fail-open hook, no encoder means no deny
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$msg" >&2
exit 2
