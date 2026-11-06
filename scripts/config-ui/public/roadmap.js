// the Roadmap page. Pure rendering, no DOM: renderRoadmap(data, ui) → HTML.
// data = GET /api/roadmap (null while loading); ui = { version, theme }, indices into data.versions / data.themes (the Sectors) or null.
// Everything shown is the server's live read. With ui.writes the Kanban cards are draggable and carry a Sector
// select, and app.js posts the drop or the select to /api/roadmap/write. The rest of the page proposes only.
import { esc, pageHeader, pg } from "./render.js";

const COLS = [["todo", "To do"], ["prog", "In progress"], ["rev", "In review"], ["ci", "CI"], ["done", "Done"], ["wont", "Won't"]];
// The Board's columns: Review and CI share one (a drop on it sets rev; CI is the pill on the card), and Won't is the narrow lane after them.
const BOARD_COLS = [["todo", "To do", ["todo"]], ["prog", "In progress", ["prog"]], ["rev", "Review / CI", ["rev", "ci"]], ["done", "Done", ["done"]], ["wont", "Won't", ["wont"]]];
// A clamped text keeps its full text in data-tip, shown by the CSS bubble on hover and focus. The clamp lives on the inner .rm-clip
// (overflow:hidden would cut the bubble off the same element); the full text is also what a screen reader gets, so no native title repeats it.
const tip = (full, inner, cls = "") => `<span class="rm-tip${cls}" data-tip="${esc(full)}"><span class="rm-clip">${inner}</span></span>`;
const section = (id, title, sub, body) => `<section id="${id}" class="box" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;
const shq = (a) => (/^[\w.,:@/=-]+$/.test(a) ? a : `"${a.replace(/(["\\$`])/g, "\\$1")}"`); // a word safe to paste: $, backtick, quote and backslash escaped
const jira = (argv) => "jira " + argv.map(shq).join(" ");

// A version's running state: with several projects each runs its own (the server marks it on the version); with one it is the page's cur and next.
const runState = (d, v, i) => (d.projects && d.projects.length > 1 ? v.run || "" : i === d.cur ? "running" : i === d.next ? "next" : "");

function releasesHtml(d) {
  if (!d.versions.length) return `<div class="empty">No train versions.</div>`;
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  return note + d.versions.map((v, i) => {
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0);
    const run = runState(d, v, i);
    const tag = v.rel ? `released${v.date ? " " + v.date : ""}` : run || "planned";
    const alert =v.open.length ? `<div class="alert"><span class="st pill fail">open</span> ${v.open.length} still open on a released version: ${v.open.map((k) => `${v.project || "HIMMEL"}-${k}`).map(esc).join(", ")}</div>` : "";
    return `<div class="card rm-rel${run === "running" ? " cur" : ""}"><h3><a href="#/roadmap/${encodeURIComponent(v.n)}">${esc(v.n)}</a> <span class="ro pill${v.rel ? " ok" : run === "running" ? " warn" : ""}">${esc(tag)}</span></h3>
      <div class="kv">${COLS.map(([b, l]) => `${esc(l)} ${c[b]}`).join(" · ")} · ${total} total</div>${alert}</div>`;
  }).join("");
}

