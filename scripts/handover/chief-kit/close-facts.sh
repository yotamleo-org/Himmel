#!/usr/bin/env bash
# scripts/handover/chief-kit/close-facts.sh - SOURCED, never run. The local
# merged-or-not proof for a finished worker's branch: built from the worker doc
# and the repo's own refs, with no `gh` and no network call.
#
#   doc_ready_head <doc> <pr>                  newest `READY <pr> <40-hex> GREEN` head
#   doc_pr <doc>                               the PR of the newest READY or MERGED bullet
#   merged_commit_of <repo> <pr>               the one first-parent commit on origin/main ending (#<pr>)
#   merged_proof <repo> <doc> <branch> <tip>   one cache row when M1 to M4 all hold
#   no_work_proof <repo> <doc> <branch> <tip>  a 0-row branch cache when the branch holds nothing to lose
#   write_branch_cache <repo> <branch> [<row>] a branch-scoped `worktree.sh --pr-cache` file
#   successor_live <doc> <predecessor 0|1> <named successor>  the named successor holds its lock, or a later RESUME doc keeps it live
#   later_successor_live <doc>                 a later-lettered RESUME doc beside <doc> holds a lock or names a worktree <doc> names
#
# A proof only feeds `worktree.sh prune --only --pr-cache` a cache row; it never
# decides a prune. Every failure prints nothing, so a missing proof keeps work.
# Sourced by close-sweep.sh.
# bash 3.2-safe.

_CF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$_CF_HERE/../../lib/git-clean.sh" || return 1
# shellcheck source=../../lib/worker-identity.sh
. "$_CF_HERE/../../lib/worker-identity.sh" || return 1

cf_git() {
    local repo="$1"; shift
    git_clean -C "$repo" "$@"
}

