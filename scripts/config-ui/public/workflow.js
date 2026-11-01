// The Workflow page: the change loop by phase, in plain words, drawn from the one workflow model the docs page also
// reads (served read-only at /dev-graph/graph.json). Two tabs:
//   Workflow  the story map (7 phases on one line, one measured number each), Walk a route, and each phase's
//             drill-in: its steps as numbered cards, every move in the model once, on its own step's card.
//   Eval      the per-phase numbers for the last 7 full days (GET /api/phase-stats), for monitoring the system.
// Pure HTML out; app.js routes (#/workflow?phase=…|step=…|walk=…&at=…, #/workflow/eval, #s-<step>) and fetches.
// Plain words only: a ticket key, file path or script name in the model is never drawn (workflow-page.test.ts).
import { esc, pg, pageHeader } from "./render.js";

const PHASES = ["start", "plan", "assign", "build", "review", "check", "merge"];
const WHO = { you: ["You", "w-you"], chief: ["Chief", "w-ch"], worker: ["Worker", "w-wk"], check: ["Automatic check", "w-ck"], judge: ["Judge", "w-jd"] };
const LEAD = { then: "flow", next: "flow", when: "dec", "goes back if": "loop", "stops if": "ref" };
const STATE = { done: "done", "in progress": "prog", "not started": "none" };
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// the route's page state: the tab, an open phase, a step to show, a walk and its position. A step's phase comes from
// the model when the page draws. `search` is location.search: a ?phase= link from the docs lands on the Workflow tab.
export function parseWorkflowRoute(hash, search) {
  const ui = { tab: "workflow", phase: null, step: null, walk: null, at: 0 };
  const deep = /^#s-(.+)$/.exec(hash || "");
  if (deep) { try { ui.step = decodeURIComponent(deep[1]); } catch (_) { ui.step = deep[1]; } return ui; }
  const m = /^#\/workflow(\/eval)?(?:\?([^#]*))?$/.exec(hash || "");
  if (m && m[1]) ui.tab = "eval";
  const q = new URLSearchParams(m ? m[2] || "" : search || "");
  if (PHASES.includes(q.get("phase"))) ui.phase = q.get("phase");
  if (/^[a-z]+\.[\w.]+$/.test(q.get("step") || "")) ui.step = q.get("step");
  if (/^w\d+$/.test(q.get("walk") || "")) { ui.walk = q.get("walk"); ui.at = Math.max(0, Number.parseInt(q.get("at") || "0", 10) || 0); }
  return ui;
}

const memo = new WeakMap();
function index(model) {
  if (memo.has(model)) return memo.get(model);
  const node = new Map(model.nodes.map((n) => [n.id, n]));
  const order = model.stages.flatMap((s) => s.steps);
  const num = new Map(order.map((id, i) => [id, i + 1]));
  const outs = new Map(), ins = new Map();
  for (const e of model.edges) {
    outs.set(e.from, [...(outs.get(e.from) || []), e]);
    if (e.from !== e.to) ins.set(e.to, [...new Set([...(ins.get(e.to) || []), e.from])]);
  }
  const ix = { node, order, num, outs, ins, stageOf: (id) => node.get(id)?.step.stage ?? null };
  memo.set(model, ix);
  return ix;
}

const stepLink = (ix, id) => `<a class="wf-to" href="#/workflow?step=${esc(id)}">${ix.num.get(id)} · ${esc(ix.node.get(id).step.name)}</a>`;
const badge = (s) => (s.badge ? `<span class="wf-badge">${esc(s.badge)}</span>` : "");

// one glyph on a phase's line: a step dot (dashed when planned), a check bar, a way back, or what the phase hands on
function glyph(ix, item, planned) {
  if (item.step) {
    const s = ix.node.get(item.step).step;
    const who = s.who === "you" ? " you" : s.who === "chief" ? " chief" : "";
    return `<span class="wf-g wf-s${who}${planned.has(item.step) || s.tagKind === "planned" ? " wf-pl" : ""}" aria-hidden="true"></span>`;
  }
  if (item.gate) return `<span class="wf-g wf-k" aria-hidden="true"></span>`;
  if (item.back) return `<span class="wf-g wf-w" aria-hidden="true">↶</span>`;
  return `<span class="wf-art">${esc(item.artifact)}</span>`;
}

