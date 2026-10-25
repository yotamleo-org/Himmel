#!/usr/bin/env node
/**
 * playwright-crawl-youtube.mjs — batch enrich YouTube clips (transcript-only MVP).
 *
 * For every clip in <vault>/Clippings/ with:
 *   - harvest_skill: clip-body
 *   - source: youtube.com/watch?v=<id> or youtu.be/<id>
 *   - no existing crawled_at: marker
 *
 * navigate to the video, scrape metadata + transcript + top comments, fold
 * a "## Crawled content" section into the clip body BEFORE "## Source" (or
 * "## Comments" if no Source).
 *
 * Primary path (HIMMEL-4677): tools/yt-scrapling-meta.py, NO cookie: metadata +
 * description from the watch page via Scrapling, the transcript from yt-dlp
 * subtitles (json3). It runs under the scrapling venv python
 * (~/.himmel/scrapling-venv, tools/requirements-scrapling.txt; override
 * YT_SCRAPLING_PYTHON) and honours the HIMMEL-4361 `local-headless` route. The
 * Scrapling path is the only path (HIMMEL-4709 removed the logged-in Playwright
 * cookie fallback).
 *
 * Scope (MVP): TRANSCRIPT ONLY. No video download, no STT, no keyframes.
 * If transcript unavailable (no auto-CC, age-gated, etc.): mark partial,
 * skip the transcript block, still capture metadata + comments.
 *
 * G-3 + idempotency + YAML parse-validate: same contract as crawl-x.
 *
 * Usage:
 *   bun playwright-crawl-youtube.mjs --vault <path> [--limit N] [--dry-run]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *   2 — the scrapling venv is not present
 *
 * LUNA-27.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, relative, sep } from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const TODAY = new Date().toISOString().slice(0, 10);
const NOW_ISO = new Date().toISOString();
const SLEEP_MIN_MS = 3000;
const SLEEP_MAX_MS = 5000;
const SCRAPLING_TIMEOUT_MS = 300000;
const SCRAPLING_HELPER = fileURLToPath(new URL("./yt-scrapling-meta.py", import.meta.url));

function usage(code = 1) {
  console.error("Usage: playwright-crawl-youtube.mjs --vault <path> [--limit N] [--dry-run]");
  console.error("");
  console.error("Pre-req: the scrapling venv ~/.himmel/scrapling-venv (tools/requirements-scrapling.txt) + yt-dlp.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  return out;
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function jitterSleep() {
  const ms = SLEEP_MIN_MS + Math.floor(Math.random() * (SLEEP_MAX_MS - SLEEP_MIN_MS));
  return sleep(ms);
}
function sha256(s) { return createHash("sha256").update(s).digest("hex"); }

function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`crawl-youtube: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  const entries = readdirSync(root, { withFileTypes: true });
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) {
            out.push(join(sub, s.name));
          }
        }
      } catch { /* skip */ }
    }
  }
  return out.sort();
}

