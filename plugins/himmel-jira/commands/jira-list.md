---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: List Jira issues in a project, optionally filtered by status. Returns one-line summary; full table in normal.log.
argument-hint: "[project] [status]"
---

## Your task

Run exactly:

```
himmel-run jira --summary-regex '^(\d+) issues?' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js list ${1:+--project "$1"} ${2:+--status "$2"}
```

Output only the runner's one-line summary. Do not add commentary. If the user asks for details, read `~/.cache/himmel-cli/jira/normal.log` (latest entries at bottom) or run `himmel-run jira --inspect <run-id>`.
