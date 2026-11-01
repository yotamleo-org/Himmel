# What changes on your machine

This page lists every file, hook and setting a starter install writes on Linux
or macOS: where each one goes, who owns it, and what `uninstall` does with it.
The rows come from
[`scripts/install/uninstall-manifest.tsv`](../../scripts/install/uninstall-manifest.tsv),
the list the uninstaller itself reads, and a test fails when that list gains a
row this page does not show.

Knowing the way back is part of deciding to try:
[Undo the install](updating.md#undo).

How to read the columns:

- **Where:** *project* is your project folder; *user* is your home folder, so
  it applies to every project on this machine.
- **Owner:** *himmel* is himmel's own code and wiring; *you* is your data or
  your own settings; *another tool* is what another program wrote.
- **Uninstall:** what `himmelctl uninstall` does with it. `--purge-state` is
  the flag that also removes your data ([detail](updating.md#undo)). Each
  cell is what a run that finishes does. When a step cannot finish, the item
  stays and the run says so: for example a bridge unit with no `systemctl` to
  disable it, a file you changed since the install, or a crontab the run
  cannot read.
- **Row:** the manifest row, so you can find it in the uninstaller's own
  preview.

Paths are the defaults. Each row of the manifest also names the setting that
moves it, for tests and non-default installs.

## Every starter install

| What | Path | Where | Owner | Uninstall | Row |
|---|---|---|---|---|---|
| Three git hooks: pre-commit, commit-msg and pre-push | `.git/hooks/` | project | himmel | Removed | `git-hooks` |
| Any hook of yours the install displaced, saved as `<hook>.himmel-backup` | `.git/hooks/` | project | you | Restored to `<hook>` when that name is free, otherwise kept beside the current hook; never deleted | `git-hook-backups` |
| himmel's hooks, status line and `env` keys | `.claude/settings.json` | project | himmel | Removed; keys himmel did not add stay | `project-settings` |
| Helper scripts copied into the project (project scope) | `scripts/` | project | himmel | Kept, except the copies the install record lists, which are removed; drop the rest with git | `adopter-scripts` |
| The Claude Code plugins of your plugin set | recorded in `.claude/settings.json`, or in `~/.claude/settings.json` at user scope | project or user | himmel | Removed, the ones the install record lists | `plugins` |
| The marketplaces those plugins come from | `~/.claude/plugins/` | user | himmel | Removed once no installed plugin needs them | `marketplaces` |
| himmel's hooks, status line and `env` keys (user scope) | `~/.claude/settings.json` | user | himmel | Removed; a status line or `HANDOVER_DIR` the install record does not list is kept, with the command to remove it by hand | `user-settings` |
| A working-principles block appended to Claude Code's user rules (user scope) | `~/.claude/CLAUDE.md` | user | himmel | Stripped; the rest of the file is untouched and a copy as found is kept beside it | `user-claude-md` |
| The same block in Codex's user rules (user scope) | `~/.codex/AGENTS.md` | user | himmel | Stripped the same way | `user-agents-md` |
| The status-line config | `~/.claude/claude-hud.json` | user | himmel | Removed while it is still himmel's | `hud-config` |
| A trust entry for the project, so Claude Code does not ask again | `~/.claude.json` | user | himmel | Removed while it is still himmel's own; an entry you had before is kept | `workspace-trust` |
| The installer's cache: your install answers, update-check stamps and launch records | `~/.claude/himmel/` | user | himmel | Removed | `himmelctl-cache` |
| The install record: every write, and a backup of each file it replaced | `~/.himmel/provenance.jsonl`, `~/.himmel/provenance-backups/` | user | you | Kept; `--purge-state` removes them | `provenance-ledger` |
| A copy of the uninstaller, so undo still works after you delete the download | `~/.himmel/uninstall/` | user | himmel | Kept; `--purge-state` removes it, last | `standalone-uninstaller` |

The install also writes a `himmelctl` launcher and a `himmel` alias to
`~/.local/bin`. Neither is a manifest row. After a successful teardown,
`himmelctl uninstall` removes the `himmelctl` launcher if it carries himmel's
marker, and never touches one it did not write. It leaves the `himmel` alias
in place: delete `~/.local/bin/himmel` yourself.

## Only if `bun` is installed

| What | Path | Where | Owner | Uninstall | Row |
|---|---|---|---|---|---|
| The qmd search tool and an index of your himmel download | `~/.himmel/qmd-fork` | user | himmel | Kept; `--purge-state` removes what this install created | `qmd-fork` |

qmd's search models (about 2 GB) live in qmd's own cache and are listed under
[Never touched](#never-touched).

When the qmd plugin's launcher in `~/.claude/plugins/cache/qmd/qmd/<version>/bin/qmd`
is broken, setup patches it in place and keeps the original beside it as
`bin/qmd.orig`. Uninstall keeps the patch: undoing it would bring the broken
launcher back.

## Only when you turn it on

A starter install leaves these off. Each appears once you set up the Telegram
bridge, arm a scheduled job, declare a personal or medical vault in setup, or
let setup save your commit rules and other answers.

| What | Path | Where | Owner | Uninstall | Row |
|---|---|---|---|---|---|
| The Telegram bridge process | — | user | himmel | Removed: stopped, not deleted | `bridge-process` |
| The Telegram bridge's systemd user unit (Linux) | `~/.config/systemd/user/telegram-bridge.service` | user | himmel | Removed: disabled, then deleted | `bridge-unit` |
| Your Telegram pairing: the bot token and the access list | `~/.claude/channels/telegram/` | user | you | Kept; `--purge-state` removes it, never while the bridge is running | `telegram-channel` |
| The bridge's sessions, inbox and outbox | `~/.claude/handover/bridge/` | user | you | Kept; `--purge-state` removes it, never while the bridge is running | `telegram-bridge` |
| `HIMMEL-Resume-*` jobs that resume a session later | your cron and `at` queue | user | himmel | Removed | `scheduled-jobs` |
| The scheduled jobs you armed | your crontab | user | himmel | Removed, by the exact names the install record holds | `cadence-jobs` |
| The pipeline job's runner scripts | `~/.claude/pipeline-cadence/` | user | himmel | Removed | `cadence-pipeline-dir` |
| The qmd refresh job's runner scripts | `~/.claude/qmd-cadence/` | user | himmel | Removed | `cadence-qmd-dir` |
| The graph-map job's runner scripts | `~/.claude/graphmap-cadence/` | user | himmel | Removed | `cadence-graphmap-dir` |
| The list of jobs a health check expects to see run | `~/.himmel/observability.json` | user | himmel | Removed | `observability-registry` |
| The personal or medical vault you declare, so local guards keep it away from cloud backends | `~/.config/claude-glm/phi-roots` | user | himmel | Not removed yet: uninstall leaves these lines in place | `phi-roots` |
| Your behaviour settings, such as the commit rules setup writes when you say yes; on a luna install it is a link into the vault | `~/.himmel/himmel.conf` | user | you | Kept; `--purge-state` removes it, and a link loses only the link, never its vault target | `himmel-conf` |
| Your per-machine overrides of those settings | `~/.himmel/himmel.conf.local` | user | you | Kept; `--purge-state` removes it | `himmel-conf-local` |
| The answers setup saves, such as the vault path and VM mode, and the shared gate policy | `~/.himmel/config.json` | user | you | Kept; `--purge-state` removes it, and a gate whose policy is gone then refuses | `himmel-config-json` |
| The backups taken before each config write; each one holds a copy of your `.env` | `~/.himmel/state/config-audit/backups/` | user | himmel | Removed; the log beside it, which holds key names only, stays | `config-audit-backups` |

If you also say yes to the `.salus` marker and the vault folder already
exists, setup creates an empty `.salus` file in it. If the folder does not
exist yet, setup still records the vault and tells you to create the marker
yourself once the folder exists. Uninstall leaves the marker there.

## Never touched

| What | Path | Where | Owner | Uninstall | Row |
|---|---|---|---|---|---|
| The himmel download, its `.env` and its worktrees | wherever you cloned it, for example `~/himmel` | user | you | Never touched: delete it yourself, after the uninstall | `himmel-clone` |
| Every `settings.json` key himmel did not add: your MCP servers, your own hooks | `~/.claude/settings.json` | user | you | Never touched | `foreign-settings` |
| Your handover notes and their registry | `~/.claude/handover/registry.json` and your handover folders | user | you | Never touched | `handover-registry` |
| Caches other tools wrote while himmel ran: npm, node-gyp, bun, Claude Code's plugin cache, qmd's models | `~/.npm/_cacache`, `~/.cache/node-gyp`, `~/.bun/install/cache`, `~/.claude/plugins/cache` | user | another tool | Never touched: clear them with each tool | `third-party-caches` |

## Where to go next

- See the same list for your own machine, with real paths, before you change
  anything: `node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run`
  ([Undo the install](updating.md#undo)).
- Keep himmel but change what it does:
  [install profiles](profiles/README.md) and
  [settings](../configuration.md).