function parseFrontmatter(text) {
  // CRLF → LF normalisation: see crawl-x.mjs parseFrontmatter docs. Without
  // this, Windows-edited clips skip silently as 'no closing ---'.
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

function alreadyCrawled(fmRaw) {
  return /^crawled_at:\s*\S/m.test(fmRaw);
}

function isYouTubeSource(sourceVal) {
  if (!sourceVal) return false;
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  return /^https?:\/\/(www\.|m\.)?(youtube\.com\/watch\?v=|youtu\.be\/)/.test(s);
}

function canonicalYouTubeUrl(sourceVal) {
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  let m = s.match(/^https?:\/\/(?:www\.|m\.)?youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/);
  if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
  m = s.match(/^https?:\/\/(?:www\.)?youtu\.be\/([A-Za-z0-9_-]{6,})/);
  if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
  return null;
}

function videoIdOf(url) {
  const m = url.match(/[?&]v=([A-Za-z0-9_-]{6,})/);
  return m ? m[1] : null;
}

function scraplingPython() {
  const override = (process.env.YT_SCRAPLING_PYTHON || "").trim();
  if (override) return override;
  const py = join(homedir(), ".himmel", "scrapling-venv", "bin", "python");
  return existsSync(py) ? py : null;
}

/**
 * Primary path (HIMMEL-4677): yt-scrapling-meta.py, cookieless. Returns the
 * scrape result shape (ok, partial, title, channel, duration, infoLine, transcript, comments) plus `via`, or { ok: false, error } with `final` (a
 * removed video: no fallback may run) or `skipped` (the route denied the slot).
 */
function scrapeViaScrapling(py, url, vault) {
  const id = videoIdOf(url);
  if (!id) return { ok: false, partial: false, error: "no_video_id" };
  const got = spawnSync(py, [SCRAPLING_HELPER, "--video-id", id, "--vault", vault],
    { encoding: "utf-8", timeout: SCRAPLING_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 });
  if (got.error) return { ok: false, partial: false, error: `scrapling_unavailable: ${got.error.code || got.error.message}` };
  let out;
  try {
    out = JSON.parse(got.stdout);
  } catch {
    return { ok: false, partial: false, error: `scrapling_error: unparseable output (rc=${got.status})` };
  }
  if (out.status === "removed") return { ok: false, partial: false, final: true, error: `removed: ${out.detail || ""}`.trim() };
  if (out.status === "skipped") return { ok: false, partial: false, skipped: true, error: "scrapling_route_skipped" };
  if (out.status !== "ok") return { ok: false, partial: false, error: `${out.status || "scrapling_error"}: ${out.detail || ""}`.trim() };
  const transcript = out.transcript && out.transcript.length > 0 ? out.transcript : null;
  return {
    ok: true,
    partial: transcript === null,
    error: transcript === null ? (out.transcript_error || "transcript_empty") : null,
    via: "scrapling",
    title: out.title,
    channel: out.channel,
    duration: out.duration,
    infoLine: [out.views ? `${out.views} views` : "", out.published ? `published ${out.published}` : ""].filter(Boolean).join(" · "),
    description: out.description || "",
    transcript,
    comments: [],
  };
}

function formatYamlValue(v) {
  if (typeof v !== "string") return String(v);
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]/.test(v)) {
    return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return v;
}

function upsertCrawlMarkers(fmRaw, markers) {
  const orderedKeys = ["crawled_at", "crawl_skill", "crawl_status", "last_error"];
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of orderedKeys) {
      const re = new RegExp(`^${k}:`);
      if (re.test(line)) {
        seen.add(k);
        if (markers[k] === undefined || markers[k] === null) return null;
        return `${k}: ${formatYamlValue(markers[k])}`;
      }
    }
    return line;
  }).filter((l) => l !== null);

  let insertIdx = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) {
      insertIdx = i + 1;
      break;
    }
  }
  const toInsert = [];
  for (const k of orderedKeys) {
    if (seen.has(k)) continue;
    if (markers[k] === undefined || markers[k] === null) continue;
    toInsert.push(`${k}: ${formatYamlValue(markers[k])}`);
  }
  return [...lines.slice(0, insertIdx), ...toInsert, ...lines.slice(insertIdx)].join("\n");
}

