---
allowed-tools: Bash, Glob, Grep, Read, Edit, Write, Skill
description: Autonomous HARVEST pass over Clippings/ — stamp harvested_at on each new clip; github repos go to luna-ingest.
argument-hint: "[vault-path] [--dry-run] [--limit N] [--firecrawl-thin] [--firecrawl-budget N]"
---

## Your task

Run an autonomous HARVEST pass over the vault's `Clippings/` folder. For each clip lacking `harvested_at:`, mark it ready for the next pipeline stage (/triage-clips). Default: process every unharvested clip. With `--dry-run`: report the dispatch plan, write nothing. With `--limit N`: stop after N clips (calibration runs).

This command is Stage 1 of the 4-stage clipper pipeline (HARVEST → TRIAGE → SYNTHESIZE → ARCHIVE; LUNA-3, Stage 4 added in LUNA-55). LUNA-26 pivot (2026-05-26): non-github clips rely on the LUNA-2 Web Clipper templates having captured rich body content (`## The Idea` for tweets, `## Highlights` + `## Summary` for articles, etc.) — `/harvest-clips` no longer re-fetches via external LLM skills. The original MVP's external-fetch paths (Grok via `/x-read`/`/youtube`, Perplexity via `/research-deep`/`/research`) are deferred to LUNA-27 (playwright-based crawl) for clips whose body is thin. LUNA-14 still covers fan-out / recursion / content-dedup as planned.

### Concurrency contract (read this BEFORE every run)

This command is NOT safe while Obsidian has the vault open AND the user is actively editing files in `Clippings/`. The harvest layer writes a much larger section (`## Harvested content`) than `/triage-clips` does — the race window is wider. At the start of every run, print this line so the user can interrupt if needed:

```
harvest-clips: assumed-safe (Obsidian not editing Clippings/). If Obsidian is open with these files, abort now (Ctrl-C).
```

### `--dry-run` hard gate

If `--dry-run` is passed, set `DRY_RUN=1` for the entire run. **Every phase below that would invoke `Edit`, `Write`, or any `Skill` that mutates the vault MUST first check `DRY_RUN`.** When `DRY_RUN=1`, the agent MUST NOT call `Edit`/`Write` and MUST NOT dispatch any harvest skill — only `Read`, `Glob`, `Grep`, read-only `Bash`. Skill dispatch is suppressed because most harvest skills carry their own write paths (e.g. `obsidian-triage:luna-ingest` writes to `30-Resources/Tech/`).

If at any point the agent realizes it has dispatched a skill OR called `Edit`/`Write` while `DRY_RUN=1`, abort immediately with:
```
harvest-clips: DRY-RUN CONTRACT VIOLATION — write/dispatch executed during --dry-run; report this as a bug.
```
Exit non-zero.

### Logging contract (G-7 unified format)

Every per-clip outcome MUST emit exactly one line to stdout BEFORE the final summary, in one of these formats:

- Success: `✓ <clip-filename.md> — harvested via <skill>, {Nb}b content, {Mr} fan-out refs (logged, not followed in MVP), harvest_status=ok`
- Skip (idempotent): `⊘ <clip-filename.md> — skipped (already-harvested): harvested_at=<date> via <skill>`
- Skip (dedup): `⊘ <clip-filename.md> — skipped (url-dedup): canonical URL matches [[Clippings/<other-clip>]]`
- Skip (G-1 privacy): `⊘ <clip-filename.md> — skipped (sensitivity): URL matched <vault>/.harvest-deny or default-deny list`
- Skip (frontmatter): `⊘ <clip-filename.md> — skipped (frontmatter): <reason>`
- Partial: `~ <clip-filename.md> — partial (<skill>): <reason — e.g. rate_limited>, retry_count={K}, harvest_status=partial`
- Failed: `✗ <clip-filename.md> — failed (<skill>): <reason>, retry_count={K}, harvest_status=failed`

Clips flagged by the Phase 4.5 injection screen (HIMMEL-256) append ` [injection-suspect: <class1>, <class2>]` to their per-clip line (any glyph) — the suffix carries the matched pattern-class names exactly as `--scan-only` prints them. A clip whose screen could not be completed appends ` [injection-screen-error]` instead (fail-closed — Phase 4.5).

