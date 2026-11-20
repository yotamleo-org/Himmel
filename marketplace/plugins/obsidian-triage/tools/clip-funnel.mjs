#!/usr/bin/env node
/**
 * clip-funnel.mjs — read-only funnel of the luna clip pipeline: of the clips taken
 * in, how many a synthesis page cites, how many subject pages were created or
 * extended, how many daily actions are open and applied, how many clips wait on
 * media, and which stage made no movement in the window.
 *
 *   node clip-funnel.mjs --vault <v> [--as-of YYYY-MM-DD] [--days N]
 *
 * Prints one JSON document. The window is the N days (default 7) ending on --as-of
 * (default today, local), inclusive; --as-of only anchors the window.
 *
 * Every stage reads files the pipeline already writes, once each, keeping a few
 * small records and no file body:
 *   intake    Clippings/_evidence/*.md                        (flat; a subfolder is not evidence;
 *                                                             `archived: true` clips count as `archived`, not as intake or cited)
 *   cited     Clippings/_synthesis/*.md                       a page cites a clip it links by name
 *   subjects  .synthesize-stubs.ledger.jsonl                  stub-create = created, densify = extended
 *   actions   50-Journal/Daily/<date>.md `## Daily report`    open = unticked, undismissed, not applied
 *             .apply-clip-actions.ledger.jsonl                fold / archive rows = applied (absent = none)
 *   media     ig_media_pending / x_media_pending: true        in Clippings/*.md and the evidence pool
 *
 * Each stage reports `moved_in_window` (events dated inside the window) and `last`
 * (its newest event, or null). `stalled` names the stages with no movement in the
 * window: intake, cited and subjects always; actions only while some are open; media
 * only while some clips wait. Nothing is written to the vault, not even a lock.
 * Exit 1: usage error, or a vault that is not a directory or cannot be read.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parse, fmScalar } from "./lib/frontmatter.mjs";
import { REPORT_HEADING, sectionLines, parseItems, carryOver } from "./lib/daily-report.mjs";

const SELF = path.basename(fileURLToPath(import.meta.url));
const DEFAULT_DAYS = 7;
const die = (msg) => { process.stderr.write(`${SELF}: ${msg}\n`); process.exit(1); };

function shiftDate(date, n) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
}

function isCalendarDate(date) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date) && shiftDate(date, 0) === date;
}

function localToday() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function parseArgs(argv) {
  const a = { vault: null, asOf: null, days: DEFAULT_DAYS };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--vault") a.vault = argv[++i];
    else if (t === "--as-of") a.asOf = argv[++i];
    else if (t === "--days") {
      const v = argv[++i];
      if (!/^[1-9]\d*$/.test(v || "")) die(`--days needs a positive integer, got: ${v}`);
      a.days = Number(v);
    } else die(`unknown arg: ${t}`);
  }
  return a;
}

function dayOf(value) {
  const m = /^\d{4}-\d{2}-\d{2}/.exec(value || "");
  return m ? m[0] : "";
}

function mdFiles(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) {
    if (e.code === "ENOENT" || e.code === "ENOTDIR") return [];
    throw e;
  }
  return entries.filter((e) => e.isFile() && e.name.endsWith(".md")).map((e) => e.name).sort();
}

function ledgerRows(file) {
  if (!fs.existsSync(file)) return [];
  const rows = [];
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    try {
      const row = JSON.parse(line);
      if (row && typeof row === "object") rows.push(row);
    } catch { continue; }
  }
  return rows;
}

function movement(inWindow) {
  let moved = 0;
  let last = "";
  return {
    see(day) {
      if (!day) return;
      if (inWindow(day)) moved++;
      if (day > last) last = day;
    },
    get moved() { return moved; },
    get last() { return last || null; },
  };
}

function funnel(vault, asOf, days) {
  const start = shiftDate(asOf, -(days - 1));
  const inWindow = (day) => day >= start && day <= asOf;
  const clips = path.join(vault, "Clippings");

  const intake = movement(inWindow);
  const enriched = movement(inWindow);
  const names = new Set();
  let waiting = 0;
  const readClip = (file) => {
    const { lines, bounds } = parse(fs.readFileSync(file, "utf8"));
    if (!bounds) return null;
    return (key) => fmScalar(lines, bounds.close, key);
  };
  const pendingMedia = (get) => get("ig_media_pending") === "true" || get("x_media_pending") === "true";
  let archived = 0;
  for (const name of mdFiles(path.join(clips, "_evidence"))) {
    const get = readClip(path.join(clips, "_evidence", name));
    const isArchived = Boolean(get) && get("archived") === "true";
    if (isArchived) archived++;
    else names.add(name.slice(0, -3));
    if (!get) continue;
    if (!isArchived) intake.see(dayOf(get("triaged_at")));
    enriched.see(dayOf(get("media_enriched_at")));
    if (pendingMedia(get)) waiting++;
  }
  for (const name of mdFiles(clips)) {
    if (name === "_deferred.md") continue;
    const get = readClip(path.join(clips, name));
    if (!get) continue;
    enriched.see(dayOf(get("media_enriched_at")));
    if (pendingMedia(get)) waiting++;
  }

  const pages = movement(inWindow);
  const cited = new Set();
  let synthesisPages = 0;
  for (const name of mdFiles(path.join(clips, "_synthesis"))) {
    synthesisPages++;
    const text = fs.readFileSync(path.join(clips, "_synthesis", name), "utf8");
    const { lines, bounds } = parse(text);
    if (bounds) pages.see(dayOf(fmScalar(lines, bounds.close, "date")));
    for (const m of text.matchAll(/\[\[([^\]|#]+)/g)) {
      const base = m[1].trim().split("/").pop().replace(/\.md$/, "");
      if (names.has(base)) cited.add(base);
    }
  }

  let subjectLast = "";
  const created = new Set();
  const extended = new Set();
  const touched = new Set();
  for (const row of ledgerRows(path.join(vault, ".synthesize-stubs.ledger.jsonl"))) {
    if (row.action !== "stub-create" && row.action !== "densify") continue;
    if (typeof row.subject !== "string") continue;
    (row.action === "stub-create" ? created : extended).add(row.subject);
    const day = dayOf(row.ts);
    if (inWindow(day)) touched.add(row.subject);
    if (day > subjectLast) subjectLast = day;
  }

  let appliedLast = "";
  const applied = new Set();
  const appliedInWindow = new Set();
  for (const row of ledgerRows(path.join(vault, ".apply-clip-actions.ledger.jsonl"))) {
    if ((row.action !== "fold" && row.action !== "archive") || typeof row.id !== "string") continue;
    applied.add(row.id);
    const day = dayOf(row.ts);
    if (inWindow(day)) appliedInWindow.add(row.id);
    if (day > appliedLast) appliedLast = day;
  }
  const dailyDir = path.join(vault, "50-Journal", "Daily");
  const lists = mdFiles(dailyDir)
    .filter((n) => /^\d{4}-\d{2}-\d{2}\.md$/.test(n))
    .map((n) => parseItems(sectionLines(fs.readFileSync(path.join(dailyDir, n), "utf8"), REPORT_HEADING)));
  const open = carryOver(lists).carried.filter((it) => !applied.has(it.id)).length;

  const stages = {
    intake: { clips: names.size, archived, moved_in_window: intake.moved, last: intake.last },
    cited: {
      clips: cited.size,
      share: names.size ? Math.round((cited.size / names.size) * 1000) / 1000 : 0,
      synthesis_pages: synthesisPages,
      moved_in_window: pages.moved,
      last: pages.last,
    },
    subjects: {
      created: created.size,
      extended: extended.size,
      moved_in_window: touched.size,
      last: subjectLast || null,
    },
    actions: { open, applied: applied.size, moved_in_window: appliedInWindow.size, last: appliedLast || null },
    media: { waiting, moved_in_window: enriched.moved, last: enriched.last },
  };
  const owes = { actions: open > 0, media: waiting > 0 };
  const stalled = Object.keys(stages).filter((k) => stages[k].moved_in_window === 0 && (owes[k] ?? true));
  return { as_of: asOf, window_days: days, ...stages, stalled };
}

const a = parseArgs(process.argv.slice(2));
if (!a.vault) die("usage: clip-funnel.mjs --vault <path> [--as-of YYYY-MM-DD] [--days N]");
if (!fs.existsSync(a.vault) || !fs.statSync(a.vault).isDirectory()) die(`vault not found: ${a.vault}`);
const asOf = a.asOf || localToday();
if (!isCalendarDate(asOf)) die("invalid --as-of (YYYY-MM-DD)");
let result;
try { result = funnel(a.vault, asOf, a.days); } catch (e) { die(`cannot read the vault: ${e.message}`); }
process.stdout.write(JSON.stringify(result, null, 2) + "\n");
