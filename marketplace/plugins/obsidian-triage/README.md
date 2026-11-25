# obsidian-triage

Autonomous triage + synthesis for Obsidian Web Clipper output.

## What it does

- **`/triage-clips`** — process every unprocessed clip in `<vault>/Clippings/`. Summarize, infer tags from the existing vault tag set, suggest Related Notes via link-graph proximity, extract Action Items to today's daily note (dedup-by-backreference for idempotency under partial failure), annotate a Promotion candidate, mark `processed: true`. Idempotent. No user prompts.
- **`/synthesize-clips`** — find cross-clip patterns (concepts hit 3+ times, repeated authors, tag overpopulation, folder pressure) and write synthesis pages to `<vault>/Clippings/_synthesis/` proposing vault restructuring (new MOCs, new folders, missing person notes). Proposals only — never restructures the vault directly.
- **`/archive-clips`** (Stage 4) — graduate clips that completed the full chain out of the `Clippings/` inbox. A clip is eligible when `harvested_at:` AND `processed: true` AND it is wikilinked from a `Clippings/_synthesis/` page; eligible clips move to `Clippings/_done/<YYYY-MM>/` with every path-qualified `[[Clippings/…]]` inbound link rewritten (literal, boundary-safe — won't clobber a prefix-sibling, preserves `|alias`/`#heading`) so they don't dangle. Basename-only `[[name]]` links resolve by Obsidian's unique-basename lookup and survive the move untouched. Dedups by `harvest_url_canonical:` before moving (never deletes). Also (re)generates `Clippings/_deferred.md` — the running backlog of fan-out refs, tail-skipped refs, and safety-flagged repos the pipeline logged but did not action. Keeps `Clippings/` an inbox: only active/incomplete clips stay visible.
- **`/contra`** — CONTRA passes over the vault. Default mode **ghost-self**: for topics active in the last 14 days, load same-topic notes older than `--min-age` (default 6 months, frontmatter-`date:` based — never mtime) and append a past-you-reacting-to-current-you entry to today's daily note under `## Thinking`, with reaction prose grounded ONLY in surviving verified quotes (hard quote-guard: every span whitespace-normalize-verified against its source BEFORE drafting; failures dropped, zero-survivor entries not written). `--bridge` mode: force one analogy between a technical-domain and a personal/philosophical-domain note (inferred domains must differ). Reports "vault too young" instead of guessing on thin history. Lean-invoke only — never scheduled.
- **`obsidian-triage:luna-ingest` skill** — chain-following triage for a github OR bitbucket.org repo URL. Fetches metadata + README, follows 1-hop references, classifies each (integrate / take-parts / inspire / skip / api_failure), writes a structured tech-ingest note under `<vault>/30-Resources/Tech/`. Issue URLs (`github.com/<owner>/<repo>/issues/<n>`) take a flat dedicated branch — fetch issue + comments via `gh api`, same safety pre-filter, write `<owner>-<repo>-issue-<n>.md` (github PR/discussion URLs stay out of scope). **Bitbucket Cloud:** the URL host routes the request — `bitbucket.org/<ws>/<repo>` (repo), `/pull-requests/<n>` (PR), and `/issues/<n>` (issue) URLs take the **Bitbucket branch**, dispatching to the himmel `bitbucket` CLI (`scripts/bitbucket/`) instead of `gh`. The bitbucket repo path reuses the github Phase 2/3 ref-following for the **github** refs in its README (BB→BB ref-following + BB has-no-stars/topics trust-tier degradation are documented in the skill); PR/issue paths are flat fetch→write. Invokable as `/luna-ingest <url>` at user prompt (via thin slash-command wrapper) OR `Skill { skill: "obsidian-triage:luna-ingest", args: "<url>" }` from inside another runbook (the skill conversion lifts the runbook out of `.claude/commands/luna-ingest.md` into a Skill-tool-dispatchable form so `/harvest-clips` can call it programmatically inside the interactive session). Two opt-in enrichment flags (off by default, orthogonal): `--deep` inventories reusable components from the code into a deduped `30-Resources/Components/` library; `--research` web-researches the source repo (maturity, alternatives, gotchas) via Claude's own WebSearch and adds a `## Research enrichment` section. The `/harvest-clips` dispatch passes neither.
- **`obsidian-triage:telegram-clip` skill** — pipeline **entry point**: turns a Telegram message (text / bare URL / forward) into a harvest-ready Web Clipper-shaped clip note in `<vault>/Clippings/` (carrying no `harvested_at:`), so `/harvest-clips` ingests it on its next pass. Classifies by the first URL's host (github→`research`, x/twitter→`tweet`, youtube, reddit, other→`article`, no-URL→`note`); preserves sender/ts/message-id provenance; idempotent per message-id. Access-gating is delegated to `telegram:access` (the channel only surfaces allowlisted senders; the tool refuses to write without a sender and never reimplements the allowlist). Invokable as `/telegram-clip <text-or-url>` OR `Skill { skill: "obsidian-triage:telegram-clip", args: "<text>" }` from the interactive telegram channel session. Deterministic logic lives in `tools/telegram-clip.mjs` (pure Node, no runtime deps; the test suite uses the vendored `js-yaml`).

- **`obsidian-triage:roadmap-clips` skill** — cross-source synthesis: aggregates actionable items across daily-note action items, the clipper backlog (`Clippings/_deferred.md`), synthesis proposals, promotion candidates, and the component inventory, clusters them into sequenced themes (effort/impact + target repo), dedups candidate tickets against open Jira, and writes a `60-Maps/<date>-roadmap.md` note. **Proposals only** — never auto-files tickets or restructures the vault (same contract as `/synthesize-clips`). Read-only aggregation lives in `tools/roadmap-aggregate.mjs` (pure Node, no runtime deps); invokable as `/roadmap-clips` OR `Skill { skill: "obsidian-triage:roadmap-clips" }`.

- **`obsidian-triage:grow-feed-log` skill** — a second entry point, parallel to `telegram-clip`: turns a grow-tent Telegram message describing a feed/watering ("added 5L + 2 caps to the mint"), or a bare nutrient-label photo, into an appended entry in `<vault>/20-Areas/Grow/Grow-Feeding-Log.md`. LLM-first by design — no rigid `/feed` command grammar; the skill reads the message (and any photo via `Read`) and derives {date, vessel, water, product, dose, EC, note} itself, resolving vessel names and product identity against the target file's own existing rows/`## Products` section (never a hardcoded table). A feed appends one row to `## Log`; a new product appends a `### <name>` subsection to `## Products` (feed rows wikilink to it via `[[#<name>]]`). Deterministic append logic lives in `tools/grow-feed-log.mjs` (pure Node, no runtime deps): vault-containment, cell sanitization (pipe-escape + newline-collapse so the table can't break), idempotency per `--msg-id` (plus a product-name idempotency gate in product mode), and the `updated:` frontmatter bump. Invokable as `/grow-feed-log <text>` OR `Skill { skill: "obsidian-triage:grow-feed-log", args: "<text>" }`. Telegram routing/access-gating (how a message reaches this skill) is separate, blocked work; this skill only owns the extract+append half.

Together: harvest → **enrich** (X body-fill via `tools/fxtwitter-enrich.mjs` — see `tools/README.md`) → tag → link → action-item → promote-suggest → mark processed → synthesize patterns → graduate to `_done/` → over time, propose structure → roadmap. `Clippings/` acts as an inbox that drains as clips complete the chain. The vault learns from accumulated clips.

The **enrich** stage runs `fxtwitter-enrich.mjs` (X) and `ig-embed-enrich.mjs` (Instagram) between harvest and triage. For X it fills a thin telegram bare-URL stub's `## The Idea` from the tweet text and de-anonymizes `author`/`title` (the `x.com/i/status/<id>` forwards), so triage tags a rich body on its first pass. The same enrich also fires **inline** at `telegram-clip` filing time (best-effort) so group links are usually born rich. Reddit has no dedicated enrich rung: its thin bodies take the Scrapling `local-headless` ladder in `harvest-clip-body-batch.py` (cookieless: every cookie media path was removed), and `scripts/web/fetch-url.sh` routes reddit hosts through the stealth fetch.

### Cookie-backed media paths removed