The final summary MUST count: `harvest-clips: N ok, M partial, K failed, S skipped. (See ✓ / ⊘ / ~ / ✗ lines above.)` Counts MUST equal the count of glyphs above. If they disagree, abort with a clear error. If F > 0 clips were flagged injection-suspect, append a second summary line listing them: `harvest-clips: F flagged injection-suspect (operator review): <clip-1.md>, <clip-2.md>, …`

Exit codes:
- 0: all clips harvested or skipped successfully
- 1: usage / input error (bad vault path, conflicting flags)
- 2: env unusable (vault not found, lockfile contention, missing required env vars)
- 3: refused under headless (HIMMEL-128)
- 4: partial run (≥1 clip landed in a **blocking** partial class below, or ≥1 failed); re-run later to retry. Deferred partials alone exit 0.
- 5: catastrophic — abort mid-run; resume-state file written for next run

### Partial classes (HIMMEL-4675) — deferred vs blocking

**Read on demand:** Before deciding whether a clip's outcome is deferred or blocking, and before writing the completion marker. Read `<plugin>/references/harvest-clips/partial-classes.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

### Date substitution rule

Wherever `YYYY-MM-DD` or `TODAY` appears below, substitute `$(date +%Y-%m-%d)`. Capture once at start: `TODAY=$(date +%Y-%m-%d)`. Wherever an ISO timestamp is needed: `$(date -u +%Y-%m-%dT%H:%M:%SZ)`.

### G-6 — Pre-flight env-var + headless refusal (run FIRST)

**Headless refusal (HIMMEL-128).** Before anything else:

```bash
if [ "${CLAUDECODE_HEADLESS:-0}" = "1" ] || [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli-print" ]; then
    echo "ERR harvest-clips: refusing to run under headless claude (HIMMEL-128 / Max-X5 billing split)." >&2
    exit 3
fi
```

Detection variable list may grow; refine during calibration cycle 1. Smoke-test in `test-harvest-clips-headless-refuse.sh`.

**Env-var preflight.** Post-LUNA-26 pivot, only github repo-root and `/tree/` URLs trigger an external skill dispatch (`obsidian-triage:luna-ingest`), which uses `gh api` and requires `gh auth status` to be ok. All other types use the **clip-body path** (described in Phase 4) and need no env vars.

| `type:` + URL pattern | Required env var | Skill that needs it |
|-----------------------|------------------|---------------------|
| `research` / `article` with a repo-root or `/tree/` `github.com/*` URL | none | `obsidian-triage:luna-ingest` (needs `gh auth status` ok) |
| thin article/web clip **with `--firecrawl-thin`** | `FIRECRAWL_API_KEY` (opt. `FIRECRAWL_BASE_URL`) | `harvest-clip-body-batch.py` firecrawl escalation |
| every other type, including a `/blob/<branch>/<path>` github file clip | none | clip-body path (no dispatch) |

If `gh auth status` is non-zero AND the batch contains any non-`/blob/` github URL: abort with `harvest-clips: gh not authenticated (needed for obsidian-triage:luna-ingest on github URLs); run 'gh auth login' and re-run.` Exit 2. (Skip the check if the batch has no github URLs, or only `/blob/` github URLs: no `gh auth` is needed for those, they take the clip-body path.)

`--firecrawl-thin` turns the escalation on; `FIRECRAWL_API_KEY` is needed only for the `firecrawl` rung (keyless Jina Reader works without it; the batch tool exits 2 only when no backend in `HARVEST_SCRAPE_BACKEND` is usable). Default runs never need it.

