---
key: "HIMMEL-6384"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T18:12:22.609+0200"
updated: "2026-10-18T18:13:16.195+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6382","HIMMEL-6383","HIMMEL-6287"]
  blocked_by: ["HIMMEL-6385","HIMMEL-6388"]
  relates: ["relates to HIMMEL-6372","relates to HIMMEL-6284"]
---

# HIMMEL-6384: feat(docs): static render of the development graph on a docs guide page

## Description

A static render of the development graph on a new docs guide page, docs/guide/dev-graph.html, using the shared ES module dev-graph.js and token-only CSS. No animation yet.
4. Cross-link from loops-and-graphs.html and installer-journey.html guide nav; one link line in docs/daily-loop.md.
- scripts/docs/test-site-guides.sh passes on the new page (no network, no ticket IDs in visible text, relative hrefs).
- Depends on: the graph.json slice, the daily-loop fix slice (shares docs/daily-loop.md), and HIMMEL-6287 (canonical tokens.css).
- Files: new docs/guide/dev-graph.html, docs/guide/dev-graph/{dev-graph.js,dev-graph.css,tokens.css}; edit graph.json, test-dev-graph.sh, two guide nav lines, one line of daily-loop.md.
