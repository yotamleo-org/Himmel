#!/usr/bin/env node
/**
 * feed-clip.mjs — release and blog feeds → Clippings/ inbox clips.
 *
 * Reads the vault's feed list, fetches each RSS, Atom or GitHub releases feed,
 * and writes one inbox clip per unseen entry. A feed clip has the shape of a
 * Telegram clip (same front matter, no harvested_at, no processed marker, lands
 * top-level in Clippings/) except `clipped_via: feed` and no telegram_* keys, so
 * /harvest-clips and /triage-clips treat it like any other clip. No model call.
 *
 * Feed list  <vault>/.feed-clip-feeds — one feed per line: `<url> [label]`,
 *   `#` starts a comment. The template ships a starter list.
 * Seen state <vault>/.feed-clip-seen.jsonl — one line per clipped entry
 *   ({feed, id, file, clipped}); an entry is clipped once. Append-only.
 *
 * Per run, at most --cap (default 3) new clips per feed, newest entry first; the
 * rest stay unseen and arrive on later runs. A feed that fails (HTTP error,
 * timeout, not a feed, walled host) is one `✗` line and never fails the run.
 *
 * Usage:
 *   node feed-clip.mjs [--vault <path>] [--feeds <file>] [--cap <n>] [--dry-run]
 *
 * Env: FEED_CLIP_TODAY (YYYY-MM-DD), FEED_CLIP_TIMEOUT_MS (default 20000),
 *   FEED_CLIP_MAX_BYTES (default 8 MiB per feed).
 *
 * Exit codes:
 *   0 — the run finished, whatever the feeds did (also: no feed list)
 *   1 — bad usage
 *   2 — env unusable (vault missing / not an Obsidian vault, unreadable seen
 *       file, a clip or seen-line write failed)
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, statSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { classifyMessage, slugify } from "./lib/telegram-clip.mjs";

const TODAY = process.env.FEED_CLIP_TODAY || new Date().toISOString().slice(0, 10);
const TIMEOUT_MS = Number(process.env.FEED_CLIP_TIMEOUT_MS) || 20000;
const MAX_BYTES = Number(process.env.FEED_CLIP_MAX_BYTES) || 8 * 1024 * 1024;
const DEFAULT_CAP = 3;
const MAX_REDIRECTS = 5;
const MAX_BODY_CHARS = 6000;
const MAX_HTML_CHARS = 200000;
const FEEDS_FILE = ".feed-clip-feeds";
const SEEN_FILE = ".feed-clip-seen.jsonl";
// Login-walled hosts (scripts/web/walled-hosts.conf): a plain fetch gets a wall,
// not a feed. They are fetched with scripts/web/fetch-url.sh, never here.
const WALLED_HOSTS = ["x.com", "twitter.com", "mobile.twitter.com", "instagram.com", "reddit.com", "redd.it"];

const USAGE = "Usage: node feed-clip.mjs [--vault <path>] [--feeds <file>] [--cap <n>] [--dry-run]";

function die(code, msg) {
  process.stderr.write(`feed-clip: ${msg}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const a = { dryRun: false, cap: DEFAULT_CAP };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined || v === "" || v.startsWith("--")) die(1, `${k} needs a value.\n${USAGE}`);
      return v;
    };
    switch (k) {
      case "-h": case "--help": a.help = true; break;
      case "--dry-run": a.dryRun = true; break;
      case "--vault": a.vault = value(); break;
      case "--feeds": a.feeds = value(); break;
      case "--cap": {
        const n = Number(value());
        if (!Number.isInteger(n) || n < 1) die(1, `--cap must be a whole number of at least 1.\n${USAGE}`);
        a.cap = n;
        break;
      }
      default: die(1, `unknown arg: ${k}\n${USAGE}`);
    }
  }
  return a;
}

function resolveVault(arg) {
  const candidate = arg || process.env.OBSIDIAN_VAULT_PATH || join(homedir(), "Documents", "luna");
  if (!existsSync(candidate) || !statSync(candidate).isDirectory()) {
    die(2, `vault path not found: ${candidate} (pass --vault or set OBSIDIAN_VAULT_PATH)`);
  }
  if (!existsSync(join(candidate, ".obsidian"))) {
    die(2, `not an Obsidian vault (no .obsidian/): ${candidate}`);
  }
  return resolve(candidate);
}

function parseFeedList(text, file) {
  const feeds = [];
  const problems = [];
  text.replace(/^﻿/, "").split(/\r?\n/).forEach((raw, i) => {
    const line = raw.replace(/(^|\s)#.*$/, "").trim();
    if (!line) return;
    const [url, ...label] = line.split(/\s+/);
    if (!/^(?:https?|file):\/\/\S+$/i.test(url)) {
      problems.push(`${file}:${i + 1}: not a feed URL, line skipped: ${line.slice(0, 60)}`);
      return;
    }
    feeds.push({ url, label: label.join(" ") });
  });
  return { feeds, problems };
}

const seenKey = (feed, id) => `${feed}\n${id}`;

function loadSeen(path) {
  const seen = new Set();
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return { seen, needsNewline: false };
    die(2, `cannot read ${path}: ${e.code || e.message}`);
  }
  for (const line of text.split("\n")) {
    if (!line) continue;
    try {
      const r = JSON.parse(line);
      if (r && r.feed && r.id) seen.add(seenKey(r.feed, r.id));
    } catch {
      /* a truncated line is not a record */
    }
  }
  return { seen, needsNewline: text !== "" && !text.endsWith("\n") };
}

