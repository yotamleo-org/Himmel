# jira-cli

The himmel Jira CLI. Run from the repo root as
`node scripts/jira/dist/index.js <op>`. ESM, arg-parsing via `commander`,
one file per op in `src/commands/`. Prefer this over the Atlassian MCP
server (cheaper per call, dogfoods shipped code).

## Build & test

```bash
cd scripts/jira
npm install
npm run build   # tsc → dist/ (gitignored)
npm test        # vitest
```

`JIRA_PROJECT_KEY` is required at runtime (no `HIMMEL` fallback). The CLI
auto-loads the repo-root `.env`.

## Verbs

`get`, `create`, `list`, `transition`, `transitions`, `comment`, `attach`,
`edit`, `projects`, `project-create` (plus `move`, `link`). Run
`node scripts/jira/dist/index.js --help` for the full option set.

To learn the site URL or where a setting comes from, run `jira config` (it lists
every Jira setting with its source; email and token show only as set or not set).
`get`, `edit`, `transition` and `move` also print a `browse:` link.

## MCP server

`jira mcp` boots a [Model Context Protocol](https://modelcontextprotocol.io)
server on stdio. It is a compatibility bridge over the CLI, for external MCP
clients. Each tool runs one fixed CLI verb as a child process (an argument
array, no shell) and returns what the CLI printed. The bridge has no Jira call
and no rule of its own, so an MCP call is refused, partial or confirmed exactly
as the same CLI call would be. Himmel's own agents use the CLI directly; the
Atlassian Jira MCP is denied to them.

Register it with your MCP client (replace `<himmel>` with the absolute path
to this repo): the command is `node <himmel>/scripts/jira/dist/index.js mcp`.

The tools require the same `JIRA_*` environment the CLI uses; the server
inherits them from the launching process / repo-root `.env`.
