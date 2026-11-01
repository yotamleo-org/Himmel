// the one Health verdict (I6) and the page's escaping, as pure functions.
import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { verdict, projectVerdict, parseView, fixAction, renderHealth } from "../public/health.js";

const r = (id: string, health: string, extra: Record<string, unknown> = {}) => ({
  id, source: "item", bundle: "guards", health, installed: { state: "present", detail: `d-${id}` }, fix: { remedy: `fix-${id}`, owner: "user" }, ...extra,
});
const feed = (...rows: object[]) => ({ rows });
const prom = (alerts: object[] | null) => ({ monitoring: { state: alerts ? "ok" : "absent", prometheus: alerts ? { state: "ok", alerts } : { state: "absent" }, exporter: { state: "absent" } } });
const page = { alertname: "A", severity: "page", summary: "s" }, warnAlert = { alertname: "W", severity: "warn", summary: "s" };

test("verdict truth table", () => {
  const cases: [string, unknown, unknown, string][] = [
    ["pending feed", null, prom([page]), "No data"],
    ["fail row", feed(r("a", "fail")), prom(null), "Act now"],
    ["page alert, clean feed", feed(r("a", "ok")), prom([page]), "Act now"],
    ["warn row", feed(r("a", "warn")), prom(null), "Needs a look"],
    ["warn-severity alert, clean feed", feed(r("a", "ok")), prom([warnAlert]), "Needs a look"],
    ["fail beats warn", feed(r("a", "warn"), r("b", "fail")), prom(null), "Act now"],
    ["clean, no alerts firing", feed(r("a", "ok"), r("b", "off")), prom([]), "All clear"],
    ["clean, Prometheus absent never raises it", feed(r("a", "ok")), prom(null), "All clear"],
    ["clean, health not loaded", feed(r("a", "ok")), null, "All clear"],
  ];
  for (const [name, f, h, want] of cases) expect([name, verdict(f, h).word]).toEqual([name, want]);
});

test("verdict counts and alert state come from their owners", () => {
  expect(verdict(feed(r("a", "fail"), r("b", "warn"), r("c", "warn")), prom([warnAlert]))).toMatchObject({ fail: 1, warn: 2, alerts: [warnAlert] });
  expect(verdict(feed(r("a", "ok")), prom(null)).alerts).toBeNull();
});

test("renderHealth escapes every feed, ledger and alert string", () => {
  const evil = `<img src=x onerror=alert(1)>`;
  const f = feed(r(evil, "fail", { installed: { state: "present", detail: evil }, fix: { remedy: evil } }), r("job", "ok", { source: "cadence", id: `cadence:${evil}` }), r("q", "ok", { bundle: "search", id: evil }));
  const h = {
    bank: { state: "ok", row: { ts: evil, verdict: evil, five_hour: evil, seven_day: evil, age: evil, degraded: false } },
    monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: evil, severity: evil, summary: evil }] }, exporter: { state: "absent" } },
  };
  const html = renderHealth(f, h);
  expect(html).not.toContain("<img");
  expect(html).toContain("&lt;img");
  expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;</span>');
});

// Frame 9: with no feed yet the strip says No data and every tile names the source it waits for; no panel opens.
test("renderHealth with no feed and no health still renders the strip, the tiles and the trends", () => {
  const html = renderHealth(null, null);
  expect([...html.matchAll(/<h2 [^>]*>([^<]*)</g)].map((m) => m[1])).toEqual(["Is this project working right now?", "Trends"]);
  expect([...html.matchAll(/data-act="health-tile"/g)].length).toBe(4);
  expect(html).toContain("waiting for the doctor feed");
  expect(html).not.toContain('id="workers"'); // the worker list lives on Fleet (Q2)
  expect(html).toContain("No data");
});

