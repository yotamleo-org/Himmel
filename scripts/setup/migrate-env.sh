#!/usr/bin/env bash
# migrate-env.sh — move every himmel .env item to where it now lives, in one
# step: behaviour keys to ~/.himmel/himmel.conf, gate-policy keys to
# ~/.himmel/config.json .policy, himmel secrets nothing in himmel reads to
# ~/.config/secrets/himmel.env. Secrets something reads stay in .env. A key
# is himmel's when .env.example names it or the key-class registry lists it;
# every other key stays in .env untouched.
# Layer table: docs/internals/config-layers.md. The update runs this after a
# dry run the user confirms.
#
#   bash scripts/setup/migrate-env.sh [--env <file>]
#   bash scripts/setup/migrate-env.sh --dry-run [--env <file>]
#
#   --env <file>   the .env to migrate (default: the one load_dotenv reads)
#   --dry-run      print the plan; write nothing
#
# Order: plan, backup (~/.himmel/env-backups, mode 600), copy, verify, and only
# then remove the moved lines from .env. Verify runs the real readers (shell
# load_dotenv and load_policy, the Jira CLI's config, handover-root and release
# readers, the lanes resolver) with the keys only in .env, then only in their
# new place; any difference names the key and reader and removes no line.
# Every gate-policy key is compared, moved or not.
#
# A secret "has a reader" when its name appears as a word in a tracked himmel
# file other than docs and Markdown. Secrets named in ~/.himmel/env-keep.txt
# (one per line, # comments) always stay, for readers outside this checkout;
# behaviour and policy keys always move. When the
# reader search itself fails, every himmel secret stays.
#
# Values never reach stdout or stderr: only key names are printed. Inside an
# agent session (CLAUDECODE set) it prints the plan and the command for the
# operator, and writes nothing (exit 3), since an agent may not write
# ~/.himmel/config.json.
#
# Exit: 0 moved, nothing to move, no .env or a dry run; 1 a step failed: no
# node, or the backup, copy or verify failed (no line removed from .env), or
# the final rewrite of .env failed (restore it from the printed backup);
# 2 usage; 3 an agent session, nothing written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/scripts/lib/load-dotenv.sh"
# shellcheck source=../lib/load-dotenv.sh
. "$LIB"

envfile="" dry=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env)
            [ "$#" -ge 2 ] || { echo "migrate-env: --env needs a value" >&2; exit 2; }
            envfile="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "migrate-env: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$envfile" ] || envfile=$(_load_dotenv_envfile "")
if [ -z "$envfile" ] || [ ! -f "$envfile" ]; then
    echo "migrate-env: no .env found; nothing to migrate."
    exit 0
fi
case "$envfile" in /*) ;; *) envfile="$(cd "$(dirname "$envfile")" && pwd)/${envfile##*/}" ;; esac

confdir=$(_himmel_config_dir)
# shellcheck disable=SC2088 # shown to the user as written, never expanded
store_rel="~/.config/secrets/himmel.env"
store="$HOME/.config/secrets/himmel.env"

# Key names only: the text before '=' on each uncommented line.
names=$(awk '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } {
    i = index($0, "="); if (i == 0) next
    k = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
    if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(k in seen)) { seen[k] = 1; print k }
}' "$envfile")
[ -n "$names" ] || { echo "migrate-env: $envfile holds no keys; nothing to migrate."; exit 0; }

keep=" "
if [ -f "$confdir/env-keep.txt" ]; then
    keep=" $(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$confdir/env-keep.txt" | grep . | tr '\n' ' ')"
fi
# himmel's keys: every name .env.example sets, commented or not.
owned=" $(sed -n 's/^#\{0,1\}[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$ROOT/.env.example" 2>/dev/null | tr '\n' ' ')"
is_owned() {
    case "$owned" in *" $1 "*) return 0 ;; esac
    [ "$(_himmel_key_class "$1")" != secret ]
}

# Readers of each secret: the first tracked file naming it, docs excluded.
secrets=""
for key in $names; do
    case "$keep" in *" $key "*) continue ;; esac
    is_owned "$key" || continue
    [ "$(_himmel_key_class "$key")" = secret ] && secrets="$secrets $key"
