// Tool health, built from the approved v9 mockup (build spec section 0, slice A): rendering only.
// Counts, rates, trend days and lane deltas come from GET /api/tool-health; what exists on the station from
// GET /api/tool-inventory; the review page text from GET /api/reviewers. A missing denominator is —, never 0.
import { esc, pg } from "./render.js";

const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const pct = (v) => (isNum(v) ? `${(v * 100).toFixed(1)}%` : "—");
const num = (v) => (isNum(v) ? String(v) : "—");
const ratio = (a, b) => (isNum(a) && isNum(b) && b > 0 ? a / b : null);
const UNKNOWN_TOOL = "(unknown)"; // the reader's bucket for a refusal recorded before tools were named
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dayLabel = (d) => `${Number(d.slice(8, 10))} ${MONTHS[Number(d.slice(5, 7)) - 1]}`;
const stamp = (ms) => `${new Date(ms).toISOString().slice(0, 16).replace("T", " ")} UTC`;
const hhmm = (ms) => `${new Date(ms).toISOString().slice(11, 16)} UTC`;
const sub = (text) => `<p class="sub">${esc(text)}</p>`;
const box = (id, title, purpose, body, tag = "") => `<section class="box" id="th-${id}"><h2>${esc(title)}${tag ? ` <span class="tag">${esc(tag)}</span>` : ""}</h2>${sub(purpose)}${body}</section>`;
const table = (head, rows, empty = "Nothing to show", cls = "") => (rows.length ? `<div class="scroll"><table class="data${cls ? ` ${cls}` : ""}"><thead><tr>${head.map((h) => `<th scope="col">${h}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>` : `<p class="nodata">${esc(empty)}</p>`);
const td = (v) => `<td>${v}</td>`;
const tdWrap = (v) => `<td class="wrap">${v}</td>`;

export const TEAM_LABEL = { chief: "chief", "chief-relay": "chief relay", worker: "workers", judge: "judge", "release-manager": "release manager", critic: "critics", interactive: "interactive (you)", other: "other" };
const KIND_LABEL = { builtin: "built-in", mcp: "MCP", res: "MCP resource", skill: "skill", cmd: "command", agent: "subagent", wf: "workflow", hook: "hook", cli: "CLI" };
const KINDS = Object.keys(KIND_LABEL);
const SRC_LABEL = { core: "core", himmel: "himmel plugin", third: "third-party plugin", project: "project", user: "user", pkg: "MCP config", station: "station", unknown: "source unknown", before: "before the split" };
const SRCS = Object.keys(SRC_LABEL);
// The Station sources table names each scan source as the mockup does; an id this page does not know prints as itself.
const SOURCE_NAME = { "hooks-project": "Hooks · project", "hooks-user": "Hooks · user", plugins: "Plugins", "plugin-items": "Plugin items", "project-claude": "Project .claude/", "user-claude": "User ~/.claude/", "mcp-user": "MCP · user config", "mcp-profiles": "MCP · launch profiles", "mcp-project": "MCP · project", "mcp-plugins": "MCP · plugins", "mcp-runtime": "MCP · runtime", core: "Core tools", clis: "Station CLIs", "rtk-history": "rtk history" };
const CORE_AGENTS = new Set(["general-purpose", "Explore", "Plan", "statusline-setup", "claude-code-guide", "claude"]);
const COLLAPSED = { Skill: "skill", Agent: "agent", Task: "agent", mcp: "mcp" };
const FILTERS = ["days", "team", "lane", "profile"];

// Only the newest request may land; a failed one keeps the last good response and says it is stale.
export function toolHealthLoader({ get, now = Date.now, onChange = () => {} }) {
  let gen = 0;
  const state = { data: null, loading: false, loadedAt: null, error: null };
  return {
    state,
    async load(query) {
      const mine = ++gen;
      state.loading = true;
      onChange();
      let data, error = null;
      try { data = await get(query); } catch (e) { error = String((e && e.message) || e || "error"); }
      if (mine !== gen) return;
      state.loading = false;
      if (error) state.error = error;
      else { state.data = data; state.error = null; state.loadedAt = now(); }
      onChange();
    },
  };
}

// The route: #/toolhealth[/<tab>]?days=&team=&lane=&profile=&tool=&guard=
export function toolHealthHref(ui, patch = {}) {
  const q = new URLSearchParams();
  for (const k of FILTERS) if (ui.filters && ui.filters[k]) q.set(k, ui.filters[k]);
  for (const k of ["tool", "guard"]) if (patch[k]) q.set(k, patch[k]);
  const tab = patch.tab || "overview", s = q.toString();
  return `#/toolhealth${tab === "overview" ? "" : `/${tab}`}${s ? `?${s}` : ""}`;
}

function srcOf(source) {
  if (typeof source !== "string" || !source) return "unknown";
  if (source.endsWith("@himmel")) return "himmel";
  if (source.includes("@")) return "third";
  return { project: "project", user: "user", "mcp-config": "pkg", core: "core" }[source] || "unknown";
}
const invKey = (it) => (it.kind === "agent" ? `Agent:${it.name}` : it.kind === "mcp" ? `mcp__${it.name}` : `Skill:${it.name}`);

// Every tool the page can name: recorded rows plus what the station scan found and nobody called.
function catalogue(data, inv) {
  const items = new Map((inv && inv.tools || []).map((it) => [invKey(it), it]));
  const rows = [];
  for (const t of data && data.tools || []) {
    const it = items.get(t.tool);
    let kind = "builtin", src = "core";
    if (it) { kind = it.kind; src = srcOf(it.source); }
    else if (COLLAPSED[t.tool]) { kind = COLLAPSED[t.tool]; src = "before"; }
    else if (/^mcp__/.test(t.tool)) { kind = "mcp"; const server = items.get(`mcp__${t.tool.split("__")[1]}`); src = server ? srcOf(server.source) : "unknown"; }
    else if (/^(ListMcpResourcesTool|ReadMcpResourceTool)$/.test(t.tool)) kind = "res";
    else if (t.tool.startsWith("Agent:")) { kind = "agent"; src = CORE_AGENTS.has(t.tool.slice(6)) ? "core" : "unknown"; }
    else if (t.tool.startsWith("Skill:")) { kind = "skill"; src = "unknown"; }
    rows.push({ key: t.tool, kind, src, source: it ? it.source : null, t });
  }
  const recorded = new Set(rows.map((r) => r.key));
  for (const [key, it] of items) {
    if (recorded.has(key) || (it.kind === "mcp" && rows.some((r) => r.key.startsWith(`${key}__`)))) continue;
    rows.push({ key, kind: it.kind, src: srcOf(it.source), source: it.source, t: null, inv: it });
  }
  return rows;
}
const displayName = (r) => (r.src === "before" && r.kind === "mcp" ? "mcp (server not recorded)" : r.key);

// A complete count can never break 0 ≤ errors, denials ≤ failures ≤ calls; one that does is flagged, not clamped.
function badCounts(data) {
  const bad = new Set();
  for (const t of data && data.tools || []) {
    const n = [t.failures, t.errors, t.denials];
    if (n.some((v) => !isNum(v) || v < 0) || t.errors > t.failures || t.denials > t.failures || (isNum(t.calls) && (t.calls < 0 || t.failures > t.calls))) bad.add(t.tool);
  }
  const tools = data && data.tools || [];
  if (isNum(data && data.totalCalls) && tools.every((t) => isNum(t.calls)) && tools.reduce((n, t) => n + t.calls, 0) !== data.totalCalls) bad.add("(total)");
  return bad;
}

function windowDays(data) {
  const a = data && data.first_day, b = data && data.last_day, out = [];
  if (!a || !b) return out;
  for (let t = Date.parse(a); t <= Date.parse(b) && out.length < 366; t += 86400000) out.push(new Date(t).toISOString().slice(0, 10));
  return out;
}
function windowLabel(data) {
  const a = data && data.first_day, b = data && data.last_day;
  if (!a || !b) return "";
  const y = b.slice(0, 4);
  if (a.slice(0, 7) === b.slice(0, 7)) return `${Number(a.slice(8))}–${dayLabel(b)} ${y}`;
  return `${dayLabel(a)}${a.slice(0, 4) === y ? "" : ` ${a.slice(0, 4)}`} – ${dayLabel(b)} ${y}`;
}

