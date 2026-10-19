---
key: "HIMMEL-5780"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: []
parent: "HIMMEL-6217"
created: "2026-10-15T16:35:39.306+0200"
updated: "2026-10-17T18:40:56.693+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5780: comment-sicko pass: apply poteto's comment keep list directory by directory (after HIMMEL-5629 and HIMMEL-5779)

## Description

Run a comment-sicko pass over the repo, one directory per PR, applying poteto's keep list (docs/internals/ponytail-convention.md, line 91 onward): keep only a non-obvious present-tense WHY, ponytail: lines, and data; delete the rest.
