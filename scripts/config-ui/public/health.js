// the Health page. Pure rendering, no DOM: renderHealth(feed, health) → HTML.
// feed = the doctor feed (null until it lands); health = GET /api/health ({bank, legs, monitoring, mode}),
// null while loading. Every value shown comes from its owner (I1): the feed's rows, the bank ledger
// row, legs.sh, Prometheus. The one verdict lives here (I6) and only counts what those sources say.
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

const nodata = (what) => `<div class="nodata">No data: ${esc(what)}</div>`;
const section = (id, title, sub, body) => `<section id="${id}" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;

function verdictHtml(feed, health) {
  const v = verdict(feed, health);
  const inputs = !feed ? "the doctor feed is still running" : `${v.fail} fail · ${v.warn} warn · ${v.alerts ? `alerts: ${v.alerts.length} firing` : "alerts not checked"}`;
  const m = health && health.monitoring;
  // Each source's failure shows on its own: a responding exporter makes the roll-up "ok" while Prometheus errors.
  const srcErrs = ["prometheus", "exporter"].filter((k) => m && m[k] && m[k].state === "error")
    .map((k) => `<div class="nodata">monitoring ${k} unreachable: ${esc(m[k].reason || "no answer")}</div>`).join("");
  const mon = m && m.state === "absent" ? `<div class="nodata">monitoring tier not running</div>`
    : srcErrs || (m && m.state === "error" ? `<div class="nodata">monitoring unreachable: ${esc(m.reason || "no answer")}</div>` : "");
  return `<div class="vhead"><span class="word st ${v.cls}">${esc(v.word)}</span><span class="inputs">${esc(inputs)}</span>
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

function brokenHtml(feed, health) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  const alerts = alertsOf(health) || [];
  const rowsHtml = rows.map((r) => {
    const remedy = (r.fix && r.fix.remedy) || "";
    return `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id)}</span>
      <span class="det">${esc(r.installed && r.installed.detail)}</span>
      ${remedy ? `<code class="remedy">${esc(remedy)}</code><button class="btn" data-act="copy" data-cmd="${esc(remedy)}">copy · runs in your terminal</button>` : ""}
      <button class="btn" data-act="open-config" data-id="${esc(r.id)}">Open in Config</button></div>`;
  }).join("");
  const alertsHtml = alerts.map((a) => `<div class="alert"><span class="st ${a.severity === "page" ? "fail" : "warn"}">${esc(a.severity || "alert")}</span><b>${esc(a.alertname)}</b> <span class="det">${esc(a.summary)}</span></div>`).join("");
  return rowsHtml + alertsHtml || `<div class="empty">Nothing broken.</div>`;
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

function legsHtml(health) {
  const l = health && health.legs;
  let body;
  if (!health) body = nodata("loading");
  else if (l.state === "ok") {
    body = l.legs.length ? l.legs.map((x) => `<div class="leg"><span class="mk">${esc(x.status)}</span><span class="doc" title="${esc(x.doc)}">${esc(String(x.doc).split("/").pop())}</span></div>`).join("") : `<div class="empty">The fleet manifest lists no worker sessions.</div>`;
  } else body = nodata(l.state === "absent" ? `no fleet manifest (${l.reason || "none found"})` : l.reason || "legs view failed");
  return `<div class="card" id="legs"><h3>Worker sessions</h3>${body}</div>`;
}

// The weekly roll-up cards from GET /api/rollup, rendered as sent: the deltas and the sentence are the server's.
const signed = (n) => (n > 0 ? "+" : "") + n;
function sparkSvg(spark, label) {
  if (!spark || spark.length < 2) return "";
  const vs = spark.map((p) => p.value), lo = Math.min(...vs), hi = Math.max(...vs), W = 120, H = 28;
  const pts = vs.map((v, i) => `${(i / (vs.length - 1) * W).toFixed(1)},${(hi === lo ? H / 2 : H - 2 - (v - lo) / (hi - lo) * (H - 4)).toFixed(1)}`).join(" ");
  return `<svg class="spark" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)} by week"><polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>`;
}
function trendCard(c) {
  if (c.state !== "ok") return `<div class="card"><h3>${esc(c.title)}</h3>${nodata("no data yet")}</div>`;
  const d = (x, than) => (x && x.delta !== null ? `<span class="kv">${esc(signed(x.delta))} vs ${than}</span> ` : "");
  return `<div class="card trend"><h3>${esc(c.title)}</h3><div class="ro">${esc(c.metric)}</div>${sparkSvg(c.spark, c.metric)}
    <div class="kv">${c.week ? `${esc(c.week.key)}: ${esc(c.week.value)} ${esc(c.unit)}` : ""}</div>
    <div>${d(c.week, "last week")}${d(c.version, "last version")}</div><p class="sentence">${esc(c.sentence)}</p></div>`;
}
function trendsHtml(health) {
  const r = health && health.rollup;
  if (!r || r.state !== "ok") return nodata(r && r.reason ? `no data yet (${r.reason})` : "no data yet");
  return r.cards.map(trendCard).join("");
}

function searchHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter((r) => r.bundle === "search");
  if (!rows.length) return nodata("doctor reports no search rows");
  return rows.map((r) => `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id)}</span><span class="det">${esc(r.installed && r.installed.detail)}</span></div>`).join("");
}

export function renderHealth(feed, health) {
  return [
    section("verdict", "Is himmel healthy?", "One word, from the doctor feed and any firing alerts.", verdictHtml(feed, health) + modeHtml(health)),
    section("broken", "What is broken, and what do I do", "Failing and drifting rows, worst first, with the fix to run in your terminal.", brokenHtml(feed, health)),
    section("jobs", "Scheduled jobs", "Cadence jobs as the doctor reports them.", jobsHtml(feed)),
    section("legs-bank", "Worker sessions and the subscription usage budget", "Read-only: the newest bank-preflight ledger row and each worker session's last marker.", bankHtml(health) + quotaHtml(health) + legsHtml(health)),
    section("trends", "Trends", "Velocity, cost and health by week, from the weekly roll-up; read-only.", trendsHtml(health)),
    section("search", "Search and graph freshness", "From the doctor's search rows.", searchHtml(feed)),
  ].join("\n");
}
