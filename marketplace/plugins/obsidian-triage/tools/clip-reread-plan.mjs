#!/usr/bin/env node
/**
 * clip-reread-plan.mjs — before a paid reread of X clips, code
 * decides which clips matter and keeps the triage fields of the rest.
 *
 * Usage:
 *   node clip-reread-plan.mjs --vault <dir> [--apply] [--min-chars N] [--kept-file <path>] [--limit N]
 *
 * Walks <vault>/Clippings at any depth (_media, _synthesis, _done and _deferred.md
 * skipped: synthesis never takes archived or deferred clips). Only X
 * clips (source on x.com / twitter.com) are considered. Per clip it prints
 *   <rel path>\t<verdict>\t<reason>
 * with verdict one of
 *   kept     the reread goes on to synthesis
 *   skipped  nothing worth a paid reread changed
 * and reason one of
 *   first-triage      not triaged yet: verdict "fresh", left for the normal first triage,
 *                     unchanged, and never part of the synthesis batch
 *   new-links         the ## Thread holds a URL the rest of the clip lacks
 *   new-author-text   the clipped author's thread posts add >= --min-chars new chars
 *   new-text          other kept thread posts add >= --min-chars new chars
 *   no-thread         no ## Thread section
 *   below-threshold   thread text is new but smaller than --min-chars, no new link
 * An already-triaged (processed: true) clip that is kept is also TRIAGE-SKIPPED:
 * it keeps processed, tags, summary and every other triage field; with --apply
 * code adds the two rule-derived fields thread_links and thread_handles. No
 * LLM, no network, and nothing is written without --apply.
 *
 * --kept-file writes the kept clips' relative paths, one per line, for the one
 * batched synthesis session; the last stdout lines are
 *   synthesis-batch: <the one command>   (only when --kept-file wrote a complete list;
 *                                         "withheld (plan incomplete)" when a file or directory was unreadable)
 *   mode: apply | dry-run
 *   summary: seen=N kept=K skipped=S fresh=F triage-skipped=T to-synthesise=K
 *            (+ unreadable=U unreadable-dirs=D when nonzero)
 * The counts are a PLAN: this tool runs no synthesis. The printed command is paid
 * and held by the ticket that owns the paid rerun; nothing here runs it.
 *
 * ponytail: tags are not re-derived from thread text (a guess is judgement),
 * upgrade path: a vault-tag-set matcher once a sample shows it is safe.
 */
import { chmodSync, existsSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, sep } from "node:path";

const SKIP_DIRS = new Set(["_media", "_synthesis", "_done"]);
const THREAD_RE = /\n## Thread\n<!-- fxtwitter thread -->[\s\S]*?(?=\n## |\s*$)/;
const POST_LABEL = /^\*\*@(\w+)\*\* \(([^)]*)\) https:\/\/x\.com\/\w+\/status\/(\d+)$/;
const DERIVED_KEYS = ["thread_links", "thread_handles"];

function usage(code) {
  (code === 0 ? console.log : console.error)("Usage: clip-reread-plan.mjs --vault <dir> [--apply] [--min-chars N] [--kept-file <path>] [--limit N]");
  process.exit(code);
}

const args = { vault: null, apply: false, minChars: 280, keptFile: null, limit: 0 };
const argv = process.argv.slice(2);
const posInt = (v, flag) => {
  if (!/^[1-9][0-9]*$/.test(v || "")) { console.error(`${flag} needs a positive integer, got '${v || ""}'`); usage(1); }
  return parseInt(v, 10);
};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--vault") args.vault = argv[++i];
  else if (a === "--apply") args.apply = true;
  else if (a === "--dry-run") args.apply = false;
  else if (a === "--min-chars") args.minChars = posInt(argv[++i], a);
  else if (a === "--limit") args.limit = posInt(argv[++i], a);
  else if (a === "--kept-file") {
    const v = argv[++i];
    if (!v || v.startsWith("--")) { console.error(`--kept-file needs a path, got '${v || ""}'`); usage(1); }
    args.keptFile = v;
  }
  else if (a === "-h" || a === "--help") usage(0);
  else { console.error(`unknown arg: ${a}`); usage(1); }
}
if (!args.vault) usage(1);
if (!existsSync(join(args.vault, "Clippings"))) { console.error(`clip-reread-plan: no Clippings/ dir under ${args.vault}`); process.exit(1); }