// a responding exporter makes monitoring.state "ok", which must not hide a failing Prometheus.
test("each monitoring source's failure is rendered on its own, even when the other is ok", () => {
  const gone = { state: "absent" };
  const mon = (prometheus: object, exporter: object) => ({ bank: gone, monitoring: { state: "ok", prometheus, exporter } });
  const promDown = renderHealth(feed(r("a", "ok")), mon({ state: "error", reason: "HTTP 500" }, { state: "ok" }));
  expect(promDown).toContain("monitoring prometheus unreachable: HTTP 500");
  expect(promDown).not.toContain("monitoring exporter unreachable");
  const expDown = renderHealth(feed(r("a", "ok")), mon({ state: "ok", alerts: [] }, { state: "error", reason: "no answer" }));
  expect(expDown).toContain("monitoring exporter unreachable: no answer");
  expect(expDown).not.toContain("monitoring prometheus unreachable");
  const bothOk = renderHealth(feed(r("a", "ok")), mon({ state: "ok", alerts: [] }, { state: "ok" }));
  expect(bothOk).not.toContain("unreachable");
});

// Q4: Health is per project through the picker; the Project mode facts card stays on Configure ▸ Tracker.
test("the Health page draws no Project mode card", () => {
  const gone = { state: "absent" };
  const html = renderHealth(null, { bank: gone, monitoring: gone, mode: { state: "ok", tracker: "local", forge: "local-git", idRequired: "1" } });
  expect(html).not.toContain('id="mode"');
  expect(html).not.toContain("tracker=local");
});

// the fail/warn/ok pills in a Health row share one width and centre their text, so the ids line up.
test("the Health row status pills have one width and centred text", async () => {
  const css = await Bun.file(new URL("../public/app.css", import.meta.url)).text();
  const rule = /(?:^|\n)\.hrow \.st,\.alert \.st\{([^}]*)\}/.exec(css);
  expect(rule).not.toBeNull();
  expect(rule![1]).toContain("flex:none");
  expect(rule![1]).toContain("min-width:4.6em");
  expect(rule![1]).toContain("text-align:center");
});

const own = (id: string, health: string, fix: object = {}) => r(id, health, { scope: "project", fix: { by: "chief", ...fix } });
const shared = (id: string, health: string, fix: object = {}) => r(id, health, { scope: "shared", fix: { by: "chief", ...fix } });

test("the page opens on the current project, all-projects only when asked", () => {
  expect(parseView("")).toMatchObject({ mode: "project", project: null, tab: "broken" });
  expect(parseView("view=all")).toMatchObject({ mode: "all" });
  expect(parseView("project=luna&tab=all&row=x")).toEqual({ mode: "project", project: "luna", tab: "all", row: "x", tile: "checks" });
  expect(parseView("tab=bogus").tab).toBe("broken");
});

test("a project's own verdict leaves the shared rows out", () => {
  expect(projectVerdict({ fail: 0, warn: 0 }).word).toBe("All clear");
  expect(projectVerdict({ fail: 1, warn: 5 }).word).toBe("Act now");
  expect(projectVerdict({ fail: 0, warn: 2 }).word).toBe("Needs a look");
});

test("every failing row has exactly one fix action, first match winning", () => {
  expect(fixAction(own("a", "fail", { by: "configure", tile: "tracker", remedy: "x" }))).toEqual({ kind: "configure", tile: "tracker" });
  expect(fixAction(own("a", "fail", { by: "operator", remedy: "gh auth login" }))).toEqual({ kind: "copy", cmd: "gh auth login" });
  expect(fixAction(own("a", "fail", { by: "operator" }))).toEqual({ kind: "chief" });
  expect(fixAction(own("a", "fail", { by: "configure", tile: "nope" }))).toEqual({ kind: "chief" });
  const html = renderHealth(feed(own("c", "fail", { by: "configure", tile: "secrets" }), own("o", "fail", { by: "operator", remedy: "run-it" }), own("h", "warn")), null);
  for (const id of ["c", "o", "h"]) {
    const row = html.split('<div class="hrow br"').find((x) => x.includes(`data-id="${id}"`))!;
    expect([...row.matchAll(/class="fixact[ "]/g)].length).toBe(1);
  }
  expect(html).toContain('href="#/config?tile=secrets"');
});

