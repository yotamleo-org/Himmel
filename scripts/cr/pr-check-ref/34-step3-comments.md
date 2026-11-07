# /pr-check reference: step 3.7: comment review

   **Step 3.7 — Comment review on code diffs; runs in the full lane, after the reviewer stage (3.5).** The deterministic comment lint (`scripts/lint/check-history-comments.sh`) refuses ticket keys and review-round notes, but not narration, banners or commented-out code. This step has a sonnet agent read the comments the diff adds and report which to delete. Gate 4g of `scripts/cr/clear-review-marker.sh` refuses to clear a full-lane marker (exit 14, `reason=missing-comment-review`) whose diff adds a code comment until the branch has a `comments` row.

   **When it runs.** Count the added code comments over the branch diff (`<db_sha>` and `<head>` are step 3.0's values, carried forward as literals):
   ```bash
   bash "<himmel_dir>/scripts/lint/check-history-comments.sh" --range <db_sha> --tip <head> --count-comments
   ```
   It prints one integer. `0` means the step ends here and no row is owed. A non-zero exit or a non-integer is a stop: report it, never treat it as 0 (the gate refuses closed on the same condition, `reason=comment-review-unreadable`).

   **The diff file.** Print the branch diff with zero context lines (the agent reads nearby code itself), then save that output unchanged to a scratch path in the session scratchpad with the Write tool, since a fence may not redirect and git's `--output` option is refused by the fence guard:
   ```bash
   git diff -U0 --no-color --no-ext-diff <db_sha> <head>
   ```

   **The dispatch.** Use the Agent tool with `subagent_type: himmel-ops:comment-review` and `model: sonnet`. The prompt names exactly two paths: the charter `<himmel_dir>/.claude/agents/comment-sicko.md` and the diff file above. The agent has Read, Grep and Glob only, reports and deletes nothing, and ends with `COMMENT-REVIEW <n>`.

   - The Codex lane has no `Agent` dispatch: record the skip with `--status off --reason codex-lane`.
   - If the Agent tool reports that `himmel-ops:comment-review` is not a known agent type (the plugin is not loaded in this session), record `--status off --reason agent-not-loaded` and say so in the report. Any other reason is refused by `ledger-append.sh`.

   **The findings.** Each `[comment-sicko-N] path:line kill|MUST KILL <symbol> — <reason>` line is a candidate. Adjudicate it as step 3.2 does a panel candidate, with one `VERDICT [comment-sicko-N] = agreed|disproved|conflict|unaddressed|deferred -> <TICKET>` line each, through `write-verdicts.sh`:
   - An agreed `kill` is an Important finding: delete the comment in this PR, then re-run this step at the new head.
   - An agreed `MUST KILL` is Important too, but it may be deferred with a ticket (`deferred -> <TICKET>`), because the fix is a rename, extract or restructure of code outside the diff's purpose.
   - A finding you disprove needs evidence from the code, as in step 3.2: a keep clause of the charter that holds on a live path today.

   **The row.** Record the review at the head it ran on, with `<n>` the number on the agent's `COMMENT-REVIEW` line:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" comments --head <head> --count <n> --status ok
   ```
   or, for a skip:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" comments --head <head> --status off --reason codex-lane
   ```
   The gate accepts a row at the clearing head, or at an earlier head when no comment was added since (it counts the added comments from that row's head to the tip). A commit that adds a comment after the row needs a new review and a new row. The clear audits `comments=ok`, or `comments=off reason=<r>` for a skip.
