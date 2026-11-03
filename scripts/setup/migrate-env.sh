#!/usr/bin/env bash
# migrate-env.sh — move every himmel .env item to where it now lives, in one
# step: behaviour keys to ~/.himmel/himmel.conf, gate-policy keys to
# ~/.himmel/config.json .policy, himmel secrets to the OS keyring through
# `himmel-secrets import-env`. A key is himmel's when .env.example names it or
# the key-class registry lists it; every other key stays in .env untouched.
# Layer table: docs/internals/config-layers.md. The update runs this after a
# dry run the user confirms.
#
#   bash scripts/setup/migrate-env.sh [-y] [--env <file>]
#   bash scripts/setup/migrate-env.sh --dry-run [--env <file>]
#
#   --env <file>   the .env to migrate (default: the one load_dotenv reads)
#   --dry-run      print the plan, one `name  class  destination` row per .env
#                  key (never a value); write nothing
#   -y             the operator's yes. The apply reads no typed yes: without -y,
#                  at a terminal, it prints the plan and refuses (exit 3)
#
# Order: plan, backup (~/.himmel/env-backups, mode 600), copy, secrets to the
# keyring, verify, and only then remove the moved lines from .env. Verify runs the
# real readers (shell load_dotenv and load_policy, the Jira CLI's config,
# handover-root and release readers, the lanes resolver) with the keys only in
# .env, then only in their new place; any difference names the key and reader
# and removes no line.
#
# Secrets: import-env prints stored|held|failed|skipped per key. A key leaves
# .env only on `stored` (the value read back from the keyring alone); `held` (the
# keyring has another value) and keys named in ~/.himmel/env-keep.txt stay. A
# `failed` key stops the run with no line removed. After the .env rewrite every
# file in ~/.himmel/env-backups loses its manifest-secret lines, and a legacy
# ~/.config/secrets/himmel.env is imported and emptied of what it stored. The
# secrets stage runs only with -y, at a terminal, outside an agent session, on
# every consent path: ENV_MIGRATION_CONSENT covers the other keys alone. With no
# unlocked keyring the run is incomplete: a secret nothing reads goes to the
# legacy file, the rest stay in .env, a WARN names them, and the apply exits 4.
# Every gate-policy key is compared, moved or not. A behaviour key whose .env
# line has an inline comment stays (the loader drops the comment, the node
# readers keep it), and the plan names it.
#
# A key whose ~/.himmel side (himmel.conf or config.json .policy) already held
# a different value is the operator's to settle: the apply names both sides,
# never the values, and asks which to keep: e (the .env value is written to
# ~/.himmel) or h (the ~/.himmel value stays). It then verifies again. Any other
# answer, or none, stops with no line removed from .env. The report lists the
# secrets that stay in .env.
#
# Secrets named in ~/.himmel/env-keep.txt (one per line, # comments) always
# stay, for readers outside this checkout; behaviour and policy keys always
# move. With no keyring a secret "has a reader" when its name appears as a word
# in a tracked himmel file other than docs and Markdown; when that search
# fails, every himmel secret stays.
#
# Values never reach stdout or stderr: only key names are printed. The apply
# prints the plan, then moves the keys only with -y, at a terminal. With no
# terminal on stdin, or inside an agent session (CLAUDECODE set, since an agent
# may not write ~/.himmel/config.json), it prints the plan and the command for
# the operator, and writes nothing. The operator can consent once instead:
# ENV_MIGRATION_CONSENT=1 in ~/.himmel/config.json .policy, read from that
# file alone (never the process env or .env), stands in for -y on the
# behaviour keys, so an unattended or agent-run update finishes that move.
# Backup and verify still run, and a key whose two sides differ still stops
# with nothing removed. The consent covers only this checkout's .env and this
# account's own ~/.himmel, and gate-policy keys stay in .env until the operator
# moves them at a prompt.
#
# Exit: 0 moved, nothing to move, no .env or a dry run; 1 a step failed: no
# node, the account's home could not be read from its passwd entry, or the
# backup, copy, secrets or verify step failed (no line removed from .env), or
# the final rewrite of .env failed (restore it from the printed backup); 2
# usage; 3 nothing written: an agent session or no terminal without the consent
# key, or no -y; 4 moved, but incomplete: no unlocked keyring for the secrets;
# 96 a chokepoint seam differs from the session's launch env.
set -uo pipefail

