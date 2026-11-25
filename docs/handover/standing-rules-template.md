# Standing rules

This station's working rules, one per line, each in force. The chief edits this file
when a ruling settles into a lasting rule; the operator corrects it, and a correction wins.
himmel seeded it from its shipped defaults at the first chief start and never overwrites it.

## Placement and versions
1. Put what the operator asks for into the current release and do it now; defer only on an explicit "later" or "next release".
2. When the operator names a version, use that version.
3. Place any other ticket by priority: High and Highest into the current version, below High into the backlog.
4. Give every ticket a version or the backlog label.
5. Finish the current version before a later one; fill workers from the current version.
6. Merged code belongs to the version open when it merged, whatever the ticket said before.
7. Place by need against the version's goals; never gate on time or counts; file every owed ticket.
8. Give a user-facing bug current-version priority.
9. On a red main, keep current work going and fix main in parallel; hold the fleet only if the red blocks the work itself.
10. Never let a later-version ticket block a current-version ticket.
11. Release or tag only after the operator approves and the board is empty.

## Review
12. Cap spec review rounds at three; give a small change no big review loop.
13. Send the operator only what is theirs to sign: a spend grant, an account or terms change, public policy, a reversal of their own ruling, a change to a project rule file, or relaxing a guard.
14. Show the operator a page only after a critic passed that revision; lead with a short summary.
15. Merge a PR only on the chief's GO after the ready check passes; report a failed check, never force it.
16. For every red on main, write down the gap that let it through and file a structural fix ticket.
17. Run outside contributors' code only on a test VM, after a full review.
18. Avoid code comments; keep ticket ids out of code, doc headings and the built UI.
19. Measure CI by wall-clock time to green.
20. Have an independent judge check audit findings, then fix them without waiting for the operator.

## Spend
21. Size a paid run first, prove it small first, and get approval with a cap; take anything more than a quarter over the cap back to the operator.
22. Cut the burn: slim sessions that hand off, fewer monitor wakes, no context nobody needs.
23. Raise effort before tier; use the top tier for one hard problem, with a stated reason.
24. Audit tools for cost against value; turn off one that measures badly.

## Workers
25. Keep the fleet full and let nothing wait forever; wake by code, never by an idle window.
26. Treat an In Progress ticket with no live worker as a chief defect.
27. Send installs, risky tests and contributor code to a test VM first.
28. Run design work in a worker; run routine commands in the chief itself.
29. Use one PR per ticket; split a big PR by default.
30. Grant a hook bypass per session, never for the whole fleet.
31. Do small operator requests on the way, with no ticket ceremony unless a gate needs a key.

## Operator authority
32. Take the operator's plain words as enough: a short or misspelled reply is a decision, and "recommended", "defaults" or "yes" accepts every recommended answer; never ask for special wording.
33. Show the operator things rather than ask them to sign; keep the "blocked on you" list real and shrinking.
34. Decide chief-ownable work in the chief; treat a command the operator has to run as a regression.
35. Show the operator the list before any destructive action.
36. Message the operator only when they must act.
