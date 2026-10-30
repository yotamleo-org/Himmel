#!/usr/bin/env bash
# migrate-env-config.sh — copy behaviour-config keys out of .env into
# ~/.himmel/himmel.conf, so .env can hold secrets only.
# Layer table: docs/internals/config-layers.md.
#
#   bash scripts/setup/migrate-env-config.sh [--env <file>] [--vault <dir>] [--profile <name>]
#   bash scripts/setup/migrate-env-config.sh --dry-run [--env <file>]
#
#   --ahead-of-setup  accepted and ignored: setup, adopt and himmelctl read and
#                  write these keys in the tracked file, so a real run needs no
#                  opt-in.
#   --env <file>   the .env to read (default: the one load_dotenv reads)
#   --vault <dir>  keep the tracked file in <dir>/.himmel/himmel.conf and link
#                  ~/.himmel/himmel.conf to it (a luna install). Without it,
#                  ~/.himmel/himmel.conf is a plain file.
#   --profile <name>  also create <vault>/.himmel/profiles/<name>.conf, with the
#                  vault dir and link when absent. Needs --vault or a himmel.conf
#                  already linked into a vault; needs no .env.
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

envfile="" vault="" profile="" profile_set=0 dry=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env|--vault|--profile)
            [ "$#" -ge 2 ] || { echo "migrate-env-config: $1 needs a value" >&2; exit 2; }
            case "$1" in --env) envfile="$2" ;; --vault) vault="$2" ;; *) profile="$2"; profile_set=1 ;; esac
            shift 2 ;;
        --dry-run) dry=1; shift ;;
        --ahead-of-setup) shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "migrate-env-config: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$vault" in ''|/*) ;; *) vault="$PWD/${vault#./}" ;; esac

confdir=$(_himmel_config_dir)
conf="$confdir/himmel.conf"

# link_vault — keep the tracked file in <vault>/.himmel/himmel.conf and link
# ~/.himmel/himmel.conf to it. Safe to repeat on a correct link.
die_create() { echo "migrate-env-config: could not create $1; nothing more was written." >&2; exit 1; }

link_vault() {
    tracked="$vault/.himmel/himmel.conf"
    mkdir -p "$vault/.himmel" "$confdir" 2>/dev/null || die_create "$vault/.himmel"
    [ -e "$tracked" ] || { : > "$tracked"; } 2>/dev/null || die_create "$tracked"
    if [ -L "$conf" ]; then
        if ! [ "$conf" -ef "$tracked" ]; then
            echo "migrate-env-config: $conf links somewhere other than $tracked; not changing it." >&2
            exit 1
        fi
    elif [ -e "$conf" ]; then
        echo "migrate-env-config: $conf already exists as a plain file; not replacing it with a link to $tracked." >&2
        exit 1
    else
        ln -s "$tracked" "$conf" 2>/dev/null || die_create "$conf"
        echo "linked $conf -> $tracked"
    fi
}

# The profile step: <vault>/.himmel/profiles/<name>.conf beside the vault
# link, made with the vault dir when absent. Needs --vault or an existing link.
if [ "$profile_set" -eq 1 ]; then
    case "$profile" in ''|.*|*[!A-Za-z0-9._-]*)
        echo "migrate-env-config: --profile needs a plain name (letters, digits, . _ -), not a path." >&2
        exit 2 ;;
    esac
    if [ -z "$vault" ]; then
        target=$([ -L "$conf" ] && readlink "$conf")
        case "$target" in
            /*/.himmel/himmel.conf) vault="${target%/.himmel/himmel.conf}" ;;
            *) echo "migrate-env-config: --profile needs --vault <dir>, or a himmel.conf already linked into a vault." >&2
               exit 2 ;;
        esac
    fi
    if [ "$dry" -eq 1 ]; then
        echo "would create $vault/.himmel/profiles/$profile.conf"
    else
        link_vault
        mkdir -p "$vault/.himmel/profiles" 2>/dev/null || die_create "$vault/.himmel/profiles"
        if [ ! -e "$vault/.himmel/profiles/$profile.conf" ]; then
            { : > "$vault/.himmel/profiles/$profile.conf"; } 2>/dev/null || die_create "$vault/.himmel/profiles/$profile.conf"
            echo "created $vault/.himmel/profiles/$profile.conf"
        fi
    fi
fi

[ -n "$envfile" ] || envfile=$(_load_dotenv_envfile "")
if [ -z "$envfile" ] || [ ! -f "$envfile" ]; then
    echo "migrate-env-config: no .env found; nothing to migrate."
    exit 0
fi

# Key names only: the text before '=' on each uncommented line.
# The shared registry includes non-secret Jira and service identifiers, so
# both the dry run and the copy use the same classification as load_dotenv.
names=$(awk '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } {
    i = index($0, "="); if (i == 0) next
    k = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
    if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(k in seen)) { seen[k] = 1; print k }
}' "$envfile")

config_keys=() policy_keys=()
for key in $names; do
    case "$(_himmel_key_class "$key")" in
        # An env-only key stays in .env; himmel.conf never serves it.
        config) _himmel_env_only_key "$key" || config_keys[${#config_keys[@]}]="$key" ;;
        policy) policy_keys[${#policy_keys[@]}]="$key" ;;
    esac
done

[ -n "$vault" ] && [ "$dry" -eq 0 ] && link_vault

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