The Instagram, X, YouTube and Reddit cookie paths are gone, along with the
`HIMMEL_MEDIA_COOKIES` switch that gated them: `gallery-dl --cookies`,
the cookie-backed X thread enricher, `reddit-enrich.mjs`, `playwright-auth-save.mjs`,
`playwright-crawl-x.mjs`, the logged-in YouTube Playwright fallback,
`youtube-state-from-chrome.py` and `lib/cookie-jar.mjs`. Every media fetch is
Scrapling (plus yt-dlp subtitles) and no cookie is sent anywhere. A Scrapling miss is
recorded as deferred with the error `scrapling:<reason>`; with no Scrapling venv
the preflight exits 2 naming `scrapling-venv`. Cookie and storage-state files
from earlier setups are no longer read; delete them by hand if present.

### Daily fetch health

`scripts/luna/fetch-health.py` runs one cheap known-good probe for every live
external fetch integration. It is a plain Python script: no Claude invocation,
no clip mutation, and no fetched response content is written to the Luna vault.
The existing `pipeline-cadence` scheduler arms it daily at **03:30** as
`HIMMEL-Pipeline-FetchHealth`, after the harvest, so it reads the night's state.

| Source integration | Real authentication artifact | Daily probe |
|---|---|---|
| Reddit thread fetch | None | Known public thread `.json?raw_json=1`, validated as a Reddit listing (a 403 reads `blocked-or-rate-limited`) |
| X thin-clip enrichment | None | FxTwitter API response for a known tweet |
| Instagram caption enrichment | None | Instagram `embed/captioned` response for a known post |
| Instagram media enrichment (`instagram-scrapling`) | None: the scrapling venv `~/.himmel/scrapling-venv` | `tools/ig-scrapling-media.py` against a known post |
| X media enrichment (`x-scrapling`) | None: the scrapling venv `~/.himmel/scrapling-venv` | `tools/x-scrapling-media.py` against a known tweet |
| YouTube enrichment (`youtube-scrapling`) | None: the scrapling venv plus `yt-dlp` on PATH | `tools/yt-scrapling-meta.py` for a known video: metadata via Scrapling, transcript via yt-dlp subtitles |
| GitHub harvest / ingest | Authenticated `gh` CLI | `gh api repos/cli/cli` |
| Bitbucket ingest | `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` (process env or the primary checkout's `.env`) | Authenticated `GET /2.0/user` |
| Firecrawl article enrichment | `FIRECRAWL_API_KEY` (process env or the primary checkout's `.env`; `FIRECRAWL_BASE_URL` optional) | `POST /v2/scrape` for `https://example.com/` |

Every probe reads the primary checkout's `.env` (keys living only there once read as missing) — the merge
happens once, at the registry boundary, so the 03:30 cadence run sees the same
config as a manual run even though its wrapper sources nothing. A live
non-empty process value still wins; a set-but-empty one does not. The
duplicate-key and empty-placeholder rules are in
[`docs/internals/environment-gotchas.md`](../../../docs/internals/environment-gotchas.md).

Every result is classified as exactly `ok`, `auth-or-cookie-expired`,
`blocked-or-rate-limited`, or `transport-fail`. Missing credentials or
required CLIs become classified health failures rather
than crashes. Current status and the preserved last-success epoch are written
atomically to `~/.himmel/fetch-health.json` (override:
`HIMMEL_FETCH_HEALTH_STATE`) and exported by the existing passive flow exporter
at `http://127.0.0.1:9877/metrics` as `clip_fetch_source_status` and
`clip_fetch_source_last_success_timestamp`.

### Instagram media rung: `/ig-media-enrich`

The heavyweight escalation rung AFTER `ig-embed-enrich.mjs`. When the caption
rung failed OR left a thin IG body (no `### Transcript` / `### Slides`), the
harvest layer marks the clip `ig_media_pending: true` and **holds it in the
inbox** (triage Phase-8 step-0 and the migrate engine both skip a pending clip);
nothing else drains it. The download rung is **lean-invoke** (`/ig-media-enrich`,
run manually or by the harvest cadence - never auto-fired from `/harvest-clips`,
because the download + local-whisper path is expensive).
`tools/ig-media-fetch.py` downloads the reel/carousel media cookieless via
Scrapling (`tools/ig-scrapling-media.py` in `~/.himmel/scrapling-venv`;
routed as `local-headless`, so `HARVEST_SCRAPE_DENY` /
`.harvest-backends` apply), transcribes reels locally (`ffmpeg` -> mono-16k WAV -> faster-whisper,
the pair pinned in `tools/requirements-whisper.txt` and checked by `tools/whisper-probe.py`),
and recompresses carousel slides into `Clippings/_media/<slug>/slide-NN.jpg`
embedded under `### Slides`. An agent then reads the slide images and the
mechanical `--apply-digest` applier writes the `### Slide digest` (scoped-G-3 +
revert). Distinct **marker namespace**: `media_enriched_at` /
`media_enrichment_status` / `media_last_error` - it never touches ig-embed's
`enriched_at` / `enrichment_status`. **Videos never enter the vault** - only the
transcript TEXT is written; the downloaded reel / mixed-carousel video stays in
the `~/.luna/ig-media/` cache. The tool **clears `ig_media_pending` on a verified
enrichment success**, releasing the held clip back into the pipeline. A
**retryable** failure (login wall, download/no-media error) keeps the flag so the
clip is retried; a **permanent** failure (`removed` / 404 - the media is gone)
also releases the clip so it parks as caption-only evidence rather than stranding
in the inbox forever. A **partial** enrichment (some slides/videos survived,
others dropped in recompress/transcode) writes what succeeded but is marked
`media_enrichment_status: partial` with a `partial_media:` last-error and
withholds `media_enriched_at`, so the clip stays selectable and is retried -
partial media loss is never stamped a full success. A clip whose summary
triage wrote from the URL alone (`summary_basis: url-only`) gets that summary
rewritten from the opening of the transcript, else of the slide digest, right
after a verified write (no model call; `summary_basis: crawled-extract`, and a
stale `harvest_flag: thin-body` is dropped in the same write; never
from an injection-flagged clip or text that trips the injection screen), and
`ig-media-fetch.py --repair-summaries <vault> [--apply] [--limit N]` is the
bounded one-time repair for clips enriched before that (dry run unless
`--apply`, default 10 per run). Command runbook:
`commands/ig-media-enrich.md`.

#### One-time setup (whisper model)

The download rung needs `ffmpeg` and the Scrapling venv, and no login. Do this
ONCE per machine before the first `/ig-media-enrich` run.

1. **Install `ffmpeg`** (the same line the preflight prints when it is missing):

   ```
   winget install Gyan.FFmpeg
   ```

2. **Pre-download the whisper model** so reel transcription runs fully offline
   (first use otherwise blocks on a ~140MB one-time fetch):

   ```
   uv run --python 3.12 --with-requirements tools/requirements-whisper.txt python -c "from faster_whisper import WhisperModel; WhisperModel('base')"
   ```

   **GPU.** `tools/transcribe.py` picks CUDA float16 with
   `large-v3-turbo` when a CUDA device is visible, else CPU int8 with `base`.
   When CUDA is usable but the cuBLAS/cuDNN wheels are not installed it re-execs
   once under `uv` with `tools/requirements-whisper-cuda.txt` added (~1.3 GB, hashed,
   linux x86_64; CPU-only hosts never fetch it). If CUDA then fails to load, it
   falls back to CPU `base`. On CUDA with no pinned model, turbo detects the
   language first and Hebrew at probability >= 0.8 is transcribed by
   `ivrit-ai/whisper-large-v3-turbo-ct2` (loaded lazily; everything else stays on
   turbo; the CPU path never routes). Overrides: `HIMMEL_WHISPER_DEVICE=cpu|cuda`,
   `HIMMEL_WHISPER_MODEL=<name>` (pins the model, no routing),
   `HIMMEL_WHISPER_ROUTE=0` (no routing), and an explicit `[model]` argument wins over both.
   `ig-media-fetch.py` and `x-media-fetch.py` pass no model unless `--whisper-model`
   is given, so the device default and routing apply. The CUDA wheels are probed
   first: only a failed install falls back to CPU, never a bad wav.
   `HIMMEL_WHISPER_DEVICE=cuda` on a host with no GPU still triggers the ~1.3 GB
   wheel download, so leave it unset there. On the
   4090 the turbo model transcribes about 7x faster than `small` on CPU and about
   halves Hebrew WER; VRAM is about 2.5 GB.

3. **Run the one-shot historical backfill.** `--include-evidence` extends the
   scan into `Clippings/_evidence/` (still skipping `_evidence/_rejected/`) so
   already-parked IG clips get enriched too:

   ```
   PYTHONUTF8=1 uv run --python 3.12 python marketplace/plugins/obsidian-triage/tools/ig-media-fetch.py <vault> --include-evidence --limit 0
   ```

   `--limit 0` lifts the default 10-clip cap so the one-shot backfill drains
   every parked clip in a single pass (steady-state runs keep the cap because
   IG rate-limits aggressively). Steady-state runs (no flag) never touch
   `_evidence/`; use the flag only for the one-time backfill.

### X/Twitter media rung: `/x-media-enrich`

The X parallel of `/ig-media-enrich`. The harvest pipeline stores a tweet's
**text + media metadata** only: X media is referenced by URL
(`<video ... src="https://video.twimg.com/...">`,
`![Image](https://pbs.twimg.com/media/...)`) and never downloaded, so a tweet
whose substance IS the media - a video/GIF demo, an animated UI element, a
caption-less visual - leaves nothing searchable behind. This rung captures it.

**Selection differs from the IG rung by design.** IG parks a thin clip with
`ig_media_pending` at harvest and the download rung drains it. X clips are
already harvested rich (the tweet text is in the body) and mostly graduated, so
selection is **body-driven**: `tools/x-media-fetch.py` picks any X-source clip
whose body references `video.twimg.com` / `pbs.twimg.com/media/` and which
carries no `media_enriched_at:`. No harvest/triage/migrate hold is added for X -
the rung enriches clips in place wherever they live. It **parks a retryable
failure with `x_media_pending: true`** (an operator breadcrumb; the clip stays
selectable regardless) and clears it on a verified success.

The rung is **lean-invoke** (`/x-media-enrich`, run manually or by the harvest
cadence - never auto-fired from `/harvest-clips`, because the download +
local-whisper path is expensive). It downloads the
tweet's media cookieless via Scrapling (`tools/x-scrapling-media.py`), transcribes videos
locally (`ffmpeg` -> mono-16k WAV -> faster-whisper), and recompresses images
into `Clippings/_media/<slug>/slide-NN.jpg` embedded under `### Slides`. A
**soundless GIF-like video** (a `tweet_video` with no audio - the animated-UI
case that motivated the ticket) has no audio to transcribe, so its first frame is
screenshotted into the vault as a slide instead; an agent then reads the slide
and the mechanical `--apply-digest` applier writes the `### Slide digest`
(scoped-G-3 + revert) so the purely-visual content becomes searchable text. It
shares the IG rung's **marker namespace** (`media_enriched_at` /
`media_enrichment_status` / `media_last_error`) - safe because the two rungs
select disjoint clip sets (IG source vs X source). **Videos never enter the
vault** - only the transcript TEXT (or the first-frame screenshot for a soundless
GIF) is written; the downloaded video stays in the `~/.luna/x-media/` cache. A
**permanent** failure (`removed` / 404) stamps `media_enriched_at` and releases
the clip so it parks as caption-only; a **partial** enrichment writes what
survived, is marked `media_enrichment_status: partial`, and keeps
`x_media_pending` for retry. Command runbook: `commands/x-media-enrich.md`.

**Subtitles-first transcripts.** Before whisper, the rung pulls
the platform's English subtitles with `yt-dlp` (manual track preferred over auto;
**no cookies needed**), cleans the VTT (tags/timestamps stripped, adjacent
rolling duplicates collapsed, no global dedupe, sentence paragraphs) and uses it
when coverage is at least `--min-sub-coverage` (default 90 percent of the video
duration). No track or low coverage falls back to the Scrapling download -> ffmpeg ->
whisper path. A
clip with no twimg ref (e.g. filed from Telegram) is probed once via fxtwitter
(`tweet.media.videos[].duration`); a post with only photos stamps
`media_probe_result: photo` and takes the download path like any media post; a
post with no media at all stamps `media_probe_at` +
`media_probe_result: no-video` and is never re-probed by the normal run.
`x-media-fetch.py <vault> --reprobe-no-video` is the one-time backfill for
clips stamped `no-video` before photos were recognised. A bare call (or with
`--dry-run`) only prints how many it would re-probe and changes nothing; with
`--live` it probes them again, re-stamps those that have media (the next normal
run fetches them) and leaves the others untouched; `--limit N` caps it (`0` =
all). Every probe, and every stamp or skip decision, appends one JSON line to
`~/.himmel/state/x-media-probe.jsonl` (override `HIMMEL_X_MEDIA_PROBE_LOG`):
`v, ts, host, source, kind` (`kind` is `probe` or `decision`), `clip` (status id),
`path`, then for a probe `url`, `result`, `videos`, `photos`, and for a decision
`action` (`stamp` or `skip`) and `reason`. Never tweet text. A log that cannot be
written costs a stderr note, never the probe.
Provenance lands in the
frontmatter (`media_transcript_source`: `platform-subs` / `auto-subs` /
`whisper-<model>` / `none`, `media_video_duration_s`, `media_transcript_coverage`)
and as a `<!-- source: platform-subs (en), coverage 100%, 38:02 -->` line in the
`### Transcript` block. `tools/transcribe.py` gained an optional
`X_TRANSCRIBE_META_FILE` side channel (last segment end) so whisper coverage is
measurable; its stdout is unchanged.

