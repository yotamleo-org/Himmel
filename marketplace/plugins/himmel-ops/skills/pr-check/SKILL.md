---
name: pr-check
description: Use in an adopted repo before opening a PR — runs himmel's CR review on the branch against origin/base.
---

# pr-check — the CR review from an adopter session (HIMMEL-7790)

`/pr-check` is a himmel project command, so a session whose cwd is an adopted
repo does not load it. This skill is the same runbook, reached through the
`HIMMEL_REPO` anchor that adopt/setup wires into settings.json `env`.

1. Read the runbook and follow it step by step, from the adopted repo's cwd:

   ```text
   Read $HIMMEL_REPO/.claude/commands/pr-check.md
   ```

   If `HIMMEL_REPO` is unset or empty, stop and report it: adopt/setup wires it, or
   export it non-empty in the launching shell.

2. Step 0 prints `anchor_lane=adopter` and `no_marker_review=yes` here: the adopted
   repo has no himmel pre-push hook, so no CR marker exists. That is the signal to
   review against `origin/<base>`, not to stop at "nothing to do". On the default
   branch step 0 still refuses (exit 4).

No arguments, ever. To review another repo, start a session whose cwd is that repo.