// ---- header, filters, state line, tabs
function filterBar(data, ui) {
  const sel = (data && data.selected) || {}, f = (data && data.filters) || {};
  const select = (name, label, options, value) => `<label>${esc(label)} <select data-tool-filter="${name}">${options.map(([v, l]) => `<option value="${esc(v)}"${String(v) === String(value ?? "") ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></label>`;
  const all = (vals, label = (v) => v) => [["", "All"], ...(vals || []).map((v) => [v, label(v)])];
  return `<div class="fields">${[
    select("days", "Window", [["7", "7 UTC days"], ["30", "30 UTC days"]], sel.days || ui.filters.days || 7),
    select("team", "Role", all(f.teams, (t) => TEAM_LABEL[t] || t), sel.team),
    select("lane", "Lane", all(f.lanes), sel.lane),
    select("profile", "Profile", all(f.profiles), sel.profile),
  ].join("")}<span class="th-win">${esc(windowLabel(data))}</span></div>`;
}
function stateLine(st, ui) {
  const parts = [];
  if (st.loading && st.data) parts.push(`<span class="pill">Refreshing; showing previous response</span>`);
  else if (st.loading) parts.push(`<span class="pill">Loading recorded observations…</span>`);
  if (st.error || (st.data && st.data.state === "error")) parts.push(`<span class="pill fail">Tool health could not load. Retry.</span>${st.data && st.data.state !== "error" && st.loadedAt ? ` <span class="pill warn">stale since ${esc(hhmm(st.loadedAt))}</span>` : ""}`);
  if (st.loadedAt) parts.push(`<span class="th-at">Loaded at ${esc(stamp(st.loadedAt))}</span>`);
  return `<div class="filters" role="status">${parts.join(" ")}<button class="btn" data-act="refresh-toolhealth"${st.loading ? " disabled" : ""}>Refresh</button> <a class="btn quiet" data-act="th-reset" href="${esc(toolHealthHref({ filters: {} }, { tab: ui.tab }))}">Reset filters</a></div>`;
}
const TABS = [["overview", "Tools & guards"], ["station", "Station"], ["map", "Tool map"], ["hooks", "Hook wiring"], ["reviewers", "Reviewers"]];
const tabs = (ui) => `<nav class="tabs" role="tablist" aria-label="Tool health">${TABS.map(([id, label]) => `<a class="tab" role="tab" aria-selected="${ui.tab === id && !ui.tool && !ui.guard}" href="${esc(toolHealthHref(ui, { tab: id }))}">${esc(label)}</a>`).join("")}</nav>`;

export function renderToolHealth(st, token = "", ui = {}) {
  st = st || {};
  ui = { tab: "overview", sort: "failed", ...ui, filters: { ...(ui.filters || {}) } };
  const data = st.data && st.data.state !== "error" ? st.data : null;
  const head = `<header class="ph"><h1>Tool health</h1><p>Is anything failing more than usual, and where? Recorded call attempts and outcomes · read-only.</p></header>`;
  const controls = ui.tab === "reviewers" && !ui.tool && !ui.guard ? "" : filterBar(data || st.data, ui);
  let body;
  if (ui.tool) body = toolDrill(data, st.inventory, ui, token);
  else if (ui.guard) body = guardDrill(data, ui, token);
  else body = ({ station: () => stationTab(data, st.inventory, ui), map: () => mapTab(data, st.inventory, ui), hooks: () => hooksTab(data, st.inventory, ui), reviewers: () => reviewersTab(st.reviewers) }[ui.tab] || (() => overview(data, st, ui)))();
  return pg(`${head}${tabs(ui)}${controls}${stateLine(st, ui)}${body}`);
}

// ---- overview
function kpis(data) {
  const tools = data ? data.tools || [] : null, bad = data ? badCounts(data) : new Set();
  const sum = (k) => (tools ? tools.reduce((n, t) => n + (isNum(t[k]) ? t[k] : 0), 0) : null);
  const calls = data ? data.totalCalls : null, failed = sum("failures"), known = sum("known"), recovered = sum("recovered");
  const rate = bad.size ? null : ratio(failed, calls);
  const tile = (id, label, value, note) => `<div class="kpi" data-kpi="${id}"><span class="k">${esc(label)}</span><b class="kv">${esc(value)}</b><span class="ks">${esc(note)}</span></div>`;
  // mockup v9: four cards. Denied rides the Failed note; Recovery is the note under the cards, so no fact leaves the page.
  const worst = data && !bad.size ? tools.filter((t) => isNum(t.calls) && t.calls >= 10 && isNum(t.failures)).map((t) => ({ t, r: t.failures / t.calls })).sort((a, b) => b.r - a.r || b.t.failures - a.t.failures || (a.t.tool < b.t.tool ? -1 : 1))[0] : null;
  const recovery = data ? `<p class="sub" data-note="recovery">Recovery ${pct(ratio(recovered, known))} (${recovered} of ${known} known · ${failed - known} unclassified)</p>` : "";
  return `<div class="kpis">${[
    tile("calls", "Calls", num(calls), data ? (isNum(calls) ? "tool call attempts" : "calls not recorded for every session") : "—"),
    tile("failed", "Failed", num(failed), data ? `${sum("errors")} errors · ${sum("denials")} denied${sum("blocked") ? ` · ${sum("blocked")} blocked reports (not failures)` : ""}` : "—"),
    tile("rate", "Failure rate", pct(rate), data ? (bad.size ? "Count check failed: rate hidden" : `${failed} of ${num(calls)} calls`) : "—"),
    tile("highest", "Highest rate", worst ? pct(worst.r) : "—", data ? (worst ? `${worst.t.tool} · ${worst.t.failures} of ${worst.t.calls} calls` : "no tool with 10 or more calls") : "—"),
  ].join("")}</div>${recovery}`;
}
function dailyRows(data) {
  const by = new Map();
  for (const d of data.daily || []) {
    const r = by.get(d.day) || { calls: 0, failures: 0 };
    r.calls = isNum(r.calls) && isNum(d.calls) ? r.calls + d.calls : null;
    r.failures += isNum(d.failures) ? d.failures : 0;
    by.set(d.day, r);
  }
  return windowDays(data).map((day) => { const r = by.get(day); return { day, calls: r ? r.calls : null, failures: r ? r.failures : null, rate: r ? ratio(r.failures, r.calls) : null, gap: !r }; });
}
function shiftDays(shift) {
  const s = shift && shift.shift;
  if (!s || !s.opened) return new Set();
  const a = Date.parse(s.opened), b = s.closed ? Date.parse(s.closed) : Date.now(), out = new Set();
  for (let t = Date.UTC(new Date(a).getUTCFullYear(), new Date(a).getUTCMonth(), new Date(a).getUTCDate()); t <= b; t += 86400000) out.add(new Date(t).toISOString().slice(0, 10));
  return out;
}
function chartTop(max, kind) {
  if (kind === "bar") return max <= 4 ? 4 : Math.ceil(max / 10) * 10;
  if (!(max > 0)) return 0.02;
  const p = 10 ** Math.floor(Math.log10(max));
  return [1, 2, 4, 5, 10].map((k) => k * p).find((t) => t >= max) || 10 * p;
}
// mockup v9 geometry: a fixed 480x180 plot, scaled uniformly so dots stay round
function chart(rows, value, max, label, kind) {
  const W = 480, H = 180, left = 48, right = 470, base = 146, plot = 116, step = (right - left) / (rows.length || 1);
  const top = chartTop(max, kind), bar = kind === "bar";
  const X = (i) => left + (i + 0.5) * step, Y = (v) => base - (v / top) * plot;
  // a rate tick keeps enough decimals that the three ticks stay distinct for a tiny top
  const tick = (v) => (bar ? label(v) : `${(v * 100).toFixed(Math.max(1, Math.ceil(-Math.log10(top * 50))))}%`);
  const grid = [0, 1, 2].map((i) => `<line x1="${left}" y1="${base - (plot * i) / 2}" x2="${right}" y2="${base - (plot * i) / 2}" class="grid"/><text class="ax" x="${left - 6}" y="${base - (plot * i) / 2 + 4}" text-anchor="end">${esc(tick((top * i) / 2))}</text>`).join("");
  const band = rows.map((r, i) => (r.shift ? `<rect x="${left + i * step}" y="${base - plot}" width="${step}" height="${plot}" class="shiftband"><title>AFK shift</title></rect>` : "")).join("");
  const dl = rows.map((r, i) => `<text class="dl" x="${X(i)}" y="168" text-anchor="middle"${rows.length > 14 ? " data-dense" : ""}>${esc(String(Number(r.day.slice(8, 10))))}</text>`).join("");
  let marks = "", line = "", prev = null;
  rows.forEach((r, i) => {
    const v = value(r), x = X(i);
    if (!isNum(v)) { prev = null; if (!bar) marks += `<text x="${x}" y="${base - 4}" class="gap" text-anchor="middle">·</text>`; return; }
    const y = Y(v), tip = `<title>${esc(r.day)}: ${esc(label(v))}</title>`;
    if (bar) { marks += `<rect x="${x - step * 0.3}" y="${y}" width="${step * 0.6}" height="${base - y}" class="fb">${tip}</rect>`; return; }
    if (prev) line += `<line x1="${prev[0]}" y1="${prev[1]}" x2="${x}" y2="${y}" class="line"/>`;
    marks += `<circle cx="${x}" cy="${y}" r="4" class="dot">${tip}</circle>`;
    prev = [x, y];
  });
  return `<svg class="thchart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(bar ? "Failures per day; exact values in the table" : "Failure rate per day; gaps have no calls recorded")}">${band}${grid}${line}${marks}${dl}</svg>`;
}
function dailyPanel(data, st) {
  const rows = dailyRows(data), today = new Date(st.loadedAt || Date.now()).toISOString().slice(0, 10), shift = shiftDays(st.shift);
  rows.forEach((r) => { r.shift = shift.has(r.day); });
  const maxF = Math.max(0, ...rows.map((r) => r.failures || 0)), maxR = Math.max(0, ...rows.map((r) => r.rate || 0));
  const table_ = table(["Day (UTC)", "Calls", "Failed", "Failure rate"], rows.map((r) => `<tr data-day="${r.day}">${td(`${esc(dayLabel(r.day))}${r.day === today ? " (still accumulating)" : ""}${r.shift ? ' <span class="tag">AFK shift</span>' : ""}`)}${td(num(r.calls))}${td(num(r.failures))}${td(pct(r.rate))}</tr>`));
  return `<div class="th-charts"><figure class="card"><h3>Failures per day <span class="tag">failed calls</span></h3>${sub("A tall bar is the first thing to look into.")}${chart(rows, (r) => r.failures, maxF, String, "bar")}</figure><figure class="card"><h3>Failure rate per day <span class="tag">failed ÷ calls</span></h3>${sub("Tells a bad day from a busy one. A gap is a day with no calls recorded, not a healthy day.")}${chart(rows, (r) => r.rate, maxR, pct, "line")}</figure></div><details><summary>Exact values per day</summary>${table_}</details>`;
}

function toolCounts(r, data) {
  if (r.t) return r.t;
  const zero = isNum(data && data.totalCalls) ? 0 : null;
  return { calls: zero, failures: zero, errors: zero, denials: zero, rate: null };
}
function hookRows(data, inv) {
  const refused = new Map((data && data.hooks || []).map((h) => [h.class, h]));
  return (inv && inv.hooks || []).map((h) => {
    const cls = `denied/${h.name.replace(/\.(sh|js|mjs|py)$/, "")}`, hit = refused.get(cls), seen = measuredRuns(data, h.name);
    return { key: `hook:${h.source}:${h.name}`, kind: "hook", src: srcOf(h.source), source: h.source, hook: h, guard: hit ? cls : null, refused: hit ? hit.failures : null, runs: isNum(seen) ? seen : derivedRuns(h, data), runsMeasured: isNum(seen) };
  });
}
const RUNS_SCOPE = "Measured hook runs cover every session on this station and ignore the filters; derived runs and Refused follow them.";
// A hook that ran inside the hook chain has a run count the chain log measured; any other hook keeps the derived count.
function measuredRuns(data, name) {
  const m = data && data.chain && data.chain.members && Object.hasOwn(data.chain.members, name) ? data.chain.members[name] : null;
  return m && isNum(m.runs) ? m.runs : null;
}
function cliRows(data, inv) {
  const heads = new Map((data && data.bash && data.bash.commands || []).map((c) => [c.head, c]));
  return (inv && inv.clis || []).filter((c) => c.state === "ok").map((c) => ({ key: `cli:${c.name}`, kind: "cli", src: "station", source: "station", cli: c, calls: heads.has(c.name) ? heads.get(c.name).calls : null }));
}
// Only a tool event's runs follow from tool calls; a hook on any other event has no derived count.
const TOOL_EVENTS = new Set(["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]);
function derivedRuns(h, data) {
  const tools = data && data.tools || [];
  let n = 0;
  for (const [event, matcher] of h.wired || []) {
    if (!TOOL_EVENTS.has(event)) return null;
    let re;
    try { re = !matcher || matcher === "*" ? /.*/ : new RegExp(`^(?:${matcher})$`); } catch { return null; }
    for (const t of tools) { const base = t.tool.split(":")[0]; if (re.test(base) || re.test(t.tool)) { if (!isNum(t.calls)) return null; n += t.calls; } }
  }
  return n;
}

function sortRows(rows, sort, data) {
  const name = (a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  const val = (r, k) => { const c = r.kind === "hook" ? { failures: r.refused, calls: r.runs } : r.kind === "cli" ? { calls: r.calls } : toolCounts(r, data); return k === "rate" ? (isNum(c.rate) ? c.rate : -1) : isNum(c[k]) ? c[k] : -1; };
  const by = { failed: "failures", rate: "rate", calls: "calls" }[sort];
  return [...rows].sort((a, b) => (by ? val(b, by) - val(a, by) || (by === "rate" ? val(b, "failures") - val(a, "failures") : 0) : 0) || name(a, b));
}
function listRow(r, data, ui, bad, max) {
  const chip = `<span class="tag">${esc(KIND_LABEL[r.kind])}</span>`;
  const srcText = r.source && r.src !== "core" ? `${SRC_LABEL[r.src]} · ${r.source}` : SRC_LABEL[r.src];
  if (r.kind === "hook") {
    const link = r.guard ? toolHealthHref(ui, { guard: r.guard }) : toolHealthHref(ui, { tab: "hooks" });
    return `<tr data-tool-row="${esc(r.key)}">${tdWrap(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(link)}">${esc(r.hook.name)}</a> ${chip}${r.hook.runs_twice ? ' <span class="tag warn">×2 runs twice</span>' : ""}`)}${td(esc(srcText))}${td(`${num(r.runs)} <span class="dim">runs ${r.runsMeasured ? "measured" : "derived"}</span>`)}${td(num(r.refused))}${td("—")}${td(num(r.refused))}${td("—")}${td("")}</tr>`;
  }
  if (r.kind === "cli") return `<tr data-tool-row="${esc(r.key)}">${tdWrap(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(toolHealthHref(ui, { tab: "station" }))}">${esc(r.cli.name)}</a> ${chip}`)}${td(esc(srcText))}${td(`${num(r.calls)} <span class="dim">Bash calls</span>`)}${td("—")}${td("—")}${td("—")}${td("—")}${td("")}</tr>`;
  const c = toolCounts(r, data), flagged = bad.has(r.key);
  const bar = isNum(c.failures) && max > 0 ? `<span class="thbar" data-w="${((c.failures / max) * 100).toFixed(1)}"></span>` : "";
  const rateCell = flagged ? '<span class="tag fail">Count check failed</span>' : `<span class="${c.rate >= 0.1 ? "bad-t" : c.rate >= 0.05 ? "warn-t" : ""}">${pct(c.rate)}</span>${isNum(c.calls) && c.calls > 0 && c.calls < 10 ? ' <span class="tag">few calls</span>' : ""}`;
  return `<tr data-tool-row="${esc(r.key)}">${tdWrap(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(toolHealthHref(ui, { tool: r.key }))}">${esc(displayName(r))}</a> ${chip}`)}${td(esc(srcText))}${td(num(c.calls))}${td(num(c.failures))}${td(num(c.errors))}${td(num(c.denials))}${td(rateCell)}${td(bar)}</tr>`;
}
function beforeSplit(data) {
  const out = new Map();
  for (const t of data.tools || []) {
    const key = t.tool.startsWith("Skill:") ? "Skill" : t.tool.startsWith("Agent:") ? "Agent" : /^mcp__/.test(t.tool) ? "mcp" : t.tool === "Task" ? "Agent" : t.tool;
    const r = out.get(key) || { tool: key, calls: 0, failures: 0, errors: 0, denials: 0 };
    r.calls = isNum(r.calls) && isNum(t.calls) ? r.calls + t.calls : null;
    for (const k of ["failures", "errors", "denials"]) r[k] += isNum(t[k]) ? t[k] : 0;
    out.set(key, r);
  }
  const rows = [...out.values()].sort((a, b) => b.failures - a.failures || (a.tool < b.tool ? -1 : 1));
  return table(["Tool (before the split)", "Calls", "Failed", "Errors", "Denied", "Failure rate"], rows.map((r) => `<tr>${td(esc(r.tool))}${td(num(r.calls))}${td(num(r.failures))}${td(num(r.errors))}${td(num(r.denials))}${td(pct(ratio(r.failures, r.calls)))}</tr>`));
}
function toolList(data, inv, ui, opts = {}) {
  const bad = data ? badCounts(data) : new Set();
  let rows = catalogue(data, inv);
  if (ui.kind === "hook" || ui.kind === "cli" || opts.withOutside) rows = [...rows, ...hookRows(data, inv), ...cliRows(data, inv)];
  const q = String(ui.q || "").toLowerCase();
  const shown = rows.filter((r) => (!ui.kind || r.kind === ui.kind) && (!ui.src || r.src === ui.src) && (!q || r.key.toLowerCase().includes(q)));
  let sorted = sortRows(shown, ui.sort, data);
  if (ui.group) {
    const g = ui.group === "source" ? (r) => r.src : (r) => r.kind, order = ui.group === "source" ? SRCS : KINDS;
    sorted = order.flatMap((k) => sorted.filter((r) => g(r) === k));
  }
  const limited = ui.all || q || ui.kind || ui.src ? sorted : sorted.slice(0, 10);
  const max = Math.max(0, ...sorted.map((r) => (r.t && isNum(r.t.failures) ? r.t.failures : 0)));
  let groupNow = null;
  const body = limited.map((r) => {
    const g = ui.group ? (ui.group === "source" ? SRC_LABEL[r.src] : KIND_LABEL[r.kind]) : null;
    const headRow = g && g !== groupNow ? `<tr class="th-grp"><th colspan="8" scope="rowgroup">${esc(g)}</th></tr>` : "";
    groupNow = g;
    return headRow + listRow(r, data, ui, bad, max);
  });
  const chip = (act, v, label, on) => `<button class="chip" data-act="${act}" data-v="${esc(v)}" aria-pressed="${on}">${esc(label)}</button>`;
  const srcs = [...new Set(rows.map((r) => r.src))].sort((a, b) => SRCS.indexOf(a) - SRCS.indexOf(b));
  const controls = `<div class="filters">${chip("th-kind", "", "All kinds", !ui.kind)}${[...new Set(rows.map((r) => r.kind))].sort((a, b) => KINDS.indexOf(a) - KINDS.indexOf(b)).map((k) => chip("th-kind", k, KIND_LABEL[k], ui.kind === k)).join("")}</div>
<div class="fields"><label>Source <select data-th="src"><option value="">All</option>${srcs.map((s) => `<option value="${s}"${ui.src === s ? " selected" : ""}>${esc(SRC_LABEL[s])}</option>`).join("")}</select></label><label>Search <input id="th-q" data-th="q" type="search" value="${esc(ui.q || "")}" placeholder="tool, skill, server"></label><label>Sort <select data-th="sort">${[["rate", "Highest failure rate"], ["failed", "Most failures"], ["calls", "Most calls"], ["name", "Name"]].map(([v, l]) => `<option value="${v}"${ui.sort === v ? " selected" : ""}>${l}</option>`).join("")}</select></label>${chip("th-group", "kind", "Group by kind", ui.group === "kind")}${chip("th-group", "source", "Group by source", ui.group === "source")}${chip("th-before", "1", "Before split", !!ui.before)}</div>`;
  const empty = q ? `No tool matches “${ui.q}”` : "No tools match these filters";
  const more = !ui.all && limited.length < sorted.length ? `<button class="btn" data-act="th-all">Show all (${sorted.length})</button>` : ui.all && sorted.length > 10 ? `<button class="btn quiet" data-act="th-all">Top 10 only</button>` : "";
  const shownLine = `<p class="sub">${limited.length} of ${sorted.length} shown${bad.size ? ' · <span class="tag fail">Count check failed</span> for ' + esc([...bad].join(", ")) : ""}. Errors include a red test suite. Rows marked “before the split” were written before skills, subagents and MCP servers got their own rows.${limited.some((r) => r.kind === "hook" && r.runsMeasured) ? ` ${esc(RUNS_SCOPE)}` : ""}</p>`;
  return `${controls}${ui.before && data ? `<p class="sub">Before split: today's rows collapsed back to Skill, Agent and mcp, for comparison.</p>${beforeSplit(data)}` : `${shownLine}${table(["Tool", "Source", "Calls", "Failed", "Errors", "Denied", "Failure rate", ""], body, empty, "thtab")}${more}`}`;
}

