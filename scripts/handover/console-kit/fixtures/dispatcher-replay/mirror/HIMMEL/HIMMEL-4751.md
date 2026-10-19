---
key: "HIMMEL-4751"
type: "Story"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-gated","sector2-fleet"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-07T08:38:28.189+0200"
updated: "2026-10-18T16:41:51.734+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-4751: AG-UI fleet view: show each session's place in the agent graph (console, legs, judges, subagents, cloud+shepherd) and its context window + token usage

## Description

2. Context window and token usage per session, where they can be measured: current context fill (the scripts/context-fill.sh method), the autocompact ceiling it runs under (200k leg or 1m console), cumulative input, output and cache tokens, and cost-eq (the cache_read ×0.1 method from HIMMEL-2763) f
