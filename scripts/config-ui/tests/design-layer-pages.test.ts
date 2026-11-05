import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseReport } from "../reports";
import { renderReport } from "../public/report.js";
import { renderShift } from "../public/shift.js";
import { renderHealth } from "../public/health.js";
import { renderConfigure } from "../public/setup.js";
import { renderRoadmap, renderKanban } from "../public/roadmap.js";
import { renderToolHealth } from "../public/tool-health.js";
import { renderWorkflow } from "../public/workflow.js";

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
  // the grid gap alone spaces its sections: the global section margin is reset inside it
  expect(css).toMatch(/(^|\n|,)\.pg>section[,{][^}]*margin:0/);
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
  for (const id of ["trends"]) expect(html).toMatch(new RegExp(`<section id="${id}" class="sec"`));
  expect(html).toMatch(/<button type="button" class="tile g-chk"[^>]*><span class="ic"[^>]*>/);
});

// Configure, Roadmap, Kanban, Tool health and Workflow sit on the same mockup body size as Shift and Health
test("Configure, Roadmap, Kanban, Tool health and Workflow render their main column on the .pg grid", () => {
  const setupState = { plans: {}, reviewGate: { data: { reviewers: [], env: [], overlay: "critics.local.json" } } };
  const pages: [string, string][] = [
    ["Configure", renderConfigure({ rows: [] }, { tile: null, setup: null, state: setupState, msgs: {} })],
    ["Roadmap", renderRoadmap(null, {})],
    ["Kanban", renderKanban(null, {})],
    ["Tool health", renderToolHealth(null, "t")],
    ["Workflow", renderWorkflow()],
  ];
  for (const [name, html] of pages) {
    expect(html.startsWith('<div class="pg">'), name).toBe(true);
    expect(html.endsWith("</div>"), name).toBe(true);
  }
});

test("Shift draws the chief chain as the mockup v3 chart: a segment per chief with its PR count, gaps between, the rest of the shift ahead", () => {
  const view = {
    ...shiftView,
    shift: { ...shiftView.shift, opened: "2026-10-27T20:00+01:00", nextCut: "2026-10-28T08:00+01:00" },
    chiefs: [
      { name: "HY", bucket: "himmel", span: { start: "2026-10-27T20:00+01:00", end: "2026-10-27T21:25+01:00", approx: false }, prs: [1, 2] },
      { name: "IA", bucket: "himmel", span: { start: "2026-10-27T21:32+01:00", end: "2026-10-27T22:20+01:00", approx: true }, prs: [3] },
      { name: "IH", bucket: "himmel", span: { start: "2026-10-28T04:26+01:00", end: null, approx: false }, prs: [4144] },
    ],
  };
  const html = renderShift(view, {}); // "now" is the server's elapsed minutes (545 from 20:00 = 05:05), not the browser clock
  const chiefs = html.slice(html.indexOf('id="sh-chiefs"'), html.indexOf('id="sh-waiting"'));
  expect(chiefs).toMatch(/<div class="chain" role="img" aria-label="[^"]*HY[^"]*">/);
  // the label carries the whole timeline: approximate spans, hand-over gaps and what is left of the shift
  expect(chiefs).toMatch(/aria-label="[^"]*approximately IA[^"]*hand-over gap 22:20 to 04:26[^"]*left until the 08:00 cut"/);
  expect(chiefs).toMatch(/<td class="cseg"[^>]*colspan="\d+"[^>]*>HY<small>2<\/small><\/td>/);
  expect(chiefs).toMatch(/<td class="cseg"[^>]*>≈?IA<small>1<\/small><\/td>/);
  expect(chiefs).toMatch(/<td class="cseg now"[^>]*>IH<small>1<\/small><\/td>/);
  expect(chiefs).toMatch(/<td class="cseg gap"[^>]*colspan="\d+"[^>]*><\/td>/); // HY to IA hand-over
  expect(chiefs).toMatch(/<td class="cseg fut"[^>]*>to the 08:00 cut<\/td>/);
  expect(chiefs).toMatch(/<div class="chain-axis"><span>20:00<\/span>/);
  expect(chiefs).not.toContain('<table class="data"'); // the chain table is gone
  expect(chiefs).not.toContain("style="); // the CSP (default-src 'self') refuses inline styles
});

