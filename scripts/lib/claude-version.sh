#!/usr/bin/env bash
# Claude Code CLI version floor -- the ONE place the minimum lives.
#
# WHY: every console / leg launch passes `--autocompact` and an Opus 5.5 id. An
# older CLI rejects the flag (needs 2.1.221+) or the model (needs 2.1.280+) at
# parse time, so the session never starts and nothing says why. The launch
# scripts (headed-arm.sh, arm-resume.sh, console.sh), himmel update and
# himmel-doctor all read the floor from here so they cannot drift apart.
#
# Bash 3.2-compatible, no python (adopters and the Windows twin may lack it).
#
# Functions:
#   claude_version_bare <text>        -- prints the first x.y.z in text
#   claude_version_lt <a> <b>         -- rc 0 iff a < b, 1 iff a >= b,
#                                        2 when either cannot be compared
#   claude_floor_check [bin]          -- sets CLAUDE_FLOOR_INSTALLED (empty when
#                                        unreadable); rc 0 at/above the floor,
#                                        1 below it, 2 absent or unreadable
#   claude_floor_message <installed>  -- the refusal text, naming both versions
#                                        and the remedy

CLAUDE_MIN_VERSION="${CLAUDE_MIN_VERSION:-2.1.280}"

claude_version_bare() {
    printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1 || true
}

# _claude_version_key <v> -- prints "major minor patch stable" (stable=1 for a
# release, 0 for a prerelease, which sorts below the same release); rc 1 when
# the core is not three numeric components.
_claude_version_key() {
    local v="${1#v}" core pre="" major minor patch rest
    v="${v%%+*}"
    core="${v%%-*}"
    [ "$core" != "$v" ] && pre="${v#*-}"
    major="${core%%.*}"; rest="${core#*.}"
    [ "$rest" != "$core" ] || return 1
    minor="${rest%%.*}"; patch="${rest#*.}"
    [ "$patch" != "$rest" ] || return 1
    case "$major$minor$patch" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
    if [ -n "$pre" ]; then
        printf '%s %s %s 0\n' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
    else
        printf '%s %s %s 1\n' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
    fi
}

claude_version_lt() {
    local ka kb a b i
    ka="$(_claude_version_key "$1")" || return 2
    kb="$(_claude_version_key "$2")" || return 2
    for i in 1 2 3 4; do
        a="$(printf '%s' "$ka" | cut -d' ' -f"$i")"
        b="$(printf '%s' "$kb" | cut -d' ' -f"$i")"
        [ "$a" -lt "$b" ] && return 0
        [ "$a" -gt "$b" ] && return 1
    done
    return 1
}

# shellcheck disable=SC2034  # output-contract global, read by sourcing callers
claude_floor_check() {
    local bin="${1:-claude}" out rc=0
    CLAUDE_FLOOR_INSTALLED=""
    command -v "$bin" >/dev/null 2>&1 || return 2
    out="$("$bin" --version 2>/dev/null)" || true
    CLAUDE_FLOOR_INSTALLED="$(claude_version_bare "$out")"
    [ -n "$CLAUDE_FLOOR_INSTALLED" ] || return 2
    claude_version_lt "$CLAUDE_FLOOR_INSTALLED" "$CLAUDE_MIN_VERSION" || rc=$?
    case "$rc" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# claude_floor_gate <who> <dry_run 0|1> [bin] -- the launch preflight every armed
# launch site calls. rc 0 = go ahead; rc 1 = refuse (message on stderr). Below
# the floor a dry run only warns. An absent or unreadable CLI is never a refusal:
# the floor is only enforced against a version we actually read.
claude_floor_gate() {
    local who="$1" dry="$2" rc=0
    claude_floor_check "${3:-claude}" || rc=$?
    [ "$rc" -eq 1 ] || return 0
    if [ "$dry" = "1" ]; then
        echo "WARN $who: $(claude_floor_message "$CLAUDE_FLOOR_INSTALLED") (dry run: continuing)" >&2
        return 0
    fi
    echo "ERR $who: $(claude_floor_message "$CLAUDE_FLOOR_INSTALLED")" >&2
    return 1
}

claude_floor_message() {
    printf 'Claude Code %s is below the minimum %s that console and leg launches need (--autocompact and the Opus 5.5 model id are rejected at parse time). Run: claude update\n' \
        "${1:-unknown}" "$CLAUDE_MIN_VERSION"
}
