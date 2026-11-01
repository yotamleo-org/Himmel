// the Health page. Pure rendering, no DOM: renderHealth(feed, health, view) → HTML.
// feed = the doctor feed (null until it lands); health = GET /api/health ({bank, workers, monitoring, mode}),
// null while loading. Every value shown comes from its owner (I1): the feed's rows, the bank ledger
// row, workers.sh, Prometheus. The one verdict lives here (I6) and only counts what those sources say.
import { esc } from "./render.js";

const isTriage = (r) => r.health === "fail" || r.health === "warn";
const ok = (s) => s && s.state === "ok";

// The firing alerts, or null when Prometheus was not reachable (alerts not checked, never a verdict input).
const alertsOf = (health) => (health && health.monitoring && ok(health.monitoring.prometheus) ? health.monitoring.prometheus.alerts || [] : null);

// feed null = pending: "No data". fail or a firing page alert: "Act now". warn or any firing alert:
// "Needs a look". Else "All clear". An absent Prometheus never raises it.
export function verdict(feed, health) {
  if (!feed) return { word: "No data", cls: "off", fail: 0, warn: 0, alerts: alertsOf(health) };
  const rows = feed.rows || [];
  const fail = rows.filter((r) => r.health === "fail").length;
  const warn = rows.filter((r) => r.health === "warn").length;
  const alerts = alertsOf(health);
  const page = (alerts || []).some((a) => a.severity === "page");
  const word = fail > 0 || page ? "Act now" : warn > 0 || (alerts || []).length > 0 ? "Needs a look" : "All clear";
  return { word, cls: { "Act now": "fail", "Needs a look": "warn", "All clear": "ok" }[word], fail, warn, alerts };
}

// A project's own verdict: only the rows that belong to it, never the shared ones (the Shared panel owns those).
export function projectVerdict(counts) {
  const fail = (counts && counts.fail) || 0, warn = (counts && counts.warn) || 0;
  const word = fail > 0 ? "Act now" : warn > 0 ? "Needs a look" : "All clear";
  return { word, cls: { "Act now": "fail", "Needs a look": "warn", "All clear": "ok" }[word], fail, warn };
}
export const countRows = (rows) => ({ fail: rows.filter((r) => r.health === "fail").length, warn: rows.filter((r) => r.health === "warn").length });

// #/health?view=all | project=<name> | (none = the project this UI runs in), with tab=, row= and tile= riding along.
// tile null = let the page pick (Checks when something is wrong, Q5); "none" = the operator closed it.
const TILES = ["checks", "usage", "jobs", "search", "none"];
export function parseView(query) {
  const q = new URLSearchParams(query || "");
  const tab = q.get("tab") === "all" ? "all" : "broken";
  const mode = q.get("view") === "all" ? "all" : "project";
  const row = q.get("row") || null;
  const tile = TILES.includes(q.get("tile")) ? q.get("tile") : tab === "all" || row ? "checks" : null;
  return { mode, project: mode === "project" ? q.get("project") || null : null, tab, row, tile };
}

const TILE_NAME = { secrets: "Secrets", review: "Review", tracker: "Tracker", scope: "Project scope" };
// Q1: one action per row, first match winning. A Configure tile writes it → open that tile; only the operator
// can run it → the command to copy; anything else → the chief session is on it, no button.
// foreign = the row belongs to another project: this UI's Configure writes this project's settings, so no button there.
export function fixAction(r, foreign = false) {
  const fix = r.fix || {};
  if (fix.by === "configure" && TILE_NAME[fix.tile]) return foreign ? { kind: "elsewhere", tile: fix.tile } : { kind: "configure", tile: fix.tile };
  if (fix.by === "operator" && fix.remedy) return { kind: "copy", cmd: fix.remedy };
  return { kind: "chief" };
}
// chief = is a chief session live for this project (true/false), or unknown (another project, or the fleet not read yet).
// Only a live one may say "on it"; none of the three is a button.
const chiefLabel = (chief) => (chief === true ? "chief is on it" : chief === false ? "for the chief · none running" : "for the chief");
const actionHtml = (a, chief) => a.kind === "configure" ? `<a class="fixact btn primary" href="#/config?tile=${esc(a.tile)}">Open in Configure</a>`
  : a.kind === "copy" ? `<button class="fixact btn" data-act="copy" data-cmd="${esc(a.cmd)}">Copy command</button>`
  : a.kind === "elsewhere" ? `<span class="fixact chief">set in that project's own UI</span>`
  : `<span class="fixact chief">${esc(chiefLabel(chief))}</span>`;