// Q1 build note: "chief is on it" needs a live chief; with none it reads "for the chief · none running", never a button.
test("a chief row says whether a chief is running, and never carries a button", () => {
  const f = feed(own("h", "warn"));
  const row = (chief: unknown) => { const html = renderHealth(f, null, { chief }); return html.slice(html.indexOf('<div class="hrow br"')); };
  expect(row(true)).toContain("chief is on it");
  expect(row(false)).toContain("for the chief · none running");
  expect(row(false)).not.toContain("chief is on it");
  expect(row(undefined)).toContain("for the chief");
  expect(row(undefined)).not.toContain("chief is on it");
  for (const c of [true, false, undefined]) expect(row(c)).not.toMatch(/Open in Configure|Copy command/);
});

// Q1: alerts use the same three answers; a firing alert is the chief's, with no button.
test("a firing alert carries one who-fixes-it answer, the chief's", () => {
  const health = { bank: { state: "absent" }, monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: "HostDown", severity: "warn", summary: "box off" }] }, exporter: { state: "ok" } } };
  const html = renderHealth(feed(own("a", "ok")), health, { chief: true });
  const alert = html.slice(html.indexOf('<div class="alert"'));
  expect([...alert.matchAll(/class="fixact[ "]/g)].length).toBe(1);
  expect(alert).toContain("chief is on it");
});

// Frames 1, 4, 5, 8: four tiles, one panel open at a time; Checks opens by itself only when something is wrong (Q5).
test("one tile panel is open at a time, and Checks opens by itself only on a problem", () => {
  const h2s = (html: string) => [...html.matchAll(/<h2 [^>]*>([^<]*)</g)].map((m) => m[1]);
  const bad = feed(own("a", "fail"), r("cadence:qmd", "ok", { source: "cadence", scope: "shared" }), r("qmd-index", "ok", { bundle: "search", scope: "shared" }));
  expect(h2s(renderHealth(bad, null))).toEqual(["Is this project working right now?", "Checks", "Trends"]);
  const calm = feed(own("a", "ok"));
  expect(h2s(renderHealth(calm, null))).toEqual(["Is this project working right now?", "Trends"]);
  expect(renderHealth(calm, null)).toContain("nothing broken");
  expect(h2s(renderHealth(bad, null, { tile: "jobs" }))).toContain("Scheduled jobs");
  expect(h2s(renderHealth(bad, null, { tile: "jobs" }))).not.toContain("Checks");
  expect(renderHealth(bad, null, { tile: "jobs" })).toContain("cadence:qmd");
  expect(renderHealth(bad, null, { tile: "search" })).toContain("qmd-index");
  expect(renderHealth(bad, null, { tile: "usage" })).toContain("open Fleet");
  expect(renderHealth(bad, null, { tile: "usage" })).toMatch(/aria-expanded="true"[^>]*data-tile="usage"|data-tile="usage"[^>]*aria-expanded="true"/);
  expect(parseView("tile=usage").tile).toBe("usage");
  expect(parseView("tab=all").tile).toBe("checks");
  expect(parseView("row=x").tile).toBe("checks");
  expect(parseView("tile=bogus").tile).toBeNull();
});

test("another project's rows never offer this UI's Configure, nor its mode and alerts", () => {
  expect(fixAction(own("a", "fail", { by: "configure", tile: "tracker" }), true)).toEqual({ kind: "elsewhere", tile: "tracker" });
  const f = feed(own("a", "fail", { by: "configure", tile: "tracker" }));
  const health = { bank: { state: "absent" }, mode: { state: "ok", tracker: "jira", forge: "github", idRequired: "1" }, monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: "HostDown", severity: "page" }] }, exporter: { state: "ok" } } };
  const html = renderHealth(f, health, { project: "luna", foreign: true });
  expect(html).not.toContain("Open in Configure");
  expect(html).not.toContain("tracker=jira");
  expect(html).not.toContain("HostDown");
  expect(renderHealth(f, health, { project: "himmel" })).toContain("HostDown");
});

