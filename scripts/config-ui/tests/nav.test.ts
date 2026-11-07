import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DOCS_URL, PAGES, fleetDot, healthDot, navLinks, pageHref, parseLanding } from "../public/nav.js";
import * as nav from "../public/nav.js";
import { LANDING, launchUrl, startServer } from "../server";

// the config chief and the AG-UI pages are one app with one rail. These pin the page list, the
// token-in-fragment rule, the landing switch and the status dot.
const TOKEN = "a".repeat(64);
const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const BASE = "http://127.0.0.1:4242";

// Only a fragment carries the token: never the path or the query, so it never reaches a request line.
const tokenOnlyInFragment = (href: string) => {
  const u = new URL(href, BASE);
  return !u.pathname.includes(TOKEN) && !u.search.includes(TOKEN);
};

test("the rail lists Fleet first, then Health, Tool health and one Configure entry, on every page, plus Run when a run is open", () => {
  const rail = ["Shift", "Morning report", "Fleet", "Health", "Tool health", "Configure", "Board", "Workflow", "Cost", "Docs"];
  expect(navLinks({ here: "console", token: TOKEN, current: "config" }).map((l) => l.label)).toEqual(rail);
  expect(navLinks({ here: "agui", token: TOKEN, current: "fleet" }).map((l) => l.label)).toEqual(rail);
  expect(navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN }).map((l) => l.label)).toEqual([...rail.slice(0, -1), "Run", "Docs"]);
});

test("the rail has one Board entry and no separate Roadmap or Kanban entry", () => {
  for (const here of ["console", "agui"] as const) {
    const links = navLinks({ here, token: TOKEN, current: "board" });
    expect(links.filter((l) => l.id === "board").map((l) => [l.label, l.current])).toEqual([["Board", true]]);
    expect(links.map((l) => l.label)).not.toContain("Roadmap");
    expect(links.map((l) => l.label)).not.toContain("Kanban");
  }
  expect(PAGES.map((p) => p.id)).not.toContain("roadmap");
  expect(PAGES.map((p) => p.id)).not.toContain("kanban");
  // with no tracker the UI can read, the Board is not offered either
  expect(navLinks({ here: "console", token: TOKEN, current: "config", sources: [] }).map((l) => l.id)).not.toContain("board");
});

test("the old Roadmap and Kanban landings from the AG-UI rail resolve to the Board page", () => {
  expect(parseLanding(`#t=${TOKEN}&page=roadmap`)).toEqual({ token: TOKEN, page: "board" });
  expect(parseLanding(`#t=${TOKEN}&page=kanban`)).toEqual({ token: TOKEN, page: "board", q: "v=all" });
  expect(parseLanding(`#t=${TOKEN}&page=board`)).toEqual({ token: TOKEN, page: "board" });
});

test("Settings and Setup are gone from the rail: Configure is the one entry, page id config", () => {
  const ids = navLinks({ here: "console", token: TOKEN, current: "config" }).map((l) => l.id);
  expect(ids.filter((i) => i === "config")).toHaveLength(1);
  expect(ids).not.toContain("setup");
  expect(PAGES.map((p) => p.label)).not.toContain("Settings");
  expect(PAGES.map((p) => p.label)).not.toContain("Setup");
});

test("the old Setup landing and page=configure resolve to Configure, Setup with the Secrets tile picked", () => {
  expect(parseLanding(`#t=${TOKEN}&page=setup`)).toEqual({ token: TOKEN, page: "config", tile: "secrets" });
  expect(parseLanding(`#t=${TOKEN}&page=configure`)).toEqual({ token: TOKEN, page: "config" });
  expect(parseLanding(`#t=${TOKEN}&page=config`)).toEqual({ token: TOKEN, page: "config" });
});

// One no-op for every name app.js imports (its local binding: `renderConfigure as render` is `render`). The import lines are
// stripped before app.js runs, so a name missing here is a free global. app-import-stubs.test.ts reads this block and fails,
// naming the import, when one is missing.
const APP_IMPORT_STUBS: Record<string, unknown> = {
  renderInventory: () => "", renderTriage: () => "", renderHeader: () => "", renderProbe: () => "", reviewGateDraft: () => [],
  renderHealth: () => "", verdict: () => ({ cls: "off", word: "No data" }), parseView: () => ({ mode: "project", project: null, tab: "broken", row: null }), projectVerdict: () => ({ word: "All clear" }), chiefLiveFor: () => undefined,
  renderToolHealth: () => "", toolHealthLoader: () => ({}), toolHealthHref: () => "",
  boardRefreshDue: () => false, driftSince: () => null, renderBoard: () => "", pinsFromSearch: () => [], searchWithPins: () => "", togglePin: () => ({ pins: [], msg: "" }),
  renderWorkflow: () => "", parseWorkflowRoute: () => null, renderCost: () => "",
  apiRolesDraft: () => null, render: () => "",
  renderShift: () => "",
  renderReport: () => "", reportBar: () => "",
  fleetDot: () => ({ cls: "off", title: "" }), healthDot: () => ({ cls: "off", title: "" }), navLinks: () => [], parseLanding: () => null, railMarkup: () => "",
};

