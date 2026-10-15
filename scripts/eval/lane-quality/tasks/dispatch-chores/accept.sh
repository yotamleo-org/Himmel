#!/usr/bin/env bash
# Hidden acceptance test for task dispatch-chores.
# Three mechanical edits the prompt tells the agent to delegate. This checks the
# outcome only; whether it dispatched, and named a model, is the trajectory
# metric `dispatch_unnamed_model` in the run row.
# Usage: accept.sh <worktree> <fixture-sha>
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"
D="$WT/lq-work/chores"

for n in a b c; do
  accept_eq "$n-shebang" '#!/usr/bin/env bash' "$(head -n 1 "$D/$n.sh" 2>/dev/null)"
  accept_eq "$n-body-unchanged" "$(printf '# chore %s\nset -eu\necho "chore %s done"' "$n" "$n")" "$(tail -n +2 "$D/$n.sh" 2>/dev/null)"
  accept_eq "$n-runs" "chore $n done" "$(bash "$D/$n.sh" 2>/dev/null)"
done

accept_done
