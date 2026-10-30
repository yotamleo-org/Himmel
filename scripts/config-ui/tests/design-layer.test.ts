import { test, expect } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderHealth } from "../public/health.js";
import { renderToolHealth } from "../public/tool-health.js";
import { renderHeader, renderInventory, renderTriage } from "../public/render.js";

// The approved mockups take every colour from tokens.css and set text in the UI font, monospace only for
// data. These pin that the served pages (public/) do the same: a colour literal outside tokens.css, or a var() that no
// stylesheet defines, is drift from the shared layer.
const PUBLIC = join(import.meta.dir, "../public");
const read = (f: string) => readFileSync(f, "utf8");

// A colour written as a literal: hex, rgb()/hsl() and their alpha forms. In a .js file only inside a style context
// (a CSS property name on the same declaration), so "#123" in a sentence is not one.
const COLOUR = String.raw`#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab|lab|lch|hwb)\(`;
const LITERAL = new RegExp(COLOUR);
const JS_STYLE = new RegExp(String.raw`(?:color|background|fill|stroke|border|outline|shadow)[\w-]*\s*[:=]\s*["'\`]?[^;"'\`<>]*?(${COLOUR})`, "gi");

// Every off-token colour and undefined custom property in a public/ directory, as "file:line: what".
export function drift(dir: string): string[] {
  const out: string[] = [];
  const files = readdirSync(dir).filter((f) => /\.(css|js|html)$/.test(f) && f !== "tokens.css");
  const defined = new Set<string>();
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".css"))) {
    for (const m of read(join(dir, f)).matchAll(/(--[\w-]+)\s*:/g)) defined.add(m[1]);
  }
  for (const f of files) {
    const lines = read(join(dir, f)).split("\n");
    lines.forEach((line, i) => {
      const at = `${f}:${i + 1}`;
      if (f.endsWith(".css")) {
        const code = line.replace(/\/\*.*?\*\//g, "");
        if (LITERAL.test(code)) out.push(`${at}: colour literal ${code.match(LITERAL)![0]}`);
      } else {
        for (const m of line.matchAll(JS_STYLE)) out.push(`${at}: colour literal ${m[1]}`);
      }
      for (const m of line.matchAll(/var\((--[\w-]+)/g)) {
        // a property the page sets inline (style="--x:…") or via setProperty counts as defined in that file
        if (!defined.has(m[1]) && !new RegExp(`${m[1]}\\s*:|setProperty\\(["']${m[1]}`).test(lines.join("\n"))) out.push(`${at}: undefined ${m[1]}`);
      }
    });
  }
  return out;
}

test("no page stylesheet or module paints a colour outside tokens.css, and every var() is defined", () => {
  expect(drift(PUBLIC)).toEqual([]);
});

test("a planted off-token colour, in CSS or in a module's inline style, is drift", () => {
  const dir = mkdtempSync(join(tmpdir(), "design-layer-"));
  try {
    writeFileSync(join(dir, "tokens.css"), ":root{--ink:#13202B;--rule:#CDD6DE}");
    writeFileSync(join(dir, "app.css"), "body{color:var(--ink)}\n/* #fff in a comment is fine */");
    writeFileSync(join(dir, "page.js"), "const s = `pick #123 from the list`;");
    expect(drift(dir)).toEqual([]);
    writeFileSync(join(dir, "app.css"), "body{color:var(--ink)}\n.x{border:1px solid #ff0000}");
    expect(drift(dir)).toEqual(["app.css:2: colour literal #ff0000"]);
    writeFileSync(join(dir, "app.css"), "body{color:var(--inc)}");
    expect(drift(dir)).toEqual(["app.css:1: undefined --inc"]);
    writeFileSync(join(dir, "app.css"), "body{color:var(--ink)}");
    writeFileSync(join(dir, "page.js"), 'const s = `<i style="background:rgba(0,0,0,.2)">`;');
    expect(drift(dir)).toEqual(["page.js:1: colour literal rgba("]);
    writeFileSync(join(dir, "page.js"), 'const s = `<i style="color:oklch(60% .1 200)">`;');
    expect(drift(dir)).toEqual(["page.js:1: colour literal oklch("]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The mockups' body text is --font-ui at the token sizes; the build had set every page in 13 px monospace.
test("the page body is set in the UI font at a token size, not monospace", () => {
  const body = read(join(PUBLIC, "app.css")).match(/(?:^|\n)body\{([^}]*)\}/);
  expect(body, "app.css must style body").not.toBeNull();
  const font = body![1].match(/font:([^;]*)/)![1];
  expect(font).toMatch(/var\(--font-ui\)|var\(--sans\)/);
  expect(font).toMatch(/var\(--fs-[a-z0-9]+\)/);
});

// The shared components every page draws with (the mockups' card, page header, status pill, verdict strip and data
// table); a page that renders one gets the mockup look without a page-local copy.
test("app.css carries the mockups' shared components", () => {
  const css = read(join(PUBLIC, "app.css"));
  for (const sel of [".ph", ".box", ".pill", ".strip", ".data"]) expect(css, sel).toMatch(new RegExp(`(^|[\\s,}])\\${sel}[\\s{,.:]`));
  expect(css).toMatch(/(^|[\s,}])\.box[,{][^}]*border-radius:10px/);
  expect(css).toMatch(/(^|[\s,}])\.pill[,{][^}]*border-radius:999px/);
});

test("the shell keeps live version identity under the Himmel brand, not above the page", () => {
  const html = read(join(PUBLIC, "index.html"));
  expect(html).not.toMatch(/<body>\s*<header/);
  expect(html).toMatch(/<div class="brand">Himmel\s*<header class="top" id="top">[\s\S]*?<\/header>[\s\S]*?<\/div>/);
  const header = renderHeader({ himmel: { version: "1.1.3", describe: "v1.1.3", commit: "0123456789abcdef", checkout: "/test/himmel" } });
  expect(header).toContain('class="ver"');
  expect(header).toContain("himmel 1.1.3 · v1.1.3");
  expect(header).toContain("<summary>Build details</summary>");
  expect(header).toContain("/test/himmel");
});

test("the desktop rail can scroll to navigation below a short viewport", () => {
  const css = read(join(PUBLIC, "theme.css"));
  expect(css).toMatch(/\.rail\{[^}]*overflow-y:auto/);
});

test("header repaint preserves the open build details and summary keyboard focus", () => {
  const doc: any = { activeElement: null, querySelectorAll: () => [] };
  let details: any = { open: true };
  const makeSummary = (): any => ({ matches: () => false, focus() { doc.activeElement = this; } });
  let summary = makeSummary();
  doc.activeElement = summary;
  const top = { set innerHTML(_html: string) { details = { open: false }; summary = makeSummary(); } };
  const elements: Record<string, unknown> = { "#top": top, "#main": {}, "#nav": {}, "#where": {} };
  const $ = (selector: string) => selector === "#top details" ? details : selector === "#top summary" ? summary : elements[selector];
  const paint = read(join(PUBLIC, "app.js")).match(/function paint\(\) \{[\s\S]*?\n\}/)![0];
  new Function("document", "$", "currentPage", "feed", "unmountPage", "renderHeader", "renderPages", "location", `${paint}\npaint();`)(
    doc, $, { render: () => "" }, { himmel: { version: "1.1.3", describe: "v1.1.3", commit: "0123456789abcdef" }, target: { scope: "user" } }, null, renderHeader, () => {}, { host: "localhost" },
  );
  expect(details.open).toBe(true);
  expect(doc.activeElement).toBe(summary);
});

test("Health Triage and Inventory use boxed sections, UI-font rows and status pills", () => {
  const rows = ["fail", "warn", "ok", "off", "info"].map((health) => ({
    id: `item-${health}`, source: "item", health, control: { class: "display-only" },
    installed: { state: "present", detail: "probe detail" },
  }));
  const state = { open: new Set(), bundles: {}, filt: { q: "item" } };
  const triage = renderTriage({ rows }, state);
  const inventory = renderInventory({ rows }, state);
  for (const [id, html] of [["triage", triage], ["inventory", inventory]]) {
    expect(html, id).toMatch(new RegExp(`<section id="${id}"[^>]*class="box"`));
    expect(html, id).toContain('class="st pill fail"');
    expect(html, id).toContain('class="st pill warn"');
  }
  for (const health of ["ok", "off", "info"]) expect(inventory).toContain(`class="st pill ${health}"`);
  const css = read(join(PUBLIC, "app.css"));
  expect(css).toMatch(/\.box \.row-head[^}]*font:[^;]*var\(--font-ui\)/);
  expect(css).toMatch(/\.box \.bhead[^}]*font:[^;]*var\(--font-ui\)/);
});

// The pages moved onto the layer draw with it, not with a page-local look.
test("Health and Tool health render the page header and boxed sections", () => {
  const health = renderHealth(null, null);
  for (const cls of ['class="ph"', 'class="box"', "strip v-"]) expect(health, `health ${cls}`).toContain(cls);
  const tools = renderToolHealth(null);
  for (const cls of ['class="ph"', 'class="box"', 'class="fields"']) expect(tools, `tool health ${cls}`).toContain(cls);
});
