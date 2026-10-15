#!/usr/bin/env bash
# forge-none.sh — the `none` forge backend (spec
# section 3). A repo with no forge has no PRs, no checks and no merges to drive,
# so every verb refuses with rc 4, the "unsupported here" exit every backend
# uses. Each verb is spelled out so a reader (and the contract suite) sees the
# whole surface. Sourced by forge.sh; not run directly.

_none_refuse() {
    echo "forge(none): $1 is not available — this repo has no forge (FORGE=none)" >&2
    return 4
}

none_forge_auth_status()    { _none_refuse auth_status; }
none_forge_repo_nwo()       { _none_refuse repo_nwo; }
none_forge_default_branch() { _none_refuse default_branch; }
none_forge_user_slug()      { _none_refuse user_slug; }
none_forge_pr_find_open()   { _none_refuse pr_find_open; }
none_forge_pr_create()      { _none_refuse pr_create; }
none_forge_pr_set_body()    { _none_refuse pr_set_body; }
none_forge_pr_mergeable()   { _none_refuse pr_mergeable; }
none_forge_pr_merge()       { _none_refuse pr_merge; }
none_forge_pr_has_merged()  { _none_refuse pr_has_merged; }
none_forge_issue_create()   { _none_refuse issue_create; }
none_forge_change_id()      { _none_refuse change_id; }
none_forge_change_view()    { _none_refuse change_view; }
none_forge_change_open()    { _none_refuse change_open; }
none_forge_checks()         { _none_refuse checks; }
none_forge_repo_id()        { _none_refuse repo_id; }
