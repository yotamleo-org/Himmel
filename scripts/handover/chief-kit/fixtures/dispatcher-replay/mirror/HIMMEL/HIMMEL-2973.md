---
key: "HIMMEL-2973"
type: "Task"
status: "wont do"
statusCategory: "Done"
priority: "Medium"
labels: ["theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-09-12T20:23:42.985+0200"
updated: "2026-10-17T22:58:12.007+0200"
resolution: "Won't Do"
resolved: "2026-10-17T22:58:11.990+0200"
links:
  blocks: []
  blocked_by: ["HIMMEL-3279"]
  relates: ["relates to HIMMEL-3138","relates to HIMMEL-3276","relates to HIMMEL-3884","relates to HIMMEL-3974"]
---

# HIMMEL-2973: Console arm: default --autocompact 200000 (Fable consoles average 255k/turn at auto; ~40 % of console context per shift)

## Description

Seven-day transcript accounting (75,521 billed API calls, deduped by requestId) puts 71 % of the Claude bank in cache-read tokens, i.e. context length × number of calls; uncached input is 0.04 %. In the 40 most recent sessions the ten largest context users are ALL Fable consoles: peak 400–445k, aver
- /console new|next (.claude/commands/console.md) documents the default and the opt-in; docs/handover/running-a-console.md §launch line updated.
- Suite: scripts/handover/test-headed-arm.sh rows for the console path: default pin present; CONSOLE_CONTEXT=1m yields auto; refusal when neither.
- scripts/handover/headed-arm.sh: [context] now defaults to standard (--autocompact 200000) instead of 1m/auto. CONSOLE_CONTEXT=1m set in the launching shell is the sole opt-in back to --autocompact auto; a bare positional 1m without that env is refused (exit 2, actionable message) before any lock/k
- scripts/handover/console/console.sh: all four printed launch/would-launch lines mirror the resolved autocompact value (--autocompact 200000 by default).
- Docs updated: docs/handover/running-a-console.md, .claude/commands/console.md.
