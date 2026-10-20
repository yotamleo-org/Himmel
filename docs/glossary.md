# Glossary

The one place himmel's fleet vocabulary is defined. Everything else — templates, prefaces, command
files, guard messages, internals docs — links here instead of restating a
definition, because a term defined in two places drifts.

It holds two vocabularies: the fleet lexicon (sessions and their roles, below)
and the [harness wiring lexicon](#harness-wiring-lexicon) (the hooks, gates and
scripts that enforce the rules), with an [overlap map](#overlap-map) of which
layers enforce each invariant. Per-hook behaviour lives in
[`internals/enforcement.md`](internals/enforcement.md), not here.

## The lexicon

Each headword is the plain name people read in the docs and UI. The repo's own
name, the one that ids, env vars, file names, flags and command names use, is
the alias in brackets. Keep repo identifiers in code spans (`/console`,
`HIMMEL_CONSOLE_LEG`, `headed-arm-leg.sh`, `go.sh`). Repo identifiers are being
renamed to the plain names (HIMMEL-5689); every old name stays a read-both alias
for one release, listed in [Identifier aliases](#identifier-aliases).
In prose, say the plain name, and the old name once in brackets the first time.

| Term | Meaning |
|---|---|
| **Automated review** [CR, code review] | The pre-PR review gate and everything named for it: the review-owed marker (CR marker), the CR ledger, the critic panel, `/pr-check` (ruled 2026-09-24, operator). A human read of the PR is "human review". CodeRabbit is one best-effort CI reviewer inside that gate and is always spelled out, never abbreviated CR. |
| **Chief** [supervisor session, console] | The operator's chief of staff: a persistent, operator-facing session that owns the shift. It holds the queue lock on its own document, the GO authority and the token (nonce) mint. It dispatches workers, watches the fleet, acts on rulings and merges on GO, and does no implementation itself. `/console new` starts one today; `/chief` becomes the canonical command in slice V5, and `/supervisor-session` stays as a permanent alias. In prose say "the chief"; never "chief session" and never a bare "supervisor": `scripts/telegram/supervisor.ts` is a process keeper. |
| **Judge session** / **judge subagent** [judge, judge call] | A clean session, headed or headless, spawned for one question, sometimes on a deliberately thin brief. **Advisory: it rules, the chief acts.** Several may run in parallel on one question with different scopes. A judge session is a worker of the judge kind; a judge subagent is an in-process child. See [Judge: call and session](#judge-call-and-session). A judge verdict stays "judge verdict". |
| **Consolidator** | Combines several judges' outputs into one reconciled answer, so the chief does not absorb N judgments. A lexicon term only: nothing in the repo implements it yet. |
| **Relay** [communicator] | Transport. Receives and moves messages and owns the machine wakes. Also called the *communicator* in the design spec; the code name is `relay`. It is launched as a worker of the chief (`headed-arm-leg.sh --relay`), never as a chief. |
| **Worker** [worker session, leg] | A working item: one ticket, one worktree, one brief, one PR. The chief starts workers and each reports back to its chief. A worker has *kinds*: an implementing worker (implements and ships), a relay, and a judge session. `HIMMEL_CONSOLE_LEG` marks every chief-spawned worker of any kind. Fleet sense only: a bare "worker" is this one; a lane worker or a dispatched subagent worker is always qualified (see [Same word, different thing](#same-word-different-thing)). |
| **Dependency chain** [chain, ticket sequence] | A set of workers that must run in order, because each needs the one before it to merge (the Jira "is blocked by" link; GitHub Actions jobs joined by `needs:`). Fleet sense only; the hook chain and the token chain keep "chain". |
| **Parallel wave** [wave, batch] | A group of workers dispatched together: the unit that collision-checking, single-writer and `HIMMEL_FLEET_CAP` apply to. Argo CD's sync waves are the closest industry precedent. `batch mode` in a cadence script and a ledger batch row are other senses. |
| **Arming** [scheduled launch] | Launching a headed or headless session on a schedule (`arm-resume.sh`, `headed-arm.sh`, `/console new --arm`). |
| **Side session** [manual override] | An ad-hoc operator-side session: a whiteboard. It passes work to the chief as a ticket and a brief, never as a relayed ruling. |
| **Succession** [shift handoff] | One chief handing over to the next: the outgoing one arms its successor and writes a HANDOFF (`/console next`). Not a dependency chain: a dependency chain is workers. |
| **himmel-bus** | The local, hash-chained message bus between a chief and its workers (`marketplace/plugins/himmel-bus`). Delivery is by hook (`bus-deliver-hook`), and a message is a ruling only under a `from` header from the receiver's registered chief (see [RETASK §3b](internals/retask-channel.md)). It is not the Telegram bridge (`scripts/telegram/bus.ts` is that bridge's own store, which himmel-bus reuses for storage only) and not the file inbox (`inbox-send.sh`, the `handovers/inbox/` files), which stays the fallback transport. |

**Not roles.** *Orchestrator* is a rule (`orchestrator-inline-guard`: a
top-tier parent must not implement inline), not a session role; the word also
names a script (`scripts/worktree.sh`) and CI components. *Conductor* is
the cross-project layer, not a role in this fleet.

## Plain names for harness terms

The terms above are defined once, in the lexicon. This is an alias index for
the harness terms, which are defined in the
[harness wiring lexicon](#harness-wiring-lexicon) under their repo names:
ids, env vars, file names, flags and command names carry those names until
their HIMMEL-5689 slice lands (see [Identifier aliases](#identifier-aliases)). In prose for people, use
the plain name, and say the old name once, the first time, in brackets.

| Plain name | Old name (alias) | Notes |
|---|---|---|
| **auto-ship step** | leg (initiative sense) | A step `HIMMEL_INITIATIVE` takes by itself, such as prcheck or merge. |
| **usage** | bank | `PARKED-BANK` and the `CADENCE_BANK_*` variables are renamed by HIMMEL-5689 slice V1; old names work until the removal release. |
| **weekly limit override** | bank lift | Renamed by slice V1. |
| **review-owed marker** | CR marker | |
| **finding status** | verdict (of a CR finding) | A judge verdict stays "judge verdict". |
| **variant sweep** | class sweep | Replaces the 10-17 interim name "sibling sweep". Named for CodeQL's "variant analysis". The `SWEEP` ledger keyword is unchanged. |
| **review round** / **diff-only round** | round / delta round | Docs only. The printed `pr-check:` line is unchanged. |
| **GO file (merge approval)** | GO file | The other GO is written "judge verdict GO". |
| **off switch** | bypass flag | Never "bypass" alone: `bypassPermissions` is a different thing. |
| **sanctioned script** | chokepoint | Docs only. |
| **warn-only** | advisory | |
| **worker system prompt** | preface | There are five prefaces (worker, worker claudex, worker openrouter, judge, consult). |
| **usage-cap auto-relaunch** | watchdog | Only where the README, getting-started and why-himmel mean the auto-arm hooks. A wall-clock killer is a "run timeout". |
| **AFK (unattended) mode** | overnight mode | `/overnight-shift` and `overnight-mode.md` are renamed by slice V3 (`afk-shift`, `afk-mode.md`); old names work until the removal release. |
| **soft block (speed bump)** | speed bump | Stops only the accidental form. |
| **revision** | RETASK | The `RETASK` block keyword stays: code parses it. |
| **token** | nonce | "Nonce" stays an alias here; ids keep it. |
| **scheduled launch** | arming | `arm-resume.sh` and `ARMAUTOMERGE` keep their names. |
| **shift handoff** | succession | `succession-tracker.sh` and `succession.md` keep their names. |

Not renamed on purpose: handover (the command, the directory and the doc keep
the word; "handoff" already has four senses), attestation trailer ("trailer" is
git's own term), floor, anchor, lane, queue lock. The identifiers that stay are
listed under [Do not rename](#do-not-rename).

## Identifier aliases

Rename plan: HIMMEL-5689. Names ruled 2026-10-20 (operator): chief, worker, dependency chain, parallel wave.
The rest follow the HIMMEL-5689 plan. A row is a plan until its slice merges: until then only the old name
exists. Each old name keeps working through the
alias mechanism below until the removal release, the release after v1.1.3.
Mechanisms: **env** = read-both via `scripts/lib/env-alias.sh` (`alias_env NEW OLD`;
writers export both; a guard keyed on an identity marker uses `env_alias_any`
and denies when either name is set); **wrapper** = a script at the old path that
`exec`s the new one; **symlink** = the old directory links to the new one;
**command alias** = a slash-command file forwarding to the new one.

| Family | Old name | New name | Slice | Alias mechanism | Removed in |
|---|---|---|---|---|---|
| F1 | `HIMMEL_CONSOLE_LEG`, `_RELAY`, `_JUDGE` | kept (OD-1): historical prefix, set only by launchers; the chief and its workers carry it | — | none | n/a |
| F1b | `HIMMEL_CONSOLE_{DOC,NAME,WORKDIR,RUNDIR}`, `HIMMEL_CONSOLE_JUDGE_{DOC,QID,EFFORT}` | kept (OD-1) | — | none | n/a |
| F1c | operator-typed `CONSOLE_*` (`CONSOLE_FG_OK`, `CONSOLE_DISPATCH_OK`, `CONSOLE_DISPATCH_DISABLE`, `CONSOLE_CONTEXT`, …) | `CHIEF_*` | V5 | env | release after v1.1.3 |
| F2 | `HIMMEL_LEG_*`, `HIMMEL_LEAN_LEG`, `LEG_*`, `HEADED_ARM_LEG_*` | `HIMMEL_WORKER_SESSION_*`, `HIMMEL_LEAN_WORKER_SESSION`, `WORKER_SESSION_*`, `HEADED_ARM_WORKER_*` (never `HIMMEL_WORKER_*`) | V4a | env | release after v1.1.3 |
| F3 | `CADENCE_BANK_*`, `BANK_LIFT_*`, `CODEX_BANK_*`, `CLAUDEX_BANK_*`, `PARKED-BANK` | `CADENCE_USAGE_*`, `USAGE_LIFT_*`, `CODEX_USAGE_*`, `CLAUDEX_USAGE_*`, `PARKED-USAGE` (usage, not budget) | V1 | env; the marker token is accepted in both spellings, the old one is emitted until the removal release | release after v1.1.3 |
| F4 | `bank-preflight.sh`, `bank-lift.sh` (+ `bank-lift.json`), `bank-monitor.sh`, `bank-attribution.sh`, `bank-status` | `usage-*` | V1 | wrapper | release after v1.1.3 |
| F5 | `clear-cr-marker.sh`, `cr-*.sh`, `CR_MARKER*` | `clear-review-marker.sh`, `review-*.sh` (the CodeRabbit scripts to `coderabbit-*`), `REVIEW_MARKER*`; the `<git-dir>/cr-pending/` dir keeps its name (OD-3) | V2 | wrapper; env | release after v1.1.3 |
| F6 | `headed-arm-leg.sh` | `headed-arm-worker.sh` | V4b | wrapper | release after v1.1.3 |
| F7 | `leg-*.sh` helpers, `leg-digest*`, `close-wrapped-leg.sh`; profiles `leg-impl`, `leg-bus`, `leg-vm` | `worker-*`, `close-wrapped-worker.sh`; profiles `worker-impl`, `worker-bus`, `worker-vm` | V4b; V4a (profiles) | wrapper; the profile flag accepts both | release after v1.1.3 |
| F8 | `scripts/handover/console-kit/`, `leg-preface*.md`, `console-template.md`, `leg-brief-template.md` | `scripts/handover/chief-kit/`, `worker-preface*.md`, `chief-template.md`, `worker-brief-template.md` | T; M (the directory) | symlink; the launcher reads both preface names | release after v1.1.3 |
| F9 | `/console`, `console.sh`, `console-context.sh`; skills `himmel-ops:console`, `himmel-ops:supervisor-session`; agents `console-judge`, `console-judge-ro` | `/chief` canonical, `chief.sh`, `chief-context.sh`; skill `himmel-ops:chief`; agents `judge`, `judge-ro` (never `chief-judge*`). `/supervisor-session` stays a permanent alias | V5 | command alias; wrapper; the dispatch guard reads both agent ids, exact match | release after v1.1.3 (`/supervisor-session` never) |
| F10 | `overnight-shift`, `overnight-mode.md`, `OVERNIGHT_*`, `HIMMEL_OVERNIGHT`, `HIMMEL_INITIATIVE_OVERNIGHT` | `afk-shift`, `afk-mode.md`, `AFK_*`, `HIMMEL_AFK`, `HIMMEL_INITIATIVE_AFK` | V3 | command alias; env; redirect stub | release after v1.1.3 |
| F11 | `watchdog` (auto-arm hooks only) | `auto-relaunch` in prose; ids deferred to the removal-release review | — | none yet | n/a |
| F13 | `class-sweep`, `missing-class-sweep` (the `SWEEP` ledger keyword is unchanged) | `variant-sweep`, `missing-variant-sweep` | V2 | env; the exit reason is accepted in both spellings | release after v1.1.3 |
| F14 | `speed bump` (message text) | `soft block` | D | none; text only | n/a |
| F15 | fleet-sense `chain`, `wave` (and the interim `ticket sequence`, `batch`) | dependency chain, parallel wave: glossary and prose only; no fleet-sense identifier exists. Reserved forms: `DEPENDENCY_CHAIN_*`, `PARALLEL_WAVE_*` | R2, T, D | none; text only | n/a |
| F16 | tick fields `legs=`, `legset=`, `bank=` | `workers=`, `workerset=`, `usage=`; `tails=` and `parked=` keep their names | T | the waiter reads both | release after v1.1.3 |
| F17 | hooks `block-leg-askuserquestion.sh`, `guard-leg-wakeup.sh`, `console-compact-reinject.sh`, `guard-console-foreground.sh` | `block-worker-askuserquestion.sh`, `guard-worker-wakeup.sh`, `chief-*` | V4a; V5 | forwarders until the operator settings step | release after v1.1.3 |

F12 (`chokepoint-*`, docs-only) is on hold. Session-name suffixes (`-console`,
`-relay`, `-N<k>-`, `-judge-<qid>`) are data contracts and are not renamed;
`-chief` may only be accepted in addition.

## Do not rename

Names that stay as they are, and why. A rename slice and the old-term lint skip them.

| Name | Why it stays |
|---|---|
| The `HIMMEL_CONSOLE_*` prefix (OD-1) | Identity markers set only by launchers and typed by no operator. Renaming them touches the strip, deny and needle sites and the guards that read them, which is one high-risk slice (V5-ID), held unless the operator overrules. |
| **`HIMMEL_WORKER`** | The dispatched-lane security marker (hook integrity, the GLM write fence, the claudex spawner). A worker does not carry it, so a worker name must never start with `HIMMEL_WORKER_` unless `SESSION_` follows. |
| The `<git-dir>/cr-pending/` dir (OD-3) | An on-disk name nobody types, with readers in three languages; one missed reader fails open on `gh pr create`. |
| The `RETASK` block keyword | Code parses it. Prose says "revision". |
| The `leg-burn:` PR-body line, `SWEEP` ledger rows, tick `tails=` and `parked=` | Data contracts. |
| The Results markers (`LIVE`, `WRAPPED`, …) | Data contract; `PARKED-BANK` is read-both, not dropped. |
| `2026-07-28-chain-ledger.md`, frozen fixtures (`*/fixtures/**`) | Recorded data. |
| The session-name suffix `-console` | A data contract (`-chief` is accepted in addition). |
| The initiative chain `legs.sh` / `resolve_legs` | The auto-ship step sense, not the fleet sense. |
| The hook chain (`RUN_HOOK_CHAIN_*`, `--chain`) and `/himmel-update`'s "dependency chain" | Other senses of chain. |
| Lane-worker files (`stop-worker.sh`, `await-glm-worker.sh`, `reconcile-workers.sh`) | Other sense of worker. |
| `console-judge-ro` until the dispatch guard reads both ids; `/supervisor-session` | The old id is read-both until then; the command is a permanent alias. |

## Who holds what

| Authority | Chief | Judge session | Judge subagent | Relay | Worker |
|---|---|---|---|---|---|
| Queue lock on the **chief's** document | yes | no | no | no | no |
| Queue lock on its **own** document | yes | yes | no (in-process child: no document, no lock) | yes | yes |
| Run `go.sh` (write a GO) | yes | no | no | no | no |
| Mint a token (nonce), send a token-quoting message (`inbox-send.sh --token`) | yes | no | no | no | no |
| Send tokenless messages (narrowing, halt, RUN notes) | yes | no | no | yes | to its chief |
| Rule on a question | acts on the ruling | rules, advisory | rules, advisory | never | escalates |

A judge session is a worker kind, so it inherits the worker guards; a judge
subagent runs inside the caller's process and holds nothing of its own.

`go.sh` refuses under `HIMMEL_CONSOLE_LEG` (every chief-spawned session) and
under `HIMMEL_CONSOLE_RELAY`; `inbox-send.sh` refuses `--token` under
`HIMMEL_CONSOLE_RELAY`. The RETASK channel that these tokens belong to is in
[`internals/retask-channel.md`](internals/retask-channel.md).

## Judge: call and session

A judge is a **worker kind**: a *judge session*. A judge session is launched by
the worker launcher (`console-kit/headed-arm-leg.sh --judge`), runs under the
worker guards, and carries the same `HIMMEL_CONSOLE_LEG` identity variable as any worker, plus a
`HIMMEL_CONSOLE_JUDGE` identity variable that `scripts/hooks/guard-judge-writes.sh` reads
to confine its writes to its own doc and qid; it cannot write its
own GO. What differs from an implementing worker is the job: it reads, verifies, writes one verdict file and stops. It
does not implement, push or merge.

| Shape | What it is | Brief |
|---|---|---|
| judge **session** | a judge worker with its own worktree, queue lock and lifecycle; survives past one turn | [`handover/judge-brief-template.md`](handover/judge-brief-template.md), verdict per [`handover/verdict-template.md`](handover/verdict-template.md) |
| judge **subagent** [judge call] | an in-process child (`.claude/agents/console-judge-ro.md`, or `console-judge.md`) for one question that fits in one dispatch | the dispatch prompt |

The chief template (`console-template.md`) records which shape asked each question as
`grade: call|session`.
`grade: call|session`.

## Session-name suffix contract

Session names carry the role, and tooling reads it back:

| Name contains | Meaning |
|---|---|
| `-console` | a chief (`<PREFIX>-nextleg-<date><letter>-console`); `-chief` may be accepted in addition |
| `-relay` | a relay |
| `-N<k>-` | a worker (session `<TICKET>-N<k>-<slug>`, doc `<TICKET>-N<k>-<slug>-<date>-RESUME.md`, label `N<k>`, a successor `N<k>b` is a distinct session; the legacy `…-leg[N]<k>-…` doc spelling is still read — `scripts/lib/leg-identity.sh`) |
| `-judge-<qid>` | a judge session (`HIMMEL-<ticket>-judge-<qid>`) |

The scorecard classifiers (`scripts/lanes/bench/scorecard/`) read a worker from
`scripts/lib/leg-identity.sh` (so a worker whose slug says `console` is still a
worker), key a chief and a relay on the `-console` and `-relay` substrings, and
count an untitled session as `unattributed`; `verdict-template.md` keys on
`-judge-<qid>`. Renaming a suffix silently misclassifies burn data.

## Lane

A **lane** is a dispatch backend a worker or subagent runs on (`--lane
native|claudex`, the Codex lane, the critic and bulk lanes); `/lanes` prints
the set available on this machine. It is not a role, and not a parallel wave.

## Planning model

How work is grouped, sized and shipped. The layers, widest first:

| Term | Meaning |
|---|---|
| **Sector** | An abstract, cross-version area of the system, wider than any one feature (example: an "identity" sector holds RBAC and users). It is neither a Jira epic nor a Jira Component (a Component is one concrete part, such as the frontend or one module). A sector matures as its epics' features become usable. In Jira (being rolled out): a single-select **Sector** field for the primary sector, and `sector2-<name>` labels for secondary ones. Sectors are optional for adopters; each project may define its own list. |
| **Epic** | One capability inside a sector, built in phases across versions: a deliverable body of work with its own done-condition, never a container for a whole sector. Every epic has one primary sector, plus secondary sectors only when the match is strong. Its tickets form a dependency chain, ordered with `blocks` links. |
| **Ticket** | A Story, Task or Bug: one phase or increment of an epic, or a standalone piece of work that the Sector field alone groups. One ticket = one worker = one worktree = one PR. |
| **Subtask** | A step that shares its ticket's PR. |
| **Version** | A focus bucket: a mix of phases from several sectors, with a soft cap of about 40 tickets. Every goal in it is near, real and backed by a proof of concept. A ticket carries a fixVersion only once a version pulls it; the rest wait in their sector's backlog. A version ships on a P80 target date (from `effort-assess`) **and** scope: on the date, what is Done ships, and the rest rolls to the next version unless a must-have is still open. Each release records planned versus delivered. |
| **Intake** | How work enters a version once it is planned. Urgent work enters with a same-size swap. Derived work enters only if it blocks the version's done-condition, otherwise it goes to its epic's backlog. New ideas wait in an intake queue for the next planning. A bump always names its reason: blocked, swapped, over-estimate, superseded or proof failed. Work may also enter by using up the planning buffer; when the buffer is gone, the version is cut and the next one opens. |
| **Cap gate** | The check `jira create` runs when a ticket would land in the current unreleased version: with 15 open `residual` tickets in it (a `residual-budget:N` line in the version description overrides the 15), the filing is refused unless `--over-cap <reason>` is passed, which labels the ticket `over-cap` and records the reason as a comment. An `operator-directed` ticket is exempt. A Bug with no `--fix-version` goes to the next version instead of a full current one. `--follow-up-of <key>` stamps the `residual` label and links the parent, so every follow-up is counted. A version past the cap flips the board's `--changed` signal. |

**Maturity ladder.** A feature, and through its features a sector, climbs:
Idea → POC → Usable → Proven (end-to-end or on a VM) → Hardened (monitored
and wired into the checks that keep it working).

**Ticket lifecycle.** Jira statuses are moving to follow the dev loop: dispatch → live
worker → PR → review → CI → waiting for GO → merged → wrapped. The
dependency graph is not a status: it is checked before a ticket is pulled or
dispatched, and feeds its priority and availability.

**The sectors.**

| Sector | Covers |
|---|---|
| Fleet orchestration | Chief and workers, lanes and model routing, delegation and briefs, the message bus. |
| Ship loop | From commit to merge: review, CI, GO, merge, and the attestation gates. |
| Safety & enforcement | Guards, the structural permission layer, hook and settings wiring. |
| Cost & efficiency | Usage banks, token cost, budget planning. |
| Visibility | Observability and failure feedback, the fleet UI, the Telegram side of remote ops. |
| Quality & proof | CI and test infrastructure, station and VM ops, tool evals and dependency bumps. |
| Deployment | Install, setup, update, uninstall, and the config UI and CLI. |
| Knowledge & steering | Retrieval (qmd, graphify), the luna vault and knowledge capture, steering docs and skills. |
| Planning & tracking | Jira and roadmap tooling, the version model, the ticket standard. |

## Industry terms

Where a himmel word maps onto a term in the
[Dictionary of AI Coding](https://github.com/mattpocock/dictionary-of-ai-coding),
or onto a term another framework or tool coined, this row names it instead of
redefining it.

| Industry term | In himmel |
|---|---|
| Automated check | A gate: a hook, a pre-commit or pre-push check, a CI job. Deterministic, pass or fail. |
| Automated review | The critic panel and `/pr-check`. An agent reviews another agent's work, so it is not deterministic and it is not a check. |
| Human review | The operator reading a PR. Write it out, never "CR". |
| Handoff, handoff artifact | A handover doc, a RESUME doc or a HANDOFF file. The artifact is a secondary source: verify it against the code. |
| Compaction, autocompact | The summary Claude Code writes when the context fills. `Compact instructions` in `CLAUDE.md` steer it. |
| AFK | A session left unattended. Overnight mode and arming are two ways to start one. |
| Subagent | A judge call or an `Agent` dispatch. In the dictionary a subagent cannot spawn another; himmel allows deeper trees under the spawn-depth cap in the environment. |
| Progressive disclosure | Lean-invoke: a slash command run on demand instead of an always-loaded rule. |
| Smart zone, attention degradation | Why a worker hands off before its context is full (`internals/leg-context-guard.md`). |
| Primary source, secondary source | The code and tests are primary. A handover doc or a memory line is secondary. |
| Software factory | What himmel is: sessions started by triggers, with at least one human approval per PR. It is not a dark factory, which has no human step. |
| AX | `internals/context-architecture.md`: what a session sees, what loads always and what loads on demand. |
| Memory system | `MEMORY.md` plus its topic files. The index routes; it does not store. |
| Supervisor (LangGraph) | The chief. LangGraph's `langgraph-supervisor` names the agent that routes work to worker agents, which is why `/supervisor-session` stays a permanent alias of `/chief`. |
| Orchestrator-workers (Anthropic, "Building effective agents") | The chief and its workers: one session splits the job, workers do the parts, the chief synthesizes. Not himmel's "orchestrator", which is a rule (`orchestrator-inline-guard`). |
| Handoff (OpenAI Agents SDK) | There a handoff passes a conversation to another agent. himmel keeps "handover" for the command, the directory and the doc, because "handoff" already has four senses here (see Same word, different thing). |
| LLM-as-a-judge (Zheng et al., 2023) | A judge session or subagent: a clean model that rules on one question. |
| Sync wave (Argo CD) | A parallel wave: ordered groups whose members run together. |
| Variant analysis (CodeQL) | The variant sweep: find every variant of a fixed bug. |

## Same word, different thing

Some words in this glossary also have a second sense somewhere else in the repo.
The rows below are the ones that still do. Senses that were renamed to avoid a
collision are not listed: they now use the new wording.

| Word | What it means in this glossary | Other things it is used for | How to tell which one |
|---|---|---|---|
| **judge** | A judge session or subagent that rules on one question. A review by the CR critic panel is a "panel review", and an independent check in the token-economy docs is a "validator". | `follow-judge`, the judge pass of the X follow-list scorer. It is being renamed to follow-scorer (ticket to come). | A judge session writes a verdict file for the chief. The follow-list judge pass scores one account and feeds a queue. The charter is `marketplace/plugins/obsidian-triage/tools/follow-judge-charter.md` and the queue is `_judge-queue.jsonl`. |
| **chief** | The session that runs the shift (formerly supervisor session, console). | "Chief judge", a real title for the head judge. | The fleet docs and `/chief` mean the session. A title means the other, which is why the judge agent ids are `judge` and `judge-ro`, never `chief-judge*`. |
| **worker** | A worker: one ticket, one worktree, one PR (formerly worker session, leg). | A lane worker (a process on a dispatch backend: `scripts/lanes/stop-worker.sh`, `await-glm-worker.sh`), a dispatched subagent worker (`internals/worker-spawn-matrix.md`), a Codex lane worker, `reconcile-workers.sh` and `max_workers`. Also `HIMMEL_WORKER`, the dispatched-lane marker, which a worker does not carry. | A bare "worker" is the fleet sense; every other sense is qualified (lane, subagent, Codex lane). Worker env names are `HIMMEL_WORKER_SESSION_*`, never `HIMMEL_WORKER_*`. |
| **chain** | A **dependency chain**: workers that must run in order. A bare "chain" is never the fleet sense in new prose. | A serial hook chain and the hook runner's `--chain` flag; the token chain of a succession (`leg-sections/succession.md`); the handover skill's chain files (`next-session-N.md`, read by `arm-resume.sh`); `/himmel-update`'s six-item dependency chain; the dependency supply chain of package security (see the overlap map); the pin chain (`PIN_CHAIN_*`). | "Dependency chain" next to tickets or workers means the fleet sense. The `/himmel-update` docs and package security use the same two words for the other senses. Hooks, tokens and chain files always carry their qualifier. The hook sense is in `architecture.md` and `harness-compat.md`. |
| **wave** | A **parallel wave**: a group of workers started together. | The idiom "wave … through" ("a guard must not wave it through"); a subagent wave (`MID-AGENT-WAVE` in `auto-arm-on-subagent-cap.sh`, `FIRST_WAVE` in `lane-readiness.mjs`); Argo CD sync waves. | "Parallel wave", or a wave of workers or tickets, means the fleet sense. The idiom is a verb. A subagent wave is a burst of `Agent` dispatches inside one session. |
| **batch** | Not a fleet term any more: a group of workers started together is a parallel wave ("batch" was the 10-17 interim name). | `batch mode` in a scheduled script, a ledger batch row, a panel batch spec. | A fleet doc means a parallel wave. A script flag or a ledger means the other. |
| **armed** | Arming (scheduled launch): launching a session on a schedule. | Opt-in auto-merge (`ARMAUTOMERGE`). That use of "armed" is kept on purpose. Starting a Monitor loop is no longer called arming, and the tick now runs in `console-wait.sh`. | A session or a schedule means arming. A PR merge means the other. |
| **orchestrator** / **coordinator** | Not session roles. Orchestrator is a rule, `orchestrator-inline-guard`. | The external pattern catalog's names for the parent session. The CI orchestrator daemon. | A hook name means the rule. A pattern description means the catalog. A CI run means the daemon. The catalog is `orchestration-patterns.md` and the daemon is `scripts/ci-orchestrator`. |
| **GO** | The chief's GO file that authorises one merge. | A judge verdict `GO` or `NO-GO`, written by `write-verdict.sh`. It is one input the chief reads before it signs a GO file. | In prose write "judge verdict GO" for the verdict and "GO file" for the merge authorisation. The verdict format is in `handover/verdict-template.md`. |
| **supervisor** | The industry word for the chief ("supervisor session" is an accepted alias, and `/supervisor-session` stays a permanent alias of `/chief`). Never a bare "supervisor" in himmel prose. | `scripts/telegram/supervisor.ts`, the process that keeps the Telegram poller alive. Also a generic "external timeout or supervisor" in the shell docs. | A session means the chief. A bun process or a restart loop means the other. |
| **handoff** | A session passing its work to another: a handover doc, a RESUME doc, a HANDOFF file. | A scope handoff, a launch handoff, and the anchor handoff (`anchor-handoff.sh`). | The fleet docs mean the document. A launcher or a gate script means the other. |

## Harness wiring lexicon

The words the enforcement surface uses: deny messages, `scripts/hooks/`
headers and [`internals/enforcement.md`](internals/enforcement.md) (HIMMEL-5419).
One definition per term; a word under *Avoid* is a synonym to replace with the
canonical term. Script names without a directory live in `scripts/hooks/`.

### Mechanisms

| Term | Meaning | Avoid |
|---|---|---|
| **Hook** | A script an event runs. Six homes: a Claude Code hook (`.claude/settings.json`), a plugin hook (`marketplace/plugins/himmel-ops/hooks/hooks.json`), a Codex hook (`.codex/hooks.json`, through `.codex/run-hook.sh`), a git hook staged by `.pre-commit-config.yaml` (pre-commit, commit-msg, pre-push), the installed `reference-transaction` shim (`install-main-ref-transaction.sh`), and the installed single-writer `pre-push` shim (`install-single-writer-floor.sh`, which runs `check-single-writer-push-floor.sh`). The `i-have-adhd`, `lean-skills` and `qmd` plugins carry their own `hooks/hooks.json` too. Two homes sit outside those files: the `rtk hook claude` PreToolUse rewriter that `rtk init -g` registers in the user's `~/.claude/settings.json`, and the Hermes `parity_guard.py` hook that `scripts/hermes/assets/wire_parity_guard.py` wires into a Hermes profile. `SessionEnd` and `Stop` are events inside the homes above, not homes of their own. | trigger |
| **Wirer / inventory** | The two scripts that write hook entries, each from its own hand-kept ordered list (the inventory): `wire-hook-bash.mjs` (`EXPECTED_SCRIPT_ORDER`, into `.claude/settings.json`) and `wire-plugin-hook-bash.mjs` (`EXPECTED_HOOKS`, into the himmel-ops `hooks.json`). A wirer run installs an inventory entry its target lacks. | hook list |
| **Impostor** | A `scripts/hooks/*.sh` call under an event the wirer owns (`PreToolUse`, `PostToolUse`, `SessionStart`) that its inventory does not list; `wire-hook-bash.mjs` refuses it (HIMMEL-1552). | — |
| **Hook runner** | `run-hook-with-bash.js`: runs one hook, or a `--chain` of them in one process, under the right bash on every platform. The Codex twin is `.codex/run-hook.sh`. | wrapper |
| **Guard** | A PreToolUse hook that can deny a tool call before it runs (`block-*`, `guard-*`). It judges the call's text, not its effect. A `guard-` prefix or a "guard" in a file name does not mean this role: `stop-console-idle-guard.sh` is a Stop hook, `check-doc-guard.sh` is a pre-commit and pre-push gate, and `parity_guard.py` is a Hermes hook. | gate (for a session hook) |
| **Gate** | A check that stops work moving to its next stage: a git hook (commit, push), a CI job, or a precondition inside a chokepoint (the CR gate, the CI-green gate, the GO gate). | guard (for a git or CI check) |
| **Fence** | A guard that confines writes or egress to an allowed set and that the session cannot lift (the terminal write-fence, the egress fences, the judge write fence). It fails closed. | wall |
| **Speed bump** | A guard documented as stopping only the accidental shape; a determined caller can route around it (`block-himmel-config-writes.sh`, `guard-bus-store.sh`). Its header says so. | fence |
| **Floor** | The deterministic minimum that still holds when every other layer is absent: the destructive-command floor (`block-destructive-commands.sh`, shared by Claude and Codex) and the single-writer force-push floor (`check-single-writer-push-floor.sh`). | baseline |
| **Gate integrity** | A gate's own collaborators are fixed paths, never environment seams, so a contaminated environment cannot forge the evidence it reads. `clear-cr-marker.sh` and `merge-on-green.sh` carry a `GATE INTEGRITY` note: the CR ledger path, `check-ci.sh` and `gh` are not overridable there. | — |
| **Advisory** | A hook or check that prints and never blocks (exit 0): `scripts/cr/doc-freshness-advisory.sh`, `graphify-freshness-advisory.sh`, `jira-nudge-on-end.sh`, the `api` backend tier. | soft gate |
| **Nudge** | A hook that steers a habit rather than protecting a secret or a checkout (`require-quiet-run.sh`, `guard-leg-wakeup.sh`, `jira-nudge-on-end`, `inject-worktree-nudge`). Advisory-only versus may-deny is a separate axis, so both kinds count: some only print, some deny. A denying nudge fails open on its own errors (missing `jq`, unparsed input). Its opposite is a security fence, which fails closed. | — |
| **Watchdog** | A hook that watches a resource and acts on its own, deliberately fail-open: `auto-arm-on-cap.sh` and `auto-arm-on-subagent-cap.sh` arm a resume as a usage cap nears and block once to force a handover (off with `AUTO_ARM_DISABLE=1`). | monitor |
| **Chokepoint** | The one sanctioned script for a privileged action, registered with its seam variables in `scripts/chokepoints.json` (`merge-on-green.sh`, `clear-cr-marker.sh`, the codex dispatchers). Agents run it by its literal path. | wrapper, helper |
| **Seam variable** | An environment variable a chokepoint reads as a test seam or opt-in. Set only in the launching shell; a per-call `VAR=` prefix on a chokepoint is denied (`block-chokepoint-env-prefix.sh`). | override |
| **Bypass flag** | An environment variable that switches one guard off for a whole session, set in the launching shell (`EDIT_ON_MAIN_OK=1 claude`); a per-call prefix never reaches a hook process. Registry: `scripts/himmelctl/lib/bypass-flags.json`. | escape hatch |
| **Fail-open / fail-closed** | What a guard does when it cannot evaluate (missing `jq`, unparsable input): allow, or deny. Hygiene guards fail open, fences fail closed; `check-fail-open-lint.sh` lints the shape. | — |
| **Classifier** | Claude Code's auto-mode permission classifier: model judgement on a call no allow rule matched, denying by named category (`[CI Bypass]`, `[Merge Without Review]`, `[Out-of-Place Publication]`). Not a himmel script; `log-classifier-denial.sh` records its denials. Codex has none, and `block-terminal-write-fence.sh` stands in for it there. | the guard |
| **Allow rule** | A literal entry the native permission matcher compares against the command *text*. A `VAR=` prefix, a quote, `$(…)` or a compound drops the call to the classifier; `auto-approve-safe-bash.sh` approves the shapes the matcher refuses. | whitelist |
| **Hook integrity** | Every guard script pinned to its committed blob hash at session start (`record-hook-integrity.sh`); a pinned guard edited mid-session locks tool use. | — |
| **Shadow ledger** | `scripts/trust/shadow-ledger.mjs`: a passive, hash-chained record of every approval-shaped decision. It records and never denies. | audit log |
| **Trust path** | A path matching `scripts/ci/ci-trust-paths.txt` (CI, the merge gate and their helpers). A PR touching one merges through `merge-on-green.sh` only on a trust-reviewed GO (`go.sh --trust-reviewed`); the list is read from the default branch, never the PR. | protected file |

### Places and identity

| Term | Meaning | Avoid |
|---|---|---|
| **Primary checkout** | The repo's main working tree, the directory holding `.git`. No feature edits land there. | main repo, root checkout |
| **Worktree isolation** | The rule that feature work happens in a worktree (`.claude/worktrees/<slug>`), never on `main` in the primary checkout. | — |
| **Anchor** | The primary checkout's absolute path, from which gate writers run. `scripts/cr/anchor-handoff.sh` hands a relative entry over to the anchor's copy, so bytes a branch controls never run as the gate. | — |
| **Single-writer** | The rule: one writer per shared artifact, many readers. | — |
| **`.single-writer`** | A gitignored sentinel file at a repo root that lets that repo commit on `main` by design (vaults, state repos); clones without it stay protected. | — |
| **`.himmel-dev`** | A sentinel file that turns on the contributor-only gates (doc-guard, the doc invariants) in a checkout. | — |
| **Queue lock** | `scripts/handover/queue-lock.sh`: one writer per handover document; acquiring prints the release token. | mutex |

### Review and merge

| Term | Meaning | Avoid |
|---|---|---|
| **CR marker** | The untracked file `.git/cr-pending/<branch>` that pre-push `check-cr-before-push.sh` writes. While it exists, `gh pr create` is denied (`check-cr-marker-on-pr-create.sh`); only `clear-cr-marker.sh` removes it. | review flag |
| **CR ledger** | `<git-common-dir>/cr-critic-scores.jsonl`: one row per critic that responded at a head. `clear-cr-marker.sh` and ready-check item 4 read it. | review log |
| **Verdict (CR)** | One disposition per review finding. `scripts/cr/write-verdicts.sh` writes `agreed`, `disproved`, `conflict` (evidence both agrees and disproves), `unaddressed` (no verdict reached; blocks) or `deferred -> <TICKET>` (a bare `deferred` is refused); it never writes `fixed`. `fixed` comes from `review-round.sh promote`, which amends an `agreed` row on a clean round (`clear-cr-marker.sh` gate 4c runs it), or from `ledger-append.sh --set verdict=fixed`. Terminal, per `promote`: `fixed`, `disproved`, `deferred`; `agreed` waits for promotion, and `conflict` and `unaddressed` are never promoted. | resolution |
| **Class sweep** [variant sweep] | One `SWEEP` line per agreed or fixed finding, naming every site of the finding's class; `clear-cr-marker.sh` refuses without it (`missing-class-sweep`). | — |
| **Round** | One counted panel run on a branch, printed as `pr-check: round N of 3 on <branch>`. A CR round, a panel round and a pr-check round are the same counter. It advances once per panel run, not per critic or retry. | — |
| **Delta round** | The one extra round allowed after round 3, printed as `pr-check: delta round 4 on <branch>`. It reviews only the diff since the last counted head, and only a Critical or escape-class finding blocks. A fourth full round or a second delta round exits 8; a signed judge GO at the exact head clears any later change instead. | 4th round |
| **Ready-check** | `scripts/handover/console-kit/ready-check.sh`: the numbered pre-GO checks on one PR head (head and merge state, check rollup, threads, CR ledger, trailers, ticket ids, coverage). `go.sh` runs it before it signs. | — |
| **GO / GO file** | The chief's merge authorisation for one PR at one head sha, written by `go.sh`. The file *is* the GO: `merge-on-green.sh` refuses (exit 17) a chief-spawned worker without it, whatever any message says. | approval |
| **Attestation trailer** | `Platforms tested: <os>` or `Security reviewed: <token>` in a PR's first commit, checked at pre-push and by ready-check item 5. | sign-off |
| **Ticket ID** | The `[KEY-n]` every commit subject and PR title carries. | — |
| **Impacted suites** | The test suites that reference a file a range touches, listed by `scripts/cr/impacted-suites.sh`; PR CI runs only these. | affected tests |

### Fleet plumbing

| Term | Meaning | Avoid |
|---|---|---|
| **Bank** [usage] | The subscription usage budget (5-hour and 7-day). `scripts/lib/bank-preflight.sh` prints one verdict token (`PROCEED`, …) and always exits 0. | quota |
| **Bank lift** [weekly limit override] | `~/.himmel/state/bank-lift.json`, which relaxes the 7-day bank check. Setting it is operator-only; `block-bank-lift-writes.sh` denies every agent write. | — |
| **Plugin profile** | A plugin set a worker launches with (`headed-arm-leg.sh --profile <name>`, defined in `scripts/lanes/plugin-profiles.json`). | — |
| **Preface** | [`handover/leg-preface.md`](handover/leg-preface.md): the rules appended to every worker's system prompt at launch. Five prefaces exist (worker, worker claudex, worker openrouter, judge, consult), so write "worker preface" or "judge preface", never a bare "preface". | system prompt |
| **Brief** | In this glossary, the per-worker header of a handover document, not a task prompt (`brief.md` and `--brief-file` name whole task prompts). It holds: ticket, worktree, base sha, token, chief, contract. The brief wins over the preface where they disagree. | — |
| **Nonce** [token] | The RETASK token minted per child; a revision must quote it ([`internals/retask-channel.md`](internals/retask-channel.md)). | password |
| **Tick** | `scripts/handover/console-kit/tick.sh`: one batched snapshot line of the fleet, read from each worker's newest status-marker bullet. | poll |
| **Waiter** | `scripts/handover/console-kit/console-wait.sh`: the chief's one background command, silent until the first real event, then it exits. | monitor loop |
| **Board** | The chief's board: a generated HTML page of fleet state and worker phases (HIMMEL-3361). | dashboard |
| **Tracker** | The ticket backend a run uses, `TRACKER=jira\|local\|none` ([configuration](configuration.md); HIMMEL-4759). | — |
| **Status marker** | The leading word of a worker's Results bullet (`LIVE`, `FINDING`, `RESOLVED`, `READY`, `BLOCKED`, `HALTED`, `WRAPPED`, `PARKED-BANK`, `RESUMED`), written by `scripts/handover/console-kit/append-results.sh`. | state |
| **Ponytail comment** | A `ponytail: <ceiling>, <upgrade path>` code comment for a deliberate simplification ([`internals/ponytail-convention.md`](internals/ponytail-convention.md)). | TODO |
| **Backend tier** | The CLI-over-MCP routing registry `scripts/backends.json`, enforced by `block-backend-tier.sh`. | — |

### Same harness word, different thing

Renamed senses are not listed. A sentinel file is `.single-writer` or
`.himmel-dev`, an identity variable is `HIMMEL_CONSOLE_LEG`, and a ponytail
comment is the `ponytail:` code comment.

| Word | What it means in this glossary | Other things it is used for | How to tell which one |
|---|---|---|---|
| **marker** | Two things: a status marker and the CR marker. | Nothing else now. The other former uses are renamed: sentinel file, identity variable and ponytail comment. | A status marker is the leading word of a Results bullet. The CR marker is an untracked file under `.git/cr-pending/`. |
| **verdict** | One disposition per review finding, written by `write-verdicts.sh`. | A judge's verdict file. The one-word answer `bank-preflight.sh` prints. These are three different objects. | A review verdict sits in the CR ledger. A judge verdict is a file written for one question (`handover/verdict-template.md`). The bank token is script output. |
| **ledger** | The CR ledger, one row per critic that responded at a head. | The shadow ledger, the claudex inbox ledger, and the bank-preflight ledger row. | Name which one. The CR ledger is `cr-critic-scores.jsonl` in the git common dir. |
| **board** | The chief's board, a generated HTML page of fleet state. | The Jira board, set by `JIRA_BOARD_ID`. The chief's board does not replace it. | A `JIRA_BOARD_ID` or a Jira URL means the Jira board. |
| **tracker** | The ticket backend a run uses, `TRACKER=jira\|local\|none`. | The roadmap page `tracker.py`, until its rename ticket lands. The version-first roadmap view (HIMMEL-3990). Neither is the `TRACKER` backend. | The `TRACKER` variable means the backend. A page or a ticket means one of the others. The page is `scripts/handover/console-kit/tracker.py`. |
| **profile** | A plugin profile: the plugin set a worker launches with (`--profile <name>`). | An install profile. An MCP profile. `CR_PROFILE`, the critic tier switch (`free,paid`, or `none` to skip the panel). The `himmelctl` install profile (`starter`, `luna`, `operator`, `custom`). The Hermes profile `himmel_agent`. | A `--profile` flag on a worker launcher means the plugin profile. `CR_PROFILE` is an env var read by `scripts/cr/critic-panel.sh` and set in `.env.example`. The `himmelctl` profile is a wizard answer (`docs/setup/new-machine.md`). The Hermes profile is in `docs/hermes-runbook.md`. The others live in `docs/setup/profiles/` and `.claude/mcp-profiles/profiles.json`. |

## Overlap map

One row per enforced invariant, one column per layer, re-derived from the live
wiring files on 2026-10-13 at merged head `610e7c01a` (origin/main `1ab4cacd0`).
A cell names the script; `—` means the layer does not enforce it. Columns:

- **Claude** — `.claude/settings.json` hooks (Pre = PreToolUse, Post = PostToolUse).
- **Plugin** — `marketplace/plugins/himmel-ops/hooks/hooks.json` (Claude sessions with the himmel-ops plugin).
- **Codex** — `.codex/hooks.json`.
- **Git** — `.pre-commit-config.yaml` stages (pc = pre-commit, cm = commit-msg, pp = pre-push) and the installed shims: reference-transaction (rt) and the single-writer pre-push (sw).
- **CI** — `.github/workflows/` jobs and the `scripts/ci/` scripts they run.
- **Kit** — a chokepoint or kit script that refuses on its own.

| Invariant | Claude | Plugin | Codex | Git | CI | Kit |
|---|---|---|---|---|---|---|
| No edits in the primary checkout | `block-edit-on-main`, `block-write-into-main-checkout`; Post `detect-dirty-primary` (reports) | `record-primary-baseline` (records) | `block-edit-on-main`, `block-terminal-write-fence`, `record-primary-baseline`, Post `detect-dirty-primary` | pc `check-worktree-isolation`; rt `check-main-ref-transaction` | — | — |
| No direct push to `main` | none (`permissions.allow` lists bare `git push`) | — | `block-terminal-write-fence` (every push needs `CODEX_EXTERNAL_WRITES_OK=1`) | pp `check-push-target` | — | `merge-on-green.sh` is the merge path |
| No force push | `block-destructive-commands`; `permissions.deny` (`git push --force`, `-f`, `--mirror`) | — | `block-destructive-commands`, `block-terminal-write-fence` | pp `check-no-force-push`; sw `check-single-writer-push-floor` (`.single-writer` repos) | — | — |
| Secrets never read | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | — | — |
| Secrets never committed | — | — | — | pc `gitleaks`, `leak-classes`, `git-env-scrub` | `secret-scan` (`check-no-secrets.sh`), `security-scan` (gitleaks), `leak-classes`, `git-env-scrub` | — |
| Ticket ID on every commit and PR | — | — | — | cm `check-commit-msg` | `commit-lint` (`check-commit-range.sh`), `pr-title-lint` (`scripts/lib/check-pr-title.sh`) | ready-check item 6 |
| CR before the PR opens | Pre `check-cr-marker-on-pr-create` | — | `check-cr-marker-on-pr-create` | pp `check-cr-before-push` (writes the marker) | — | `clear-cr-marker.sh`, ready-check item 4 |
| Review findings resolved before merge | Post `trigger-cr-on-pr-create`, `trigger-cr-on-push` (request CodeRabbit) | `block-unresolved-cr-merge` (gate 1) | — | pc `check-cr-best-effort` (a text lint: no tracked doc waits on CodeRabbit) | `codeowner-review-gate` (outside PRs only) | ready-check item 3, `merge-on-green.sh` (via `check-ci.sh`) |
| Merge only on green CI and a GO | — | `block-unresolved-cr-merge` (gates 2–3) | `block-terminal-write-fence` (`gh pr merge` needs an opt-in) | pp `check-pr-mergeable` (conflicts only) | — | `go.sh`, `merge-on-green.sh` (exit 17 without the GO file) |
| Trust-path PRs need a trust-reviewed GO | — | `block-unresolved-cr-merge` (gate 4, every session) | — | — | — | `go.sh --trust-reviewed`, `merge-on-green.sh` (both read `ci-trust-paths.txt`) |
| Attestation trailers in the first commit | — | — | — | pp `check-platforms-tested`, `check-security-reviewed`; cm `check-commit-msg` (warns only) | `commit-lint` (first commit, PR events only, through `check-hooks-on-pr-range.sh`) | ready-check item 5 |
| No rogue scheduler job launches `claude` | `block-rogue-claude-schedule` (Bash, PowerShell) | — | `block-rogue-claude-schedule` (Bash, PowerShell) | — | — | — |
| Destructive commands denied | `block-destructive-commands` | `block-docker-privesc` | `block-destructive-commands`, `block-docker-privesc` | — | — | — |
| No `git stash` | `block-git-stash` (Bash, PowerShell) | — | `block-git-stash` (Bash, PowerShell) | — | — | — |
| Live settings not writable | `block-edit-live-settings` (Bash, PowerShell, Edit) | — | `block-edit-live-settings` (Bash, PowerShell; not `apply_patch`, HIMMEL-5430 open) | — | — | — |
| Bank lift not writable | `block-bank-lift-writes` (Bash, Edit) | — | `block-bank-lift-writes` (Bash, Edit) | — | — | — |
| `~/.himmel/config.json` opt-ins not writable | `block-himmel-config-writes` | — | `block-himmel-config-writes` | — | — | — |
| Lesson and enforcement files not agent-written | — | `block-lesson-enforcement-writes` | `block-lesson-enforcement-writes` | — | — | — |
| No commit onto a merged PR's branch | — | `block-merged-pr-commit` | `block-merged-pr-commit` | pc `check-merged-branch` (warns) | — | — |
| Chokepoints called bare | `block-chokepoint-env-prefix`, `guard-pr-check-literal` | `block-rogue-codex-exec` | `guard-pr-check-literal` | — | — | — |
| Agent dispatch names a model and the right lane | `guard-agent-model` (blocks a Fable model and a `console-judge` tier override; allows a missing model) | `guard-subagent-model` (denies a missing model unless a fork; `SUBAGENT_MODEL_OK=1`), `guard-implementor-dispatch`, `guard-console-dispatch` | — | — | — | — |
| Egress stays inside policy | `mcp-policy`, `block-backend-tier` | `block-graphify-egress`, `block-agent-native-egress`, `block-glm-external-writes` | `mcp-policy`, `block-backend-tier`, `block-terminal-write-fence` | — | — | — |
| Worker session discipline | `block-leg-askuserquestion`, `guard-leg-wakeup`, `guard-leg-context-handoff` (+ PreCompact), `block-subagent-park` | — | `guard-leg-context-handoff` | — | — | — |
| Judge and relay writes confined | `guard-relay-writes` | `guard-judge-writes` | — | — | — | `go.sh` refuses under `HIMMEL_CONSOLE_LEG` / `HIMMEL_CONSOLE_RELAY` |
| Guard scripts intact | Post `check-hook-file-parse` | `record-hook-integrity` | — | pc `fail-open-lint`, `hook-lib-node-suites`, `guardrail-matrices` | `guardrail-matrices`, `lanes-and-trust-suites` (`check-hook-lib-suites.sh`) | `ci-trust-paths.txt` lists `scripts/hooks/lib/` |
| Test suites run through `quiet-run` | `require-quiet-run`, `block-tail-pipe-on-gates` | — | `require-quiet-run` | — | — | — |
| Dependency supply chain | — | — | — | pc `lockfile-integrity`, `uv-lock-integrity`, `pip-hashes`; pp `npm-audit`, `npm-licenses`, `npm-audit-signatures` | `security-scan` (same scripts, `pip-hashes` excepted) | — |
| Generated docs match their sources | — | — | — | pc `agents-md-fresh`, `debrand-coverage`, `lanes-inventory-guard`, `commands-catalog-drift`, `secrets-doc-drift`, `skill-description-cap`, `doc-guard`; pp `doc-guard-push` | `doc-invariants` (same checks over the staged tree, plus `doc-guard` over the PR range) | — |
| Plugin edits bump the version | — | — | — | pc `plugin-version-bump-required` | `plugin-version-bump` | — |

### Overlaps worth a look

Facts only; nothing here is a proposed change.

**Enforced three or more times**

1. **Primary-checkout writes** — seven scripts across four layers:
   `block-edit-on-main`, `block-write-into-main-checkout`,
   `detect-dirty-primary`, `record-primary-baseline`,
   `block-terminal-write-fence`,
   `check-worktree-isolation` and `check-main-ref-transaction`.
2. **The CR gate** — the pre-push marker, the PR-create guard (Claude and
   Codex), `clear-cr-marker.sh`, ready-check items 3–4, `block-unresolved-cr-merge`
   and `merge-on-green.sh` all decide some part of "reviewed before it lands".
3. **Force push** — `block-destructive-commands` (Claude and Codex), the
   settings `permissions.deny` rules, `block-terminal-write-fence` (Codex),
   pre-push `check-no-force-push` and, in `.single-writer` repos, the installed
   pre-push `check-single-writer-push-floor`.
4. **Ticket ID** — commit-msg, CI `commit-lint`, CI `pr-title-lint` and
   ready-check item 6.
5. **Secrets committed** — `gitleaks` and `leak-classes` at pre-commit, then
   again in CI (`security-scan`, `leak-classes`), plus `check-no-secrets.sh` on
   workflow files.
6. **Agent dispatch** — four `Agent` PreToolUse guards in two files
   (`guard-agent-model` in settings; `guard-subagent-model`,
   `guard-implementor-dispatch`, `guard-console-dispatch` in the plugin).
7. **Attestation trailers** — pre-push `check-platforms-tested` and
   `check-security-reviewed`, the same two gates re-run over the PR range in CI
   `commit-lint`, and ready-check item 5.

**Look redundant on a first read**

- `guard-agent-model` (settings) and `guard-subagent-model` (plugin) both read
  an `Agent` call's `model` field, but split the job. `guard-agent-model`
  denies a blocked model (Fable) and a `console-judge` tier override, and
  allows a missing model. `guard-subagent-model` denies a missing model for
  every subagent type except a fork (`SUBAGENT_MODEL_OK=1` lets one through)
  and never reads the model's value.
- The green-CI check runs in `block-unresolved-cr-merge` (on `gh pr merge`) and
  in `merge-on-green.sh` (on its own merge); they guard two entry points to one
  action.
- The trust-path rule runs in `block-unresolved-cr-merge` (gate 4, on
  `gh pr merge`, every session) and in `merge-on-green.sh`. Both ask the same
  `trust_path_check` in `scripts/lib/go-gate.sh`.
- `check-merged-branch` (pre-commit, warns) and `block-merged-pr-commit`
  (PreToolUse, denies) catch the same commit at two moments.
- Most pre-commit checks re-run in CI. That is by design: a commit made with
  `--no-verify` skips every git hook, and CI is where that is caught.

**One layer only**

- Secrets never *read* — `block-read-secrets` only (Claude and Codex wire the
  same script).
- `git stash`, live settings writes, rogue scheduler jobs, `quiet-run` — a
  PreToolUse hook only (Claude and Codex wire the same scripts); no git or CI
  layer. Codex does not cover the live-settings write path through
  `apply_patch` (HIMMEL-5430, open).
- No direct push to `main` from a Claude session — pre-push
  `check-push-target` only; no Claude hook, and `permissions.allow` lists bare
  `git push`.
- Bank lift and `~/.himmel/config.json` — one script per invariant, wired in
  both Claude and Codex.
- Attestation trailers in CI — `commit-lint` runs them on `pull_request`
  events only, so a push with no PR is not re-checked there.

**Codex parity** (guards only: hooks that can deny a tool call; context
injectors, watchdogs and end-side hooks are not counted): `.codex/hooks.json`
wires no plugin-only guard except `block-docker-privesc`,
`block-merged-pr-commit` and `block-lesson-enforcement-writes`; it adds
`block-terminal-write-fence`, which no Claude file wires.
