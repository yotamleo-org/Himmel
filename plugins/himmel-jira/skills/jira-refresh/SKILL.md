---
name: jira-refresh
description: Refresh the Jira metadata cache ("refresh jira metadata", "jira cache is stale").
---

Run `/jira-refresh`. It re-fetches projects, issue types, and transitions into `himmel-cli/jira/metadata.json` under `$XDG_CACHE_HOME` (default `~/.cache`).
