<!-- Moved verbatim out of harvest-clips.md (HIMMEL-5513) so the always-loaded body stays small. Loaded on demand; the heading levels are unchanged. -->

### G-2 — Lockfile + obsidian-github-sync race guard

Before processing any clip:

1. Acquire sentinel lockfile at `<vault>/.harvest.lock` containing PID + ISO timestamp + clip-batch hash. If the lockfile exists, parse its PID:
   - **PID alive** (`kill -0 <PID>` succeeds): abort with `harvest-clips: another harvest run is active (PID=<X>); wait for it OR delete <vault>/.harvest.lock if stale.` Exit 2.
   - **PID dead** (`kill -0 <PID>` fails — the prior run was SIGKILLed, or the machine lost power, before its exit trap could run): log `harvest-clips: removing stale lock (PID=<X> not running, written <ts>)`, remove `<vault>/.harvest.lock`, and acquire a fresh lock.
   - **Unparseable / no PID** (the lockfile content doesn't yield a PID, or liveness can't be determined): treat as **alive** — fail closed. Abort with the same message as the alive case (`harvest-clips: another harvest run is active (PID=<X>); wait for it OR delete <vault>/.harvest.lock if stale.`). Exit 2.
2. **Invalidate the completion marker (HIMMEL-1137).** `rm -f "<vault>/.harvest.done" "<vault>/.harvest.done.provisional"`. Do this immediately after acquiring the lock, before any other G-2 step — a run that dies at any later point (including during the sync-state check below) must not leave an OLDER run's marker in place for downstream stages to trust.
3. Check obsidian-github-sync sync state. If `<vault>/.obsidian/plugins/obsidian-github-sync/data.json` exists, parse `lastSync` ISO timestamp. If within ±30s of now: WARN once and proceed (heuristic — Windows file-locking semantics may be unreliable; refine during calibration per replan trigger §17). If `lastSync` cannot be parsed: skip the check.
4. Clean up: register a trap to remove `<vault>/.harvest.lock` on exit (including signals).
