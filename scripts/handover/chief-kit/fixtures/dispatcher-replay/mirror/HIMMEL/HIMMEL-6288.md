---
key: "HIMMEL-6288"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T02:40:08.576+0200"
updated: "2026-10-19T06:53:01.158+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-6289"]
  relates: ["relates to HIMMEL-6284"]
---

# HIMMEL-6288: Docs accuracy sweep: remove Windows and GLM residue, fix dead links, anchors and paths, fill catalog and flag gaps

## Description

5. Fix the real doc-drift rows of scripts/lint/flag-parity-baseline.tsv and delete them from the baseline.
- bash scripts/lint/flag-parity.sh passes with the baseline shrunk by the fixed rows.
Proof: paste the link/path checker output before (the counts in the spec) and after (0), the .ps1 grep, and the flag-parity run. A checker script can be added under scripts/docs/ if it is wired into CI; otherwise run it from scratch and paste. Docs-only otherwise. Can split into two legs (Windows pu
