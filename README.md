# himmel

> **A control plane for coding agents.**

New to himmel? Start with the trial below. Here to run or work on himmel
itself? Go to the [Quickstart](#quickstart).

himmel earns its keep once you run several Claude Code sessions at once, want
work done while you are away, or want each session to pick up where the last
one stopped. If Claude Code as it ships serves you well, you do not need it;
[Who is this for](#who-is-this-for) says more.

## Start here: protect one project

Try himmel on a project you can throw away. Install it, then ask Claude Code
to edit a file on `main`, the main branch, and watch the edit get refused.
Commit the install before creating a worktree, a separate working folder and
branch; make a change there, then remove himmel at the end of the trial.

The install adds hooks and settings for Claude Code (under `.claude/`), the
scripts they run (`scripts/`) and `.gitignore` entries to the project.
Follow [Getting Started](docs/getting-started.md) step by step: it previews
the install before you run it, and each step tells you which folder to run
it from and what you should see.

That one protected project is a complete result. The rest is optional and
comes later: a notes vault, runs that carry on while you are away, many
sessions in parallel. The [adoption trail](docs/adoption-trail.html) lays these
out as levels, and each level says what it gives you, what it costs and how to
turn it off.

> Deciding whether it is worth it? Read [**Why himmel**](docs/why-himmel.md),
> the failure modes it exists for and what each one costs. Want the design
> in one read? [**System design**](docs/system-design.md) explains the parts,
> one ticket's flow, the trust model and the trade-offs. Want the wiring?
> [**Architecture**](docs/architecture.md) shows how the guardrails, the
> handover notes, the parallel sessions, the Jira link and the logs fit
> together.

## What himmel is

If you work with a coding agent every day, alone or in a small team, himmel
is for you. Claude Code still runs your sessions; himmel installs on top of it
and adds checks before edits, commits and pull requests (PRs), so nobody has
to remember the rules. Each change gets its own branch and a reviewed PR, each commit names
its ticket (a Jira issue, or a plain `#number` if you do not use Jira), and
notes carry the work into the next session. Run several sessions at once and
they work like a small software factory: tickets go in, reviewed and merged
PRs come out, and each merge still waits for a GO: a signed approval to merge
that one PR at the exact commit that was reviewed.

Built for Claude Code. The guardrails also run under Codex CLI, through its
hooks and an `AGENTS.md` file. Other agents are not supported yet;
[harness compatibility](docs/internals/harness-compat.md) has the detail.

It has four layers, and each one works without the layers above it:

1. **The guarded session.** Checks run before Claude Code edits a file,
   commits or opens a PR, and refuse what breaks the rules.
2. **Handover and memory.** Plain markdown notes carry the work and its
   reasons from one session to the next, with a search index to find them.
3. **Jarvis, the command layer.** One session, the *chief*, plans the work
   and hands each ticket to a *worker*, another session that owns that one
   change. The chief checks each result and approves its merge with a GO;
   the worker then merges. [Jarvis](docs/jarvis-subsystems.md) describes it.
4. **The surface.** The himmel UI (`himmelctl ui`), Telegram, the
   statusline, the morning report and the metrics show you what the sessions
   are doing and let you steer the chief.

The idea is simple: anything you would otherwise repeat by hand (checking a
commit, reviewing a PR, writing down where you stopped, restarting after a
usage limit) becomes a tool or a gate. Safety comes from structure, not from
Claude remembering a paragraph of instructions.

## What you get

The trial above shows the first of these: the refused edit on `main`, a
check before each commit and the separate worktree. The rest arrive as you
add them, and the [adoption trail](docs/adoption-trail.html) says which level
brings each one.

- **Work carries over between sessions.** Each session leaves a plain
  markdown handover doc behind. A fresh session reads it and resumes where the
  last one stopped, with the decisions and the reasons for them intact.
- **Work runs while you sleep.** `/afk-shift` (afk: away from keyboard) hands
  tickets to parallel agents that branch, review themselves and open PRs.
  When a session nears its usage limit, himmel schedules a restart with the
  operating system's scheduler, so the run carries on.
- **Mistakes are blocked, not just discouraged.** Hooks stop edits on `main`,
  reads of secret files, and opening a PR without a passing review, at the
  moment Claude tries the tool call.
- **Every merge is reviewed by several agents.** `/pr-check` runs a panel of
  review agents plus a first pass from a second model, and the PR cannot merge
  until the result is clean. A finding marked critical must survive an
  adversarial check first, which filters out invented findings.
- **It stays cheap.** A local Jira CLI replaces a Jira MCP (Model Context
  Protocol) server, a command-line filter shortens noisy output before Claude
  reads it, and each helper agent gets only the instructions it needs. All
  three keep the context window and the bill small.
- **Memory you can read and edit.** Everything Claude remembers is a markdown
  file you can open. The search index on top is disposable and always points
  back at the file. [Memory architecture](#memory-architecture) explains how
  the pieces fit.
- **GitHub or Bitbucket.** The worktree, PR and merge loop works the same on
  GitHub and Bitbucket Cloud. himmel picks the backend from each repo's
  `origin` remote.
- **Linux and macOS.** Linux is checked on every PR, macOS on a scheduled
  run. Details in the [Support matrix](#support-matrix).

## How it flows

<p align="center">
  <img src="docs/assets/flows.svg" alt="Four himmel flows, each a row of six steps: shipping a change, running a fleet of workers from a chief, carrying work across sessions, and finding what you already know" width="960">
</p>

<!-- The diagram is rendered by scripts/docs/render-flows.py: edit the script, not the image. -->

The diagram shows the four flows that make up most of a day with himmel.

**1. Ship a change.** Give your change its own branch and working folder with
`/worktree`, so you never edit `main` directly. Each commit names its ticket.
Checks on each commit and push examine the message format, secrets and
statements of what was tested. `/pr-check` runs a review; once the pull
request (PR) is approved, continuous integration (CI) tests for the affected
suites pass and, in a fleet run, the chief has given written approval (a GO)
for its exact commit, the PR can merge. `/clean` removes the finished
worktree.

**2. Run a fleet: one chief, many workers.** For bigger runs, one Claude
session acts as the *chief*. It plans the work and starts *workers*, other
Claude sessions that each own one ticket, one worktree and one PR. Each
worker reports back and never merges on its own. The chief checks the PR (and
can ask an independent judge for a second opinion) and approves it in writing
(a GO); only then does the worker merge. The [glossary](docs/glossary.md)
defines chief, worker, judge and the rest.

**3. Carry work across sessions.** A session that has made decisions writes
them into a handover doc with `/handover`. The doc lives in a separate git
repo for your notes (set with `HANDOVER_DIR`), not in the project, so it
survives anything that happens to the session. If the session hits its usage
limit, himmel schedules a restart. The next session runs `/handover-resume`,
reads the doc, and continues where the last one stopped.

**4. Find what you already know.** Before improvising, a session looks up
what is already known. Claude Code's per-project `MEMORY.md` is a short index
that routes a keyword to a topic note. `qmd`, a local search engine, searches
the markdown itself (notes, handovers, docs) by keyword and meaning.
`graphify`, a map of the code, answers questions about how the code fits
together. Every answer points at a real file, and a lesson learned on the way
is written back to memory for the next session.

The commands behind flow 1, numbered in the order you run them. In Claude
Code:

```text
/worktree feat/my-thing   # 1. its own branch and worktree (never edit on main)
/pr-check                 # 3. review panel; clears the merge gate when clean
/clean                    # 5. after the merge: prune merged worktrees
/handover                 # 6. write down where you stopped
```

In your shell, from the worktree:

```bash
git add <files>           # 2. after working with Claude in the worktree
git commit && git push    # 2. hooks check the message, secrets and statements of what was tested
gh pr create              # 4. then merge once CI is green and the PR is approved
```

Going unattended, in Claude Code:

```text
/afk-shift --limit 5   # five tickets to parallel agents, each ending in a PR
/stop                  # ask an overnight run to halt gracefully
```

[`docs/daily-loop.md`](docs/daily-loop.md) walks flow 1 end to end and
explains every hook at the moment it fires.
[`docs/configuration.md`](docs/configuration.md) lists every gate, knob and
off switch in one place. Pointing an AI assistant at this repo? Give it
[`llms.txt`](llms.txt), a map of the repo written for language models.

## Quickstart

himmel runs on top of [Claude Code](https://claude.com/claude-code), so
install Claude Code first:
`curl -fsSL https://claude.ai/install.sh | bash`.

There are two ways in:

1. **Protecting your own project?** This is the usual case. It brings over
   the portable core: hooks, guardrails, the worktree workflow and the
   marketplace plugins and skills. Do the trial in
   [`docs/getting-started.md`](docs/getting-started.md) on a spare project
   first, then run this from your project's folder:

   ```bash
   git clone https://github.com/yotamleo-org/Himmel ~/himmel   # once
   node ~/himmel/scripts/himmelctl/bin.js install --scope project
   ```

   Use `--scope user` to wire every project on the machine, or leave out
   `--scope` and the installer asks. What each scope and install profile
   brings, and the checklist for your own repo, is in
   [`docs/setup/install.md`](docs/setup/install.md). The
   [adoption trail](docs/adoption-trail.html) (also at
   [yotamleo-org.github.io/Himmel/adoption-trail.html](https://yotamleo-org.github.io/Himmel/adoption-trail.html))
   shows what each later level of adoption changes.
2. **Working on himmel itself, or installing from the release tarball?** The
   rest of this section covers that: the prerequisites, the
   release tarball or a clone, the environment and the install check.

**Prerequisites.** `scripts/setup.sh` needs `bash`, `git`, `node`, `npm`,
`bun`, `python3`, `jq`, `gh` and `mktemp`. It installs the missing ones it
can, and stops with install hints for the rest. `bun` is required even though
everything it runs is optional: the qmd search index, the Telegram bridge, the
vault tools and resuming a scheduled session. You also need one of `uv`,
`pipx` or an installed `pre-commit`: setup uses it to install `pre-commit` and
then wires the git hooks. Per-platform install steps are in
[`docs/setup/new-machine.md`](docs/setup/new-machine.md).

**Linux, from the release tarball** (checksummed and pre-built: no clone, no
`npm install`). Pick a release from the
[releases page](https://github.com/yotamleo-org/Himmel/releases) and put its
version in place of `X.Y.Z`:

```bash
V=X.Y.Z   # a release that ships the tarball
curl -fsSLO "https://github.com/yotamleo-org/Himmel/releases/download/v$V/himmel-$V-linux.tar.gz"
curl -fsSLO "https://github.com/yotamleo-org/Himmel/releases/download/v$V/himmel-$V-linux.tar.gz.sha256"
sha256sum -c "himmel-$V-linux.tar.gz.sha256" \
  && mkdir -p ~/.local/share/himmel/"$V" \
  && tar -xzf "himmel-$V-linux.tar.gz" -C ~/.local/share/himmel/"$V" --strip-components=1 \
  && ln -sfn "$V" ~/.local/share/himmel/current \
  && node ~/.local/share/himmel/current/scripts/himmelctl/bin.js install --scope user
```

The `&&` chain matters: if the tarball does not match its published
`.sha256`, `sha256sum -c` fails and nothing is extracted or installed. Every
release tarball is built by this repo's CI, and with `gh` you can check that:
`gh attestation verify himmel-$V-linux.tar.gz -R yotamleo-org/Himmel`.

Each release unpacks into its own `~/.local/share/himmel/<version>/` (no root
needed), and `~/.local/share/himmel/current` points at the live one.
`himmelctl install` wires everything through `current` and puts a `himmelctl`
launcher in `~/.local/bin`.

To upgrade, run `himmelctl update` from a shell. It downloads the latest
release, verifies it, unpacks it next to the old one and only then switches
`current`, so a failed download changes nothing. To roll back, point `current`
at the previous version: `ln -sfn <previous-version> ~/.local/share/himmel/current`.
After `himmelctl uninstall`, deleting `~/.local/share/himmel` removes every
version. An older install that unpacked straight into `~/.local/share/himmel`
predates this layout: move it aside and install once with the recipe above.

**Linux or macOS, from a clone:**

```bash
git clone https://github.com/yotamleo-org/Himmel himmel
cd himmel
node scripts/himmelctl/bin.js install
```

No node on the machine yet? From the cloned himmel folder, run
`bash scripts/himmelctl/bootstrap.sh` instead: it installs node with apt
(Linux) or Homebrew (macOS), then runs `node scripts/himmelctl/bin.js install`
for you. `install` asks a few questions, then runs `scripts/setup.sh`; run
that directly for a scripted or CI install.

**Environment.** Set these in the shell that launches Claude. The notes
vault, the Telegram bridge and Jira are optional; himmel runs without them.

| Variable             | Required? | Notes                                                              |
|----------------------|-----------|--------------------------------------------------------------------|
| `USER_SLUG`          | recommended | Your kebab-case handle, e.g. `jane-doe`. Names your folder in the handover repo (`handovers/<USER_SLUG>/`) and your worktree folders. If unset, it is derived from `git config user.name`; setup fails only if both are unset. |
| `JIRA_PROJECT_KEY`   | only for Jira | e.g. `HIMMEL`. The project the CLI creates and queries issues in. |
| `JIRA_BASE_URL`      | only for Jira | Your Atlassian site, e.g. `https://your-site.atlassian.net`. |
| `JIRA_API_TOKEN` + `JIRA_EMAIL` | only for Jira | API-token credentials. Never commit them; `.env` is gitignored. |
| `HANDOVER_DIR`       | recommended | Path to your external handover repo. Or leave it unset and run `/handover-setup` once. Until one of the two is done there is no handover root, and handover commands stop with a clear message instead of writing to the wrong place. |

The Jira CLI needs only those four Jira variables, no cloud ID.
`JIRA_CLOUD_ID` is only for the optional Atlassian MCP server. The full list
is in [`.env.example`](.env.example).

Check the install. From the cloned himmel folder:

```bash
gh auth status                            # talk to GitHub
pre-commit run --all-files                # all hooks green
node scripts/jira/dist/index.js list      # only if you set up Jira
```

From the release tarball, run `gh auth status`, then `himmelctl status`,
which reports any part of the install that is missing or out of date.

Then run one full loop (worktree, commit, PR, merge, `/clean`, `/handover`)
with [`docs/daily-loop.md`](docs/daily-loop.md) open beside you.

## Support matrix

himmel runs on Linux and macOS. Windows (Git Bash or WSL) is not supported.

| Tier | Platforms | What it promises |
|---|---|---|
| **Supported** | Linux | Checked on every PR as a required check ([CI runs on `main`](https://github.com/yotamleo-org/Himmel/actions/workflows/ci.yml?query=branch%3Amain)). Installing into your own project and removing it again is tested. |
| **Supported** | macOS | Checked twice a week, not on every PR ([scheduled macOS runs](https://github.com/yotamleo-org/Himmel/actions/workflows/macos-cadence.yml?query=event%3Aschedule)). |

**Install channels:**

| Channel | Status |
|---|---|
| Release tarball (`himmel-<version>-linux.tar.gz` + `.sha256`) | **Supported** on Linux: the recipe above. A fresh machine installing from it is tested end to end. |
| `git clone` + `himmelctl install` | **Supported** on Linux and macOS. |
| Plugin marketplace (`marketplace/plugins/*`, one directory per plugin) | **Supported.** Installed, updated and removed by Claude Code itself (`claude plugin install/update/uninstall`), not by `himmelctl`. Includes [`himmel-ops`](marketplace/plugins/himmel-ops/README.md) (skills that load when a guardrail stops you and explain the way out), [`himmel-bus`](docs/himmel-bus.md) (a local message bus between sessions, early) and [`luna-correlate`](marketplace/plugins/luna-correlate/README.md) (an opt-in, offline health-factor correlation MCP). |
| AUR (`himmel`) | **Not on the AUR yet**; the recipe is in [`packaging/aur/`](packaging/aur/) (Arch). A package built from it installs to `/opt/himmel`; each user then runs `himmelctl install --scope user`, and `himmelctl update` defers to `pacman -Syu`. To remove: `himmelctl uninstall` for each user, then `pacman -R himmel`. |
| brew (Linux tap) | Not supported. |
| nix, deb, rpm | Not supported; open an issue if you need it. |

himmel's scripts run on macOS's built-in bash.

## Memory architecture

Your agent's working memory lives in files you can open, edit and correct.
Search indexes help it find those files; they do not replace them. The agent
can read a note alongside its links, decisions and reasons, then write back
to it.

Another approach extracts facts from conversations and files into a separate
database and retrieves matching facts rather than their source files. That
can be useful for very large collections where readers do not need to
inspect the originals. himmel instead keeps the files as the source so you
can inspect and fix what the agent uses.

What the memory is made of today, all plain files:

- **Auto-memory.** Claude Code keeps a per-project memory folder. himmel uses
  its `MEMORY.md` as a short index that *routes*: one line per theme, each
  pointing to a topic note that holds the detail. A session reads the index,
  then only the notes it needs.
- **Handover state.** Each piece of work has a markdown handover doc in your
  handover state repo (`$HANDOVER_DIR`): what was done, what was decided, what
  comes next. This is how work survives the end of a session. The state can
  live in your own repo or in a separate handover repo; see the
  [handover system](docs/internals/handover-system.md).
- **The luna vault (optional).** An Obsidian vault built from
  [`templates/luna-second-brain/`](templates/luna-second-brain/) holds notes,
  web clippings and daily entries that Claude reads and writes like any other
  markdown.

Two search tools sit on top. Neither replaces a file:

- **[qmd](https://www.npmjs.com/package/@tobilu/qmd)** is a local search
  engine over the markdown, using keyword ranking (BM25) and vectors. It
  returns a pointer to the source file, never a fact in its place. The index
  can be deleted and rebuilt at any time. The distinction is not whether
  search uses embeddings, but whether it leads back to the file.
- **graphify** builds a knowledge graph of the code (which file and function
  relates to which) and answers structure questions with `graphify query` and
  `graphify explain`. The graph is rebuilt from the source on a schedule.
  Building the graph can send code to an outside model; the
  [egress matrix](docs/internals/egress-matrix.md) lists which files may go to
  which provider.

### Companion vault tooling (optional)

If you run the vault in Obsidian, himmel ships and pins the tools to operate
it. None of them is needed by the core harness.

- **[obsidian-triage](marketplace/plugins/obsidian-triage/README.md)** (part of
  himmel) turns an Obsidian Web Clipper inbox into a knowledge base that keeps
  itself tidy: `/harvest-clips`, `/triage-clips`, `/synthesize-clips`,
  `/archive-clips`.
- **qmd** reaches Claude as an MCP server (`qmd@qmd`). The standalone CLI
  installs from himmel's qmd fork with `bash scripts/lib/qmd-bin.sh install`,
  which setup runs for you.
- **[claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian)**, pinned
  to an upstream release tag:
  skills to ingest, query and save notes, and to lint vault health
  (`wiki-lint`).
- **[obsidian (kepano)](https://github.com/kepano/obsidian-skills)**, pinned:
  the `obsidian-markdown` skill for Obsidian-flavored markdown.

Once you turn on the vault schedule (`/pipeline-cadence`), a vault check runs
every Sunday at 04:00; run `/obsidian-health` any time by hand.

## Features

Each feature below links to the page that explains it;
[`docs/README.md`](docs/README.md) lists every page.

**Core loop and enforcement**
- Worktree isolation with `/worktree`, `/clean`, `/clean_garden`:
  [`docs/commands-catalog.md`](docs/commands-catalog.md) and
  [`CLAUDE.md`](CLAUDE.md) (`## WORKFLOWS`)
- Pre-commit and Claude tool-call guardrail hooks, and the multi-agent PR
  review (`/pr-check`) that gates every merge:
  [`docs/internals/enforcement.md`](docs/internals/enforcement.md)
- Handover system (multi-repo registry, auto-branch, PR, flush):
  [`docs/internals/handover-system.md`](docs/internals/handover-system.md)
- Collision preflight: before you start a session,
  `bash scripts/handover/queue-lock.sh preflight <handover-doc> [file...]`
  warns you when a file you plan to change is already being changed in
  another session. It changes nothing.
- AFK (unattended) mode runs (`/afk-shift`, `/stop` to halt):
  [`docs/handover/afk-mode.md`](docs/handover/afk-mode.md)

**Lifecycle and delegation**
- `himmelctl` install, update and uninstall:
  [`docs/setup/updating.md`](docs/setup/updating.md)
- Handing work to cheaper or stronger Claude models, or to Codex, listed
  live by `/lanes`: [`docs/tooling-catalog.md`](docs/tooling-catalog.md)
- Running sessions in the cloud on your copy of the repo (`claude --cloud`):
  [`docs/setup/cloud-environment.md`](docs/setup/cloud-environment.md)
- Watchers that cost almost no tokens: `/morning-report` (git, GitHub and Jira
  state) and the `check-ci` merge-gate watcher:
  [`docs/commands-catalog.md`](docs/commands-catalog.md)
- Test VMs (osboxes, Multipass) driven by `/vm`:
  [`docs/setup/vms.md`](docs/setup/vms.md)

**Jira and forge**
- Jira CLI, a token-cheap local replacement for an MCP server:
  [`scripts/jira/`](scripts/jira/) and
  [`docs/internals/jira-plugin.md`](docs/internals/jira-plugin.md)
- GitHub and Bitbucket Cloud, detected from `origin`:
  [`scripts/bitbucket/`](scripts/bitbucket/) and
  [`plugins/himmel-gh/`](plugins/himmel-gh/)

**Knowledge (optional)**
- Vault capture and the clip pipeline (harvest, triage, synthesize, archive):
  [`marketplace/plugins/obsidian-triage/README.md`](marketplace/plugins/obsidian-triage/README.md)
- graphify and qmd: see [Memory architecture](#memory-architecture)

**Comms**
- Telegram bridge (start a session, check on it and chat with it from your
  phone): [`docs/telegram-bridge.md`](docs/telegram-bridge.md)

## Who is this for

Claude Code use tends to grow through four stages:

1. **Vanilla**: Claude Code as it ships. Boris Cherny, one of its creators,
   has described his own setup as "surprisingly vanilla".
2. **Customized**: your own skills and slash commands.
3. **Orchestrated**: parallel agents and a harness around them.
4. **Autonomous**: scheduled runs that work unattended, around the clock.

himmel is built for stages 3 and 4. If you are happy at stage 1, and many
excellent engineers are, you do not need it. It earns its complexity once you
run several sessions in parallel, want work done overnight, or want work to
build on itself across sessions without re-explaining the context each time.

## Setup details

- **A new machine, step by step:**
  [`docs/setup/new-machine.md`](docs/setup/new-machine.md) (required
  environment and per-platform notes).
- **Adopting himmel in your own repo:** the commands are in the
  [Quickstart](#quickstart); what each scope and install profile brings, and
  the checklist for your own repo:
  [`docs/setup/install.md`](docs/setup/install.md). Coming from an older
  install: [`docs/setup/migrating.md`](docs/setup/migrating.md).
- **Updating:** `/himmel-update` inside Claude Code, or `himmelctl update`
  from a shell. On a clone both run a `git pull` plus a marketplace re-sync;
  on the release tarball, use `himmelctl update`. Claude Code's own
  `autoUpdate` does not deliver himmel. `/luna-upgrade` upgrades a companion
  vault separately.
- **Uninstalling:** `node scripts/himmelctl/bin.js uninstall`. Preview it first
  with `uninstall --dry-run`, which touches nothing. It removes himmel's wiring and keeps your state unless you
  pass `--purge-state` ([details](docs/setup/install.md#uninstalling)). All of
  this in full: [`docs/setup/updating.md`](docs/setup/updating.md).
- **Global Claude Code config** (`~/.claude/`):
  [`docs/setup/global-claude-md.md`](docs/setup/global-claude-md.md).
- **Test VMs:** [`docs/setup/vms.md`](docs/setup/vms.md).
- **Status line:** a pinned
  [claude-hud](marketplace/plugins/claude-hud/VENDORED.md) shows live session
  and cost data ([`docs/tooling-catalog.md`](docs/tooling-catalog.md)).
- **Security review** before shipping code changes:
  [`docs/security-review.md`](docs/security-review.md).

## Docs site (local preview)

`bash scripts/docs-site/serve.sh` builds `docs/` with Starlight and serves it on
loopback only: open `http://127.0.0.1:4321/Himmel/`. Needs Node 22.22+ and
network on first run (`npm ci` in `site/`).

## Contributing

The workflow is in [`docs/contributing.md`](docs/contributing.md). In short:

1. All work goes through a PR; `main` is protected.
2. Conventional commits with the ticket in the subject:
   `type(scope): [PROJ-123] message`.
3. One worktree per branch (`/worktree <type>/<slug>`); never edit on `main`.
4. Pre-commit and pre-push hooks must pass.
5. A new shell script comes with a smoke test (`scripts/<area>/test-<thing>.sh`).
6. New shell scripts target bash and stay bash 3.2-safe, so they run on
   macOS's default bash.

## Project conventions

Commits follow Conventional Commits with a Jira ticket in the subject, and the
pre-commit hooks enforce the format. Worktrees live under
`.claude/worktrees/` and branches are named `<type>/<slug>` (`feat`, `fix`,
`chore`, `docs`, `refactor`, `test`). Branch protection, force-push gates,
platform attestation and the rules for headless Claude runs are all in
[`CLAUDE.md`](CLAUDE.md).

## License

himmel is licensed under the MIT License; see [`LICENSE`](LICENSE).

The vendored fork `marketplace/plugins/telegram-himmel` keeps its upstream
**Apache-2.0** license; see its `LICENSE` file. `scripts/cr/floor-reviewer.md`
is a modified copy of the Apache-2.0 `code-reviewer` agent from
`anthropics/claude-plugins-official` (see `THIRD-PARTY-NOTICES.md`).

Third-party attribution for vendored bundles and the dependency-license
audit (clean, fully permissive) is in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
