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
const glyph = (s) => GLYPH[s] || (/^waits on/.test(s) ? "…" : s === "done · out of order" ? "⚠" : /^done/.test(s) ? "✓" : "");
// The one chain-link icon: on the Chains tab and on every card badge, so a card says which tab it opens.
const CLINK = `<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></svg>`;
// A chain badge under the card title: the chain icon and id, the ticket's step as words, and its state as a glyph and a word,
// so it reads without colour (at most two badges, then +N). A ticket in no chain, or no chain read at all, has none.
function chainBadge(t, ch, v, d) {
  const ct = chainOk(ch) ? ch.tickets[idOf(t)] : null;
  if (!ct || !Array.isArray(ct.badges) || !ct.badges.length) return "";
  const at = encodeURIComponent(idOf(t));
  const parts = ct.badges.map((id) => ct.chains.find((c) => c.id === id)).filter(Boolean).map((c) => {
    const state = viewState(ct, c.state, ch, d).state, step = `step ${c.step} of ${c.steps}`;
    const text = `${glyph(state)} ${c.id} ${step} · ${state}`.trim();
    return `<a class="rm-chain" href="#/board?tab=chains${v ? `&amp;v=${esc(encodeURIComponent(v))}` : ""}&amp;at=${esc(at)}" aria-label="Open the ${esc(c.id)} chain on the Chains tab: ${esc(text)}">${tip(text, `${CLINK}<span aria-hidden="true">${glyph(state)}</span> ${esc(c.id)} ${esc(step)} · ${esc(state)}`)}</a>`;
  });
  return `<div class="rm-chains">${parts.join("")}${ct.more ? ` <span class="ro">+${esc(String(ct.more))}</span>` : ""}</div>`;
}