test("the all-projects view opens the who-fixes-it box and does not call a pending feed healthy", () => {
  const projects = { current: "himmel", projects: [{ name: "luna", current: false, checkedAt: "2026-10-30T01:00:00Z", counts: { project: { fail: 1, warn: 0 }, shared: { fail: 0, warn: 0 } }, broken: [own("lunabad", "fail", { by: "configure", tile: "tracker" })] }] };
  const html = renderHealth(feed(shared("s", "fail")), null, { mode: "all", projects, row: "lunabad" });
  expect([...html.matchAll(/class="who"/g)].length).toBe(1);
  expect(html).not.toContain("Open in Configure");
  const pending = renderHealth(null, null, { mode: "all", projects });
  expect(pending).not.toContain("Nothing shared is broken");
});

test("a firing alert shows under Shared in the all-projects view", () => {
  const health = { bank: { state: "absent" }, monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: "HostDown", severity: "page", summary: "box off" }] }, exporter: { state: "ok" } } };
  const html = renderHealth(feed(own("a", "ok")), health, { mode: "all", projects: { current: "himmel", projects: [] } });
  const shd = html.slice(html.indexOf('id="shared"'));
  expect(shd).toContain("HostDown");
  expect(shd).not.toContain("Nothing shared is broken");
});

test("the What is broken tab counts the firing alerts it lists", () => {
  const health = { bank: { state: "absent" }, monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: "HostDown", severity: "page", summary: "box off" }] }, exporter: { state: "ok" } } };
  const html = renderHealth(feed(own("a", "ok")), health, { tab: "broken" });
  expect(html).toContain("What is broken · 1");
});

test("the who-fixes-it box opens on the chosen row only", () => {
  const f = feed(own("a", "fail"), own("b", "fail"));
  expect([...renderHealth(f, null, { row: "a" }).matchAll(/class="who"/g)].length).toBe(1);
  expect(renderHealth(f, null).includes('class="who"')).toBe(false);
});

test("Every item checked lists all rows with a result, and a problem bundle opens by itself", () => {
  const f = feed(own("a", "ok"), own("b", "fail"), r("c", "ok", { scope: "project", bundle: "search" }));
  const html = renderHealth(f, null, { tab: "all" });
  const all = html.slice(html.indexOf('id="tab-all"'), html.indexOf('id="trends"'));
  expect([...all.matchAll(/<tr><td><span class="pill/g)].length).toBe(3);
  expect(all).toMatch(/<details class="bundle" open><summary><b>guards<\/b>/);
  expect(all).toMatch(/<details class="bundle"><summary><b>search<\/b>/);
  expect(html).toContain("Every item checked · 3");
  expect(html).toContain("What is broken · 1");
});

test("a shared failure shows once under Shared and is in neither project's own count", () => {
  const f = feed(shared("doctor:C12-gh-auth", "fail"), own("mine", "warn"));
  const projects = { current: "himmel", projects: [
    { name: "luna", current: false, checkedAt: "2026-10-30T01:00:00Z", counts: { project: { fail: 0, warn: 0 }, shared: { fail: 1, warn: 0 } }, broken: [] },
    { name: "himmel", current: true, checkedAt: "2026-10-31T01:00:00Z", counts: { project: { fail: 0, warn: 1 }, shared: { fail: 1, warn: 0 } }, broken: [own("mine", "warn")] },
    { name: "salus", current: false, checkedAt: null, counts: { project: { fail: 0, warn: 0 }, shared: { fail: 0, warn: 0 } }, broken: [] },
  ] };
  const html = renderHealth(f, null, { mode: "all", projects });
  expect(html.split('<div class="hrow br" data-id="doctor:C12-gh-auth"').length - 1).toBe(1);
  expect(html).toContain("Health · all my projects");
  const shd = html.slice(html.indexOf('id="shared"'), html.indexOf('class="box prj"'));
  expect(shd).toContain("doctor:C12-gh-auth");
  expect(html.indexOf('data-project="himmel"')).toBeLessThan(html.indexOf('data-project="luna"')); // worst first
  expect(html).toContain("not checked");
  expect(html).toContain('href="#/health?project=luna"');
});

test("the Usage panel points the worker list at Fleet", () => {
  const html = renderHealth(null, { bank: { state: "absent" }, monitoring: { state: "absent" } }, { fleetHref: "/agui/?t=x", tile: "usage" });
  expect(html).toContain("open Fleet");
  expect(html).toContain('href="/agui/?t=x"');
});
