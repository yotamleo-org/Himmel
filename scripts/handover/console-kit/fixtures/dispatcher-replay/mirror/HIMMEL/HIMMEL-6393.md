---
key: "HIMMEL-6393"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T18:23:48.539+0200"
updated: "2026-10-19T15:27:53.105+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6353"]
---

# HIMMEL-6393: ci.yml atd start step must fail loudly, not end in || true

## Description

1. In .github/workflows/ci.yml (~line 1200) replace sudo systemctl enable --now atd || sudo service atd start || true with a start that ends in a check that atd is active.
Touches .github/workflows/ci.yml, so it needs the CI-workflow edit path and a trust-reviewed GO.