done
readers="" have_git=1
if [ -n "$secrets" ]; then
    pats=()
    for key in $secrets; do pats[${#pats[@]}]="-e"; pats[${#pats[@]}]="$key"; done
    # git grep exits 1 for no match; anything else means the search failed.
    hits=$(git -C "$ROOT" grep -I -w -F -o "${pats[@]}" -- . ':!*.md' ':!docs/' ':!.env.example' \
        ':!scripts/setup/migrate-env*' ':!scripts/setup/test-migrate-env*' 2>/dev/null)
    case $? in
        0) readers=$(printf '%s\n' "$hits" | awk -F: '!($NF in s) { s[$NF] = 1; print $NF, $1 }') ;;
        1) ;;
        *) have_git=0 ;;
    esac
fi

config_keys=() policy_keys=() secret_keys=() plan=""
for key in $names; do
    if ! is_owned "$key"; then plan="$plan  $key stays (not himmel's, left in place)"$'\n'; continue; fi
    case "$(_himmel_key_class "$key")" in
        config) config_keys[${#config_keys[@]}]="$key"; plan="$plan  $key → ~/.himmel/himmel.conf"$'\n' ;;
        policy) policy_keys[${#policy_keys[@]}]="$key"; plan="$plan  $key → ~/.himmel/config.json .policy"$'\n' ;;
        *)
            reader=$(printf '%s\n' "$readers" | awk -v k="$key" '$1 == k { print $2; exit }')
            if case "$keep" in *" $key "*) true ;; *) false ;; esac; then
                plan="$plan  $key stays (keep-list)"$'\n'
            elif [ "$have_git" -eq 0 ]; then
                plan="$plan  $key stays (its readers could not be searched)"$'\n'
            elif [ -n "$reader" ]; then
                plan="$plan  $key stays (read by $reader)"$'\n'
            else
                secret_keys[${#secret_keys[@]}]="$key"; plan="$plan  $key → $store_rel"$'\n'
            fi ;;
    esac
done
moving=$(( ${#config_keys[@]} + ${#policy_keys[@]} + ${#secret_keys[@]} ))

echo "env migration for $envfile (key names only):"
printf '%s' "$plan"
if [ "$moving" -eq 0 ]; then
    echo "nothing to move: every key stays in .env."
    exit 0
fi
bdir="$confdir/env-backups"
if [ "$dry" -eq 1 ] || [ -n "${CLAUDECODE:-}" ]; then
    echo "backup: the apply first copies .env to $bdir/env.<UTC time>.<pid> (mode 600)"
fi
[ "$dry" -eq 0 ] || { echo "dry run: nothing written."; exit 0; }
if [ -n "${CLAUDECODE:-}" ]; then
    echo "migrate-env: an agent session cannot write ~/.himmel/config.json; nothing written."
    printf 'Run this at your own prompt:\n  bash %q --env %q\n' "$HERE/migrate-env.sh" "$envfile"
    exit 3
fi
command -v node >/dev/null 2>&1 || { echo "migrate-env: node is needed to write and verify the config; nothing written." >&2; exit 1; }

umask 077
# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh"
work=$(tmpdir) || exit 1
trap 'rm -rf "$work"' EXIT

# --- backup ---
backup="$bdir/env.$(date -u +%Y%m%dT%H%M%SZ).$$"
if ! { mkdir -p "$bdir" && chmod 700 "$bdir" && cp "$envfile" "$backup" && chmod 600 "$backup" \
    && cmp -s "$envfile" "$backup"; } 2>/dev/null; then
    echo "migrate-env: could not write the backup $backup; nothing changed." >&2
    exit 1
fi
echo "backup: $backup (mode 600)"
restore_hint() {
    echo "restore: cp $backup $envfile"
    echo "the backup holds your secrets; remove it once you are happy: rm $backup"
}

# The readers, run with the keys only in .env (an empty HOME) or only in their
# new place (the real HOME, an empty .env), in one scratch checkout.
git init -q "$work/repo" && : > "$work/repo/.env"
mkdir -p "$work/home"
read_shell() {  # <home> <reader> KEY... — KEY=value lines, for comparing only
    # shellcheck disable=SC2016 # expanded by the child shell
    env -i HOME="$1" PATH="$PATH" bash -c '
        . "$1"; reader=$2; shift 2
        if [ "$reader" = load_policy ]; then load_policy --root "$PWD" "$@" || exit 1
        else load_dotenv --root "$PWD" "$@" || exit 1; fi
        for k; do printf "%s=%s\n" "$k" "${!k-}"; done' _ "$LIB" "$2" "${@:3}" 2>/dev/null
}
value_of() {  # <lines> <key>, one dotenv quote pair dropped
    printf '%s\n' "$1" | awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2)
        c = substr(v, 1, 1); if (length(v) > 1 && (c == "\"" || c == "'\''") && substr(v, length(v), 1) == c) v = substr(v, 2, length(v) - 2)
        print v; exit }'
}

policy_all=$( { node -e 'process.stdout.write(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).policy || {}).join("\n"))' \
    "$ROOT/docs/setup/himmel-config.example.json" 2>/dev/null; echo
    printf '%s\n' ${policy_keys[@]+"${policy_keys[@]}"}; } | grep . | sort -u | tr '\n' ' ')
policy_all=${policy_all% }
if [ -n "$policy_all" ]; then
    # shellcheck disable=SC2086 # word-split key names
    if ! policy_before=$(cd "$work/repo" && read_shell "$HOME" load_policy $policy_all); then
        echo "migrate-env: ~/.himmel/config.json cannot be read; nothing changed." >&2
        restore_hint
        exit 1
    fi
fi

# --- copy ---
if [ "${#config_keys[@]}" -gt 0 ]; then
    if ! out=$(bash "$HERE/migrate-env-config.sh" --env "$envfile" 2>&1); then
        printf '%s\n' "$out" >&2
        echo "migrate-env: behaviour keys not copied; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
fi
if [ "${#policy_keys[@]}" -gt 0 ]; then
    # Values go to node on stdin, never argv. A key config.json already holds
    # is left alone; verify then says whether the two disagree.
    if ! for key in "${policy_keys[@]}"; do
            line=$(_load_dotenv_extract "$envfile" "$key")
            printf '%s=%s\n' "$key" "$(_load_dotenv_trim "${line#*=}")"
        done | node -e '
            const fs = require("fs");
            const file = process.argv[1];
            const doc = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : { version: 1 };
            if (!doc || typeof doc !== "object" || Array.isArray(doc)) process.exit(3);
            if (doc.policy === undefined || doc.policy === null) doc.policy = {};
            if (typeof doc.policy !== "object" || Array.isArray(doc.policy)) process.exit(3);
            for (const line of fs.readFileSync(0, "utf8").split("\n")) {
                const i = line.indexOf("=");
                if (i < 1) continue;
                const key = line.slice(0, i);
                let v = line.slice(i + 1);
                if (v.length > 1 && (v[0] === "\"" || v[0] === "\x27") && v.endsWith(v[0])) v = v.slice(1, -1);
                if (doc.policy[key] === undefined || doc.policy[key] === null) doc.policy[key] = v;
            }
            const tmp = file + ".migrate-env.tmp";
            fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", { mode: 0o600 });
            if (fs.existsSync(file)) fs.chmodSync(tmp, fs.statSync(file).mode & 0o777);
            fs.renameSync(tmp, file);
        ' "$confdir/config.json" 2>/dev/null; then
        echo "migrate-env: could not write ~/.himmel/config.json; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
fi
# ponytail: secrets go to one mode-600 file, not a keyring; upgrade path: this
# function writes to the himmel keyring store once that ships.
store_secret() {  # <key>
    local line have
    line=$(awk -v k="$1" '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } { i = index($0, "=")
        n = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n) } i && n == k { print; exit }' "$envfile")
    have=$(_load_dotenv_extract "$store" "$1" 2>/dev/null)
    if [ -n "$have" ]; then
        [ "$have" = "$(_load_dotenv_extract "$envfile" "$1")" ]
        return
    fi
    { [ ! -s "$store" ] || [ -z "$(tail -c 1 "$store")" ] || printf '\n' >> "$store"; } && printf '%s\n' "$line" >> "$store"
}
if [ "${#secret_keys[@]}" -gt 0 ]; then
    if ! { mkdir -p "$HOME/.config" && { [ -d "$HOME/.config/secrets" ] || mkdir -m 700 "$HOME/.config/secrets"; } \
        && { [ -e "$store" ] || : > "$store"; } && chmod 600 "$store"; } 2>/dev/null; then
        echo "migrate-env: could not write $store_rel; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
    for key in "${secret_keys[@]}"; do
        if ! store_secret "$key" 2>/dev/null; then
            echo "MISMATCH $key ($store_rel already holds a different value, or it cannot be written)"
            echo "no lines were removed from .env."
            restore_hint
            exit 1
        fi
    done
fi

# --- verify ---
bad="" verified="load_dotenv"
cp "$envfile" "$work/repo/.env"
if [ "${#config_keys[@]}" -gt 0 ]; then
    before=$(cd "$work/repo" && read_shell "$work/home" load_dotenv "${config_keys[@]}") \
        || bad="${bad}verify: load_dotenv failed reading .env before the move"$'\n'
fi
if [ -n "$policy_all" ]; then
    verified="$verified, load_policy"
    # shellcheck disable=SC2086 # word-split key names
    policy_env=$(cd "$work/repo" && read_shell "$work/home" load_policy $policy_all) \
        || bad="${bad}verify: load_policy failed reading .env before the move"$'\n'
fi
if [ "${#config_keys[@]}" -gt 0 ]; then
    if ! nodeout=$(node "$HERE/migrate-env-verify.mjs" "$work/repo" "$envfile" "$work/home" "$HOME" "$ROOT" "${config_keys[@]}" 2>&1); then
        bad="$bad$(printf '%s\n' "$nodeout" | grep -E '^(MISMATCH|verify:) ')"$'\n'
        [ -n "$(printf '%s' "$bad" | tr -d '\n')" ] || bad="${bad}verify: the node readers failed to run"$'\n'
    fi
    rl=$(printf '%s\n' "$nodeout" | sed -n 's/^readers: //p')
    [ -z "$rl" ] || verified="$verified, $rl"
fi
: > "$work/repo/.env"
if [ "${#config_keys[@]}" -gt 0 ]; then
    after=$(cd "$work/repo" && read_shell "$HOME" load_dotenv "${config_keys[@]}") \
        || bad="${bad}verify: load_dotenv failed reading ~/.himmel after the move"$'\n'
    for key in "${config_keys[@]}"; do
        [ "$(value_of "$before" "$key")" = "$(value_of "$after" "$key")" ] || bad="${bad}MISMATCH $key (load_dotenv)"$'\n'
    done
fi
if [ -n "$policy_all" ]; then
    # shellcheck disable=SC2086 # word-split key names
    if ! policy_after=$(cd "$work/repo" && read_shell "$HOME" load_policy $policy_all); then
        bad="${bad}verify: load_policy cannot read ~/.himmel/config.json after the move"$'\n'
    fi
    for key in $policy_all; do
        case " ${policy_keys[*]-} " in
            *" $key "*) want=$(value_of "$policy_env" "$key") ;;
            *) want=$(value_of "$policy_before" "$key") ;;
        esac
        [ "$want" = "$(value_of "$policy_after" "$key")" ] || bad="${bad}MISMATCH $key (load_policy)"$'\n'
    done
fi
if [ -n "$(printf '%s' "$bad" | tr -d '\n')" ]; then
    printf '%s' "$bad" | grep .
    echo "verify failed: a reader sees a different value after the move than .env holds, so no lines were removed from .env."
    echo "fix the reader, or make ~/.himmel agree with .env, then run this again."
    restore_hint
    exit 1
fi

# --- remove the moved lines, in place so .env keeps its mode ---
if ! cmp -s "$envfile" "$backup"; then
    echo "migrate-env: $envfile changed during the migration; no lines were removed from .env." >&2
    restore_hint
    exit 1
fi
moved=" ${config_keys[*]-} ${policy_keys[*]-} ${secret_keys[*]-} "
awk -v moved="$moved" '{ l = $0; sub(/\r$/, "", l) }
    l ~ /^[[:space:]]*#/ { print; next }
    { i = index(l, "="); k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
    i && k != "" && index(moved, " " k " ") { next }
    { print }' "$backup" > "$work/env.new" || {
    echo "migrate-env: could not build the new .env; no lines were removed from .env." >&2
    restore_hint
    exit 1
}
if ! cat "$work/env.new" > "$envfile"; then
    echo "migrate-env: could not rewrite $envfile; restore it from the backup." >&2
    restore_hint
    exit 1
fi

echo "verified: $verified"
[ -z "$policy_all" ] || echo "policy compared: $policy_all"
echo "moved $moving key(s); removed their lines from .env."
restore_hint
