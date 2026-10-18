---
name: worktree
description: Create a git worktree under .claude/worktrees/ for a type/slug branch. Use for /worktree.
---

# worktree

When the user asks to create a worktree, run:

    bash scripts/worktree.sh new --no-prune <branch-name> [--no-install] [--verbose] [--dry-run]

Branch must be `type/slug` (type ∈ feat|fix|chore|docs|refactor|test). After the
OK line, report the printed worktree path so the operator can `cd` in. For
prune+create use `worktree.sh new <branch>` (no `--no-prune`); for prune-only use `clean`.