// numbers in words: minutes as "under 1 min", "22 min", "1 h 08", "5 d 4 h"; rounds as "3 rounds"
export function fmtValue(v, unit) {
  if (v === null || v === undefined) return "no data yet";
  if (unit === "rounds") return `${v} round${v === 1 ? "" : "s"}`;
  const m = Math.round(v);
  if (v < 1) return "under 1 min";
  if (m < 60) return `${m} min`;
  if (m < 48 * 60) return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`;
  return `${Math.floor(m / 1440)} d ${Math.floor((m % 1440) / 60)} h`;
}
function windowLabel(stats) {
  if (!stats || !stats.days || stats.days.length !== 7) return "7 days";
  const [a, b] = [stats.days[0], stats.days[6]].map((d) => ({ d: Number(d.slice(8, 10)), m: MONTHS[Number(d.slice(5, 7)) - 1] }));
  return `7 days · ${a.d}${a.m === b.m ? "" : ` ${a.m}`}–${b.d} ${b.m}`;
}
const statRow = (stats, id) => (stats && stats.phases ? stats.phases.find((p) => p.id === id) : null);

// the one number on a phase of the story map, with what it counts
function measure(stage, stats) {
  if (!stage.measure) return { v: "no source yet", none: true, cap: stage.noSource || "" };
  if (!stats) return { v: "loading…", none: true, cap: "" };
  if (stats.error) return { v: "not read", none: true, cap: stats.error };
  const p = statRow(stats, stage.measure);
  if (!p || p.state !== "ok") return { v: "no data yet", none: true, cap: "" };
  const line = `n ${p.n} · 8 in 10 under ${fmtValue(p.p80, p.unit)}`;
  if (stage.measure === "review") {
    const up = stats.review.threeUp.merged + stats.review.threeUp.notMerged;
    return { v: `${Math.round((up / p.n) * 100)} %`, cap: `of branches needed 3 or more review rounds · n ${p.n} · median ${fmtValue(p.median, p.unit)}` };
  }
  const what = { build: "median time in Build, from LIVE to the PR opening", check: "median from the first CI run to the merge", merge: "median from the merge to WRAPPED" }[stage.measure];
  return { v: fmtValue(p.median, p.unit), cap: `${what} · ${line}` };
}

function storyMap(model, ix, stats, open) {
  return `<ol class="wf-map">${model.stages.map((st) => {
    const planned = new Set(st.map.filter((x) => x.planned).map((x) => x.step));
    const marks = st.line.filter((x) => x.gate || x.back);
    const met = measure(st, stats);
    return `<li class="wf-ph${open === st.id ? " wf-sel" : ""}" data-ph="${esc(st.id)}">`
      + `<a class="wf-ph-btn" href="#/workflow?phase=${esc(st.id)}" aria-label="Open phase ${st.n}, ${esc(st.name)}"><span class="wf-ph-n">${st.n}</span><span class="wf-ph-name">${esc(st.name)}</span><span class="wf-ph-who">${esc(st.who)}</span></a>`
      + `<div class="wf-line" title="${esc(st.name)}: steps and marks in order">${st.line.map((x) => glyph(ix, x, planned)).join("")}</div>`
      + `<ul class="wf-marks">${marks.map((x) => `<li>${glyph(ix, x, planned)}<span>${esc(x.gate || x.back)}</span></li>`).join("")}</ul>`
      + `<div class="wf-met"><span class="wf-win">${esc(windowLabel(stats))}</span><span class="wf-v${met.none ? " wf-none" : ""}">${esc(met.v)}</span>${met.cap ? `<span class="wf-cap">${esc(met.cap)}</span>` : ""}</div>`
      + `<ol class="wf-steps">${st.map.map((x) => {
        const s = ix.node.get(x.step).step;
        return `<li>${glyph(ix, { step: x.step }, planned)}<a class="wf-mstep" href="#/workflow?step=${esc(x.step)}">${esc(s.name)}${badge(s)}</a>${x.tag ? `<span class="wf-tag${x.planned ? " wf-pl" : ""}">${esc(x.tag)}</span>` : ""}</li>`;
      }).join("")}</ol></li>`;
  }).join("")}</ol>`;
}

function outLine(ix, e) {
  const kind = LEAD[e.move.lead] || "flow";
  const to = e.from === e.to ? `<span class="wf-to wf-self">↻ this step again</span>` : `<a class="wf-to" href="#/workflow?step=${esc(e.to)}">→ ${ix.num.get(e.to)} · ${esc(ix.node.get(e.to).step.name)}</a>`;
  return `<li class="wf-k-${kind}" data-edge="${esc(e.id)}"><span class="wf-lead">${esc(e.move.lead)}</span>${e.move.say ? `${esc(e.move.say)} ` : ""}${to}</li>`;
}

function card(ix, id, hl) {
  const s = ix.node.get(id).step;
  const [who, whoCls] = WHO[s.who] || [s.who, ""];
  const from = (ix.ins.get(id) || []).slice().sort((a, b) => ix.num.get(a) - ix.num.get(b));
  return `<li class="wf-step${s.place.startsWith("above") ? " wf-above" : ""}${hl === id ? " wf-hl" : ""}" id="s-${esc(id)}"><span class="wf-num">${ix.num.get(id)}</span><div class="wf-card">`
    + `<div class="wf-sh"><b class="wf-sn">${esc(s.name)}</b>${badge(s)}<span class="wf-who ${whoCls}">${esc(who)}</span><span class="wf-place">${esc(s.place)}</span>`
    + `${s.tag ? `<span class="wf-tag${s.tagKind === "planned" ? " wf-pl" : ""}">${esc(s.tag)}</span>` : ""}${s.proposed ? `<span class="wf-tag wf-pl">proposed</span>` : ""}</div>`
    + `<p class="wf-plain">${esc(s.plain)}</p>`
    + (s.changes || []).map((c) => `<p class="wf-chg"><span class="wf-chg-tag">This version</span>${esc(c.text)} <span class="wf-cst wf-cst-${STATE[c.state] || "none"}">${esc(c.state)}</span></p>`).join("")
    + `<ul class="wf-outs">${(ix.outs.get(id) || []).map((e) => outLine(ix, e)).join("")}`
    + `${from.length ? `<li class="wf-k-from"><span class="wf-lead">reached from</span>${from.map((f) => stepLink(ix, f)).join(", ")}</li>` : ""}</ul>`
    + `${s.detail ? `<details class="wf-hood"><summary>More detail</summary><p>${esc(s.detail)}</p></details>` : ""}`
    + `</div></li>`;
}

function panel(model, ix, st, stats, open, hl) {
  const first = ix.num.get(st.steps[0]), last = ix.num.get(st.steps.at(-1));
  const met = measure(st, stats);
  const chip = (x) => x.step
    ? `<a class="wf-chip" href="#/workflow?step=${esc(x.step)}">${glyph(ix, x, new Set())}${esc(ix.node.get(x.step).step.name)}${badge(ix.node.get(x.step).step)}</a>`
    : x.gate ? `<span class="wf-chip wf-k">┃ ${esc(x.gate)}</span>` : x.back ? `<span class="wf-chip wf-w">↶ ${esc(x.back)}</span>` : `<span class="wf-chip wf-artchip">${esc(x.artifact)}</span>`;
  return `<section class="wf-panel" id="pp-${esc(st.id)}" data-ph="${esc(st.id)}"${open === st.id ? "" : " hidden"}>`
    + `<p class="wf-crumb">Workflow › <b>${st.n} · ${esc(st.name)}</b></p><h2>${st.n} · ${esc(st.name)}</h2>`
    + `<p class="wf-purpose"><b>This phase answers:</b> ${esc(st.purpose)}</p>`
    + `<h3>The phase on its line</h3><div class="wf-flow">${st.line.map(chip).join(`<span class="wf-arrow" aria-hidden="true">→</span>`)}</div>`
    + `<h3>Every step, in order (${st.steps.length}: steps ${first} to ${last})</h3><ol class="wf-stepper">${st.steps.map((id) => card(ix, id, hl)).join("")}</ol>`
    + `${st.gates.length ? `<h3>Checks in this phase</h3><ul class="wf-list">${st.gates.map((g) => `<li>${esc(g)}</li>`).join("")}</ul>` : ""}`
    + `${st.back.length ? `<h3>Ways back</h3><ul class="wf-list">${st.back.map((b) => `<li>${esc(b)}</li>`).join("")}</ul>` : ""}`
    + `<p class="wf-metbox">This phase's number on the story map: <b>${esc(met.v)}</b>${met.cap ? `, ${esc(met.cap)}` : ""}. The full numbers are in the <a href="#/workflow/eval">Eval tab</a>.</p>`
    + `</section>`;
}