test("Shift chain: time already passed since the last chief ended is a gap, only the rest of an open shift is ahead", () => {
  const view = {
    ...shiftView,
    shift: { ...shiftView.shift, opened: "2026-10-27T20:00+01:00", nextCut: "2026-10-28T08:00+01:00", minutes: 360 },
    chiefs: [{ name: "HY", bucket: "himmel", span: { start: "2026-10-27T20:00+01:00", end: "2026-10-27T21:00+01:00", approx: false }, prs: [] }],
  };
  // a browser clock far past the cut must not move the edge: the server says 360 minutes (02:00) have elapsed
  const html = renderShift(view, { now: Date.parse("2026-10-29T12:00+01:00") });
  expect(html).toMatch(/<td class="cseg gap" colspan="42"><\/td><td class="cseg fut" colspan="50">to the 08:00 cut<\/td>/); // of 12 h: 21:00 to 02:00 is 42 %, 02:00 to 08:00 is 50 %
});

test("Shift chain: a hand-over gap shorter than half a percent of the shift is still drawn", () => {
  const view = {
    ...shiftView,
    shift: { ...shiftView.shift, opened: "2026-10-27T20:00+01:00", nextCut: "2026-10-28T08:00+01:00", minutes: 200 },
    chiefs: [
      { name: "HY", bucket: "himmel", span: { start: "2026-10-27T20:00+01:00", end: "2026-10-27T21:00+01:00", approx: false }, prs: [] },
      { name: "IA", bucket: "himmel", span: { start: "2026-10-27T21:03+01:00", end: "2026-10-27T23:20+01:00", approx: false }, prs: [] },
    ],
  };
  expect(renderShift(view, {})).toMatch(/title="hand-over gap 21:00–21:03"/); // 3 min of 12 h is under half a percent
});

// Morning report, mockup v7.1 frame 1: the parts the generator's data already supports
const GEN71 = [
  "# 🌅 Morning Report", "", "> The tiles, Completed and Chiefs cover Tue 27 Oct 00:00 to Wed 28 Oct 00:00. Spend per shift covers each shift over its own [opened, closed).", "",
  "## ✅ What shipped", "", "**3** PRs merged to main · **5** commits", "",
  "## ⏳ What waits on you", "", "- **1** worker(s) awaiting your GO", "- **0** worker question(s)", "",
  "## 💸 What it spent", "", "- Claude usage of the shift (last 24h): weekly bank **+4.5** points", "",
  "## ▶️ What runs next", "", "- **2** In-Progress ticket(s) in flight.", "",
  "## 👥 Chiefs", "", "| Chief | Span | PRs merged | Shift |", "|---|---|---|---|",
  "| GZ | 00:00 to 00:21 | 0 | night 2026-10-26T20:00+01:00 |", "| HA | 00:35 to 01:16 | 8 | night 2026-10-26T20:00+01:00 |", "| HK | 09:00 to open | 3 | day 2026-10-27T08:00+01:00 |", "",
  "## 💸 Spend per shift", "", "| Shift | Span | PRs merged | Chiefs | Claude bank | Codex tokens | Codex bank | API $ | OpenRouter $ |", "|---|---|---|---|---|---|---|---|---|",
  "| night 2026-10-26T20:00+01:00 | 10-26 20:00 to 10-27 08:00 | 62 | 2 | 78% (log) | not available | not available | $0.13 (priced) | not available |",
  "| day 2026-10-27T08:00+01:00 | 10-27 08:00 to 10-27 20:00 | 52 | 1 | 83% (log) | not available | not available | $0.49 (priced) | not available |", "",
  "## TL;DR", "", "- **3** PRs merged · **2** shifts ended", "",
  "## ✅ Completed (3 PRs merged to main)", "", "| PR | Ticket | Summary |", "|---|---|---|", "| #1 | HIMMEL-1 | x |", "",
].join("\n");
const LIST71 = { days: ["2026-10-27"], newest: "2026-10-27", ageHours: 5, today: "2026-10-28", soFar: { day: "2026-10-28", shifts: [] } };
const page71 = () => renderReport(LIST71, parseReport(GEN71, "2026-10-27"), { day: "2026-10-27", shiftHref: "#/shift" });

test("the TL;DR is a strip right under the tiles, not a boxed group panel", () => {
  const html = page71();
  expect(html).toMatch(/<\/div><section id="tldr" class="sec rp-tldr"[^>]*><h2[^>]*>TL;DR<\/h2>[\s\S]*?<\/section>/);
  expect(html.indexOf('id="tldr"')).toBeGreaterThan(html.indexOf('class="tiles t5"'));
  expect(html.indexOf('id="tldr"')).toBeLessThan(html.indexOf('<section id="s-'));
  expect((html.match(/>TL;DR</g) || []).length).toBe(1);
});

