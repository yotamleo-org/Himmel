# Cache health (HIMMEL-5672)

`scripts/eval/cache-health.py` computes per-role prompt-cache metrics from
session transcripts (`~/.claude/projects/**/*.jsonl`) with no model call.
`scripts/eval/cache-health-cadence.sh` runs it hourly from cron and delivers the
alerts. Cadence arm/disarm: [`docs/cadences.md`](../cadences.md).

`hit = cache_read / (cache_read + cache_creation + input)`, rows deduped by
message id. Roles: `console`, `leg`, `subagent`, `bridge`, `other` (same
classifier as the research baseline). Two windows: RECENT (default last 24 h)
and BASELINE (the 7 days before it), cut by turn timestamp.

## Alert rules

| Key | Crossing (default) | Clears |
|---|---|---|
| `role-drop:<role>` | recent hit more than 3 pts under baseline, both windows over 5M tokens | back within 2 pts (one recovery message) |
| `session-low:<session id>` | session over 1M recent tokens with hit under 90 % | expires silently when it leaves the window |
| `compactions:leg` | workers average more than 4 compactions in the recent window | below the limit (one recovery message) |

`role-drop` and `session-low` apply to `--alert-roles` (default `console,leg`);
subagent, bridge and other hit rates swing with cold starts, so they are metrics
only (a real dry run on 2026-10-14 showed subagents 4.2 pts under baseline with
nothing wrong).

One message per run carries every NEW crossing (max 5 lines shown). A key that
stays crossed sends nothing. State is committed only for delivered messages, so
a failed send retries on the next run. Delivery is Telegram plus the live
chief's bridge inbox; either channel counts as delivered.

## `~/.himmel/state/cache-health/` files

- `metrics.json` — rewritten every run (schema below). Read by the morning-report
  cache line (HIMMEL-668, `scripts/handover/cache-health-line.py`: freshness gate,
  older than 26h prints `unmonitored`) and the board.
- `history.jsonl` — one `{"ts","overall","roles":{role: hit_pct}}` row per run,
  last 720 kept. The morning-report line derives its 7-day ratio (unweighted mean
  of the runs' 24h hit_pct) and 14-day-median baseline from it. The baseline is
  our own history; the 76.5% / 40% figures quoted online are NOT a baseline.
- `alert-state.json` — `{"active": {key: text}}`, the hysteresis state.

## `metrics.json` schema (`schema: 1`)

```json
{
  "schema": 1,
  "generated_at": 1760000000,
  "window": {"recent_hours": 24, "baseline_days": 7},
  "overall": {"tokens": 0, "hit_pct": 97.8, "baseline_hit_pct": 97.9,
              "write_share_pct": 29.0, "w1h_pct": 99.0},
  "roles": {
    "<console|leg|subagent|bridge|other>": {
      "sessions": 0, "tokens": 0, "hit_pct": 0.0, "baseline_hit_pct": 0.0,
      "baseline_tokens": 0, "delta_pts": 0.0, "write_share_pct": 0.0,
      "w1h_pct": 0.0, "compactions": 0, "compactions_per_session": 0.0
    }
  },
  "top_offenders": [
    {"session": "<id>", "title": "...", "role": "leg", "tokens": 0,
     "hit_pct": 0.0, "excess": 0, "compactions": 0}
  ],
  "alerts": {"active": ["key"], "new": ["key"], "recovered": ["key"]}
}
```

- `*_pct` fields are `null` when the window has no tokens.
- `write_share_pct` = share of the cost-weighted bill from cache writes
  (read ×0.1, 5m write ×1.25, 1h write ×2.0, input ×1.0).
- `w1h_pct` = 1h share of all cache-write tokens.
- `excess` = weighted cost minus the all-read ideal, in tokens; `top_offenders`
  lists the recent-window sessions over 1M tokens, worst first (max 10).
- `alerts.*` reflect the run that wrote the file.

## Running by hand

- `python3 -I scripts/eval/cache-health.py report` prints today's numbers.
- `bash scripts/eval/cache-health-cadence.sh run --dry-run` prints the metrics
  and the would-send text; nothing is sent or written.