const nodata = (what) => `<div class="nodata">No data: ${esc(what)}</div>`;
// cls: "box" (the all-projects view), "sec" (an unboxed block in the project grid) or "p g-*" (the open tile's group panel)
const section = (id, title, sub, body, cls = "box") => `<section id="${id}" class="${cls}" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;

const groupOf = (r) => (r.source === "cadence" ? "job" : r.bundle === "search" ? "srch" : "chk");
const sharedOf = (feed) => ((feed && feed.rows) || []).filter((r) => r.scope === "shared");

const agoText = (iso, now) => {
  const s = Math.round((now - Date.parse(iso)) / 1000);
  return !Number.isFinite(s) ? "" : s < 90 ? "just now" : s < 5400 ? `${Math.round(s / 60)} min ago` : s < 129600 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} d ago`;
};
function verdictHtml(feed, health, now) {
  const v = verdict(feed, health);
  const shared = feed ? sharedOf(feed).filter(isTriage).length : 0;
  const ago = feed && feed.generatedAt ? agoText(feed.generatedAt, now) : "";
  const inputs = !feed ? "the doctor feed is still running" : `${v.fail} fail · ${v.warn} warn · ${v.alerts ? `alerts: ${v.alerts.length} firing` : "alerts not checked"}${ago ? ` · checked ${ago}` : ""}`;
  const n = (h) => ((feed && feed.rows) || []).filter((r) => r.health === h).length;
  const pills = feed ? `<span class="pills"><span class="pill fail">${v.fail} fail</span><span class="pill warn">${v.warn} warn</span>${shared ? `<span class="pill scope">${shared} shared</span>` : ""}<span class="pill ok">${n("ok")} ok</span>${n("off") ? `<span class="pill off">${n("off")} off</span>` : ""}</span>` : "";
  const m = health && health.monitoring;
  // Each source's failure shows on its own: a responding exporter makes the roll-up "ok" while Prometheus errors.
  const srcErrs = ["prometheus", "exporter"].filter((k) => m && m[k] && m[k].state === "error")
    .map((k) => `<div class="nodata">monitoring ${k} unreachable: ${esc(m[k].reason || "no answer")}</div>`).join("");
  const mon = m && m.state === "absent" ? `<div class="nodata">monitoring tier not running</div>`
    : srcErrs || (m && m.state === "error" ? `<div class="nodata">monitoring unreachable: ${esc(m.reason || "no answer")}</div>` : "");
  return `<div class="vhead strip v-${v.cls}"><span class="word st ${v.cls}">${esc(v.word)}</span><span class="inputs">${esc(inputs)}</span>${pills}
    <button class="btn" data-act="refresh-health">refresh</button></div>${mon}`;
}

const whoText = (a, chief) => a.kind === "configure" ? `You, in Configure → ${TILE_NAME[a.tile]}. The setting is written there.`
  : a.kind === "elsewhere" ? `You, in Configure → ${TILE_NAME[a.tile]}, in the UI that runs in that project. This UI's Configure writes its own project.`
  : a.kind === "copy" ? "You, in your terminal. Only the operator can run this; the chief session cannot."
  : chief === false ? "The chief session, and none is running for this project. Nothing for you to press; the next chief picks it up, and the row leaves this list when a later doctor run finds it ok."
  : "The chief session works every new doctor warn. Nothing for you to press; the row leaves this list when a later doctor run finds it ok.";

// one broken row: pill, id, scope tag, what it found, its single fix action, and a "Who fixes it" box that opens on the row.
function brokenRow(r, open, foreign = false, chief) {
  const a = fixAction(r, foreign), id = r.id;
  const who = open ? `<div class="who"><b>Who fixes it</b><p>${esc(whoText(a, chief))}</p>${a.kind === "copy" ? `<code class="remedy">${esc(a.cmd)}</code>` : ""}</div>` : "";
  return `<div class="hrow br" data-id="${esc(id)}"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(id)}</span>
    ${r.scope === "shared" ? `<span class="scope">shared</span>` : ""}<span class="det">${esc(r.installed && r.installed.detail)}</span>
    ${actionHtml(a, chief)}<button class="btn" data-act="health-row" data-id="${esc(id)}" aria-expanded="${open}">${open ? "close" : "who fixes it"}</button>${who}</div>`;
}

