fix(ci): [HIMMEL-6256] shellcheck PR-range lints only the PR's own diff against its merge base, in parallel

On a pull_request run HEAD is the merge ref, so the PR's change is `HEAD^1...HEAD^2`; elsewhere it is `base...HEAD`. A rerun reuses a stale base.sha, so main commits merged forward are no longer re-linted. The neighbour closure of the changed files is computed in one pass from a single grep of the tree's source lines, and the selected set goes through the existing component-sharded parallel sweep. Selection and lint timings are printed.
