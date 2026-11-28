#!/usr/bin/env bash
# Test seam HIMMEL_PRIMARY_ROOT (the checkout whose hook adapter goes into hooks.json),
# registered in scripts/chokepoints.json: on the anchor checkout a value that differs from the Claude
# session's launch environment exits 96 (scripts/lib/chokepoint-seam-guard.sh).
set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "install-antigravity-backstop.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/antigravity/install-antigravity-backstop.sh || exit 96

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --check|--dry-run) DRY_RUN=1 ;;
        -h|--help)
            printf 'usage: install-antigravity-backstop.sh [--check|--dry-run]\n'
            exit 0
            ;;
        *)
            printf 'install-antigravity-backstop: unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || { printf 'install-antigravity-backstop: jq required\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/prim.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/prim.sh" || { printf 'install-antigravity-backstop: cannot load prim.sh\n' >&2; exit 1; }

resolve_primary_root() {
    local common="" root=""
    if [ -n "${HIMMEL_PRIMARY_ROOT:-}" ] && [ -d "${HIMMEL_PRIMARY_ROOT}" ]; then
        (cd -P "$HIMMEL_PRIMARY_ROOT" && pwd -P)
        return 0
    fi
    if command -v git >/dev/null 2>&1; then
        if common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$common" ] && [ -d "$common" ]; then
            root="$(dirname "$common")"
            if [ -f "$root/scripts/hooks/antigravity-hook-adapter.sh" ]; then
                printf '%s' "$root"
                return 0
            fi
        fi
    fi
    (cd -P "$SCRIPT_DIR/../.." && pwd -P)
}

PRIMARY_ROOT="$(resolve_primary_root)"
ADAPTER="$PRIMARY_ROOT/scripts/hooks/antigravity-hook-adapter.sh"
[ -f "$ADAPTER" ] || { printf 'install-antigravity-backstop: adapter missing at %s\n' "$ADAPTER" >&2; exit 1; }

case "$ADAPTER" in
    *"'"*|*$'\n'*)
        printf 'install-antigravity-backstop: unsafe adapter path: %s\n' "$ADAPTER" >&2
        exit 1
        ;;
esac

SPEC_JSON="$(jq -n --arg a "$ADAPTER" '{
    "himmel-antigravity-backstop": {
        "SessionStart": [
            {"type": "command", "command": ("exec bash \u0027" + $a + "\u0027 --event SessionStart"), "timeout": 60}
        ],
        "PreToolUse": [
            {
                "matcher": "*",
                "hooks": [
                    {"type": "command", "command": ("exec bash \u0027" + $a + "\u0027 --event PreToolUse"), "timeout": 60}
                ]
            }
        ],
        "PostToolUse": [
            {
                "matcher": "run_command",
                "hooks": [
                    {"type": "command", "command": ("exec bash \u0027" + $a + "\u0027 --event PostToolUse"), "timeout": 30}
                ]
            }
        ],
        "Stop": [
            {"type": "command", "command": ("exec bash \u0027" + $a + "\u0027 --event Stop"), "timeout": 15}
        ]
    }
}')"

install_target() {
    local target="$1"
    local dir parent
    dir="$(dirname "$target")"
    parent="$(dirname "$dir")"

    if [ -L "$target" ] || [ -L "$dir" ] || [ -L "$parent" ]; then
        printf 'install-antigravity-backstop: refusing symlink target or ancestor at %s\n' "$target" >&2
        return 1
    fi

    local merged=""
    if [ -f "$target" ]; then
        if ! jq -e 'type == "object"' "$target" >/dev/null 2>&1; then
            printf 'install-antigravity-backstop: malformed JSON object in %s\n' "$target" >&2
            return 1
        fi
        merged="$(jq -S --argjson spec "$SPEC_JSON" '. * $spec' "$target")"
        local current
        current="$(jq -S '.' "$target")"
        if [ "$merged" = "$current" ]; then
            printf 'UNCHANGED   : %s\n' "$target"
            return 0
        fi
    else
        merged="$(printf '%s\n' "$SPEC_JSON" | jq -S '.')"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'WOULD UPDATE: %s\n' "$target"
        return 0
    fi

    mkdir -p "$dir" || return 1
    printf '%s\n' "$merged" | atomic_write "$target" || return 1
    printf 'CHANGED     : %s\n' "$target"
    return 0
}

T3_HOME="${T3CODE_HOME:-$HOME/.t3}"
AGY_PROVIDERS_DIR="$T3_HOME/userdata/providers/antigravity"
rc=0

if [ -d "$AGY_PROVIDERS_DIR" ] && [ ! -L "$AGY_PROVIDERS_DIR" ]; then
    shopt -s nullglob
    for hdir in "$AGY_PROVIDERS_DIR"/*; do
        [ -d "$hdir" ] && [ ! -L "$hdir" ] || continue
        install_target "$hdir/config/hooks.json" || rc=1
    done
    shopt -u nullglob
fi

install_target "$HOME/.gemini/config/hooks.json" || rc=1
exit "$rc"