// Q1: an alert gets the same answer as a row, and the chief fixes alerts (Grafana is where you read one, not where it is fixed).
const alertHtml = (a, chief) => `<div class="alert"><span class="st ${a.severity === "page" ? "fail" : "warn"}">${esc(a.severity || "alert")}</span><b>${esc(a.alertname)}</b> <span class="det">${esc(a.summary)}</span>
  <span class="scope">shared</span><span class="fixact chief">${esc(chiefLabel(chief))}</span></div>`;

function brokenHtml(feed, health, view) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  const alerts = alertsOf(health) || [];
  const chief = view.foreign ? undefined : view.chief;
  const rowsHtml = rows.map((r) => brokenRow(r, view.row === r.id, view.foreign, chief)).join("");
  return rowsHtml + alerts.map((a) => alertHtml(a, chief)).join("") || `<div class="empty">Nothing broken.</div>`;
}

// Every item checked: all rows by bundle, a result each; a bundle with a problem opens by itself.
function allHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const by = new Map();
  for (const r of feed.rows || []) { const k = r.bundle || r.source || "other"; if (!by.has(k)) by.set(k, []); by.get(k).push(r); }
  if (!by.size) return `<div class="empty">The doctor reported no rows.</div>`;
  return [...by].map(([k, rows]) => {
    const bad = rows.filter(isTriage).length;
    return `<details class="bundle"${bad ? " open" : ""}><summary><b>${esc(k)}</b> <span class="ro">${rows.length} checked${bad ? ` · ${bad} to look at` : ""}</span></summary>
      <table class="data"><thead><tr><th>result</th><th>check</th><th>what it found</th><th>kind</th></tr></thead><tbody>${rows.map((r) =>
        `<tr><td><span class="pill ${esc(r.health)}">${esc(r.health)}</span></td><td>${esc(r.id)}</td><td>${esc(r.installed && r.installed.detail)}</td><td>${esc(r.kind || r.source)}</td></tr>`).join("")}</tbody></table></details>`;
  }).join("");
}

function tabsHtml(feed, health, view) {
  const broken = feed ? feed.rows.filter(isTriage).length + (alertsOf(health) || []).length : 0, total = feed ? feed.rows.length : 0;
  const tab = (id, label, n) => `<button class="tab" role="tab" data-act="health-tab" data-tab="${id}" aria-selected="${view.tab === id}">${label} · ${n}</button>`;
  return `<div class="tabs" role="tablist">${tab("broken", "What is broken", broken)}${tab("all", "Every item checked", total)}</div>
    <div role="tabpanel" id="tab-broken"${view.tab === "broken" ? "" : " hidden"}>${brokenHtml(feed, health, view)}</div>
    <div role="tabpanel" id="tab-all"${view.tab === "all" ? "" : " hidden"}>${allHtml(feed)}</div>`;
}

// four group tiles (frame 1); a tile opens its panel under the strip, one at a time. Counts come from the rows, never invented.
const GROUPS = [["chk", "Checks", "checks", "!"], ["use", "Usage", "usage", "%"], ["job", "Scheduled jobs", "jobs", "⏱"], ["srch", "Search & graph", "search", "⌕"]];
const worst = (rows) => (rows.some((r) => r.health === "fail") ? "fail" : rows.some((r) => r.health === "warn") ? "warn" : "ok");
function tileVal(g, feed, health) {
  const rows = (feed && feed.rows) || [];
  if (g === "use") {
    const b = health && health.bank && health.bank.state === "ok" ? health.bank.row : null;
    return b ? [`Claude ${b.five_hour} % of 5h · ${b.seven_day} % of week`, String(b.verdict || "").toLowerCase(), b.verdict === "PROCEED" ? "ok" : "warn"] : ["no preflight row yet", "no data", "off"];
  }
  if (!feed) return ["waiting for the doctor feed", "no data", "off"];
  if (g === "chk") {
    const v = verdict(feed, health), c = countRows(rows);
    const alerts = v.alerts && v.alerts.length ? ` · alerts: ${v.alerts.length} firing` : "";
    return [`${rows.length} items · ${c.fail + c.warn ? `${c.fail} fail · ${c.warn} warn` : "nothing broken"}${alerts}`, v.word.toLowerCase(), v.cls];
  }
  const l = rows.filter((r) => groupOf(r) === g), c = countRows(l), w = worst(l);
  if (g === "job") return l.length ? [`${l.filter((r) => r.health !== "off").length} of ${l.length} armed`, w, w] : ["no jobs declared", "none", "off"];
  return l.length ? [`${l.length} checked`, c.fail + c.warn ? `${c.fail + c.warn} to look at` : "fresh", w] : ["doctor reports no search rows", "no data", "off"];
}
function tilesHtml(feed, health, open) {
  return `<div class="tiles htiles">${GROUPS.map(([g, name, id, ic]) => {
    const [val, word, cls] = tileVal(g, feed, health);
    return `<button type="button" class="tile g-${g}" data-act="health-tile" data-tile="${id}" aria-expanded="${open === id}"><span class="ic" aria-hidden="true">${ic}</span><span class="tname">${esc(name)}</span><span class="tval">${esc(val)}</span><span class="pill ${esc(cls)}">${esc(word)}</span></button>`;
  }).join("")}</div>`;
}

