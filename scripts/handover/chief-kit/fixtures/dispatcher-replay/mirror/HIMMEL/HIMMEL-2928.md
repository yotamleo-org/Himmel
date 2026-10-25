---
key: "HIMMEL-2928"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["needs-standard","theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-09-12T01:51:30.411+0200"
updated: "2026-10-19T04:37:28.123+0200"
resolution: "Done"
resolved: "2026-10-19T04:37:28.104+0200"
links:
  blocks: ["HIMMEL-3269"]
  blocked_by: []
  relates: ["relates to HIMMEL-3270"]
---

# HIMMEL-2928: leg token burn: a ~75k fixed floor is re-paid on every API call and after every ~12-min compaction; six 03O legs burned ~120M context tokens in 75 min — cut the floor (lean leg profile) and the call count (batched tool calls, no text-only turns)

## Description

1. The fixed floor is ~75k tokens before a leg does anything (first-turn context: N158 74.3k, N156 76.4k, N149 66.1k). It is the system prompt + tool/skill roster + CLAUDE.md + MEMORY.md + the SessionStart hook injections (superpowers block, where-are-we, qmd advisory, graphify staleness) + the leg
2. Cut calls (brief-level now, profile-level later): every leg brief says "batch independent tool calls into ONE turn; never a text-only turn between tool calls; narrate in the Results bullet, not in chat". Expected: 30–45 % fewer API calls on the observed mix. Add a measurement line to tick.sh or a
| method | first-turn floor | |---|---| | component sum (schemas + system prompt + CLAUDE.md chain + hooks + brief) | 74,299 | | scripts/lanes/leg-burn.sh on N158's transcript | first-turn=74.3k |
N158's full line: calls=278 avg-ctx=128.1k first-turn=74.3k out=191.2k compactions=9 text-only=2. The tool that produced it (scripts/lanes/leg-burn.sh) landed with 2830, so this is re-measurable on any leg from now on.
| component | size | can a plugin profile reach it? | |---|---|---| | tool + MCP schemas | ~40k tokens | no — graphify (11 tools) and obsidian-vault (15 tools) are user/project-level MCP servers, not plugin-provided, so enabledPlugins leaves them fully loaded | | CLAUDE.md chain (instructions) | 29,
Re-measure after the batching rule (PR 3011, merged 2026-10-17T14:52Z), 18 post-rule leg-impl legs, scripts/lanes/leg-burn.sh per transcript.
