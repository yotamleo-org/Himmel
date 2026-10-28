---
allowed-tools: Bash(himmel-run:*), Bash(gh:*)
description: List open GitHub PRs. Returns count summary; full JSON in normal.log. Pass --author "@me" to filter to your authored PRs (gh's idiomatic flag — there is no --mine).
argument-hint: "[--author \"@me\"]"
---

## Your task

Run exactly:

```
himmel-run gh --summary-jq 'length | tostring + " open PR(s)"' -- gh pr list --json number,title,state,author --limit 30 $@
```

Output only the runner's one-line summary. Do not add commentary. If the user asks for details, read `normal.log` in the `himmel-run` gh log directory (see the README) or run `himmel-run gh --inspect <run-id>`.
