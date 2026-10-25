---
key: "HIMMEL-6139"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Highest"
labels: ["knowledge-critical","must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T16:37:27.998+0200"
updated: "2026-10-18T10:17:53.024+0200"
resolution: "Done"
resolved: "2026-10-18T10:17:31.763+0200"
links:
  blocks: ["HIMMEL-6138"]
  blocked_by: []
  relates: []
---

# HIMMEL-6139: K3: cross-file identity so graphify path works

## Description

Node IDs are file-scoped, so the same entity in different files (a doc concept, a code symbol, a glossary term) is not one node. Traversal across files is broken, which is why CLAUDE.md says to never use graphify path.
4. When they pass, remove the "never graphify path" rule from CLAUDE.md.
- The CLAUDE.md "never graphify path" rule is removed in the same PR once the pairs pass.
PR #3063 (yotamleo/Himmel) merged @ 6379f9b8237e59aa0e8baf502fde61d7d2bbe32c. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Merged in PR #3063 as squash commit 3c84c2463ea2f520573a331576bce9f831f05277 (head 6379f9b8). The harden pass now gives one canonical cross-file node identity: code files, name() symbols, glossary terms and /command/plugin/skill/hook names merge. On the live graph that gives identity-merged=62 and i