# The consent is read from the policy dir, so the seam that moves that dir is
# refused when it differs from the session's launch env.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "migrate-env.sh: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/setup/migrate-env.sh || exit 96

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/scripts/lib/load-dotenv.sh"
# shellcheck source=../lib/load-dotenv.sh
. "$LIB"
# Every write below leaves an audit row against one backup of the
# full set. A checkout without the lib (a fixture copy) writes unaudited.
if [ -f "$ROOT/scripts/lib/config-audit.sh" ]; then
    # shellcheck source=../lib/config-audit.sh
    . "$ROOT/scripts/lib/config-audit.sh"
else
    config_audit_pre() { :; }
    config_audit_post() { :; }
fi

envfile="" dry=0 yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env)
            [ "$#" -ge 2 ] || { echo "migrate-env: --env needs a value" >&2; exit 2; }
            envfile="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -y) yes=1; shift ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
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
key_names() {  # <file>
    awk '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } {
        i = index($0, "="); if (i == 0) next
        k = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(k in seen)) { seen[k] = 1; print k }
    }' "$1"
}
names=$(key_names "$envfile")
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

# The secret key set and the keyring state both come from the resolver, the one
# owner of each (I4): no list of secrets lives here.
hs="$ROOT/scripts/lib/himmel-secrets"
secret_names=" $(bash "$hs" names --class secret 2>/dev/null | tr '\n' ' ')"
kstate=$(bash "$hs" status 2>/dev/null | sed -n 's/^keyring: //p')
backend_ok=0
[ "$kstate" != unlocked ] || backend_ok=1

# With no keyring: readers of each secret, the first tracked file naming it, docs excluded.
secrets=""
if [ "$backend_ok" -eq 0 ]; then
    for key in $names; do
        case "$keep" in *" $key "*) continue ;; esac
        is_owned "$key" || continue
        case "$secret_names" in *" $key "*) ;; *) continue ;; esac
        [ "$(_himmel_key_class "$key")" = secret ] && secrets="$secrets $key"
    done
fi
readers="" have_git=1
if [ -n "$secrets" ]; then
    pats=()
    for key in $secrets; do pats[${#pats[@]}]="-e"; pats[${#pats[@]}]="$key"; done
    # git grep exits 1 for no match; anything else means the search failed.
    hits=$(git -C "$ROOT" grep -I -w -F -o "${pats[@]}" -- . ':!*.md' ':!docs/' ':!.env.example' \
        ':!scripts/himmelctl/lib/secrets-manifest.json' \
        ':!scripts/setup/migrate-env*' ':!scripts/setup/test-migrate-env*' 2>/dev/null)
    case $? in
        0) readers=$(printf '%s\n' "$hits" | awk -F: '!($NF in s) { s[$NF] = 1; print $NF, $1 }') ;;
        1) ;;
        *) have_git=0 ;;
    esac
fi

