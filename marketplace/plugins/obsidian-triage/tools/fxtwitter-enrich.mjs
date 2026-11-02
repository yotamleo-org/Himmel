#!/usr/bin/env node
/**
 * fxtwitter-enrich.mjs — browser-free X-clip enricher via api.fxtwitter.com.
 *
 * For every clip in <vault>/Clippings/ with:
 *   - processed: true (Stage-4 enrichment runs ONLY on triaged clips)
 *   - source: https://x.com/<user>/status/<id> (or twitter.com)
 *   - no existing enriched_at: marker
 *
 * fetch https://api.fxtwitter.com/<user>/status/<id>, add frontmatter markers,
 * and (for X Articles + quote tweets) append a "## Crawled content" body
 * section. Plain tweets and long ("note") tweets are frontmatter-only
 * enrichments — the body already has the raw text from the clip-body harvest.
 *
 * HIMMEL-2621: a quote tweet gets BOTH — its own text body-filled into
 * "## The Idea" (when the clip body is thin) AND the quoted post under
 * "## Crawled content". The chooser used to be exclusive, so any tweet with
 * a quote recorded only the QUOTED author's words.
 *
 * G-3 invariant: existing body sections must be byte-identical post-write.
 * Only "## Crawled content" may be added (articles + quote-context).
 * Frontmatter mutation is whitelisted to the keys listed in FM_KEYS below.
 * YAML parse-validate post-write; revert to baseline on parse failure.
 * Scoped exception: the backfill re-triage reset (body-fill on an
 * already-processed clip) deliberately mutates the body beyond a single
 * section-add — it strips the triage-authored "## Promotion candidate"
 * section and clears processed:/triaged_at:. On that path the single-
 * section-add identity is skipped; the write-matches-intended-newBody check
 * and YAML parse-validate still guard it.
 *
 * Idempotent: re-runs skip clips with enriched_at: already present.
 *
 * Usage:
 *   bun fxtwitter-enrich.mjs --vault <path> [--limit N] [--dry-run]
 *                            [--reflag] [--reenrich-quote-only]
 *
 * Exit codes:
 *   0 — run completed, no clip failed (partial/skipped alone still exit 0)
 *   1 — bad usage
 *   3 — run completed but at least one clip failed (HIMMEL-1136: distinct
 *       from 0 so a caller gating on exit code sees a 100%-failure run)
 *
 * LUNA-33. Default X enrich path (the Playwright X crawler was removed,
 * HIMMEL-4709).
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, relative, sep, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
// js-yaml is dynamically imported lazily in writeEnrichment so the
// draftJsToMarkdown export can be loaded by tests without the dep
// installed. Tests don't exercise the write path.

const TODAY = new Date().toISOString().slice(0, 10);
const RATE_LIMIT_MS = 1000;
const FETCH_TIMEOUT_MS = 15000;
const FXT_BASE = "https://api.fxtwitter.com";
// Most link-bearing replies by OTHER authors kept under ## Thread.
// The clipped author's own posts are never capped.
export const THREAD_MAX_LINKED_REPLIES = 5;
const SCRAPLING_PY = join(homedir(), ".himmel", "scrapling-venv", "bin", "python");
const SCRAPLING_TIMEOUT_MS = 90000;
// A captured thread: heading + marker, up to the next `## ` heading or end of
// body. Every post line is blockquoted, so tweet text can never end it early.
const THREAD_SECTION_RE = /\n## Thread\n<!-- fxtwitter thread -->[\s\S]*?(?=\n## |\s*$)/;
const FM_KEYS = [
  "enriched_at",
  "enrichment_source",
  "tweet_stats",
  "tweet_is_note",
  "tweet_is_article",
  "tweet_has_quote",
  "enrichment_status",
  "needs_thread",
  "last_error",
  "author",
  "title",
  "harvest_flag",
  "harvest_flag_detail",
];

// Triage-authored frontmatter keys cleared on the backfill re-triage reset
// (body-fill on an already-processed clip). They are NOT in FM_KEYS, so
// upsertEnrichMarkers won't touch them — they must be filtered explicitly.
const RESET_FM_KEYS = ["processed", "triaged_at"];

// The triage-authored "## Promotion candidate" section: heading + its
// `<!-- triage <date> ... -->` marker, up to the next `## ` heading or
// end-of-body. Stripped on the backfill re-triage reset.
const PROMOTION_SECTION_RE = /\n## Promotion candidate\n<!-- triage (?:(?!-->)[\s\S])*?-->[\s\S]*?(?=\n## |\s*$)/;

// A previously written fxtwitter quote-context "## Crawled content" section:
// heading + its `<!-- enriched <date> via fxtwitter (quote-context) -->`
// marker, up to the next `## ` heading or end-of-body. Replaced (not
// duplicated) by the --reenrich-quote-only backfill.
const QUOTE_SECTION_RE = /\n## Crawled content\n<!-- enriched \d{4}-\d{2}-\d{2} via fxtwitter \(quote-context\) -->[\s\S]*?(?=\n## |\s*$)/;

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: fxtwitter-enrich.mjs --vault <path> [--limit N] [--dry-run] [--reflag] [--reenrich-quote-only]");
  out("");
  out("Enrich X clips via api.fxtwitter.com (no browser, no auth).");
  out("--reflag: backfill the needs_thread signal onto already-enriched X clips");
  out("          (fetch + re-evaluate; writes ONLY needs_thread, no body change).");
  out("--reenrich-quote-only: backfill clips already enriched by fxtwitter that have");
  out("          tweet_has_quote: true but NO `## The Idea` — the pre-HIMMEL-2621");
  out("          chooser dropped the clipped author's own text. Re-fetches, adds");
  out("          `## The Idea`, and replaces the stale quote-context section.");
  out("--dry-run: no network, no writes. Runs the js-yaml import and YAML parse-validate");
  out("          on the frontmatter a real run would write, and reports their failures;");
  out("          the G-3 body checks and the fetched content are NOT exercised.");
  out("Only clips with `processed: true` are enriched.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false, reflag: false, reenrichQuoteOnly: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--reflag") out.reflag = true;
    else if (a === "--reenrich-quote-only") out.reenrichQuoteOnly = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  if (out.reflag && out.reenrichQuoteOnly) {
    console.error("--reflag and --reenrich-quote-only are separate backfills; run them one at a time");
    usage(1);
  }
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function sha256(s) {
  return createHash("sha256").update(s).digest("hex");
}

/**
 * Glob Clippings/*.md + one-level subfolders. Same layout as the other enrichers.
 */
function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`fxt-enrich: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  for (const e of readdirSync(root, { withFileTypes: true })) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) out.push(join(sub, s.name));
        }
      } catch {
        // skip unreadable subdir
      }
    }
  }
  return out.sort();
}

/**
 * Parse top-level frontmatter. Minimal
 * YAML-ish, top-level key: value only, CRLF normalized on read.
 */
function parseFrontmatter(text) {
  const normalized = text.includes("\r\n") ? text.replace(/\r\n/g, "\n") : text;
  if (!normalized.startsWith("---\n")) return { fm: null, fmRaw: "", body: normalized, present: false };
  const end = normalized.indexOf("\n---\n", 4);
  if (end < 0) return { fm: null, fmRaw: "", body: normalized, present: false };
  const fmRaw = normalized.slice(4, end);
  const body = normalized.slice(end + 5);
  const fm = {};
  for (const line of fmRaw.split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$/);
    if (m) fm[m[1]] = m[2].trim();
  }
  return { fm, fmRaw, body, present: true };
}

/**
 * Return true when a tweet clip body carries no real tweet text.
 *
 * A body is "thin" when:
 *   - The `## The Idea` section (if present) contains no meaningful lines
 *     (blank, image, template-italic, or bare URL lines are not meaningful).
 *   - The prose between the H1 title and the first `## ` heading is empty or
 *     only the source URL.
 *
 * Used by body-fill enrichment to decide whether to populate `## The Idea`.
 *
 * @param {string} body - the clip body (text after the frontmatter `---`).
 * @returns {boolean}
 */
