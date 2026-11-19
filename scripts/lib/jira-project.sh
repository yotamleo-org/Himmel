#!/usr/bin/env bash
# jira-project.sh — the one place a shell script learns which Jira project it works on and
# where that project's mirror lives. Source it, then call:
#   jira_project_key   print the project key
#   jira_mirror_dir    print the mirror directory
#   jira_project_configured   succeed when a key is set anywhere (env, himmel.conf, .env), so
#                      the HIMMEL fallback does not count as configured
#
# Key: JIRA_PROJECT_KEY from the process env when non-empty, else the value load_dotenv finds
# (himmel.conf, then .env), else HIMMEL. An exported empty value counts as unset, the same
# rule load_dotenv uses. The lookup runs in a subshell, so nothing is exported into the caller.
# A value that is not an upper-case project key (letter, then letters, digits, underscores) warns
# on stderr without echoing it, and gives HIMMEL, so no mirror path is built from it.
# Mirror dir: HIMMEL_JIRA_MIRROR when non-empty (the override the config UI reads for the
# project JIRA_PROJECT_KEY names), else $HOME/.himmel/state/jira-mirror/<key>, the path the
# jira CLI's defaultRoot builds. Both print one line, never a credential, and are safe under
# `set -u`.

if ! declare -F load_dotenv >/dev/null 2>&1; then
    # shellcheck source=load-dotenv.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/load-dotenv.sh"
fi

jira_project_key() {
    local _jp_key="${JIRA_PROJECT_KEY:-}"
    if [ -z "$_jp_key" ]; then
        _jp_key=$(load_dotenv JIRA_PROJECT_KEY; printf '%s' "${JIRA_PROJECT_KEY:-}")
    fi
    local LC_ALL=C
    case "$_jp_key" in
        '') _jp_key=HIMMEL ;;
        [!A-Z]*|*[!A-Z0-9_]*)
            echo "jira-project: JIRA_PROJECT_KEY is not a valid project key; using HIMMEL" >&2
            _jp_key=HIMMEL ;;
    esac
    printf '%s\n' "$_jp_key"
}

jira_project_configured() {
    [ -n "${JIRA_PROJECT_KEY:-}" ] && return 0
    [ -n "$(load_dotenv JIRA_PROJECT_KEY; printf '%s' "${JIRA_PROJECT_KEY:-}")" ]
}

jira_mirror_dir() {
    if [ -n "${HIMMEL_JIRA_MIRROR:-}" ]; then
        printf '%s\n' "$HIMMEL_JIRA_MIRROR"
        return 0
    fi
    printf '%s/.himmel/state/jira-mirror/%s\n' "${HOME:-}" "$(jira_project_key)"
}
