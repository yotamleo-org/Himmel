fix(chief-kit): [HIMMEL-6829] status drift skips standing tickets and tickets with an open PR in another repo

status-drift.sh printed sdrift=4 on a clean shift, all of it false: the Dependabot standing ticket (label `standing`) stays In Progress by design with no single PR, and a ticket whose PR is open in another repo was reported UNOWNED, DERIVE-MISMATCH and WORKER-COMMENT because the check only reads PRs in this repo. The report now skips both cases. It stays report-only: no new transition, no auto-fix.