test("Spend per shift opens with the shift timeline and the chief chart, each segment a table cell sized by colspan", () => {
  const html = page71();
  const spend = html.slice(html.indexOf("Spend per shift</h2>"));
  expect(spend).toMatch(/<div class="rp-tl" role="group" aria-label="Shifts and chiefs from 10-26 20:00 to 10-27 20:00">/);
  expect(spend).toMatch(/<span class="rp-tll">shifts<\/span><div class="chain" role="img"[^>]*>/);
  expect(spend).toContain('<td class="cseg" colspan="144" title="night: 10-26 20:00 to 10-27 08:00">night</td><td class="cseg" colspan="144" title="day: 10-27 08:00 to 10-27 20:00">day</td>');
  expect(spend).toMatch(/<span class="rp-tll">chiefs<\/span>/);
  expect(spend).toContain('<td class="cseg gap" colspan="3"></td><td class="cseg" colspan="8" title="HA: 00:35 to 01:16">HA</td>'); // 00:35 is 275 min after the window opened, 55 cells; GZ ended at cell 52
  expect(spend).toContain('<td class="cseg" colspan="132" title="HK: 09:00 to open">HK</td>'); // from 09:00 to the day's close
  expect(spend).toContain('<div class="chain-axis"><span>20</span><span>02</span><span>08</span><span>14</span><span>20</span></div>');
  expect(spend.indexOf('class="rp-tl"')).toBeLessThan(spend.indexOf("<table"));
  expect(spend).not.toContain("style="); // the CSP (default-src 'self') refuses inline styles
});

test("a chief of the previous evening is drawn at its own clock time, not on the day", () => {
  const gen = GEN71.replace("| HK | 09:00 to open", "| YE | 21:00 to 23:00 | 1 | night 2026-10-26T20:00+01:00 |\n| HK | 09:00 to open"); // ran Mon 21:00 to 23:00, inside the night shift that opened Mon 20:00
  const html = renderReport(LIST71, parseReport(gen, "2026-10-27"), { day: "2026-10-27", shiftHref: "#/shift" });
  const spend = html.slice(html.indexOf("Spend per shift</h2>"));
  expect(spend).toContain('<tr><td class="cseg gap" colspan="12"></td><td class="cseg" colspan="24" title="YE: 21:00 to 23:00">YE</td>'); // 60 min after the window opened, 120 min long
});

// the shape of a real report (morning-report-2026-11-05): the report day is 11-05 but its shifts closed on 11-04, a chief on two shifts has two rows, a
// night chief runs "to open", and the names are the long session names
const REAL71 = [
  "# 🌅 Morning Report — 2026-11-05", "", "## ✅ What shipped", "", "**25** PRs merged to main · **30** commits", "",
  "## 👥 Chiefs", "", "| Chief | Span | PRs merged | Shift |", "|---|---|---|---|",
  "| HIMMEL-nextleg-2026-11-03PK-roadmap-chief | 20:00 to open (approx) | 25 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-03PL-roadmap-chief | 20:00 to 20:00 (approx) | 0 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-03PM-roadmap-chief | 20:02 to 20:55 | 1 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-03PR-roadmap-chief | 00:12 to 00:32 | 0 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-04QD-roadmap-chief | 05:45 to 06:18 (approx) | 2 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-04QD-roadmap-chief | 06:18 to 06:18 (approx) | 2 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-04QG-roadmap-chief | 07:48 to open | 0 | night 2026-11-03T20:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-03PK-roadmap-chief | 08:00 to open (approx) | 16 | day 2026-11-04T08:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-04QG-roadmap-chief | 08:00 to 08:14 | 0 | day 2026-11-04T08:00+01:00 |",
  "| HIMMEL-nextleg-2026-11-04QX-roadmap-chief | 19:38 to open (approx) | 1 | day 2026-11-04T08:00+01:00 |", "",
  "## 💸 Spend per shift", "", "| Shift | Span | PRs merged | Chiefs | Claude bank | Codex tokens | Codex bank | API $ | OpenRouter $ |", "|---|---|---|---|---|---|---|---|---|",
  "| night 2026-11-03T20:00+01:00 | 11-03 20:00 to 11-04 08:00 | 25 | 22 | 52% (cadence ledger) | 0 tokens (codex rollouts) | not available | not available | not available |",
  "| day 2026-11-04T08:00+01:00 | 11-04 08:00 to 11-04 20:00 | 16 | 19 | 41% (cadence ledger) | 0 tokens (codex rollouts) | not available | not available | not available |", "",
  "## TL;DR", "", "**27** in-flight · **81** stale branches", "",
].join("\n");
const real71 = (gen = REAL71) => {
  const html = renderReport({ days: ["2026-11-05"], newest: "2026-11-05", ageHours: 5, today: "2026-11-06", soFar: { day: "2026-11-06", shifts: [] } }, parseReport(gen, "2026-11-05"), { day: "2026-11-05", shiftHref: "#/shift" });
  return html.slice(html.indexOf("Spend per shift</h2>"));
};
const PK = "HIMMEL-nextleg-2026-11-03PK-roadmap-chief";

