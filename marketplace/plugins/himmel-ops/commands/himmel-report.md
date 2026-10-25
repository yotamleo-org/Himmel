---
description: Report a wrong refusal or review point: a redacted issue draft (sent only on your yes) plus a local lesson.
---

Report the last refusal (a hook or classifier denial) or review point (a critic or CodeRabbit finding) you
think was wrong. One run gives two results: a redacted issue draft for the himmel maintainers, and a local lesson
so your own setup stops repeating it. **Nothing is sent to GitHub unless the user says yes.**

`$ARGUMENTS` may carry a class slug for a review point (`--class bare-wait-claim`) and a note on what you expected.

**Step 1 — pick the text.** Take the exact text of the last refusal or review point from this conversation. If
unsure which one, ask the user in plain text. Write it to a scratchpad file (Write tool, never a heredoc). It may
hold secrets; the script redacts it, so do not paste it anywhere else.

**Step 2 — resolve the himmel checkout and draft.** This command runs from any directory, with the same
resolution order as `marketplace/plugins/himmel-ops/scripts/legs.sh` (`$HIMMEL_REPO` → git toplevel → canonical
install paths → error):

```bash
REPO="${HIMMEL_REPO:-}"
[ -n "$REPO" ] && [ -f "$REPO/scripts/report/himmel_report.py" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/report/himmel_report.py" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel"; do
    [ -f "$c/scripts/report/himmel_report.py" ] && { REPO="$c"; break; }
  done
fi
[ -f "$REPO/scripts/report/himmel_report.py" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

python3 -I "$REPO/scripts/report/himmel_report.py" draft --text-file <the scratchpad file>            # a refusal
python3 -I "$REPO/scripts/report/himmel_report.py" draft --kind review --class <slug> --text-file <file>  # a review point
```

Add `--note "<what you expected>"` to fill the draft's expectation section. The script redacts secrets, home paths
and emails, runs the repo's gitleaks gate over the result (exit 3 = it still trips: nothing is written), then writes
the draft to `~/.himmel/reports/<id>.md`, a lesson class to `~/.himmel/known-findings.local.json`, and one row to
`~/.himmel/state/user-reports.jsonl` (`scripts/eval/friction/friction.py` counts it as a user-reported over-deny).
A repeat of the same text prints `already reported` and writes nothing.

**Step 3 — show the draft.** Print the draft the script returned and the local lesson. For a hook refusal it also
prints a guard-override suggestion; relay it as a suggestion, apply nothing.

**Step 4 — ask, then send.** Ask the user plainly: send this draft as an issue on `yotamleo-org/Himmel`? Only on an
explicit yes run `python3 -I "$REPO/scripts/report/himmel_report.py" send <id> --yes` (the id is the script's
`report-id:` line). Without `--yes` it sends nothing (exit 4). Any other answer: stop, the draft stays local.

Load the local lessons into the pre-panel self-review with `KNOWN_FINDINGS_FILE=~/.himmel/known-findings.local.json
bash scripts/cr/known-findings.sh --list`. Reference: `docs/evals/user-reports.md`.
