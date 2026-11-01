// the Shift page. Pure rendering, no DOM: renderShift(view, ui) → HTML.
// view = GET /api/shift (null while loading). One shift is the whole fleet between cuts, not one chief's run.
// The page only reads: Waiting rows link out to where the action happens, and nothing here acts.
import { esc, pageHeader } from "./render.js";

// a section is the mockup's group panel: the group colour (g-*) on its left edge and on its count
const sec = (id, g, title, count, body) => `<section id="${id}" class="p ${g}" aria-labelledby="h-${id}"><div class="p-h"><h2 id="h-${id}">${esc(title)}${count === null ? "" : ` <b>${count}</b>`}</h2></div>${body}</section>`;
const pg = (html) => `<div class="pg">${html}</div>`; // the mockup main column (app.css .pg)
const day = (iso) => String(iso || "").slice(0, 10);
const clock = (iso) => String(iso || "").slice(11, 16);
const stamp = (iso) => (iso ? `${day(iso)} ${clock(iso)}` : "");
const dur = (min) => (min >= 60 ? `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")} min` : `${min} min`);
const nameLabel = (n) => (n === "night" ? "Night shift" : "Day shift");
const ticketLink = (k) => (k ? `<a href="#/roadmap">${esc(k)}</a>` : "");
// Fleet is not a console route: the app passes the Fleet page's own link (it carries the token), this is the bare page
const fleetOf = (ui) => esc((ui && ui.fleet) || "/agui/");
const prRef = (n, ui) => (n === null || n === undefined ? "" : `<a class="ro" href="${fleetOf(ui)}">#${esc(n)}</a>`);
const none = (what) => `<div class="empty">${esc(what)}</div>`;

function pager(v) {
  const p = v.pager || {};
  const prev = p.prev ? `<a href="#/shift/${encodeURIComponent(p.prev)}">‹ ${esc(prevLabel(v))}</a>` : `<span class="dim">‹</span>`;
  const next = p.next ? `<a href="#/shift${p.next === "now" ? "" : "/" + encodeURIComponent(p.next)}">${p.next === "now" ? "now ›" : "next ›"}</a>` : `<span class="dim">›</span>`;
  return `<nav class="sh-pager" aria-label="Shift pager">${prev} <span class="ro">${v.shift ? esc(stamp(v.shift.opened)) : ""}</span> ${next}</nav>`;
}
const prevLabel = () => "earlier shift";

function header(v) {
  const s = v.shift;
  const closed = s.closed !== null;
  const when = closed ? `${esc(stamp(s.opened))} to ${esc(stamp(s.closed))} (${esc(s.zone)}), ${dur(s.minutes)}, closed by ${s.why === "cut" ? "the clock cut" : "an idle hour"}` : `opened ${esc(stamp(s.opened))} (${esc(s.zone)}), ${dur(s.minutes)} so far; next cut ${clock(s.nextCut)}`;
  return `<div><h2 class="sh-title">${esc(nameLabel(s.name))}${closed ? " · closed" : ""}</h2><p class="sub">${when}</p></div>`;
}

// "1 GO · 2 question": the tile's value line counts its rows by kind, as the mockup does
const tally = (rows, key) => { const m = new Map(); for (const r of rows) m.set(r[key], (m.get(r[key]) || 0) + 1); return [...m].map(([k, n]) => `${n} ${k}`).join(" · "); };
// the shared group tile (app.css .tile): icon, name, the count as the big number, one value line
function tiles(v) {
  const t = (g, ic, label, n, val) => `<div class="tile ${g}${n === 0 ? " zero" : ""}"><span class="ic" aria-hidden="true">${ic}</span><span class="tname">${esc(label)}</span><span class="num">${n}</span><span class="tval">${esc(val)}</span></div>`;
  const closed = v.shift.closed !== null;
  const n = v.shipped.length;
  const shipped = v.mergedUnread ? t("g-ship", "✓", "Shipped", "?", "could not be read") : t("g-ship", "✓", "Shipped", n, `${n} PR${n === 1 ? "" : "s"}`);
  return `<div class="tiles three">${closed ? t("g-chief", "◆", "Chiefs", v.chiefs.length, "") + shipped + t("g-carry", "→", "Carried", v.carried.length, tally(v.carried, "stage"))
    : t("g-wait", "!", "Waiting on you", v.waiting.length, tally(v.waiting, "kind")) + t("g-run", "▶", "Running now", v.running.length, tally(v.running, "stage")) + shipped}</div>`;
}

