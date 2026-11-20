#!/usr/bin/env bash
# scripts/t3/provider-instances.sh - make every himmel launch profile a T3 Code
# provider instance (claudeAgent_<profile>) in a T3 settings file.
#
# Usage: provider-instances.sh [--dry-run | --apply] --settings-file <path>
#   --dry-run  (default) print a diff of providerInstances against <path>, then the
#              allowlist ids to add to .t3.instance_allowlist in ~/.himmel/config.json.
#   --apply    back <path> up to <path>.bak.<UTC stamp>, then replace it atomically.
# rc 0 ok; rc 2 usage / unreadable or malformed settings file / resolver failure;
# rc 3 an instance environment entry names a himmel guard bypass flag (nothing written).
#
# Per profile: --settings <stable path from scripts/lanes/profile-settings.sh>, plus
# --mcp-config <file> --strict-mcp-config when the profile declares an mcpServers allowlist.
# A profile already reachable through another instance (same <profile>.json in a launchArgs)
# gets no new id; existing instances are never edited except a claudeAgent_<profile> whose
# stable path moved. This script never writes ~/.himmel/config.json: it prints the ids.
# Env seams (tests): T3_PI_RESOLVER (resolver script), T3_PI_PROFILES (comma list),
# T3_PI_EMPTY_OK (comma list of profiles that resolve to no settings; default "operator").
# Platform: POSIX bash 3.2+, jq, node (default resolver).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RESOLVER="${T3_PI_RESOLVER:-$HERE/../lanes/profile-settings.sh}"
EMPTY_OK=",${T3_PI_EMPTY_OK:-operator},"
MODE=dry-run
FILE=""
die() { echo "provider-instances: $2" >&2; exit "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE=dry-run; shift ;;
        --apply) MODE=apply; shift ;;
        --settings-file) [ $# -ge 2 ] || die 2 "--settings-file needs a path"; FILE="$2"; shift 2 ;;
        *) die 2 "usage: provider-instances.sh [--dry-run | --apply] --settings-file <path> (got '$1')" ;;
    esac
done
[ -n "$FILE" ] || die 2 "--settings-file <path> is required"
[ -f "$FILE" ] || die 2 "settings file not found: $FILE"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"
jq -e 'type == "object" and ((.providerInstances // {}) | type == "object")' "$FILE" >/dev/null 2>&1 \
    || die 2 "settings file is not a JSON object with an object providerInstances (left untouched): $FILE"

if [ -n "${T3_PI_PROFILES:-}" ]; then
    PROFILES="$(printf '%s' "$T3_PI_PROFILES" | tr ',' '\n')"
else
    PROFILES="$(cd "$HERE/../.." && node scripts/lanes/plugin-profiles.mjs --list)" || die 2 "cannot list profiles"
fi

# Bypass-flag refusal: any env/environment entry named *_OK or *BYPASS*, in the final document.
# shellcheck disable=SC2016  # jq program: $id is a jq variable
BYPASS_JQ='[ .providerInstances // {} | to_entries[] | .key as $id | (.value.config // {}) | (.env // .environment // empty)
  | (if type == "object" then keys[] elif type == "array" then .[] | (if type == "object" then (.name // .key // "") else (split("=")[0]) end) else empty end)
  | select(test("_OK$") or test("BYPASS"; "i")) | "\($id): \(.)" ] | .[]'

GEN='{}'
for p in $PROFILES; do
    case "$p" in ''|*[!A-Za-z0-9._-]*) die 2 "bad profile name '$p'" ;; esac
    if ! sp="$("$RESOLVER" "$p" 2>/dev/null)" || [ -z "$sp" ]; then
        case "$EMPTY_OK" in *",$p,"*) echo "provider-instances: skip '$p' (resolves to no settings file)" >&2; continue ;; esac
        die 2 "profile '$p' did not resolve to a settings file"
    fi
    mp="$("$RESOLVER" "$p" --mcp-config 2>/dev/null)" || die 2 "profile '$p' mcp-config did not resolve"
    args="--settings $sp"
    [ -n "$mp" ] && args="$args --mcp-config $mp --strict-mcp-config"
    GEN="$(printf '%s' "$GEN" | jq --arg p "$p" --arg a "$args" '.[$p] = $a')" || die 2 "jq failed"
done

NEW="$(jq --argjson gen "$GEN" '
  def basenames: (.config.launchArgs // "") | [scan("--settings ([^ ]+)")[0] | split("/")[-1]];
  . as $doc
  | (.providerInstances // {}) as $pi
  | reduce ($gen | keys_unsorted[]) as $p (.;
      ("claudeAgent_" + $p) as $id
      | (($pi | to_entries | map(select(.key != $id) | .value | basenames | index($p + ".json")) | any)) as $covered
      | if $covered then .
        else .providerInstances[$id] = (($pi[$id] // {"driver":"claudeAgent","displayName":("Claude (" + $p + ")"),"enabled":true})
              | .config = ((.config // {}) + {launchArgs: $gen[$p]}))
        end)' "$FILE")" || die 2 "merge failed"

BAD="$(printf '%s' "$NEW" | jq -r "$BYPASS_JQ")"
if [ -n "$BAD" ]; then
    echo "provider-instances: REFUSED - an instance environment names a himmel guard bypass flag:" >&2
    printf '%s\n' "$BAD" >&2
    exit 3
fi

# prim-ok: scratch diff dir removed by the EXIT trap below
WORK="$(mktemp -d "${TMPDIR:-/tmp}/t3pi.XXXXXX")" || die 2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
jq -S '.' "$FILE" > "$WORK/before.json"
printf '%s' "$NEW" | jq -S '.' > "$WORK/after.json"
if cmp -s "$WORK/before.json" "$WORK/after.json"; then
    echo "provider-instances: $FILE already carries every profile instance (no change)"
else
    diff -u --label "$FILE (current)" --label "$FILE (proposed)" "$WORK/before.json" "$WORK/after.json"
fi

echo ""
echo "# add to .t3.instance_allowlist in ~/.himmel/config.json (operator-only):"
for p in $(printf '%s' "$GEN" | jq -r 'keys_unsorted[]'); do
    id="claudeAgent_$p"
    printf '%s' "$NEW" | jq -e --arg id "$id" '.providerInstances | has($id)' >/dev/null 2>&1 && echo "$id"
done

if [ "$MODE" = apply ] && ! cmp -s "$WORK/before.json" "$WORK/after.json"; then
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    BAK="$FILE.bak.$STAMP"
    cp -p "$FILE" "$BAK" || die 2 "cannot write backup $BAK"
    TMP="$FILE.tmp.$$"
    # prim-ok: temp lives beside the target and is renamed over it (same-filesystem atomic replace)
    if ! printf '%s' "$NEW" | jq '.' > "$TMP" || ! mv -f "$TMP" "$FILE"; then
        rm -f "$TMP"
        die 2 "cannot replace $FILE (backup kept at $BAK)"
    fi
    echo "provider-instances: applied; backup at $BAK" >&2
fi
exit 0
