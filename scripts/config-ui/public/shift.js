// the Shift page. Pure rendering, no DOM: renderShift(view, ui) → HTML.
// view = GET /api/shift (null while loading). One shift is the whole fleet between cuts, not one chief's run.
// The page only reads: Waiting rows link out to where the action happens, and nothing here acts.
import { esc } from "./render.js";

const pageHeader = (title, sub) => `<header class="ph"><h1>${esc(title)}</h1><p>${esc(sub)}</p></header>`;
const sec = (id, title, count, body) => `<section id="${id}" class="box sh-sec" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}${count === null ? "" : ` <span class="ro">${count}</span>`}</h2>${body}</section>`;
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
  const when = closed ? `${stamp(s.opened)} to ${stamp(s.closed)} (${esc(s.zone)}), ${dur(s.minutes)}, closed by ${s.why === "cut" ? "the clock cut" : "an idle hour"}` : `opened ${stamp(s.opened)} (${esc(s.zone)}), ${dur(s.minutes)} so far; next cut ${clock(s.nextCut)}`;
  return `<h2 class="sh-title">${esc(nameLabel(s.name))}${closed ? " · closed" : ""}</h2><p class="sub">${when}</p>`;
}

function tiles(v) {
  const t = (label, n) => `<div class="card sh-tile"><b>${n}</b><span>${esc(label)}</span></div>`;
  const closed = v.shift.closed !== null;
  return `<div class="sh-tiles">${closed ? t("Chiefs", v.chiefs.length) + t("Shipped", v.shipped.length) + t("Carried", v.carried.length) : t("Waiting on you", v.waiting.length) + t("Running now", v.running.length) + t("Shipped", v.shipped.length)}</div>`;
}

function chiefsHtml(v) {
  const closedAt = v.shift && v.shift.closed; // a chief still running at the close ends there, not "now"
  if (!v.chiefs.length) return none("No chief has run in this shift.");
  const byBucket = new Map();
  for (const c of v.chiefs) byBucket.set(c.bucket, [...(byBucket.get(c.bucket) || []), c]);
  const rows = v.chiefs.map((c) => `<tr><td>${esc(c.name)}</td><td>${esc(c.bucket)}</td><td>${esc(clock(c.span.start))} to ${c.span.end ? esc(clock(c.span.end)) : closedAt ? esc(clock(closedAt)) : "now"}${c.span.approx ? ` <span class="ro" title="no LIVE bullet: the span starts at the predecessor's end">approx</span>` : ""}</td><td>${c.prs.length} PR${c.prs.length === 1 ? "" : "s"}</td></tr>`).join("");
  const gap = v.gap.length ? `<p class="sub">${v.gap.map((g) => `#${esc(g.pr)} merged in the hand-over between ${esc(g.chiefs[0])} and ${esc(g.chiefs[1])}: credited to both, counted once`).join("; ")}.</p>` : "";
  return `<p class="sub">${byBucket.size} bucket${byBucket.size === 1 ? "" : "s"}: ${[...byBucket.keys()].map(esc).join(", ")}</p><table class="data"><thead><tr><th>Chief</th><th>Bucket</th><th>Span</th><th>PR credit</th></tr></thead><tbody>${rows}</tbody></table>${gap}`;
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

const links = (ui) => `<p class="sub"><a href="#/shift" data-act="refresh-shift">refresh</a> · See also <a href="#/morning-report">Morning report</a> · <a href="#/roadmap">Roadmap</a> · <a href="${fleetOf(ui)}">Fleet</a>.</p>`;

export function renderShift(v, ui) {
  const page = pageHeader("Shift", "One shift is the whole fleet between cuts: what is running, what waits on you, what shipped.");
  if (!v) return page + `<p class="sub" id="status">loading…</p>`;
  if (v.reason) return page + `<div class="nodata">${esc(v.reason)}</div>`;
  if (!v.shift) {
    const l = v.last;
    const line = l ? `Last shift: <a href="#/shift/${encodeURIComponent(l.id)}">${esc(nameLabel(l.name))}, ${esc(stamp(l.opened))} to ${esc(stamp(l.closed))}</a>, ${l.chiefs} chief${l.chiefs === 1 ? "" : "s"}${l.shipped === null ? "" : `, ${l.shipped} shipped`}.` : "No shift has been recorded yet.";
    return page + `<section id="sh-none" class="box"><h2>No shift is open</h2><p class="sub">A shift opens when a chief goes live.</p><p>${line}</p></section>${links(ui)}`;
  }
  const closed = v.shift.closed !== null;
  const head = `<section class="box sh-head">${header(v)}${pager(v)}${tiles(v)}</section>`;
  const body = [
    sec("sh-chiefs", closed ? "Chiefs" : "Chiefs this shift", v.chiefs.length, chiefsHtml(v)),
    closed ? "" : sec("sh-waiting", "Waiting on you", v.waiting.length, waitingHtml(v, ui)),
    closed ? "" : sec("sh-running", "Running now", v.running.length, runningHtml(v, ui)),
    sec("sh-shipped", closed ? "Shipped" : "Shipped this shift", v.shipped.length, shippedHtml(v, ui)),
    closed ? sec("sh-carried", "Carried to the next shift", v.carried.length, carriedHtml(v, ui)) : "",
  ].join("");
  return page + head + body + links(ui);
}