// All my projects: the shared rows once, then each project worst first with its own broken rows.
function sharedPanel(feed, health, view) {
  if (!feed) return section("shared", "Shared", "Problems with the machine or himmel itself. Shown once here, never counted against a project.", nodata("the doctor feed is still running"));
  const rows = sharedOf(feed).filter(isTriage), alerts = alertsOf(health) || []; // firing alerts watch the machine, so they belong here too
  const mini = GROUPS.map(([g, name]) => { const l = rows.filter((r) => groupOf(r) === g); return `<div class="mini"><b>${name}</b><span class="ro">${l.length ? `${l.length} to look at` : "ok"}</span></div>`; }).join("");
  return `<section id="shared" class="box" aria-labelledby="h-shared"><h2 id="h-shared">Shared</h2><p class="sub">Problems with the machine or himmel itself. Shown once here, never counted against a project.</p>
    <div class="minis">${mini}</div>${rows.length || alerts.length ? rows.map((r) => brokenRow(r, view.row === r.id, false, view.chief)).join("") + alerts.map((a) => alertHtml(a, view.chief)).join("") : `<div class="empty">Nothing shared is broken.</div>`}</section>`;
}
function projectLine(p, view) {
  const c = (p.counts && p.counts.project) || { fail: 0, warn: 0 }, v = projectVerdict(c);
  const head = p.checkedAt ? `<span class="pill ${v.cls}">${esc(v.word)}</span>` : `<span class="pill off">not checked</span>`;
  const broken = (p.broken || []).map((r) => brokenRow(r, view.row === r.id, !p.current, p.current ? view.chief : undefined)).join("");
  return `<div class="box prj" data-project="${esc(p.name)}"><div class="phead"><b>${esc(p.name)}</b>${p.current ? `<span class="scope">this UI</span>` : ""}${head}
    <span class="ro">${p.checkedAt ? `${c.fail} fail · ${c.warn} warn · checked ${esc(String(p.checkedAt).slice(0, 16).replace("T", " "))}` : "no cached check yet: open Health in that project once"}</span>
    <a class="btn" href="#/health?project=${encodeURIComponent(p.name)}">open ▸</a></div>${broken}</div>`;
}
const rank = (p) => (p.checkedAt ? ((p.counts && p.counts.project && p.counts.project.fail) || 0) * 1000 + ((p.counts && p.counts.project && p.counts.project.warn) || 0) : -1);
function allProjectsHtml(feed, health, view) {
  const ps = [...((view.projects && view.projects.projects) || [])].sort((a, b) => rank(b) - rank(a) || String(a.name).localeCompare(String(b.name)));
  return `<header class="ph"><h1>Health · all my projects</h1><p>Shared problems once, then every registered project, worst first.</p></header>
    ${sharedPanel(feed, health, view)}${ps.map((p) => projectLine(p, view)).join("") || `<div class="empty">No projects are registered.</div>`}`;
}

function jobsHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const jobs = (feed.rows || []).filter((r) => r.source === "cadence");
  if (!jobs.length) return `<div class="empty">No scheduled jobs are declared.</div>`;
  return jobs.map((r) => {
    const f = r.fires;
    return `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id.replace(/^cadence:/, ""))}</span>
      <span class="det">${esc(r.installed && r.installed.detail)}</span>
      <span class="ro">${f && f.state === "yes" ? `last fired ${esc(f.at)} · ${esc(f.evidence)}` : esc(f ? f.state : "unverified")}</span></div>`;
  }).join("");
}

