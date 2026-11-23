# Telegram bridge

An always-on remote Telegram bridge for Claude Code. An immortal bun
poller owns the single Telegram poll slot (`getUpdates`) and delivers each
inbound message by spawning a **bounded one-turn cold `claude` run** per logical
session — interactive `claude "<prompt>"` with stdin closed (EOF), so the child
does one turn, replies, and exits (Max quota, no `-p`). A file bus carries
per-session inbox / outbox / context so work survives across runs, caps, and
crashes.

> [!important] Armed/overnight relaunches do NOT use `--channels`.
> Telegram reachability comes from the always-on bun bridge, **not** from a
> `claude` session holding `--channels`. A `--channels` Telegram relaunch
> alongside the live bridge is a 2nd `getUpdates` consumer (→ 409 Conflict)
> AND its `--dangerously-load-development-channels` prompt hangs an unattended
> launch ([§ WS-C](#ws-c--why-no---channels-dev-channels-spike-result)). So the
> anti-lockout default is a **PLAIN relaunch** — keep the bun bridge up, drop
> `--channels`. `scripts/handover/arm-resume.sh` enforces this: it **refuses**
> `--channels` (rc=5) while the bridge is live (`ARM_CHANNELS_OK=1` overrides,
> after `bun supervisor.ts --kill`).

## Cold-spawn-per-message delivery

Each inbound message is handled by a **bounded one-turn cold `claude` run**, not
a long-lived warm child. `makeRunFn` (in `poller.ts`) `peekPending`s the durable
inbox slice, spawns `runSession(buildPrompt(...))` — interactive `claude` with
stdin closed → EOF → one turn → reply appended to `outbox.jsonl` → exit — and
commits the consumed cursor **only on a clean (non-capped) run**; `buildPrompt`
passes `context.md` so a cold reply still carries prior-turn continuity. After a
clean run it drains by re-running until `peekPending` returns 0.

> [!note] Why cold, not warm.
> An earlier design tried a **persistent warm child** with a piped stdin, writing one
> line per turn. That never drove a turn: interactive `claude "<prompt>"`
> processes + replies only at **EOF**, never on a newline written to a
> still-open stdin pipe — so the warm child consumed the inbox line, stayed
> alive, and replied to nobody (the "bot is deaf" bug). Cold-spawn closes stdin,
> which is what makes the one turn fire. `inbox.jsonl` stays the durable queue;
> a cap/rate-limit on a run's output marks the session `capped` + `retry_at`
> (now + `TELEGRAM_RETRY_MS`, default 15m) and leaves the message uncommitted so
> it redelivers at retry.

### Reply flush timer (T4)
A cold run is a separate process that appends its reply to `outbox.jsonl` as it
works, so the poller flushes outboxes on its **own ~1s timer**
(`TELEGRAM_FLUSH_MS`) running **concurrently** with the 30s `getUpdates`
long-poll, behind a re-entrancy guard (`guarded`) that drops a tick while a
prior flush is still in flight. A reply reaches the operator within ~1s instead
of up to 30s. The flush path touches only the outbox files; the run path touches
only inbox/meta/pending — disjoint, so the concurrent timer adds no shared-file
race.

### Inter-session IPC (T6 messaging)
`bun bus.ts send <target> <text>` calls `sendToSession`, which `ensureSession`s
the target and appends the message to its durable `inbox.jsonl`. The poller's
per-tick `deliverAllPending` scan runs pending lines for **every** session
(spawning a bounded run), skipping a `capped` session until `retry_at`
passes. **Boundary (followup):** a target that has *never* been created via
Telegram has no `meta.json`, so `deliverAllPending` defers it — an IPC message
to a brand-new target queues durably but is not delivered until that session is
first created (and reply routing needs a `chat_id`, which only a
Telegram-created session has). A→B between two already-live sessions works.

### Atomic cursor writes
Every committed cursor (inbound, per-session outbox, inbox `.consumed`, and the
`inbox.pending.jsonl` scratch) is written via `atomicWrite` (tmp+rename) so a
crash mid-write can't leave a torn byte-offset. (`meta.json` / `offset` /
`context.md` were already atomic.)

## Hardening

Non-blocking minor items from the PR #222 heavy automated review:

- **Malformed `getUpdates` tolerance.** `getUpdates` returns `j.result ?? []`,
  so an `ok:true` response that omits `result` yields an empty batch instead of
  throwing into the poll loop's catch.
- **Append-log truncation (`truncateFullyConsumed`).** `flushOutboxes` and the
  run loop read each session's whole outbox/inbox into memory every tick;
  on a very long-lived session those logs would grow without bound. When a
  log's byte-cursor reaches EOF (every line sent/consumed) the file and its
  cursor are reset to 0. Truncation fires **only at the fully-consumed point**
  and re-reads the file length immediately before the reset, so it never drops
  unsent/unconsumed bytes. A residual sub-millisecond race remains for the
  outbox (a bounded run is a separate process and could append between the final
  length read and the rename) — bounded to one flush interval of output and
  consistent with the bridge's existing at-least-once / operator-resends model.
- **Capped session is not a stall.** A `capped` session with new inbound stays
  **queued** (uncommitted) until its `retry_at` passes — `deliverAllPending`
  skips it by design. A queued-but-not-delivering capped session is expected
  back-pressure, not a hang; it resumes automatically at retry.
- **I2 — at-least-once mid-batch dup window.** Inbound is durably appended
  *before* the Telegram offset advances (append-then-confirm), so a crash
  between the append and the offset write can re-append the same update on
  restart. `ingestUpdates` dedups by `update_id` (skips any `update_id <
  offset`), so the dup window is collapsed at ingest and never reaches a session.
- **`supervisor --kill` is a real lever.** The supervisor writes a
  `supervisor.pid` file (its own pid + the current poller child pid) under the
  bridge root. `bun supervisor.ts --kill` reads it and stops the supervisor
  first (so it can't respawn the poller) then the poller, and removes the file.
- **Registry changes need no restart.** Every
  dispatch resolves the `telegram` plugin profile (`--settings` and
  `--mcp-config`) through `loadPluginProfilesModule`, which re-imports
  `scripts/lanes/plugin-profiles.mjs` and its lazy local graph from a fresh copy
  whenever one of those files' mtimes changes. A merge that changes the registry
  and its validator together is picked up on the next dispatch.
- **Repeated identical dispatch failure alerts once.** A run that
  throws before the worker spawns leaves the message pending, so the session is
  re-dispatched and fails again on every tick. After
  `DISPATCH_FAIL_ALERT_AFTER` (5) identical failures in a row for one session,
  the operator's DM gets one `⚠️ bridge: every dispatch for <session> has
  failed …` message with the error. It does not repeat for that streak; a clean
  run or a different error starts a new one. With no operator chat configured it
  is a log line only.

## WS-C — why no `--channels` (dev-channels spike result)

Loading a local-marketplace channel (`plugin:telegram-himmel@himmel`)
requires `--dangerously-load-development-channels`, whose "I am using this
for local development" prompt **does NOT persist**. Verified empirically:
it re-prompts on every launch, and nothing is written to `~/.claude.json`,
settings, or any other file to record the acknowledgement. This is
confirmed by the claude-code guide — there is no settings key, env var, or
flag to suppress it, because forked plugins never reach Anthropic's
approved-channels allowlist. An unattended relaunch would therefore hang
forever waiting on that prompt.

The bridge avoids `--channels` entirely: a standalone bun poller receives
inbound via the Telegram Bot API, and the bridge sessions are plain
interactive runs (no dev-channel load, no prompt to hang on).

## Components

- **poller** (`scripts/telegram/poller.ts`) — the only daemon and driver.
  Owns the single `getUpdates` slot, gates inbound against `access.json`,
  writes durable inbound (append-then-confirm: append to `inbound.jsonl` +
  fsync, then advance the offset), routes each message with pure code, spawns
  bounded runs, and flushes outboxes back to Telegram.
- **supervisor** (`scripts/telegram/supervisor.ts`) — keeps the poller alive
  (restart-on-exit + backoff + a circuit-breaker on repeated immediate
  crashes). No claude session to manage.
- **bus** (`scripts/telegram/bus.ts`) — the file substrate under
  `~/.claude/handover/bridge/`: `inbound.jsonl`, `offset`, and
  `sessions/<S>/{inbox,outbox,context,meta}`. Single-writer-per-file
  (meta = poller only; outbox = run only; inbox = poller only;
  context = run only); readers use a sibling byte-cursor (`atomicWrite`) and
  parse only complete `\n`-terminated lines. Also `sendToSession` + the
  `bun bus.ts send` IPC CLI.
- **bounded run** (`scripts/telegram/run.ts`) — the delivery primitive:
  `runSession` spawns interactive `claude "<prompt>" </dev/null` (Max quota,
  stdin closed → one turn → reply → exit) + `detectCap`. `poller.ts`'s
  `makeRunFn` wires it per session (peek → run → commit-on-clean).
- **onboard** (`scripts/telegram/onboard.ts`) — a dedicated, bounded entry
  point (`bun scripts/telegram/onboard.ts`, ~5min default timeout,
  `--timeout`/`ONBOARD_TIMEOUT_SEC` to override) that helps an adopter
  discover the `chat.id`/`chat.type`/`from.id` values to hand-author into
  `access.json`. Deliberately not a poller flag: it refuses to start while
  the bridge is armed (a live pidfile pid, a detected `supervisor.ts`/
  `poller.ts` process, or the token-scoped launcher lock present) rather than
  becoming a second `getUpdates` consumer. It prints a one-time nonce, waits
  for a matching message, and reports the ids it arrived on — it never
  writes `access.json` itself.

Fast-resume is an independent capability for recovering a closed
session's stop-point: `scripts/telegram/armed-session-track.ts` +
`/handover-resume-armed`.

## Message classes

Every message the harness sends to Telegram carries a kind, and `scripts/telegram/message-classes.json` gives each kind one class. **escalate** goes to the operator chat: it needs the operator and no agent can do it, and it is a short brief (what is wrong, what it blocks, the one thing to do). **monitor** goes to the monitoring chat: routine and live monitoring. **silent** sends nothing: the chief or a script handles it. An unset or failing monitoring chat never drops an escalation, and a kind with no row still escalates, so losing a real escalation is never the failure direction. The table is generated from the json and `scripts/telegram/test-message-classes.sh` fails when a kind has no row here, or a row carries a different class.

| Kind | Class | Sender | What it says |
|---|---|---|---|
| `merge-blocked` | escalate | `scripts/lib/merge-block-alert.sh` | Merge refused: PR 4882 in octo/demo. Blocks: the merge after GO. Do: ask a reviewer for the one approval GitHub still wants |
| `token-in-output` | escalate | `scripts/hooks/detect-token-in-output.sh` | A credential leaked: a GitHub token appeared in session 81843b5d. Blocks: nothing yet, it is in the transcript. Do: rotate the GitHub token |
| `config-audit` | escalate | `scripts/lib/config-audit.sh` | A session changed .env: JIRA_API_TOKEN. Blocks: nothing. Do: check it was you, else restore the file from its backup |
| `hold-ask-operator` | escalate | `scripts/handover/chief-kit/chief-wait.sh` | A worker on a ticket needs a settings or CI file: .github/workflows/ci.yml. Blocks: that worker. Do: in a real terminal, run: bash scripts/handover/chief-kit/go.sh grant the-ticket |
| `hold-ask-stuck` | escalate | `scripts/handover/chief-kit/chief-wait.sh` | A file ask waited 30 min: a worker wants .github/workflows/ci.yml, held by another ticket. Blocks: that worker. Do: in a real terminal, run: bash scripts/handover/chief-kit/go.sh grant the-ticket |
| `denial-stuck` | escalate | `scripts/handover/chief-kit/chief-wait.sh` | A worker N4992b has been parked 30 min by a classifier denial (PAUSE-RISK). Blocks: its ticket. Do: open the session in Remote Control, or run ack-denial.sh with the label |
| `monitor-chat-down` | escalate | `scripts/telegram/poller.ts` | The monitoring group is getting no messages (unset); 3 are kept on the station. Blocks: routine monitoring only. Do: check the two monitoring lines in the bridge env file and that the monitoring bot is in its group, then restart the bridge |
| `recover-failed` | escalate | `scripts/station-ops/recover.sh` | Reboot recovery failed: the bridge did not come back. Blocks: every Telegram message. Do: run systemctl --user restart telegram-bridge.service |
| `bypass-ask` | escalate | `scripts/station-ops/bypass-launchd.sh` | A chief asked to launch a worker with a bypass: it wants settings access for one ticket. Blocks: that launch. Do: reply go 4821 to launch it, or no 4821 to refuse; the ask expires in 6 h |
| `bypass-failed` | escalate | `scripts/station-ops/bypass-launchd.sh` | A bypass launch you approved failed (rc 1): the worker did not start. Blocks: that worker. Do: read the launch log in the bypass queue, then ask the chief to relaunch it |
| `chief-reply` | escalate | `docs/handover/running-a-chief.md` | A chief's reply to the operator, sent through chief-route.ts; ticket keys and PR numbers carry their plain words; a key whose title cannot be read stays bare (see title-unresolved). |
| `hold-ask-chief` | silent | `scripts/handover/chief-kit/chief-wait.sh` | A worker wants scripts/cr/critic-panel.sh, held by another ticket. Blocks: that worker. Do: in a real terminal, run: bash scripts/handover/chief-kit/go.sh grant the-ticket |
| `denial-page` | monitor | `scripts/handover/chief-kit/chief-wait.sh` | Session 81843b5d of the himmel chief has 3 classifier denials (PAUSE-RISK). Blocks: that session. Do: open it in Remote Control and answer the prompt |
| `title-unresolved` | monitor | `scripts/telegram/chief-route.ts` | A line sent through chief-route.ts named a ticket key whose title could not be read on the station. The line keeps the bare key. One report per line names such keys, ten at most, and counts the rest. A report that names a salus key goes to the operator chat instead. |
| `worker-silent` | silent | `scripts/handover/chief-kit/chief-wait.sh` | A worker went silent; the chief handles it, so nothing is sent to any chat. |
| `denied-launch` | monitor | `scripts/handover/chief-kit/denied-launch-alert.sh` | A worker launch was denied by the classifier; details stay on the station log. |
| `silent-go-merge` | monitor | `scripts/handover/chief-kit/silent-go-merge.sh` | A GO'd PR whose worker went silent was merged by the chief's script. |
| `claude-only-clear` | monitor | `scripts/cr/clear-review-marker.sh` | The review marker was cleared on the Claude-only fallback after every other review lane was out. |
| `bypass-result` | monitor | `scripts/station-ops/bypass-launchd.sh` | A bypass worker launch you answered with go or no ran, was refused, or did not run; the outcome is logged on the station. |
| `version-approval` | escalate | `scripts/handover/chief-kit/version-approval-alert.sh` | An out-of-version approval was signed for a ticket in the current version, for 14 days; 3 approvals are open. Blocks: nothing. Do: check you gave this approval, else revoke it |
| `cache-health` | monitor | `scripts/eval/cache-health-cadence.sh` | The hourly prompt-cache health check crossed a threshold. |
| `failure-review` | monitor | `scripts/eval/worker-digest/failure_review.py` | The daily failure review found something in the last 24 hours. |
| `upstream-watch` | monitor | `scripts/upstreams/upstream-watch.sh` | An upstream project the harness tracks has news to review. |
| `jira-nudge` | monitor | `scripts/hooks/jira-nudge-on-end.sh` | A session committed work tied to a ticket but made no Jira update (advisory). |
| `luna-sync` | monitor | `scripts/observability/luna-sync-alert.ts` | The luna vault has commits or files waiting to be pushed. |
| `recover-ok` | monitor | `scripts/station-ops/recover.sh` | Reboot recovery finished and the bridge is back up. |
| `cadence:himmel-doctor` | monitor | `scripts/doctor-cadence.sh` | The himmel-doctor scheduled worker reported a failure. |
| `cadence:judge-accuracy` | monitor | `scripts/eval/judge-accuracy/judge-accuracy-cadence.sh` | The judge-accuracy scheduled worker reported a failure. |
| `cadence:failure-review` | monitor | `scripts/eval/worker-digest/failure-review-cadence.sh` | The failure-review scheduled worker reported a failure. |
| `cadence:failure-review-digest` | monitor | `scripts/eval/worker-digest/failure-review-cadence.sh` | The failure-review-digest scheduled worker reported a failure. |
| `cadence:failure-review-route` | monitor | `scripts/eval/worker-digest/failure-route-notify.sh` | The failure-review-route scheduled worker reported a failure. |
| `cadence:claudex-inbox` | monitor | `scripts/lib/claudex-inbox.sh` | The claudex-inbox scheduled worker reported a failure. |
| `cadence:steering-cull` | monitor | `scripts/cleanup/steering-cull-cadence.sh` | The steering-cull scheduled worker reported a failure. |
| `cadence:clip-relevance` | monitor | `scripts/luna/clip-relevance-cadence.sh` | The weekly clip-relevance pass proposed himmel changes (up to five, one message), or its scheduled worker reported a failure. |
| `cadence:cache-health` | monitor | `scripts/eval/cache-health-cadence.sh` | The cache-health scheduled worker reported a failure. |
| `cadence:qmd-quality` | monitor | `scripts/eval/qmd-quality/qmd-quality-cadence.sh` | The qmd-quality scheduled worker reported a failure. |
| `cadence:ledger-drift` | monitor | `scripts/handover/chief-kit/ci-cadence.sh` | The ledger-drift scheduled worker reported a failure. |
| `cadence:vault-stall` | monitor | `scripts/luna/vault-stall-cadence.sh` | The vault-stall scheduled worker reported a failure. |
| `cadence:vm-maintain-cadence` | monitor | `scripts/vm/vm-maintain-cadence.sh` | The vm-maintain-cadence scheduled worker reported a failure. |
| `cadence:graph-channel-publish` | monitor | `scripts/graphify/publish-graph-channel.sh` | The graph-channel-publish scheduled worker reported a failure. |
| `cadence:librarian` | monitor | `scripts/handover/librarian-cadence.sh` | The librarian scheduled worker reported a failure. |
| `cadence:qmd-reindex` | monitor | `scripts/luna/qmd-cadence.sh` | The qmd-reindex scheduled worker reported a failure. |
| `cadence:rollup` | monitor | `scripts/eval/rollup-cadence.sh` | The rollup scheduled worker reported a failure. |
| `cadence:graphmap-himmel` | monitor | `scripts/luna/graphmap-cadence.sh` | The graphmap-himmel scheduled worker reported a failure. |
| `cadence:graphmap-luna` | monitor | `scripts/luna/graphmap-cadence.sh` | The graphmap-luna scheduled worker reported a failure. |
| `cadence:graphmap-ast-himmel` | monitor | `scripts/luna/graphmap-cadence.sh` | The graphmap-ast-himmel scheduled worker reported a failure. |
| `cadence:graphmap-ast-luna` | monitor | `scripts/luna/graphmap-cadence.sh` | The graphmap-ast-luna scheduled worker reported a failure. |
| `cadence:graphmap-semantic-luna` | monitor | `scripts/luna/graphmap-cadence.sh` | The graphmap-semantic-luna scheduled worker reported a failure. |
| `cadence:graph-config-unreadable` | monitor | `scripts/graphify/refresh-graph-map.sh` | The graph-config-unreadable scheduled worker reported a failure. |
| `cadence:pipeline-harvest` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-harvest scheduled worker reported a failure. |
| `cadence:pipeline-harvest-x-media` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-harvest-x-media scheduled worker reported a failure. |
| `cadence:pipeline-synthesize` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-synthesize scheduled worker reported a failure. |
| `cadence:pipeline-health` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-health scheduled worker reported a failure. |
| `cadence:pipeline-fetch-health` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-fetch-health scheduled worker reported a failure. |
| `cadence:pipeline-synthesize-index-lock` | monitor | `scripts/luna/pipeline-cadence.sh` | The pipeline-synthesize-index-lock scheduled worker reported a failure. |
| `cadence:upstream-watch` | monitor | `scripts/upstreams/upstream-watch-cadence.sh` | The upstream-watch scheduled worker reported a failure. |
| `cadence:security-audit` | escalate | `scripts/security/security-audit-cadence.sh` | security-audit: 2 new high or critical findings. Cause: new-high-critical findings in the dependency audit. Blocks: nothing yet. Do: read the audit log and decide which finding to fix |
| `cadence:snyk-scan` | escalate | `scripts/security/snyk-scan-cadence.sh` | snyk-scan: the scan found high findings. Cause: high-findings. Blocks: nothing yet. Do: read the scan log and decide which finding to fix |
| `cadence:graph-key-*` | escalate | `scripts/graphify/semantic-update.sh` | graph-key-A: account A API key rejected. Cause: HTTP 401 or 403 from the provider. Blocks: the semantic graph update for that account. Do: rotate that account's key file, or remove the account from the route |
| `cadence:graph-semantic-*` | monitor | `scripts/graphify/graph-cadence.sh` | Any `cadence:graph-semantic-*` kind: a scheduled worker of that family reported a failure. |
| `cadence:vm-maintain-login-*` | monitor | `scripts/vm/vm-maintain.sh` | Any `cadence:vm-maintain-login-*` kind: a scheduled worker of that family reported a failure. |
| `cadence:grafana-Flow_run_truncated` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Flow run truncated. |
| `cadence:grafana-Flow_run_error` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Flow run error. |
| `cadence:grafana-Flow_run_stalled` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Flow run stalled. |
| `cadence:grafana-Flow_last-success_age_exceeded` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Flow last-success age exceeded. |
| `cadence:grafana-Orphaned_quiet-run_suites___writer-less_tail_followers` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Orphaned quiet-run suites writer-less tail followers. |
| `cadence:grafana-Watcher_down` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Watcher down. |
| `cadence:grafana-Luna_inbox_backlog_rising` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Luna inbox backlog rising. |
| `cadence:grafana-Session_dead` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Session dead. |
| `cadence:grafana-Hook_chain_budget_pressure` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Hook chain budget pressure. |
| `cadence:grafana-Hook_chain_budget_denials` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Hook chain budget denials. |
| `cadence:grafana-Hook_chain_log_unreadable` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Hook chain log unreadable. |
| `cadence:grafana-Guard_denies_a_large_share_of_sessions` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Guard denies a large share of sessions. |
| `cadence:grafana-One_session_repeatedly_denied_by_one_guard` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: One session repeatedly denied by one guard. |
| `cadence:grafana-Eval_regression_beyond_noise_band` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Eval regression beyond noise band. |
| `cadence:grafana-Scheduled_eval_has_not_run_in_14_days` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Scheduled eval has not run in 14 days. |
| `cadence:grafana-Scheduled_eval_has_no_ledger_series` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: Scheduled eval has no ledger series. |
| `cadence:grafana-DatasourceNoData` | monitor | `scripts/observability/grafana-cadence-hook.ts` | Grafana alert rule: DatasourceNoData. |

A message with no kind is an `unclassified` escalate and goes to the operator chat. That is deliberate in one place: `chief-wait.sh` sends a denial page with no kind when it could not write the page record, so a page that could not be remembered is never made quiet. `bypass-launchd.sh` names a kind on every line it sends: `bypass-ask` for the go-or-no ask, `bypass-failed` for a failed launch, and `bypass-result` for every verdict and refusal.

Every `monitor` row also carries an `on-alert` field that says what should happen when a line of that kind arrives. It is one of three entries: `{"do":"repair","verb":…}` runs a repair that already exists, and the verb comes from a two-entry allow-list (`doctor-fix`, `rerun:rollup`) with no free command; `{"do":"escalate","to":"chief"|"operator","reason":…}` hands the line to its owner with the reason no automatic repair is safe; `{"do":"info","why":…}` marks a success or report line that needs no action. A kind whose lines differ carries an ordered list instead: each entry has a `match` regex tried in order, and the last entry has no `match` and is the fallback, so no line of the kind is left unmapped. For `cadence:himmel-doctor` the list is applied to each finding id the line names; for every other kind it is applied to the line text. `test-message-classes.sh` fails a `monitor` row with no valid `on-alert`. Nothing reads the field yet: the alerts watcher that acts on it arrives in a later change.


## Ops runbook

**Start:**

```bash
cd scripts/telegram && bun supervisor.ts
```

The supervisor keeps `bun poller.ts` alive.

**Restart (Linux/macOS):** `bash
scripts/telegram/restart-bridge.sh start` kills ONLY the bridge's bun
processes (matched on `supervisor.ts`/`poller.ts` command line), with a
token-scoped `flock` for serialization where `flock` exists (macOS ships none by
default, so there the script continues without it), and starts exactly one
supervisor detached. It does NOT verify no-409/settled progress after launch (a known
gap). `status` reports without touching
anything; `--repo <path>` points at a non-default checkout. **Stop
(cross-platform):** `bun supervisor.ts --kill` (reads the `supervisor.pid`
file written under the bridge root) or `bash
scripts/telegram/restart-bridge.sh stop`.

**Kills are INSTANCE-scoped.** Matching `supervisor.ts` /
`poller.ts` on the command line narrows the candidate set; it is not an
ownership test, because every himmel checkout on a machine runs those same two
entrypoint names. `restart-bridge.sh` therefore kills a candidate only when it
is also *this* instance's, by either of two independent sources: the
`supervisor.pid` ledger under this instance's bridge root, or a working
directory equal to this instance's `$repo/scripts/telegram` (the launcher
`cd`s there, and the poller child inherits it) — the cwd source is what keeps
stale-ORPHAN recovery working, since an orphan predates the current pidfile.
A candidate whose cwd cannot be read and which is not in the pidfile is left
ALONE, with a named WARNING on stderr. Before this, a sandboxed test fixture
running the launcher SIGKILLed the operator's live production bridge and still
reported all-green.

What this costs is read off the rule, not off an intuition about "instances".
A process is ours iff **its cwd is our `$BRIDGE_DIR`** (`<repo>/scripts/telegram`),
**or** it is recorded in our pidfile ledger (under `bridgeRoot` =
`${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}`) **and that entry is not
stale** — the process did not start after the pidfile was written. So:

- Same **checkout** (any roots) → one instance to each other, via the cwd. They
  sweep each other; *one poller per token* preserved.
- Same **bridge root** (any checkouts) → one instance to each other, via a
  live ledger entry. This is the ordinary local case: a git worktree and the
  primary checkout under one `$HOME` have *different* bridge dirs but *one*
  `supervisor.pid`. They sweep each other; *one poller per token* preserved.
- Only when the roots **and** the checkouts both differ are the two isolated.
  They can then run concurrently, and on the same `TELEGRAM_BOT_TOKEN` both
  poll `getUpdates` and Telegram answers one with `409 Conflict`.

That last case is a real, narrow behaviour change and it is deliberate: the only
thing that previously prevented it was the indiscriminate machine-wide kill this
ticket removes — silently killing a process the launcher could not attribute, to
paper over an operator misconfiguration. Instead `start`/`run`/`stop` print one
non-destructive WARNING naming how many foreign bridge processes were left
alone. A shared token cannot be detected (no portable way to read another
process's environment), so running exactly one bridge per token stays an
operator responsibility.

**Staleness, not cwd, is what makes both halves safe at once**, and it is not
novel here: the restart script's ledger-pid check already refuses any
ledger pid whose process was created after the ledger was written. Drop the
staleness check and honouring the ledger across checkouts would license
`kill -9` on another checkout's supervisor that merely inherited a recycled
pid; drop the ledger source instead and a worktree and the primary checkout
stop seeing each other and both poll one token. Earlier rounds of this fix
each fixed one of those by breaking the other. When a timestamp cannot be read
at all the check reports *undeterminable* rather than inventing a verdict, and
an undeterminable verdict licenses ownership **only where there is no cwd
evidence against it** — i.e. the cwd was unreadable too, which is the
macOS/no-`lsof` host the fallback exists for and which must still be able to
stop its own bridge. A readable but *mismatching* cwd is evidence, and it is
not overridden. The consequence, stated rather than glossed: on a host that can
read cwds but not timestamps, a shared-root instance stops being swept — a
possible `409` is accepted rather than possibly SIGKILLing a stranger's bridge,
because a 409 is recoverable and visible while killing someone else's live
bridge is neither.

Two roots sharing a checkout are deliberately **not** separated: nothing
portable distinguishes "my own orphan from a previous run" from "another root's
live bridge" when both run from the same directory, and recovering that orphan
is exactly why the cwd source exists.

Two related levers came with it:

- **`run` verb** — `start` without the detach: same lock, same instance-scoped
  sweep, then `exec`s the supervisor in the FOREGROUND, so systemd tracks the
  supervisor itself as MAINPID.
- **`HIMMEL_TEST_FIXTURE=1`** — a marker any test fixture sets (the shell-suite
  runner exports it for every suite it launches). Under it, `start`/`stop`/`run`
  REFUSE with **rc=3** in two cases. First, `BRIDGE_ROOT` unset — the pidfile
  source would be the operator's real one. Second, `--repo` pointing at a **real
  checkout**, meaning the target bridge dir is inside *any* git work tree: the
  cwd source would then select that checkout's live bridge processes, sandboxed
  root or not. The launcher's **own** checkout is the likeliest form of that
  mistake and is called out by name with its own message, but the refusal is not
  limited to it — a fixture aimed at some *other* clone is refused just the
  same. The work-tree test is **unconditional**: it walks up from the bridge dir
  looking for a `.git` entry in pure shell, so there is no `git` binary to be
  missing and no host on which the guard quietly stops guarding — which matters
  because the shell-suite runner exports the marker for *every* suite.
  Fail-closed by design: a `TMPDIR` that sits inside a git-managed `$HOME`
  therefore makes bridge fixtures refuse — the rc=3 message names the bridge
  dir it refused and says it is inside a git work tree, so the cause is
  diagnosable. Loud and fixable, rather than quietly permitted.
  `status` and `--print-lock-path` are read-only and unaffected.

**Launch handoff.** `start`/`run`'s lock is released before the
process they just launched is *visible* to process discovery — `list_bridge_pids`'
candidate set is derived from a live `ps` scan matching `supervisor.ts`/
`poller.ts` command lines, and neither verb can hold the lock across that
window. `run` execs into the supervisor, and fd 200 must close before the exec
or a later blocking `stop` deadlocks; `start`'s own lock dies with the launcher
script's process, milliseconds after `nohup … &`, while the backgrounded child
may not have exec'd into `bun` yet. In that window the future supervisor is a
live process but not yet a `bun supervisor.ts` line, so a *concurrent* `start`
taking the lock finds nothing to sweep and launches a duplicate — two pollers
on one token, `409 Conflict` to one of them.

Both verbs close it with a launch **marker** file,
`<bridgeRoot>/supervisor.launching = "<pid> <epoch>"`, written while still
under the lock and naming the pid about to become the supervisor (`$$` for
`run`, preserved across its `exec`; the backgrounded child's own pid for
`start`, preserved through `nohup`'s exec). A launcher that takes the lock and
finds an ACTIVE marker neither sweeps nor launches — it reports the in-flight
launch and exits **rc=4**. ACTIVE requires all three of:

- the pid is still **alive** (`ps -p`, not `kill -0` — `EPERM` on a
  foreign-owned pid would read as dead);
- the pid is **not already in the discovery set** — the moment the supervisor
  is visible, the marker has done its job and stops blocking, which is what
  keeps a second `start` still meaning "sweep and relaunch" rather than
  refusing forever;
- its age can be **computed** and is younger than `LAUNCH_MARKER_MAX_AGE_SEC`
  (30s, generous — the real handoff is a fork+exec, sub-100ms) — the backstop
  for a launcher that hangs or dies before exec'ing, or a recycled pid. An age
  that *cannot* be computed — an unreadable epoch or clock, or a negative age
  from a clock stepped backwards — retires the marker as inactive (one named
  WARNING) rather than leaving it active indefinitely: an unboundable age
  costs the handoff guard for one launch, the opposite direction could wedge
  the bridge permanently.

An inactive marker is ignored and removed by the next mutating verb (`stop`
warns instead of removing an *active* one — it cannot reap what it cannot see,
so a bridge may still come up right after `stop` returns). `write_launch_marker`
is placed immediately adjacent to the actual detach/exec in both verbs, after
every earlier point either verb can exit — bun resolution, the stale sweep —
so a launch that fails *before* the handoff never writes a marker at all; pid
liveness alone would not catch that case, since the launching shell's own pid
stays alive regardless of whether the launch it named ever became a bridge.

The honest residual: on a host **without `flock`** there is no lock at all, so
the marker's own write and a concurrent read race each other exactly as the
rest of this serialization already degrades — documented, not silently
papered over. And the marker is bridge-**root** scoped, exactly like
`supervisor.pid`: two instances sharing a root serialise their handoffs; two
that share neither root nor checkout do not, which is the same isolation (and
the same accepted `409`) the instance-scoping section above documents.

**Reboot persistence:** nothing relaunches the bridge on its own after a
reboot. Linux installs a systemd **user** unit plus `loginctl enable-linger` (without linger
the unit stops at logout). The unit is `Type=simple` running
`restart-bridge.sh run`, so the bun supervisor is the unit's MAINPID and
`Restart=on-failure` brings it back when it dies — including on a signal
death — bounded by `StartLimitIntervalSec=600` + `StartLimitBurst=5`, which is
what keeps `Restart=` from overriding `supervisor.ts`'s own circuit breaker
(the breaker halts with `exit 1`, and without a start limit systemd would
relaunch it every 10s forever). Five restarts in ten minutes leaves the unit
`failed`, for a human. (It was `Type=oneshot` + `RemainAfterExit=yes` around a detached
`start`, which made systemd blind to the supervisor's lifetime: the unit
happily reported `active (exited)` through the silent bridge deaths
this fix was filed for.) *Operator note:* an already-installed unit file is
a rendered COPY — it stays on the old shape until `himmelctl`'s
bridge-persistence install step is re-run. Recipe:
`scripts/telegram/README.md`'s "survive a reboot" section.

**Required config:**

- `~/.claude/channels/telegram/.env` with `TELEGRAM_BOT_TOKEN=...`
- `~/.claude/channels/telegram/access.json` with `{"allowFrom":["<your-id>"]}`
  — hand-authored; the allowlist is a prompt-injection surface (anyone it
  admits can drive bounded runs), so it is never written automatically. `bun
  scripts/telegram/onboard.ts` (see Components above) exists to make the ids
  safe to *find*: it prints a one-time nonce, waits for it to come back in a
  message, and reports the `chat.id`/`chat.type`/`from.id` it arrived on —
  copy those into `access.json` yourself.

**Inspect:** session state lives under
`~/.claude/handover/bridge/sessions/`.

**Single-owner rule:** exactly one `getUpdates` consumer per token. Do NOT
run a `claude --channels` / `TELEGRAM_OWN_POLLER=1` owner-fork session while
the poller is running — it would 409-conflict the poller (Telegram allows
only one long-poll consumer per token).

**Message verbs:**

- `work on <KEY>` — dispatch: ensure session `<KEY>`, run it.
- `<KEY>: <text>` — follow-up to that session.
- `status` / `sessions` / `stop <KEY>` — control.
- anything else → chat.

## WS-D — auto-mode

The poller is a bun process, not an LLM, so it spawns `claude` directly
rather than through a classifier-gated tool — there is no special
allow-rule to add for dispatch. The bounded runs it spawns operate under the
operator's standing auto / accept-edits policy, which is what gives them
unattended autonomy.
