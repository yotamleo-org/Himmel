# Getting Started

Audience: newcomer. This page is the first task: protect one spare project
with himmel, see a guardrail refuse a risky edit, make one change in a
worktree, then undo it all. If you want to run or develop himmel itself
instead, that contributor path is in
[setup/new-machine.md](setup/new-machine.md#4-himmel-repo).

The ten steps below are the same sequence as the
[adoption trail's practice climb](adoption-trail.html#trial), and that
sequence is the canonical one. On 2026-10-23 it was run end to end on a clean
Linux virtual machine with a sandboxed home folder: install, commit, worktree
and undo. The editor refusal in step 7 was checked by calling the edit hook
directly, not in a live Claude Code session, and macOS was not part of that
run. Each step says which folder to run it from and what you should see, and
step 10 undoes the install. A different result means stop and read
[setup/install.md](setup/install.md). The
[daily-loop walkthrough](daily-loop.md), which narrates every hook, is
*optional depth*; the steps below stand on their own.

> **What is himmel?** A harness that runs Claude Code as a PR-gated,
> overnight-capable agent: worktree isolation, multi-agent review, guardrail
> hooks, and durable handover state that survives session boundaries. See the
> [README](../README.md) for the full pitch and the
> [advantages](../README.md#what-you-get).

## The first protected project, in ten steps

Do this on a throwaway or a small repo first. The paths below use
`~/try-himmel` for the project and `~/himmel` for the himmel download; they
are two separate folders, and the install writes into the project, not into
the download.

### 1. Install the tools

You need git, node with npm, jq, python3 and Claude Code. The installer
checks for them and stops with install hints if one is missing.

```bash
# Debian or Ubuntu (needs sudo); Ubuntu's nodejs package ships without npm
sudo apt-get update
sudo apt-get install -y nodejs npm git jq python3 curl
curl -fsSL https://claude.ai/install.sh | bash

# macOS with Homebrew; the bash and python3 macOS ships are too old for some scripts
brew install node git jq python bash uv
curl -fsSL https://claude.ai/install.sh | bash
uv tool install pre-commit
```

You should see: `claude` is found in a new terminal.

### 2. Sign in to Claude Code

Run `claude`, finish the sign-in in the browser it opens, and leave with
`/exit`. An account problem then shows up before himmel is involved.

```bash
claude --version
```

You should see: a version number followed by `(Claude Code)`.

### 3. Make a spare project and name the folder you are in

```bash
mkdir ~/try-himmel && cd ~/try-himmel && git init -b main
git commit --allow-empty -m "chore: initial commit #1"
pwd
```

You should see: `pwd` prints the full path of `~/try-himmel`, the project
you are about to protect. The installer acts on the folder you run it from,
so a wrong folder here is a wrong install. The commit is made before any himmel hook
exists; it still carries a ticket reference (`#1`), as every later commit
must. Use your own repository instead if you prefer, but it needs at least one
commit and a clean `git status`. No remote is needed.

### 4. Download himmel next to your projects

```bash
git clone https://github.com/yotamleo-org/Himmel ~/himmel   # once; the installer lives here
```

You should see: git ends without an error. This folder is the download; you
never work inside it.

### 5. Preview the footprint

Run from `~/try-himmel`:

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project --dry-run
bash ~/himmel/scripts/adopt.sh --profile core --scope project --dry-run
```

You should see: both change nothing. The first prints a summary of what the
install would run, its list headed
`would install (--dry-run — NOTHING below was executed):`; the second prints
one `DRY:` line for each file and setting it would write. `git status` is
still clean. Node-less machine? Run
`bash ~/himmel/scripts/himmelctl/bootstrap.sh` first.

### 6. Install

Run from `~/try-himmel`:

```bash
node ~/himmel/scripts/himmelctl/bin.js install --scope project
git status --short
```

These steps were run with project scope only. A `--scope user` install wires the
harness for every project on the machine instead (see
[setup/install.md](setup/install.md)); steps 8 to 10 are not written for it.

You should see: in `~/try-himmel`, `git status` lists `.claude/`, `scripts/`
and `.gitignore` as **untracked**. The install is on disk but not yet in your
project's history. That matters in step 9. In your own repository, a path it
already tracks shows as modified instead, or not at all.

### 7. See the harmless refusal

Start `claude` in `~/try-himmel` and ask it to create `hello.txt`.

You should see: on `main` the edit is refused with
`block-edit-on-main: refusing to edit …`, and `hello.txt` does not exist. That
refusal is the guardrail working, not an error. Leave Claude with `/exit`.

### 8. Commit and merge the install

Run from `~/try-himmel`. On a machine without the `pre-commit` tool the
installer places plain git hooks, and the commit hook then refuses a commit
made directly on `main`. (With `pre-commit` present the hooks run whatever
your `.pre-commit-config.yaml` lists, and a starter install writes none, so
nothing refuses.) Commit on a branch and
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
in place of `main`. If the repo has an `origin`, push `chore/install-himmel`
and merge it through a PR before step 9, because the worktree is cut from
`origin/main`. (The trail's version of this step lets the installer make the
one commit on `main` itself, with `adopt.sh --commit-install`; either way the
install is in `main`'s history before step 9.)

You should see: `git log --oneline -1` on `main` shows
`chore: install himmel #1`, and `git status` is clean.

`.claude/settings.json` carries the path of your himmel download (the status
line and `HIMMEL_REPO` point at `~/himmel`), so the commit above bakes this
machine's path into the project. That is fine for a throwaway; in a repo you
share, a teammate whose download sits elsewhere needs those two values changed
to their own path.

### 9. Create the worktree, then relaunch inside it

Run from `~/try-himmel`:

```bash
bash scripts/worktree.sh feat/try-himmel
```

You should see: it prints the path,
`.claude/worktrees/feat+try-himmel`. With no remote it also warns that it is
branching from local `main`; that is normal. It does not move a running Claude
Code session: quit, then run `claude` from inside that path. A worktree is cut
from committed history, so cutting it before step 8 gives you a folder
**without** the hooks or the edit guard.

### 10. Verify, preview the undo, then undo

Verify from inside the worktree
(`~/try-himmel/.claude/worktrees/feat+try-himmel`): `.claude/settings.json`,
`scripts/hooks/block-edit-on-main.sh` and `scripts/worktree.sh` all exist,
`claude` can create `hello.txt` there, and
`node ~/himmel/scripts/himmelctl/bin.js status` shows no drift. Then run the
loop below once before you undo, or go straight to the undo.

Undo from the project folder you installed into (`~/try-himmel`), not from
the worktree: the uninstaller acts on the folder you run it from.

```bash
cd ~/try-himmel
node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run   # lists what stays and what goes
node ~/himmel/scripts/himmelctl/bin.js uninstall --yes       # --yes is required without a terminal
```

You should see: it removes the files the install recorded (git shows them
as deleted), keeps your own files and any copy it does not recognize, and
prints `verified: no himmel wiring left in …`. Your Telegram pairing and
bridge state stay unless you add `--purge-state`.

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
opened in step 9, on `feat/try-himmel` with `claude` running inside it, so make
your change there and use that branch name in the push line. For every later
change, make a new worktree, `cd` into the path it prints and relaunch `claude`
there before you edit. The hooks below only fire inside an active session. The
throwaway project from step 3 has no remote, so the push and PR lines need a
GitHub remote first (`git remote add origin <url>`); without one, stop after
the commit. The throwaway's first worktree was cut from local `main` and
already has the install commit. Once `origin` exists, every new worktree is cut from
`origin/main`, which lacks the install commit until you push
`chore/install-himmel` and merge it there through a PR. The day-to-day loop is:

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
                             #   reference it wants, see step 8); the pre-push
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