test("a real report, whose shifts closed before its own day, still draws the shift timeline over the 24 h that end at the last close", () => {
  const spend = real71();
  expect(spend).toContain('aria-label="Shifts and chiefs from 11-03 20:00 to 11-04 20:00"');
  expect(spend).toContain('<td class="cseg" colspan="144" title="night: 11-03 20:00 to 11-04 08:00">night</td><td class="cseg" colspan="144" title="day: 11-04 08:00 to 11-04 20:00">day</td>'); // 12 h of 5 min cells each
  expect(spend).toContain("<span>20</span><span>02</span><span>08</span><span>14</span><span>20</span>");
});

test("every Chiefs row is drawn, a chief on two shifts twice, none hidden behind a chief that runs to open", () => {
  const spend = real71();
  expect(spend.match(/<td class="cseg"[^>]*title="HIMMEL-nextleg-[^"]*"/g)).toHaveLength(10); // one cell per Chiefs row, 10 rows
  expect(spend).toContain(`title="${PK}: 20:00 to open (approx)">PK</td>`);
  expect(spend).toContain(`title="${PK}: 08:00 to open (approx)">PK</td>`);
  expect(spend).toContain('title="HIMMEL-nextleg-2026-11-03PM-roadmap-chief: 20:02 to 20:55">PM</td>'); // the long name is shortened to its two letters, the title keeps it whole
  expect((spend.match(/>QD<\/td>/g) || []).length).toBe(2);
  expect((spend.match(/<span class="rp-tll">chiefs<\/span>/g) || []).length).toBe(1); // a chief lane below the first is unlabelled
});

test("a chief that crosses midnight is drawn for its real length", () => {
  const gen = REAL71.replace("| HIMMEL-nextleg-2026-11-03PR-roadmap-chief", "| ZZ | 23:50 to 00:10 | 0 | night 2026-11-03T20:00+01:00 |\n| HIMMEL-nextleg-2026-11-03PR-roadmap-chief");
  expect(real71(gen)).toContain('<td class="cseg" colspan="4" title="ZZ: 23:50 to 00:10">ZZ</td>'); // 20 min of 5 min cells
});

test("the spend table sits in a scroll box and is the wide kind", () => {
  const html = page71();
  expect(html).toMatch(/<div class="tw"><table class="data wide">[\s\S]*?<th>OpenRouter \$<\/th>/);
  const css = read("app.css");
  expect(css).toMatch(/(^|\n)\.tw\{[^}]*overflow-x:auto/);
  expect(css).toMatch(/(^|\n)table\.wide\{[^}]*min-width:/);
});

test("the Chiefs table adds the length of each span after the span", () => {
  const html = page71();
  const chiefs = html.slice(html.indexOf("Chiefs</h2>"), html.indexOf("Spend per shift</h2>"));
  expect(chiefs).toMatch(/<th>Chief<\/th><th>Span<\/th><th>Length<\/th><th>PRs merged<\/th><th>Shift<\/th>/);
  expect(chiefs).toMatch(/<td>00:35 to 01:16<\/td><td>41 min<\/td><td>8<\/td>/);
  expect(chiefs).toMatch(/<td>09:00 to open<\/td><td>open<\/td>/);
  expect(chiefs).toContain('<div class="tw"><table class="data wide">'); // five columns do not wrap at 390 px, they scroll
});

test("the Health project picker sits in the page bar above the page, never in the rail", () => {
  const js = read("app.js");
  expect(js).toMatch(/id: "health"[^\n]*render: \(f\) => pageBar\(\) \+ healthPage\(f\)/);
  expect(js).toMatch(/const ctl = currentPage\.id === "health" \? projectPicker\(\) : currentPage\.id === "report" \? reportBar\(reportList, reportView, reportUi\) : ""/);
  expect(js).toMatch(/\$\("#pages"\)\.innerHTML = railMarkup\(/);
});
