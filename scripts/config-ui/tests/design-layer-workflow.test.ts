import { test, expect } from "bun:test";
import { join } from "node:path";
import { renderWorkflow } from "../public/workflow.js";
import { drift } from "./design-layer.test";

// Removing the shared header or moving the graph outside its box loses the mockup's type and frame.
test("Workflow renders the shared page header and boxes the existing graph mount", async () => {
  let title = "", headers = 0, descriptions = 0, graphs = 0;
  await new HTMLRewriter()
    .on(".ph h1", { element() { headers++; }, text(t) { title += t.text; } })
    .on(".ph p", { element() { descriptions++; } })
    .on('section.box #workflow-graph[aria-label="Development graph"]', { element() { graphs++; } })
    .transform(new Response(renderWorkflow())).text();
  expect(headers).toBe(1);
  expect(title).toBe("Workflow");
  expect(descriptions).toBe(1);
  expect(graphs).toBe(1);
  expect(drift(join(import.meta.dir, "../public")).filter((d) => d.startsWith("workflow.js:"))).toEqual([]);
});
