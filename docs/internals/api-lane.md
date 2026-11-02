# The API lane: failure alert and subscription fallback

`scripts/api-lane/claude-api.sh` runs one print-mode `claude` call billed to an
API account (`HIMMEL_API_ACCOUNT=A|B|auto`) instead of the subscription. It is
OFF unless the launching shell sets `HIMMEL_API_LANE=on`. This page covers what
happens when a call on it fails (HIMMEL-8643). The launcher's header lists the
full argument and environment contract.

## Who uses it

| Caller | Default backend | How it reaches the API lane |
|---|---|---|
| `scripts/api-lane/judge-call.sh` | API lane | always (a chief's verdict question) |
| `scripts/api-lane/bulk-call.sh` | API lane | always |
| `jira release rm-run` (release manager) | API lane | always; the prompt goes on stdin and is replayed on the fallback |
| `scripts/cr/critic-first-pass.sh` (claude critic) | the registry row's provider | provider `claude-api`; with the lane off, the refusal alerts (one per hour) and the review runs on the subscription |
| `scripts/graphify/graph-cadence.sh --semantic` | `claude-cli` | `GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api` |
| `scripts/cleanup/steering-cull-cadence.sh` | `claude-cli` | `STEERING_CULL_BACKEND=claude-api`, or `arm --backend claude-api --api-account A\|B\|auto` |

The two cadences default to the subscription (`claude-cli`) because both API
accounts can run dry; the API lane is an explicit opt-in there.

## The failure path

A failed call still fails first, exactly as before: the refusal line
(`claude-api: refused: …`, exit 2), a rejected account (exit 6, the account is
marked), or the call's own non-zero exit. A TERM, INT or HUP sent to the launcher
itself is its caller stopping it, for example `bulk-call.sh --cancel`, and sends
no alert and runs no fallback. During the call the launcher stops it, settles
and exits 143; once the call has ended it exits with its usual code, and a stop
that lands in the failure path ends that path too.
The call watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) signals only the call, so a call
it stops is a failed call and takes the path below. Then the launcher:

1. **Decides whether to fall back** (first match wins):

   | Condition | Decision |
   |---|---|
   | `HIMMEL_API_FALLBACK=off` | no fallback |
   | the request itself was refused (bad argument, run kind, cache TTL, job id or tool grant) | no fallback |
   | the call was granted `Edit`, `Write` or `Bash` and ran (it may have half-done its edits; a rejected account can answer on a later turn) | no fallback; only a refusal before any request (exit 2) falls back |
   | the native usage preflight says `PROCEED`, `BANK-STALE` or `BANK-UNKNOWN` | **runs the fallback** |
   | the preflight says `SKIPPED-BANK` or `SKIPPED-FLEET` (or nothing) | no fallback |

   The preflight is `scripts/lib/usage-preflight.sh` on the native lane, worker
   `sub-fallback:<kind>:<job>`, with every API-key variable removed.

2. **Sends one Telegram alert** through the existing notification sender
   (`scripts/telegram/session-status.ts notification`), type
   `api-lane <class>`:

   ```text
   kind judge, account auto, refused (exit 2): api lane is OFF (set HIMMEL_API_LANE=on); fallback: running on the subscription (preflight PROCEED)
   ```

   - The class is `refused`, `rejected` (exit 6) or `call-failed`.
   - The reason is one line of at most 200 characters. The key, any key the caller
     holds and anything shaped like `sk-ant-…` become `[key]`. The call's result
     text is never included.
   - At most one alert per run kind and class per hour. The stamp is written only
     after the sender exits 0, so a failed send does not mute the next failure.
     The stamp files live in `~/.himmel/state/api-lane-alerts/`.
   - The sender runs with every `ANTHROPIC_*`, `LQ_API_*` and
     `CLAUDE_CODE_OAUTH_TOKEN` variable removed. An explicitly empty
     `TELEGRAM_GROUP_CHAT_ID` suppresses it. Without a chat id or `bun`, nothing
     is sent and the fallback still runs.

3. **Runs the fallback**: the same prompt, once, as a subscription `claude -p`.
   - Same model, permission mode, tool grant, budget cap and effort, with
     `--output-format json`.
   - Native auth (`scripts/lib/native-auth-pin.sh`), every `HIMMEL_API_*` and
     `LQ_API_*` variable removed, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`. The
     launch is refused if any API-key name or the key's value is still in its
     environment.
   - A prompt on stdin is kept in a mode-600 scratch file
     (`claude-api-prompt.*` under `TMPDIR`) that the API call reads and the
     fallback replays byte for byte; the file is removed on every exit path. A
     refusal before the prompt is buffered has not read stdin, so a piped
     prompt still reaches the fallback.
   - The fallback's stdout is the launcher's stdout, and its exit code replaces
     the API exit code. A caller sees an ordinary result (judge-call records the
     verdict, bulk-call writes `OK`) when the fallback succeeds.

## The per-caller switch

`HIMMEL_API_FALLBACK` is **on by default**. A caller that must never spend
the subscription sets `HIMMEL_API_FALLBACK=off`: the failure still alerts (the
alert says `fallback: off (HIMMEL_API_FALLBACK=off)`) and the original exit code
stands. `judge-call.sh`, `bulk-call.sh` and `critic-first-pass.sh` leave it on.
The usage preflight remains the gate on the subscription bank.

## Records

The fallback appends one row to the same `launches.jsonl` as the API call:

| Field | Value |
|---|---|
| `lane` | `sub-fallback` |
| `outcome` | `sub-fallback`, or `sub-fallback-failed` on a non-zero exit |
| `cost_usd` | empty (no API credit spent) |
| `sub_cost_usd` | the subscription call's reported cost |
| `rc` | the fallback's exit code |
| `api_rc` | the original API exit code |
| `api_class` | the original failure class |
| `kind`, `job_id`, `branch`, `head`, `pr` | as on the API row |

The API call's own row and its reservation are settled as before.

## Test seams

- `HIMMEL_API_ALERT_CMD=<path>` replaces the Telegram sender. Every test that
  can reach the failure path sets a stub, so no test sends a real message.
- `HIMMEL_API_ALERT_DIR=<dir>` moves the rate-limit stamps.
- `HIMMEL_API_CLAUDE_BIN` already stubs `claude`, and the fallback runs the same binary.

## Known limits

- ponytail: two failures of the same kind and class at the same moment can both send an alert (the stamp is checked, then written after the send, up to 30 seconds later), upgrade path: an atomic `mkdir` lock if duplicate alerts show up.
- ponytail: the fallback has no watchdog of its own; it is bounded by the caller's timeout (judge-call's `--timeout`) and its budget cap, upgrade path: reuse the launcher's watchdog for the fallback.
- ponytail: a looping caller (bulk) continues item by item on the subscription after the API account is marked, one alert per hour, upgrade path: a per-run circuit breaker if the subscription draw becomes a problem.
- ponytail: fallback rows carry no API cost, so the shift-spend report does not price them, upgrade path: price `sub_cost_usd` in the subscription spend view.
- ponytail: a call stopped by the API watchdog (`HIMMEL_API_CALL_TIMEOUT_S`) counts as a failed call, so its prompt reruns on the subscription, upgrade path: skip the fallback for a timeout if reruns of long calls cost too much.
