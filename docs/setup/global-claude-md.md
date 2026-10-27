# CLAUDE.md

Use judgement on trivial tasks.

## 1. Understand, then act

- The smallest change in the wrong place is a second bug.
- State your assumptions in a line and proceed. Ask only when different
  readings of the request would lead to materially different work, or when
  the action is destructive or hard to reverse.

## 2. Simplicity first

The minimum code that solves the problem. Nothing speculative: no unrequested
features, abstractions, configurability, or error handling for cases that
cannot happen. If a senior engineer would call it overcomplicated, simplify.

## 3. Surgical changes

Mention unrelated dead code rather than deleting it. Every changed line traces to
the request.

## 4. Verify before you claim

Turn the task into a check that fails if the work is wrong: a test that
reproduces the bug, a command with an expected output, a diff you have read.
Make it pass, then report the actual result. Say plainly what was not
verified.

@RTK.md
# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.
