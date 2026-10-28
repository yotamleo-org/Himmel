---
allowed-tools: Bash(himmel-run:*), Bash(node:*)
description: Upload one or more files as attachments to an existing Jira issue. Returns one-line "Attached N file(s) to KEY" summary.
argument-hint: "<KEY> <path>..."
---

## Your task

```
himmel-run jira --summary-regex '^Attached \d+ file\(s\) to ([A-Z]+-\d+)' \
  -- node $CLAUDE_PROJECT_DIR/scripts/jira/dist/index.js attach "$1" "${@:2}"
```

Paths in `${@:2}` should be absolute or relative-to-cwd. Files are uploaded in order; first failure stops the batch and the CLI exits 1 with the offending file in the message.