function bankHtml(health) {
  const b = health && health.bank;
  let body;
  if (!health) body = nodata("loading");
  else if (b.state === "ok") {
    const r = b.row;
    body = `<div class="kv"><b>${esc(r.verdict)}</b> · five_hour ${esc(r.five_hour)} % · seven_day ${esc(r.seven_day)} %${r.degraded ? " · degraded" : ""}</div>
      <div class="ro">${esc(r.ts)}${r.age !== "" && r.age != null ? ` · ${esc(r.age)} min old` : ""} · read from the bank-preflight ledger, never re-measured here</div>`;
  } else body = nodata(b.reason || "no bank-preflight ledger");
  return `<div class="card" id="bank"><h3>Last subscription usage budget preflight</h3>${body}</div>`;
}

// the Claude and Codex bank windows from GET /api/bank. Unknown shows "unknown (why)" and its age, never 0 %.
const ageText = (s) => (s == null ? "" : s < 90 ? `${s} s old` : s < 5400 ? `${Math.round(s / 60)} min old` : `${Math.round(s / 3600)} h old`);
function quotaRow(bank, label, w) {
  const age = ageText(w.age_s);
  const cell = w.used_pct == null ? `unknown (${esc(w.reason || "no reading")})` : `${esc(w.used_pct)} % used`;
  const flags = [w.state === "stale" ? "stale" : "", w.possibly_reset ? "possibly reset" : ""].filter(Boolean);
  const resets = w.resets_at ? `resets ${esc(w.resets_at)}` : "";
  return `<div class="hrow"><span class="st ${w.state === "ok" && !w.possibly_reset ? "ok" : "warn"}">${esc(w.state)}</span><span class="id">${esc(bank)} ${esc(label)}</span>
    <span class="det">${cell}${age ? ` · ${esc(age)}` : ""}${flags.length ? ` · ${esc(flags.join(", "))}` : ""}</span><span class="ro">${resets}</span></div>`;
}
function quotaHtml(health) {
  const q = health && health.quota;
  let body;
  if (!health) body = nodata("loading");
  else if (!q) body = nodata("the subscription usage budget windows did not load");
  else body = [
    quotaRow("claude", "5h", q.claude.five_hour), quotaRow("claude", "weekly", q.claude.seven_day),
    quotaRow("codex", "5h", q.codex.five_hour), quotaRow("codex", "weekly", q.codex.weekly),
  ].join("") + `<div class="ro">read from the caches bank-preflight reads, never re-measured here</div>`;
  return `<div class="card" id="quota"><h3>Subscription usage budget windows</h3>${body}</div>`;
}

// Q2: the worker list moved to Fleet; Health keeps the budget and points there.
const fleetLink = (view) => `<p class="ro"><a href="${esc(view.fleetHref || "/agui/")}" target="_blank" rel="noopener noreferrer">open Fleet ▸</a> for the worker sessions.</p>`;

// The weekly roll-up cards from GET /api/rollup, rendered as sent: the deltas and the sentence are the server's.
const compact = (n) => { const a = Math.abs(n); return a >= 1e6 ? (n / 1e6).toFixed(1) + "M" : a >= 1e4 ? Math.round(n / 1e3) + "k" : String(Math.round(n * 100) / 100); };
const signed = (n) => (n > 0 ? "+" : "") + compact(n);
function sparkSvg(spark, label) {
  if (!spark || spark.length < 2) return "";
  const vs = spark.map((p) => p.value), lo = Math.min(...vs), hi = Math.max(...vs), W = 120, H = 28;
  const pts = vs.map((v, i) => `${(i / (vs.length - 1) * W).toFixed(1)},${(hi === lo ? H / 2 : H - 2 - (v - lo) / (hi - lo) * (H - 4)).toFixed(1)}`).join(" ");
  return `<svg class="spark" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)} by week"><polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>`;
}
function trendCard(c) {
  if (c.state !== "ok") return `<div class="card"><h3>${esc(c.title)}</h3>${nodata("no data yet")}</div>`;
  const d = (x, than) => (x && x.delta !== null ? `<span class="kv">${esc(signed(x.delta))} vs ${than}</span> ` : "");
  return `<div class="card trend"><h3>${esc(c.title)}</h3><div class="ro">${esc(c.metric)}</div>
    ${c.week ? `<div class="big">${esc(compact(c.week.value))} <small>${esc(c.unit)} · ${esc(c.week.key)}</small></div>` : ""}${sparkSvg(c.spark, c.metric)}
    <div>${d(c.week, "last week")}${d(c.version, "last version")}</div><p class="sentence">${esc(c.sentence)}</p></div>`;
}
function trendsHtml(health) {
  const r = health && health.rollup;
  if (!r || r.state !== "ok") return nodata(r && r.reason ? `no data yet (${r.reason})` : "no data yet");
  return `<div class="trends">${r.cards.map(trendCard).join("")}</div>`;
}

