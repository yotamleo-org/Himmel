---
key: "HIMMEL-5497"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["lanes","operator-directed","theme-lanes-cloud","unscheduled"]
fixVersions: []
parent: "HIMMEL-563"
created: "2026-10-13T13:19:03.223+0200"
updated: "2026-10-17T22:37:28.652+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-5577","HIMMEL-5578","HIMMEL-5579","HIMMEL-5738","HIMMEL-4274"]
  blocked_by: ["HIMMEL-5455"]
  relates: []
---

# HIMMEL-5497: hermes impl lane POC: a native shepherd leg ships one real ticket implemented by hermes on codex (gpt-6.1-sol)

## Description

- Shepherd: a native sonnet leg owns one small real ticket and its PR. The implementation is done by scripts/hermes/dispatch-trusted.sh (himmel_agent profile, provider openai-codex, gpt-6.1-sol) run inside the leg's worktree. The shepherd writes the hermes brief, reviews the diff, runs impacted suit
- Measure, in the PR body and a POC note: hermes wall time, iterations, rc (126 = iteration budget truncated); shepherd Claude tokens (leg-burn line) vs a comparable native leg; codex bank delta (scripts/lanes/codex-bank-probe.ts before and after); how much the shepherd fixed by hand; CR finding cou
- Known gap: .claude/settings.json has no Bash(bash scripts/hermes/dispatch-trusted.sh:*) allow rule (the script header says the operator adds it once). A refused call goes to the console; the leg never routes around it.
