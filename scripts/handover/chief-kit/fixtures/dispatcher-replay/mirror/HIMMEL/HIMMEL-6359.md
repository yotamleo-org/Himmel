---
key: "HIMMEL-6359"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6205"
created: "2026-10-18T17:08:08.226+0200"
updated: "2026-10-18T18:13:11.692+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6287"]
  blocked_by: ["HIMMEL-6360","HIMMEL-6386"]
  relates: ["relates to HIMMEL-6284"]
---

# HIMMEL-6359: [docs-site] UI1: himmel UI adopts the docs-site tokens and gains a Docs rail link

## Description

The config console (scripts/config-ui) adopts the docs site's design tokens and gains a Docs link in its rail.
1. Copy site/src/styles/tokens.css (created by HIMMEL-6287) byte for byte to scripts/config-ui/public/tokens.css. Re-point theme.css's --bg --panel --line --fg --dim --accent --ok --warn --fail --off at the shared tokens. Use system-ui and ui-monospace; drop IBM Plex.
3. Add scripts/config-ui/tests/tokens-sync.test.ts, which fails when the two token files differ.
- e2e journey J2 (plan section 4.3) passes in scripts/config-ui/tests/e2e/.
- The operator reviews the UI locally with node scripts/himmelctl/bin.js ui.
- Files: scripts/config-ui/public/{tokens.css,theme.css,nav.js}, scripts/config-ui/tests/tokens-sync.test.ts, one J2 spec under tests/e2e/.