One-time setup mirrors the IG rung (`ffmpeg`, pre-fetched whisper model). `--include-evidence` and `--include-done` are **orthogonal pool
switches** (each opens exactly one gated pool; neither implies the other): the
steady-state run scans only the inbox, `--include-evidence` adds the
reviewed-evidence pool (never `_evidence/_rejected/`), and `--include-done` adds
the graduated `Clippings/_done/` pool. The **historical backfill** - the pass
that recovers the already-lost visual ideas - passes BOTH so it sweeps every
pool where an old X clip may live:

```
PYTHONUTF8=1 uv run --python 3.12 python marketplace/plugins/obsidian-triage/tools/x-media-fetch.py <vault> --include-done --include-evidence --limit 0
```

**Inbox-internal names** (never source clips; excluded from harvest/triage/archive scans): `_synthesis/` (synthesize output), `_done/` (archive of graduated clips), `_deferred.md` (archive backlog log), `_evidence/` (reviewed-evidence pool — see below; `/synthesize-clips` intentionally keeps visibility into it).

### Evidence-pool substrate

A flat `Clippings/_evidence/` folder serves as the **reviewed-evidence pool**: clips that have been manually reviewed and promoted out of the inbox but are not yet archived to `_done/`. Rejected clips land in `Clippings/_evidence/_rejected/`. **State is encoded by folder location** — there is no `lifecycle:` enum.

When a clip is promoted to `_evidence/`, its `evidence_kind:` frontmatter field (a multi-valued YAML list) is populated using the shared helper `tools/lib/evidence-kind.mjs`. Kinds are drawn from the closed set `authors | concepts | misc | patterns | questions | tools`; `misc` is the fallback when no other kind matches. A clip can hold multiple kinds (e.g. a GitHub repo that is also a conceptual framework gets `[concepts, tools]`). The `promoted_to:` field records the promotion timestamp.

`tools/lib/evidence-kind.mjs` is dependency-free (pure ESM, bare `node`). Harvest, triage, and archive exclude `_evidence/` from their inbox scans; `/synthesize-clips` deliberately keeps visibility into it so synthesis can reference promoted evidence.

### Feed clips: `tools/feed-clip.mjs`

A second pipeline entry point beside `telegram-clip`, with no model call and no npm dependency: it reads the vault's feed list, fetches each RSS, Atom or GitHub `releases.atom` feed, and writes one inbox clip per unseen entry, so release notes and engineering posts reach the vault without a hand-forward.

```bash
node tools/feed-clip.mjs --dry-run            # print what it would clip, write nothing
node tools/feed-clip.mjs --vault <path> --cap 3
```

