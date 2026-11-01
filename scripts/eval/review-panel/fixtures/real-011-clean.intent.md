fix(console): [HIMMEL-7064] admit residuals only on RM rows, read .env HANDOVER_DIR, resume Stories

next-dispatchable.sh admitted a residual into a version on any ledger row that was not a deferral, so a kind-less intake row admitted it. Only an `rm-admit` or `override` ledger row admits now. The ledger path reads `HANDOVER_DIR` from the .env when the live environment has none. A wrapped To Do Story with a resume brief is offered as a RESUME row; an Epic or a Sub-task still is not.
