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

// #/health?view=all | project=<name> | (none = the project this UI runs in), with tab= and row= riding along.
export function parseView(query) {
  const q = new URLSearchParams(query || "");
  const tab = q.get("tab") === "all" ? "all" : "broken";
  const mode = q.get("view") === "all" ? "all" : "project";
  return { mode, project: mode === "project" ? q.get("project") || null : null, tab, row: q.get("row") || null };
}

const TILE_NAME = { secrets: "Secrets", review: "Review", tracker: "Tracker", scope: "Project scope" };
// Q1: one action per row, first match winning. A Configure tile writes it → open that tile; only the operator
// can run it → the command to copy; anything else → the chief session is on it, no button.
export function fixAction(r) {
  const fix = r.fix || {};
  if (fix.by === "configure" && TILE_NAME[fix.tile]) return { kind: "configure", tile: fix.tile };
  if (fix.by === "operator" && fix.remedy) return { kind: "copy", cmd: fix.remedy };
  return { kind: "chief" };
}
const actionHtml = (a) => a.kind === "configure" ? `<a class="btn primary" href="#/config?tile=${esc(a.tile)}">Open in Configure</a>`
  : a.kind === "copy" ? `<button class="btn" data-act="copy" data-cmd="${esc(a.cmd)}">Copy command</button>`
  : `<span class="chief">chief is on it</span>`;

