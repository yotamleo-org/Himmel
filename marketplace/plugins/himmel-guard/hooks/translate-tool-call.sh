#!/usr/bin/env bash
# translate-tool-call.sh <guard.sh>: runs <guard.sh> on the hook payload in Claude's shape.
set -u

guard=${1:-}
if [ -z "$guard" ]; then
    echo "translate-tool-call: missing guard path" >&2
    exit 2
fi
table="$(cd "$(dirname "$0")" && pwd)/lib/harness-tool-map.json"

input=$(cat && printf x) || {
    echo "translate-tool-call: could not read the hook payload; refusing the tool call" >&2
    exit 2
}
input=${input%x}

if ! command -v jq >/dev/null 2>&1; then
    echo "translate-tool-call: jq not found; refusing the tool call" >&2
    exit 2
fi

kind=$(printf '%s' "$input" | jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0].tool_name | type) == "string" then "tool" else "other" end' 2>/dev/null) || kind=other
if [ "$kind" != tool ]; then
    printf '%s' "$input" | bash "$guard"
    exit $?
fi
if [ "$(printf '%s' "$input" | jq -r '.toolInputTruncated == true and .hook_event_name != "PostToolUse" and .hook_event_name != "PostToolUseFailure"')" != false ]; then
    echo "translate-tool-call: the harness marked this tool input truncated, so no guard can judge all of it; refusing the tool call" >&2
    exit 2
fi

shape='type == "object"
    and (.tools | type) == "object"
    and (.mcp_servers | type) == "array"
    and all(.mcp_servers[]; type == "string")
    and (.events | type) == "object"
    and all(.events[]; type == "string")
    and all(.tools[]; type == "object" and (.claude | type) == "string"
        and ((has("keys") | not) or ((.keys | type) == "object" and all(.keys[]; type == "string"))))'
if ! { tbl=$(cat "$table" 2>/dev/null) && printf '%s' "$tbl" | jq -se "length == 1 and (.[0] | $shape)" >/dev/null 2>&1; }; then
    echo "translate-tool-call: harness tool table $table is missing, unreadable or malformed; refusing the tool call" >&2
    exit 2
fi

out=$(printf '%s' "$input" | jq -c --argjson t "$tbl" '
    def obj: type == "object";
    def mapevent: .hook_event_name as $ev
        | if ($ev | type) == "string" and ($t.events | has($ev)) then .hook_event_name = $t.events[$ev] else . end;
    .tool_name as $n
    | if ($t.tools | has($n)) then
        $t.tools[$n] as $e
        | .tool_name = $e.claude
        | if (.tool_input | obj) then
            reduce (($e.keys // {}) | to_entries[]) as $k (.;
                if (.tool_input | has($k.key)) | not then .
                elif .tool_input | has($k.value) then
                    (if .tool_input[$k.key] == .tool_input[$k.value] then . else error("two different values under \($k.key) and \($k.value)") end)
                else .tool_input |= with_entries(if .key == $k.key then .key = $k.value else . end) end)
          else . end
        | mapevent
    elif ($n | startswith("mcp__") | not)
        and (($n | index("__")) as $i | $i != null and $i > 0 and ($n | length) > $i + 2
            and ($n[:$i] as $s | any($t.mcp_servers[]; . == $s))) then
        (if (.tool_input | obj) and .tool_input.tool_name == $n and (.tool_input.tool_input | obj)
         then .tool_input = .tool_input.tool_input else . end)
        | .tool_name = "mcp__" + $n
        | mapevent
    else null end') || {
    echo "translate-tool-call: the tool call could not be translated (see jq's error above); refusing it" >&2
    exit 2
}

if [ "$out" = null ]; then
    printf '%s' "$input" | bash "$guard"
else
    printf '%s\n' "$out" | bash "$guard"
fi
exit $?
