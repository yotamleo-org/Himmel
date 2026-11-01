import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderWorkflow } from "../public/workflow.js";
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
