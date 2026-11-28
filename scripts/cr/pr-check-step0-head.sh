# shellcheck shell=bash
# scripts/cr/pr-check-step0-head.sh - the step 0 head record, sourced, no CLI. Bash 3.2 safe.
# sourced-lib: sourced by pr-check-context.sh and panel-first-pass.sh only
# git-env-ok: inherits the caller's GIT_*: pr-check-context.sh has scrubbed it, and panel-first-pass.sh's record lookup must answer about the same repository as its live HEAD and critic-panel's pin
#
# pr-check-context.sh (step 0) writes the full head it resolved for a checked-out branch, and
# panel-first-pass.sh reads it, so no session types a full sha into the panel call. The record is
# <absolute git common dir>/cr-step0-head/<key>, where <key> is `git hash-object --stdin` of the
# branch name, and holds exactly three lines: branch=<branch>, head=<full sha>, toplevel=<worktree root>.
# No other production file builds the path or parses the format.
#
#   step0_toplevel           prints `git rev-parse --show-toplevel`; rc 1 outside a work tree
#   step0_abs_common_dir     prints the cwd's absolute git common dir; rc 1 outside a repository
#   step0_head_path <b>      prints the record path; rc 1 on an empty branch or outside a repository
#   step0_head_write <b> <h> writes the record (temp file, then mv); rc 1 on any failure, no stdout
#   step0_head_read <b>      rc 0: prints <branch>\t<head>\t<toplevel>; rc 1: nothing at the path;
#                            rc 2: prints the path to remove (the record, or cr-step0-head itself
#                            when that is a symlink or not a directory)
#   step0_head_clear <b>     removes the record; rc 1 prints what is still there (the record, or
#                            cr-step0-head itself); does nothing for an empty branch

step0_toplevel() {
    git rev-parse --show-toplevel 2>/dev/null
}

step0_abs_common_dir() {
    local raw
    raw="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1  # swallow-ok: outside a repository there is no record path (rc 1)
    [ -n "$raw" ] || return 1
    case "$raw" in
        /*) printf '%s\n' "$raw" ;;
        *) (CDPATH='' cd -P -- "./$raw" 2>/dev/null && pwd -P) || return 1 ;;
    esac
}

step0_head_path() {
    local common key
    [ -n "${1:-}" ] || return 1
    common="$(step0_abs_common_dir)" || return 1
    key="$(printf '%s' "$1" | git hash-object --stdin 2>/dev/null)" || return 1  # swallow-ok: a failed hash names no record path (rc 1)
    [ -n "$key" ] || return 1
    printf '%s/cr-step0-head/%s\n' "$common" "$key"
}

_step0_dir_bad() {
    [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }
}

step0_head_write() {
    local p d top v tmpf
    p="$(step0_head_path "${1:-}")" || return 1
    d="${p%/*}"
    top="$(step0_toplevel)" || return 1
    for v in "$1" "${2:-}" "$top"; do
        case "$v" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
    done
    ! _step0_dir_bad "$d" || return 1
    mkdir -p "$d" 2>/dev/null || return 1
    ! _step0_dir_bad "$d" || return 1
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -f "$p" ]; }; then return 1; fi
    tmpf="$(mktemp "$d/.tmp.XXXXXX" 2>/dev/null)" || return 1  # swallow-ok: a failed mktemp is a failed write (rc 1), which the caller warns about
    if printf 'branch=%s\nhead=%s\ntoplevel=%s\n' "$1" "$2" "$top" > "$tmpf" && mv -f "$tmpf" "$p"; then  # prim-ok: the temp file sits in the record's own directory, so mv is one rename; a sourced library the fixture suites copy alone, without prim.sh
        return 0
    fi
    rm -f "$tmpf"
    return 1
}

step0_head_read() {
    local p d line k v b="" h="" t="" nb=0 nh=0 nt=0 bad=0
    p="$(step0_head_path "${1:-}")" || return 1
    d="${p%/*}"
    if _step0_dir_bad "$d"; then printf '%s\n' "$d"; return 2; fi
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 1; fi
    if [ -L "$p" ] || [ ! -f "$p" ]; then printf '%s\n' "$p"; return 2; fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *=*) k="${line%%=*}"; v="${line#*=}" ;;
            *) bad=1; break ;;
        esac
        case "$v" in ''|*$'\t'*) bad=1; break ;; esac
        case "$k" in
            branch) nb=$((nb + 1)); b="$v" ;;
            head) nh=$((nh + 1)); h="$v" ;;
            toplevel) nt=$((nt + 1)); t="$v" ;;
            *) bad=1; break ;;
        esac
    done 2>/dev/null < "$p"  # read-sink-ok: $p comes from step0_head_path, a hash-named file under the git common dir, never argv or env
    [ "$bad" -ne 0 ] || [ "$(git rev-parse --verify --quiet "$h^{commit}" 2>/dev/null)" = "$h" ] || bad=1  # swallow-ok: a head= that is not this repo's full id of a commit is malformed (rc 2)
    if [ "$bad" -ne 0 ] || [ "$nb" -ne 1 ] || [ "$nh" -ne 1 ] || [ "$nt" -ne 1 ]; then
        printf '%s\n' "$p"
        return 2
    fi
    printf '%s\t%s\t%s\n' "$b" "$h" "$t"
}

step0_head_clear() {
    local p d
    [ -n "${1:-}" ] || return 0
    p="$(step0_head_path "$1")" || return 0
    d="${p%/*}"
    if _step0_dir_bad "$d"; then printf '%s\n' "$d"; return 1; fi
    rm -f "$p" 2>/dev/null
    if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; return 1; fi
    return 0
}