// The review page text from GET /api/reviewers, as sent: only its Markdown headings, bullets and paragraphs are shaped here.
function reviewersHtml(health) {
  const r = health && health.reviewers;
  if (!r || r.state !== "ok") return nodata(r && r.reason ? r.reason : "no review page yet");
  const out = [];
  let list = false;
  for (const line of String(r.text).split("\n")) {
    const li = /^- (.*)$/.exec(line);
    if (list && !li) { out.push("</ul>"); list = false; }
    if (li) { if (!list) { out.push("<ul>"); list = true; } out.push(`<li>${esc(li[1])}</li>`); continue; }
    const h = /^#{1,3} (.*)$/.exec(line);
    if (h) out.push(line.startsWith("# ") ? "" : `<h4>${esc(h[1])}</h4>`);
    else if (line.trim()) out.push(`<p>${esc(line)}</p>`);
  }
  if (list) out.push("</ul>");
  return `<div class="card" id="reviewers-page">${out.join("")}<p class="sub">Written ${esc(String(r.writtenAt).slice(0, 10))}</p></div>`;
}

function searchHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter((r) => r.bundle === "search");
  if (!rows.length) return nodata("doctor reports no search rows");
  return rows.map((r) => `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id)}</span><span class="det">${esc(r.installed && r.installed.detail)}</span></div>`).join("");
}

export function renderHealth(feed, health, view = {}) {
  view = { mode: "project", tab: "broken", row: null, ...view };
  if (view.mode === "all") return allProjectsHtml(feed, health, view);
  const name = view.project || (feed && feed.target && feed.target.project) || "this project";
  if (view.unchecked) return `<header class="ph"><h1>Health · ${esc(name)}</h1></header>${nodata(`${name} has not been checked yet; open Health in that project once`)}`;
  // The firing alerts belong to the project this UI runs in, so another project's page does not show them.
  const own = view.foreign ? health && { ...health, monitoring: null } : health;
  // Q5: with no tile chosen, Checks opens by itself only on a problem; tile=none means the operator closed it.
  const v = verdict(feed, own), open = view.tile || (feed && (v.cls === "fail" || v.cls === "warn") ? "checks" : "none");
  const sharedTag = `<span class="scope">shared</span>`;
  const panel = {
    checks: () => section("broken", "Checks", "Worst first. Each row has one fix action; shared rows are the machine's, not this project's.", tabsHtml(feed, own, view), "p g-chk"),
    usage: () => section("usage", "Usage", "Read-only: the newest bank-preflight ledger row and the subscription usage budget windows.", sharedTag + bankHtml(health) + quotaHtml(health) + fleetLink(view), "p g-use"),
    jobs: () => section("jobs", "Scheduled jobs", "Cadence jobs as the doctor reports them.", sharedTag + jobsHtml(feed), "p g-job"),
    search: () => section("search", "Search & graph", "From the doctor's search rows.", searchHtml(feed), "p g-srch"),
  }[open];
  // mockup v2: the strip, the tiles and the open tile's panel sit straight in the main-column grid (app.css .pg), unboxed
  return `<div class="pg">${[
    `<header class="ph"><h1>Health · ${esc(name)}</h1><p>Is himmel working here, what is broken and who fixes it, from the doctor feed and the monitoring tier.</p></header>`,
    section("verdict", "Is this project working right now?", "One word, from the doctor feed and any firing alerts. A tile opens its panel.", verdictHtml(feed, own, view.now ?? Date.now()) + tilesHtml(feed, own, open), "sec"),
    panel ? panel() : "",
    section("trends", "Trends", "Velocity, cost and health by week, from the weekly roll-up; read-only.", trendsHtml(health), "sec"),
    section("reviewers", "How good are our reviewers?", "The critics on planted bugs and the judges on merged PRs, from the weekly review page; read-only.", reviewersHtml(health), "sec"),
  ].join("\n")}</div>`;
}
