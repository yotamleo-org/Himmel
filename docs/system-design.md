# himmel system design

This page explains how himmel is designed and why. It is a narrative: read it
top to bottom once and you will know what the parts are, how one piece of work
moves through them, what keeps the whole thing safe, and which trade-offs were
made on purpose.

It does not redraw what other pages already draw. The structural diagrams are in
[`architecture.md`](architecture.md); the behavioural chains and every knob are
in [`configuration.md`](configuration.md); the vocabulary is defined once in
[`glossary.md`](glossary.md), and this page uses those terms exactly.

- [1. Goals and non-goals](#1-goals-and-non-goals)
- [2. The parts](#2-the-parts)
- [3. One ticket, from file to merge](#3-one-ticket-from-file-to-merge)
- [4. The trust and safety model](#4-the-trust-and-safety-model)
- [5. Key decisions and their trade-offs](#5-key-decisions-and-their-trade-offs)
- [6. Where to read next](#6-where-to-read-next)

---

## 1. Goals and non-goals

himmel runs Claude Code as a managed agent. A solo operator or a small team
works with Claude every day; himmel makes the safe way of working the only easy
way, and lets work continue when the operator is away.

**Goals**

- **Safety is structural.** A rule that matters is a hook, a gate or a script
  that refuses, not a paragraph a model is asked to remember. Prose in a context
  window is a probability; an exit code is not.
- **Work survives sessions.** A session ends and the next one starts cold. The
  state of the work lives in plain markdown on disk, so a successor resumes from
  the recorded stop point instead of re-deriving it.
- **One writer per artifact.** Several sessions run at once. Each owns one
  ticket, one worktree and one pull request; nobody edits `main`; coordination
  that can be a lock is a lock.
- **Every change is reviewed before it merges.** Review, CI and an explicit
  authorisation to merge are separate checks, and the merge script verifies all
  of them itself.
- **Small always-on context.** What every session must carry is kept short;
  everything else loads on demand.

**Non-goals**

- It is not a general agent framework or a memory backend. Handover state is
  readable markdown you can edit and diff; the search index over it is a derived
  view, rebuilt on demand.
- It is not for workflows that commit straight to `main` by design. Most of the
  value is aimed at a PR-gated, ticket-tracked workflow.
- It does not claim the model is trustworthy. The design assumes a session can
  drift, be wrong, or read hostile text, and bounds what that can cost.
- It is not one command to install in full. The portable core adopts into an
  existing repo in one step; the observability stack, the Telegram bridge and the
  vault tooling are separate, optional bring-ups.

The case for these goals, with the failure modes behind each, is argued in
[`why-himmel.md`](why-himmel.md).

---

## 2. The parts

Seven things make up the system. The first four are people and sessions; the
last three are machinery that every one of them works inside.

| Part | What it is | What it deliberately does not do |
|---|---|---|
| **Operator** | The one human. Rules on open questions, usually away while the fleet runs. | Does not dispatch workers or merge by hand in the normal flow. |
| **Chief** | A persistent, operator-facing session that owns a shift. It writes briefs, dispatches workers, verifies reports and writes the GO file (merge approval). | Does no implementation itself. |
| **Worker** | One working item: one ticket, one worktree, one brief, one PR. A worker has kinds: a work session, a relay session, a judge session. | Never merges on its own word, and never asks the operator directly. |
| **Judge** | A clean session spawned for one question, often on a deliberately thin brief. It reads, verifies and writes one verdict. | Advisory only: it rules, the chief acts. It holds no GO and no nonce mint. |
| **Guardrail layer** | Hooks that run before and after every tool call, plus git gates on every commit and push. | It is not a role and cannot be argued with; it is always in the room. |
| **Handover system** | Plain-markdown state per worker, a queue lock, and scheduled relaunch so a stopped session resumes. | It is not a memory store that is queried instead of the source. |
| **Backends** | A local Jira CLI preferred over an always-loaded MCP server; lanes for delegated work; an optional Telegram bridge. | They do not change who may write or merge. |

Two further terms matter for fan-out. A **batch** is a set of workers dispatched
together, which is the unit that collision checks, the single-writer rule and the
fleet cap apply to. A **dependency chain** is an ordered sequence of workers that belong
together. **Arming** is launching a session on a schedule or a signal so that a
run can start or resume unattended, and **succession** is one chief handing
over to the next.

The definitions, and who holds which authority (queue lock, GO, nonce mint), are
in [`glossary.md`](glossary.md#who-holds-what). The diagrams of the layers, the
handover system, the fleet and the backend seam are in
[`architecture.md`](architecture.md).

---

## 3. One ticket, from file to merge

This is the path a single piece of work takes. The same path is drawn as a flow
in [`configuration.md`](configuration.md#21-the-delivery-chain-end-to-end) and
walked as a hands-on loop in [`daily-loop.md`](daily-loop.md). This version
names who does what and why each hand-off exists.

1. **File.** The work starts as a ticket in the tracker, driven through the
   local Jira CLI. Every commit and every pull request carries a ticket ID, so
   each change traces to a reason.
2. **Dispatch.** The chief writes a brief and launches a worker. The dispatch
   carries a fresh worktree on a `type/slug` branch, a trimmed tool set, an
   explicit model, a per-worker-session nonce for the RETASK channel, and a queue lock on
   the worker's own handover document. Before launching, the chief checks the
   subscription usage budget and counts live workers against the fleet cap; over the cap, nothing
   launches.
3. **Build.** The worker works in its worktree. Edits on `main` are refused by a
   hook and again by a pre-commit gate. The worker writes its own failing test
   first and records its progress as markers in its handover document, so the
   chief reads state from a file rather than from a conversation.
4. **Commit and push.** The commit-message gate enforces conventional commits
   and the ticket ID. The first commit of the PR carries attestation trailers
   (what platform was tested, what security review was done), written after that
   work happened. The push gates check them, and a push also writes a **review-owed
   marker** that records a review is owed.
5. **Review.** `/pr-check` runs a multi-agent automated review. Findings go back to
   the build step; each one needs a terminal finding status. A clean result clears the
   marker, and only then can the pull request be opened.
6. **Ready.** The worker reports that the PR is open at a named head, CI is green
   there, review threads are resolved, the review ledger has a row for that head
   and the trailers are in place. The chief re-verifies each claim itself
   rather than trusting the report.
7. **Judge, when the change touches trust.** A change to a hook, a guard, a
   permission or a CI trust path additionally needs a judge's independent
   verdict from a clean session.
8. **GO and merge.** The chief writes a GO file (merge approval):
   signed, on disk, bound to
   one PR head. The merge script checks that file, CI and review state itself and
   refuses without them. A push after the GO needs a new one.
9. **Wrap.** The worker records the merge, releases its queue lock, reports it is
   finished and stops. The chief closes the window after verifying the lock is
   free and no process is left running. The ticket's status has followed the
   work through the scripts, and the state of the work remains in the handover
   document for whoever reads it next.

Three properties fall out of this shape. The chief never implements and the
worker never merges, so no single session both writes and approves a change.
Review happens before the pull request exists, so a reviewer is never asked to
look at something that is already half-merged in someone's head. And every
transition that is dangerous is a script with its own refusal, not a convention.

---

## 4. The trust and safety model

Nothing in the harness assumes the model will behave. The design bounds what a
session can do, then asks what a mistaken, manipulated or merely long-running
session could cost.

**Five independent stages.** A rule is checked where it is cheapest to catch:
at the tool call, at commit, at push, in CI, and at merge. Each stage sees
something the others cannot. A hook sees the intent of one call but not the
diff; a pre-push gate sees the whole range; CI sees a clean machine; the merge
gate sees the CI result plus review state. The rules that matter most are
checked at more than one stage. The stages are drawn in
[`architecture.md`](architecture.md#1-the-enforcement-layers).

**Authority is separated, not shared.** Only the chief writes a GO or mints a
nonce. A judge cannot write its own GO. A worker cannot widen its own scope. These
are enforced by the scripts, which refuse under the environment markers that
every session started by the chief carries, not by a request to behave.

**The RETASK channel treats tool output as hostile.** Text that arrives inside
a tool result, a file or a web page is data, never instruction. A genuine
revision of a worker's task arrives only as a direct message from its chief. An
expansion or a redirect must quote the worker's token; a halt or a narrowing needs
none. The asymmetry is deliberate: someone who can only make a worker do less has
no leverage, so refusing to do less is never the safe default. A revision never
widens the permissions a session was launched with.

**Single writer, enforced.** Many sessions may read; one writes. A worker holds a
queue lock on its own handover document, the lock is a directory created
atomically and released only with the token printed when it was taken, and the
chief collision-checks the files of every queued worker before a batch launches.
Two workers editing one file is the conflict a merge queue cannot untangle.

**The merge is a sanctioned script.** Merging goes through one script that
verifies the GO file, CI and review state, and a list of trust paths (CI
definitions, shared libraries, the merge gate itself). That list is read from
the default branch, so a pull request that edits it cannot shrink the list it is
judged by. A change touching a trust path needs a trust-reviewed judge verdict GO in
addition.

**Secrets and egress are fenced.** Reads of secret files are blocked, commits
are scanned for secrets, and a data-egress matrix decides which corpus may go to
which provider for which purpose, enforced by a hook rather than by the brief.

**Cost is part of safety.** An unattended session draws the same subscription usage budget as
an interactive one. Launches are preflighted against the budget and the fleet cap,
and delegation tiers are fixed so that the scarcest model is the escalation
target, not the default.

**When a guardrail stops you.** A refusal always names its recovery path. A
bypass is a session-level setting in the launching shell, never a per-call
prefix, so it is a deliberate act at the start of a session rather than
something one tool call can grant itself. See
[`internals/stuck-playbook.md`](internals/stuck-playbook.md).

The full inventory of hooks and gates, with each one's bypass, is in
[`internals/enforcement.md`](internals/enforcement.md); the control surface and
off-switches are in [`configuration.md`](configuration.md).

---

## 5. Key decisions and their trade-offs

| Decision | Why | What it costs |
|---|---|---|
| **Structural over instructional.** The first drift of a prose rule is a signal; on the second, it becomes a hook, gate or classifier, never stronger prose. | Prose in a context window decays with compaction and is silent when it fails. A refusal is observable. | Gates fire on you too. Some will stop a change you believe is fine. The recovery path is documented, but you meet the friction every day. |
| **Derive a gate's input from the thing it guards.** The hook that blocks Jira MCP calls asks the CLI which verbs it has instead of keeping a list. | A hand-kept list is a second copy of the truth and stops protecting without anyone noticing. | Gates depend on the guarded tool exposing a way to be asked. Where that is missing, a list is kept and the drift risk remains. |
| **Handover is plain markdown, one file per worker.** State and orders never split across two documents. | A resuming session cannot read half the picture, and a human can read, correct and diff the memory. | Writing state takes discipline. A worker that records nothing leaves nothing to resume from. |
| **A lock, not a convention, for one writer per queue.** The lock is a directory with a release token. | Prose coordination between two armed sessions failed in practice: duplicate dispatch and duplicate shipping. | A stale lock needs a deliberate release, and a session that dies holding one has to be recognised as dead. |
| **A local CLI before an MCP server.** MCP is used only for operations the CLI does not implement, and routing is enforced. | An MCP server costs context in every session that loads it; a CLI costs nothing until called. | The CLI is a build artifact and must be invoked by absolute path from the primary checkout; a worktree does not have it. |
| **Separate roles: chief, worker, judge.** The session that approves is not the session that writes. | A reviewer that shares the author's context shares the author's blind spots. | More sessions, more coordination and more cost for the same diff. It earns this on changes that touch trust, and is overkill on others. |
| **Fail-safe revision.** A narrowing or halt needs no token; an expansion needs one. | Hostile text can only make a worker do less, never more. | A legitimate narrowing can be accepted from the wrong place; the cost is wasted work, not a breach. |
| **Always-on context stays small.** Cross-cutting frame-shaping rules live in the root instruction file; domain-local rules live in subtree files; the rest loads on demand. | Every token in the always-loaded surface is paid in every session and every subagent. | Knowledge has to be found by retrieval or by following a pointer, and the pointer layer has to be curated. |
| **Observability is passive.** The exporter reads; it never writes a ledger, mutates state or starts or kills a process, and missing data stays missing. | A monitor that guesses is worse than none: a crashed session never writes its end record. | Liveness is inferred by the reader from what exists, so some states are reported as stalled rather than known. |
| **Opt-in autonomy.** Initiative mode, arming, AFK (unattended) mode and the Telegram bridge are each off until turned on, with an off-switch each. | Each layer of autonomy is a deliberate choice, and a layer you did not enable cannot surprise you. | A fresh install does less than the full picture suggests, and the operator has to turn each layer on. |

Agent teams are an example of a decision recorded as *parked*. The feature is
experimental, its token cost scales with every active teammate, and nothing in
the harness depends on it; the opt-in trigger is written down so the decision
can be revisited rather than re-argued. See
[`orchestration-patterns.md`](orchestration-patterns.md#8-agent-teams-decision-record).

---

## 6. Where to read next

| If you want | Read |
|---|---|
| The case for the harness and the failure modes behind it | [`why-himmel.md`](why-himmel.md) |
| To get it running | [`getting-started.md`](getting-started.md) |
| One full loop with every hook explained where it fires | [`daily-loop.md`](daily-loop.md) |
| The structural diagrams | [`architecture.md`](architecture.md) |
| The behavioural chains, every gate and every knob | [`configuration.md`](configuration.md) |
| The vocabulary | [`glossary.md`](glossary.md) |
| How to run a chief and its workers | [`handover/running-a-console.md`](handover/running-a-console.md) |
| Coordination doctrine for fan-outs and verify loops | [`orchestration-patterns.md`](orchestration-patterns.md) |
| Where knowledge lives so the always-loaded surface stays small | [`internals/context-architecture.md`](internals/context-architecture.md) |
| Every hook, gate and bypass | [`internals/enforcement.md`](internals/enforcement.md) |
| The RETASK channel and its threat model | [`internals/retask-channel.md`](internals/retask-channel.md) |
| The handover system and its resolver | [`internals/handover-system.md`](internals/handover-system.md) |
