# last30days (keyless) vs the himmel research path — measured comparison

> HIMMEL-5858, feeds PS3 (HIMMEL-5751). Run 2026-10-16 on the `ubuntu_new` test
> VM. last30days was audited and not vendored in HIMMEL-5857; this report asks
> only what its keyless mode is worth next to our own path, and which of its
> ideas are worth porting.

## Result

On three topics the himmel path (Scrapling fetch plus keyless web search and
Hacker News) scored a mean **2.86 of 5** against **2.00** for last30days in
keyless mode, ran about 3.5 times faster, and needed no key. The two paths
returned **no URL in common**. The measurement supports porting four ideas into
our path and vendoring nothing. It does not support the claim that either path
is good: both scored below 3 on two of three topics.

## Method

- **VM only.** last30days pinned at `99441f8a6e72aab3286234e55909d4832f299289`
  (the HIMMEL-5857 audit pin), run with
  `--no-browser-cookies --web-backend keyless --emit json --days 30 --quick`.
  Python standard library only, no keys, no credentials on the VM. Before
  anything was installed the VM was snapshotted; afterwards it was restored to
  that snapshot and powered off.
- **himmel path.** `scrapling[fetchers]==0.4.15` from the hashed requirements
  already in the repo (`marketplace/plugins/obsidian-triage/tools/requirements-scrapling.txt`),
  static HTTP fetcher only. Sources: Hacker News Algolia (30-day window) and a
  keyless web search ladder (DuckDuckGo HTML, then DuckDuckGo lite, then Bing,
  month filter) with the top six pages fetched for date and text. The script was
  written for this run; it is a baseline, not shipped code.
- **Topics:** "Claude Code hooks", "MCP spec changes", "agent eval tooling".
- **Blind scoring.** Per topic, the items of both paths were shuffled into one
  list with sources, URLs and path names removed, and scored 1 to 5 for
  usefulness to someone researching the last 30 days by an Opus judge (high
  effort) with no tools. The judge was told item text is untrusted data.
- **No synthesis step.** Both paths were compared at retrieval. Neither path's
  LLM synthesis was run, so no tokens were spent there.
