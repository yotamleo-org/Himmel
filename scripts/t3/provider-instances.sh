#!/usr/bin/env bash
# scripts/t3/provider-instances.sh - make every himmel launch profile a T3 Code
# provider instance (claudeAgent_<profile>) in a T3 settings file.
#
# Usage: provider-instances.sh [--dry-run | --apply] --settings-file <path>
#   --dry-run  (default) print a diff of providerInstances against <path>, then the
#              allowlist ids to add to .t3.instance_allowlist in ~/.himmel/config.json.
#   --apply    back <path> up to <path>.bak.<UTC stamp>, then replace it atomically.
# rc 0 ok; rc 2 usage / unreadable or malformed settings file / resolver failure;
# rc 3 an instance environment entry names a himmel guard bypass flag, or an instance's
# launchArgs carry a permission-bypass flag (nothing written).
# Env seams (tests): T3_PI_RESOLVER (resolver script), T3_PI_PROFILES (comma list),
# T3_PI_EMPTY_OK (comma list of profiles that resolve to no settings; default "operator"; each
# gets an instance carrying only the resolver's default Artifact deny, as does the built-in
# "claudeAgent" instance).
# Relay copies: .t3.relay_instances in $HOME/.himmel/config.json (absent or [] = none) adds
# "<id>_relay" beside each listed instance; T3_PI_BUILTIN_RELAY=1 also lets the built-in
# "codex" (no entry) get a driver-only copy.
# Antigravity: antigravity_<p> (driver antigravity) is added for each profile that
# antigravity-profiles.sh --list names, only when `T3CODE_HOME=<settings file's T3 home> ... --check
# --profile <p>` exits 0 with "OK antigravity_<p>". rc 1 with "NOT OK antigravity_<p>..." adds nothing;
# any other outcome, or a failed --list, writes nothing and exits 2. Existing antigravity entries
# are never edited, and no "_relay" copy is made of any antigravity_* id. Seam: T3_PI_AGY_PROFILES (the script).
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

# prim-ok: scratch dir removed by the EXIT trap below
WORK="$(mktemp -d "${TMPDIR:-/tmp}/t3pi.XXXXXX")" || die 2 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

AGY_SCRIPT="${T3_PI_AGY_PROFILES:-$HERE/antigravity-profiles.sh}"
AGY_ADD='{}'
if ! AGY_LIST="$(bash "$AGY_SCRIPT" --list 2>"$WORK/agy.err")"; then
    cat "$WORK/agy.err" >&2
    die 2 "$AGY_SCRIPT --list failed; nothing written"
fi
AGY_X=""
if [ -n "$AGY_LIST" ]; then
    agy_dir="$(cd "$(dirname "$FILE")" && pwd)" || die 2 "cannot resolve the directory of $FILE"
    case "$agy_dir" in */userdata) AGY_X="${agy_dir%/userdata}" ;; esac
    [ -n "$AGY_X" ] || echo "provider-instances: warning: $FILE is not <T3 home>/userdata/<file>; no Antigravity instance is added or checked" >&2
fi
for p in $AGY_LIST; do
    case "$p" in ''|*[!A-Za-z0-9._-]*) die 2 "bad Antigravity profile name '$p'" ;; esac
    [ -n "$AGY_X" ] || continue
    agy_have="$(jq -r --arg i "antigravity_$p" '(.providerInstances // {}) | has($i)' "$FILE")" || die 2 "jq failed"
    agy_out="$(T3CODE_HOME="$AGY_X" bash "$AGY_SCRIPT" --check --profile "$p" 2>"$WORK/agy.err")"; agy_rc=$?
    agy_first="${agy_out%%$'\n'*}"
    if [ "$agy_rc" = 0 ] && [ "$agy_out" = "OK antigravity_$p" ]; then
        AGY_ADD="$(printf '%s' "$AGY_ADD" | jq --arg i "antigravity_$p" --arg n "Antigravity ($p)" \
            '.[$i] = {"driver":"antigravity","displayName":$n,"enabled":true}')" || die 2 "jq failed"
    elif [ "$agy_rc" = 1 ] && case "$agy_first" in "NOT OK antigravity_$p"|"NOT OK antigravity_$p;"*) true ;; *) false ;; esac; then
        if [ "$agy_have" = true ]; then
            echo "provider-instances: antigravity_$p: home is stale, run --apply" >&2
        elif command -v agy >/dev/null 2>&1 || [ -d "$AGY_X/userdata/providers/antigravity" ]; then
            echo "provider-instances: antigravity_$p skipped, home not ready (run: bash scripts/t3/antigravity-profiles.sh --apply --profile $p)" >&2
        else
            echo "provider-instances: antigravity_$p: not provisioned" >&2
        fi
    else
        cat "$WORK/agy.err" >&2
        [ -z "$agy_out" ] || printf '%s\n' "$agy_out" >&2
        die 2 "antigravity_$p: the check ended rc=$agy_rc with neither OK nor NOT OK; nothing written"
    fi