// app.js is a browser module; run it against stubs (as slow.test.ts does) and read where each hash lands.
async function landedOn(hash: string) {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8").replace(/^import .*$/gm, "");
  const urls: string[] = [];
  const painted: unknown[] = [];
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  const g = globalThis as Record<string, unknown>;
  const names = [...Object.keys(APP_IMPORT_STUBS), "document", "location", "history", "fetch", "addEventListener"];
  const saved = Object.fromEntries(names.map((n) => [n, g[n]]));
  Object.assign(g, {
    ...APP_IMPORT_STUBS,
    render: (_f: unknown, c: unknown) => { painted.push(c); return ""; },
    document: { querySelector: el, querySelectorAll: () => [], getElementById: el, activeElement: null, addEventListener() {} },
    location: { hash, pathname: "/", search: "", host: "x" }, history: { replaceState: (_a: unknown, _b: unknown, u: string) => urls.push(u) },
    fetch: () => new Promise(() => {}), addEventListener() {},
  });
  try { new Function(src)(); } finally { for (const n of names) { if (saved[n] === undefined) delete g[n]; else g[n] = saved[n]; } }
  return { urls, tile: (painted.at(-1) as { tile?: string } | undefined)?.tile ?? null };
}

test("the old #/setup and #/configure routes land on Configure, #/setup with the Secrets tile open", async () => {
  expect(await landedOn("#/setup")).toEqual({ urls: ["/#/config?tile=secrets"], tile: "secrets" });
  expect(await landedOn("#/configure")).toEqual({ urls: ["/#/config"], tile: null });
  expect(await landedOn("#/config?tile=tracker")).toEqual({ urls: [], tile: "tracker" });
  expect(await landedOn("#/health")).toEqual({ urls: [], tile: null });
  expect((await landedOn("#/config?tile=__proto__")).tile).toBeNull(); // an unknown tile id opens none, and Configure still paints
  expect((await landedOn("#/config?tile=nope")).tile).toBeNull();
});

test("the old #/roadmap, #/roadmap/<version> and #/kanban routes land on the Board page", async () => {
  expect(await landedOn("#/roadmap")).toMatchObject({ urls: ["/#/board"] });
  expect(await landedOn("#/roadmap/v1.1.3")).toMatchObject({ urls: ["/#/board?v=v1.1.3"] });
  expect(await landedOn("#/kanban")).toMatchObject({ urls: ["/#/board?v=all"] });
  expect(await landedOn("#/board?v=all&tab=tidy")).toMatchObject({ urls: [] }); // the Board route itself is not rewritten
});

test("from the AG-UI pages the Configure link carries the token in the fragment", () => {
  expect(navLinks({ here: "agui", token: TOKEN, current: "fleet" }).find((l) => l.id === "config")!.href).toBe(`/#t=${TOKEN}&page=config`);
});

test("the rail ends with Docs, an external link to DOCS_URL that is never the current page and carries no token", () => {
  for (const here of ["console", "agui"] as const) {
    const docs = navLinks({ here, token: TOKEN, current: "config" }).at(-1)!;
    expect(docs).toMatchObject({ id: "docs", label: "Docs", href: DOCS_URL, current: false, external: true });
    expect(docs.href).not.toContain(TOKEN);
  }
});

test("exactly the current page is marked current", () => {
  const links = navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN });
  expect(links.filter((l) => l.current).map((l) => l.id)).toEqual(["run"]);
});

test("from the console, its own pages are in-document routes and the AG-UI pages carry the token in the fragment", () => {
  const by = Object.fromEntries(navLinks({ here: "console", token: TOKEN, current: "config" }).map((l) => [l.id, l.href]));
  expect(by.config).toBe("#/config");
  expect(by.health).toBe("#/health");
  expect(by.fleet).toBe(`/agui/#t=${TOKEN}`);
});

test("from the AG-UI page, every link carries the token in the fragment and nowhere else", () => {
  const links = navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN });
  const by = Object.fromEntries(links.map((l) => [l.id, l.href]));
  expect(by.config).toBe(`/#t=${TOKEN}&page=config`);
  expect(by.health).toBe(`/#t=${TOKEN}&page=health`);
  expect(by.fleet).toBe(`/agui/#t=${TOKEN}`);
  expect(by.run).toBe(`/agui/#t=${TOKEN}&run=${RUN}`);
  for (const l of links) expect(tokenOnlyInFragment(l.href)).toBe(true);
  expect(pageHref({ here: "agui", token: TOKEN, id: "health" })).toBe(by.health);
});

