// thin DOM glue. All markup comes from render.js.
import { renderInventory, renderTriage, renderHeader, renderProbe, reviewGateDraft } from "/render.js";
import { renderHealth, verdict, parseView, projectVerdict, chiefLiveFor } from "/health.js";
import { renderToolHealth, toolHealthLoader, toolHealthHref } from "/tool-health.js";
import { boardRefreshDue, driftSince, pinsFromSearch, renderBoard, searchWithPins, togglePin } from "/roadmap.js";
import { renderWorkflow, parseWorkflowRoute } from "/workflow.js";
import { renderCost } from "/cost.js";
import { apiRolesDraft, renderConfigure as render } from "/setup.js";
import { renderShift } from "/shift.js";
import { renderReport, reportBar } from "/report.js";
import { fleetDot, healthDot, navLinks, parseLanding, railMarkup } from "/nav.js";

const $ = (s) => document.querySelector(s);
const state = { open: new Set(), bundles: {}, filt: { health: null, kind: null, q: "", problems: false }, plans: {}, vm: null, reviewGate: null, apiRoles: null, fleetCap: null, tile: null };
let feed = null;
let lastProbe = null; // the newest 202 body ({ elapsedMs, progress }) while the first report runs

const landing = parseLanding(location.hash);
const TAB_KEY = "himmel.fleet-token";
const keptToken = () => { try { return sessionStorage.getItem(TAB_KEY) || ""; } catch (_) { return ""; } };
const keepToken = (t) => { try { sessionStorage.setItem(TAB_KEY, t); } catch (_) {} };
let token = landing ? landing.token : keptToken();
if (landing) keepToken(token);
async function adoptToken() {
  try {
    const r = await fetch("/api/fleet-token", { cache: "no-store" });
    if (!r.ok) return false;
    const t = (await r.json()).token;
    if (typeof t !== "string" || !/^[\w-]+$/.test(t)) return false;
    token = t;
    keepToken(t);
    return true;
  } catch (_) { return false; }
}
if (landing) history.replaceState(null, "", location.pathname + location.search + "#/" + landing.page + (landing.tile ? "?tile=" + landing.tile : landing.q ? "?" + landing.q : ""));
// the Fleet link's status dot, read on load and on each page change (never polled: an open
// chief must still let the server idle out).
let fleet = { data: null, error: null };

