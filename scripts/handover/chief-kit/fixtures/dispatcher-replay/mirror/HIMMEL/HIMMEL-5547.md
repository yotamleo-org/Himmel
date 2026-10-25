---
key: "HIMMEL-5547"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["graphify","operator-directed","sector2-cost","spike"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6212"
created: "2026-10-13T19:06:14.878+0200"
updated: "2026-10-19T10:05:12.679+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["duplicates HIMMEL-5506"]
---

# HIMMEL-5547: Spike: codex-cli backend for graphify semantic extraction (Codex bank instead of Claude)

## Description

- Questions: (1) does upstream graphify accept a pluggable backend, or is a local wrapper needed (verify upstream, do not assume); (2) can codex exec emit the extraction JSON graphify expects (schema fidelity on 3 sample files); (3) Codex-bank cost and wall time per file vs claude-cli on the same fi
- Q1: upstream graphify 0.9.92 has no pluggable subprocess backend; custom providers are OpenAI-compatible HTTP only. A local HTTP shim around scripts/codex/dispatch-codex-exec.sh (no --output-schema in its allow-list) or a graphify patch is needed.