- **Feed list** — `<vault>/.feed-clip-feeds`, one feed per line: `<feed-url> [label] [skip=<word>,<word>]`, `#` starts a comment. The label prefixes the clip title (`Claude Code: v2.1.0`). The vault template ships a starter list (Claude Code, the Claude Agent SDK, Codex, T3 Code, the MCP specification, the OpenAI engineering blog); `/luna-upgrade` installs it into a vault that lacks it, once, and never overwrites a copy that exists. `--feeds <file>` reads a list from another path.
- **Skip filter** — an entry whose title holds one of a line's `skip=` words (any case, not inside a longer word: `rc` skips `v2.1-rc1` and `rc2`, not `source` or `arc`) is not clipped and not counted as pending, so skipped newest entries do not use up the cap. The starter list skips `alpha`, `nightly`, `rc` and `mobile` on the Codex and T3 Code feeds. A malformed `skip=` (empty, a character outside letters, digits, `.`, `_`, `-`, or given twice) is a `✗` line and the feed line is skipped.
- **Release notes** — the clip body is the entry's own text, so a GitHub release clip carries its release notes. `/harvest-clips` takes a `github.com/<owner>/<repo>/releases/tag/<tag>` clip that has text of its own as an article (clip-body path, injection screen, no repository ingest, a short note is not a thin body); a release link whose body is only the link, a repository root, the releases list and an issue still go to `luna-ingest`.
- **Clip shape** — the front matter of a Telegram clip in the same order (`title`, `source`, `date_clipped`, `type`, `tags: []`, `status: unread`), with `clipped_via: feed` and no `telegram_*` keys; `type` comes from the Telegram classifier (a GitHub link is `research`, other links `article`). It carries no `harvested_at:` and no `processed:`, and lands top-level in `Clippings/`, so `/harvest-clips` and `/triage-clips` take it like any other clip. The body is the entry's text with markup stripped (capped at 6000 characters), then a `## Source` link. An entry without an http(s) link is skipped.
- **Clipped once** — `<vault>/.feed-clip-seen.jsonl` (append-only, one line per clipped entry) is the record; deleting a clip does not bring the entry back. A clip file that already exists is never overwritten.
- **Cap** — at most `--cap` (default 3) new clips per feed per run, newest entry first; the rest stay unseen and arrive on later runs. A feed's first run therefore trickles in over several runs.
- **Failures** — a feed that errors (HTTP status, timeout, not a feed, larger than 8 MiB, a malformed list line) is one `✗ feed-clip:` line; the other feeds are still processed and the exit code stays 0. Login-walled hosts (`x.com`, `instagram.com`, `reddit.com`, …) are refused, also when a redirect leads to one. So is any host that is, or resolves to, a loopback, private (RFC 1918, unique-local IPv6), link-local, unspecified or reserved address, an IP literal and the IPv4-mapped IPv6 forms included, on every hop: the feed fails with `refused: <host> …` and the run goes on. A name is resolved once per hop and the socket connects to the address that was checked, so a name that answers differently the second time is never reached. The suite's loopback fixture server gets in only through the test-only `--unsafe-allow-host <host:port>` option, which the feed list, the environment and the nightly runner's command line cannot set. Exit 2 is for an unusable vault or an unreadable or unwritable state file.
- **Scheduling** — the nightly harvest runner that `scripts/luna/pipeline-cadence.sh` generates runs it before the harvest, at most `--feed-cap` (default 2, set when arming) new clips per feed (see the nightly paragraph below); outside that runner it runs only when invoked by hand.

`tests/test-feed-clip.sh` covers it against synthetic fixture feeds served from local files and a loopback server (never a real feed): one clip per entry and none on the second run, the Telegram clip shape, failing feeds, the cap (3, 3, 3, 1, 0 for ten entries), the seen state, `--dry-run`, a crafted feed that must not stall the parser, a redirect loop, the body-size caps, and non-printable characters in a title. Each guard on untrusted input has a row that goes red when the guard is deleted.

### One-time backfill: `/migrate-clip-lifecycle`

The TRIAGE exit-target change made **triage** drain new `processed: true` clips into `_evidence/`
going forward; the clips processed *before* that change still sit in the
top-level `Clippings/` inbox. `/migrate-clip-lifecycle` (engine:
`tools/migrate-clip-lifecycle.mjs`, dependency-light, reuses `evidence-kind.mjs`)
is the **one-time** backfill that migrates them. It is deterministic, idempotent,
resumable (folder-keyed), and **byte-identically reversible** via a reverse
manifest. Eligible = top-level (depth 1–2) `processed: true` clips only; it never
touches `_evidence/` / `_done/` / `_synthesis/` / `_deferred.md` / unprocessed
clips. Inbound links are rewritten across **SIX literal boundary forms** — the
three plain forms PLUS their `.md`-suffixed twins (`[[Clippings/<id>.md]]`, etc.),
because real `_synthesis/` pages cite clips with the `.md` extension and a
3-form rewrite would leave those dangling silently. Modes: `--dry-run` (plan +
reverse manifest, mutates nothing), `--apply [--month YYYY-MM]` (per-month
staged or all), `--rollback <manifest.json>`. **Not a recurring stage** — run
ONCE behind the mandatory staging gate documented in
`commands/migrate-clip-lifecycle.md` (copy vault → git oracle → apply → assert
zero `.md`-form danglers → rollback → assert `git diff` empty → only then live).

### Daily timeline + telegram feedback (Phase 3 wiring)

The final phase connects the pipeline to the operator's two daily surfaces, so
the vault visibly compounds where the operator already looks.

**Daily timeline.** `tools/daily-timeline.mjs --vault <v> --date <d>`
upserts a single `## Clip pipeline` section into `50-Journal/Daily/<date>.md`
logging the day's flow: **N captured → inbox**, **N reviewed → evidence (by
kind)**, **N promoted → subjects** (with `[[subject]]` backrefs), **N densified
subjects**. It is a **state recount** — it recomputes every metric from vault
state (`date_clipped`/`triaged_at`/`evidence_kind`) plus the synthesize-stubs
ledger — so it is idempotent by construction: re-running the same day UPDATES the
one section, never appends a second or double-counts (bi-temporal: clips carry
`date_clipped`, subjects their own `date`, the daily note anchors *when* review
/ promotion happened). Triage calls it once after Phase 5; `/synthesize-stubs`
calls it after a live `--apply`. A missing daily note is created from
`_Templates/Daily-Note.md`. Section surgery is byte/CRLF-preserving
(`tools/lib/daily-timeline.mjs`).

**Daily report.** The same run upserts a `## Daily report` section
(`tools/lib/daily-report.mjs`) so the day's intake turns into decisions:

- **Sources:** `_evidence/` clips with `triaged_at: <date>`, grouped by
  `evidence_kind`: link, title, and a one-line why (the first sentence of
  `## The Idea`, else of the first prose line). A clip carrying the subtitles-first rung's
  `media_video_duration_s` also gets a video line (duration, transcript
  coverage and source). A day with no intake gets `- No intake on <date>.`
- **Suggested actions:** deterministic, no model. One per clip, first rule
  wins: failed harvest → archive; a tag/source naming himmel|luna|salus → file a
  ticket; a GitHub source or `tools` kind → evaluate the tool (against
  `docs/tool-adoption/rubric.md`); a tag shared with a `60-Maps/` MOC → fold
  into it (clips sharing a MOC merge); else archive. Ranked (archive last, then
  more clips, then engagement), top 7. The report only proposes: nothing here
  edits another note. `tools/apply-clip-actions.mjs` (below) applies the fold and
  archive kinds, and the report stops listing an action the vault shows applied.
- **Markers:** `- [ ] … <!-- act:<id> since:<date> -->`. `[x]` = done, `[-]` =
  dismissed. A tick on today's report survives re-runs.
- **Carry-over:** an action still unchecked in the prior 14 day notes, and not
  ticked or dismissed in any of them, is re-listed under `### Carried over`
  with its age, until it is resolved.

**Telegram promotion feedback.** A telegram capture is **inbox-state by
folder placement** — top-level in `Clippings/` with no `processed:`/`lifecycle:`
marker (design §12.A, no enum); `telegram-clip` adds `telegram_chat_id`
provenance (alongside `telegram_msg_id`) so a later promotion can reply to the
originating chat. When `/synthesize-stubs --apply` promotes a telegram-origin
clip to a subject, the engine writes a **batched digest** to
`<vault>/.synthesize-stubs.telegram-digest.json` — **ONE reply per originating
chat**, not one per promotion (design §12.F) — listing the new `[[subject]]`(s);
the `/synthesize-stubs` runbook sends it through the telegram bridge `reply` tool
(operator-gated live send). A re-run that promotes nothing new clears the stale
digest, and `--no-telegram-digest` suppresses it entirely during the one-time
migration backfill. Pure builder: `tools/lib/telegram-digest.mjs`.

