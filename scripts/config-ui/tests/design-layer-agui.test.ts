import { test, expect } from "bun:test";
import { copyFileSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { drift } from "./design-layer.test";

const SRC = join(import.meta.dir, "../agui-web/src");
const PUBLIC = join(import.meta.dir, "../public");
const css = () => readFileSync(join(SRC, "styles.css"), "utf8");
const rule = (selector: string) => css().replaceAll("}", "}\n").split(`\n${selector}{`)[1]?.split("}")[0] ?? "";

// A page-local colour or an undefined token must fail even though Fleet bundles its CSS separately.
test("the AG-UI stylesheet uses only the shared colours and defined custom properties", () => {
  const dir = mkdtempSync(join(tmpdir(), "design-layer-agui-"));
  try {
    for (const name of ["theme.css", "tokens.css"]) copyFileSync(join(PUBLIC, name), join(dir, name));
    copyFileSync(join(SRC, "styles.css"), join(dir, "styles.css"));
    // React sets per-agent colours and nesting depth inline; include only properties the renderers actually set.
    const inline = readdirSync(SRC).filter((f) => f.endsWith(".tsx"))
      .flatMap((f) => [...readFileSync(join(SRC, f), "utf8").matchAll(/\["(--[\w-]+)" as string\]\s*:/g)])
      .map((m) => `${m[1]}:initial;`).join("");
    writeFileSync(join(dir, "inline.css"), `:root{${inline}}`);
    expect(drift(dir)).toEqual([]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("every agent name colour meets normal-text contrast in both shared themes", () => {
  const tokens = readFileSync(join(PUBLIC, "tokens.css"), "utf8");
  const palette = [...css().matchAll(/--ag[0-5]:var\(--([\w-]+)\)/g)];
  expect(palette).toHaveLength(6);
  const luminance = (theme: string, token: string) => {
    const hex = tokens.match(new RegExp(`--${theme}-${token}:#([0-9a-fA-F]{6})\\b`))?.[1];
    expect(hex, `${theme}-${token}`).toBeDefined();
    const rgb = hex!.match(/../g)!.map((channel) => {
      const c = parseInt(channel, 16) / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
  };
  for (const theme of ["l", "d"]) {
    const bg = luminance(theme, "bg");
    for (const [agent, token] of palette) {
      const fg = luminance(theme, token);
      expect((Math.max(fg, bg) + 0.05) / (Math.min(fg, bg) + 0.05), `${theme} ${agent}`).toBeGreaterThanOrEqual(4.5);
    }
  }
});

test("Fleet prose uses the UI font at token sizes, with monospace kept for session data and tables", () => {
  expect(rule("body")).toMatch(/font:var\(--fs-[a-z0-9]+\)\/[^;]+var\(--(?:font-ui|sans)\)/);
  for (const selector of [".fleet-sec>summary", ".fleet-chief h2", ".fleet-menu", ".fleet-search", ".fleet-chip-btn", ".fleet-clear", ".fleet-more-btn"]) {
    expect(rule(selector), selector).toMatch(/font:[^;]*var\(--(?:font-ui|sans)\)/);
    expect(rule(selector), selector).toMatch(/var\(--fs-[a-z0-9]+\)/);
  }
  for (const selector of [".fleet-name", ".fleet-procs", ".fleet-graph,.fleet-usage"]) {
    expect(rule(selector), selector).toMatch(/font:[^;]*var\(--(?:font-mono|mono)\)/);
  }
});

test("Fleet cards and status pills carry the shared component shape and soft status colours", () => {
  expect(rule(".fleet-row")).toContain("border-radius:10px");
  expect(rule(".fleet-row")).toContain("border:1px solid var(--rule)");
  for (const selector of [".fleet-kind", ".fleet-hops-badge", ".fleet-chip", ".fleet-chip-btn", ".state"]) {
    expect(rule(selector), selector).toContain("border-radius:999px");
  }
  for (const [state, token] of [["running", "ship"], ["waiting", "accent"], ["idle", "beta"], ["blocked", "crit"]]) {
    expect(rule(`.state.${state}`), state).toContain(`background:var(--${token}-soft)`);
  }
});
