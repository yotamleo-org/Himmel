# The chief and its workers

A chief is one long-running Claude session that keeps several tickets moving
at once. You talk to the chief; the chief runs the workers.

## What the chief does

- It picks tickets from the queue and writes a brief for each one it starts.
- It starts one worker per ticket, each in a terminal window, worktree and
  branch of its own.
- It answers the workers' questions, and brings you the ones only you can
  answer.
- It checks every finished PR itself before it lets it merge: CI green at that
  exact commit, no open review threads, the required commit trailers.
- It hands itself over to a fresh chief before its context fills, so a shift
  outlives any one session.
<!-- mem:7a7399f97076 -->
- Tell the chief to end every milestone report with a "Blocked on you" list:
  one clickable PR URL or absolute path per line plus the one action wanted, or
  "Nothing blocked on you". "Held for your review" with no link is not enough.

The chief writes no code itself. Today the chief always runs from the himmel
clone, whichever repo its workers change.

## What workers do

A worker is one ticket, one worktree and one PR. It makes the change with
tests, reviews it with `/pr-check`, opens the PR, and reports to the chief at
each milestone: live, a question, ready, blocked, wrapped. When the chief gives
it a GO it merges, closes the ticket and ends.

## Parallel waves

The chief starts workers in parallel waves: a group dispatched together, after
it checks that no two of them will change the same files. `HIMMEL_FLEET_CAP`
caps how many sessions run at once; a worker launch past it is refused.

## Your approval: the GO

A worker never merges on its own say-so. When it reports ready, the chief
re-checks the PR at that exact commit, and only then writes a GO file for that
one PR at that one commit. A push after the GO needs a new one. The GO is
written on your authority: tell the chief to hold a PR, change a ticket's scope
or stop a worker, and it acts on that. Your rulings reach the chief from you
directly, in its terminal or from Telegram with `/chief <session> <text>`.

## Start one and hand it over

```bash
/chief new           # writes the chief's document, takes its lock, prints the launch line
/chief new --arm     # also arms the launch for you
/chief next          # hands the shift to a fresh chief
```

Without `--arm`, paste the printed launch line, whole, into a terminal of its
own. With `--arm` the line is printed for information only: do not paste it,
or a second chief starts on the same document.

## Where the shift board is