**Subject promotion, per run and by night.** `synthesize-stubs.mjs` treats the
singular and plural spelling of a tag as one subject (`workflow` and `workflows`
make one page; regular English plurals only, and `class`, `status`, `analysis`
keep their form), and `--apply --limit N` writes at most N pages a run, because
Obsidian hangs on bulk file churn; the rest are reported as `pending`. The
nightly runners `scripts/luna/pipeline-cadence.sh` generates run three steps that
make no model call, each logging one `[nightly-...]` line: `feed-clip.mjs` before
the harvest, then after the synthesis `synthesize-stubs.mjs --apply --limit N
--no-telegram-digest` and `apply-clip-actions.mjs --apply --limit N`. A failing
step is reported and never fails the run; a step whose tool is not installed
reports `skipped: tool not installed`. The two writers hold the vault's git index
lock while they write, and both are undone with `--revert <their ledger>`, the actions
ledger first (a clip archived after it was stamped refuses to revert once its stamp is gone).
A clip stamped `archived: true` by the daily note's archive action feeds neither a
subject page nor a synthesis candidate, and a page that already cites it is left as it is.

### Synthesis candidates (`tools/synthesis-candidates.mjs`)

`/synthesize-clips` starts from this read-only script instead of choosing what to
look at: it lists **every** candidate of the four pattern kinds (concept, author,
tag, folder) with its clip count, distinct sources and a PASS or skip verdict. The
agent's remaining job is the substantive-content gate, the page, and one log line
per candidate.

```bash
node tools/synthesis-candidates.mjs [vault] [--today YYYY-MM-DD] [--since YYYY-MM-DD] [--format lines|json]
```

- **Output.** `lines` (default): `PASS <rank> <kind> <slug> clips= evidence= urls= sources= [supersedes=]`
  per passing candidate, the runbook's own `⊘ <slug> — skipped (<category>): <reason> — <detail>`
  line per failing one, `⊘ … excluded from synthesis (input)` per unreadable clip, and a
  `counts` line per kind. `json` adds each candidate's `evidence` list. Same vault and
  same `--today`: byte-identical output. The vault is never written.
- **Ranks interleave the kinds** (best concept, best author, best tag, best folder, then the
  second of each…), so the runbook's per-run page cap cannot be spent on one lens.
- **The four lenses are independent**, as in the runbook: a subject may pass as a concept and as
  a tag, because a concept synthesis and a tag index proposal are different pages. Each lens
  applies its own dedup (a concept page, a person note, a `60-Maps/` MOC, a synthesis page).
- **Skip reasons.** `confidence-floor`: `single-source-domain`, `single-author-on-platform`,
  `too-few-sources` (a concept needs 3 distinct sources, a tag or folder 2), `single-24h-window`,
  `undated-evidence` (fewer than 2 evidence clips carry a parseable date). `dedup`:
  `existing-vault-page` (a concept page or
  `60-Maps/` hub, a person note, a `60-Maps/` MOC, or the folder already exists), `synthesis-page-within-14d`,
  `no-new-evidence` (a page older than 14 days that lists as many clips),
  `substance-floor-recorded` (the runbook logged a substance-gate failure for the slug in
  `Clippings/_synthesis/.substance-skips.tsv` within 14 days and the evidence has not grown, so
  candidates that cannot pass do not use the examination budget every night). A page older than
  14 days with more evidence passes with `supersedes=`.
- **Sources.** For concept and tag groups, clips on a platform domain (x.com, youtube.com,
  reddit.com, instagram.com, tiktok.com, linkedin.com, github.com, medium.com, substack.com,
  threads.net, bsky.app, facebook.com) count one source per distinct author, so many unrelated
  authors on x.com can form a concept page while one author cannot. Any other domain is one
  source. Authors are exempt from the source test; folders keep the plain domain rule. The
  author is the `author:` field, else the x.com or github.com URL; no author at all is one
  shared unknown source.
- **Lenses.** Concept and tag groups come from the clips' `tags:` (platform and clip-type
  tags are ignored); thresholds are 3 clips (concept), 2 (author), 5 (tag), 5 (folder). A group
  below its threshold is not a candidate. Each candidate lists its 40 newest clips (`evidence`);
  `clipCount` is the group total.
- **Dates.** The 24-hour floor reads `date_clipped` (else `triaged_at`); a clip without a
  parseable date cannot help meet it, and a date-time with no zone is read as UTC, so the
  output does not depend on the station's time zone.
- **Gate.** No `<vault>/.harvest.done`: exit 2 with the runbook's message.
- **Frontmatter** is read with the line-based helpers in `tools/lib/frontmatter.mjs`, not a
  YAML parser: a processed clip whose frontmatter never closes, or has a top-level line that is
  not `key: value`, is an input exclusion.

### Clip funnel (outcomes, read-only)

`tools/clip-funnel.mjs --vault <v> [--as-of YYYY-MM-DD] [--days N]` prints one
JSON document answering "is the pipeline doing its job": of the clips taken in,
how many a synthesis page cites, how many subject pages were created or
extended, how many daily actions are open and applied, how many clips wait on
media. The morning report (`scripts/handover/generate-morning-briefing.sh`)
renders it as its `Clip funnel` block. It writes nothing to the vault, reads
each file once and prints the same bytes on two runs.

- **intake:** the flat `Clippings/_evidence/` pool (a subfolder is not evidence).
  A clip stamped `archived: true` is counted in `intake.archived` (the report's
  `Archived` line) and left out of `intake.clips`, of `cited` and of the intake
  movement, so the share of clips cited is of the clips still in view.
- **cited:** a clip is cited when a page in `Clippings/_synthesis/` links it by
  name; the folder in the link and a `.md` suffix do not matter, so a link to
  the clip's old `_done/` folder still counts. Accepted proposals under
  `_synthesis/_done/` are not scanned.
- **subjects:** `.synthesize-stubs.ledger.jsonl`, `stub-create` rows = created,
  `densify` rows = extended, counted per distinct page.
- **actions:** open = the `## Daily report` items in `50-Journal/Daily/` that
  no report ticked or dismissed and the apply ledger has not applied; applied =
  the distinct ids with a `fold` or `archive` row in
  `.apply-clip-actions.ledger.jsonl`. An absent ledger is zero applied. A row
  stays after `apply-clip-actions.mjs --revert`, and a crash can leave a row for
  an edit that never landed, so either still reads as applied.
- **media:** clips with `ig_media_pending: true` or `x_media_pending: true` in
  `Clippings/` (the inbox) or `_evidence/`.

Each stage reports `moved_in_window` (events dated inside the window, default
the 7 days ending on `--as-of`) and `last` (its newest event). `stalled` names
the stages with no movement in the window: `intake`, `cited` and `subjects`
always, `actions` only while some are open, `media` only while some clips wait.

### Applying the daily actions: `tools/apply-clip-actions.mjs`

The two mechanical kinds of suggested action apply themselves; nobody has to
tick them. "Evaluate tool" and "File a ticket" actions need judgement and are
**never** applied.

```bash
node tools/apply-clip-actions.mjs --vault <v> [--date YYYY-MM-DD] [--limit N]            # dry-run (default): prints, writes nothing
node tools/apply-clip-actions.mjs --vault <v> [--date YYYY-MM-DD] [--limit N] --apply    # apply + ledger
node tools/apply-clip-actions.mjs --vault <v> --revert <vault>/.apply-clip-actions.ledger.jsonl
```

- **Fold** (`Fold <clips> into [[60-Maps/<moc>]]`): the clips whose link the map
  lacks are added as `- [[Clippings/_evidence/<clip>|title]]` bullets at the end of
  its `## Evidence` section, which ends at the next `#` or `##` heading (a new
  `## Evidence` section at the end of the map when it has none). Line endings are
  kept.
