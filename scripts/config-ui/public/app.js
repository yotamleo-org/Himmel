// thin DOM glue. All markup comes from render.js.
import { renderInventory, renderTriage, renderHeader, renderProbe, reviewGateDraft } from "/render.js";
import { renderHealth, verdict, parseView, projectVerdict } from "/health.js";
import { renderToolHealth } from "/tool-health.js";
import { renderKanban, renderRoadmap } from "/roadmap.js";
import { renderWorkflow, mountWorkflow } from "/workflow.js";
import { renderConfigure as render } from "/setup.js";
import { fleetDot, healthDot, navLinks, parseLanding } from "/nav.js";

const $ = (s) => document.querySelector(s);
const state = { open: new Set(), bundles: {}, filt: { health: null, kind: null, q: "", problems: false }, plans: {}, vm: null, reviewGate: null, fleetCap: null, tile: null };
let feed = null;
let lastProbe = null; // the newest 202 body ({ elapsedMs, progress }) while the first report runs

// The token rides the URL fragment (never sent in a request line); keep it in
// memory only and clear it from the address bar. The AG-UI rail
// links here as #t=<token>&page=<id>, landing on that page.
const landing = parseLanding(location.hash);
const token = landing ? landing.token : "";
if (landing) history.replaceState(null, "", location.pathname + location.search + "#/" + landing.page + (landing.tile ? "?tile=" + landing.tile : ""));
// the Fleet link's status dot, read on load and on each page change (never polled: an open
// chief must still let the server idle out).
let fleet = { data: null, error: null };

// Pages: one entry each (id = the `#/<id>` route).
// Health renders without a feed (D2): its bank and workers cards do not wait for the doctor report. So does Configure, so a
// first-run Account never waits on the minutes-long probe; refreshFeed asks it to pick up a newer report on arrival anyway.
let health = null; // GET /api/health, null while loading
let projects = null; // GET /api/projects: { current, projects: [...] }, null until read (the picker waits for it)
let otherFeed = null; // the feed of the project on the page when it is not this one: null while loading, "none" when never checked
let healthView = { mode: "project", project: null, tab: "broken", row: null }; // #/health?view=all | project=<name> & tab= & row=
let projectsGen = 0, otherGen = 0; // declared before route() runs: a reload at #/health calls loadProjects() from it
let vmLoadGen = 0; // declared before route() runs: a reload at #/config calls loadVm() from it; only the newest read may land
let healthGen = 0; // declared before route() runs: a reload at #/health calls loadHealth() from it
let reviewGateLoadGen = 0, reviewGateSaving = false; // declared before route() runs: a reload at #/config calls loadReviewGate() from it
let fleetCapLoadGen = 0, fleetCapSaving = false; // likewise for loadFleetCap()
let toolHealth = null, toolHealthGen = 0;
let setup = null, setupGen = 0; // GET /api/setup: secret presence and the commit rules; declared before route() runs
const setupMsgs = {}; // per secret name: the last save or remove outcome, never a value
let verify = null; // the Setup page's Verify step: null, { state: "running" } or POST /api/setup/verify's answer; page memory only
const toolFilters = new URLSearchParams();
let roadmap = null, roadmapGen = 0; // declared before route() runs, as healthGen is
const roadmapUi = { version: null, theme: null, ver: null, hideDone: false, writes: true, writeError: null }; // writes = cards drag and take a theme // ver = the #/roadmap/<version> drill-in, from the route
let sources; // GET /api/sources: the trackers the UI can read; undefined until read, [] hides Roadmap and Kanban
const noTracker = () => `<div class="nodata">No tracker the UI can read is configured, so there is no roadmap or board to show. Roadmap and Kanban read a Jira mirror, or GitHub issues when TRACKER=github and gh is signed in.</div>`;
const trackerPage = (draw) => () => (sources && sources.length === 0 ? noTracker() : draw());
const PAGES = [
  { id: "config", label: "Configure", needsFeed: false, refreshFeed: true, render: (f) => render(f, { tile: state.tile, setup, state, msgs: setupMsgs, verify }), onVisit: () => { if (!state.vm || !state.vm.data) loadVm(); if (!state.reviewGate || !state.reviewGate.data) loadReviewGate(); if (!state.fleetCap || !state.fleetCap.data) loadFleetCap(); loadSetup(); } },
  { id: "health", label: "Health", needsFeed: false, refreshFeed: true, render: (f) => healthPage(f), onVisit: () => { if (!health) loadHealth(); loadProjects(); } },
  { id: "toolhealth", label: "Tool health", needsFeed: false, render: () => renderToolHealth(toolHealth, token), onVisit: () => { if (!toolHealth) loadToolHealth(); } },
  { id: "roadmap", label: "Roadmap", needsFeed: false, render: trackerPage(() => renderRoadmap(roadmap, roadmapUi)), onVisit: () => { if (!roadmap && !(sources && !sources.length)) loadRoadmap(); } },
  { id: "kanban", label: "Kanban", needsFeed: false, render: trackerPage(() => renderKanban(roadmap, roadmapUi)), onVisit: () => { if (!roadmap && !(sources && !sources.length)) loadRoadmap(); } },
  { id: "workflow", label: "Workflow", needsFeed: false, render: () => renderWorkflow(), afterPaint: () => mountWorkflow() },
];
let unmountPage = null; // what the page's afterPaint returned: undoes its draw before the next paint replaces #main
let currentPage = PAGES[0];
const probeStatus = () => (lastProbe ? renderProbe(lastProbe) : `<p class="sub" id="status">loading…</p>`); // what a page that waits on, or shows, the report says meanwhile

