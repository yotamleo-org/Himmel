---
key: "HIMMEL-6443"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone","theme-bank-ci-cost"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T06:56:03.456+0200"
updated: "2026-10-19T14:52:33.568+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-1907"]
  relates: []
---

# HIMMEL-6443: claudex lane: committed read-only probe chunk script so HIMMEL-1907 slice 3 can run under dontAsk

## Description

Commit a read-only chunk script (for example scripts/claudex/probe-chunk.sh <k>) that prints chunk k of the fixed 100 KB-per-chunk stream of tracked docs, scripts and *.md files. The worker must be able to run it as one literal command with no pipes, redirects or $(...), so it matches the lane's all
1. Add scripts/claudex/probe-chunk.sh (read-only, one numeric arg, no side effects) with a shell test.
- bash scripts/claudex/probe-chunk.sh 0 prints exactly 100000 bytes and its test passes.
