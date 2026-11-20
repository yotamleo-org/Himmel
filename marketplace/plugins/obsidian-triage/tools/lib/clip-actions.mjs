/**
 * clip-actions.mjs — the daily report's suggested actions as vault state, shared
 * by daily-timeline.mjs (which lists them) and apply-clip-actions.mjs (which
 * applies the mechanical ones) so the two cannot disagree about what an action
 * is, which clips it covers, or whether it is already done.
 *
 * An action id is sha256(verb|target|date): it names what is done and the day it
 * was suggested, not the clips. This module re-derives, for a day, every action
 * the report could suggest (uncapped), tells fold / archive from the rest, and
 * reads "applied" off the vault:
 *   fold    — every clip's link is in the target map (`60-Maps/<moc>.md`)
 *   archive — every clip carries `archived: true`
 * Evaluate-tool and ticket actions are never applied, so never applied here.
 *
 * Reads the vault only; the pure string transforms (foldContent,
 * stampArchived) do no I/O either.
 */

import fs from "node:fs";
import path from "node:path";
import { parse, fmScalar, fmList, hasKey, insertScalar } from "./frontmatter.mjs";
import {
  REPORT_HEADING, actionId, suggestActions, sourceFromClip, wikilink, sectionLines, parseItems, carryOver,
} from "./daily-report.mjs";

export const REPORT_LOOKBACK_DAYS = 14;

/** YYYY-MM-DD shifted by n days (calendar arithmetic, no timezone). */
export function shiftDate(date, n) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);
}

/** YYYY-MM-DD naming a real day: refuses 2026-13-01 and 2026-02-30. */
export function isCalendarDate(date) {
  return /^\d{4}-\d{2}-\d{2}$/.test(date) && !Number.isNaN(Date.parse(`${date}T00:00:00Z`)) && shiftDate(date, 0) === date;
}

/** Resolve the daily note for <date>, or null if none exists (no phantom). */
export function resolveDaily(vault, date, override) {
  const candidates = override
    ? [override]
    : [
        path.join(vault, "50-Journal", "Daily", `${date}.md`),
        path.join(vault, "Daily", `${date}.md`),
      ];
  for (const c of candidates) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}

/** The action items in <date>'s `## Daily report`, or null when there is no note. */
export function reportItems(vault, date) {
  const p = resolveDaily(vault, date, null);
  return p ? parseItems(sectionLines(fs.readFileSync(p, "utf8"), REPORT_HEADING)) : null;
}

/** MOCs in 60-Maps/ (`type: moc`) with their tags: the fold targets. */
export function listMocs(vault) {
  const dir = path.join(vault, "60-Maps");
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
  const mocs = [];
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith(".md")) continue;
    let content;
    try { content = fs.readFileSync(path.join(dir, e.name), "utf8"); } catch { continue; }
    const { lines, bounds } = parse(content);
    if (!bounds || fmScalar(lines, bounds.close, "type") !== "moc") continue;
    const tags = fmList(lines, bounds.close, "tags").filter((t) => t !== "moc");
    if (tags.length) mocs.push({ link: `60-Maps/${e.name.replace(/\.md$/, "")}`, tags });
  }
  return mocs;
}

/**
 * Report sources for each of `dates` in one pass over the flat `_evidence/` pool
 * (`_rejected/` and any subdir are not sources): Map<date, source[]>, a source
 * being sourceFromClip's record plus `archived` (the `archived: true` stamp).
 */
export function loadSources(vault, dates) {
  const byDate = new Map([...new Set(dates)].map((d) => [d, []]));
  const dir = path.join(vault, "Clippings", "_evidence");
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return byDate; }
  for (const e of entries) {
    if (!e.isFile() || !e.name.endsWith(".md")) continue;
    let content;
    try { content = fs.readFileSync(path.join(dir, e.name), "utf8"); } catch { continue; }
    const { lines, bounds } = parse(content);
    if (!bounds) continue;
    const triaged = fmScalar(lines, bounds.close, "triaged_at");
    if (!byDate.has(triaged)) continue;
    const src = sourceFromClip(`Clippings/_evidence/${e.name.replace(/\.md$/, "")}`, content);
    src.archived = fmScalar(lines, bounds.close, "archived") === "true";
    byDate.get(triaged).push(src);
  }
  return byDate;
}

/** Report sources for one day. */
export function reportSources(vault, date) {
  return loadSources(vault, [date]).get(date);
}

/** True when `content` links `link` (`[[link]]`, `[[link|alias]]` or `[[link#heading]]`). */
export function hasLink(content, link) {
  return ["]]", "|", "#"].some((tail) => content.includes(`[[${link}${tail}`));
}

const FOLD_TEXT = /^Fold .* into \[\[([^\]|]+)\]\]$/;

/**
 * What the report's own rules (suggestActions) make of one source. The verb and
 * fold target are read off the rendered text and CHECKED against the id the
 * report would print; a mismatch is "other", so a drift between this reader and
 * the rules can never turn into a wrong edit.
 */
