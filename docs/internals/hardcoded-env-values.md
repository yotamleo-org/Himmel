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
| pages-url | `<owner>.github.io` | 8 | 5 | 7 | `himmelctl` help text: migrated (derived from origin). `site/astro.config.mjs` is held by another leg: deferred. Rest are vendored plugin bundles and docs. |
| ghcr-image | `ghcr.io/` | 2 | 0 | 3 | `.github/workflows/ci-image.yml` and the Dockerfile label: workflow edit is out of this PR's scope; deferred. |
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

`scripts/ci/check-hardcoded-env-values.sh [<base>]` scans the **added lines** of
`<base>..HEAD` (default `origin/main`) for the audited classes and fails on a
new literal. It skips:

- paths listed in `scripts/ci/hardcoded-env-values-allow.txt` (tests, fixtures,
  docs, templates, vendored bundles, the detector files)
- a line carrying `env-literal-ok: <reason>`

Wired as the `no-new-hardcoded-env-values` pre-push hook. The CI job is not
wired yet: `ci.yml` is single-writer and HIMMEL-6557 carries it.
