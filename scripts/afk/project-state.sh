#!/usr/bin/env bash
# afk/project-state — which project a /afk-shift runs for, and where its state lives.
#
# The project is the repository of the current directory, identified by git's
# common dir, so every worktree of one project shares one shift. Its key is
# <name slug>-<cksum of the common dir path>, the name being the checkout's
# directory (or a --separate-git-dir's own name): two projects with the same
# directory name still get two keys.
#
# The himmel clone (it carries scripts/adopt.sh, which adopt never copies into a
# project) and a run outside any git repository keep the paths the shift always
# had: ledger TSVs in /tmp, the stop marker at ~/.claude/.overnight-stop, the
# morning report at the handover root. An adopted
# project keeps them under <handover root>/afk/<key>/ and ~/.claude/afk/<key>/.
#
# Source it for the afk_* functions, or run it:
#   project-state.sh key        print the project key
#   project-state.sh dir        print (and create) the ledger and plan dir
#   project-state.sh legacy     exit 0 where the original paths apply, 1 in an adopted project
#
# Exit codes (run mode): 0 ok, 1 adopted project (legacy), 2 usage or unresolvable.

_AFK_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# afk_git_common_dir — the repository's common git dir, shared by every worktree.
afk_git_common_dir() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
        echo "project-state: not inside a git repository" >&2
        return 2
    }
    (cd "$common" && pwd -P)
}

# afk_legacy_paths — exit 0 where the shift keeps its original paths: the himmel
# clone, or no project at all (outside a git repository).
afk_legacy_paths() {
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [ -f "$top/scripts/adopt.sh" ]
}

afk_project_key() {
    local common name slug sum
    common=$(afk_git_common_dir) || return 2
    case "$common" in
        */.git) name=$(basename "$(dirname "$common")") ;;
        *)      name=$(basename "$common" .git) ;;
    esac
    slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    sum=$(printf '%s' "$common" | cksum | cut -d' ' -f1)
    printf '%s-%s\n' "${slug:-project}" "$sum"
}

# afk_stop_dir — the stop marker's directory (AFK_STOP_DIR wins).
afk_stop_dir() {
    local key
    if [ -n "${AFK_STOP_DIR:-}" ]; then
        printf '%s\n' "$AFK_STOP_DIR"
    elif afk_legacy_paths; then
        printf '%s\n' "$HOME/.claude"
    else
        key=$(afk_project_key) || return 2
        printf '%s\n' "$HOME/.claude/afk/$key"
    fi
}

# afk_report_subdir — appended to the handover root for the morning report.
afk_report_subdir() {
    local key
    if afk_legacy_paths; then return 0; fi
    key=$(afk_project_key) || return 2
    printf '/afk/%s\n' "$key"
}

# afk_state_dir — the ledger TSVs and plan. Creates the dir (a write op).
afk_state_dir() {
    local root sub
    if afk_legacy_paths; then printf '/tmp\n'; return 0; fi
    # shellcheck disable=SC1091
    if . "$_AFK_STATE_DIR/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
    # shellcheck source=../lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$_AFK_STATE_DIR/../lib/handover-path.sh"
    root=$(handover_root_ensure) || return 2
    sub=$(afk_report_subdir) || return 2
    mkdir -p "$root$sub" || return 2
    printf '%s\n' "$root$sub"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        key)      afk_project_key ;;
        dir)      afk_state_dir ;;
        legacy)   afk_legacy_paths ;;
        *)        echo "Usage: project-state.sh key|dir|legacy" >&2; exit 2 ;;
    esac
fi