export function isThinTweetBody(body) {
  const ideaMatch = body.match(/^## The Idea\s*$/m);
  if (ideaMatch) {
    const after = body.slice(ideaMatch.index + ideaMatch[0].length);
    const next = after.search(/^## /m);
    const section = (next < 0 ? after : after.slice(0, next));
    const meaningful = section.split("\n").map((l) => l.trim())
      .filter((l) => l && !/^!\[/.test(l) && !/^\*\(.*\)\*$/.test(l) && !/^https?:\/\/\S+$/.test(l));
    if (meaningful.length > 0) return false;
  }
  const firstH2 = body.search(/^## /m);
  const head = (firstH2 < 0 ? body : body.slice(0, firstH2));
  const prose = head.split("\n").map((l) => l.trim())
    .filter((l) => l && !l.startsWith("# ") && !/^https?:\/\/\S+$/.test(l));
  return prose.length === 0;
}

function alreadyEnriched(fmRaw) {
  return /^enriched_at:\s*\S/m.test(fmRaw);
}

/**
 * Return true when a clip is a pre-HIMMEL-2621 quote-only casualty: enriched
 * by fxtwitter, the tweet carried a quote, the clip still has no
 * `## The Idea`, AND the body carries no real tweet text of its own — i.e. it
 * recorded the QUOTED author's words and dropped the clipped author's own. A
 * clip with no `## The Idea` that already has the author's own prose
 * elsewhere (a different heading, or plain prose before the first `## `) was
 * never a casualty of the old exclusive chooser — body-filling it would
 * duplicate text it already has, so `isThinTweetBody` gates it out. The
 * --reenrich-quote-only backfill targets exactly the casualties; every other
 * clip is skipped under that switch.
 *
 * A clip carrying `last_error: quote_only_no_own_text` (HIMMEL-2628) is also
 * excluded: a prior re-enrich already found the author added no text of
 * their own, so there is nothing left to body-fill and re-fetching it again
 * would only repeat that same no-op-ish rewrite.
 *
 * @param {string} fmRaw - raw frontmatter text.
 * @param {string} body  - the clip body.
 * @returns {boolean}
 */
export function isQuoteOnlyClip(fmRaw, body) {
  if (!/^enrichment_source:\s*"?fxtwitter"?\s*$/m.test(fmRaw)) return false;
  if (!/^tweet_has_quote:\s*"?true"?\s*$/m.test(fmRaw)) return false;
  if (/^last_error:\s*"?quote_only_no_own_text"?\s*$/m.test(fmRaw)) return false;
  if (/^## The Idea\s*$/m.test(body)) return false;
  return isThinTweetBody(body);
}

function isProcessed(fm) {
  const v = (fm.processed || "").toLowerCase().replace(/^"|"$/g, "");
  return v === "true";
}

function isXSource(sourceVal) {
  if (!sourceVal) return false;
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  return /^https?:\/\/(www\.|mobile\.)?(x|twitter)\.com\/[^/]+\/status\/\d+/.test(s);
}

/**
 * Canonicalisation: strip mobile./www.,
 * map twitter.com → x.com, drop query/fragment, keep just /user/status/id.
 */
function canonicalXUrl(sourceVal) {
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  const m = s.match(/^https?:\/\/(?:www\.|mobile\.)?(?:x|twitter)\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `https://x.com${m[1]}`;
}

function fxtUrlFor(canonical) {
  // canonical = https://x.com/<user>/status/<id>
  const m = canonical.match(/^https:\/\/x\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `${FXT_BASE}${m[1]}`;
}

function fxtThreadUrlFor(canonical) {
  // canonical = https://x.com/<user>/status/<id>
  const m = canonical.match(/^https:\/\/x\.com\/[^/]+\/status\/(\d+)/);
  if (!m) return null;
  return `${FXT_BASE}/2/thread/${m[1]}`;
}

/**
 * Fetch the fxtwitter JSON. Returns { ok, tweet, error }.
 */
async function fetchFxt(url) {
  if (process.env.FXT_FIXTURE) {
    try {
      const data = JSON.parse(readFileSync(process.env.FXT_FIXTURE, "utf-8"));
      if (data.code !== 200 || !data.tweet) return { ok: false, error: `api_${data.code}` };
      return { ok: true, tweet: data.tweet };
    } catch (e) { return { ok: false, error: `fixture_err: ${e.message}` }; }
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, {
      headers: { Accept: "application/json", "User-Agent": "fxtwitter-enrich/1.0" },
      signal: ctrl.signal,
    });
    if (!r.ok) return { ok: false, error: `http_${r.status}` };
    const data = await r.json();
    if (data.code !== 200 || !data.tweet) {
      return { ok: false, error: `api_${data.code || "unknown"}_${data.message || ""}`.slice(0, 80) };
    }
    return { ok: true, tweet: data.tweet };
  } catch (e) {
    return { ok: false, error: `fetch_err: ${(e.message || String(e)).slice(0, 80)}` };
  } finally {
    clearTimeout(t);
  }
}

/**
 * Fetch the fxtwitter self-thread JSON (/2/thread/<id>, keyless). Returns
 * { ok, thread, error }. `thread` is an array of posts (possibly the single
 * status itself), or null when fxtwitter found no thread for this id — that
 * is NOT an error, just "no thread".
 */
async function fetchFxtThread(url) {
  // Test seams: one file for every call, or <dir>/<status id>.json per tweet.
  const statusId = (url.match(/(\d+)$/) || [])[1] || "none";
  const fixture = process.env.FXT_THREAD_FIXTURE ||
    (process.env.FXT_THREAD_FIXTURE_DIR ? join(process.env.FXT_THREAD_FIXTURE_DIR, statusId + ".json") : null);
  if (fixture) {
    try {
      const data = JSON.parse(readFileSync(fixture, "utf-8"));
      if (data.code !== 200) return { ok: false, error: `api_${data.code}` };
      return { ok: true, thread: data.thread ?? null, status: data.status ?? null };
    } catch (e) { return { ok: false, error: `fixture_err: ${e.message}` }; }
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, {
      headers: { Accept: "application/json", "User-Agent": "fxtwitter-enrich/1.0" },
      signal: ctrl.signal,
    });
    if (!r.ok) return { ok: false, error: `http_${r.status}` };
    const data = await r.json();
    if (data.code !== 200) {
      return { ok: false, error: `api_${data.code || "unknown"}_${data.message || ""}`.slice(0, 80) };
    }
    return { ok: true, thread: data.thread ?? null, status: data.status ?? null };
  } catch (e) {
    return { ok: false, error: `fetch_err: ${(e.message || String(e)).slice(0, 80)}` };
  } finally {
    clearTimeout(t);
  }
}

/**
 * True when the thread array carries more than one post by screenName.
 * Pure + side-effect free.
 */
function threadHasMultipleByAuthor(thread, screenName) {
  if (!Array.isArray(thread) || !screenName) return false;
  const count = thread.filter((p) => p && p.author && p.author.screen_name === screenName).length;
  return count > 1;
}

/**
 * detectThreadSignal, extended with a fallback network check (HIMMEL-3506):
 * a corporate/launch self-thread often carries no text signal at all on
 * post 1 (no n/N counter, no 🧵, no reply-pointer) — replies > 0 is the only
 * hint. When the text heuristic misses and replies > 0, ask the keyless
 * /2/thread/<id> endpoint whether this status is part of a multi-post
 * self-thread. At most one extra request per clip. A thread-API error is
 * answered `true` (a possible thread, logged on one line), so the caller flags
 * the clip needs_thread / partial rather than reading a failed check as "no
 * thread"; "no thread found" on a good answer stays `false`.
 */
async function detectThreadSignalWithApi(tweet, canon, rel, opts = {}) {
  const repliesCount = tweet.replies ?? 0;
  if (detectThreadSignal(tweet.text || "", repliesCount)) return true;
  if (repliesCount <= 0) return false;
  const threadUrl = fxtThreadUrlFor(canon);
  if (!threadUrl) return false;
  if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);
  const threadRes = await fetchFxtThread(threadUrl);
  if (!threadRes.ok) {
    // A check that could not be made on a tweet with replies is not "no thread".
    console.error(`${rel} -- thread-api check failed, treated as a possible thread: ${threadRes.error}`);
    return true;
  }
  return threadHasMultipleByAuthor(threadRes.thread, tweet.author?.screen_name);
}

// ---------------------------------------------------------------------------
// Keep the thread, not just a yes/no about it
// ---------------------------------------------------------------------------

// Runs under the scrapling venv python as `python -I -c <this> <status url>`.
// A constant: the tweet URL is argv, never part of the code. Prints one JSON
// object {status, posts:[{id, author:{screen_name}, text}]}. A logged-out X
// page shows only a few posts; whatever it shows is kept, nothing more.
const SCRAPLING_THREAD_PY = String.raw`
import json, re, sys
try:
    from scrapling.fetchers import StealthyFetcher
    page = StealthyFetcher.fetch(sys.argv[1], headless=True, network_idle=True, timeout=60000)
    posts = []
    for art in page.css('article[data-testid="tweet"]'):
        node = art.css('[data-testid="tweetText"]')
        text = node[0].get_all_text().strip() if node else ""
        handle = pid = ""
        for a in art.css("a"):
            m = re.match(r"^/([A-Za-z0-9_]+)/status/([0-9]+)$", a.attrib.get("href", ""))
            if m:
                handle, pid = m.group(1), m.group(2)
                break
        if text and pid:
            posts.append({"id": pid, "author": {"screen_name": handle}, "text": text})
    print(json.dumps({"status": "ok" if posts else "no_posts", "posts": posts}))
except Exception as e:
    print(json.dumps({"status": "error", "detail": str(e)[:80]}))
`;

/**
 * Fallback when /2/thread/<id> fails: read the public status page with
 * Scrapling (keyless, no login). Returns { ok, thread, error } like
 * fetchFxtThread. Test seam FXT_SCRAPLING_FIXTURE serves a recorded answer;
 * in any other fixture mode the real venv is never launched.
 */
function fetchThreadViaScrapling(canon) {
  if (process.env.FXT_SCRAPLING_FIXTURE) {
    try {
      const d = JSON.parse(readFileSync(process.env.FXT_SCRAPLING_FIXTURE, "utf-8"));
      if (d.status !== "ok") return { ok: false, error: `scrapling_${d.status}` };
      return { ok: true, thread: d.posts ?? null, status: null };
    } catch (e) { return { ok: false, error: `scrapling_fixture_err: ${e.message}`.slice(0, 80) }; }
  }
  if (process.env.FXT_FIXTURE || process.env.FXT_THREAD_FIXTURE || process.env.FXT_THREAD_FIXTURE_DIR) {
    return { ok: false, error: "scrapling_skipped_fixture_mode" };
  }
  if (!existsSync(SCRAPLING_PY)) return { ok: false, error: "scrapling_not_installed" };
  const r = spawnSync(SCRAPLING_PY, ["-I", "-c", SCRAPLING_THREAD_PY, canon], {
    encoding: "utf-8", timeout: SCRAPLING_TIMEOUT_MS, windowsHide: true,
  });
  if (r.error || r.status !== 0) return { ok: false, error: `scrapling_exit_${r.status ?? "spawn"}` };
  try {
    const d = JSON.parse(String(r.stdout).trim().split("\n").pop());
    if (d.status !== "ok") return { ok: false, error: `scrapling_${d.status}${d.detail ? `: ${d.detail}` : ""}`.slice(0, 80) };
    return { ok: true, thread: d.posts ?? null, status: null };
  } catch { return { ok: false, error: "scrapling_bad_output" }; }
}

/**
 * The thread for one status: the keyless endpoint first, Scrapling when the
 * endpoint errors (not on the inline call, see below). An endpoint answer with no thread is NOT an error (the
 * tweet simply has no continuation). One endpoint request per call.
 */
async function fetchThreadAny(canon, rel, opts = {}) {
  const threadUrl = fxtThreadUrlFor(canon);
  if (!threadUrl) return { ok: false, error: "no_thread_url" };
  if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);
  const res = await fetchFxtThread(threadUrl);
  if (res.ok) return res;
  // The inline call (skipRateLimit) runs inside the Telegram bridge: Scrapling
  // is a synchronous launch of up to a minute there, so it leaves the clip
  // partial for the backfill to finish.
  if (opts.skipRateLimit) {
    console.error(`${rel} -- thread endpoint failed (${res.error}); inline call, no Scrapling fallback`);
    return res;
  }
  console.error(`${rel} -- thread endpoint failed (${res.error}); trying Scrapling`);
  const fb = fetchThreadViaScrapling(canon);
  if (!fb.ok) console.error(`${rel} -- thread not captured: ${fb.error}`);
  return { ...fb, via: "scrapling" };
}

function isLinkBearing(post) {
  if (/https?:\/\/\S+/i.test(post.text || "")) return true;
  const facets = post.raw_text?.facets;
  return Array.isArray(facets) && facets.some((f) => f && f.type === "url");
}

/**
 * Pick what to keep from a thread answer. Pure. Keeps, in answer order, EVERY
 * post by the clipped author (not only a run from post 1) and, capped at
 * THREAD_MAX_LINKED_REPLIES, posts by anyone else that carry a URL. Returns
 * { posts, extraChars, authorExtraChars }: the text beyond the clipped post
 * that `bodyText` (the clip body, when given) does not already hold, in total
 * and by the clipped author alone.
 */
export function extractThreadPosts(thread, clippedId, authorHandle, bodyText = "") {
  if (!Array.isArray(thread) || !authorHandle) return { posts: [], extraChars: 0, authorExtraChars: 0 };
  const norm = (s) => s.replace(/\s+/g, " ").trim();
  const haystack = norm(bodyText);
  const me = authorHandle.toLowerCase();
  const seen = new Set();
  const posts = [];
  let linked = 0;
  for (const p of thread) {
    if (!p || !p.id || !p.text || seen.has(String(p.id))) continue;
    const handle = String(p.author?.screen_name || "");
    const mine = handle.toLowerCase() === me;
    if (!mine) {
      if (!isLinkBearing(p) || linked >= THREAD_MAX_LINKED_REPLIES) continue;
      linked++;
    }
    seen.add(String(p.id));
    posts.push({ id: String(p.id), handle, mine, text: String(p.text).trim() });
  }
  const fresh = posts.filter((p) => p.id !== String(clippedId) && !(haystack && haystack.includes(norm(p.text))));
  const chars = (ps) => ps.reduce((n, p) => n + p.text.length, 0);
  return { posts, extraChars: chars(fresh), authorExtraChars: chars(fresh.filter((p) => p.mine)) };
}

/**
 * Render captured posts as `## Thread`. Every post is labelled with its
 * author handle and blockquoted, so author and non-author text never mix and
 * tweet text can never forge a heading. Handle and id are sanitised.
 */
export function renderThreadSection(posts) {
  const lines = ["## Thread", "<!-- fxtwitter thread -->"];
  for (const p of posts) {
    const handle = p.handle.replace(/[^A-Za-z0-9_]/g, "") || "unknown";
    const id = p.id.replace(/\D/g, "");
    lines.push("", `**@${handle}** (${p.mine ? "author" : "reply with link"}) https://x.com/${handle}/status/${id}`, "", toBlockquote(p.text));
  }
  return lines.join("\n");
}

/**
 * True when replacing the `## Thread` section `existing` with `section` would
 * lose captured text: a post that was kept is missing from the new answer, or
 * is shorter in it. Only the per-post label lines start a post, so a status
 * link inside a post's own text is not a post.
 */
/**
 * Split a held `## Thread` section into the captured posts (up to the last
 * quoted line) and whatever someone wrote below them, which is theirs and is
 * neither compared nor dropped by a rewrite.
 */
function splitThreadTail(section) {
  const lines = section.split("\n");
  let last = -1;
  lines.forEach((l, i) => { if (l.startsWith(">")) last = i; });
  if (last < 0) return { head: section, tail: "" };
  return { head: lines.slice(0, last + 1).join("\n"), tail: lines.slice(last + 1).join("\n").trim() };
}

function threadWouldShrink(existing, section) {
  const label = /^\*\*@\w+\*\* \([^)]*\) https:\/\/x\.com\/\w+\/status\/(\d+)\n/;
  const sizes = (s) => {
    const out = new Map();
    for (const part of s.split(/^(?=\*\*@\w+\*\* \([^)]*\) https:\/\/x\.com\/\w+\/status\/\d+$)/m)) {
      const m = part.match(label);
      if (m) out.set(m[1], part.trim().length);
    }
    return out;
  };
  const want = sizes(section);
  return [...sizes(existing)].some(([id, n]) => !want.has(id) || want.get(id) < n);
}

function statusIdOf(canon) {
  return (canon.match(/\/status\/(\d+)/) || [])[1] || "";
}

/**
 * Thread capture for one clipped tweet (normal enrich path). Never reads ok
 * on a failed check: replies > 0 and neither the endpoint nor Scrapling gave
 * an answer -> needsThread true. A tweet with replies == 0 is not fetched.
 * Only the clipped author's own continuation clears the heuristic flag: a
 * link-bearing reply by someone else does not, and a Scrapling page that shows
 * no continuation proves nothing (a logged-out page lists only some posts).
 * Returns { section, needsThread }.
 */
async function captureThread(tweet, canon, rel, opts = {}) {
  const replies = tweet.replies ?? 0;
  const heuristic = detectThreadSignal(tweet.text || "", replies);
  if (replies <= 0) return { section: null, needsThread: heuristic };
  const res = await fetchThreadAny(canon, rel, opts);
  if (!res.ok) return { section: null, needsThread: true };
  const id = statusIdOf(canon);
  const clipped = Array.isArray(res.thread) ? res.thread.find((p) => p && String(p.id) === id) : null;
  const handle = tweet.author?.screen_name || clipped?.author?.screen_name || "";
  const cap = extractThreadPosts(res.thread, id, handle);
  const section = cap.extraChars > 0 ? renderThreadSection(cap.posts) : null;
  if (cap.authorExtraChars > 0) return { section, needsThread: false };
  return { section, needsThread: res.via === "scrapling" || heuristic };
}

// ---------------------------------------------------------------------------
// Draft.js → markdown converter
//
// X Articles serialize as a Draft.js ContentState:
//   { blocks: [{type, text, inlineStyleRanges, entityRanges, depth}, ...],
//     entityMap: { "<key>": { type, mutability, data: {url, ...} } } }
//
// Inline styles overlap arbitrarily; we resolve them by walking the text
// per character, computing the active style-set at each index, and emitting
// markdown delimiter transitions on style-set changes.
//
// Link entities take precedence over inline styles for the wrapping —
// markdown links wrap, and inline styles emit inside the link text.
// ---------------------------------------------------------------------------

const BLOCK_TYPES = new Set([
  "unstyled",
  "header-one",
  "header-two",
  "header-three",
  "header-four",
  "header-five",
  "header-six",
  "unordered-list-item",
  "ordered-list-item",
  "blockquote",
  "code-block",
  "atomic",
]);

const INLINE_DELIMS = {
  // Order matters for emission stability (BOLD outside ITALIC outside CODE).
  // Map style-name → markdown delimiter.
  BOLD: "**",
  ITALIC: "*",
  CODE: "`",
};
const INLINE_ORDER = ["BOLD", "ITALIC", "CODE"];

function mdEscape(s) {
  // Conservative: escape characters that would prematurely terminate
  // inline markdown. Keep newlines (block renderer handles them) and
  // leave backslash-existing escapes alone.
  return s.replace(/([*_`[\]\\])/g, "\\$1");
}

/**
 * Build a per-character style-set for a single block's text. Returns an
 * array of Sets the same length as the text (counting code points as
 * single positions where Draft.js does — Draft's offset/length count
 * UTF-16 code units, so str.length is the right measure).
 */
function buildStyleMap(text, inlineStyleRanges) {
  const styles = new Array(text.length).fill(null).map(() => new Set());
  if (!Array.isArray(inlineStyleRanges)) return styles;
  for (const r of inlineStyleRanges) {
    if (!r || typeof r.offset !== "number" || typeof r.length !== "number") continue;
    const style = r.style;
    if (!style || !(style in INLINE_DELIMS)) continue;
    const start = Math.max(0, r.offset);
    const end = Math.min(text.length, r.offset + r.length);
    for (let i = start; i < end; i++) styles[i].add(style);
  }
  return styles;
}

/**
 * Build a per-character link-key map. null where no link applies.
 */
function buildLinkMap(text, entityRanges, entityMap) {
  const links = new Array(text.length).fill(null);
  if (!Array.isArray(entityRanges) || !entityMap) return links;
  for (const r of entityRanges) {
    if (!r || typeof r.offset !== "number" || typeof r.length !== "number") continue;
    const ent = entityMap[String(r.key)];
    if (!ent || (ent.type || "").toUpperCase() !== "LINK") continue;
    const url = ent.data && (ent.data.url || ent.data.href);
    if (!url) continue;
    const start = Math.max(0, r.offset);
    const end = Math.min(text.length, r.offset + r.length);
    for (let i = start; i < end; i++) links[i] = url;
  }
  return links;
}

function setsEqual(a, b) {
  if (a.size !== b.size) return false;
  for (const v of a) if (!b.has(v)) return false;
  return true;
}

/**
 * Render a single Draft.js block's inline content to markdown.
 * Handles: inline styles (BOLD/ITALIC/CODE), LINK entities. Other
 * inline styles + entity types fall through as plain text.
 */
function renderInline(block, entityMap) {
  const text = typeof block.text === "string" ? block.text : "";
  if (!text) return "";

  const styleMap = buildStyleMap(text, block.inlineStyleRanges || []);
  const linkMap = buildLinkMap(text, block.entityRanges || [], entityMap || {});

  // Walk text, segment by (linkUrl, styleSet) tuple. Emit one segment at a
  // time. Inline delimiters wrap inside link markdown.
  let out = "";
  let i = 0;
  while (i < text.length) {
    const linkUrl = linkMap[i];
    const styleSet = styleMap[i];
    let j = i + 1;
    while (
      j < text.length &&
      linkMap[j] === linkUrl &&
      setsEqual(styleMap[j], styleSet)
    ) {
      j++;
    }
    const slice = text.slice(i, j);
    // Inline-style wrap, in declared order.
    let wrapped = mdEscape(slice);
    // Strip pure whitespace from the styled wrap targets to avoid e.g. "** **".
    const isAllSpace = !slice.trim();
    if (!isAllSpace) {
      for (const k of INLINE_ORDER) {
        if (styleSet.has(k)) {
          const d = INLINE_DELIMS[k];
          wrapped = `${d}${wrapped}${d}`;
        }
      }
    }
    if (linkUrl) {
      // Markdown link with the wrapped inline content as link text.
      const safeUrl = String(linkUrl).replace(/\)/g, "\\)");
      out += `[${wrapped}](${safeUrl})`;
    } else {
      out += wrapped;
    }
    i = j;
  }
  return out;
}

/**
 * Convert a Draft.js content object to markdown.
 * content = { blocks: [...], entityMap: {...} }
 */
export function draftJsToMarkdown(content) {
  if (!content || !Array.isArray(content.blocks)) return "";
  const entityMap = content.entityMap || {};
  const out = [];
  // Numbered-list counter; resets when block type breaks the run.
  let olCounter = 0;
  for (const block of content.blocks) {
    if (!block || typeof block !== "object") continue;
    const type = (block.type || "unstyled");
    if (type !== "ordered-list-item") olCounter = 0;
    const rendered = renderInline(block, entityMap);
    if (!BLOCK_TYPES.has(type)) {
      // Unknown block type — emit text as plain paragraph; preserves content
      // even when the renderer doesn't know the structural meaning.
      out.push(rendered);
    } else if (type === "header-one") out.push(`# ${rendered}`);
    else if (type === "header-two") out.push(`## ${rendered}`);
    else if (type === "header-three") out.push(`### ${rendered}`);
    else if (type === "header-four") out.push(`#### ${rendered}`);
    else if (type === "header-five") out.push(`##### ${rendered}`);
    else if (type === "header-six") out.push(`###### ${rendered}`);
    else if (type === "unordered-list-item") {
      const depth = Math.max(0, Math.min(6, block.depth || 0));
      out.push(`${"  ".repeat(depth)}- ${rendered}`);
    } else if (type === "ordered-list-item") {
      olCounter += 1;
      const depth = Math.max(0, Math.min(6, block.depth || 0));
      out.push(`${"  ".repeat(depth)}${olCounter}. ${rendered}`);
    } else if (type === "blockquote") {
      // Preserve internal newlines as quoted lines.
      const lines = rendered.split("\n").map((l) => `> ${l}`).join("\n");
      out.push(lines || "> ");
    } else if (type === "code-block") {
      // Wrap in fenced code block. Don't markdown-escape inside.
      const raw = (block.text || "");
      out.push(`\`\`\`\n${raw}\n\`\`\``);
    } else if (type === "atomic") {
      // Atomic blocks reference media via entityRanges; render any link entity.
      if (rendered) out.push(rendered);
    } else {
      // unstyled (paragraph).
      out.push(rendered);
    }
  }
  return out.join("\n\n").trim();
}

// ---------------------------------------------------------------------------
// Frontmatter mutation
// ---------------------------------------------------------------------------

function formatYamlValue(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (Array.isArray(v)) {
    // Flow sequence, e.g. ["@aiedge_"]. Each element formatted recursively
    // so strings get the same quoting/escaping rules.
    return `[${v.map((x) => formatYamlValue(x)).join(", ")}]`;
  }
  if (typeof v === "object") {
    // Flow-style mapping for compact stats: { replies: N, ... }
    const parts = [];
    for (const [k, val] of Object.entries(v)) {
      parts.push(`${k}: ${formatYamlValue(val)}`);
    }
    return `{ ${parts.join(", ")} }`;
  }
  const s = String(v);
  // `@` and backtick are YAML reserved indicators (e.g. @screen_name in a
  // flow sequence) and MUST be quoted or the parse fails.
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]|^[@`]/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

/**
 * Insert/replace whitelisted frontmatter keys (FM_KEYS). In-place replace
 * when key already exists; append after last non-empty line otherwise.
 * Crawl-marker upsert contract shared with the crawlers.
 */
function upsertEnrichMarkers(fmRaw, markers) {
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of FM_KEYS) {
      const re = new RegExp(`^${k}:`);
      if (re.test(line)) {
        seen.add(k);
        // Key not set this run → leave the existing line UNCHANGED. Critical
        // for keys like `author:` that head a YAML block-list — deleting the
        // key line would orphan its `  - "@handle"` items into invalid YAML
        // (the frontmatter-only enrich path doesn't set author/title). Only an
        // EXPLICIT null marker (e.g. last_error: null to clear) deletes.
        if (!(k in markers)) return line;
        if (markers[k] === null) return null;
        return `${k}: ${formatYamlValue(markers[k])}`;
      }
    }
    return line;
  }).filter((l) => l !== null);

  let insertIdx = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) { insertIdx = i + 1; break; }
  }
  const toInsert = [];
  for (const k of FM_KEYS) {
    if (seen.has(k)) continue;
    if (markers[k] === undefined || markers[k] === null) continue;
    toInsert.push(`${k}: ${formatYamlValue(markers[k])}`);
  }
  return [...lines.slice(0, insertIdx), ...toInsert, ...lines.slice(insertIdx)].join("\n");
}

/**
 * Insert "## Crawled content" BEFORE "## Source" (or "## Comments"). Mirrors
 * crawler placement contract.
 */
function insertCrawledSection(body, sectionMarkdown) {
  const sourceMatch = body.match(/^## Source\b/m);
  const commentsMatch = body.match(/^## Comments\b/m);
  let insertAt;
  if (sourceMatch) insertAt = sourceMatch.index;
  else if (commentsMatch) insertAt = commentsMatch.index;
  else {
    const sep2 = body.endsWith("\n") ? "" : "\n";
    return body + sep2 + "\n" + sectionMarkdown + "\n";
  }
  const before = body.slice(0, insertAt);
  const after = body.slice(insertAt);
  const trailingNewlines = before.match(/\n*$/)[0].length;
  let prefix = before;
  if (trailingNewlines < 2) prefix = before.replace(/\n*$/, "") + "\n\n";
  return prefix + sectionMarkdown + "\n\n" + after;
}

// ---------------------------------------------------------------------------
// Section renderers
// ---------------------------------------------------------------------------

function renderArticleSection(tweet) {
  const article = tweet.article || {};
  // Collapse any whitespace (incl. newlines) into a single space so the
  // markdown H3 stays on one line. Truncate fallback to 80 chars after
  // collapsing.
  const rawTitle = article.title || tweet.text || "(untitled article)";
  const title = String(rawTitle).replace(/\s+/g, " ").trim().slice(0, 80) || "(untitled article)";
  const content = article.content || {};
  const md = draftJsToMarkdown(content);
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via fxtwitter (article) -->`,
    "",
    `### ${title}`,
    "",
    md || "_(article body empty)_",
  ];
  return lines.join("\n");
}

/**
 * Render the quoted post's body.
 *
 * `q.text` carries t.co links already expanded to their destination;
 * `q.raw_text.text` keeps the shortener — so `q.text` is preferred here
 * (verified against the live api.fxtwitter.com payloads on HIMMEL-2621).
 *
 * A quoted post that is itself an X Article, or media with a bare t.co
 * stand-in for its text, has no prose of its own. Rendering that verbatim
 * produced sections whose ONLY content was a shortener URL. Fall back to
 * what fxtwitter does give: the article title + preview, or a media marker.
 *
 * The forbidden thing is a bare SHORTENER, not a bare URL. A quoted post
 * whose whole text is a real external link and that carries no article or
 * media metadata still has content worth keeping — so the URL is preserved
 * as the last resort, and only a t.co (which carries nothing on its own)
 * degrades to the no-text marker.
 *
 * @param {object} q - the quoted tweet (tweet.quote).
 * @returns {string} markdown body for the quote section.
 */
function renderQuoteBody(q) {
  const text = (q.text || q.raw_text?.text || "").trim();
  if (text && !/^https?:\/\/\S+$/.test(text)) return text;
  const article = q.article || {};
  const title = String(article.title || "").replace(/\s+/g, " ").trim();
  if (title) {
    const preview = String(article.preview_text || "").trim();
    return preview ? `**${title}**\n\n${preview}` : `**${title}**`;
  }
  const mediaCount = q.media?.all?.length || 0;
  if (mediaCount) return `_(quoted media: ${mediaCount} item(s))_`;
  if (text && !/^https?:\/\/t\.co\//.test(text)) return text;
  return "_(no quote text)_";
}

/**
 * Render text as a markdown blockquote (`> ` per line).
 *
 * HIMMEL-2627: the quoted tweet's text is untrusted, verbatim third-party
 * content and may itself contain a line starting `## `. QUOTE_SECTION_RE's
 * lookahead stops at the next `\n## `, so a bare `## ` line inside the quote
 * would truncate a later strip of this same section. Blockquoting turns any
 * such line into `> ## `, which the strip regex can never match.
 *
 * @param {string} text
 * @returns {string}
 */
function toBlockquote(text) {
  return String(text || "")
    .split("\n")
    .map((line) => (line ? `> ${line}` : ">"))
    .join("\n");
}

function renderQuoteSection(tweet) {
  // tweet.quote holds the quoted tweet
  const q = tweet.quote || {};
  const author = q.author?.screen_name ? `@${q.author.screen_name}` : "(unknown)";
  const text = toBlockquote(renderQuoteBody(q));
  const url = q.url || "";
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via fxtwitter (quote-context) -->`,
    "",
    `### Quoted tweet (${author})`,
    "",
    text,
    "",
  ];
  if (url) lines.push(`[Quoted tweet](${url})`);
  return lines.join("\n");
}

/**
 * Build a populated `## The Idea` section from fetched tweet text.
 *
 * Used by body-fill enrichment to inject tweet text into thin clips.
 *
 * @param {string} text - the tweet's raw text.
 * @returns {string} a markdown section string (no trailing newline).
 */
export function renderIdeaSection(text) {
  const t = String(text || "").trim();
  return ["## The Idea", `<!-- enriched ${TODAY} via fxtwitter (text) -->`, "", t || "_(no tweet text)_"].join("\n");
}

/**
 * Return true when a clip title is a Telegram-harvester placeholder rather
 * than a real title (e.g. "tweet from x.com/i/status/123").
 *
 * Telegram-harvested clips that lack a resolved title arrive with a generated
 * placeholder that encodes the URL. Body-fill enrichment can replace this
 * with the tweet author + text snippet once the fxtwitter payload is fetched.
 *
 * @param {string} title - the clip's H1 title (without the leading `# `).
 * @returns {boolean}
 */
export function isTelegramTitlePlaceholder(title) {
  const s = String(title || "").trim().replace(/^['"]|['"]$/g, "");
  return /^(tweet|article|research|youtube|reddit|note) from (?:x\.com|twitter\.com|mobile\.twitter\.com|\S+)\//.test(s);
}

/**
 * Detect whether a tweet hides content elsewhere — a self-thread
 * continuation ("1/5"), or a payload parked in replies ("repo in comment").
 * Pure + side-effect free. Used to set needs_thread for the escalation pass.
 * Edge-anchors the n/N counter (N in 2..25) to dodge mid-line fractions
 * ("1/2 cup"). Line-start dates ("6/14 …") are an accepted rare false
 * positive — cost is one wasted burner fetch.
 *
 * @param {string} text          tweet.text
 * @param {number} repliesCount  tweet.replies (0 if absent)
 * @returns {boolean}
 */
export function detectThreadSignal(text, repliesCount = 0) {
  if (!text) return false;
  const lines = text.split("\n").map((l) => l.trim());
  const counterRe = /^(\d{1,2})\s*\/\s*(\d{1,2})\b|\b(\d{1,2})\s*\/\s*(\d{1,2})$/;
  const isThreadCounter = lines.some((ln) => {
    const m = ln.match(counterRe);
    if (!m) return false;
    const n = Number(m[1] ?? m[3]);
    const N = Number(m[2] ?? m[4]);
    return N >= 2 && N <= 25 && n >= 1 && n <= N;
  });
  const selfThread =
    isThreadCounter ||
    /\u{1F9F5}/u.test(text) ||            // 🧵
    /\b(a thread|thread:)/i.test(text);
  const replyPointer =
    /repo in (the )?comments?/i.test(text) ||
    /links? in (the )?repl(y|ies)/i.test(text) ||
    /\bin (the )?comments?\b/i.test(text) ||
    /[↓\u{1F447}]/u.test(text);      // ↓ 👇
  return selfThread || (replyPointer && repliesCount > 0);
}

// ---------------------------------------------------------------------------
// Post-body-fill injection re-screen
//
// Body-fill writes untrusted tweet.text into `## The Idea`. That content
// didn't exist when the harvest-time screen ran, so the just-written clip
// must be re-screened before downstream agents (/triage-clips,
// /synthesize-clips) read it. Flag-only — never blocks. The screener is the
// python tool that owns the canonical pattern list.
// ---------------------------------------------------------------------------

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const SCREENER = join(TOOLS_DIR, "harvest-clip-body-batch.py");

/**
 * Run harvest-clip-body-batch.py --scan-only over a just-written clip.
 *
 * Returns null when the clip is clean (no flag needed), or
 * { detail: "<comma-joined classes>" } when a flag must be upserted.
 * Fail-closed: a scanner error (exit 2), a missing interpreter, or any
 * spawn error all return { detail: "screen-error" } so an unscreenable
 * clip is still flagged rather than passing through trusted.
 *
 * @param {string} clipPath - absolute path to the just-written clip.
 * @returns {{detail: string}|null}
 */
function rescreenInjection(clipPath) {
  const screener = process.env.FXT_SCREENER || SCREENER;
  const args = [screener, "--scan-only", clipPath];
  const opts = { encoding: "utf-8", timeout: 20000, windowsHide: true };
  let res = spawnSync("python", args, opts);
  if (res.error && res.error.code === "ENOENT") {
    res = spawnSync("python3", args, opts);
  }
  if (res.error) {
    // Both interpreters ENOENT, or any other spawn failure — fail-closed.
    return { detail: "screen-error" };
  }
  if (res.status === 0) return null;
  if (res.status === 1) {
    const classes = String(res.stdout || "")
      .split("\n").map((l) => l.trim()).filter(Boolean);
    return { detail: classes.join(",") || "injection-suspect" };
  }
  // Exit 2 (scanner error) or any other non-{0,1} status — fail-closed.
  return { detail: "screen-error" };
}

// ---------------------------------------------------------------------------
// Per-clip processing
// ---------------------------------------------------------------------------

// --dry-run runs the write path's js-yaml import and YAML parse-validate on the
// frontmatter a real run would produce, minus the write. It cannot run the G-3
// body checks or see fetch-dependent content: no network, so no section.
const DRY_RUN_LIMIT = "js-yaml + frontmatter YAML checked; G-3 body checks and fetch not run";
const DRY_RUN_MARKERS = {
  enriched_at: TODAY,
  enrichment_source: "fxtwitter",
  enrichment_status: "ok",
  tweet_stats: { replies: 0, retweets: 0, quotes: 0, likes: 0, views: 0 },
  tweet_is_note: false,
  tweet_is_article: false,
  tweet_has_quote: false,
  last_error: null,
};

async function dryRunYamlCheck(rel, fmRaw, markers) {
  try {
    const yaml = await import("js-yaml");
    yaml.load(upsertEnrichMarkers(fmRaw, markers));
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (yaml parse; dry-run): ${e.message}` };
  }
  return null;
}

export async function processClip(clipPath, vault, dryRun, opts = {}) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try {
    text = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` };
  }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { glyph: "o", message: `${rel} -- skipped (no closing ---)` };

  // --reflag (backfill): the normal enrich path below skips already-enriched
  // clips (alreadyEnriched gate), so X clips enriched BEFORE the
  // detectThreadSignal feature never get a needs_thread evaluation. This branch
  // re-evaluates exactly those: fetch the tweet, run the pure detector, and
  // write ONLY needs_thread:true when it fires — no body mutation, no other
  // marker changes (writeEnrichment with section=null keeps the body
  // byte-identical under the no-section G-3 guard). Idempotent: a clip that
  // already has needs_thread:true is skipped.
  if (opts.reflag) {
    const src = fm.source || "";
    if (!isXSource(src)) return { glyph: "o", message: `${rel} -- skipped (reflag: not x/twitter source)` };
    if (!alreadyEnriched(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (reflag: not enriched — normal enrich handles it)` };
    if (THREAD_SECTION_RE.test(body)) return { glyph: "o", message: `${rel} -- skipped (reflag: thread already captured under ## Thread)` };
    if (/^needs_thread:\s*true\s*$/m.test(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (reflag: needs_thread already set)` };
    const canon = canonicalXUrl(fm.harvest_url_canonical || src) || canonicalXUrl(src);
    const fxtUrl = canon && fxtUrlFor(canon);
    if (!fxtUrl) return { glyph: "x", message: `${rel} -- failed (reflag canonicalize): ${src}` };
    if (dryRun) {
      const bad = await dryRunYamlCheck(rel, fmRaw, { needs_thread: true });
      return bad || { glyph: "v", message: `${rel} -- would reflag via ${fxtUrl} [dry-run; ${DRY_RUN_LIMIT}]` };
    }
    if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);
    const fxt = await fetchFxt(fxtUrl);
    if (!fxt.ok) return { glyph: "~", message: `${rel} -- partial (reflag fetch): ${fxt.error}` };
    if (!(await detectThreadSignalWithApi(fxt.tweet, canon, rel, opts))) {
      return { glyph: "o", message: `${rel} -- skipped (reflag: no thread signal)` };
    }
    return await writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: {
        needs_thread: true,
        enrichment_status: "partial",
        ...(!fm.last_error || fm.last_error === "null" ? { last_error: "thread_not_captured" } : {}),
      },
      section: null, resetTriage: false,
      statusGlyph: "v", statusMsg: "reflagged needs_thread",
    });
  }

  // --reenrich-quote-only: clips already enriched by
  // fxtwitter whose tweet carried a quote lost the clipped author's own text,
  // because the old chooser was exclusive. They are already-enriched, so the
  // normal path skips them forever. This switch re-processes exactly those —
  // fxtwitter source, tweet_has_quote: true, NO `## The Idea` yet, and no
  // real tweet text elsewhere in the body (isQuoteOnlyClip) — and nothing
  // else: every other clip is skipped under it.
  const thinBody = isThinTweetBody(body);
  const quoteBackfill = !!opts.reenrichQuoteOnly && isQuoteOnlyClip(fmRaw, body);
  if (opts.reenrichQuoteOnly && !quoteBackfill) {
    return { glyph: "o", message: `${rel} -- skipped (reenrich-quote-only: not a quote-only fxtwitter clip)` };
  }

  if (!isProcessed(fm) && !thinBody && !quoteBackfill) {
    return { glyph: "o", message: `${rel} -- skipped (not processed, body not thin)` };
  }
  if (alreadyEnriched(fmRaw) && !quoteBackfill) return { glyph: "o", message: `${rel} -- skipped (already enriched)` };
  const sourceVal = fm.source || "";
  if (!isXSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not x/twitter source)` };

  const canon = canonicalXUrl(fm.harvest_url_canonical || sourceVal) || canonicalXUrl(sourceVal);
  if (!canon) return { glyph: "x", message: `${rel} -- failed (canonicalize): ${sourceVal}` };
  const fxtUrl = fxtUrlFor(canon);
  if (!fxtUrl) return { glyph: "x", message: `${rel} -- failed (build fxt url): ${canon}` };

  if (dryRun) {
    const what = quoteBackfill ? "would re-enrich (quote-only)" : "would enrich";
    const bad = await dryRunYamlCheck(rel, fmRaw, DRY_RUN_MARKERS);
    return bad || { glyph: "v", message: `${rel} -- ${what} via ${fxtUrl} [dry-run; ${DRY_RUN_LIMIT}]` };
  }

  // Rate-limit BEFORE the network call. The single inline telegram-clip call
  // (serial bridge) skips it — politeness only matters for the batch loop.
  if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);

  const fxt = await fetchFxt(fxtUrl);
  if (!fxt.ok) {
    // Network / API failure — do NOT write enriched_at, so a re-run picks
    // the clip back up (transient 429s / 5xx clear naturally). Permanent
    // failures (404 tweet-deleted, 401 suspended) will keep tripping this
    // path on every run; the operator handles those out-of-band.
    return { glyph: "~", message: `${rel} -- partial (fxt fetch): ${fxt.error}` };
  }

  const tweet = fxt.tweet;
  const isArticle = !!(tweet.article && tweet.article.content);
  const isNote = !!tweet.is_note_tweet;
  const hasQuote = !!tweet.quote;

  const stats = {
    replies: tweet.replies ?? 0,
    retweets: tweet.retweets ?? 0,
    quotes: tweet.quotes ?? 0,
    likes: tweet.likes ?? 0,
    views: tweet.views ?? 0,
  };

  let section = null;
  // True only on the real-text body-fill path (## The Idea inserted from
  // untrusted tweet.text) — the path that needs the injection re-screen.
  let didBodyFill = false;
  // Body-fill markers for thin plain/note tweets (author/title repair).
  const bodyFill = {};
  // Quote tweet, thin body, but the author added no text of their own —
  // there is nothing to body-fill. Set below so the terminal last_error
  // marker stops isQuoteOnlyClip re-selecting this clip.
  let quoteOnlyNoOwnText = false;
  if (isArticle) {
    section = renderArticleSection(tweet);
  } else if (hasQuote) {
    // a quote tweet carries BOTH — the clipped author's own text
    // (body-filled into `## The Idea` when the clip body is thin, through the
    // SAME didBodyFill path so the injection re-screen runs) and
    // the quoted post under `## Crawled content`. The two render into one
    // section string so the single G-3 section-add identity still holds.
    // quoteBackfill implies thinBody (isQuoteOnlyClip requires
    // isThinTweetBody), so the plain thinBody check covers both paths.
    const quoteSection = renderQuoteSection(tweet);
    const ownText = (tweet.text || "").trim();
    if (thinBody && ownText) {
      section = `${renderIdeaSection(tweet.text)}\n\n${quoteSection}`;
      didBodyFill = true;
      if (!fm.author) bodyFill.author = [`@${tweet.author?.screen_name || ""}`];
      if (isTelegramTitlePlaceholder(fm.title)) {
        bodyFill.title = ownText.replace(/\s+/g, " ").trim().slice(0, 80);
      }
    } else {
      section = quoteSection;
      if (thinBody) quoteOnlyNoOwnText = true;
    }
  } else if (thinBody) {
    // Thin plain/note tweet: inject tweet text into `## The Idea`.
    const tweetText = (tweet.text || "").trim();
    if (!tweetText && tweet.media?.all?.length) {
      // Media-only tweet: no text to inject. Mark partial so a later
      // resolver (or operator) can attend to the media.
      const mediaMarkers = {
        enriched_at: TODAY,
        enrichment_source: "fxtwitter",
        enrichment_status: "partial",
        last_error: "media_only",
        tweet_is_note: isNote,
        tweet_is_article: false,
        tweet_has_quote: false,
      };
      return writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers: mediaMarkers, section: null, resetTriage: false, statusGlyph: "~", statusMsg: "partial (media_only)" });
    }
    if (!tweetText) {
      // Empty text, no media — write NO marker so a re-run retries (the
      // fxt payload may have been transiently empty).
      return { glyph: "~", message: `${rel} -- partial (tweet_unavailable: empty text)` };
    }
    section = renderIdeaSection(tweet.text);
    didBodyFill = true;
    if (!fm.author) bodyFill.author = [`@${tweet.author?.screen_name || ""}`];
    if (isTelegramTitlePlaceholder(fm.title)) {
      bodyFill.title = tweet.text.replace(/\s+/g, " ").trim().slice(0, 80);
    }
  }
  // Plain tweets + note tweets add no section here; a captured thread below
  // may still add `## Thread`.

  // Keep the posts the thread endpoint returns (## Thread). A
  // thread that could not be read (endpoint and Scrapling both failed) on a
  // tweet with replies is needs_thread, never ok.
  const thread = await captureThread(tweet, canon, rel, opts);
  const needsThread = thread.needsThread;
  // Thread text is untrusted tweet text too: take the injection re-screen.
  if (thread.section) didBodyFill = true;

  const markers = {
    enriched_at: TODAY,
    enrichment_source: "fxtwitter",
    // A thread that is flagged but not captured is partial, not ok with the
    // continuation silently missing.
    enrichment_status: needsThread ? "partial" : "ok",
    tweet_stats: stats,
    tweet_is_note: isNote,
    tweet_is_article: isArticle,
    tweet_has_quote: hasQuote,
    ...(needsThread ? { needs_thread: true } : {}),
    last_error: quoteOnlyNoOwnText ? "quote_only_no_own_text" : needsThread ? "thread_not_captured" : null,
    ...bodyFill,
  };
  const res = await writeEnrichment({
    clipPath, rel, text, baselineSha, fmRaw, body, markers, section,
    threadSection: thread.section,
    // The re-triage reset is for the thin→filled transition at FIRST enrich.
    // The quote backfill is a corrective re-enrich of clips that were already
    // triaged (and mostly archived into _evidence/) — clearing processed: on
    // those would strip 170 triage-authored `## Promotion candidate` sections
    // and dump the whole archive back into the triage queue. Not this ticket's
    // job: the backfill restores dropped text, it does not re-open verdicts.
    resetTriage: thinBody && isProcessed(fm) && !quoteBackfill,
    // On the quote backfill the clip already carries a stale quote-context
    // section; replace it rather than adding a second one.
    stripQuoteSection: quoteBackfill,
    statusGlyph: "v",
    statusMsg: `${quoteBackfill ? "re-enriched (quote-only)" : "enriched"} (article=${isArticle}, note=${isNote}, quote=${hasQuote})`,
  });

  // re-screen the just-written clip for prompt injection on the
  // real-text body-fill path only (## The Idea now holds untrusted tweet
  // text). Flag-only — a hit (or a fail-closed screen-error) adds the
  // harvest_flag markers via a second small marker-only write. The body is
  // byte-identical on this second write, so the normal no-section G-3 check
  // protects it. Re-screen only after a verified write (res.glyph === "v").
  if (didBodyFill && res.glyph === "v") {
    const flag = rescreenInjection(clipPath);
    if (flag) {
      const flagMarkers = { harvest_flag: "injection-suspect", harvest_flag_detail: flag.detail };
      // Fail-closed flag-write. If the re-read/parse/write of the flag fails
      // (throw or no parseable frontmatter), the injection verdict would be
      // silently dropped — leaving untrusted tweet.text in `## The Idea` with
      // NO harvest_flag (downstream reads it as trusted). The fail-closed move
      // is to NOT leave the untrusted content on disk: revert to the original
      // pre-enrichment stub (harvest retries later).
      try {
        const enrichedText = readFileSync(clipPath, "utf-8");
        const ep = parseFrontmatter(enrichedText);
        if (!ep.present) {
          writeFileSync(clipPath, text, { encoding: "utf-8" });
          return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted to stub, fail-closed): no parseable frontmatter on re-read` };
        }
        const flagRes = await writeEnrichment({
          clipPath, rel, text: enrichedText, baselineSha: sha256(enrichedText),
          fmRaw: ep.fmRaw, body: ep.body, markers: flagMarkers, section: null,
          resetTriage: false, statusGlyph: "v",
          statusMsg: `${res.message.replace(`${rel} -- `, "")} [injection-suspect: ${flag.detail}]`,
        });
        return flagRes;
      } catch (e) {
        writeFileSync(clipPath, text, { encoding: "utf-8" });
        return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted to stub, fail-closed): ${e.message}` };
      }
    }
  }
  return res;
}

/**
 * Write the enriched clip with full G-3 / YAML verification and revert.
 */
async function writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body: bodyIn, markers, section, threadSection = null, resetTriage = false, stripQuoteSection = false, statusGlyph, statusMsg }) {
  // A thread already in the clip is never shrunk by a shorter answer.
  const held = bodyIn.match(THREAD_SECTION_RE);
  if (threadSection && held) {
    const { head, tail } = splitThreadTail(held[0]);
    if (threadWouldShrink(head, threadSection)) threadSection = null;
    else if (tail) threadSection = `${threadSection}\n\n${tail}`;
  }
  // A rewritten thread replaces the one already in the clip, so the G-3
  // single-section-add identity is checked against the body without it.
  const body = threadSection ? bodyIn.replace(THREAD_SECTION_RE, "") : bodyIn;
  // Stale-read guard.
  let nowText;
  try {
    nowText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (re-read): ${e.message}` };
  }
  if (sha256(nowText) !== baselineSha) {
    return { glyph: "~", message: `${rel} -- partial (stale-read): operator-edit detected mid-pass` };
  }

  let newBody = body;
  // Quote backfill: drop the stale fxtwitter quote-context
  // section before inserting the freshly rendered one, so the clip ends up
  // with exactly one `## Crawled content`.
  if (stripQuoteSection) newBody = newBody.replace(QUOTE_SECTION_RE, "");
  if (section) newBody = insertCrawledSection(newBody, section);
  if (threadSection) newBody = insertCrawledSection(newBody, threadSection);
  let fmForMarkers = fmRaw;
  if (resetTriage) {
    // Backfill re-triage reset: strip the triage-authored promotion section
    // from the body, and drop processed:/triaged_at: from the frontmatter so
    // a later /triage-clips re-tags the now-rich clip cleanly. These keys are
    // not in FM_KEYS, so upsertEnrichMarkers leaves them — filter explicitly.
    newBody = newBody.replace(PROMOTION_SECTION_RE, "");
    fmForMarkers = fmRaw.split("\n")
      .filter((line) => !RESET_FM_KEYS.some((k) => new RegExp(`^${k}:`).test(line)))
      .join("\n");
  }
  const newFm = upsertEnrichMarkers(fmForMarkers, markers);
  const newText = `---\n${newFm}\n---\n${newBody}`;

  try {
    writeFileSync(clipPath, newText, { encoding: "utf-8" });
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (write): ${e.message}` };
  }

  // Verify + revert-on-failure.
  let diskText;
  try {
    diskText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write read; reverted): ${e.message}` };
  }
  const post = parseFrontmatter(diskText);
  if (!post.present) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted)` };
  }
  if (post.body !== newBody) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  // G-3 single-section-add: when we added a section, stripping it from the
  // post-write body must leave the original intact. When we didn't, body
  // must be byte-identical to the original.
  //
  // SKIPPED on the backfill re-triage reset: that path deliberately mutates
  // the body beyond a single-section-add (it strips the promotion section),
  // so the single-section-add identity no longer holds. Same for the
  // quote backfill, which replaces the stale quote-context
  // section. The other guards (post.body === newBody write-succeeded check
  // above, frontmatter-present check above, YAML parse-validate below) still
  // fully protect the write.
  if (!resetTriage && !stripQuoteSection) {
    if (section || threadSection) {
      let stripped = post.body;
      if (section) stripped = stripped.replace(section, "");
      if (threadSection) stripped = stripped.replace(threadSection, "");
      stripped = stripped.replace(/\n{3,}/g, "\n\n");
      const origNorm = body.replace(/\n{3,}/g, "\n\n");
      if (!stripped.includes(origNorm.trim().slice(0, 200))) {
        writeFileSync(clipPath, text, { encoding: "utf-8" });
        return { glyph: "x", message: `${rel} -- failed (G-3 single-section-add; reverted)` };
      }
    } else if (post.body !== body) {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { glyph: "x", message: `${rel} -- failed (G-3 body changed without section; reverted)` };
    }
  }
  // YAML parse-validate. js-yaml imported lazily so test imports
  // of draftJsToMarkdown don't need the dep installed.
  try {
    const yaml = await import("js-yaml");
    yaml.load(post.fmRaw);
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (yaml parse; reverted): ${e.message}` };
  }
  return { glyph: statusGlyph, message: `${rel} -- ${statusMsg}` };
}

