#!/usr/bin/env bash
# anchor-bytes.sh — sourced lib: prove a worktree's copy of named scripts is the
# primary checkout's (the anchor's) committed copy, byte for byte and mode for mode.
#
#   anchor_bytes_match <anchor-root> <worktree-root> <rel-path>...   (rc 0 = all match)
#
# Same method as guard-pr-check-literal.sh's step-3 manifest check: the anchor must
# be on refs/heads/main with each path equal to main's committed blob (ls-tree, which
# runs no filter), and the worktree's file must hash to the same blob and mode.
# Blob ids come from `hash-object --no-filters` (no clean filter can normalise an
# edit back; no index or assume-unchanged flag is read). A missing file, a symlink
# or a symlinked parent directory on either side is a mismatch. Refs other than
# refs/heads/main are never consulted: a leg can move refs/remotes/* freely.
# ponytail: checked at call time only, a swap between this check and the exec is not closed here; guard-pr-check-literal.sh still carries its own copy of this method, move it onto this lib to keep one.
# git-env-ok: sourced only by hooks that already ran git_env_scrub
# Bash 3.2-compatible.

_ab_git() { git --no-replace-objects -c core.fsmonitor=false -c core.quotePath=false "$@"; }

# _ab_plain <root> <rel-path>: regular file, no symlink in any component under root.
_ab_plain() {
    local root=$1 rel=$2 acc="" part rest
    rest=$rel
    while [ -n "$rest" ]; do
        part=${rest%%/*}
        if [ "$part" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
        case "$part" in ''|.|..) return 1 ;; esac
        acc="${acc:+$acc/}$part"
        [ ! -L "$root/$acc" ] || return 1
    done
    [ -f "$root/$rel" ]
}

# _ab_mode <root> <rel-path>: 100755 or 100644.
_ab_mode() { if [ -x "$1/$2" ]; then printf 100755; else printf 100644; fi; }

anchor_bytes_match() {
    local anchor=$1 wt=$2 rel head_ref want have_oid
    shift 2
    [ $# -gt 0 ] || return 1
    head_ref=$(_ab_git -C "$anchor" symbolic-ref -q HEAD 2>/dev/null) || return 1
    [ "$head_ref" = refs/heads/main ] || return 1
    for rel in "$@"; do
        case "$rel" in /*|*[[:cntrl:]]*|*' '*) return 1 ;; esac
        _ab_plain "$anchor" "$rel" && _ab_plain "$wt" "$rel" || return 1
        # "<mode> <blob>" main commits for this path.
        want=$(_ab_git -C "$anchor" ls-tree --full-tree refs/heads/main -- "$rel" 2>/dev/null \
            | awk -F'\t' 'NF == 2 { split($1, m, " "); print m[1] " " m[3] }') || return 1
        [ -n "$want" ] && [ "$(printf '%s\n' "$want" | wc -l)" -eq 1 ] || return 1
        # The anchor's working copy must itself equal main (else it is not a base).
        have_oid=$(_ab_git -C "$anchor" hash-object --no-filters -- "$anchor/$rel" 2>/dev/null) || return 1
        [ "$(_ab_mode "$anchor" "$rel") $have_oid" = "$want" ] || return 1
        have_oid=$(_ab_git -C "$wt" hash-object --no-filters -- "$wt/$rel" 2>/dev/null) || return 1
        [ "$(_ab_mode "$wt" "$rel") $have_oid" = "$want" ] || return 1
    done
    return 0
}
