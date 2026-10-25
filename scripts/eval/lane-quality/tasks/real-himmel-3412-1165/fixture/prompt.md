# fleet.mjs follow-ups: finished bg pid fallback, partial sweep on timeout, launch-log prefix read

Context
Follow-ups from the /pr-check panel round 2 on the HIMMEL-3404 PR (fleet.mjs, a local status UI for headed and headless legs). Each is real but low impact, and the brief allowed only a Critical after one fix round, so they were deferred rather than fixed in that PR.
Items (all in scripts/handover/console-kit/fleet.mjs)
1. Pid fallback still uses a finished background row. The pid selection ends with || agPid, which also applies to a finished bg row, contradicting the comment above it (a finished row's pid may be stale or reused). A reused pid can make a completed leg look alive and raise a false attention flag. Fix: take agPid only when !agBg || agRun.
3. Launch logs are read only for their first 8192 bytes. A pid or session-log path appended after that prefix is never seen, so a reused or growing launch log can leave the row on an obsolete process. Fix: read the tail, or state the supported log format in the header comment and the docs.
Acceptance

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/handover/console-kit/test-fleet.sh`

The checks it must pass include:

- `scripts/handover/console-kit/test-fleet.sh`: snapshot is valid JSON with 12 leg rows (9 listed + 3 unlisted held)
- `scripts/handover/console-kit/test-fleet.sh`: HIMMEL-3412(a): a finished bg row's stale/reused pid does not resurrect the leg
- `scripts/handover/console-kit/test-fleet.sh`: HIMMEL-3412(c): a launch-log pid= past byte 8192 is still read from the tail
- `scripts/handover/console-kit/test-fleet.sh`: HIMMEL-3412(c): that tail-read pid makes the leg alive
- `scripts/handover/console-kit/test-fleet.sh`: dead bank + gh: still renders every row
- `scripts/handover/console-kit/test-fleet.sh`: absent launch-log dir tolerated

Run the tests you touch before you finish. Report what you changed and what you checked.
