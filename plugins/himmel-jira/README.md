# himmel-jira

Thin Claude Code plugin wrapping `scripts/jira/` CLI through `scripts/himmel-run/`.

## Install

The plugin lives in this repo. Add via:

```
/plugin install ./plugins/himmel-jira
```

## Auth file location

`/jira-init` writes `JIRA_EMAIL`, `JIRA_API_TOKEN`, and `JIRA_BASE_URL` to (all three are required):

- `<repo-root>/.env` if that `.env` file already exists at the repo root; otherwise `~/.config/himmel-cli/jira.env`.

The file is `chmod 600`.

## Commands

- `/jira-init` — bootstrap auth + metadata cache (run once per machine).
- `/jira-list [project] [status]` — list issues.
- `/jira-get <KEY>` — show one issue.
- `/jira-create <type> "<title>"` — file issue.
- `/jira-transition <KEY> <status>` — transition issue.
- `/jira-comment <KEY> "<body>"` — add comment.
- `/jira-refresh` — re-fetch metadata cache.

Each command has a matching skill that auto-triggers on Jira intent.

## Logs

The metadata cache is written to `$XDG_CACHE_HOME/himmel-cli/jira/` when `XDG_CACHE_HOME` is set, otherwise `~/.cache/himmel-cli/jira/`. Inspect any run:

```
himmel-run jira --inspect <run-id-from-summary-line>
```
