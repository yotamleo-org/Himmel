import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderShift } from "../public/shift.js";
import { renderHealth } from "../public/health.js";

// Shift (mockup v3) and Health (mockup v2) sit on the shared layer the way their mockups do:
// one main-column grid at the mockup body size, the group tile with its big number, and group panels with a coloured
// left edge, instead of every section boxed and page-local tiles.
const PUBLIC = join(import.meta.dir, "../public");
const read = (f: string) => readFileSync(join(PUBLIC, f), "utf8");

const shiftView = {
  shift: { id: "2026-10-27T20:00+01:00", name: "night", opened: "2026-10-27T20:00+01:00", closed: null, zone: "+01:00", minutes: 545, nextCut: "2026-10-28T08:00+01:00", why: null },
  pager: { prev: "2026-10-27T08:00+01:00", next: null },
  chiefs: [{ name: "IH", bucket: "himmel", span: { start: "2026-10-28T04:26+01:00", end: null, approx: false }, prs: [4144] }],
  gap: [], carried: [], mergedUnread: false,
  waiting: [{ kind: "GO", ticket: "HIMMEL-7591", title: "t", detail: "", pr: 4144, chief: "IH", since: "2026-10-28T04:27+01:00" }],
  running: [{ stage: "building", ticket: "HIMMEL-7962", title: "t", pr: null }],
  shipped: [{ number: 4133, title: "t", mergedAt: "2026-10-28T04:41+01:00", chief: "IH" }],
};

test("the main-column grid carries the mockup body size, and the group panel is a shared component", () => {
  const css = read("app.css");
  expect(css).toMatch(/(^|\n)\.pg\{[^}]*display:grid[^}]*\}/);
  expect(css).toMatch(/(^|\n)\.pg\{[^}]*gap:var\(--s3\)[^}]*\}/);
  expect(css).toMatch(/(^|\n)\.pg\{[^}]*font-size:var\(--fs-base\)[^}]*\}/);
  expect(css).toMatch(/(^|\n)\.p\{[^}]*border-left:4px solid var\(--gc/);
  expect(css).not.toMatch(/\.sh-tile[\s{,.]/);
});

test("Shift draws its KPI tiles as the shared group tile and its sections as group panels", () => {
  const html = renderShift(shiftView, {});
  expect(html.startsWith('<div class="pg">')).toBe(true);
  expect(html).not.toContain("sh-tile");
  for (const g of ["g-wait", "g-run", "g-ship"]) expect(html).toMatch(new RegExp(`<div class="tile ${g}"><span class="ic"[^>]*>[^<]+</span><span class="tname">[^<]+</span><span class="num">\\d+</span>`));
  for (const [id, g] of [["sh-chiefs", "g-chief"], ["sh-waiting", "g-wait"], ["sh-running", "g-run"], ["sh-shipped", "g-ship"]]) {
    expect(html).toMatch(new RegExp(`<section id="${id}" class="p ${g}[^"]*"`));
  }
  expect(html).not.toMatch(/<section[^>]*class="box/);
});

test("Health's project view: strip and tiles straight in the grid, the open tile as a group panel, no boxed sections", () => {
  const feed = { generatedAt: "2026-10-31T10:00:00Z", target: { project: "himmel" }, rows: [{ id: "g", source: "item", bundle: "guards", health: "fail", installed: { detail: "d" }, fix: { remedy: "", owner: "user" }, control: { class: "display-only" } }] };
  const html = renderHealth(feed, null, { now: Date.parse("2026-10-31T10:05:00Z") });
  expect(html.startsWith('<div class="pg">')).toBe(true);
  expect(html).not.toMatch(/<section[^>]*class="box/);
  expect(html).toMatch(/<section id="verdict" class="sec"[\s\S]*?class="vhead strip v-fail"/);
  expect(html).toMatch(/<section id="broken" class="p g-chk"/);
  for (const id of ["trends", "reviewers"]) expect(html).toMatch(new RegExp(`<section id="${id}" class="sec"`));
  expect(html).toMatch(/<button type="button" class="tile g-chk"[^>]*><span class="ic"[^>]*>/);
});

test("the Health project picker sits above the page links in the rail", () => {
  const js = read("app.js");
  expect(js).toMatch(/\$\("#pages"\)\.innerHTML = \(currentPage\.id === "health" \? projectPicker\(\) : ""\) \+ navLinks\(/);
});
