---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Add a comment to a Jira issue. Returns one-line "comment added" summary. Supports --attach <path> (repeatable, attaches to the parent issue — Jira attachments are issue-scoped, not comment-scoped).
argument-hint: "<KEY> \"<body>\" [--attach path]..."
---

## Your task

```
himmel-run jira --summary-regex '(comment added|OK)' -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js comment "$1" "$2" "${@:3}"
```

Pass `--attach <path>` (repeatable) through after `$2`. Attachments land on the parent issue `$1`.
