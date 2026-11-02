#!/usr/bin/env node
/**
 * x-thread-backfill.mjs — re-fetch the thread of EVERY X clip under
 * <vault>/Clippings/ and keep the author's self-thread (and link-bearing
 * replies) under `## Thread`. Same capture as fxtwitter-enrich.mjs.
 *
 * Usage:
 *   node x-thread-backfill.mjs --vault <dir> [--apply] [--limit N] [--resume-after <rel path>]
 *
 * Default is a dry run: it fetches and reports, and writes NOTHING. --apply
 * writes, and only inside Clippings/ of the given --vault.
 *
 * Per clip it prints  <rel path>\t<verdict>\t<chars>  with verdict one of
 *   adds-text    the thread holds text the clip lacks (chars = how much)
 *   no-new-text  fetched fine, nothing to add (also: already applied)
 *   fetch-failed endpoint and Scrapling both failed; the clip is left as is
 * then one line:  summary: seen=N adds-text=A no-new-text=B fetch-failed=C
 *
 * Rate: one request per clip at 1 s, so about 25 minutes for 1383 clips.
 * Resumable: a re-run skips nothing on its own, so pass --resume-after with
 * the last path printed (paths are processed in sorted order); a clip that was
 * already applied reports no-new-text and is not rewritten. One failed clip
 * never aborts the run.
 *
 * Exit: 0 done, 1 bad usage, 3 at least one guarded write was reverted.
 */
import { existsSync } from "node:fs";
import { relative, sep } from "node:path";
import { findClips, rethreadClip } from "./fxtwitter-enrich.mjs";

function usage(code) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: x-thread-backfill.mjs --vault <dir> [--apply] [--limit N] [--resume-after <rel path>]");
  out("Re-fetches the thread of every X clip in <dir>/Clippings and keeps the author's");
  out("self-thread under `## Thread`. Dry run unless --apply. 1 request/clip at 1 s:");
  out("about 25 minutes for 1383 clips. Resume with --resume-after <last printed path>.");
  process.exit(code);
}

const args = { vault: null, apply: false, limit: 0, resumeAfter: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--vault") args.vault = argv[++i];
  else if (a === "--apply") args.apply = true;
  else if (a === "--dry-run") args.apply = false;
  else if (a === "--limit") args.limit = parseInt(argv[++i] || "0", 10) || 0;
  else if (a === "--resume-after") args.resumeAfter = argv[++i];
  else if (a === "-h" || a === "--help") usage(0);
  else { console.error(`unknown arg: ${a}`); usage(1); }
}
if (!args.vault) usage(1);
if (!existsSync(args.vault)) { console.error(`x-thread-backfill: vault not found: ${args.vault}`); process.exit(1); }

const counts = { seen: 0, "adds-text": 0, "no-new-text": 0, "fetch-failed": 0 };
let writeFailed = 0;
let skippedNonX = 0;
let done = 0;
for (const clip of findClips(args.vault)) {
  const rel = relative(args.vault, clip).split(sep).join("/");
  if (args.resumeAfter && rel <= args.resumeAfter) continue;
  if (args.limit > 0 && done >= args.limit) break;
  let res;
  try {
    res = await rethreadClip(clip, args.vault, args.apply);
  } catch (e) {
    res = { kind: "fetch-failed", chars: 0, message: `${rel} -- ${e.message}` };
  }
  if (res.kind === "skip") { skippedNonX++; continue; }
  done++;
  counts.seen++;
  if (res.kind === "write-failed") { writeFailed++; console.error(`${rel}\twrite-failed\t0\t${res.message}`); continue; }
  counts[res.kind]++;
  console.log(`${rel}\t${res.kind}\t${res.chars}`);
}
console.log(`non-x skipped: ${skippedNonX}`);
if (writeFailed) console.log(`write-failed: ${writeFailed}`);
console.log(`mode: ${args.apply ? "apply" : "dry-run"}`);
console.log(`summary: seen=${counts.seen} adds-text=${counts["adds-text"]} no-new-text=${counts["no-new-text"]} fetch-failed=${counts["fetch-failed"]}`);
process.exit(writeFailed ? 3 : 0);
