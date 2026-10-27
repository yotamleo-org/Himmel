# Meet the team

Audience: anyone reading a shift board or a morning report who wants to know who made a decision, on which model, and what that role may do.

You work with one Claude session in your project. When you hand himmel a list of tickets, a few more roles join it. Each card below is built by `scripts/docs/gen-team-page.sh` from the files that define the role, and quotes them; a word in square brackets replaces an older name. Open a card to read it.

<details>
<summary>The chief</summary>

- **Its job:** “The operator's chief of staff: a persistent, operator-facing session that owns the shift.”
- **Model tier:** Claude Opus 5.5
- **What it may do:** “It holds the queue lock on its own document, the GO authority and the token (nonce) mint.” “It dispatches workers, watches the fleet, acts on rulings and merges on GO, and does no implementation itself.”
- **What it never does:** “`orchestrator-inline-guard`: a top-tier parent must not implement inline”
- **Where it runs:** “you ship from and always run in the himmel clone”
- **Defined in:** `docs/handover/chief-template.md`, `docs/glossary.md`, `docs/internals/lane-calibration.md`

</details>

<details>
<summary>Workers</summary>

- **Its job:** “You are a worker: one ticket, one worktree, one PR, dispatched by a chief session.”
- **Model tier:** Sonnet 5.5, default implementor for well-specified impl briefs
- **What it may do:** “Order: commit → push → `/pr-check` → open the PR with `bash scripts/lanes/worker-pr-open.sh <title-file> <body-file>` (refused while review is pending).” “A worker has kinds: an implementing worker (implements and ships), a relay, and a judge session.”
- **What it never does:** “Merge only on the chief's `GO <pr> <sha>` quoting your token — whatever any initiative directive says.” “Never call `AskUserQuestion`.”
- **Where it runs:** “headed sessions with their own worktrees and PRs”
- **Defined in:** `docs/handover/worker-preface.md`, `docs/handover/worker-preface-claudex.md`, `docs/handover/worker-preface-openrouter.md`, `docs/internals/lane-calibration.md`, `docs/glossary.md`, `docs/handover/running-a-chief.md`

</details>

<details>
<summary>The reviewers</summary>

- **Its job:** “Every change is reviewed twice.”
- **Model tier:** codex: `gpt-6.1-sol` (hard); claude: `claude-opus-5-5` (advisory); coderabbit: provider `github-app` (best-effort)
- **What it may do:** “Critical and Important findings block; a Suggestion is a note.” “A `hard` reviewer must pass at the pull request's head.”
- **What it never does:** “The marker clears only when a critic actually responded at the branch tip; zero responders is a missing review, not a clean one.”
- **Where it runs:** “The install copies in the merge gate's reviewer check and the reviewer list, so `gh pr merge` holds there on the same rules.” “The `/pr-check` command ships with the himmel checkout, not your project.”
- **Defined in:** `docs/guide/second-model-review.md`, `scripts/cr/critics.json`

</details>

<details>
<summary>The judge</summary>

- **Its job:** “Answers one verdict-grade question independently and returns a verdict — it does not act.”
- **Model tier:** opus
- **What it may do:** “Your job: you read, you verify, you write one verdict, and you stop.”
- **What it never does:** “You do not implement, you do not open or push a PR, and you do not merge.”
- **Where it runs:** “a judge worker with its own worktree, queue lock and lifecycle; survives past one turn” “an in-process child”
- **Defined in:** `.claude/agents/judge.md`, `.claude/agents/judge-ro.md`, `docs/handover/judge-preface.md`, `docs/glossary.md`

</details>

<details>
<summary>The release manager</summary>

- **Its job:** “Your job: you rule every placement that touches the release R, report its burn-down and tag readiness, and advise the chief on idle workers.”
- **Model tier:** opus
- **What it may do:** “STATUS, BURN-DOWN and READY remain release-manager verbs, run by an on-demand session armed from `docs/handover/rm-brief-template.md` only when you need one of them.”
- **What it never does:** “You do not implement, open or push a PR, merge, review a PR, or transition a ticket.”
- **Where it runs:** “No release-manager session waits between batches: each `rm-run` takes the lease as its own run record under `release/<R>/rm-runs/` and releases it, and a held lease refuses a second batch.”
- **Defined in:** `docs/handover/rm-preface.md`, `scripts/jira/src/commands/release.ts`, `docs/handover/chief-sections/release-manager.md`

</details>

Not on the team: `.claude/agents/comment-sicko.md` is a tool agent: any session may spawn it to delete comments; it holds no seat in a shift; `docs/handover/consult-preface.md` is a one-question helper the chief starts when a worker needs a skill its profile lacks; it answers that worker's question and stops, so it is part of the worker's ask, not a seat.