const isWalled = (hostname) => {
  const host = hostname.toLowerCase().replace(/\.+$/, "");
  return WALLED_HOSTS.some((w) => host === w || host.endsWith(`.${w}`));
};

async function readCapped(res) {
  const chunks = [];
  let n = 0;
  for await (const c of res.body) {
    n += c.length;
    if (n > MAX_BYTES) throw new Error(`feed larger than ${MAX_BYTES} bytes`);
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function fetchFeed(url) {
  if (url.toLowerCase().startsWith("file://")) {
    const path = fileURLToPath(url);
    if (statSync(path).size > MAX_BYTES) throw new Error(`feed larger than ${MAX_BYTES} bytes`);
    return readFileSync(path, "utf8");
  }
  let u = new URL(url);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error(`unsupported scheme ${u.protocol}`);
    if (isWalled(u.hostname)) throw new Error(`walled host ${u.hostname} (fetch it with scripts/web/fetch-url.sh)`);
    const res = await fetch(u, {
      redirect: "manual",
      headers: { Accept: "application/atom+xml, application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5", "User-Agent": "feed-clip/1.0" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const loc = res.headers.get("location");
    if (res.status >= 300 && res.status < 400 && loc) {
      u = new URL(loc, u);
      continue;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await readCapped(res);
  }
  throw new Error("too many redirects");
}

function describeError(e) {
  if (e && e.name === "TimeoutError") return `timed out after ${TIMEOUT_MS} ms`;
  const cause = e && e.cause && (e.cause.code || e.cause.message);
  return String((cause && `${e.message} (${cause})`) || (e && e.message) || e).replace(/\s+/g, " ").slice(0, 200);
}

const NS = "(?:[\\w.-]+:)?";
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (m, e) => {
    const k = e.toLowerCase();
    if (k[0] !== "#") return ENTITIES[k];
    try {
      return String.fromCodePoint(k[1] === "x" ? parseInt(k.slice(2), 16) : parseInt(k.slice(1), 10));
    } catch {
      return m;
    }
  });
}

const TAG_MAX = 1000;

function xmlText(raw) {
  let out = "";
  let i = 0;
  for (;;) {
    const s = raw.indexOf("<![CDATA[", i);
    const e = s < 0 ? -1 : raw.indexOf("]]>", s + 9);
    if (e < 0) break;
    out += decodeEntities(raw.slice(i, s)) + raw.slice(s + 9, e);
    i = e + 3;
  }
  return out + decodeEntities(raw.slice(i));
}

function field(block, names) {
  for (const n of names) {
    const open = new RegExp(`<(${NS}${n})(?![\\w:.-])[^>]{0,${TAG_MAX}}(?<!/)>`, "g");
    let m;
    while ((m = open.exec(block))) {
      const end = block.indexOf(`</${m[1]}>`, open.lastIndex);
      if (end < 0) break;
      const t = xmlText(block.slice(open.lastIndex, end)).trim();
      if (t) return t;
    }
  }
  return "";
}

const attr = (tag, name) => {
  const m = tag.match(new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`));
  return m ? decodeEntities(m[1] ?? m[2]) : "";
};

function linkOf(block) {
  for (const m of block.matchAll(new RegExp(`<link(?![\\w:.-])([^>]{0,${TAG_MAX}}?)/?>`, "g"))) {
    const href = attr(m[1], "href");
    const rel = attr(m[1], "rel");
    if (href && (!rel || rel === "alternate")) return href;
  }
  return field(block, ["link"]);
}

function cleanLink(raw, base) {
  if (!raw.trim()) return ""; // an empty href would resolve to the feed URL itself
  try {
    const u = new URL(raw.trim(), base);
    return u.protocol === "http:" || u.protocol === "https:" ? u.href : "";
  } catch {
    return "";
  }
}

function htmlToText(html) {
  let out = "";
  let skip = "";
  const token = new RegExp(`<(/?)([a-z][a-z0-9]*)[^>]{0,${TAG_MAX}}>|<[!?][^>]{0,${TAG_MAX}}>|<|[^<]+`, "gi");
  for (const [tok, close, name] of html.slice(0, MAX_HTML_CHARS).matchAll(token)) {
    const n = name && name.toLowerCase();
    if (skip) {
      if (close && n === skip) skip = "";
    } else if (!n) {
      if (!/^<[!?]/.test(tok)) out += tok;
    } else if (!close && (n === "script" || n === "style")) {
      skip = n;
    } else if (n === "br") {
      out += "\n";
    } else if (!close && n === "li") {
      out += "\n- ";
    } else if (close && /^(?:p|div|h[1-6]|ul|ol|pre|blockquote|tr)$/.test(n)) {
      out += "\n\n";
    }
  }
  return decodeEntities(out)
    .split("\n")
    .map((l) => l.trimEnd())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\n\n(?=- )/g, "\n")
    .trim();
}

const isControl = (c) => (c < 32 && c !== 9 && c !== 10 && c !== 13) || c === 127;
const stripControls = (s) => Array.from(s).filter((ch) => !isControl(ch.charCodeAt(0))).join("");
const oneLine = (s) => stripControls(s).replace(/\s+/g, " ").trim();

function parseFeed(xml, feedUrl) {
  if (!/<(?:rss|feed|rdf:RDF)(?![\w:.-])/i.test(xml)) throw new Error("not a feed (no rss, atom or rdf root element)");
  const blocks = [];
  let head = xml;
  const open = new RegExp(`<(entry|item)(?![\\w:.-])[^>]{0,${TAG_MAX}}>`, "g");
  for (let m; (m = open.exec(xml)); ) {
    if (blocks.length === 0) head = xml.slice(0, m.index);
    const end = xml.indexOf(`</${m[1]}>`, open.lastIndex);
    if (end < 0) break;
    blocks.push(xml.slice(open.lastIndex, end));
    open.lastIndex = end;
  }
  const channel = oneLine(field(head, ["title"]));
  const entries = [];
  let skipped = 0;
  for (const b of blocks) {
    const link = cleanLink(linkOf(b), feedUrl);
    if (!link) {
      skipped++;
      continue;
    }
    entries.push({
      id: field(b, ["id", "guid"]) || link,
      title: oneLine(field(b, ["title"])),
      link,
      ts: Date.parse(field(b, ["published", "updated", "pubDate", "date"])) || 0,
      body: htmlToText(field(b, ["encoded", "content", "summary", "description"])),
    });
  }
  return { channel, entries, skipped };
}

function yamlQuote(s) {
  return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\n\t]+/g, " ") + '"';
}

function clipTitle(label, entry) {
  const t = entry.title || new URL(entry.link).host + new URL(entry.link).pathname.replace(/\/+$/, "");
  const full = label && !t.toLowerCase().includes(label.toLowerCase()) ? `${label}: ${t}` : t;
  return full.length > 80 ? full.slice(0, 80).trim() : full;
}

function clipBody(entry) {
  const b = stripControls(entry.body);
  if (!b) return entry.link;
  return b.length > MAX_BODY_CHARS ? `${b.slice(0, MAX_BODY_CHARS).trimEnd()}…` : b;
}

function buildClip({ title, source, type, body }) {
  const fm = [
    "---",
    `title: ${yamlQuote(title)}`,
    `source: ${source}`,
    `date_clipped: ${TODAY}`,
    `type: ${type}`,
    "tags: []",
    "status: unread",
    "clipped_via: feed",
    "---",
  ];
  return [fm.join("\n"), "", `# ${title}`, "", body, "", "## Source", `[${source}](${source})`, ""].join("\n");
}

const clipFilename = (feed, id, title) =>
  `feed-${createHash("sha1").update(seenKey(feed, id)).digest("hex").slice(0, 10)}-${slugify(title)}.md`;

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(USAGE + "\n");
    process.exit(0);
  }
  const vault = resolveVault(args.vault);
  const clippings = join(vault, "Clippings");
  const listPath = args.feeds ? resolve(args.feeds) : join(vault, FEEDS_FILE);
  const seenPath = join(vault, SEEN_FILE);

  let listText;
  try {
    listText = readFileSync(listPath, "utf8");
  } catch (e) {
    if (e.code !== "ENOENT") die(2, `cannot read ${listPath}: ${e.code || e.message}`);
    process.stdout.write(`⊘ feed-clip: no feed list at ${listPath}: nothing to do (the vault template ships a starter ${FEEDS_FILE})\n`);
    process.exit(0);
  }
  const { feeds, problems } = parseFeedList(listText, listPath);
  for (const p of problems) process.stdout.write(`✗ feed-clip: ${p}\n`);

  const { seen, needsNewline } = loadSeen(seenPath);
  let prefix = needsNewline ? "\n" : "";
  let clipped = 0;
  let pendingTotal = 0;
  let failed = problems.length;

  for (const feed of feeds) {
    let label = feed.label || feed.url;
    let parsed;
    try {
      parsed = parseFeed(await fetchFeed(feed.url), feed.url);
    } catch (e) {
      failed++;
      process.stdout.write(`✗ feed-clip: ${label} — failed: ${describeError(e)}\n`);
      continue;
    }
    label = feed.label || parsed.channel || feed.url;

    const ids = new Set();
    const fresh = parsed.entries
      .filter((e) => !seen.has(seenKey(feed.url, e.id)) && !ids.has(e.id) && ids.add(e.id))
      .sort((a, b) => b.ts - a.ts);
    const take = fresh.slice(0, args.cap);
    const pending = fresh.length - take.length;
    pendingTotal += pending;

    for (const entry of take) {
      const title = clipTitle(label, entry);
      const { type } = classifyMessage({ text: entry.link });
      if (args.dryRun) {
        process.stdout.write(`  would clip: ${title} → ${entry.link} (type=${type})\n`);
        clipped++;
        continue;
      }
      const fname = clipFilename(feed.url, entry.id, title);
      const clip = buildClip({ title, source: entry.link, type, body: clipBody(entry) });
      let wrote = true;
      try {
        mkdirSync(clippings, { recursive: true });
        writeFileSync(join(clippings, fname), clip, { encoding: "utf8", flag: "wx" });
      } catch (e) {
        if (e.code !== "EEXIST") die(2, `failed to write Clippings/${fname}: ${e.code || e.message}`);
        wrote = false;
      }
      try {
        appendFileSync(seenPath, `${prefix}${JSON.stringify({ feed: feed.url, id: entry.id, file: fname, clipped: TODAY })}\n`);
        prefix = "";
      } catch (e) {
        die(2, `failed to record ${fname} in ${seenPath}: ${e.code || e.message}`);
      }
      seen.add(seenKey(feed.url, entry.id));
      if (wrote) {
        clipped++;
        process.stdout.write(`  + Clippings/${fname} (type=${type})\n`);
      } else {
        process.stdout.write(`  ⊘ Clippings/${fname} already exists, recorded as seen\n`);
      }
    }

    const done = args.dryRun ? "to clip" : "clipped";
    if (take.length === 0) process.stdout.write(`⊘ feed-clip: ${label} — nothing new\n`);
    else process.stdout.write(`✓ feed-clip: ${label} — ${take.length} ${done}, ${pending} pending (cap ${args.cap})\n`);
  }

  const ok = feeds.length - (failed - problems.length);
  process.stdout.write(
    `feed-clip: ${args.dryRun ? "dry-run, " : ""}${clipped} ${args.dryRun ? "to clip" : "clipped"}, ${pendingTotal} pending, ${failed} failed, ${ok} of ${feeds.length} feeds read\n`,
  );
  process.exit(0);
}

main().catch((e) => {
  process.stderr.write(`feed-clip: fatal: ${e && e.message ? e.message : e}\n`);
  process.exit(2);
});