// A card's open PRs and their CI as links (#N · CI state), from the worker records /api/board carries as prs; a started card with none says so. With no read
// of the records nothing is shown, so the flag never rests on a guess.
function prHtml(t, pr) {
  if (!pr || pr.state !== "ok" || !pr.prs) return "";
  const list = pr.prs[idOf(t)] || [];
  if (list.length) return `<div class="rm-pr">${list.map((p) => {
    const text = `#${p.pr} · CI ${p.ci}`;
    return pr.repo ? `<a class="pr ci-${esc(p.ci)}" href="https://github.com/${esc(pr.repo)}/pull/${p.pr}" target="_blank" rel="noopener">${esc(text)}</a>` : `<span class="pr ci-${esc(p.ci)}">${esc(text)}</span>`;
  }).join(" ")}</div>`;
  if ((pr.unread || []).includes(idOf(t))) return "";
  return t.b === "prog" || t.b === "rev" || t.b === "ci" ? `<div class="rm-pr"><span class="pr nopr">no open PR</span></div>` : "";
}

// What an open ticket waits on, from the mirror's links: "blocked by open X" for a blocker still open, "after X (done)" for a shut one, and a key in no mirror says its state is unknown.
// The tracker's FAST-TRACK label: an open ticket in a chain names the chain and its step. Needs the chain read; nothing is guessed without it.
function ftHtml(t, ch) {
  const ct = chainOk(ch) && t.b !== "done" && t.b !== "wont" ? ch.tickets[idOf(t)] : null, c = ct && ct.chains && ct.chains[0];
  if (!c) return "";
  const def = ch.chains.find((x) => x.id === c.id);
  return `<div class="rm-ft">FAST-TRACK · ${esc(def && def.name ? def.name : c.id)} · step ${c.step}</div>`;
}
function depHtml(t) {
  const a = Array.isArray(t.after) ? t.after : [];
  if (!a.length) return "";
  const open = a.filter((x) => x.b === "todo" || x.b === "prog" || x.b === "rev" || x.b === "ci"), shut = a.filter((x) => x.b === "done" || x.b === "wont"), unk = a.filter((x) => x.b === "unknown");
  return `<div class="rm-dep">${open.length ? `<span class="warn">blocked by open ${open.map((x) => esc(x.id)).join(", ")}</span> ` : ""}${shut.length ? `after ${shut.map((x) => `${esc(x.id)} (${x.b === "wont" ? "won't do" : "done"})`).join(", ")} ` : ""}${unk.length ? unk.map((x) => `${esc(x.id)} (state unknown)`).join(", ") : ""}</div>`;
}

// "50 min ago", "3 h ago", "2 d ago": the tracker's own steps, from the worker record's last event; empty when the record is missing or unreadable.
function agoHtml(t, pr) {
  const ts = pr && pr.state === "ok" && pr.seen ? Date.parse(pr.seen[idOf(t)]) : NaN;
  if (!Number.isFinite(ts)) return "";
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  return ` <span class="ro">· ${s < 3600 ? `${Math.floor(s / 60)} min` : s < 86400 ? `${Math.floor(s / 3600)} h` : `${Math.floor(s / 86400)} d`} ago</span>`;
}

function cardHtml(t, d, showVersion, w, ch, v, known, pr) {
  const kb = known && known.get(idOf(t)) ? `<span class="rm-kb" title="The drift row on this ticket is the checker's fault: listed, not counted."><span aria-hidden="true">≠</span> checker bug ${esc(known.get(idOf(t)))}</span>` : "";
  const lg = t.worker ? `<div class="rm-worker"><b>${esc(t.worker.label)} ${esc(t.worker.marker)}</b>${t.worker.reason ? " " + esc(t.worker.reason) : ""}${agoHtml(t, pr)}</div>` : "";
  const dr = t.drift === 1 ? `<span class="st pill warn">drift</span> plan: ${esc(t.pv)}` : t.drift === 2 ? `<span class="st pill warn">unplanned</span>` : "";
  const ver = showVersion && t.v >= 0 ? `<a class="ro" href="#/roadmap/${encodeURIComponent(d.versions[t.v].n)}">${esc(d.versions[t.v].n)}</a> ` : "";
  const theme = w ? sectorPick(t, d) : esc(d.themes[t.theme]);
  const local = t.backend === "local";
  const attrs = w ? ` draggable="true" data-rm-card="${t.k}"${projAttr(t)}${local ? ` data-rm-id="${esc(t.id)}" data-rm-backend="local"` : ""}` : "";
  const open = ` data-rm-open="${t.k}"${w ? "" : projAttr(t)} tabindex="0"`; // a click, Enter or Space opens the drawer; the project attribute is shared with the drag one
  const ci = t.b === "ci" ? ` <span class="ro pill warn">CI</span>` : ""; // CI shares the Review column: the pill says which of the two the card is in
  // two lines: the id, status and sector row, then the title clamped to two lines; the card's accessible name is the id and the full title
  return `<div class="rm-card"${attrs}${open} role="button" aria-label="${esc(idOf(t))}: ${esc(t.t)}"><div class="rm-top"><b>${esc(idOf(t))}</b>${local ? ` <span class="ro pill">local</span>` : ""} <span class="ro pill${t.b === "done" ? " ok" : t.b === "prog" || t.b === "rev" || t.b === "ci" ? " warn" : ""}">${esc(t.s)}</span>${ci} <span class="ro">${ver}${theme} ${dr}</span></div>`
    + `<div class="rm-tip rm-title" data-tip="${esc(t.t)}"><span class="rm-clip">${esc(t.t)}</span></div>${chainBadge(t, ch, v, d)}${ftHtml(t, ch)}${kb}${depHtml(t)}${prHtml(t, pr)}${lg}</div>`;
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
    const body = cards.map((t) => cardHtml(t, d, showVersion, w, ch, v, o.known, o.prs)).join(""), drop = w ? ` data-rm-drop="${b}"` : "";
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
function windowBar(d, ui, w, inert = false) {
  const chk = (attr, label, on) => `<label><input type="checkbox" ${attr}${on ? " checked" : ""}> ${label}</label>`;
  return `<div class="rm-vwin fields"${inert ? " inert" : ""}><span class="ro" role="status">showing ${w.idx.length} of ${d.versions.length} versions${w.pinned.length ? " · pinned" : ""}</span>`
    + `<button class="btn" data-rm-show-all aria-pressed="${!!ui.showAll}">${ui.showAll ? "Show 5" : "Show all"}</button>`
    + chk("data-rm-hide-prev", "Hide previous", ui.hidePrev) + chk("data-rm-hide-future", "Hide far future", ui.hideFuture)
    + (w.pinned.length ? `<button class="btn" data-rm-clear-pins>Clear pins</button>` : "") + `</div>`;
}

// slim (the Chains tab): one small chip per version, the picked version's numbers in one line under the chips, and the window controls
// behind a "N of M versions" menu. The fuller tiles stay on the Roadmap, Tidy up and No version tabs.
function slimStrip(d, sel, tab, ui, w, inert) {
  const info = (i) => { const v = d.versions[i], c = v.counts; return { v, c, run: runState(d, v, i), tag: v.rel ? `released${v.date ? " " + v.date : ""}` : runState(d, v, i) || "planned", total: Object.values(c).reduce((a, b) => a + b, 0) }; };
  const stat = (x) => `${x.c.done} done · ${x.c.prog + x.c.rev + x.c.ci} in flight · ${x.c.todo} to do${x.c.wont ? ` · ${x.c.wont} won't` : ""}`;
  const chips = w.idx.map((i) => { const x = info(i);
    return `<a class="vc${i === sel ? " sel" : ""}" href="${boardHref({ tab, v: x.v.n })}"${i === sel ? ` aria-current="true"` : ""} title="${esc(`${x.v.n} · ${x.tag} · ${stat(x)}`)}"><b>${esc(x.v.n)}</b> <small>${esc(x.tag)}</small><progress value="${x.c.done}" max="${x.total || 1}" aria-label="${esc(x.v.n)}: ${x.c.done} of ${x.total} tickets done"></progress></a>`; }).join("");
  const pv = sel >= 0 && d.versions[sel] ? `<p class="pv"><b>${esc(d.versions[sel].n)}</b> · ${esc(info(sel).tag)} · ${nTickets(info(sel).total)} · ${esc(stat(info(sel)))}</p>` : "";
  const menu = `<details class="vmenu"${inert ? " inert" : ""}><summary>${w.idx.length} of ${d.versions.length} versions ▾</summary>${windowBar(d, ui, w, inert)}</details>`;
  return (chips ? `<div class="vchips" aria-label="Versions">${chips}${menu}</div>` : `<div class="empty">No versions to show with these filters.</div>${menu}`) + pv;
}
function stripHtml(d, sel, tab, ui = {}, lead = "", slim = false) {
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  const w = windowOf(d, ui), pins = ui.pins || [];
  if (slim) return lead + note + slimStrip(d, sel, tab, ui, w, !!ui.inert);
  const tiles = w.idx.map((i) => {
    const v = d.versions[i];
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0), flight = c.prog + c.rev + c.ci;
    const run = runState(d, v, i), tag = v.rel ? `released${v.date ? " " + v.date : ""}` : run || "planned";
    const stats = `${c.done} done · ${flight} in flight · ${c.todo} to do${c.wont ? ` · ${c.wont} won't` : ""}`;
    const open = v.open.length ? `<span class="ro pill fail">${v.open.length} still open: ${v.open.map((k) => `${v.project || "HIMMEL"}-${k}`).map(esc).join(", ")}</span>` : "";
    const pinned = pins.includes(v.n);
    return `<div class="rm-vcell"><a class="rm-vt${i === sel ? " sel" : ""}" href="${boardHref({ tab: tab === "roadmap" ? "" : tab, v: v.n })}"${i === sel ? ` aria-current="true"` : ""}>${tip(`${v.n} · ${tag}`, `<b>${esc(v.n)}</b> <span class="ro pill${v.rel ? " ok" : run === "running" ? " warn" : ""}">${esc(tag)}</span>`)}`
      + `<progress value="${c.done}" max="${total || 1}" aria-label="${esc(v.n)}: ${c.done} of ${total} done"></progress>`
      + tip(stats, `<span class="ro">${esc(stats)}</span>`) + `${open}</a>`
      + `<button class="rm-pin" data-rm-pin="${esc(v.n)}" aria-pressed="${pinned}" aria-label="${pinned ? "Unpin" : "Pin"} ${esc(v.n)}">${pinned ? "★" : "☆"}</button></div>`;
  }).join("");
  const msg = ui.pinMsg || (w.capped ? CAP_MSG : "");
  return lead + note + (msg ? `<div class="nodata" role="alert">${esc(msg)}</div>` : "") + (tiles ? `<div class="rm-vstrip" aria-label="Versions">${tiles}</div>` : `<div class="empty">No versions to show with these filters.</div>`);
}

// Two links under the strip. "waits for you" counts the same rows as the Waiting on you section (open operator-labelled tickets plus
// the chain read's "waits on you" tickets); with no chain read it still counts the labelled ones and says the holds were not read, and
// with neither it says so. A ticket with no version is not counted (the default read leaves it out), so while one exists the count says
// how many and points at the No version tab, and a 0 never stands alone; the line is short because a longer one wraps the tab row. "Shipped" has no count here (the merged-PR read is the Shift page's), so it names where the number is.
function linksHtml(ch, rows, d, nv) {
  let wait = `<b>waits for you: not read</b> (${esc(noChains(ch))})`;
  if (chainOk(ch) || rows.length) {
    wait = `<b>${rows.length} ${rows.length === 1 ? "waits" : "wait"} for you</b>${rows.length ? ": " + rows.map((x) => esc(x.key)).join(", ") : ""}${chainOk(ch) ? "" : ` (chain holds not read: ${esc(noChains(ch))})`}`;
  }
  const unread = nvOk(nv) ? 0 : d.noVersionCount || 0; // once the No version read is in, those tickets are in the rows above and nothing is left uncounted
  const scope = unread ? ` <span class="ro">(${unread} not counted: <a href="${boardHref({ tab: "nv" })}">no version</a>)</span>` : "";
  return `<div class="rm-links"><div class="rm-link"><span>${wait}${scope}</span><a href="#/shift">open in Shift →</a></div>`
    + `<div class="rm-link"><span><b>Shipped since yesterday</b>: the count is not read here</span><a href="#/report">Morning report →</a></div></div>`;
}

// What waits on the operator, as the roadmap tracker counts it: an open ticket carrying an operator label, plus a ticket the chain read
// marks "waits on you" (a live operator hold). Every version, whichever one is selected; a ticket with no version is on the No version tab.
// One row per key. The chain read can be missing while the labels are not, so the two are read apart.
const OPERATOR_LABELS = ["operator-decision", "operator", "operator-present", "operator-gated"];
// nv = the No version read (GET /api/roadmap?nv=1) once it has arrived: its operator-labelled tickets are rows too, tagged noVersion.
const nvOk = (nv) => !!(nv && nv.state === "ok" && Array.isArray(nv.tickets));
function waitingRows(d, ch, nv) {
  const rows = new Map();
  const add = (list, noVersion) => {
    for (const t of list) {
      const labels = (t.labels || []).filter((l) => OPERATOR_LABELS.includes(l));
      if (labels.length && (t.b === "todo" || t.b === "prog" || t.b === "rev" || t.b === "ci")) rows.set(idOf(t), { key: idOf(t), title: t.t, labels, noVersion });
    }
  };
  add(d.tickets, false);
  if (nvOk(nv)) add(nv.tickets, true);
  if (chainOk(ch)) for (const x of Object.values(ch.tickets)) {
    if (x.state !== "waits on you") continue;
    const own = rows.get(x.key);
    rows.set(x.key, { key: x.key, title: (own && own.title) || x.title || "", labels: own ? own.labels : [], noVersion: !!(own && own.noVersion), chain: (x.chains || []).find((y) => y.state === "waits on you") || (x.chains || [])[0] });
  }
  return [...rows.values()];
}

// The Waiting on you section, one row per waiting ticket: key, title, the operator label or the chain and step it waits at. The key
// opens its chain only where the Chains tab (the running version) holds the ticket. With nothing waiting there is no section: the count
// link beside the tabs says 0 or "not read", and an empty box would push the first card down.
function waitingHtml(rows, tabCh, v, d, ch, nv) {
  if (!rows.length) return "";
  const row = (x) => {
    const href = `#/board?tab=chains${v ? `&amp;v=${esc(encodeURIComponent(v))}` : ""}&amp;at=${esc(encodeURIComponent(x.key))}`;
    // a ticket with no version opens the No version tab, where its card is; any other opens its chain where the Chains tab holds it
    const key = x.noVersion ? `<a href="${boardHref({ tab: "nv" })}">${esc(x.key)}</a>` : chainOk(tabCh) && tabCh.tickets[x.key] ? `<a href="${href}">${esc(x.key)}</a>` : esc(x.key);
    const why = [...x.labels, ...(x.chain ? [`${x.chain.id} ${x.chain.step}/${x.chain.steps}`] : []), ...(x.noVersion ? ["no version"] : [])];
    return `<li>${key} ${esc(x.title || "")}${why.length ? ` <span class="ro">${why.map(esc).join(" · ")}</span>` : ""}</li>`;
  };
  const nvRead = nvOk(nv);
  const notes = [chainOk(ch) ? "" : "chain holds not read", d.noVersionCount && !nvRead ? `${d.noVersionCount} tickets with no version are on the No version tab` : ""].filter(Boolean);
  return section("rm-waiting", "Waiting on you", `${rows.length} ${rows.length === 1 ? "ticket waits" : "tickets wait"} on you, across every version${nvRead ? " and the tickets with no version" : ""}${notes.length ? ` (${notes.join("; ")})` : ""}.`,
    `<ul class="rm-waiting">${rows.map(row).join("")}</ul>`);
}

