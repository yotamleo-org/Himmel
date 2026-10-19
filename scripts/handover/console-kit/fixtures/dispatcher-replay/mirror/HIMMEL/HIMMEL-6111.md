---
key: "HIMMEL-6111"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "High"
labels: ["console-kit","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-3744"
created: "2026-10-17T14:55:27.603+0200"
updated: "2026-10-17T18:44:38.342+0200"
resolution: "Done"
resolved: "2026-10-17T18:37:53.167+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6111: Dispatch gate: gen-briefs and next-dispatchable refuse Windows/WSL tickets unless labelled windows-removal

## Description

1. scripts/handover/console-kit/gen-briefs.py: a leg whose title, desc, why or scope matches the platform pattern (case-insensitive: windows, wsl, powershell, pwsh, \.ps1, git bash, git-bash, msys, mingw, win32, cmd\.exe) is refused (exit 1, nothing written) unless the leg sets "platform_removal": t
2. scripts/handover/console-kit/next-dispatchable.sh: drop candidates whose summary matches the same pattern unless the ticket has label windows-removal; print one # skipped N windows/wsl ticket(s) line.
3. Keep the pattern in ONE shared file (e.g. scripts/handover/console-kit/platform-dropped.re) read by both.
4. Document the gate in docs/handover/console-sections/ where dispatch is described (one line).
Files: scripts/handover/console-kit/gen-briefs.py, scripts/handover/console-kit/test-gen-briefs.sh, scripts/handover/console-kit/next-dispatchable.sh, scripts/handover/console-kit/test-next-dispatchable.sh, the new shared pattern file, one docs line. Not hooks, not CI. Existing Windows-removal ticke
PR #2998 (yotamleo/Himmel) merged @ d2701e4577cee636eabb364621b940af1a25fc89. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
