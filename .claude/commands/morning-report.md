---
description: Generate the dated Morning Report from live git/gh/jira/worktree state at ~zero tokens; --llm enriches it.
argument-hint: "[--llm] [--llm-model M] [--since SHA] [--since-date YYYY-MM-DD] [--out PATH] [--jira-limit N] [--backlog-limit N] [--dry-run]"
---

Generate the daily 🌅 Morning Report by templating live `git`/`gh`/`jira`/`worktree`
state into the curated schema and writing it to the handover root
(`$HANDOVER_DIR`, Mode B) or `<repo>/handovers/` (Mode A) as
`morning-report-<local-date>.md`. The default run costs ~no Claude tokens — it
leads with four answers (✅ What shipped, ⏳ What waits on you, 💸 What it spent,
▶️ What runs next; a field with no input reads "not available"), then emits
deterministic sections (✅ Completed PRs, 🔴 In-flight WIP, 🧹 Stale
worktrees, 📋 Backlog, Done cross-ref, 🗄️ Prompt cache) plus heuristic TL;DR + Suggested order.
The cache line reads the cache-health metrics: 7-day read ratio per role, a
trailing 14-day-median baseline and a 3-day below-baseline flag; stale or missing
metrics print `cache: unmonitored`.

Pass `--llm` to enrich TL;DR, Suggested order, and Backlog theme-clustering via a
bounded interactive Sonnet turn (degrades to the deterministic heuristic if
`claude` is unavailable, and skipped with a notice under Codex). It is a point-in-time snapshot — cross-day continuity
stays a session's job.

Run:

```bash
bash scripts/handover/generate-morning-briefing.sh $ARGUMENTS
```

The separate overnight report (`scripts/overnight/morning-report.sh`) takes an operator template: one section id per line (`header decisions tickets operator-actions unlanded changelog`) in `$MORNING_REPORT_TEMPLATE`, else `<handover-root>/morning-report.tmpl`, else the shipped `morning-report.default.tmpl`. Operator actions are always appended.

Common: `/morning-report` · `/morning-report --llm` · `/morning-report --dry-run`