**Scrape backend order (HIMMEL-4335).** The thin-body escalation tries backends in the order set by `HARVEST_SCRAPE_BACKEND` (comma list of `local-headless`, `jina`, `firecrawl`; default `local-headless,jina,firecrawl`). `local-headless` is a local Scrapling stealth-browser fetch (HIMMEL-4344; reads per-site cookies from the `~/.luna/cookies/*.txt` jar, override `HARVEST_COOKIE_DIR`, but never sends the `instagram.com` / `x.com` / `twitter.com` / `youtube.com` / `reddit.com` / `redd.it` jar cookies, HIMMEL-4709; optional dep pinned in `tools/requirements-scrapling.txt`, silently skipped to jina when scrapling is not installed in the python that runs the harvest; navigations, redirect hops (via CDP `Fetch`), same-process subresources and page websockets are checked against the private-host rule before the browser resolves or connects, and aborted when private; service workers and popups are blocked, and a guard that fails to install leaves the browser denying everything. NOT guarded, tracked in HIMMEL-4496: cross-site iframes (separate CDP targets), dedicated and shared workers including worker websockets, and DNS rebinding (the check is hostname-only), so this is not a complete SSRF boundary); `jina` is Jina Reader (`https://r.jina.ai/<url>`, no key, no credits); `firecrawl` is the capped last rung (`--firecrawl-budget`, dropped from the chain when `FIRECRAWL_API_KEY` is unset). A backend that fails falls through to the next. The skip-host list and the G-1 privacy gate run before any backend. The clip's `harvest_skill` records which backend served it. Every Firecrawl call (harvest, follow-web, fetch-health) appends one line (`v, ts, host, source, kind, call_site, endpoint, credits, ok`; never the key, URL query or page body) to `~/.himmel/state/firecrawl-ledger.jsonl` (override `HIMMEL_FIRECRAWL_LEDGER`).


**Firecrawl unavailable (HIMMEL-4371).** A 402, a quota or insufficient-credits body, or a 429 from Firecrawl marks it unavailable for the rest of the run (one stderr line, no further calls; a 429 claims no reset date, a 402 reads `billingPeriodEnd` from the free credit-usage endpoint). Items that needed it are parked as `deferred: firecrawl-unavailable` in `~/.himmel/state/firecrawl-parked.jsonl` (override `HIMMEL_FIRECRAWL_PARKED`; enveloped, registered in `scripts/observability/ledgers.json`; follow-web parks a query hash, never the query). The next run retries parked clips first, after one free credit-usage probe (0 remaining: zero scrape calls and the items stay parked; probe failure: one attempt). Any backend's success resolves a parked clip; a parked clip whose file is gone resolves as `gone`. Doctor check C51 WARNs while items are parked, and `doctor-cadence` DMs once for a new WARN.
**Scrape routing and caps (HIMMEL-4361).** Every backend name (env, routing file, chain) resolves through one table, `BACKEND_REGISTRY` in `tools/harvest-clip-body-batch.py` (name, client class, `needs_key`, cap, `egress_host`); an unknown name is an error naming the valid set.

- **Per-site routing, `<vault>/.harvest-backends`.** One line per rule: `<url-glob> skip=a,b` (drop those backends for matching URLs) or `<url-glob> only=a` (restrict to those). `#` starts a comment. Globs are matched exactly like `.harvest-deny` (same canonicalisation and `*` / `**`). **The first matching line wins**, so put the narrow rules first. A missing file is no constraint. An unreadable file, a malformed line or an unknown backend name fails closed: nothing is scraped. A starter template is `tools/templates/harvest-backends.template`.
- **Precedence, highest first:** the odd-host refusal and `.harvest-deny` (a denied URL reaches no backend; `.harvest-allow` overrides a deny as before), then the `HARVEST_SCRAPE_DENY` kill switch, then `.harvest-backends`, then the `HARVEST_SCRAPE_BACKEND` order. A routing line can never re-add a killed backend or one with no key.
- **`HARVEST_SCRAPE_DENY=<b,...>`** (or `all`) removes those backends for the whole run. `follow-web` honours it too: denying `firecrawl` turns its search off and reports `search unavailable`. There is no keyless search fallback. `all` also turns off the hermes rung (a paid agent fan-out, reported on stderr when `FOLLOW_WEB_HERMES` is set); the free local qmd and CLI rungs stay, and a named list leaves every non-firecrawl rung alone.
- **Call cap:** `--firecrawl-budget N` wins, then `HARVEST_FIRECRAWL_BUDGET`, default 20. `follow-web` takes `FOLLOW_WEB_BUDGET` first, then the same variable.
- **Credit ceiling:** `HARVEST_FIRECRAWL_MAX_CREDITS` (default 5; the benchmark saw one X post cost 30). When a call reports more credits than that, firecrawl is disabled for the rest of the run and a line is logged to stderr. The ceiling cannot refund the call that tripped it; it only stops the next ones. A `creditsUsed` that is present but not an integer counts as over the ceiling. An unparseable response is charged the call's assumed cost (1, or 5 with stealth) and trips the ceiling only when that exceeds it, logging the same line. Both budget and ceiling variables take ASCII digits only (`+5`, `1_0` are errors). A stealth call costs 5, so it passes the default; a ceiling below 5 with stealth on is refused before any call.
- **Stealth/proxy:** never sent unless `HARVEST_FIRECRAWL_STEALTH=1` (scrape payload `proxy: stealth`, 5x credits). The search path never sends it.
- **No `FIRECRAWL_API_KEY`:** firecrawl is left out and the chain runs on Jina alone, silently.

