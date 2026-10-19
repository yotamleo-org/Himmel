---
key: "HIMMEL-4862"
type: "Story"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["later","security","theme-install-adopter"]
fixVersions: []
parent: "HIMMEL-6183"
created: "2026-10-07T20:55:49.086+0200"
updated: "2026-10-18T17:09:47.512+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-3111","HIMMEL-4002","HIMMEL-5750"]
  blocked_by: ["HIMMEL-4863"]
  relates: []
---

# HIMMEL-4862: Secrets to a password vault + config UI username/password login (after the env-file split 3111/4002)

## Description

- One resolver (scripts/lib/load-dotenv.sh becomes a secrets resolver) with this order: vault, then a legacy env file with a deprecation notice for one release.
- Bootstrap, doctor row and docs: docs/setup/new-machine.md.
Today the UI is loopback-only with a per-launch token in the URL fragment (scripts/config-ui/server.ts).
- A trust-path review applies (scripts/lib/), with an opus judge before GO.
For v1.1.3 the install wizard writes secrets into today's documented 0600 stores through one interface, scripts/himmelctl/lib/secret-store.js (HIMMEL-6361, W1). The vault becomes a backend of that interface later, through this ticket, with no wizard change.
