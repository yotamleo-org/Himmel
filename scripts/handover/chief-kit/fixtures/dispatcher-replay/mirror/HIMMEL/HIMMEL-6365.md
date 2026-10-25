---
key: "HIMMEL-6365"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T17:08:25.356+0200"
updated: "2026-10-18T20:24:49.712+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6287","HIMMEL-6283"]
  blocked_by: []
  relates: ["relates to HIMMEL-6284"]
---

# HIMMEL-6365: [docs-site] DS3: deploy the Starlight site to GitHub Pages and run J1 in CI

## Description

The docs site stays local-only until it is deployed. The public URL keeps serving raw docs/.
1. In .github/workflows/pages.yml, set up node 22, run npm ci and npm run build in site/, and upload site/dist with the existing upload-pages-artifact step. Keep the daily plus on-demand cadence from HIMMEL-6283.
- Files: .github/workflows/pages.yml only (a trust path).
Condition 3 for DS3, from DS1 (PR 3102): the Pages CI job must run npm ci in site/ and then bash scripts/docs-site/test-site-build.sh. Both DS1 tests print a SKIP line and exit 0 when site/node_modules is absent, so the hermetic shell shards never exercise the build. The build test lives under scrip
