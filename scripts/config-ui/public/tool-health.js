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
const table = (head, rows, empty = "Nothing to show") => (rows.length ? `<div class="scroll"><table class="data"><thead><tr>${head.map((h) => `<th scope="col">${h}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>` : `<p class="nodata">${esc(empty)}</p>`);
const td = (v) => `<td>${v}</td>`;

export const TEAM_LABEL = { chief: "chief", "chief-relay": "chief relay", worker: "workers", judge: "judge", "release-manager": "release manager", critic: "critics", interactive: "interactive (you)", other: "other" };
const KIND_LABEL = { builtin: "built-in", mcp: "MCP", res: "MCP resource", skill: "skill", cmd: "command", agent: "subagent", wf: "workflow", hook: "hook", cli: "CLI" };
const KINDS = Object.keys(KIND_LABEL);
const SRC_LABEL = { core: "core", himmel: "himmel plugin", third: "third-party plugin", project: "project", user: "user", pkg: "MCP config", station: "station", unknown: "source unknown", before: "before the split" };
const SRCS = Object.keys(SRC_LABEL);
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
  return `<div class="kpis">${[
    tile("calls", "Calls", num(calls), data ? (isNum(calls) ? "tool call attempts" : "calls not recorded for every session") : "—"),
    tile("failed", "Failed", num(failed), data ? `${sum("errors")} errors · ${sum("denials")} denied` : "—"),
    tile("rate", "Failure rate", pct(rate), data ? (bad.size ? "Count check failed: rate hidden" : `${failed} of ${num(calls)} calls`) : "—"),
    tile("denied", "Denied", num(sum("denials")), data ? "refused attempts; a refusal can be correct" : "—"),
    tile("recovery", "Recovery", pct(ratio(recovered, known)), data ? `${recovered} of ${known} known · ${failed - known} unclassified` : "—"),
  ].join("")}</div>`;
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
function chart(rows, value, max, label, kind) {
  const w = 24, h = 64, top = max > 0 ? max : 1;
  const marks = rows.map((r, i) => {
    const v = value(r), x = i * w + 4;
    if (!isNum(v)) return `<text x="${x + 8}" y="${h - 2}" class="gap">·</text>`;
    const y = h - 12 - (v / top) * (h - 20);
    return kind === "bar" ? `<rect x="${x}" y="${y}" width="${w - 8}" height="${h - 12 - y}" class="fb"><title>${esc(r.day)}: ${esc(label(v))}</title></rect>` : `<circle cx="${x + 8}" cy="${y}" r="3" class="dot"><title>${esc(r.day)}: ${esc(label(v))}</title></circle>`;
  }).join("");
  let line = "", seg = [];
  rows.forEach((r, i) => { const v = value(r); if (isNum(v)) seg.push(`${i * w + 12},${h - 12 - (v / top) * (h - 20)}`); else { if (seg.length > 1) line += `<polyline points="${seg.join(" ")}" class="line"/>`; seg = []; } });
  if (kind !== "bar" && seg.length > 1) line += `<polyline points="${seg.join(" ")}" class="line"/>`;
  const marker = rows.map((r, i) => (r.shift ? `<rect x="${i * w}" y="0" width="${w}" height="${h - 10}" class="shiftband"><title>AFK shift</title></rect>` : "")).join("");
  return `<svg class="thchart" viewBox="0 0 ${rows.length * w} ${h}" preserveAspectRatio="none" role="img" aria-label="${esc(kind === "bar" ? "Failures per day; exact values in the table" : "Failure rate per day; gaps have no calls recorded")}">${marker}${marks}${line}</svg>`;
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
    return `<tr data-tool-row="${esc(r.key)}">${td(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(link)}">${esc(r.hook.name)}</a> ${chip}${r.hook.runs_twice ? ' <span class="tag warn">×2 runs twice</span>' : ""}`)}${td(esc(srcText))}${td(`${num(r.runs)} <span class="dim">runs ${r.runsMeasured ? "measured" : "derived"}</span>`)}${td(num(r.refused))}${td("—")}${td(num(r.refused))}${td("—")}${td("")}</tr>`;
  }
  if (r.kind === "cli") return `<tr data-tool-row="${esc(r.key)}">${td(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(toolHealthHref(ui, { tab: "station" }))}">${esc(r.cli.name)}</a> ${chip}`)}${td(esc(srcText))}${td(`${num(r.calls)} <span class="dim">Bash calls</span>`)}${td("—")}${td("—")}${td("—")}${td("—")}${td("")}</tr>`;
  const c = toolCounts(r, data), flagged = bad.has(r.key);
  const bar = isNum(c.failures) && max > 0 ? `<span class="thbar" data-w="${((c.failures / max) * 100).toFixed(1)}"></span>` : "";
  const rateCell = flagged ? '<span class="tag fail">Count check failed</span>' : `<span class="${c.rate >= 0.1 ? "bad-t" : c.rate >= 0.05 ? "warn-t" : ""}">${pct(c.rate)}</span>${isNum(c.calls) && c.calls > 0 && c.calls < 10 ? ' <span class="tag">few calls</span>' : ""}`;
  return `<tr data-tool-row="${esc(r.key)}">${td(`<a class="tl" data-tool="${esc(r.key)}" href="${esc(toolHealthHref(ui, { tool: r.key }))}">${esc(displayName(r))}</a> ${chip}`)}${td(esc(srcText))}${td(num(c.calls))}${td(num(c.failures))}${td(num(c.errors))}${td(num(c.denials))}${td(rateCell)}${td(bar)}</tr>`;
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
  return `${controls}${ui.before && data ? `<p class="sub">Before split: today's rows collapsed back to Skill, Agent and mcp, for comparison.</p>${beforeSplit(data)}` : `${shownLine}${table(["Tool", "Source", "Calls", "Failed", "Errors", "Denied", "Failure rate", ""], body, empty)}${more}`}`;
}

const isClassifier = (cls) => /^denied\/classifier(:|$)/.test(cls);
function guardsPanel(data, ui) {
  const rows = (data.hooks || []).filter((h) => !isClassifier(h.class)).sort((a, b) => b.failures - a.failures || (a.class < b.class ? -1 : 1));
  return table(["Guard", "Refused", "Rate", "Denominator", "Bash-only rate (legacy)", "Legacy denominator"], rows.map((h) => `<tr data-guard-row="${esc(h.class)}">${td(`<a data-guard="${esc(h.class)}" href="${esc(toolHealthHref(ui, { guard: h.class }))}">${esc(h.class.replace(/^denied\//, ""))}</a>`)}${td(num(h.failures))}${td(pct2(h.eligible_rate))}${td(eligibleWords(h))}${td(pct(h.rate))}${td(isNum(h.calls) ? `÷${h.calls} Bash calls (legacy)` : "÷ Bash calls not recorded (legacy)")}</tr>`), "No guard refused a call in this window");
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
function candidatesPanel(data) {
  const rows = (data.drop_candidates || []).map((d) => `<tr data-candidate="${esc(`${d.profile} ${d.tool}`)}">${td(esc(d.profile))}${td(esc(d.tool))}${td(`${num(d.calls)} calls`)}${td(`${num(d.listing_tokens)} tokens per listing`)}</tr>`);
  return table(["Profile", "Tool", "Calls in window", "Listing cost"], rows, "Nothing loaded and unused, or the listing cost is not measured");
}

function overview(data, st, ui) {
  const toolsBox = (text) => box("tools", "Tools", "Which tool, skill, hook or plugin fails most? Each name opens its drill-in.", `<p class="nodata">${esc(text)}</p>`, "First build");
  if (!data) return `${kpis(null)}${st.loading || st.error ? "" : toolsBox(st.data && st.data.state === "error" ? "Tool health could not load. Retry." : "No recorded tool observations in this window")}`;
  if (data.state !== "ok") return `${kpis(null)}${toolsBox("No recorded tool observations in this window. Try the 30-day window.")}`;
  const bad = badCounts(data);
  const banner = bad.size ? `<p class="nodata"><span class="tag fail">Count check failed</span> ${esc([...bad].join(", "))}: counts that cannot be true (more denials or errors than failures, or more failures than calls). Their rates are hidden, not clamped.</p>` : "";
  if (!(data.tools || []).length) return `${kpis(data)}<p class="nodata">No observations match these filters. <a class="btn" href="${esc(toolHealthHref({ filters: {} }))}">Reset filters</a></p>`;
  return `${banner}${kpis(data)}${dailyPanel(data, st)}
