# The go-code launch route for billed and bypass flags

`scripts/station-ops/bypass-launchd.sh` launches a worker with an allowlisted
`HIMMEL_*_OK` flag only after the operator replies with a one-time code on
Telegram. With the operator away from the station, this is the only way a
session can get `HIMMEL_BILLED_OK=1` (a paid eval) or
`HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1` (a leg that edits `scripts/hooks/`).

## Why a session cannot set the flag itself

- **The auto-mode classifier refuses it.** Since 2026-11-12 the classifier
  denies `HIMMEL_BILLED_OK=1` as `[Safety Bypass Flag]`, both as a per-call
  prefix and inside a launch script a chief runs. Chiefs ran the same shapes
  on 11-03 and 11-04 without a denial, and the denials ledger has no
  `HIMMEL_BILLED_OK` row before 11-12. The billing gate in `run.sh` is older
  (2026-10-24). What changed is the classifier. Any env flag that
  turns a guard off looks like self-escalation to the classifier, so a
  session cannot set it, whatever the brief says.
- **afk-sudo cannot carry it.** The root floor (`never_remote.py`, rule
  `guards-off`) refuses any `HIMMEL_*_OK=1` request, and afk-sudo runs as root
  with cwd `/`, which is the wrong context for a worker launch.

So the flag has to come from a process the operator started outside any
session, and it is set only on the operator's own reply.

## What it replaces

Earlier, the chief ran the critic-eval sweep itself
(`HIMMEL_BILLED_OK=1 bash scripts/eval/review-panel/run.sh ...`), or exported
the flag in a worker's launch script. Both shapes are now refused. Instead:

1. The chief writes the sweep worker's brief in the handover bucket.
2. The chief writes a request into `<bucket>/bypass-queue/<name>.req`:

   ```text
   brief=<absolute brief path, directly in the bucket>
   model=claude-sonnet-5-5
   chief=<chief session name>
   flags=HIMMEL_BILLED_OK
   effort=high
   decision=<operator decision number>
   ```

3. The daemon sends the operator an ask on Telegram. It names every flag, the
   decision (`PAID RUN (decision N)`), the brief's description and sha, and a
   one-time code.
4. The operator replies `go <code>` and the daemon launches the worker with
   `headed-arm-worker.sh`. A reply of `no <code>` launches nothing, and so do
   6 h with no reply.

For a critic change, the paid eval is the default route
(`scripts/eval/review-panel/README.md`, "The merge gate"). The chief launches
the sweep without asking whether to spend. The go code authorises the flag for
that one launch; it is not a decision about whether to run the eval. Only
skipping the eval needs an operator decision, as a `gate-bypass.tsv` row.

## What the daemon guarantees

- **Only an allowlisted flag, only on a go.** `flags=` may name only
  `HIMMEL_HOOK_INTEGRITY_BYPASS_OK` and `HIMMEL_BILLED_OK`; any other flag
  refuses the request. A billed request without a numeric `decision=` is
  refused before any ask.
- **Only the operator's reply counts.** The go must come from the operator's
  own chat (`from` and `chat_id` both equal `allowFrom[0]` of the bridge's
  `access.json`) and must not be forwarded.
- **The approval is bound to what was asked.** After the go, the daemon
  launches only if the brief still has the sha the ask named. It appends
  `granted_at=`, `go=` and `sha=` to the request, which ends as `.done`, and
  writes `GRANT <brief> env=<flags> decision=<n> go=<code>` to `daemon.log`.
- **Nothing inherited leaks through.** The launch clears every `*_OK` variable
  in the daemon's environment, and any inherited effort, then sets only the
  granted flags. A station opt-in such as `HIMMEL_DEEPSEEK_INFERENCE_OK`
  therefore does not reach a worker launched this way.
- **Failures are reported.** A launcher that exits non-zero within the settle
  window logs `LAUNCH-FAILED <brief> rc=<n>`, and the request ends `.failed`.
- **It is bounded.** `--until <YYYY-MM-DD>` is required and may be at most 7
  days ahead. `<bucket>/bypass-queue/stop` stops the daemon. It refuses to
  start inside a Claude session (`CLAUDECODE` set) and holds one instance per
  queue (`flock`).

## Starting and stopping it

The operator starts it from their own shell, never from a session:

```bash
setsid nohup bash <repo>/scripts/station-ops/bypass-launchd.sh --bucket <bucket> --until <YYYY-MM-DD> >/dev/null 2>&1 &
```

To replace a running instance, `touch <bucket>/bypass-queue/stop`, wait for
`stop file` in `daemon.log`, remove the stop file, then start it again. bash
holds the loop it parsed, so editing the script does not change a running
instance.

## Limits

A process running as the operator's user can append a forged `go <code>` line
to the bridge's `inbound.jsonl` if it can read the code from the bridge's
outgoing queue. The per-request code, the own-chat check, the fixed launch
shape, the flag and model allowlists and the 7-day bound limit the damage.
They do not prevent it. The same user can also swap or edit the brief after
the post-go sha check, before the launcher and the worker read it, so the
worker runs instructions the operator never saw, with the granted flag; the
fix is a launch from a root-held snapshot of the approved brief. Closing both
needs a root-owned station op that afk-sudo approves.

Tests: `scripts/station-ops/test-bypass-launchd.sh` runs the daemon with a
stub sender and a stub launcher on a temp bucket.
