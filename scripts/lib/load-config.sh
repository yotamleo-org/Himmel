#!/usr/bin/env bash
# load-config.sh — the behaviour-config and gate-policy layers that sit beside
# .env (layer table: docs/internals/config-layers.md).
#
# Sourced by load-dotenv.sh, never on its own: it uses that file's
# _load_dotenv_extract, _load_dotenv_trim and _load_dotenv_envfile.
#
#   behaviour keys  ~/.himmel/himmel.conf.local > ~/.himmel/himmel.conf
#                   (KEY=value, parsed, never sourced). load_dotenv reads them
#                   with the process env still winning.
#   policy keys     ~/.himmel/config.json .policy, the operator-owned file a
#                   guard keeps agents from writing. load_policy, the gate
#                   reader, IGNORES the process env for them.
#   secret keys     .env only. Never read from either file above.
#
# The directory is fixed at $HOME/.himmel; no env var selects another one.
# ponytail: the path follows $HOME, so a caller that controls HOME picks the
# file; clear-cr-marker's seam guard does not cover HOME (it is always set).
# Upgrade path: pin the directory from the passwd entry if a gate ever runs
# under a caller-chosen HOME.
# ponytail: policy keys live in config.json, not the tracked himmel.conf,
# because no guard covers writes to himmel.conf yet; move them once one does.

# Keys this layer serves. Anything else is a secret and stays in .env.
_himmel_key_class() {
    case "$1" in
        CR_REQUIRE_CROSS_MODEL|CR_FLOOR_FALLBACK|ARMAUTOMERGE)
            printf 'policy' ;;
        HANDOVER_DIR|USER_SLUG|LUNA_VAULT_PATH|HIMMEL_DOC_FRESHNESS|\
        HIMMEL_INITIATIVE|HIMMEL_INITIATIVE_OVERNIGHT|HIMMEL_OVERNIGHT|\
        HIMMEL_WHERE_ARE_WE|HIMMEL_WHERE_ARE_WE_STALE_HOURS|\
        HIMMEL_WORKTREE_NUDGE|HIMMEL_UPDATE_AUTOSTASH|CR_PROFILE|\
        CR_CLAUDE_AGENTS|TICKET_ID_REQUIRED|TICKET_ID_PATTERN|\
        TICKET_ID_EXEMPT_AUTHORS|TRACKER)
            printf 'config' ;;
        *)
            printf 'secret' ;;
    esac
}

_himmel_config_dir() {
    printf '%s/.himmel' "$HOME"
}

# One stderr line naming the keys (never their values) still read from .env.
_himmel_deprecation_notice() {
    printf 'himmel: DEPRECATED: %s read from .env, which is for secrets only. Move behaviour keys to ~/.himmel/himmel.conf and policy keys to ~/.himmel/config.json .policy (bash scripts/setup/migrate-env-config.sh). The .env fallback goes away next release.\n' "$*" >&2
}

# _himmel_policy_json <config.json> KEY... — print KEY=value for each key
# present under .policy. Strings, numbers and booleans only; a value holding a
# newline is dropped. Returns non-zero when the file cannot be parsed or node
# is missing, so a gate can fail closed.
_himmel_policy_json() {
    node -e '
        const fs = require("fs");
        const [file, ...keys] = process.argv.slice(1);
        const doc = JSON.parse(fs.readFileSync(file, "utf8"));
        const policy = doc && typeof doc.policy === "object" && doc.policy !== null ? doc.policy : {};
        for (const key of keys) {
            const v = policy[key];
            if (!["string", "number", "boolean"].includes(typeof v)) continue;
            const s = String(v);
            if (/[\r\n\0]/.test(s)) continue;
            process.stdout.write(key + "=" + s + "\n");
        }
    ' "$@" 2>/dev/null
}

