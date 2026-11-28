#!/usr/bin/env bash
# guard-t3-thread-tools.sh — PreToolUse hook on the T3 Code MCP tools (mcp__t3-code__* from
# Claude and Antigravity, mcp__t3_code__* and mcp__t3_code_direct__* from Codex): refuses
# a T3 Code tool call that names a bypass provider instance, or one off the
# optional narrowing list, or that sets a -chief or -console thread title.
#
# Bypass instance: an entry in T3's settings file
# (${T3CODE_HOME:-$HOME/.t3}/userdata/settings.json, .providerInstances) whose
# env / environment (on the instance or its config) names a *_OK or *BYPASS*
# variable (any case) or a flag in scripts/himmelctl/lib/bypass-flags.json, is
# malformed (entry, config, environment entry name or launchArgs), or whose launchArgs carry
# --dangerously-skip-permissions or bypassPermissions. A maintainer-profile instance
# (claudeAgent_maintainer-hooks or claudeAgent_maintainer-billed, each with an optional
# _relay suffix) is a bypass instance by id. Any other instance id is
# allowed, from any provider to any provider.
#
# Own settings: a Claude instance (driver claudeAgent, or no driver and an id of
# claudeAgent or claudeAgent_*) is refused unless each of its launchArgs and
# config.launchArgs is empty or exactly "--settings <D>/<h>/<n>.json", optionally
# followed by " --mcp-config <D>/mcp-<h2>/<n2>.mcp.json --strict-mcp-config", the
# line scripts/t3/provider-instances.sh writes. <D> is
# ${HIMMEL_PROFILE_SETTINGS_DIR:-$HOME/.himmel/launch-profiles}, matched as a string
# prefix and usable only when canonical (absolute, [A-Za-z0-9._/-], no //, no
# trailing /, no . or .. segment). For a named id each file must be a readable
# regular file whose sha256 starts with its <h>/<h2>. Rule own-settings-instance;
# a non-canonical <D> or no sha256 tool is own-settings-unverifiable. A <n> of
# maintainer-hooks or maintainer-billed (any case) is a maintainer instance.
# A refusal line prints a value only when it is a path, never inline JSON, a
# file's content or a flag's value.
#
# Narrowing: .t3.instance_narrow in $HOME/.himmel/config.json, an array of
# strings; an absent file or key narrows nothing. .t3.instance_allowlist is not read.
#
# Harness registry (scripts/harnesses): an instance outside delegatedFrom must
# resolve to a T3 driver with a complete descriptor. The driver is the settings
# entry's .driver, or the descriptor that names the id as a built-in.
#
# Security fence, fail-closed: missing jq, a payload that does not parse, an
# unreadable or malformed T3 settings file, bypass registry or harness registry,
# and a malformed or symlinked narrowing config are refused.
#
# Refusal row: each refusal appends one JSONL row (ts, host, guard, rule, instance,
# thread title; never a settings value) to ${HIMMEL_GUARD_REFUSALS_LOG:-
# ~/.himmel/state/guard-refusals.jsonl}. The write is fail-open and runs after the
# refusal is decided, so the exit code and stderr are unchanged.
#
# Bypass: T3_THREAD_TOOLS_OK=1 in the launching shell; the allow is printed to
# stderr.
#
# Hook I/O: JSON on stdin; exit 0 allow, exit 2 refuse (stderr shown).
set -uo pipefail

CONFIG="${HOME:-/nonexistent}/.himmel/config.json"
T3_SETTINGS="${T3CODE_HOME:-${HOME:-/nonexistent}/.t3}/userdata/settings.json"
REGISTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../himmelctl/lib/bypass-flags.json"
HARNESSES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../harnesses"

REFUSALS="${HIMMEL_GUARD_REFUSALS_LOG:-${HOME:-/nonexistent}/.himmel/state/guard-refusals.jsonl}"

record_refusal() {
    (
        umask 077
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
        { [ -r "$here/../lib/redact.sh" ] && . "$here/../lib/redact.sh"; } 2>/dev/null || exit 0
        command -v jq >/dev/null 2>&1 || exit 0
        title="$3"
        if [ -z "$title" ]; then
            title=$(jq -r '[.tool_input // {} | .. | objects | .title? | strings] | first // ""' <<<"$input" 2>/dev/null) || title="" # swallow-ok: a title that cannot be read is an empty field
        fi
        cap() { printf '%s' "$(redact "$1")" | tr '\n\r' '  ' | cut -c1-200; }
        mkdir -p "$(dirname "$REFUSALS")" || exit 0
        [ ! -e "$REFUSALS" ] || [ -f "$REFUSALS" ] || exit 0
        host=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown) # swallow-ok: the host is a label, unknown stands in
        jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$host" \
            --arg rule "$1" --arg instance "$(cap "$2")" --arg title "$(cap "$title")" \
            '{v:1, ts:$ts, host:$host, source:"guard-t3-thread-tools", kind:"refusal", guard:"guard-t3-thread-tools", rule:$rule, instance:$instance, title:$title}' >>"$REFUSALS"
    ) >/dev/null 2>&1 || true
}