function insertCrawledSection(body, sectionMarkdown) {
  const sourceMatch = body.match(/^## Source\b/m);
  const commentsMatch = body.match(/^## Comments\b/m);
  let insertAt;
  if (sourceMatch) insertAt = sourceMatch.index;
  else if (commentsMatch) insertAt = commentsMatch.index;
  else {
    const sep = body.endsWith("\n") ? "" : "\n";
    return body + sep + "\n" + sectionMarkdown + "\n";
  }
  const before = body.slice(0, insertAt);
  const after = body.slice(insertAt);
  const trailingNewlines = before.match(/\n*$/)[0].length;
  let prefix = before;
  if (trailingNewlines < 2) {
    prefix = before.replace(/\n*$/, "") + "\n\n";
  }
  return prefix + sectionMarkdown + "\n\n" + after;
}

function renderCrawledSection(data) {
  const lines = [
    "## Crawled content",
    `<!-- crawled ${TODAY} via scrapling-youtube (metadata) + yt-dlp (transcript) -->`,
    "",
    "### Metadata",
    "",
    `- Title: ${data.title || "_unknown_"}`,
    `- Channel: ${data.channel || "_unknown_"}`,
    `- Duration: ${data.duration || "_unknown_"}`,
    `- Info: ${data.infoLine || "_unknown_"}`,
    "",
  ];
  if (data.description) {
    lines.push("### Description", "", data.description.trim(), "");
  }
  lines.push("### Transcript", "");
  if (data.transcript && data.transcript.length > 0) {
    for (const seg of data.transcript) {
      lines.push(`[${seg.ts}] ${seg.tx}`, "");
    }
  } else {
    lines.push("_Transcript unavailable._", "");
  }
  lines.push("### Top comments", "");
  if (data.comments && data.comments.length > 0) {
    for (const c of data.comments) {
      const escapedText = c.text.replace(/\n+/g, " ").replace(/"/g, "'").slice(0, 500);
      lines.push(`- **${c.author}** — "${escapedText}"`);
    }
  } else {
    lines.push("_No comments captured._");
  }
  return lines.join("\n");
}

async function processClip(crawler, clipPath, vault, dryRun) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try {
    text = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` };
  }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { glyph: "o", message: `${rel} -- skipped (frontmatter): no closing ---` };
  if (fm.harvest_skill !== "clip-body") return { glyph: "o", message: `${rel} -- skipped (not clip-body harvest)` };
  if (alreadyCrawled(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (already-crawled)` };

  const sourceVal = fm.source || "";
  if (!isYouTubeSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not youtube source)` };
  const url = canonicalYouTubeUrl(fm.harvest_url_canonical || sourceVal) || canonicalYouTubeUrl(sourceVal);
  if (!url) return { glyph: "x", message: `${rel} -- failed (canonicalize): ${sourceVal}` };

  if (dryRun) return { glyph: "v", message: `${rel} -- would crawl ${url} [dry-run]` };

  await jitterSleep();

  const scrape = scrapeViaScrapling(crawler.py, url, vault);
  if (!scrape.ok && !scrape.final) {
    // Leave the clip unmarked so a later run retries it.
    if (scrape.skipped) return { glyph: "o", message: `${rel} -- skipped (scrapling route denied)` };
    return { glyph: "x", message: `${rel} -- failed (retryable, not marked): ${scrape.error}` };
  }
  let status, lastError, section;
  if (scrape.ok && !scrape.partial) {
    status = "ok";
    lastError = null;
    section = renderCrawledSection(scrape);
  } else if (scrape.ok && scrape.partial) {
    status = "partial";
    lastError = scrape.error || "transcript_unavailable";
    section = renderCrawledSection(scrape);
  } else {
    status = "failed";
    lastError = scrape.error || "scrape_failed";
    section = null;
  }

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
  if (section) newBody = insertCrawledSection(body, section);

  const markers = {
    crawled_at: NOW_ISO,
    crawl_skill: "scrapling-youtube",
    crawl_status: status,
    last_error: lastError,
  };
  const newFm = upsertCrawlMarkers(fmRaw, markers);
  const newText = `---\n${newFm}\n---\n${newBody}`;

  try {
    writeFileSync(clipPath, newText, { encoding: "utf-8" });
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (write): ${e.message}` };
  }

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
    return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted): no closing ---` };
  }
  if (post.body !== newBody) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  if (section) {
    const stripped = post.body.replace(section, "").replace(/\n{3,}/g, "\n\n");
    const origNorm = body.replace(/\n{3,}/g, "\n\n");
    if (!stripped.includes(origNorm.trim().slice(0, 200))) {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { glyph: "x", message: `${rel} -- failed (G-3 single-section-add; reverted)` };
    }
  } else if (post.body !== body) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body changed without section; reverted)` };
  }
  try {
    const yaml = await import("js-yaml");
    yaml.load(post.fmRaw);
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (frontmatter-yaml; reverted): ${e.message}` };
  }

  if (status === "ok") return { glyph: "v", message: `${rel} -- crawled ok` };
  if (status === "partial") return { glyph: "~", message: `${rel} -- partial: ${lastError}` };
  return { glyph: "x", message: `${rel} -- failed: ${lastError}` };
}

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`crawl-youtube: vault not found: ${args.vault}`);
    process.exit(1);
  }
  const py = scraplingPython();
  if (!py) {
    console.error("crawl-youtube: install the Scrapling path: " +
      "~/.himmel/scrapling-venv per tools/requirements-scrapling.txt, plus yt-dlp on PATH.");
    process.exit(2);
  }

  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("crawl-youtube: 0 clips found.");
    process.exit(0);
  }

  const crawler = { py };

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;

  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    const { glyph, message } = await processClip(crawler, clip, args.vault, args.dryRun);
    const prefix =
      glyph === "v" ? "OK  " :
      glyph === "o" ? "SKIP" :
      glyph === "~" ? "PART" :
      "FAIL";
    const target = glyph === "x" ? process.stderr : process.stdout;
    target.write(`${prefix} ${message}\n`);
    if (glyph === "v") { ok++; processed++; }
    else if (glyph === "~") { partial++; processed++; }
    else if (glyph === "x") { failed++; processed++; }
    else skipped++;
  }

  console.log(
    `\ncrawl-youtube: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. ` +
    `(dry_run=${args.dryRun})`
  );
  process.exit(0);
}

main().catch((e) => {
  console.error("crawl-youtube: fatal:", e);
  process.exit(1);
});