function filters(d, ui) {
  const sel = (name, label, items, cur) => `<label>${label} <select data-rm-filter="${name}"><option value="">all</option>${items.map((x, i) =>
    `<option value="${i}"${cur === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
  return `<div class="rm-filters">${sel("version", "Version", d.versions.map((v) => v.n), ui.version)} ${sel("theme", "Sector", d.themes, ui.theme)}</div>`;
}

// one select per card; the option value is the Sector name, which the Jira CLI checks against the live option list. The
// "no sector" bucket is not a Sector (neither the CLI nor the tracker seam can clear one), so it is shown but disabled unless
// it is the card's group. A local card may also name a new Sector: app.js asks for it when "new sector…" is picked.
const NO_SECTOR = "(no sector)";
const idOf = (t) => t.id || "HIMMEL-" + t.k;
// The Sector options a card offers. Each Jira project has its own option list, so with several projects a card offers only the
// Sectors its own project's tickets use (and the no-sector placeholder), never another project's; with one project, every Sector.
const sectorsOf = (d, t) => {
  const own = d.projectThemes && t.project ? d.projectThemes[t.project] : null; // the server's read over every ticket of the project, with a version or not
  return own ? { has: (i) => own.includes(i) || d.themes[i] === NO_SECTOR } : { has: () => true };
};
const projAttr =(t) => (t.project ? ` data-rm-project="${esc(t.project)}"` : ""); // with the number it names a card: two projects share numbers
const sectorPick = (t, d) => `<select class="rm-theme" data-rm-theme-key="${t.k}"${projAttr(t)} aria-label="Sector of ${esc(idOf(t))}">${d.themes.map((x, i) => [x, i]).filter(([, i]) => sectorsOf(d, t).has(i)).map(([x, i]) =>
  `<option value="${x === NO_SECTOR ? "" : esc(x)}"${t.theme === i ? " selected" : x === NO_SECTOR ? " disabled" : ""}>${esc(x)}</option>`).join("")}${
  t.backend === "local" ? `<option value="" data-rm-new>new sector…</option>` : ""}</select>`;

// The chain read (GET /api/board, chain-state.mjs): usable only when it carries chains; anything else is the absent notice.
const chainOk = (ch) => !!(ch && Array.isArray(ch.chains) && ch.tickets);
const GLYPH = { done: "✓", "in flight": "●", "can launch": "▷", blocked: "⛔", "waits on you": "?", "date-gated": "⏲" };
const glyph = (s) => GLYPH[s] || (/^waits on step/.test(s) ? "…" : /^done/.test(s) ? "✓" : "");
// A chain badge under the card title: chain id, the ticket's step of the chain's steps, and its state as a glyph and a word,
// so it reads without colour (at most two badges, then +N). A ticket in no chain, or no chain read at all, has none.
function chainBadge(t, ch, v) {
  const ct = chainOk(ch) ? ch.tickets[idOf(t)] : null;
  if (!ct || !Array.isArray(ct.badges) || !ct.badges.length) return "";
  const at = encodeURIComponent(idOf(t));
  const parts = ct.badges.map((id) => ct.chains.find((c) => c.id === id)).filter(Boolean).map((c) => {
    const text = `${glyph(c.state)} ${c.id} ${c.step}/${c.steps} · ${c.state}`.trim();
    return `<a class="rm-chain" href="#/board?tab=chains${v ? `&amp;v=${esc(encodeURIComponent(v))}` : ""}&amp;at=${esc(at)}" aria-label="Open the ${esc(c.id)} chain on the Chains tab: ${esc(text)}">${tip(text, `<span aria-hidden="true">${glyph(c.state)}</span> ${esc(c.id)} ${esc(String(c.step))}/${esc(String(c.steps))} · ${esc(c.state)}`)}</a>`;
  });
  return `<div class="rm-chains">${parts.join("")}${ct.more ? ` <span class="ro">+${esc(String(ct.more))}</span>` : ""}</div>`;
}

function cardHtml(t, d, showVersion, w, ch, v, known) {
  const kb = known && known.get(idOf(t)) ? `<span class="rm-kb" title="The drift row on this ticket is the checker's fault: listed, not counted."><span aria-hidden="true">≠</span> checker bug ${esc(known.get(idOf(t)))}</span>` : "";
  const lg = t.worker ? `<div class="rm-worker"><b>${esc(t.worker.label)} ${esc(t.worker.marker)}</b>${t.worker.reason ? " " + esc(t.worker.reason) : ""}</div>` : "";
  const dr = t.drift === 1 ? `<span class="st pill warn">drift</span> plan: ${esc(t.pv)}` : t.drift === 2 ? `<span class="st pill warn">unplanned</span>` : "";
  const ver = showVersion && t.v >= 0 ? `<a class="ro" href="#/roadmap/${encodeURIComponent(d.versions[t.v].n)}">${esc(d.versions[t.v].n)}</a> ` : "";
  const theme = w ? sectorPick(t, d) : esc(d.themes[t.theme]);
  const local = t.backend === "local";
  const attrs = w ? ` draggable="true" data-rm-card="${t.k}"${projAttr(t)}${local ? ` data-rm-id="${esc(t.id)}" data-rm-backend="local"` : ""}` : "";
  const open = ` data-rm-open="${t.k}"${w ? "" : projAttr(t)} tabindex="0"`; // a click, Enter or Space opens the drawer; the project attribute is shared with the drag one
  const ci = t.b === "ci" ? ` <span class="ro pill warn">CI</span>` : ""; // CI shares the Review column: the pill says which of the two the card is in
  // two lines: the id, status and sector row, then the title clamped to two lines; the card's accessible name is the id and the full title
  return `<div class="rm-card"${attrs}${open} role="button" aria-label="${esc(idOf(t))}: ${esc(t.t)}"><div class="rm-top"><b>${esc(idOf(t))}</b>${local ? ` <span class="ro pill">local</span>` : ""} <span class="ro pill${t.b === "done" ? " ok" : t.b === "prog" || t.b === "rev" || t.b === "ci" ? " warn" : ""}">${esc(t.s)}</span>${ci} <span class="ro">${ver}${theme} ${dr}</span></div>`
    + `<div class="rm-tip rm-title" data-tip="${esc(t.t)}"><span class="rm-clip">${esc(t.t)}</span></div>${chainBadge(t, ch, v)}${kb}${lg}</div>`;
}

// One board: a column per status over the given tickets (Review and CI share one). Won't stays hidden while empty so a quiet board stays short.
// With w every column is a drop target, Won't included: a writable board must be able to receive it.
// o (the Board's lanes only): scope = every ticket Jira has for these columns before the filters, so each column says "Jira N matches"
// or "Jira N · M shown"; foldDone = Done is a closed <details> (open while o.find is set, so a find never hides its match).
function boardHtml(d, tickets, showVersion, w, ch, v, o = {}) {
  const cols = BOARD_COLS.filter(([b, , bs]) => w || b !== "wont" || tickets.some((t) => bs.includes(t.b)));
  return `<div class="rm-board">${cols.map(([b, l, bs]) => {
    const cards = tickets.filter((t) => bs.includes(t.b)), n = cards.length;
    const jn = o.scope ? o.scope.filter((t) => bs.includes(t.b)).length : null;
    const jira = jn === null ? "" : `<span class="ro rm-jira">${jn === n ? `Jira ${jn} matches` : `Jira ${jn} · ${n} shown`}</span>`;
    const body = cards.map((t) => cardHtml(t, d, showVersion, w, ch, v, o.known)).join(""), drop = w ? ` data-rm-drop="${b}"` : "";
    const drawerHere = o.drawer && cards.some((t) => t.k === o.drawer.k && (t.project || "") === (o.drawer.project || "")); // closing the drawer focuses its card: it must not sit in a closed <details>
    if (o.foldDone && b === "done") return `<details class="rm-col rm-done"${o.find || drawerHere ? " open" : ""}${drop} data-rm-col="done"><summary><b>${esc(l)}</b> <span class="ro rm-n">${n}</span> ${jira}</summary>${body}</details>`;
    return `<div class="rm-col${b === "wont" ? " rm-lane" : ""}"${drop}${o.scope ? ` data-rm-col="${b}"` : ""}><h4>${tip(l, esc(l))} <span class="ro rm-n">${n}</span> ${jira}</h4>${body}</div>`;
  }).join("")}</div>`;
}

const themeSel = (d, ui) => `<label>Sector <select data-rm-filter="theme"><option value="">all</option>${d.themes.map((x, i) =>
  `<option value="${i}"${ui.theme === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
// A refused or failed write: shown above the board, the card has already moved back (the board is redrawn from the server).
const writeNote = (ui) => (ui.writeError ? `<div class="alert" role="alert"><span class="st pill fail">refused</span> ${esc(ui.writeError)}</div>` : "")
  + (ui.held ? `<div class="alert" role="status"><span class="st pill warn">held</span> ${esc(ui.held)}</div>` : ""); // a drop on a column its event moves: nothing was written
const byTheme = (d, ui) => d.tickets.filter((t) => ui.theme == null || t.theme === ui.theme);

// #/roadmap/<version>, one version's board.
function versionHtml(d, ui) {
  const back = pageHeader(ui.ver, "Tickets by status and sector.") + `<p><a href="#/roadmap">← Roadmap</a></p>`;
  const v = d.versions.findIndex((x) => x.n === ui.ver);
  if (v < 0) return back + `<div class="empty">${esc(ui.ver)}: no such version in the mirror.</div>`;
  const shown = byTheme(d, ui).filter((t) => t.v === v);
  const head = `<div class="rm-bar fields">${themeSel(d, ui)}<button class="btn" data-act="refresh-roadmap">refresh</button></div>${writeNote(ui)}`;
  return back + section("rm-version", d.versions[v].n, `${shown.length} tickets in this version; the worker marker shows on the card.`,
    head + (shown.length ? boardHtml(d, shown, false, ui.writes) : `<div class="empty">No tickets match.</div>`));
}

// TRACKER=none: say so, so the page is never mistaken for an empty board.
const noTrackerHtml = () => `<div class="nodata">No tracker is configured (TRACKER=none), so there are no tickets to show: this is not an empty board.
  Set TRACKER=local (tickets in a local store, no Jira) or TRACKER=jira in himmel.conf to track work here.</div>`;

// #/kanban, every version on one board with no version filter. Done can be hidden.
export const renderKanban = (data, ui) => pg(kanbanHtml(data, ui));
function kanbanHtml(data, ui) {
  const page = pageHeader("Kanban", "Tickets across versions, grouped by status.");
  if (!data) return page + `<p class="sub" id="status">loading…</p>`;
  if (data.source === "none") return page + noTrackerHtml();
  if (data.state !== "ok") return page + `<div class="nodata">${esc(data.reason || "kanban unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  const u = { ...ui, writes: ui && ui.writes && data.source !== "github" };
  const shown = byTheme(data, u).filter((t) => !(u.hideDone && t.b === "done"));
  const head = `<div class="rm-bar fields">${themeSel(data, u)}<label><input type="checkbox" data-rm-hide-done${u.hideDone ? " checked" : ""}> Hide Done</label>`
    + `<button class="btn" data-act="refresh-roadmap">refresh</button></div>${writeNote(u)}`;
  const gh = data.source === "github";
  return page + section("rm-kanban", "Kanban", gh ? `Every issue across milestones (${shown.length} shown). GitHub issues are read-only here: change them on GitHub.${data.truncated ? " Only the newest 1000 issues are read, so older ones are missing." : ""}`
    : data.source === "local" ? `Every local tracker item across versions (${shown.length} shown).${u.writes ? " Drag a card to another column to change its status in the local store." : ""}`
      : `Every train ticket across versions (${shown.length} shown).${u.writes ? " Drag a card to another column to change its Jira status." : ""}`,
    head + (shown.length ? boardHtml(data, shown, true, u.writes) : `<div class="empty">No tickets match.</div>`));
}

function driftHtml(d) {
  const n = d.drift.now;
  const trend = d.drift.trend.length ? `<div class="ro">trend (drift/unplanned/no sector, oldest first): ${d.drift.trend.map((r) => `${r[1]}/${r[2]}/${r[3]}`).map(esc).join(" → ")}</div>`
    : `<div class="nodata">no drift log rows</div>`;
  const plan = d.plan.state === "ok" ? "" : `<div class="nodata">plan absent: ${esc(d.plan.reason || "no plan dir")}; drift is not computed</div>`;
  return `<div class="kv">drift ${n.drift} · unplanned ${n.unplanned} · no sector ${n.unthemed}</div>${plan}${trend}`;
}

// The version/theme filter narrows the sync and librarian lists too: a filtered-out ticket renders nowhere.
const shownKs = (d, ui) => new Set(d.tickets.filter((t) => (ui.version == null || t.v === ui.version) && (ui.theme == null || t.theme === ui.theme)).map(idOf)); // by shown id: two projects share ticket numbers
const opId = (o) => o.id || "HIMMEL-" + o.k;

function syncHtml(d, ui) {
  const keep = shownKs(d, ui);
  const ops = (d.sync || []).filter((o) => keep.has(opId(o)));
  const body = ops.length ? ops.map((o) => `<tr><td>${esc(opId(o))}</td><td>${esc(o.marker)}</td><td>${esc(o.why)}</td>
      <td><code>${esc(jira(o.argv))}</code> <button class="btn" data-act="copy" data-cmd="${esc(jira(o.argv))}">copy</button></td></tr>`).join("")
    : `<tr><td colspan="4" class="empty">Jira already matches the workers.</td></tr>`;
  return `<p class="ro">Planned only: the console kit is the one writer, via the Jira CLI. Workers never write Jira and this page never does.</p>
    <div class="scroll"><table class="rm-sync data"><thead><tr><th>Ticket</th><th>Worker</th><th>Why</th><th>Command</th></tr></thead><tbody>${body}</tbody></table></div>`;
}

function librarianHtml(d, ui) {
  const l = d.librarian, keep = shownKs(d, ui);
  const ids = new Map(d.tickets.map((t) => [t.k, idOf(t)]));
  const id = (k) => ids.get(k) || "HIMMEL-" + k;
  const pids = (p) => p.ids || (p.keys ? p.keys.map(id) : [p.id || id(p.k)]); // the ids a proposal names: a project's number alone is ambiguous
  const list = (title, all) => { const items = all.filter((p) => pids(p).some((x) => keep.has(x))); return `<div class="card"><h3>${esc(title)} <span class="ro">${items.length}</span></h3>${items.length ? items.map((p) =>
    `<div class="hrow"><span class="id">${pids(p).map(esc).join(" = ")}</span><span class="det">${esc(p.title)}</span><span>${esc(p.proposal)}</span></div>`).join("")
    : `<div class="empty">Nothing to propose.</div>`}</div>`; };
  return `<p class="ro">Proposals only: needs operator approval (or a recorded standing rule) before any fixVersion move or close.</p>`
    + list("Stale In Progress", l.staleInProgress) + list("Version drift", l.drift) + list("No sector", l.unthemed)
    + list("Released but open", l.releasedOpen) + list("Duplicate titles", l.duplicates);
}

export const renderRoadmap = (data, ui) => pg(roadmapHtml(data, ui));
function roadmapHtml(data, ui) {
  const page = pageHeader("Roadmap", "Versions, drift and worker proposals.");
  if (!data) return page + `<p class="sub" id="status">loading…</p>`;
  if (data.source === "none") return page + noTrackerHtml();
  if (data.state !== "ok") return page + `<div class="nodata">${esc(data.reason || "roadmap unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  const gh = data.source === "github";
  const u = { ...ui, writes: ui && ui.writes && !gh };
  if (u.ver) return versionHtml(data, u);
  const bar = `<div class="rm-bar fields">${filters(data, u)}<button class="btn" data-act="refresh-roadmap">refresh</button></div>`;
  if (gh) {
    return page + section("rm-releases", "Milestones", `Live from GitHub issues (${data.mirror.count} issues). Read-only: change them on GitHub.${data.truncated ? " Only the newest 1000 issues are read, so older ones are missing." : ""} Open a milestone for its kanban.`, releasesHtml(data));
  }
  // the local store has no plan and no worker sync: its versions and the librarian only
  if (data.source === "local") {
    return [page, section("rm-releases", "Releases", `Live from the local tracker store (${data.mirror.count} items). Open a version for its kanban.`, releasesHtml(data)),
      bar, section("rm-librarian", "Librarian", "Ready-to-approve cleanups.", librarianHtml(data, u))].join("\n");
  }
  return [
    page,
    section("rm-releases", "Releases", `Live from the Jira mirror (${data.mirror.count} tickets, newest update ${data.mirror.newest || "unknown"}). Open a version for its kanban.`, releasesHtml(data)),
    section("rm-drift", "Drift", "Jira's fixVersion against the plan's placement.", driftHtml(data)),
    bar, // narrows the sync and librarian lists below
    section("rm-sync", "Worker to Jira sync", "What the workers say that Jira does not yet.", syncHtml(data, u)),
    section("rm-librarian", "Librarian", "Ready-to-approve cleanups.", librarianHtml(data, u)),
  ].join("\n");
}

// ---- the Board page: the one per-version page that replaced the Roadmap and Kanban pages --------------------------------
// renderBoard(data, ui, extras) → HTML. data = GET /api/roadmap; extras = { drift, chains } from GET /api/board (null until read).
// ui: { tab: roadmap|nv|chains|tidy, v: a version name | "all" | null (the running version), theme, chain, hideDone, writes, writeError, at,
// project, planTheme, only, find (the lane filters), nv (GET /api/roadmap?nv=1, null until the No version tab has read it) }.
// A field whose source is not there is shown as absent in words, never as a number: no drift file, no chain registry.
// renderRoadmap and renderKanban above stay exported: the design-layer and tracker tests pin their markup.
const TABS = [["roadmap", "Roadmap"], ["chains", "Chains"], ["tidy", "Tidy up"], ["nv", "No version"]];
const query = (o) => { const p = new URLSearchParams(); for (const [k, v] of Object.entries(o)) if (v) p.set(k, v); const s = p.toString(); return s ? "?" + s : ""; };
const boardHref = (o) => esc("#/board" + query(o));
const driftOk = (dr) => !!(dr && dr.counts && dr.file && dr.file.exists && !dr.unknown);
const noChains = (ch) => (ch && ch.reason) || "no chain registry: none found under the handover root, and HIMMEL_CHAIN_REGISTRY is not set";

// The version asked for: an index, -1 for every version, -2 for a name the mirror does not have. No version asked = the running one.
function selIndex(d, ui) {
  if (ui.v === "all") return -1;
  if (ui.v) return d.versions.findIndex((x) => x.n === ui.v) < 0 ? -2 : d.versions.findIndex((x) => x.n === ui.v);
  if (d.projects && d.projects.length > 1) return -1; // several projects each run their own version: the default is every version, not one project's
  return d.cur >= 0 ? d.cur : d.next >= 0 ? d.next : -1;
}

function driftBanner(dr) {
  if (!dr || dr.state === "absent" || !dr.counts || !dr.file) return `<div class="nodata">drift: not read${dr && dr.reason ? ` (${esc(dr.reason)})` : ""}</div>`;
  if (!dr.file.exists) return `<div class="nodata">drift: no saved run yet</div>`;
  if (dr.unknown) return `<div class="nodata">drift: the saved run's result is unknown</div>`;
  const c = dr.counts, n = c.real;
  return `<div class="alert"><span class="st pill ${n ? "warn" : "ok"}">drift</span> <b>${n} drift row${n === 1 ? "" : "s"}</b> · not counted: ${c.known} known checker bug, ${c.transient} transient · <b>${esc(dr.mode)}</b> mode`
    + `${dr.stale ? " · the saved run is older than 3 h" : ""} <a href="#/board?tab=tidy">Tidy up ▸</a></div>`;
}

// The version strip shows at most MAX_VERSIONS tiles. Pins (ui.pins, version names) win; with none, the running version and 2 each side. "Show all"
// lifts the cap; "Hide previous" drops released versions; "Hide far future" drops versions more than 2 after the running one. Display only: no write.
const MAX_VERSIONS = 5;
const CAP_MSG = `The Board shows at most ${MAX_VERSIONS} versions, so at most ${MAX_VERSIONS} can be pinned: unpin one first.`;
export function togglePin(pins, name) {
  const cur = pins || [];
  if (cur.includes(name)) return { pins: cur.filter((p) => p !== name), msg: "" };
  if (cur.length >= MAX_VERSIONS) return { pins: cur, msg: CAP_MSG };
  return { pins: [...cur, name], msg: "" };
}
// The pins live in the URL's query string (?pins=a,b, before the #/board hash, which hash navigation leaves alone): a reload or a bookmark keeps them,
// and the page stores nothing in the browser and writes nothing to the server.
// ponytail: per URL, not per account, upgrade path: a server-side per-user setting.
export const pinsFromSearch = (search) => (new URLSearchParams(search || "").get("pins") || "").split(",").filter(Boolean);
export function searchWithPins(search, pins) {
  const p = new URLSearchParams(search || "");
  if (pins.length) p.set("pins", pins.join(",")); else p.delete("pins");
  const s = p.toString();
  return s ? "?" + s : "";
}
function windowOf(d, ui) {
  const n = d.versions.length, anchor = d.cur >= 0 ? d.cur : d.next >= 0 ? d.next : n - 1;
  const pinned = [...new Set((ui.pins || []).map((name) => d.versions.findIndex((v) => v.n === name)).filter((i) => i >= 0))].sort((x, y) => x - y);
  if (pinned.length && !ui.showAll) return { idx: pinned.slice(0, MAX_VERSIONS), capped: pinned.length > MAX_VERSIONS, pinned }; // Show all lifts the pins' cap on the strip, so another version can be pinned
  const open = d.versions.map((v, i) => i).filter((i) => !(ui.hidePrev && d.versions[i].rel) && !(ui.hideFuture && i > anchor + 2));
  return { idx: ui.showAll ? open : open.filter((i) => Math.abs(i - anchor) <= 2), capped: false, pinned };
}
function windowBar(d, ui, w) {
  const chk = (attr, label, on) => `<label><input type="checkbox" ${attr}${on ? " checked" : ""}> ${label}</label>`;
  const msg = ui.pinMsg || (w.capped ? CAP_MSG : "");
  return `<div class="rm-vwin fields"><span class="ro" role="status">showing ${w.idx.length} of ${d.versions.length} versions${w.pinned.length ? " · pinned" : ""}</span>`
    + `<button class="btn" data-rm-show-all aria-pressed="${!!ui.showAll}">${ui.showAll ? "Show 5" : "Show all"}</button>`
    + chk("data-rm-hide-prev", "Hide previous", ui.hidePrev) + chk("data-rm-hide-future", "Hide far future", ui.hideFuture)
    + (w.pinned.length ? `<button class="btn" data-rm-clear-pins>Clear pins</button>` : "") + `</div>` + (msg ? `<div class="nodata" role="alert">${esc(msg)}</div>` : "");
}

function stripHtml(d, sel, ch, tab, ui = {}) {
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  const w = windowOf(d, ui), pins = ui.pins || [];
  const tiles = w.idx.map((i) => {
    const v = d.versions[i];
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0), flight = c.prog + c.rev + c.ci;
    const run = runState(d, v, i), tag = v.rel ? `released${v.date ? " " + v.date : ""}` : run || "planned";
    const inChains = chainOk(ch) ? d.tickets.filter((t) => t.v === i && ch.tickets[idOf(t)]).length : null;
    const stats = `${c.done} done · ${flight} in flight · ${c.todo} to do${c.wont ? ` · ${c.wont} won't` : ""}${inChains !== null ? ` · ${inChains} in chains` : ""}`;
    const open = v.open.length ? `<span class="ro pill fail">${v.open.length} still open: ${v.open.map((k) => `${v.project || "HIMMEL"}-${k}`).map(esc).join(", ")}</span>` : "";
    const pinned = pins.includes(v.n);
    return `<div class="rm-vcell"><a class="rm-vt${i === sel ? " sel" : ""}" href="${boardHref({ tab: tab === "roadmap" ? "" : tab, v: v.n })}"${i === sel ? ` aria-current="true"` : ""}>${tip(`${v.n} · ${tag}`, `<b>${esc(v.n)}</b> <span class="ro pill${v.rel ? " ok" : run === "running" ? " warn" : ""}">${esc(tag)}</span>`)}`
      + `<progress value="${c.done}" max="${total || 1}" aria-label="${esc(v.n)}: ${c.done} of ${total} done"></progress>`
      + tip(stats, `<span class="ro">${esc(stats)}</span>`) + `${open}</a>`
      + `<button class="rm-pin" data-rm-pin="${esc(v.n)}" aria-pressed="${pinned}" aria-label="${pinned ? "Unpin" : "Pin"} ${esc(v.n)}">${pinned ? "★" : "☆"}</button></div>`;
  }).join("");
  return note + windowBar(d, ui, w) + (tiles ? `<div class="rm-vstrip" aria-label="Versions">${tiles}</div>` : `<div class="empty">No versions to show with these filters.</div>`);
}

// Two links under the strip. "waits for you" counts the chain read's tickets whose state is "waits on you"; with no chain read it
// says so. "Shipped" has no count here (the merged-PR read is the Shift page's), so it names where the number is.
function linksHtml(ch) {
  let wait = `<b>waits for you: not read</b> (${esc(noChains(ch))})`;
  if (chainOk(ch)) {
    const w = Object.values(ch.tickets).filter((x) => x.state === "waits on you");
    wait = `<b>${w.length} ${w.length === 1 ? "waits" : "wait"} for you</b>${w.length ? ": " + w.map((x) => esc(x.key)).join(", ") : ""}`;
  }
  return `<div class="rm-links"><div class="rm-link"><span>${wait}</span><a href="#/shift">open in Shift →</a></div>`
    + `<div class="rm-link"><span><b>Shipped since yesterday</b>: the count is not read here</span><a href="#/report">Morning report →</a></div></div>`;
}

function tabsHtml(d, ui, tab, ch, dr) {
  const blocked = chainOk(ch) ? Object.values(ch.tickets).filter((x) => x.state === "blocked").length : 0;
  const em = { chains: chainOk(ch) ? (ch.version ? `${ch.chains.length} in ${ch.version} · ${blocked} blocked` : `${ch.chains.length} · no running version`) : "", tidy: driftOk(dr) ? `${dr.counts.real} drift` : "", nv: d.noVersionCount ? String(d.noVersionCount) : "" };
  // the No version tab is there while some ticket has no fixVersion (the count is the default read's; the tickets are read when it opens)
  return `<nav class="tabs" role="tablist" aria-label="Board">${TABS.filter(([id]) => id !== "nv" || d.noVersionCount || tab === "nv").map(([id, label]) =>
    `<a class="tab" role="tab" aria-selected="${tab === id}" href="${boardHref({ tab: id, v: ui.v })}">${esc(label)}${em[id] ? ` <span class="ro">${esc(em[id])}</span>` : ""}</a>`).join("")}</nav>`;
}

// The Roadmap tab's lane filters. Project is the ticket id's prefix; Theme is the plan's theme (the Sector has its own filter); Only is one
// state of the chain read, or the plan drift. The chain states are listed but disabled while no chain read is there.
const projectOf = (t) => (/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(idOf(t)) ? idOf(t).slice(0, idOf(t).indexOf("-")) : "GitHub");
const projectsOf = (d) => [...new Set(d.tickets.map(projectOf))].sort();
const chainState = (t, ch) => (chainOk(ch) ? ch.tickets[idOf(t)] : null);
const ONLY = [["blocked", (t, ct) => !!ct && ct.state === "blocked", true], ["waits on step", (t, ct) => !!ct && /^waits on step/.test(ct.state), true],
  ["waits on you", (t, ct) => !!ct && ct.state === "waits on you", true], ["date-gated", (t, ct) => !!ct && ct.state === "date-gated", true],
  ["drift", (t) => t.drift === 1, false], ["in a chain", (t, ct) => !!ct, true]];
const fsel = (name, label, items, cur) => `<label>${label} <select data-rm-filter="${name}"><option value="">all</option>${items.map((x, i) =>
  `<option value="${i}"${cur === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
function laneFilters(d, ui, ch, sel) {
  const scope = d.tickets.filter((t) => sel < 0 || t.v === sel);
  const only = ONLY.map(([l, f, needs]) => needs && !chainOk(ch) ? `${l} (not read)` : `${l} ${scope.filter((t) => f(t, chainState(t, ch))).length}`);
  const onlySel = `<label>Only <select data-rm-filter="only"><option value="">all</option>${ONLY.map(([, , needs], i) =>
    `<option value="${i}"${needs && !chainOk(ch) ? " disabled" : ui.only === i ? " selected" : ""}>${esc(only[i])}</option>`).join("")}</select></label>`;
  // [stays on the bar line, goes under More ▾]
  return [`<label>Find <input type="search" data-rm-find value="${esc(ui.find || "")}" placeholder="find a ticket or title" aria-label="Find a ticket or title"></label>`,
    fsel("project", "Project", projectsOf(d), ui.project) + fsel("planTheme", "Theme", d.planThemes, ui.planTheme) + onlySel];
}

// The one filter bar and refresh, drawn above every tab: the version links keep the tab, the Sector, Chain and Hide Done filters narrow what the tab lists.
function barHtml(d, ui, ch, tab, sel, fresh = "") {
  const here = d.versions[d.cur] ? d.versions[d.cur].n : d.versions[d.next] ? d.versions[d.next].n : "all";
  const keep = tab === "roadmap" ? "" : tab;
  const lanes = `<a href="${boardHref({ tab: keep, v: here })}">this version</a> · <a href="${boardHref({ tab: keep, v: "all" })}">all versions</a>`;
  const chainSel = chainOk(ch) ? `<label>Chain <select data-rm-chain><option value="">all</option>${ch.chains.map((c) =>
    `<option value="${esc(c.id)}"${ui.chain === c.id ? " selected" : ""}>${esc(c.id)}</option>`).join("")}</select></label>` : "";
  const [find, more] = tab === "roadmap" ? laneFilters(d, ui, ch, sel) : tab === "nv" && ui.nv && ui.nv.state === "ok" ? laneFilters(ui.nv, ui, ch, -1) : ["", ""];
  // one line: the lanes, Sector, find, Chain, Hide Done and refresh; the rarer filters wait under More ▾ (a closed <details> keeps them out of the way)
  return `<div class="rm-bar fields"><span>Lanes: ${lanes}</span>${themeSel(d, ui)}${find}${chainSel}<label><input type="checkbox" data-rm-hide-done${ui.hideDone ? " checked" : ""}> Hide Done</label>`
    + (more ? `<details class="rm-more"><summary>More ▾</summary><div class="rm-more-pop fields">${more}</div></details>` : "")
    + `<button class="btn" data-act="refresh-roadmap">refresh</button>${fresh ? tip(fresh, `<span class="ro">${esc(fresh)}</span>`, " rm-fresh") : ""}</div>${writeNote(ui)}`;
}

// What a ticket must pass to be drawn: the Sector, Hide Done, Chain, Project, Theme, Only and the find box. d is the payload the tickets and the
// Project and Theme indexes come from; the Sector select is drawn from `from` (the default read), so it is compared by name, not by index.
const passOf = (d, ui, ch, from = d) => {
  const q = (ui.find || "").trim().toLowerCase(), only = ONLY[ui.only];
  const sector = ui.theme == null ? null : from.themes[ui.theme], project = ui.project == null ? null : projectsOf(d)[ui.project];
  return (t) => (ui.theme == null || (sector != null && d.themes[t.theme] === sector)) && !(ui.hideDone && t.b === "done")
    && (!ui.chain || !chainOk(ch) || (ch.tickets[idOf(t)] && ch.tickets[idOf(t)].chains.some((c) => c.id === ui.chain)))
    && (ui.project == null || projectOf(t) === project) && (ui.planTheme == null || t.pt === ui.planTheme)
    && (!only || (only[2] && !chainOk(ch)) || only[1](t, chainState(t, ch)))
    && (!q || idOf(t).toLowerCase().includes(q) || t.t.toLowerCase().includes(q));
};

// ticket key to the checker ticket that explains its drift row, for the tag on a lane card
const knownByKey = (dr) => new Map((dr && dr.known ? dr.known : []).map((r) => [r.key, r.checker]));

function lanesHtml(d, ui, sel, ch, dr) {
  const gh = d.source === "github";
  const writeOn = !!ui.writes && !gh;
  if (sel === -2) return section("rm-lanes", "Roadmap", "", `<div class="empty">${esc(ui.v)}: no such version in the mirror.</div>`);
  const scope = d.tickets.filter((t) => sel < 0 || t.v === sel), shown = scope.filter(passOf(d, ui, ch));
  const what = sel >= 0 ? `${d.versions[sel].n}: ${shown.length} tickets` : `every version: ${shown.length} tickets`;
  const sub = gh ? `${what}. GitHub issues are read-only here: change them on GitHub.${d.truncated ? " Only the newest 1000 issues are read, so older ones are missing." : ""}`
    : `${what}.${writeOn ? " Drag a card to another column to change its status." : ""}`;
  return section("rm-lanes", "Roadmap", sub, shown.length ? boardHtml(d, shown, sel < 0, writeOn, ch, ui.v, { scope, foldDone: true, find: (ui.find || "").trim().toLowerCase(), drawer: ui.drawer, known: knownByKey(dr) }) : `<div class="empty">No tickets match.</div>`);
}

// The No version tab: the tickets with no fixVersion, in the same columns. They are not in the default read; ui.nv is GET /api/roadmap?nv=1,
// asked for when this tab opens (null until it arrives).
function nvTab(data, ui, ch, dr) {
  const nv = ui.nv, sub = "Tickets with no fixVersion. Give one a fixVersion in Jira to put it on a version's board.";
  if (!nv) return section("rm-nv", "No version", sub, `<p class="sub" id="status">loading…</p>`);
  if (nv.state !== "ok") return section("rm-nv", "No version", sub, `<div class="nodata">${esc(nv.reason || "the tickets with no version could not be read")}</div>`);
  const writeOn = !!ui.writes && nv.source !== "github";
  const scope = nv.tickets.filter((t) => t.noVersion), shown = scope.filter(passOf(nv, ui, ch, data));
  return section("rm-nv", "No version", `${shown.length} ticket${shown.length === 1 ? "" : "s"}. ${sub}${writeOn ? " Drag a card to another column to change its status." : ""}`,
    shown.length ? boardHtml(nv, shown, false, writeOn, ch, ui.v, { scope, foldDone: true, find: (ui.find || "").trim().toLowerCase(), drawer: ui.drawer, known: knownByKey(dr) }) : `<div class="empty">No tickets match.</div>`);
}

// The Chains tab, from the v4 mockup's frames 4 and 4b: how chains link, what each one logged, why a ticket waits, and the burn-down. Reads only.
const live = (a) => a.status === "open" || a.status === "unknown";
const whyLink = (ui, key, on) => { const id = `${key}.${on || ""}`;
  return `<a class="rm-whylink" data-why-open="${esc(id)}" aria-label="Why ${esc(key)} waits${on ? " on " + esc(on) : ""}" href="${boardHref({ tab: "chains", v: ui.v, why: id })}">Why</a>`; };
const stamp = (ts) => String(ts || "").slice(0, 16).replace("T", " ");
// With several Board projects a version is named "<name> (<PROJECT>)"; the chain read has the bare name.
// ponytail: the first project with that name wins, upgrade path: the chain read names its project.
const versionAt = (d, name) => (d.versions || []).findIndex((x) => x.n === name || x.n.startsWith(`${name} (`));

function chainMap(ch) {
  const W = 200, H = 56, GX = 40, GY = 40, COLS = 3;
  const at = new Map(ch.chains.map((c, i) => [c.id, { x: 10 + (i % COLS) * (W + GX) + W / 2, y: 10 + Math.floor(i / COLS) * (H + GY) + H / 2 }]));
  const edges = new Map(); // the blocker's chain to the waiting chain; open while any link between them is
  for (const c of ch.chains) for (const a of c.across || []) if (a.dir === "waits-on") for (const o of a.chains || []) {
    if (!at.has(o) || o === c.id) continue;
    const k = JSON.stringify([o, c.id]);
    edges.set(k, edges.get(k) || live(a));
  }
  const lines = [...edges].map(([k, open]) => {
    const [from, to] = JSON.parse(k), p = at.get(from), q = at.get(to), dx = q.x - p.x, dy = q.y - p.y;
    const t = Math.min(dx ? W / 2 / Math.abs(dx) : 1, dy ? (H / 2 + 4) / Math.abs(dy) : 1); // the line stops at each box's edge
    return `<line class="rm-edge${open ? " open" : ""}" x1="${p.x + dx * t}" y1="${p.y + dy * t}" x2="${q.x - dx * t}" y2="${q.y - dy * t}" marker-end="url(#rm-arrow)"/>`;
  }).join("");
  const boxes = ch.chains.map((c) => { const p = at.get(c.id), name = String(c.name || c.id);
    return `<rect class="rm-map-box" x="${p.x - W / 2}" y="${p.y - H / 2}" width="${W}" height="${H}" rx="8"/><text x="${p.x}" y="${p.y - 4}" text-anchor="middle">${esc(name.length > 24 ? name.slice(0, 23) + "…" : name)}</text>`
      + `<text class="rm-map-sub" x="${p.x}" y="${p.y + 16}" text-anchor="middle">${esc(String(c.done))}/${esc(String(c.total))} done</text>`; }).join("");
  const rows = Math.ceil(ch.chains.length / COLS);
  return `<svg class="rm-map" viewBox="0 0 ${3 * W + 2 * GX + 20} ${rows * (H + GY) - GY + 20}" role="img" aria-label="Map of ${ch.chains.length} chains and the links between them; the list below says the same in words">`
    + `<defs><marker id="rm-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="8" markerHeight="8" orient="auto"><path class="rm-arrow" d="M0 0L8 4L0 8z"/></marker></defs>${lines}${boxes}</svg>`;
}

function crossLinks(ui, ch) {
  const name = (id) => { const c = ch.chains.find((x) => x.id === id); return (c && c.name) || id; };
  const rows = ch.chains.flatMap((c) => (c.across || []).filter((a) => a.dir === "waits-on" && (a.chains || []).length).map((a) =>
    `<li><b>${esc(a.key)}</b> <span class="ro">in ${esc(name(c.id))}</span> waits on <b>${esc(a.on)}</b> <span class="ro">in ${esc(a.chains.map(name).join(", "))} · ${esc(a.kind)} · ${esc(a.status)}</span>${live(a) ? " " + whyLink(ui, a.key, a.on) : ""}</li>`));
  const list = rows.length ? `<ul class="rm-xlist">${rows.join("")}</ul>` : `<p class="ro">${ch.version ? `No links between the chains of ${esc(ch.version)}; a link to work outside it shows under its chain.` : "No links across chains."}</p>`;
  const map = chainMap(ch), note = map ? `<p class="sub rm-map-note">An arrow runs from the work that lands first. A moving dashed line is still open; a solid one is cleared.</p>` : "";
  return section("rm-xlinks", "How the chains link", "Which ticket waits on a ticket in another chain.", note + map + list);
}

function acrossHtml(ui, c, version) {
  const rows = (c.across || []).map((a) => {
    const where = (a.chains || []).length ? `in ${a.chains.join(", ")}` : `in no chain${version ? ` of ${version}` : ""}`;
    const other = a.dir === "waits-on" ? `waits on <b>${esc(a.on)}</b> <span class="ro">${esc(where)}` : `holds up <b>${esc(a.key)}</b> <span class="ro">${esc(where)}`;
    const self = a.dir === "waits-on" ? a.key : a.on;
    return `<li><b>${esc(self)}</b> ${other} · ${esc(a.kind)} · ${esc(a.status)}</span>${live(a) ? " " + whyLink(ui, a.key, a.on) : ""}</li>`;
  });
  return rows.length ? `<p class="rm-subh">Across other work</p><ul class="rm-xlist">${rows.join("")}</ul>` : "";
}

function logHtml(ui, c) {
  const log = c.log || [];
  if (!log.length) return `<p class="ro">No changes logged.</p>`;
  const last = log[log.length - 1];
  return `<details class="rm-log" data-log="${esc(c.id)}"${(ui.logOpen || []).includes(c.id) ? " open" : ""}><summary>Change log · ${log.length} · last ${esc(stamp(last.ts))}: ${esc(last.change)}</summary>`
    + `<div class="scroll"><table class="rm-sync data"><thead><tr><th>When</th><th>Change</th><th>Ticket</th><th>On</th><th>Kind</th><th>Who</th><th>Reason</th></tr></thead><tbody>${log.map((r) =>
      `<tr><td>${esc(stamp(r.ts))}</td><td>${esc(r.change || "")}</td><td>${esc(r.key || r.chain || "")}</td><td>${esc(r.on || "")}</td><td>${esc(r.kind || "")}</td><td>${esc(r.who || "")}</td><td>${esc(r.reason || "")}</td></tr>`).join("")}</tbody></table></div></details>`;
}

function burnHtml(d, ch) {
  const b = ch.burn;
  if (!b) return "";
  const sub = "Open tickets across the chains, one point a day; bars are the merges of that day.";
  const undated = b.undated ? ` ${b.undated} done ticket${b.undated === 1 ? " has" : "s have"} no recorded date and ${b.undated === 1 ? "is" : "are"} left out.` : "";
  const scope = ch.version ? ` in ${ch.version}` : "";
  if (!b.points.length) return section("rm-burn", "Burn-down", sub, `<p class="ro rm-burn-words">No merge recorded yet${esc(scope)}: ${b.total} open.${undated}</p>`);
  const v = (d.versions || [])[versionAt(d, ch.version)], cut = v && v.date ? v.date : "";
  const dayMs = (x) => Date.parse(`${x}T00:00:00Z`), first = dayMs(b.points[0].day), lastPt = b.points[b.points.length - 1];
  const end = Math.max(dayMs(lastPt.day), cut ? dayMs(cut) : 0), W = 640, H = 140, top = 8;
  const X = (ms) => 10 + (end > first ? (ms - first) / (end - first) : 0) * (W - 20), Y = (n) => top + (1 - n / (b.total || 1)) * (H - top);
  const pts = b.points.map((p) => ({ ...p, x: X(dayMs(p.day)), y: Y(p.open) }));
  const bars = pts.filter((p) => p.merged).map((p) => `<rect class="rm-burn-bar" x="${p.x - 3}" y="${Y(p.merged)}" width="6" height="${H - Y(p.merged)}"/>`).join("");
  const pace = cut ? `<polyline class="rm-burn-pace" points="${pts[0].x},${pts[0].y} ${X(dayMs(cut))},${Y(0)}"/>` : "";
  const merged = b.points.reduce((n, p) => n + p.merged, 0);
  const words = `${lastPt.open} open of ${b.total}${scope}; ${merged} merged since ${b.points[0].day}.${cut ? ` The dashed line is the even pace to the cut on ${cut}.` : ch.version ? " This version has no date, so there is no pace line." : " No running version, so there is no pace line."}${undated}`;
  return section("rm-burn", "Burn-down", sub, `<svg class="rm-burn-svg" viewBox="0 0 ${W} ${H + 4}" role="img" aria-label="${esc(words)}">${bars}${pace}<polyline class="rm-burn-open" points="${pts.map((p) => `${p.x},${p.y}`).join(" ")}"/>`
    + `${pts.map((p) => `<circle class="rm-burn-dot" cx="${p.x}" cy="${p.y}" r="3"><title>${esc(p.day)}: ${p.open} open, ${p.merged} merged</title></circle>`).join("")}</svg><p class="ro rm-burn-words">In words: ${esc(words)}</p>`);
}

function whyHtml(ui, ch) {
  if (!ui.why || !chainOk(ch)) return "";
  const dot = ui.why.indexOf("."), key = dot < 0 ? ui.why : ui.why.slice(0, dot), on = dot < 0 ? "" : ui.why.slice(dot + 1);
  const t = ch.tickets[key], same = ((t && t.links) || []).filter((x) => (x.on || "") === on), l = same.find(live) || same[0];
  const close = `<a class="btn rm-why-close" href="${boardHref({ tab: "chains", v: ui.v })}" aria-label="Close why panel">close ✕</a>`;
  const head = (h) => `<div class="rm-dh"><h4 id="h-rm-why">${esc(h)}</h4>${close}</div>`;
  const panel = (b) => `<aside class="drawer rm-why" role="dialog" aria-modal="true" aria-labelledby="h-rm-why">${b}</aside>`;
  if (!l) return panel(head(`Why ${key} waits`) + `<p class="nodata">This link is not in this chain read: it cleared, or the ticket left the version.</p>`);
  const fact = (k, v) => (v ? `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>` : "");
  const show = (k) => (ch.tickets[k] ? `<a href="${boardHref({ tab: "chains", v: ui.v, at: k })}">Show ${esc(k)} in its chain</a>` : "");
  return panel(head(on ? `Why ${key} waits on ${on}` : `Why ${key} waits: ${l.kind}`)
    + `<dl class="rm-facts">${fact("State", t.state)}${fact("Blocker", on ? on + (ch.tickets[on] ? "" : ` (in no chain${ch.version ? ` of ${ch.version}` : ""})`) : "")}${fact("Kind", l.kind)}${fact("Source", l.source)}${fact("Added", l.added ? stamp(l.added) : "not recorded")}${fact("Status", l.status)}${fact("What clears it", l.clears)}${fact("Reason", l.reason)}${fact("Owner", l.owner)}${fact("Until", l.until)}</dl>`
    + `<p>${[show(key), on ? show(on) : ""].filter(Boolean).join(" · ")}</p><p class="ro">Esc closes this panel.</p>`);
}

// The tab reads the running version whatever tile was asked for, and says so.
function coversHtml(ui, ch, d) {
  if (!ch.version) return "";
  const at = (d.versions || [])[versionAt(d, ch.version)];
  const other = ui.v === "all" ? "every version" : ui.v && ui.v !== ch.version && !(at && at.n === ui.v) ? ui.v : "";
  const missing = ui.at && !ch.tickets[ui.at] ? ` ${ui.at} is not in a chain of ${ch.version}.` : "";
  return `<p class="sub rm-covers">${esc(`This tab covers the running version, ${ch.version}${other ? `, not ${other}` : ""}.${missing}`)}</p>`;
}

function chainsTab(ui, ch, d) {
  const sub = "Work that has to land in order.";
  if (!chainOk(ch)) return section("rm-chains", "Chains", sub, `<div class="nodata">${esc(noChains(ch))}</div>`);
  const covers = coversHtml(ui, ch, d);
  if (!ch.chains.length) return section("rm-chains", "Chains", sub, `${covers}<div class="empty">${ch.version ? `No chain has a ticket in ${esc(ch.version)}.` : "No chains in the registry."}</div>`);
  const noVersion = ch.version ? "" : `<div class="nodata">no running version: the chain read covers every version, so it cannot tell a real block and shows no count of them.</div>`;
  return covers + noVersion + crossLinks(ui, ch) + "\n" + ch.chains.map((c) => {
    const rows = Object.values(ch.tickets).map((t) => [t, (t.chains || []).find((x) => x.id === c.id)]).filter(([, x]) => x)
      .sort((a, b) => a[1].step - b[1].step || String(a[0].key).localeCompare(String(b[0].key), "en", { numeric: true }));
    const nxt = c.next ? `next: step ${c.next.step} ${(c.next.keys || []).map(esc).join(", ")}` : c.done < c.total ? "no step can launch yet" : "no step left";
    return `<section id="rm-chain-${esc(c.id)}" class="box" aria-labelledby="h-rm-chain-${esc(c.id)}"><h2 id="h-rm-chain-${esc(c.id)}">${esc(c.name || c.id)} <span class="ro">${esc(c.id)}</span></h2>`
      + `<p class="sub">${c.done}/${c.total} done · ${c.steps} step${c.steps === 1 ? "" : "s"} · ${nxt}</p>${acrossHtml(ui, c, ch.version)}<div class="scroll"><table class="rm-sync rm-chainrows data"><thead><tr><th>Ticket</th><th>Title</th><th>Step</th><th>State</th></tr></thead><tbody>${rows.map(([t, x]) =>
        `<tr${t.chains[0].id === c.id ? ` id="cn-${esc(t.key)}"` : ""}${ui.at === t.key ? ` class="rm-at"` : ""}><td>${esc(t.key)}</td><td>${esc(t.title || "")}</td><td>${esc(String(x.step))}/${esc(String(x.steps))}</td><td><span aria-hidden="true"${x.state === "in flight" ? ` class="rm-ping"` : ""}>${glyph(x.state)}</span> ${esc(x.state)}${(t.links || []).filter(live).map((l) => " " + whyLink(ui, t.key, l.on)).join("")}</td></tr>`).join("")}</tbody></table></div>${logHtml(ui, c)}</section>`;
  }).join("\n") + "\n" + burnHtml(d, ch);
}

// One row of status-drift.sh: `CLASS KEY says | writer=… | fix=…`. The fix is shown with a copy button; the Board never runs it.
// The origin column: the newest status move on the ticket, from its Jira history. himmel's account can also be a person on the same login, so it never reads as "himmel did it".
function originText(h) {
  if (!h) return "reading…";
  if (h.error) return "origin not read";
  const e = h.events[h.events.length - 1];
  if (!e) return "no status move in Jira";
  return e.himmel ? "himmel's Jira account: a script, or a hand move if the login is shared" : `moved in Jira by ${e.who}`;
}
function driftRow(r, origins) {
  const parts = String(r.line || "").split(" | "), prefix = `${r.class} ${r.key} `;
  const says = parts[0].startsWith(prefix) ? parts[0].slice(prefix.length) : parts[0];
  const get = (k) => (parts.find((p) => p.startsWith(k + "=")) || "").slice(k.length + 1);
  const fix = get("fix");
  return `<tr><td><code>${esc(r.class)}</code></td><td class="rm-key">${esc(r.key)}</td><td>${esc(says)}</td><td>${esc(originText(origins && origins[r.key]))}</td><td>${esc(get("writer"))}</td><td>${fix ? `<code>${esc(fix)}</code> <button class="btn" data-act="copy" data-cmd="${esc(fix)}">copy</button>` : ""}</td></tr>`;
}
function statusDriftHtml(dr, origins) {
  if (!driftOk(dr)) return `<div class="nodata">${dr && dr.file && !dr.file.exists ? "no saved drift run yet" : dr && dr.counts && dr.unknown ? "the saved drift run's result is unknown" : "status drift not read" + (dr && dr.reason ? ` (${esc(dr.reason)})` : "")}</div>`;
  const grp = (title, rows) => rows && rows.length ? `<tr class="grp"><td colspan="6">${esc(title)} · ${rows.length}</td></tr>${rows.map((r) => driftRow(r, origins)).join("")}` : "";
  const body = grp("Real drift · counted", dr.real) + grp("Known checker bug · listed, not counted", dr.known) + grp("Transient · listed, not counted", dr.transient);
  return `<div class="kv">real ${dr.counts.real} · known checker bug ${dr.counts.known} · transient ${dr.counts.transient} · ${esc(dr.mode)} mode · saved run ${esc(dr.file.writtenHm || "unknown")}</div>`
    + (body ? `<div class="scroll"><table class="data"><thead><tr><th>class</th><th>ticket</th><th>says</th><th>origin</th><th>writer</th><th>fix</th></tr></thead><tbody>${body}</tbody></table></div>`
      : `<div class="empty">No drift rows.</div>`);
}

// What a re-run changed, row by row, from the rows on screen before it (mockup v4 frame 6).
const driftLines = (dr) => (dr && dr.real ? [...dr.real, ...dr.known, ...dr.transient].map((r) => r.line.split(" | ")[0]) : []);
export function driftSince(before, after) {
  const was = driftLines(before), now = driftLines(after), added = now.filter((l) => !was.includes(l));
  const real = driftLines({ real: (after && after.real) || [], known: [], transient: [] });
  return { from: before && before.file ? before.file.writtenHm : null, added, counted: added.filter((l) => real.includes(l)), healed: was.filter((l) => !now.includes(l)), same: now.filter((l) => was.includes(l)).length };
}
function sinceHtml(s) {
  const row = (tag, text) => `<tr><td>${tag}</td><td>${esc(text)}</td></tr>`;
  return `<div class="scroll"><table class="data"><thead><tr><th>since ${esc(s.from || "the last run")}</th><th>row</th></tr></thead><tbody>${s.added.map((l) => row((s.counted || []).includes(l) ? "new · counted" : "new", l)).join("")}${s.healed.map((l) => row("healed", l)).join("")}${row("same", `${s.same} row${s.same === 1 ? "" : "s"}`)}</tbody></table></div>`;
}
// The Refresh control (mockup v4 frame 6). Opening the tab reads the saved file and starts nothing; a run keeps the saved rows on screen until it ends.
function driftBar(dr, run) {
  const hm = dr && dr.file && dr.file.exists ? dr.file.writtenHm || "unknown" : null, running = run && run.state === "running";
  const facts = hm ? ` · written <b>${esc(hm)}</b>${dr.sdrift ? ` · <code>sdrift=${esc(dr.sdrift)}</code>` : ""}${dr.stale ? " · older than 3 h" : ""}` : "";
  const text = running ? `<span class="rm-spin" aria-hidden="true"></span> re-running the check · started <b>${esc(run.started)}</b> · usually about 2 min, at most 3 min 20 s${hm ? ` · the rows below are from ${esc(hm)}` : ""}`
    : hm ? `drift: <b>${run && run.state === "done" ? "re-run" : "saved run"}</b>${facts}` : `drift: no saved run to show`;
  const bar = `<div class="rm-driftbar" role="status"><span>${text}</span><button class="btn" data-act="drift-refresh" aria-label="refresh: re-run the drift check"${running ? " disabled" : ""}>refresh</button></div>`;
  if (run && run.state === "failed") return `${bar}<div class="alert" role="alert"><span class="st pill fail">not re-run</span> ${esc(run.reason)} · ${hm ? `the saved run from ${esc(hm)} is kept` : "there is no saved run to keep"}</div>`;
  return run && run.state === "done" ? bar + sinceHtml(run.since) : bar;
}
// The mode is read-only here: its one switch is on Configure (mockup v4 frame 5b).
function modeHtml(dr) {
  if (!dr || !dr.mode) return "";
  const team = dr.mode === "team";
  return `<div class="kv rm-mode">team mode is <b>${team ? "on" : "off"}</b> · <a href="#/config?tile=tracker">change in Configure → Tracker ▸</a> · ${team ? "team: a drift is ordinary tidy-up · the doctor only reports it" : "single-user: a real drift = a himmel bug · the doctor WARNs"}</div>`;
}

function tidyTab(d, ui, sel, dr) {
  // Tidy up covers every version unless the route names one: a default of the running version would hide the other versions' sync ops and released-but-open tickets.
  const u = { ...ui, version: ui.v && ui.v !== "all" && sel >= 0 ? sel : null };
  if (d.source === "github") return section("rm-tidy", "Tidy up", "", `<div class="nodata">GitHub issues are read-only here, so there is nothing to tidy: change them on GitHub.</div>`);
  const lib = section("rm-librarian", "Librarian", "Ready-to-approve cleanups.", librarianHtml(d, u));
  if (d.source === "local") return lib; // the local store has no Jira status, no plan and no worker sync
  return [
    section("rm-status-drift", "Status drift", "Jira against the events, from the saved drift run.", driftBar(dr, ui.driftRun) + modeHtml(dr) + statusDriftHtml(dr, ui.driftOrigins)),
    section("rm-drift", "Drift", "Jira's fixVersion against the plan's placement.", driftHtml(d)),
    section("rm-sync", "Worker to Jira sync", "What the workers say that Jira does not yet.", syncHtml(d, u)),
    lib,
  ].join("\n");
}

// ---- the ticket drawer (mockup v4 frame 3): opened from a card, it shows the card's facts, the CLI call each write makes, and its stage history.
// ui.drawer = { k, project, history }: the card (number and project: two projects share numbers) and its status moves as the page fetched them
// (null while loading, { events } when read, { error } when the read failed, so a failed read never looks like "no moves").
const STATUS = { todo: "To Do", prog: "In Progress", rev: "In Review", ci: "IN CI", done: "Done", wont: "wont do" };
const OPERATOR_OWNED = ["todo", "prog", "wont"]; // the columns a drop or a key may write; In review, CI and Done are moved by their event
// The call a write makes. A local card runs the tracker seam's own verbs, as local-tracker.ts passes them (a move carries --allow-back).
const moveLine = (t, status) => (t.backend === "local" ? ["tracker_transition", idOf(t), status, "--allow-back"].map(shq).join(" ") : jira(["transition", idOf(t), status]));
const sectorLine = (t, sector) => (t.backend === "local" ? ["tracker_sector", idOf(t), sector].map(shq).join(" ") : jira(["edit", idOf(t), "--sector", sector]));
const when = (at) => String(at).slice(0, 16).replace("T", " ");

function historyHtml(t, h) {
  if (t.backend !== "jira") return `<p class="ro">Stage history is read from Jira; this card's tracker keeps none.</p>`;
  if (!h) return `<p class="ro">loading…</p>`;
  if (h.error) return `<div class="nodata" role="alert">${esc(h.error)}</div>`;
  if (!h.events.length) return `<p class="ro">No status moves recorded.</p>`;
  return `<ul class="rm-tl">${h.events.map((e) => `<li class="done"><span class="when">${esc(when(e.at))}</span><b>${esc(e.from || "(none)")} → ${esc(e.to || "(none)")}</b> · ${esc(e.who)}</li>`).join("")}`
    + `<li class="now"><span class="when">now</span>${esc(t.s)}</li></ul>`;
}

function actionsHtml(d, t) {
  if (t.backend === "github") return `<p class="ro">GitHub issues are read-only here: change them on GitHub.</p>`;
  const sector = d.themes[t.theme] && d.themes[t.theme] !== NO_SECTOR ? d.themes[t.theme] : "<Sector>";
  const row = (what, line) => `<tr><td>${what}</td><td><code>${esc(line)}</code> <button class="btn" data-act="copy" data-cmd="${esc(line)}">copy</button></td></tr>`;
  // the tracker seam refuses "wont do" (exit 2), so a local card is not offered it
  const moves = OPERATOR_OWNED.filter((b) => b !== t.b && !(t.backend === "local" && b === "wont")).map((b) => row(`move to ${esc(STATUS[b])}`, moveLine(t, STATUS[b])));
  return `<table class="data rm-acts"><thead><tr><th>action</th><th>runs</th></tr></thead><tbody>${moves.join("")}${row("Sector", sectorLine(t, sector))}`
    + `<tr><td>In review, CI, Done</td><td>moved by their event (a PR opening, CI, the merge): a drop or a key there writes nothing</td></tr></tbody></table>`;
}

function drawerHtml(d, ui) {
  const dr = ui.drawer;
  if (!dr) return "";
  const own = (x) => x.k === dr.k && (x.project || "") === (dr.project || "");
  const t = d.tickets.find(own) || (ui.nv && ui.nv.state === "ok" ? ui.nv.tickets.find(own) : undefined);
  if (!t) return "";
  const id = idOf(t), v = t.v >= 0 && d.versions[t.v] ? d.versions[t.v].n : "none: no fixVersion, so it is on the No version tab";
  const worker = t.worker ? `${t.worker.label} ${t.worker.marker}${t.worker.reason ? " · " + t.worker.reason : ""}` : "none live";
  const plan = t.drift === 1 ? `drift: the plan puts it in ${t.pv}` : t.drift === 2 ? "unplanned" : "as planned";
  return `<aside class="drawer" role="dialog" aria-label="Ticket ${esc(id)}">
    <div class="rm-dh"><div><span class="rm-id">${esc(id)}</span> <span class="ro">· ${esc(t.backend || "jira")}${t.project ? " · " + esc(t.project) : ""}</span><h4>${esc(t.t)}</h4></div>
      <button class="btn" data-act="rm-close" aria-label="Close ticket ${esc(id)}">close ✕</button></div>
    <dl class="rm-facts"><dt>stage</dt><dd>${esc(t.s)}</dd><dt>worker</dt><dd>${esc(worker)}</dd><dt>version</dt><dd>${esc(v)}</dd><dt>Sector</dt><dd>${esc(d.themes[t.theme] || "")}</dd><dt>plan</dt><dd>${esc(plan)}</dd></dl>
    <div class="rm-sec"><p class="rm-subh">Actions, and the CLI call each one makes</p>${actionsHtml(d, t)}</div>
    <div class="rm-sec"><p class="rm-subh">Stage history</p>${historyHtml(t, dr.history)}</div>
    <p class="ro">Keyboard: on a card, Enter opens this drawer, Shift+Left and Shift+Right move it between To do, In progress and Won't. Esc closes the drawer.</p>
  </aside>`;
}

export const renderBoard =(data, ui, extras) => pg(boardPage(data, ui || {}, extras || {}));
function boardPage(data, ui, extras) {
  const page = pageHeader("Board", "Every version, what each ticket is doing, and what is left");
  if (!data) return page + `<p class="sub" id="status">loading…</p>`;
  if (data.source === "none") return page + noTrackerHtml();
  if (data.state !== "ok") return page + `<div class="nodata">${esc(data.reason || "board unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  // the whole Board reads every version; the Chains tab reads the running one
  const { drift: dr, chains: ch, versionChains: tabCh = ch } = extras;
  const tab = TABS.some(([id]) => id === ui.tab) ? ui.tab : "roadmap";
  const sel = selIndex(data, ui);
  const tileSel = tab !== "chains" || !chainOk(tabCh) ? sel : tabCh.version ? versionAt(data, tabCh.version) : -1; // a tile never highlights over totals of another version
  const src = data.source === "github" ? `GitHub issues (${data.mirror.count})` : data.source === "local" ? `the local tracker store (${data.mirror.count} items)`
    : `the Jira mirror (${data.mirror.count} tickets, newest update ${data.mirror.newest || "unknown"})`;
  // plain text: the bar clips it to what fits and keeps the whole line in its bubble
  const fresh = `read live from ${src}${driftOk(dr) && dr.file.exists ? ` · drift: saved run ${dr.file.writtenHm || "unknown"}` : ""}`;
  const body = tab === "chains" ? chainsTab(ui, tabCh, data) : tab === "tidy" ? tidyTab(data, ui, sel, dr) : tab === "nv" ? nvTab(data, ui, ch, dr) : lanesHtml(data, ui, sel, ch, dr);
  const drawer = drawerHtml(data, ui), why = tab === "chains" ? whyHtml(ui, tabCh) : "";
  // with a drawer or the Why panel open the board under it is inert: no drag, select, key or click reaches a card until it closes
  return [page, `<div class="rm-under"${drawer || why ? " inert" : ""}>`, driftBanner(dr), stripHtml(data, tileSel, ch, tab, ui), `<div class="rm-tabrow">${tabsHtml(data, ui, tab, tabCh, dr)}${linksHtml(ch)}</div>`, barHtml(data, ui, ch, tab, sel, fresh), body, `</div>`, drawer, why].join("\n");
}
