#!/usr/bin/env bash
# forge-localgit.sh — the `local-git` forge backend
# (spec section 3). A local-git repo has no hosted PRs: a change is a branch,
# its id is `br-<branch>` (lowercased, `/` to `-`), and opening it writes a
# change record under <git-common-dir>/himmel/changes/<id>.json that every
# worktree of the repo shares. Verbs not defined here (pr_*, checks, merge)
# refuse with rc 4 through forge.sh's _forge_route; local checks and merge are
# WP5a/WP5b. Sourced by forge.sh; not run directly. Bash 3.2-safe.

# _lg_changes_dir — absolute <git-common-dir>/himmel/changes (not created).
_lg_changes_dir() {
    local common
    common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    common=$(cd "$common" && pwd -P) || return 1
    printf '%s/himmel/changes\n' "$common"
}

# _lg_json_str <s> — <s> as a JSON string literal (control characters dropped).
_lg_json_str() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# _lg_field <record> <key> — a string field of a change record. Records are
# written one field per line by lg_forge_change_open, so a line match is exact;
# the value is un-escaped (\\ to \, \" to ") through a placeholder byte that
# _lg_json_str can never emit.
_lg_field() {
    local soh
    soh=$(printf '\001')
    sed -n "s/^\"$2\":\"\\(.*\\)\",\\{0,1\\}\$/\\1/p" "$1" | head -n 1 |
        sed -e "s/\\\\\\\\/$soh/g" -e 's/\\"/"/g' -e "s/$soh/\\\\/g"
}

# _lg_default_base — the repo's default branch: origin/HEAD's target when set,
# else the first of main and master that exists, else main.
_lg_default_base() {
    local b
    if b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$b" ]; then
        printf '%s\n' "${b#origin/}"
        return 0
    fi
    for b in main master; do
        if git rev-parse --verify --quiet "refs/heads/$b^{commit}" >/dev/null 2>&1; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    printf 'main\n'
}

# _lg_valid_id <id> — rc 0 when the WHOLE value is ^br-[a-z0-9._-]+$. A [[ =~ ]]
# match is anchored on the string, not per line, so a value carrying a newline
# (br-ok, newline, ../x) is refused rather than passing on its first line.
_lg_valid_id() {
    local re='^br-[a-z0-9._-]+$'
    [[ $1 =~ $re ]]
}

# lg_forge_change_id [branch] — print br-<branch>; the current branch when none
# is given. rc 2 when the id is not ^br-[a-z0-9._-]+$, or when the change
# record for that id already belongs to another branch (feat/a-b and feat-a/b
# both map to br-feat-a-b: the second is refused, never merged into the first).
lg_forge_change_id() {
    local branch="${1:-}" id dir rec owner
    [ -n "$branch" ] || branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    if [ -z "$branch" ]; then
        echo "forge(local-git): change_id needs a branch (HEAD is detached)" >&2
        return 2
    fi
    id="br-$(printf '%s' "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
    if ! _lg_valid_id "$id"; then
        echo "forge(local-git): branch '$branch' gives change id '$id', outside ^br-[a-z0-9._-]+\$ — rename the branch" >&2
        return 2
    fi
    dir=$(_lg_changes_dir) || dir=""
    rec="$dir/$id.json"
    if [ -n "$dir" ] && [ -f "$rec" ]; then
        owner=$(_lg_field "$rec" branch)
        if [ "$owner" != "$branch" ]; then
            echo "forge(local-git): change id $id already belongs to branch '$owner' — '$branch' collides with it; rename one branch" >&2
            return 2
        fi
    fi
    printf '%s\n' "$id"
}

