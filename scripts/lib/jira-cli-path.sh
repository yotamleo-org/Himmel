#!/usr/bin/env bash
# scripts/lib/jira-cli-path.sh - sourced: the primary checkout and its Jira CLI.
#   himmel_primary_root      prints the parent of this tree's --git-common-dir; 1 when unknown
#   jira_cli_path            prints the CLI: OWE_JIRA_CLI (tests), else the primary checkout's
#                            scripts/jira/dist/index.js; 1 when there is none
#   jira_cli_run <key> ...   runs it with JIRA_PROJECT_KEY set to the key's project
# gate-repo-resolver.sh's gate_repo_dir is not reused: it honours HIMMEL_REPO, which the
# Jira CLI lookup does not.
#
# Platform guard: POSIX bash 3.2+.

himmel_primary_root() {
    local kit common
    kit="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
    # shellcheck source=scripts/lib/git-clean.sh
    . "$kit/git-clean.sh" 2>/dev/null || return 1
    common="$(git_clean -C "$kit" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1  # swallow-ok: no git, or an old git, is "unknown"
    [ -n "$common" ] || return 1
    dirname -- "$common"
}

jira_cli_path() {
    local cli="${OWE_JIRA_CLI:-}" root
    if [ -z "$cli" ]; then
        root="$(himmel_primary_root)" && cli="$root/scripts/jira/dist/index.js"
    fi
    [ -n "$cli" ] && [ -e "$cli" ] || return 1
    printf '%s\n' "$cli"
}

jira_cli_run() {
    local key="$1" cli
    shift
    cli="$(jira_cli_path)" || return 1
    case "$cli" in
        *.js) JIRA_PROJECT_KEY="${key%%-*}" node "$cli" "$@" ;;
        *) JIRA_PROJECT_KEY="${key%%-*}" "$cli" "$@" ;;
    esac
}
