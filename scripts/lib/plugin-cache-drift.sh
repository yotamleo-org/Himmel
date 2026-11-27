# shellcheck shell=bash
# plugin-cache-drift.sh — the one place that decides whether an installed
# plugin cache differs from the checkout's plugin tree at the same version.
# Sourced by himmel-update.sh and himmel-doctor.sh. Bash 3.2 and BSD tools safe.
#
# plugin_cache_drift <checkout plugin dir> <cache dir>
#   Compares the whole tree, both directions. A completed compare prints one line
#   per drifting path and returns 0, with or without drift:
#     D <path>  in both trees, bytes differ
#     M <path>  the checkout ships it, the cache lacks it
#     X <path>  only the cache has it
#   Any read or git error, or a path with a newline (or one git quotes), returns
#   non-zero and prints nothing: the caller treats that as drift of unknown files.
#   The checkout ships its files; inside a git work tree, only those git lists as
#   tracked or unignored, and a cache-only path the checkout's ignore rules cover
#   is not drift. Skipped in both trees: node_modules/, __pycache__/, .git/, and
#   Claude Code's own cache files .in_use/ and .orphaned_at. The body is a
#   subshell with one locale, so sort and comm order the same way.

_pcd_walk() {
    local nl='
' odd
    ( cd "$1" && find . -type d \( -name node_modules -o -name __pycache__ -o -name .git -o -name .in_use \) -prune \
        -o -type f ! -name .orphaned_at -print ) > "$2.raw" 2>/dev/null || return 1
    odd="$( cd "$1" && find . -type d \( -name node_modules -o -name __pycache__ -o -name .git -o -name .in_use \) -prune \
        -o -name "*$nl*" -print 2>/dev/null )" || return 1
    [ -z "$odd" ] || return 1
    sed 's|^\./||' "$2.raw" > "$2.cut" || return 1
    sort -u "$2.cut" > "$2"
}

plugin_cache_drift() (
    export LC_ALL=C
    tree="$1" cache="$2"
    [ -d "$tree" ] && [ -d "$cache" ] || exit 1
    # prim-ok: private scratch the function removes itself; its callers do not source prim.sh
    work="$(mktemp -d "${TMPDIR:-/tmp}/plugin-drift.XXXXXX")" || exit 1
    trap 'rm -rf "$work"' EXIT
    _pcd_walk "$tree" "$work/tree" || exit 1
    _pcd_walk "$cache" "$work/cache" || exit 1
    in_git=0
    if [ "$(git -C "$tree" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
        in_git=1
        git -C "$tree" -c core.quotePath=false ls-files --cached --others --exclude-standard -- . > "$work/ls" 2>/dev/null || exit 1
        ! grep -q '^"' "$work/ls" || exit 1
        sort -u "$work/ls" > "$work/ls.sorted" || exit 1
        comm -12 "$work/tree" "$work/ls.sorted" > "$work/shipped" || exit 1
    else
        cp "$work/tree" "$work/shipped" || exit 1
    fi
    : > "$work/out" || exit 1
    while IFS= read -r f; do
        if [ ! -f "$cache/$f" ]; then
            printf 'M %s\n' "$f" >> "$work/out" || exit 1
            continue
        fi
        cmp -s "$tree/$f" "$cache/$f"
        case $? in
            0) ;;
            1) printf 'D %s\n' "$f" >> "$work/out" || exit 1 ;;
            *) exit 1 ;;
        esac
    done < "$work/shipped"
    comm -13 "$work/shipped" "$work/cache" > "$work/extra" || exit 1
    while IFS= read -r f; do
        if [ "$in_git" -eq 1 ]; then
            git -C "$tree" check-ignore -q -- "$f" 2>/dev/null
            case $? in
                0) continue ;;
                1) ;;
                *) exit 1 ;;
            esac
        fi
        printf 'X %s\n' "$f" >> "$work/out" || exit 1
    done < "$work/extra"
    cat "$work/out"
)