// Pages: one entry each (id = the `#/<id>` route).
// Health renders without a feed (D2): its bank and workers cards do not wait for the doctor report. So does Configure, so a
// first-run Account never waits on the minutes-long probe; refreshFeed asks it to pick up a newer report on arrival anyway.
let health = null; // GET /api/health, null while loading
let projects = null; // GET /api/projects: { current, projects: [...] }, null until read (the picker waits for it)
let otherFeed = null; // the feed of the project on the page when it is not this one: null while loading, "none" when never checked
let healthView = { mode: "project", project: null, tab: "broken", row: null, tile: null }; // #/health?view=all | project=<name> & tab= & row= & tile=
let projectsGen = 0, otherGen = 0; // declared before route() runs: a reload at #/health calls loadProjects() from it
let reportsLoadGen = 0, reportsSaving = false; // likewise for loadReportSettings(): the Reports and shifts card
let reportList = null, reportView = null, reportGen = 0; // GET /api/reports and GET /api/report?day=, null until read
const reportUi = { day: null }; // from the route: #/report?day=YYYY-MM-DD
let vmLoadGen = 0; // declared before route() runs: a reload at #/config calls loadVm() from it; only the newest read may land
let healthGen = 0; // declared before route() runs: a reload at #/health calls loadHealth() from it
let reviewGateLoadGen = 0, reviewGateSaving = false; // declared before route() runs: a reload at #/config calls loadReviewGate() from it
let apiRolesLoadGen = 0, apiRolesSaving = false; // likewise for loadApiRoles(): the Multi accounts section
let fleetCapLoadGen = 0, fleetCapSaving = false; // likewise for loadFleetCap()
// Tool health: three reads, each keeping its last good answer when a newer one fails (tool-health.js toolHealthLoader).
const thGet = (path) => async (q) => {
  const r = await fetch(path + (q ? "?" + q : ""), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
  if (!r.ok) throw new Error(`${path} failed (${r.status})`);
  return r.json();
};
const thPaint = () => { if (currentPage.id === "toolhealth") paint(); };
let th = null; // made on the first visit: { health, inventory, reviewers }
const thLoaders = () => th || (th = Object.fromEntries([["health", "/api/tool-health"], ["inventory", "/api/tool-inventory"], ["reviewers", "/api/reviewers"]].map(([k, path]) => [k, toolHealthLoader({ get: thGet(path), onChange: thPaint })])));
// filters, tool and guard ride the route (#/toolhealth[/<tab>]?days=&team=&lane=&profile=&tool=&guard=); the rest is page memory
const thUi = { tab: "overview", filters: {}, tool: null, guard: null, sort: "failed", kind: null, src: null, q: "", group: null, all: false, before: false, sorts: {} };
const TH_TABS = ["overview", "station", "map", "hooks", "reviewers"];
let thQuery = null, thReturn = null; // thReturn: the tool whose drill-in was just left, so focus goes back to its row
let setup = null, setupGen = 0; // GET /api/setup: secret presence and the commit rules; declared before route() runs
const setupMsgs = {}; // per secret name: the last save or remove outcome, never a value
let session = null; // is this browser holding a login session: null until read, then true or false; the header shows it
const NEEDS_LOGIN = "log in to save a secret; what you typed was cleared, type it again after you are back"; // the row's message for a save refused in service mode; declared before route() runs
let verify = null; // the Setup page's Verify step: null, { state: "running" } or POST /api/setup/verify's answer; page memory only
let roadmap = null, roadmapGen = 0, nvGen = 0; // declared before route() runs, as healthGen is: a reload at #/board?tab=nv calls loadNoVersion() from it
let boardExtras = null, boardGen = 0, boardAsked = ""; // boardAsked: the version tile the last read was sent for // GET /api/board: { drift, chains, versionChains }, null until read
let pagebarOpen = false; // the page bar's "Filters (n on)" fold at phone width; declared before route() runs, as the next one is
let originsReading = false; // declared before route() runs: a reload at #/board paints, and that paint asks for Tidy up's origins
// writes = cards drag and take a theme // tab, v, at = the Board route (#/board?tab=&v=&at=); chain = the Chain filter
// pins, showAll, hidePrev, hideFuture = the version strip's window (display only; no Jira call); the pins are kept in the URL's ?pins=, see savePins.
const savePins = (pins) => history.replaceState(null, "", location.pathname + searchWithPins(location.search, pins) + location.hash);
const roadmapUi = { version: null, theme: null, ver: null, hideDone: false, writes: true, writeError: null, held: null, drawer: null, tab: null, v: null, at: null, why: null, logOpen: [], chain: null, nv: null, pins: pinsFromSearch(location.search), showAll: false, hidePrev: false, hideFuture: false, pinMsg: "" };
let sources; // GET /api/sources: the trackers the UI can read; undefined until read, [] hides the Board
const noTracker = () => `<div class="nodata">No tracker the UI can read is configured, so there is no board to show. The Board reads the local tracker store (TRACKER=local, once it holds an item), a Jira mirror, or GitHub issues when TRACKER=github and gh is signed in.</div>`;
const trackerPage = (draw) => () => (sources && sources.length === 0 ? noTracker() : draw());
let shift = null, shiftGen = 0, shiftAt = 0; // GET /api/shift, null until read; shiftAt throttles the rail badge's reads
const shiftUi = { id: null, all: false }; // from the route: #/shift/<id>?all=1
let wfModel = null, wfStats = null, wfGen = 0, wfAt = 0, wfScrolled = null; // the workflow model and GET /api/phase-stats, null until read
const wfUi = { tab: "workflow", phase: null, step: null, walk: null, at: 0 }; // from the route: #/workflow[/eval]?phase=|step=|walk=&at=
let costModel = null, costErr = false, costGen = 0;
const costView = { open: [] };
const PAGES = [
  { id: "config", label: "Configure", needsFeed: false, refreshFeed: true, render: (f) => withLoginButton(render(f, { tile: state.tile, setup, state, msgs: setupMsgs, verify })), onVisit: () => { if (!state.vm || !state.vm.data) loadVm(); if (!state.reviewGate || !state.reviewGate.data) loadReviewGate(); if (!state.apiRoles || !state.apiRoles.data) loadApiRoles(); if (!state.fleetCap || !state.fleetCap.data) loadFleetCap(); if (!state.reports || !state.reports.data) loadReportSettings(); loadSetup(); } },
  { id: "health", label: "Health", needsFeed: false, refreshFeed: true, render: (f) => pageBar() + healthPage(f), onVisit: () => { if (!health) loadHealth(); loadProjects(); } },
  { id: "toolhealth", label: "Tool health", needsFeed: false, render: () => toolHealthPage(), onVisit: () => loadToolHealth(), afterPaint: () => thFocusBack() },
  { id: "board", label: "Board", needsFeed: false, render: trackerPage(() => renderBoard(roadmap, roadmapUi, boardExtras)), afterPaint: () => { whyFocus(null); loadDriftOrigins(); }, onVisit: () => { if (!(sources && !sources.length)) { if (!roadmap) loadRoadmap(); if (!boardExtras) loadBoard(); if (roadmapUi.tab === "nv" && !roadmapUi.nv) loadNoVersion(); } } },
  { id: "workflow", label: "Workflow", needsFeed: false, render: () => renderWorkflow(wfModel, wfUi, wfStats), onVisit: () => { if (!wfModel || wfModel.error || !wfStats || wfStats.error || Date.now() - wfAt > 60_000) loadWorkflow(); }, afterPaint: () => wfScroll() },
  { id: "cost", label: "Cost", needsFeed: false, render: () => (costErr ? `<p class="sub">The cost could not be read just now${costModel ? "; this is the last good read" : ""}.</p>` : "") + renderCost(costModel, { ...costView, err: costErr }), onVisit: () => loadCost(), afterPaint: () => costMount() },
  { id: "shift", label: "Shift", needsFeed: false, render: () => renderShift(shift, { ...shiftUi, fleet: (navLinks({ here: "console", token, current: "shift", sources }).find((l) => l.id === "fleet") || {}).href }), onVisit: () => loadShift() },
  { id: "report", label: "Morning report", needsFeed: false, render: () => pageBar() + renderReport(reportList, reportView, { ...reportUi, shiftHref: "#/shift" }), onVisit: () => loadReport() },
];
let unmountPage = null; // what the page's afterPaint returned: undoes its draw before the next paint replaces #main
let currentPage = PAGES[0];
const probeStatus = () => (lastProbe ? renderProbe(lastProbe) : `<p class="sub" id="status">loading…</p>`); // what a page that waits on, or shows, the report says meanwhile

// Settings and Setup became the one Configure page: their old routes still land on it, Setup with the Secrets tile open.
// (nav.js maps the AG-UI rail's page=setup landing the same way.)
const OLD_ROUTES = { setup: "secrets", configure: null };
const TILE_IDS = ["secrets", "review", "tracker", "scope"];

function route() {
  // a step's deep link (#s-<step>) and the docs page's ?phase=<id> land on the Workflow page
  if (/^#s-/.test(location.hash) || (!location.hash.startsWith("#/") && new URLSearchParams(location.search).has("phase"))) {
    const u = parseWorkflowRoute(location.hash, location.search);
    const q = u.step ? "step=" + encodeURIComponent(u.step) : u.phase ? "phase=" + u.phase : "";
    history.replaceState(null, "", location.pathname + "#/workflow" + (q ? "?" + q : ""));
  }
  // Roadmap and Kanban became the Board page: their routes land on it, #/roadmap/<v> keeping the version, #/kanban every version.
  let hash = location.hash;
  const alias = /^#\/(roadmap|kanban)(?:\/([^/?#]+))?/.exec(hash);
  if (alias) {
    let v = alias[1] === "kanban" ? "all" : null;
    if (alias[2]) { try { v = decodeURIComponent(alias[2]); } catch (_) { v = alias[2]; } }
    hash = "#/board" + (v ? "?v=" + encodeURIComponent(v) : "");
    history.replaceState(null, "", location.pathname + location.search + hash);
  }
  const m = /^#\/(\w+)(?:\/([^/?#]+))?(?:\?([^#]*))?/.exec(hash) || [];
  const old = Object.hasOwn(OLD_ROUTES, m[1]);
  const id = old ? "config" : m[1];
  currentPage = PAGES.find((p) => p.id === id) || PAGES[0];
  // the open tile rides the hash (#/config?tile=tracker), so a reload keeps it; any other route leaves none open.
  const asked = old ? OLD_ROUTES[m[1]] : new URLSearchParams(m[3] || "").get("tile");
  state.tile = currentPage.id === "config" && TILE_IDS.includes(asked) ? asked : null; // an unknown ?tile= opens none (nav.js TILES; slow.test.ts runs this file without its imports)
  if (currentPage.id === "toolhealth") {
    const q = new URLSearchParams(m[3] || ""), was = thUi.tool;
    thUi.tab = TH_TABS.includes(m[2]) ? m[2] : "overview";
    thUi.filters = Object.fromEntries(["days", "team", "lane", "profile"].map((k) => [k, q.get(k) || ""]).filter(([k, v]) => v && (k !== "days" || v === "7" || v === "30")));
    thUi.tool = q.get("tool");
    thUi.guard = q.get("guard");
    thReturn = was && !thUi.tool ? was : null;
  }
  if (currentPage.id === "health") {
    const was = healthView.project;
    healthView = parseView(m[3]);
    if (healthView.project !== was) { otherFeed = null; otherGen++; } // never show the last project's rows under this one's name
  }
  if (old || id !== currentPage.id) history.replaceState(null, "", location.pathname + location.search + "#/" + currentPage.id + (state.tile ? "?tile=" + state.tile : ""));
  const bq = new URLSearchParams(currentPage.id === "board" ? m[3] || "" : "");
  roadmapUi.tab = bq.get("tab"); roadmapUi.v = bq.get("v"); roadmapUi.at = bq.get("at"); roadmapUi.drawer = null; // a new route closes the drawer
  if (currentPage.id === "board" && boardExtras && askedVersion() !== boardAsked) loadBoard(); // a tile picked: the Chains tab reads that version
  const wasWhy = roadmapUi.why;
  roadmapUi.why = bq.get("why");
  shiftUi.id = null;
  shiftUi.all = new URLSearchParams(m[3] || "").get("all") === "1";
  const asked_day = new URLSearchParams(m[3] || "").get("day");
  reportUi.day = currentPage.id === "report" && /^\d{4}-\d{2}-\d{2}$/.test(asked_day || "") ? asked_day : null;
  if (currentPage.id === "shift" && m[2]) { try { shiftUi.id = decodeURIComponent(m[2]); } catch (_) { shiftUi.id = m[2]; } }
  if (currentPage.id === "workflow") Object.assign(wfUi, parseWorkflowRoute(location.hash, ""));
  if (unmountPage) { unmountPage(); unmountPage = null; } // the branch below can replace #main without a paint
  renderPages();
  loadFleet();
  if (currentPage.onVisit) currentPage.onVisit();
  if (feed || currentPage.needsFeed === false) paint();
  else { $("#main").innerHTML = probeStatus(); $("#nav").innerHTML = ""; } // no stale page under this tab
  whyFocus(wasWhy);
  // back on Configure (or another feed page), pick up a newer report the server loaded in the background.
  if (feed && (currentPage.needsFeed !== false || currentPage.refreshFeed)) refreshFeed();
}
addEventListener("hashchange", route);
route();
loadSources();

// The rail (nav.js, shared with the AG-UI page): Config and Health are routes here, Fleet is /agui/.
function renderPages() {
  const dots = { fleet: fleetDot(fleet.data, fleet.error), health: healthDot(verdict(feed, health)) };
  const waiting = shift && shift.state === "open" ? shift.waiting.length : 0; // the Shift entry's badge: rows waiting on the operator
  $("#pages").innerHTML = railMarkup({ token, current: currentPage.id, sources, dots, waiting });
}

// The page bar (spec 8044 section 2): the slot under the top of a page for that page's own controls, never the rail.
// Health holds the project picker, Report its day picker and refresh; Shift has none.
// One line on desktop; at 760 px the controls fold behind "Filters (n on)" (app.css).
function pageBar() {
  if (currentPage.id !== "health" && currentPage.id !== "report") return "";
  const ctl = currentPage.id === "health" ? projectPicker() : currentPage.id === "report" ? reportBar(reportList, reportView, reportUi) : "";
  const on = currentPage.id === "health" && (healthView.mode === "all" || (healthView.project && projects && healthView.project !== projects.current)) ? 1 : 0;
  const fold = ctl ? `<button type="button" class="pb-fold" aria-expanded="${pagebarOpen}" aria-controls="pb-ctl">Filters (${on} on)</button>` : "";
  return `<div class="pagebar${pagebarOpen ? " open" : ""}" id="pagebar" data-page="${currentPage.id}"${ctl ? "" : " hidden"}>${fold}<div class="pb-ctl" id="pb-ctl">${ctl}</div></div>`;
}

// The page bar's project picker, drawn on the Health page only (only Health reloads /api/projects): "All my projects" first, then each registered project with its own verdict (shared rows left out).
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
  const view = { ...healthView, projects, project: healthView.project || cur, foreign: Boolean(other), fleetHref: fleetLink && fleetLink.href, unchecked: Boolean(other) && otherFeed === "none", chief: chiefLive(cur), himmelChief: chiefLive("himmel") };
  // the filterable Inventory stays below the v2 page until its e2e is ported to the Every item checked tab; Triage is the broken tab now.
  const legacy = shown && !other && healthView.mode !== "all" ? renderInventory(shown, state) : "";
  return renderHealth(shown, health, view) + legacy + (!shown && !other && healthView.mode !== "all" ? probeStatus() : "");
}
// Is a chief session of this project live? true/false from the fleet read, undefined until it lands (the row then says only
// "for the chief"). A chief is named <KEY>-…, the key being the project's name uppercased (health.js chiefLiveFor); shared rows
// ask for "himmel", the harness's own project. ponytail: a name prefix, upgrade path: a project field on each fleet row.
function chiefLive(project) {
  return project ? chiefLiveFor(fleet.data, project) : undefined;
}
const healthHash = (v) => {
  const q = new URLSearchParams();
  if (v.mode === "all") q.set("view", "all"); else if (v.project) q.set("project", v.project);
  if (v.tab === "all") q.set("tab", "all");
  if (v.row) q.set("row", v.row);
  if (v.tile) q.set("tile", v.tile);
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
  if (currentPage.id === "board") paint();
}