${box("tools", "Tools", "Which tool, skill, hook or plugin fails most? Each name opens its drill-in.", toolList(data, st.inventory, ui), "First build")}
<div class="th-cols">${box("guards", "Guards that refuse most", "Which guard blocks the most calls? The rate is over the calls to the tools each guard is wired to check; the Bash-only rate is the older denominator, kept for comparison. A refusal can be correct.", guardsPanel(data, ui), "÷ eligible call attempts")}${box("classifier", "Classifier denials", "Which calls did the auto-mode classifier deny? A count per category; the reason stays unverified.", classifierPanel(data), "reason unverified")}</div>
${box("lanes", "Bash on each lane", "Does Bash fail more on one lane?", lanePanel(data))}
${box("unused", "Loaded, never used", "Costs usage in every session; could load on demand. The cost is the estimated tokens per listing, not a measured gain.", candidatesPanel(data) + profilePanel(data))}`;
}

// ---- drill-ins
const back = (ui) => `<a class="btn quiet" href="${esc(toolHealthHref(ui))}">Back to overview</a>`;
const stat = (id, label, v) => `<div><dt>${esc(label)}</dt><dd data-stat="${id}">${esc(v)}</dd></div>`;

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
  events.map((e) => `<tr data-chain-event="${esc(e.call_id)}">${td(esc(utc(e.ts)))}${td(esc(OUTCOME_WORDS[e.outcome] || e.outcome))}${td(esc(reasonWords(e)))}${td(esc(e.member))}${td(esc(e.tool || "—"))}${td(esc(timingWords(e)))}${td(e.deny_line ? esc(e.deny_line) : "—")}${td(callDrawer(e, token))}</tr>`), empty);
const noteP = (text) => (text ? `<p class="sub">${esc(text)}</p>` : "");
function guardWhy(data, h, token) {
  if (isClassifier(h.class)) return "";
  const c = data.chain, suffix = h.class.replace(/^denied\//, ""), known = chainKnown(c);
  const name = Object.keys(c && c.members || {}).find((k) => k.replace(/\.(sh|js|mjs|py)$/, "") === suffix), m = name ? c.members[name] : null;
  const count = (k) => (m ? m.by_reason[k] : known && c.by_reason[k] !== null ? 0 : null);
  const rows = REASON_ROWS.map(([k, label, means]) => `<tr data-chain-reason="${k}">${td(esc(label))}${td(num(count(k)))}${td(esc(means))}</tr>`);
  const shown = m ? m.events : [], total = m ? m.denials + m.skips : 0;
  const more = m && shown.length < total ? `Showing the newest ${shown.length} of ${total}.` : "";
  const outside = known && !m ? "No hook-chain row names this guard; it may run outside the chain." : "";
  const body = `${noteP(chainNote(c))}${table(["Reason", "Refusals and skipped checks", "What it means"], rows)}${chainAudit(c)}${noteP(CHAIN_SCOPE)}${noteP(outside)}${known ? `${chainEvents(shown, token, "No refusal or skipped check recorded for this guard in the chain logs")}${noteP(more)}` : ""}`;
  return box("guard-why", "Why it refused", "Was it the rule, a timeout, or a guard that never started? One row per exact call, from the hook-chain logs.", body);
}
function toolChain(data, key, token) {
  const c = data && data.chain, tool = /^(Skill|Agent):/.test(key) ? null : key, known = chainKnown(c) && tool !== null;
  const mine = known ? (c.events || []).filter((e) => e.tool === tool) : [];
  const capped = known && isNum(c.events_total) && c.events_total > (c.events || []).length;
  const timeouts = known ? `${capped ? "at least " : ""}${mine.filter((e) => e.kind === "timeout").length}` : "—";
  const shown = mine.slice(0, 20);
  const notes = `${noteP(tool === null ? "The chain logs name the tool, not the skill or subagent, so its timeouts are unverified." : chainNote(c))}${chainAudit(c)}${noteP(CHAIN_SCOPE)}`;
  const none = capped ? `None of the newest ${c.events.length} events name this tool; ${c.events_total - c.events.length} older events are not shown` : "No guard refused or skipped a call to this tool in the chain logs";
  const events = known ? `${chainEvents(shown, token, none)}${noteP(shown.length < mine.length ? `Showing the newest ${shown.length} of ${capped ? "at least " : ""}${mine.length}.` : "")}` : "";
  return box("chain", "Timeouts and recent events", "How often did a guard time out on this tool, and what happened last? Guards that refused or skipped a call to it, from the hook-chain logs.", `<dl class="stats">${stat("timeouts", "Timeouts", timeouts)}</dl>${notes}${events}`);
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
${box("bash-cause", "Failures by cause", "Who broke the call: the command, the rtk hook, a himmel guard or the classifier? rtk filter failures need rtk to log the call id (later).", table(["Cause", "Failed"], Object.entries(causes).map(([k, l]) => `<tr data-cause="${k}">${td(esc(l))}${td(String(totals[k]))}</tr>`)))}
${box("bash-rtk", "rtk vs bash", "Does going through rtk fail more often? Whole fleet: not split by role, lane or profile.", rtkBody, "whole fleet")}`;
}
function toolDrill(data, inv, ui, token) {
  const r = catalogue(data, inv).find((x) => x.key === ui.tool);
  if (!r) return `<section class="box">${back(ui)}<h2>No matching tool</h2>${sub(`“${ui.tool}” is not in this window's response or the station scan.`)}</section>`;
  const head = `${back(ui)}<h2>Tool drill-in: ${esc(displayName(r))} <span class="tag">${esc(KIND_LABEL[r.kind])}</span> <span class="tag">${esc(SRC_LABEL[r.src])}${r.source && r.src !== "core" ? ` · ${esc(r.source)}` : ""}</span></h2>`;
  if (!r.t) return `<section class="box">${head}${sub("What happened to this tool in the window?")}<p class="nodata">No recorded calls in this window. The station scan lists it; calls ${isNum(data && data.totalCalls) ? "0" : "—"}.</p></section>${toolChain(data, r.key, token)}`;
  const t = r.t, bad = badCounts(data).has(t.tool);
  const stats = `<dl class="stats">${stat("calls", "Calls", num(t.calls))}${stat("failed", "Failed", num(t.failures))}${stat("errors", "Errors", num(t.errors))}${stat("denied", "Denied", num(t.denials))}${stat("rate", "Failure rate", bad ? "Count check failed" : pct(t.rate))}${stat("error-rate", "Error rate", bad ? "—" : pct(t.error_rate))}${stat("recovery", "Recovery", `${pct(t.recovery_rate)} (${num(t.recovered)} of ${num(t.known)} known)`)}</dl>`;
  const classes = table(["Class", "Count", "Share of this tool's calls"], (t.classes || []).map((c) => `<tr data-class="${esc(c.class)}">${td(esc(c.class))}${td(num(c.count))}${td(pct(ratio(c.count, t.calls)))}</tr>`), "No failure class recorded");
  return `<section class="box">${head}${sub("Was it this tool, or its callers? The same population as the overview row.")}${stats}</section>
${t.tool === "Bash" ? bashSections(data) : ""}
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
  const stats = `<dl class="stats">${stat("refused", "Refused", num(h.failures))}${stat("rate", "Rate ÷ eligible call attempts", pct2(h.eligible_rate))}${stat("eligible", "Eligible call attempts", num(h.eligible_calls))}${stat("legacy-rate", "Rate ÷ Bash calls (legacy)", pct(h.rate))}${stat("bash", "Bash calls", num(h.calls))}${stat("recovery", "Recovery", `${pct(h.recovery_rate)} (${num(h.recovered)} of ${num(h.known)} known)`)}</dl>`;
  const eligible = h.eligible_by_tool && typeof h.eligible_by_tool === "object" ? h.eligible_by_tool : null, byTool = h.by_tool && typeof h.by_tool === "object" ? h.by_tool : {};
  const wiredName = (tool) => (/^(?:Skill|Agent):/.test(tool) ? tool.slice(0, tool.indexOf(":")) : tool);
  const toolNote = (tool) => (tool === UNKNOWN_TOOL ? "tool not recorded (legacy)" : eligible ? (Object.hasOwn(eligible, wiredName(tool)) ? "a tool this guard is wired to check" : "not a tool this guard is wired to check") : "");
  const toolRows = [...new Set([...Object.keys(byTool), ...(eligible ? Object.keys(eligible) : [])])].sort((a, b) => (byTool[b] || 0) - (byTool[a] || 0) || (a < b ? -1 : 1))
    .map((tool) => `<tr data-guard-tool="${esc(tool)}">${td(esc(tool))}${td(num(byTool[tool] || 0))}${td(esc(toolNote(tool)))}${td(eligible && Object.hasOwn(eligible, tool) ? num(eligible[tool]) : "—")}</tr>`);
  const split = box("guard-tools", "Refused by tool", "Which tool was refused? Calls are the eligible call attempts to that tool in the window; a refusal recorded before tools were named sits in the legacy bucket.", `${table(["Tool", "Refused", "Note", "Eligible call attempts"], toolRows, "No refusal recorded for this guard")}${isNum(h.unattributed) && h.unattributed > 0 ? `<p class="sub">${h.unattributed} refusals name no tool row.</p>` : ""}`);
  return `<section class="box">${back(ui)}<h2>Guard drill-in: ${esc(h.class.replace(/^denied\//, ""))} <span class="tag">whole window</span></h2>${sub("On which days did this guard refuse calls, and which tool did it refuse, and why?")}${stats}</section>
${guardWhy(data, h, token)}
${split}
${box("guard-days", "Refusals per day", "Refusals per UTC day; a gap is a day with no calls recorded.", `${chart(days.map((d) => ({ day: d.day, n: d.n })), (d) => d.n, max, String, "bar")}${table(["Day (UTC)", "Refused"], days.map((d) => `<tr data-guard-day="${d.day}">${td(esc(dayLabel(d.day)))}${td(num(d.n))}</tr>`))}`)}
${box("evidence", "Evidence", "Sessions where it refused, opened in AG-UI.", evidence(h.sessions, h.tool_call_ids, token))}`;
}

// ---- station, map, hook wiring
const sortable = (id, head, rows, ui) => {
  const s = (ui.sorts || {})[id];
  const sorted = isNum(s && s.col) ? [...rows].sort((a, b) => { const x = a[s.col][0], y = b[s.col][0]; const c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y)); return s.desc ? -c : c; }) : rows;
  return table(head.map((h, i) => `<button class="th-sort" data-act="th-sort" data-table="${id}" data-col="${i}" aria-label="Sort by ${esc(h)}">${esc(h)}${s && s.col === i ? (s.desc ? " ▾" : " ▴") : ""}</button>`), sorted.map((r) => `<tr>${r.map((c) => td(c[1])).join("")}</tr>`));
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
  const sources = (inv.sources || []).map((s) => [st_(s.id), st_(s.reads), [s.state, esc(found(s))], st_(s.reason || "")]);
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
  const tiles = `<div class="kpis">${[["Skills", count("skill")], ["Commands", count("cmd")], ["Subagents", count("agent")], ["Workflows", count("wf")], ["MCP servers", servers.size], ["Hooks", (inv.hooks || []).length], ["CLIs on PATH", (inv.clis || []).filter((c) => c.state === "ok").length]].map(([k, v]) => `<div class="kpi"><span class="k">${esc(k)}</span><b class="kv">${num(v)}</b></div>`).join("")}</div>`;
  const at = esc(inv.scanned_at ? stamp(Date.parse(inv.scanned_at)) : "—");
  const scan = `<div class="filters"><span>Scanned at ${at}</span>${inv.stale ? ` <span class="pill warn">Rescan failed (${esc(inv.stale)}); showing the scan from ${at}</span>` : ""}<button class="btn" data-act="th-rescan">Rescan</button></div>`;
  return `${box("station", "Station inventory", "What this station has. AG-UI reads these files and commands, then fills the map. A source it cannot find reads absent, never 0.", scan + tiles, "read-only scan")}
${box("sources", "Where AG-UI reads each source", "Which file or command feeds each count? MCP servers are read as names only, never their arguments or environment.", sortable("sources", ["Source", "Reads at runtime", "Found", "Note"], sources, ui))}
${box("mcp", "MCP servers", "Which servers exist, and which load in a chief session?", sortable("mcp", ["Server", "Configured in", "Loads in chief", "Tools", "Calls"], mcp, ui))}
${box("clis", "Station CLIs", "Is every CLI the harness calls on PATH?", sortable("clis", ["CLI", "Path", "Version", "Bash calls"], clis, ui))}`;
}
function mapTab(data, inv, ui) {
  const wait = invState(inv);
  const rows = [...catalogue(data, inv), ...hookRows(data, inv), ...cliRows(data, inv)];
  const srcs = SRCS.filter((s) => rows.some((r) => r.src === s)), kinds = KINDS.filter((k) => rows.some((r) => r.kind === k));
  const cell = (s, k) => {
    const items = rows.filter((r) => r.src === s && r.kind === k);
    if (!items.length) return `<span class="mc none" aria-hidden="true"></span>`;
    const outside = k === "hook" || k === "cli";
    const calls = outside ? null : items.reduce((n, r) => (n === null || !isNum(toolCounts(r, data).calls) ? null : n + toolCounts(r, data).calls), 0);
    const failed = outside ? items.reduce((n, r) => n + (isNum(r.refused) ? r.refused : 0), 0) : items.reduce((n, r) => n + (isNum(toolCounts(r, data).failures) ? toolCounts(r, data).failures : 0), 0);
    const rate = ratio(failed, calls);
    const tint = outside ? "" : !isNum(calls) || calls === 0 ? " zero" : failed === 0 ? " ok-t" : rate >= 0.1 ? " bad-t" : rate >= 0.05 ? " warn-t" : " ok-t";
    const runs = k === "hook" ? items.reduce((n, r) => (n === null || !isNum(r.runs) ? null : n + r.runs), 0) : null;
    const line = k === "hook" ? `${num(runs)} runs ${items.every((r) => r.runsMeasured) ? "measured" : items.some((r) => r.runsMeasured) ? "measured and derived" : "derived"} · ${failed} refused` : k === "cli" ? "outside call total" : `${num(calls)} calls · ${failed} failed${isNum(calls) && calls > 0 && calls < 10 ? " · few calls" : ""}`;
    return `<button class="mc${tint}${ui.src === s && ui.kind === k ? " sel" : ""}" data-act="th-pick" data-src="${s}" data-kind="${k}" aria-pressed="${ui.src === s && ui.kind === k}"><b>${items.length} ${esc(KIND_LABEL[k])}</b><span>${esc(line)}</span></button>`;
  };
  const grid = `<div class="thmap" data-cols="${kinds.length}"><span class="mh"></span>${kinds.map((k) => `<span class="mh">${esc(KIND_LABEL[k])}</span>`).join("")}${srcs.map((s) => `<span class="mr">${esc(SRC_LABEL[s])}</span>${kinds.map((k) => cell(s, k)).join("")}`).join("")}</div>`;
  const legend = `<div class="legend"><span class="tag fail">≥10%</span><span class="tag warn">5–10%</span><span class="tag ok">under 5%</span><span class="tag">0 failed</span><span class="tag">few calls: under 10</span><span class="tag">outside call total: hooks, CLIs</span></div>`;
  const picked = ui.src || ui.kind ? box("map-list", `Tools: ${[ui.src && SRC_LABEL[ui.src], ui.kind && KIND_LABEL[ui.kind]].filter(Boolean).join(" · ")}`, "The tiles you picked; each name opens its drill-in.", toolList(data, inv, ui, { withOutside: true })) : "";
  return `${box("map", "Tool map", "Every kind and source at a glance; click a tile to filter the list below. Hook runs are measured where the hook chain logged them; any other hook's runs are derived from matchers × matching calls.", `${wait}<p class="sub"><span class="tag">hook runs: measured or derived, as each tile says</span></p>${legend}${grid}`, "First build")}${picked}`;
}
function hooksTab(data, inv, ui) {
  const wait = invState(inv);
  if (wait) return box("hooks", "Hook wiring", "Which hook is wired where, and which runs twice?", wait);
  const rows = hookRows(data, inv).map((r) => [[r.hook.name, `<a data-tool="${esc(r.key)}" href="${esc(r.guard ? toolHealthHref(ui, { guard: r.guard }) : toolHealthHref(ui, { tab: "map" }))}">${esc(r.hook.name)}</a>`], st_(r.source), [String(r.hook.wired.map((w) => w.join(":"))), esc((r.hook.wired || []).map(([e, m]) => `${e} · ${m}`).join(", ") || "—")], sv((r.hook.wired || []).length), [r.hook.runs_twice ? 1 : 0, r.hook.runs_twice ? '<span class="tag warn">×2 runs twice</span>' : "no"], [isNum(r.runs) ? r.runs : -1, `${num(r.runs)} <span class="dim">${r.runsMeasured ? "measured" : "derived"}</span>`], sv(r.refused)]);
  return box("hooks", "Hook wiring", `Which hook is wired where, and which runs twice? Runs are measured where the hook chain logged them, otherwise derived from matchers × matching calls.${hookRows(data, inv).some((r) => r.runsMeasured) ? ` ${RUNS_SCOPE}` : ""}`, sortable("hooks", ["Hook", "Source", "Wired on", "Wirings", "Runs twice", "Runs", "Refused"], rows, ui), "First build");
}

// ---- reviewers (moved from Health): the weekly review page as written, never re-graded here.
function reviewersTab(r) {
  const purpose = "Do our code reviewers catch planted bugs? This is the “How good are our reviewers?” panel moved from Health. Tool health filters do not apply.";
  let body;
  if (r === undefined || r === null) body = '<p class="nodata">Loading the review page…</p>';
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
    body = `${r.stale ? `<p><span class="pill warn">Refresh failed (${esc(r.stale)}); showing the page read earlier</span></p>` : ""}<div class="card" id="reviewers-page">${out.join("")}</div>${updated(r)}<p class="sub">As written by the weekly review job.</p>`;
  }
  return box("reviewers", "Reviewers", purpose, body);
}
const updated = (r) => { const t = Date.parse(r.writtenAt); return `<p class="sub">File updated ${Number.isFinite(t) ? esc(stamp(t)) : "—"}</p>`; };
