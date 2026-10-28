---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Transition a Jira issue to a new status. Resolves transition ID from metadata cache.
argument-hint: "<KEY> <status-name>"
---

## Your task

```
TID=$(node $CLAUDE_PROJECT_DIR/plugins/himmel-jira/lib/transition-resolver.mjs --key "$1" --status "$2")
himmel-run jira --summary-regex '^Transitioned ' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js transition "$1" "$TID"
```
