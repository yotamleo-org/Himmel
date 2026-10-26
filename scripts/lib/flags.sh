#!/usr/bin/env bash
# scripts/lib/flags.sh — himmel_flag <name>: the shell reader of scripts/lib/flags.tsv.
#
#   . scripts/lib/flags.sh; himmel_flag chain_soft_edges && echo on
#   bash scripts/lib/flags.sh chain_soft_edges        # same, as a command
#
# Exit: 0 on, 1 off, 2 unknown name or unreadable registry or an invalid value (loud, on stderr).
# Resolution (docs/internals/config-layers.md): HIMMEL_FLAG_<NAME> in the environment,
# then ~/.himmel/himmel.conf.local, then ~/.himmel/himmel.conf (HIMMEL_CONFIG_DIR moves the
# directory, as for load_dotenv), then the registry default. A flag is never read from .env.
# HIMMEL_FLAGS_TSV points the reader at another registry (the test suites use it).
# flags.py and flags.mjs read the same TSV by the same rules.
# Platform guard (gitbash-only): POSIX bash 3.2+, no external commands beyond tr.

_HIMMEL_FLAGS_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_hf_trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# _hf_conf_value <KEY> — the first non-empty value of KEY in himmel.conf.local, then himmel.conf
_hf_conf_value() {
    local dir="${HIMMEL_CONFIG_DIR:-$HOME/.himmel}" f line k v
    for f in "$dir/himmel.conf.local" "$dir/himmel.conf"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            case "$line" in ''|'#'*|*=*) ;; *) continue ;; esac
            case "$line" in ''|'#'*) continue ;; esac
            k="$(_hf_trim "${line%%=*}")"
            [ "$k" = "$1" ] || continue
            v="$(_hf_trim "${line#*=}")"
            case "$v" in
                \"*\"*) v="${v#\"}"; v="${v%%\"*}" ;;
                \'*\'*) v="${v#\'}"; v="${v%%\'*}" ;;
                *' #'*) v="$(_hf_trim "${v%% #*}")" ;;
            esac
            [ -n "$v" ] || continue
            printf '%s' "$v"
            return 0
        done < "$f"
    done
    return 1
}

himmel_flag() {
    local name="${1:-}" reg="${HIMMEL_FLAGS_TSV:-$_HIMMEL_FLAGS_SELF_DIR/flags.tsv}"
    local key val def="" found=0 line n d
    case "$name" in
        ''|[!a-z]*|*[!a-z0-9_]*) echo "himmel_flag: '$name' is not a flag name (lower_snake_case)" >&2; return 2 ;;
    esac
    [ -r "$reg" ] || { echo "himmel_flag: cannot read the registry $reg" >&2; return 2; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        n="${line%%$'\t'*}"
        [ "$n" = "$name" ] || continue
        d="${line#*$'\t'}"; d="${d%%$'\t'*}"
        def="$d"; found=1
        break
    done < "$reg"
    if [ "$found" != 1 ]; then
        echo "himmel_flag: unknown flag '$name' (not registered in $reg)" >&2
        return 2
    fi
    key="HIMMEL_FLAG_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    val="${!key:-}"
    [ -n "$val" ] || val="$(_hf_conf_value "$key")" || val=""
    [ -n "$val" ] || val="$def"
    case "$val" in
        1|on|true) return 0 ;;
        0|off|false) return 1 ;;
        *) echo "himmel_flag: $name has the value '$val' (want 1, 0, on or off)" >&2; return 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    himmel_flag "$@"
fi