refuse() {
    if [ "${T3_THREAD_TOOLS_OK:-0}" = "1" ]; then
        echo "guard-t3-thread-tools: override: allowed $1 (T3_THREAD_TOOLS_OK=1)" >&2
        exit 0
    fi
    record_refusal "$3" "${4:-}" "${5:-}"
    printf 'BLOCKED: guard-t3-thread-tools refused %s.\n%s\nBypass (operator only): relaunch from a shell with T3_THREAD_TOOLS_OK=1 (the allow is printed to stderr).\n' "$1" "$2" >&2
    exit 2
}

input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' returns 1 at EOF by design

command -v jq >/dev/null 2>&1 \
    || refuse "a T3 tool call" "jq is not on PATH, so the tool input cannot be checked for a provider instance or a chief title." no-jq

# swallow-ok: a failed parse refuses on the next line
tool=$(jq -er '.tool_name | strings' <<<"$input" 2>/dev/null) \
    || refuse "a T3 tool call" "The hook input is not JSON with a string tool_name, so it cannot be checked." bad-payload
T3_TOOL_PREFIXES="mcp__t3-code__ mcp__t3_code__ mcp__t3_code_direct__"
judged=0
for p in $T3_TOOL_PREFIXES; do
    case "$tool" in "$p"*) judged=1; break ;; esac
done
[ "$judged" = 1 ] || exit 0

