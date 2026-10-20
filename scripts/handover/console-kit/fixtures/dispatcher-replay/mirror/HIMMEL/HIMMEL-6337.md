---
key: "HIMMEL-6337"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["security"]
fixVersions: []
parent: "HIMMEL-6168"
created: "2026-10-18T08:23:03.061+0200"
updated: "2026-10-18T08:31:06.721+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6338"]
---

# HIMMEL-6337: PR-check literal guard reads a heredoc body that re-expands the last argument via prompt expansion as a mention, so the guarded command runs

## Description

1. Find where the PR-check literal guard decides a heredoc body is mention-only (it shares the shell tokenizer, scripts/hooks/lib/shell-tokenize.sh).
Files: scripts/hooks/guard-pr-check-literal.sh, scripts/hooks/lib/shell-tokenize.sh (if the fix lives there), and their suites. Hook file: launch with the hook-integrity bypass. Never feed probe commands to the live hooks from the leg's own Bash; use fixture JSON fed to the worktree copy.
