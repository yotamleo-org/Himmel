#!/usr/bin/env bash
# translate-tool-call.sh <guard.sh> — runs <guard.sh> on the hook payload with a
# Grok or Cursor tool call mapped onto Claude's shape, so the guard sees it.
#
# The jq copy of himmel-ops' lib/harness-tool-translate.js (this plugin ships
# no node), over lib/harness-tool-map.json beside this file:
#   - no string tool_name: the payload unchanged, the table never read.
#   - a string tool_name and a missing, unreadable, unparseable or misshapen
#     table (or no jq): exit 2, Claude names included.
#   - tools[name]: tool_name becomes its claude name, each keys entry renamed
#     when the target key is absent.
#   - <server>__<tool> with <server> in mcp_servers: tool_name becomes
#     mcp__<server>__<tool>, and Grok's use_tool wrapper is unwrapped.
#   - any other name: the payload byte for byte.
set -u

guard=${1:-}
if [ -z "$guard" ]; then
    echo "translate-tool-call: missing guard path" >&2
    exit 2
fi
table="$(cd "$(dirname "$0")" && pwd)/lib/harness-tool-map.json"

input=$(cat; printf x)
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

shape='type == "object"
    and (.tools | type) == "object"
    and (.mcp_servers | type) == "array"
    and all(.mcp_servers[]; type == "string")
    and all(.tools[]; type == "object" and (.claude | type) == "string"
        and ((has("keys") | not) or ((.keys | type) == "object" and all(.keys[]; type == "string"))))'
if ! { [ -r "$table" ] && jq -e "$shape" "$table" >/dev/null 2>&1; }; then
    echo "translate-tool-call: harness tool table $table is missing, unreadable or malformed; refusing the tool call" >&2
    exit 2
fi

out=$(printf '%s' "$input" | jq -c --slurpfile t "$table" '
    def obj: type == "object";
    $t[0] as $t | .tool_name as $n
    | if ($t.tools | has($n)) then
        $t.tools[$n] as $e
        | .tool_name = $e.claude
        | if (.tool_input | obj) then
            reduce (($e.keys // {}) | to_entries[]) as $k (.;
                if (.tool_input | has($k.key)) and ((.tool_input | has($k.value)) | not)
                then .tool_input |= with_entries(if .key == $k.key then .key = $k.value else . end)
                else . end)
          else . end
    elif ($n | startswith("mcp__") | not)
        and (($n | index("__")) as $i | $i != null and $i > 0 and ($n | length) > $i + 2
            and ($n[:$i] as $s | any($t.mcp_servers[]; . == $s))) then
        (if (.tool_input | obj) and .tool_input.tool_name == $n and (.tool_input.tool_input | obj)
         then .tool_input = .tool_input.tool_input else . end)
        | .tool_name = "mcp__" + $n
    else null end') || {
    echo "translate-tool-call: jq failed translating the tool call; refusing it" >&2
    exit 2
}

if [ "$out" = null ]; then
    printf '%s' "$input" | bash "$guard"
else
    printf '%s\n' "$out" | bash "$guard"
fi
exit $?
