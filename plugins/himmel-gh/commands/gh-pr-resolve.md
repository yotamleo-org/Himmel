---
allowed-tools: Bash(himmel-run:*), Bash(node:*), Bash(gh:*)
description: Resolve a PR review thread by 6-char prefix, posting the reason as a reply first. Run /gh-pr-comments first.
argument-hint: "<thread-prefix> \"<reason>\""
---

## Your task

Resolve repo context:

```
eval "$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/repo-context-cli.mjs)"
```

The prefix cache is keyed by `(owner, repo, PR-N)`. If the current session has not seen the PR number for this prefix, ask via AskUserQuestion; store in `$pr_n`.

Then resolve. The CLI expands the prefix to a thread id and routes the mutate
through the active forge (GitHub GraphQL or, for a `bitbucket.org` repo, the
`bitbucket pr resolve` REST verb — spec §5.3):

```
himmel-run gh --summary-regex 'resolved: ok' -- node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/thread-resolve-action-cli.mjs --owner "$owner" --repo "$name" --number "$pr_n" --prefix "$1" --reason "$2"
```

`$2` is the reason, quoted as one argument: `"fixed <sha>"`, `"followup <KEY-n>"`
or `"rejected <why>"`; an unquoted reason arrives as its first word and is refused.
The CLI refuses without one, posts it as a thread reply, and resolves only
after the reply lands.

Output only the runner's one-line summary. If the prefix resolver fails, surface stderr and suggest re-running `/gh-pr-comments <N>` to refresh the cache.
