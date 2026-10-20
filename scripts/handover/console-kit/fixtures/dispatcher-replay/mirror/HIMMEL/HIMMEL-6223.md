---
key: "HIMMEL-6223"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["ps3-intake"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6218"
created: "2026-10-17T18:03:00.728+0200"
updated: "2026-10-18T01:44:09.102+0200"
resolution: "Done"
resolved: "2026-10-18T01:43:49.067+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6223: jira create refuses a ticket without a Sector and an epic or standalone marker

## Description

1. Add a Sector and epic-or-standalone check beside plainBlockVerdict in scripts/jira/src, shared by the CLI and the MCP create, with Epic and Subtask warn-only.
4. Document the rule in scripts/jira/CLAUDE.md and in the ticket-standard skill, and update the create callers that file tickets (briefs, homing pass).
- A vitest case for each of the four outcomes passes, and npm run test in scripts/jira is green.
Files: scripts/jira/src/plain-block.ts, scripts/jira/src/commands/create.ts, the MCP create tool, plain-block.test.ts. Suite: npm run test in scripts/jira (rebuild dist with npm run build). Parent: set to the PL-STD epic in phase 2 of the apply list.
PR #3025 (yotamleo/Himmel) merged @ 2f8a52100a145ac1cea02ddf4b525f19ca07dec0. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
- scripts/doctor-cadence.sh assumes the Visibility Sector exists in Jira.