- **Archive** (`Archive <clip>`): the clip is stamped with two frontmatter keys,
  `archived: true` and `archived_at: <YYYY-MM-DD>` (the run's `--date`). Nothing
  else changes: no move, no link rewrite, `status:` and every other key stay. The
  clip stays in `Clippings/_evidence/`, so synthesis citations and the evidence
  pool are untouched. A clip that already carries an `archived` or `archived_at`
  key other than `archived: true` is left alone and reported. **Nothing reads
  `archived` yet** beyond the daily timeline: excluding archived clips from
  synthesis or promotion is a separate decision.
- **Which actions:** the unticked actions in the day notes of the last 14 days,
  oldest first, each re-derived from the vault by `tools/lib/clip-actions.mjs`, the
  same code `daily-timeline.mjs` lists them with. An action already applied (every
  clip stamped, or every clip linked in the map) is skipped, so a re-run never
  repeats one. The summary line counts what was skipped: never-applied kinds,
  actions the vault no longer reproduces (`unmatched`), and already applied.
- **Bounded:** at most `--limit` actions per run (default 5), because Obsidian
  hangs on bulk file churn. A dry run honours the same limit.
- **Atomic page writes:** apply and revert each write the whole page to a hidden
  temp file beside it, copy the page's permissions, then rename it over the page,
  so a write that fails part-way (a full disk) leaves the page as it was and the
  temp file removed. The temp file is created exclusively: anything already at its
  name (a leftover, or a symbolic link) is never reused or followed, and a page
  that is a symbolic link or other non-regular file is never replaced. Each is one
  printed refusal line (`⊘ <page> — refused: an existing symbolic link sits there,
  nothing written`), the same wording as `synthesize-stubs.mjs`; an apply counts it
  on the summary line (`N refused`) and still exits 0, a
  revert exits 3. (Symlinked maps and clips are not offered by the discovery at all.)
- **Ledger and revert:** one line per applied action in
  `<vault>/.apply-clip-actions.ledger.jsonl` (`--ledger` overrides), carrying the
  page hashes before and after. `--revert` undoes newest-first and **refuses** any
  page whose hash is no longer the recorded post-apply hash (a page edited since is
  not rewritten) and any restore that would not reproduce the recorded bytes: it
  exits 3 if it refused anything. A page path read from a ledger line must stay
  inside the vault (checked on the path as written, so a symlinked folder inside
  the vault still works); the `--ledger` and `--revert` file paths themselves are
  not restricted. Every page path is checked before the first page is written: a
  path that leaves the vault, or that cannot be inspected (it runs through a
  regular file, a symbolic-link loop, a folder with no access), is refused on its
  own line (counted in the summary, exit 3) and the other pages are still
  reverted, so a damaged line never leaves a half-done undo with nothing saying
  which pages were restored (an apply refuses such a page the same way and counts
  it). A ledger line that
  is not valid JSON or lacks the fields of its action stops the run with exit 1
  before anything is written. Reverting twice is a no-op ("already reverted"),
  also when several actions folded into one map. A map hand-edited between two
  applies is refused for the earlier apply (and for anything older on that page),
  not reported reverted: a page counts as already reverted only at a state from
  before that entry or an older one. The ledger line is written before
  its edits, so a crash can leave a line for an edit that never landed (read as
  "already reverted"), never an edit with no line.
- **One writer at a time:** `--apply` and `--revert` take `<vault>/.apply-clip-actions.lock`
  (an atomic `mkdir`, as `/archive-clips` does) and exit 2 while it is held; a run
  that was killed leaves it behind, and the message names it. A dry run ignores it.
  A page open and being edited in Obsidian when the tool rewrites it is not
  detected: Obsidian reloads a file changed on disk.
- **The daily note is not edited.** "Applied" is read off the vault (the stamp, or
  the link in the map), so `daily-timeline.mjs` drops an applied action from
  `### Suggested actions` and `### Carried over` on its next run. The clip carries
  no extra stamp for a fold: the link in the map is the evidence.

The ledger and the lock are vault state like `.synthesize-stubs.ledger.jsonl`; add
`.apply-clip-actions.*` to the vault's `.gitignore` if the vault is a git repo. The nightly synthesize runner applies
the mechanical actions after the promotion, at most 5 a night (`--actions-limit`). Pure Node, no install: `tests/test-apply-clip-actions.sh`.

## Why a plugin

A sibling task ships the install pipeline (Web Clipper extension + JSON templates landed in luna PR #11, see `_Templates/Web-Clipper/import/`). Without triage, clips become a bookmark graveyard inside the vault — the exact failure the source article called out. This plugin owns the triage rhythm.

The clip-ingest brief (tracked in the operator's private handover repo) documents three approach options (A manual / B interactive / C scheduled). This implements **B autonomous** — no per-clip confirmations, but on-demand rather than nightly cron.

## Architecture strategy: statusline-pattern (himmel-as-LOGIC, fork-as-vendor)

This plugin lives in himmel as **independent triage LOGIC**, not embedded in a fork of any upstream skill. Why:

- **LOGIC stays in himmel.** The `/triage-clips` and `/synthesize-clips` runbooks are pure-markdown agent instructions with no dependency on any specific upstream skill. They run against any vault that has a `Clippings/` folder and (optionally) a `_CLAUDE.md` Folder Map.
- **Companion plugins are vendored, not absorbed.** `claude-obsidian` (AgriciDaniel) is tag-pinned directly to upstream in himmel's `marketplace.json` (the `yotamleo` vendor fork was retired at v2.2.0 once its whole carried delta landed upstream). `obsidian` (kepano) and `obsidian-second-brain` (eugeniughelbur) are NOT declared in himmel's marketplace — they install from their own sources (a bare-SHA himmel pin is not installable and kepano publishes no tags). We read their OUTPUTS (skill invocations, frontmatter conventions) — we don't fork their SOURCE.
- **Forks (when needed) are minimal.** We forked `AgriciDaniel/claude-obsidian` as `yotamleo/claude-obsidian` for attribution (banner-only diff from upstream) — similar to how himmel forks `claude-statusline` purely for CRLF/hooks/.gitattributes guardrails. Triage LOGIC does NOT migrate into a fork when one exists; claude-obsidian's fork was retired once upstream absorbed its whole delta and the marketplace pin now points directly at upstream.

Trade-off accepted: a few Luna-flavored fallbacks in the command bodies (folder names like `30-Resources/Concepts/`, `20-Areas/`, `50-Journal/Daily/`). All such paths fall back to `<vault>/_CLAUDE.md` Folder Map for non-Luna vaults. Easy to delete the Luna-specific paragraphs if upstreaming a subset to `eugeniughelbur/obsidian-second-brain` later.

## Install

This plugin ships as part of himmel's marketplace. With the himmel marketplace registered:

```
/plugin install obsidian-triage
```

Companion plugins — read the **Install method** column carefully (different sources have different install paths):

| Plugin | Repo (pinned) | Install method | Why |
|--------|--------------|----------------|-----|
| `obsidian` (kepano) | [kepano/obsidian-skills](https://github.com/kepano/obsidian-skills) — NOT in himmel marketplace | `/plugin install obsidian@obsidian-skills` (kepano's own marketplace) | Provides `obsidian-markdown` skill that `/triage-clips` can use for OFM syntax. **Recommended, not required** — conservative-subset fallback is documented in the command body. *(Not himmel-pinned: a bare-SHA pin isn't installable and kepano publishes no tags.)* |
| `claude-obsidian` (AgriciDaniel) | [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian) @ tag `v3.0.1` in himmel marketplace.json | `/plugin install claude-obsidian` from himmel marketplace | `wiki-query` optionally powers richer Phase 4 Related Notes traversal. Optional. *(The vendor fork was retired at v2.2.0 once upstream absorbed its delta; the pin now points directly at upstream.)* |

## Usage

```bash
# Triage everything unprocessed in Luna's Clippings/
/triage-clips

# Dry-run — report what would change, write nothing (hard contract — phases never write under --dry-run)
/triage-clips --dry-run

# Limit to 5 clips for calibration
/triage-clips --limit 5

# Explicit vault path
/triage-clips ~/Documents/luna

# Cross-clip synthesis weekly
/synthesize-clips --since 2026-05-17

# Both commands accept --dry-run
/synthesize-clips --dry-run
```

## Vault-first link reading

When a link (X post, article, repo URL) is handed to the agent, read it from
the vault **first** — the harvest/clipper pipeline has usually already captured
the full clip body — instead of live-fetching. The priority order:

1. **Vault clip, enriched** → read it; stop, no network.
2. **Vault clip, thin** (skeleton/placeholder body, or only a summary triage wrote
   from the URL) → enrich it (fxtwitter for X; the free fetch rungs for articles,
   plus firecrawl when enabled+gated), then read.
3. **No clip** → live fetch as a last resort: `fxtwitter-enrich.mjs`
   (api.fxtwitter.com) for X, WebFetch for articles, `luna-ingest` for repos.
4. **Never Grok.** `/x-read`'s x.ai path is dead (no credits) and is never called.

`/read-link <url>` is the operator-facing command. `tools/lib/clip-lookup.mjs`
is the single source of truth for *"is this URL already harvested (and
enriched)?"* — a filesystem-only canonical-URL/status-id match plus a per-type
`isThinClipBody` thinness predicate. `telegram-clip.mjs` (`alreadyFiledByUrl`)
and `dedup-sweep.mjs` (`indexVault`) derive their URL key from it, and
`harvest-clips` shells out to `is-thin-cli.mjs` so a thin article clip on a
default machine is fetched through the free rungs, and one the fetch could not
fill is marked `harvest_status: partial` + `harvest_flag: thin-body` and retried
on the next runs (also from `_evidence/`), never `ok` with an empty body. No vault / no clip degrades silently to
live fetch (adopter-safe).

**YouTube.** A YouTube URL, or any "watch / summarize this video" ask, goes to `/watch-youtube <url> [--visual]` (`tools/yt-watch.py`): Scrapling metadata + yt-dlp transcript from `yt-scrapling-meta.py`, plus with `--visual` a ≤720p yt-dlp download and ffmpeg scene frames (`-fps_mode vfr`; ffmpeg 9 rejects `-vsync`). No cookie and no Gemini/Grok/XAI key: Claude reads the transcript and frames itself. Do not use the vault plugin's `/youtube` for this (its upstream `-vsync` fix is still pending).

`/read-link`'s UX is inspired by
[eugeniughelbur/obsidian-second-brain](https://github.com/eugeniughelbur/obsidian-second-brain)'s
`/x-read`; this is a clean-room himmel-native reimplementation that skips Grok —
not a vendored fork (no `UPSTREAM_PIN`, no `plugin-upstreams.json` entry).

**Attribution.** `hooks/validate-ai-first.sh` is ported from
[eugeniughelbur/obsidian-second-brain](https://github.com/eugeniughelbur/obsidian-second-brain)
v0.18.1 (MIT, Eugeniu Ghelbur) and keeps its MIT licence header. The marketplace
no longer carries that plugin; this one hook is the only piece himmel still uses.

## Idempotency

`/triage-clips`:
- Adds `processed: true` + `triaged_at: <today>` to each clip's frontmatter on success. Re-runs skip those clips.
- Phase 5 (action item → daily note) uses **dedup-by-backreference** to guarantee idempotency under partial failure. If a prior run completed Phase 5 but failed before Phase 7, the next run detects the existing `(from [[Clippings/<clip>]])` backref in the daily note and skips re-appending — only writes the missing `processed: true` marker. No duplicate action items.
- To force re-triage of a single clip, delete BOTH `processed: true` AND `triaged_at:` lines manually.

`/synthesize-clips`:
- Deterministic slug derivation (see command body § "Slug derivation") — same pattern + subject → same slug across runs.
- Checks `Clippings/_synthesis/` for existing pages with the same slug within the last 14 days — skips if a proposal stands.
- Old (>14d) proposals get superseded by new ones with `supersedes:` frontmatter linking back.

## Recommended cadence

- After each clipping session OR nightly: `/triage-clips`
- Weekly: `/synthesize-clips --since YYYY-MM-DD` (pass the start-of-week ISO date — script doesn't compute it for you)
- Manual reviewing of `Clippings/_synthesis/` is a once-a-week task. Move accepted proposals to `Clippings/_synthesis/_done/` after acting on them.

## Tests

`tests/test-triage-invariants.sh` validates the scan helper, frontmatter mutation contract, and Phase 7 placement invariants on a portable bash matrix (verified on Git Bash for Windows). Fixture clips live in `tests/fixtures/clips/` — three cover real Web Clipper output shapes (`tags: []` flow-empty, `tags:` block-list with items, and edge-case unicode title).

Run: `bash marketplace/plugins/obsidian-triage/tests/test-triage-invariants.sh`

`tests/test-synthesis-candidates.sh` is the fixture-vault acceptance test for the candidate list: all four kinds list a passing candidate, every skip reason, the platform-domain rule (5 unrelated authors on one platform pass, 5 clips by one author fail), the 14-day dedup window and supersede rule, the evidence cap, input exclusions, the harvest-completion gate, byte-identical re-runs, a read-only vault, and the runbook wiring. Pure Node.

A `tests/test-synthesize-invariants.sh` covers the synthesize-side invariants (processed-filter, 14-day dedup, confidence-floor single-source rejection for Patterns 1/3/4 + the Pattern 2 domain-floor exemption, deterministic slug derivation).

`tests/test-telegram-clip.sh` covers the telegram entry point: URL→type classification, frontmatter shape + provenance, idempotent re-run dedup, `--dry-run` no-write, no-sender refusal, and YAML-validity of the written clip. Requires `bun install` (or `npm install`) in `tools/` first (the YAML-validity check resolves the vendored `js-yaml`).

`tests/test-roadmap-aggregate.sh` covers the roadmap aggregator: per-source parsers (daily action items, `_deferred.md` sections, synthesis `## Proposed vault change`, promotion-candidate frontmatter, component inventory), CLI JSON shape + counts, `_done`-exclusion, empty-source graceful, and vault validation. Pure Node — no `bun install` needed.

`tests/test-daily-timeline.sh` is the fixture-gated acceptance test for the daily `## Clip pipeline` timeline: correct captured/reviewed-by-kind/promoted/densified counts anchored to the target date, byte-identical second-run idempotency, in-place refresh on state change, CRLF preservation, missing-note creation, and the triage/synthesize runbook wiring. Pure Node.

`tests/test-daily-report.sh` is the fixture-vault acceptance test for the `## Daily report` section: sources grouped by kind with why and video lines, ranked actions citing their clips, carry-over with age (done, dismissed and older-ticked actions dropped), byte-identical re-run with ticks preserved, the no-intake line in a created note, CRLF, and shortened titles / capped citations. Pure Node.

`tests/test-apply-clip-actions.sh` is the fixture-vault acceptance test for `tools/apply-clip-actions.mjs`: a dry run leaves the tree byte-identical, `--limit` bounds both dry-run and apply, a second run never repeats an action, fold lands inside `## Evidence` (CRLF kept, a seeded link not repeated), archive stamps only the two keys, evaluate and ticket actions are never touched, the daily timeline stops listing applied actions while keeping the rest, revert restores the vault byte for byte (twice over, also when several folds hit one map) and refuses a page edited since (exit 3), a held run lock stops `--apply` and `--revert` (exit 2), bad arguments are refused (exit 1), a ledger line naming a page outside the vault is refused on its own line while the rest is undone (exit 3), a malformed ledger line stops the revert before any write (exit 1), and a page that became a symbolic link or a link planted at the temporary file's name is refused with its target left byte for byte unchanged. Pure Node.

`tests/test-telegram-digest.sh` + `tests/test-synthesize-telegram-digest.sh` + `tests/test-telegram-clip-inbox.sh` cover the promotion digest (one batched reply per chat — not per promotion — distinct-subject dedup, non-telegram/suppression exclusion, reply threading), its end-to-end emission from `synthesize-stubs --apply` (digest file written, stale-cleared on no-op re-run, suppressed under `--no-telegram-digest`), and the telegram-clip inbox-state contract (no `processed:`/`lifecycle:` marker, `telegram_chat_id` provenance). Pure Node.

`tests/test-grow-feed-log.sh` covers the feed-log entry point against a temp fixture vault (never the real vault): feed-row placement inside the `## Log` table (right after the last existing row, `## Products` untouched), idempotent re-run by `--msg-id` (byte-identical no-op), pipe/newline cell sanitization, `--dry-run` no-write, product-mode section insertion before `## Notes` plus its own product-name idempotency gate, vault/target-file/`## Log`-table validation exit codes, and the `updated:` frontmatter bump on a real write only. Pure Node.

`tests/test-clip-funnel.sh` covers the clip funnel against a synthetic fixture vault (`tests/fixtures/clip-funnel/`): every stage's count, the apply ledger present and absent, the seven-day stall boundary, `--days`, identical bytes on two runs, a vault left byte for byte unchanged, one read per file, and the bad-argument exits.

## Known issues (as of audit cycle 2026-05-25)

Tracked in the operator's private handover repo (the clip-ingest next-session notes). Calibration-on-real-clips will tighten these:

- **Phase 3 tag inference is heuristic.** Conservative ≥80% confidence threshold + "prefer existing vault tags" rule, but real-world false-positive rate unknown until calibration. Tune in command body if needed.
- **Phase 4 Related Notes proximity is grep-based.** Falls back to a comment when `claude-obsidian:wiki-query` skill is unavailable OR vault has >1000 notes. Quality depends on vault link-graph density.
- **Concurrency with Obsidian's auto-save.** Documented at top of `/triage-clips` runbook. There is no cross-platform IPC to detect Obsidian holding a file open — the contract is "don't run while editing Clippings/ or today's daily note in Obsidian." The Phase 7 stale-read guard catches the race after the fact, but the work in Phases 2-6 is wasted if it fires.

## Follow-list scorer

`tools/follow-list-score.mjs` — evidence-first `gather` →
manual Claude judge pass → `assemble` pipeline that scores/tiers the X/Twitter
follow list. See `tools/README.md` ("Follow-list scorer" section) for the
full runbook.

### Advisory repo security scan

`tools/repo-security-scan.mjs` reads a GitHub repo's README, root docs, command and skill markdown, `package.json` and setup scripts through `gh api` (no clone, nothing executed) and reports prompt injection, install hooks, obfuscated payloads, secret upload / pipe-to-shell in setup, and git/URL dependencies. It is advisory: it never installs, rejects or gates anything.

- **Crawler:** `gather` scans each account's top 3 repos by stars and writes the result to `dossier.repos.security_scan[]`. It does not set `injection_suspect`.
- **Ingest:** `/luna-ingest` Phase 1.6 runs `node tools/repo-security-scan.mjs <owner>/<repo>` and records `repo_scan:` plus a `## Security scan (advisory)` section in the tech-ingest note.
- Findings carry a fixed `kind` / `detail` and a sanitized path, never a quote of the repo text. A scan that cannot run is `fetch_error` / `unavailable`, never `clean`.
- Tests: `tests/test-repo-security-scan.sh` (hermetic; `REPO_SCAN_GH_FIXTURE` swaps `gh`).

### Skill scan: SkillSpector (Stage 1 read-through, full scan for vendoring)

`tools/skillspector-scan.sh <skill-dir> <report.json>` runs NVIDIA SkillSpector over one skill directory and stores the JSON report. `SKILLSPECTOR_PROVIDER` picks the mode and has no default:

- **Vendoring (required step):** a skill we want to vendor from someone else's repo gets the full scan, Stage 2 (the AI review) included: `SKILLSPECTOR_PROVIDER=nv_build` with `NVIDIA_INFERENCE_KEY`, or `SKILLSPECTOR_PROVIDER=anthropic` with `ANTHROPIC_API_KEY`, exported in the launching shell (never read from `.env`). The skill text goes to the provider. A missing key is a named refusal (rc 2), never a clean result. The scanner's stderr is kept in the report under `wrapper_stderr` (keys redacted). A HIGH or CRITICAL finding that survives Stage 2 stops the vendoring (rc 4, report stored) until a person reads the flagged line and records its `match_fingerprint` in `<report>.ack`, one per line; running the wrapper again then returns rc 0. A Stage 2 that did not run is rc 3, never clean.
- **Read-through (advisory):** `SKILLSPECTOR_PROVIDER=ollama` runs Stage 1 only (static, `--no-llm`), nothing leaves the machine, and a finding means "read the flagged line before adopting or using the skill" (the pilot saw false positives on clean skills, and Stage 1 never returns SAFE alone).

- **Ingest:** `/luna-ingest <url> --skill-scan` runs Phase 3.7 over each skill directory of the source repo and writes `skill_scan:` plus a `## Skill scan (advisory)` section, with the reports in `<repo-slug>.skillspector/` beside the note.
- **Clips:** `/harvest-clips` passes `--skill-scan` for a clipped `/tree/<branch>/.../skills/...` URL, so a clipped skill is scanned before it is used.
- **What leaves the machine:**
  - **Provider:** the wrapper refuses (rc 2) an unset provider or any outside `ollama`, `nv_build`, `anthropic`. Upstream defaults an unset provider to `nv_build`; only the two full-scan providers send skill text out (to build.nvidia.com or the Claude API). `SKILLSPECTOR_OFFLINE=1` with a full-scan provider is refused (Stage 2 needs the network).
  - **OSV lookup (on by default):** Stage 1 posts the package names and versions from a skill's lockfile to api.osv.dev to check them for known CVEs. This is the scan's one network call, and it stays on. If the lookup fails, the report is incomplete and the wrapper returns rc 3.
  - **Offline (opt-in):** `SKILLSPECTOR_OFFLINE=1` skips the live CVE lookup. The wrapper runs the scanner in an empty network namespace (`unshare --user --map-root-user --net`), SkillSpector checks the dependencies against its small built-in list only, and the summary line ends `deps=offline-fallback`. Use it for a private skill whose dependency list must not leave the machine. Where the namespace cannot be made (macOS, or Linux with unprivileged user namespaces disabled), the wrapper refuses with rc 2.
- **No install:** the wrapper never installs SkillSpector (rc 3 when missing). `pip install` belongs in a throwaway sandbox or the test VM.
- Tests: `tests/test-skillspector-scan.sh` (hermetic stub, incl. a stub Stage 2 HIGH that stops, a clean report that passes, and a missing key that is a named refusal; replays two real reports captured from skillspector 2.12.0 @182a4753 on the pilot fixtures under `tests/fixtures/skillspector/`).

### Opt-in web search: DeepSeek

The claim-check web rung (`tools/lib/follow-web.mjs`) can search with DeepSeek
Search, plus DeepSeek Fetch on the top hit when it has no snippet. **Off for
every install.** A key alone never enables it.

| Switch | Meaning |
|---|---|
| `FOLLOW_WEB_DEEPSEEK=1` | the one opt-in (set it in your own shell or local config, never in the repo) |
| `DEEPSEEK_API_KEY` | the key, read from env only; never printed, logged or ledgered |
| `FOLLOW_WEB_DEEPSEEK_BUDGET` | searches per run (default 20) |

**Privacy terms, plainly:** DeepSeek is PRC-hosted. Queries are stored in the
PRC, may be used to train models, are retained for the account lifetime, and
there is no zero-retention option and no DPA. Opt in only for content you are
content to send there.

- **Order:** the free rungs (local qmd, CLI, hermes) stay first and unchanged. DeepSeek, when opted in, runs only after they miss, and is never called when a free rung already returned a result. Firecrawl stays the last fallback, so its credits cover only DeepSeek misses.
- **salus/PHI never:** the egress matrix (`scripts/guardrails/egress-matrix.json`) hard-denies salus x deepseek for every purpose. The rung checks the vault root before any request and refuses a salus root (a `.salus` marker, or a `phi-roots` / `egress-denylist` overlap), and a root it cannot map to the `luna-clippings` corpus (including no root at all). A refusal prints one stderr line naming the reason.
- **Spend:** $0.00075 per successful call, one row per call in the Firecrawl ledger (`~/.himmel/state/firecrawl-ledger.jsonl`, override `HIMMEL_FIRECRAWL_LEDGER`) with `source: "deepseek"`, `credits: 0` and a `usd` field. `HARVEST_SCRAPE_DENY=all` also drops this rung.
- **Vault root:** `follow-list-score.mjs` passes its vault root; outside it set `FOLLOW_WEB_VAULT_ROOT`.

## Cross-refs

- Sibling task (install pipeline: the Web Clipper extension and templates): done
- This plugin's clip-ingest work: in progress (audit fixes landed; calibration pending)
- Upcoming follow-up: fork `claude-obsidian` for vendor/attribution (statusline-pattern; LOGIC stays in himmel)
- Handover: tracked in the operator's private handover repo
- Templates landed in luna: `_Templates/Web-Clipper/` + `_Templates/Web-Clipper/import/`
- Reference page: luna `30-Resources/Tech/Obsidian Web Clipper Templates.md`
- Source article (the *why*): Kanika (@KanikaBK) — "fill in Related Notes before closing the clip"

## Pin update workflow

The external `claude-obsidian` plugin is pinned in himmel's `marketplace/.claude-plugin/marketplace.json`. The `ref` MUST be an **immutable tag**, never a bare commit SHA: `claude plugin install` clones the source with `git clone --branch <ref>`, and `--branch` only resolves branch/tag *names* — a 40-hex SHA (even one that is the tip of `main`) fails with `fatal: Remote branch <sha> not found`. A branch name would install but moves, breaking reproducibility. So: **tag, not SHA, not branch.** This keeps the same hygiene posture as `npm-audit-signatures` / `pip-hashes` / `lockfile-integrity` — no moving refs in production marketplace entries — while staying installable.

### Bumping the pin (`claude-obsidian`)

`claude-obsidian` pins directly to upstream `AgriciDaniel/claude-obsidian` — the `yotamleo/claude-obsidian` vendor fork was retired at v2.2.0 once upstream merged its whole carried delta (#178 UTF-8 test-stdout guards, #179 CRLF-frontmatter fix). The fork repo stays up as an archive, not deleted. To pick up a new upstream release: in **one himmel PR**, move `marketplace.json`'s `ref` to the new upstream tag and bump `synced_base` in both `scripts/upstreams.json` and [`scripts/plugin-upstreams.json`](../../../scripts/plugin-upstreams.json) to match; `scripts/check-plugin-drift.sh` reports BEHIND once upstream tags newer than the recorded `synced_base` appear.
