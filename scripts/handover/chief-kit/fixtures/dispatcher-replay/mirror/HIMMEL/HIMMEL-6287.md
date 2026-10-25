---
key: "HIMMEL-6287"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T02:40:06.468+0200"
updated: "2026-10-19T13:39:48.879+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6286"]
  blocked_by: ["HIMMEL-6290","HIMMEL-6359","HIMMEL-6365","HIMMEL-6384","HIMMEL-6388"]
  relates: ["relates to HIMMEL-6284"]
---

# HIMMEL-6287: Docs site on GitHub Pages: build the Starlight site with the full navigation, search and raw .md passthrough

## Description

1. Add a build job to .github/workflows/pages.yml (a CI trust path: ask the console first and say so in READY): npm ci and npm run build in site/, cached, then upload site/dist instead of raw docs/.
5. Replace the "Publishing these docs" section of docs/README.md with a pointer to the site.
Proof: the dispatch run URL with its green conclusion, and the curl status lines for the URLs above pasted in the PR. Depends on: S1 GO verdict on HIMMEL-6284; HIMMEL-6283 merged. Trust path: .github/workflows/pages.yml (check scripts/ci/ci-trust-paths.txt, needs a trust-reviewed GO). Spec section 3
- Local only. The GitHub Pages half moves to the new slice HIMMEL-6365 (DS3), which waits for this ticket, HIMMEL-6283 and the operator's OK on the local review. This slice no longer touches .github/workflows/pages.yml.