function walkPanel(model, ix, ui) {
  const w = model.walkthroughs.find((x) => x.id === ui.walk);
  const at = w ? Math.min(ui.at, w.steps.length - 1) : 0;
  const href = (id, i) => `#/workflow?walk=${esc(id)}&amp;at=${i}`;
  let now = "";
  if (w) {
    const cur = w.steps[at];
    now = `<div class="wf-ctl">${at > 0 ? `<a class="btn" href="${href(w.id, at - 1)}">‹ Previous</a>` : ""}${at < w.steps.length - 1 ? `<a class="btn" href="${href(w.id, at + 1)}">Next ›</a>` : ""}</div>`
      + `<p class="wf-wnow"><span class="wf-wpos">Step ${at + 1} of ${w.steps.length}</span><span>${esc(cur.say)}</span>${stepLink(ix, cur.at)}</p>`
      + `<ol class="wf-route">${w.steps.map((x, i) => `<li${i === at ? ' aria-current="step"' : ""}><a href="${href(w.id, i)}">${ix.num.get(x.at)} · ${esc(ix.node.get(x.at).step.name)}</a><span class="wf-wcap">${esc(x.say)}</span></li>`).join("")}</ol>`;
  }
  return `<section class="wf-walk"><h2>Walk a route</h2><p class="wf-purpose"><b>Answers:</b> what does one change actually go through, start to finish? Pick a route, then step through it.</p>`
    + `<div class="wf-ctl" role="group" aria-label="Pick a route">${model.walkthroughs.map((x) => `<a class="btn" href="${href(x.id, 0)}"${w && w.id === x.id ? ' aria-current="true"' : ""}>${esc(x.name)} (${x.steps.length} steps)</a>`).join("")}</div>${now}</section>`;
}

