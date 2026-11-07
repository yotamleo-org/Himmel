#!/usr/bin/env bash
# set-handover-dir.sh — idempotently set HANDOVER_DIR in the repo .env.
#
# Writes (create-or-update) the `HANDOVER_DIR=<path>` line in the primary
# checkout's .env so the handover shell tooling (via scripts/lib/load-dotenv.sh)
# and the handover skill resolve state from one configured location instead of
# a hardcoded path. This is the auto-write step behind `/handover-setup`.
#
# Usage:
#   set-handover-dir.sh <handover-dir> [--env-file <path>]
#   set-handover-dir.sh --inline [--env-file <path>]
#   set-handover-dir.sh --read-env [--root <repo-root>]
#   set-handover-dir.sh --read-config
#
#   <handover-dir>   Absolute path to the handover state root (Mode B). Must be
#                    an existing directory (fail-closed — matches the resolver
#                    in scripts/lib/handover-path.sh).
#   --inline         The inline choice (Mode A): write an EMPTY `HANDOVER_DIR=`
#                    line. An empty value reads as unset (load_dotenv and the
#                    resolver both test -n), so state stays under
#                    <repo-root>/handovers. The line is the persisted record:
#                    it replaces a stale vault or external path, and a re-run
#                    of adopt.sh leaves it alone instead of re-pinning a vault.
#   --env-file <p>   Target .env (default: <primary-checkout-root>/.env).
#
# Idempotent: re-running with the same value reaches the same end-state (the
# line is rewritten to the same value); a new value replaces the existing line
# in place (file order preserved). Commented example lines (`# HANDOVER_DIR=...`)
# are left untouched — an active line is appended.
#
# Exit codes:
#   0  written (or already correct)
#   1  usage / input error
#   2  handover dir does not exist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/env-append.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$SCRIPT_DIR/../lib/env-append.sh"

HDIR=""
ENV_FILE=""
INLINE=0
READ_MODE=""
READ_ROOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)   ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*) ENV_FILE="${1#--env-file=}"; shift ;;
        --inline)     INLINE=1; shift ;;
        --read-env)    READ_MODE=dotenv; shift ;;
        --read-config) READ_MODE=config; shift ;;
        --root)        READ_ROOT="${2:-}"; shift 2 ;;
        -*)           echo "ERR set-handover-dir: unknown flag: $1" >&2; exit 1 ;;
        *)
            if [ -z "$HDIR" ]; then HDIR="$1"; shift
            else echo "ERR set-handover-dir: unexpected arg: $1" >&2; exit 1; fi
            ;;
    esac
done

if [ "$INLINE" -eq 1 ] && [ -n "$HDIR" ]; then
    echo "ERR set-handover-dir: --inline takes no handover dir" >&2
    exit 1
fi

# Read modes: print one layer's HANDOVER_DIR through the loader, never touching a file.
# They exist so /handover-setup can read a layer with `bash <this> --read-env`, a shape
# the secrets and main-checkout guards pass (a `bash -c` body with a redirect is refused).
#   --read-env     the .env layer only (config files off): `HANDOVER_DIR=<value>` or `unset`
#   --read-config  the himmel.conf layers (.local, station profile, himmel.conf): same output
#   --root <dir>   the repo root whose .env is read (default: the primary checkout)
# Non-zero exit means the loader could not be read; it never prints `unset` then.
if [ -n "$READ_MODE" ]; then
    if [ "$INLINE" -eq 1 ] || [ -n "$HDIR" ]; then
        echo "ERR set-handover-dir: --read-env/--read-config take no handover dir and no --inline" >&2
        exit 1
    fi
    if [ -z "$READ_ROOT" ]; then
        if common=$(git rev-parse --git-common-dir 2>/dev/null); then # swallow-ok: not in a git repo takes the else branch, a script-relative root
            READ_ROOT="$(cd "$common/.." && pwd)"
        else
            READ_ROOT="$SCRIPT_DIR/../.."
        fi
    fi
    (
        unset HANDOVER_DIR
        if [ "$READ_MODE" = dotenv ]; then export HIMMEL_CONFIG_DIR=/nonexistent; fi
        # shellcheck source=scripts/lib/load-dotenv.sh
        # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
        . "$SCRIPT_DIR/../lib/load-dotenv.sh" || exit 1
        if [ "$READ_MODE" = dotenv ]; then
            load_dotenv --root "$READ_ROOT" HANDOVER_DIR 2>/dev/null || exit 1
            if [ "${HANDOVER_DIR+set}" = set ]; then printf 'HANDOVER_DIR=%s\n' "$HANDOVER_DIR"; else echo unset; fi
        else
            out=$(_himmel_config_layers HANDOVER_DIR) || exit 1
            if [ -n "$out" ]; then printf '%s\n' "$out"; else echo unset; fi
        fi
    )
    exit $?