done

# shellcheck disable=SC2016
BYPASS_JQ='[ .providerInstances // {} | to_entries[] | .key as $id | .value as $v | ($v.config // {}) as $c
  | ( ( ($v.env, $v.environment, $c.env, $c.environment) | select(. != null)
        | (if type == "object" then keys[] elif type == "array" then .[] | (if type == "object" then (.name // .key // "") else (split("=")[0]) end) else empty end)
        | select(test("_OK$") or test("BYPASS"; "i")) )
      , ( ($c.launchArgs // "") | select(test("dangerously-skip-permissions|bypassPermissions"; "i")) | "launchArgs" ) )
  | "\($id): \(.)" ] | .[]'

DENY_JSON="$(cd "$HERE/../.." && node --input-type=module -e "
import { resolveProfile } from './scripts/lanes/plugin-profiles.mjs';
console.log(JSON.stringify({ permissions: resolveProfile({ profiles: { x: {} } }, 'x').permissions }));
" 2>/dev/null)" || die 2 "cannot resolve the default Artifact deny"
case "$DENY_JSON" in '{"permissions":{"deny":['*) ;; *) die 2 "the resolver default carries no deny list: $DENY_JSON" ;; esac
if command -v sha256sum >/dev/null 2>&1; then DENY_HASH="$(printf '%s\n' "$DENY_JSON" | sha256sum | cut -c1-12)"
else DENY_HASH="$(printf '%s\n' "$DENY_JSON" | shasum -a 256 | cut -c1-12)"; fi
DENY_DIR="${HIMMEL_PROFILE_SETTINGS_DIR:-$HOME/.himmel/launch-profiles}/$DENY_HASH"
DENY_FILE="$DENY_DIR/artifact-deny.json"
case "$DENY_FILE" in *[[:space:]]*) die 2 "default deny settings path has whitespace; launchArgs would split it: $DENY_FILE" ;; esac
mkdir -p "$DENY_DIR" 2>/dev/null || die 2 "cannot create $DENY_DIR"
if ! printf '%s\n' "$DENY_JSON" > "$DENY_FILE.tmp.$$" || ! mv -f "$DENY_FILE.tmp.$$" "$DENY_FILE"; then
    rm -f "$DENY_FILE.tmp.$$"
    die 2 "cannot write $DENY_FILE"
fi
DENY_ARGS="--settings $DENY_FILE"

SUM_READ="$(cksum < "$FILE")"
GEN='{}'
for p in $PROFILES; do
    case "$p" in ''|*[!A-Za-z0-9._-]*) die 2 "bad profile name '$p'" ;; esac
    if ! sp="$("$RESOLVER" "$p" 2>/dev/null)" || [ -z "$sp" ]; then
        case "$EMPTY_OK" in
            *",$p,"*)
                echo "provider-instances: '$p' resolves to no settings file; its instance carries the default Artifact deny only" >&2
                GEN="$(printf '%s' "$GEN" | jq --arg p "$p" --arg a "$DENY_ARGS" '.[$p] = $a')" || die 2 "jq failed"
                continue ;;
        esac
        die 2 "profile '$p' did not resolve to a settings file"
    fi
    mp="$("$RESOLVER" "$p" --mcp-config 2>/dev/null)" || die 2 "profile '$p' mcp-config did not resolve"
    case "$sp$mp" in *[[:space:]]*) die 2 "profile '$p' resolved to a path with whitespace; launchArgs would split it" ;; esac
    args="--settings $sp"
    [ -n "$mp" ] && args="$args --mcp-config $mp --strict-mcp-config"
    GEN="$(printf '%s' "$GEN" | jq --arg p "$p" --arg a "$args" '.[$p] = $a')" || die 2 "jq failed"
done

OWNED_RE='^--settings [^ ]*/[0-9a-f]{12}/artifact-deny\.json$'
USER_ARGS="$(jq -r --arg re "$OWNED_RE" '(.providerInstances.claudeAgent.config.launchArgs // "") | if . == "" or test($re) then "" else . end' "$FILE")" || die 2 "jq failed"
[ -z "$USER_ARGS" ] || echo "provider-instances: claudeAgent carries its own launchArgs; left alone, so the default Artifact deny is not added to it" >&2

