# Chief section — proof rows

Read on demand from `chief-sections/live-state.md`, when a `pool-disposition:` row is tagged `proof`.

Once the listing carries it, a row tagged `proof` is dispatched to a `kind: proof` worker (gen-briefs), never run by the chief. A row re-tagged `proof` always dispatches a new proof worker; an earlier verdict never stands in for it. The latest `PROOF VERDICT` comment, read before dispatching, only tells you what the last run found.

- **On CLOSE:** check the evidence file's rows against the proof Contract's rules (every row MET with a quoted artifact, three empty reads). If they pass, do not close the ticket (decision 847): write `pool-disposition: <KEY> close decision 847 operator-owed: PROOF VERDICT CLOSE evidence=<path>` in Live state, which the tracker lists under Waiting on you, and close only on the operator's words. If they fail, treat it as KEEP.
- **On KEEP:** replace the text the row was tagged from with the KEEP slice's Writes line in the same action: the `Writes:` line of the description, or, when `--why` names `remainder of PR #n`, that PR's `Remaining:` line (one `gh pr edit <n> --body-file <file>`), so the row lists as an ordinary one.
