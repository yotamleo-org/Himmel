#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-graphify-path-advice.sh — refuse the graphify installer's `graphify path`
# advice in the agent instruction files (HIMMEL-5303).
#
# CLAUDE.md "Retrieval routing" bans `graphify path` (node IDs are file-scoped,
# so cross-file traversal is structurally broken). But `graphify install` /
# `graphify update` rewrites the `## graphify` section of CLAUDE.md, AGENTS.md
# and GEMINI.md with upstream text that RECOMMENDS it:
#   Use `graphify path "<A>" "<B>"` for relationships ...
# A hand fix does not stick, so this gate catches the re-introduction at commit
# time. The ban prose itself (`never `graphify path``, no arguments) is not a hit:
# only an invocation with arguments (`graphify path "...` / `graphify path <...`)
# is advice.
#
# Fix on a hit: delete the `Use `graphify path ...` for relationships and` clause
# from the flagged line; in AGENTS.md regenerate with
# `node scripts/agents-md/generate.mjs --write` rather than hand-editing.
#
# Usage: check-graphify-path-advice.sh [repo-root]   (default: this checkout)
# Exit: 0 clean · 1 findings (path:line:match) · 2 cannot evaluate

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="${1:-$(cd "$SELF_DIR/../.." && pwd)}"

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "check-graphify-path-advice: '$ROOT' is not a git checkout" >&2; exit 2; }

rc=0
out="$(git -C "$ROOT" grep -nIE 'graphify path[[:space:]]+["'"'"'<]' -- CLAUDE.md AGENTS.md GEMINI.md)" || rc=$?
case "$rc" in
    0)
        printf '%s\n' "$out"
        echo "check-graphify-path-advice: the graphify installer text recommends \`graphify path\`, which CLAUDE.md bans (file-scoped node IDs, HIMMEL-5303)." >&2
        echo "  Remove the \`Use \`graphify path ...\` for relationships and\` clause; regenerate AGENTS.md with: node scripts/agents-md/generate.mjs --write" >&2
        exit 1
        ;;
    1) exit 0 ;;
    *) echo "check-graphify-path-advice: git grep failed (rc=$rc)" >&2; exit 2 ;;
esac
