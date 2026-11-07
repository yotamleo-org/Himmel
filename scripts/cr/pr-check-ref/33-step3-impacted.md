# /pr-check reference: step 3.6: impacted suites

   **Step 3.6 — Impacted suites: one verdict per suite (runs in BOTH lanes — the docs-audit lane of step 2.5 skips step 3 but not this).** PR #2261 changed `scripts/machine-setup/uninstall-plugins.sh` and merged with `scripts/test-uninstall.sh` — the suite one directory up that drives it end to end — never run: the implementor swept the owning directory, this command certified, and nothing computed *which suites reference what the PR changed*. This step is that computation. It is a gate, not advice: a missing verdict makes the row NOT clean.

   `<base>` is step 3.0's `<db_sha>` (carried forward like `<head>`; the script takes the merge-base itself). In the docs-audit lane there is no step 3.0, so the docs-audit base is the PR's base branch as `origin/<base-branch>`, where `<base-branch>` is step 0's `base=` value (never step 0's `branch=`, the head branch: `origin/<head branch>..<head>` is empty once the branch is pushed and the step would pass vacuously) — `origin/main` for himmel. Both halves are 40-hex / a fixed literal, so the range `<base>..<head>` stays unquoted (see the quoting rules above).

   ```bash
   bash "<himmel_dir>/scripts/cr/impacted-suites.sh" <base>..<head>
   ```

   It prints every test suite (`**/test-*.sh`, `*.test.mjs`, `*.test.js`, `*.test.ts`) whose text references the basename of a file this PR changed — or, for a slash command or skill, `/<name>` — plus every suite the PR itself changed, one repo-relative path per line. **Print that list in your report row as `impacted suites (N): <paths>`.** An unresolvable range exits 2: treat that as BLOCKED for the whole step, never as an empty list. Then give EACH listed suite one verdict (a suite CI runs is run once, in CI). **The station runs little and CI runs the rest (decision 775): a worker runs locally the suite its PR changed, with that suite's failing-first proof, plus the suites that cannot go to CI, each with a named reason.** Print the split first, it is computed, not judged: `bash "<himmel_dir>/scripts/cr/impacted-suites.sh" --plan <base>..<head>`. Each line is `LOCAL <path> (<reason>)` or `CI <path>`. A `LOCAL` line is one of: a suite the PR changed (`changed: failing-first proof required`: run it red before the change and green after, and show both; the plan only prints this instruction, no gate checks it); a suite CI does not run (the reason is `suite-coverage.sh`'s own words, e.g. `not run in CI (SKIP_LIST)`); a suite that is not a `test-*.sh` (`*.test.mjs` / `.js` / `.ts`: `no per-suite CI proof`, until a follow-up gives ready-check item 19 one). Every `CI` line is left to CI: do not run it "to be safe" and do not run a neighbouring suite because it sits near the change. Once a follow-up gives item 19 a CI proof for JS/TS suites, a typical PR plans 5 or fewer `LOCAL` lines; until then every impacted JS/TS suite is a `LOCAL` line and the count is larger. Each `LOCAL` line says why, and a PR that changes many suites itself is the expected exception. **Run locally**, FOREGROUND and scoped: the `LOCAL` lines of the plan; the RED rows of the item built; every suite the PR itself adds or changes; every `*.test.mjs` / `.js` / `.ts` suite; every suite `--check` refuses `= CI` for; and every suite on the brief's `Local suites:` line (the worker copies each into the PR body as `Local suites: <path>`, one path per line). Shell suites run as `bash scripts/quiet-run.sh <label> -- bash <suite>`; `*.test.mjs` / `.js` / `.ts` suites run through the command `impacted-suites.sh --runner <path>` prints (never guess `bun test` — a node:test suite can pass under `node --test` and fail under `bun test` on an unrelated bun quirk). **Hand on to CI** every other impacted `test-*.sh`: write `SUITE <path> = CI` and do not run it. With `HIMMEL_SUITES_LOCAL=1` in the session's environment `--check` refuses every `= CI`, so every impacted suite runs locally (all of them in one go with `scripts/ci/run-shell-tests.sh --impacted <base>..<head>`, wrapped the same way; it only reaches suites under its scan root and names the rest). Record exactly one verdict line each:

   - `SUITE <path> = PASS` — it ran and passed. A suite that FAILED is a finding, not a verdict: fix it (or the code) and re-run; do not record it as anything else.
   - `SUITE <path> = CI` — not run here; CI runs it. `--check` accepts it only for a `test-*.sh` the PR did not change or add that `scripts/handover/suite-coverage.sh` says runs in PR CI, and never under `HIMMEL_SUITES_LOCAL=1`; a refused one prints `CI NOT ACCEPTED <path> (<reason>)`, counts as no verdict, and must run locally. ready-check item 19 ("suite evidence") then needs that suite's exact `ran 0 <path>` line in a shard manifest of the CI run at the head.
   - `SUITE <path> = SKIP <reason>` — it was not run, and the reason names WHY it does not apply to this diff (a host that lacks the tool, a suite that cannot exercise the changed lines). A bare `SKIP` is not a verdict, and a SKIP is no suite evidence at ready-check item 19 unless the chief ruled it (below).
   - `SUITE <path> = BLOCKED <denial>` — it could not be run, and the denial quotes the refusal (a hook/permission text, a lock wait that expired). Route the BLOCKED to your chief/operator; it is not clean either, only *accounted for*: `--check` exits 3 on it, so the row stays open until the chief/operator rules: re-run the suite, or, for a suite nobody can run (a tool missing on both the CI runner and the station, a `quarantine` suite, no VM route), re-record it in exactly this shape:

     ```text
     SUITE <path> = SKIP ruled <chief-session> <reason>
     ```

     `<chief-session>` is the ruling chief's session name; it must contain `chief` and only `[A-Za-z0-9._-]` (the checker records anything else as a bare SKIP, which is no evidence). ready-check item 19 accepts a ruled SKIP and names each one in its PASS line, so the chief sees it again at GO (a hand GO only: `auto-go.sh` does not stop on a ruled SKIP); it never counts as CI or local evidence. Any other SKIP is still no evidence.

   Then submit them. Write `<path>` and the reason as printed, one line per suite, to a scratch file via the Write tool. **Keep the `<himmel_dir>` anchor spelling exactly as shown below — never a bare relative `bash scripts/cr/impacted-suites.sh`.** As of a review round that ruled "CUT, do not patch", `guard-pr-check-literal.sh` denies every heredoc and `< <file>` redirect shape outright — three rounds of patching the same regex-approximates-bash-grammar mechanism kept finding a new bypass, so the mechanism itself was cut, not narrowed further. The sanctioned shape is `--from-file <path>`: a single literal token naming a scratch file, no shell metacharacters/quotes/glob/whitespace in the value, and `--check` is required alongside it (`impacted-suites.sh` refuses `--from-file` without `--check`):

   ```bash
   bash "<himmel_dir>/scripts/cr/impacted-suites.sh" --check <base>..<head> --from-file <scratch-path>
   ```
   with `<scratch-path>` containing lines of the form:
   ```text
   SUITE <path> = PASS
   SUITE <path> = CI
   SUITE <path> = SKIP <reason>
   ```

   **Record the verdicts on every PR** (spec 2.2; `outside-pr: yes` or not) with `--record`, naming the PR's head branch (`headRefName`) and head. This is the DEFAULT shape of the fence; the bare fence above only previews. Ready-check item 19 reads this row as the local proof, so a PR without it has none:
   ```bash
   bash "<himmel_dir>/scripts/cr/impacted-suites.sh" --check <base>..<head> --from-file <scratch-path> --record --branch '<headRefName>' --head <head>
   ```
   `--record` appends one `impacted` row (its exit code and its SKIP count) to the CR ledger and keeps `--check`'s exit code. A failed append exits 4. Ready-check item 16f passes an outside PR only when the newest such row at its head reads exit 0 with no SKIP. When the diff touches the blast scope (`scripts/cr/blast-scope.cjs`), item 16g also needs a `blast` row at that head. Record it with the same branch, run from wherever you review it, the primary checkout included:
   ```bash
   bash "<himmel_dir>/scripts/cr/ledger-append.sh" blast --branch '<headRefName>' --head <head> --duration-secs <s>
   ```

   Carry forward `impacted_rc` (the fence's exit code) and its `impacted-suites: N impacted, M without a verdict` line. `impacted_rc = 0` means every impacted suite has a verdict (or none is impacted); `impacted_rc = 1` names each unverdicted suite on stderr and the row is NOT clean; `impacted_rc = 2` is an unresolvable range or a failed search — fix it, do not proceed as if the list were empty; `impacted_rc = 3` means every suite has a verdict but at least one is BLOCKED (accounted for, NOT clean). Steps 4.9, 5 and 6 read `impacted_rc`.
