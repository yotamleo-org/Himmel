#!/usr/bin/env bash
# update-channel.sh — the release-channel resolver and tag ranking, shared by
# scripts/himmel-update.sh (what the updater does) and
# scripts/hooks/check-update-available.sh (what the session-start nudge says),
# so the two cannot disagree about what "behind" means on a channel station.
#
# Sourced, never executed. Defines functions only: no side effects, no `set`.
# Bash 3.2 compatible.
# shellcheck shell=bash

# ─── release-channel seam ──────────────────────────────────────
# `channel: stable|pre` lets a station follow tagged releases (`vX.Y.Z`,
# optionally `vX.Y.Z-pre.N`) instead of the current branch's tip. Unset (the
# default) is untouched — update_pull() above only calls into this when
# $UPDATE_CHANNEL is non-empty.
#
# Storage: the himmelctl install-answers cache
# (${HIMMELCTL_CACHE_DIR:-~/.claude/himmel}/install-profile.json,
# scripts/himmelctl/lib/helpers.js's cacheDir()) — NOT
# scripts/install/capture-operator-profile.mjs (a docs-snapshot generator,
# never read by live code; header says so explicitly) and NOT
# scripts/himmelctl/lib/adopter-profile.js (pure logic, no data file; bash
# cannot require() it anyway). install-profile.json is the one JSON file a
# real adopter's machine actually has that himmel-update.sh can read without
# node — via the same optional `jq` dependency already used elsewhere in this
# script (report_plugin_gap et al.).
_channel_profile_path() {
    echo "${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/install-profile.json"
}

# Resolves the effective channel: env > profile > default (unset, meaning
# "today's plain git pull"). A malformed value at either layer fails loud
# (rc 2, message on stderr) rather than silently falling through to the layer
# below or to default — "fail LOUD rather than guess" per the ticket. No
# profile FILE is treated as "no channel set" (a station that never installed
# via himmelctl must see zero behavior change) — but once a profile exists,
# we cannot tell whether it carries a channel without reading it, so a
# missing jq or a malformed profile fails loud too: a
# stable/pre station silently missing jq must not silently start pulling
# branch-tip commits again.
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
        # A separate check from the syntax check above: valid JSON with a
        # non-object root (e.g. a bare `[]` or `"x"`) passes `jq -e .` but
        # would fail INSIDE the .channel lookup below, where `|| echo ""`
        #  would silently swallow that failure as "no
        # channel set" instead of erroring loud.
        if ! jq -e 'type == "object"' "$profile" >/dev/null 2>&1; then
            echo "update: profile $profile is not a valid JSON object — cannot read channel" >&2
            return 2
        fi
        # Absent key or explicit `null` both mean "no channel set" (a bare
        # `null` is a normal way to spell "unset" in JSON); any OTHER
        # non-string value (false, a number, an object...) is malformed the
        # same way a bad string is, so it fails loud below rather than
        # silently collapsing to "unset" like a missing key would.
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

# Strict `vX.Y.Z` / `vX.Y.Z-pre.N` tag matcher. Echoes "<major> <minor>
# <patch> <pre>" (pre="NONE" when the tag has no -pre.N suffix); rc 1 if the
# tag doesn't match at all (any other tag in the repo — unrelated to
# releases — is silently ignored by callers, never treated as a candidate).
_channel_tag_parts() {
    local tag="$1"
    if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-pre\.([0-9]+))?$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]:-NONE}"
        return 0
    fi
    return 1
}

# Echoes the greater of two already-matching tags. Semver, not lexical order —
# no python dependency for adopters (unlike _cli_proxy_version_cmp above,
# which this deliberately does not reuse: it treats any prerelease as
# uniformly below stable without comparing prerelease numbers against each
# other, and it shells out to python3). A stable tag always outranks any
# -pre.N of the same major.minor.patch; two -pre.N tags compare N numerically
# (pre.10 > pre.9), never lexically.
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

# Highest tag on the given channel among the NAMES in $2 (newline separated;
# non-release names are ignored). stable: only tags with no -pre.N suffix are
# candidates. pre: both forms are candidates (a stable release still outranks a
# -pre.N of the same version, via _channel_tag_max). Echoes the winner; rc 1 +
# no output means no candidate.
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