findings=$(jq -r '
    def key_is($names): ascii_downcase | gsub("_"; "") as $k | any($names[]; . == $k);
    def walk_pairs($df):
        if type == "object" then
            to_entries[] | (.key | ascii_downcase == "delegatedfrom") as $d
            | {key, value, df: $df}, (.value | walk_pairs($df or $d))
        elif type == "array" then .[] | walk_pairs($df)
        else empty end;
    [.tool_input // {} | walk_pairs(false)] as $pairs
    | ($pairs[] | select(.key | key_is(["instanceid", "providerinstanceid"])) | .df as $df | .value
        | select(. != null) | (if $df then "source\t" else "instance\t" end) + (if type == "string" then tojson else "non-string " + tojson end)),
      ($pairs[] | select((.df | not) and (.key | ascii_downcase == "title")) | .value | strings
        | select(gsub("^\\s+|\\s+$"; "") | ascii_downcase | test("-(chief|console)$")) | "title\t" + tojson)
' <<<"$input" 2>/dev/null) \
    || refuse "$tool" "Its tool_input could not be walked, so it cannot be checked." walk-failed
[ -n "$findings" ] || exit 0

narrow="" narrow_err="" bypass='{}' settings_err="" drivers='{}' harnesses='[]' harness_err=""
case "$findings" in
    instance$'\t'* | *$'\n'instance$'\t'* | source$'\t'* | *$'\n'source$'\t'*)
        harness_args=()
        for f in "$HARNESSES"/*.json; do harness_args+=(--rawfile "${f##*/}" "$f"); done
        if ! harnesses=$(jq -nc "${harness_args[@]}" --arg out registry -f "$HARNESSES/registry.jq" 2>&1) \
            || ! jq -e 'type == "array" and length > 0' <<<"$harnesses" >/dev/null 2>&1; then
            harness_err="the harness registry cannot be read: ${harnesses:-the loader returned nothing}" harnesses='[]'
        fi
        if [ -L "${HOME:-/nonexistent}/.himmel" ] || [ -L "$CONFIG" ]; then
            narrow_err="$CONFIG is a symlink"
        elif [ -e "$CONFIG" ]; then
            if ! narrow=$(jq -cs 'if length != 1 then error("not one JSON document") else .[0] end | if .t3 == null or (.t3 | has("instance_narrow") | not) then empty else .t3.instance_narrow end' "$CONFIG" 2>&1); then
                narrow_err="$CONFIG is not JSON with an optional .t3.instance_narrow: $narrow" narrow=""
            elif [ -z "$narrow" ]; then
                :
            elif ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$narrow" >/dev/null 2>&1; then
                narrow="" narrow_err=".t3.instance_narrow in $CONFIG is not an array of strings"
            fi
        fi
        if [ -n "${HIMMEL_PROFILE_SETTINGS_DIR:-}" ]; then profile_dir="$HIMMEL_PROFILE_SETTINGS_DIR"
        elif [ -n "${HOME:-}" ]; then profile_dir="$HOME/.himmel/launch-profiles"
        else profile_dir=""; fi
        # swallow-ok: jq's error text can quote T3's settings values, which agents may not read; a failure refuses every instance id
        bypass=$(jq -c --slurpfile reg "$REGISTRY" --arg D "$profile_dir" '
            def shown: if test("\\A(/|~/|\\.)") and test("\\A[A-Za-z0-9._/~-]{1,200}\\z") then . else "a value that is not a path" end;
            def own($text): {rule: "own-settings-instance", text: ("carries settings of its own in its launchArgs (" + $text + ")")};
            ($D | test("\\A/[A-Za-z0-9._/-]*\\z") and (test("//|/\\z|/\\.\\.?(/|\\z)") | not)) as $dok
            | ($D + "/") as $Dp
            | def under($re): type == "string" and startswith($Dp) and (.[($Dp | length):] | test($re));
              def pfile: under("\\A[0-9a-f]{12}/[A-Za-z0-9._-]+\\.json\\z");
              def mfile: under("\\Amcp-[0-9a-f]{12}/[A-Za-z0-9._-]+\\.mcp\\.json\\z");
              def classify:
                if . == "" then {own: [], files: []}
                elif test("--settings") and contains("{") then {own: [own("inline settings JSON")], files: []}
                elif ($dok | not) and test("--settings") then
                    {own: [{rule: "own-settings-unverifiable", text: "whether its settings files are resolved profile files is unknown (the profile settings directory is not a canonical absolute path)"}], files: []}
                else split(" ") as $t
                | if (($t | length) == 2 and $t[0] == "--settings" and ($t[1] | pfile))
                     or (($t | length) == 5 and $t[0] == "--settings" and ($t[1] | pfile) and $t[2] == "--mcp-config"
                         and ($t[3] | mfile) and $t[4] == "--strict-mcp-config") then
                    {own: [], files: ([{flag: "--settings", path: $t[1], shown: ($t[1] | shown), hash: $t[1][($Dp | length):][0:12],
                                        name: ($t[1] | split("/")[-1] | rtrimstr(".json"))}]
                                      + (if ($t | length) == 5 then [{flag: "--mcp-config", path: $t[3], shown: ($t[3] | shown),
                                          hash: $t[3][($Dp | length) + 4:][0:12], name: ""}] else [] end))}
                  else
                    ([range(0; $t | length) as $i
                      | if $t[$i] == "--settings" then ($t[$i + 1] // "")
                        elif ($t[$i] | startswith("--settings=")) then $t[$i][11:]
                        else empty end
                      | select(pfile | not)] | first) as $bad
                    | if $bad != null then
                        {own: [own("--settings " + ($bad | shown) + ": not a resolved profile file under " + ($D | shown))], files: []}
                      else
                        ([$t[] | select(startswith("--") and (IN("--settings", "--mcp-config", "--strict-mcp-config") | not))
                           | ((capture("\\A(?<f>--[A-Za-z0-9-]+)").f) // "an extra argument")]
                         + ([range(0; $t | length) as $i | select($t[$i] == "--mcp-config") | ($t[$i + 1] // "") | select(mfile | not)]
                            | if length > 0 then ["--mcp-config"] else [] end)
                         | unique | if length == 0 then ["an extra argument"] else . end) as $out
                        | {own: [own("launchArgs not in the resolved-profile shape: " + ($out | join(", ")))], files: []}
                      end
                  end
                end;
            ([$reg[0].flags | if type == "array" then .[] else error("the bypass flag registry flags is not an array") end
              | if (.name | type) == "string" then .name
                else error("a bypass flag registry entry has no string name") end]) as $names
            | if type == "object" then . else error("the settings file is not an object") end
            | (if has("providerInstances") then .providerInstances else {} end)
            | if type == "object" then . else error("providerInstances is not an object") end
            | with_entries(
                .value as $o | .key as $id
                | .value = (if ($o | type) != "object" then {flags: ["a malformed instance entry"]}
                  elif ($o.config != null and ($o.config | type) != "object") then {flags: ["a malformed instance config"]}
                  else ($o.config // {}) as $c
                  | (if (if $o | has("driver") then $o.driver == "claudeAgent" else ($id == "claudeAgent" or ($id | startswith("claudeAgent_"))) end)
                     then [($o.launchArgs, $c.launchArgs) | strings | classify] else [] end) as $cls
                  | {own: ([$cls[].own[]] | unique), files: ([$cls[].files[]] | unique), flags: (
                    [
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
                  ] | unique)} end))
            | with_entries(select(.value | (.flags // []) + (.own // []) + (.files // []) | length > 0))' "$T3_SETTINGS" 2>/dev/null) \
            || { bypass='{}' settings_err="T3's settings file $T3_SETTINGS or the bypass flag registry $REGISTRY could not be read"; }
        # swallow-ok: jq's error text can quote T3's settings values; a failure refuses every instance id
        if ! drivers=$(jq -c '(.providerInstances // {}) | with_entries(.value |= (if type == "object" then .driver else null end))' "$T3_SETTINGS" 2>/dev/null) \
            || [ -z "$drivers" ]; then
            drivers='{}'
            [ -n "$settings_err" ] || [ -z "$bypass" ] || settings_err="the drivers in T3's settings file $T3_SETTINGS could not be read"
        fi
        ;;
esac

sha256_12() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-12; }
bad_instances="" bad_titles="" bad_rules="" bad_ids="" bad_title_vals=""
note_rule() { bad_rules="$bad_rules$1"$'\n'; }
note_id() {
    local d
    d=$(jq -rn --argjson v "$1" '$v | if type == "string" then . else tojson end' 2>/dev/null) || d="" # swallow-ok: an id that cannot be decoded is left out of the row only
    bad_ids="$bad_ids${bad_ids:+,}$d"
}
while IFS= read -r line; do
    case "$line" in
        instance$'\t'* | source$'\t'*)
            role=${line%%$'\t'*}
            val=${line#*$'\t'}
            case "$val" in
                'non-string '*) bad_instances="$bad_instances  ${val}: not a string instance id"$'\n'; note_rule non-string-instance; note_id "${val#non-string }"; continue ;;
            esac
            if jq -en --argjson v "$val" '$v | test("^claudeAgent_maintainer-(hooks|billed)(_relay)?$")' >/dev/null 2>&1; then
                bad_instances="$bad_instances  ${val}: is a maintainer-profile instance (its hook bypass rides the profile's settings file)"$'\n'
                note_rule maintainer-instance; note_id "$val"
                continue
            fi
            if [ -n "$settings_err" ]; then
                bad_instances="$bad_instances  ${val}: whether it carries a bypass flag is unknown ($settings_err)"$'\n'
                note_rule settings-unreadable; note_id "$val"
                continue
            fi
            if ! entry=$(jq -cn --argjson m "$bypass" --argjson v "$val" '$m[$v] // {} | {flags: (.flags // []), own: (.own // []), files: (.files // [])}' 2>&1); then
                bad_instances="$bad_instances  ${val}: whether it carries a bypass flag is unknown (the bypass lookup failed: ${entry%%$'\n'*})"$'\n'
                note_rule bypass-lookup-failed; note_id "$val"
                continue
            fi
            maint=$(jq -r '[.files[].name | ascii_downcase | select(. == "maintainer-hooks" or . == "maintainer-billed")] | first // ""' <<<"$entry")
            if [ -n "$maint" ]; then
                bad_instances="$bad_instances  ${val}: is a maintainer-profile instance (its launchArgs point at the $maint resolved file)"$'\n'
                note_rule maintainer-instance; note_id "$val"
                continue
            fi
            flags=$(jq -r '.flags | join(", ")' <<<"$entry")
            own_lines=""
            while IFS=$'\t' read -r o_rule o_text; do
                [ -n "$o_rule" ] || continue
                own_lines="$own_lines  ${val}: $o_text"$'\n'
                note_rule "$o_rule"
            done <<<"$(jq -r '.own[] | [.rule, .text] | @tsv' <<<"$entry")"
            while IFS=$'\t' read -r f_flag f_path f_shown f_hash; do
                [ -n "$f_flag" ] || continue
                if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
                    own_lines="$own_lines  ${val}: whether its settings files are resolved profile files is unknown (no sha256 tool)"$'\n'
                    note_rule own-settings-unverifiable
                    break
                fi
                if [ ! -f "$f_path" ] || [ ! -r "$f_path" ] || ! f_got=$(sha256_12 <"$f_path") || [ -z "$f_got" ]; then
                    own_lines="$own_lines  ${val}: carries settings of its own in its launchArgs ($f_flag $f_shown: the file cannot be read)"$'\n'
                    note_rule own-settings-instance
                elif [ "$f_got" != "$f_hash" ]; then
                    own_lines="$own_lines  ${val}: carries settings of its own in its launchArgs ($f_flag $f_shown: its content does not match its resolved hash)"$'\n'
                    note_rule own-settings-instance
                fi
            done <<<"$(jq -r '.files[] | [.flag, .path, .shown, .hash] | @tsv' <<<"$entry")"
            if [ -n "$flags" ] || [ -n "$own_lines" ]; then
                [ -z "$flags" ] || { bad_instances="$bad_instances  ${val}: carries a himmel bypass flag (${flags})"$'\n'; note_rule bypass-instance; }
                bad_instances="$bad_instances$own_lines"
                note_id "$val"
            elif [ -n "$narrow_err" ]; then
                bad_instances="$bad_instances  ${val}: the narrowing list cannot be read ($narrow_err)"$'\n'
                note_rule narrow-config-unreadable; note_id "$val"
            elif [ -n "$narrow" ] && ! jq -en --argjson allow "$narrow" --argjson v "$val" '$allow | index([$v]) != null' >/dev/null 2>&1; then
                bad_instances="$bad_instances  ${val}: off .t3.instance_narrow in $CONFIG ($(jq -r 'map(tojson) | join(", ")' <<<"$narrow"))"$'\n'
                note_rule off-narrow; note_id "$val"
            elif [ -n "$harness_err" ]; then
                bad_instances="$bad_instances  ${val}: $harness_err"$'\n'
                note_rule harness-registry-unreadable; note_id "$val"
            elif [ "$role" = instance ]; then
                if ! why=$(jq -rn --argjson reg "$harnesses" --argjson drv "$drivers" --argjson v "$val" '
                    (if ($drv | has($v)) then $drv[$v]
                     else [$reg[] | select(any(.t3.instance_ids[]; . == $v)) | .t3.driver] | first end) as $d
                    | if ($d | type) != "string" then "no T3 driver is known for it"
                      else ([$reg[] | select(.t3.driver == $d)] | first) as $h
                        | if $h == null then "its driver \($d) has no harness descriptor"
                          elif $h.launchable then ""
                          else "its driver \($d) has an incomplete harness descriptor (\($h.id).json)" end
                      end' 2>&1); then
                    why="its harness descriptor lookup failed: ${why%%$'\n'*}"
                fi
                if [ -n "$why" ]; then
                    bad_instances="$bad_instances  ${val}: $why"$'\n'
                    note_rule no-complete-descriptor; note_id "$val"
                fi
            fi
            ;;
        title$'\t'*)
            bad_titles="$bad_titles  ${line#title$'\t'}"$'\n'
            t=$(jq -rn --argjson v "${line#title$'\t'}" '$v' 2>/dev/null) || t="" # swallow-ok: a title that cannot be decoded is left out of the row only
            bad_title_vals="$bad_title_vals${bad_title_vals:+, }$t"
            ;;
    esac
done <<<"$findings"

if [ -n "$bad_instances" ]; then
    refuse "$tool on a provider instance an agent may not pick" "Refused instance id(s):
${bad_instances}A bypass instance (a T3 instance whose environment or launchArgs carry a himmel bypass flag) is never
picked by an agent: a hook bypass is granted per session, by the operator choosing that instance in the T3 UI,
never to every thread T3 starts. A Claude instance whose launch line carries settings that are not a resolved profile file
is refused the same way, and the operator still picks it in the T3 UI. An agent launches only onto a T3 driver that has a complete descriptor in
himmel's scripts/harnesses. Every other instance is allowed, from any provider to any provider, unless
the operator narrows the list with .t3.instance_narrow in \$HOME/.himmel/config.json, an operator-owned file.
Omit the instance id to keep the thread's instance, or name an instance without a bypass flag." \
        "$(printf '%s' "$bad_rules" | sort -u | tr '\n' ',' | sed 's/,$//')" "$bad_ids"
fi
if [ -n "$bad_titles" ]; then
    refuse "$tool with a chief-shaped thread title" "Refused title(s):
${bad_titles}A T3 thread is named as a chief (a -chief or -console suffix) only by the operator in the T3 UI,
because the chief guards trust that name as the session's identity. Pick a title without that suffix." chief-title "" "$bad_title_vals"
fi
exit 0