The chief renders its board, one static page, from its own state and
republishes it as it changes: the fleet against its cap, each worker's stage,
and what needs a decision. The same board shows on the Fleet page of
`himmelctl ui` when you start it with `HANDOVER_DIR` set. Both are in
[The local dashboard](../ui.md#the-chiefs-board-and-roadmap-tracker).

For a fixed list of well-scoped tickets you want done unattended in one
session, an AFK shift is simpler: [AFK (unattended) runs](afk-mode.md).

## For maintainers

The full runbook: starting, dispatching, rulings, merges and handing over, step
by step.

A chief is how a single operator keeps several tickets moving at once across
sessions that each forget everything at the end. What a chief, worker, judge,
relay, dependency chain, parallel wave, arming and side session *are* is defined once, in
[`../glossary.md`](../glossary.md); read that first if any of those words is
new. This page is how to run one.

`/chief new` starts one. `/chief next` hands it over to its successor.
For the sources, authors and licences behind the team's tools, see
[Credits](../credits.md).

## Who does what

- **You (the operator)** talk to the chief. It dispatches **workers**,
  one ticket per worker, and acts on their questions and on **judge** verdicts;
  it merges only on a GO file (merge approval) that it writes.
- Judges and relays serve the chief; neither holds GO or the nonce mint;
  only the chief does (the authority table is in the glossary).
- **Side session.** If you work in a side session of your own, hand the
  chief a ticket and a brief; never pass it a ruling by way of a relay. A
  ruling reaches the chief from you directly, or not at all.
<!-- mem:ace94451564b -->
- **Planning session.** A session that scopes an epic, writes its plan and runs
  its evals hands the whole epic to the chief and then closes. The chief
  reports in the normal flow: gate results as comments on the epic, operator
  calls in the "Blocked on you" list you tell it to keep, never back to the
  planning session.
  Before closing it, check that the plan is in the epic body, the eval
  artifacts are in the state repo (not a session scratchpad), the release
  versions are set, and the chief has been told it is the single writer.

## Chief vs. `/afk-shift`

They look adjacent and are not interchangeable.

| | `/afk-shift` | chief |
|---|---|---|
| Shape | one session fans out N subagents inside itself | one session dispatches N *separate* sessions |
| Lifetime | one run, then done | a succession: each chief arms its successor |
| State | in-session | a handover document + a queue lock, survives the session |
| Children | subagents, no window of their own | headed sessions with their own worktrees and PRs |
| Rulings | none; the plan is fixed at fanout | RETASK channel, mid-flight, authenticated |
| Handover | none | `/chief next` writes the successor + a HANDOFF |

Reach for `/afk-shift` when you have a fixed list of well-scoped tickets
and want them done unattended. Reach for a chief when the work will need
decisions you cannot pre-write, or will outlive one context window.

## Starting one

```bash
/chief new                        # writes the doc, takes the lock, prints the launch line
/chief new --name night           # a differently-named succession in the same bucket
/chief new --arm                  # also arms it headed, on a signal file + deadline
/chief new --dry-run              # print what it would write, touch nothing
```

`new` resolves your handover root through the shared resolver (`HANDOVER_DIR`,
else `<repo>/handovers`) and your bucket the same way the handover skill does,
then writes `<root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-chief.md` from
[`chief-template.md`](chief-template.md). A second `new` on the same day
writes `…B-chief.md`; it never overwrites.

<!-- mem:5987b4cf9ea9 -->
**Keep the `-chief` suffix in a scoped name:** `--name roadmap-chief`, not
`--name roadmap`. The suffix is load-bearing. `chief-compact-reinject.sh`
re-injects the live state after a compaction only for a session whose
launch-time `-n` name ends in `-chief` (or the older `-console`), and `/rename`
does not change that name. A `--name roadmap-chief` is mapped to
`roadmap-chief`, and `next` on a `…-console.md` predecessor arms a `…-chief.md`
successor; every guard and reader still treats a live `-chief` session as a
chief. `next` derives the successor's name from its `--doc`, so a doc without
the suffix hands the mistake down the chain. To fix a mis-named chief, copy
its doc to a `…-chief.md` path, take the lock on the new path, release the
old one, and leave a pointer stub behind.

It then acquires the queue lock on that document and prints the
`release-token:` line. **That token belongs to the chief you are about to
launch**. Record it in the chief's first Results bullet, because releasing
the lock at wrap requires it. The chief *adopts* this lock; it does not
acquire a second one. (`new` takes the lock and then exits, so a chief that
tried to acquire again would be refused by its own startup lock.)

Without `--arm`, paste the printed `launch:` line **verbatim, including its
`env -u …` prefix**. With `--arm`, `headed-arm.sh` launches the chief and the
printed line is informational: pasting it as well starts a second chief on the
same document.
That prefix is load-bearing, not decoration: you are almost always pasting into
a terminal that was itself spawned from a claude session, and it clears the
`CLAUDE_CODE_CHILD_SESSION` / `CLAUDE_PID` / `CLAUDE_CODE_SESSION_ID` variables
that shell inherited, plus the `CLAUDE_CODE_MESSAGING_SOCKET` / `_TOKEN` pair
and `CLAUDE_JOB_DIR`: a session that keeps them answers to the name of the
session that launched it. A chief that keeps the first three writes no transcript and gets
`UNKNOWN` from `scripts/context-fill.sh --percent`, which is the signal its
own handover contract runs on. Trimming the line to just
`claude …` silently recreates that failure.

Finally it prints the launch line. Without `--arm`, run it in a terminal of its
own:

```text
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_JOB_DIR \
    CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 \
    claude --model '<model>' --autocompact auto -n <session-name> "load <doc> and continue"
```

`[1m]` is appended to the model only for the 4.6 family (`claude-opus-4-6`,
`claude-sonnet-4-6`); Opus 4.7+, Sonnet 5+, Haiku 5.5 and Fable run 1M natively
and non-Anthropic ids (`gpt-*`, `glm-*`, anything with a `/`) never take it
(HIMMEL-5501). `--autocompact` and the Opus 5.5 id need Claude Code 2.1.280 or
newer: an armed launch on an older CLI refuses and names `claude update`
(`/himmel-update` brings it current).

Chiefs default to 1m context with `--autocompact auto`
(a chief exemption). Both `chief new` and `next`
accept `--context 1m|standard`, which overrides the environment and default.
Use `--context standard` or `CHIEF_CONTEXT=standard` in the launching shell
to opt down to `--autocompact 200000`. The printed launch line and armed
launch use the same resolved choice. Fable-family models retain their existing
handling: the CLI strips `[1m]`, so the suffix is not applied; autocompact still
is. Workers and non-chief arms keep their standard default.

A chief wants a real TTY. A session launched without one exits at the first
idle cross-session message.

<!-- mem:8d69de351916 -->
A chief armed with `arm-resume.sh` to survive a reboot is itself launched by
`at`: its stdin is the deleted at spool file (`ls -l /proc/<pid>/fd/0` shows
it). Its first job is to hand off to a headed chief via
`scripts/handover/headed-arm.sh`, before it launches any worker; otherwise the
first worker `LIVE` or `READY` message is the idle message that ends it.

## ACTION ZERO

The template's first section. The chief runs it before anything else and
writes the result as its first Results bullet: who is alive (`ListAgents`),
what locks are held **at the handover root** (not just its own bucket; a
bucket sweep reports a false "no held locks"), the primary's head and remote,
`usage-preflight.sh`, the live worker processes, host load, and the kit path. Then
it records the lock token `new` printed (confirming with `queue-lock.sh
status` that the lock is held, and acquiring one only if it reports `free`)
and tells its predecessor it is live.

It also opens a **Telegram inbox**: it creates
`<bridge root>/consoles/<session>.md` and watches it with its one event waiter,
`chief-kit/chief-wait.sh`, run with Bash `run_in_background` (no `Monitor` re-arm loop, so an idle chief takes no turns; a persisted read
cursor means a line appended while no waiter ran is delivered on the next
start; at-least-once, so a waiter killed mid-emit can repeat one line), so
the operator's `/chief <session> <text>` (or the older alias `/console`) from
Telegram reaches the running chief with the operator's authority (rulings,
halts, new work) but never a permission or settings change and never a
skipped GO verification. The chief replies with
`bun scripts/telegram/chief-route.ts reply <chat_id> <text>`. A line tagged
`[voice satellite=<id> UNVERIFIED-SPEAKER]` carries no operator authority: the
chief acts directly only on status asks and narrowings, and turns anything
wider into a Telegram `voice asked: <X> — reply yes` that acts on a later
`[telegram from=...] yes`. That yes carries Telegram authority and no more, so
it never changes a permission or setting either. Operator-side
usage: [`../telegram-bridge.md`](../telegram-bridge.md#messaging-a-running-chief).

The same waiter **pages the operator** when a worker's classifier
denials reach `SHIP-STEP` or `PAUSE-RISK`: one Telegram message with the worker
label, count and class, and nothing else. A paged worker is then **refused** on
re-dispatch (`headed-arm-worker.sh` exits 14) until someone has looked and run
`bash scripts/handover/chief-kit/ack-denial.sh <worker-label-or-doc>`;
`--ignore-denials` overrides. Detail:
[`../internals/enforcement.md`](../internals/enforcement.md#log-classifier-denialsh--classifier-denial-tap-himmel-3724).

## Dispatching workers

**Pre-dispatch trust-path check:** trace the planned scope and
list the trust paths it will plausibly need (shared libraries, hooks, launchers,
settings, or guardrail inventories). Put the exact paths, permitted operations,
and exclusions in the initial brief, with the operator's up-front scope grant.
If that grant is missing, narrow the task or obtain it before dispatch; a
chief cannot manufacture operator permission. The brief grants task scope,
not a bypass of the worker's tool-permission envelope. In particular, an auto-mode
worker's mid-flight inbox EXPANSION may be refused by the classifier and needs
operator confirmation in-window, even with a valid RETASK token. Do not use
repeated inbox revisions as a workaround; see
[`../internals/retask-channel.md`](../internals/retask-channel.md).

When drafting the brief's **Ship:** item, spell the attestation trailers'
grammar rather than paraphrasing it: the token is the FIRST word after the
colon: `Platforms tested: <os>`, `Security reviewed: manual — <what you
checked>` (or `claude-code-security-review` / `pr-review-toolkit` / `ad-hoc`
in place of `manual`). A paraphrase the worker copies faithfully is how a
non-conforming trailer reaches the pre-push gate.

The chief writes a brief from
[`worker-brief-template.md`](worker-brief-template.md) and launches it headed:

```bash
setsid nohup bash scripts/handover/chief-kit/headed-arm-worker.sh --profile worker-impl \
  <session-name> <brief> <signal-file> <deadline-epoch> <log> <model> \
  >/dev/null 2>&1 &
```

Two rules govern the fan-out. **Collision-check first:** list the files each
queued worker will touch and confirm they are disjoint; **single-writer** means
many readers but exactly one writer per artifact. And **every dispatch names an
explicit model**: an unnamed one draws on the scarcer parent quota. Tier and
effort guidance, including the chief's own wake-up budget, is in
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

Four pre-launch checks that each cost a chief a dead worker when skipped:

<!-- mem:c263127c8979 -->
- **An old backlog bug may already be fixed.** Before dispatching a worker on a
  bug filed weeks ago, check that it still reproduces on current main: read
  the code the ticket names and look for a regression test that covers it.
  Many have been fixed in passing. Batch the check in one read-only agent pass
  (still open, fixed, or partial, each with file:line evidence), and verify any
  "fixed" claim yourself before you close the ticket.
- **The Tier line needs a literal em-dash.** An Opus or Fable worker launches only
  if its brief carries `> **Tier:** opus — <category>: <reason>`. With an ASCII
  hyphen in place of the em-dash, `headed-arm-worker.sh` refuses: no launch log,
  nothing in `pgrep`. `--dry-run` an Opus or Fable launch first and look for
  `refusing` in its output. Never probe with a real launch under `timeout`
  instead: the launch reserves a fleet slot under the session name for the
  deadline plus 60 s, and a killed probe does not release it, so the real
  launch then refuses with "fleet-size cap reached" in its log (a duplicate
  reservation underneath) even when the fleet is far under cap. If a name is stranded,
  relaunch under a fresh session name.
- **Design-profile workers need a one-time interactive OAuth login.** The `design`
  profile enables `builder-visual@himmel`, whose `.mcp.json` registers the hosted
  `agent-native-dispatch` MCP server (`https://dispatch.agent-native.com/mcp`,
  OAuth). Until the operator has logged in once (`/mcp`, pick
  `agent-native-dispatch`), the server needs auth and a worker cannot answer the
  prompt, which looks like a hung worker. Tool arguments go to Builder.io servers:
  never use it on salus/PHI work. `block-agent-native-egress.sh`
  refuses the call from a salus session or when the payload names salus. `context7` needs no login. Do not arm a
  design-profile worker unattended (`--arm`, at-jobs, overnight) until a fresh
  session has been checked to keep the token.
<!-- mem:c5cd55be07ae -->
- **No live session may own the target worktree.** Disjoint file sets do not
  prove it is safe: a session still running there may be mid-commit on the
  same fix. Check `ListAgents` and `pgrep -af 'claude .*-n <name>'` against
  the ticket before fanout. A quiet worktree does not prove the session is
  dead: one running tests or awaiting a reply writes nothing. A killed session's uncommitted
  files survive, but only in its own worktree, so re-dispatch into that
  worktree rather than a fresh one.

Pass **`--profile worker-impl`** on a native-lane worker: it narrows
the worker's plugin set, appends the standing rules from
[`worker-preface.md`](worker-preface.md) to its system prompt (which is why the v3
brief template no longer repeats them) and exports `HIMMEL_LEAN_WORKER_SESSION=1` to
quiet the warn-only SessionStart hooks. It also now passes
`--mcp-config`/`--strict-mcp-config`, so a worker only ever sees the `qmd` MCP
server, not the USER-level MCP roster (a chief gets the same treatment:
`qmd` and `himmel-bus` only). A worker dispatched WITHOUT the flag is
unchanged in every respect, including its argv, so the worker system prompt rules must then be
pasted into the brief. Detail:
[`../internals/lane-calibration.md`](../internals/lane-calibration.md).

**Repo map (off by default).** Set `WORKER_SESSION_REPO_MAP=1` in the launching shell and
a profiled worker's system prompt starts with a repo map: the files of
the worker's repo ranked by PageRank over its primary checkout's
`graphify-out/graph.json`, each with its most-referenced symbols, capped at
`WORKER_SESSION_REPO_MAP_TOKENS` (default 2000) tokens. It is built by
`scripts/graphify/repo-map.py`; with no graph, or a generator still running after
`WORKER_SESSION_REPO_MAP_TIMEOUT` (default 30) seconds, or on a host with no GNU `timeout` to bound
it, the worker launches without it and the launch log says so. It stays off because the A/B on the K7 questions
(HIMMEL-6142) showed no gain: 15/15 answers found with and without it, at the
same token cost.

`headed-arm-worker.sh` exports `HIMMEL_CONSOLE_LEG=1`, which
`block-worker-askuserquestion.sh` uses to structurally deny
`AskUserQuestion` on the worker, rather than relying on the brief's prose NEVER.

`headed-arm-worker.sh` also exports `HIMMEL_CONSOLE_NAME` into the
worker, resolved from the first of: a `--chief <name>` flag, this launching
shell's own `HIMMEL_CONSOLE_NAME`, or the chief's own session name if it can
be read reliably. It is never guessed from the process tree, and exported not at
all if no source yields a name. A running chief usually needs no flag: its
own session name resolves automatically. This is what lets a worker's
merge-block alert (`scripts/lib/merge-block-alert.sh`) route to
the chief's own inbox instead of DMing the operator.

**Idle capacity is the chief's duty.** `tick.sh` appends `fleet=<live>/<cap>`
(usage-preflight's own census: native + claudex + reserved, `HIMMEL_FLEET_CAP`)
and `capacity=`. On `capacity=UNDERFILLED:<slack>` (live below cap and no worker
launched for `TICK_UNDERFILL_MIN` minutes, default 10), pull dispatchable work
from the Jira backlog, not only the held queue, and launch up to `<slack>` workers.
`chief-wait.sh` wakes on it once per streak (`WAKE underfilled`) and prints
`chief-kit/next-dispatchable.sh --priority-pool-only`'s ranked, collision-checked
list (free slots fill from the priority pool; it ends with `# pool=<rows>/<slack>`, `,LOW`
when short; `POOL-EMPTY` lists the tier-4 `NEXT-TIER` rows and means unblock
collisions, draft specs for the next priority items, else idle);
`chief-kit/gen-briefs.py` writes the briefs and launchers (nothing launches
itself). A bare `--bucket himmel` resolves to `<handover-root>/<user>/himmel`;
`--no-worktree` refuses a worker whose worktree does not exist and prints the
`worktree.sh new` line to run.
Before dispatching a chain of PRs, `python3 scripts/handover/chief-kit/chain-graph.py --prs <n>,<n>,...`
prints the pairwise hard and soft edges between them (read-only; `--json` for scripts, `--head PR=SHA`
to pin a PR to an older head).
`capacity=unknown` (`fleet=?`) means the census could not be read, not that
capacity is fine.

**A red orphan is owed a worker.** An `unowned-prs=` entry ending `:dispatch-owed`
(`#<pr>:<age>m:dispatch-owed`) is an open, non-draft PR with no live worker and at least one
failed check. Launch a resume worker for it on the next WAKE; triaging the red is that
resumed worker's job. A pending or green orphan keeps its plain `#<pr>:<age>m` entry.

**Reading worker locks and the tick.** `tick.sh --workers` takes **absolute**
handover-doc paths on ONE `## Live state` worker line (its field name:
[`chief-sections/live-state.md`](chief-sections/live-state.md)); a relative path drops the bucket
prefix out of the lock key and the worker reads `free` while it is live. The
queue-lock owner pid is the launcher **wrapper**, so every owner reads dead
while its worker is alive, and the release token a worker pasted into its LIVE
bullet can be wrong; recover the real one from
`${XDG_RUNTIME_DIR}/himmel-queue-lock/` before calling a lock stale.
`IDLE-HELD?` is heartbeat age, not death: a worker inside a long foreground suite
makes no tool calls. Verify with `pgrep` against the worker's session name;
never force-release on the flag alone.
**`NOLIVE` and `FORKED`.** A worker that never took its lock or wrote
a marker bullet reads `FREE` forever, so the waiter's key never moved and the
chief was never woken. `workers=` now shows `<N>:NOLIVE` once a worker with no held
lock and no marker bullet at all is older than `TICK_NOLIVE_MIN` minutes
(default 10), counted from the fleet manifest's `added` time, else the launch
log's `armed:` line, else the doc's mtime; the change from `FREE` wakes the
waiter. `<N>:FORKED` means the worker's session transcript (found only by its
`custom-title`, never guessed) ends in a `continued-in` record: the session was
forked or backgrounded into another one, usually without its worker system prompt. A
`WRAPPED`, `READY`, `LIVE`, `BLOCKED` or held-lock worker is never either. Act on
both the same way: `ListAgents`, then `SendMessage` the worker its lock command
(`queue-lock.sh acquire <its doc>`), your chief name and its RETASK
token; if it is gone, relaunch it.
`tick.sh --workers-from <manifest>` reads the same absolute docs
from a fleet manifest that `chief-kit/fleet-manifest.sh add|remove` keeps,
re-read every sample, so a dispatch or wrap needs no waiter re-start.
Pass `--fleet <manifest>` before the positional arguments to
`chief-kit/headed-arm-worker.sh` and `chief-kit/close-wrapped-worker.sh` to keep
that manifest updated automatically: launch adds its doc only after a successful
handoff; close removes its doc only on a successful close (including benign
prune skips). Failed/refused launches and closes leave the manifest unchanged.
Without the flag, both verbs keep their existing behavior. Dry-run launches
never update the manifest. An update failure returns nonzero and reports that
the launch/close already happened; it does not undo it. Nonces remain chief-only
inputs to `live-state.sh --nonce`, never sourced from the manifest.

A worker's `MERGED` or `WRAPPED` message is one call, not a turn sequence:
`chief-kit/worker-event.sh --doc <chief doc> --fleet <manifest> <message-file>`
routes it to `chief-kit/wrap-merged.sh` and prints `HANDLED` or `ESCALATE
<reason>`; a judge verdict is one `chief-kit/verdict-go.sh` call. Chiefs that
ran the hand sequences spent most of their input tokens on them
(HIMMEL-5592 inventory: `scripts/eval/chief-load-inventory.py`).

**Lane canary**: `scripts/lanes/lane-canary.sh [--lanes a,b]
[--timeout <sec>] [--out <report.json>] [--dry-run]` launches one no-op worker per
lane through the real launcher and reports PASS, FAIL or SKIP with the time to
the first Results bullet. Run it after a station update or a lane change; the
unit suites check the generated command, this checks that a worker on the lane
actually starts, registers, receives its brief and writes a bullet. Lanes run
one at a time, and a lane whose backend is not configured is SKIP. The report
lands at `<handover root>/.canary/latest.json`, the file the board reads. A lane
whose launcher refuses on its usage (exit 11, for example OpenRouter credit under
`OPENROUTER_MIN_CREDIT_USD`) reports FAIL, not SKIP: read the detail column
before treating it as a lane defect.

**Worker tabs** (off by default): launch the chief with `HIMMEL_WORKER_SESSION_TABS=1`
in its environment, for example `HIMMEL_WORKER_SESSION_TABS=1 claude`, and every worker
session it dispatches opens as a tab in one Konsole window per chief instead
of a separate window each. The switch passes to successor chiefs through the
environment. Unset, every launch is unchanged.

- The first worker opens the window. `headed-arm.sh` records that window's pid
  in its lock directory as `tabs-<chief name>.window`. Each later
  worker opens as a new tab in it over Konsole's D-Bus (`qdbus6`
  `/Windows/1 newSession`), titled with the worker's session name.
- The tab's process is the worker itself, so closing a worker
  (`close-wrapped-worker.sh` stops its claude process) closes only its tab. A
  crashed worker leaves only its own tab dead. The window and the other tabs
  stay up either way.
- A worker falls back to a window of its own, never lost, when the recorded
  window is gone (that new window becomes the chief's window), when D-Bus
  fails (a `WARN: tab launch` line in its launch log), on macOS, for chief
  arms, and when `HIMMEL_CONSOLE_NAME` is unset.
- The window keeps the first worker's `HIMMEL-` tab title, so the KWin rule
  that places new `HIMMEL-` windows still matches it.
- Limits: two workers dispatched at the same instant before any window exists
  can open two windows. The tick's dead-window sweep closes a window only when
  nothing runs in it, so a dead tab beside live ones stays until you close it.

## Claudex workers: the inbox is the only channel

A `--lane claudex` worker (`headed-arm-worker.sh`) runs under
`~/.claude-codex`, which keeps it out of the session registry `ListAgents`
reads on both ends, so `SendMessage` reaches it in neither direction, even
though its socket is alive. The only channel either way is the file inbox
(`inbox-send.sh`): chief → worker is `inbox-send.sh <worker-session>
--file <path>`, delivered as `PostToolUse`/`SessionStart` additionalContext on
the worker's next tool call; worker → chief is the same script addressed to the
chief's own session name. `AskUserQuestion` reaches nobody on a claudex worker
while the operator is away; every claudex brief must say so and give the worker
the chief's exact session name.

Inbox delivery is **tool-call-gated**. Before ending a turn at BLOCKED,
READY, PR-READY, or a blocking question/PROBE ask, the worker arms ONE bounded
Monitor on `bash scripts/handover/chief-kit/inbox-follow.sh --wake
<handover-root>/inbox/<session>.md`, with `timeout_ms: 1800000`. Resolve the
root through `handover_root()` and use only the worker's own exact session name.
The supported API has no persistent flag. The worker re-arms on expiry for at
most eight windows/four hours per unresolved hold; unrelated wakes do not
reset the wall-clock cap. Full lifecycle, failure recovery and wrap rules:
[`worker-preface-claudex.md`](worker-preface-claudex.md).

The fixed wake envelope is data only: the worker makes a benign tool call to
receive the authoritative inbox hook delivery before acting. The follower's
`.md.cursor` never steals the hook's `.cursor/<session>` delivery cursor;
restart drains lines appended during a re-arm gap without normal replay.
Suppression can lose a wake, so expiry must trigger hook delivery too. The
short claudex idle-wake probe (n=1) is not a four-hour soak or a
cross-lane persistence claim. No registry or hook authority changes here.

## Rulings

A worker that hits something it cannot decide reports to the chief, not to the
operator. The chief verifies the finding itself, then answers.

Re-tasking a running worker goes through the **RETASK channel**: each dispatch
carries a fresh nonce, and a genuine revision is a direct message quoting it.
Expanding or redirecting a worker needs the token; narrowing it or halting it does
not. That asymmetry is deliberate, so a halt can never be argued away. Full
threat model and the verbatim block:
[`../internals/retask-channel.md`](../internals/retask-channel.md).

**A ruling that widens what a worker may do is refused by the worker's own auto-mode
classifier**, for example an extra push, or SKIP verdicts in place of a suite
that a guard blocked. The refusal is correct: a chief ruling is not user
consent. Narrow the ask instead (run each suite on its own, with no runner
flags), or do the step from the chief, for example push the worker's verified
head yourself and then tell it to continue.

**Address `inbox-send.sh` by the worker's real session name**, the `-n` it was
launched with (see its launch log). That name may lack the doc's date suffix.
A ruling sent to the wrong name is never delivered and raises no error, so run
`inbox-send.sh --pending` after sending.

**A PR parked at the round-3 review cap gets one more review round from the chief,
never from the worker**. Run
`scripts/handover/chief-kit/grant-round.sh <pr> <new-head> <qid>`. It grants
only on a signed judge record for that exact head, a PR that has reached the
cap, a head that is still the PR's live head, and a qid no earlier grant
consumed; one record buys one round. A worker or a relay is refused (exit 3). A
judge's NO-GO on a head that follows the reviewed one by a test-only or
comment-only commit is written with
`write-verdict.sh ... --bind-reviewed <reviewed-sha>`: the verdict
keeps naming the judged head and carries a signed `reviewed-head:` line, and any
other delta is refused with nothing written.

## Merges

`READY <pr> <head> GREEN` → the chief verifies independently (all check-runs
green at that exact head, zero unresolved review threads, attestation trailers
in the first commit) → `GO` → the worker merges and reports `MERGED #<n> → <sha>`.

<!-- mem:d21a0c8458ad -->
A worker's `READY`, or a predecessor's note that a PR is clean, is not
evidence: the chief is the reviewer of record, so it runs the checks before
every GO. A successor that takes over a PR mid-`READY` re-verifies it instead
of trusting the predecessor's GO.

The Jira close is the worker's call from the brief, not a default:
`merge-on-green.sh` transitions the ticket only on `--jira-transition`,
and the brief's Ship contract carries `completes-ticket: yes|no`:
`yes` → the worker passes the flag, `no` (the ticket spans further
PRs) → it omits it. After `MERGED`, re-read the ticket: the flag closes only the
first `[KEY]` of the PR title, so a multi-key PR needs its other ticket checked
by hand.

`scripts/handover/chief-kit/ready-check.sh <pr> <full-40-hex-head-sha>`
mechanizes that independent verification: it re-runs checks
1-6 (head match + clean merge state, statusCheckRollup all green, zero
unresolved review threads, an automated review ledger row for that head, attestation
trailers in the first commit, a ticket ID on every commit subject) and
prints `READY-CHECK PASS|FAIL`. It is read-only (no ledger rows, GO files,
or PR comments) and it does **not** read the three-dot diff; that judgement
call stays the chief's own, which the script says on its last line. On a
PR that is already `MERGED`, GitHub reports `mergeStateStatus: UNKNOWN`
permanently, so check 1 always fails there; that is expected, not a bug, and
the script's domain is a PR that has not yet merged.

<!-- mem:220565770e67 -->
GitHub's own `gh pr view <n> --json mergeStateStatus` is the authority on
whether a PR can merge; never infer it from the check runs. The latest run of
each check is right for reporting that check's state, never for deciding
mergeability.

`scripts/handover/chief-kit/ready-go.sh [--to <worker> --token <nonce>] [--ledger <chief doc>] <pr> <sha>`
is the whole mechanical READY turn in one call: the `ready-check.sh` output, the coverage line, the trust-path result, the ticket state and the exact GO line to send. It is read-only (no GO file, no message): `go.sh` and the SendMessage stay yours.

<!-- mem:7aba121571b0 -->
The automated review ledger is keyed by head sha, so **every push needs its own review
round**, even a one-line fix after a judge's NO-GO. A ruling of "no new
`/pr-check` panel" leaves check 4 with no row to find, and the marker-clear
script refuses when no critic answered at that head. Word the ruling as "one
`/pr-check` round at the new head; only Critical or Important findings block".

A PR on HIMMEL-2973/2976/2928/2974/2975 is READY only if its body cites
`HIMMEL-2977 "GATE <previous lever> PASS <date>"` (for 2973:
`P0 EXIT <date>`; this line carries no separate status word, and its mere
presence, verbatim, is the pass signal for 2973). Open HIMMEL-2977's comments
and find that citation's line verbatim: a missing citation or a line not
found is not READY; for the general `GATE ... <status> <date>` shape (every
ticket except 2973), a found line whose status is not PASS is also not READY.
The chief pulls the primary and the worker wraps (closing its ticket only if the
brief's `completes-ticket: yes` says the PR completes it).
The chief sends the GO file (merge approval) by first running `bash scripts/handover/chief-kit/go.sh
<pr> <full head sha>`. The file IS the GO; the SendMessage is the
notification: a worker launched by `headed-arm-worker.sh` carries
`HIMMEL_CONSOLE_LEG=1`, and `merge-on-green.sh` refuses it (exit 17) without a
GO for the exact head it certifies, so a push after GO needs a fresh one.
`go.sh` runs `ready-check.sh` itself and writes nothing unless
it passes (exit 4). A `--trust-reviewed <qid>` GO also needs the
judge's ``**GO** for head `<sha>`.`` verdict under `verdicts/<qid>/` (exit 5).

An opt-in auto-merge stops at "awaiting approval" wherever branch protection requires
a review the automation identity cannot give. On a single-maintainer repo the
only path through is the admin bypass, which the merge script refuses by
design, so the chief hands the merge to the operator and sends `MERGED`
back when it lands.

### Fork PRs (himmel adapters)

A PR on a fork we own merges only when the repo is listed with `merge_allowed`
true in `scripts/guardrails/himmel-adapters.json` (read from the default branch,
so a worktree edit cannot widen it) and the PR targets that entry's
`himmel_branch`. Run the judge, then, from the primary checkout:

1. `bash <anchor>/scripts/handover/chief-kit/go.sh --repo <owner/repo> --trust-reviewed <judge-qid> <pr> <head>`
   (exit 6 not allowlisted or the harness repo itself, 7 PR not OPEN, CLEAN and on the adapter branch at that head
   or a review thread still open, 5 no signed judge GO).
2. `bash <anchor>/scripts/handover/merge-fork-pr.sh [--jira-transition] <owner/repo> <pr> <head>`
   (chief only; a bare `gh pr merge --repo <fork>` stays refused; pass `--jira-transition` when the brief says `completes-ticket: yes`, and send the worker its `jira-transition=` line).

Both scripts require GitHub's `mergeStateStatus` CLEAN (every check at the head
passed, no conflict, up to date) and zero unresolved review threads, so a PR
with pending or red checks gets no GO and no merge. A push after the GO needs a
fresh GO.

## Handing over

Chiefs hand over at **45 % context fill, or 90 k input tokens in one turn**.

```bash
/chief next --arm --doc <this chief's own doc> --bucket <its bucket> --prefix <its prefix> --model <its model>
```

**Name your own document, bucket, prefix and model explicitly.** Without
`--doc`, `next` hands over from the highest-lettered doc it can find, which is the
wrong one as soon as another `new` has run or a successor already exists;
without `--bucket` and `--prefix` it re-resolves those from the environment
and writes the successor into the wrong bucket, or under the wrong key;
without `--model` it re-resolves the model from `CHIEF_MODEL` or the
built-in default instead of continuing on the model this chief itself runs
on. The rendered chief doc carries the exact command with all four already
filled in.

`next` writes the successor stub (letter bumped, pointed at this chief and
its HANDOFF) and the predecessor's `-HANDOFF.md` skeleton, and arms the
successor on a signal file. The letter rolls past Z in bijective base-26 (Z →
AA → AB → … → ZZ, then refuses) instead of ever refusing at Z; pass `--date
<YYYY-MM-DD>` to pre-mint tomorrow's first chief (`A`) immediately, near
midnight, instead of waiting for the date to roll over. Fill in the HANDOFF
(head, what is in flight worker by worker with nonces and lock tokens, rulings made,
the held queue in launch order, what wrapped), then `touch` the signal path
that `next --arm` printed and hand your live workers over by name.

**Re-brief your live workers before you release**. Each
worker's brief names *you* as its chief, and a successor is a different session
on a different socket: the successor names itself to you during its ACTION ZERO,
you relay each worker to it from your own session, never by hand: `next` leaves a
chief with a bus identity a `WAKE relay-on-live` (or run `chief-kit/relay-batch.sh <this doc>
--successor <it>`). That run sends each native worker one himmel-bus relay record naming
the successor (the bus proves you sent it, so the record carries no token), and each claudex
worker its inbox relay plus the bus record its `bus adopt` needs. A native record that
fails, or a chief with no bus identity, prints a `SENDMESSAGE` line quoting the worker's
token for a worker in Live state: send it from your own session. A failed claudex
notice record prints only `BUS-RELAY-FAIL`: that worker already has its inbox relay. A
worker in the fleet manifest but missing from Live state prints `NOT-IN-LIVE-STATE` when
its record fails, when the chief has no bus identity, when it is a claudex worker, or
when its session does not resolve: relay it by hand if it is live. `SKIPPED`, `UNRESOLVED` and
`UNRESOLVED-LANE` lines sent nothing: each needs a relay by hand. So does a `FAILED-INBOX` line (its claudex inbox send
failed). `BUS-RELAY <label> ok` means the bus stored the record, not that the
worker saw it: delivery needs the worker's `HIMMEL_BUS_NAME` hooks, so the
successor's `WAKE succession partial` is the backstop for one that never quotes back. The worker
session's quote-back is the `SUCCESSION accepted` Results bullet in its own doc (the successor's
waiter tallies it); it sends a `SendMessage` only on a timeout or a decline. That run is the
relay: never re-run it (a retry resends the claudex inbox relays). Unless you pass
`--fresh <label>=<token>`, it never carries a fresh token, and a relay with none is
complete (the worker keeps its own): native and claudex workers are not rotated on a
bus succession, and `WAKE relay-on-live` passes no `--fresh`. A successor that issued fresh
tokens has the outgoing chief run `relay-batch.sh <this doc> --successor <it>` with one
`--fresh <label>=<token>` per worker instead: the `SENDMESSAGE` line and the claudex inbox
relay quote the held token and the fresh one, and a native worker owed a fresh token gets
that `SENDMESSAGE` rather than a bus record (a bus record is token-free). A claudex worker's
bus record is sent right after its inbox relay. `FRESH-UNUSED <label>` means no relayed
worker took that token: hand it over. It prints `RELAYED <n> of <m>` last, and n
counts its `SENDMESSAGE` lines: send those relays first, then that line to the successor,
naming every worker still unrelayed (n alone does not say which). A batch that fails or
times out (`WAKE relay-on-live ... relay-failed rc=<n>`) prints its partial output and no
`RELAYED` line. On `relay-failed`, relay by hand every worker with no `BUS-RELAY <label> ok` or `SENT-INBOX` line,
then send `RELAYED <n> of <m>` yourself, n the delivered lines.
The quote-backs are the successor's to tally; you do not wait for them.
A successor that arrives after you have left can prove itself only with the
two-token chain form; a worker that cannot verify that is stranded (it keeps
working and can still be merged, but cannot be re-scoped). The successor's
tick reads `nonces=UNCONFIRMED:<worker>` until each worker's own `SUCCESSION
accepted` bullet names the successor (`RELAYED:<worker>`, a relay that kept the
worker's token, is valid) or the worker has rotated.

**Release your lock only after the successor reports `LIVE`.** It sends that
once your `RELAYED` line arrives (naming the workers you could not relay, and
why: ACTION ZERO step 9), and it is the only evidence the arm actually fired
and the successor completed ACTION ZERO; releasing on the `touch` alone leaves
an unattended fleet if the launch failed. Relay each worker it names as not relayed by
hand before you wrap. A relay delivered is enough: a worker
drains it at its next tool round whether you are live or gone (S1), so you wrap
without waiting for the quote-backs; workers that did not quote back are named
on the successor's informational `WAKE succession partial`.

<!-- mem:8d14bb881ebb -->
A session's "safe to exit" is not evidence either. Before you exit a detached
session, commit and push its work, `TaskStop` any monitor it left running, and
confirm it has no live descendants
(`bash scripts/handover/wrap-subtree-check.sh --queue-doc <doc>` prints
`CLOSABLE:`) and no orphaned shell, which that check cannot see once it is
reparented (`bash scripts/handover/chief-kit/orphan-loops.sh --list` shows no
`owner=orphan` row; it counts only wrappers older than 30 minutes); an exit
with a worker still running orphans its uncommitted work.

**Wrap only with no subagent still running**. An in-process
subagent, a judge subagent above all, dies with its parent session and its verdict
with it. Wrap with `chief.sh wrap <your doc> <release-token> '<line>'`: it
writes `WRAPPED` and releases the lock, and refuses (exit 4, nothing written)
while `chief-kit/live-subagents.sh` finds a running child of this session or
cannot tell. The successor's `close-wrapped-worker.sh --chief` holds the same
line from the outside: exit 7 means the predecessor still has a live subagent;
retry once it finishes. Every judge subagent persists its verdict with
`write-verdict.sh` under `verdicts/<qid>/`, trust path or not, and the HANDOFF
lists the open judge subagents (`next` fills in the children still running), so a
successor reads a verdict instead of re-running the judge.

How a live subagent is detected from outside its session: Claude Code writes
`<projects>/<proj>/<session>/subagents/agent-<id>.meta.json` when it launches a
child, and appends a `queue-operation` enqueue of the child's
`<task-notification>` (carrying `<task-id><id></task-id>`) to the parent
transcript the moment the child stops, whether or not the parent ever reads it.
A child with a registry entry and no later completion record is running. A
foreground child completes with its `tool_result` instead. The process tree
cannot see a subagent (it is not a process), and the `tasks/<id>.output` links
outlive the child.

The HANDOFF is the successor's only required read. Written properly, the succession
does not need the predecessor's transcript at all.

<!-- mem:606678f8c0a1 -->
Its list of running things is a snapshot, though. Before you pass on a "close
these windows" or "still open" line, or any other claim about live sessions or
workers, run `ListAgents` or `pgrep -af 'claude .*-n <prefix>'`; check a
monitor or a suite by its own task id or pid. Name only what is actually live;
by the time a successor reads the doc, the operator has usually closed them.

## Switching the Claude account

An account switch is a machine-level login: one active Claude account per
machine, so it changes the subscription usage budget every worker and chief draws on,
not any routing. Do it at a boundary, in this order.

**1. Before the switch, bring the workers to a boundary.** Let each worker reach a
milestone (`READY`, `FINDING`, `RESOLVED`) or `WRAPPED`; do not switch mid-turn on
a deep-context worker. The cost is not yet measured: the prompt-cache audit
([`../internals/prompt-cache.md`](../internals/prompt-cache.md), row 11) marks
"an account switch rewrites the full prefix of running sessions" **UNVERIFIED**.
Its live run L5 was a weekly usage budget reset on the *same* account, not a switch: 2
sessions kept their prefix, 0 invalidated, 0 compacted (a chief reading about
318k tokens from cache stayed warm). So a real switch is still untested. If it
does invalidate, expect each live session to re-pay its whole prefix, which is
why a worker parked at a boundary is cheaper than one switched mid-turn. Record what
you see (re-run `invalidation --event <switch ISO>` from that doc's "Re-run").

**2. Decide every armed resume.** List the jobs, find the `HIMMEL-Resume-*` ones
(`at -c <job-id>` shows the marker), and keep or cancel each: one armed for the
old account's reset fires against the wrong subscription usage budget:

```bash
atq
atrm <job-id>
```

`auto-arm-on-cap.sh` re-arms a resume on the next tool call once any window is at
or above `AUTO_ARM_THRESHOLD` (default 90 %) and none exists, so an `atrm` made
early can be undone before you finish. **Cancel last:** after the workers are
parked and as the final action of the session, or from a plain terminal.

**3. After the switch, refresh the usage cache.** The cache is stamped with the
account that wrote it; `usage-preflight.sh` reports `BANK-UNKNOWN` while the
stamp does not match the logged-in account. Force
one re-derive, then confirm the new numbers:

```bash
USAGE_FORCE_REFRESH=1 bash scripts/statusline/usage-cache-producer.sh <<< '{}'
bash scripts/lib/usage-preflight.sh
```

Pass: `usage-preflight` prints the new account's `five_hour` / `seven_day` and
`PROCEED` (or `SKIPPED-BANK` if that account is genuinely high). `BANK-UNKNOWN`
means the cache is still the old account's; refresh again, or check the login.

**4. Confirm the weekly budget override voided itself.** An override is bound to the
account that set it, so it is no override under the new login; only the operator can
set one (`usage-lift.sh set`). Verify:

```bash
bash scripts/lib/usage-lift.sh show
```

Expect `usage-lift: INVALID: account` after an account switch. Other invalid
reasons are `expired`, `window`, `trust`, `parse` (or `missing` when unset).
The doctor reports `lift set but INVALID: <reason>`. A stale file is harmless
and can be removed with `bash scripts/lib/usage-lift.sh clear`.

A one-window weekly budget override skips only the weekly ceiling; `five_hour` still binds.
Whole-second reset values tolerate up to one second of fractional API jitter,
not a different weekly window. Only the operator can enable the standing
"spend to 100 %" policy:

```bash
bash scripts/lib/usage-lift.sh set --standing
```

It records `standing:true` in the same operator-only, account-bound override file
(no new state path or hook bypass). The policy applies to every fresh window
for that account and defaults `CADENCE_USAGE_MAX_PCT` to 100 for launch checks.
An explicit ceiling still controls `five_hour`; either usage budget at 100 refuses,
so no launch starts on extra usage. Plain `set` replaces it with a one-window weekly budget override;
`clear` disables it. Agents must never run either form of `set`.

The Done-when for this change needs the operator to walk this once at a real
switch and record the result (and the cache-probe verdict from step 1) in the PR.

## Controlling the VM CI runner

Two VirtualBox VMs (`himmel-ci-1`, `himmel-ci-2`, cloned from the
`ci-runner-v3` snapshot, 4096 MB and 4 CPU each) can run the 8 ubuntu
shell-unit shards. The chief drives them with one script, each form a bare
relative literal pre-approved in `.claude/settings.json`:

```
bash scripts/handover/chief-kit/vm-runner.sh on            # both VMs
bash scripts/handover/chief-kit/vm-runner.sh on --vms 1    # or --vms 2
bash scripts/handover/chief-kit/vm-runner.sh off           # kill switch
bash scripts/handover/chief-kit/vm-runner.sh status
```

- `on` refuses (rc 3) unless the repo's fork-PR approval policy is
  `all_external_contributors`, clones VM 2 when missing, sets the
  `HIMMEL_VM_RUNNER` repo variable to `on`, removes `~/.himmel/ci-runner.stop`
  and starts one `himmel-ci-runner@<n>.service` user unit per VM. A unit that
  will not start switches the runner `off` again.
- `off` sets the variable `off` first (so GitHub stops routing to the VMs),
  writes the stop file and stops the units; a job already running is not
  re-queued but no new runner is minted.
- `status` prints the variable, per-VM up/idle/busy state and the last error.
- `tick.sh` carries `vmrun=<off | ok:<up>/<want>,busy=<n> | DEAD | STUCK | FAILING | DISAGREE:<up>/<want>,online=<n>>`.
  `DEAD` is variable on with no unit up; `STUCK` is a job running past its
  budget plus ten minutes; `FAILING` is a loop whose newest log line is an
  error, or a GitHub runner count that could not be read; `DISAGREE` is more units
  with a registered, unfinished runner than GitHub shows himmel-vm runners
  online (fewer online between jobs is normal and reads `ok`). `chief-wait.sh` wakes only on a move to `DEAD`,
  `STUCK` or `DISAGREE`; answer with `status`, then `off` and a note to the operator.
- With the variable `on`, `ci.yml` runs the `shell-unit-shard` matrix on the VM
  runner for a same-repo `pull_request` whose author and actor are the operator
  accounts; everything else (fork PRs, other authors, push, schedule, dispatch)
  and the variable `off` or unset run on `ubuntu-latest`, with the required
  check names unchanged. `scripts/ci/test-ci-vm-routing.sh` pins that
  expression. The routed shard's apt, sudo and pip steps run on GitHub-hosted
  runners only (`runner.environment == 'github-hosted'`); the guest must carry
  the tools instead (`guest-provision.sh`). **Keep the variable `off`** until the
  guest image has been rebaked with those packages (`ci-runner-v4`) and a
  `vm-runner-probe.yml` dispatch has passed with no operator PR CI running:
  until then every routed shard would fail and fail-fast blocks the PRs.
- A classifier denial of one of these commands means the allow rule is missing
  or mismatched; see the stuck playbook, never reshape the command.

## See also

- [`chief-template.md`](chief-template.md): the chief's operating contract
- [`chief-handoff-template.md`](chief-handoff-template.md): the handover skeleton
- [`worker-brief-template.md`](worker-brief-template.md): what a dispatched worker gets
- [`afk-mode.md`](afk-mode.md): the unattended-pipeline alternative
- [`../internals/retask-channel.md`](../internals/retask-channel.md): authenticated re-tasking
- [`../internals/lane-calibration.md`](../internals/lane-calibration.md): tiers, effort, wake-up budget
