# Retrieval routing: the graphify graph

Reference for `_CLAUDE.md` ("Retrieval Routing"). Everything here applies only
while the vault graph is on and fresh; otherwise use qmd only.

## Turning the graph on

The graph is off by default (decision 449: graphify stays off the vault until it
proves better than qmd for its cost). It is on when its cadence is armed
(`bash "$HIMMEL_DIR/scripts/luna/graphmap-cadence.sh" arm --luna-only`, which
registers the `HIMMEL-GraphMap-Luna` and `HIMMEL-GraphMapAst-Luna` rows) and
`bash "$HIMMEL_DIR/scripts/graphify/check-graph-freshness.sh" --out
~/.local/share/himmel/graphify/luna/graphify-out` reads it fresh (rc 0).
`$HIMMEL_DIR` is the absolute path of your himmel checkout, the same variable
`/luna-upgrade` reads.

The graph lives **outside the vault**, at
`~/.local/share/himmel/graphify/luna/graphify-out/` (`GRAPHIFY_LUNA_OUT_ROOT`
overrides the root), because Obsidian hung on its churn inside the vault.

## Querying it

- `graphify query "<question>" --graph ~/.local/share/himmel/graphify/luna/graphify-out/graph.json`.
  The graph path must be the `--graph` flag: a positional directory is
  silently ignored and the query runs against the current directory's graph.
- The graphify MCP tools, when connected: always pass `project_path` set to
  `~/.local/share/himmel/graphify/luna` with the `~` expanded to your home
  directory (the tools do not expand it; without `project_path` the server
  uses its configured default graph, and a `GRAPHIFY_OUT` override changes the
  out dir name).
- The curated entry point is the graphify map note in `60-Maps/` (written by
  the graph refresh).
- Never `graphify path`: node IDs are file-scoped, so cross-file traversal is
  structurally broken; join `graphify query` results in-head instead.

## Escalation (documented, not applied)

If sessions keep defaulting to text search only, `graphify install --project
--strict` wires a hook that blocks the first raw file read per session until
one `graphify query` runs.
