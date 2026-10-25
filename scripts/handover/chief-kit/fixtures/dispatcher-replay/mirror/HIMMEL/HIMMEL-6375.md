---
key: "HIMMEL-6375"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["ci","security","standalone"]
fixVersions: []
parent: null
created: "2026-10-18T18:05:09.510+0200"
updated: "2026-10-18T18:05:09.616+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6375: lint-corpus-sandbox fails closed on any unwrapped hook reference (source, direct exec, other interpreters)

## Description

scripts/ci/lint-corpus-sandbox.py misses several hook launch shapes: direct "$HOOK" exec, . "$HOOK" / source "$HOOK", exec "$HOOK", "${HOOKS[0]}", launches split across a \ line continuation, and dash/zsh/python3 interpreters. A corpus suite using one of these runs its hook outside the sandbox and p
Files: scripts/ci/lint-corpus-sandbox.py (trust path: an opus trust judge before GO), scripts/ci/test-corpus-sandbox.sh. Evidence: verdicts/jG3097 in the himmel handover bucket. Residual of HIMMEL-4979.
