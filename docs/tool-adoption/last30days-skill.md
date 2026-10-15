# last30days (`mvanhorn/last30days-skill`) — tool-adoption eval

HIMMEL-5857, 2026-10-16. Method: [`rubric.md`](rubric.md). Verdict: **REJECT**. Nothing vendored.

## Goal (rubric §1)

- **Problem:** the operator wants "what people said about X in the last 30 days" research.
- **Desired outcome:** a cited trend brief without hand-searching.
- **KPI:** a ticket or decision that ships faster with the brief than with WebSearch plus luna ingest.

## Facts

| Item | Finding |
|---|---|
| Source | `https://github.com/mvanhorn/last30days-skill`, audited at `99441f8a6e72aab3286234e55909d4832f299289` (2026-10-15, v3.28.0) |
| License | MIT, (c) 2026 Matt Van Horn. Vendoring is legal |
| Activity | 1368 commits, 187 in the last 60 days. Very active, so any pin goes stale fast |
| Size | 588 tracked files, about 17 MB under `skills/last30days/` alone: a Python engine (`scripts/lib/`), a vendored X client (`bird-search`, Node), a Go MCP server (`mcp/`), 7 translated READMEs, media assets |
| Keys | 24 distinct key or token env names read by `env.py`, among them `SCRAPECREATORS_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `X_BEARER_TOKEN`, `OPENROUTER_API_KEY`, `PERPLEXITY_API_KEY`, `BRAVE_API_KEY`, `APIFY_API_TOKEN`, `GITHUB_TOKEN`, `AUTH_TOKEN`/`CT0` (X session cookies), `BSKY_APP_PASSWORD`, `TRUTHSOCIAL_TOKEN` |
| Credential access | `chrome_cookies.py` and `cookie_extract.py` decrypt Chromium browser cookies (macOS Keychain passphrase, AES) to authenticate to X. Upstream gates it on consent, but it is browser-profile credential extraction inside a research skill |
| Install behavior | The setup wizard tells the user to run `curl -fsSL https://x.ai/cli/install.sh \| bash`, `pip install yt-dlp`, `npx @mvanhorn/printing-press-library install ...`. Pulls and runs unpinned third-party binaries |
| Egress | Sends the research topic to every enabled source: Reddit, X, YouTube, TikTok, Instagram, Hacker News, Polymarket, GitHub, Bluesky, DuckDuckGo/Startpage fallback, plus any hosted model whose key is set (snippets and comments go to it). Optional upload to `api.ht-ml.app`. `LAST30DAYS_API_BASE` can reroute the topic to another endpoint. None of these hosts has a row in `scripts/guardrails/egress-matrix.json` |
| EEA terms | Free tiers and scraping services (ScrapeCreators, Apify, Bright Data) are third-party; none was checked for EEA terms because the verdict stops earlier. Reddit and X scraping carries its own terms-of-service risk |
| Injection surface | Its whole input is untrusted public social content (posts, comments, transcripts) fed to the model, and `allowed-tools` grants `Bash, Read, Write`. That pairing is the textbook injection path. Not scanned file by file: 588 files exceed a reasonable `source-read-mandatory` read |
| Trust posture | Requires `source-read-mandatory` (secrets, egress, cookie access). A complete read of this tree is not proportionate to the gain |

## Overlap

`WebSearch`, `WebFetch` and the luna ingest flows already cover ad-hoc research with no keys and no new egress. The extra value of last30days is engagement-ranked social sources, which is exactly the part that needs cookies, scraping keys or paid APIs.

## Value test

None run. A live run needs a new API key or browser-cookie consent (the console's approval is required for both) and every path with real signal sends the topic to a host outside the egress matrix. The verdict rests on the static facts above.

## Decision: REJECT

Reason: blast radius out of proportion to the value. Browser-cookie decryption, 24 credential envs, curl-to-bash setup, unaudited egress and untrusted social ingest with `Bash` and `Write` granted, in a 17 MB tree that moves daily.

**Revisit trigger:** the operator names a recurring trend-research need that WebSearch and luna ingest fail at. Then build a narrow keyless in-house slice (Hacker News Algolia, GitHub search, Polymarket public API) with its own egress-matrix rows, not a vendored copy of this tree. Reconsider the upstream skill only if it ships a keyless, cookie-free, pinned-install profile.