function classify(src, mocs, date) {
  const [a] = suggestActions([src], mocs, { date });
  const fold = FOLD_TEXT.exec(a.text);
  if (fold && a.id === actionId("fold", fold[1], date)) return { id: a.id, kind: "fold", target: fold[1] };
  if (a.text.startsWith("Archive ") && a.id === actionId("archive", src.link, date)) {
    return { id: a.id, kind: "archive", target: src.link };
  }
  return { id: a.id, kind: "other", target: "" };
}

/**
 * Every action the report could suggest for the days in `sourcesByDate`,
 * uncapped: Map<id, { id, kind: "fold"|"archive"|"other", target, since, clips,
 * applied }>. `clips` are the sources it covers, sorted by link.
 */
export function actionIndex(vault, sourcesByDate, mocs) {
  const index = new Map();
  for (const [date, sources] of sourcesByDate) {
    for (const src of sources) {
      const c = classify(src, mocs, date);
      if (!index.has(c.id)) index.set(c.id, { ...c, since: date, clips: [] });
      index.get(c.id).clips.push(src);
    }
  }
  const maps = new Map();
  const mapText = (target) => {
    if (!maps.has(target)) {
      let text = "";
      try { text = fs.readFileSync(path.join(vault, ...`${target}.md`.split("/")), "utf8"); } catch { /* unreadable map: nothing is folded into it */ }
      maps.set(target, text);
    }
    return maps.get(target);
  };
  for (const a of index.values()) {
    a.clips.sort((x, y) => x.link.localeCompare(y.link));
    a.applied =
      a.kind === "fold" ? a.clips.every((c) => hasLink(mapText(a.target), c.link))
      : a.kind === "archive" ? a.clips.every((c) => c.archived)
      : false;
  }
  return index;
}

/** The ids in the index whose work the vault already shows done. */
export function appliedIds(vault, sourcesByDate, mocs) {
  const ids = new Set();
  for (const a of actionIndex(vault, sourcesByDate, mocs).values()) if (a.applied) ids.add(a.id);
  return ids;
}

/**
 * Open actions in the day notes from `date - lookback` through `date`
 * (unticked, undismissed), oldest first: [{ id, text, since }].
 */
export function openActions(vault, date, lookback = REPORT_LOOKBACK_DAYS) {
  const lists = [];
  for (let n = lookback; n >= 0; n--) {
    const items = reportItems(vault, shiftDate(date, -n));
    if (items) lists.push(items);
  }
  return carryOver(lists).carried;
}

/**
 * Add the clips whose link a map lacks, as bullets at the end of its
 * `## Evidence` section (which ends at the next `#`/`##` heading; a new section
 * at EOF when it has none), in the map's
 * own line endings. Returns { next, at, appended, fresh } — `appended` is the
 * literal text inserted at offset `at`, so a revert can cut exactly it — or
 * null when every clip is already linked.
 */
export function foldContent(content, clips) {
  const fresh = clips.filter((c) => !hasLink(content, c.link));
  if (!fresh.length) return null;
  const eol = content.includes("\r\n") ? "\r\n" : "\n";
  const bullets = fresh.map((c) => `- ${wikilink(c.link, c.title)}`).join(eol);
  const head = /^## Evidence[ \t]*\r?$/m.exec(content);
  if (!head) {
    const appended = `${content.endsWith("\n") ? "" : eol}${eol}## Evidence${eol}${eol}${bullets}${eol}`;
    return { next: content + appended, at: content.length, appended, fresh };
  }
  const bodyStart = head.index + head[0].length;
  const nextHead = content.slice(bodyStart).search(/^#{1,2} /m);
  const bodyEnd = nextHead === -1 ? content.length : bodyStart + nextHead;
  const kept = content.slice(bodyStart, bodyEnd).replace(/\s+$/, "").length;
  const at = bodyStart + kept;
  const appended = (kept === 0 ? eol + eol : eol) + bullets;
  return { next: content.slice(0, at) + appended + content.slice(at), at, appended, fresh };
}

/**
 * Stamp a clip `archived: true` + `archived_at: <date>` at the end of its
 * frontmatter; no other key is touched. { next } on success, { skip: <reason> }
 * for a clip already stamped, without frontmatter, or carrying an `archived` /
 * `archived_at` key that is not ours to overwrite.
 */
export function stampArchived(content, date) {
  const { lines, bounds } = parse(content);
  if (!bounds) return { skip: "no frontmatter" };
  if (fmScalar(lines, bounds.close, "archived") === "true") return { skip: "already archived" };
  if (hasKey(lines, bounds.close, "archived") || hasKey(lines, bounds.close, "archived_at")) {
    return { skip: "has an archived/archived_at key it does not overwrite" };
  }
  return { next: insertScalar(insertScalar(content, "archived", "true"), "archived_at", date) };
}