// Settings and Setup became the one Configure page: their old routes still land on it, Setup with the Secrets tile open.
// (nav.js maps the AG-UI rail's page=setup landing the same way.)
const OLD_ROUTES = { setup: "secrets", configure: null };
const TILE_IDS = ["secrets", "review", "tracker", "scope"];

function route() {
  const m = /^#\/(\w+)(?:\/([^/?#]+))?(?:\?([^#]*))?/.exec(location.hash) || [];
  const old = Object.hasOwn(OLD_ROUTES, m[1]);
  const id = old ? "config" : m[1];
  currentPage = PAGES.find((p) => p.id === id) || PAGES[0];
  // the open tile rides the hash (#/config?tile=tracker), so a reload keeps it; any other route leaves none open.
  const asked = old ? OLD_ROUTES[m[1]] : new URLSearchParams(m[3] || "").get("tile");
  state.tile = currentPage.id === "config" && TILE_IDS.includes(asked) ? asked : null; // an unknown ?tile= opens none (nav.js TILES; slow.test.ts runs this file without its imports)
  if (currentPage.id === "health") {
    const was = healthView.project;
    healthView = parseView(m[3]);
    if (healthView.project !== was) { otherFeed = null; otherGen++; } // never show the last project's rows under this one's name
  }
  if (old || id !== currentPage.id) history.replaceState(null, "", location.pathname + location.search + "#/" + currentPage.id + (state.tile ? "?tile=" + state.tile : ""));
  let ver = null;
  if (currentPage.id === "roadmap" && m[2]) { try { ver = decodeURIComponent(m[2]); } catch (_) { ver = m[2]; } }
  roadmapUi.ver = ver;
  if (unmountPage) { unmountPage(); unmountPage = null; } // the branch below can replace #main without a paint
  renderPages();
  loadFleet();
  if (currentPage.onVisit) currentPage.onVisit();
  if (feed || currentPage.needsFeed === false) paint();
  else { $("#main").innerHTML = probeStatus(); $("#nav").innerHTML = ""; } // no stale page under this tab
  // back on Configure (or another feed page), pick up a newer report the server loaded in the background.
  if (feed && (currentPage.needsFeed !== false || currentPage.refreshFeed)) refreshFeed();
}
addEventListener("hashchange", route);
route();
loadSources();

// The rail (nav.js, shared with the AG-UI page): Config and Health are routes here, Fleet is /agui/.
function renderPages() {
  const dots = { fleet: fleetDot(fleet.data, fleet.error), health: healthDot(verdict(feed, health)) };
  $("#pages").innerHTML = navLinks({ here: "console", token, current: currentPage.id, sources }).map((l) =>
    `<a href="${l.href}"${l.current ? ' aria-current="page"' : ""}${l.external ? ' target="_blank" rel="noopener noreferrer"' : ""}>${l.label}${dots[l.id] ? `<span class="st-dot ${dots[l.id].cls}" title="${dots[l.id].title}"></span>` : ""}</a>`).join("") + (currentPage.id === "health" ? projectPicker() : "");
}

// The rail's project picker, drawn on the Health page only (only Health reloads /api/projects): "All my projects" first, then each registered project with its own verdict (shared rows left out).
function projectPicker() {
  if (!projects) return "";
  const esc = (x) => String(x).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const sel = healthView.mode === "all" ? "*" : healthView.project || projects.current; // "*" cannot be a registered name
  const word = (p) => (p.checkedAt ? projectVerdict(p.counts.project).word : "not checked");
  const opts = projects.projects.map((p) => `<option value="${esc(p.name)}"${sel === p.name ? " selected" : ""}>${esc(p.name)} · ${word(p)}</option>`).join("");
  return `<label class="picker"><span>Project</span><select id="proj" aria-label="Project"><option value="*"${sel === "*" ? " selected" : ""}>All my projects</option>${opts}</select></label>`;
}

