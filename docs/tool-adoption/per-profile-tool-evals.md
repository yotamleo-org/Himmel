# Per-profile tool evals

How to read tool usage per launch profile and decide which tool to drop from a profile's default. Proposal only: dropping a tool changes live behaviour, so the apply goes VM-first through the chief.

## What is recorded

`scripts/eval/leg-digest/leg-digest.ts --profile <launch profile>` stamps the profile on the digest and on every `tool_health[]` row. Without the flag the profile is `unknown`: the recorder's environment says nothing about the profile of the session it digests. The recorder (`leg_ledger.py record --launch-name <session name>`, passed by `leg-digest-step.sh` and by backfill) reads the launched profile from the launcher's per-session launch record and stamps it on the row's `tool_health[]` and `meta.profile`. A session with no launch record, or whose launch lines disagree on the profile, stays `unknown`; rows recorded before this read `unknown` too.

## How it is rolled up

`rollupToolHealth(evals, failures, query, now, listing)` in `scripts/eval/leg-digest/tool-health.mjs` keeps every existing output field and adds:

- `profiles[]`: per profile, the same per-tool calls and failure rate, plus `listing_tokens` and a `verdict` per tool.
- `drop_candidates[]`: `{profile, tool, listing_tokens, calls, window_days, sessions}` for every tool that costs listing tokens and has zero calls in the window.
- `window_days`: the effective window length, `since` through today when `since` is given, else the `days` switch; it also sets the per-day trend length.
- a `profile` query filter and `filters.profiles`.

`listing` is `{profile: {tool: tokens}}`. A tool with no measured cost reports `listing_tokens: null` and is never flagged. A tool listed for a profile that no session called reads `0` calls, or `null` when a session's denominators are unknown or incomplete.

## Where listing cost comes from

The evals page and `readToolHealth` read the `{profile: {tool: tokens}}` map from `~/.himmel/profile-listing.json` (override `HIMMEL_PROFILE_LISTING`); an operator writes it from a probe run. Absent, every cost reads "not measured" and no tool is flagged.

- Measured: `listingTokensByPlugin(contextUsage)` in `scripts/lanes/profile-context-probe.mjs` turns a `/context` reply into the `Skill` tool's listing tokens and the per-plugin split. The probe bills real usage, so it runs on request only.
- Unbilled estimate: `scripts/lanes/skill-cost.mjs` scan, characters over 4, summed over the plugins a profile enables (uncapped; the live listing is capped by the listing budget).
- MCP tool schema cost has no source yet, so MCP tools carry no cost and cannot be flagged.

## Reading a drop candidate

A candidate is a prompt to look, not a verdict. Check the window (`window_days`) and `sessions` first: zero calls over a handful of sessions means nothing. Then check whether the tool is a safety net used rarely on purpose. Then propose the drop on the ticket.