config_keys=() policy_keys=() secret_keys=() file_keys=() legacy_keys=() plan="" stay_secrets="" commented=" " incomplete=0
# The shell loader drops an unquoted trailing comment and the node readers keep it,
# so such a line would read differently after the move: it stays.
has_inline_comment() {  # <key>
    local line ext
    line=$(awk -v k="$1" '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } { i = index($0, "=")
        n = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n) } i && n == k { print substr($0, i + 1); exit }' "$envfile")
    ext=$(_load_dotenv_extract "$envfile" "$1")
    [ "$(_load_dotenv_trim "$line")" != "$(_load_dotenv_trim "${ext#*=}")" ]
}
for key in $names; do
    if ! is_owned "$key"; then plan="$plan  $key  unrelated  stays (not himmel's, left in place)"$'\n'; continue; fi
    case "$(_himmel_key_class "$key")" in
        config)
            # An env-only key has no himmel.conf reader: it stays in .env, as in migrate-env-config.sh.
            if _himmel_env_only_key "$key"; then plan="$plan  $key  config  stays (env-only: no himmel.conf reader)"$'\n'
            elif has_inline_comment "$key"; then commented="$commented$key "; plan="$plan  $key  config  stays (its .env line has an inline comment the readers do not agree on; remove the comment to move it)"$'\n'
            else config_keys[${#config_keys[@]}]="$key"; plan="$plan  $key  config  → ~/.himmel/himmel.conf"$'\n'; fi ;;
        policy) policy_keys[${#policy_keys[@]}]="$key"; plan="$plan  $key  config (policy)  → ~/.himmel/config.json .policy"$'\n' ;;
        *)
            reader=$(printf '%s\n' "$readers" | awk -v k="$key" '$1 == k { print $2; exit }')
            if case "$keep" in *" $key "*) true ;; *) false ;; esac; then
                stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  kept (env-keep)"$'\n'
            elif case "$secret_names" in *" $key "*) false ;; *) true ;; esac; then
                stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (not in the secrets manifest)"$'\n'
            elif [ "$backend_ok" -eq 1 ]; then
                secret_keys[${#secret_keys[@]}]="$key"; plan="$plan  $key  secret  → keyring"$'\n'
            else
                incomplete=1
                if [ "$have_git" -eq 0 ]; then
                    stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (no keyring; its readers could not be searched)"$'\n'
                elif [ -n "$reader" ]; then
                    stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (no keyring; read by $reader)"$'\n'
                else
                    file_keys[${#file_keys[@]}]="$key"; plan="$plan  $key  secret  → $store_rel (no keyring)"$'\n'
                fi
            fi ;;
    esac
done
# A legacy secrets file moves into the keyring too, once there is one.
if [ "$backend_ok" -eq 1 ] && [ -s "$store" ]; then
    for key in $(key_names "$store"); do
        case "$keep" in *" $key "*) continue ;; esac
        case "$secret_names" in *" $key "*) ;; *) continue ;; esac
        legacy_keys[${#legacy_keys[@]}]="$key"; plan="$plan  $key  secret  → keyring (from $store_rel)"$'\n'
    done
fi
moving=$(( ${#config_keys[@]} + ${#policy_keys[@]} + ${#secret_keys[@]} + ${#file_keys[@]} + ${#legacy_keys[@]} ))

echo "env migration for $envfile (key names only):"
printf '%s' "$plan"
[ -z "$stay_secrets" ] || echo "secrets stay in .env:$stay_secrets"
if [ "$incomplete" -eq 1 ]; then
    echo "migrate-env: WARN no keyring backend (keyring: ${kstate:-absent}); secrets cannot reach the keyring, so this run is incomplete (exit 4 on an apply)."
    echo "unlock the keyring or install a Secret Service, then run this again."
fi
if [ "$moving" -eq 0 ]; then
    echo "nothing to move: every key stays in .env."
    exit 0
fi
bdir="$confdir/env-backups"
echo "backup: the apply first copies .env (mode 600) to $bdir/env.<UTC time>.<pid>"
[ "$dry" -eq 0 ] || { echo "dry run: nothing written."; exit 0; }
apply_cmd=$(printf 'bash %q --env %q -y' "$HERE/migrate-env.sh" "$envfile")
poldir=$(_himmel_policy_dir) || { echo "migrate-env: cannot read this account's home from its passwd entry; nothing written." >&2; exit 1; }
consent=0 cv=""
if [ -f "$poldir/config.json" ] \
    && cv=$(_himmel_policy_json "$poldir/config.json" ENV_MIGRATION_CONSENT) \
    && [ "$(_himmel_policy_strict ENV_MIGRATION_CONSENT "${cv#ENV_MIGRATION_CONSENT=}")" = 0 ]; then
    consent=1
    echo "migrate-env: ENV_MIGRATION_CONSENT is set in ~/.himmel/config.json; moving without a prompt."
else
    if [ -n "${CLAUDECODE:-}" ]; then
        echo "migrate-env: an agent session cannot write ~/.himmel/config.json; nothing written."
        printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
        exit 3
    fi
    if [ ! -t 0 ]; then
        echo "migrate-env: no terminal to confirm the move at; nothing written."
        printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
        exit 3
    fi
fi
if [ "$consent" -eq 1 ]; then
    # The consent covers this checkout's own .env moving into this account's
    # own ~/.himmel, and never writes a gate-policy key: those move only at the
    # operator's own prompt, so an agent cannot fill policy through it.
    if ! [ "$envfile" -ef "$ROOT/.env" ]; then
        echo "migrate-env: the consent covers only this checkout's .env, not $envfile; nothing written."
        printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
        exit 3
    fi
    if [ "${HOME%/}/.himmel" != "$poldir" ] || [ "${confdir%/}" != "$poldir" ]; then
        echo "migrate-env: the consent covers only this account's own ~/.himmel, and HOME or HIMMEL_CONFIG_DIR points elsewhere; nothing written."
        printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
        exit 3
    fi
    if [ "${#policy_keys[@]}" -gt 0 ]; then
        echo "migrate-env: gate-policy keys move only at your own prompt; these stay in .env: ${policy_keys[*]}"
        printf 'To move them, run this at your own prompt:\n  %s\n' "$apply_cmd"
        moving=$(( moving - ${#policy_keys[@]} )) policy_keys=()
        [ "$moving" -gt 0 ] || { echo "nothing else to move; nothing written."; exit 3; }
    fi
fi
# Moving live credentials into the keyring is a step a person starts (OS-1): -y, a
# terminal and no agent session, whichever way the other keys were allowed. The
# consent does not stand in for them.
secrets_refusal=""
if [ -n "${CLAUDECODE:-}" ]; then secrets_refusal="an agent session cannot move secrets"
elif [ ! -t 0 ]; then secrets_refusal="no terminal to move secrets at"
elif [ "$yes" -ne 1 ]; then secrets_refusal="moving secrets needs -y"; fi
if [ "$consent" -eq 1 ] && [ -n "$secrets_refusal" ] && [ $(( ${#secret_keys[@]} + ${#legacy_keys[@]} )) -gt 0 ]; then
    echo "migrate-env: $secrets_refusal; they stay in .env: ${secret_keys[*]-} ${legacy_keys[*]-}"
    printf 'To move them, run this at your own prompt:\n  %s\n' "$apply_cmd"
    moving=$(( moving - ${#secret_keys[@]} - ${#legacy_keys[@]} )) secret_keys=() legacy_keys=()
    [ "$moving" -gt 0 ] || { echo "nothing else to move; nothing written."; exit 3; }
fi
command -v node >/dev/null 2>&1 || { echo "migrate-env: node is needed to write and verify the config; nothing written." >&2; exit 1; }
if [ "$consent" -eq 0 ] && [ "$yes" -ne 1 ]; then
    echo "migrate-env: nothing written; rerun with -y"
    printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
    exit 3
fi

umask 077
# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh"
work=$(tmpdir) || exit 1
next=""
trap 'rm -rf "$work"; [ -z "$next" ] || [ -L "$envfile" ] || rm -f "$next"' EXIT
trap 'exit 1' HUP INT TERM

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
    echo "the backup can hold your secrets until a run ends cleanly; remove it once you are happy: rm $backup"
}
ca_bid=$(HIMMEL_CONFIG_AUDIT_ENV_FILE="$envfile" config_audit_pre "$poldir/config.json" migrate-env.sh)
ca_post() {  # <file> <action>
    HIMMEL_CONFIG_AUDIT_ENV_FILE="$envfile" config_audit_post "$ca_bid" "$1" "$2" migrate-env.sh
}

# The readers, run with the keys only in .env (an empty HOME, the policy dir
# pointed at it) or only in their new place (the real HOME, an empty .env), in
# one scratch checkout.
git init -q "$work/repo" && : > "$work/repo/.env"
mkdir -p "$work/home"
read_shell() {  # <home> <reader> KEY... — KEY=value lines, for comparing only
    local follow=${HIMMEL_POLICY_FOLLOWS_HOME-}
    [ "$1" != "$work/home" ] || follow=1
    # shellcheck disable=SC2016 # expanded by the child shell
    env -i HOME="$1" PATH="$PATH" HIMMEL_POLICY_FOLLOWS_HOME="$follow" bash -c '
        . "$1"; reader=$2; shift 2  # read-sink-ok: $1 is always the checkout load-dotenv.sh
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

write_policy() {  # <force 0|1> KEY...: the .env values into config.json .policy
    local force=$1 key line
    shift
    mkdir -p "$poldir" 2>/dev/null || return 1
    # Values go to node on stdin, never argv. A key config.json already holds
    # is kept unless force is 1.
    for key in "$@"; do
        line=$(_load_dotenv_extract "$envfile" "$key")
        printf '%s=%s\n' "$key" "$(_load_dotenv_trim "${line#*=}")"
    done | node -e '
        const fs = require("fs");
        const file = process.argv[1];
        const force = process.argv[2] === "1";
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
            if (force || doc.policy[key] === undefined || doc.policy[key] === null) doc.policy[key] = v;
        }
        const tmp = file + ".migrate-env.tmp";
        fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", { mode: 0o600 });
        if (fs.existsSync(file)) fs.chmodSync(tmp, fs.statSync(file).mode & 0o777);
        fs.renameSync(tmp, file);
    ' "$poldir/config.json" "$force" 2>/dev/null
}
set_line() {  # <in> <key> <line> <out>: <in> with the key's lines replaced by <line>; comments stay
    NEWLINE="$3" awk -v k="$2" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { print; next }
        { i = index(l, "="); n = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n) }
        i && n == k { if (!done) print ENVIRON["NEWLINE"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["NEWLINE"] }' "$1" > "$4"
}

# Keys whose ~/.himmel side already holds a value, before anything is copied:
# if verify finds one of these differing, the operator picks which side wins.
held=" "
for key in ${config_keys[@]+"${config_keys[@]}"}; do
    [ -f "$confdir/himmel.conf" ] && [ -n "$(_load_dotenv_extract "$confdir/himmel.conf" "$key")" ] && held="$held$key "
done
for key in ${policy_keys[@]+"${policy_keys[@]}"}; do
    [ -n "$(value_of "${policy_before-}" "$key")" ] && held="$held$key "
done

# --- copy ---
if [ "${#config_keys[@]}" -gt 0 ]; then
    # The copy step takes every behaviour key it finds, so the commented ones are left out of its input.
    awk -v skip="$commented" '{ l = $0; sub(/\r$/, "", l) }
        l !~ /^[[:space:]]*#/ { i = index(l, "="); n = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
            if (i && index(skip, " " n " ")) next }
        { print }' "$envfile" > "$work/env.copy" \
        || { echo "migrate-env: could not stage .env for the copy; no lines were removed from .env." >&2; exit 1; }
    if ! out=$(bash "$HERE/migrate-env-config.sh" --env "$work/env.copy" 2>&1); then
        printf '%s\n' "$out" >&2
        echo "migrate-env: behaviour keys not copied; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
    ca_post "$confdir/himmel.conf" migrate
fi
if [ "${#policy_keys[@]}" -gt 0 ]; then
    # A key config.json already holds is left alone; verify then says whether
    # the two disagree.
    if ! write_policy 0 "${policy_keys[@]}"; then
        echo "migrate-env: could not write ~/.himmel/config.json; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
    ca_post "$poldir/config.json" migrate
fi
# ponytail: with no keyring a secret nothing reads goes to one mode-600 file; upgrade
# path: a host with a Secret Service never takes this path, and the file is
# imported into the keyring on the first run after one appears.
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
if [ "${#file_keys[@]}" -gt 0 ]; then
    if ! { mkdir -p "$HOME/.config" && { [ -d "$HOME/.config/secrets" ] || mkdir -m 700 "$HOME/.config/secrets"; } \
        && { [ -e "$store" ] || : > "$store"; } && chmod 600 "$store"; } 2>/dev/null; then
        echo "migrate-env: could not write $store_rel; no lines were removed from .env." >&2
        restore_hint
        exit 1
    fi
    for key in "${file_keys[@]}"; do
        if ! store_secret "$key" 2>/dev/null; then
            echo "MISMATCH $key ($store_rel already holds a different value, or it cannot be written)"
            echo "no lines were removed from .env."
            restore_hint
            exit 1
        fi
    done
fi

# --- secrets to the keyring ---
# import-env stores each key, reads it back from the keyring alone, and prints
# stored|held|failed|skipped NAME. Only `stored` keys leave .env (I3). It is
# handed a private copy holding just the secrets this run moves, so a key the plan
# left alone is never imported; the copy lives in $work, which is removed on exit.
stored_keys=" " legacy_stored=" "
run_import() {  # <file> <var for the stored names>: sets imp_out; returns 1 when the run must stop
    local kf=() rc=0 st
    [ ! -f "$confdir/env-keep.txt" ] || kf=(--keep-file "$confdir/env-keep.txt")
    imp_out=$(bash "$hs" import-env ${kf[@]+"${kf[@]}"} "$1" 2>&1) || rc=$?
    printf '%s\n' "$imp_out" | grep -E '^(stored|held|failed|skipped) [A-Za-z_]' | sed 's/^/  /'
    st=$(printf '%s\n' "$imp_out" | sed -n 's/^stored \([A-Za-z_][A-Za-z0-9_]*\)$/\1/p' | tr '\n' ' ')
    printf -v "$2" ' %s' "$st"
    if [ "$rc" -ne 0 ] || printf '%s\n' "$imp_out" | grep -q '^failed '; then
        printf '%s\n' "$imp_out" | grep -v -E '^(stored|held|failed|skipped|imported) ' | sed 's/^/  /'
        return 1
    fi
    if printf '%s\n' "$imp_out" | grep -q '^held '; then
        echo "held keys keep their .env line: the keyring already holds another value for them (settle it with himmel-secrets)."
    fi
    return 0
}
if [ "${#secret_keys[@]}" -gt 0 ]; then
    secret_set=" ${secret_keys[*]} "
    awk -v set="$secret_set" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { next }
        { i = index(l, "="); if (!i) next; k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
        index(set, " " k " ") { print }' "$envfile" > "$work/secrets.env" 2>/dev/null
    if ! run_import "$work/secrets.env" stored_keys; then
        echo "migrate-env: the secrets did not all reach the keyring; no lines were removed from .env."
        restore_hint
        exit 1
    fi
fi
if [ "${#legacy_keys[@]}" -gt 0 ]; then
    if ! run_import "$store" legacy_stored; then
        echo "migrate-env: the legacy secrets file did not all reach the keyring; no lines were removed from .env."
        restore_hint
        exit 1
    fi
fi

# --- verify ---
verify_env="$envfile"   # the .env the readers compare against; a kept ~/.himmel value is swapped in
verify_all() {  # sets bad and verified
    bad="" verified="load_dotenv"
    cp "$verify_env" "$work/repo/.env"
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
        # Each node reader is compared against its own value read from the real .env.
        if ! nodeout=$(node "$HERE/migrate-env-verify.mjs" "$work/repo" "$verify_env" "$work/home" "$HOME" "$ROOT" "${config_keys[@]}" 2>&1); then
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
}
has_bad() { [ -n "$(printf '%s' "$bad" | tr -d '\n')" ]; }
# A copy beside the file (same mode) renamed over it, so a failed write leaves
# the file whole; a symlink is followed to its target, so the link stays.
replace_file() {  # <new content file> <dest>
    local dest="$2" link hops=0 tmp
    while [ -L "$dest" ]; do
        hops=$((hops + 1)); [ "$hops" -le 40 ] || return 1
        link=$(readlink "$dest")
        case "$link" in /*) dest=$link ;; *) dest="${dest%/*}/$link" ;; esac
    done
    tmp="$dest.migrate.$$"
    # prim-ok: cp -p keeps the file's mode, which atomic_write would reset to 600
    if cp -p "$dest" "$tmp" && cat "$1" > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi  # read-sink-ok: $1 is always a scratch file this script built
    rm -f "$tmp"
    return 1
}
verify_all
if has_bad; then
    printf '%s' "$bad" | grep .
    # Every failure a key whose ~/.himmel side held a different value: the
    # operator settles each one, then the readers run again.
    settle=1 keys=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key=$(printf '%s' "$line" | sed -n 's/^MISMATCH \([A-Za-z_][A-Za-z0-9_]*\) (.*/\1/p')
        if [ -z "$key" ] || { case "$held" in *" $key "*) false ;; *) true ;; esac; }; then settle=0; break; fi
        case " $keys " in *" $key "*) ;; *) keys="$keys $key" ;; esac
    done <<< "$bad"
    keep_env="" keep_him=""
    if [ "$settle" -eq 1 ]; then
        echo "these keys hold different values in .env and in ~/.himmel (values not shown):"
        for key in $keys; do
            # shellcheck disable=SC2088 # shown to the user as written, never expanded
            if [ "$(_himmel_key_class "$key")" = policy ]; then side="~/.himmel/config.json .policy"; else side="~/.himmel/himmel.conf"; fi
            printf '  %s: %s  vs  %s\n' "$key" "$envfile" "$side"
            # Only the operator at a terminal settles a difference, never the consent.
            if [ "$consent" -eq 1 ]; then settle=0; continue; fi
            printf 'keep the value in [e] %s or [h] %s? [e/h] ' "$envfile" "$side"
            answer=""
            read -r answer || answer=""
            case "$answer" in
                e|E) keep_env="$keep_env $key" ;;
                h|H) keep_him="$keep_him $key" ;;
                *) printf 'no choice for %s: nothing was removed from .env.\n' "$key"; settle=0; break ;;
            esac
        done
        [ "$consent" -eq 0 ] || printf 'the consent does not settle a difference; run this at your own prompt:\n  %s\n' "$apply_cmd"
    fi
    if [ "$settle" -eq 1 ]; then
        for key in $keep_env; do
            if [ "$(_himmel_key_class "$key")" = policy ]; then
                write_policy 1 "$key"
            else
                set_line "$confdir/himmel.conf" "$key" "$(_load_dotenv_extract "$envfile" "$key")" "$work/conf.new" \
                    && replace_file "$work/conf.new" "$confdir/himmel.conf"
            fi || { echo "migrate-env: could not apply the choice for $key; no lines were removed from .env." >&2; restore_hint; exit 1; }
        done
        if [ -n "$keep_env" ]; then
            ca_post "$poldir/config.json" settle
            ca_post "$confdir/himmel.conf" settle
        fi
        for key in $keep_him; do
            if [ "$(_himmel_key_class "$key")" = policy ]; then
                keptvalue=$(value_of "$policy_before" "$key")
                case "$keptvalue" in *' #'*) keptvalue="\"$keptvalue\"" ;; esac   # an unquoted ' #' reads as a comment
                keptline="$key=$keptvalue"
            else keptline=$(_load_dotenv_extract "$confdir/himmel.conf" "$key"); fi
            if set_line "$verify_env" "$key" "$keptline" "$work/env.verify.new" && mv -f "$work/env.verify.new" "$work/env.verify"; then
                verify_env="$work/env.verify"
            else
                echo "migrate-env: could not build the verify copy for $key; no lines were removed from .env." >&2
                restore_hint
                exit 1
            fi
        done
        verify_all
        has_bad && printf '%s' "$bad" | grep .
    fi
    if [ "$settle" -eq 0 ] || has_bad; then
        echo "verify failed: a reader sees a different value after the move than .env holds, so no lines were removed from .env."
        echo "fix the reader, or make ~/.himmel agree with .env, then run this again."
        restore_hint
        exit 1
    fi
fi

# --- remove the moved lines; .env keeps its mode ---
if ! cmp -s "$envfile" "$backup"; then
    echo "migrate-env: $envfile changed during the migration; no lines were removed from .env." >&2
    restore_hint
    exit 1
fi
moved=" ${config_keys[*]-} ${policy_keys[*]-}${stored_keys}${file_keys[*]-} "
# shellcheck disable=SC2086 # word-split key names
moved_n=$(printf '%s\n' $moved | grep -c .)
awk -v moved="$moved" '{ l = $0; sub(/\r$/, "", l) }
    l ~ /^[[:space:]]*#/ { print; next }
    { i = index(l, "="); k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
    i && k != "" && index(moved, " " k " ") { next }
    { print }' "$backup" > "$work/env.new" || {
    echo "migrate-env: could not build the new .env; no lines were removed from .env." >&2
    restore_hint
    exit 1
}
# A copy beside .env (same mode) renamed over it, so a failed write leaves
# .env whole; a symlinked .env is rewritten in place to keep the link.
next="$envfile.migrate.$$" rewrote=0
if [ -L "$envfile" ]; then
    cat "$work/env.new" > "$envfile" && rewrote=1
else
    cp -p "$envfile" "$next" && cat "$work/env.new" > "$next" && mv -f "$next" "$envfile" && rewrote=1
fi
if [ "$rewrote" -eq 0 ]; then
    echo "migrate-env: could not rewrite $envfile; check it, and restore it from the backup if it is not whole." >&2
    restore_hint
    exit 1
fi
ca_post "$envfile" migrate

# --- scrub: the legacy file and the backups keep no line of a secret the keyring now holds ---
final_rc=0
drop_lines() {  # <set of names> <file>: the file without those keys' lines (`export NAME=` too); mode kept
    awk -v set="$1" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { print; next }
        { i = index(l, "="); k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); sub(/^export[[:space:]]+/, "", k) }
        i && k != "" && index(set, " " k " ") { next }
        { print }' "$2" > "$work/scrub.new" && replace_file "$work/scrub.new" "$2"
}
if [ "${#legacy_keys[@]}" -gt 0 ] && [ "$legacy_stored" != " " ]; then
    drop_lines "$legacy_stored" "$store" \
        || { echo "migrate-env: WARN could not empty $store_rel of the keys it stored; remove those lines by hand."; final_rc=1; }
fi
if [ "$backend_ok" -eq 1 ]; then
    for bfile in "$bdir"/*; do
        [ -f "$bfile" ] && [ ! -L "$bfile" ] || continue
        drop_lines "$secret_names" "$bfile" \
            || { echo "migrate-env: WARN could not scrub the secret lines from $bfile; remove that backup by hand."; final_rc=1; }
    done
fi

echo "verified: $verified"
[ -z "$policy_all" ] || echo "policy compared: $policy_all"
echo "moved $moved_n key(s); removed their lines from .env."
restore_hint
[ "$final_rc" -eq 0 ] || exit 1
[ "$incomplete" -eq 0 ] || exit 4
exit 0
