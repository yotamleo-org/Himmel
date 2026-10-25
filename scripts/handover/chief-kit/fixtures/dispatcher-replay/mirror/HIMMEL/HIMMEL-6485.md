---
key: "HIMMEL-6485"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T16:45:11.080+0200"
updated: "2026-10-19T16:45:11.175+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6485: Filing into the current version passes a cap gate; follow-ups are always labelled

## Description

Follow-up and side work flows into the current version with nothing stopping it: v1.1.3 has 839 counted tickets against a documented soft cap of about 40 per version (docs/glossary.md:177), and 14 of the 39 tickets created into v1.1.3 on 10-19 carry neither an operator-directed nor a residual label.
OPERATOR 10-19 16:4x: "do we protect ourselves from rabbit holes that fold into the version and they shouldn't?". Audit (console R): the cap is display-only (board.mjs:750, :811); scripts/jira/src/commands/create.ts:141-143 accepts any --fix-version, and :149-163 defaults a versionless Bug into the
Files: scripts/jira/src/commands/create.ts and tests, scripts/handover/console-kit/board.mjs, tick.sh. Leg + console briefs updated to use --follow-up-of. Related HIMMEL-6371, 6380.