const nodata = (what) => `<div class="nodata">No data: ${esc(what)}</div>`;
const section = (id, title, sub, body) => `<section id="${id}" class="box" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;

const groupOf = (r) => (r.source === "cadence" ? "job" : r.bundle === "search" ? "srch" : "chk");
const sharedOf = (feed) => ((feed && feed.rows) || []).filter((r) => r.scope === "shared");

function verdictHtml(feed, health) {
  const v = verdict(feed, health);
  const shared = feed ? sharedOf(feed).filter(isTriage).length : 0;
  const inputs = !feed ? "the doctor feed is still running" : `${v.fail} fail · ${v.warn} warn · ${v.alerts ? `alerts: ${v.alerts.length} firing` : "alerts not checked"}`;
  const pills = feed ? `<span class="pills"><span class="pill fail">${v.fail} fail</span><span class="pill warn">${v.warn} warn</span>${shared ? `<span class="pill scope">${shared} shared</span>` : ""}</span>` : "";
  const m = health && health.monitoring;
  // Each source's failure shows on its own: a responding exporter makes the roll-up "ok" while Prometheus errors.
  const srcErrs = ["prometheus", "exporter"].filter((k) => m && m[k] && m[k].state === "error")
    .map((k) => `<div class="nodata">monitoring ${k} unreachable: ${esc(m[k].reason || "no answer")}</div>`).join("");
  const mon = m && m.state === "absent" ? `<div class="nodata">monitoring tier not running</div>`
    : srcErrs || (m && m.state === "error" ? `<div class="nodata">monitoring unreachable: ${esc(m.reason || "no answer")}</div>` : "");
  return `<div class="vhead strip v-${v.cls}"><span class="word st ${v.cls}">${esc(v.word)}</span><span class="inputs">${esc(inputs)}</span>${pills}
    <button class="btn" data-act="refresh-health">refresh</button></div>${mon}`;
}

// The resolver's answer (scripts/lib/project-mode.*), shown as it came: tracker and forge on one row.
function modeHtml(health) {
  const m = health && health.mode;
  let body;
  if (!m) body = nodata(health ? "server did not report the mode" : "loading");
  else if (m.state === "ok") body = `<div class="kv">tracker=${esc(m.tracker)} forge=${esc(m.forge)}</div>
      <div class="ro">ticket ID required: ${m.idRequired === "0" ? "no" : "yes"} · set with TRACKER / FORGE or git config himmel.tracker / himmel.forge</div>`;
  else body = `<div class="nodata">${esc(m.reason || "mode unresolved")}</div>`;
  return `<div class="card" id="mode"><h3>Project mode</h3>${body}</div>`;
}

const whoText = (a, r) => a.kind === "configure" ? `You, in Configure → ${TILE_NAME[a.tile]}. The setting is written there.`
  : a.kind === "copy" ? "You, in your terminal. Only the operator can run this; the chief session cannot."
  : "The chief session. Nothing for you to do; it shows here until the check passes.";

// one broken row: pill, id, scope tag, what it found, its single fix action, and a "Who fixes it" box that opens on the row.
function brokenRow(r, open) {
  const a = fixAction(r), id = r.id;
  const who = open ? `<div class="who"><b>Who fixes it</b><p>${esc(whoText(a, r))}</p>${a.kind === "copy" ? `<code class="remedy">${esc(a.cmd)}</code>` : ""}</div>` : "";
  return `<div class="hrow br" data-id="${esc(id)}"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(id)}</span>
    ${r.scope === "shared" ? `<span class="scope">shared</span>` : ""}<span class="det">${esc(r.installed && r.installed.detail)}</span>
    ${actionHtml(a)}<button class="btn" data-act="health-row" data-id="${esc(id)}" aria-expanded="${open}">${open ? "close" : "who fixes it"}</button>${who}</div>`;
}

function brokenHtml(feed, health, view) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  const alerts = alertsOf(health) || [];
  const rowsHtml = rows.map((r) => brokenRow(r, view.row === r.id)).join("");
  const alertsHtml = alerts.map((a) => `<div class="alert"><span class="st ${a.severity === "page" ? "fail" : "warn"}">${esc(a.severity || "alert")}</span><b>${esc(a.alertname)}</b> <span class="det">${esc(a.summary)}</span></div>`).join("");
  return rowsHtml + alertsHtml || `<div class="empty">Nothing broken.</div>`;
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
  const broken = feed ? feed.rows.filter(isTriage).length : 0, total = feed ? feed.rows.length : 0;
  const tab = (id, label, n) => `<button class="tab" role="tab" data-act="health-tab" data-tab="${id}" aria-selected="${view.tab === id}">${label} · ${n}</button>`;
  return `<div class="tabs" role="tablist">${tab("broken", "What is broken", broken)}${tab("all", "Every item checked", total)}</div>
    <div role="tabpanel" id="tab-broken"${view.tab === "broken" ? "" : " hidden"}>${brokenHtml(feed, health, view)}</div>
    <div role="tabpanel" id="tab-all"${view.tab === "all" ? "" : " hidden"}>${allHtml(feed)}</div>`;
}

// four group tiles; each scrolls to its panel. Counts come from the rows, never invented.
const GROUPS = [["chk", "Checks", "broken"], ["use", "Usage", "usage"], ["job", "Scheduled jobs", "jobs"], ["srch", "Search & graph", "search"]];
function tilesHtml(feed, health) {
  const rows = (feed && feed.rows) || [];
  const val = (g) => {
    if (g === "use") { const b = health && health.bank && health.bank.state === "ok" ? health.bank.row : null; return b ? `${b.verdict} · 5h ${b.five_hour} %` : "no reading"; }
    if (!feed) return "waiting";
    const l = rows.filter((r) => groupOf(r) === g), c = countRows(l);
    return c.fail + c.warn ? `${c.fail} fail · ${c.warn} warn` : `${l.length} ok`;
  };
  return `<div class="tiles htiles">${GROUPS.map(([g, name, target]) =>
    `<button type="button" class="tile g-${g}" data-act="health-tile" data-target="${target}"><span class="tname">${name}</span><span class="tval">${esc(val(g))}</span></button>`).join("")}</div>`;
}

// All my projects: the shared rows once, then each project worst first with its own broken rows.
function sharedPanel(feed) {
  const rows = sharedOf(feed).filter(isTriage);
  const mini = GROUPS.map(([g, name]) => { const l = rows.filter((r) => groupOf(r) === g); return `<div class="mini"><b>${name}</b><span class="ro">${l.length ? `${l.length} to look at` : "ok"}</span></div>`; }).join("");
  return `<section id="shared" class="box" aria-labelledby="h-shared"><h2 id="h-shared">Shared</h2><p class="sub">Problems with the machine or himmel itself. Shown once here, never counted against a project.</p>
    <div class="minis">${mini}</div>${rows.length ? rows.map((r) => brokenRow(r, false)).join("") : `<div class="empty">Nothing shared is broken.</div>`}</section>`;
}
function projectLine(p) {
  const c = (p.counts && p.counts.project) || { fail: 0, warn: 0 }, v = projectVerdict(c);
  const head = p.checkedAt ? `<span class="pill ${v.cls}">${esc(v.word)}</span>` : `<span class="pill off">not checked</span>`;
  const broken = (p.broken || []).map((r) => brokenRow(r, false)).join("");
  return `<div class="box prj" data-project="${esc(p.name)}"><div class="phead"><b>${esc(p.name)}</b>${p.current ? `<span class="scope">this UI</span>` : ""}${head}
    <span class="ro">${p.checkedAt ? `${c.fail} fail · ${c.warn} warn · checked ${esc(String(p.checkedAt).slice(0, 16).replace("T", " "))}` : "no cached check yet: open Health in that project once"}</span>
    <a class="btn" href="#/health?project=${encodeURIComponent(p.name)}">open ▸</a></div>${broken}</div>`;
}
const rank = (p) => (p.checkedAt ? ((p.counts && p.counts.project && p.counts.project.fail) || 0) * 1000 + ((p.counts && p.counts.project && p.counts.project.warn) || 0) : -1);
function allProjectsHtml(feed, view) {
  const ps = [...((view.projects && view.projects.projects) || [])].sort((a, b) => rank(b) - rank(a) || String(a.name).localeCompare(String(b.name)));
  return `<header class="ph"><h1>Health · all my projects</h1><p>Shared problems once, then every registered project, worst first.</p></header>
    ${sharedPanel(feed)}${ps.map(projectLine).join("") || `<div class="empty">No projects are registered.</div>`}`;
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
  if (view.mode === "all") return allProjectsHtml(feed, view);
  const name = view.project || (feed && feed.target && feed.target.project) || "this project";
  if (view.unchecked) return `<header class="ph"><h1>Health · ${esc(name)}</h1></header>${nodata(`${name} has not been checked yet; open Health in that project once`)}`;
  return [
    `<header class="ph"><h1>Health · ${esc(name)}</h1><p>Is himmel healthy here, what is broken and who fixes it, from the doctor feed and the monitoring tier.</p></header>`,
    section("verdict", "Is himmel healthy?", "One word, from the doctor feed and any firing alerts.", verdictHtml(feed, health) + tilesHtml(feed, health) + modeHtml(health)),
    section("broken", "What is broken, and what do I do", "Worst first. Each row has one fix action; shared rows are the machine's, not this project's.", tabsHtml(feed, health, view)),
    section("jobs", "Scheduled jobs", "Cadence jobs as the doctor reports them.", jobsHtml(feed)),
    section("usage", "Usage", "Read-only: the newest bank-preflight ledger row and the subscription usage budget windows.", bankHtml(health) + quotaHtml(health) + fleetLink(view)),
    section("trends", "Trends", "Velocity, cost and health by week, from the weekly roll-up; read-only.", trendsHtml(health)),
    section("reviewers", "How good are our reviewers?", "The critics on planted bugs and the judges on merged PRs, from the weekly review page; read-only.", reviewersHtml(health)),
    section("search", "Search and graph freshness", "From the doctor's search rows.", searchHtml(feed)),
  ].join("\n");
}
