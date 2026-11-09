import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { drift } from "./design-layer.test";
import { renderBoard, renderRoadmap, renderKanban } from "../public/roadmap.js";

const PUBLIC = join(import.meta.dir, "../public");
const data = {
  state: "ok", mirror: { count: 1, newest: "2026-10-29" }, cur: 0, next: -1,
  versions: [{ n: "v1.1.3", rel: false, open: [], counts: { todo: 0, prog: 1, rev: 0, ci: 0, done: 0, wont: 0 } }],
  themes: ["Visibility"], planThemes: ["(no theme)"],
  tickets: [{ k: 8141, t: "Shared design layer", s: "In Progress", b: "prog", v: 0, theme: 0, pt: 0, drift: 1, pv: "v1.1.2", worker: null }],
  drift: { now: { drift: 1, unplanned: 0, unthemed: 0 }, trend: [] }, plan: { state: "ok" },
  sync: [{ k: 8141, marker: "LIVE", why: "Worker active", argv: ["comment", "HIMMEL-8141", "LIVE"] }],
  librarian: { staleInProgress: [], drift: [], unthemed: [], releasedOpen: [], duplicates: [] },
};

// Removing the shared classes would restore the old unboxed text dump on any of these routes.
for (const [name, render, input, ui, title] of [
  ["Roadmap", renderRoadmap, data, {}, "Roadmap"],
  ["version board", renderRoadmap, data, { ver: "v1.1.3" }, "v1.1.3"],
  ["Kanban", renderKanban, data, {}, "Kanban"],
  ["GitHub Roadmap", renderRoadmap, { ...data, source: "github" }, {}, "Roadmap"],
  ["GitHub Kanban", renderKanban, { ...data, source: "github" }, {}, "Kanban"],
  ["Board", renderBoard, data, {}, "Board"],
  ["Board Tidy up", renderBoard, data, { tab: "tidy" }, "Board"],
  ["GitHub Board", renderBoard, { ...data, source: "github" }, {}, "Board"],
] as const) {
  test(`${name} renders a shared page header and boxed section`, () => {
    const html = render(input, ui);
    expect(html).toMatch(/<header class="ph">/);
    expect(html).toContain(`<h1>${title}</h1>`);
    expect(html).toMatch(name === "Board" || name === "GitHub Board" ? /<section[^>]*class="cp[ "]/ : /<section[^>]*class="box"/);
  });
}

test("board statuses and drift use shared pills without losing write controls", () => {
  const html = renderKanban(data, { writes: true });
  expect(html).toMatch(/class="[^"]*\bpill\b[^"]*">In Progress<\/span>/);
  expect(html).toMatch(/class="[^"]*\bpill\b[^"]*">drift<\/span>/);
  expect(html).toContain('draggable="true" data-rm-card="8141"');
  expect(html).toContain('data-rm-theme-key="8141"');
  expect(html).toContain('data-rm-drop="prog"');
});

test("Board lanes use the Chains tab's status chips and keep the write controls; its version chips read like the Chains tab's", () => {
  const html = renderBoard(data, { writes: true }, null);
  expect(html).toMatch(/class="[^"]*\btk\b[^"]*">In Progress<\/span>/);
  expect(html).toMatch(/<a class="vc sel"[^>]*><b>v1\.1\.3<\/b> <small>running<\/small>/);
  expect(html).toContain('draggable="true" data-rm-card="8141"');
  expect(html).toContain('data-rm-drop="prog"');
  expect(renderBoard(data, { tab: "tidy" }, null)).toMatch(/<table class="[^"]*\bdata\b/);
});

test("Roadmap sync uses the shared data table and releases use status pills", () => {
  const html = renderRoadmap(data, {});
  expect(html).toMatch(/<table class="[^"]*\bdata\b/);
  expect(html).toMatch(/class="[^"]*\bpill\b[^"]*">running<\/span>/);
  expect(html).toContain('data-act="copy"');
});

test("loading and unavailable states keep the page identity", () => {
  for (const [render, title] of [[renderRoadmap, "Roadmap"], [renderKanban, "Kanban"], [renderBoard, "Board"]] as const) {
    for (const input of [null, { state: "absent", reason: "No mirror" }]) {
      expect(render(input, {})).toContain(`<h1>${title}</h1>`);
    }
  }
});

test("roadmap spacing uses tokens and the page introduces no colour or variable drift", () => {
  const css = readFileSync(join(PUBLIC, "app.css"), "utf8");
  const rules = [...css.matchAll(/\.rm-[^{]+\{([^}]+)\}/g)].map((m) => m[1]);
  expect(rules.length).toBeGreaterThan(0);
  for (const rule of rules) {
    for (const declaration of rule.split(";")) {
      if (/^(?:gap|padding|margin(?:-[\w]+)?):/.test(declaration)) expect(declaration).not.toMatch(/\dpx/);
    }
  }
  expect(drift(PUBLIC)).toEqual([]);
});

// ---- the dense Board's style block ----
const appCss = () => readFileSync(join(PUBLIC, "app.css"), "utf8");
// the body of the first rule whose selector list is exactly `sel` (a later @media override of the same selector does not count)
const firstRule = (sel: string) => new RegExp(`(?:^|[}{])\\s*${sel.replace(/[.[\]()]/g, "\\$&")}\\s*\\{([^}]*)\\}`).exec(appCss())?.[1] ?? "";

test("the board has four columns, with a narrow lane after them", () => {
  expect(firstRule(".rm-board")).toContain("repeat(4");
});

test("a card title clamps to two lines (three on a phone), and the shared bubble shows on hover and on focus, off at 760 px or with no hover", () => {
  const css = appCss();
  expect(firstRule(".rm-title .rm-clip")).toContain("-webkit-line-clamp:2");
  expect(css).toMatch(/@media\s*\(max-width:760px\)\s*\{[^@]*\.rm-title \.rm-clip\{[^}]*-webkit-line-clamp:3/);
  expect(css).toContain("[data-tip]:hover::after");
  expect(css).toMatch(/:focus-visible[^{]*::after/);
  expect(css).toMatch(/@media\s*\(max-width:760px\)\s*,\s*\(hover:none\)\s*\{[^}]*::after[^}]*display:none/);
});