// The Chains tab is the one coloured tab: the chain icon, the number of chains of the read it opens, and a blocked chip only while a ticket is blocked.
function tabsHtml(d, ui, tab, ch, dr) {
  const ok = chainOk(ch), n = ok ? ch.chains.length : 0, blocked = ok && ch.version ? countsOf(ch, d).blocked : 0;
  const em = { tidy: driftOk(dr) ? `${dr.counts.real} drift ${dr.counts.real === 1 ? "row" : "rows"}` : "", nv: d.noVersionCount ? nTickets(d.noVersionCount) : "" };
  const chains = (on) => `<a class="tab ch" role="tab" aria-selected="${on}" href="${boardHref({ tab: "chains", v: ui.v })}"${ok ? ` aria-label="${esc(`Chains, ${n} ${n === 1 ? "chain" : "chains"}${ch.version ? " in " + ch.version : ""}${blocked ? `, ${nTickets(blocked)} blocked` : ""}`)}"` : ""}>${CLINK}Chains${ok ? ` <span class="cnt">${n}</span>` : ""}${blocked ? ` <span class="blk">⛔ ${nTickets(blocked)} blocked</span>` : ""}</a>`;
  // the No version tab is there while some ticket has no fixVersion (the count is the default read's; the tickets are read when it opens)
  return `<nav class="tabs" role="tablist" aria-label="Board">${TABS.filter(([id]) => id !== "nv" || d.noVersionCount || tab === "nv").map(([id, label]) => id === "chains" ? chains(tab === id) :
    `<a class="tab" role="tab" aria-selected="${tab === id}" href="${boardHref({ tab: id, v: ui.v })}">${esc(label)}${em[id] ? ` <span class="ro">${esc(em[id])}</span>` : ""}</a>`).join("")}</nav>`;
}
// What sits beside the tabs on the Chains tab: who waits for you (every version), the two pages that follow, and the real refresh.
function asideHtml(ch, rows, fresh) {
  const wait = chainOk(ch) || rows.length ? `${nTickets(rows.length)} ${rows.length === 1 ? "waits" : "wait"} for you, any version` : "waits for you: not read";
  return `<div class="aside"><a href="#/shift">${wait} Shift →</a><a href="#/report">Morning report →</a><button class="btn" data-act="refresh-roadmap" aria-label="refresh: read the board again">↻ refresh</button>${fresh ? `<span class="ro rd">${esc(fresh)}</span>` : ""}</div>`;
}