# _himmel_config_layers KEY... — print KEY=value for every requested
# behaviour key found in himmel.conf(.local) and every policy key found in
# config.json. Secret keys are skipped. Non-zero only when config.json exists
# and cannot be read.
_himmel_config_layers() {
    local _hc_dir _hc_key _hc_line _hc_val _hc_file _hc_found=" "
    local _hc_cfg=() _hc_pol=()
    _hc_dir=$(_himmel_config_dir)
    for _hc_key in "$@"; do
        case "$(_himmel_key_class "$_hc_key")" in
            config) _hc_cfg[${#_hc_cfg[@]}]="$_hc_key" ;;
            policy) _hc_pol[${#_hc_pol[@]}]="$_hc_key" ;;
        esac
    done
    if [ "${#_hc_cfg[@]}" -gt 0 ]; then
        for _hc_file in "$_hc_dir/himmel.conf.local" "$_hc_dir/himmel.conf"; do
            [ -f "$_hc_file" ] || continue
            while IFS= read -r _hc_line || [ -n "$_hc_line" ]; do
                _hc_key="${_hc_line%%=*}"
                case "$_hc_found" in *" $_hc_key "*) continue ;; esac
                _hc_val=$(_load_dotenv_trim "${_hc_line#*=}")
                [ -n "$_hc_val" ] || continue
                _hc_found="$_hc_found$_hc_key "
                printf '%s=%s\n' "$_hc_key" "$_hc_val"
            done < <(_load_dotenv_extract "$_hc_file" "${_hc_cfg[@]}")
        done
    fi
    if [ "${#_hc_pol[@]}" -gt 0 ] && [ -f "$_hc_dir/config.json" ]; then
        _himmel_policy_json "$_hc_dir/config.json" "${_hc_pol[@]}" || return 1
    fi
    return 0
}

# load_policy [--root <dir>] KEY... — the gate reader for policy keys.
# Order: ~/.himmel/config.json .policy, then legacy .env (deprecation
# notice), then unset, which every gate treats as its safe default. The
# process env is never used: a value there is dropped, with a notice when it
# differs from the resolved one. Returns non-zero when a file that exists
# cannot be read, so the caller fails closed instead of using a default.
load_policy() {
    local _lp_root=""
    if [ "${1:-}" = "--root" ]; then
        _lp_root="$2"; shift 2
    fi
    [ "$#" -gt 0 ] || return 0
    local _lp_key _lp_line _lp_val _lp_out _lp_envfile _lp_i _lp_found=" "
    local _lp_keys=() _lp_env=() _lp_rest=() _lp_legacy=()
    local _lp_conf
    _lp_conf="$(_himmel_config_dir)/config.json"

    for _lp_key in "$@"; do
        if [ "$(_himmel_key_class "$_lp_key")" != policy ]; then
            printf 'load_policy: %s is not a policy key\n' "$_lp_key" >&2
            return 1
        fi
        _lp_keys[${#_lp_keys[@]}]="$_lp_key"
        _lp_env[${#_lp_env[@]}]="${!_lp_key-}"
        unset "$_lp_key"
    done

    if [ -f "$_lp_conf" ]; then
        if ! _lp_out=$(_himmel_policy_json "$_lp_conf" "${_lp_keys[@]}"); then
            printf 'himmel: ~/.himmel/config.json cannot be parsed; gate policy fails closed\n' >&2
            return 1
        fi
        while IFS= read -r _lp_line; do
            [ -n "$_lp_line" ] || continue
            _lp_found="$_lp_found${_lp_line%%=*} "
            # shellcheck disable=SC2163 # exports the KEY=value the line holds
            export "$_lp_line"
        done <<EOF
$_lp_out
EOF
    else
        printf 'himmel: no ~/.himmel/config.json; policy keys (%s) come from legacy .env or their safe defaults\n' "${_lp_keys[*]}" >&2
    fi

    for _lp_key in "${_lp_keys[@]}"; do
        case "$_lp_found" in *" $_lp_key "*) ;; *) _lp_rest[${#_lp_rest[@]}]="$_lp_key" ;; esac
    done
    if [ "${#_lp_rest[@]}" -gt 0 ]; then
        _lp_envfile=$(_load_dotenv_envfile "$_lp_root")
        if [ -n "$_lp_envfile" ] && [ -e "$_lp_envfile" ]; then
            if [ ! -r "$_lp_envfile" ]; then
                printf 'himmel: legacy .env exists but is unreadable; gate policy fails closed\n' >&2
                return 1
            fi
            while IFS= read -r _lp_line || [ -n "$_lp_line" ]; do
                _lp_key="${_lp_line%%=*}"
                _lp_val=$(_load_dotenv_trim "${_lp_line#*=}")
                export "$_lp_key=$_lp_val"
                _lp_legacy[${#_lp_legacy[@]}]="$_lp_key"
            done < <(_load_dotenv_extract "$_lp_envfile" "${_lp_rest[@]}")
            if [ "${#_lp_legacy[@]}" -gt 0 ]; then
                _himmel_deprecation_notice "${_lp_legacy[@]}"
            fi
        fi
    fi

    _lp_i=0
    for _lp_key in "${_lp_keys[@]}"; do
        if [ -n "${_lp_env[$_lp_i]}" ] && [ "${_lp_env[$_lp_i]}" != "${!_lp_key-}" ]; then
            printf 'himmel: ignoring process-env %s; gate policy is read from ~/.himmel/config.json only\n' "$_lp_key" >&2
        fi
        _lp_i=$((_lp_i + 1))
    done
    return 0
}
