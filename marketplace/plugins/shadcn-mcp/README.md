# shadcn-mcp

himmel-owned wrapper plugin (HIMMEL-4012) that exposes the official shadcn/ui
registry MCP server to the `design` profile. Upstream ships no Claude plugin,
only the `shadcn` npm CLI (`npx shadcn mcp`, docs: https://ui.shadcn.com/docs/mcp,
repo https://github.com/shadcn-ui/ui, MIT).

- No API key. The server reads and writes a project's `components.json`
  registry only when asked.
- `npx` downloads the package from npm on first use.
- The version pin lives in `.mcp.json` (`shadcn@4.21.0`); bump it by hand in a
  PR (no drift row: the npm tag shape is not tracked by `check-plugin-drift.sh`).

## motion-budget skill (HIMMEL-5708)

`skills/motion-budget` is the design core's short animation note: the duration
table, the under-300ms rule and the frequency principle, credited to Emil
Kowalski (https://x.com/emilkowalski/status/2110429909160264027). It follows
that tweet, so modals read 200-300ms and page transitions 300-400ms; the full
`emilkowalski-skills` (`--profile design,design-motion`) say modals 200-500ms
and have no page-transitions row.
