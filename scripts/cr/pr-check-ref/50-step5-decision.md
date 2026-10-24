# /pr-check reference: steps 5 / 6 / 6.5: gate decision, marker clear, footer

5. If step 4.9 did not already clear the marker, and `N == 0` AND step 4.8 reported `threads_rc = 0` AND step 3.6 reported `impacted_rc = 0` (every suite that references a changed file has a verdict — HIMMEL-2821), clear the marker via
   the chokepoint — **never a bare `rm -f <marker>`** (HIMMEL-1064). Substitute
   step 0's printed `branch=` literal, SINGLE-quoted (HIMMEL-2226 — this is a
   pasted, shell-parsed operand, and a git ref may legitimately contain `;`,
   `$` or a backtick):
   ```bash
   bash "<himmel_dir>/scripts/cr/clear-cr-marker.sh" '<branch>'
   ```
   A raw `rm` of `cr-pending/<branch>` is byte-identical to the
   self-declare-clean pattern the auto-mode classifier flags as **[CI Bypass]**,
   so it is reliably DENIED — the classifier cannot see that `/pr-check` really
   ran. That denial is structural: EVERY clean run hit it, leaving a stale
   marker that later blocks `gh pr create` on a branch whose CR was actually
   clean. The script does not take this session's word for the verdict: it
   re-derives it from what the step-4.5 ledger recorded at this exact SHA
   (a critic actually responded + zero blocking findings), plus check-ci when a
   PR already exists — so it is strictly STRONGER than the `rm` it replaces.
   - Exit 0 → report its `CR clean — marker cleared …` line VERBATIM. Under `CR_REQUIRE_CROSS_MODEL` that line states the clearing basis: a plain one means a non-Claude lane reviewed the SHA; one reading `… ON THE SAME-MODEL FLOOR …` means the context-free Claude floor cleared it and the PR has no cross-model coverage (HIMMEL-3108) — never shorten it to "CR clean".
   - Any non-zero → the marker STAYS and the gate is NOT clear; treat it as
     step 6. Notably `14` = no critic responded at this SHA (a MISSING review
     signal, e.g. a rate-limited or timed-out critic — never a clean one) and `13` =
     a commit landed after the review, so re-run `/pr-check` on the new HEAD.
     Do NOT fall back to `rm`.

   **Promote agreed findings to fixed (HIMMEL-2911).** Once the marker cleared
   above, terminalize every finding still `agreed` on this branch:
   ```bash
   bash "<himmel_dir>/scripts/cr/review-round.sh" promote --branch '<branch>' --head <head>
   ```
   Paste its summary line. Exit 0 = done. Exit 3 = it printed each
   `still-open <id>@<sha>` finding it left `agreed` — a genuine re-raise, a
   same-head or non-ancestor commit, or a finding it could not safely check —
   name those in the report and never hand-amend one of them to `fixed`. Any
   other non-zero (a malformed ledger row, an unresolvable `--head`, or a
   ledger write failure) is an infrastructure failure, not a
   per-finding one: STOP, report the exact stderr line, repair the cause, and
   re-run `promote` — never hand-amend anything as a workaround.
   A `still-open <id>@<sha> (unadjudicated)` line (HIMMEL-2917) means a
   finding row with no effective verdict after applying amendments — nobody
   dispositioned it at all. A
   finding fixed within THIS round must be amended `fixed` at step 4.5,
   naming the fixing sha, never left with no verdict for `promote` to find
   later. The summary line is not evidence the ledger is clean until every
   row prints as `promoted` or `skip-terminal`.

6. If either `N > 0`, or step 4.8 reported `threads_rc != 0`, or step 3.6 reported `impacted_rc != 0`:
   - Leave the marker in place.
   - Surface the Critical / Important findings (and any unresolved-thread count, and every impacted suite still missing a verdict) to the user.
   - **Route each finding (HIMMEL-6303).** Fix each in-scope Critical or Important finding, and each finding in the version's priority pool, in this PR and run it through a round. Defer a genuinely out-of-scope Critical or Important finding only through step 4.5, with its ticket, `fu_class`, and finding reason. After the round cap, fix Critical and escape-class Important findings; defer classified-hardening Important findings and suggestions/nits only through the cap disposition, with the required ticket and reason. Every suggestion/nit still needs an explicit fixed, deferred, or disproved disposition. A change that does land clears on a signed judge GO at its exact head (`review-round.sh judge-go`, step 3.0), never on a new full round.
   - **A Suggestions-only round 2 or later closes the loop (HIMMEL-7345).** When step 3.0 printed round 2 or 3 and every open finding at this head is a Suggestion or nit (no Critical or Important left open), leave those Suggestion/nit rows unamended in step 4.5 and run step 4.9's `review-round.sh defer` instead of another round: it defers each Suggestion to a follow-up ticket through the cap disposition and clears the marker. It does this only for the branch's one open PR, headed at this head, whose changed files match no pattern in the default branch's `scripts/ci/ci-trust-paths.txt` (the `trust_path_check` merge-on-green runs). On a trust-path PR, with no open PR, or on any refusal it exits 2 and the round-4 cap stays in force: fix the Suggestions in a round as before.
   - Instruct: address the findings, commit fixes, resolve the addressed PR threads, then re-run `/pr-check`. Fix the whole round in ONE commit and ONE push (never a WIP push), and make any PR title/body/`## Ticket coverage` edit in that same step, not after CI is green: every push re-runs CI and an edit re-queues `pr-title-lint` and `codeowner-review-gate`. (A new commit invalidates the SHA in the marker too, but the marker is still present until `/pr-check` clears it.)

6.5. **Critic-score footer (append after the gate decision in steps 5/6).** Emit a per-model verdict tally for this run plus the cumulative agreed% from the ledger:
   ```bash
   bash "<himmel_dir>/scripts/cr/cr-scores.sh"
   ```
   For any critic slug that appeared in the panel registry but whose
   `panel-availability:` line was `unavailable` (or absent entirely), append an
   **"absent this run"** note next to that model's row so the operator can see
   transient drop-outs. If the ledger has no records yet (first run),
   `cr-scores.sh` prints `no critic scores recorded yet` — emit that verbatim
   rather than suppressing it.