test("the console reads its landing fragment: the token and the page, never an unknown page", () => {
  expect(parseLanding(`#t=${TOKEN}`)).toEqual({ token: TOKEN, page: "config" });
  expect(parseLanding(`#t=${TOKEN}&page=health`)).toEqual({ token: TOKEN, page: "health" });
  expect(parseLanding(`#t=${TOKEN}&page=fleet`)).toEqual({ token: TOKEN, page: "config" }); // fleet is not a console route
  expect(parseLanding(`#t=${TOKEN}&page=nope`)).toEqual({ token: TOKEN, page: "config" });
  expect(parseLanding("#/health")).toBeNull();
  expect(parseLanding("#t=not-hex")).toBeNull();
});

test("the Fleet status dot: ok, warn when degraded, fail when the fleet cannot be read", () => {
  expect(fleetDot({ census: "ok" }, null).cls).toBe("ok");
  expect(fleetDot({ census: "degraded" }, null).cls).toBe("warn");
  expect(fleetDot({ census: "unavailable" }, null).cls).toBe("fail");
  expect(fleetDot(null, "the token was refused").cls).toBe("fail");
  expect(fleetDot(null, null).cls).toBe("off"); // not read yet
  for (const d of [fleetDot({ census: "ok" }, null), fleetDot(null, "x")]) expect(d.title.length).toBeGreaterThan(0);
});

test("the Health status dot takes the verdict's ok, warn and fail, and is off until a verdict exists", () => {
  expect(healthDot({ cls: "ok", word: "All clear" }).cls).toBe("ok");
  expect(healthDot({ cls: "warn", word: "Needs a look" }).cls).toBe("warn");
  expect(healthDot({ cls: "fail", word: "Act now" }).cls).toBe("fail");
  expect(healthDot({ cls: "off", word: "No data" }).cls).toBe("off");
  expect(healthDot({ cls: "fail", word: "Act now" }).title).toBe("health: Act now");
});

test("himmelctl ui prints ONE URL: the landing switch picks the fleet or the console", () => {
  expect(["fleet", "config"]).toContain(LANDING);
  expect(launchUrl(BASE, TOKEN, { landing: "fleet", built: true })).toBe(`${BASE}/agui/#t=${TOKEN}`);
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: true })).toBe(`${BASE}/#t=${TOKEN}`);
  // An unbuilt page cannot be the landing: the chief, which links to the fleet's build steps.
  expect(launchUrl(BASE, TOKEN, { landing: "fleet", built: false })).toBe(`${BASE}/#t=${TOKEN}`);
  // --agui asks for the AG-UI page outright: the fleet, or one run.
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: true, agui: "fleet" })).toBe(`${BASE}/agui/#t=${TOKEN}`);
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: false, agui: RUN })).toBe(`${BASE}/agui/#t=${TOKEN}&run=${RUN}`);
});

// The console rail is the same on every page; page controls sit in the page bar, never the rail.
const railIds = (html: string) => [...html.matchAll(/data-page="([^"]+)"/g)].map((m) => m[1]);
const railOf = (current: string) => (nav as any).railMarkup({ token: TOKEN, current, dots: {}, waiting: 0 }) as string;

test("the console rail markup holds the same child ids on Health as on Board, and no picker", () => {
  const health = railOf("health"), board = railOf("board");
  expect(railIds(health)).toEqual(railIds(board));
  expect(railIds(health).length).toBeGreaterThan(0);
  expect(health).not.toContain("picker");
  expect(health).not.toContain("<select");
});

test("railItems(p) is the page ids plus the docs link for every page", () => {
  for (const p of PAGES) expect((nav as any).railItems(p.id)).toEqual([...PAGES.map((x) => x.id), "docs"]);
  expect((nav as any).railItems("run")).toEqual([...PAGES.map((x) => x.id), "run", "docs"]);
  for (const p of PAGES) expect(railIds(railOf(p.id))).toEqual((nav as any).railItems(p.id));
});

let stops: (() => void)[] = [];
afterEach(() => { for (const f of stops) f(); stops = []; });

test("the shared rail files are served like every other page: same headers, no token", async () => {
  const home = mkdtempSync(join(tmpdir(), "nav-home-"));
  const s = startServer({ onIdle: () => {}, port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } });
  stops.push(() => { s.stop(); rmSync(home, { recursive: true, force: true }); });
  for (const [path, type] of [["/nav.js", "application/javascript; charset=utf-8"], ["/theme.css", "text/css; charset=utf-8"], ["/tokens.css", "text/css; charset=utf-8"]]) {
    const r = await fetch(`http://127.0.0.1:${s.port}${path}`);
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toBe(type);
    expect(r.headers.get("content-security-policy")).toBe("default-src 'self'");
    expect(r.headers.get("x-frame-options")).toBe("DENY");
  }
});