const tabs = (on) => `<nav class="wf-tabs" aria-label="Workflow tabs"><a href="#/workflow"${on === "workflow" ? ' aria-current="page"' : ""}>Workflow</a><a href="#/workflow/eval"${on === "eval" ? ' aria-current="page"' : ""}>Eval</a></nav>`;
const HEAD = pageHeader("Workflow", "How a change gets from an idea to main: seven phases on one line, the checks on it, and the ways back.");

function workflowTab(model, ix, ui, stats) {
  const walk = ui.walk && model.walkthroughs.find((x) => x.id === ui.walk);
  const hl = ui.step && ix.node.has(ui.step) ? ui.step : walk ? walk.steps[Math.min(ui.at, walk.steps.length - 1)].at : null;
  const open = hl ? ix.stageOf(hl) : ui.phase;
  const above = model.stages.flatMap((s) => s.steps).filter((id) => ix.node.get(id).step.place.startsWith("above")).map((id) => ix.num.get(id));
  return `<p class="wf-tabq"><b>Workflow tab:</b> the system, explained. It shows the path every change takes, with one measured number per phase. It is not a live monitor: nothing here shows what is running right now.</p>`
    + `<div class="wf-band"><span class="wf-ring" aria-hidden="true"></span><div><b>Above the line: the chief's loop.</b> It is not one change, and it runs all the time: wait, read the fleet, pick, brief, start a worker. Each worker it starts enters the line at phase 3. When its shift ends, a new chief takes over the whole fleet, with the start and plan work still in flight. Its steps are ${above.join(", ")}, in phase 3's drill-in.</div></div>`
    + storyMap(model, ix, stats, open)
    + walkPanel(model, ix, ui)
    + `<nav class="wf-ctl wf-picker" aria-label="Open a phase">${model.stages.map((s) => `<a class="btn" href="#/workflow?phase=${esc(s.id)}"${open === s.id ? ' aria-current="true"' : ""}>${s.n} · ${esc(s.name)}</a>`).join("")}</nav>`
    + model.stages.map((st) => panel(model, ix, st, stats, open, hl)).join("");
}

