# /pr-check reference: step 3.6: impacted suites

   **Step 3.6 — Impacted suites: one verdict per suite (HIMMEL-2821; runs in BOTH lanes — the docs-audit lane of step 2.5 skips step 3 but not this).** PR #2261 changed `scripts/machine-setup/uninstall-plugins.sh` and merged with `scripts/test-uninstall.sh` — the suite one directory up that drives it end to end — never run: the implementor swept the owning directory, this command certified, and nothing computed *which suites reference what the PR changed*. This step is that computation. It is a gate, not advice: a missing verdict makes the row NOT clean.

   `<base>` is step 3.0's `<db_sha>` (carried forward like `<head>`; the script takes the merge-base itself). In the docs-audit lane there is no step 3.0, so the docs-audit base is the PR's base branch as `origin/<branch>` — `origin/main` for himmel. Both halves are 40-hex / a fixed literal, so the range `<base>..<head>` stays unquoted (see the quoting rules above).

   ```bash
   bash "<himmel_dir>/scripts/cr/impacted-suites.sh" <base>..<head>
   ```

   It prints every test suite (`**/test-*.sh`, `*.test.mjs`, `*.test.js`, `*.test.ts`) whose text references the basename of a file this PR changed — or, for a slash command or skill, `/<name>` — plus every suite the PR itself changed, one repo-relative path per line. **Print that list in your report row as `impacted suites (N): <paths>`.** An unresolvable range exits 2: treat that as BLOCKED for the whole step, never as an empty list. Then, for EACH listed suite, run it FOREGROUND and scoped — shell suites as `bash scripts/quiet-run.sh <label> -- bash <suite>` (or all of them in one go with `scripts/ci/run-shell-tests.sh --impacted <base>..<head>`, wrapped the same way; it only reaches suites under its scan root and names the rest), `*.test.mjs` / `.js` / `.ts` suites through the command `impacted-suites.sh --runner <path>` prints (HIMMEL-3436: never guess `bun test` — a node:test suite can pass under `node --test` and fail under `bun test` on an unrelated bun quirk) — and record exactly one verdict line each:

   - `SUITE <path> = PASS` — it ran and passed. A suite that FAILED is a finding, not a verdict: fix it (or the code) and re-run; do not record it as anything else.
   - `SUITE <path> = SKIP <reason>` — it was not run, and the reason names WHY it does not apply to this diff (a host that lacks the tool, a suite that cannot exercise the changed lines). A bare `SKIP` is not a verdict.
   - `SUITE <path> = BLOCKED <denial>` — it could not be run, and the denial quotes the refusal (a hook/permission text, a lock wait that expired). Route the BLOCKED to your console/operator; it is not clean either, only *accounted for*: `--check` exits 3 on it, so the row stays open until the console/operator rules (re-run the suite, or re-record it `SKIP <reason>` quoting the ruling).

   Then submit them. Write `<path>` and the reason as printed, one line per suite, to a scratch file via the Write tool. **Keep the `<himmel_dir>` anchor spelling exactly as shown below — never a bare relative `bash scripts/cr/impacted-suites.sh`.** As of HIMMEL-3798 round 3 ("CUT, do not patch"), `guard-pr-check-literal.sh` denies every heredoc and `< <file>` redirect shape outright — three rounds of patching the same regex-approximates-bash-grammar mechanism kept finding a new bypass, so the mechanism itself was cut, not narrowed further. The sanctioned shape is `--from-file <path>`: a single literal token naming a scratch file, no shell metacharacters/quotes/glob/whitespace in the value, and `--check` is required alongside it (`impacted-suites.sh` refuses `--from-file` without `--check`):

   ```bash
   bash "<himmel_dir>/scripts/cr/impacted-suites.sh" --check <base>..<head> --from-file <scratch-path>
   ```
   with `<scratch-path>` containing lines of the form:
   ```text
   SUITE <path> = PASS
   SUITE <path> = SKIP <reason>
   ```

   Carry forward `impacted_rc` (the fence's exit code) and its `impacted-suites: N impacted, M without a verdict` line. `impacted_rc = 0` means every impacted suite has a verdict (or none is impacted); `impacted_rc = 1` names each unverdicted suite on stderr and the row is NOT clean; `impacted_rc = 2` is an unresolvable range or a failed search — fix it, do not proceed as if the list were empty; `impacted_rc = 3` means every suite has a verdict but at least one is BLOCKED (accounted for, NOT clean). Steps 4.9, 5 and 6 read `impacted_rc`.
