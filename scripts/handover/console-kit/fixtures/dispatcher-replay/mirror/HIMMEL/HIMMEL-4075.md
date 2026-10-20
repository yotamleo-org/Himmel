---
key: "HIMMEL-4075"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["ci","cost-reduction","theme-bank-ci-cost"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-01T18:05:28.763+0200"
updated: "2026-10-19T13:15:10.603+0200"
resolution: "Done"
resolved: "2026-10-19T13:14:47.409+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-4075: [optimization] CI: bin-pack shell-unit shards by measured suite duration (slowest shard 1297s vs 753s)

## Description

- Assign suites to shards by measured duration: greedy longest-first bin packing over scripts/ci/suite-durations.tsv, instead of whatever split is used today.
PR #3177 (yotamleo/Himmel) merged @ 36f0c2d3c9d7280ddafe142e5f2a7b0f975d407d. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Merged in PR #3177 (merge commit a1fd76f3f106b7afa2c2fc81d93aaa4ee0ee39a3). The packer was correct; the committed ledger was a stale 2026-10-01 snapshot. Refreshed scripts/ci/suite-durations.tsv from the mean of three green main runs (39180908042, 39161402108, 39128734363). Replay on run 39180908042
