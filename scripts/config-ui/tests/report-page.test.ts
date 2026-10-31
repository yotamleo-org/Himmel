// The Morning report page: the four report/shift settings (route + Configure card), the dated-report
// read routes, the markdown parser and the page renderer. Every test points HOME, the config path and the handover
// root at a temp dir.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { parseReport } from "../reports";
import { renderReport } from "../public/report.js";
import { renderReports } from "../public/render.js";
// @ts-expect-error CommonJS module without types
import { defaultConfig } from "../../himmelctl/lib/luna-config.js";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "r".repeat(64);
const SAVED = ["HOME", "HIMMEL_LUNA_CONFIG_PATH", "HIMMEL_PROVENANCE_DIR"] as const;
let saved: Record<string, string | undefined> = {};
let dir = "", cfg = "", handover = "";
let stop: (() => void) | null = null;

beforeEach(() => {
  saved = Object.fromEntries(SAVED.map((k) => [k, process.env[k]]));
  dir = mkdtempSync(join(tmpdir(), "report-page-"));
  mkdirSync(join(dir, "home"));
  handover = join(dir, "handover");
  mkdirSync(handover);
  cfg = join(dir, "config.json");
  process.env.HOME = join(dir, "home");
  process.env.HIMMEL_LUNA_CONFIG_PATH = cfg;
  process.env.HIMMEL_PROVENANCE_DIR = join(dir, "prov");
});
afterEach(() => {
  stop?.(); stop = null;
  for (const k of SAVED) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  rmSync(dir, { recursive: true, force: true });
});

