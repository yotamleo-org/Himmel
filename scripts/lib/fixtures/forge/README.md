# forge contract fixtures (HIMMEL-4762)

Replayed by `scripts/lib/test-forge-contract.sh` through the `GH_CMD` and
`BITBUCKET_CMD` stubs. No test here talks to a network.

## github/

Recorded 2026-10-12 with read-only `gh` calls against the public repo
`yotamleo/Himmel`, then scrubbed to the fields the backend requests:

| file | recorded with |
|---|---|
| `repo-view.json` | `gh repo view yotamleo/Himmel --json nameWithOwner,defaultBranchRef` |
| `pr-list-open.json` | `gh pr list -R yotamleo/Himmel --state open --json number` (one row kept) |
| `pr-view.json` | `gh pr view 2464 -R yotamleo/Himmel --json number,headRefOid,baseRefName,title,state` |
| `pr-checks.json` | `gh pr checks 2464 -R yotamleo/Himmel --json bucket,name` (first four rows kept) |

## bitbucket/

**Not recorded: there is no Bitbucket account.** These files are built by hand
from the documented Bitbucket Cloud REST 2.0 response shapes
(`GET /repositories/{workspace}/{repo_slug}` and
`GET /repositories/{workspace}/{repo_slug}/pullrequests[/{id}]`), as projected
by the himmel `bitbucket` CLI (`scripts/bitbucket/src/client.ts`: `RepoInfo`,
`PrInfo`, `PrIngestInfo`). The workspace, repo and every value are invented.