# lg_forge_change_open <branch> <title-file> <body-file> — write the change
# record and print the change id. The title is the title file's first line;
# the body is copied beside the record as <id>.body.md; the base is the repo's
# default branch. A new record is claimed with a hard link, which fails when
# the record exists, so two colliding opens cannot both pass the ownership
# check. Re-opening the same branch rewrites its record (a temp file renamed
# into place); a record owned by another branch refuses with rc 2.
lg_forge_change_open() {
    local branch="${1:-}" title_file="${2:-}" body_file="${3:-}" id dir title tmp btmp rec owner
    if [ -z "$branch" ] || [ ! -f "$title_file" ] || [ ! -f "$body_file" ]; then
        echo "forge(local-git): usage: change_open <branch> <title-file> <body-file>" >&2
        return 2
    fi
    id=$(lg_forge_change_id "$branch") || return $?
    dir=$(_lg_changes_dir) || { echo "forge(local-git): not inside a git repository" >&2; return 1; }
    mkdir -p "$dir" || return 1
    IFS= read -r title < "$title_file" || [ -n "$title" ] || title=""
    rec="$dir/$id.json"
    tmp=$(mktemp "$dir/.$id.json.XXXXXX") || return 1
    {
        printf '{\n'
        printf '"id":%s,\n' "$(_lg_json_str "$id")"
        printf '"branch":%s,\n' "$(_lg_json_str "$branch")"
        printf '"base":%s,\n' "$(_lg_json_str "$(_lg_default_base)")"
        printf '"title":%s,\n' "$(_lg_json_str "$title")"
        printf '"body_path":%s,\n' "$(_lg_json_str "$dir/$id.body.md")"
        printf '"opened_at":%s\n' "$(_lg_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
        printf '}\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    # Stage the body before any record is published: a failed copy leaves no
    # record pointing at a missing or stale body.
    btmp=$(mktemp "$dir/.$id.body.md.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp "$body_file" "$btmp" 2>/dev/null || {
        rm -f "$tmp" "$btmp"
        echo "forge(local-git): cannot copy the body $body_file" >&2
        return 1
    }
    if ln "$tmp" "$rec" 2>/dev/null; then
        rm -f "$tmp"
        mv -f "$btmp" "$dir/$id.body.md" || { rm -f "$btmp" "$rec"; return 1; }
    else
        if [ ! -f "$rec" ]; then
            rm -f "$tmp" "$btmp"
            echo "forge(local-git): cannot write the change record $rec" >&2
            return 1
        fi
        owner=$(_lg_field "$rec" branch)
        if [ "$owner" != "$branch" ]; then
            rm -f "$tmp" "$btmp"
            echo "forge(local-git): change id $id already belongs to branch '$owner' — '$branch' collides with it; rename one branch" >&2
            return 2
        fi
        mv -f "$btmp" "$dir/$id.body.md" || { rm -f "$tmp" "$btmp"; return 1; }
        mv -f "$tmp" "$rec" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s\n' "$id"
}

# lg_forge_change_view <id> — one compact JSON object {id, head, base, title,
# state, merged}: head is the branch tip now; state is MERGED when that tip is
# already in the base branch, OPEN otherwise, CLOSED when the branch is gone.
# rc 1 when no change record holds <id>.
lg_forge_change_view() {
    local id="${1:-}" dir rec branch base title head state merged=false
    if ! _lg_valid_id "$id"; then
        echo "forge(local-git): '$id' is not a change id (^br-[a-z0-9._-]+\$)" >&2
        return 1
    fi
    dir=$(_lg_changes_dir) || dir=""
    rec="$dir/$id.json"
    if [ -z "$dir" ] || [ ! -f "$rec" ]; then
        echo "forge(local-git): no change record for '$id'" >&2
        return 1
    fi
    branch=$(_lg_field "$rec" branch)
    base=$(_lg_field "$rec" base)
    title=$(_lg_field "$rec" title)
    head=$(git rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null) || head=""
    if [ -z "$head" ]; then
        state=CLOSED
    elif git merge-base --is-ancestor "$head" "refs/heads/$base" 2>/dev/null; then
        state=MERGED; merged=true
    else
        state=OPEN
    fi
    printf '{"id":%s,"head":%s,"base":%s,"title":%s,"state":"%s","merged":%s}\n' \
        "$(_lg_json_str "$id")" "$(_lg_json_str "$head")" "$(_lg_json_str "$base")" \
        "$(_lg_json_str "$title")" "$state" "$merged"
}

# lg_forge_repo_id — local:<absolute git-common-dir>, the repo's identity that
# every worktree shares (go-gate.sh reads the trust list through it).
lg_forge_repo_id() {
    local dir
    dir=$(_lg_changes_dir) || { echo "forge(local-git): not inside a git repository" >&2; return 1; }
    printf 'local:%s\n' "${dir%/himmel/changes}"
}
