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
#   --keys A,B     also move these names to the keyring: a name that is not himmel's
#                  and not in the secrets manifest ("unowned"). Each must be a key
#                  in the file (a himmel key in the list moves by its own route);
#                  -y alone never moves an unowned name
#   --unowned      also move every unowned name the plan lists. With -y this is the
#                  one command for the secrets a user placed in an env file:
#                    bash scripts/setup/migrate-env.sh -y --unowned
#
# A named or unowned name is stored through `himmel-secrets put --stdin`, read back
# with `same-value`, and its whole entry leaves the file only on a match (a quoted
# value over several lines goes whole, closing quote included); a value with a
# newline inside it cannot be one keyring item and its entry stays. Every name that
# reached the keyring is then cleared from the systemd user manager with
# `systemctl --user unset-environment`; the report names them and the names still held.
#
# Order: plan, backup (~/.himmel/env-backups, mode 600), copy, secrets to the
# keyring, verify, and only then remove the moved lines from .env. Verify runs the
# real readers (shell load_dotenv and load_policy, the Jira CLI's config,
# handover-root and release readers, the lanes resolver) with the keys only in
# .env, then only in their new place; any difference names the key and reader
# and removes no line.
#
# Secrets: import-env prints stored|held|failed|skipped per key, and shadowed for a
# stored key that a project-scope item with another value is served ahead of. A key
# leaves .env only on `stored` (the value read back from the keyring alone); `held`
# (the keyring has another value, and that one is served) and keys named in
# ~/.himmel/env-keep.txt stay. A `failed` key stops the run with no line removed. A
# blank secret line, and an `export NAME=` line of a himmel key (the readers do not
# read it), stay with a plan row. Every line of a key that moves leaves .env, a later
# duplicate too; this run's backup keeps a duplicate that holds another value.
#
# The scrub: after the .env rewrite, when the secrets stage was allowed, a file in
# ~/.himmel/env-backups and the .env copy in each config-audit backup (manifest
# checksums kept true) lose a manifest-secret key's lines only when every real value
# of that key there (`export` and duplicate lines included) equals the user-scope
# keyring item. An empty or quoted-empty line is no value. .env is no copy for this: a
# config-audit restore overwrites .env from the backup. An env-keep key never leaves.
# Every other line stays, so a placeholder or a NAME="" in .env or the keyring cannot
# cost a real backup-only value. Before you run it with -y, delete every NAME="" or
# placeholder line from .env: it is stored and served like any value. Every exit from
# here on names the keys such lines hold (`keeps a line for`): no-op, dry run or refusal. A keyring that
# is not unlocked cannot be compared, so the report gives its state and names what the
# backups hold; a project-scope item never counts. A run with nothing else to move, or
# with an emptied or missing .env, still finishes an owed scrub. When a .env exists, a
# legacy ~/.config/secrets/himmel.env is imported and loses each key it stored whose
# lines all equal the item. The keyring stage and the scrub run only with -y, at a
# terminal, outside an agent session, on every consent path. With no unlocked keyring
# the run is incomplete: a secret nothing reads goes to the legacy file and leaves .env
# with -y, or under the consent alone, even in an agent session or with no terminal;
# the rest stay in .env, a WARN names them, and the apply exits 4.
# A commented-out secret and a fragment of a multi-line value stay in .env and the
# backups: neither has a key the readers read. An unquoted value with " #" in it is cut
# there by the readers, at import too: quote it first.
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
# behaviour keys, and on a secret nothing reads when there is no unlocked keyring,
# so an unattended or agent-run update finishes that move.
# Backup and verify still run, and a key whose two sides differ still stops
# with nothing removed. The consent covers only this checkout's .env and this
# account's own ~/.himmel, and gate-policy keys stay in .env until the operator
# moves them at a prompt: -y at a terminal outside an agent session is that
# prompt, and there the consent is not read, so the printed command moves them.
# -y with no --env acts only on this checkout's .env: the default follows the
# current directory's git root, so inside another repository it refuses (exit 3).
# The e/h answer above stays typed: it picks one of two values and moves nothing.
#
# Exit: 0 moved, nothing to move, no .env or a dry run; 1 a step failed: no
# node, the account's home could not be read from its passwd entry, or the
# backup, copy, secrets or verify step failed (no line removed from .env), or
# the final rewrite of .env failed (restore it from the printed backup); 2
# usage; 3 nothing written: an agent session or no terminal without the consent
# key, or no -y (also: a scrub-only run without -y), or -y with no --env on a
# .env outside this checkout; 4 moved, but incomplete: no
# unlocked keyring for the secrets (also when nothing else moves);
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
    config_audit_scrub() { :; }
fi