// The chief chain (mockup v3): one strip per bucket, a segment per chief sized by its span, a blank stretch for each hand-over gap,
// the rest of an open shift ahead. Segment widths are table-cell colspans (whole percent of the shift): the CSP (default-src 'self')
// refuses an inline style="flex:N". A bucket's chain is one <table> row inside the .chain box.
const minutes = (iso) => Date.parse(iso) / 60000;
function chainHtml(chiefs, v, ui) {
  const s = v.shift, closed = s.closed !== null;
  const t0 = minutes(s.opened), end = minutes(closed ? s.closed : s.nextCut), total = Math.max(end - t0, 1);
  const nowM = minutes(new Date(ui && typeof ui.now === "number" ? ui.now : Date.now()).toISOString());
  const units = (m) => Math.max(1, Math.round((100 * m) / total));
  const cells = [], said = [];
  let cursor = t0, cursorIso = s.opened;
  for (const c of [...chiefs].sort((a, b) => minutes(a.span.start) - minutes(b.span.start))) {
    const start = Math.min(Math.max(minutes(c.span.start), t0), end);
    const live = !c.span.end && !closed; // a chief still running at the close ends there, not "now"
    const stop = Math.min(Math.max(c.span.end ? minutes(c.span.end) : live ? nowM : end, start), end);
    if (start - cursor >= total / 200) cells.push(`<td class="cseg gap" colspan="${units(start - cursor)}" title="hand-over gap ${esc(clock(cursorIso))}–${esc(clock(c.span.start))}"></td>`);
    const to = c.span.end ? clock(c.span.end) : live ? "now" : clock(s.closed);
    cells.push(`<td class="cseg${live ? " now" : ""}" colspan="${units(stop - start)}" title="${esc(c.name)}: ${esc(clock(c.span.start))} to ${esc(to)}${c.span.approx ? " (approx: no LIVE bullet, the span starts at the predecessor's end)" : ""}">${c.span.approx ? "≈" : ""}${esc(c.name)}<small>${c.prs.length}</small></td>`);
    said.push(`${c.name} ${clock(c.span.start)} to ${to}, ${c.prs.length} PR${c.prs.length === 1 ? "" : "s"}`);
    if (stop > cursor) { cursor = stop; cursorIso = c.span.end || ""; }
  }
  if (end - cursor >= total / 200) cells.push(closed ? `<td class="cseg gap" colspan="${units(end - cursor)}"></td>` : `<td class="cseg fut" colspan="${units(end - cursor)}">to the ${esc(clock(s.nextCut))} cut</td>`);
  return `<div class="chain" role="img" aria-label="${esc(`${chiefs.length} chief${chiefs.length === 1 ? "" : "s"}: ${said.join("; ")}`)}"><table><tbody><tr>${cells.join("")}</tr></tbody></table></div>`
    + `<div class="chain-axis"><span>${esc(clock(s.opened))}</span><span>${esc(clock(closed ? s.closed : s.nextCut))}</span></div>`;
}

function chiefsHtml(v, ui) {
  if (!v.chiefs.length) return none("No chief has run in this shift.");
  const byBucket = new Map();
  for (const c of v.chiefs) byBucket.set(c.bucket, [...(byBucket.get(c.bucket) || []), c]);
  const strips = [...byBucket].map(([bucket, cs]) => `<p class="sub">${esc(bucket)} bucket · ${cs.length} chief${cs.length === 1 ? "" : "s"}</p>${chainHtml(cs, v, ui)}`).join("");
  const gap = v.gap.length ? `<p class="sub">${v.gap.map((g) => `#${esc(g.pr)} merged in the hand-over between ${esc(g.chiefs[0])} and ${esc(g.chiefs[1])}: credited to both, counted once`).join("; ")}.</p>` : "";
  return `${strips}<p class="foot">The small number under each chief is the PRs merged while it was live. Hover shows its span. A blank stretch is a hand-over gap.</p>${gap}`;
}

function waitingHtml(v, ui) {
  if (!v.waiting.length) return none("Nothing is waiting on you.");
  return `<ul class="sh-list">${v.waiting.map((w) => `<li><span class="pill ${w.kind === "GO" ? "ok" : "warn"}">${esc(w.kind)}</span> ${ticketLink(w.ticket)} ${esc(w.detail || w.title)} ${prRef(w.pr, ui)}${w.chief ? ` <span class="ro">${esc(w.chief)}</span>` : ""}${w.since ? ` <span class="ro">since ${esc(clock(w.since))}</span>` : ""}</li>`).join("")}</ul><p class="sub">Answer these where they live: <a href="${fleetOf(ui)}">Fleet</a>.</p>`;
}