**Adding a scrape backend.** Three steps, no change to the chain, routing or deny gate:
1. A client class with `name`, `scrape(url) -> markdown` and `from_env(env, budget)` (return `None` when its key is missing).
2. One `BACKEND_REGISTRY` row (`BackendSpec(cls, needs_key, cap, egress_host)`); also add the name to `SCRAPE_BACKEND_NAMES` in `tools/lib/follow-web.mjs` so the kill switch accepts it.
3. One `scripts/guardrails/egress-matrix.json` row for its `egress_host`, plus a RED row in `tests/test-scrape-backends.py` (serves a URL, falls through on failure, honours `skip=`/`only=` and the kill switch).

### G-2 — Lockfile + obsidian-github-sync race guard

**Read on demand:** At run start, after G-6 and before the per-clip loop (acquire the lock; release it at the end). Read `<plugin>/references/harvest-clips/g-2-lockfile.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

### Resolve vault path (cross-platform: Linux / macOS / Windows-Git-Bash)

Same logic as `/triage-clips`:
1. If `$1` is a directory, use it.
2. Else `$OBSIDIAN_VAULT_PATH` if set.
3. Else `~/Documents/luna`.
4. Else exit 1 with `harvest-clips: vault path not found; pass as $1 or set OBSIDIAN_VAULT_PATH`.

All `find` / `grep` / `cat` use forward-slash paths. Quote every path containing spaces.

Verify `<vault>/Clippings/` exists. If not, exit 0 with `harvest-clips: no Clippings/ folder — nothing to harvest`.

### Scan for unharvested clips

A clip is **unharvested** if its YAML frontmatter does NOT contain a line matching `^harvested_at:[[:space:]]*\S` (case-sensitive, allows any non-blank value). Implementation:

```bash
find "<vault>/Clippings" -maxdepth 2 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*' -print0 \
  | xargs -0 -I {} sh -c 'grep -qE "^harvested_at:[[:space:]]*\S" "${1}" || echo "${1}"' _ {}