function evalTab(model, stats) {
  const intro = `<p class="wf-tabq"><b>Eval tab:</b> phase statistics for monitoring the system. Every figure says in words what it counts.</p>`;
  if (!stats) return intro + `<p class="sub">loading…</p>`;
  if (stats.error) return intro + `<div class="nodata" role="alert">The phase numbers were not read: ${esc(stats.error)}</div>`;
  const day = (iso) => { const d = new Date(iso); return `${d.getUTCDate()} ${["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][d.getUTCMonth()]}`; };
  const n = (s) => Object.fromEntries(model.stages.map((x) => [x.id, x.n]))[s];
  const cells = (p) => p.state === "nosource" ? Array(4).fill("no source yet")
    : [p.unit === "rounds" ? `${p.n} branches` : String(p.n), fmtValue(p.median, p.unit), fmtValue(p.p80, p.unit), p.perDay.join(" · ")];
  const name = (id) => (stats.phases.find((p) => p.id === id) || {}).name || id;
  const r = stats.review;
  return intro
    + `<p class="wf-win">Window: ${esc(day(stats.from))} 00:00 to ${esc(day(stats.to))} 00:00 UTC, 7 full days. A ticket counts in a phase when it enters the phase in the window.</p>`
    + `<section class="box"><h2>Phase summary</h2><table class="wf-sum"><thead><tr><th>Phase</th><th>n</th><th>Median</th><th>8 in 10 under</th><th>Entered per day</th></tr></thead><tbody>`
    + stats.phases.map((p) => `<tr><th>${n(p.id)} ${esc(p.name)}</th>${cells(p).map((c) => `<td>${esc(c)}</td>`).join("")}</tr>`).join("")
    + `</tbody></table><ul class="wf-list">${stats.phases.map((p) => `<li><b>${esc(p.name)}:</b> ${esc(p.counts)}.</li>`).join("")}</ul></section>`
    + `<section class="box"><h2>Review: merged or not, by rounds</h2><table class="wf-rev"><thead><tr><th>Branches</th><th>Merged</th><th>Not merged</th><th>All</th></tr></thead><tbody>`
    + [["3 or more rounds", r.threeUp], ["under 3 rounds", r.under]].map(([label, x]) => `<tr><th>${label}</th><td>${x.merged}</td><td>${x.notMerged}</td><td>${x.merged + x.notMerged}</td></tr>`).join("")
    + `</tbody></table></section>`
    + `<section class="box"><h2>Outliers</h2>${stats.outliers.length ? `<table class="wf-out"><thead><tr><th>Change</th><th>Phase</th><th>Time or rounds</th><th>vs the 8-in-10 line</th></tr></thead><tbody>`
      + stats.outliers.map((o) => { const p = statRow(stats, o.phase); return `<tr><th>${o.pr ? `PR ${esc(o.pr)}` : "a branch with no PR"}</th><td>${esc(name(o.phase))}</td><td>${esc(fmtValue(o.value, o.unit))}</td><td>${o.times} × ${esc(fmtValue(p && p.p80, o.unit))}</td></tr>`; }).join("")
      + `</tbody></table><p class="sub">A ticket that was parked and resumed counts its wait, so the longest rows are often a pause, not slow work.</p>` : `<p class="sub">No change was far outside its phase's 8-in-10 line.</p>`}</section>`
    + `<section class="box"><h2>Cost per ticket</h2><p class="wf-cost"><span class="wf-v wf-none">${esc(stats.cost.say)}</span> What one ticket costs, and how much of it is spent before the build starts, is not joined to the ticket yet.</p></section>`;
}

// model: the parsed workflow model, null while loading, or { error }; ui: parseWorkflowRoute's answer;
// stats: GET /api/phase-stats, null while loading, or { error }.
export function renderWorkflow(model, ui, stats) {
  const tab = ui && ui.tab === "eval" ? "eval" : "workflow";
  if (!model) return pg(HEAD + tabs(tab) + `<p class="sub">loading…</p>`);
  if (model.error) return pg(HEAD + tabs(tab) + `<div class="nodata" role="alert">The workflow did not load: ${esc(model.error)}</div>`);
  const ix = index(model);
  return pg(HEAD + tabs(tab) + (tab === "eval" ? evalTab(model, stats) : workflowTab(model, ix, ui, stats)));
}
