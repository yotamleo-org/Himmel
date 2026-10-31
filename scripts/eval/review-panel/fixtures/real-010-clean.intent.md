fix(chief-kit): [HIMMEL-8028] the dispatcher counts a Done-category status as done

`next-dispatchable.sh` compared Jira status names only, so a ticket in `wont do` or `wont fix` (Jira category Done) still counted as open. A mirror row whose `statusCategory` is `Done` counts as done; the status-name list stays as a fallback, and every done check goes through one `done_key()` helper. A done-category blocker is still live-read. The `--dispositions` list drops done-category tickets and keeps open ones. Ticket proof: each behaviour above has a test row that goes RED on the base.
