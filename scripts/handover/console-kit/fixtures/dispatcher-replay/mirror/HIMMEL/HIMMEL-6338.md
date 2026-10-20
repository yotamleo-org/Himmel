---
key: "HIMMEL-6338"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["residual-depth-1","security","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T08:30:56.850+0200"
updated: "2026-10-18T13:14:42.442+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6015","relates to HIMMEL-6337"]
---

# HIMMEL-6338: block-tail-pipe-on-gates withdraws on any unquoted heredoc, so a gate pipe in a heredoc-bearing command is never checked

## Description

scripts/hooks/block-tail-pipe-on-gates.sh:1139 (case $normalised in *"$HEREDOC_MARK"*) exit 0 ;; esac) withdraws the whole hook when it sees an unquoted <<. That withdrawal is deliberate: heredoc bodies in this repo often document the very shape the guard denies, and a flat scanner cannot tell body