// Health for the project in the picker: this UI's own feed, another project's cached one, or the all-projects view.
function healthPage(f) {
  if (healthView.project && !projects) return probeStatus(); // whose page this is waits on /api/projects: never this project's rows under another's name
  const cur = projects && projects.current;
  const other = healthView.project && cur && healthView.project !== cur;
  const fleetLink = navLinks({ here: "console", token, current: "health", sources }).find((l) => l.id === "fleet");
  const shown = other ? (otherFeed && otherFeed !== "none" ? otherFeed : null) : f;
  const view = { ...healthView, projects, project: healthView.project || cur, foreign: Boolean(other), fleetHref: fleetLink && fleetLink.href, unchecked: Boolean(other) && otherFeed === "none" };
  // the filterable Inventory stays below the v2 page until its e2e is ported to the Every item checked tab; Triage is the broken tab now.
  const legacy = shown && !other && healthView.mode !== "all" ? renderInventory(shown, state) : "";
  return renderHealth(shown, health, view) + legacy + (!shown && !other && healthView.mode !== "all" ? probeStatus() : "");
}
const healthHash = (v) => {
  const q = new URLSearchParams();
  if (v.mode === "all") q.set("view", "all"); else if (v.project) q.set("project", v.project);
  if (v.tab === "all") q.set("tab", "all");
  if (v.row) q.set("row", v.row);
  return "#/health" + (q.size ? "?" + q : "");
};
async function loadProjects() {
  const gen = ++projectsGen;
  try {
    const r = await fetch("/api/projects", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    if (r.ok && gen === projectsGen) projects = await r.json();
  } catch (_) { /* the picker stays hidden */ }
  if (gen !== projectsGen) return;
  loadOther();
  renderPages();
  if (currentPage.id === "health") paint();
}
async function loadOther() {
  const p = healthView.project, g = ++otherGen;
  otherFeed = null;
  if (!p || !projects || p === projects.current) return;
  try {
    const r = await fetch("/api/feed?project=" + encodeURIComponent(p), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = r.ok ? await r.json() : "none";
    if (g === otherGen) { otherFeed = j; if (currentPage.id === "health") paint(); }
  } catch (_) { if (g === otherGen) { otherFeed = "none"; if (currentPage.id === "health") paint(); } }
}

async function loadSources() {
  try {
    const r = await fetch("/api/sources", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    if (r.ok) sources = (await r.json()).sources;
  } catch (_) { /* unknown stays unknown: nothing is hidden */ }
  renderPages();
  if (currentPage.id === "roadmap" || currentPage.id === "kanban") paint();
}

async function loadFleet() {
  try {
    const r = await fetch("/api/agui/fleet", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    fleet = r.ok ? { data: await r.json(), error: null } : { data: null, error: r.status === 401 ? "the token was refused" : `the server answered ${r.status}` };
  } catch (_) { fleet = { data: null, error: "server unreachable" }; }
  renderPages();
}

function paint() {
  const buildOpen = $("#top details")?.open;
  const focusBuild = document.activeElement === $("#top summary");
  const keep = document.activeElement && document.activeElement.id === "q" ? document.activeElement.selectionStart : null;
  const focusK = document.activeElement && document.activeElement.matches && document.activeElement.matches(".row-head") ? document.activeElement.dataset.k : null;
  const focusB = document.activeElement && document.activeElement.matches && document.activeElement.matches(".bhead") ? document.activeElement.dataset.b : null;
  const focusRg = document.activeElement && document.activeElement.matches && document.activeElement.matches("[data-rg]") ? { rg: document.activeElement.dataset.rg, slug: document.activeElement.dataset.slug } : null;
  const focusT = document.activeElement && document.activeElement.matches && document.activeElement.matches("button.tile") ? document.activeElement.dataset.tile : null;
  // A secret or path being typed lives only in its field: a repaint (a report landing, a read finishing) must not wipe it.
  // It is held in this one synchronous call and put straight back; it is never kept in page state.
  const typing = [...document.querySelectorAll("input[data-secret],input[data-path],input[data-account]")].map((i) => ({ sel: ["secret", "path", "account"].map((a) => (i.dataset[a] !== undefined ? `input[data-${a}="${i.dataset[a]}"]` : "")).find(Boolean), value: i.value, edited: i.value !== i.defaultValue, had: i === document.activeElement, from: i.selectionStart, to: i.selectionEnd }));
  if (unmountPage) { unmountPage(); unmountPage = null; }
  $("#main").innerHTML = currentPage.render(feed);
  if (currentPage.afterPaint) unmountPage = currentPage.afterPaint();
  // only an edited field (even one emptied) is put back; an untouched one takes the value the repaint rendered from the fresh read
  for (const t of typing) { const i = document.querySelector(t.sel); if (i) { if (t.edited) i.value = t.value; if (t.had) { i.focus(); i.setSelectionRange(t.from, t.to); } } }
  $("#nav").innerHTML = "";
  $("#top").innerHTML = renderHeader(feed);
  const buildDetails = $("#top details");
  if (buildOpen && buildDetails) buildDetails.open = true;
  if (focusBuild) $("#top summary")?.focus();
  renderPages(); // the Health dot follows the feed and the health read
  $("#where").textContent = `${location.host} · ${feed && feed.target ? feed.target.scope : "?"} scope`;
  if (focusK !== null) { for (const h of document.querySelectorAll(".row-head")) if (h.dataset.k === focusK) { h.focus(); break; } }
  if (focusB !== null) { for (const h of document.querySelectorAll(".bhead")) if (h.dataset.b === focusB) { h.focus(); break; } }
  if (focusRg !== null) { for (const c of document.querySelectorAll("[data-rg]")) if (c.dataset.rg === focusRg.rg && c.dataset.slug === focusRg.slug) { c.focus(); break; } }
  if (focusT !== null) { for (const t of document.querySelectorAll("button.tile")) if (t.dataset.tile === focusT) { t.focus(); break; } }
  if (keep !== null) { const q = $("#q"); q.focus(); q.setSelectionRange(keep, keep); }
}

// #status lives in main and a page paint replaces it; fall back to the toast.
function setStatus(t) { const el = $("#status"); if (el) el.textContent = t; else toast(t); }

function toast(t) {
  const el = $("#toast");
  el.textContent = t; el.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { el.hidden = true; }, 2600);
}

async function post(path, body) {
  let r;
  try { r = await fetch(path, { method: "POST", headers: { "X-Himmel-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) }); }
  catch (_) { return { ok: false, status: 0, j: { error: `${path} unreachable (is the server still running?)` } }; }
  let j = {};
  try { j = await r.json(); } catch (_) { j = { error: `${path} failed (${r.status})` }; }
  return { ok: r.ok, status: r.status, j };
}

// The server answers 202 while its one background report runs (it can take
// minutes); keep asking, with the token each time, until a terminal answer.
// a 202 answers as soon as the probe step changes; onWait gets its body ({ elapsedMs, progress }).
async function fetchFeed(onWait, force) {
  for (let first = true; ; first = false) {
    const r = await fetch(force && first ? "/api/feed?refresh=1" : "/api/feed", { headers: { "X-Himmel-Token": token } }); // only the first request forces; the polls wait on that run
    if (r.status !== 202) return r;
    let j = {};
    try { j = await r.json(); } catch (_) { /* progress text only */ }
    lastProbe = j;
    onWait(j);
  }
}

// Only the newest call may paint: an older report can land after a newer one.
let feedGen = 0;
async function loadFeed(force) {
  const gen = ++feedGen;
  const say = (j) => {
    const s = Math.round((j.elapsedMs || 0) / 1000), p = j.progress;
    return p ? `re-probing ${p.source} (${p.i} of ${p.n})… ${s}s` : `re-probing… ${s}s`;
  };
  try {
    const r = await fetchFeed((j) => { if (gen === feedGen) toast(say(j)); }, force);
    if (r.ok) { const f = await r.json(); if (gen === feedGen) { feed = f; paint(); if (currentPage.id === "health") loadProjects(); } }
    else if (gen === feedGen) toast(`re-probe failed (${r.status})`);
  } catch (_) { if (gen === feedGen) toast("re-probe failed: server unreachable"); }
}

// one quiet look for a newer report (the server refreshes it in the background). Only a 200 with a
// new generatedAt repaints, and never over a loadFeed started since; a 202 or an error says nothing. Called on
// arriving at Config and when the tab becomes visible, never on a timer: an open chief must still idle out.
async function refreshFeed() {
  if (!feed) return;
  const gen = feedGen;
  try {
    const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
    if (r.status !== 200) return;
    const f = await r.json();
    if (gen === feedGen && feed && f.generatedAt !== feed.generatedAt) { feed = f; paint(); if (currentPage.id === "health") loadProjects(); }
  } catch (_) { /* quiet */ }
}
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refreshFeed(); });

// the vm.mode / vm.remote form. The draft is what the operator is typing; a saved or loaded answer resets it.
const vmDraft = (d) => ({ mode: d.mode, ssh: (d.remote && d.remote.ssh) || "", port: d.remote && d.remote.port !== undefined ? String(d.remote.port) : "", identity: (d.remote && d.remote.identity) || "" });
async function loadVm() {
  const gen = ++vmLoadGen;
  state.vm = { data: null, error: null };
  try {
    const r = await fetch("/api/vm", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = await r.json();
    if (gen !== vmLoadGen) return;
    state.vm = r.ok ? { data: j, error: null, draft: vmDraft(j) } : { data: null, error: j.error || `vm setting failed (${r.status})` };
  } catch (_) { if (gen !== vmLoadGen) return; state.vm = { data: null, error: "vm setting: server unreachable" }; }
  if (currentPage.id === "config") paint();
}
let vmSaving = false; // one save at a time: an older reply landing last must not overwrite a newer setting
async function saveVm() {
  const d = state.vm && state.vm.draft;
  if (!d || vmSaving) return;
  vmSaving = true;
  const body = { mode: d.mode };
  if (d.mode === "remote") body.remote = { ssh: d.ssh.trim(), port: d.port.trim(), identity: d.identity.trim() };
  const sent = JSON.stringify(d);
  let res;
  try { res = await post("/api/vm", body); } finally { vmSaving = false; }
  const { ok, j } = res;
  const edited = state.vm.draft && JSON.stringify(state.vm.draft) !== sent; // typed while the save was in flight: keep it
  state.vm = ok ? { data: j, error: null, draft: edited ? state.vm.draft : vmDraft(j), msg: { ok: true, text: "saved" } } : { ...state.vm, msg: { ok: false, text: j.error || "save failed" } };
  paint();
}

// the fleet cap card. The draft is the cap as typed; a saved or loaded answer resets it.
async function loadFleetCap() {
  const gen = ++fleetCapLoadGen;
  state.fleetCap = { data: null, error: null };
  try {
    const r = await fetch("/api/fleet-cap", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = await r.json();
    if (gen !== fleetCapLoadGen) return;
    state.fleetCap = r.ok ? { data: j, error: null, draft: String(j.cap) } : { data: null, error: j.error || `fleet cap failed (${r.status})` };
  } catch (_) { if (gen !== fleetCapLoadGen) return; state.fleetCap = { data: null, error: "fleet cap: server unreachable" }; }
  if (currentPage.id === "config") paint();
}
async function saveFleetCap() {
  const fc = state.fleetCap;
  if (!fc || !fc.data || fleetCapSaving) return;
  fleetCapSaving = true;
  const sent = fc.draft;
  let res;
  try { res = await post("/api/fleet-cap", { cap: sent }); } finally { fleetCapSaving = false; }
  const { ok, j } = res;
  const edited = state.fleetCap && state.fleetCap.draft !== sent;
  state.fleetCap = ok ? { data: j, error: null, draft: edited ? state.fleetCap.draft : String(j.cap), msg: { ok: true, text: edited ? "saved; later edits not saved yet" : "saved" } } : { ...state.fleetCap, msg: { ok: false, text: j.error || "save failed" } };
  paint();
}

// the review gate card. The draft is the per-reviewer choice being edited; a saved or loaded answer resets it.
async function loadReviewGate() {
  const gen = ++reviewGateLoadGen;
  state.reviewGate = { data: null, error: null };
  try {
    const r = await fetch("/api/review-gate", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = await r.json();
    if (gen !== reviewGateLoadGen) return;
    state.reviewGate = r.ok ? { data: j, error: null, draft: reviewGateDraft(j) } : { data: null, error: j.error || `review gate failed (${r.status})` };
  } catch (_) { if (gen !== reviewGateLoadGen) return; state.reviewGate = { data: null, error: "review gate: server unreachable" }; }
  if (currentPage.id === "config") paint();
}
async function saveReviewGate() {
  const rg = state.reviewGate;
  if (!rg || !rg.draft || reviewGateSaving) return;
  reviewGateSaving = true;
  const sent = JSON.stringify(rg.draft);
  let res;
  try { res = await post("/api/review-gate", { reviewers: rg.draft }); } finally { reviewGateSaving = false; }
  const { ok, j } = res;
  // an edit made while the request was in flight stays in the draft instead of being overwritten by the saved answer.
  const edited = state.reviewGate && state.reviewGate.draft && JSON.stringify(state.reviewGate.draft) !== sent;
  state.reviewGate = ok ? { data: j, error: null, draft: edited ? state.reviewGate.draft : reviewGateDraft(j), msg: { ok: true, text: edited ? "saved; later edits not saved yet" : "saved" } } : { ...state.reviewGate, msg: { ok: false, text: j.error || "save failed" } };
  paint();
}

// Only the newest call may paint, as with the feed.
async function loadHealth() {
  const gen = ++healthGen;
  let j;
  try {
    const [r, qr, rr, vr] = await Promise.all([
      fetch("/api/health", { headers: { "X-Himmel-Token": token } }),
      fetch("/api/bank", { headers: { "X-Himmel-Token": token } }).catch(() => null), // the panel degrades alone
      fetch("/api/rollup", { headers: { "X-Himmel-Token": token } }).catch(() => null),
      fetch("/api/reviewers", { headers: { "X-Himmel-Token": token } }).catch(() => null),
    ]);
    j = r.ok ? await r.json() : null;
    if (!j) toast(`health sources failed (${r.status})`);
    else {
      if (qr && qr.ok) j.quota = await qr.json().catch(() => undefined); // a bad bank body must not drop the health cards
      if (rr && rr.ok) j.rollup = await rr.json().catch(() => undefined);
      if (vr && vr.ok) j.reviewers = await vr.json().catch(() => undefined);
    }
  } catch (_) { j = null; toast("health sources: server unreachable"); }
  if (gen !== healthGen) return;
  const gone = { state: "error", reason: "health endpoint unreachable" };
  health = j || { bank: gone, workers: gone, monitoring: { state: "error", reason: "health endpoint unreachable" } };
  if (currentPage.needsFeed === false) paint();
}

async function loadSetup() {
  const gen = ++setupGen;
  let data;
  try {
    const r = await fetch("/api/setup", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : { error: `setup failed (${r.status})` };
  } catch (_) { data = { error: "server unreachable" }; }
  if (gen !== setupGen) return;
  const stale = data.error && setup && !setup.error; // a failed refresh keeps the last good read, so an open form stays
  if (!stale) setup = data;
  if (currentPage.id === "config") paint();
  if (stale && currentPage.id === "config") toast(`${data.error}: showing the last read, change a setting or reopen the page to retry`);
}
async function runVerify() {
  if (verify && verify.state === "running") return;
  verify = { state: "running" };
  paint();
  const { ok, j } = await post("/api/setup/verify", {});
  verify = ok ? j : { state: "error", error: j.error || "the checks failed" };
  if (currentPage.id === "config") paint();
}
// The value leaves the field in this one request and the field is cleared whatever the answer is.
async function saveSecret(name, op, input) {
  const body = { name, op };
  if (input) { if (!input.value) { setupMsgs[name] = "type a value first"; return paint(); } body.value = input.value; input.value = ""; }
  const { ok, j } = await post("/api/setup/secret", body);
  setupMsgs[name] = ok ? (op === "set" ? "saved" : "removed") : (j.error || "failed");
  const s = ok && setup && setup.secrets && setup.secrets.find((x) => x.name === name);
  if (s) s.status = j.status;
  paint();
}

async function loadToolHealth() {
  const gen = ++toolHealthGen;
  let data;
  try {
    const r = await fetch("/api/tool-health?" + toolFilters, { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : { state: "error" };
  } catch (_) { data = { state: "error" }; }
  if (gen !== toolHealthGen) return;
  toolHealth = data;
  if (currentPage.id === "toolhealth") paint();
}
// read live on every load; only the newest call may paint.
async function loadRoadmap() {
  const gen = ++roadmapGen;
  let data;
  try {
    const r = await fetch("/api/roadmap", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : { state: "error", reason: `roadmap failed (${r.status})` };
  } catch (_) { data = { state: "error", reason: "server unreachable" }; }
  if (gen !== roadmapGen) return;
  roadmap = data;
  roadmapUi.writes = data.source !== "github"; // GitHub cards are read-only
  if (currentPage.id === "roadmap" || currentPage.id === "kanban") paint();
}
// a drop or a Sector select goes to Jira through the server. The board is redrawn from the server's data either way:
// on a refusal nothing local changed, so the card is back where it was and the reason is shown above the board.
let rmWriting = false;
async function writeRoadmap(body) {
  if (rmWriting || !roadmap || roadmap.state !== "ok") return;
  const t = roadmap.tickets.find((x) => x.k === Number(String(body.key).replace("HIMMEL-", "")));
  if (!t) return;
  rmWriting = true; roadmapUi.writeError = null;
  const { ok, j } = await post("/api/roadmap/write", body);
  rmWriting = false;
  if (!ok) { roadmapUi.writeError = `${body.key}: ${j.error || "write failed"}${j.output ? " (" + String(j.output).trim().slice(0, 200) + ")" : ""}`; return paint(); }
  if ("status" in j) { const c = COLS_BY_ID[j.status]; t.b = j.status; t.s = j.name || c || t.s; }
  else {
    let i = roadmap.themes.indexOf(j.sector);
    if (i < 0) { roadmap.themes.push(j.sector); i = roadmap.themes.length - 1; }
    t.theme = i;
  }
  paint();
  if (j.mirror === "refreshed") loadRoadmap();
}
const COLS_BY_ID = { todo: "To Do", prog: "In Progress", rev: "In Review", ci: "IN CI", done: "Done", wont: "wont do" };
let rmDrag = null;
document.addEventListener("dragstart", (e) => {
  const c = e.target.closest && e.target.closest("[data-rm-card]");
  if (!c) return;
  rmDrag = Number(c.dataset.rmCard);
  try { e.dataTransfer.setData("text/plain", "HIMMEL-" + rmDrag); e.dataTransfer.effectAllowed = "move"; } catch (_) { /* no dataTransfer */ }
});
document.addEventListener("dragover", (e) => { if (rmDrag !== null && e.target.closest && e.target.closest("[data-rm-drop]")) e.preventDefault(); });
document.addEventListener("drop", (e) => {
  const col = e.target.closest && e.target.closest("[data-rm-drop]");
  if (rmDrag === null || !col) return;
  e.preventDefault();
  const k = rmDrag; rmDrag = null;
  const t = roadmap && roadmap.tickets.find((x) => x.k === k);
  if (t && t.b !== col.dataset.rmDrop) writeRoadmap({ key: "HIMMEL-" + k, status: col.dataset.rmDrop });
});
document.addEventListener("dragend", () => { rmDrag = null; });
document.addEventListener("change", (e) => {
  if (e.target.id === "proj") { // the rail picker: it routes, the route reads the project
    const v = e.target.value;
    location.hash = v === "*" ?"#/health?view=all" : projects && v === projects.current ? "#/health" : "#/health?project=" + encodeURIComponent(v);
    return;
  }
  if (e.target.dataset.rmThemeKey) return void writeRoadmap({ key: "HIMMEL-" + e.target.dataset.rmThemeKey, sector: e.target.value });
  const rgf = e.target.dataset.rg, rgd = state.reviewGate && state.reviewGate.draft;
  if (rgf && rgd) {
    const x = rgd.find((y) => y.slug === e.target.dataset.slug);
    if (x) {
      x[rgf] = rgf === "mode" || rgf === "model" || rgf === "effort" ? e.target.value : e.target.checked;
      state.reviewGate.msg = null;
      return rgf === "model" ? undefined : paint(); // a text box commits on blur: repainting would swallow the click on save that caused it
    }
  }
  if (e.target.dataset.fc === "cap" && state.fleetCap && state.fleetCap.data) { state.fleetCap.draft = e.target.value; state.fleetCap.msg = null; return; }
  if (e.target.dataset.vm === "mode" && state.vm && state.vm.draft) { state.vm.draft.mode = e.target.value; state.vm.msg = null; return paint(); }
  if (e.target.dataset.rmHideDone !== undefined) { roadmapUi.hideDone = e.target.checked; return paint(); }
  const f = e.target.dataset.rmFilter;
  if (f) { roadmapUi[f] = e.target.value === "" ? null : Number(e.target.value); return paint(); }
  const name = e.target.dataset.toolFilter;
  if (!name) return;
  toolFilters.set(name, e.target.value);
  loadToolHealth();
});

// Two-step write: the dry-run binds a preview id; only confirm runs it.
function preview(b) {
  const req ={ action: b.dataset.action, target: b.dataset.target };
  if (b.dataset.value) req.value = b.dataset.value;
  return previewReq(b.dataset.k, req);
}
async function previewReq(k, req) {
  const busy = state.plans[k];
  if (busy && (busy.stage === "loading" || busy.stage === "running")) return; // one request per row at a time
  state.plans[k] = { stage: "loading" }; paint();
  const { ok, j } = await post("/api/preview", req);
  state.plans[k] = ok ? { stage: "plan", req, typed: "", ...j } : { stage: "error", error: j.error || "preview failed", output: j.output };
  paint();
}

async function run(k) {
  const p = state.plans[k];
  if (!p || p.stage !== "plan") return;
  state.plans[k] = { stage: "running", command: p.command }; paint();
  const { ok, j } = await post("/api/run", { previewId: p.previewId, ...p.req, consent: p.typed });
  state.plans[k] = ok ? { stage: "done", ...j } : { stage: "error", error: j.error || "run failed", output: j.output };
  paint();
  if (ok) { loadFeed(); if (currentPage.id === "config") loadSetup(); }
}
// The password leaves its fields in this one request; both fields are cleared whatever the answer is.
async function createAccount(f) {
  const user = f.querySelector('[data-account="user"]').value;
  const pw = f.querySelector('[data-account="password"]'), again = f.querySelector('[data-account="confirm"]');
  const same = pw.value === again.value, password = pw.value;
  pw.value = ""; again.value = "";
  if (!same) { setupMsgs.account = "the two passwords differ"; return paint(); }
  const { ok, j } = await post("/api/setup/account", { user, password });
  setupMsgs.account = ok ? "login created" : (j.error || "failed");
  paint();
  if (ok) loadSetup();
}
document.addEventListener("submit", (e) => {
  const a = e.target.closest && e.target.closest("[data-account-form]");
  if (a) { e.preventDefault(); return void createAccount(a); }
  const pf = e.target.closest && e.target.closest("[data-path-form]");
  if (pf) {
    e.preventDefault();
    const target = pf.dataset.target;
    return void previewReq(`setup|${target}`, { action: "config.paths", target, value: pf.querySelector("input").value });
  }
  const f =e.target.closest && e.target.closest("[data-setup-form]");
  if (!f) return;
  e.preventDefault();
  void saveSecret(f.dataset.name, "set", f.querySelector("input"));
});

// A header click records an override with the bundle's rank at click time; a
// later worse rank makes render.js drop it (isOpen).
function toggleBundle(h) {
  state.bundles[h.dataset.b] = { open: h.getAttribute("aria-expanded") !== "true", rank: Number(h.dataset.rank) };
  paint();
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-act],[data-f]");
  if (!b) return;
  if (b.dataset.act === "refresh-toolhealth") return void loadToolHealth();
  if (b.dataset.act === "refresh-roadmap") return void loadRoadmap();
  if (b.dataset.act === "vm-save") return void saveVm();
  if (b.dataset.act === "review-gate-save") return void saveReviewGate();
  if (b.dataset.act === "fleet-cap-save") return void saveFleetCap();
  if (b.dataset.act === "reveal") {
    e.stopPropagation();
    const field = b.closest("form").querySelector(`input[data-secret="${b.dataset.reveal}"],input[data-account="${b.dataset.reveal}"]`);
    field.type = field.type === "password" ? "text" : "password";
    const shown = field.type === "text";
    b.textContent = shown ? "hide" : "show";
    b.setAttribute("aria-pressed", String(shown));
    b.setAttribute("aria-label", `${shown ? "Hide" : "Show"} ${b.dataset.reveal}`);
    return;
  }
  if (b.dataset.act === "setup-remove") {
    const field = b.closest("[data-setup-form]")?.querySelector("input");
    if (field) field.value = ""; // remove sends no value, so the typed text must not be put back by the repaint
    return void saveSecret(b.dataset.name, "remove", null);
  }
  if (b.dataset.act === "setup-verify") return void runVerify();
  if (b.dataset.act === "refresh-health") { loadHealth(); return void loadFeed(true); } // the verdict reads the doctor feed too
  if (b.dataset.act === "open-config") return void (location.hash = "#/health?row=" + encodeURIComponent(b.dataset.id)); // a check's finding opens its row on Health
  if (b.dataset.act === "health-tile") { const t = document.getElementById(b.dataset.target); if (t) t.scrollIntoView({ block: "start" }); return; }
  if (b.dataset.act === "health-tab" || b.dataset.act === "health-row") {
    if (b.dataset.act === "health-tab") healthView.tab = b.dataset.tab;
    else healthView.row = healthView.row === b.dataset.id ? null : b.dataset.id;
    history.replaceState(null, "", location.pathname + location.search + healthHash(healthView));
    return paint();
  }
  if (b.dataset.act === "tile") { // one group open at a time; the open one closes again. The hash keeps it across a reload.
    state.tile = state.tile === b.dataset.tile ? null : b.dataset.tile;
    history.replaceState(null, "", location.pathname + location.search + "#/config" + (state.tile ? "?tile=" + state.tile : ""));
    return paint();
  }
  if (!feed && currentPage.needsFeed !== false) return;
  if (b.dataset.f) { state.filt[b.dataset.f] = state.filt[b.dataset.f] === b.dataset.v ? null : b.dataset.v; return paint(); }
  if (b.dataset.act === "copy") {
    e.stopPropagation();
    const t = b.dataset.cmd;
    try { navigator.clipboard.writeText(t).then(() => toast("Copied: " + t), () => toast(t)); } catch (_) { toast(t); }
    return;
  }
  if (b.dataset.act === "bundle") return toggleBundle(b);
  if (b.dataset.act === "problems") { state.filt.problems = !state.filt.problems; return paint(); }
  if (b.dataset.act === "plan") { e.stopPropagation(); return void preview(b); }
  if (b.dataset.act === "run") return void run(b.dataset.k);
  if (b.dataset.act === "close") { delete state.plans[b.dataset.k]; return paint(); }
  if (b.dataset.act === "toggle" && !e.target.closest(".slot")) {
    const k = b.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});
document.addEventListener("input", (e) => {
  const vf = e.target.dataset.vm;
  if (vf && vf !== "mode" && state.vm && state.vm.draft) { state.vm.draft[vf] = e.target.value; return; } // no repaint: keep the caret
  if (e.target.dataset.fc === "cap" && state.fleetCap && state.fleetCap.data) { state.fleetCap.draft = e.target.value; state.fleetCap.msg = null; return; } // typed text survives a repaint before blur
  if (e.target.dataset.rg === "model" && state.reviewGate && state.reviewGate.draft) {
    const x = state.reviewGate.draft.find((y) => y.slug === e.target.dataset.slug);
    if (x) { x.model = e.target.value; state.reviewGate.msg = null; }
    return;
  }
  if (e.target.id === "q") { state.filt.q = e.target.value; paint(); return; }
  if (e.target.dataset.act === "consent") {
    // No repaint: keep the caret; only flip the confirm button.
    const p = state.plans[e.target.dataset.k];
    if (!p) return;
    p.typed = e.target.value;
    const btn = e.target.closest(".plan").querySelector('[data-act="run"]');
    if (btn) btn.disabled = p.typed !== p.consent.expect;
  }
});
document.addEventListener("keydown", (e) => {
  if (!feed || e.target.matches("input,select")) return;
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".bhead")) {
    e.preventDefault();
    return toggleBundle(e.target);
  }
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".row-head")) {
    e.preventDefault();
    const k = e.target.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});

(async () => {
  try {
    // the probe status (step, n of N, a progress bar) replaces #status on a page that waits for the feed.
    const r = await fetchFeed((j) => { const el = $("#status"); if (el) el.outerHTML = renderProbe(j); });
    if (r.status === 401) { setStatus("Not authorised: open the URL printed by `himmelctl ui` (it carries the session token), or log in at /login."); return; }
    if (!r.ok) {
      let why = "";
      try { why = (await r.json()).reason || ""; } catch (_) { /* status only */ }
      setStatus(`Feed failed (${r.status})${why ? ": " + why : ""}. Reload to retry.`);
      return;
    }
    feed = await r.json();
    paint();
  } catch (_) { setStatus("Server unreachable (it exits after 30 min idle)."); }
})();
