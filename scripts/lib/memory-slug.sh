#!/usr/bin/env bash
# scripts/lib/memory-slug.sh — SOURCED. The ONE definition of where the
# per-project auto-memory lives, shared by scripts/memory/audit-memory-capture.sh
# and scripts/memory/memory-snapshot.sh.
#
#   memory_slug <abs path>     Claude Code's project-dir slug: every character
#                              outside [A-Za-z0-9] becomes `-` (so `.` and `_`
#                              map too, not just `/`, `:` and `\`).
#   memory_resolve_memdir      print <config>/projects/<slug of the PRIMARY
#                              checkout>/memory; rc 1 + a stderr line when cwd is
#                              not in a git repo. <config> is CLAUDE_CONFIG_DIR,
#                              else ~/.claude.
#
# An explicit MEMDIR (env) always wins and never reaches this file. Documented
# relocation knobs it does NOT follow (code.claude.com/docs/en/memory):
# autoMemoryDirectory (settings) and CLAUDE_CODE_PROJECT_DIR_NAME; point MEMDIR
# at the relocated store instead.
#
# scripts/hooks/memory-index-state-notice.sh keeps its own inline copy of the
# slug rule (fail-open SessionStart hook, not rewired here); row A9 of
# scripts/memory/test-audit-memory-capture.sh turns RED if the two drift.
#
# bash 3.2-safe.

memory_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

memory_resolve_memdir() {
    local gcd root
    # The PRIMARY checkout's slug, not a worktree's: --git-common-dir is the
    # shared .git dir every worktree points back at.
    gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$gcd" ]; then
        # git < 2.31 lacks --path-format (empty, not an error). The plain form
        # can return a RELATIVE path (".git"): resolve it against cwd or the
        # slug would differ from the --path-format=absolute case.
        gcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
        case "$gcd" in
            ""|/*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;
            *) gcd="$(cd "$gcd" 2>/dev/null && pwd -P)" ;;
        esac
    fi
    [ -n "$gcd" ] || {
        printf '%s\n' 'memory: not inside a git repo (git --git-common-dir returned nothing) — cannot derive MEMDIR; set MEMDIR explicitly or run from a repo' >&2
        return 1
    }
    root="$(dirname "$gcd")"
    printf '%s/projects/%s/memory\n' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}" "$(memory_slug "$root")"
}
