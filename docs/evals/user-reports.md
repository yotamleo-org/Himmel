# User reports — a refusal or review point you called wrong

> `/himmel-report` (plugin `himmel-ops`) turns the last refusal or review point
> into two results. Evaluation side: [`scripts/eval/friction/friction.py`](../../scripts/eval/friction/friction.py)
> counts the reports next to its own verdicts.

## The two results

| Result | Where | Who sees it |
|---|---|---|
| A redacted issue draft | `~/.himmel/reports/<id>.md` | You. It goes to `yotamleo-org/Himmel` only after an explicit yes (`himmel_report.py send <id> --yes`); without `--yes` nothing is sent |
| A local lesson | `~/.himmel/known-findings.local.json`, one `rebuttal` class per report class | Only your setup. Load it with `KNOWN_FINDINGS_FILE=<file> bash scripts/cr/known-findings.sh --list`. A hook refusal also prints a guard-override suggestion (the hook's off switch, set in the launching shell); nothing is applied |

Redaction runs before anything is written: the credential shapes the CR ledger scrubs, long token-shaped strings, emails
and home paths, then the repo's gitleaks gate over the draft. A gitleaks hit exits 3 and writes nothing.

## What friction.py does with the counts

Each draft appends one row to `~/.himmel/state/user-reports.jsonl` (`$HIMMEL_USER_REPORTS` overrides the path). A
repeat of the same text adds no row. `friction.py --reports <file>` reads the rows inside its window as a third
verdict source, **user-reported over-deny**, next to the transcript verdicts (`over-deny`, `true-positive`, `unclear`):

- the Markdown and `--json` carry a "User-reported over-denies" table by source and class (`user_reports`, `meta.user_reports`);
- `--record` adds `user_reported_over_deny` and `user_over_deny:<source>/<class>` to the eval-runs row.

The user verdict never changes the transcript counts: a class the classifier calls a true positive can still be
user-reported, and the two numbers sit side by side.
