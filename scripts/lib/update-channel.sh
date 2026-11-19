#!/usr/bin/env bash
# update-channel.sh — the release-channel resolver and tag ranking, shared by
# scripts/himmel-update.sh (what the updater does) and
# scripts/hooks/check-update-available.sh (what the session-start nudge says),
# so the two cannot disagree about what "behind" means on a channel station.
#
# Sourced, never executed. Defines functions only: no side effects, no `set`.
# Bash 3.2 compatible.
# shellcheck shell=bash

_channel_profile_path() {
    echo "${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/install-profile.json"
}

_resolve_update_channel() {
    local env_val="${HIMMEL_UPDATE_CHANNEL:-}"
    if [ -n "$env_val" ]; then
        case "$env_val" in
            stable|pre) echo "$env_val"; return 0 ;;
            *)
                echo "update: HIMMEL_UPDATE_CHANNEL must be 'stable' or 'pre' (got '$env_val')" >&2
                return 2 ;;
        esac
    fi
    local profile
    profile=$(_channel_profile_path)
    if [ -f "$profile" ]; then
        if ! command -v jq >/dev/null 2>&1; then
            echo "update: profile $profile exists but jq is not installed — cannot read channel; install jq" >&2
            return 2
        fi
        if ! jq -e . "$profile" >/dev/null 2>&1; then
            echo "update: profile $profile is not valid JSON — cannot read channel" >&2
            return 2
        fi
        if ! jq -e 'type == "object"' "$profile" >/dev/null 2>&1; then
            echo "update: profile $profile is not a valid JSON object — cannot read channel" >&2
            return 2
        fi
        local val
        val=$(jq -r 'if .channel == null then "" elif (.channel | type) == "string" then .channel else "himmel_channel_badtype" end' "$profile" 2>/dev/null || echo "")
        if [ "$val" = "himmel_channel_badtype" ]; then
            local raw
            raw=$(jq -c '.channel' "$profile" 2>/dev/null)
            echo "update: profile $profile has an invalid channel $raw (must be 'stable' or 'pre')" >&2
            return 2
        fi
        if [ -n "$val" ]; then
            case "$val" in
                stable|pre) echo "$val"; return 0 ;;
                *)
                    echo "update: profile $profile has an invalid channel '$val' (must be 'stable' or 'pre')" >&2
                    return 2 ;;
            esac
        fi
    fi
    echo ""
    return 0
}

_channel_tag_parts() {
    local tag="$1"
    if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-pre\.([0-9]+))?$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]:-NONE}"
        return 0
    fi
    return 1
}

_channel_tag_max() {
    local a="$1" b="$2" pa pb
    pa=$(_channel_tag_parts "$a") || return 2
    pb=$(_channel_tag_parts "$b") || return 2
    local a_maj a_min a_pat a_pre b_maj b_min b_pat b_pre
    read -r a_maj a_min a_pat a_pre <<<"$pa"
    read -r b_maj b_min b_pat b_pre <<<"$pb"
    if [ "$a_maj" -ne "$b_maj" ]; then { [ "$a_maj" -gt "$b_maj" ] && echo "$a"; } || echo "$b"; return 0; fi
    if [ "$a_min" -ne "$b_min" ]; then { [ "$a_min" -gt "$b_min" ] && echo "$a"; } || echo "$b"; return 0; fi
    if [ "$a_pat" -ne "$b_pat" ]; then { [ "$a_pat" -gt "$b_pat" ] && echo "$a"; } || echo "$b"; return 0; fi
    if [ "$a_pre" = "NONE" ] && [ "$b_pre" = "NONE" ]; then echo "$a"; return 0; fi
    if [ "$a_pre" = "NONE" ]; then echo "$a"; return 0; fi
    if [ "$b_pre" = "NONE" ]; then echo "$b"; return 0; fi
    { [ "$a_pre" -ge "$b_pre" ] && echo "$a"; } || echo "$b"
}

_channel_best_tag() {
    local channel="$1" names="$2" tag best="" parts pre
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        parts=$(_channel_tag_parts "$tag") || continue
        if [ "$channel" = "stable" ]; then
            pre="${parts##* }"
            [ "$pre" != "NONE" ] && continue
        fi
        if [ -z "$best" ]; then
            best="$tag"
        else
            best=$(_channel_tag_max "$best" "$tag")
        fi
    done <<EOF
$names
EOF
    [ -z "$best" ] && return 1
    echo "$best"
}
