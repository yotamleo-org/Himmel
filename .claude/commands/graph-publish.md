---
description: Publish the live graphify graph to graph-data.
argument-hint: [--dry-run] [--base <branch>] [--no-fetch]
---

Publishes this station's live graph to the **graph-data** branch, where adopters
fetch it instead of paying for their own semantic pass. A repo that does not
track `graphify-out/graph.json` (himmel itself, the steady state) runs
`scripts/graphify/graph-cadence.sh` and exits with its code. With no `--semantic`
the cadence makes **no model call**: when the live graph in `graphify-out/` is
newer than the graph-data tip and carries a semantic layer (a
`semantic-manifest.json` with at least one stamped file), it is scanned by
`publish-graph-channel.sh` (gitleaks and a host-path check) and pushed. A paused
semantic step therefore cannot leave the branch behind a graph that is already
built. When the branch is current, or the live graph has no semantic layer, the
run is a skip and nothing is pushed.

`--dry-run` prints the exact command it would run (`bash <graph-cadence.sh>`) and
exits 0 without running it.

The PR flow below applies **only to a repo that still tracks
`graphify-out/graph.json`**: it publishes a locally-refreshed
`graphify-out/graph.json` (+ `GRAPH_REPORT.md`) by opening or refreshing a PR. It
refuses cleanly when there is nothing newer than the shipped (committed) graph,
and refuses if the working tree has uncommitted changes outside the two graph
paths. The PR is machine-generated and never gets a CodeRabbit App review: do not
post a review-trigger comment on it and do not park on the CR gate. `check-ci.sh`
classifies the PR from its diff shape (every changed path is a tracked
`graphify-out/` artifact) and treats the absent App review as expected;
checks-green and unresolved-thread gating still apply.

Run:

```bash
bash scripts/graphify/graph-publish.sh $ARGUMENTS
```

Common invocations:
- `/graph-publish` — publish the live graph to graph-data (tracked-graph repo: open or refresh its PR).
- `/graph-publish --dry-run` — preview what would happen without running anything.
- `/graph-publish --base develop` — tracked-graph repo only: target a non-default base branch.

Environment:
- `GH_CMD=<cmd>` — override the gh binary (tracked-graph path; tests use a fake).
- `GRAPH_PUBLISH_BASE=<ref>` — default base branch. Default: `main`.
- `GRAPH_PUBLISH_CADENCE=<path>` — the `graph-cadence.sh` the untracked-graph path runs (tests use a recorder).

Exit codes:
- Untracked-graph repo (graph-data path): the exit code of `graph-cadence.sh` (`0` published or skipped, `3` a worker failed, see its header); `--dry-run` always exits `0`.
- `0` tracked-graph path: published — commit pushed AND the PR was opened/refreshed
- `1` usage error
- `2` required tool missing (git or gh)
- `3` no local graphify-out/graph.json on disk
- `4` no longer returned: a repo that doesn't track graphify-out/graph.json runs graph-cadence.sh instead
- `5` nothing newer to publish (local graph == shipped graph)
- `6` working tree has uncommitted changes outside graphify-out/{graph.json,GRAPH_REPORT.md}
- `7` cannot resolve a base ref
- `8` checkout/commit/push failed
- `9` pushed, but the PR step did NOT complete (forge undetectable, or `gh pr create`/`gh pr edit` failed) — branch is pushed; open the PR manually
- `10` graphify-out/manifest.json is missing — refresh-graph-map.sh's transaction marker is absent, so graph.json/GRAPH_REPORT.md may be an inconsistent pair; re-run refresh-graph-map.sh first
- `11` graphify-out/GRAPH_REPORT.md is missing while graph.json is present — refresh-graph-map.sh always promotes both together, so this is anomalous (report deleted after a completed refresh?); restore GRAPH_REPORT.md or re-run refresh-graph-map.sh, then retry

On the tracked-graph path `--dry-run` implies `--no-fetch` (no git/gh calls at all, network included).
