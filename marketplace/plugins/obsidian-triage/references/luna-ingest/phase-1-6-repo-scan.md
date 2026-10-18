# luna-ingest — Phase 1.6 — Advisory repo security scan (HIMMEL-5816)

Runs on every github repo run, after Phase 1.5 and before Phase 2. **Advisory and read-only**: it fetches text through `gh api`, never clones, never runs an install script, and never refuses or skips the ingest. A flagged repo is still ingested; the findings are shown in the note.

```bash
scan_json="$(mktemp "${TMPDIR:-/tmp}/luna-ingest-scan.XXXXXX")" || exit 1
node "<plugin>/tools/repo-security-scan.mjs" "${owner_repo}" > "$scan_json"
```

Read `$scan_json`, then `rm -f "$scan_json"`.

`<plugin>` is the plugin root. The JSON carries `status` (`ok` | `partial` | `fetch_error`), `scanned[]`, `findings[]` (`{kind, detail, path}`) and a one-line `summary`. `kind` is one of `prompt-injection` (the `harvest-clip-body-batch.py --scan-only` classes, run over README, root docs, command and skill markdown), `install-script`, `obfuscated-payload`, `setup-exfil`, `suspicious-dependency`. Findings never quote the scanned text.

Record in the synthesis:

- Frontmatter `repo_scan: clean | flagged | unavailable` — `flagged` when `findings[]` is non-empty, `unavailable` on `fetch_error`, on `partial` with no findings (the summary reads `incomplete:`; a listing failure or a repo over the file cap is partial), or a non-zero exit of the tool (a scan that could not run or read every file is never written as `clean`).
- A `## Security scan (advisory)` section: the `summary` line, then one bullet per finding as `` `<kind>: <detail>` in `<path>` ``. Omit nothing, quote nothing from the repo. Clean and `unavailable` runs render the `summary` line alone.

Do **not** change `trust_tier`, `safety_flag` or the Phase 1.5 outcome from this scan: it informs the operator, it does not gate.