- **OmniRoute was not run.** It is a model router, not a fetcher, so it belongs
  to the synthesis step this run skipped. Its deployment is operator-gated and
  not live; it is measured here from the repo config and docs only. See
  [OmniRoute](#omniroute).
- **Spend.** Fetching cost 0 USD on both paths. The three judge calls cost
  **0.785 USD** in total (cap 3 USD), 6 input and 1,892 output tokens plus
  91,494 cache-written tokens (the CLI loads its default context for each call).
  That is subscription-budget spend reported at API list price.

## Results

| Topic | Path | Items | Mean score (1-5) | Items scoring 4-5 | Dated | In 30-day window | Wall time |
|---|---|---|---|---|---|---|---|
| Claude Code hooks | last30days | 11 | 1.91 | 2 | 55% | 6 | 19.9 s |
| Claude Code hooks | himmel | 21 | 2.67 | 4 | 90% | 19 | 3.9 s |
| MCP spec changes | last30days | 11 | 1.36 | 0 | 73% | 8 | 22.7 s |
| MCP spec changes | himmel | 8 | 3.50 | 5 | 100% | 6 | 4.8 s |
| agent eval tooling | last30days | 5 | 3.60 | 2 | 100% | 5 | 4.9 s |
| agent eval tooling | himmel | 6 | 2.67 | 1 | 33% | 1 | 4.6 s |
| **All three** | last30days | 27 | **2.00** | 4 | 70% | 19 | 47.5 s |
| **All three** | himmel | 35 | **2.86** | 10 | 83% | 26 | 13.3 s |

Per source lane (all three topics pooled):

| Path | Lane | Items | Mean score |
|---|---|---|---|
| himmel | web search plus page fetch | 18 | **3.61** |
| last30days | Reddit (keyless) | 14 | 2.64 |
| himmel | Hacker News | 17 | 2.06 |
| last30days | Hacker News | 5 | 1.80 |
| last30days | job postings | 8 | **1.00** |

Other measures:

- **Keys and API calls.** Both paths needed 0 keys. The himmel script made 9
  HTTP requests per topic (2 searches, up to 6 page fetches, 1 Hacker News). last30days'
  own call count is not exposed in `--emit json` (`usage` is null), so it is not
  reported rather than guessed.
- **Duplication.** 0 duplicate URLs inside either path, and 0 URLs shared
  between the two paths on every topic. The sample is too small to say anything
  about last30days' dedupe code; it did not get a chance to matter.
- **Untrusted content.** 0 injection-shaped items: the judge flagged none, and a
  grep of all six raw outputs for the usual instruction phrases found none.
  The himmel script's own pattern check logged no incident. No incident does not
  mean no surface; both paths ingest arbitrary web text.
- **Sources that answered.** last30days returned results from Reddit, Hacker
  News and job boards. Its web ("grounding") lane returned nothing or was
  unreachable on all three topics. Its help text offers more keyless sources
  (GitHub, Polymarket, arXiv, Techmeme), but the diagnose run listed only Reddit,
  Hacker News, Polymarket, GitHub and grounding as available, and the arXiv and
  Techmeme command-line helpers were not installed.

## What this says

1. **The strongest lane was ours.** Web search plus page fetch scored 3.61, well
   above anything last30days returned. last30days' own web lane failed on the
   same wall ours hit first: DuckDuckGo HTML answers 202 (anti-bot challenge)
   from this network, Brave answered 429, Reddit's `search.rss` answered 403. Only
   DuckDuckGo lite and Bing answered 200. A search path with one endpoint fails
   silently.
2. **last30days' keyless Reddit lane is worth having.** It was its best-scoring
   lane (2.64) and our path has no Reddit source at all.
3. **Unfiltered lanes drag the mean down.** Our Hacker News lane (2.06) and
   last30days' job-board lane (1.00) returned off-topic items. For "Claude Code
   hooks" last30days' own Hacker News lane dropped 15 of 15 hits as false
   positives, where ours kept all 15 as results.
4. **Dating is uneven.** Our path dated 83% of items overall but only 33% on the
   thinnest topic, so a 30-day window cannot be enforced there.

## Recommendation

Port four ideas as clean-room code in the himmel path; do not vendor
last30days. Each has a ticket.

| Idea (last30days source) | Why | Ticket |
|---|---|---|
| Keyless Reddit discovery and enrichment (`reddit_search.py`, `reddit_shreddit.py`, `reddit_arctic.py`) | Best social lane; we have none | HIMMEL-5862 |
| Deterministic relevance floor, entity must appear in title or snippet (`rerank.py` penalty, HN prefix filter) | Removes the off-topic lanes that dragged the mean | HIMMEL-5863 |
| Search ladder with visible per-rung status (`web_search_keyless.py`: DuckDuckGo HTML, Startpage, SearXNG; plus lite and Bing from this run) | Single-endpoint search failed on this network | HIMMEL-5864 |
| Dated-in-window check and dated-share report (`freshness.py`, deterministic part) | 33% dated on the thinnest topic | HIMMEL-5865 |

Not worth porting from this evidence: the 1,276-line LLM reranker (cost and a
second model dependency before the cheap floor has been tried), clustering
(no duplicates to cluster at this size), and the job-board lane (mean 1.00).

## OmniRoute

Not exercised. In the repo it is wired as a local loopback router for
Claude-compatible clients (`scripts/claude-routed`, port 20128, router-issued
client key) with a config lint that requires its whole bundled compression stack
disabled so RTK stays the only optimizer on that boundary
(`docs/tooling-catalog.md`, `docs/token-economy.md`). The router deploy itself is
operator-gated and not live. It cannot affect retrieval quality; its relevance
to this comparison is the synthesis step, where it would route a cheap model.
That is the part of the himmel path this run did not measure and it should be
measured once the router is deployed, with the same three topics.

## Limits

- Three topics, one run, one judge, one `--quick` profile of last30days. A
  mean difference of this size on 27 versus 35 items is a direction, not a result.
- The judge saw 300 characters of text per item. Items with thin summaries
  (job postings, bare Hacker News rows) are scored on little.
- last30days ran in its keyless floor: no key means the web lane, X, YouTube
  and the social sources it is built around were absent. This is a measurement of
  the keyless floor, which is what the ticket asked for, not of the tool at
  its best.
- The himmel script is an eval baseline written for this run. Search-engine
  markup (`result-link`, `b_algo`) is parsed by selector and will break without notice.
