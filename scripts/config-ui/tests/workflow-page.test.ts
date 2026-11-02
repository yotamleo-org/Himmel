// The Workflow tab drawn from the one workflow model (docs/guide/dev-graph/graph.json): 45 steps in 7 phases, numbered in
// order; every move once, on its own step's card; plain words only (no ticket ID, file path, script name or WAKE key);
// the v7 step names; the deep links; the real state of each "This version" line; and the Eval tab's per-phase numbers.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderWorkflow, parseWorkflowRoute } from "../public/workflow.js";

const MODEL = JSON.parse(readFileSync(join(import.meta.dir, "../../../docs/guide/dev-graph/graph.json"), "utf8"));
const FORBIDDEN = /HIMMEL-\d+|~\/|\b[\w.-]+\.(sh|py|jsonl?|md|ya?ml|js|ts|mjs)\b|scripts\/|docs\/|\.github|\.claude|graph\.json|WAKE/;

// the v7 name table (design spec frame "Step names"), in step order
const NAMES: [string, string][] = [
  ["s.idea", "An idea arrives"], ["p.grill", "Grill the idea"], ["s.minerva", "Write a checked spec"], ["p.write", "Fill the ticket"],
  ["s.cost", "Count what the start cost"], ["p.plan", "Write and check the plan"], ["p.estimate", "Estimate the effort"],
  ["p.design", "Draw the design"], ["p.approve", "You approve the design"], ["c.start", "Start the chief"],
  ["c.wait", "Wait for the next event"], ["c.tick", "Read the fleet's state"], ["c.pick", "Pick the next tickets"],
  ["c.brief", "Write the brief and worktree"], ["c.arm", "Start a worker"], ["l.ticket", "Read the ticket"], ["o.ruling", "Your decision"],
  ["c.next", "Shift handoff to a new chief"], ["l.live", "Claim the work"], ["l.red", "Write a failing test"], ["l.commit", "Commit"],
  ["g.prepush", "Checks on every push"], ["g.marker", "Check whether the push needs a review"], ["l.prcheck", "Automated review round"],
  ["g.cap", "Review round limit"], ["c.grant", "Chief grants one more round"], ["l.pr", "Open the pull request"],
  ["g.coderabbit", "CodeRabbit review"], ["g.reviewgate", "Required reviewers passed"], ["g.release", "Start the full CI run"],
  ["g.ci", "Wait for CI"], ["l.cired", "Fix a red CI run"], ["l.ready", "Report ready"], ["c.verify", "Check the pull request is ready"],
  ["j.judge", "A judge reviews"], ["j.verdict", "Judge's verdict"], ["c.verdictgo", "Turn the verdict into approval"],
  ["c.go", "Approve this commit"], ["l.merge", "Merge"], ["g.mergehook", "Guard on a direct merge"], ["l.close", "Close the ticket, if done"],
  ["l.wrap", "Worker wraps up"], ["c.legevent", "Chief reads the last report"], ["c.residual", "File the follow-ups"],
  ["c.wrapmerged", "Chief closes out the worker"],
];