const walkErrors = [];
function findClips(dir, out = []) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch (e) { walkErrors.push(`${dir}: ${e.code || e.message}`); return out; }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) findClips(p, out); }
    else if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") out.push(p);
  }
  return out;
}

/** One YAML scalar value: quotes removed, an unquoted trailing ` # comment` dropped. */
function scalar(raw) {
  const v = raw.trim();
  const q = v.match(/^(["'])(.*?)\1(?:\s+#.*)?$/);
  if (q) return q[2];
  return v.replace(/\s+#.*$/, "");
}

function split(text) {
  const t = text.replace(/\r\n/g, "\n");
  if (!t.startsWith("---\n")) return null;
  const end = t.indexOf("\n---\n", 4);
  if (end < 0) return null;
  const fmRaw = t.slice(4, end);
  const fm = {};
  for (const line of fmRaw.split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$/);
    if (m) fm[m[1]] = scalar(m[2]);
  }
  return { fm, fmRaw, body: t.slice(end + 5) };
}

const norm = (s) => s.replace(/\s+/g, " ").trim();
const urlsOf = (s) => [...new Set((s.match(/https?:\/\/[^\s)<>\]"']+/g) || []).map((u) => u.replace(/[.,;:!?]+$/, "")))];

/** Posts of a `## Thread` section: { id, handle, mine, text }. The clipped post's own id is dropped. */
function parseThread(section, clippedId) {
  const posts = [];
  let cur = null;
  for (const line of section.split("\n")) {
    const m = line.match(POST_LABEL);
    if (m) { cur = { handle: m[1], mine: m[2] === "author", id: m[3], text: [] }; posts.push(cur); continue; }
    if (cur && line.startsWith(">")) cur.text.push(line.replace(/^>\s?/, ""));
  }
  return posts.filter((p) => p.id !== clippedId).map((p) => ({ ...p, text: p.text.join("\n").trim() }));
}

function isXSource(src) {
  try { return /^(?:www\.|mobile\.)?(?:x|twitter)\.com$/.test(new URL(src).hostname); } catch { return false; }
}

function classify(text) {
  const parts = split(text);
  if (!parts || !isXSource(parts.fm.source || "")) return null; // not an X clip
  const triaged = /^true$/.test((parts.fm.processed || ""));
  const m = parts.body.match(THREAD_RE);
  if (!triaged) return { verdict: "fresh", reason: "first-triage", triageSkip: false, parts };
  if (!m) return { verdict: "skipped", reason: "no-thread", triageSkip: false, parts };
  const clippedId = ((parts.fm.source || "").match(/status\/(\d+)/) || [])[1] || "";
  const rest = withoutDerived(parts.fmRaw).join("\n") + "\n" + parts.body.replace(THREAD_RE, "");
  const haystack = norm(rest);
  const fresh = parseThread(m[0], clippedId).filter((p) => p.text && !haystack.includes(norm(p.text)));
  const restUrls = new Set(urlsOf(rest));
  const newLinks = fresh.flatMap((p) => urlsOf(p.text)).filter((u) => !restUrls.has(u));
  const chars = (ps) => ps.reduce((n, p) => n + p.text.length, 0);
  let reason = "below-threshold";
  if (newLinks.length) reason = "new-links";
  else if (chars(fresh.filter((p) => p.mine)) >= args.minChars) reason = "new-author-text";
  else if (chars(fresh) >= args.minChars) reason = "new-text";
  const all = parseThread(m[0], clippedId);
  return {
    verdict: reason === "below-threshold" ? "skipped" : "kept", reason, triageSkip: reason !== "below-threshold", parts,
    links: [...new Set(all.flatMap((p) => urlsOf(p.text)))], handles: [...new Set(all.map((p) => p.handle))],
  };
}

/** The frontmatter lines without the two fields this tool derives. */
function withoutDerived(fmRaw) {
  const kept = [];
  let skipping = false;
  for (const line of fmRaw.split("\n")) {
    const key = (line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):/) || [])[1];
    if (key) skipping = DERIVED_KEYS.includes(key);
    else if (skipping && /^\s+-\s|^\s*$/.test(line)) continue;
    else skipping = false;
    if (!skipping) kept.push(line);
  }
  return kept;
}

/** Add thread_links / thread_handles to the frontmatter (replacing earlier copies); the body and its line endings are untouched. */
function deriveFields(text, links, handles) {
  const m = text.match(/^---(\r?\n)([\s\S]*?)\r?\n---(\r?\n)/);
  const eol = m[1];
  const kept = withoutDerived(m[2].replace(/\r\n/g, "\n"));
  const block = (k, vs) => (vs.length ? [`${k}:`, ...vs.map((v) => `  - ${JSON.stringify(v)}`)] : []);
  const fm = [...kept, ...block("thread_links", links), ...block("thread_handles", handles)].join(eol);
  return `---${eol}${fm}${eol}---${m[3]}${text.slice(m[0].length)}`;
}

/** Replace a clip atomically: write beside it, then rename over it. */
function writeAtomic(p, out) {
  const tmp = join(dirname(p), `.${basename(p)}.reread-plan.tmp`);
  const mode = statSync(p).mode & 0o7777;
  writeFileSync(tmp, out, { encoding: "utf-8" });
  chmodSync(tmp, mode);
  renameSync(tmp, p);
}

const rows = [];
let seen = 0, kept = 0, skipped = 0, fresh = 0, triageSkipped = 0, unreadable = 0;
const clips = findClips(join(args.vault, "Clippings")).map((p) => ({ p, rel: relative(args.vault, p).split(sep).join("/") })).sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
for (const { p, rel } of clips) {
  if (args.limit > 0 && seen >= args.limit) break;
  let text;
  try { text = readFileSync(p, "utf-8"); } catch (e) { unreadable++; console.error(`${rel}\tunreadable\t${e.code || e.message}`); continue; }
  const c = classify(text);
  if (!c) continue;
  seen++;
  if (c.verdict === "kept") kept++; else if (c.verdict === "fresh") fresh++; else skipped++;
  if (c.triageSkip) {
    triageSkipped++;
    if (args.apply) {
      const out = deriveFields(text, c.links, c.handles);
      if (out !== text) writeAtomic(p, out);
    }
  }
  if (c.verdict === "kept") rows.push(rel);
  console.log(`${rel}\t${c.verdict}\t${c.reason}${c.triageSkip ? "\ttriage-skipped" : ""}`);
}
const shq = (v) => `'${String(v).replace(/'/g, "'\\''")}'`;
const incomplete = unreadable > 0 || walkErrors.length > 0;
if (args.keptFile) {
  writeFileSync(args.keptFile, rows.map((r) => r + "\n").join(""), { encoding: "utf-8" });
  console.log(incomplete
    ? "synthesis-batch: withheld (plan incomplete)"
    : `synthesis-batch: [paid, held for the operator, not run by this tool] claude --model claude-sonnet-5-5 ${shq(`Run /synthesize-clips ${args.vault} once, over exactly the clips listed in ${args.keptFile}`)}`);
}
console.log(`mode: ${args.apply ? "apply" : "dry-run"}`);
console.log(`summary: seen=${seen} kept=${kept} skipped=${skipped} fresh=${fresh} triage-skipped=${triageSkipped} to-synthesise=${kept}${unreadable ? ` unreadable=${unreadable}` : ""}${walkErrors.length ? ` unreadable-dirs=${walkErrors.length}` : ""}`);
for (const w of walkErrors) console.error(`unreadable directory (its clips were NOT seen): ${w}`);
process.exit(unreadable || walkErrors.length ? 3 : 0);
