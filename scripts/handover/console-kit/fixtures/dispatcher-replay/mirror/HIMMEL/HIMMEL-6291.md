---
key: "HIMMEL-6291"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T02:40:14.068+0200"
updated: "2026-10-19T06:53:04.725+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6284"]
---

# HIMMEL-6291: llms.txt: trim below budget, link the docs site and trail, publish it and llms-full.txt at the site root

## Description

1. Move the plugin-profile paragraph to docs/setup/install.md (already linked) and shorten the Lifecycle section, to land at or under 600 words.
4. Extend scripts/docs/check-llms-links.sh to check the built site copy's links resolve inside the build output.
- bash scripts/docs/check-llms-links.sh passes with llms.txt at or under 600 words (pasted counts).
Proof: the check-llms-links output with the word and line counts, and (for step 3) the curl loop output over the served file's links. Steps 1–2 need no site and can ship first; steps 3–4 wait for S2. Keep the existing invariants (no private names, no handovers/ paths, no links into docs/internals/).
