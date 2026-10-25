---
key: "HIMMEL-6127"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Highest"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6160"
created: "2026-10-17T16:21:03.093+0200"
updated: "2026-10-19T11:45:04.281+0200"
resolution: "Done"
resolved: "2026-10-19T11:45:04.261+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6127: himmel-bus: succession leaves the new console with no edges to its legs, and a message never wakes an idle leg

## Description

Files: marketplace/plugins/himmel-bus (bin/bus, lib/edges.mjs, lib/identity.mjs), docs/handover/leg-sections/succession.md, scripts/handover/console/console.sh, the leg launcher, tick.sh. Related: HIMMEL-5966 (succession as a script).
2. bash scripts/handover/console-kit/inbox-send.sh <session> 'bus waker live proof: reply with one LIVE bullet'
3. bash scripts/handover/bus-idle-waker.sh --name <session> --service org.kde.konsole-<pid> --session /Sessions/1 --poll 2 --grace 20 --rewake 120 --max-polls 40
Scratch-proof waker call (konsole 1045288 closed afterwards): bash scripts/handover/bus-idle-waker.sh --name <scratch> --service org.kde.konsole-1045288 --session /Sessions/1 --poll 2 --grace 5 --rewake 120 --max-polls 20
   ``    bash scripts/handover/bus-idle-waker.sh --name <leg-name> --service <konsole service> --session /Sessions/<n> --max-polls 30    `    - **Expected (idle input box):** one wake line, and the leg reads the ping.    - **Expected (wrong <leg-name>`):** rc=4 and no keystroke.
- node marketplace/plugins/himmel-bus/bin/bus status HIMMEL-nextleg-2026-10-19M-roadmap-console printed live, rc=0.
