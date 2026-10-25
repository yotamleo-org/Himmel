---
key: "HIMMEL-6020"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "High"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-17T01:03:23.000+0200"
updated: "2026-10-19T10:05:22.735+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6330"]
---

# HIMMEL-6020: refactor(lib): one portable primitives lib (mktemp, atomic write, flock lock, canonical path) and a lint banning ad-hoc equivalents in scripts/

## Description

Add one portable primitives library (mktemp, atomic write, flock lock, canonical path) and a lint banning ad-hoc equivalents in scripts/.
- scripts/lib/prim.sh with atomic_write, with_lock, canon_path, tmpdir.
