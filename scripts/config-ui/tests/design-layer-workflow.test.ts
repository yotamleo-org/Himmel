import { test, expect } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderWorkflow } from "../public/workflow.js";
import { readPhaseStats } from "../phase-stats";
import { drift } from "./design-layer.test";

const MODEL = JSON.parse(readFileSync(join(import.meta.dir, "../../../docs/guide/dev-graph/graph.json"), "utf8"));

// Removing the shared header or the two tabs loses the mockup's type and frame; a colour off tokens.css is drift.
test("Workflow renders the shared page header, the Workflow and Eval tabs, and the story map", async () => {
  let title = "", headers = 0, descriptions = 0, tabs = 0, current = "", phases = 0;
  await new HTMLRewriter()
    .on(".ph h1", { element() { headers++; }, text(t) { title += t.text; } })
    .on(".ph p", { element() { descriptions++; } })
    .on("nav.wf-tabs a", { element(e) { tabs++; if (e.getAttribute("aria-current") === "page") current = e.getAttribute("href") || ""; } })
    .on("ol.wf-map > li.wf-ph", { element() { phases++; } })
    .transform(new Response(renderWorkflow(MODEL, { tab: "workflow" }, null))).text();
  expect(headers).toBe(1);
  expect(title).toBe("Workflow");
  expect(descriptions).toBe(1);
  expect(tabs).toBe(2);
  expect(current).toBe("#/workflow");
  expect(phases).toBe(7);
  expect(drift(join(import.meta.dir, "../public")).filter((d) => /^(workflow\.js|app\.css):/.test(d))).toEqual([]);
});

// The Eval tab's sparklines and Trends charts are drawn in SVG on the shared layer: strokes and text take currentColor
// (the page's own ink token), never a colour attribute or a style. Seeded through phase-stats.ts's own reader.
test("the Eval tab's sparklines and trend charts paint only currentColor and carry no inline colour", () => {
  const dir = mkdtempSync(join(tmpdir(), "workflow-eval-design-"));
  try {
    const state = join(dir, "state"), rounds = join(dir, "rounds");
    mkdirSync(state); mkdirSync(join(rounds, "fix"), { recursive: true });
    const at = (day: number, min: number) => new Date(Date.UTC(2026, 9, day, 8, min)).toISOString();
    const rows = [1, 2, 3].flatMap((i) => ["live", "pr-open", "ci-start", "merge", "wrapped"].map((event, k) => JSON.stringify({ ts: at(24 + i * 2, k * 20), event, key: `HIMMEL-${i}`, pr: String(i) })));
    writeFileSync(join(state, "status-events.jsonl"), rows.join("\n") + "\n");
    const f = join(rounds, "fix/himmel-1-x.round");
    writeFileSync(f, "3\n");
    utimesSync(f, Date.UTC(2026, 9, 27, 12) / 1000, Date.UTC(2026, 9, 27, 12) / 1000);
    const html = renderWorkflow(MODEL, { tab: "eval" }, readPhaseStats({ TICKET_STATUS_STATE_DIR: state }, rounds, Date.parse("2026-11-01T09:30:00Z")));
    const svgs = html.match(/<svg class="wf-(?:sp|trend|ch)"[\s\S]*?<\/svg>/g) || [];
    expect(svgs).toHaveLength(12);
    for (const svg of svgs) {
      expect(svg).not.toMatch(/style=|#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch)\(/);
      expect(svg).toContain('stroke="currentColor"');
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
