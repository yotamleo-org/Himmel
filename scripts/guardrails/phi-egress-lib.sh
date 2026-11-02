#!/usr/bin/env bash
# scripts/guardrails/phi-egress-lib.sh — shared fail-closed predicates for the
# PHI/egress guard family.
#
# WHY: scripts/guardrails/graphify-fence.sh (the interactive path) and
# scripts/graphify/refresh-graph-map.sh (the scheduled path) each classify (a)
# PHI-root/egress-denylist file readability and (b) an Anthropic endpoint URL
# down to a hostname. Before this file existed, each had its OWN copy of
# both checks, and the scheduled copy fell behind the fence's fail-closed
# behavior at least once, found only in review. A parity TEST can only catch drift already committed;
# sourcing ONE implementation from both call sites makes the drift itself
# impossible instead of merely detectable.
#
# Contract: every predicate here fails CLOSED — an absent, unreadable, or
# unparseable input is never treated as an allow. Callers own the deny
# message and any exact-value allowlisting; these functions only classify.
#
# Deliberately does NOT call `set` itself: it is sourced into callers running
# under different shell options (graphify-fence.sh: `-uo pipefail`;
# refresh-graph-map.sh: `-euo pipefail`) — `set` mutates the CALLING shell
# once sourced, so declaring options here would silently drop the sourcing
# script's own `-e` (exactly the fail-open-by-accident shape this ticket is
# about).

# _guard_file_readable <path> -> rc 0 iff <path> exists, is a regular file,
# and is readable by this process; rc 1 otherwise (missing, a directory/
# special file, or present-but-unreadable). Callers must NOT collapse
# "unreadable" into "absent": an EXISTING-but-unreadable PHI-roots/denylist
# file must still deny, not silently proceed as if it declared nothing
_guard_file_readable() {
    [ -f "$1" ] && [ -r "$1" ]
}

# _guard_endpoint_host <url> -> prints the lowercased, syntactically-validated
# hostname on stdout and returns 0; returns 1 (nothing printed) when <url> is
# empty, contains a backslash (some HTTP clients fold `\` into
# `/`, so a backslash before the real authority can smuggle a different host
# past a naive parser), is not an explicit `https://` URL (plaintext,
# scheme-less, and arbitrary-scheme values all fail closed), or otherwise
# fails to yield a non-empty host. EXACT-host allowlisting downstream (never
# substring/prefix matching on the raw URL, which a lookalike host like
# api.anthropic.com.evil.example would pass) is the caller's job; this
# function only normalizes and validates the URL shape.
_guard_endpoint_host() {
    local u="$1" host
    [ -n "$u" ] || return 1
    u="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')"
    case "$u" in *\\*) return 1 ;; esac
    case "$u" in https://*) : ;; *) return 1 ;; esac
    u="${u#*://}"       # strip the (validated) https:// scheme
    u="${u%%/*}"        # authority = up to the first '/'
    u="${u%%\?*}"       # strip ?query   (scheme-/path-less forms)
    u="${u%%#*}"        # strip #fragment
    host="${u##*@}"     # drop userinfo (user:pass@)
    host="${host%%:*}"  # drop :port
    [ -n "$host" ] || return 1
    printf '%s' "$host"
}

# --- The PHI config dir ------------------------------------------------------
# ~/.config/himmel/phi is the neutral dir for phi-roots / egress-denylist;
# ~/.config/claude-glm (or $CLAUDE_GLM_CONFIG_DIR, which replaces only that dir)
# is the old one. NO GUARD READS THE NEUTRAL DIR YET: only the doctor calls the
# functions below, until a later change re-points the readers. Until then the old
# path stays authoritative. A list under EITHER dir counts (a union, so a
# neutral list can never hide an old one). The neutral dir keys on HOME alone,
# so an environment variable cannot steer a fail-closed read away from it.

# _guard_phi_dir_provable <dir> -> rc 0 iff the presence of a file in <dir> can
# be proven either way. [ -e ] is also false on EACCES, so a locked dir or a
# locked parent would otherwise read as "no list here". The nearest existing
# ancestor must be a directory this process can traverse.
_guard_phi_dir_provable() {
    local d="$1" up
    while [ ! -e "$d" ] && [ ! -L "$d" ]; do
        up="${d%/*}"
        { [ -n "$up" ] && [ "$up" != "$d" ]; } || return 0
        d="$up"
    done
    [ -d "$d" ] && [ -x "$d" ]
}

# _guard_phi_list_paths <list name> -> prints every present copy of the list,
# neutral first, one per line. rc 0 = at least one printed; 2 = unreadable (a
# dir that cannot be proven, or no HOME); 3 = none declared, which is NOT an
# empty list and NOT clear. A dangling symlink counts as present.
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

# _guard_phi_list_entries <file> -> prints each root, trimmed, comments and
# blanks dropped, backslashes folded, trailing slashes removed (an entry of only
# slashes prints as /). rc 2 when the file cannot be read or is not named as one
# of the two lists: the slurp comes first so a read error cannot pass for a short
# list.
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

# _guard_phi_under <path> <root> -> rc 0 iff <path> is <root> or lies beneath it.
_guard_phi_under() {
    [ "$2" = / ] && return 0
    case "$1/" in "$2"/*) return 0 ;; esac
    return 1
}

# _guard_phi_canon <path> -> prints the path with symlinks resolved through its
# deepest existing ancestor; the input unchanged when that cannot be done (the
# raw form is always compared as well).
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

# _guard_phi_decision <path> -> the egress decision for <path> over both dirs
# and both lists. rc 0 = clear (lists were read, none covers the path); 1 =
# listed, deny (the path is under a root, or holds one); 2 = unreadable, deny; 3
# = none declared. Any unreadable copy wins over everything else, including a
# hit, so the answer does not depend on read order. Callers under `set -e` must
# capture the rc with `|| rc=$?`.
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

# _guard_phi_unenforced_roots -> prints each root listed under the neutral dir
# that an old dir does not cover: the guards cannot see it, so it has no guard
# behind it. Both old locations must cover it, because some readers honour
# $CLAUDE_GLM_CONFIG_DIR and some hard-code HOME. rc 2 when a neutral list cannot
# be read (it may hold such a root). Goes away once the guards read the neutral dir.
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