NEW="$(jq --argjson gen "$GEN" --arg deny "$DENY_ARGS" --arg re "$OWNED_RE" '
  def basenames: (.config.launchArgs // "") | [scan("--settings ([^ ]+)")[0] | split("/")[-1]];
  . as $doc
  | (.providerInstances // {}) as $pi
  | reduce ($gen | keys_unsorted[]) as $p (.;
      ("claudeAgent_" + $p) as $id
      | (($pi | to_entries | map(select(.key != $id and .key != "claudeAgent" and (.key | endswith("_relay") | not)) | .value | basenames | index($p + ".json")) | any)) as $covered
      | if $covered then .
        else .providerInstances[$id] = (($pi[$id] // {"driver":"claudeAgent","displayName":("Claude (" + $p + ")"),"enabled":true})
              | .config = ((.config // {}) + {launchArgs: $gen[$p]}))
        end)
  | .providerInstances.claudeAgent = ((.providerInstances.claudeAgent // {"driver":"claudeAgent","displayName":"Claude","enabled":true})
        | if ((.config.launchArgs // "") == "" or ((.config.launchArgs // "") | test($re)))
          then .config = ((.config // {}) + {launchArgs: $deny}) else . end)' "$FILE")" || die 2 "merge failed"
NEW="$(printf '%s' "$NEW" | jq --argjson add "$AGY_ADD" '
  reduce ($add | keys_unsorted[]) as $id (.; if ((.providerInstances // {}) | has($id)) then . else .providerInstances[$id] = $add[$id] end)')" \
    || die 2 "antigravity merge failed"

RELAY='[]'
CFG="$HOME/.himmel/config.json"
if [ -f "$CFG" ]; then
    RELAY="$(jq -c '(.t3.relay_instances // []) | if type == "array" then map(select(type == "string")) else [] end' "$CFG" 2>/dev/null)" \
        || { echo "provider-instances: warning: $CFG is not readable; no relay copies" >&2; RELAY='[]'; }
fi
RELAY_PLAN="$(printf '%s' "$NEW" | jq -r --argjson ids "$RELAY" --arg bi "${T3_PI_BUILTIN_RELAY:-0}" '
  (.providerInstances // {}) as $pi
  | $ids[] | if (test("^[A-Za-z0-9._-]+$") | not) or endswith("_relay") then "unknown\t" + (gsub("[^A-Za-z0-9._-]"; "?"))
             elif startswith("antigravity_") then "skip-agy\t" + .
             elif ($pi[.] | type) == "object" then "copy\t" + .
             elif . == "codex" then (if $bi == "1" then "copy\t" + . else "skip-builtin\t" + . end)
             else "unknown\t" + . end')" || die 2 "relay plan failed"
COPIES='[]'
while IFS=$'\t' read -r kind rid; do
    case "$kind" in
        copy) COPIES="$(printf '%s' "$COPIES" | jq -c --arg i "$rid" '. + [$i]')" || die 2 "jq failed" ;;
        skip-builtin) echo "provider-instances: skip relay copy of built-in '$rid': T3 is not shown to accept a driver-only entry (T3_PI_BUILTIN_RELAY=1 forces it)" >&2 ;;
        skip-agy) echo "provider-instances: skip relay copy of '$rid': an Antigravity profile instance gets no relay copy (its '${rid}_relay' home would be one no check passed)" >&2 ;;
        unknown) echo "provider-instances: skip relay id '$rid': no such provider instance" >&2 ;;
    esac
done <<EOF
$RELAY_PLAN
EOF
NEW="$(printf '%s' "$NEW" | jq --argjson ids "$COPIES" '
  reduce $ids[] as $id (.;
    .providerInstances[$id + "_relay"] =
      ((.providerInstances[$id] // {"driver": $id}) | .enabled = true | .displayName = ((.displayName // $id) + " + chief relay")))')" \
    || die 2 "relay merge failed"

BAD="$(printf '%s' "$NEW" | jq -r "$BYPASS_JQ")" || die 2 "bypass-flag check could not run (left untouched)"
if [ -n "$BAD" ]; then
    echo "provider-instances: REFUSED - an instance environment names a himmel guard bypass flag:" >&2
    printf '%s\n' "$BAD" >&2
    exit 3
fi

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
for rid in $(printf '%s' "$COPIES" | jq -r '.[]'); do
    echo "${rid}_relay"
done

if [ "$MODE" = apply ] && ! cmp -s "$WORK/before.json" "$WORK/after.json"; then
    [ "$(cksum < "$FILE")" = "$SUM_READ" ] || die 2 "$FILE changed while the profiles were resolved; nothing written, re-run"
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