```

Maxdepth 2 captures subfolders. Four inbox-internal names are never source clips and are excluded: `_synthesis/` (`/synthesize-clips` output — `type: synthesis` proposal pages), `_done/` (`/archive-clips` archive of graduated clips, which already completed harvest), `_deferred.md` (`/archive-clips` backlog log), and `_evidence/` (the reviewed-evidence pool, including `_rejected/`; visible to `/synthesize-clips` only). Without these, the scan re-catches derived/archived content every run and pollutes it with `harvest_*` frontmatter. Sort by `date_clipped` ascending (oldest first). Apply `--limit N` cap.

If zero unharvested clips: exit 0 with `harvest-clips: 0 unharvested clips in Clippings/ — nothing to do`.

### G-5 — Resume state contract

State file at `<vault>/.harvest-run-state-$YYYY-MM-DD.jsonl` (one per day; rotate at midnight).

Line format (one JSON-object per line):

```json
{"clip_path": "Clippings/foo.md", "harvest_status": "ok|partial|failed|gave_up|refused_sensitivity", "harvest_skill": "x-read", "started_at": "2026-05-26T03:00:00Z", "ended_at": "2026-05-26T03:00:42Z", "retry_count": 0, "last_error": "" }
```

On startup:
- Append-load all today's state-file entries.
- For each unharvested clip in the scan, check the state-file:
  - `harvest_status: ok` → already done; do NOT redispatch (the unharvested-scan should have filtered this, but double-check guards against stale frontmatter).
  - `harvest_status: partial | failed` AND `retry_count < 3` → retry (increment `retry_count` on dispatch).
  - `harvest_status: partial | failed` AND `retry_count >= 3` → mark `gave_up`; emit `⊘` skip line; do NOT dispatch. (CR M1: covers both `partial` and `failed` so rate-limited clips don't loop forever.)
  - `harvest_status: gave_up | dedup | refused_sensitivity` → skip.
  - Not in state file → first attempt (`retry_count = 0`).

State-file appends are the canonical record. Frontmatter is the operator-visible cache. The exception is the cross-day retry count of a deferred partial: it lives in the clip's `harvest_defer_count` frontmatter, because this file rotates daily (see "Partial classes" above).

### Per-clip workflow

For each unharvested clip (post-scan + post-state-file filter):

**Phase 1 — Baseline + parse.**
- Read the full file. Compute baseline SHA256.
- Parse frontmatter: `type`, `source`, `author`, `date_clipped`, existing `tags`.
- If frontmatter unparseable OR `type:` missing: log `⊘ <clip> — skipped (frontmatter): <reason>`. Append state-file line with `harvest_status: failed` + `last_error: frontmatter_parse`. Move on.

**Phase 2 — G-1 privacy URL gate.**

Canonicalize the source URL (see Phase 3). Then check:

1. Deny if the URL matches any of (matching semantics below):
   - Exact hostname: `localhost`, `127.0.0.1`, `::1`.
   - **Host-suffix match (leading dot is the signal):** `.lan`, `.local`, `.internal`. A URL's hostname matches `.lan` iff it ends with the literal `.lan` AND has at least one preceding character — `app.lan` matches, `evil-lan.com` does NOT (the `-lan` doesn't have the leading-dot boundary). Implementation: `host == "lan" || host == *.lan` where `*` is one or more non-dot segments.
   - Private RFC 1918 ranges: `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`. CIDR semantics, not glob — `172.15.x.x` and `172.32.x.x` are public and should NOT match. <!-- leak-allow: private-lan-ip doc spec listing the RFC1918 ranges themselves -->
   - Any URL with basic-auth credentials in the userinfo component (`https://user:pass@host/`).
   - Any line in `<vault>/.harvest-deny` (one URL/glob pattern per line; `#` starts a comment). Glob semantics: `*` matches zero-or-more non-`/` characters; `**` matches across path segments. Pattern and URL are normalised before matching (scheme dropped, host lowercased with any trailing dot removed and IDNA-encoded, path percent-decoded with dot-segments resolved, empty path = `/`), and a line with no `/` is a host rule covering every path. A URL with a backslash anywhere, a `%XX` in the authority, a bracketed IPv6 literal, or any host that is not plain `[a-z0-9.-]` is refused for every backend and stamped like a deny, never decoded or repaired, because a scraper may read it as a different host.
2. Allow override only if the URL matches a line in `<vault>/.harvest-allow` (same glob semantics).

If denied:
- Frontmatter: set `harvest_status: refused_sensitivity`, `harvest_url_canonical: <canonical>`.
- Log `⊘ <clip> — skipped (sensitivity): <pattern that matched>`.
- State-file: append with `harvest_status: refused_sensitivity`.
- Continue.

**Phase 3 — URL canonicalization + dedup check.**

Apply canonicalization rules per domain (LUNA-11 will land the shared `lib/url-canonical.sh` — for MVP, inline these rules in the runbook):

| Domain | Rule |
|--------|------|
| `x.com` / `twitter.com` / `mobile.twitter.com` | host → `x.com`; keep path through `/status/<id>`; drop query string. |
| `youtube.com` / `youtu.be` | normalize to `youtube.com/watch?v=<id>`; drop other query params. |
| `github.com` | strip `/tree/<branch>` and trailing `/`; **keep** `/blob/<branch>/<path>` (one file is a distinct document from the repo root — HIMMEL-1735). Lowercase owner/repo. |
| `reddit.com` / `old.reddit.com` / `new.reddit.com` / other subdomain variants | host -> `www.reddit.com`; drop query/fragment + trailing slash; lowercase the `/r/<sub>` segment. `redd.it` short links are not resolved here. |
| Generic article | drop `utm_*`, `fbclid`, `gclid`, `ref=`, `source=`, `mc_cid`, `mc_eid`. |
| `medium.com` | drop `?source=`. |

Record `harvest_url_canonical: <canonical>` in frontmatter (Phase 5 placement).

**URL-canonical dedup check.** Scan other clips for the same `harvest_url_canonical:` value. If found AND the other clip has `harvest_status: ok`: skip with `⊘ <clip> — skipped (url-dedup): canonical URL matches [[Clippings/<other-clip>]]`. Frontmatter: `harvest_status: dedup`, `harvest_dedup_target: [[Clippings/<other-clip>]]`. State-file: `harvest_status: dedup`.

