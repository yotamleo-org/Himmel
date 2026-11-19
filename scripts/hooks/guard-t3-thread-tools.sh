#!/usr/bin/env bash
# guard-t3-thread-tools.sh — PreToolUse hook (matcher mcp__t3-code__.*). A
# SECURITY FENCE over the T3 Code MCP tools.
#
# WHY: each T3 provider instance carries its own environment variables, and
# himmel's hook bypasses are environment variables, so an instance can carry a
# bypass flag. The operator picks such an instance in the T3 UI. T3's MCP tools
# also let an agent pick the instance of a new or existing thread, which would
# let the agent move itself onto that instance. And a T3 thread title is the
# session name session-name.sh trusts for a chief (a `-chief` or `-console`
# suffix), so an agent must not set one either.
#
# RULE 1, instances: every value stored under a key named instanceId or
# providerInstanceId (case and `_` ignored) anywhere in .tool_input must be on
# the instance allowlist. A null value counts as absent; any other non-string
# value is refused.
#   Allowlist: .t3.instance_allowlist in $HOME/.himmel/config.json, an array of
#   strings that replaces the default. Default ["claudeAgent", "codex"] (T3's
#   two default instances) when the file or key is absent, unreadable,
#   malformed or a symlink. block-himmel-config-writes.sh refuses agent writes
#   to that file.
# RULE 2, titles: a string under a key named title anywhere in .tool_input
# whose trimmed value ends in -chief or -console (any case) is refused. A title
# inside a delegatedFrom object names the calling thread, not the new one, and
# is not judged.
#
# FAIL MODE: closed. Missing jq or a payload that does not parse is refused
# (only T3 tools are routed here). Any other tool name exits 0 at once.
#
# Bypass: T3_THREAD_TOOLS_OK=1 in the LAUNCHING shell (a per-call prefix does
# not reach the hook); the allow is printed to stderr.
#
# Hook I/O: JSON on stdin; exit 0 allow, exit 2 refuse (stderr shown).
# bash 3.2-compatible.
set -uo pipefail

DEFAULT_ALLOW='["claudeAgent","codex"]'
CONFIG="${HOME:-/nonexistent}/.himmel/config.json"

refuse() { # refuse <what was refused> <message body>
    if [ "${T3_THREAD_TOOLS_OK:-0}" = "1" ]; then
        echo "guard-t3-thread-tools: override: allowed $1 (T3_THREAD_TOOLS_OK=1)" >&2
        exit 0
    fi
    printf 'BLOCKED: guard-t3-thread-tools refused %s.\n%s\nBypass (operator only): relaunch from a shell with T3_THREAD_TOOLS_OK=1 (the allow is printed to stderr).\n' "$1" "$2" >&2
    exit 2
}

input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' returns 1 at EOF by design

command -v jq >/dev/null 2>&1 \
    || refuse "a T3 tool call" "jq is not on PATH, so the tool input cannot be checked for a provider instance or a chief title."

# swallow-ok: a failed parse refuses on the next line
tool=$(jq -er '.tool_name | strings' <<<"$input" 2>/dev/null) \
    || refuse "a T3 tool call" "The hook input is not JSON with a string tool_name, so it cannot be checked."
case "$tool" in
    mcp__t3-code__*) ;;
    *) exit 0 ;;
esac

findings=$(jq -r '
    def key_is($names): ascii_downcase | gsub("_"; "") as $k | any($names[]; . == $k);
    def walk_pairs($df):
        if type == "object" then
            to_entries[] | (.key | ascii_downcase == "delegatedfrom") as $d
            | {key, value, df: $df}, (.value | walk_pairs($df or $d))
        elif type == "array" then .[] | walk_pairs($df)
        else empty end;
    [.tool_input // {} | walk_pairs(false)] as $pairs
    | ($pairs[] | select(.key | key_is(["instanceid", "providerinstanceid"])) | .value
        | select(. != null) | "instance\t" + (if type == "string" then tojson else "non-string " + tojson end)),
      ($pairs[] | select((.df | not) and (.key | ascii_downcase == "title")) | .value | strings
        | select(gsub("^\\s+|\\s+$"; "") | ascii_downcase | test("-(chief|console)$")) | "title\t" + tojson)
' <<<"$input" 2>/dev/null) \
    || refuse "$tool" "Its tool_input could not be walked, so it cannot be checked."
[ -n "$findings" ] || exit 0

allow="$DEFAULT_ALLOW" allow_src="the built-in default, since $CONFIG has no usable .t3.instance_allowlist"
if [ ! -L "${HOME:-/nonexistent}/.himmel" ] && [ ! -L "$CONFIG" ] && [ -f "$CONFIG" ] && [ -r "$CONFIG" ]; then
    # swallow-ok: an unreadable or malformed allowlist keeps the built-in default
    if cfg=$(jq -ce '.t3.instance_allowlist | select(type == "array" and all(.[]; type == "string"))' "$CONFIG" 2>/dev/null); then
        allow="$cfg" allow_src=".t3.instance_allowlist in $CONFIG"
    fi
fi

bad_instances="" bad_titles=""
while IFS= read -r line; do
    case "$line" in
        instance$'\t'*)
            val=${line#instance$'\t'}
            case "$val" in
                'non-string '*) bad_instances="$bad_instances  ${val}"$'\n' ;;
                *) jq -en --argjson allow "$allow" --argjson v "$val" '$allow | index([$v]) != null' >/dev/null 2>&1 \
                    || bad_instances="$bad_instances  ${val}"$'\n' ;;
            esac
            ;;
        title$'\t'*) bad_titles="$bad_titles  ${line#title$'\t'}"$'\n' ;;
    esac
done <<<"$findings"

if [ -n "$bad_instances" ]; then
    refuse "$tool on a provider instance off the allowlist" "Refused instance id(s):
${bad_instances}Allowed instances: $(jq -r 'map(tojson) | join(", ")' <<<"$allow") (from ${allow_src}).
The allowlist is .t3.instance_allowlist in \$HOME/.himmel/config.json, an operator-owned file.
Only the operator starts or moves a thread onto another instance, by choosing it in the T3 UI.
Omit the instance id to keep the default, or name one of the allowed instances."
fi
if [ -n "$bad_titles" ]; then
    refuse "$tool with a chief-shaped thread title" "Refused title(s):
${bad_titles}A T3 thread is named as a chief (a -chief or -console suffix) only by the operator in the T3 UI,
because the chief guards trust that name as the session's identity. Pick a title without that suffix."
fi
exit 0
