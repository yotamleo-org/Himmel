// the Roadmap page. Pure rendering, no DOM: renderRoadmap(data, ui) → HTML.
// data = GET /api/roadmap (null while loading); ui = { version, theme }, indices into data.versions / data.themes (the Sectors) or null.
// Everything shown is the server's live read. With ui.writes the Kanban cards are draggable and carry a Sector
// select, and app.js posts the drop or the select to /api/roadmap/write. The rest of the page proposes only.
import { esc, pageHeader, pg } from "./render.js";

const COLS = [["todo", "To do"], ["prog", "In progress"], ["rev", "In review"], ["ci", "CI"], ["done", "Done"], ["wont", "Won't"]];
const section = (id, title, sub, body) => `<section id="${id}" class="box" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;
const jira = (argv) => "jira " + argv.map((a) => (/^[\w.,:@/=-]+$/.test(a) ? a : `"${a.replace(/(["\\$`])/g, "\\$1")}"`)).join(" ");

function releasesHtml(d) {
  if (!d.versions.length) return `<div class="empty">No train versions.</div>`;
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  return note + d.versions.map((v, i) => {
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0);
    const tag = v.rel ? `released${v.date ? " " + v.date : ""}` : i === d.cur ? "running" : i === d.next ? "next" : "planned";
    const alert = v.open.length ? `<div class="alert"><span class="st pill fail">open</span> ${v.open.length} still open on a released version: ${v.open.map((k) => `HIMMEL-${k}`).map(esc).join(", ")}</div>` : "";
    return `<div class="card rm-rel${i === d.cur ? " cur" : ""}"><h3><a href="#/roadmap/${encodeURIComponent(v.n)}">${esc(v.n)}</a> <span class="ro pill${v.rel ? " ok" : i === d.cur ? " warn" : ""}">${esc(tag)}</span></h3>
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
const sectorPick = (t, d) => `<select class="rm-theme" data-rm-theme-key="${t.k}" aria-label="Sector of ${esc(idOf(t))}">${d.themes.map((x, i) =>
  `<option value="${x === NO_SECTOR ? "" : esc(x)}"${t.theme === i ? " selected" : x === NO_SECTOR ? " disabled" : ""}>${esc(x)}</option>`).join("")}${
  t.backend === "local" ? `<option value="" data-rm-new>new sector…</option>` : ""}</select>`;

// The chain read (GET /api/board, chain-state.mjs): usable only when it carries chains; anything else is the absent notice.
const chainOk = (ch) => !!(ch && Array.isArray(ch.chains) && ch.tickets);
const GLYPH = { done: "✓", "in flight": "●", "can launch": "▷", blocked: "⛔", "waits on you": "?", "date-gated": "⏲" };
const glyph = (s) => GLYPH[s] || (/^waits on step/.test(s) ? "…" : /^done/.test(s) ? "✓" : "");
// A chain badge under the card title: chain id, the ticket's step of the chain's steps, and its state as a glyph and a word,
// so it reads without colour (at most two badges, then +N). A ticket in no chain, or no chain read at all, has none.
function chainBadge(t, ch) {
  const ct = chainOk(ch) ? ch.tickets[idOf(t)] : null;
  if (!ct || !Array.isArray(ct.badges) || !ct.badges.length) return "";
  const at = encodeURIComponent(idOf(t));
  const parts = ct.badges.map((id) => ct.chains.find((c) => c.id === id)).filter(Boolean).map((c) =>
    `<a class="rm-chain" href="#/board?tab=chains&amp;at=${esc(at)}" title="Open the ${esc(c.id)} chain on the Chains tab"><span aria-hidden="true">${glyph(c.state)}</span> ${esc(c.id)} ${esc(String(c.step))}/${esc(String(c.steps))} · ${esc(c.state)}</a>`);
  return `<div class="rm-chains">${parts.join("")}${ct.more ? ` <span class="ro">+${esc(String(ct.more))}</span>` : ""}</div>`;
}

function cardHtml(t, d, showVersion, w, ch) {
  const lg = t.worker ? `<div class="rm-worker"><b>${esc(t.worker.label)} ${esc(t.worker.marker)}</b>${t.worker.reason ? " " + esc(t.worker.reason) : ""}</div>` : "";
  const dr = t.drift === 1 ? `<span class="st pill warn">drift</span> plan: ${esc(t.pv)}` : t.drift === 2 ? `<span class="st pill warn">unplanned</span>` : "";
  const ver = showVersion ? `<a class="ro" href="#/roadmap/${encodeURIComponent(d.versions[t.v].n)}">${esc(d.versions[t.v].n)}</a> ` : "";
  const theme = w ? sectorPick(t, d) : esc(d.themes[t.theme]);
  const local = t.backend === "local";
  const attrs = w ? ` draggable="true" data-rm-card="${t.k}"${local ? ` data-rm-id="${esc(t.id)}" data-rm-backend="local"` : ""}` : "";
  return `<div class="rm-card"${attrs}><b>${esc(idOf(t))}</b>${local ? ` <span class="ro pill">local</span>` : ""} <span class="ro pill${t.b === "done" ? " ok" : t.b === "prog" || t.b === "rev" || t.b === "ci" ? " warn" : ""}">${esc(t.s)}</span><div>${esc(t.t)}</div>${chainBadge(t, ch)}
    <div class="ro">${ver}${theme} ${dr}</div>${lg}</div>`;
}

// One board: a column per status over the given tickets. Won't and CI stay hidden while empty so a quiet board stays short.
// With w every column is a drop target, Won't included: a writable board must be able to receive it.
function boardHtml(d, tickets, showVersion, w, ch) {
  return `<div class="rm-board">${COLS.filter(([b]) => w || b !== "wont" || tickets.some((t) => t.b === b)).map(([b, l]) => {
    const cards = tickets.filter((t) => t.b === b);
    return `<div class="rm-col"${w ? ` data-rm-drop="${b}"` : ""}><h4>${esc(l)} <span class="ro">${cards.length}</span></h4>${cards.map((t) => cardHtml(t, d, showVersion, w, ch)).join("")}</div>`;
  }).join("")}</div>`;
}

const themeSel = (d, ui) => `<label>Sector <select data-rm-filter="theme"><option value="">all</option>${d.themes.map((x, i) =>
  `<option value="${i}"${ui.theme === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
// A refused or failed write: shown above the board, the card has already moved back (the board is redrawn from the server).
const writeNote = (ui) => (ui.writeError ? `<div class="alert" role="alert"><span class="st pill fail">refused</span> ${esc(ui.writeError)}</div>` : "");
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
const shownKs = (d, ui) => new Set(d.tickets.filter((t) => (ui.version == null || t.v === ui.version) && (ui.theme == null || t.theme === ui.theme)).map((t) => t.k));

function syncHtml(d, ui) {
  const keep = shownKs(d, ui);
  const ops = (d.sync || []).filter((o) => keep.has(o.k));
  const body = ops.length ? ops.map((o) => `<tr><td>HIMMEL-${o.k}</td><td>${esc(o.marker)}</td><td>${esc(o.why)}</td>
      <td><code>${esc(jira(o.argv))}</code> <button class="btn" data-act="copy" data-cmd="${esc(jira(o.argv))}">copy</button></td></tr>`).join("")
    : `<tr><td colspan="4" class="empty">Jira already matches the workers.</td></tr>`;
  return `<p class="ro">Planned only: the console kit is the one writer, via the Jira CLI. Workers never write Jira and this page never does.</p>
    <div class="scroll"><table class="rm-sync data"><thead><tr><th>Ticket</th><th>Worker</th><th>Why</th><th>Command</th></tr></thead><tbody>${body}</tbody></table></div>`;
}

function librarianHtml(d, ui) {
  const l = d.librarian, keep = shownKs(d, ui);
  const ids = new Map(d.tickets.map((t) => [t.k, idOf(t)]));
  const id = (k) => ids.get(k) || "HIMMEL-" + k;
  const list = (title, all) => { const items = all.filter((p) => (p.keys ? p.keys.some((k) => keep.has(k)) : keep.has(p.k))); return `<div class="card"><h3>${esc(title)} <span class="ro">${items.length}</span></h3>${items.length ? items.map((p) =>
    `<div class="hrow"><span class="id">${p.keys ? p.keys.map(id).map(esc).join(" = ") : esc(id(p.k))}</span><span class="det">${esc(p.title)}</span><span>${esc(p.proposal)}</span></div>`).join("")
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
// ui: { tab: roadmap|chains|tidy, v: a version name | "all" | null (the running version), theme, chain, hideDone, writes, writeError, at }.
// A field whose source is not there is shown as absent in words, never as a number: no drift file, no chain registry.
// renderRoadmap and renderKanban above stay exported: the design-layer and tracker tests pin their markup.
const TABS = [["roadmap", "Roadmap"], ["chains", "Chains"], ["tidy", "Tidy up"]];
const query = (o) => { const p = new URLSearchParams(); for (const [k, v] of Object.entries(o)) if (v) p.set(k, v); const s = p.toString(); return s ? "?" + s : ""; };
const boardHref = (o) => esc("#/board" + query(o));
const driftOk = (dr) => !!(dr && dr.counts && dr.file && dr.file.exists && !dr.unknown);
const noChains = (ch) => (ch && ch.reason) || "no chain registry: set HIMMEL_CHAIN_REGISTRY to a himmel.chain-registry/1 file";

// The version asked for: an index, -1 for every version, -2 for a name the mirror does not have. No version asked = the running one.
function selIndex(d, ui) {
  if (ui.v === "all") return -1;
  if (ui.v) return d.versions.findIndex((x) => x.n === ui.v) < 0 ? -2 : d.versions.findIndex((x) => x.n === ui.v);
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

function stripHtml(d, sel, ch) {
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  const tiles = d.versions.map((v, i) => {
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0), flight = c.prog + c.rev + c.ci;
    const tag = v.rel ? `released${v.date ? " " + v.date : ""}` : i === d.cur ? "running" : i === d.next ? "next" : "planned";
    const inChains = chainOk(ch) ? d.tickets.filter((t) => t.v === i && ch.tickets[idOf(t)]).length : null;
    const open = v.open.length ? `<span class="ro">${v.open.length} still open: ${v.open.map((k) => `HIMMEL-${k}`).map(esc).join(", ")}</span>` : "";
    return `<a class="rm-vt${i === sel ? " sel" : ""}" href="${boardHref({ v: v.n })}"${i === sel ? ` aria-current="true"` : ""}><span><b>${esc(v.n)}</b> <span class="ro pill${v.rel ? " ok" : i === d.cur ? " warn" : ""}">${esc(tag)}</span></span>`
      + `<progress value="${c.done}" max="${total || 1}" aria-label="${esc(v.n)}: ${c.done} of ${total} done"></progress>`
      + `<span class="ro">${c.done} done · ${flight} in flight · ${c.todo} to do${c.wont ? ` · ${c.wont} won't` : ""}${inChains !== null ? ` · ${inChains} in chains` : ""}</span>${open}</a>`;
  }).join("");
  return note + (tiles ? `<div class="rm-vstrip" aria-label="Versions">${tiles}</div>` : `<div class="empty">No train versions.</div>`);
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

function tabsHtml(ui, tab, ch, dr) {
  const blocked = chainOk(ch) ? Object.values(ch.tickets).filter((x) => x.state === "blocked").length : 0;
  const em = { chains: chainOk(ch) ? `${ch.chains.length} · ${blocked} blocked` : "", tidy: driftOk(dr) ? `${dr.counts.real} drift` : "" };
  return `<nav class="tabs" role="tablist" aria-label="Board">${TABS.map(([id, label]) =>
    `<a class="tab" role="tab" aria-selected="${tab === id}" href="${boardHref({ tab: id, v: ui.v })}">${esc(label)}${em[id] ? ` <span class="ro">${esc(em[id])}</span>` : ""}</a>`).join("")}</nav>`;
}

function lanesHtml(d, ui, sel, ch) {
  const gh = d.source === "github";
  const writeOn = !!ui.writes && !gh;
  const here = d.versions[d.cur] ? d.versions[d.cur].n : d.versions[d.next] ? d.versions[d.next].n : "all";
  const lanes = `<a href="${boardHref({ v: here })}">this version</a> · <a href="${boardHref({ v: "all" })}">all versions</a>`;
  const chainSel = chainOk(ch) ? `<label>Chain <select data-rm-chain><option value="">all</option>${ch.chains.map((c) =>
    `<option value="${esc(c.id)}"${ui.chain === c.id ? " selected" : ""}>${esc(c.id)}</option>`).join("")}</select></label>` : "";
  const bar = `<div class="rm-bar fields"><span>Lanes: ${lanes}</span>${themeSel(d, ui)}${chainSel}<label><input type="checkbox" data-rm-hide-done${ui.hideDone ? " checked" : ""}> Hide Done</label>`
    + `<button class="btn" data-act="refresh-roadmap">refresh</button></div>${writeNote(ui)}`;
  if (sel === -2) return section("rm-lanes", "Roadmap", "", bar + `<div class="empty">${esc(ui.v)}: no such version in the mirror.</div>`);
  const shown = byTheme(d, ui)
    .filter((t) => sel < 0 || t.v === sel)
    .filter((t) => !(ui.hideDone && t.b === "done"))
    .filter((t) => !ui.chain || !chainOk(ch) || (ch.tickets[idOf(t)] && ch.tickets[idOf(t)].chains.some((c) => c.id === ui.chain)));
  const what = sel >= 0 ? `${d.versions[sel].n}: ${shown.length} tickets` : `every version: ${shown.length} tickets`;
  const sub = gh ? `${what}. GitHub issues are read-only here: change them on GitHub.${d.truncated ? " Only the newest 1000 issues are read, so older ones are missing." : ""}`
    : `${what}.${writeOn ? " Drag a card to another column to change its status." : ""}`;
  return section("rm-lanes", "Roadmap", sub, bar + (shown.length ? boardHtml(d, shown, sel < 0, writeOn, ch) : `<div class="empty">No tickets match.</div>`));
}

function chainsTab(ui, ch) {
  const sub = "Work that has to land in order.";
  if (!chainOk(ch)) return section("rm-chains", "Chains", sub, `<div class="nodata">${esc(noChains(ch))}</div>`);
  if (!ch.chains.length) return section("rm-chains", "Chains", sub, `<div class="empty">No chains in the registry.</div>`);
  return ch.chains.map((c) => {
    const rows = Object.values(ch.tickets).map((t) => [t, (t.chains || []).find((x) => x.id === c.id)]).filter(([, x]) => x)
      .sort((a, b) => a[1].step - b[1].step || String(a[0].key).localeCompare(String(b[0].key), "en", { numeric: true }));
    const nxt = c.next ? `next: step ${c.next.step} ${(c.next.keys || []).map(esc).join(", ")}` : "no step left";
    return `<section id="rm-chain-${esc(c.id)}" class="box" aria-labelledby="h-rm-chain-${esc(c.id)}"><h2 id="h-rm-chain-${esc(c.id)}">${esc(c.name || c.id)} <span class="ro">${esc(c.id)}</span></h2>`
      + `<p class="sub">${c.done}/${c.total} done · ${c.steps} steps · ${nxt}</p><div class="scroll"><table class="rm-sync data"><thead><tr><th>Ticket</th><th>Title</th><th>Step</th><th>State</th></tr></thead><tbody>${rows.map(([t, x]) =>
        `<tr${t.chains[0].id === c.id ? ` id="cn-${esc(t.key)}"` : ""}${ui.at === t.key ? ` class="rm-at"` : ""}><td>${esc(t.key)}</td><td>${esc(t.title || "")}</td><td>${esc(String(x.step))}/${esc(String(x.steps))}</td><td><span aria-hidden="true">${glyph(x.state)}</span> ${esc(x.state)}</td></tr>`).join("")}</tbody></table></div></section>`;
  }).join("\n");
}

// One row of status-drift.sh: `CLASS KEY says | writer=… | fix=…`. The fix is shown with a copy button; the Board never runs it.
function driftRow(r) {
  const parts = String(r.line || "").split(" | "), prefix = `${r.class} ${r.key} `;
  const says = parts[0].startsWith(prefix) ? parts[0].slice(prefix.length) : parts[0];
  const get = (k) => (parts.find((p) => p.startsWith(k + "=")) || "").slice(k.length + 1);
  const fix = get("fix");
  return `<tr><td><code>${esc(r.class)}</code></td><td>${esc(r.key)}</td><td>${esc(says)}</td><td>${esc(get("writer"))}</td><td>${fix ? `<code>${esc(fix)}</code> <button class="btn" data-act="copy" data-cmd="${esc(fix)}">copy</button>` : ""}</td></tr>`;
}
function statusDriftHtml(dr) {
  if (!driftOk(dr)) return `<div class="nodata">${dr && dr.file && !dr.file.exists ? "no saved drift run yet" : dr && dr.counts && dr.unknown ? "the saved drift run's result is unknown" : "status drift not read" + (dr && dr.reason ? ` (${esc(dr.reason)})` : "")}</div>`;
  const grp = (title, rows) => rows && rows.length ? `<tr class="grp"><td colspan="5">${esc(title)} · ${rows.length}</td></tr>${rows.map(driftRow).join("")}` : "";
  const body = grp("Real drift · counted", dr.real) + grp("Known checker bug · listed, not counted", dr.known) + grp("Transient · listed, not counted", dr.transient);
  return `<div class="kv">real ${dr.counts.real} · known checker bug ${dr.counts.known} · transient ${dr.counts.transient} · ${esc(dr.mode)} mode · saved run ${esc(dr.file.writtenHm || "unknown")}</div>`
    + (body ? `<div class="scroll"><table class="data"><thead><tr><th>class</th><th>ticket</th><th>says</th><th>writer</th><th>fix</th></tr></thead><tbody>${body}</tbody></table></div>`
      : `<div class="empty">No drift rows.</div>`);
}

function tidyTab(d, ui, sel, dr) {
  const u = { ...ui, version: sel >= 0 ? sel : null };
  if (d.source === "github") return section("rm-tidy", "Tidy up", "", `<div class="nodata">GitHub issues are read-only here, so there is nothing to tidy: change them on GitHub.</div>`);
  const lib = section("rm-librarian", "Librarian", "Ready-to-approve cleanups.", librarianHtml(d, u));
  if (d.source === "local") return lib; // the local store has no Jira status, no plan and no worker sync
  return [
    section("rm-status-drift", "Status drift", "Jira against the events, from the saved drift run.", statusDriftHtml(dr)),
    section("rm-drift", "Drift", "Jira's fixVersion against the plan's placement.", driftHtml(d)),
    section("rm-sync", "Worker to Jira sync", "What the workers say that Jira does not yet.", syncHtml(d, u)),
    lib,
  ].join("\n");
}

export const renderBoard = (data, ui, extras) => pg(boardPage(data, ui || {}, extras || {}));
function boardPage(data, ui, extras) {
  const page = pageHeader("Board", "Every version, what each ticket is doing, and what is left");
  if (!data) return page + `<p class="sub" id="status">loading…</p>`;
  if (data.source === "none") return page + noTrackerHtml();
  if (data.state !== "ok") return page + `<div class="nodata">${esc(data.reason || "board unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  const { drift: dr, chains: ch } = extras;
  const tab = TABS.some(([id]) => id === ui.tab) ? ui.tab : "roadmap";
  const sel = selIndex(data, ui);
  const src = data.source === "github" ? `GitHub issues (${data.mirror.count})` : data.source === "local" ? `the local tracker store (${data.mirror.count} items)`
    : `the Jira mirror (${data.mirror.count} tickets, newest update ${data.mirror.newest || "unknown"})`;
  const fresh = `<p class="ro rm-fresh">read live from ${src}${driftOk(dr) && dr.file.exists ? ` · drift: saved run ${esc(dr.file.writtenHm || "unknown")}` : ""}</p>`;
  const body = tab === "chains" ? chainsTab(ui, ch) : tab === "tidy" ? tidyTab(data, ui, sel, dr) : lanesHtml(data, ui, sel, ch);
  return [page, fresh, driftBanner(dr), stripHtml(data, sel, ch), linksHtml(ch), tabsHtml(ui, tab, ch, dr), body].join("\n");
}
