# /pr-check reference: step 4.5: ledger append

4.5. **Ledger append (runs after verdict extraction, before the step 5/6 gate decision).** Single-writer: only this orchestrator step writes the ledger.

   **Availability records are ALWAYS appended — never skipped (HIMMEL-1064).** The step-5 chokepoint requires at least one `avail … status=ok` at this HEAD to certify that a review actually happened, so a reviewer that responds CLEANLY (zero findings) must still be recorded — otherwise the gate reads "no responders" and refuses (exit 14) on a genuinely clean review. Findings are what varies; availability is what proves the review ran. In particular:
   - A critic that responded with zero findings → still record `avail --status ok`.
   - A critic that failed / rate-limited → record `avail --status unavailable`. That is a MISSING signal, and the chokepoint treats it as such.
   - **Claude-only path** (`CR_PROFILE=none`, or every cross-model critic unconfigured, absent or skipped — an attempted critic that failed is recorded `unavailable`, not covered by this row): you performed the step-3.5 backstop review yourself, so record THAT as the evidence — `bash "<himmel_dir>/scripts/cr/ledger-append.sh" avail --branch '<branch>' --head <head> --model claude --status ok`, substituting step 0's printed literals — plus a `finding` record per blocking issue you found. Without it the claude-only mode can never clear its own marker. **(HIMMEL-1224 — this row IS the Claude-only floor: on a zero-external-critic adopter it is the ONLY `avail … ok` row, and what makes the gate adopter-portable. It is the escape hatch for lane ABSENCE — it is NOT written for a lane that ATTEMPTED and failed, which records `unavailable` instead per HIMMEL-1126.)**
   - **Docs-audit lane** (step 2.5): it skips the full step-3 matrix, so record the docs audit you performed the same way (`--model claude --status ok`, plus a `finding` per `[ACCURACY|DEAD-LINK|STALE|EXAMPLE|CONSISTENCY]` blocker — `[CONSISTENCY]` is Important per step 2.5, so it blocks too and must be recorded, or the chokepoint sees zero blockers and clears despite it). Use the FULL SHA step 0 printed as `head=` — the docs-audit lane reviews the same captured SHA the full lane does. When `CR_REQUIRE_CROSS_MODEL` was truthy, also record `docs-audit-panel.sh`'s `panel-availability:` rows (from its **stderr**) and its adjudicated findings (from its **stdout**), exactly like the full lane records `panel-first-pass.sh`'s two streams. If every cross-model critic is unavailable, record those `unavailable` rows and say the marker will stay closed under `CR_REQUIRE_CROSS_MODEL`; do not use an undocumented override. A docs-only push DOES write a marker (lane `docs-audit`), so without these records the docs lane can never clear it either (HIMMEL-2026).

   Rule of thumb: **every path that completes a review records exactly one availability row for the reviewer that did it.** If a path can reach step 5 with zero `avail … ok` rows at this HEAD, the chokepoint refuses (exit 14) and the lane is unshippable — that is the bug this list exists to prevent.

   Only the per-finding VERDICT loop below is a no-op when the step-3.0 panel's stdout is empty (there are no cross-model findings to adjudicate) — the availability records above still run.

   **The producers already wrote these rows — you only record the VERDICT
   (HIMMEL-2321).** `critic-panel.sh` has always self-written every panel
   finding through `ledger-append.sh --batch-file`. So by the time
   you reach this step the finding rows for `[<slug>-N]`
   ALREADY EXIST at this head, carrying the reviewer's own
   file, line and text — written by the producer process that received them,
   never retyped. What is missing from each row is the one thing a producer
   cannot know: your adjudicated verdict.

   That is the whole point of the ticket. The old form of this step pasted
   `--file '<file>' --line '<line>'` — and, at the 4.6/4.7 sites below, the
   finding TITLE — into a shell fence as substituted literals. A critic's
   title legitimately contains an apostrophe (`doesn't`, `the script's`), which
   closes the surrounding quote and hands the rest to the shell; HIMMEL-2226
   closed three instances of this class at their root and the ticket is explicit
   that escaping is the wrong fix, because prose cannot fire before the shell
   parses pasted text. Recording only a verdict removes the last reviewer-authored
   byte from these fences: an id and a closed-vocabulary word, nothing else.

   For each `[<slug>-N]` Critical,
   Important or Suggestion finding you adjudicated, call — `<head>` from step 0,
   `<slug>-N` single-quoted (the id embeds a reviewer-supplied slug), the
   verdict unquoted (a fixed word set), and `--reason` a FIXED LITERAL you write
   yourself, never reviewer text:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" amend \
       --head <head> --id '<slug>-N' \
       --set verdict=<agreed|disproved|conflict|unaddressed> \
       --reason 'adjudicated by /pr-check step 4.5'
   ```
   A `deferred` verdict additionally carries its ticket, its follow-up class
   and the reason the gate reads (`--set verdict=deferred --set
   deferred_to=HIMMEL-<n> --set fu_class=<escape|hardening|polish> --set
   'reason=<why out of scope>'`; without a class the append exits 2) — see the deferral paragraph below, whose
   `--set reason=` is a different field from `amend`'s own `--reason`.
   A `disproved` verdict on a finding whose text names a shell or platform
   (dash, bash, zsh, busybox, macOS, git-bash, ...) is refused with the generic
   `--reason` alone: it needs your OWN measurement, written yourself, naming
   each such shell with a version — `--set 'reason=measured on <shell>
   <version>: <what it showed>'`. Run the check on the real binary; the
   refusal prints this form.

   **`amend` refusing is a real signal — do not fall back to `finding`.** It
   exits non-zero when no matching finding exists at that head, which means the
   producer's self-write did not happen: an unpinned producer run (no `--head`,
   so it refuses to guess what it reviewed), a failed ledger write, or a head
   you mistyped. In every one of those cases the row you are trying to adjudicate
   is genuinely absent, so treat it exactly as the paragraph below treats any
   failed append — the marker stays and you fix the cause. Re-appending it as a
   `finding` would recreate the retyping surface this step exists to remove, and
   would stamp reviewer text you retyped over a row the producer never wrote.

   **The session's OWN findings still use `finding`, and that is not an
   inconsistency.** On the Claude-only backstop and the docs-audit lane above,
   there is no producer — YOU are the reviewer, so there is no prior row to
   amend and no reviewer-authored text to protect: the file, line and severity
   are yours. Those paths keep the `finding` verb with `--model claude`, exactly
   as the two bullets above describe.

   For each `panel-availability:` line the step-3.0 `panel-first-pass.sh` (or,
   in the docs-audit lane, the step-2.5 `docs-audit-panel.sh`) printed on its
   **stderr**. **These rows come off stderr
   now, not out of a shell variable (HIMMEL-2226):** a script cannot hand
   `$panel_avail_lines` / `$docs_audit_panel_avail_lines`
   back to the calling session, so the lines that used to be captured into
   those variables are printed instead. Format (unchanged):
   `panel-availability: <slug> ok` for responders, or
   `panel-availability: <slug> unavailable (rc=N) reason=<class>` for drops), call.
   Parsing: the slug is the 2nd whitespace-delimited token and the status is
   the 3rd token (`ok` or `unavailable`) — ignore any trailing suffix, whether
   `(rc=N)` or `(timeout Ns)`. Either way the 3rd token is still
   `unavailable`, so the rule yields the right status regardless of the
   suffix. (HIMMEL-2704 retired two suffix forms this used to enumerate —
   the CLI's own `(rc=N)` shape and the conservation gate's `(conserved)` —
   so ignoring the suffix rather than matching it is now the whole rule.)
   Normalize `fallback(<model>)` (HIMMEL-729 quota-exhaustion fallback — the
   critic DID respond, via its fallback model) → `ok`; a `fallback-failed`
   line accompanies an `unavailable` line for the same slug — record only the
   `unavailable`. Pass `--status` as exactly `ok` or `unavailable`.

   **Reason capture (HIMMEL-1176), OPTIONAL — never blocks on a parse miss.**
   The critic panel (`critic-panel.sh`) appends
   a `reason=<class>` token AFTER the existing `(rc=N)`/`(timeout Ns)`
   suffix (append-only — the old suffix is untouched, so any
   prior parsing that only reads the 2nd/3rd tokens keeps working unchanged).
   When an `unavailable` line carries a `reason=<class>` token, extract it
   (whitespace-delimited, no internal spaces) and pass `--reason <class>` on
   the `ledger-append.sh avail` call below. A `detail=<text>` token, when
   present, is the REMAINDER of the line — it is critic-supplied free text,
   already visible on the process's own stderr line, so it is NOT re-pasted
   into a fence (HIMMEL-2321): doing so would reopen the last
   reviewer-authored-text-through-a-shell-fence surface this ticket closes,
   for no gain over what the printed line already shows. A line with no
   `reason=` token (e.g. an older critic build,
   or a lane not yet wired) omits `--reason` entirely — this is the default,
   fully back-compat path; do not invent a reason. `<class>` is a LITERAL you
   substitute; drop the `--reason` word itself when you have none, rather
   than passing an empty value (HIMMEL-2226 — the conditional-expansion form
   the fence used is refused by the worktree-isolation guard, and there is no
   shell variable to expand from anyway):
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" avail \
       --branch '<branch>' --head <head> \
       --model '<slug>' --status <ok|unavailable> \
       --reason '<class>'
   ```

   **Ledger persistence is a PREREQUISITE for clearing, not best-effort
   (HIMMEL-1064).** It used to be advisory, which was safe while the ledger was
   only a scorecard — but step 5's chokepoint now DERIVES its verdict from these
   records, so a partial write is a gate hole: if an `avail … ok` row persists
   while a blocking `finding` append fails, the chokepoint sees "a responder and
   zero findings" and clears the marker on a review that actually found a
   blocker. Check the exit status of EVERY `ledger-append.sh` call. If any append
   fails, do NOT invoke `clear-cr-marker.sh` — treat the run as step 6 (marker
   stays), surface the failure, and re-run once the ledger is writable. An
   unrecorded finding must never read as no finding.

   The ledger is deduped on `(head, finding_id)` for findings and `(head, model)`
   for avail records, so re-running `/pr-check` on the same HEAD is safe.

   **Record the head the finding was RAISED AGAINST (HIMMEL-1294).** `--head`
   is the SHA the critic reviewed, not the SHA that fixes it. Keying a finding
   onto the fixing head makes gate 4 block a commit that already resolved it,
   and the fix then requires an `amend` (below). Across multiple pushes, where a
   review lands against an earlier head than the commit carrying the fix, this
   is easy to get wrong — take the head from the review, not from
   `git rev-parse HEAD`.

   **A genuinely out-of-scope blocking finding is DEFERRED, never downgraded
   (HIMMEL-1294).** When a `crit`/`imp` finding is real but out-of-diff,
   pre-existing, or out-of-scope for this branch, do NOT record it as `sug` and
   do NOT claim `disproved` — both are false, and the gate used to leave no
   other mechanical exit. File a ticket and record the disposition with
   `amend`, not `finding` (HIMMEL-2321): the producers self-write every
   finding row, so the row for `<slug>-N` already exists at this head,
   carrying its own file/line and text — a deferral changes only the verdict,
   never re-supplies what the process that received the finding already
   wrote. Re-pasting `<file>`/`<line>` into a fence would reopen the last
   reviewer-authored shell surface HIMMEL-2321 closes:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" amend \
       --head <head> --id '<slug>-N' \
       --set verdict=deferred --set deferred_to=HIMMEL-<n> \
       --set fu_class=<escape|hardening|polish> \
       --set 'reason=<why it is out of scope for this branch>' \
       --reason 'deferred by /pr-check step 4.5'
   ```
   (`--set reason=` is a DIFFERENT field from `amend`'s own `--reason` — the
   gate reads the finding's `reason`; `--reason` records why the row
   changed.) Gate 4 accepts a deferral ONLY with both the ticket key and the
   reason — a bare `deferred` still blocks, so this is a truthful third exit,
   not a free pass. The deferral is printed and audit-logged when the marker
   clears.

   **Correcting a record: `amend`, never a re-append (HIMMEL-1294).** Findings
   dedup on `(head, finding_id)`, so re-appending with different content writes
   nothing. That used to exit 0 silently — the caller believed the severity was
   fixed while the gate kept reading the original — and it wedged the
   HIMMEL-1291 loop twice. It is now a loud non-zero pointing here:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" amend \
       --head <head-the-finding-is-CURRENTLY-recorded-at> --id '<slug>-N' \
       --set severity=sug --reason '<why the original record was wrong>'
   # or re-key a mis-keyed finding onto the head it was raised against:
   #   --set head=<raised-against-sha>
   # or defer it after the fact — `--set reason=` is required and is NOT the
   # same field as `--reason` (which says why the RECORD was wrong; the gate
   # reads the FINDING's reason). The whole --set operand is single-quoted,
   # not just its value: the free text after the `=` is pasted, so it is
   # shell-parsed the same way any other substituted literal is.
   #   --set verdict=deferred --set deferred_to=HIMMEL-<n> --set fu_class=<escape|hardening|polish> --set 'reason=<why out of scope>'
   ```
   `amend` APPENDS a supersede record — the ledger stays append-only and the
   correction is itself auditable. It refuses non-zero when no matching finding
   exists, so it can never report success without writing. Never hand-edit
   `.git/cr-critic-scores.jsonl`.

4.6/4.7. **Handover bridges — reviewer-notes capture (HIMMEL-416 F2 / C2) and the CR→bug-tracker lifecycle (HIMMEL-446). Run alongside 4.5; best-effort, graceful skip when there is no active handover item, and they NEVER block the gate.** 4.6 mirrors the findings into the current work-item's `reviewer-notes.md` so CR results survive the session (the F1 ledger is machine state; this is the human-readable trail surfaced on resume). 4.7 gives Critical/Important findings a tracked **open→resolved lifecycle** in the item's `bugs.md`, closing the CR-ledger / bug-tracker / handover triangle.

   **These were the last two sites that put reviewer-authored text through a
   shell fence, and they no longer do (HIMMEL-2321).** The old steps had you
   substitute a finding's TITLE and SYMPTOM — CodeRabbit's and the critics' own
   prose — into `--title '<one-line finding title>'` and a tab-separated
   `printf` row. A title legitimately contains an apostrophe (`doesn't`, `the
   script's`), which closes the surrounding quote and hands the rest to the
   shell; 4.7 additionally had you hand-build two temp files with an
   append-vs-truncate rule (`>>` not `>`) that silently dropped findings when
   an editor got it wrong. Both are now one call: `scripts/cr/handover-bridge.sh`
   reads the rows the producers already wrote to the ledger and invokes
   `scripts/handover/append-cr-findings.sh` / `append-cr-bugs.sh` with **argv
   built in-process**. argv is inert — it is never re-parsed by a shell — so
   there is no escaping rule to get right and none was invented. Neither
   handover script needed to change.

   Resolve the active item ONCE via a single script call, substituting step
   0's printed `branch=` literal. The rc branching itself lives inside the
   script now, not in this fence (HIMMEL-3707: guard-pr-check-literal.sh reads
   a `case` statement's bare `*` default arm as an unresolved
   scripts/handover/ writer operand whenever the same command also invokes a
   scripts/handover/ script, denying this exact fence — the same class of fix
   HIMMEL-2321 applied to the reviewer-notes/bugs writers below). It
   normalizes the exit code STRUCTURALLY rather than leaving the
   graceful-skip claim to prose (HIMMEL-195): rc 0 prints the item dir —
   carry it forward as a literal below — rc 3 prints an explicit SKIP line,
   and any other rc a distinguishable error on stderr; neither blocks steps
   5/6:
   ```bash
   bash "<himmel_dir>/scripts/handover/resolve-active-item-report.sh" --branch '<branch>'
   ```

   When that printed an item dir, run the bridge ONCE — it does both halves.
   `<head>` and `<branch>` are step 0's printed literals (never re-derived: the
   ledger rows are keyed on the SHA the review actually certified, HIMMEL-1175);
   `<today>` is today's date as `YYYY-MM-DD`; the two paths are built from the
   printed `<item-dir>` and are SINGLE-quoted like any repo-derived value. Drop
   `--pr <n>` entirely when there is no open PR rather than passing an empty
   value:
   ```bash
   bash "<himmel_dir>/scripts/cr/handover-bridge.sh" \
       --head <head> --branch '<branch>' \
       --notes '<item-dir>/reviewer-notes.md' --bugs '<item-dir>/bugs.md' \
       --date <today> --pr <n>
   ```

   It prints one summary line naming what it did (`handover-bridge: N
   finding(s) -> reviewer-notes, M blocking + K avail row(s) -> bugs.md`).
   Relay that line in the `/pr-check` report.

   **What it does, so a reader does not have to infer it from the script.** It
   reads every `finding` row at this head, applying any `amend` supersession
   first — so a finding adjudicated to `deferred` is seen as deferred, and an
   amend that re-keys a row onto another head moves it, exactly as
   `clear-cr-marker.sh` evaluates the same records. 4.6 receives every severity
   (`crit`, `imp` AND `sug` — `append-cr-findings.sh` records all three; only
   the blocking COUNT in step 4 excludes `sug`). 4.7 receives only `crit`/`imp`
   findings that are still open: one adjudicated to `disproved` or `deferred`
   is NOT an open blocker and is excluded, so it can never open or reopen a bug
   for a finding the round already dispositioned. **A run with zero blocking
   findings still calls the bugs bridge** — that is the normal clean-review
   state, and `append-cr-bugs.sh` resolves vanished tracked bugs off the
   availability rows, which is precisely what a clean run must do. Nothing is
   ever fabricated to fill a row.

   Both halves are **deduped** (`append-cr-findings.sh` skips a `(head, id)`
   already present; `append-cr-bugs.sh` dedups by finding-id and reopens a
   resolved bug whose finding reappears), so re-running `/pr-check` on the same
   HEAD adds nothing. Errors are best-effort throughout: a missing
   `reviewer-notes.md`, an unwritable state repo, or an unreadable ledger logs
   to stderr and the bridge still exits 0, so steps 5/6 are never blocked.
