#!/usr/bin/env bash
# Read-only fleet control contract. Source and call fleet_control_show MANIFEST.
# Output is bounded JSON; callers MUST require state=ok AND mode=active for
# managed admission. This snapshot grants no reservation or spawn authority.
# Missing/bad/unbound/conflicting inputs are effectively paused, with null
# family/generation/target. No environment mode or held flag is consulted.
#
# schema 1 anchor: {schema,family,mode,generation,target,updated,reason}.
# A chief's .control = {family,anchor}; anchor is the physical manifest bucket's
# fleet-control.json. Succession copies that reference, never mutable values.
# Only fleet-manifest.sh writes either object. Atomic rename permits lock-free
# snapshots here; a future final admission MUST serialize with anchor updates.
# No PID/age-based liveness, pause acknowledgement or reconciliation is implied.

# shellcheck source=scripts/lib/legacy-names.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/legacy-names.sh"

fleet_control_path() (
    [ "$#" -eq 1 ] && [ -n "$1" ] || exit 1
    local dir base
    base=${1##*/}
    case "$base" in ''|.|..|fleet-control.json|*[[:cntrl:]]*) exit 1 ;; esac
    dir=$(cd -- "$(dirname -- "$1")" && pwd -P) || exit 1
    printf '%s/%s\n' "${dir%/}" "$base"
)

fleet_control_manifest_valid() {
    local w='def W: .workers;'
    if legacy_names_on; then w='def W: (.workers // .legs);'; fi
    { [ "$1" = - ] || { [ -f "$1" ] && [ ! -L "$1" ]; }; } && jq -e -s "$w"'
        length == 1 and (.[0] | type == "object" and .schema == 1
        and (W | type == "array") and all(W[]; type == "object"
        and (.doc | type == "string" and test("^/[^[:space:]*?\\[]+$"))))' "$1" >/dev/null 2>&1
}

FLEET_CONTROL_VALID='
        def posint: type == "number" and . >= 1 and . <= 9007199254740990 and floor == .;
        def family: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$");
        length == 1 and (.[0] | type == "object" and .schema == 1
        and (.family | family) and (.mode == "paused" or .mode == "shadow" or .mode == "active")
        and (.generation | posint) and (.target | posint and . <= 2147483647)
        and (.updated | type == "string" and length <= 40 and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (.reason | type == "string" and length <= 160))'

fleet_control_anchor_valid() {
    [ -f "$1" ] && [ ! -L "$1" ] && jq -e -s "$FLEET_CONTROL_VALID" "$1" >/dev/null 2>&1
}

fleet_control_show() (
    [ "$#" -eq 1 ] || exit 2
    local manifest anchor state=ok family ref input
    if ! manifest=$(fleet_control_path "$1" 2>/dev/null); then
        state=invalid
    elif [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
        state=missing
    elif [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        state=invalid
    elif ! input=$(cat -- "$manifest"); then
        state=invalid
    elif ! printf '%s\n' "$input" | fleet_control_manifest_valid -; then
        state=invalid
    elif ! printf '%s\n' "$input" | jq -e 'has("control")' >/dev/null; then
        state=unbound
    elif ! printf '%s\n' "$input" | jq -e '.control | type == "object"
        and (.family | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$"))
        and (.anchor | type == "string")' >/dev/null; then
        state=invalid
    else
        anchor="${manifest%/*}/fleet-control.json"
        ref=$(printf '%s\n' "$input" | jq -r '.control.anchor') || exit 1
        family=$(printf '%s\n' "$input" | jq -r '.control.family') || exit 1
        if [ "$ref" != "$anchor" ]; then state=mismatch
        elif [ ! -e "$anchor" ] && [ ! -L "$anchor" ]; then state=missing
        elif [ ! -f "$anchor" ] || [ -L "$anchor" ]; then state=invalid
        # Read and validate one immutable snapshot, so an intervening rename
        # cannot combine an old family with new mode/generation/target.
        else
            if ! ref=$(cat -- "$anchor"); then state=invalid
            elif ! printf '%s\n' "$ref" | jq -e -s "$FLEET_CONTROL_VALID" >/dev/null 2>&1; then state=invalid
            elif ! printf '%s\n' "$ref" | jq -e --arg f "$family" '.family == $f' >/dev/null; then state=mismatch
            else
                printf '%s\n' "$ref" | jq -c '{state:"ok",mode,family,generation,target}'
                exit $?
            fi
        fi
    fi
    jq -nc --arg s "$state" '{state:$s,mode:"paused",family:null,generation:null,target:null}'
)
