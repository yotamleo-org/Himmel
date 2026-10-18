---
name: clean-garden
description: Prune merged-PR worktrees AND create a new one in one shot. Use for /clean_garden or prune-and-create.
---

# clean-garden

When the user asks to prune-and-create, run:

    bash scripts/worktree.sh new <branch-name> [--no-prune] [--no-install] [--dry-run]

(`scripts/clean-garden.sh` is a deprecated forwarder to `worktree.sh new|prune`.)

`<branch-name>` is `type/slug`. Summarize prunes, then the created worktree path.

`bash scripts/worktree.sh prune --health` (no other flag) is the read-only health check: alarm lines only (`LOST-COMMITS`, `STUCK`, `SWEEP-ERROR`), empty when healthy, exit 1 if any.