function runningHtml(v, ui) {
  if (!v.running.length) return none("Nothing is running.");
  return `<ul class="sh-list">${v.running.map((r) => `<li><span class="pill">${esc(r.stage)}</span> ${ticketLink(r.ticket)} ${esc(r.title)} ${prRef(r.pr, ui)}</li>`).join("")}</ul>`;
}

const SHOWN = 20; // the longest list shows its newest rows; "show all" opens the rest
function shippedHtml(v, ui) {
  if (v.mergedUnread) return none("The merged PRs could not be read from GitHub. Refresh to try again.");
  if (!v.shipped.length) return none("Nothing merged in this shift.");
  const all = ui && ui.all;
  const rows = all ? v.shipped : v.shipped.slice(0, SHOWN);
  const more = v.shipped.length > SHOWN ? `<p><a href="#/shift${v.shift && v.shift.closed ? "/" + encodeURIComponent(v.shift.id) : ""}${all ? "" : "?all=1"}">${all ? "show fewer" : `show all ${v.shipped.length}`}</a></p>` : "";
  return `<ul class="sh-list">${rows.map((p) => `<li><a class="ro" href="${fleetOf(ui)}">#${esc(p.number)}</a> ${esc(p.title)} <span class="ro">${esc(clock(p.mergedAt))}${p.chief ? ` · ${esc(p.chief)}` : ""}</span></li>`).join("")}</ul>${more}`;
}

function carriedHtml(v, ui) {
  if (!v.carried.length) return none("Nothing carried over.");
  return `<ul class="sh-list">${v.carried.map((c) => `<li>${ticketLink(c.ticket)} ${esc(c.title)} <span class="pill">${esc(c.stage)}</span> ${prRef(c.pr, ui)}</li>`).join("")}</ul>`;
}

const links = (ui, v) => `<p class="sub"><a href="#/shift${v && v.shift && v.shift.closed ? "/" + encodeURIComponent(v.shift.id) : ""}" data-act="refresh-shift">refresh</a> · See also <a href="#/roadmap">Roadmap</a> · <a href="${fleetOf(ui)}">Fleet</a>.</p>`;

export function renderShift(v, ui) {
  const page = pageHeader("Shift", "One shift is the whole fleet between cuts: what is running, what waits on you, what shipped.");
  if (!v) return pg(page + `<p class="sub" id="status">loading…</p>`);
  if (v.reason) return pg(page + `<div class="nodata">${esc(v.reason)}</div>`);
  if (!v.shift) {
    const l = v.last;
    const line = l ? `Last shift: <a href="#/shift/${encodeURIComponent(l.id)}">${esc(nameLabel(l.name))}, ${esc(stamp(l.opened))} to ${esc(stamp(l.closed))}</a>, ${l.chiefs} chief${l.chiefs === 1 ? "" : "s"}${l.shipped === null ? "" : `, ${esc(l.shipped)} shipped`}.` : "No shift has been recorded yet.";
    return pg(page + `<section id="sh-none" class="p"><h2>No shift is open</h2><p class="sub">A shift opens when a chief goes live.</p><p>${line}</p></section>${links(ui)}`);
  }
  const closed = v.shift.closed !== null;
  // mockup v3 order: the shift line and pager, the chiefs panel, the tiles, then one panel per list
  const head = `<div class="sh-head">${header(v)}${pager(v)}</div>`;
  const body = [
    sec("sh-chiefs", "g-chief", closed ? "Chiefs" : "Chiefs this shift", v.chiefs.length, chiefsHtml(v, ui)),
    tiles(v),
    closed ? "" : sec("sh-waiting", "g-wait need", "Waiting on you", v.waiting.length, waitingHtml(v, ui)),
    closed ? "" : sec("sh-running", "g-run", "Running now", v.running.length, runningHtml(v, ui)),
    sec("sh-shipped", "g-ship", closed ? "Shipped" : "Shipped this shift", v.mergedUnread ? null : v.shipped.length, shippedHtml(v, ui)),
    closed ? sec("sh-carried", "g-carry", "Carried to the next shift", v.carried.length, carriedHtml(v, ui)) : "",
  ].join("");
  return pg(page + head + body + links(ui, v));
}
