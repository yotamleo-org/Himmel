---
key: "HIMMEL-6010"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["theme-bank-ci-cost"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-10-17T00:35:06.543+0200"
updated: "2026-10-19T06:48:47.240+0200"
resolution: "Done"
resolved: "2026-10-19T06:48:47.215+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6010: Route mechanical briefs to Haiku: CLAUDE.md subagent-policy and fanout.md wording (from HIMMEL-2660 sample)

## Description

# HIMMEL-6010: Route mechanical briefs to Haiku: CLAUDE.md subagent-policy and fanout.md wording (from HIMMEL-2660 sample)
Add one rule to the CLAUDE.md subagent policy (and its AGENTS.md mirror) and one sentence to the fanout command: a brief that is a specified edit list, sweep or scoped extraction ending in a named machine check names haiku at medium effort.
Haiku 5.5 measured about 15x cheaper than Sonnet 5.5 at equal acceptance (docs/internals/lane-calibration.md); moving the 13 saves about 70-73 % of the sample. Follow-up to HIMMEL-2660; the 13 are two campaigns, so the saving recurs only with bulk campaigns.
- CLAUDE.md "Subagent policy", after "Every dispatch names an explicit model": a brief that is a specified edit list, comment or rename sweep, fixture regeneration or scoped extraction, ending in a named machine check (gate script, test, schema validator), names haiku at medium effort, not sonnet; S
- marketplace/plugins/himmel-ops/commands/fanout.md, implementation row: a batch of file-scoped items sharing one gate is mechanical: true.
Console H 10-19: closing per HIMMEL-6440 triage (N2731) and HIMMEL-6417 audit: PR 3006 changed the 3 files asked (CLAUDE.md, AGENTS.md, fanout.md); rule is live.
