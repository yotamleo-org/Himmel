#!/usr/bin/env bash
# guard-t3-thread-tools.sh — PreToolUse hook (matcher mcp__t3-code__.*): refuses
# a T3 Code tool call that names a bypass provider instance, or one off the
# optional narrowing list, or that sets a -chief or -console thread title.
#
# Bypass instance: an entry in T3's settings file
# (${T3CODE_HOME:-$HOME/.t3}/userdata/settings.json, .providerInstances) whose
# env / environment (on the instance or its config) names a *_OK or *BYPASS*
# variable (any case) or a flag in scripts/himmelctl/lib/bypass-flags.json, is
# malformed (entry, config, environment entry name or launchArgs), or whose launchArgs carry
# --dangerously-skip-permissions or bypassPermissions. Any other instance id is
# allowed, from any provider to any provider.
#
# Narrowing: .t3.instance_narrow in $HOME/.himmel/config.json, an array of
# strings; an absent file or key narrows nothing. .t3.instance_allowlist is not read.
#
# Security fence, fail-closed: missing jq, a payload that does not parse, an
# unreadable or malformed T3 settings file or bypass registry, and a malformed or
# symlinked narrowing config are refused.
#
# Bypass: T3_THREAD_TOOLS_OK=1 in the launching shell; the allow is printed to
# stderr.
#
# Hook I/O: JSON on stdin; exit 0 allow, exit 2 refuse (stderr shown).
set -uo pipefail

CONFIG="${HOME:-/nonexistent}/.himmel/config.json"
T3_SETTINGS="${T3CODE_HOME:-${HOME:-/nonexistent}/.t3}/userdata/settings.json"
REGISTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../himmelctl/lib/bypass-flags.json"

refuse() {
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

narrow="" narrow_err="" bypass='{}' settings_err=""
case "$findings" in
    instance$'\t'* | *$'\n'instance$'\t'*)
        if [ -L "${HOME:-/nonexistent}/.himmel" ] || [ -L "$CONFIG" ]; then
            narrow_err="$CONFIG is a symlink"
        elif [ -e "$CONFIG" ]; then
            if ! narrow=$(jq -c '.t3.instance_narrow' "$CONFIG" 2>&1); then
                narrow_err="$CONFIG is not JSON with an optional .t3.instance_narrow: $narrow" narrow=""
            elif [ "$narrow" = null ]; then
                narrow=""
            elif ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$narrow" >/dev/null 2>&1; then
                narrow="" narrow_err=".t3.instance_narrow in $CONFIG is not an array of strings"
            fi
        fi
        # swallow-ok: jq's error text can quote T3's settings values, which agents may not read; a failure refuses every instance id
        bypass=$(jq -c --slurpfile reg "$REGISTRY" '
            ([$reg[0].flags[].name | strings]) as $names
            | if type == "object" then . else error("the settings file is not an object") end
            | (if has("providerInstances") then .providerInstances else {} end)
            | if type == "object" then . else error("providerInstances is not an object") end
            | with_entries(
                .value as $o
                | .value = (if ($o | type) != "object" then ["a malformed instance entry"]
                  elif ($o.config != null and ($o.config | type) != "object") then ["a malformed instance config"]
                  else ($o.config // {}) as $c
                  | [
                    (($o.env, $o.environment, $c.env, $c.environment) | select(. != null)
                        | if type == "object" then keys[]
                          elif type == "array" then .[]
                            | if type == "object" then
                                (if (.name | type) == "string" then .name
                                 elif .name == null and (.key | type) == "string" then .key
                                 else "a malformed environment entry" end)
                              elif type == "string" then split("=")[0]
                              else "a malformed environment entry" end
                          else "a malformed environment entry" end
                        | select(. == "a malformed environment entry"
                            or (ascii_upcase | test("_OK$|BYPASS"))
                            or (. as $n | any($names[]; . == $n)))),
                    (($o.launchArgs, $c.launchArgs) | select(. != null)
                        | if type == "string" then
                            (match("dangerously-skip-permissions|bypassPermissions"; "gi").string | "launchArgs " + .)
                          else "malformed launchArgs" end)
                  ] | unique end))
            | with_entries(select(.value | length > 0))' "$T3_SETTINGS" 2>/dev/null) \
            || { bypass='{}' settings_err="T3's settings file $T3_SETTINGS or the bypass flag registry $REGISTRY could not be read"; }
        ;;
esac

bad_instances="" bad_titles=""
while IFS= read -r line; do
    case "$line" in
        instance$'\t'*)
            val=${line#instance$'\t'}
            case "$val" in
                'non-string '*) bad_instances="$bad_instances  ${val}: not a string instance id"$'\n'; continue ;;
            esac
            if [ -n "$settings_err" ]; then
                bad_instances="$bad_instances  ${val}: whether it carries a bypass flag is unknown ($settings_err)"$'\n'
                continue
            fi
            if ! flags=$(jq -rn --argjson m "$bypass" --argjson v "$val" '$m[$v] // [] | join(", ")' 2>&1); then
                bad_instances="$bad_instances  ${val}: whether it carries a bypass flag is unknown (the bypass lookup failed: ${flags%%$'\n'*})"$'\n'
                continue
            fi
            if [ -n "$flags" ]; then
                bad_instances="$bad_instances  ${val}: carries a himmel bypass flag (${flags})"$'\n'
            elif [ -n "$narrow_err" ]; then
                bad_instances="$bad_instances  ${val}: the narrowing list cannot be read ($narrow_err)"$'\n'
            elif [ -n "$narrow" ] && ! jq -en --argjson allow "$narrow" --argjson v "$val" '$allow | index([$v]) != null' >/dev/null 2>&1; then
                bad_instances="$bad_instances  ${val}: off .t3.instance_narrow in $CONFIG ($(jq -r 'map(tojson) | join(", ")' <<<"$narrow"))"$'\n'
            fi
            ;;
        title$'\t'*) bad_titles="$bad_titles  ${line#title$'\t'}"$'\n' ;;
    esac
done <<<"$findings"

if [ -n "$bad_instances" ]; then
    refuse "$tool on a provider instance an agent may not pick" "Refused instance id(s):
${bad_instances}A bypass instance (a T3 instance whose environment or launchArgs carry a himmel bypass flag) is never
picked by an agent: a hook bypass is granted per session, by the operator choosing that instance in the T3 UI,
never to every thread T3 starts. Every other instance is allowed, from any provider to any provider, unless
the operator narrows the list with .t3.instance_narrow in \$HOME/.himmel/config.json, an operator-owned file.
Omit the instance id to keep the thread's instance, or name an instance without a bypass flag."
fi
if [ -n "$bad_titles" ]; then
    refuse "$tool with a chief-shaped thread title" "Refused title(s):
${bad_titles}A T3 thread is named as a chief (a -chief or -console suffix) only by the operator in the T3 UI,
because the chief guards trust that name as the session's identity. Pick a title without that suffix."
fi
exit 0