fi

if [ "$INLINE" -eq 0 ] && [ -z "$HDIR" ]; then
    echo "Usage: set-handover-dir.sh <handover-dir> [--env-file <path>]" >&2
    echo "       set-handover-dir.sh --inline [--env-file <path>]" >&2
    exit 1
fi

if [ "$INLINE" -eq 0 ] && [ ! -d "$HDIR" ]; then
    echo "ERR set-handover-dir: handover dir does not exist: $HDIR" >&2
    echo "    Create it first (e.g. a 'handovers' dir in your state repo), then re-run." >&2
    exit 2
fi

# Canonicalize (absolute, forward slashes — some Windows bash builds emit
# backslashes from pwd; normalize so the stored value is shell-safe).
# shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not a quote escape
if [ "$INLINE" -eq 0 ]; then
    HDIR="$(cd "$HDIR" && pwd | tr '\\' '/')"
fi

# Resolve the target .env: explicit --env-file, else the primary checkout root
# (parent of git-common-dir — finds the real .env from inside a worktree too).
if [ -z "$ENV_FILE" ]; then
    if common=$(git rev-parse --git-common-dir 2>/dev/null); then # swallow-ok: not in a git repo takes the else branch, a script-relative .env
        ENV_FILE="$(cd "$common/.." && pwd)/.env"
    else
        ENV_FILE="$SCRIPT_DIR/../../.env"
    fi
fi

if [ ! -e "$ENV_FILE" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    : > "$ENV_FILE"
elif [ ! -f "$ENV_FILE" ]; then
    # Exists but is a directory / symlink-to-dir / device — refuse rather than
    # clobber or write into something unexpected.
    echo "ERR set-handover-dir: target is not a regular file: $ENV_FILE" >&2
    exit 1
fi

new_line="HANDOVER_DIR=$HDIR"

if grep -qE '^[[:space:]]*HANDOVER_DIR=' "$ENV_FILE"; then
    # Follow a symlinked .env to its real file so the rename replaces the target,
    # not the link (readlink without -f: bash 3.2 / macOS safe).
    target="$ENV_FILE"
    hops=0
    while [ -L "$target" ] && [ "$hops" -lt 20 ]; do
        link=$(readlink "$target")
        case "$link" in
            /*) target="$link" ;;
            *)  target="$(dirname "$target")/$link" ;;
        esac
        hops=$((hops + 1))
    done
    # mktemp in the target's dir (0600, unpredictable name); copy the original
    # mode onto it so the update never widens a 0600 .env to the umask mode.
    tmp=$(mktemp "$target.XXXXXX") || { echo "ERR set-handover-dir: mktemp failed for $target" >&2; exit 1; }
    trap 'rm -f "$tmp"' EXIT
    perm=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || echo '') # swallow-ok: an unreadable mode skips the chmod, the temp keeps its 0600
    if [ -n "$perm" ]; then chmod "$perm" "$tmp" 2>/dev/null || true; fi
    awk -v repl="$new_line" '
        !done && /^[[:space:]]*HANDOVER_DIR=/ { print repl; done=1; next }
        { print }
    ' "$ENV_FILE" > "$tmp"
    # prim-ok: the original .env mode is copied onto $tmp above; atomic_write would reset it to 0600 and drop the EXIT-trap cleanup shape.
    mv "$tmp" "$target"
    trap - EXIT
    echo "OK set-handover-dir: updated HANDOVER_DIR=$HDIR in $ENV_FILE"
else
    env_append_line "$ENV_FILE" "$new_line"
    echo "OK set-handover-dir: appended HANDOVER_DIR=$HDIR to $ENV_FILE"
fi