async function loadFleet() {
  try {
    const r = await fetch("/api/agui/fleet", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    fleet = r.ok ? { data: await r.json(), error: null } : { data: null, error: r.status === 401 ? "the token was refused" : `the server answered ${r.status}` };
  } catch (_) { fleet = { data: null, error: "server unreachable" }; }
  renderPages();
  if (currentPage.id === "health" && (feed || otherFeed)) paint(); // a chief row says whether a chief is live, so it waits on this read
  // the rail's Shift badge counts Waiting rows on every page: read the shift after a fleet read that worked, at most once a minute
  if (fleet.data && currentPage.id !== "shift" && Date.now() - shiftAt > 60_000) loadShift();
}

function paint() {
  const buildOpen = $("#top details")?.open;
  const focusBuild = document.activeElement === $("#top summary");
  const keep = document.activeElement && document.activeElement.id === "q" ? document.activeElement.selectionStart : null;
  const focusK = document.activeElement && document.activeElement.matches && document.activeElement.matches(".row-head") ? document.activeElement.dataset.k : null;
  const focusB = document.activeElement && document.activeElement.matches && document.activeElement.matches(".bhead") ? document.activeElement.dataset.b : null;
  const focusRg = document.activeElement && document.activeElement.matches && document.activeElement.matches("[data-rg]") ? { rg: document.activeElement.dataset.rg, slug: document.activeElement.dataset.slug } : null;
  const focusT = document.activeElement && document.activeElement.matches && document.activeElement.matches("button.tile") ? document.activeElement.dataset.tile : null;
  const focusP = document.activeElement && document.activeElement.matches && document.activeElement.matches("button.dr") ? document.activeElement.dataset.phase : null;
  const focusD = document.activeElement && document.activeElement.closest && document.activeElement.closest(".drawer") ? { act: document.activeElement.dataset.act, cmd: document.activeElement.dataset.cmd } : null; // any repaint (the history landing, a refresh) keeps keyboard focus on the same drawer control
  // A secret or path being typed lives only in its field: a repaint (a report landing, a read finishing) must not wipe it.
  // It is held in this one synchronous call and put straight back; it is never kept in page state.
  const typing = [...document.querySelectorAll("input[data-secret],input[data-path],input[data-account]")].map((i) => ({ sel: ["secret", "path", "account"].map((a) => (i.dataset[a] !== undefined ? `input[data-${a}="${i.dataset[a]}"]` : "")).find(Boolean), value: i.value, edited: i.value !== i.defaultValue, had: i === document.activeElement, from: i.selectionStart, to: i.selectionEnd }));
  if (unmountPage) { unmountPage(); unmountPage = null; }
  $("#main").innerHTML = currentPage.render(feed);
  if (currentPage.afterPaint) unmountPage = currentPage.afterPaint();
  // only an edited field (even one emptied) is put back; an untouched one takes the value the repaint rendered from the fresh read
  for (const t of typing) { const i = document.querySelector(t.sel); if (i) { if (t.edited) i.value = t.value; if (t.had) { i.focus(); i.setSelectionRange(t.from, t.to); } } }
  $("#nav").innerHTML = "";
  $("#top").innerHTML = renderHeader(feed) + loginBadge();
  const buildDetails = $("#top details");
  if (buildOpen && buildDetails) buildDetails.open = true;
  if (focusBuild) $("#top summary")?.focus();
  renderPages(); // the Health dot follows the feed and the health read
  $("#where").textContent = `${location.host} · ${feed && feed.target ? feed.target.scope : "?"} scope`;
  if (focusK !== null) { for (const h of document.querySelectorAll(".row-head")) if (h.dataset.k === focusK) { h.focus(); break; } }
  if (focusB !== null) { for (const h of document.querySelectorAll(".bhead")) if (h.dataset.b === focusB) { h.focus(); break; } }
  if (focusRg !== null) { for (const c of document.querySelectorAll("[data-rg]")) if (c.dataset.rg === focusRg.rg && c.dataset.slug === focusRg.slug) { c.focus(); break; } }
  if (focusT !== null) { for (const t of document.querySelectorAll("button.tile")) if (t.dataset.tile === focusT) { t.focus(); break; } }
  if (focusP !== null) { for (const b of document.querySelectorAll("button.dr")) if (b.dataset.phase === focusP) { b.focus(); break; } }
  if (focusD) { const c =[...document.querySelectorAll(".drawer [data-act]")].find((x) => x.dataset.act === focusD.act && x.dataset.cmd === focusD.cmd); if (c) c.focus(); }
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

// Read-only mode (himmelctl ui --read-only): GET /api/mode says so once on load. The server refuses every write with 403 whatever
// this page does; the page shows the banner and disables the write controls so nothing offers a change that cannot land.
let readOnly = false;
const WRITE_CONTROLS = [
  '[data-act="plan"]', '[data-act="run"]', '[data-act="consent"]', '[data-act="vm-save"]', '[data-act="reports-save"]', '[data-act="review-gate-save"]', '[data-act="role-toggle"]', '[data-act="roles-save"]',
  '[data-act="setup-remove"]', '[data-act="setup-verify"]', '[data-act="drift-refresh"]',
  '[data-vm]', '[data-rs]', '[data-fc]', '[data-rg]', 'select.rm-theme',
  'form[data-setup-form] :is(input,button)', 'form[data-path-form] :is(input,button)', 'form[data-account-form] :is(input,button)',
].join(",");
function lockWrites() {
  for (const el of document.querySelectorAll(WRITE_CONTROLS)) el.disabled = true;
  for (const el of document.querySelectorAll("[data-rm-card]")) el.draggable = false;
}
async function loadMode() {
  let readOnlyNow = false;
  try {
    const r = await fetch("/api/mode", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    if (r.status === 401) session = false; // no token and no session: not logged in. A token-less read-only server answers the same, so its Log in leads to a 403 (accepted: telling it apart would need a signal on a 401)
    if (!r.ok) { if (session === false && (feed || currentPage.needsFeed === false)) paint(); return; }
    readOnlyNow = (await r.json()).readOnly === true;
    const held = r.headers.get("X-Himmel-Session"); // the cookie is HttpOnly, so the server says whether this browser holds a session
    session = readOnlyNow || held === null ? null : held === "1"; // a read-only server refuses login and logout too: the header offers neither
  } catch (_) { return; } // no answer: the server still refuses writes itself
  if (feed || currentPage.needsFeed === false) paint();
  if (!readOnlyNow) return;
  readOnly = true;
  $("#read-only-banner").hidden = false;
  document.body.dataset.readOnly = "1";
  lockWrites();
  new MutationObserver(lockWrites).observe($("#main"), { childList: true, subtree: true });
}
loadMode();
if (!landing) adoptToken().then((ok) => { if (ok) renderPages(); });

// /login takes ?next=, the page to come back to; login.js accepts only a path on this site. The address holds no typed value.
function loginHref() { return "/login?next=" + encodeURIComponent(location.pathname + location.search + location.hash); }
function loginBadge() {
  if (session === null) return "";
  return `<div id="login-state"><span class="k">login</span> ${session ? `logged in · <button class="btn" type="button" data-act="logout">Log out</button>` : `not logged in · <a class="btn" href="${loginHref()}" target="_blank" rel="noopener">Log in</a>`}</div>`;
}
async function logout() {
  const { ok } = await post("/api/logout", {});
  if (ok) { session = false; if (feed || currentPage.needsFeed === false) paint(); }
  loadMode();
}
// A save refused for want of a session says so in the row, with Log in beside it (NEEDS_LOGIN is declared with `session`, before route() paints).
function withLoginButton(html) { return html.split(`role="status">${NEEDS_LOGIN}</span>`).join(`role="status">${NEEDS_LOGIN} <a class="btn primary" href="${loginHref()}" target="_blank" rel="noopener">Log in</a></span>`); }

async function post(path, body) {
  if (readOnly) return { ok: false, status: 403, j: { error: "read-only: this config UI was started with --read-only" } };
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

// the Reports and shifts card. The draft is what the operator is typing; a saved or loaded answer resets it.
const reportsDraft = (d) => ({ report_day: d.report_day, idle: String(d.shift_idle_min), cut1: d.shift_cuts[0], cut2: d.shift_cuts[1], minrun: String(d.shift_min_run_h) });
async function loadReportSettings() {
  const gen = ++reportsLoadGen;
  state.reports = { data: null, error: null };
  try {
    const r = await fetch("/api/report-settings", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = await r.json();
    if (gen !== reportsLoadGen) return;
    state.reports = r.ok ? { data: j, error: null, draft: reportsDraft(j) } : { data: null, error: j.error || `report settings failed (${r.status})` };
  } catch (_) { if (gen !== reportsLoadGen) return; state.reports = { data: null, error: "report settings: server unreachable" }; }
  if (currentPage.id === "config") paint();
}
async function saveReportSettings() {
  const d = state.reports && state.reports.draft;
  if (!d || reportsSaving) return;
  reportsSaving = true;
  const sent = JSON.stringify(d);
  let res;
  try { res = await post("/api/report-settings", { report_day: d.report_day, shift_idle_min: d.idle.trim(), shift_cuts: [d.cut1.trim(), d.cut2.trim()], shift_min_run_h: d.minrun.trim() }); } finally { reportsSaving = false; }
  const { ok, j } = res;
  const edited = state.reports.draft && JSON.stringify(state.reports.draft) !== sent;
  state.reports = ok ? { data: j, error: null, draft: edited ? state.reports.draft : reportsDraft(j), msg: { ok: true, text: "saved; a new day start applies from the next report on" } } : { ...state.reports, msg: { ok: false, text: j.error || "save failed" } };
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

// the Multi accounts section (Configure -> Secrets). The draft is the pending role map; a loaded or saved answer resets it.
async function loadApiRoles(msg) {
  const gen = ++apiRolesLoadGen;
  if (!state.apiRoles || !state.apiRoles.data) state.apiRoles = { data: null, error: null };
  try {
    const r = await fetch("/api/api-roles", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = await r.json();
    if (gen !== apiRolesLoadGen) return;
    state.apiRoles = r.ok ? { data: j, error: null, draft: apiRolesDraft(j), preview: false, msg: msg || null } : { data: null, error: j.error || `role map failed (${r.status})` };
  } catch (_) { if (gen !== apiRolesLoadGen) return; state.apiRoles = { data: null, error: "role map: server unreachable" }; }
  if (currentPage.id === "config") paint();
}
async function saveApiRoles() {
  const ar = state.apiRoles;
  if (!ar || !ar.draft || apiRolesSaving) return;
  apiRolesSaving = true;
  let res;
  try { res = await post("/api/api-roles", ar.draft); } finally { apiRolesSaving = false; }
  if (res.ok) return void loadApiRoles({ ok: true, text: "saved" });
  const errors = Array.isArray(res.j.errors) ? res.j.errors.join(", ") : "";
  state.apiRoles = { ...state.apiRoles, msg: { ok: false, text: errors ? `not saved: ${errors}` : res.j.error || "save failed" } };
  paint();
}
function toggleApiRole(role, letter) {
  const ar = state.apiRoles;
  if (!ar || !ar.draft || apiRolesSaving) return;
  const now = ar.draft[role] || [], next = now.includes(letter) ? now.filter((l) => l !== letter) : [...now, letter].sort();
  if (next.length) ar.draft[role] = next; else delete ar.draft[role];
  ar.msg = null;
  paint();
}

// Only the newest call may paint, as with the feed.
async function loadHealth() {
  const gen = ++healthGen;
  let j;
  try {
    const [r, qr, rr] = await Promise.all([
      fetch("/api/health", { headers: { "X-Himmel-Token": token } }),
      fetch("/api/bank", { headers: { "X-Himmel-Token": token } }).catch(() => null), // the panel degrades alone
      fetch("/api/rollup", { headers: { "X-Himmel-Token": token } }).catch(() => null),
    ]);
    j = r.ok ? await r.json() : null;
    if (!j) toast(`health sources failed (${r.status})`);
    else {
      if (qr && qr.ok) j.quota = await qr.json().catch(() => undefined); // a bad bank body must not drop the health cards
      if (rr && rr.ok) j.rollup = await rr.json().catch(() => undefined);
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
  const { ok, status, j } = await post("/api/setup/secret", body);
  const needsLogin = status === 401 || (status === 403 && /^service mode: log in/.test(j.error || "")); // 401: no token and no session (a read-only server answers 403 before auth)
  if (needsLogin) session = false;
  setupMsgs[name] = ok ? (op === "set" ? "saved" : "removed") : needsLogin ? NEEDS_LOGIN : (j.error || "failed");
  const s = ok && setup && setup.secrets && setup.secrets.find((x) => x.name === name);
  if (s) s.status = j.status;
  paint();
  if (ok && session === false) loadMode(); // a login in another tab made this save work: the header says so
}

// a filter change reads again; a tab or drill-in change reuses the answer already held. force: the Refresh button.
function loadToolHealth(force = false) {
  const { health: toolHealth, inventory: toolInventory, reviewers: toolReviewers } = thLoaders();
  const q = new URLSearchParams(thUi.filters).toString();
  if (force || q !== thQuery || (!toolHealth.state.data && !toolHealth.state.loading)) { thQuery = q; toolHealth.load(q); }
  if (force || (!toolInventory.state.data && !toolInventory.state.loading)) toolInventory.load("");
  if (force || (!toolReviewers.state.data && !toolReviewers.state.loading)) toolReviewers.load("");
}
// The server CSP refuses inline style attributes, so bar widths and map columns are set through the CSSOM after paint.
// Leaving a drill-in puts focus back on the row that opened it.
function thFocusBack() {
  for (const el of document.querySelectorAll(".thbar[data-w]")) el.style.setProperty("--w", `${el.dataset.w}%`);
  for (const el of document.querySelectorAll(".thmap[data-cols]")) el.style.setProperty("--cols", el.dataset.cols);
  const back = thReturn && [...document.querySelectorAll("a[data-tool]")].find((a) => a.dataset.tool === thReturn);
  if (back) { back.focus(); thReturn = null; }
}
function toolHealthPage() {
  const l = thLoaders(), inv = l.inventory.state, rv = l.reviewers.state;
  return renderToolHealth({
    ...l.health.state,
    inventory: inv.data ? (inv.error ? { ...inv.data, stale: inv.error } : inv.data) : inv.error ? { state: "error", reason: inv.error } : null,
    reviewers: rv.data ? (rv.error ? { ...rv.data, stale: rv.error } : rv.data) : rv.error ? { state: "error", reason: rv.error } : undefined,
    shift,
  }, token, thUi);
}
// the open shift, or the closed one named by shiftUi.id; read live, only the newest call may land.
async function loadShift() {
  const gen = ++shiftGen;
  shiftAt = Date.now();
  let data;
  try {
    const r = await fetch("/api/shift" + (shiftUi.id ? "?id=" + encodeURIComponent(shiftUi.id) : ""), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : { reason: `shift failed (${r.status})` };
  } catch (_) { data = { reason: "server unreachable" }; }
  if (gen !== shiftGen) return;
  shift = data;
  renderPages();
  if (currentPage.id === "shift") paint();
}
// the Workflow page: the workflow model (once) and the per-phase numbers; only the newest read may land.
async function loadWorkflow() {
  const gen = ++wfGen;
  wfAt = Date.now();
  const get = async (path, headers) => {
    const r = await fetch(path, { headers, cache: "no-store" });
    if (!r.ok) throw new Error(`the server answered ${r.status}`);
    return r.json();
  };
  const [m, s] = await Promise.allSettled([wfModel && !wfModel.error ? wfModel : get("/dev-graph/graph.json", {}), get("/api/phase-stats", { "X-Himmel-Token": token })]);
  if (gen !== wfGen) return;
  wfModel = m.status === "fulfilled" ? m.value : { error: m.reason instanceof Error ? m.reason.message : "server unreachable" };
  wfStats = s.status === "fulfilled" ? s.value : { error: s.reason instanceof Error ? s.reason.message : "server unreachable" };
  if (currentPage.id === "workflow") paint();
}
async function loadCost() {
  const gen = ++costGen;
  try {
    const r = await fetch("/api/cost", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    if (!r.ok) throw new Error(`the server answered ${r.status}`);
    const m = await r.json();
    if (gen !== costGen) return;
    costModel = m; costErr = false;
  } catch (_) { if (gen !== costGen) return; costErr = true; }
  if (currentPage.id === "cost") paint();
}
// The bars' widths come in the markup as style attributes, which the page's CSP (default-src 'self') refuses, so they are set here.
function costMount() {
  const main = $("#main");
  for (const el of main.querySelectorAll(".bar[style]")) el.style.width = (/width:\s*([\d.]+%)/.exec(el.getAttribute("style")) || [])[1] || "0%";
  const onClick = (e) => {
    const b = e.target.closest && e.target.closest("button.dr");
    const id = b && b.dataset.phase;
    if (!id) return;
    costView.open = costView.open.includes(id) ? costView.open.filter((x) => x !== id) : [...costView.open, id];
    paint();
    const again = [...main.querySelectorAll("button.dr")].find((x) => x.dataset.phase === id);
    if (again) again.focus();
  };
  main.addEventListener("click", onClick);
  return () => main.removeEventListener("click", onClick);
}
// a step link or a walk scrolls its card (or the opened phase) into view, once per route: a later repaint never jumps.
function wfScroll() {
  const el = document.querySelector(".wf-step.wf-hl") || (wfUi.phase && document.getElementById("pp-" + wfUi.phase));
  if (el && wfModel && !wfModel.error && wfScrolled !== location.hash) { wfScrolled = location.hash; el.scrollIntoView({ block: "center" }); }
  if (!el) wfScrolled = null;
}
// the report list, then the chosen day (the one in the route, else the newest); read live, only the newest call may land.
async function loadReport() {
  const gen = ++reportGen;
  const get = async (p) => { const r = await fetch(p, { headers: { "X-Himmel-Token": token }, cache: "no-store" }); if (!r.ok) throw new Error(String(r.status)); return r.json(); };
  let list, view = null;
  try {
    list = await get("/api/reports");
    const day = reportUi.day || list.newest || list.today;
    if (day) view = await get("/api/report?day=" + encodeURIComponent(day));
  } catch (e) { if (gen !== reportGen) return; reportList = { error: `the reports could not be read (${e.message})` }; reportView = null; if (currentPage.id === "report") paint(); return; }
  if (gen !== reportGen) return;
  reportList = list;
  reportView = view;
  if (currentPage.id === "report") paint();
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
  if (data.state === "ok") roadmapUi.readAt = Date.now(); // the Board's read line says when, and the self-refresh counts from here
  roadmapUi.writes = data.source !== "github"; // GitHub cards are read-only
  if (currentPage.id === "board") paint();
  // Waiting on you lists the operator-labelled tickets with no version, which only the No version read carries (a local mirror read, no network): ask for it beside the default one
  if (data.noVersionCount && !roadmapUi.nv && roadmapUi.tab !== "nv") loadNoVersion();
}
// the Board's No version tab: those tickets are not in the default read, so they are fetched when the tab opens (and again on refresh).
async function loadNoVersion() {
  const gen = ++nvGen;
  let data;
  try {
    const r = await fetch("/api/roadmap?nv=1", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : { state: "error", reason: `roadmap failed (${r.status})` };
  } catch (_) { data = { state: "error", reason: "server unreachable" }; }
  if (gen !== nvGen) return;
  roadmapUi.nv = data;
  if (currentPage.id === "board") paint();
}
// the version tile the Chains tab reads; "all" is never sent (the tab has no all-versions choice)
function askedVersion() { return roadmapUi.v && roadmapUi.v !== "all" ? roadmapUi.v : ""; }
// the Board's drift summary and chain read: each part absent on its own, so a missing registry never hides the lanes.
async function loadBoard() {
  const gen = ++boardGen;
  let data;
  boardAsked = askedVersion();
  try {
    const r = await fetch("/api/board" + (boardAsked ? "?v=" + encodeURIComponent(boardAsked) : ""), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    data = r.ok ? await r.json() : null;
  } catch (_) { data = null; }
  if (gen !== boardGen) return;
  boardExtras = data || { drift: { state: "absent", reason: "the board read failed" }, chains: { state: "absent", reason: "the board read failed" } };
  if (currentPage.id === "board") paint();
}
// Tidy up's origin column: each drift row's ticket has its Jira history read once, one at a time, only while the tab is open. A failed read is kept as one.
async function loadDriftOrigins() {
  if (originsReading || roadmapUi.tab !== "tidy") return;
  const dr = boardExtras && boardExtras.drift, seen = roadmapUi.driftOrigins || (roadmapUi.driftOrigins = {});
  const next = dr && dr.real ? [...dr.real, ...dr.known, ...dr.transient].map((r) => r.key).find((k) => !seen[k]) : undefined;
  if (!next) return;
  originsReading = true;
  let h;
  try {
    const r = await fetch("/api/roadmap/history?key=" + encodeURIComponent(next), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    h = r.ok ? await r.json() : { error: "history unavailable" };
  } catch (_) { h = { error: "history unavailable" }; }
  originsReading = false;
  (roadmapUi.driftOrigins || {})[next] = h;
  if (currentPage.id === "board") paint(); // the paint's afterPaint asks for the next key
}
// Tidy up's Refresh: the server runs the check once for every caller; the saved rows stay on screen until it answers.
async function refreshDriftRun() {
  if (roadmapUi.driftRun && roadmapUi.driftRun.state === "running") return;
  const before = boardExtras && boardExtras.drift;
  roadmapUi.driftRun = { state: "running", started: new Date().toTimeString().slice(0, 8) };
  paint();
  const { ok, j } = await post("/api/board/drift-refresh", {});
  if (!ok || j.state !== "ok") { roadmapUi.driftRun = { state: "failed", reason: j.reason || j.error || "the re-run failed" }; if (currentPage.id === "board") paint(); return; }
  await loadBoard();
  roadmapUi.driftOrigins = {}; // a new run may name a move made since the last read
  roadmapUi.driftRun = { state: "done", since: driftSince(before, boardExtras.drift) };
  if (currentPage.id === "board") paint();
}
// a drop or a Sector select goes to Jira, or to the local tracker store for a local card, through the server. The board is
// redrawn from the server's data either way: on a refusal nothing local changed, so the card is back where it was and the
// reason is shown above the board.
let rmWriting = false;
// a card is named by its number and its project (two projects share numbers); a card with no project (GitHub, local) has none
const rmTicket = (k, project) => (roadmap && roadmap.state === "ok" ? roadmap.tickets.find((x) => x.k === k && (x.project || "") === (project || "")) : undefined)
  || (roadmapUi.nv && roadmapUi.nv.state === "ok" ? roadmapUi.nv.tickets.find((x) => x.k === k && (x.project || "") === (project || "")) : undefined); // a card on the No version tab is in the second read
async function writeRoadmap(t, change) {
  if (rmWriting || !t || roadmapUi.drawer) return; // a write is held while the drawer is open: the board under it is inert, and this is the one place every write passes
  const local = t.backend === "local";
  const body = { key: t.id || "HIMMEL-" + t.k, ...(local ? { backend: "local" } : {}), ...change }; // the card's own key: its project is never a default
  rmWriting = true; roadmapUi.writeError = null; roadmapUi.held = null;
  const { ok, j } = await post("/api/roadmap/write", body);
  rmWriting = false;
  if (!ok) { roadmapUi.writeError = `${body.key}: ${j.error || "write failed"}${j.output ? " (" + String(j.output).trim().slice(0, 200) + ")" : ""}`; return paint(); }
  if ("status" in j) { const c = COLS_BY_ID[j.status]; t.b = j.status; t.s = j.name || c || t.s; }
  else {
    const src = roadmapUi.nv && roadmapUi.nv.tickets && roadmapUi.nv.tickets.includes(t) ? roadmapUi.nv : roadmap; // the read this card came from
    let i = src.themes.indexOf(j.sector);
    if (i < 0) { src.themes.push(j.sector); i = src.themes.length - 1; }
    t.theme = i;
  }
  paint();
  if (j.mirror === "refreshed" || local) loadRoadmap();
}
const COLS_BY_ID = { todo: "To Do", prog: "In Progress", rev: "In Review", ci: "IN CI", done: "Done", wont: "wont do" };
let rmDrag = null;
document.addEventListener("dragstart", (e) => {
  const c = e.target.closest && e.target.closest("[data-rm-card]");
  if (!c) return;
  if (readOnly) return void e.preventDefault();
  rmDrag = { k: Number(c.dataset.rmCard), project: c.dataset.rmProject || "" };
  try { e.dataTransfer.setData("text/plain", c.dataset.rmId || (rmDrag.project || "HIMMEL") + "-" + rmDrag.k); e.dataTransfer.effectAllowed = "move"; } catch (_) { /* no dataTransfer */ }
});
document.addEventListener("dragover", (e) => { if (rmDrag !== null && e.target.closest && e.target.closest("[data-rm-drop]")) e.preventDefault(); });
document.addEventListener("drop", (e) => {
  const col = e.target.closest && e.target.closest("[data-rm-drop]");
  if (rmDrag === null || !col) return;
  e.preventDefault();
  const card = rmDrag; rmDrag = null;
  const t = rmTicket(card.k, card.project);
  if (t && EVENT_OWNED.has(col.dataset.rmDrop)) { // In review, CI and Done are moved by their event (a PR opening, CI, the merge): a drop there is held, nothing is written (ruling Q4)
    if (t.b !== col.dataset.rmDrop && !(col.dataset.rmDrop === "rev" && t.b === "ci")) { roadmapUi.held = `${t.id || "HIMMEL-" + t.k}: ${COLS_BY_ID[col.dataset.rmDrop]} is moved by its event, not by a drop. Nothing was written.`; paint(); }
    return;
  }
  if (t && t.b !== col.dataset.rmDrop) writeRoadmap(t, { status: col.dataset.rmDrop });
});
const EVENT_OWNED = new Set(["rev", "ci", "done"]);
const CARD_COLS = ["todo", "prog", "rev", "ci", "done", "wont"]; // the board's column order, left to right

// The Why panel on the Chains tab is a route (why=<ticket>.<blocker>), so a link opens it and its close link shuts it. Apart from the drawer: focus goes
// into the panel on opening and back to the link that opened it on closing; Esc follows the close link.
function whyFocus(was) {
  if (roadmapUi.why) document.querySelector(".rm-why-close")?.focus();
  else if (was) document.querySelector(`[data-why-open="${CSS.escape(was)}"]`)?.focus();
}
// A repaint must not fold a change log the operator opened.
document.addEventListener("toggle", (e) => {
  const id = e.target.dataset && e.target.dataset.log;
  if (!id) return;
  roadmapUi.logOpen = roadmapUi.logOpen.filter((x) => x !== id).concat(e.target.open ? [id] : []);
}, true);

// The ticket drawer: a click, Enter or Space on a card opens it; its stage history is fetched then and only then (never per card, never on load).
const cardSel = (k, project) => `[data-rm-open="${k}"]` + (project ? `[data-rm-project="${CSS.escape(project)}"]` : ":not([data-rm-project])");
function openDrawer(c) {
  const k = Number(c.dataset.rmOpen), project = c.dataset.rmProject || "", t = rmTicket(k, project);
  if (!t) return;
  const dr = { k, project, history: null };
  roadmapUi.drawer = dr; roadmapUi.held = null;
  paint();
  const close = document.querySelector(".drawer [data-act=rm-close]");
  if (close) close.focus();
  if (t.backend === "jira") void loadHistory(t, dr);
}
async function loadHistory(t, dr) {
  let h = { error: "history unavailable" }; // a failed read is never an empty list
  try {
    const r = await fetch("/api/roadmap/history?key=" + encodeURIComponent(t.id || "HIMMEL-" + t.k), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    const j = r.ok ? await r.json().catch(() => null) : null;
    if (j && Array.isArray(j.events)) h = { events: j.events };
  } catch (_) { /* unavailable */ }
  if (roadmapUi.drawer === dr) { dr.history = h; paint(); }
}
function closeDrawer() {
  const dr = roadmapUi.drawer;
  if (!dr) return;
  roadmapUi.drawer = null;
  paint();
  const c = document.querySelector(cardSel(dr.k, dr.project));
  const lane = c && c.closest("details"); // a Done card lives in the folded Done lane, which the repaint just folded again: a card in a closed <details> cannot take focus
  if (lane) lane.open = true;
  if (c) c.focus();
}
// Shift+Left / Shift+Right on a focused card moves it to the next column its operator may write (To do, In progress, Won't), through the same write as a drop.
async function moveByKey(c, dir) {
  const k = Number(c.dataset.rmOpen), project = c.dataset.rmProject || "", t = rmTicket(k, project);
  let j = CARD_COLS.indexOf(t && t.b) + dir;
  while (j >= 0 && j < CARD_COLS.length && EVENT_OWNED.has(CARD_COLS[j])) j += dir;
  if (!t || j < 0 || j >= CARD_COLS.length) return;
  await writeRoadmap(t, { status: CARD_COLS[j] });
  const again = document.querySelector(cardSel(k, project));
  if (again) again.focus();
}
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && roadmapUi.drawer) return void closeDrawer();
  if (e.key === "Escape" && roadmapUi.why) return void document.querySelector(".rm-why-close")?.click();
  const c = e.target.closest && e.target.closest("[data-rm-open]");
  if (!c || e.target !== c) return; // only the focused card itself, never a select or a link inside it
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); return void openDrawer(c); }
  if (e.shiftKey && (e.key === "ArrowLeft" || e.key === "ArrowRight") && c.hasAttribute("data-rm-card")) { e.preventDefault(); void moveByKey(c, e.key === "ArrowRight" ? 1 : -1); }
});
document.addEventListener("dragend", () => { rmDrag = null; });
// The Board reads itself again at a bounded interval (roadmap.js BOARD_REFRESH_MS), checked on a 10 s tick; boardRefreshDue holds back while the page is hidden, a drawer
// is open, a field has focus, a card is being dragged or a read of this kind is still running.
let boardReads = 0;
setInterval(() => { // t13b-ok: a bounded 10 s tick that lives and dies with the open Board page, no background service
  if (typeof document === "undefined") return; // a suite that imports this module without a page has nothing to refresh
  const a = document.activeElement;
  if (!boardRefreshDue({ page: currentPage.id, visible: document.visibilityState === "visible", modal: !!(roadmapUi.drawer || roadmapUi.why),
    editing: !!(a && /^(INPUT|SELECT|TEXTAREA)$/.test(a.tagName)), dragging: rmDrag !== null, busy: boardReads > 0, readAt: roadmapUi.readAt || 0, now: Date.now() })) return;
  boardReads++;
  roadmapUi.readAt = Date.now(); // the attempt counts: a server that is down is asked once per interval, not every tick
  Promise.all([loadRoadmap(), loadBoard(), roadmapUi.nv || roadmapUi.tab === "nv" ? loadNoVersion() : null]).finally(() => { boardReads--; });
}, 10_000);
document.addEventListener("change", (e) => {
  if (e.target.id === "proj") { // the page bar picker: it routes, the route reads the project
    const v = e.target.value;
    location.hash = v === "*" ?"#/health?view=all" : projects && v === projects.current ? "#/health" : "#/health?project=" + encodeURIComponent(v);
    return;
  }
  if (e.target.dataset.rmThemeKey) {
    const t = rmTicket(Number(e.target.dataset.rmThemeKey), e.target.dataset.rmProject), opt = e.target.selectedOptions && e.target.selectedOptions[0];
    // "new sector…" (a local card only): ask for the name; a cancel redraws the card as it was
    const sector = opt && opt.hasAttribute("data-rm-new") ? (prompt(`New Sector for ${t ? t.id : "this card"}`) || "").trim() : e.target.value;
    return void (sector ? writeRoadmap(t, { sector }) : paint());
  }
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
  if (e.target.dataset.rs === "report_day" && state.reports && state.reports.draft) { state.reports.draft.report_day = e.target.value; state.reports.msg = null; return paint(); }
  if (e.target.dataset.rmHideDone !== undefined) { roadmapUi.hideDone = e.target.checked; return paint(); }
  if (e.target.dataset.rmHidePrev !== undefined) { roadmapUi.hidePrev = e.target.checked; return paint(); }
  if (e.target.dataset.rmHideFuture !== undefined) { roadmapUi.hideFuture = e.target.checked; return paint(); }
  if (e.target.dataset.rmChain !== undefined) { roadmapUi.chain = e.target.value || null; return paint(); }
  if (e.target.dataset.rmFind !== undefined) { roadmapUi.find = e.target.value.trim() || null; return paint(); } // a text box commits on Enter or blur, so typing is never repainted under the cursor
  const f = e.target.dataset.rmFilter;
  if (f) { roadmapUi[f] = e.target.value === "" ? null : Number(e.target.value); return paint(); }
  const th = e.target.dataset.th;
  if (th === "src" || th === "sort") { thUi[th] = e.target.value || (th === "sort" ? "failed" : null); return paint(); }
  const name = e.target.dataset.toolFilter;
  if (!name) return;
  location.hash = toolHealthHref({ filters: { ...thUi.filters, [name]: e.target.value } }, { tab: thUi.tab, tool: thUi.tool, guard: thUi.guard }); // the route reads again
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

// A tab without the launch token has no Fleet to show: /agui/ would open the bundled replay as if it were live.
for (const type of ["click", "auxclick"]) document.addEventListener(type, (e) => {
  const link = e.target.closest && e.target.closest('a[href^="/agui/"]');
  if (token || !link) return;
  e.preventDefault();
  adoptToken().then((ok) => {
    if (!ok) return setStatus("This tab is not signed in, so Fleet is not available here: log in, then open Fleet again.");
    renderPages();
    if (type === "click") location.assign(link.getAttribute("href").replace(/#t=.*$/, "") + "#t=" + token);
    else setStatus("Fleet is ready for this tab: open it again.");
  });
});

document.addEventListener("click", (e) => {
  const card = e.target.closest && e.target.closest("[data-rm-open]");
  if (card && !e.target.closest("a,select,button,input,summary,[data-act]")) return void openDrawer(card);
  const b = e.target.closest("[data-act],[data-f]");
  if (!b) {
    const vc = e.target.closest("[data-rm-pin],[data-rm-show-all],[data-rm-clear-pins]"); // the Board's version strip controls
    if (!vc) return;
    if (vc.dataset.rmPin !== undefined) { const r = togglePin(roadmapUi.pins, vc.dataset.rmPin); roadmapUi.pins = r.pins; roadmapUi.pinMsg = r.msg; savePins(r.pins); }
    else if (vc.dataset.rmClearPins !== undefined) { roadmapUi.pins = []; roadmapUi.pinMsg = ""; savePins([]); }
    else roadmapUi.showAll = !roadmapUi.showAll;
    return void paint();
  }
  if (b.dataset.act === "rm-close") return void closeDrawer();
  if (b.dataset.act === "refresh-toolhealth") return void loadToolHealth(true);
  if (b.dataset.act && b.dataset.act.startsWith("th-")) return void toolHealthClick(b);
  if (b.dataset.act === "refresh-roadmap") { roadmapUi.nv = null; if (roadmapUi.tab === "nv") loadNoVersion(); return void (loadRoadmap(), loadBoard()); }
  if (b.dataset.act === "drift-refresh") return void refreshDriftRun();
  if (b.dataset.act === "refresh-shift") return void loadShift();
  if (b.dataset.act === "vm-save") return void saveVm();
  if (b.dataset.act === "reports-save") return void saveReportSettings();
  if (b.dataset.act === "refresh-report") return void loadReport();
  if (b.dataset.act === "review-gate-save") return void saveReviewGate();
  if (b.dataset.act === "role-toggle") return void toggleApiRole(b.dataset.role, b.dataset.account);
  if (b.dataset.act === "roles-save") return void saveApiRoles();
  if (b.dataset.act === "roles-preview" && state.apiRoles) { state.apiRoles.preview = true; return void paint(); }
  if (b.dataset.act === "roles-cancel" && state.apiRoles && state.apiRoles.data && !apiRolesSaving) { Object.assign(state.apiRoles, { draft: apiRolesDraft(state.apiRoles.data), preview: false, msg: null }); return void paint(); }
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
  if (b.dataset.act === "logout") return void logout();
  if (b.dataset.act === "setup-verify") return void runVerify();
  if (b.dataset.act === "refresh-health") { loadHealth(); loadFleet(); return void loadFeed(true); } // the verdict reads the doctor feed too; a chief row reads the Fleet census
  if (b.dataset.act === "open-config") return void (location.hash = "#/health?row=" + encodeURIComponent(b.dataset.id)); // a check's finding opens its row on Health
  if (b.dataset.act === "health-tab" || b.dataset.act === "health-row" || b.dataset.act === "health-tile") {
    // one tile panel open at a time; the open tile closes it again (tile=none keeps a self-opened Checks shut on reload)
    if (b.dataset.act === "health-tile") healthView.tile = b.getAttribute("aria-expanded") === "true" ? "none" : b.dataset.tile;
    else if (b.dataset.act === "health-tab") healthView.tab = b.dataset.tab;
    else healthView.row = healthView.row === b.dataset.id ? null : b.dataset.id;
    history.replaceState(null, "", location.pathname + location.search + healthHash(healthView));
    return paint();
  }
  if (b.dataset.act === "report-refresh") return loadReport();
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
  const rf = e.target.dataset.rs;
  if (rf && rf !== "report_day" && state.reports && state.reports.draft) { state.reports.draft[rf] = e.target.value; return; } // no repaint: keep the caret
  if (vf && vf !== "mode" && state.vm && state.vm.draft) { state.vm.draft[vf] = e.target.value; return; } // no repaint: keep the caret
  if (e.target.dataset.fc === "cap" && state.fleetCap && state.fleetCap.data) { state.fleetCap.draft = e.target.value; state.fleetCap.msg = null; return; } // typed text survives a repaint before blur
  if (e.target.dataset.rg === "model" && state.reviewGate && state.reviewGate.draft) {
    const x = state.reviewGate.draft.find((y) => y.slug === e.target.dataset.slug);
    if (x) { x.model = e.target.value; state.reviewGate.msg = null; }
    return;
  }
  if (e.target.id === "q") { state.filt.q = e.target.value; paint(); return; }
  if (e.target.id === "th-q") { // the search box survives the repaint it causes, caret and all
    const at = [e.target.selectionStart, e.target.selectionEnd];
    thUi.q = e.target.value;
    paint();
    const i = $("#th-q");
    if (i) { i.focus(); i.setSelectionRange(at[0], at[1]); }
    return;
  }
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

// Tool health's in-page controls: chips, picks and sorts are page memory and repaint; Rescan and Retry read again.
function toolHealthClick(b) {
  const v = b.dataset.v || null, act = b.dataset.act;
  if (act === "th-kind") thUi.kind = v;
  else if (act === "th-group") thUi.group = thUi.group === v ? null : v;
  else if (act === "th-before") thUi.before = !thUi.before;
  else if (act === "th-all") thUi.all = !thUi.all;
  else if (act === "th-pick") { const same = thUi.src === b.dataset.src && thUi.kind === b.dataset.kind; thUi.src = same ? null : b.dataset.src; thUi.kind = same ? null : b.dataset.kind; }
  else if (act === "th-sort") { const t = b.dataset.table, col = Number(b.dataset.col), was = thUi.sorts[t]; thUi.sorts[t] = { col, desc: !!(was && was.col === col && !was.desc) }; }
  else if (act === "th-rescan") return void thLoaders().inventory.load("rescan=1");
  else if (act === "th-reviewers") return void thLoaders().reviewers.load("");
  else if (act === "th-reset") Object.assign(thUi, { kind: null, src: null, q: "", group: null, all: false, before: false }); // a link to the current hash fires no hashchange, so paint here too
  else return;
  paint();
}

// The page bar's "Filters (n on)" fold at phone width: it toggles the class in place, no repaint.
document.addEventListener("click", (e) => {
  const b = e.target.closest && e.target.closest(".pb-fold");
  if (!b) return;
  pagebarOpen = !pagebarOpen;
  $("#pagebar").classList.toggle("open", pagebarOpen);
  b.setAttribute("aria-expanded", String(pagebarOpen));
});
