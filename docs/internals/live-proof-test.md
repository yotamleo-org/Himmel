# Live-proof test — when a ticket may be Done

A ticket that ships a feature is Done only when the feature works in the real
fleet. A passing suite or a fixture shows the code path is correct; it does not
show the fleet runs it. The ticket standard (`marketplace/plugins/himmel-ops/skills/ticket-standard/SKILL.md`)
names the proof a ticket owes; this page defines what counts as a live proof
row, so a Done-truth audit can apply the same test to an already-Done ticket.

## The test

A live proof row is a command run against the real station or fleet (the
primary checkout at main, the running service, a real session, the real
ledger), with its output pasted in the ticket's Results or comments. It must:

1. run against main or the running system, not a scratch copy or a fixture;
2. name the command, so a reader can re-run it;
3. show an observable the feature produces (a status, a file, a log line, a
   delivered message), not an exit code alone;
4. be able to fail: the same command on the state before the change, or with
   the feature off, gives a different result.

A suite row, a fixture screenshot, or "the PR merged" is not a live proof row.

## Per kind

| Kind | Live proof row |
|---|---|
| Service or daemon | the unit is active and answers the request it exists for (`systemctl --user is-active <unit>` plus one request) |
| Hook or guard | the guard fires on a real denied call in a session, and stays silent on an allowed one |
| Script in the ship loop | run it on a real PR, doc or ticket and show the output |
| Cadence or ledger | the newest ledger row is newer than the last run and carries the new field |
| Docs, config, pin | the value on main matches the claim (`git grep` line) |

## Applying it to a Done ticket (the audit)

1. Read the Proof section and the merge comment of the ticket.
2. Run the row for the kind, from the primary checkout at main.
3. Row passes: the ticket is OK. Record the row in the audit table.
4. Row fails, or the feature is absent on main: reopen the ticket with the
   failing output as the comment. Reopen only on concrete evidence; a row you
   could not run is `not verified`, never a reopen.
5. Never reopen a ticket a live worker owns; message that worker's chief instead.

The reverse direction: a merged PR whose ticket is not Done, with every Done-when
item evidenced on main, is closed with the evidence in the comment. A merge
comment that says the ticket stays open is not a missing Done.