/**
 * x-thread-backfill.mjs, one clip. Re-fetches the thread of an X clip and
 * (only when `apply`) rewrites the `## Thread` section plus the status fields
 * it owns (needs_thread, and enrichment_status / last_error when they were
 * only the thread_not_captured stamp). Never touches the rest of the body or
 * enriched_at. Returns { kind, chars, message } where kind is one of
 *   skip         not an X clip (not counted)
 *   adds-text    the thread holds text the clip lacks (chars = how much)
 *   no-new-text  fetched fine, nothing to add (also: already applied)
 *   fetch-failed endpoint and Scrapling both failed, or only Scrapling answered
 *                and showed no continuation; the clip is left as is
 *   write-failed a guarded write was reverted
 * Idempotent: a second apply finds the identical section and reports
 * no-new-text without writing.
 */
export async function rethreadClip(clipPath, vault, apply, opts = {}) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try { text = readFileSync(clipPath, "utf-8"); }
  catch (e) { return { kind: "fetch-failed", chars: 0, message: `${rel} -- unreadable: ${e.message}` }; }
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present || !isXSource(fm.source || "")) return { kind: "skip", chars: 0, message: `${rel} -- not an X clip` };
  const canon = canonicalXUrl(fm.harvest_url_canonical || fm.source) || canonicalXUrl(fm.source);
  if (!canon) return { kind: "skip", chars: 0, message: `${rel} -- no canonical X url` };

  const res = await fetchThreadAny(canon, rel, opts);
  if (!res.ok) return { kind: "fetch-failed", chars: 0, message: `${rel} -- ${res.error}` };

  const id = statusIdOf(canon);
  const clipped = Array.isArray(res.thread) ? res.thread.find((p) => p && String(p.id) === id) : null;
  const handle = clipped?.author?.screen_name || res.status?.author?.screen_name || (canon.match(/x\.com\/([^/]+)\//) || [])[1];
  const existing = body.match(THREAD_SECTION_RE);
  // Text the clip already holds outside its thread section is not "new".
  const cap = extractThreadPosts(res.thread, id, handle && handle !== "i" ? handle : "", body.replace(THREAD_SECTION_RE, ""));
  // A logged-out Scrapling page that shows nothing past the clipped post proves
  // nothing about the thread: it is a failed check, not "no more text".
  if (res.via === "scrapling" && !cap.posts.some((p) => p.mine && p.id !== id)) {
    return { kind: "fetch-failed", chars: 0, message: `${rel} -- thread not captured: the Scrapling page showed no continuation` };
  }
  if (cap.extraChars <= 0) return { kind: "no-new-text", chars: 0, message: `${rel} -- no more text in the thread` };

  const section = renderThreadSection(cap.posts);
  if (existing) {
    const { head } = splitThreadTail(existing[0]);
    if (head.trimEnd() === `\n${section}`) return { kind: "no-new-text", chars: 0, message: `${rel} -- thread already in the clip` };
    // Never lose a post an earlier fetch kept: replace only with a superset.
    if (threadWouldShrink(head, section)) return { kind: "no-new-text", chars: 0, message: `${rel} -- kept the fuller thread already in the clip` };
  }
  const out = { kind: "adds-text", chars: cap.extraChars, message: `${rel} -- thread adds ${cap.extraChars} chars` };
  if (!apply) return out;

  // Only the author's own continuation counts as the thread being captured:
  // drop the flag it was stamped with then, never for a link reply alone.
  const markers = {};
  if (cap.posts.some((p) => p.mine && p.id !== id)) {
    if (/^needs_thread:/m.test(fmRaw)) markers.needs_thread = null;
    if (/^last_error:\s*"?thread_not_captured"?\s*$/m.test(fmRaw)) {
      markers.last_error = null;
      if (/^enrichment_status:\s*"?partial"?\s*$/m.test(fmRaw)) markers.enrichment_status = "ok";
    }
  }
  const w = await writeEnrichment({
    clipPath, rel, text, baselineSha: sha256(text), fmRaw, body, markers,
    section: null, threadSection: section, resetTriage: false, statusGlyph: "v", statusMsg: "thread added",
  });
  if (w.glyph !== "v") return { kind: "write-failed", chars: 0, message: w.message };
  // Thread text is untrusted tweet text: flag-only re-screen, as body-fill does.
  const flag = rescreenInjection(clipPath);
  if (flag) {
    // Fail closed as body-fill does: if the flag cannot be written, put the
    // clip back as it was so the next run re-fetches and re-screens it.
    // (Except when the clip changed under us: see below.)
    const revert = (why) => {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { kind: "write-failed", chars: 0, message: `${rel} -- injection flag-write failed (${why}); reverted` };
    };
    const flagOnce = async () => {
      const t2 = readFileSync(clipPath, "utf-8");
      const p2 = parseFrontmatter(t2);
      if (!p2.present) return { glyph: "x", message: "no frontmatter on re-read" };
      return writeEnrichment({
        clipPath, rel, text: t2, baselineSha: sha256(t2), fmRaw: p2.fmRaw, body: p2.body,
        markers: { harvest_flag: "injection-suspect", harvest_flag_detail: flag.detail },
        section: null, resetTriage: false, statusGlyph: "v", statusMsg: "flagged",
      });
    };
    let fw = await flagOnce();
    // A stale-read refusal means someone else edited the clip meanwhile: flag
    // their version once more, and never overwrite it with the pre-thread copy.
    if (fw.glyph === "~") fw = await flagOnce();
    if (fw.glyph === "~") return { kind: "write-failed", chars: 0, message: `${rel} -- injection flag-write refused (${fw.message}); clip NOT reverted and NOT flagged, review it by hand` };
    if (fw.glyph !== "v") return revert(fw.message);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`fxt-enrich: vault not found: ${args.vault}`);
    process.exit(1);
  }
  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("fxt-enrich: 0 clips found.");
    process.exit(0);
  }

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;
  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    const res = await processClip(clip, args.vault, args.dryRun, { reflag: args.reflag, reenrichQuoteOnly: args.reenrichQuoteOnly });
    const prefix =
      res.glyph === "v" ? "OK  " :
      res.glyph === "o" ? "SKIP" :
      res.glyph === "~" ? "PART" :
      "FAIL";
    const target = res.glyph === "x" ? process.stderr : process.stdout;
    target.write(`${prefix} ${res.message}\n`);
    if (res.glyph === "v") { ok++; processed++; }
    else if (res.glyph === "~") { partial++; processed++; }
    else if (res.glyph === "x") { failed++; processed++; }
    else skipped++;
  }
  console.log(`\nfxt-enrich: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. (dry_run=${args.dryRun})`);
  process.exit(failed > 0 ? 3 : 0);
}

// Run unless imported as a module (tests import draftJsToMarkdown directly).
// import.meta.main is bun-only; fall back to argv[1] basename match for node.
const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("fxtwitter-enrich.mjs");

if (_isMain) {
  main().catch((e) => {
    console.error("fxt-enrich: fatal:", e);
    process.exit(1);
  });
}