origin_nwo() {
    local url path
    url=$(cf_git "$1" remote get-url origin) || return 1
    case "$url" in
        https://github.com/*|http://github.com/*) path="${url#*github.com/}" ;;
        git@github.com:*) path="${url#git@github.com:}" ;;
        ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    path="${path%.git}"
    path="${path%/}"
    case "$path" in
        */*) printf '%s\n' "$path" ;;
        *) return 1 ;;
    esac
}

doc_ready_head() {
    local doc="$1" pr="$2" line rest found=""
    [ -f "$doc" ] || return 0
    while IFS= read -r line; do
        rest=$(printf '%s\n' "$line" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')
        if [[ $rest =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+GREEN([^A-Za-z0-9_]|$) ]] \
            && [ "${BASH_REMATCH[1]}" = "$pr" ]; then
            found="${BASH_REMATCH[2]}"
        fi
    done < <(grep -E '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY' "$doc")
    if [ -n "$found" ]; then printf '%s\n' "$found"; fi
    return 0
}

doc_pr() {
    [ -f "$1" ] || return 0
    grep -E '^- ([0-9:]+ )?(\*\*)?(READY|MERGED)' "$1" | grep -oE '(READY|MERGED)[ #-]+(PR[ #]+)?[0-9]+' | tail -n 1 | grep -oE '[0-9]+$' || true
}

merged_commit_of() {
    local hits count
    hits=$(cf_git "$1" log --first-parent -2000 --format='%H%x09%s' refs/remotes/origin/main 2>/dev/null \
        | awk -F'\t' -v pat="(#$2)" 'length($2) >= length(pat) && substr($2, length($2) - length(pat) + 1) == pat { print $1 }') || return 0
    [ -n "$hits" ] || return 0
    count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    if [ "$count" = "1" ]; then printf '%s\n' "$hits"; fi
    return 0
}

# merged_proof <repo> <doc> <branch> <tip>: one `<nwo>\t<branch>\tmerged\t<tip>`
# row when all four hold, else nothing:
#   M1 the doc's PR n has exactly one (#n) commit S on origin/main
#   M2 the branch tip is the doc's newest READY head H for n
#   M3 S changes exactly the files the PR changed
#   M4 merging H into S adds nothing (git merge-tree --write-tree S H is clean
#      and its tree is S's tree); an old git without --write-tree fails closed
merged_proof() {
    local repo="$1" doc="$2" branch="$3" tip="$4" pr head nwo s files_s mb files_h mt st
    pr=$(doc_pr "$doc")
    [ -n "$pr" ] || return 0
    head=$(doc_ready_head "$doc" "$pr")
    [ -n "$head" ] || return 0
    nwo=$(origin_nwo "$repo") || return 0
    s=$(merged_commit_of "$repo" "$pr")
    [ -n "$s" ] || return 0
    [ "$tip" = "$head" ] || return 0
    files_s=$(cf_git "$repo" diff --name-only "${s}^" "$s" | sort) || return 0
    [ -n "$files_s" ] || return 0
    mb=$(cf_git "$repo" merge-base "${s}^" "$head") || return 0
    files_h=$(cf_git "$repo" diff --name-only "$mb" "$head" | sort) || return 0
    [ "$files_s" = "$files_h" ] || return 0
    mt=$(cf_git "$repo" merge-tree --write-tree "$s" "$head") || return 0
    st=$(cf_git "$repo" rev-parse "${s}^{tree}") || return 0
    [ "$mt" = "$st" ] || return 0
    printf '%s\t%s\tmerged\t%s\n' "$nwo" "$branch" "$tip"
}

write_branch_cache() {
    local repo="$1" branch="$2" row="${3:-}" nwo n=0
    nwo=$(origin_nwo "$repo") || return 1
    printf '# nwo=%s\n# scope=branch %s\n' "$nwo" "$branch"
    if [ -n "$row" ]; then printf '%s\n' "$row"; n=1; fi
    printf '# complete rows=%s\n' "$n"
}

no_work_proof() {
    local repo="$1" doc="$2" branch="$3" tip="$4" ahead
    [ -z "$(doc_pr "$doc")" ] || return 0
    if [ -f "$doc" ] && grep -qE '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY' "$doc"; then return 0; fi
    if cf_git "$repo" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null 2>&1; then return 0; fi
    ahead=$(cf_git "$repo" rev-list --count "refs/remotes/origin/main..$tip") || return 0
    [ "$ahead" = "0" ] || return 0
    write_branch_cache "$repo" "$branch" || return 0
}

later_successor_live() {
    local doc="$1" sib_dir sib_label doc_worktrees cand lbase cl cwd
    sib_dir="$(dirname "$doc")"
    sib_label="$(worker_label "$doc")"
    [[ $sib_label =~ ^(N[0-9]+)[a-z]*$ ]] || return 1
    lbase="${BASH_REMATCH[1]}"
    doc_worktrees=$(grep -oE "/[^\` ]*/\.claude/worktrees/[^\`) ]+" "$doc" | sort -u)
    for cand in "$sib_dir"/*-RESUME.md; do
        [ -f "$cand" ] && [ ! -L "$cand" ] && [ "$cand" != "$doc" ] || continue
        cl="$(worker_label "$cand")"
        [[ $cl =~ ^${lbase}[a-z]*$ ]] && [[ $cl > $sib_label ]] || continue
        bash "$_CF_HERE/../queue-lock.sh" status "$cand" >/dev/null 2>&1 || return 0
        cwd="$(sed -n '1,20s/^resume_cwd:[[:space:]]*//p' "$cand" | head -n 1)"
        [ -n "$cwd" ] && [ -n "$doc_worktrees" ] && grep -qxF -- "$cwd" <<< "$doc_worktrees" && return 0
    done
    return 1
}

successor_live() {
    local doc="$1" predecessor="$2" named="$3"
    { [ "$predecessor" = "1" ] && ! bash "$_CF_HERE/../queue-lock.sh" status "$named" >/dev/null 2>&1; } || later_successor_live "$doc"
}