// The Roadmap tab's lane filters. Project is the ticket id's prefix; Theme is the plan's theme (the Sector has its own filter); Only is one
// state of the chain read, or the plan drift. The chain states are listed but disabled while no chain read is there.
const projectOf = (t) => (/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(idOf(t)) ? idOf(t).slice(0, idOf(t).indexOf("-")) : "GitHub");
const projectsOf = (d) => [...new Set(d.tickets.map(projectOf))].sort();
// the ticket's chain row with the state the page shows (a wait on an earlier version is a wait, not "blocked")
const chainState = (t, ch, d) => { const ct = chainOk(ch) ? ch.tickets[idOf(t)] : null; return ct ? { ...ct, state: viewState(ct, ct.state, ch, d).state } : null; };
const ONLY = [["blocked", (t, ct) => !!ct && ct.state === "blocked", true], ["waits on step", (t, ct) => !!ct && /^waits on step/.test(ct.state), true],
  ["waits on you", (t, ct) => !!ct && ct.state === "waits on you", true], ["date-gated", (t, ct) => !!ct && ct.state === "date-gated", true],
  ["drift", (t) => t.drift === 1, false], ["in a chain", (t, ct) => !!ct, true]];
const fsel = (name, label, items, cur) => `<label>${label} <select data-rm-filter="${name}"><option value="">all</option>${items.map((x, i) =>
  `<option value="${i}"${cur === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
function laneFilters(d, ui, ch, sel) {
  const scope = d.tickets.filter((t) => sel < 0 || t.v === sel);
  const only = ONLY.map(([l, f, needs]) => needs && !chainOk(ch) ? `${l} (not read)` : `${l} ${scope.filter((t) => f(t, chainState(t, ch, d))).length}`);
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
    && (!only || (only[2] && !chainOk(ch)) || only[1](t, chainState(t, ch, d)))
    && (!q || idOf(t).toLowerCase().includes(q) || t.t.toLowerCase().includes(q));
};

// ticket key to the checker ticket that explains its drift row, for the tag on a lane card
const knownByKey = (dr) => new Map((dr && dr.known ? dr.known : []).map((r) => [r.key, r.checker]));

// The drain line (the tracker's): a version's open tickets, how many are in a chain and how many are in none. Needs the chain read.
const drainLine = (d, sel, scope, ch) => {
  if (sel < 0 || !chainOk(ch)) return "";
  const open = scope.filter((t) => t.b !== "done" && t.b !== "wont"), inChain = open.filter((t) => ch.tickets[idOf(t)] && ch.tickets[idOf(t)].chains.length).length;
  return `<div class="rm-drain">${esc(d.versions[sel].n)} drain: open ${open.length} · in-chain ${inChain} · in no chain ${open.length - inChain}</div>`;
};
// The sector legend: each Sector of the open tickets in scope with its count, the largest first (the tracker's .seclegend). A ticket with no Sector is not a Sector.
const sectorLegend = (d, scope) => {
  const n = new Map();
  for (const t of scope) if (t.b !== "done" && t.b !== "wont" && d.themes[t.theme] && d.themes[t.theme] !== NO_SECTOR) n.set(d.themes[t.theme], (n.get(d.themes[t.theme]) || 0) + 1);
  const rows = [...n].sort((x, y) => y[1] - x[1] || x[0].localeCompare(y[0]));
  return rows.length ? `<div class="seclegend" aria-label="Sectors of the open tickets">${rows.map(([name, c]) => `<span class="sec">${esc(name)} ${c}</span>`).join(" ")}</div>` : "";
};

function lanesHtml(d, ui, sel, ch, dr, prs) {
  const gh = d.source === "github";
  const writeOn = !!ui.writes && !gh;
  if (sel === -2) return section("rm-lanes", "Roadmap", "", `<div class="empty">${esc(ui.v)}: no such version in the mirror.</div>`);
  const scope = d.tickets.filter((t) => sel < 0 || t.v === sel), shown = scope.filter(passOf(d, ui, ch));
  const what = sel >= 0 ? `${d.versions[sel].n}: ${shown.length} tickets` : `every version: ${shown.length} tickets`;
  const sub = gh ? `${what}. GitHub issues are read-only here: change them on GitHub.${d.truncated ? " Only the newest 1000 issues are read, so older ones are missing." : ""}`
    : `${what}.${writeOn ? " Drag a card to another column to change its status." : ""}`;
  return section("rm-lanes", "Roadmap", sub, shown.length ? drainLine(d, sel, scope, ch) + sectorLegend(d, scope) + boardHtml(d, shown, sel < 0, writeOn, ch, ui.v, { scope, foldDone: true, find: (ui.find || "").trim().toLowerCase(), drawer: ui.drawer, known: knownByKey(dr), prs }) : `<div class="empty">No tickets match.</div>`);
}

// The No version tab: the tickets with no fixVersion, in the same columns. They are not in the default read; ui.nv is GET /api/roadmap?nv=1,
// asked for when this tab opens (null until it arrives).
function nvTab(data, ui, ch, dr, prs) {
  const nv = ui.nv, sub = "Tickets with no fixVersion. Give one a fixVersion in Jira to put it on a version's board.";
  if (!nv) return section("rm-nv", "No version", sub, `<p class="sub" id="status">loading…</p>`);
  if (nv.state !== "ok") return section("rm-nv", "No version", sub, `<div class="nodata">${esc(nv.reason || "the tickets with no version could not be read")}</div>`);
  const writeOn = !!ui.writes && nv.source !== "github";
  const scope = nv.tickets.filter((t) => t.noVersion), shown = scope.filter(passOf(nv, ui, ch, data));
  return section("rm-nv", "No version", `${shown.length} ticket${shown.length === 1 ? "" : "s"}. ${sub}${writeOn ? " Drag a card to another column to change its status." : ""}`,
    shown.length ? boardHtml(nv, shown, false, writeOn, ch, ui.v, { scope, foldDone: true, find: (ui.find || "").trim().toLowerCase(), drawer: ui.drawer, known: knownByKey(dr), prs }) : `<div class="empty">No tickets match.</div>`);
}

// The Chains tab: one read, the selected version's, and every count carries its unit. Reads only.
const live = (a) => a.status === "open" || a.status === "unknown";
const whyLink = (ui, key, on) => { const id = `${key}.${on || ""}`;
  return `<a class="rm-whylink" data-why-open="${esc(id)}" aria-label="Why ${esc(key)} waits${on ? " on " + esc(on) : ""}" href="${boardHref({ tab: "chains", v: ui.v, why: id })}">Why</a>`; };
const stamp = (ts) => String(ts || "").slice(0, 16).replace("T", " ");
// With several Board projects a version is named "<name> (<PROJECT>)"; the chain read has the bare name.
// ponytail: the first project with that name wins, upgrade path: the chain read names its project.
const versionAt = (d, name) => (d.versions || []).findIndex((x) => x.n === name || x.n.startsWith(`${name} (`));
const nTickets = (n) => `${n} ${n === 1 ? "ticket" : "tickets"}`;
const shortKey = (k) => String(k).replace(/^[A-Za-z][A-Za-z0-9]*-/, "");

// The chain read calls a ticket "blocked" whenever an open blocker is outside the read's version. The page keeps that word for a blocker nothing
// lands before the version: one in a later version, in no version, or in a released version and still open. A blocker in an earlier open
// version is only a wait, and it reads "waits on <that version>" with no red.
function blockerKind(l, ch, d) {
  const names = l.onVersions || [], at = versionAt(d, ch.version), idx = names.map((n) => versionAt(d, n));
  if (!names.length) return { kind: "none" };
  const rel = idx.findIndex((i) => i >= 0 && d.versions[i].rel);
  if (rel >= 0) return { kind: "released", v: names[rel] };
  // with no versions snapshot nothing is known to be released, so an earlier open version is not trusted to be unreleased: it stays blocked
  if (at >= 0 && idx.every((i) => i >= 0 && i < at)) return { kind: d.releaseUnknown ? "unsure" : "earlier", v: names[idx.indexOf(Math.max(...idx))] };
  return { kind: "later", v: names[0] };
}
function viewState(t, state, ch, d) {
  if (state !== "blocked") return { state };
  const outs = ((t && t.links) || []).filter((l) => l.status === "open" && l.on && !(l.onVersions || []).includes(ch.version)).map((l) => ({ l, ...blockerKind(l, ch, d) }));
  const hard = outs.find((o) => o.kind !== "earlier");
  if (hard || !outs.length) return { state: "blocked", why: hard };
  const last = outs.reduce((a, b) => (versionAt(d, b.v) > versionAt(d, a.v) ? b : a));
  return { state: `waits on ${last.v}`, why: last };
}
const blockerWords = (o) => (o.kind === "none" ? "in no version" : o.kind === "released" ? `in ${o.v}, a released version, and still open` : o.kind === "earlier" ? `planned in ${o.v}, an earlier version` : o.kind === "unsure" ? `planned in ${o.v}, an earlier version, but no versions snapshot says whether it is released` :`in ${o.v}, a later version`);

// The tickets of one read by state, each ticket once. "waiting" is every wait: on a step, on you, on a date, on an earlier version.
function countsOf(ch, d) {
  const n = { done: 0, flight: 0, launch: 0, wait: 0, blocked: 0, unknown: 0 };
  for (const t of Object.values(ch.tickets)) {
    const s = viewState(t, t.state, ch, d).state;
    if (/^done/.test(s)) n.done++; else if (s === "in flight") n.flight++; else if (s === "can launch") n.launch++; else if (s === "blocked" && ch.version) n.blocked++; else if (s === "unknown") n.unknown++; else n.wait++;
  }
  return n;
}

const rowsOf = (ch, c) => Object.values(ch.tickets).map((t) => [t, (t.chains || []).find((x) => x.id === c.id)]).filter(([, x]) => x)
  .sort((a, b) => a[1].step - b[1].step || String(a[0].key).localeCompare(String(b[0].key), "en", { numeric: true }));
const arrow = (open) => `<svg class="lk${open ? " open" : ""}" viewBox="0 0 30 12" aria-hidden="true"><line x1="1" y1="6" x2="23" y2="6"/><path d="M22 1l7 5-7 5z"/></svg>`;
const doneOf = (c) => c.total > 0 && c.done === c.total;
const progress = (c) => `<progress value="${c.done}" max="${c.total || 1}" aria-hidden="true"></progress>${c.done} of ${nTickets(c.total)} done`;

// The chain's members that sit outside the picked version: the whole read has them, the narrowed read does not.
function outsideOf(ch, c, whole, d) {
  const w = chainOk(whole) ? whole.chains.find((x) => x.id === c.id) : null, mine = new Set(c.members || rowsOf(ch, c).map(([t]) => t.key));
  return ((w && w.members) || []).filter((k) => !mine.has(k)).map((k) => { const t = d.tickets.find((x) => idOf(x) === k); return { key: k, v: t && t.v >= 0 ? d.versions[t.v].n : "" }; });
}
const outChip = (list, version) => (list.length ? `<span class="out" title="${esc(list.map((o) => `${o.key} is in ${o.v || "no version"}`).join("; "))}">+${nTickets(list.length)} outside ${esc(version)}<span class="outn"> · ${list.map((o) => `${esc(o.key)} in ${esc(o.v || "no version")}`).join(", ")}</span></span>` : "");

function chipHtml(ui, ch, d, c, [t, x]) {
  const st = viewState(t, x.state, ch, d).state;
  const cls = st === "done · out of order" ? "oo" : /^done/.test(st) ? "dn" : st === "in flight" ? "fl" : st === "can launch" ? "go" : st === "blocked" ? "bd" : "wt";
  const word = st === "done" ? "" : ` ${st}`;
  const why = /^done/.test(st) ? "" : (t.links || []).filter(live).slice(0, 1).map((l) => " " + whyLink(ui, t.key, l.on)).join("");
  return `<a class="tk ${cls}${ui.at === t.key ? " rm-at" : ""}"${t.chains[0].id === c.id ? ` id="cn-${esc(t.key)}"` : ""} href="${boardHref({ tab: "chains", v: ui.v, at: t.key })}" title="${esc(`${t.key} ${t.title || ""}`.trim())}">`
    + `<span class="gl" aria-hidden="true">${glyph(st)}</span> ${esc(shortKey(t.key))}${esc(word)}</a>${why}`;
}
function railHtml(ui, ch, d, c, rows) {
  const by = new Map();
  for (const r of rows) { if (!by.has(r[1].step)) by.set(r[1].step, []); by.get(r[1].step).push(r); }
  return `<div class="rl">${[...by.keys()].sort((a, b) => a - b).map((s, i) => `${i ? arrow(by.get(s).some(([, x]) => /^waits on step/.test(x.state))) : ""}<div class="st"><small>step ${s} of ${c.steps}</small>${by.get(s).map((r) => chipHtml(ui, ch, d, c, r)).join("")}</div>`).join("")}</div>`;
}
// Every ticket with its full title, one line each: a phone has no hover, so nothing a reader needs lives only in a bubble.
function titlesHtml(ch, d, rows, fold = true) {
  const list = `<ul class="tl">${rows.map(([t, x]) => `<li><b>${esc(t.key)}</b> ${esc(viewState(t, x.state, ch, d).state.replace(" · ", ", "))}, step ${x.step} of ${x.steps}: ${esc(t.title || "")}</li>`).join("")}</ul>`;
  return fold ? `<details class="fold"><summary>Tickets and titles · ${nTickets(rows.length)}</summary>${list}</details>` : list;
}
// What is going on in an open chain: what is running now, what can launch next, and what waits or is blocked (full title, never clamped).
function nowHtml(ch, d, c, rows) {
  const vs = rows.map((r) => ({ t: r[0], ...viewState(r[0], r[1].state, ch, d) }));
  const line = (tag, key, text) => `<span><em>${tag}</em><b>${esc(key)}</b> ${text}</span>`;
  const title = (t) => esc(t.title || "");
  const more = (n) => (n > 1 ? ` <span class="ro">+${n - 1} more</span>` : "");
  const flight = vs.filter((x) => x.state === "in flight"), blocked = vs.filter((x) => x.state === "blocked"), waits = vs.filter((x) => x.why && x.state !== "blocked");
  const out = [];
  if (flight.length) out.push(line("NOW", flight[0].t.key, title(flight[0].t) + more(flight.length)));
  if (c.next && c.next.keys.length) { const t = ch.tickets[c.next.keys[0]]; out.push(line("NEXT", c.next.keys[0], title(t || {}) + more(c.next.keys.length))); }
  for (const x of blocked.slice(0, 2)) out.push(line("BLOCKED", x.t.key, x.why ? `waits on ${esc(x.why.l.on)}, ${esc(blockerWords(x.why))}` : "waits on a ticket this read cannot place"));
  for (const x of waits.slice(0, 2)) out.push(line("WAITS", x.t.key, `waits on ${esc(x.why.v)}: ${esc(x.why.l.on)} is ${esc(blockerWords(x.why))}`));
  if (!out.length) out.push(`<span class="ro">no step can launch yet</span>`);
  return `<div class="now">${out.join("")}</div>`;
}
function acrossHtml(ui, c, version) {
  const as = c.across || [];
  if (!as.length) return "";
  const open = as.filter(live).length;
  const rows = as.map((a) => {
    const where = (a.chains || []).length ? `in ${a.chains.join(", ")}` : `in no chain${version ? ` of ${version}` : ""}`;
    const other = a.dir === "waits-on" ? `waits on <b>${esc(a.on)}</b> <span class="ro">${esc(where)}` : `holds up <b>${esc(a.key)}</b> <span class="ro">${esc(where)}`;
    return `<li><b>${esc(a.dir === "waits-on" ? a.key : a.on)}</b> ${other} · ${esc(a.kind)} · ${esc(a.status)}</span>${live(a) ? " " + whyLink(ui, a.key, a.on) : ""}</li>`;
  });
  return `<details class="fold"><summary>Across other work · ${as.length} ${as.length === 1 ? "link" : "links"}, ${open ? `${open} open` : "all cleared"}</summary><ul class="rm-xlist">${rows.join("")}</ul></details>`;
}
// The change log shows only when the chain has rows.
function logHtml(ui, c) {
  const log = c.log || [];
  if (!log.length) return "";
  const last = log[log.length - 1];
  return `<details class="rm-log fold" data-log="${esc(c.id)}"${(ui.logOpen || []).includes(c.id) ? " open" : ""}><summary>Change log · ${log.length} ${log.length === 1 ? "row" : "rows"} · last ${esc(stamp(last.ts))}: ${esc(last.change)}</summary>`
    + `<div class="scroll"><table class="rm-sync data"><thead><tr><th>When</th><th>Change</th><th>Ticket</th><th>On</th><th>Kind</th><th>Who</th><th>Reason</th></tr></thead><tbody>${log.map((r) =>
      `<tr><td>${esc(stamp(r.ts))}</td><td>${esc(r.change || "")}</td><td>${esc(r.key || r.chain || "")}</td><td>${esc(r.on || "")}</td><td>${esc(r.kind || "")}</td><td>${esc(r.who || "")}</td><td>${esc(r.reason || "")}</td></tr>`).join("")}</tbody></table></div></details>`;
}

function openCard(ui, ch, d, whole, c, rows) {
  const red = rows.some(([t, x]) => viewState(t, x.state, ch, d).state === "blocked");
  return `<article id="rm-chain-${esc(c.id)}" class="cc${red ? " red" : ""}" aria-labelledby="h-rm-chain-${esc(c.id)}"><div class="cct"><div><h3 id="h-rm-chain-${esc(c.id)}">${esc(c.name || c.id)}</h3><span class="cid">${esc(c.id)}</span></div>`
    + `<div class="prog">${outChip(outsideOf(ch, c, whole, d), ch.version || "this read")}${progress(c)}</div></div>${railHtml(ui, ch, d, c, rows)}${nowHtml(ch, d, c, rows)}${acrossHtml(ui, c, ch.version)}${titlesHtml(ch, d, rows)}${logHtml(ui, c)}</article>`;
}
function finCard(ui, ch, d, whole, c, rows) {
  const bad = rows.filter(([, x]) => x.state === "done · out of order").map(([t]) => shortKey(t.key)), held = rows.some(([, x]) => x.state === "done · order held");
  const chk = bad.length ? `<span class="chk bad">⚠ ${bad.slice(0, 2).join(", ")}${bad.length > 2 ? ` +${bad.length - 2}` : ""} out of order</span>` : held ? `<span class="chk">order held</span>` : `<span></span>`;
  return `<details id="rm-chain-${esc(c.id)}" class="fin"${ui.at && rows.some(([t]) => t.key === ui.at) ? " open" : ""}><summary><span class="gl" aria-hidden="true">✓</span><span class="nm">${esc(c.name || c.id)} <span class="cid">${esc(c.id)}</span></span>${chk}`
    + `${outChip(outsideOf(ch, c, whole, d), ch.version || "this read") || "<span></span>"}<span class="prog">${c.done} of ${nTickets(c.total)} done</span></summary>`
    + `<div class="inner">${railHtml(ui, ch, d, c, rows)}${titlesHtml(ch, d, rows, false)}${logHtml(ui, c)}</div></details>`;
}

// The link strip: shown only when a ticket of one chain waits on a ticket of another chain of this read.
function linkStrip(ui, ch) {
  const by = (id) => ch.chains.find((x) => x.id === id);
  const box = (c) => `<span class="lbox">${esc(c.name || c.id)}<span>${c.done} of ${nTickets(c.total)} done</span></span>`;
  return ch.chains.flatMap((c) => (c.across || []).filter((a) => a.dir === "waits-on").map((a) => ({ c, a, from: (a.chains || []).map(by).find((x) => x && x.id !== c.id) })).filter((x) => x.from))
    .map(({ c, a, from }) => `<div class="lmap" aria-label="How the chains link">${box(from)}${arrow(live(a))}${box(c)}<span class="foot">${esc(a.key)} waits on ${esc(a.on)} · ${esc(a.kind)} · ${esc(a.status)}${live(a) ? " " + whyLink(ui, a.key, a.on) : ""}</span></div>`).join("");
}

// The burn-down is folded. Its words are the same facts in text; there is no pace line when the cut date is before the first merge.
function burnHtml(d, ch) {
  const b = ch.burn;
  if (!b) return "";
  const undated = b.undated ? ` ${b.undated} done ${b.undated === 1 ? "ticket has" : "tickets have"} no recorded date and ${b.undated === 1 ? "is" : "are"} left out.` : "";
  const scope = ch.version ? ` in ${ch.version}` : "";
  const fold = (inner) => `<details class="burn"><summary>Burn-down</summary>${inner}</details>`;
  if (!b.points.length) return fold(`<p class="ro rm-burn-words">No merge recorded yet${esc(scope)}: ${nTickets(b.total)} open.${undated}</p>`);
  const v = (d.versions || [])[versionAt(d, ch.version)], cut = v && v.date ? v.date : "";
  const dayMs = (x) => Date.parse(`${x}T00:00:00Z`), first = dayMs(b.points[0].day), lastPt = b.points[b.points.length - 1];
  const paced = !!cut && dayMs(cut) >= first;
  const end = Math.max(dayMs(lastPt.day), paced ? dayMs(cut) : 0), W = 640, H = 110, top = 8;
  const X = (ms) => 10 + (end > first ? (ms - first) / (end - first) : 0) * (W - 20), Y = (n) => top + (1 - n / (b.total || 1)) * (H - top);
  const pts = b.points.map((p) => ({ ...p, x: X(dayMs(p.day)), y: Y(p.open) }));
  const bars = pts.filter((p) => p.merged).map((p) => `<rect class="bar" x="${p.x - 3}" y="${Y(p.merged)}" width="6" height="${H - Y(p.merged)}"/>`).join("");
  const pace = paced ? `<polyline class="rm-burn-pace" points="${pts[0].x},${pts[0].y} ${X(dayMs(cut))},${Y(0)}"/>` : "";
  const merged = b.points.reduce((n, p) => n + p.merged, 0);
  const cutWords = !cut ? (ch.version ? " This version has no date, so there is no pace line." : " No running version, so there is no pace line.")
    : paced ? ` The dashed line is the even pace to the cut on ${cut}.` : ` The cut date, ${cut}, has passed, so no pace line is drawn.`;
  const words = `${lastPt.open} of ${nTickets(b.total)} open${scope}; ${nTickets(merged)} merged since ${b.points[0].day}.${cutWords}${undated}`;
  return fold(`<svg viewBox="0 0 ${W} ${H + 4}" role="img" aria-label="${esc(words)}">${bars}${pace}<polyline class="ol" points="${pts.map((p) => `${p.x},${p.y}`).join(" ")}"/>`
    + `${pts.map((p) => `<circle cx="${p.x}" cy="${p.y}" r="3"><title>${esc(p.day)}: ${p.open} open, ${p.merged} merged</title></circle>`).join("")}</svg><p class="ro rm-burn-words">In words: ${esc(words)}</p>`);
}
function sparkHtml(ch) {
  const b = ch.burn;
  if (!b || !b.points.length) return "";
  const n = b.points.length, last = b.points[n - 1];
  const line = n > 1 ? `<svg viewBox="0 0 110 26" role="img" aria-label="Open tickets across the chains"><polyline points="${b.points.map((p, i) => `${2 + (i / (n - 1)) * 106},${2 + (1 - p.open / (b.total || 1)) * 22}`).join(" ")}"/></svg>` : "";
  return `<div class="spark">${line}${nTickets(last.open)} open</div>`; // no total here: the line above has the chains' ticket total, and the burn-down leaves out undated done tickets
}

function whyHtml(ui, ch, d) {
  if (!ui.why || !chainOk(ch)) return "";
  const dot = ui.why.indexOf("."), key = dot < 0 ? ui.why : ui.why.slice(0, dot), on = dot < 0 ? "" : ui.why.slice(dot + 1);
  const t = ch.tickets[key], same = ((t && t.links) || []).filter((x) => (x.on || "") === on), l = same.find(live) || same[0];
  const close = `<a class="btn rm-why-close" href="${boardHref({ tab: "chains", v: ui.v })}" aria-label="Close why panel">close ✕</a>`;
  const head = (h) => `<div class="rm-dh"><h4 id="h-rm-why">${esc(h)}</h4>${close}</div>`;
  const panel = (b) => `<aside class="drawer rm-why" role="dialog" aria-modal="true" aria-labelledby="h-rm-why">${b}</aside>`;
  if (!l) return panel(head(`Why ${key} waits`) + `<p class="nodata">This link is not in this chain read: it cleared, or the ticket left the version.</p>`);
  const fact = (k, v) => (v ? `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>` : "");
  const show = (k) => (ch.tickets[k] ? `<a href="${boardHref({ tab: "chains", v: ui.v, at: k })}">Show ${esc(k)} in its chain</a>` : "");
  const where = (l.onVersions || []).length ? `in ${l.onVersions.join(", ")}` : "in no version";
  return panel(head(on ? `Why ${key} waits on ${on}` : `Why ${key} waits: ${l.kind}`)
    + `<dl class="rm-facts">${fact("State", viewState(t, t.state, ch, d).state)}${fact("Blocker", on ? on + (ch.tickets[on] ? "" : ` (${where}${ch.version ? `; in no chain of ${ch.version}` : ""})`) : "")}${fact("Kind", l.kind)}${fact("Source", l.source)}${fact("Added", l.added ? stamp(l.added) : "not recorded")}${fact("Status", l.status)}${fact("What clears it", l.clears)}${fact("Reason", l.reason)}${fact("Owner", l.owner)}${fact("Until", l.until)}</dl>`
    + `<p>${[show(key), on ? show(on) : ""].filter(Boolean).join(" · ")}</p><p class="ro">Esc closes this panel.</p>`);
}

// The tab reads the version the tile picked. When it cannot (all versions, or a name the mirror lacks) it reads the running one, and says so in one line.
function notesHtml(ui, ch) {
  if (!ch.version) return "";
  const notes = [ui.v === "all" ? `Chains show one version at a time, so “all versions” shows the running version, ${ch.version}.` : "",
    ch.fellBack ? `${ch.fellBack.asked} is not a version in the mirror, so this tab shows the running version, ${ch.version}.` : "",
    ui.at && !ch.tickets[ui.at] ? `${ui.at} is not in a chain of ${ch.version}.` : ""].filter(Boolean);
  return notes.length ? `<p class="sub rm-covers">${esc(notes.join(" "))}</p>` : "";
}
// The chains of the whole read with no ticket in this version, and the first other version that has one.
function footHtml(ui, ch, d, whole, sel) {
  if (!ch.version || !chainOk(whole)) return "";
  const rest = whole.chains.filter((x) => !ch.chains.some((c) => c.id === x.id));
  if (!rest.length) return "";
  const at = d.tickets.filter((t) => rest.some((x) => (x.members || []).includes(idOf(t))) && t.v >= 0 && t.v !== sel).map((t) => t.v);
  const first = at.length ? Math.min(...at) : -1;
  const there = rest.filter((x) => d.tickets.some((t) => t.v === first && (x.members || []).includes(idOf(t))));
  const pick = at.length ? ` Pick <a href="${boardHref({ tab: "chains", v: d.versions[first].n })}">${esc(d.versions[first].n)}</a> to see ${there.length === rest.length ? (rest.length === 1 ? "it" : "them") : there.map((x) => esc(x.id)).join(", ")}.` : "";
  return `<p class="foot">${rest.length === 1 ? "1 more chain" : `${rest.length} more chains`}, ${rest.map((x) => esc(x.id)).join(", ")}, ${rest.length === 1 ? "has" : "have"} no ticket in ${esc(ch.version)}.${pick}</p>`;
}

function chainsTab(ui, ch, d, whole, sel) {
  if (!chainOk(ch)) return `<section id="rm-chains" class="cp" aria-label="Chains"><div class="nodata">${esc(noChains(ch))}</div></section>`;
  const per = ch.chains.map((c) => ({ c, rows: rowsOf(ch, c) })), open = per.filter((x) => !doneOf(x.c)), fin = per.filter((x) => doneOf(x.c));
  const label = ch.version ? `Chains in ${ch.version}` : "Chains";
  const wrap = (inner) => `<section id="rm-chains" class="cp" aria-label="${esc(label)}">${notesHtml(ui, ch)}${inner}</section>`;
  if (!per.length) return wrap(`<div class="empty">${ch.version ? `No chain has a ticket in ${esc(ch.version)}.` : "No chains in the registry."}</div>${footHtml(ui, ch, d, whole, sel)}`);
  const k = countsOf(ch, d), total = Object.keys(ch.tickets).length;
  const states = [[k.done, "done"], [k.flight, "in flight"], [k.launch, "can launch"], [k.wait, "waiting"]].filter(([n]) => n).map(([n, w]) => `${nTickets(n)} ${w}`).concat(ch.version ? [`${nTickets(k.blocked)} blocked`] : [], k.unknown ? [`${nTickets(k.unknown)} unclear`] : []);
  const noVersion = ch.version ? "" : `<div class="nodata">no running version: the chain read covers every version, so it cannot tell a real block and shows no count of them.</div>`;
  return wrap(`<div class="cph"><div class="big">${per.length} ${per.length === 1 ? "chain" : "chains"}${ch.version ? ` in ${esc(ch.version)}` : ""}<small>${open.length} open · ${fin.length} finished</small></div>`
    + `<div class="tick"><b>${nTickets(total)}</b> in them: ${states.join(" · ")}<div class="legend">A chain is work that has to land in order. Steps run left to right; tickets in one step can run side by side.</div></div>${sparkHtml(ch)}</div>`
    + noVersion + linkStrip(ui, ch)
    + (open.length ? `<div class="gh">Open · ${open.length} ${open.length === 1 ? "chain" : "chains"}</div>${open.map((x) => openCard(ui, ch, d, whole, x.c, x.rows)).join("\n")}` : "")
    + (fin.length ? `<div class="gh">Finished${ch.version ? ` in ${esc(ch.version)}` : ""} · ${fin.length} ${fin.length === 1 ? "chain" : "chains"}</div>${fin.map((x) => finCard(ui, ch, d, whole, x.c, x.rows)).join("\n")}` : "")
    + footHtml(ui, ch, d, whole, sel) + burnHtml(d, ch));
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

// The Board reads itself again once a whole interval has passed since its last read, and only while it is on screen with nothing being typed, dragged,
// opened or already loading: a repaint under any of those would lose the operator's place. The caller (app.js) ticks this on a timer.
export const BOARD_REFRESH_MS = 60_000;
export const boardRefreshDue = (s) => s.page === "board" && !!s.visible && !s.modal && !s.editing && !s.dragging && !s.busy && s.readAt > 0 && s.now - s.readAt >= BOARD_REFRESH_MS;

export const renderBoard =(data, ui, extras) => pg(boardPage(data, ui || {}, extras || {}));
function boardPage(data, ui, extras) {
  const page = pageHeader("Board", "Every version, what each ticket is doing, and what is left");
  if (!data) return page + `<p class="sub" id="status">loading…</p>`;
  if (data.source === "none") return page + noTrackerHtml();
  if (data.state !== "ok") return page + `<div class="nodata">${esc(data.reason || "board unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  // the whole Board reads every version; the Chains tab reads the running one
  const { drift: dr, chains: ch, versionChains: tabCh = ch, prs } = extras;
  const tab = TABS.some(([id]) => id === ui.tab) ? ui.tab : "roadmap";
  const sel = selIndex(data, ui);
  const rows = waitingRows(data, ch, ui.nv);
  const tileSel = tab !== "chains" || !chainOk(tabCh) ? sel : tabCh.version ? versionAt(data, tabCh.version) : -1; // a tile never highlights over totals of another version
  const src = data.source === "github" ? `GitHub issues (${data.mirror.count})` : data.source === "local" ? `the local tracker store (${data.mirror.count} items)`
    : `the Jira mirror (${data.mirror.count} tickets, newest update ${data.mirror.newest || "unknown"})`;
  // plain text: the bar clips it to what fits and keeps the whole line in its bubble
  const readAt = ui.readAt ? ` · read ${new Date(ui.readAt).toLocaleTimeString([], { hour12: false })}, refreshes every ${BOARD_REFRESH_MS / 1000} s` : "";
  const fresh = `read live from ${src}${readAt}${driftOk(dr) && dr.file.exists ? ` · drift: saved run ${dr.file.writtenHm || "unknown"}` : ""}`;
  // the badges, the Only filter and its counts read the picked version's own read when the tab holds it, so a wait on an earlier version reads the same everywhere
  const cardCh = chainOk(tabCh) && tabCh.version && versionAt(data, tabCh.version) === sel ? tabCh : ch;
  const drawer = drawerHtml(data, ui), why = tab === "chains" ? whyHtml(ui, tabCh, data) : "";
  const modal = !!(drawer || why);
  if (tab === "chains") {
    // one read, the picked version's: a slim version row, the tabs and their aside, and the panel. No drift banner, no lane filters, no "all versions".
    const head = `<div class="rm-head bh"${modal ? " inert" : ""}><header class="ph"><h1>Board</h1></header>${stripHtml(data, tileSel, tab, { ...ui, inert: modal }, "", true)}</div>`;
    return [head, `<div class="rm-under"${modal ? " inert" : ""}>`, `<div class="tr">${tabsHtml(data, ui, tab, tabCh, dr)}${asideHtml(ch, rows, fresh)}</div>`, writeNote(ui), chainsTab(ui, tabCh, data, ch, tileSel), `</div>`, drawer, why].join("\n");
  }
  // the No version tab's tickets are in no version, so the picked version's read cannot hold them: it keeps the whole read
  const shownCh = tab === "nv" ? ch : cardCh;
  const body = tab === "tidy" ? tidyTab(data, ui, sel, dr) : tab === "nv" ? nvTab(data, ui, shownCh, dr, prs) : waitingHtml(rows, tabCh, ui.v, data, ch, ui.nv) + lanesHtml(data, ui, sel, cardCh, dr, prs);
  // with a drawer or the Why panel open the board under it is inert: no drag, select, key or click reaches a card until it closes
  return [`<div class="rm-head">${page}${windowBar(data, ui, windowOf(data, ui), modal)}</div>`, `<div class="rm-under"${modal ? " inert" : ""}>`, stripHtml(data, tileSel, tab, ui, driftBanner(dr)), `<div class="rm-tabrow">${tabsHtml(data, ui, tab, tabCh, dr)}${linksHtml(ch, rows, data, ui.nv)}</div>`, barHtml(data, ui, shownCh, tab, sel, fresh), body, `</div>`, drawer, why].join("\n");
}
