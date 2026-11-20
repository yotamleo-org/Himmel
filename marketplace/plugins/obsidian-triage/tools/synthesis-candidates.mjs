#!/usr/bin/env node
/**
 * synthesis-candidates.mjs - the read-only, deterministic candidate list
 * /synthesize-clips starts from (same vault + same --today => same bytes).
 *
 *   node synthesis-candidates.mjs [vault] [--today YYYY-MM-DD] [--since YYYY-MM-DD]
 *                                 [--format lines|json]
 *
 * Lists every concept, author, tag and folder candidate as PASS or a named skip;
 * the substantive-content gate stays with the agent. Exit: 0 ok | 2 harvest gate
 * (no <vault>/.harvest.done) | 1 usage. Rules, skip reasons and output: README.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { canonicalize } from "./lib/url-canonical.mjs";
import { frontmatterBounds, fmScalar, fmList, splitLines, stripCR } from "./lib/frontmatter.mjs";

const KINDS = ["concept", "author", "tag", "folder"];
const MIN_CLIPS = { concept: 3, author: 2, tag: 5, folder: 5 };
const MIN_SOURCES = { concept: 3, tag: 2, folder: 2 };
const DEDUP_DAYS = 14;
const EVIDENCE_CAP = 40;
const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_DEPTH = 3;

const PLATFORM_DOMAINS = new Set([
  "x.com", "youtube.com", "reddit.com", "instagram.com", "tiktok.com",
  "linkedin.com", "github.com", "medium.com", "substack.com", "threads.net",
  "bsky.app", "facebook.com",
]);

const STRUCTURAL_TAGS = new Set([
  "clippings", "clip", "web-clipper", "synthesis",
  "x", "twitter", "tweet", "github", "instagram", "youtube", "reddit",
  "medium", "substack", "tiktok", "linkedin",
  "article", "research", "newsletter",
]);

const SELF = path.basename(new URL(import.meta.url).pathname);
function die(code, msg) { process.stderr.write(`${SELF}: ${msg}\n`); process.exit(code); }
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

function localToday() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function parseArgs(argv) {
  const a = { vault: null, today: null, since: null, format: "lines" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--today") a.today = argv[++i];
    else if (t === "--since") a.since = argv[++i];
    else if (t === "--format") a.format = argv[++i];
    else if (t.startsWith("--")) die(1, `unknown flag ${t}`);
    else if (a.vault === null) a.vault = t;
    else die(1, `unexpected argument ${t}`);
  }
  const isDate = (s) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s || "")) return false;
    const d = new Date(`${s}T00:00:00Z`);
    return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
  };
  if (!["lines", "json"].includes(a.format)) die(1, `--format must be lines or json`);
  if (a.today !== null && !isDate(a.today)) die(1, "--today needs YYYY-MM-DD");
  if (a.since !== null && !isDate(a.since)) die(1, "--since needs YYYY-MM-DD");
  a.today = a.today || localToday();
  a.vault = a.vault || process.env.OBSIDIAN_VAULT_PATH || path.join(os.homedir(), "Documents", "luna");
  return a;
}

function norm(s) {
  return String(s).normalize("NFKC").toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "");
}

function cleanName(raw) {
  let s = String(raw || "").trim();
  const wiki = s.match(/^\[\[([^\]|]+)(?:\|[^\]]*)?\]\]$/);
  if (wiki) s = wiki[1];
  return s.replace(/^@+/, "").trim();
}

function domainOf(rawUrl) {
  const c = canonicalize(rawUrl);
  if (!c) return "";
  try { return new URL(c).hostname.toLowerCase().replace(/^www\./, ""); } catch { return ""; }
}

function authorFromUrl(rawUrl) {
  const c = canonicalize(rawUrl);
  if (!c) return "";
  let u;
  try { u = new URL(c); } catch { return ""; }
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  const first = u.pathname.split("/").filter(Boolean)[0] || "";
  if (host === "x.com") return /^(i|home|search|intent|hashtag|share)$/i.test(first) ? "" : first;
  if (host === "github.com") return first;
  return "";
}

function whenOf(s) {
  const t = String(s || "").trim().replace(" ", "T");
  if (!/^\d{4}-\d{2}-\d{2}/.test(t)) return NaN;
  if (t.length === 10) return Date.parse(`${t}T00:00:00Z`);
  return Date.parse(/(Z|[+-]\d{2}(:?\d{2})?)$/i.test(t) ? t : `${t}Z`);
}

function walk(dir, depth, out) {
  const ents = fs.readdirSync(dir, { withFileTypes: true }).sort((x, y) => cmp(x.name, y.name));
  for (const e of ents) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === "_synthesis" || e.name === "_done") continue;
      if (depth + 1 < MAX_DEPTH) walk(abs, depth + 1, out);
    } else if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
      out.push(abs);
    }
  }
}

function sectionTarget(lines) {
  let inSec = false;
  let has = false;
  for (const raw of lines) {
    const l = stripCR(raw);
    if (/^##\s+Promotion candidate\s*$/.test(l)) { inSec = true; has = true; continue; }
    if (inSec && /^##\s/.test(l)) break;
    if (!inSec) continue;
    const m = l.match(/Suggested target:\*{0,2}\s*(?:`([^`]+)`|(\S+))/);
    if (m) return { has, target: (m[1] || m[2] || "").trim() };
  }
  return { has, target: "" };
}

/** -> { skip: true } | { excluded: reason } | { clip } */
function readClip(vault, abs, since) {
  const rel = path.relative(vault, abs).split(path.sep).join("/");
  let content = fs.readFileSync(abs, "utf8");
  if (content.charCodeAt(0) === 0xfeff) content = content.slice(1);
  const lines = splitLines(content);
  if (stripCR(lines[0] || "") !== "---") return { skip: true };
  const b = frontmatterBounds(lines);
  if (!b) {
    const claimsProcessed = lines.slice(0, 200).some((l) => /^processed:\s*true\s*$/.test(stripCR(l)));
    return claimsProcessed
      ? { rel, excluded: "frontmatter parse error: opening --- has no closing ---" }
      : { skip: true };
  }
  if (fmScalar(lines, b.close, "processed") !== "true") return { skip: true };
  for (let i = 1; i < b.close; i++) {
    const l = stripCR(lines[i]);
    if (l === "" || /^[\s#-]/.test(l) || /^[^\s:#][^:]*:(\s|$)/.test(l)) continue;
    return { rel, excluded: `frontmatter parse error: line ${i + 1} is not a "key: value" entry` };
  }
  const triaged = fmScalar(lines, b.close, "triaged_at");
  if (since && !(triaged.slice(0, 10) >= since)) return { skip: true };

  const source = fmScalar(lines, b.close, "source") || fmScalar(lines, b.close, "harvest_url_canonical");
  const domain = domainOf(source);
  const authorRaw = fmList(lines, b.close, "author")[0] || fmScalar(lines, b.close, "author")
    || fmList(lines, b.close, "authors")[0] || "";
  const authorLabel = cleanName(authorRaw) || authorFromUrl(source);
  const tags = [...new Set(fmList(lines, b.close, "tags").map(norm).filter((t) => t && !STRUCTURAL_TAGS.has(t)))];
  const promo = sectionTarget(lines.slice(b.close + 1));
  const landed = whenOf(fmScalar(lines, b.close, "date_clipped") || triaged);
  return {
    clip: {
      rel,
      link: rel.replace(/\.md$/, ""),
      domain,
      authorKey: norm(authorLabel),
      authorLabel,
      urlKey: fmScalar(lines, b.close, "canonical_url") || source || rel,
      tags,
      landed,
      landedText: (fmScalar(lines, b.close, "date_clipped") || triaged).slice(0, 10),
      hasPromo: promo.has,
      target: promo.target,
    },
  };
}

function indexDir(vault, relDir, stripMoc) {
  const m = new Map();
  const dir = path.join(vault, relDir);
  if (!fs.existsSync(dir)) return m;
  const ents = fs.readdirSync(dir, { withFileTypes: true }).sort((x, y) => cmp(x.name, y.name));
  for (const e of ents) {
    if (!e.isFile() || !e.name.endsWith(".md")) continue;
    const rel = `${relDir}/${e.name}`;
    let base = e.name.replace(/\.md$/, "");
    if (stripMoc) base = base.replace(/[-\s]?moc$/i, "");
    const keys = new Set([norm(cleanName(base))]);
    const lines = splitLines(fs.readFileSync(path.join(dir, e.name), "utf8"));
    const b = frontmatterBounds(lines);
    if (b) for (const al of fmList(lines, b.close, "aliases")) keys.add(norm(cleanName(al)));
    for (const k of keys) if (k && !m.has(k)) m.set(k, rel);
  }
  return m;
}

function synthesisPages(vault) {
  const bySlug = new Map();
  const dir = path.join(vault, "Clippings", "_synthesis");
  if (!fs.existsSync(dir)) return bySlug;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const m = e.isFile() && e.name.match(/^(\d{4}-\d{2}-\d{2})-(.+)\.md$/);
    if (!m) continue;
    const text = fs.readFileSync(path.join(dir, e.name), "utf8");
    const evidence = splitLines(text).filter((l) => /^\s*[-*]\s*\[\[Clippings\//.test(l)).length;
    if (!bySlug.has(m[2])) bySlug.set(m[2], []);
    bySlug.get(m[2]).push({ date: m[1], file: e.name, evidence });
  }
  for (const list of bySlug.values()) list.sort((x, y) => cmp(y.file, x.file));
  return bySlug;
}

function substanceSkips(vault) {
  const bySlug = new Map();
  const file = path.join(vault, "Clippings", "_synthesis", ".substance-skips.tsv");
  if (!fs.existsSync(file)) return bySlug;
  for (const line of splitLines(fs.readFileSync(file, "utf8"))) {
    const [date, slug, n] = stripCR(line).split("\t");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date || "") || !slug || !/^\d+$/.test(n || "")) continue;
    const prev = bySlug.get(slug);
    if (!prev || date >= prev.date) bySlug.set(slug, { date, evidence: Number(n) });
  }
  return bySlug;
}

const ageDays = (today, date) => Math.round((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${date}T00:00:00Z`)) / DAY_MS);

function groupBy(clips, keysOf) {
  const g = new Map();
  for (const c of clips) {
    for (const k of keysOf(c)) {
      if (!g.has(k)) g.set(k, []);
      g.get(k).push(c);
    }
  }
  return g;
}

function folderOf(c) {
  const t = c.target.replace(/^\.?\//, "").replace(/\/+$/, "");
  if (!t || /\.md$/i.test(t) || t.split("/").includes("..")) return [];
  return [t];
}

const SLUG = {
  concept: (k) => `concept-${norm(k)}`,
  author: (k) => `author-${norm(k)}`,
  tag: (k) => `tag-${norm(k)}-moc`,
  folder: (k) => `folder-${norm(k)}`,
};

function sourceKey(kind, c) {
  if (kind === "folder" || !PLATFORM_DOMAINS.has(c.domain)) return c.domain || "(no-source)";
  return `${c.domain}|${c.authorKey || "(unknown)"}`;
}

function evaluate(kind, key, clips, ctx) {
  const sorted = [...clips].sort((x, y) => {
    const dx = Number.isNaN(x.landed) ? -Infinity : x.landed;
    const dy = Number.isNaN(y.landed) ? -Infinity : y.landed;
    return dy - dx || cmp(x.rel, y.rel);
  });
  const slug = SLUG[kind](key);
  const sources = new Set(sorted.map((c) => sourceKey(kind, c)));
  const listed = sorted.slice(0, EVIDENCE_CAP);
  const cand = {
    kind, slug, key,
    clipCount: sorted.length,
    evidenceCount: listed.length,
    uniqueUrls: new Set(listed.map((c) => c.urlKey)).size,
    distinctSources: sources.size,
    evidence: listed.map((c) => c.link),
  };
  const skip = (category, reason, detail) => ({ ...cand, status: "skip", category, reason, detail });

  const existing = ctx.existing[kind](key);
  if (existing) return skip("dedup", "existing-vault-page", `vault page ${existing} already covers this pattern`);

  if (kind !== "author" && sources.size < MIN_SOURCES[kind]) {
    if (sources.size >= 2) {
      return skip("confidence-floor", "too-few-sources",
        `${sorted.length} evidence clips come from ${sources.size} distinct sources; a ${kind} group needs at least ${MIN_SOURCES[kind]}`);
    }
    const domains = new Set(sorted.map((c) => c.domain));
    const d = [...domains][0] || "(no source)";
    if (domains.size === 1 && kind !== "folder" && PLATFORM_DOMAINS.has(d)) {
      const who = sorted[0].authorLabel ? `${sorted[0].authorLabel}` : "unknown authors";
      return skip("confidence-floor", "single-author-on-platform",
        `all ${sorted.length} evidence clips are by one author (${who}) on ${d}; one author is one source`);
    }
    return skip("confidence-floor", "single-source-domain", `all ${sorted.length} evidence clips share source domain ${d}`);
  }
  const dated = sorted.filter((c) => !Number.isNaN(c.landed));
  if (dated.length < 2) {
    return skip("confidence-floor", "undated-evidence",
      `${dated.length} of ${sorted.length} evidence clips carry a parseable date; the 24-hour floor cannot be shown`);
  }
  if (dated[0].landed - dated[dated.length - 1].landed < DAY_MS) {
    return skip("confidence-floor", "single-24h-window",
      `all ${dated.length} dated evidence clips landed within 24 hours (${dated[dated.length - 1].landedText} to ${dated[0].landedText})`);
  }

  const prior = (ctx.pages.get(slug) || [])[0];
  if (prior) {
    if (ageDays(ctx.today, prior.date) <= DEDUP_DAYS) {
      return skip("dedup", "synthesis-page-within-14d", `existing synthesis page ${prior.file} within 14d window`);
    }
    if (listed.length <= prior.evidence) {
      return skip("dedup", "no-new-evidence",
        `existing synthesis page ${prior.file} lists ${prior.evidence} clips and the evidence has not grown`);
    }
  }
  const failed = ctx.substanceSkips.get(slug);
  if (failed && ageDays(ctx.today, failed.date) <= DEDUP_DAYS && listed.length <= failed.evidence) {
    return skip("dedup", "substance-floor-recorded",
      `substance gate failed on ${failed.date} with ${failed.evidence} evidence clips; not re-examined within 14d unless the evidence grows`);
  }
  return { ...cand, status: "pass", supersedes: prior ? prior.file : null };
}

function mostCommon(values) {
  const n = new Map();
  for (const v of values) if (v) n.set(v, (n.get(v) || 0) + 1);
  return [...n].sort((x, y) => y[1] - x[1] || cmp(x[0], y[0]))[0]?.[0] || "";
}

function build(args) {
  const vault = args.vault;
  if (!fs.existsSync(path.join(vault, "Clippings"))) return { noClippings: true };
  if (!fs.existsSync(path.join(vault, ".harvest.done"))) {
    return { gate: `synthesize-clips: upstream harvest incomplete — ${vault}/.harvest.done not found; run /harvest-clips first.` };
  }

  const files = [];
  walk(path.join(vault, "Clippings"), 0, files);
  const clips = [];
  const inputsExcluded = [];
  for (const abs of files) {
    const r = readClip(vault, abs, args.since);
    if (r.clip) clips.push(r.clip);
    else if (r.excluded) inputsExcluded.push({ path: r.rel, reason: r.excluded });
  }
  clips.sort((x, y) => cmp(x.rel, y.rel));
  inputsExcluded.sort((x, y) => cmp(x.path, y.path));

  const concepts = indexDir(vault, "30-Resources/Concepts", false);
  const people = indexDir(vault, "20-Areas", false);
  const maps = indexDir(vault, "60-Maps", true);
  const ctx = {
    today: args.today,
    pages: synthesisPages(vault),
    substanceSkips: substanceSkips(vault),
    existing: {
      concept: (k) => concepts.get(norm(k)) || maps.get(norm(k)) || "",
      author: (k) => people.get(norm(k)) || "",
      tag: (k) => maps.get(norm(k)) || "",
      folder: (k) => (fs.existsSync(path.join(vault, k)) && fs.statSync(path.join(vault, k)).isDirectory() ? `${k}/` : ""),
    },
  };

  const groups = {
    concept: groupBy(clips, (c) => c.tags),
    author: groupBy(clips, (c) => (c.authorKey ? [c.authorKey] : [])),
    tag: groupBy(clips, (c) => c.tags),
    folder: groupBy(clips, folderOf),
  };
  const candidates = [];
  for (const kind of KINDS) {
    const keys = [...groups[kind].keys()].sort(cmp);
    for (const key of keys) {
      const members = groups[kind].get(key);
      if (members.length < MIN_CLIPS[kind]) continue;
      const c = evaluate(kind, key, members, ctx);
      if (kind === "author") c.name = mostCommon(members.map((m) => m.authorLabel));
      candidates.push(c);
    }
  }

  const conceptPasses = new Map(candidates.filter((c) => c.kind === "concept" && c.status === "pass").map((c) => [c.key, c]));
  for (const c of candidates) {
    const twin = c.kind === "tag" && c.status === "pass" ? conceptPasses.get(c.key) : null;
    if (!twin) continue;
    delete c.supersedes;
    Object.assign(c, {
      status: "skip", category: "dedup", reason: "same-subject-as-concept",
      detail: `candidate ${twin.slug} covers the same subject and is listed instead`,
    });
  }

  const byKind = Object.fromEntries(KINDS.map((k) => [k, candidates
    .filter((c) => c.kind === k && c.status === "pass")
    .sort((x, y) => y.clipCount - x.clipCount || cmp(x.slug, y.slug))]));
  const ranked = [];
  for (let i = 0; KINDS.some((k) => i < byKind[k].length); i++) {
    for (const k of KINDS) if (i < byKind[k].length) ranked.push(byKind[k][i]);
  }
  ranked.forEach((c, i) => { c.rank = i + 1; });
  const skipped = candidates.filter((c) => c.status === "skip")
    .sort((x, y) => KINDS.indexOf(x.kind) - KINDS.indexOf(y.kind) || cmp(x.slug, y.slug));

  const counts = {};
  for (const k of KINDS) {
    const mine = candidates.filter((c) => c.kind === k);
    counts[k] = {
      candidates: mine.length,
      pass: mine.filter((c) => c.status === "pass").length,
      skipConfidenceFloor: mine.filter((c) => c.category === "confidence-floor").length,
      skipDedup: mine.filter((c) => c.category === "dedup").length,
    };
  }
  return {
    vault, today: args.today, since: args.since,
    eligibleClips: clips.length,
    inputsExcluded,
    folderLensExcluded: clips.filter((c) => !c.hasPromo).length,
    counts,
    candidates: [...ranked, ...skipped],
  };
}

function renderLines(r) {
  const out = [];
  out.push(`synthesis-candidates: vault=${r.vault} today=${r.today}${r.since ? ` since=${r.since}` : ""} eligible=${r.eligibleClips} inputs-excluded=${r.inputsExcluded.length}`);
  for (const x of r.inputsExcluded) out.push(`⊘ ${x.path} — excluded from synthesis (input): ${x.reason}`);
  out.push(`note: ${r.folderLensExcluded} eligible clips have no "## Promotion candidate" section — excluded from the folder lens only`);
  for (const c of r.candidates.filter((x) => x.status === "pass")) {
    out.push(`PASS ${c.rank} ${c.kind} ${c.slug} clips=${c.clipCount} evidence=${c.evidenceCount} urls=${c.uniqueUrls} sources=${c.distinctSources}${c.supersedes ? ` supersedes=${c.supersedes}` : ""}`);
  }
  for (const c of r.candidates.filter((x) => x.status === "skip")) {
    out.push(`⊘ ${c.slug} — skipped (${c.category}): ${c.reason} — ${c.detail}`);
  }
  for (const k of KINDS) {
    const n = r.counts[k];
    out.push(`counts ${k}: candidates=${n.candidates} pass=${n.pass} skip-confidence-floor=${n.skipConfidenceFloor} skip-dedup=${n.skipDedup}`);
  }
  return out.join("\n") + "\n";
}

const args = parseArgs(process.argv.slice(2));
const result = build(args);
if (result.noClippings) {
  process.stdout.write("synthesize-clips: no Clippings/ — nothing to synthesize\n");
  process.exit(0);
}
if (result.gate) { process.stderr.write(result.gate + "\n"); process.exit(2); }
process.stdout.write(args.format === "json" ? JSON.stringify(result, null, 2) + "\n" : renderLines(result));
