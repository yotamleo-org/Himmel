# Fork pre-commit core

Every `yotamleo/*` fork is a himmel adapter (HIMMEL-5900). A commit to a fork
skips himmel's own gates, so a secret or an unticketed change can land on a
fork the station then installs. This page defines the small **core** every fork
gets, what stays himmel-only, and how a fork adopts it. Tracked in HIMMEL-5978.

The rule: the core is **security and process only**. It never imposes himmel's
lint or style on upstream code; a fork's own linters win.

## The core

| Hook | What it enforces | Source |
|---|---|---|
| `gitleaks` | no secret in a staged diff; anchored `^...$` allowlist for 40-hex and 64-hex SHAs | `gitleaks/gitleaks` `v8.30.1`, config `.himmel/gitleaks.toml` |
| `no-commit-to-branch` | no direct commit on the fork's default branch | `pre-commit/pre-commit-hooks` `v6.0.0` |
| `himmel-ticket-id` | commit subject is conventional and carries `HIMMEL-<n>` (only git-generated `Merge branch '…'`, `Merge pull request #…`, `Merge remote-tracking branch '…'` and `Revert "…"` subjects pass without one) | local `pygrep` hook, no script |

The pins match himmel's own `.pre-commit-config.yaml`, so the hook cache is
shared on a station and `pin-scan.py` sees one version of each.

Opt-in per fork, only where the fork already enforces it: `trailing-whitespace`
and `end-of-file-fixer`. They are not in the template because a fork whose
upstream does not enforce them would see a diff on every touched file.

## Himmel-only (stay in himmel)

| Hook | Why it stays |
|---|---|
| `shellcheck`, `fail-open-lint`, `no-history-comments`, `no-ticket-id-in-user-strings`, `vacuous-path-assert` | himmel's lint and style; a fork's code is upstream's |
| `worktree-isolation`, `merged-branch-check` | fork edits already go through a himmel branch; the core's default-branch refusal covers the real risk |
| `plugin-version-bump-required`, `template-version`, `doc-guard`, `agents-md-fresh`, `claude-md-budget`, `lanes-inventory-guard`, `guardrail-matrices`, `hook-lib-node-suites`, `trust-node-suites` | check himmel's own files (plugins, templates, docs, hook inventory); no meaning in a fork |
| `conventional-commit-msg` (`check-commit-msg.sh`) | reads himmel's `.env` ticket config and `scripts/lib`; the core's `himmel-ticket-id` is the portable subset |
| `leak-classes`, `artifact-leakage`, `git-env-scrub` | himmel's public-repo and vault leak classes |

## Delivery

Two files under `.himmel/` in the fork, copied from `templates/fork-precommit/`:

```
.himmel/pre-commit-config.yaml
.himmel/gitleaks.toml
```

Then, in the fork clone:

```
pre-commit install -c .himmel/pre-commit-config.yaml -t pre-commit -t commit-msg
```

Why this shape:

- `.himmel/` is a path upstream never writes, so `git rebase upstream/<branch>`
  has nothing to conflict on. A clone runs ONE pre-commit config: the install
  bakes its `-c` path into `.git/hooks/pre-commit`, and installing over a
  pre-commit-generated hook replaces it (no `.legacy` copy; only a non-pre-commit
  hook is backed up that way). So for a fork with its own
  `.pre-commit-config.yaml` (core and graphify), adopting this core stops that
  config running unless its hooks are merged in (see "Adopting a fork").
- Zero scripts: gitleaks and `no-commit-to-branch` are upstream repos, the
  ticket check is a `pygrep` regex. Nothing to vendor or keep in sync.
- Per fork, set `--branch` in `no-commit-to-branch` to the fork's default branch.

The hooks live in `.git/hooks`, which is per clone: adoption is two files in the
fork's himmel branch plus the one `install` line, run once per clone.

## Fork inventory (2026-10-16)

From `gh repo list yotamleo-org --fork`; the HIMMEL-5900 registry
(`scripts/guardrails/himmel-adapters.json`) lists every fork (standard:
`docs/internals/fork-adapters.md`).

| Fork | Default | Language | Own hooks | Own lint | CI |
|---|---|---|---|---|---|
| qmd | main | TypeScript | none | oxlint | yes |
| obsidian-second-brain | main | Python | none | `pyproject.toml` | yes |
| core (home-assistant) | dev | Python | `.pre-commit-config.yaml` | prettier | yes |
| claude-hud | main | JavaScript | none | `.editorconfig` | yes |
| graphify | v8 | Python | `.pre-commit-config.yaml` | `pyproject.toml` | yes |
| twitter-cli | main | Python | none | `pyproject.toml` | yes |
| home-assistant.io | current | HTML | none | `.editorconfig` | yes |
| hermes-agent | main | Python | none | eslint, prettier | yes |
| codex-plugin-cc, claude-obsidian, claude-video | main | JS / Python | none | none | yes |
| caveman | main | Go | none | `.editorconfig` | yes |
| codex | main | Rust | none | prettier | yes |
| effective-html, obsidian-skills | main | HTML / none | none | none | none |

Archived forks (`claude-statusline`, `claude-squad`) and the de-forked
`claude-obsidian` need no hooks.

## Adopting a fork

1. In the fork, branch from the himmel branch: `git checkout -b himmel/<ticket>-precommit`.
2. Copy both files from `templates/fork-precommit/` into `.himmel/`.
3. Set `--branch` in `.himmel/pre-commit-config.yaml` to the fork's default branch.
4. Run the `pre-commit install` line above, then make one ticketed commit.
5. Check a commit with a fake secret and a commit with no ticket ID are both
   refused (`scripts/hooks/test-fork-precommit-core.sh` does this against a
   scratch repo).
6. Open the fork PR through the himmel flow (judge, signed GO, chief merge).

A fork with its own `.pre-commit-config.yaml` (core, graphify) must keep its
hooks running: append that file's `repos:` entries to `.himmel/pre-commit-config.yaml`
(keeping the fork's file itself untouched, so rebases stay clean) before step 4,
and re-do the merge when upstream changes its config.

## Pilot

`yotamleo-org/qmd` on branch `himmel/fork-precommit-core`:
[PR 24](https://github.com/yotamleo-org/qmd/pull/24). qmd has no hook setup of its own and uses oxlint, so the core adds
no overlap.