const isClassifier = (cls) => /^denied\/classifier(:|$)/.test(cls);
function guardsPanel(data, ui) {
  const rows = (data.hooks || []).filter((h) => !isClassifier(h.class)).sort((a, b) => b.failures - a.failures || (a.class < b.class ? -1 : 1));
  return table(["Guard", "Refused", "Rate", "Denominator", "Bash-only rate (legacy)", "Legacy denominator"], rows.map((h) => `<tr data-guard-row="${esc(h.class)}">${tdWrap(`<a data-guard="${esc(h.class)}" href="${esc(toolHealthHref(ui, { guard: h.class }))}">${esc(h.class.replace(/^denied\//, ""))}</a>`)}${td(num(h.failures))}${td(pct2(h.eligible_rate))}${tdWrap(eligibleWords(h))}${td(pct(h.rate))}${tdWrap(isNum(h.calls) ? `÷${h.calls} Bash calls (legacy)` : "÷ Bash calls not recorded (legacy)")}</tr>`), "No guard refused a call in this window", "thtab");
}
// Option B: refusals over the calls to the tools the guard is wired to check ("eligible call attempts", never "calls checked").
const pct2 = (v) => (isNum(v) ? `${(v * 100).toFixed(2)}%` : "—");
function eligibleWords(h) {
  if (!isNum(h.eligible_calls)) return "eligible tools unknown";
  return isNum(h.outside_eligible) && h.outside_eligible > 0 ? `÷${h.eligible_calls} eligible call attempts · Count check failed: ${h.outside_eligible} refused on another tool` : `÷${h.eligible_calls} eligible call attempts`;
}
function classifierPanel(data) {
  const rows = (data.hooks || []).filter((h) => isClassifier(h.class)).sort((a, b) => b.failures - a.failures);
  return table(["Category", "Denied", "Label"], rows.map((h) => `<tr data-classifier-row="${esc(h.class)}">${td(esc(h.class.replace(/^denied\/classifier:?/, "") || "classifier"))}${td(num(h.failures))}${td("category · reason unverified")}</tr>`), "No classifier denial recorded in this window");
}
function lanePanel(data) {
  const rows = (data.comparison || []).filter((r) => r.key === "Bash" && r.metric !== "denial_rate");
  const lanes = (data.filters && data.filters.lanes || []).filter((l) => rows.some((r) => isNum(r.values && r.values[l])));
  const fmt = (m, v) => (m === "calls_per_100" ? (isNum(v) ? v.toFixed(1) : "—") : pct(v));
  const delta = (m, d) => (!isNum(d) ? "—" : m === "calls_per_100" ? `${d < 0 ? "−" : "+"}${Math.abs(d).toFixed(1)} calls/100` : `${d < 0 ? "−" : "+"}${Math.abs(d * 100).toFixed(1)} pp`);
  const label = { calls_per_100: "Bash calls per 100 calls", error_rate: "Error rate", recovery_rate: "Recovery" };
  const others = lanes.filter((l) => l !== "native");
  const head = ["Metric", ...lanes.map(esc), ...others.map((l) => `Δ ${esc(l)} vs native`)];
  return `${sub("All lanes; model, role and profile retained. Δ is against native; a rate Δ is in percentage points. No native value means no Δ.")}${table(head, rows.map((r) => `<tr data-lane-metric="${esc(r.metric)}">${td(esc(label[r.metric] || r.metric))}${lanes.map((l) => td(fmt(r.metric, r.values[l]))).join("")}${others.map((l) => td(delta(r.metric, r.delta && r.delta[l]))).join("")}</tr>`), "No lane recorded Bash calls in this window")}`;
}
const profileName = (p) => (p === "unknown" ? "unknown (launch profile not recorded)" : p);
const verdictWords = (t) => (t.verdict === "drop-candidate" ? "Move to on-demand (drop from default)" : t.listing_tokens === null || t.listing_tokens === undefined ? "Keep (listing cost not measured)" : "Keep");
function profilePanel(data) {
  const rows = (data.profiles || []).flatMap((p) => (p.tools && p.tools.length ? p.tools.map((t) => `<tr data-profile-tool="${esc(`${p.profile} ${t.tool}`)}">${td(esc(profileName(p.profile)))}${td(num(p.sessions))}${td(num(t.calls))}${td(esc(t.tool))}${td(pct(t.rate))}${td(isNum(t.listing_tokens) ? `${t.listing_tokens} tokens per listing` : "not measured")}${td(esc(verdictWords(t)))}</tr>`) : [`<tr data-profile-tool="${esc(p.profile)}">${td(esc(profileName(p.profile)))}${td(num(p.sessions))}${td("—")}${td("no tool rows")}${td("—")}${td("—")}${td("—")}</tr>`]));
  const empty = '<p class="nodata">No per-profile data: no sessions in this period</p>';
  return `<h3 class="sec">Tools by launch profile</h3>${sub("Per launch profile: sessions, how often each tool was called and failed, its estimated listing cost (Skill listing only; MCP schemas are not measured), and whether it earns its place in that profile's default. Suggestions only: nothing changes until an operator applies one.")}${rows.length ? table(["Profile", "Sessions", "Calls", "Tool", "Failure rate", "Listing cost", "Suggestion"], rows) : empty}`;
}
// Role x lane x profile, straight from the rollup's cross_tab; the unknown share and what it was are named, never inferred.
function crossTabPanel(data) {
  const rows = (data.cross_tab || []).map((c) => `<tr data-cross-tab="${esc(`${c.team} ${c.lane} ${c.profile}`)}">${td(esc(TEAM_LABEL[c.team] || c.team))}${td(esc(c.lane))}${td(esc(profileName(c.profile)))}${td(num(c.sessions))}${td(num(c.calls))}${td(num(c.failures))}${td(num(c.denials))}</tr>`);
  const a = data.attribution || {};
  const remainder = (a.remainder || []).map((r) => `${esc(r.kind)} (${num(r.sessions)} sessions, ${num(r.calls)} calls)`).join(", ");
  const note = isNum(a.lane_unknown_share) || isNum(a.profile_unknown_share)
    ? `<p class="nodata" data-attribution>Lane unknown: ${pct(a.lane_unknown_share)} of calls (${num(a.lane_unknown_sessions)} of ${num(a.sessions)} sessions). Launch profile unknown: ${pct(a.profile_unknown_share)} of calls.${remainder ? ` Lane remainder by kind of session: ${remainder}.` : ""}</p>` : "";
  return `${sub("Every session's role, lane and launch profile come from its launch record at ingest. A session with no launch record reads unknown and names what kind of session it was; nothing is inferred.")}${table(["Role", "Lane", "Profile", "Sessions", "Calls", "Failures", "Denied"], rows, "No sessions in this window")}${note}`;
}
function candidatesPanel(data) {
  const rows = (data.drop_candidates || []).map((d) => `<tr data-candidate="${esc(`${d.profile} ${d.tool}`)}">${td(esc(d.profile))}${td(esc(d.tool))}${td(`${num(d.calls)} calls`)}${td(`${num(d.listing_tokens)} tokens per listing`)}</tr>`);
  return table(["Profile", "Tool", "Calls in window", "Listing cost"], rows, "Nothing loaded and unused, or the listing cost is not measured");
}

function launchesPanel(data) {
  const l = data.launches_refused;
  const note = (t) => `<p class="nodata">${esc(t)}</p>`;
  if (!l || l.state === "not-read") return note("Launch refusals were not read for this response.");
  const skipped = l.skipped > 0 ? note(`${num(l.skipped)} unreadable row${l.skipped === 1 ? "" : "s"}`) : "";
  if (l.state === "absent") return note("No launch refusal recorded yet.") + skipped;
  if (!l.total) return note("No launch refused in this window.") + skipped;
  const codes = (rc) => Object.entries(rc || {}).sort((a, b) => b[1] - a[1] || Number(a[0]) - Number(b[0])).map(([c, n]) => `${esc(c)} ×${num(n)}`).join(", ");
  const byCause = table(["Cause", "Refused", "Exit codes"], l.by_cause.map((c) => `<tr data-launch-cause="${esc(c.cause)}">${td(esc(c.cause))}${td(num(c.count))}${td(codes(c.rc))}</tr>`));
  const recent = table(["Time", "Worker", "Cause", "Exit", "Reason"], l.recent.map((r) => `<tr data-launch-row="${esc(r.ts)}">${td(esc(utc(r.ts)))}${td(r.name ? esc(r.name) : "—")}${td(esc(r.cause))}${td(num(r.rc))}${tdWrap(r.line ? esc(r.line) : "see the launch log")}</tr>`));
  return `${byCause}<details data-launch-recent><summary>Most recent refusals (${num(l.recent.length)} of ${num(l.total)})</summary>${recent}</details>${skipped}`;
}
function overview(data, st, ui) {
  const toolsBox = (text) => box("tools", "Tools", "Which tool, skill, hook or plugin fails most? Each name opens its drill-in.", `<p class="nodata">${esc(text)}</p>`, "First build");
  const launchesBox = () => box("launches", "Launches refused", "Worker launches not confirmed as started, by cause. Whole fleet: the filters above do not apply. Exit 7 and 9 may still have come up late.", launchesPanel(data));
  if (!data) return `${kpis(null)}${st.loading || st.error ? "" : toolsBox(st.data && st.data.state === "error" ? "Tool health could not load. Retry." : "No recorded tool observations in this window")}`;
  if (data.state !== "ok") return `${kpis(null)}${toolsBox("No recorded tool observations in this window. Try the 30-day window.")}${launchesBox()}`;
  const bad = badCounts(data);
  const banner = bad.size ? `<p class="nodata"><span class="tag fail">Count check failed</span> ${esc([...bad].join(", "))}: counts that cannot be true (more denials or errors than failures, or more failures than calls). Their rates are hidden, not clamped.</p>` : "";
  if (!(data.tools || []).length) return `${kpis(data)}<p class="nodata">No observations match these filters. <a class="btn" href="${esc(toolHealthHref({ filters: {} }))}">Reset filters</a></p>${launchesBox()}`;
  return `${banner}${kpis(data)}${dailyPanel(data, st)}
${box("tools", "Tools", "Which tool, skill, hook or plugin fails most? Each name opens its drill-in.", toolList(data, st.inventory, ui), "First build")}
${launchesBox()}
<div class="th-cols">${box("guards", "Guards that refuse most", "Which guard blocks the most calls? The rate is over the calls to the tools each guard is wired to check; the Bash-only rate is the older denominator, kept for comparison. A refusal can be correct.", guardsPanel(data, ui), "÷ eligible call attempts")}${box("classifier", "Classifier denials", "Which calls did the auto-mode classifier deny? A count per category; the reason stays unverified.", classifierPanel(data), "reason unverified")}</div>
${box("lanes", "Bash on each lane", "Does Bash fail more on one lane?", lanePanel(data))}
${box("roles", "Role, lane and profile", "Which role ran on which lane under which profile, and how much of the fleet the launch records leave unnamed?", crossTabPanel(data))}
${box("unused", "Loaded, never used", "Costs usage in every session; could load on demand. The cost is the estimated tokens per listing, not a measured gain.", candidatesPanel(data) + profilePanel(data))}`;
}

// ---- drill-ins
const back = (ui) => `<a class="btn quiet" href="${esc(toolHealthHref(ui))}">Back to overview</a>`;
const stat = (id, label, v) => `<div><dt>${esc(label)}</dt><dd data-stat="${id}">${esc(v)}</dd></div>`;
const weekCard = (id, label, v) => `<div class="kpi"><span class="k">${esc(label)}</span><b class="kv" data-stat="${id}">${esc(v)}</b></div>`;

// ---- hook-chain incidents (the `chain` section of GET /api/tool-health): why a guard refused one exact call, with the recorded timing.
const REASON_ROWS = [
  ["rule", "Rule", "the guard looked at the call and said no"],
  ["timeout", "Timeout", "the guard started but ran past its time budget"],
  ["deadline", "Never started", "the chain had no time left to run the guard"],
  ["buffer", "Output too large", "the guard's output overflowed its buffer"],
  ["other", "Other", "a reason code this page does not name"],
];
const OUTCOME_WORDS = { deny: "Refused the call", skip: "Skipped the check" };
const CHAIN_SCOPE = "Hook-chain logs cover every session on this station. The day window applies; the model, lane, role and profile filters do not apply to this box.";
const utc = (iso) => { const t = Date.parse(iso); return Number.isFinite(t) ? `${new Date(t).toISOString().slice(0, 19).replace("T", " ")} UTC` : "—"; };
const chainKnown = (c) => !!c && c.infra_known === true;
function chainNote(c) {
  if (!c || c.state === "not-read") return "Hook-chain logs were not read for this response, so the reason is unverified.";
  if (c.state === "absent") return "No hook-chain log was found on this station, so the reason is unverified.";
  if (c.state === "error") return "A hook-chain log could not be read, so the reason is unverified.";
  if (c.state !== "partial") return "";
  const why = [], a = c.audit || {};
  for (const [name, label] of [["skip", "skip log"], ["run", "run log"]]) {
    const s = c.sources && c.sources[name];
    if (!s || s.state !== "ok") why.push(`the ${label} is unavailable`);
    else if (s.truncated) why.push(`the ${label} was read from its newest part only`);
  }
  if (c.worktrees_unreadable) why.push("a worktree folder could not be listed, so its logs may be missing");
  if (a.unverified > 0) why.push(`unverified rows left out: ${a.unverified}`);
  if (a.malformed > 0) why.push(`malformed rows left out: ${a.malformed}`);
  return `Partial: ${why.join("; ")}. A count may be low, and a — is unverified.`;
}
function chainAudit(c) {
  const a = c && (c.state === "ok" || c.state === "partial") ? c.audit : null;
  if (!a) return "";
  return `<p class="sub" data-chain-audit>Rows read ${num(a.total)}: accepted ${num(a.accepted)} · test fixtures excluded ${num(a.excluded_fixture)} · unverified ${num(a.unverified)} · malformed ${num(a.malformed)} · duplicates ${num(a.duplicates)} · outside the window ${num(a.outside_window)} · not tool calls ${num(a.non_tool)}</p>`;
}
function timingWords(e) {
  if (e.not_started) return "not started";
  if (!isNum(e.elapsed_ms)) return "not recorded";
  if (!isNum(e.budget_ms)) return `${e.elapsed_ms} ms · budget not recorded`;
  if (e.budget_ms === 0) return `${e.elapsed_ms} ms · no budget recorded`;
  return `${e.elapsed_ms} ms of ${e.budget_ms} ms (${pct(e.ratio)})`;
}
const reasonWords = (e) => (e.kind === "other" ? `Other: ${e.reason}` : (REASON_ROWS.find(([k]) => k === e.kind) || [])[1] || `Other: ${e.reason}`);
function callDrawer(e, token) {
  const sess = UUID.test(e.session || "") ? `<a href="/agui/#${esc(new URLSearchParams({ t: token, run: e.session }).toString())}">${esc(e.session)}</a>` : e.session ? `<code>${esc(e.session)}</code>` : "—";
  const row = (label, v) => `<div><dt>${esc(label)}</dt><dd>${v}</dd></div>`;
  return `<details><summary><code>${esc(e.call_id)}</code></summary><dl class="stats">${row("Time", esc(utc(e.ts)))}${row("Outcome", esc(OUTCOME_WORDS[e.outcome] || e.outcome))}${row("Reason code", `<code>${esc(e.reason)}</code>`)}${row("Guard", esc(e.member))}${row("Tool", esc(e.tool || "—"))}${row("Session", sess)}${row("Call id", `<code>${esc(e.call_id)}</code>`)}${row("Chain run", `<code>${esc(e.invocation)}</code>`)}${row("Time used", esc(timingWords(e)))}${row("Refusal line", e.deny_line ? esc(e.deny_line) : "—")}${row("Recovery", "not recorded")}</dl></details>`;
}
const chainEvents = (events, token, empty) => table(["When (UTC)", "Outcome", "Reason", "Guard", "Tool", "Time used", "Refusal line", "Call"],
  events.map((e) => `<tr data-chain-event="${esc(e.call_id)}">${td(esc(utc(e.ts)))}${td(esc(OUTCOME_WORDS[e.outcome] || e.outcome))}${td(esc(reasonWords(e)))}${td(esc(e.member))}${td(esc(e.tool || "—"))}${td(esc(timingWords(e)))}${tdWrap(e.deny_line ? esc(e.deny_line) : "—")}${tdWrap(callDrawer(e, token))}</tr>`), empty, "events");
const noteP = (text) => (text ? `<p class="sub">${esc(text)}</p>` : "");
function guardWhy(data, h, token) {
  if (isClassifier(h.class)) return "";
  const c = data.chain, suffix = h.class.replace(/^denied\//, ""), known = chainKnown(c);
  const name = Object.keys(c && c.members || {}).find((k) => k.replace(/\.(sh|js|mjs|py)$/, "") === suffix), m = name ? c.members[name] : null;
  // With the counted refusals joined to the chain the rows count those refusals only, and two labelled residuals make them add up to Refused.
  const gap = h.reason_gap && known ? h.reason_gap : null;
  const count = (k) => (gap ? gap.by_reason[k] : m ? m.by_reason[k] : known && c.by_reason[k] !== null ? 0 : null);
  const residual = gap ? [["before_logged", "Recorded before reasons were logged", gap.before_reasons_logged, `refused before the hook chain began to log a reason${gap.run_log_start ? ` (the first run-log row is ${utc(gap.run_log_start)})` : ""}`],
    ["not_established", "No reason row, cause not established", gap.not_established, "refused with no chain row, and not older than the run log"]] : [];
  const rows = [...REASON_ROWS.map(([k, label, means]) => [k, label, count(k), means]), ...residual].map(([k, label, n, means]) => `<tr data-chain-reason="${k}">${td(esc(label))}${td(num(n))}${td(esc(means))}</tr>`);
  const unmatched = gap && gap.unmatched_chain > 0 ? `${gap.unmatched_chain} chain row${gap.unmatched_chain === 1 ? "" : "s"} names a refusal this window does not count (a session not yet digested, or a call outside the window).` : "";
  const shown = m ? m.events : [], total = m ? m.denials + m.skips : 0;
  const more = m && shown.length < total ? `Showing the newest ${shown.length} of ${total}.` : "";
  const outside = known && !m ? "No hook-chain row names this guard; it may run outside the chain." : "";
  const body = `${noteP(chainNote(c))}${table(["Reason", gap ? "Refusals" : "Refusals and skipped checks", "What it means"], rows)}${chainAudit(c)}${noteP(CHAIN_SCOPE)}${noteP(outside)}${noteP(unmatched)}${known ? `${chainEvents(shown, token, "No refusal or skipped check recorded for this guard in the chain logs")}${noteP(more)}` : ""}`;
  return box("guard-why", "Why it refused", "Was it the rule, a timeout, or a guard that never started? One row per exact call, from the hook-chain logs.", body);
}
function toolChain(data, key, token) {
  const c = data && data.chain, tool = /^(Skill|Agent):/.test(key) ? null : key, known = chainKnown(c) && tool !== null;
  const mine = known ? (c.events || []).filter((e) => e.tool === tool) : [];
  const capped = known && isNum(c.events_total) && c.events_total > (c.events || []).length;
  // A skill or subagent has no exact incident ids: the chain rows name the tool, so its count needs new data, not 0.
  const timeouts = tool === null ? "needs new data" : known ? `${capped ? "at least " : ""}${mine.filter((e) => e.kind === "timeout").length}` : "—";
  const shown = mine.slice(0, 20);
  const notes = `${noteP(tool === null ? "Needs new data: the chain logs name the tool, not the skill or subagent, so its timeouts have no exact call ids. The hook runner would have to record which skill or subagent a call named." : chainNote(c))}${chainAudit(c)}${noteP(CHAIN_SCOPE)}`;
  const none = capped ? `None of the newest ${c.events.length} events name this tool; ${c.events_total - c.events.length} older events are not shown` : "No guard refused or skipped a call to this tool in the chain logs";
  const events = known ? `${chainEvents(shown, token, none)}${noteP(shown.length < mine.length ? `Showing the newest ${shown.length} of ${capped ? "at least " : ""}${mine.length}.` : "")}` : "";
  return box("chain", "Timeouts and recent events", "How often did a guard time out on this tool, and what happened last? Guards that refused or skipped a call to it, from the hook-chain logs.", `<dl class="stats">${stat("timeouts", "Timeouts", timeouts)}</dl>${notes}${events}`);
}
// Time to result per tool: RESULT time minus START time, so it includes waiting and the hook chain. Calls that shared an API message
// wait on each other and stay out of the headline; a call with no time is counted apart, never as 0.
function timeBox(t, c) {
  const tm = t.timing || {}, ms = (v) => (isNum(v) ? `${v} ms` : "—"), plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
  const hook = c && c.hook_ms_by_tool && c.hook_ms_by_tool[t.tool];
  const batched = isNum(tm.batched_n) && tm.batched_n > 0 ? `${ms(tm.batched_p50_ms)} (${plural(tm.batched_n, "batched call")}, kept out of the headline)` : "—";
  const hookText = hook ? `${ms(hook.p50_ms)} median over ${plural(hook.n, "run")} of the hook chain` : "—";
  const notes = [hook ? "Hook chain time covers every session on this station and ignores the filters." : "", isNum(tm.unknown_calls) && tm.unknown_calls > 0 ? `${plural(tm.unknown_calls, "call")} ${tm.unknown_calls === 1 ? "was" : "were"} recorded before time to result was kept.` : "",
    isNum(tm.missing) && tm.missing > 0 ? `${plural(tm.missing, "call")} had no result or no time recorded; they show as — and are not counted as 0.` : "",
    tm.capped ? "Some calls were not kept, so the percentiles use the first kept times." : ""].filter(Boolean);
  const stats = `<dl class="stats">${stat("ttr-p50", "Median (p50)", ms(tm.p50_ms))}${stat("ttr-p95", "p95", ms(tm.p95_ms))}${stat("ttr-n", "Calls timed", num(tm.n))}${stat("ttr-batched", "Batched calls", batched)}${stat("ttr-missing", "Calls with no time", num(tm.missing))}${stat("ttr-hook", "Hook chain time", hookText)}</dl>`;
  return box("time", "Time to result", "How long until this tool's result came back? The headline is calls issued alone; it is time to result (includes waiting and hooks), not the time the tool itself ran.", `${stats}${notes.map(noteP).join("")}`);
}
function evidence(sessions, ids, token) {
  const seen = [...new Set(sessions || [])], ok = seen.filter((s) => UUID.test(s)), bad = seen.filter((s) => !UUID.test(s));
  const links = ok.map((s) => `<a href="/agui/#${esc(new URLSearchParams({ t: token, run: s }).toString())}">${esc(s)}</a>`);
  return `<p class="sub">${ok.length} sessions with observations (not every session that ran)</p><p>${links.join("<br>") || "—"}</p>${bad.length ? `<p class="sub">Not a session id, so not a link: ${bad.map((s) => `<code>${esc(s)}</code>`).join(", ")}</p>` : ""}<p class="sub">Sampled call ids (up to 20, samples only): ${(ids || []).map(esc).join(", ") || "—"}</p>`;
}
function trendTable(trend, attr) {
  const rows = (trend || []).map((p) => ({ ...p, rate: isNum(p.calls) && p.calls > 0 ? ratio(p.failures, p.calls) : null }));
  const max = Math.max(0, ...rows.map((r) => r.rate || 0));
  return `${chart(rows, (r) => r.rate, max, pct, "line")}${table(["Day (UTC)", "Calls", "Failed", "Failure rate"], rows.map((p) => `<tr ${attr}="${esc(p.day)}">${td(esc(dayLabel(p.day)))}${td(num(p.calls))}${td(num(p.failures))}${td(pct(p.rate))}</tr>`))}`;
}
// mockup v9 "Failures by cause": one stacked bar over five cards. The server refuses inline style attributes, so the bar is an SVG
// whose segment widths are percent attributes and whose fills are tokens. rtk filter has no data yet (rtk logs no call id): it reads —.
const CAUSE_FILL = { command: "var(--crit)", rtk_hook: "var(--beta)", guard: "var(--road)", classifier: "var(--alpha)", other: "var(--rule-strong)" };
function causeView(totals, b, rtkOk) {
  // No Bash call carries its command yet, so no cause was recorded: zeros here would read as an all-clear.
  if (!(b.recorded > 0)) return `<p class="nodata">No failure cause recorded: no Bash call in this window carries its command yet</p>`;
  const failed = Object.values(totals).reduce((n, v) => n + v, 0);
  let at = 0;
  const segs = Object.entries(totals).filter(([, v]) => v > 0).map(([k, v]) => {
    const w = (v / failed) * 100, x = at;
    at += w;
    return `<rect data-cause-seg="${k}" x="${x.toFixed(2)}" y="0" width="${w.toFixed(2)}" height="18" fill="${CAUSE_FILL[k]}"><title>${esc(k.replace("_", " "))}: ${esc(String(v))}</title></rect>`;
  }).join("");
  const bar = `<svg class="thcausebar" viewBox="0 0 100 18" width="100%" height="18" preserveAspectRatio="none" role="img" aria-label="${esc(`${failed} failed Bash calls by cause`)}"><rect x="0" y="0" width="100" height="18" fill="var(--surface-2)"/>${segs}</svg>`;
  const swatch = (k) => `<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><rect width="10" height="10" fill="${CAUSE_FILL[k]}"/></svg> `;
  const card = (id, label, value, k, title = "") => `<div class="kpi" data-cause-card="${id}"><span class="k">${k ? swatch(k) : ""}${esc(label)}</span><b class="kv"${title ? ` title="${esc(title)}"` : ""}>${esc(value)}</b></div>`;
  const cards = `<div class="kpis">${[
    card("command", "Command", String(totals.command), "command"),
    card("rtk-filter", "rtk filter", "—", null, "rtk's parse failures carry no call id until upstream rtk logs one; these failures count under Command for now"),
    rtkOk ? card("rtk-hook", "rtk hook", String(totals.rtk_hook), "rtk_hook") : card("rtk-hook", "rtk hook", "—", "rtk_hook", "rtk history could not be read, so an rtk hook refusal cannot be told from a himmel guard refusal; it counts under himmel guard"),
    card("guard", "himmel guard", String(totals.guard), "guard"),
    card("classifier", "Auto-mode classifier", String(totals.classifier), "classifier"),
  ].join("")}</div>`;
  // Causes come from the calls that carry their command; a window with older calls shows a subset, so say how much.
  const all = isNum(b.unrecorded) ? b.recorded + b.unrecorded : null;
  const cover = b.unrecorded === null || b.unrecorded > 0 ? `<p class="sub">Failure causes cover ${num(b.recorded)} of ${isNum(all) ? num(all) : "an unknown number of"} calls: the rest were written before the command was recorded.</p>` : "";
  return `${bar}${cards}${totals.other > 0 ? `<p class="sub">${esc(String(totals.other))} other: a failure with no named cause.</p>` : ""}${cover}`;
}
function bashSections(data) {
  const b = data.bash;
  if (!b) return "";
  const rtkOk = b.rtk && b.rtk.state === "ok";
  const cmds = table(["Command", "Calls", "rtk", "bash", "Failed"], (b.commands || []).map((c) => `<tr data-command="${esc(c.head)}">${td(esc(c.head))}${td(num(c.calls))}${td(rtkOk ? num(c.rtk) : "—")}${td(rtkOk ? num(c.bash) : "—")}${td(num(c.failures))}</tr>`), "No Bash command recorded in this window");
  const causes = { command: "command", rtk_hook: "rtk hook", guard: "himmel guard", classifier: "classifier", other: "other" };
  const totals = Object.fromEntries(Object.keys(causes).map((k) => [k, (b.commands || []).reduce((n, c) => n + ((c.cause && c.cause[k]) || 0), 0)]));
  const fl = b.fleet;
  const rtkRows = rtkOk && fl ? [["rtk", fl.rtk], ["bash", fl.bash], ["not in rtk history", fl.unmatched]].map(([k, v]) => `<tr data-path="${k}">${td(k)}${td(num(v.calls))}${td(num(v.failures))}${td(pct(ratio(v.failures, v.calls)))}</tr>`) : [];
  const rtkBody = rtkOk && fl ? `${table(["Path", "Calls", "Failed", "Failure rate"], rtkRows)}<p class="sub">rtk history: ${num(b.rtk.matched)} matched, ${num(b.rtk.unmatched)} unmatched, ${num(b.rtk.duplicates)} duplicate call ids.</p>` : `<p class="nodata">rtk history unavailable (${esc(b.rtk ? b.rtk.state : "not-read")}): rtk —, bash —</p>`;
  return `${box("bash-cmd", "Calls by command", `Which commands run, and how many go through rtk? The command is recorded for ${num(b.recorded)} calls; ${num(b.unrecorded)} were written before it was.`, cmds)}
${box("bash-cause", "Failures by cause", "Who broke the call: the command, the rtk hook, a himmel guard or the classifier? rtk filter failures need rtk to log the call id (later).", causeView(totals, b, rtkOk))}
${box("bash-rtk", "rtk vs bash", "Does going through rtk fail more often? Whole fleet: not split by role, lane or profile.", rtkBody, "whole fleet")}`;
}
function toolDrill(data, inv, ui, token) {
  const r = catalogue(data, inv).find((x) => x.key === ui.tool);
  if (!r) return `<section class="box">${back(ui)}<h2>No matching tool</h2>${sub(`“${ui.tool}” is not in this window's response or the station scan.`)}</section>`;
  const head = `${back(ui)}<h2>Tool drill-in: ${esc(displayName(r))} <span class="tag">${esc(KIND_LABEL[r.kind])}</span> <span class="tag">${esc(SRC_LABEL[r.src])}${r.source && r.src !== "core" ? ` · ${esc(r.source)}` : ""}</span></h2>`;
  if (!r.t) return `<section class="box">${head}${sub("What happened to this tool in the window?")}<p class="nodata">No recorded calls in this window. The station scan lists it; calls ${isNum(data && data.totalCalls) ? "0" : "—"}.</p></section>${toolChain(data, r.key, token)}`;
  const t = r.t, bad = badCounts(data).has(t.tool);
  const stats = `<dl class="stats">${stat("calls", "Calls", num(t.calls))}${stat("failed", "Failed", num(t.failures))}${stat("errors", "Errors", num(t.errors))}${stat("denied", "Denied", num(t.denials))}${isNum(t.blocked) && t.blocked > 0 ? stat("blocked", "Blocked reports", num(t.blocked)) : ""}${stat("rate", "Failure rate", bad ? "Count check failed" : pct(t.rate))}${stat("error-rate", "Error rate", bad ? "—" : pct(t.error_rate))}${stat("recovery", "Recovery", `${pct(t.recovery_rate)} (${num(t.recovered)} of ${num(t.known)} known)`)}</dl>`;
  const classes = table(["Class", "Count", "Share of this tool's calls"], (t.classes || []).map((c) => `<tr data-class="${esc(c.class)}">${td(esc(c.class))}${td(num(c.count))}${td(pct(ratio(c.count, t.calls)))}</tr>`), "No failure class recorded");
  return `<section class="box">${head}${sub("Was it this tool, or its callers? The same population as the overview row.")}${stats}</section>
${t.tool === "Bash" ? bashSections(data) : ""}
${timeBox(t, data.chain)}
${box("classes", "Failure classes", "Which kinds of failure, each over this tool's own calls.", classes)}
${box("trend", `${(t.trend || []).length}-day trend`, "Failure rate per UTC day; a gap is a day with no calls recorded.", trendTable(t.trend, "data-trend-day"))}
${box("evidence", "Evidence", "Sessions that recorded this tool, opened in AG-UI.", evidence(t.sessions, t.tool_call_ids, token))}
${toolChain(data, t.tool, token)}`;
}
function guardDrill(data, ui, token) {
  const h = data && (data.hooks || []).find((x) => x.class === ui.guard);
  if (!h) return `<section class="box">${back(ui)}<h2>No matching guard</h2>${sub(`“${ui.guard}” refused nothing in this window's response.`)}</section>`;
  const cohort = new Set((data.daily || []).map((d) => d.day)), by = new Map();
  for (const d of data.daily_hooks || []) if (d.class === h.class) by.set(d.day, (by.get(d.day) || 0) + (isNum(d.failures) ? d.failures : 0));
  const days = windowDays(data).map((day) => ({ day, n: by.has(day) ? by.get(day) : cohort.has(day) ? 0 : null }));
  const max = Math.max(0, ...days.map((d) => d.n || 0));
  // The four This week cards sit beside the chart; the eligible attempts, the legacy rate, Bash calls and recovery are in the counted box below.
  const peak = days.reduce((b, d) => (isNum(d.n) && d.n > 0 && (!b || d.n > b.n) ? d : b), null), counted = days.filter((d) => isNum(d.n));
  const cards = `<h3>${data.selected && data.selected.days === 30 ? "This window (30 days)" : "This week"}</h3><div class="kpis th-cols">${weekCard("refused", "Refused", num(h.failures))}${weekCard("rate", "Rate ÷ eligible call attempts", pct2(h.eligible_rate))}${weekCard("busiest", "Busiest day", peak ? `${dayLabel(peak.day)} · ${peak.n}` : "—")}${weekCard("none", "Days with none", counted.length ? num(counted.filter((d) => d.n === 0).length) : "—")}</div>`;
  const counting = box("guard-counts", "How the rate is counted", "The eligible call attempts behind the rate, the older Bash-only rate kept for comparison, and how often a refused call was retried and recovered.", `<dl class="stats">${stat("eligible", "Eligible call attempts", num(h.eligible_calls))}${stat("legacy-rate", "Rate ÷ Bash calls (legacy)", pct(h.rate))}${stat("bash", "Bash calls", num(h.calls))}${stat("recovery", "Recovery", `${pct(h.recovery_rate)} (${num(h.recovered)} of ${num(h.known)} known)`)}</dl>`);
  // mockup v9: Refusals per day and the four This week cards sit side by side.
  const perDay = `<figure class="card"><h3>Refusals per day <span class="tag">refused calls</span></h3>${sub("Refusals per UTC day; a gap is a day with no calls recorded.")}${chart(days.map((d) => ({ day: d.day, n: d.n })), (d) => d.n, max, String, "bar")}<details><summary>Exact values per day</summary>${table(["Day (UTC)", "Refused"], days.map((d) => `<tr data-guard-day="${d.day}">${td(esc(dayLabel(d.day)))}${td(num(d.n))}</tr>`))}</details></figure>`;
  const week = `<figure class="card">${cards}</figure>`;
  const eligible = h.eligible_by_tool && typeof h.eligible_by_tool === "object" ? h.eligible_by_tool : null, byTool = h.by_tool && typeof h.by_tool === "object" ? h.by_tool : {};
  const wiredName = (tool) => (/^(?:Skill|Agent):/.test(tool) ? tool.slice(0, tool.indexOf(":")) : tool);
  const toolNote = (tool) => (tool === UNKNOWN_TOOL ? "tool not recorded (legacy)" : eligible ? (Object.hasOwn(eligible, wiredName(tool)) ? "a tool this guard is wired to check" : "not a tool this guard is wired to check") : "");
  const toolRows = [...new Set([...Object.keys(byTool), ...(eligible ? Object.keys(eligible) : [])])].sort((a, b) => (byTool[b] || 0) - (byTool[a] || 0) || (a < b ? -1 : 1))
    .map((tool) => `<tr data-guard-tool="${esc(tool)}">${tdWrap(esc(tool))}${td(num(byTool[tool] || 0))}${tdWrap(esc(toolNote(tool)))}${td(eligible && Object.hasOwn(eligible, tool) ? num(eligible[tool]) : "—")}</tr>`);
  const split = box("guard-tools", "Refused by tool", "Which tool was refused? Calls are the eligible call attempts to that tool in the window; a refusal recorded before tools were named sits in the legacy bucket.", `${table(["Tool", "Refused", "Note", "Eligible call attempts"], toolRows, "No refusal recorded for this guard", "thtab")}${isNum(h.unattributed) && h.unattributed > 0 ? `<p class="sub">${h.unattributed} refusals name no tool row.</p>` : ""}`);
  return `<section class="box">${back(ui)}<h2>Guard drill-in: ${esc(h.class.replace(/^denied\//, ""))} <span class="tag">whole window</span></h2>${sub("On which days did this guard refuse calls, and which tool did it refuse, and why?")}</section>
<div class="th-charts">${perDay}${week}</div>
${counting}
${guardWhy(data, h, token)}
${split}
${box("evidence", "Evidence", "Sessions where it refused, opened in AG-UI.", evidence(h.sessions, h.tool_call_ids, token))}`;
}

// ---- station, map, hook wiring
const sortable = (id, head, rows, ui, wrap = []) => {
  const s = (ui.sorts || {})[id];
  const sorted = isNum(s && s.col) ? [...rows].sort((a, b) => { const x = a[s.col][0], y = b[s.col][0]; const c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y)); return s.desc ? -c : c; }) : rows;
  return table(head.map((h, i) => `<button class="th-sort" data-act="th-sort" data-table="${id}" data-col="${i}" aria-label="Sort by ${esc(h)}">${esc(h)}${s && s.col === i ? (s.desc ? " ▾" : " ▴") : ""}</button>`), sorted.map((r) => `<tr>${r.map((c, i) => (wrap.includes(i) ? tdWrap(c[1]) : td(c[1]))).join("")}</tr>`), "Nothing to show", "thtab");
};
const sv = (v) => [isNum(v) ? v : -1, num(v)];
const st_ = (v) => [String(v ?? ""), esc(v ?? "—")];
function invState(inv) {
  if (!inv) return '<p class="nodata">Loading the station scan…</p>';
  if (inv.state === "error" && !(inv.sources || []).length) return `<p class="nodata">Station scan could not load. <button class="btn" data-act="th-rescan">Retry</button></p>`;
  return "";
}
function stationTab(data, inv, ui) {
  const wait = invState(inv);
  if (wait) return box("station", "Station inventory", "What this station has. AG-UI reads these files and commands, then fills the map.", wait, "First build");
  const found = (s) => (s.state === "ok" && s.found ? Object.entries(s.found).map(([k, v]) => `${k.replace(/_/g, " ")} ${v}`).join(" · ") : s.state);
  const sources = (inv.sources || []).map((s) => [st_(SOURCE_NAME[s.id] || s.id), st_(s.reads), [s.state, esc(found(s))], st_(s.reason || "")]);
  const tools = data && data.tools || [];
  const servers = new Map((inv.tools || []).filter((t) => t.kind === "mcp").map((t) => [t.name, t]));
  for (const t of tools) if (/^mcp__/.test(t.tool)) { const s = t.tool.split("__")[1]; if (!servers.has(s)) servers.set(s, null); }
  const mcp = [...servers].map(([name, it]) => {
    const own = tools.filter((t) => t.tool.startsWith(`mcp__${name}__`)), calls = own.every((t) => isNum(t.calls)) ? own.reduce((n, t) => n + t.calls, 0) : null;
    return [st_(name), st_(it ? (it.configured_in || []).join(", ") || it.source : "source unknown"), st_(!it ? "—" : it.loads_in_chief ? "yes" : "no"), sv(own.length), sv(own.length ? calls : isNum(data && data.totalCalls) ? 0 : null)];
  });
  const heads = new Map((data && data.bash && data.bash.commands || []).map((c) => [c.head, c.calls]));
  const clis = (inv.clis || []).map((c) => [st_(c.name), st_(c.path || "absent"), st_(c.version || "—"), sv(heads.has(c.name) ? heads.get(c.name) : data && data.bash && data.bash.recorded ? 0 : null)]);
  const count = (kind) => (inv.tools || []).filter((t) => t.kind === kind).length;
  // mockup v9 tiles; a source that was not read shows — (a missing file is absent, never 0)
  const srcNum = (id, k) => { const s = (inv.sources || []).find((x) => x.id === id); return s && s.state === "ok" && s.found && isNum(s.found[k]) ? s.found[k] : null; };
  const hookSrc = (inv.sources || []).filter((s) => s.id.startsWith("hooks-") && s.state === "ok");
  const wirings = hookSrc.length ? hookSrc.reduce((n, s) => n + (isNum(s.found && s.found.wirings) ? s.found.wirings : 0), 0) + (srcNum("plugin-items", "hook_wirings") || 0) : null;
  const twice = hookSrc.length ? new Set((inv.hooks || []).filter((h) => h.runs_twice).map((h) => h.name)).size : null;
  const on = srcNum("plugins", "on"), installed = srcNum("plugins", "installed"), cliList = inv.clis || [];
  const tiles = `<div class="kpis">${[
    ["plugins", "Plugins", on === null || installed === null ? "—" : `${on} / ${installed}`, "on / installed", ""],
    ["skills", "Skills", num(count("skill")), "in the scan", ""],
    ["mcp", "MCP servers", num(servers.size), "configured or called", ""],
    ["wirings", "Hook wirings", num(wirings), wirings === null ? "not read" : `${new Set((inv.hooks || []).map((h) => h.name)).size} scripts`, ""],
    ["twice", "Runs twice", num(twice), "wired in two places", twice > 0 ? " warn" : ""],
    ["clis", "CLIs", `${cliList.filter((c) => c.state === "ok").length} / ${cliList.length}`, "on PATH", ""],
  ].map(([id, k, v, s, w]) => `<div class="kpi${w}" data-tile="${id}"><span class="k">${esc(k)}</span><b class="kv">${esc(v)}</b><span class="ks">${esc(s)}</span></div>`).join("")}</div>`;
  const at = esc(inv.scanned_at ? stamp(Date.parse(inv.scanned_at)) : "—");
  const scan = `<div class="filters"><span>Scanned at ${at}</span>${inv.stale ? ` <span class="pill warn">Rescan failed (${esc(inv.stale)}); showing the scan from ${at}</span>` : ""}<button class="btn" data-act="th-rescan">Rescan</button></div>`;
  return `${box("station", "Station inventory", "What this station has. AG-UI reads these files and commands, then fills the map. A source it cannot find reads absent, never 0.", scan + tiles, "read-only scan")}
${box("sources", "Where AG-UI reads each source", "Which file or command feeds each count? MCP servers are read as names only, never their arguments or environment.", sortable("sources", ["Source", "Reads at runtime", "Found", "Note"], sources, ui, [1, 2, 3]))}
${box("mcp", "MCP servers", "Which servers exist, and which load in a chief session?", sortable("mcp", ["Server", "Configured in", "Loads in chief", "Tools", "Calls"], mcp, ui, [1]))}
${box("clis", "Station CLIs", "Is every CLI the harness calls on PATH?", sortable("clis", ["CLI", "Path", "Version", "Bash calls"], clis, ui, [1]))}`;
}
// The mockup's Tool map: every kind plus an All column, an All sources row, sortable headers, a loaded-never-used mark and one card per source on a phone.
const outsideKind = (k) => k === "hook" || k === "cli";
function mapTab(data, inv, ui) {
  const wait = invState(inv);
  const rows = [...catalogue(data, inv), ...hookRows(data, inv), ...cliRows(data, inv)];
  const srcs = SRCS.filter((s) => rows.some((r) => r.src === s));
  const itemsOf = (s, k) => rows.filter((r) => (!s || r.src === s) && (k ? r.kind === k : !outsideKind(r.kind)));
  const sort = (ui.sorts || {}).map;
  const sortKey = (s) => (!sort || !isNum(sort.col) || sort.col === 0 ? SRC_LABEL[s] : itemsOf(s, sort.col === KINDS.length + 1 ? "" : KINDS[sort.col - 1]).length);
  const ordered = isNum(sort && sort.col) ? [...srcs].sort((a, b) => { const x = sortKey(a), y = sortKey(b); const c = typeof x === "number" && typeof y === "number" ? x - y || SRC_LABEL[a].localeCompare(SRC_LABEL[b]) : String(x).localeCompare(String(y)); return sort.desc ? -c : c; }) : srcs;
  const heads = ["Source", ...KINDS.map((k) => KIND_LABEL[k]), "All"];
  const head = heads.map((h, i) => `<span class="mh"><button class="th-sort" data-act="th-sort" data-table="map" data-col="${i}" aria-label="Sort sources by ${esc(h)}"${i === KINDS.indexOf("res") + 1 ? ` title="No scan source lists MCP resources, so this column stays empty."` : ""}>${esc(h)}${sort && sort.col === i ? (sort.desc ? " ▾" : " ▴") : ""}</button></span>`).join("");
  // One tile's facts, shared by the desktop grid cell and the phone card tile: count, calls line, failure-rate tint, loaded-never-used.
  // A sum is a number only when every part is one: an unread digest leaves a dash, never a zero. An empty list is `empty`.
  const sumOf = (list, f, empty = null) => (!list.length ? empty : list.every((x) => isNum(f(x))) ? list.reduce((n, x) => n + f(x), 0) : null);
  const tileInfo = (s, k) => {
    const items = itemsOf(s, k);
    if (!items.length) return null;
    const outside = outsideKind(k);
    const counts = items.map((r) => toolCounts(r, data));
    const calls = outside ? null : sumOf(counts, (c) => c.calls);
    const failed = outside ? (data ? items.reduce((n, r) => n + (isNum(r.refused) ? r.refused : 0), 0) : null) : sumOf(counts, (c) => c.failures);
    const rate = ratio(failed, calls);
    const tint = outside ? "" : !isNum(calls) || calls === 0 || !isNum(failed) ? " zero" : failed === 0 ? " good-t" : rate >= 0.1 ? " bad-t" : rate >= 0.05 ? " warn-t" : " ok-t";
    const runs = k === "hook" ? items.reduce((n, r) => (n === null || !isNum(r.runs) ? null : n + r.runs), 0) : null;
    const unused = items.filter((r, i) => (r.kind === "hook" ? r.runs === 0 : !outsideKind(r.kind) && counts[i].calls === 0)).length;
    const line = k === "hook" ? `${num(runs)} runs ${items.every((r) => r.runsMeasured) ? "measured" : items.some((r) => r.runsMeasured) ? "measured and derived" : "derived"} · ${num(failed)} refused` : k === "cli" ? "outside call total" : `${num(calls)} calls · ${num(failed)} failed${isNum(calls) && calls > 0 && calls < 10 ? " · few calls" : ""}`;
    const label = k ? `${items.length} ${KIND_LABEL[k]}` : `${items.length} ${items.length === 1 ? "tool" : "tools"}`;
    return { items, label, line, tint, unused };
  };
  const cell = (s, k, total) => {
    const info = tileInfo(s, k);
    if (!info) return `<span class="mc none" aria-hidden="true"></span>`;
    const { label, line, tint, unused } = info;
    const inner = `<b>${esc(label)}</b><span>${esc(line)}</span><span class="nu">${unused ? `○ ${unused}` : ""}</span>`;
    if (total) return `<span class="mc total${tint}">${inner}</span>`;
    const on = (ui.src || "") === s && (ui.kind || "") === k;
    return `<button class="mc${tint}${on ? " sel" : ""}" data-act="th-pick" data-src="${s}" data-kind="${k}" aria-pressed="${on}">${inner}</button>`;
  };
  const kindCols = [...KINDS, ""];
  const body = ordered.map((s) => `<span class="mr"><button data-act="th-pick" data-src="${s}" data-kind="">${esc(SRC_LABEL[s])}</button></span>${kindCols.map((k) => cell(s, k)).join("")}`).join("");
  const foot = `<span class="mr mall">All sources</span>${kindCols.map((k) => cell("", k, k === "")).join("")}`;
  const grid = `<div class="thmap" data-cols="${kindCols.length}">${head}${body}${foot}</div>`;
  const cards = `<div class="thcards">${ordered.map((s) => {
    const own = rows.filter((r) => r.src === s), counted = own.filter((r) => !outsideKind(r.kind)).map((r) => toolCounts(r, data));
    const none = isNum(data && data.totalCalls) ? 0 : null, calls = sumOf(counted, (c) => c.calls, none), rate = ratio(sumOf(counted, (c) => c.failures, none), calls);
    // mockup v9: each source card names its tools, calls and failure rate, then one tile per kind with the same calls line and tint as the desktop grid
    const summary = `${own.length} ${own.length === 1 ? "tool" : "tools"} · ${num(calls)} calls${isNum(rate) ? ` · ${pct(rate)}` : ""}`;
    const tiles = KINDS.map((k) => ({ k, info: tileInfo(s, k) })).filter((x) => x.info).map(({ k, info }) => {
      const on = (ui.src || "") === s && (ui.kind || "") === k;
      return `<button class="mln mc${info.tint}${on ? " sel" : ""}" data-act="th-pick" data-src="${s}" data-kind="${k}" aria-pressed="${on}"><span class="kl">${esc(KIND_LABEL[k])}</span><b>${info.items.length}</b><span>${esc(info.line)}</span><span class="nu">${info.unused ? `○ ${info.unused}` : ""}</span></button>`;
    }).join("");
    return `<div class="thcard"><button class="mcard" data-act="th-pick" data-src="${s}" data-kind="">${esc(SRC_LABEL[s])}</button><p class="sub">${esc(summary)}</p><div class="mlgrid">${tiles}</div></div>`;
  }).join("")}</div>`;
  const legend = `<div class="legend"><span class="tag fail">≥10%</span><span class="tag warn">5–10%</span><span class="tag">under 5%</span><span class="tag ok">0 failed</span><span class="tag">few calls: under 10</span><span class="tag">○ loaded, never used</span><span class="tag">outside call total: hooks, CLIs</span></div>`;
  const picked = ui.src || ui.kind ? box("map-list", `Tools: ${[ui.src && SRC_LABEL[ui.src], ui.kind && KIND_LABEL[ui.kind]].filter(Boolean).join(" · ")}`, "The tiles you picked; each name opens its drill-in.", toolList(data, inv, ui, { withOutside: true })) : "";
  return `${box("map", "Tool map", "Every kind and source at a glance; click a tile to filter the list below. Hook runs are measured where the hook chain logged them; any other hook's runs are derived from matchers × matching calls.", `${wait}<p class="sub"><span class="tag">hook runs: measured or derived, as each tile says</span></p>${legend}${grid}${cards}`, "First build")}${picked}`;
}
function hooksTab(data, inv, ui) {
  const wait = invState(inv);
  if (wait) return box("hooks", "Hook wiring", "Which hook is wired where, and which runs twice?", wait);
  const rows = hookRows(data, inv).map((r) => [[r.hook.name, `<a data-tool="${esc(r.key)}" href="${esc(r.guard ? toolHealthHref(ui, { guard: r.guard }) : toolHealthHref(ui, { tab: "map" }))}">${esc(r.hook.name)}</a>`], st_(r.source), [String(r.hook.wired.map((w) => w.join(":"))), esc((r.hook.wired || []).map(([e, m]) => `${e} · ${m}`).join(", ") || "—")], sv((r.hook.wired || []).length), [r.hook.runs_twice ? 1 : 0, r.hook.runs_twice ? '<span class="tag warn">×2 runs twice</span>' : "no"], [isNum(r.runs) ? r.runs : -1, `${num(r.runs)} <span class="dim">${r.runsMeasured ? "measured" : "derived"}</span>`], sv(r.refused)]);
  return box("hooks", "Hook wiring", `Which hook is wired where, and which runs twice? Runs are measured where the hook chain logged them, otherwise derived from matchers × matching calls.${hookRows(data, inv).some((r) => r.runsMeasured) ? ` ${RUNS_SCOPE}` : ""}`, sortable("hooks", ["Hook", "Source", "Wired on", "Wirings", "Runs twice", "Runs", "Refused"], rows, ui, [0, 2]), "First build");
}

const isoDay = (ts) => (typeof ts === "string" && /^\d{4}-\d{2}-\d{2}/.test(ts) ? ts.slice(0, 10) : "—");
const kOfN = (m) => (isNum(m.value) && isNum(m.k) ? `${m.k} of ${m.n} ${m.sample_unit}: ${pct(m.value)}` : `${num(m.n)} ${m.sample_unit}: —`);
const measure = (m) => `${esc(m.label)}${(m.limitations || []).length ? `<br><span class="dim">${esc(m.limitations.join("; "))}</span>` : ""}`;
const range = (m) => (m.interval && isNum(m.interval.lo) && isNum(m.interval.hi) ? `${pct(m.interval.lo)} to ${pct(m.interval.hi)}` : "—");
function codeReviewersView(r) {
  const c = r.codeReviewers;
  const out = [];
  const bad = (c.sources || []).filter((s) => s.state === "error");
  if (c.state === "partial") out.push(`<p><span class="pill warn">Partial: ${esc(bad.map((s) => `${s.id} could not be read (${s.reason})`).join("; "))}</span></p>`);
  out.push(sub(`Report of ${stamp(Date.parse(c.generated_at))}. Sources: ${(c.sources || []).map((s) => `${s.id} ${s.state === "ok" ? `read, ${s.records} records through ${isoDay(s.observed_through)}` : s.state === "absent" ? "absent" : `could not be read (${s.reason})`}`).join(" · ")}.`));
  const bench = c.metrics.filter((m) => m.family === "benchmark"), prod = c.metrics.filter((m) => m.family === "production");
  out.push("<h4>Planted-bug benchmark</h4>");
  const u = c.latest_usable, a = c.latest_attempt, f = (c.benchmark || {}).freshness;
  if (!u) out.push('<p class="nodata">No usable benchmark run</p>');
  else out.push(`<p>Observed ${esc(isoDay(u.at))} (${esc(u.run_id)}, ${esc(u.status)})${f && f.state === "old" ? ` <span class="pill warn">Old: observed ${esc(String(f.age_days))} days before this report</span>` : ""}</p>`);
  if (a && !a.usable) out.push(`<p><span class="pill warn">Latest attempt ${esc(isoDay(a.at))} (${esc(a.run_id)}): ${esc(a.status)}, not usable</span></p>`);
  const el = c.comparison_eligibility || { eligible: false, reasons: [] };
  if (u) out.push(sub(el.eligible ? "Earlier figures are from the previous comparable run." : `No trend: ${(el.reasons || []).join("; ")}`));
  if (bench.length) out.push(table(["Reviewer", "Measure", "Kind", "k of n", "Range", "Earlier"], bench.map((m) => `<tr>${td(esc(m.reviewer))}${tdWrap(measure(m))}${td(esc(m.kind))}${td(esc(kOfN(m)))}${td(esc(range(m)))}${td(m.trend && isNum(m.trend.previous_value) ? esc(`${pct(m.trend.previous_value)} at ${m.trend.previous_run_id}`) : "—")}</tr>`)));
  const p = c.production || {};
  out.push(`<h4>Review findings on merged work, ${esc(isoDay((p.window || {}).since))} to ${esc(isoDay((p.window || {}).until))}</h4>`);
  const measured = p.capture_coverage === "measured" || p.capture_coverage === "partial", cap = p.capture;
  if (!p.last_record_at) out.push(`<p class="nodata">No records${measured ? "" : "; capture coverage unknown"}</p>`);
  else if (!p.records_in_window) out.push(`<p>No new records since ${esc(isoDay(p.last_record_at))}${measured ? "" : "; capture coverage unknown"}.</p>`);
  else if (measured) out.push(`<p>Last record ${esc(isoDay(p.last_record_at))}.</p>`);
  else out.push(`<p>Last record ${esc(isoDay(p.last_record_at))}. Capture coverage unknown: ${esc(p.capture_reason || "no capture receipts")}.</p>`);
  if (cap) {
    const zero = (cap.captured_zero || []).length;
    const gaps = [["failed", cap.failed], ["not captured", cap.uncaptured]].filter(([, xs]) => xs && xs.length).map(([w, xs]) => `${w}: ${xs.map((x) => `#${x}`).join(", ")}`);
    const asOf = `, snapshot as of ${isoDay(cap.snapshot_as_of)}${p.capture_coverage === "partial" ? ", partial: PRs merged after it are not in it" : ""}`;
    const head = measured ? `${cap.n ? `Capture: ${cap.k} of ${cap.n} expected PRs captured (${zero} with zero threads)` : "Capture: no expected PR merged in the window"}${asOf}` : `Capture receipts: ${cap.receipts} PRs, ${zero} with zero threads; ${p.capture_reason || "no expected-PR snapshot"}, so no coverage`;
    const dropped = cap.snapshot_dropped ? [`${cap.snapshot_dropped} snapshot rows dropped (no PR number or merge time)`] : [];
    out.push(`<p>${esc([head, ...gaps, ...dropped].join("; "))}.</p>`);
  }
  if (p.roster && p.roster !== "ok") out.push(sub("The reviewer roster could not be read, so no slug counts as a reviewer."));
  if (p.not_reviewers && isNum(p.not_reviewers.findings) && p.not_reviewers.findings > 0) out.push(sub(`Counted out: ${p.not_reviewers.findings} findings from ${num(p.not_reviewers.slugs)} slugs that are not code reviewers.`));
  if (prod.length) out.push(table(["Reviewer", "Model", "Scope", "Verdict source", "Measure", "k of n", "Range"], prod.map((m) => `<tr>${td(esc(m.reviewer))}${td(esc(m.model || "—"))}${td(esc(m.cohort || "—"))}${td(esc(String(m.verdict_source || "").replace(/-/g, " ")))}${tdWrap(measure(m))}${td(esc(kOfN(m)))}${td(esc(range(m)))}</tr>`)));
  out.push("<h4>Reviewer changes</h4>");
  out.push(c.proposals && c.proposals.length ? `<ul>${c.proposals.map((x) => `<li>${esc(x.label)}</li>`).join("")}</ul>` : '<p class="nodata">No change yet</p>');
  return `${r.stale ? `<p><span class="pill warn">Refresh failed (${esc(r.stale)}); showing the report read earlier</span></p>` : ""}<div class="card" id="reviewers-report">${out.join("")}</div>`;
}
function reviewersTab(r) {
  const purpose = "Do our code reviewers catch planted bugs, and how do their findings on merged work fare? Read from the ledgers on each visit. Tool health filters do not apply.";
  let body;
  if (r === undefined || r === null) body = '<p class="nodata">Loading the review page…</p>';
  else if (r.codeReviewers && r.state === "absent") body = `<p class="nodata">No reviewer evidence yet</p>${sub("No benchmark run, reviewer change or review finding is recorded in the ledgers this station reads.")}`;
  else if (r.codeReviewers && r.state !== "error") body = codeReviewersView(r);
  else if (r.state === "absent") body = '<p class="nodata">No review page yet</p>';
  else if (r.state !== "ok") body = `<p class="nodata">Review page could not load${r.reason ? ` (${esc(r.reason)})` : ""}. <button class="btn" data-act="th-reviewers">Retry</button></p>`;
  else if (!String(r.text || "").trim()) body = `<p class="nodata">Review page is empty</p>${updated(r)}`;
  else {
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
    body = `${r.stale ? `<p><span class="pill warn">Refresh failed (${esc(r.stale)}); showing the page read earlier</span></p>` : ""}<p><span class="tag">Stored snapshot</span></p><div class="card" id="reviewers-page">${out.join("")}</div>${updated(r)}<p class="sub">As written by the weekly review job.</p>`;
  }
  return box("reviewers", "Reviewers", purpose, body);
}
const updated = (r) => { const t = Date.parse(r.writtenAt); return `<p class="sub">File updated ${Number.isFinite(t) ? esc(stamp(t)) : "—"}</p>`; };
