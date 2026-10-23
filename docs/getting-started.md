# Getting Started

Audience: newcomer. Owner of the rewrite: HIMMEL-7211.

New to himmel? This is the path from clone to your first protected project. It is
eight numbered steps, in an order that was run end to end on a clean Linux
virtual machine (install, commit, worktree, undo; the editor refusal was
checked by calling the edit hook directly, not in a live session), and you stay
in control the whole way. The
[daily-loop walkthrough](daily-loop.md), which narrates every hook, is
*optional depth*; the steps below stand on their own.

> **What is himmel?** A harness that runs Claude Code as a PR-gated,
> overnight-capable agent: worktree isolation, multi-agent review, guardrail
> hooks, and durable handover state that survives session boundaries. See the
> [README](../README.md) for the full pitch and the
> [advantages](../README.md#what-you-get).

> **Before you start:** himmel is a harness *for* Claude Code, so you need
> [Claude Code](https://claude.com/claude-code) installed:
> `curl -fsSL https://claude.ai/install.sh | bash` (Linux/macOS). The install wizard
> checks for it and for the other prerequisites, and fails fast with install
> hints (the node-less bootstrap step below installs Node itself).

## The first protected project, in eight steps

Do this on a throwaway or a small repo first. Every step says what you should
see; a different result means stop and read
[setup/install.md](setup/install.md).

### 1. Name the folder you are in

```bash
git clone https://github.com/yotamleo-org/Himmel ~/himmel   # once; the installer lives here
mkdir ~/try-himmel && cd ~/try-himmel && git init -b main
git commit --allow-empty -m "chore: initial commit"
pwd
```

`pwd` prints the project you are about to protect. The installer acts on the
folder you run it from, so a wrong folder here is a wrong install. Use your own
repository instead if you prefer, but it needs at least one commit and a clean
`git status`.

### 2. Preview the footprint

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project --dry-run
bash ~/himmel/scripts/adopt.sh --profile core --scope project --dry-run
```

Both change nothing. The first prints a summary of what the install would run;
the second prints one `DRY:` line for each file and setting it would write.
Node-less machine? Run `bash ~/himmel/scripts/himmelctl/bootstrap.sh` first.

### 3. Install

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project
git status --short
```

These steps were run with project scope only. A `--scope user` install wires the
harness for every project on the machine instead (see
[setup/install.md](setup/install.md)); steps 5 to 7 are not written for it.

`git status` now lists `.claude/`, `scripts/` and `.gitignore` as **untracked**.
The install is on disk but not yet in your project's history. That matters in
step 6.

### 4. See the harmless refusal

Start `claude` in the project and ask it to create `hello.txt`. On `main` the
edit is refused with `block-edit-on-main: refusing to edit …`. That refusal is
the guardrail working, not an error.

### 5. Commit and merge the install

On a machine without the `pre-commit` tool the installer places plain git
hooks, and the commit hook then refuses a commit made directly on `main`. (With
`pre-commit` present the hooks run whatever your `.pre-commit-config.yaml` lists,
and a starter install writes none, so nothing refuses.) Commit on a branch and
fast-forward either way:

```bash
git switch -c chore/install-himmel
git add -A
git commit -m "chore: install himmel #1"
git switch main
git merge --ff-only chore/install-himmel
```

Where the plain git hooks run, the commit-msg gate wants a ticket reference in
every message (`COMMIT REJECTED: no ticket reference matched`). With no
`JIRA_PROJECT_KEY` set, `#<number>` satisfies it (as above); for a repo with
no ticket convention, `TICKET_ID_REQUIRED=0 git commit …` switches the
requirement off. On a repo whose `main` is branch-protected, push the branch and
merge it through a PR instead; if your default branch has another name, use it
in place of `main`.

`.claude/settings.json` carries the path of your himmel download (the status
line and `HIMMEL_REPO` point at `~/himmel`), so the commit above bakes this
machine's path into the project. That is fine for a throwaway; in a repo you
share, a teammate whose download sits elsewhere needs those two values changed
to their own path.

### 6. Create the worktree, then relaunch inside it

```bash
bash scripts/worktree.sh feat/try-himmel
```

It prints the path, `.claude/worktrees/feat+try-himmel`. It does not move a
running Claude Code session: quit, then run `claude` from inside that path. A
worktree is cut from committed history, so cutting it before step 5 gives you
a folder **without** the hooks or the edit guard.

### 7. Verify

In the worktree, `.claude/settings.json`, `scripts/hooks/block-edit-on-main.sh`
and `scripts/worktree.sh` all exist, `claude` can create `hello.txt` there, and
`node ~/himmel/scripts/himmelctl/bin.js status` shows no drift. Then run the
loop below once.

### 8. Preview the undo, then undo

Run these from the project folder you installed into (`~/try-himmel`), not from
the worktree: the uninstaller acts on the folder you run it from.

```bash
cd ~/try-himmel
node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run   # lists what stays and what goes
node ~/himmel/scripts/himmelctl/bin.js uninstall --yes       # --yes is required without a terminal
```

It removes the files the install recorded (git shows them as deleted),
keeps your own files and any copy it does not recognize, and prints `verified:
no himmel wiring left in …`. Your Telegram pairing and bridge state stay unless
you add `--purge-state`.

That is the whole install for the common case. **The full guide is
[setup/install.md](setup/install.md)**: prerequisites, what each scope and
install profile lands, the Windows caveat, and the adaptation checklist for a
repo that is not himmel. Already have himmel wired some older way? See
[setup/migrating.md](setup/migrating.md).

> **Developing himmel itself** (running the repo standalone, hacking on the
> harness) is a different path: see
> [setup/new-machine.md](setup/new-machine.md#4-himmel-repo).

## Minimal config

**`USER_SLUG`** is your kebab-case handle (e.g. `jane-doe`). Skip it and himmel
derives one from your `git config user.name`. That is the whole required
configuration; luna, Telegram, [hermes](hermes-runbook.md) and Jira are all
opt-in. The details, including the companion vault, are in
[setup/install.md](setup/install.md#minimal-config).

**For your first loop you need none of this**, because the installer already
did the work. Skip straight to the loop.

## Your first loop

The first time, skip the first line below: you are already in the worktree you
opened in step 6, on `feat/try-himmel` with `claude` running inside it, so make
your change there and use that branch name in the push line. For every later
change, make a new worktree, `cd` into the path it prints and relaunch `claude`
there before you edit. The hooks below only fire inside an active session. The
throwaway project from step 1 has no remote, so the push and PR lines need a
GitHub remote first (`git remote add origin <url>`); without one, stop after
the commit. Once `origin` exists, later worktrees are cut from `origin/main`,
which lacks the install commit until you push `chore/install-himmel` and merge
it there through a PR. The day-to-day loop is:

```bash
bash scripts/worktree.sh feat/my-thing
                             # isolated branch + worktree. Branch must be type/slug —
                             #   type in feat|fix|chore|docs|refactor|test. Never edit main.
                             #   Then cd into the printed path and relaunch `claude` there.
                             #   (A full himmel checkout also has the `/worktree` slash
                             #   command; a starter install copies only `scripts/worktree.sh`.)
#   … make a small change with Claude …
git add -A && git commit -m "feat: my change #2" && git push -u origin feat/my-thing
                             # conventional-commit gate fires at commit (the #2 is the ticket
                             #   reference it wants, see step 5); the pre-push
                             #   gates run and record that a review is owed
/pr-check                    # multi-agent review; clears the merge gate when clean
#   gh pr create / gh pr merge --squash
/clean                       # prune merged-PR worktrees
/handover                    # save notes on what you did + where you left off, so the
                             #   next session (or a teammate) resumes with full context
```

> **First time using `/handover`?** Run **`/handover-setup`** once to point it at
> your own state store: an inline `handovers/` folder in the repo, or a separate
> git repo (via `HANDOVER_DIR`). Your cross-session notes land wherever you
> point it.

**How to tell it's working:** if you try to edit a file on `main` you'll get a
`block-edit-on-main` message pointing you back into a worktree (`/clean_garden`
or `/worktree`). That message means the guardrail works; it is not an error.
(If you also installed the optional pre-commit gates,
`pre-commit run --all-files` should pass too.)

**You're done when:** `/pr-check` reports clean, the PR merges, `/clean` removes
the worktree, and `/handover` confirms a saved snapshot. To verify, run
`cd ~/try-himmel && git checkout main && git pull && git log --oneline -3` and
look for your change on `main`. (Run it from the project folder: `main` is
checked out there, so `git checkout main` fails inside a linked worktree.)

Want every hook and gate explained at the moment it fires, on a real toy
change? The optional **[daily-loop walkthrough](daily-loop.md)** runs the real
workflow on a real branch. It is the best way to see what each guard
does before you rely on it.

Going unattended later: `/afk-shift --limit 5` dispatches scoped tickets as
parallel agents that open PRs while you sleep ([AFK (unattended) mode](handover/afk-mode.md)).

## Initiative mode + planning pipelines

Two optional accelerators sit on top of the loop. Both are opt-in.

### `HIMMEL_INITIATIVE` — drive-to-ship

When set, each session drives finished work toward shipping at *natural
completion points* (a logical chunk is done **and** verified), instead of
waiting for you to say "ship it" each time. In the default (interactive)
profile, the `all` master switch runs four auto-ship steps, in order:

1. `prcheck`: run `/pr-check` and loop until the review is clean.
2. `pr`: open or refresh the PR.
3. `ticket`: transition the Jira ticket.
4. `handover`: write the handover.

> **Merging is opt-in.** None of the four interactive auto-ship steps
> merges. The full grammar does include `merge` and `public` auto-ship steps,
> used by the overnight profile or an explicit subset. Know what `merge`
> means before enabling it: **the auto-ship step itself authorizes an autonomous private
> merge**. `ARMAUTOMERGE` only selects *which* merge path it takes (the
> CI-certified sanctioned script vs a plain squash-merge); it is not an extra
> on/off gate. To turn merging off, do not enable the step. With `ARMAUTOMERGE=1` that
> script can also merge the one configured public origin, but only after a live read
> shows branch protection with `enforce_admins` and a non-empty required-status-checks
> list; any other public repo, or an unreadable protection read, is refused. The
> `public` auto-ship step is retired and does nothing. See
> [configuration.md](configuration.md) for the complete grammar and gate
> conditions. The directive also can't relax any safety rail. Every gate in
> [configuration.md](configuration.md) still applies: the review-owed marker
> still gates `gh pr create`, the attestation commit-lines
> (`Platforms tested:` / `Security reviewed:`) are still required, and
> reactive history rewrites / settings self-edits stay vetoed.

**Enable it in the launching shell** (it's read at session start):

```bash
HIMMEL_INITIATIVE=all claude        # the four interactive legs
HIMMEL_INITIATIVE=prcheck,pr claude # just CR + open the PR
```

Grammar: a master switch `1`/`true`/`on`/`yes`/`all` (= the four auto-ship steps above),
or a comma-separated subset of the full vocabulary
`plan,execute,prcheck,pr,ticket,merge,public,handover`. Case-insensitive,
whitespace-tolerant; an unset/falsy/typo value is **OFF** (the default), a
byte-identical no-op. A separate overnight profile (`HIMMEL_OVERNIGHT` +
`HIMMEL_INITIATIVE_OVERNIGHT`) widens `all` to six auto-ship steps for
unattended runs. Grammar, per-step semantics, and profiles are in
[configuration.md](configuration.md).

**Most people should leave the aggressive auto-ship steps OFF.** It is the
default because auto-opening PRs and transitioning tickets is a lot of
initiative. If you want some of it, start conservative (`prcheck`, or
`prcheck,handover`) and reserve `all` (or the overnight profile) for
trusted/overnight contexts.

**Per-project override (user default + per-repo tightening).** Beyond the
launching-shell variable, you can set it via the `env` block in
`settings.json`, which Claude Code makes visible to the session's hooks. Per
Claude Code's settings precedence, a **project** `.claude/settings.json`
deep-merges over your **user** `~/.claude/settings.json`, so you can set a
machine-wide default and override it per repo:

```jsonc
// ~/.claude/settings.json — your default for every repo
{ "env": { "HIMMEL_INITIATIVE": "prcheck,handover" } }

// <repo>/.claude/settings.json — make THIS repo stricter (off) or freer (all)
{ "env": { "HIMMEL_INITIATIVE": "" } }
```

A value exported in the launching shell takes precedence over `settings.json`
(per Claude Code's docs), and any change needs a **session restart** to take
effect.

### `/himmel-ops:minerva` — idea → critic-hardened plan

Runs brainstorm → spec → plan as one pipeline with an adversarial critic between
each stage, so every artifact is red-teamed before it advances. Use it for any
feature/design work before writing code. It stops at the plan (it doesn't
implement) and hands off.

## You're in control

himmel makes the workflow *structurally* safe, but nothing is hidden, and every
guard is yours to lift:

- **Everything is plain files.** Rules live in [`CLAUDE.md`](../CLAUDE.md), hooks
  and permissions in `.claude/settings.json`, gates in `.pre-commit-config.yaml`.
  Read them; change them.
- **What himmel adds to your repo:** PreToolUse hooks (block edits on `main`,
  block secret reads, gate PR creation on a passing review) and
  pre-commit/pre-push gates. (The auto-mode classifier you may hit in
  unattended sessions is Claude Code's own, not himmel's; himmel routes
  sanctioned commands around it.) The full inventory and what each one does:
  [`docs/internals/enforcement.md`](internals/enforcement.md).
- **Nearly every guard has an off switch.** Each session hook is bypassed by an
  env var set in the launching shell, e.g. `EDIT_ON_MAIN_OK=1 claude` to edit
  `main`, or `READ_SECRETS_OK=1 claude` if the (deliberately strict)
  secret-read guard blocks a file you need to inspect. A small set of gates is
  deliberately hard (secret-leak scans, the human-only public merge). The
  per-gate map, including that list, is in
  [configuration.md](configuration.md); the
  [`stuck-playbook`](internals/stuck-playbook.md) has the recovery flow for
  each guard.
- **No surprise network or spend, with three named exceptions.** Optional
  integrations are opt-in; headless Claude calls are gated; the local
  Jira CLI talks only to your own Atlassian site. Each exception has a switch:
  a throttled session-start update check (a plain `git fetch` of your own
  himmel clone's remote, no data sent; `UPDATE_CHECK_DISABLE=1`); the
  usage-cap auto-relaunch, which schedules a local session relaunch when a cap
  approaches (`AUTO_ARM_DISABLE=1`); and `/pr-check`'s external review
  critics, which run only where you configured their lane (`CR_PROFILE=none`
  forces a Claude-only automated review with no external spend). The full map:
  [configuration.md](configuration.md).

## Where to go next

| You want to… | Read |
|---|---|
| See one full loop explained | [daily-loop.md](daily-loop.md) |
| See every knob, gate, and off switch in one place | [configuration.md](configuration.md) |
| Understand every hook + gate | [internals/enforcement.md](internals/enforcement.md) |
| Browse the slash commands | [commands-catalog.md](commands-catalog.md) |
| Browse every tool/script | [tooling-catalog.md](tooling-catalog.md) |
| Run unattended overnight | [handover/afk-mode.md](handover/afk-mode.md) |
| Adopt the core in another repo | [setup/install.md](setup/install.md) |
| Full machine setup + gotchas | [setup/new-machine.md](setup/new-machine.md) |
| Update the harness + upgrade the vault | [setup/updating.md](setup/updating.md) |
| Uninstall / offboard himmel | `node ~/himmel/scripts/himmelctl/bin.js uninstall` (execs [`scripts/uninstall.sh`](../scripts/uninstall.sh); see [updating.md](setup/updating.md#uninstalling--offboarding)) |

Working as an LLM in this repo? Start from [`llms.txt`](../llms.txt) — the
machine-readable map.
