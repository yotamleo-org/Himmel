#!/usr/bin/env bash
# phi-egress-lib.sh — the plugin lane's comment-stripped copy of
# scripts/guardrails/phi-egress-lib.sh; test-plugin-hook-bash-wiring.sh pins its functions.

_guard_file_readable() {
    [ -f "$1" ] && [ -r "$1" ]
}

_guard_endpoint_host() {
    local u="$1" host
    [ -n "$u" ] || return 1
    u="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')"
    case "$u" in *\\*) return 1 ;; esac
    case "$u" in https://*) : ;; *) return 1 ;; esac
    u="${u#*://}"
    u="${u%%/*}"
    u="${u%%\?*}"
    u="${u%%#*}"
    host="${u##*@}"
    host="${host%%:*}"
    [ -n "$host" ] || return 1
    printf '%s' "$host"
}

_guard_phi_dir_provable() {
    local d="$1" up
    while [ ! -e "$d" ] && [ ! -L "$d" ]; do
        case "$d" in
            /) return 0 ;;
            .) [ -x . ]; return ;;
            */*) up="${d%/*}"; [ -n "$up" ] || up=/ ;;
            *) up=. ;;
        esac
        [ "$up" != "$d" ] || return 0
        d="$up"
    done
    [ -d "$d" ] && [ -x "$d" ]
}

_guard_phi_list_paths() {
    local name="$1" d found=3
    [ -n "${HOME:-}" ] || return 2
    for d in "$HOME/.config/himmel/phi" "${CLAUDE_GLM_CONFIG_DIR:-$HOME/.config/claude-glm}"; do
        _guard_phi_dir_provable "$d" || return 2
        if [ -e "$d/$name" ] || [ -L "$d/$name" ]; then
            printf '%s\n' "$d/$name"
            found=0
        fi
    done
    return "$found"
}

_guard_phi_list_entries() {
    local content line
    case "${1##*/}" in
        phi-roots | egress-denylist) ;;
        *) return 2 ;;
    esac
    _guard_file_readable "$1" || return 2
    # read-sink-ok: the case above admits only the two list names; the dir can come from an env override and the file can be a symlink, and the content is only compared, never printed by the doctor
    content="$(cat -- "$1")" || return 2
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        line="${line//\\//}"
        line="${line%"${line##*[!/]}"}"
        printf '%s\n' "${line:-/}"
    done <<<"$content"
}

_guard_phi_under() {
    [ "$2" = / ] && return 0
    case "$1/" in "$2"/*) return 0 ;; esac
    return 1
}

_guard_phi_canon() {
    local p="$1" rest="" real up
    while [ -n "$p" ]; do
        # prim-ok: gnu-ok: this lib sources nothing into the guards that load it, and the raw form is compared when this fails.
        if [ -e "$p" ] && real="$(readlink -f -- "$p" 2>/dev/null)" && [ -n "$real" ]; then
            printf '%s%s' "${real%/}" "$rest"
            return 0
        fi
        up="${p%/*}"
        [ "$up" != "$p" ] || break
        rest="/${p##*/}$rest"
        p="$up"
    done
    printf '%s' "$1"
}

_guard_phi_decision() {
    local path="$1" canon name lists entries f root real any=0 hit=0 rc
    [ -n "$path" ] || return 2
    canon="$(_guard_phi_canon "$path")"
    for name in phi-roots egress-denylist; do
        rc=0
        lists="$(_guard_phi_list_paths "$name")" || rc=$?
        [ "$rc" -ne 2 ] || return 2
        [ "$rc" -eq 0 ] || continue
        any=1
        while IFS= read -r f; do
            entries="$(_guard_phi_list_entries "$f")" || return 2
            while IFS= read -r root; do
                [ -n "$root" ] || continue
                real="$(_guard_phi_canon "$root")"
                if _guard_phi_under "$path" "$root" || _guard_phi_under "$canon" "$root" \
                    || _guard_phi_under "$path" "$real" || _guard_phi_under "$canon" "$real" \
                    || _guard_phi_under "$root" "$path" || _guard_phi_under "$real" "$canon"; then
                    hit=1
                fi
            done <<<"$entries"
        done <<<"$lists"
    done
    [ "$hit" -eq 0 ] || return 1
    [ "$any" -eq 1 ] || return 3
    return 0
}

_guard_phi_unenforced_roots() {
    local neutral="${HOME:-}/.config/himmel/phi" name f e d n covered o entries old_entries
    [ -n "${HOME:-}" ] || return 2
    _guard_phi_dir_provable "$neutral" || return 2
    for name in phi-roots egress-denylist; do
        f="$neutral/$name"
        [ -e "$f" ] || [ -L "$f" ] || continue
        entries="$(_guard_phi_list_entries "$f")" || return 2
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            for d in "${CLAUDE_GLM_CONFIG_DIR:-$HOME/.config/claude-glm}" "$HOME/.config/claude-glm"; do
                covered=0
                for n in phi-roots egress-denylist; do
                    old_entries="$(_guard_phi_list_entries "$d/$n" 2>/dev/null)" || continue
                    while IFS= read -r o; do
                        [ -n "$o" ] || continue
                        if _guard_phi_under "$e" "$o"; then covered=1; fi
                    done <<<"$old_entries"
                done
                if [ "$covered" -eq 0 ]; then
                    printf '%s\n' "$e"
                    break
                fi
            done
        done <<<"$entries"
    done
}