function boot() {
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: process.env.HOME, HANDOVER_DIR: handover, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" } });
  stop = () => s.stop();
  return s.port;
}
const seed = () => { const doc = defaultConfig(); doc.luna.vaultPath = "/seeded/vault"; doc.bridge.enabled = true; writeFileSync(cfg, JSON.stringify(doc, null, 2) + "\n"); };
const url = (port: number, p: string) => `http://127.0.0.1:${port}${p}`;
const get = (port: number, p: string) => fetch(url(port, p), { headers: { "X-Himmel-Token": TOKEN } });
const post = (port: number, body: unknown) => fetch(url(port, "/api/report-settings"), { method: "POST", headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json", Origin: `http://127.0.0.1:${port}` }, body: JSON.stringify(body) });

const GOOD = { report_day: "utc", shift_idle_min: "90", shift_cuts: ["07:30", "19:30"], shift_min_run_h: "3" };

test("the four settings read their defaults, then save and read back, keeping every other section", async () => {
  seed();
  const port = boot();
  expect(await (await get(port, "/api/report-settings")).json()).toEqual({ report_day: "local", shift_idle_min: 60, shift_cuts: ["08:00", "20:00"], shift_min_run_h: 4 });
  const r = await post(port, GOOD);
  expect(r.status).toBe(200);
  expect(await r.json()).toEqual({ report_day: "utc", shift_idle_min: 90, shift_cuts: ["07:30", "19:30"], shift_min_run_h: 3 });
  const doc = JSON.parse(readFileSync(cfg, "utf8"));
  expect(doc.reports).toEqual({ report_day: "utc", shift_idle_min: 90, shift_cuts: ["07:30", "19:30"], shift_min_run_h: 3 });
  expect(doc.luna.vaultPath).toBe("/seeded/vault");
});

test("a setting that is not valid is named and nothing is written", async () => {
  seed();
  const port = boot();
  const before = readFileSync(cfg, "utf8");
  for (const [bad, word] of [[{ report_day: "mars" }, "report_day"], [{ shift_idle_min: "0" }, "shift_idle_min"], [{ shift_cuts: ["20:00", "08:00"] }, "shift_cuts"], [{ shift_cuts: ["8am", "20:00"] }, "shift_cuts"], [{ shift_min_run_h: "25" }, "shift_min_run_h"]] as const) {
    const r = await post(port, { ...GOOD, ...bad });
    expect(r.status).toBe(400);
    expect(((await r.json()) as { error: string }).error).toContain(word);
  }
  expect(readFileSync(cfg, "utf8")).toBe(before);
});

test("the report routes list the dated files, read one day, and answer none for a missing day", async () => {
  seed();
  writeFileSync(join(handover, "morning-report-2026-10-27.md"), "# Morning Report\n\n> The tiles, Completed and Chiefs cover Tue 27 Oct 00:00 to Wed 28 Oct 00:00.\n> Day starts: local midnight · change on Configure.\n\n## ✅ What shipped\n\n**3** PRs merged to main · **5** commits\n");
  writeFileSync(join(handover, "morning-report-2026-10-28.md"), "# Morning Report\n\n## ✅ What shipped\n\nx\n");
  writeFileSync(join(handover, "not-a-report.md"), "x");
  const port = boot();
  const list = await (await get(port, "/api/reports")).json() as { days: string[]; newest: string };
  expect(list.days).toEqual(["2026-10-28", "2026-10-27"]);
  expect(list.newest).toBe("2026-10-28");
  const one = await (await get(port, "/api/report?day=2026-10-27")).json() as { state: string; bar: string[]; sections: { title: string }[] };
  expect(one.state).toBe("ok");
  expect(one.bar).toHaveLength(2);
  expect(one.sections[0].title).toBe("✅ What shipped");
  expect(await (await get(port, "/api/report?day=2026-10-25")).json()).toEqual({ state: "none", day: "2026-10-25" });
  expect((await get(port, "/api/report?day=../../etc/passwd")).status).toBe(400);
  expect((await get(port, "/api/report?day=2026-99-99")).status).toBe(400);
  expect((await fetch(url(port, "/api/report?day=2026-10-27"))).status).toBe(401);
});

test("so far lists the shifts closed today, straight from shifts.jsonl", async () => {
  seed();
  const d = new Date(), today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const row = { id: `${today}T08:00+00:00`, name: "night", opened: `${today}T00:30+00:00`, closed: `${today}T08:00+00:00`, why: "cut", zone: "+00:00", minutes: 450, chiefs: [{ name: "IH", bucket: "himmel", span: { start: `${today}T01:00+00:00`, end: null, approx: false }, prs: [1, 2] }], carried: [] };
  writeFileSync(join(handover, "shifts.jsonl"), JSON.stringify(row) + "\n");
  const port = boot();
  const list = await (await get(port, "/api/reports")).json() as { today: string; soFar: { shifts: { id: string; prs: number; chiefs: number }[] } };
  expect(list.today).toBe(today);
  expect(list.soFar.shifts.map((s) => [s.id, s.chiefs, s.prs])).toEqual([[row.id, 1, 2]]);
});

test("report_day utc makes today the UTC date, local the station's", async () => {
  seed();
  const port = boot();
  const local = new Date(), localDay = `${local.getFullYear()}-${String(local.getMonth() + 1).padStart(2, "0")}-${String(local.getDate()).padStart(2, "0")}`;
  expect(((await (await get(port, "/api/reports")).json()) as { today: string }).today).toBe(localDay);
  expect((await post(port, { ...GOOD, report_day: "utc" })).status).toBe(200);
  expect(((await (await get(port, "/api/reports")).json()) as { today: string }).today).toBe(new Date().toISOString().slice(0, 10));
});

test("Configure shows the four settings with their values, and the save button", () => {
  const html = renderReports({ data: { report_day: "utc", shift_idle_min: 60, shift_cuts: ["08:00", "20:00"], shift_min_run_h: 4 }, error: null });
  expect(html).toContain("local midnight on the station (default)");
  expect(html).toMatch(/<input type="radio" name="report_day" data-rs="report_day" value="utc" checked>/);
  expect(html).toMatch(/data-rs="idle" value="60"/);
  expect(html).toMatch(/data-rs="cut1" value="08:00"/);
  expect(html).toMatch(/data-rs="cut2" value="20:00"/);
  expect(html).toMatch(/data-rs="minrun" value="4"/);
  expect(html).toContain('data-act="reports-save"');
  expect(html).toContain("applies from the next report on");
  expect(renderReports({ data: null, error: "boom" })).toContain("boom");
});

const GEN = [
  "# 🌅 Morning Report", "", "> The tiles, Completed and Chiefs cover Tue 27 Oct 00:00 to Wed 28 Oct 00:00. Spend per shift covers each shift over its own [opened, closed).",
  "> Day starts: local midnight on the station · change on Configure.", "> ⚠️ Jira: not available (jira unavailable)", "",
  "## ✅ What shipped", "", "**3** PRs merged to main · **5** commits · not available (jira unavailable) Done", "",
  "## ⏳ What waits on you", "", "- **2** open PR(s) to review/merge", "- **1** worker(s) awaiting your GO", "- **0** worker question(s)", "",
  "## 💸 What it spent", "", "- Claude usage of the shift (last 24h): weekly bank **+4.5** points", "",
  "## ▶️ What runs next", "", "- **2** In-Progress ticket(s) in flight.", "",
  "## 💸 Spend per shift", "", "| Shift | Span | PRs merged | Claude bank | Codex tokens |", "|---|---|---|---|---|", "| night | 20:00 to 08:00 | 2 | 41% (cadence log) | not available |", "",
].join("\n");

test("the parser reads the generator's dialect: bar, degraded notes, sections, tables", () => {
  const v = parseReport(GEN, "2026-10-27");
  if (v.state !== "ok") throw new Error("not ok");
  expect(v.bar).toHaveLength(2);
  expect(v.notes).toEqual(["Jira: not available (jira unavailable)"]);
  expect(v.sections.map((s) => s.title)).toEqual(["✅ What shipped", "⏳ What waits on you", "💸 What it spent", "▶️ What runs next", "💸 Spend per shift"]);
  const t = v.sections[4].blocks.find((b) => b.t === "table");
  expect(t && t.t === "table" && t.rows[0]).toEqual(["night", "20:00 to 08:00", "2", "41% (cadence log)", "not available"]);
});

const LIST = { days: ["2026-10-28", "2026-10-27"], newest: "2026-10-28", ageHours: 5, today: "2026-10-28", soFar: { day: "2026-10-28", shifts: [] } };
const ui = { day: null, shiftHref: "#/shift" };

test("a report draws the day selector, the window bar, five tiles, the open PRs apart and a degraded banner", () => {
  const html = renderReport(LIST, parseReport(GEN, "2026-10-27"), ui);
  expect(html).toContain('href="#/report?day=2026-10-27"');
  expect(html).toContain("Day starts: local midnight on the station");
  expect(html).toContain("covers each shift over its own [opened, closed)");
  expect((html.match(/<div class="tile /g) || []).length).toBe(5);
  expect(html).toMatch(/<span class="tname">Open PRs<\/span><span class="num">2<\/span>/);
  expect(html).toMatch(/<span class="tname">Waits on you<\/span><span class="num">1<\/span>/);
  expect(html).toMatch(/<section id="open-prs-1" class="p g-wait"/);
  expect(html).toContain('id="degraded"');
  expect(html).toContain('<span class="dim">not available</span>');
  expect(html).not.toContain("<script");
});

test("a day with no report says so, and today shows the so-far view instead", () => {
  const miss = renderReport(LIST, { state: "none", day: "2026-10-25" }, ui);
  expect(miss).toContain("No report was made for Sunday 25 October");
  const so = renderReport({ ...LIST, days: ["2026-10-27"], newest: "2026-10-27" }, { state: "none", day: "2026-10-28" }, ui);
  expect(so).toContain("So far today");
  expect(so).toContain("is not a report and is never saved");
  expect(so).toContain(">so far</a>");
});

test("a newest report older than 36 hours warns that the cadence has not run", () => {
  const html = renderReport({ ...LIST, ageHours: 40 }, { state: "none", day: "2026-10-25" }, ui);
  expect(html).toContain("No report since 2026-10-28. The morning-report cadence has not run (doctor: WARN).");
  expect(renderReport(LIST, { state: "none", day: "2026-10-25" }, ui)).not.toContain("No report since");
});
