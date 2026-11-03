# himmel-jira

Thin Claude Code plugin wrapping `scripts/jira/` CLI through `scripts/himmel-run/`.

## Install

The plugin lives in this repo. Add via:

```
/plugin install ./plugins/himmel-jira
```

## Auth file location

`/jira-init` needs `JIRA_EMAIL`, `JIRA_API_TOKEN`, and `JIRA_BASE_URL` (all three are required). The plugin reads each from the first of these that holds it: the environment, `~/.himmel/himmel.conf` (`JIRA_EMAIL` and `JIRA_BASE_URL`), the credentials directory, the OS keyring, and last the `.env` file.

When the OS keyring is unlocked and `scripts/lib` is next to the plugin (a himmel checkout), `/jira-init` stores the token in the keyring and writes no token line. Otherwise (locked keyring, or the plugin installed alone) it writes all three to:

- `<repo-root>/.env` if that `.env` file already exists at the repo root; otherwise `~/.config/himmel-cli/jira.env`.

The email and base URL are written there either way. The file is `chmod 600`. A token held in the keyring wins over a token in `.env`; replace it with `himmel-secrets put --stdin JIRA_API_TOKEN`, not by editing `.env`.

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

The metadata cache (`metadata.json`) is written to `$XDG_CACHE_HOME/himmel-cli/jira/` when `XDG_CACHE_HOME` is set, otherwise `~/.cache/himmel-cli/jira/`. `himmel-run` keeps its `normal.log`, `error.log` and run index in the `himmel-cli/jira/` directory under its own cache root (`env-paths`: the same path on Linux, `~/Library/Caches` on macOS). Inspect any run:

```
himmel-run jira --inspect <run-id-from-summary-line>
```