// HTMLRewriter hands text over as written, entities and all
const ENT: Record<string, string> = { "#39": "'", quot: '"', lt: "<", gt: ">", amp: "&" };
const un = (s: string) => s.replace(/&(#39|quot|lt|gt|amp);/g, (_, k: string) => ENT[k]);
type Card = { id: string; num: string; name: string; edges: string[]; changes: string[]; cls: string; panel: string };
async function parse(html: string) {
  const cards: Card[] = [], panels: { id: string; hidden: boolean }[] = [];
  const text: string[] = [];
  let card: Card | null = null, panel = "", inName = false, inNum = false, chg: string | null = null;
  await new HTMLRewriter()
    .on("section.wf-panel", { element(e) { panel = e.getAttribute("data-ph") || ""; panels.push({ id: panel, hidden: e.hasAttribute("hidden") }); } })
    .on("li.wf-step", { element(e) { card = { id: (e.getAttribute("id") || "").replace(/^s-/, ""), num: "", name: "", edges: [], changes: [], cls: e.getAttribute("class") || "", panel }; cards.push(card); } })
    .on("li.wf-step .wf-num", { element(e) { inNum = true; e.onEndTag(() => { inNum = false; }); }, text(t) { if (inNum && card) card.num += t.text; } })
    .on("li.wf-step .wf-sn", { element(e) { inName = true; e.onEndTag(() => { inName = false; }); }, text(t) { if (inName && card) card.name += t.text; } })
    .on("li.wf-step li[data-edge]", { element(e) { card!.edges.push(e.getAttribute("data-edge")!); } })
    .on("li.wf-step .wf-chg", { element(e) { chg = ""; e.onEndTag(() => { card!.changes.push(chg!); chg = null; }); }, text(t) { if (chg !== null) chg += t.text; } })
    .on("*", {
      element(e) { for (const a of ["title", "aria-label", "alt"]) { const v = e.getAttribute(a); if (v) text.push(v); } },
      text(t) { if (t.text.trim()) text.push(t.text); },
    })
    .transform(new Response(html)).text();
  for (const c of cards) { c.name = un(c.name); c.changes = c.changes.map(un); }
  return { cards, panels, text: un(text.join(" ")) };
}
const tab = (ui = {}) => renderWorkflow(MODEL, { tab: "workflow", phase: null, step: null, walk: null, at: 0, ...ui }, null);

test("Workflow: 45 step cards in 7 phases, each model step once, numbered 1 to 45 in order", async () => {
  const { cards, panels } = await parse(tab());
  expect(MODEL.stages).toHaveLength(7);
  expect(panels.map((p) => p.id)).toEqual(MODEL.stages.map((s: { id: string }) => s.id));
  expect(cards).toHaveLength(45);
  expect(cards.map((c) => c.num.trim())).toEqual(Array.from({ length: 45 }, (_, i) => String(i + 1)));
  expect(cards.map((c) => c.id)).toEqual(MODEL.stages.flatMap((s: { steps: string[] }) => s.steps));
  expect(new Set(cards.map((c) => c.id)).size).toBe(MODEL.nodes.length);
  for (const c of cards) expect(c.panel).toBe(MODEL.nodes.find((n: { id: string }) => n.id === c.id).step.stage);
});

test("Workflow: every move in the model is one outcome line on its own step's card (59 of today's page plus 24 new)", async () => {
  const { cards } = await parse(tab());
  const lines = cards.flatMap((c) => c.edges.map((e) => [c.id, e]));
  expect(lines).toHaveLength(83);
  expect(MODEL.edges.filter((e: { id: string }) => e.id.startsWith("m."))).toHaveLength(24);
  expect(new Set(lines.map(([, e]) => e)).size).toBe(83);
  for (const e of MODEL.edges) expect(lines).toContainEqual([e.from, e.id]);
});

test("Workflow: the step names are the v7 name table", async () => {
  const { cards } = await parse(tab());
  expect(cards.map((c) => [c.id, c.name.trim()])).toEqual(NAMES);
});

test("Workflow: no ticket ID, file path, script name or WAKE key in the visible text or any route caption", async () => {
  // not vacuous: the model's developer fields (sources, conditions, captions) hold all four kinds
  expect(JSON.stringify(MODEL.nodes.map((n: { sources: unknown }) => n.sources))).toMatch(FORBIDDEN);
  expect(JSON.stringify(MODEL.walkthroughs.map((w: { steps: { caption: string }[] }) => w.steps.map((s) => s.caption)))).toMatch(/WAKE/);
  for (const ui of [{}, { phase: "build" }, ...MODEL.walkthroughs.flatMap((w: { id: string; steps: unknown[] }) => w.steps.map((_, at) => ({ walk: w.id, at })))]) {
    const { text } = await parse(tab(ui));
    expect(text.match(FORBIDDEN)).toBeNull();
  }
  const evalTab = renderWorkflow(MODEL, { tab: "eval" }, STATS);
  expect((await parse(evalTab)).text.match(FORBIDDEN)).toBeNull();
});

test("Workflow: ?phase=build opens Build; #s-l.commit opens Build and highlights Commit", async () => {
  expect(parseWorkflowRoute("", "?phase=build")).toMatchObject({ tab: "workflow", phase: "build", step: null });
  expect(parseWorkflowRoute("#/workflow?phase=build", "")).toMatchObject({ phase: "build" });
  // a step's phase comes from the model when the page draws; the route only carries the step
  expect(parseWorkflowRoute("#s-l.commit", "")).toMatchObject({ tab: "workflow", step: "l.commit" });
  expect(parseWorkflowRoute("#/workflow?step=l.commit", "")).toMatchObject({ step: "l.commit" });
  expect(parseWorkflowRoute("#/workflow/eval", "")).toMatchObject({ tab: "eval" });
  expect(parseWorkflowRoute("#/workflow?phase=nope", "")).toMatchObject({ phase: null });
  const build = await parse(tab(parseWorkflowRoute("", "?phase=build")));
  expect(build.panels.filter((p) => !p.hidden).map((p) => p.id)).toEqual(["build"]);
  const commit = await parse(tab(parseWorkflowRoute("#s-l.commit", "")));
  expect(commit.panels.filter((p) => !p.hidden).map((p) => p.id)).toEqual(["build"]);
  expect(commit.cards.filter((c) => /\bwf-hl\b/.test(c.cls)).map((c) => c.id)).toEqual(["l.commit"]);
});

test("Workflow: each This version line shows its change's real state, and never its ticket", async () => {
  const { cards } = await parse(tab());
  let seen = 0;
  for (const n of MODEL.nodes) {
    const want = (n.step.changes || []) as { text: string; state: string }[];
    const got = cards.find((c) => c.id === n.id)!.changes;
    expect(got).toHaveLength(want.length);
    want.forEach((w, i) => { expect(got[i]).toContain(w.text); expect(got[i]).toContain(w.state); seen++; });
  }
  expect(seen).toBe(19);
  const handoff = cards.find((c) => c.id === "c.next")!;
  expect(handoff.num.trim()).toBe("18");
  expect(handoff.changes.join(" ")).toContain("pointers only");
});

const STATS = {
  from: "2026-10-25T00:00:00.000Z", to: "2026-11-01T00:00:00.000Z",
  days: ["2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31"],
  phases: [
    { id: "start", name: "Start", state: "nosource", unit: "min", n: 0, median: null, p80: null, perDay: [], counts: "nothing records when an idea arrives" },
    { id: "plan", name: "Plan and design", state: "nosource", unit: "min", n: 0, median: null, p80: null, perDay: [], counts: "x" },
    { id: "assign", name: "Assign", state: "nosource", unit: "min", n: 0, median: null, p80: null, perDay: [], counts: "x" },
    { id: "build", name: "Build", state: "ok", unit: "min", n: 387, median: 22.2, p80: 50.8, perDay: [85, 48, 89, 31, 44, 71, 78], counts: "each ticket's time from LIVE to its PR opening" },
    { id: "review", name: "Review", state: "ok", unit: "rounds", n: 559, median: 3, p80: 4, perDay: [1, 2, 3, 4, 5, 6, 7], counts: "each branch's highest review round" },
    { id: "check", name: "Check and approve", state: "ok", unit: "min", n: 386, median: 68.1, p80: 126.6, perDay: [1, 1, 1, 1, 1, 1, 1], counts: "x" },
    { id: "merge", name: "Merge and wrap up", state: "nodata", unit: "min", n: 0, median: null, p80: null, perDay: [0, 0, 0, 0, 0, 0, 0], counts: "x" },
  ],
  review: { threeUp: { merged: 323, notMerged: 6 }, under: { merged: 222, notMerged: 8 } },
  outliers: [{ pr: "4347", phase: "build", value: 7435.8, unit: "min", times: 146.4 }],
  cost: { state: "nodata", say: "no data yet" },
};

test("Eval: one row per phase with a Start row, the 7-day numbers in words, and the cost per ticket says no data yet", async () => {
  const html = renderWorkflow(MODEL, { tab: "eval" }, STATS);
  const rows: string[][] = [];
  let row: string[] | null = null, cell: string | null = null;
  await new HTMLRewriter()
    .on("table.wf-sum tbody tr", { element(e) { row = []; rows.push(row); } })
    .on("table.wf-sum tbody tr > *", { element(e) { cell = ""; e.onEndTag(() => { row!.push(cell!.trim()); cell = null; }); }, text(t) { if (cell !== null) cell += t.text; } })
    .transform(new Response(html)).text();
  expect(rows.map((r) => r[0])).toEqual(["1 Start", "2 Plan and design", "3 Assign", "4 Build", "5 Review", "6 Check and approve", "7 Merge and wrap up"]);
  expect(rows[0].slice(1, 4)).toEqual(["no source yet", "no source yet", "no source yet"]);
  expect(rows[3].slice(1, 4)).toEqual(["387", "22 min", "51 min"]);
  expect(rows[4].slice(1, 4)).toEqual(["559 branches", "3 rounds", "4 rounds"]);
  expect(rows[5].slice(1, 4)).toEqual(["386", "1 h 08", "2 h 07"]);
  expect(rows[6].slice(1, 4)).toEqual(["0", "no data yet", "no data yet"]);
  expect(html).toContain("Cost per ticket");
  expect(html).toMatch(/wf-cost[^>]*>[\s\S]*no data yet/);
  expect(html).toContain("PR 4347");
  expect(renderWorkflow(MODEL, { tab: "eval" }, null)).toContain("loading");
});

// the story map's Frame 1 pieces: a drill-in link per phase, the legend, the always-on and measurement
// notes, and each step's dot inside its own label link so a narrow column cannot strand the dot on a line above it
test("Workflow: the story map has a drill-in link per phase, the legend, the always-on note and the measurement note", () => {
  const html = tab();
  const map = html.slice(html.indexOf('<ol class="wf-map">'), html.lastIndexOf("</li></ol>", html.indexOf("Key")) + 10);
  const phases = map.split('<li class="wf-ph').slice(1);
  expect(phases).toHaveLength(7);
  phases.forEach((ph, i) => {
    const id = MODEL.stages[i].id;
    expect(ph).toContain(`<a class="wf-to wf-open" href="#/workflow?phase=${id}">Open the drill-in ›</a>`);
  });
  expect(html).toContain('aria-label="Key"');
  for (const k of ["a step (worker, check or judge)", "a step (chief)", "a step (you)", "an automatic check", "a way back", "planned, pilot, or only sometimes", "what passes to the next phase"]) expect(html).toContain(k);
  expect(html).toContain("Always on, under every phase:");
  expect(html).toContain("each tool call meets himmel's guards first");
  expect(html).toContain("Each phase shows one number: a 7-day measurement from the fleet's own records, not live state.");
});

test("Workflow: a step's dot sits inside the same link as its label", () => {
  const html = tab();
  const steps = html.split('<ol class="wf-steps">').slice(1).map((s) => s.slice(0, s.indexOf("</ol>")));
  const items = steps.flatMap((s) => s.split("<li>").slice(1));
  expect(items).toHaveLength(MODEL.stages.reduce((n: number, s: { map: unknown[] }) => n + s.map.length, 0));
  for (const li of items) expect(li).toMatch(/^<a class="wf-mstep"[^>]*><span class="wf-g wf-s[^"]*" aria-hidden="true"><\/span>/);
});