envfile="" dry=0 yes=0 env_given=0 keys_arg="" unowned_all=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keys)
            [ "$#" -ge 2 ] || { echo "migrate-env: --keys needs a list of names" >&2; exit 2; }
            keys_arg="$keys_arg,$2"; shift 2 ;;
        --unowned) unowned_all=1; shift ;;
        --env)
            [ "$#" -ge 2 ] || { echo "migrate-env: --env needs a value" >&2; exit 2; }
            envfile="$2"; env_given=1; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -y) yes=1; shift ;;
        -h|--help) sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/!p;}' "$0"; exit 0 ;;
        *) echo "migrate-env: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$envfile" ] || envfile=$(_load_dotenv_envfile "")
# A missing .env still leaves any owed backup scrub to finish, so the run goes on to find out.
no_env=0
if [ -z "$envfile" ] || [ ! -f "$envfile" ]; then
    no_env=1
else
    case "$envfile" in /*) ;; *) envfile="$(cd "$(dirname "$envfile")" && pwd)/${envfile##*/}" ;; esac
fi
# The default follows the current directory's git root: inside another repository that is another project's file.
if [ "$yes" -eq 1 ] && [ "$env_given" -eq 0 ] && [ "$no_env" -eq 0 ] && [ "$dry" -eq 0 ]; then
    primary=$(_load_dotenv_primary_for "$ROOT" 2>/dev/null) || primary=""
    if ! { [ "$envfile" -ef "$ROOT/.env" ] || { [ -n "$primary" ] && [ "$envfile" -ef "$primary/.env" ]; } \
        || [ "$envfile" -ef "${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/.env" ]; }; then
        echo "migrate-env: -y with no --env would act on $envfile, which is not this checkout's .env; nothing written. To move that file, name it with --env."
        exit 3
    fi
fi

confdir=$(_himmel_config_dir)
# shellcheck disable=SC2088 # shown to the user as written, never expanded
store_rel="~/.config/secrets/himmel.env"
store="$HOME/.config/secrets/himmel.env"

