#!/usr/bin/env node
/**
 * apply-clip-actions.mjs — apply the daily note's two mechanical suggested
 * actions so they stop piling up unticked:
 *
 *   Fold <clips> into [[60-Maps/<moc>]]  → the clip links are added to that map
 *   Archive <clip>                       → the clip is stamped `archived: true` +
 *                                          `archived_at: <date>` (it stays in
 *                                          Clippings/_evidence/; nothing is moved)
 *
 * "Evaluate tool" and ticket actions need judgement and are NEVER applied.
 *
 *   node apply-clip-actions.mjs --vault <v> [--date YYYY-MM-DD] [--limit N]        dry-run (default), writes nothing
 *   node apply-clip-actions.mjs --vault <v> [--date ...] [--limit N] --apply       apply + ledger
 *   node apply-clip-actions.mjs --vault <v> --revert <ledger.jsonl>                divergence-guarded undo
 *
 * The open actions are those still unticked in the day notes of the last
 * REPORT_LOOKBACK_DAYS days (oldest first). Each is re-derived from the vault by
 * ./lib/clip-actions.mjs — the same code the daily timeline lists them with — and
 * is skipped when the vault already shows it applied, so a re-run never repeats
 * an action. At most --limit actions are applied per run (default 5): Obsidian
 * hangs on bulk file churn.
 *
 * Reversibility, as in synthesize-stubs.mjs: one ledger line per applied action
 * (<vault>/.apply-clip-actions.ledger.jsonl) records the page hashes before and
 * after. --revert undoes newest-first and REFUSES any page whose hash is not the
 * recorded post-apply hash (exit 3): a page edited since is not ours to rewrite.
 * The daily notes are not edited; the daily timeline reads "applied" off the vault.
 * --apply and --revert hold <vault>/.apply-clip-actions.lock (exit 2 while held).
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { removeScalar, sha256 } from "./lib/frontmatter.mjs";
import {
  isCalendarDate, listMocs, loadSources, actionIndex, openActions, foldContent, stampArchived,
} from "./lib/clip-actions.mjs";

const SELF = path.basename(fileURLToPath(import.meta.url));
const DEFAULT_LIMIT = 5;
const out = (s) => process.stdout.write(s + "\n");
const err = (s) => process.stderr.write(s + "\n");
function die(code, msg) { err(`${SELF}: ${msg}`); process.exit(code); }

function localToday() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function parseArgs(argv) {
  const a = { mode: "dry-run", vault: null, date: null, limit: DEFAULT_LIMIT, ledger: null, revertPath: null };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--vault") a.vault = argv[++i];
    else if (t === "--date") a.date = argv[++i];
    else if (t === "--limit") {
      const v = argv[++i];
      if (!/^[1-9]\d*$/.test(v || "")) die(1, `--limit needs a positive integer, got: ${v}`);
      a.limit = Number(v);
    }
    else if (t === "--ledger") a.ledger = argv[++i];
    else if (t === "--dry-run") a.mode = "dry-run";
    else if (t === "--apply") a.mode = "apply";
    else if (t === "--revert") { a.mode = "revert"; a.revertPath = argv[++i]; }
    else die(1, `unknown arg: ${t}`);
  }
  return a;
}

function absOf(vault, rel) {
  const root = path.resolve(vault);
  const abs = path.resolve(root, ...rel.split("/"));
  if (!abs.startsWith(root + path.sep)) die(1, `path escapes the vault: ${rel}`);
  return abs;
}

function plan(vault, a, date) {
  if (a.kind === "fold") {
    const rel = `${a.target}.md`;
    let before;
    try { before = fs.readFileSync(absOf(vault, rel), "utf8"); } catch { return { skip: `${rel} unreadable` }; }
    const f = foldContent(before, a.clips);
    if (!f) return { skip: `${rel} already links these clips` };
    return {
      line: `fold ${f.fresh.length} clip(s) into ${a.target} [act:${a.id} since:${a.since}]`,
      edits: [{ abs: absOf(vault, rel), next: f.next }],
      entry: {
        action: "fold", id: a.id, since: a.since, map: rel,
        map_sha256_before: sha256(before), map_sha256: sha256(f.next),
        at: f.at, appended: f.appended, clips: f.fresh.map((c) => c.link),
      },
    };
  }
  const edits = [];
  const files = [];
  let why = "nothing to stamp";
  for (const c of a.clips) {
    const rel = `${c.link}.md`;
    let before;
    try { before = fs.readFileSync(absOf(vault, rel), "utf8"); } catch { why = `${rel} unreadable`; continue; }
    const s = stampArchived(before, date);
    if (s.skip) { if (s.skip !== "already archived") why = `${rel}: ${s.skip}`; continue; }
    edits.push({ abs: absOf(vault, rel), next: s.next });
    files.push({ rel, sha256_before: sha256(before), sha256: sha256(s.next) });
  }
  if (!edits.length) return { skip: why };
  return {
    line: `archive ${a.clips.map((c) => c.link).join(", ")} [act:${a.id} since:${a.since}]`,
    edits,
    entry: { action: "archive", id: a.id, since: a.since, date, files },
  };
}

function recordThenWrite(p, ledgerPath) {
  fs.appendFileSync(ledgerPath, JSON.stringify({ ts: new Date().toISOString(), ...p.entry }) + "\n");
  for (const e of p.edits) fs.writeFileSync(e.abs, e.next);
}

function runApply(vault, date, limit, ledgerPath, dryRun) {
  const open = openActions(vault, date);
  const sourcesByDate = loadSources(vault, open.map((o) => o.since));
  const index = actionIndex(vault, sourcesByDate, listMocs(vault));
  const eligible = [];
  const skipped = { never: 0, unmatched: 0, applied: 0 };
  for (const o of open) {
    const a = index.get(o.id);
    if (!a) skipped.unmatched++;
    else if (a.kind === "other") skipped.never++;
    else if (a.applied) skipped.applied++;
    else eligible.push(a);
  }

  const done = { fold: 0, archive: 0 };
  let failed = 0;
  for (const a of eligible) {
    if (done.fold + done.archive >= limit) break;
    const p = plan(vault, a, date);
    if (p.skip) { out(`⊘ ${a.kind} ${a.target} — ${p.skip}`); failed++; continue; }
    if (dryRun) { out(`would ${p.line}`); done[a.kind]++; continue; }
    recordThenWrite(p, ledgerPath);
    out(`✓ ${p.line}`);
    done[a.kind]++;
  }
  const n = done.fold + done.archive;
  out(
    `${SELF}: ${n} ${dryRun ? "would-apply" : "applied"} (${done.fold} fold, ${done.archive} archive) of ` +
    `${eligible.length} eligible, limit ${limit}; skipped: ${skipped.never} never applied (evaluate/ticket), ` +
    `${skipped.unmatched} unmatched, ${skipped.applied} already applied, ${failed} unappliable`,
  );
}

function runRevert(vault, revertPath) {
  if (!fs.existsSync(revertPath)) die(1, `ledger not found: ${revertPath}`);
  const entries = fs.readFileSync(revertPath, "utf8").split("\n").map((l) => l.trim()).filter(Boolean).map((l) => {
    try { return JSON.parse(l); } catch (e) { return die(1, `corrupt ledger line: ${e.message}`); }
  }).filter((e) => e.action === "fold" || e.action === "archive");

  let reverted = 0, already = 0, refused = 0, gone = 0;
  const preApplyHashes = new Map();
  const notePreApply = (rel, h) => {
    if (!preApplyHashes.has(rel)) preApplyHashes.set(rel, new Set());
    preApplyHashes.get(rel).add(h);
  };
  for (const e of entries) {
    if (e.action === "fold") notePreApply(e.map, e.map_sha256_before);
    else for (const f of e.files) notePreApply(f.rel, f.sha256_before);
  }
  const revertPage = (rel, shaBefore, shaAfter, restore, what) => {
    const abs = absOf(vault, rel);
    if (!fs.existsSync(abs)) { gone++; return; }
    const cur = fs.readFileSync(abs, "utf8");
    const h = sha256(cur);
    if (h !== shaAfter) {
      if (preApplyHashes.get(rel).has(h)) { out(`= ${rel} — already reverted`); already++; return; }
      out(`⊘ ${rel} — diverged since ${what} (edited after the apply); refusing to revert`);
      refused++;
      return;
    }
    const restored = restore(cur);
    if (restored === null || sha256(restored) !== shaBefore) {
      out(`⊘ ${rel} — diverged since ${what} (cannot restore the recorded bytes); refusing to revert`);
      refused++;
      return;
    }
    fs.writeFileSync(abs, restored);
    out(`↩ ${rel} — ${what} reverted`);
    reverted++;
  };

  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.action === "fold") {
      revertPage(e.map, e.map_sha256_before, e.map_sha256,
        (cur) => (cur.slice(e.at, e.at + e.appended.length) === e.appended ? cur.slice(0, e.at) + cur.slice(e.at + e.appended.length) : null),
        "fold");
    } else {
      for (const f of e.files) {
        revertPage(f.rel, f.sha256_before, f.sha256, (cur) => removeScalar(removeScalar(cur, "archived_at"), "archived"), "archive");
      }
    }
  }
  out(`${SELF}: ${reverted} reverted, ${already} already-reverted, ${refused} refused (diverged), ${gone} already-gone`);
  if (refused) process.exitCode = 3;
}

function takeLock(vault) {
  const lock = path.join(vault, ".apply-clip-actions.lock");
  try { fs.mkdirSync(lock); } catch (e) {
    if (e.code === "EEXIST") die(2, `another run is active (or a stale lock at ${lock}); wait, or remove it`);
    throw e;
  }
  process.on("exit", () => { try { fs.rmdirSync(lock); } catch {} });
  for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => process.exit(130));
}

const a = parseArgs(process.argv.slice(2));
if (!a.vault) die(1, "usage: apply-clip-actions.mjs --vault <path> [--date YYYY-MM-DD] [--limit N] [--dry-run|--apply|--revert <ledger>]");
if (!fs.existsSync(a.vault) || !fs.statSync(a.vault).isDirectory()) die(1, `vault not found: ${a.vault}`);
const date = a.date || localToday();
if (!isCalendarDate(date)) die(1, "invalid --date (YYYY-MM-DD)");

if (a.mode !== "dry-run") takeLock(a.vault);
if (a.mode === "revert") {
  if (!a.revertPath) die(1, "--revert needs a ledger path");
  runRevert(a.vault, a.revertPath);
} else {
  runApply(a.vault, date, a.limit, a.ledger || path.join(a.vault, ".apply-clip-actions.ledger.jsonl"), a.mode === "dry-run");
}
