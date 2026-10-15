# luna-ingest — Phase 2 — Reference extraction

Moved verbatim out of `SKILL.md`.

Parse the README for github URLs that point at OTHER repos:

```bash
grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?' /tmp/luna-ingest-readme.$$.md \
  | sed -E 's|^https://github\.com/||; s|\.git$||; s|/$||' \
  | sort -u \
  | grep -v "^${owner_repo}$" \
  > /tmp/luna-ingest-refs.$$.txt || true
```

The `(\.git)?` suffix on the regex plus the `s|\.git$||` substitution dedupes `<owner>/<repo>` with `<owner>/<repo>.git` (a common README link form).

Strip refs whose path has more than one `/` (sub-paths inside the same repo — keep the bare owner/repo only), AND reject any segment that is purely `.` or `..` (would survive the looser ref regex and lead to `gh api repos/../something` calls that pollute the audit log):

```bash
awk -F/ 'NF==2 && $1 !~ /^\.+$/ && $2 !~ /^\.+$/' /tmp/luna-ingest-refs.$$.txt > /tmp/luna-ingest-refs.clean.$$.txt
```

Apply the `--limit` cap (the explicit `--limit <N>` if passed, else the default `250`). If more refs exist than the cap, log "tail-skipped: N refs" in the synthesis under § Open questions. With the default `250`, a tail-skip now signals a genuinely huge meta-list (re-run with an explicit higher `--limit`), not the old routine `[1,25]`-clamp truncation.

**LUNA-7 size telemetry:** measure the decoded README size with `wc -c < /tmp/luna-ingest-readme.$$.md` and record it in the synthesis § Audit log. If the size exceeds **512 KB**, emit a single stderr warning before Phase 3 starts:

```
WARN luna-ingest: README is <N> KB (>512 KB threshold). --limit caps API-call count, NOT text size; large monorepo/awesome-list READMEs may produce a noisy ref pool.
```

Continue regardless — the warning is informational. `--limit` already bounds the per-ref API-call cost; the size warning just flags "expect noisy classification" for the operator.
