---
key: "HIMMEL-6026"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["ci","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-17T01:38:17.788+0200"
updated: "2026-10-19T10:05:25.477+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6026: Evaluate preloop (local microVM GitHub Actions engine): security audit first, then VM POC

## Description

Operator request 2026-10-17: evaluate https://github.com/preloopdev/preloop (MIT, Rust, created 2026-06-25, about 211 stars, v0.34.0). It is a local, self-hosted GitHub Actions engine: it runs .github/workflows unchanged in microVMs (SmolVM, about 300 ms fork from a golden image), speaks the officia
