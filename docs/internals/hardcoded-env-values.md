# Hardcoded environment values — inventory, config surface, lint

HIMMEL-6508. The org move (HIMMEL-6502) broke merges because a repo name was a
literal. This page is the inventory by value class, the one place values are
read from, and the lint that keeps new literals out.

## Inventory

Counts are `git grep -c -E` line hits on `main` at `7b06c7f39`, templates
excluded. Regenerate with the patterns in the third column.

| Class | Pattern | Runtime | Test/fixture | Doc | Disposition |
|---|---|---|---|---|---|
| repo-slug | `yotamleo-org/`, `yotamleo/(Himmel\|himmel\|qmd\|luna\|salus)` | 84 | 282 | 120 | Owned by HIMMEL-6495 and PR 3225 (HIMMEL-6516). Not edited here; the lint flags new ones. Fixtures stay literal. |
| owner-account | `yotamleo` | 172 | 458 | 161 | Superset of repo-slug. The remainder is identity (CODEOWNERS, author allowlists, git history); allowlisted by path or marker. |
| pages-url | `<owner>.github.io` | 8 | 5 | 7 | Migrated: `himmelctl` help text and `site/src/urls.mjs` (the site URL `astro.config.mjs` imports) derive from `GITHUB_REPOSITORY`, else git origin. The config UI's link to the product's own docs site carries `env-literal-ok`. Rest are vendored plugin bundles and docs. |
| ghcr-image | `ghcr.io/` | 2 | 0 | 3 | Migrated: `ci-image.yml` builds `ghcr.io/${{ github.repository_owner }}/himmel-ci`; the Dockerfile label names `ghcr.io/<owner>/himmel-ci`. |
| home-path | `/home/<user>` | 15 | 327 | 3 | Intentional: `/home/runner` is the CI runner user; `leak-classes.sh` is the detector itself. Fixtures stay literal. |
| jira-host | `<site>.atlassian.net` | 2 | 24 | 7 | `handover/pr-open.sh`: migrated to `JIRA_BASE_URL`. Rest are `.env.example` placeholders. |
| jira-field-id | `customfield_<n>` | 2 | 91 | 0 | Already config (`JIRA_*_FIELD` in `.env`); the two runtime hits are help text and an example. |
| machine-name | `OVERLORD8`, `cachyos-x8664` | 12 | 89 | 8 | All runtime hits are comments recording where a measurement was taken. Intentional history. |

Project keys (`HIMMEL`) are read from `JIRA_PROJECT_KEY` already and are not a
lint class.

## Config surface

`scripts/lib/env-value.sh` is the reader. Resolution order:

1. `~/.himmel/config.json` `.env_values.<KEY>` (operator-owned file)
2. the caller's discovery command (git origin, `gh`, `github.repository`)
3. fail closed (rc 1, nothing printed)

There is no environment seam: a security-sensitive value such as
merge-on-green's allowed public origin must not be settable by a launching
environment. Values already owned by `.env` (`JIRA_BASE_URL`) keep that home;
callers read them directly and do not route through this reader.

## Lint

`scripts/ci/check-hardcoded-env-values.sh [<base> | --staged | --tree]` scans
added lines for the audited classes and fails on a new literal:

- `<base>` (default `origin/main`, then `main`): the range `<base>...HEAD`;
  `PRE_COMMIT_TO_REF` replaces HEAD as the tip. No resolvable base is rc 2.
- `--staged`: the index.
- `--tree`: every tracked file at HEAD, every class except repo-slug (which
  HIMMEL-6495 owns).

It skips:

- paths listed in `scripts/ci/hardcoded-env-values-allow.txt` (tests, fixtures,
  docs, templates, vendored bundles, the detector files)
- comment-only lines and a line carrying `env-literal-ok: <reason>`
- `/home/runner`, the CI runner user

Wired in three places:

- pre-commit: the `no-new-hardcoded-env-values-staged` hook (`--staged`)
- pre-push: the `no-new-hardcoded-env-values` hook (range)
- CI `lint` job: the PR range, run from the BASE copy of the script and its
  allowlist, and `--tree` on every event from the checkout