# Where a quote opened at the start of a value closes: the position in <s>, or 0. A
# double quote is escaped by a backslash; a single quote is literal.
CLOSEAT='function closeat(s, q,   n, j, c) {
    n = length(s)
    for (j = 1; j <= n; j++) {
        c = substr(s, j, 1)
        if (q == "\"" && c == "\\") { j++; continue }
        if (c == q) return j
    }
    return 0
}'
# Key names only: the text before '=' on each uncommented line. The lines inside a
# quoted value that runs over several lines are that value's, never a key.
key_names() {  # <file>
    awk "$CLOSEAT"'
    { sub(/\r$/, "") }
    inq { if (closeat($0, q)) inq = 0; next }
    /^[[:space:]]*#/ { next }
    {
        i = index($0, "="); if (i == 0) next
        k = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        v = substr($0, i + 1); sub(/^[[:space:]]+/, "", v); c = substr(v, 1, 1)
        if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (c == "\"" || c == "\047") && !closeat(substr(v, 2), c)) { q = c; inq = 1 }
        if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !(k in seen)) { seen[k] = 1; print k }
    }' "$1"
}
# The first entry of a key. mode=span prints "<first line> <last line>" (or "open" when
# its quote never closes); mode=value prints a quoted value, its lines joined by newlines.
# shellcheck disable=SC2016 # awk program text, not shell
ENTRY_AWK="$CLOSEAT"'
{ l = $0; sub(/\r$/, "", l) }
inq { p = closeat(l, q); if (p) { val = val "\n" substr(l, 1, p - 1); last = NR; done = 1; exit } val = val "\n" l; next }
l ~ /^[[:space:]]*#/ { next }
{
    i = index(l, "="); if (!i) next
    n = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); if (n != k) next
    v = substr(l, i + 1); sub(/^[[:space:]]+/, "", v); first = NR; c = substr(v, 1, 1)
    if (c == "\"" || c == "\047") {
        q = c; rest = substr(v, 2); p = closeat(rest, q)
        if (p) { val = substr(rest, 1, p - 1); last = NR; done = 1; exit }
        val = rest; inq = 1; next
    }
    last = NR; done = 1; exit
}
END { if (!first) exit 1; if (!done) { print "open"; exit } if (mode == "span") print first, last; else printf "%s", val }'
entry_span() { awk -v k="$2" -v mode=span "$ENTRY_AWK" "$1"; }  # <file> <key>
entry_value() {  # <file> <key>: the value the reader would see, one quote pair dropped; 1 when the quote never closes
    local span line v
    span=$(entry_span "$1" "$2") || return 1
    [ "$span" != open ] || return 1
    if [ "${span% *}" = "${span#* }" ]; then
        line=$(_load_dotenv_extract "$1" "$2")
        v=$(_load_dotenv_trim "${line#*=}")
        if [ "${#v}" -gt 1 ]; then
            case "${v:0:1}" in '"'|"'") [ "${v: -1}" != "${v:0:1}" ] || v=${v:1:${#v}-2} ;; esac
        fi
        printf '%s' "$v"
    else
        awk -v k="$2" -v mode=value "$ENTRY_AWK" "$1"
    fi
}
names=""
[ "$no_env" -eq 1 ] || names=$(key_names "$envfile")

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

# A name given with --keys must be a key of the file: a typo is a usage error, with
# nothing written. A himmel key in the list moves by its own route, named or not.
for key in $(printf '%s' "$keys_arg" | tr ',' ' '); do
    if ! grep -qxF -- "$key" <<<"$names"; then
        echo "migrate-env: --keys $key is not a key in ${envfile:-the .env}; nothing written." >&2
        exit 2
    fi
done
unowned_chosen() {  # <key>
    [ "$unowned_all" -eq 1 ] || case ",$keys_arg," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# key_names skips an `export NAME=` line, and the readers do not read one: himmel's own get a plan row.
export_keys=""
if [ "$no_env" -eq 0 ]; then
    while IFS= read -r key; do
        if is_owned "$key"; then export_keys="$export_keys $key"; fi
    done < <(sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$envfile" | sort -u)
fi

# The secret key set and the keyring state both come from the resolver, the one
# owner of each (I4): no list of secrets lives here.
hs="$ROOT/scripts/lib/himmel-secrets"
if ! secret_names_out=$(bash "$hs" names --class secret 2>/dev/null); then
    echo "migrate-env: cannot read the secret names from $hs; nothing migrated." >&2
    exit 1
fi
secret_names=" $(printf '%s\n' "$secret_names_out" | tr '\n' ' ')"
kstate=$(bash "$hs" status 2>/dev/null | sed -n 's/^keyring: //p')
backend_ok=0
[ "$kstate" != unlocked ] || backend_ok=1
# An emptied .env still has a legacy secrets file to import once the keyring is up.
empty_env=0
if [ "$no_env" -eq 1 ] || { [ -z "$names" ] && [ -z "$export_keys" ] && { [ "$backend_ok" -eq 0 ] || [ ! -s "$store" ]; }; }; then empty_env=1; fi

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

config_keys=() policy_keys=() secret_keys=() file_keys=() legacy_keys=() own_keys=() plan="" stay_secrets="" commented=" " incomplete=0 unowned_left=""
# The shell loader drops an unquoted trailing comment and the node readers keep it,
# so such a line would read differently after the move: it stays.
has_inline_comment() {  # <key>
    local line ext
    line=$(awk -v k="$1" '{ sub(/\r$/, "") } /^[[:space:]]*#/ { next } { i = index($0, "=")
        n = substr($0, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n) } i && n == k { print substr($0, i + 1); exit }' "$envfile")
    ext=$(_load_dotenv_extract "$envfile" "$1")
    [ "$(_load_dotenv_trim "$line")" != "$(_load_dotenv_trim "${ext#*=}")" ]
}
blank_line() {  # <key>: the readers see no value on its first line
    local v
    v=$(_load_dotenv_extract "$envfile" "$1")
    [ -z "$(_load_dotenv_trim "${v#*=}")" ]
}
plan_own() {  # <key> <label>: a name outside the manifest that the user chose; sets one plan row
    local key=$1 label=$2 val
    if case "$keep" in *" $key "*) true ;; *) false ;; esac; then
        plan="$plan  $key  $label  kept (env-keep)"$'\n'
    elif [ "$backend_ok" -eq 0 ]; then
        incomplete=1; plan="$plan  $key  $label  stays (no keyring)"$'\n'
    elif ! val=$(entry_value "$envfile" "$key"); then
        plan="$plan  $key  $label  stays (its quote never closes)"$'\n'
    elif [ -z "$(_load_dotenv_trim "$val")" ]; then
        plan="$plan  $key  $label  stays (blank in .env: no value)"$'\n'
    else
        own_keys[${#own_keys[@]}]="$key"; plan="$plan  $key  $label  → keyring (you named it)"$'\n'
    fi
}
for key in $names; do
    if ! is_owned "$key"; then
        # An unowned name moves only when the user names it (--keys) or accepts every one (--unowned).
        if unowned_chosen "$key"; then
            plan_own "$key" unowned
        else
            unowned_left="$unowned_left $key"
            plan="$plan  $key  unrelated  stays (not himmel's, left in place)"$'\n'
        fi
        continue
    fi
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
                # In .env.example but not in the manifest: the user's to name, like an unowned name.
                if unowned_chosen "$key"; then
                    plan_own "$key" secret
                else
                    unowned_left="$unowned_left $key"
                    stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (not in the secrets manifest)"$'\n'
                fi
            elif blank_line "$key"; then
                stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (blank in .env: no value)"$'\n'
            elif [ "$backend_ok" -eq 1 ]; then
                # A quoted value over several lines is read whole and removed whole, so it takes the same road as a named key.
                span=$(entry_span "$envfile" "$key")
                if [ "$span" = open ]; then
                    stay_secrets="$stay_secrets $key"; plan="$plan  $key  secret  stays (its quote never closes)"$'\n'
                elif [ "${span% *}" != "${span#* }" ]; then
                    own_keys[${#own_keys[@]}]="$key"; plan="$plan  $key  secret  → keyring (value over several lines)"$'\n'
                else
                    secret_keys[${#secret_keys[@]}]="$key"; plan="$plan  $key  secret  → keyring"$'\n'
                fi
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
for key in $export_keys; do
    class=$(_himmel_key_class "$key")
    [ "$class" != secret ] || stay_secrets="$stay_secrets $key"
    plan="$plan  $key  $class  stays (an export line: the readers do not read it; remove export to move it)"$'\n'
done
# A legacy secrets file moves into the keyring too, once there is one.
if [ "$backend_ok" -eq 1 ] && [ "$no_env" -eq 0 ] && [ -s "$store" ]; then
    for key in $(key_names "$store"); do
        case "$keep" in *" $key "*) continue ;; esac
        case "$secret_names" in *" $key "*) ;; *) continue ;; esac
        legacy_keys[${#legacy_keys[@]}]="$key"; plan="$plan  $key  secret  → keyring (from $store_rel)"$'\n'
    done
fi
moving=$(( ${#config_keys[@]} + ${#policy_keys[@]} + ${#secret_keys[@]} + ${#file_keys[@]} + ${#legacy_keys[@]} + ${#own_keys[@]} ))

if [ "$empty_env" -eq 0 ]; then
    echo "env migration for $envfile (key names only):"
    printf '%s' "$plan"
    [ -z "$stay_secrets" ] || echo "secrets stay in .env:$stay_secrets"
    if [ -n "$unowned_left" ]; then
        echo "not himmel's and not in the secrets manifest (unowned), left in place:$unowned_left"
        echo "to move the ones you name:  bash $HERE/migrate-env.sh -y --keys NAME[,NAME]"
        echo "to move all of them (the one command for the secrets you placed in this file):  bash $HERE/migrate-env.sh -y --unowned"
    fi
    if [ "$incomplete" -eq 1 ]; then
        echo "migrate-env: WARN no keyring backend (keyring: ${kstate:-absent}); secrets cannot reach the keyring, so this run is incomplete (exit 4 on an apply)."
        echo "unlock the keyring or install a Secret Service, then run this again."
    fi
fi

umask 077
# shellcheck source=../lib/prim.sh
. "$ROOT/scripts/lib/prim.sh"
work=$(tmpdir) || exit 1
next="" names_owed=0
trap 'rm -rf "$work"; [ -z "$next" ] || [ -L "$envfile" ] || rm -f "$next"; [ "$names_owed" -eq 0 ] || name_kept' EXIT
trap 'names_owed=0; exit 1' HUP INT TERM
bdir="$confdir/env-backups"
apply_cmd=$(printf 'bash %q --env %q -y' "$HERE/migrate-env.sh" "$envfile")
[ -z "$keys_arg" ] || apply_cmd="$apply_cmd$(printf ' --keys %q' "${keys_arg#,}")"
[ "$unowned_all" -eq 0 ] || apply_cmd="$apply_cmd --unowned"

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

# --- the backups and the legacy file keep every secret line the keyring does not hold ---
final_rc=0 scrubbed=0
drop_lines() {  # <set of names> <file>: the file without those keys' lines (`export NAME=` too); mode kept
    awk -v set="$1" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { print; next }
        { i = index(l, "="); k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); sub(/^export[[:space:]]+/, "", k) }
        i && k != "" && index(set, " " k " ") { next }
        { print }' "$2" > "$work/scrub.new" && replace_file "$work/scrub.new" "$2"
}
lines_for() {  # <set of names> <file>: the names of the set the file has a line for (`export NAME=` too)
    [ -f "$2" ] || return 0
    awk -v set="$1" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { next }
        { i = index(l, "="); if (!i) next; k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); sub(/^export[[:space:]]+/, "", k) }
        k != "" && index(set, " " k " ") && !(k in seen) { seen[k] = 1; print k }' "$2"
}
line_values() {  # <name> <file>: each real value of the key's lines, parsed as the readers parse one; empty and quoted-empty are none
    local l
    while IFS= read -r l; do
        l=$(_load_dotenv_extract /dev/stdin X <<<"X=$l")
        l=$(_load_dotenv_trim "${l#*=}")
        case "$l" in ''|'""'|"''") ;; *) printf '%s\n' "$l" ;; esac
    done < <(awk -v k="$1" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { next }
        { i = index(l, "="); if (!i) next; n = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); sub(/^export[[:space:]]+/, "", n) }
        n == k { print substr(l, i + 1) }' "$2" 2>/dev/null)
}
real_names() {  # <file>: the manifest-secret keys with a real value in the file
    local n
    for n in $(lines_for "$secret_names" "$1" 2>/dev/null); do
        [ -z "$(line_values "$n" "$1")" ] || echo "$n"
    done
}
list_backups() {  # sets env_backups and ca_backups: the plain files a scrub walks
    local f
    env_backups=() ca_backups=()
    for f in "$bdir"/*; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then env_backups[${#env_backups[@]}]="$f"; fi
    done
    for f in "${HIMMEL_CONFIG_AUDIT_DIR:-$confdir/state/config-audit}"/backups/*/.env; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then ca_backups[${#ca_backups[@]}]="$f"; fi
    done
}
# A line leaves only on a keyring match. .env is no copy: a restore overwrites it from the backup, so a line dropped
# because .env holds it would be lost with that .env. An env-keep key has no keyring reader, so it never leaves.
covered_in() {  # <file>...: sets covered, the keys these files may lose: every real value in them equals the user-scope item
    local n f vals names
    covered=" "
    names=$(for f in "$@"; do lines_for "$secret_names" "$f"; done 2>/dev/null | sort -u)
    for n in $names; do
        case "$keep" in *" $n "*) continue ;; esac
        vals=$(for f in "$@"; do line_values "$n" "$f"; done)
        if [ -n "$vals" ]; then printf '%s\n' "$vals"; fi | bash "$hs" same-value "$n" 2>/dev/null && covered="$covered$n "
    done
}
# ponytail: one set covers all config copies, so a differing value in any copy keeps the key in all; a per-copy scrub set in config-audit is the upgrade path.
# ponytail: a kill between the two renames in config-audit's scrub leaves that manifest's checksum stale until the next write; a journaled rename in config-audit is the upgrade path.
name_kept() {  # names the keys the backups keep, or says why they cannot be compared; prints no value
    local f n k s all="" would id reason="the keyring's user-scope item does not hold that value, or env-keep names the key, so the line stays."
    list_backups
    if [ "$backend_ok" -ne 1 ]; then
        for f in ${env_backups[@]+"${env_backups[@]}"} ${ca_backups[@]+"${ca_backups[@]}"}; do
            if [ -r "$f" ]; then all="$all $(real_names "$f" | tr '\n' ' ')"; fi
        done
        # shellcheck disable=SC2086 # word-split key names
        all=$(printf '%s\n' $all | grep . | sort -u | tr '\n' ' ')
        all=${all% }
        if [ "$kstate" = locked ] || [ -n "$all" ]; then
            echo "migrate-env: WARN keyring: ${kstate:-absent}, so the backups cannot be compared with it${all:+: they hold lines for $all}."
        fi
        return 0
    fi
    for f in ${env_backups[@]+"${env_backups[@]}"}; do
        if [ ! -r "$f" ]; then echo "migrate-env: WARN $f cannot be read, so it was not checked; check it by hand."; continue; fi
        covered_in "$f"
        k=""
        for n in $(real_names "$f"); do
            case "$covered" in *" $n "*) ;; *) k="$k $n" ;; esac
        done
        [ -z "$k" ] || echo "migrate-env: WARN $f keeps a line for$k: $reason"
    done
    [ "${#ca_backups[@]}" -gt 0 ] || return 0
    covered_in "${ca_backups[@]}"
    would=$(config_audit_scrub --dry-run "$covered" "$secret_names" 2>/dev/null)
    for f in "${ca_backups[@]}"; do
        id=${f%/.env}; id=${id##*/}
        if [ ! -r "$f" ]; then echo "migrate-env: WARN config backup $id cannot be read, so it was not checked; check it by hand."; continue; fi
        k="" s=""
        for n in $(real_names "$f"); do
            case "$covered" in *" $n "*) s="$s $n" ;; *) k="$k $n" ;; esac
        done
        [ -z "$k" ] || echo "migrate-env: WARN config backup $id keeps a line for$k: $reason"
        if [ -n "$s" ] && ! grep -Fxq "would-scrub $id" <<<"$would"; then
            echo "migrate-env: WARN config backup $id keeps a line for$s: the scrub skips that backup (its manifest cannot be read); remove it by hand."
        fi
    done
}
pending_scrub() {  # sets pend, how many backup files a scrub would change; a failed count sets final_rc=1
    local f out
    pend=0
    list_backups
    for f in ${env_backups[@]+"${env_backups[@]}"}; do
        covered_in "$f"
        [ "$covered" = " " ] || pend=$((pend + 1))
    done
    covered_in ${ca_backups[@]+"${ca_backups[@]}"}
    if out=$(config_audit_scrub --dry-run "$covered" "$secret_names" 2>/dev/null); then
        pend=$(( pend + $(printf '%s\n' "$out" | grep -c '^would-scrub ') ))
    else
        echo "migrate-env: WARN could not check the .env copies in the config backups (~/.himmel/state/config-audit/backups); a scrub of them may be owed."
        final_rc=1
    fi
}
scrub_backups() {  # sets scrubbed=1; a failure sets final_rc=1; a kept line is named
    local f
    scrubbed=1
    list_backups
    for f in ${env_backups[@]+"${env_backups[@]}"}; do
        covered_in "$f"
        drop_lines "$covered" "$f" \
            || { echo "migrate-env: WARN could not scrub the secret lines from $f; remove that backup by hand."; final_rc=1; }
    done
    covered_in ${ca_backups[@]+"${ca_backups[@]}"}
    if ! config_audit_scrub "$covered" "$secret_names" >/dev/null 2>&1; then
        echo "migrate-env: WARN could not scrub the .env copies in the config backups (~/.himmel/state/config-audit/backups); remove those by hand."
        final_rc=1
    fi
    name_kept
    names_owed=0
}
# Moving live credentials is a step a person starts (OS-1): -y, a terminal and no agent
# session, whichever way the other keys were allowed. The consent does not stand in for them.
secrets_gate() {  # sets secrets_refusal; empty = the secrets stage may run
    secrets_refusal=""
    if [ -n "${CLAUDECODE:-}" ]; then secrets_refusal="an agent session cannot move secrets"
    elif [ ! -t 0 ]; then secrets_refusal="no terminal to move secrets at"
    elif [ "$yes" -ne 1 ]; then secrets_refusal="moving secrets needs -y"; fi
}

names_owed=1
if [ "$moving" -eq 0 ]; then
    pend=0
    [ "$backend_ok" -ne 1 ] || pending_scrub
    if [ "$pend" -eq 0 ]; then
        if [ "$no_env" -eq 1 ]; then echo "migrate-env: no .env found; nothing to migrate."; exit "$final_rc"; fi
        if [ "$empty_env" -eq 1 ]; then echo "migrate-env: $envfile holds no keys; nothing to migrate."; exit "$final_rc"; fi
        echo "nothing to move: every key stays in .env."
        [ "$final_rc" -eq 0 ] || exit 1
        [ "$dry" -eq 1 ] || [ "$incomplete" -eq 0 ] || exit 4
        exit 0
    fi
    echo "scrub only: $pend backup file(s) hold secret lines whose value matches the keyring item; the scrub drops only those."
    [ "$dry" -eq 0 ] || { echo "dry run: nothing written."; exit "$final_rc"; }
    secrets_gate
    if [ -n "$secrets_refusal" ]; then
        echo "migrate-env: $secrets_refusal; the backups stay as they are."
        printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
        exit 3
    fi
    scrub_backups
    [ "$final_rc" -eq 0 ] || exit 1
    [ "$incomplete" -eq 0 ] || exit 4
    exit 0
fi
echo "backup: the apply first copies .env (mode 600) to $bdir/env.<UTC time>.<pid>"
[ "$dry" -eq 0 ] || { echo "dry run: nothing written."; exit 0; }
poldir=$(_himmel_policy_dir) || { echo "migrate-env: cannot read this account's home from its passwd entry; nothing written." >&2; exit 1; }
# -y at a terminal outside an agent session is the operator's own prompt: the consent is not read, so the printed command is true.
at_prompt=0
if [ "$yes" -eq 1 ] && [ -t 0 ] && [ -z "${CLAUDECODE:-}" ]; then at_prompt=1; fi
consent=0 cv=""
if [ "$at_prompt" -eq 0 ] && [ -f "$poldir/config.json" ] \
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
secrets_gate
if [ "$consent" -eq 1 ] && [ -n "$secrets_refusal" ] && [ $(( ${#secret_keys[@]} + ${#legacy_keys[@]} + ${#own_keys[@]} )) -gt 0 ]; then
    echo "migrate-env: $secrets_refusal; they stay in .env: ${secret_keys[*]-} ${legacy_keys[*]-} ${own_keys[*]-}"
    printf 'To move them, run this at your own prompt:\n  %s\n' "$apply_cmd"
    moving=$(( moving - ${#secret_keys[@]} - ${#legacy_keys[@]} - ${#own_keys[@]} )) secret_keys=() legacy_keys=() own_keys=()
    [ "$moving" -gt 0 ] || { echo "nothing else to move; nothing written."; exit 3; }
fi
command -v node >/dev/null 2>&1 || { echo "migrate-env: node is needed to write and verify the config; nothing written." >&2; exit 1; }
if [ "$consent" -eq 0 ] && [ "$yes" -ne 1 ]; then
    echo "migrate-env: nothing written; rerun with -y"
    printf 'Run this at your own prompt:\n  %s\n' "$apply_cmd"
    exit 3
fi

# A killed run leaves its copy beside .env, holding secrets: a dead pid's goes, a live run's stays. $work, mode 700, stays after a SIGKILL.
for f in "$envfile".migrate.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "${f##*.migrate.}" in ''|*[!0-9]*) continue ;; esac
    kill -0 "${f##*.migrate.}" 2>/dev/null || rm -f "$f"
done

# --- backup ---
backup="$bdir/env.$(date -u +%Y%m%dT%H%M%SZ).$$"
if ! { mkdir -p "$bdir" && chmod 700 "$bdir" && cp "$envfile" "$backup" && chmod 600 "$backup" \
    && cmp -s "$envfile" "$backup"; } 2>/dev/null; then
    echo "migrate-env: could not write the backup $backup; nothing changed." >&2
    exit 1
fi
echo "backup: $backup (mode 600)"
restore_hint() {
    if [ "${scrubbed:-0}" -eq 1 ]; then
        echo "backup $backup no longer holds the secret lines the keyring also holds; the keyring serves those. To undo a config move, copy back only the lines you want. Remove it once you are happy: rm $backup"
    else
        echo "restore: cp $backup $envfile"
        echo "the backup can hold your secrets until a scrub; remove it once you are happy: rm $backup"
    fi
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
# stored|held|shadowed|failed|skipped NAME. Only `stored` keys leave .env (I3). It is
# handed a private copy holding just the secrets this run moves, so a key the plan
# left alone is never imported; the copy lives in $work, which is removed on exit.
stored_keys=" " legacy_stored=" "
run_import() {  # <file> <var for the stored names>: sets imp_out; returns 1 when the run must stop
    local kf=() rc=0 st
    [ ! -f "$confdir/env-keep.txt" ] || kf=(--keep-file "$confdir/env-keep.txt")
    imp_out=$(bash "$hs" import-env ${kf[@]+"${kf[@]}"} "$1" 2>&1) || rc=$?
    printf '%s\n' "$imp_out" | grep -E '^(stored|held|shadowed|failed|skipped) [A-Za-z_]' | sed 's/^/  /'
    st=$(printf '%s\n' "$imp_out" | sed -n 's/^stored \([A-Za-z_][A-Za-z0-9_]*\)$/\1/p' | tr '\n' ' ')
    printf -v "$2" ' %s' "$st"
    if [ "$rc" -ne 0 ] || grep -q '^failed ' <<<"$imp_out"; then
        printf '%s\n' "$imp_out" | grep -v -E '^(stored|held|shadowed|failed|skipped|imported) ' | sed 's/^/  /'
        return 1
    fi
    if grep -q '^held ' <<<"$imp_out"; then
        echo "held keys keep their .env line: the keyring value is the one served, and .env holds another (settle it with himmel-secrets)."
    fi
    if grep -q '^shadowed ' <<<"$imp_out"; then
        echo "shadowed keys: a project-scope keyring item with another value is served first in this checkout (settle it with himmel-secrets)."
    fi
    return 0
}
if [ "${#secret_keys[@]}" -gt 0 ]; then
    secret_set=" ${secret_keys[*]} "
    if ! awk -v set="$secret_set" '{ l = $0; sub(/\r$/, "", l) }
        l ~ /^[[:space:]]*#/ { next }
        { i = index(l, "="); if (!i) next; k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
        index(set, " " k " ") { print }' "$envfile" > "$work/secrets.env" 2>/dev/null; then
        echo "migrate-env: could not write the private copy of the secrets; no lines were removed from .env."
        restore_hint
        exit 1
    fi
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
# Named, unowned and several-line entries: the value is parsed here, stored through
# `himmel-secrets put --stdin`, and read back from the keyring alone (same-value). An entry
# whose store or read-back fails stays in .env whole; the others still move.
own_stored=" " own_kept=""
for key in ${own_keys[@]+"${own_keys[@]}"}; do
    own_err=""
    if ! own_val=$(entry_value "$envfile" "$key"); then
        own_err="its quote never closes"
    elif own_err=$(printf '%s' "$own_val" | bash "$hs" put --stdin "$key" 2>&1 >/dev/null); [ -n "$own_err" ]; then
        own_err=$(printf '%s' "$own_err" | head -n 1)
    elif ! printf '%s\n' "$own_val" | bash "$hs" same-value "$key" 2>/dev/null; then
        own_err="the keyring does not hold that value after the store"
    fi
    own_val=""
    if [ -z "$own_err" ]; then
        own_stored="$own_stored$key "; echo "  stored $key"
    else
        own_kept="$own_kept $key"; echo "  failed $key ($own_err); its entry stays in .env"
    fi
done
if [ -n "$own_kept" ]; then
    echo "migrate-env: WARN these entries did not reach the keyring and stay in .env:$own_kept"
    final_rc=1
fi

# --- verify ---
verify_env="$envfile"   # the .env the readers compare against; a kept ~/.himmel value is swapped in
verify_all() {  # sets bad and verified
    bad="" verified="load_dotenv"
    cp "$verify_env" "$work/repo/.env" || bad="${bad}verify: could not copy .env into the scratch checkout"$'\n'
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
moved=" ${config_keys[*]-} ${policy_keys[*]-}${stored_keys}${own_stored}${file_keys[*]-} "
# shellcheck disable=SC2086 # word-split key names
moved_n=$(printf '%s\n' $moved | grep -c .)
# A moved key's whole entry goes: a quoted value over several lines too, closing quote included.
awk -v moved="$moved" "$CLOSEAT"'
    { l = $0; sub(/\r$/, "", l) }
    skipq != "" { if (closeat(l, skipq)) skipq = ""; next }
    l ~ /^[[:space:]]*#/ { print; next }
    { i = index(l, "="); k = substr(l, 1, i - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k) }
    i && k != "" && index(moved, " " k " ") {
        v = substr(l, i + 1); sub(/^[[:space:]]+/, "", v); c = substr(v, 1, 1)
        if ((c == "\"" || c == "\047") && !closeat(substr(v, 2), c)) skipq = c
        next
    }
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

# --- scrub: the legacy file and the backups keep every secret line the keyring does not hold ---
if [ "${#legacy_keys[@]}" -gt 0 ] && [ "$legacy_stored" != " " ]; then
    # This file has no backup: a later duplicate with another value would be gone.
    covered_in "$store"
    legacy_drop=" " legacy_kept=""
    for key in $legacy_stored; do
        case "$covered" in *" $key "*) legacy_drop="$legacy_drop$key " ;; *) legacy_kept="$legacy_kept $key" ;; esac
    done
    drop_lines "$legacy_drop" "$store" \
        || { echo "migrate-env: WARN could not empty $store_rel of the keys it stored; remove those lines by hand."; final_rc=1; }
    [ -z "$legacy_kept" ] || echo "migrate-env: WARN $store_rel keeps a line for$legacy_kept: its lines hold another value than the keyring item, and the file has no backup, so the line stays."
fi
if [ "$backend_ok" -eq 1 ] && [ -z "$secrets_refusal" ]; then
    scrub_backups
elif [ "$backend_ok" -eq 1 ]; then
    echo "migrate-env: the backups keep their secret lines ($secrets_refusal); run this at your own prompt to scrub them:"
    printf '  %s\n' "$apply_cmd"
fi

# Every name that reached the keyring leaves the systemd user manager, whatever a login put there.
clear_manager() {  # <names>: prints names, never a value
    local n cleared="" failed="" held=0 after envargs=()
    if ! command -v systemctl >/dev/null 2>&1; then echo "systemd user manager: no systemctl here; nothing to clear."; return 0; fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then echo "systemd user manager: not reachable from here; nothing cleared (log in as that user and run: systemctl --user unset-environment $*)."; return 0; fi
    for n in "$@"; do
        if systemctl --user unset-environment "$n" >/dev/null 2>&1; then cleared="$cleared $n"; else failed="$failed $n"; fi
    done
    after=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')
    for n in "$@"; do
        if grep -qxF -- "$n" <<<"$after"; then held=$((held + 1)); fi
    done
    echo "systemd user manager: unset-environment for$cleared; of these names it still holds $held"
    [ -z "$failed" ] || { echo "migrate-env: WARN unset-environment failed for:$failed"; final_rc=1; }
    # The serving layer after the move, read with the names out of this process's environment.
    for n in "$@"; do envargs[${#envargs[@]}]="-u"; envargs[${#envargs[@]}]="$n"; done
    env "${envargs[@]}" bash "$hs" status "$@" 2>/dev/null | grep -v '^keyring:' | sed 's/^/  serving layer: /'
}
if [ -z "$secrets_refusal" ]; then
    # shellcheck disable=SC2086 # word-split key names
    unset_names=$(printf '%s\n' $stored_keys $own_stored $legacy_stored | grep . | sort -u | tr '\n' ' ')
    # shellcheck disable=SC2086 # word-split key names
    [ -z "$unset_names" ] || clear_manager $unset_names
fi

echo "verified: $verified"
[ -z "$policy_all" ] || echo "policy compared: $policy_all"
echo "moved $moved_n key(s); removed their lines from .env."
restore_hint
[ "$final_rc" -eq 0 ] || exit 1
[ "$incomplete" -eq 0 ] || exit 4
exit 0
