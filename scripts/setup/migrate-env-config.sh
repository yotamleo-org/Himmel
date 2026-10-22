#!/usr/bin/env bash
# migrate-env-config.sh — copy behaviour-config keys out of .env into
# ~/.himmel/himmel.conf, so .env can hold secrets only.
# Layer table: docs/internals/config-layers.md.
#
#   bash scripts/setup/migrate-env-config.sh [--env <file>] [--vault <dir>]
#   bash scripts/setup/migrate-env-config.sh --dry-run [--env <file>]
#
#   --ahead-of-setup  accepted and ignored: setup, adopt and himmelctl read and
#                  write these keys in the tracked file, so a real run needs no
#                  opt-in.
#   --env <file>   the .env to read (default: the one load_dotenv reads)
#   --vault <dir>  keep the tracked file in <dir>/.himmel/himmel.conf and link
#                  ~/.himmel/himmel.conf to it (a luna install). Without it,
#                  ~/.himmel/himmel.conf is a plain file.
#   --dry-run      say what would move; write nothing
#
# Values never reach stdout or stderr: each line is copied file to file, and
# only key NAMES are printed. Keys already in himmel.conf are left alone. .env
# itself is never edited: delete the moved lines by hand once the next session
# runs clean (the deprecation notice names any key still read from .env).
#
# Gate-policy keys (CR_REQUIRE_CROSS_MODEL, CR_FLOOR_FALLBACK, ARMAUTOMERGE)
# belong in ~/.himmel/config.json .policy, which an agent may not write. For
# each one found, this prints a command for the operator to run at their own
# prompt; the command reads the value from .env itself, so it is never shown.
# shellcheck disable=SC2016 # the printed command is literal text for the operator
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/load-dotenv.sh
. "$HERE/../lib/load-dotenv.sh"

envfile="" vault="" dry=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env|--vault)
            [ "$#" -ge 2 ] || { echo "migrate-env-config: $1 needs a value" >&2; exit 2; }
            if [ "$1" = --env ]; then envfile="$2"; else vault="$2"; fi
            shift 2 ;;
        --dry-run) dry=1; shift ;;
        --ahead-of-setup) shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "migrate-env-config: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$envfile" ] || envfile=$(_load_dotenv_envfile "")
if [ -z "$envfile" ] || [ ! -f "$envfile" ]; then
    echo "migrate-env-config: no .env found; nothing to migrate."
    exit 0
fi

confdir=$(_himmel_config_dir)
conf="$confdir/himmel.conf"

# Key names only: the text before '=' on each uncommented line.
names=$(awk '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } {
    i = index($0, "="); if (i == 0) next
    k = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
    if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(k in seen)) { seen[k] = 1; print k }
}' "$envfile")

config_keys=() policy_keys=()
for key in $names; do
    case "$(_himmel_key_class "$key")" in
        config) config_keys[${#config_keys[@]}]="$key" ;;
        policy) policy_keys[${#policy_keys[@]}]="$key" ;;
    esac
done

if [ -n "$vault" ] && [ "$dry" -eq 0 ]; then
    tracked="$vault/.himmel/himmel.conf"
    mkdir -p "$vault/.himmel" "$confdir"
    [ -e "$tracked" ] || : > "$tracked"
    if [ -L "$conf" ]; then
        if [ "$(readlink "$conf")" != "$tracked" ]; then
            echo "migrate-env-config: $conf links somewhere other than $tracked; not changing it." >&2
            exit 1
        fi
    elif [ -e "$conf" ]; then
        echo "migrate-env-config: $conf already exists as a plain file; not replacing it with a link to $tracked." >&2
        exit 1
    else
        ln -s "$tracked" "$conf"
        echo "linked $conf -> $tracked"
    fi
fi

moved=0
for key in ${config_keys[@]+"${config_keys[@]}"}; do
    if [ -f "$conf" ] && [ -n "$(_load_dotenv_extract "$conf" "$key")" ]; then
        echo "skip  $key (already in himmel.conf)"
        continue
    fi
    if [ "$dry" -eq 1 ]; then
        echo "would move  $key"
        continue
    fi
    line=$(_load_dotenv_extract "$envfile" "$key")
    if [ -z "$line" ]; then
        echo "skip  $key (no value in .env)"
        continue
    fi
    # A last line with no newline gets one first, so the append starts a line.
    if ! { mkdir -p "$confdir" \
        && { [ ! -s "$conf" ] || [ -z "$(tail -c 1 "$conf")" ] || printf '\n' >> "$conf"; } \
        && printf '%s\n' "$line" >> "$conf"; } 2>/dev/null; then
        echo "migrate-env-config: could not write $conf; $key was not moved. Keep it in .env." >&2
        exit 1
    fi
    echo "moved $key"
    moved=$((moved + 1))
done
[ "${#config_keys[@]}" -gt 0 ] || echo "no behaviour-config keys in .env."
[ "$dry" -eq 1 ] || echo "$moved key(s) copied to $conf. Delete them from .env once a session starts without a DEPRECATED notice."

if [ "${#policy_keys[@]}" -gt 0 ]; then
    echo
    echo "Gate-policy keys found in .env: ${policy_keys[*]}"
    echo "An agent cannot write ~/.himmel/config.json. Run each line below at your own prompt; it reads the value from .env, so the value is not shown:"
    for key in "${policy_keys[@]}"; do
        printf '  v=$(awk -v k=%s '\''{ i = index($0, "="); n = substr($0, 1, i - 1); gsub(/^[ \\t]+|[ \\t]+$/, "", n) } i && n == k { v = substr($0, i + 1); sub(/\\r$/, "", v); sub(/[ \\t]+#.*/, "", v); gsub(/^[ \\t]+|[ \\t]+$/, "", v); c = substr(v, 1, 1); if (length(v) > 1 && (c == sprintf("%%c", 34) || c == sprintf("%%c", 39)) && substr(v, length(v), 1) == c) v = substr(v, 2, length(v) - 2); print v; exit }'\'' %q) && mkdir -p ~/.himmel && f=~/.himmel/config.json && { [ -f "$f" ] || echo {} > "$f"; } && jq --arg v "$v" '\''.policy.%s = $v'\'' "$f" > "$f.tmp" && mv "$f.tmp" "$f"\n' \
            "$key" "$envfile" "$key"
    done
fi