**Phase 4 — Dispatch decision (post-LUNA-26 pivot).**

**Read on demand:** For every clip, after the Phase 3 dedup check. Read `<plugin>/references/harvest-clips/phase-4-dispatch.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

**Phase 4.5 — Injection screen (HIMMEL-256, flag-only — both paths, pre-harvest content only; luna-ingest output is NOT screened by this phase — see the github-ingest re-screen below).**

**Read on demand:** For every clip, on both dispatch paths, after Phase 4 and before Phase 5 writes anything. Read `<plugin>/references/harvest-clips/phase-4-5-injection-screen.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

**Phase 5 — G-3 single-section-add invariant + write (atomic sequence).**

**Read on demand:** For every clip, after Phase 4.5. Read `<plugin>/references/harvest-clips/phase-5-write.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

**Phase 6 — State-file append.**

Append one JSON line to `<vault>/.harvest-run-state-$YYYY-MM-DD.jsonl` with the final outcome. Lockfile-protect the append.

**Portable lock fallback (CR M6).** `flock(1)` ships on Linux + macOS but NOT on Git Bash for Windows. Use atomic-mkdir as the portable lock primitive:

```bash
# Acquire — atomic across platforms (mkdir fails if dir exists).
state_lock="<vault>/.harvest-run-state.lock"
while ! mkdir "$state_lock" 2>/dev/null; do sleep 0.1; done
# (Release in a trap so signals don't leave a stale lock dir.)
trap 'rmdir "$state_lock" 2>/dev/null || true' EXIT INT TERM
# ... append the JSON line ...
rmdir "$state_lock"
trap - EXIT INT TERM
```

The same fallback applies to G-2's `<vault>/.harvest.lock` (line above): use `mkdir` to create the lock dir + a sidecar file inside it carrying PID + ISO timestamp + batch hash. Check liveness via `kill -0 <pid>` (msys supports it).

**Phase 7 — Fan-out scan (LUNA-10 MVP: LOG ONLY, do NOT dispatch).**

Scan the harvested body for secondary github URLs. For each unique secondary URL:
- Log the URL count in the `✓` line (`{Mr} fan-out refs`).
- Do NOT dispatch — fan-out crawl ships in LUNA-14.
- Append URLs to `<vault>/.harvest-run-fanout-candidates-$YYYY-MM-DD.txt` for LUNA-14 to pick up.

### Tracking

After the run, append one line to `<vault>/log.md` (if it exists):
```
## [$TODAY] harvest-clips | N harvested ok, M partial, K failed, S skipped. State file: .harvest-run-state-$TODAY.jsonl
```

### G-8 — Completion marker (HIMMEL-1137) — write LAST, clean runs only

**Read on demand:** Last, once the per-clip loop is finished, on clean runs only. Read `<plugin>/references/harvest-clips/g-8-completion-marker.md` (`<plugin>` is this runbook's plugin root, `marketplace/plugins/obsidian-triage`) in full and follow it exactly as if it were inlined here; do not work from memory of it.

### Notes for the agent

- **Skill invocations**: use the `Skill` tool. Do NOT shell out via `Bash: claude -p`. HIMMEL-128 + Max-X5 billing.
- **All writes preserve the original clip body.** Phase 5 G-3 invariant enforces this — never overwrite operator hand-edits in `## Why I Saved This` / `## How I Can Use This` / etc.
- **MVP scope:** no fan-out, no recursion, no content-dedup. Those ship in LUNA-14.
- **No promotion-target writing.** This command does NOT move clips out of `Clippings/`. The TRIAGE pass (`/triage-clips`) handles promotion candidates separately.
- **This command is autonomous by design.** Do NOT ask the user for confirmation between phases. The design contract is "runs end-to-end and reports."

### Failure modes (calibration cycle 1 will refine)

- Skill returns empty / too-short / structurally-garbage output → `harvest_status: needs_enrichment` (LUNA-14 rung ladder will pick this up).
- Skill rate-limited mid-batch → `harvest_status: partial`, run exits rc=4.
- Stale-read mid-pass → skip clip, state-file `partial`, continue.
- All clips refused by G-1 → suggests denylist too aggressive; halt + review.
- Headless detection false-positive → diagnose env-var collision (replan trigger §17).
