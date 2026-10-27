# Install profiles

Pick a starting point. You can move later.

The installer's first question is the install profile. An install profile
only fills in default answers. The installer still asks every question that
applies to your answers, so you can change any answer as you go. Nothing is final: you can run the
installer again, switch scope, or undo the whole install.

The install profile is one of three separate choices. The second is the
scope: [this project, or every project](#this-project-or-every-project).
The third is the plugin set:
[more or fewer plugins](#more-or-fewer-plugins).

## The four install profiles

Every install profile sets up the guardrails, which refuse risky moves before
they run, the git gates, and worktrees, so every change gets its own folder.
The bullets under each one are the answers it fills in for you. The word in
code is the answer as the installer shows it.

### `starter`, the default

Guardrails, git gates and worktrees for this project. Use it for any repo,
and for the practice climb on the
[adoption trail](../../adoption-trail-levels.html#trial).

- **Notes vault:** `none`. With no vault, the installer skips the vault
  questions and the Telegram bridge question.
- **Session notes:** `inline`, kept in this repo's own `handovers/` folder.
- **Always-on machine:** `no`.
- **Scheduled jobs:** none picked. The installer still lists any job your
  other answers allow, unticked.
- **Telegram bridge:** `off`. It is not asked without a vault.
- **Voice-note model:** `small`. It is asked only when the bridge is on.

### `luna`

Starter plus a second brain, a notes vault. Use it for Level 2 and up on the
[adoption trail](../../adoption-trail.html).

- **Notes vault:** `default-template`, a new vault made from the template.
  You can point at a vault you already have instead.
- **Session notes:** `inline`, kept in this repo's own `handovers/` folder.
- **Always-on machine:** `no`.
- **Scheduled jobs:** none picked. With a vault, the installer offers the
  notes pipeline, the search index and the map jobs; you tick the ones you
  want.
- **Telegram bridge:** `off`, and asked, because you have a vault.
- **Voice-note model:** `small`. It is asked when you turn the bridge on.

### `custom`

Every question from scratch. Use it when neither starter nor luna fits. It
fills in only the installer's plain defaults:

- **Notes vault:** `none`.
- **Session notes:** `inline`, kept in this repo's own `handovers/` folder.
- **Always-on machine:** `no`.
- **Scheduled jobs:** none picked.
- **Telegram bridge:** `off`. It is not asked without a vault.
- **Voice-note model:** `small`. It is asked only when the bridge is on.

### `operator`, the full stack (contributors)

Based on a setup that runs every day: the whole stack on, with an existing
vault and session notes kept in a repo of their own. The installer offers it
only when you run it with `--contribute` from a git clone of himmel.

- **Notes vault:** `existing`, the vault you already have.
- **Session notes:** `external`, kept in a separate repo you name.
- **Always-on machine:** `yes`. The installer prints the checklist for a
  machine that runs jobs while you are away; it does not change the machine
  itself.
- **Scheduled jobs:** `pipeline`, `qmd` and `graphmap` picked: the notes
  pipeline, the search index and the map.
- **Telegram bridge:** `on`.
- **Voice-note model:** `large-v3-turbo`.

Every answer is a setting you can change later. The
[Settings page](../../configuration.md#change-one-setting) lists each one
with its command.

## This project, or every project?

The second question is the scope.

- **`project`, the default.** The install lives in this repo's own
  `.claude/` folder. Install again in each other project you want it in.
- **`user`.** The install lives in `~/.claude/` and applies once, to every
  project you open.

## Where every answer lives

| What | Where | Change it with |
|---|---|---|
| Your install answers | `~/.claude/himmel/install-profile.json` (in `$HIMMELCTL_CACHE_DIR` instead, if you set it) | the installer, or `--from-profile` to replay them |
| Hooks and the status line | `.claude/settings.json` (project scope) or `~/.claude/settings.json` (user scope) | `himmelctl scope set` |
| Which plugins are on | `~/.claude/settings.json`, whichever scope you install | `himmelctl profile …` |
| Commit rules | `~/.himmel/himmel.conf` | the tracker questions, `himmelctl config set commit.tracker`, or edit the file |
| Vault, scheduled jobs, Telegram | `~/.himmel/config.json` | the installer, again |
| Secrets | a file only you can read (mode 0600), never the answers file | the installer's secrets step, run from a plain terminal |
| Four working principles: think first, keep it simple, change only what the task needs, check the result | `~/.claude/CLAUDE.md`, whichever scope you install, so a scope move leaves them alone | edit the file; uninstall removes the block |

## Move between them

### See where you are

```bash
himmelctl status
himmelctl gaps
```

`status` compares what is installed with what your answers ask for. Run it
from your project's folder for project scope. `gaps` lists what this setup
does not have compared with the reference machine: your own "no" answers,
questions you never saw, and things no question can set up yet. It is a
report and never blocks anything.

### Change install profile

```bash
himmelctl install
```

Run the installer again and pick another install profile. It prints the plan
and asks `Proceed? [Y/n]` before it changes anything.

Checked on a test VM (a bare Ubuntu machine, project scope): a `starter`
install, then `himmelctl install` again, picking `luna` and accepting the
plan. The second run finished with exit code 0 and changed these:

- The answers file went from `profile: "starter"` to `profile: "luna"`. Its
  vault changed from `none` to the default template at `~/Documents/luna`, and
  it gained the luna, Telegram bridge and scheduled-job answers.
- The notes vault was created at `~/Documents/luna` from the luna template. A
  `luna` search collection was added.
- In the project, no file was added or removed. `.claude/settings.json` gained
  `LUNA_VAULT_PATH`, which points at the new vault.
- The second install asked more than the first: the vault path, where VM
  checks run, a longer list of scheduled jobs, two health-data questions and
  the Telegram bridge. With the defaults accepted, every scheduled job and
  the bridge stayed off, and the install stayed uncommitted.

`himmelctl status` right after the move showed 2 red and 2 degraded items. Both
red items came from the bare test machine, not from the move: `pre-commit` was
not installed (the machine had neither `uv` nor `pipx`) and no search daemon
(`qmd`, optional) was running.

Scheduled jobs you armed before the move are not turned off for you; the
installer prints the command to disarm each one.

### Change scope

```bash
himmelctl scope set user --dry-run
himmelctl scope set user
```

The first command prints the plan. The second wires the new scope and
unwires the old one, after you confirm. `himmelctl scope get` prints the scope
you are on. If an item would end up wired in both scopes, the command refuses
and changes nothing.

### More or fewer plugins

```bash
himmelctl profile full
himmelctl profile lean
himmelctl profile enable humanizer@himmel
```

`lean`: only the everyday plugins are on. The rest stay installed but off, so
sessions start small. `full`: all of them are on, so more is ready and every
session starts bigger. `enable` turns on just one; `himmelctl profile list`
shows each plugin and whether it is on. The plugin set applies to your whole
user, not one project.

### Same setup, another machine

```bash
himmelctl install --from-profile install-profile.json
```

Copy `~/.claude/himmel/install-profile.json` (or `install-profile.json` in
`$HIMMELCTL_CACHE_DIR`, if you set it) across first. The answers file
records only whether each secret is set, never its value, so set the secrets
again on the new machine.

### Back out

```bash
himmelctl uninstall --dry-run
himmelctl uninstall
```

The first command lists every file, plugin, hook and setting it would remove,
and touches nothing. The second removes himmel. Your Telegram pairing and
bridge state stay unless you add `--purge-state`.

`himmelctl` is the launcher the install puts in `~/.local/bin`. It is the
same as `node ~/himmel/scripts/himmelctl/bin.js`, where `~/himmel` is your
himmel download.

## For contributors: the install profile files

The `.install-profile.json` files in this folder are covered on
[The install profile files](../../internals/install-profile-files.md).
