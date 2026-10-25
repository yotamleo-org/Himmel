---
key: "HIMMEL-5217"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["bugs","needs-standard","theme-tracker-forge-seam","tracker","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6221"
created: "2026-10-11T12:21:32.856+0200"
updated: "2026-10-18T08:44:03.837+0200"
resolution: "Done"
resolved: "2026-10-18T08:44:03.820+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6132","relates to HIMMEL-6132"]
---

# HIMMEL-5217: tracker: rendered per-version review defects (leg chips, multi-fixVersion counts, wont-do as done, stale current version, unversioned in-flight work)

## Description

The roadmap tracker page (scripts/handover/console-kit/tracker.py) was checked as it renders, version by version, at the operator's request (2026-10-11, DA console). It was rendered with headless chromium and the embedded data was run through the page's own logic. All 961 ticket rows were compared w
