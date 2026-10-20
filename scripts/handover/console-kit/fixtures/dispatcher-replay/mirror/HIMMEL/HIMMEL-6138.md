---
key: "HIMMEL-6138"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Highest"
labels: ["knowledge-critical","must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T16:37:26.130+0200"
updated: "2026-10-17T23:34:19.130+0200"
resolution: "Done"
resolved: "2026-10-17T23:33:40.706+0200"
links:
  blocks: []
  blocked_by: ["HIMMEL-6139"]
  relates: ["relates to HIMMEL-6262"]
---

# HIMMEL-6138: K2: shell call resolution in the graphify harden pass

## Description

Shell call resolution: a himmel-side harden pass (scripts/graphify/harden-graph.py or a sibling, no fork needed) that resolves bash|sh|source|.|exec "$HERE|$ROOT|$SCRIPT_DIR/..." and literal scripts/...sh paths into cross-file calls / sources edges.
1. Add the resolver to the harden pass (or a sibling script); handle $HERE, $ROOT, $SCRIPT_DIR and literal scripts/...sh paths.
PR #3030 (yotamleo/Himmel) merged @ 3ff7bd8f26cfff627520ab5e56f5f71e10d49eb2. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
