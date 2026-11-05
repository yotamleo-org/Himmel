// the Morning report page. Pure rendering, no DOM: renderReport(list, view, ui) → HTML.
// list = GET /api/reports ({ days, newest, ageHours, today, soFar }), view = GET /api/report?day= (parsed blocks), null while loading.
// ui = { day, shiftHref }: the day the route asks for. The page only reads the dated files the generator wrote; "so far"
// is today's closed shifts read live from shifts.jsonl: it is not a report and nothing here saves it.
import { esc, pageHeader } from "./render.js";

const sec = (id, g, title, body) => `<section id="${id}" class="p ${g}" aria-labelledby="h-${id}"><div class="p-h"><h2 id="h-${id}">${esc(title)}</h2></div>${body}</section>`;
const pg = (html) => `<div class="pg">${html}</div>`;
const none = (what) => `<div class="empty">${esc(what)}</div>`;

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const parts = (day) => { const d = new Date(`${day}T12:00:00Z`); return { wd: DAYS[d.getUTCDay()], d: d.getUTCDate(), mo: MONTHS[d.getUTCMonth()] }; };
const longDay = (day) => { const p = parts(day); return `${p.wd} ${p.d} ${p.mo}`; };
const shortDay = (day) => { const p = parts(day); return `${p.wd.slice(0, 3)} ${p.d} ${p.mo.slice(0, 3)}`; };

// the generator's inline dialect: **bold** and `code`, nothing else; everything is escaped first
const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`(.+?)`/g, "<code>$1</code>");
const cell = (s) => (/^not available/.test(s) ? `<span class="dim">${esc(s)}</span>` : inline(s));

// The Chiefs table gains a Length column after Span, computed from the span ("HH:MM to HH:MM", or "to open"); the generator writes no length.
const minutes = (hm) => { const m = /^(\d\d):(\d\d)$/.exec(hm || ""); return m ? Number(m[1]) * 60 + Number(m[2]) : null; };
const lengthOf = (span) => {
  const m = /^(\d\d:\d\d) to (\d\d:\d\d|open)/.exec(span || "");
  if (!m) return "";
  if (m[2] === "open") return "open";
  return `${(minutes(m[2]) - minutes(m[1]) + 1440) % 1440} min`;
};
const withLength = (b) => (b.head[1] === "Span" ? { ...b, head: [b.head[0], b.head[1], "Length", ...b.head.slice(2)], rows: b.rows.map((r) => [r[0], r[1], lengthOf(r[1]), ...r.slice(2)]) } : b);

function blockHtml(b, o = {}) {
  if (b.t === "table" && o.chiefs) b = withLength(b);
  if (b.t === "p") return `<p class="sub">${inline(b.text)}</p>`;
  if (b.t === "ul") return `<ul class="rp-list">${b.items.map((i) => `<li>${inline(i)}</li>`).join("")}</ul>`;
  if (b.t === "code") return `<pre>${esc(b.text)}</pre>`;
  const table = `<table class="data${o.wide ? " wide" : ""}"><thead><tr>${b.head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${b.rows.map((r) => `<tr>${r.map((c) => `<td>${cell(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
  return o.wide ? `<div class="tw">${table}</div>` : table;
}

const group = (title) => (/shipped|Completed/.test(title) ? "g-ship" : /waits/.test(title) ? "g-wait" : /runs next|In-flight/.test(title) ? "g-run" : /Chiefs/.test(title) ? "g-chief" : "g-carry");
const find = (sections, re) => sections.find((s) => re.test(s.title));
const items = (s) => (s ? s.blocks.filter((b) => b.t === "ul").flatMap((b) => b.items) : []);
const text = (s) => (s ? s.blocks.filter((b) => b.t === "p").map((b) => b.text).join(" ") : "");
const num = (re, str) => { const m = re.exec(str || ""); return m ? m[1] : null; };

// the five tiles come from the sections the generator leads with; a figure the report did not carry reads "?"
// ponytail: the page re-parses the briefing's markdown for tile figures; ceiling = a heading reword breaks a tile to "?"; upgrade path = the briefing writes a small JSON front-matter of its counts that the page reads.
function tiles(sections) {
  const shipped = find(sections, /What shipped/), waits = find(sections, /What waits/), spent = find(sections, /What it spent/), next = find(sections, /What runs next/);
  const wi = items(waits);
  const openLine = wi.find((i) => /open PR/i.test(i)) || "";
  const gos = num(/\*\*(\d+)\*\* worker\(s\) awaiting/, wi.join("\n")), qs = num(/\*\*(\d+)\*\* worker question/, wi.join("\n"));
  const waitN = gos === null && qs === null ? "?" : String(Number(gos || 0) + Number(qs || 0));
  const t = (g, ic, label, n, val) => `<div class="tile ${g}${n === "0" ? " zero" : ""}"><span class="ic" aria-hidden="true">${ic}</span><span class="tname">${esc(label)}</span><span class="num">${esc(n)}</span><span class="tval">${esc(val)}</span></div>`;
  const bank = num(/\+([\d.]+)\*\* points/, items(spent).join("\n"));
  return `<div class="tiles t5">${[
    t("g-ship", "✓", "What shipped", num(/(\d+)\*{0,2} PRs merged/, text(shipped)) || "?", "PRs merged to main"),
    t("g-wait", "!", "Waits on you", waitN, `${gos || 0} GO · ${qs || 0} question`),
    t("g-wait", "⇄", "Open PRs", num(/\*\*(\d+)\*\* open PR/, openLine) || "?", "to review or merge"),
    t("g-carry", "$", "What it spent", bank || "n/a", bank ? "weekly bank points" : "no figure in this report"),
    t("g-run", "▶", "What runs next", num(/\*\*(\d+)\*\* In-Progress/, items(next).join("\n")) || "n/a", "tickets in flight"),
  ].join("")}</div>`;
}

// The shift timeline and the chief chart (mockup v7.1): the report day cut into 5-minute cells, each segment a table cell whose colspan is its
// width (the CSP refuses an inline style). Read from the Spend per shift table (a shift's dated span) and the Chiefs table (a chief's HH:MM span,
// placed on the first such clock time after its shift opened).
// ponytail: the spans carry no year, so a shift is dated in the report day's year; ceiling = a Dec/Jan report places a shift a year out and the chart skips it; upgrade path = the generator writes ISO spans.
const UNIT = 5, CELLS = 1440 / UNIT;
const tableIn = (sections, re) => { const s = find(sections, re); return s ? s.blocks.find((b) => b.t === "table") : null; };
const stamp = (day, md, hm) => {
  const m = /^(\d\d)-(\d\d)$/.exec(md), t = minutes(hm);
  if (!m || t === null) return null;
  return (Date.UTC(Number(day.slice(0, 4)), Number(m[1]) - 1, Number(m[2])) - Date.parse(`${day}T00:00:00Z`)) / 60000 + t;
};
const lane = (label, segs, aria) => {
  const cells = [];
  let at = 0;
  for (const g of segs.slice().sort((a, b) => a.from - b.from)) {
    const from = Math.max(g.from, at);
    if (g.to <= from) continue;
    if (from > at) cells.push(`<td class="cseg gap" colspan="${from - at}"></td>`);
    cells.push(`<td class="cseg" colspan="${g.to - from}" title="${esc(g.title)}">${esc(g.text)}</td>`);
    at = g.to;
  }
  if (at < CELLS) cells.push(`<td class="cseg gap" colspan="${CELLS - at}"></td>`);
  return `<div class="rp-tlr"><span class="rp-tll">${esc(label)}</span><div class="chain" role="img" aria-label="${esc(aria)}"><table><tbody><tr>${cells.join("")}</tr></tbody></table></div></div>`;
};
const cellOf = (m) => Math.round(Math.min(Math.max(m, 0), 1440) / UNIT);
function timeline(sections, day) {
  const sp = tableIn(sections, /Spend per shift/), ch = tableIn(sections, /Chiefs/);
  if (!sp) return "";
  const shifts = [];
  for (const r of sp.rows) {
    const m = /^(\d\d-\d\d) (\d\d:\d\d) to (\d\d-\d\d) (\d\d:\d\d)$/.exec(r[1] || "");
    const o = m ? stamp(day, m[1], m[2]) : null, c = m ? stamp(day, m[3], m[4]) : null;
    if (o === null || c === null || c <= 0 || o >= 1440) continue;
    shifts.push({ key: r[0], name: r[0].split(" ")[0], span: r[1], open: o, close: c });
  }
  if (!shifts.length) return "";
  const bands = shifts.map((s) => ({ from: cellOf(s.open), to: cellOf(s.close), text: `${s.open < 0 ? "◂ " : ""}${s.name}${s.close > 1440 ? " ▸" : ""}`, title: `${s.name}: ${s.span}` }));
  const seen = new Set(), chiefs = [];
  for (const r of ch ? ch.rows : []) {
    const m = /^(\d\d:\d\d) to (\d\d:\d\d|open)/.exec(r[1] || ""), sh = shifts.find((s) => s.key === r[3]);
    if (!m || !sh || seen.has(r[0])) continue;
    seen.add(r[0]);
    const a = minutes(m[1]) + 1440 * Math.ceil((sh.open - minutes(m[1])) / 1440); // the first such clock time at or after the shift opened, which may be the evening before the day
    const z = m[2] === "open" ? sh.close : a + ((minutes(m[2]) - minutes(m[1]) + 1440) % 1440);
    if (a >= 1440 || z <= 0) continue;
    const from = cellOf(a);
    chiefs.push({ from, to: Math.max(cellOf(z), from + 1), text: r[0], title: `${r[0]}: ${r[1]}` });
  }
  const say = (n, what, names) => `${n} ${what}${n === 1 ? "" : "s"}: ${names.join("; ")}`;
  const axis = `<div class="rp-tlr"><span class="rp-tll"></span><div class="chain-axis"><span>00</span><span>06</span><span>12</span><span>18</span><span>24</span></div></div>`;
  return `<div class="rp-tl" role="group" aria-label="${esc(`Shifts and chiefs on ${longDay(day)}`)}">${lane("shifts", bands, say(shifts.length, "shift", shifts.map((s) => `${s.name} ${s.span}`)))}${chiefs.length ? lane("chiefs", chiefs, say(chiefs.length, "chief", chiefs.map((c) => c.title))) : ""}${axis}</div>`;
}

function selector(list, day, ui) {
  const link = (d, label) => `<a class="chip" href="#/report?day=${encodeURIComponent(d)}" aria-pressed="${d === day}"${d === day ? ' aria-current="page"' : ""}>${esc(label)}</a>`;
  const hasToday = list.days.includes(list.today);
  const shown = list.days.slice(0, 7), older = list.days.slice(7);
  const so = !hasToday && list.today ? link(list.today, "so far") + " " : "";
  const more = older.length ? ` <details class="rp-more"><summary>earlier ▾</summary>${older.map((d) => link(d, shortDay(d))).join(" ")}</details>` : "";
  return `<nav class="rp-days" aria-label="Report day">${so}${shown.map((d) => link(d, shortDay(d))).join(" ")}${more}</nav>`;
}

// the page bar's controls (app.js pageBar): the day picker and a refresh that reads the list and the day again; empty while loading or on an error
export function reportBar(list, view, ui) {
  if (!list || list.error || list.reason) return "";
  const day = (view && view.day) || ui.day || list.newest || list.today;
  return `${selector(list, day, ui)}<button type="button" class="chip" data-act="report-refresh">Refresh</button>`;
}

function stale(list) {
  if (list.newest === null || list.ageHours === null || list.ageHours < 36) return "";
  return `<div class="nodata" role="status">No report since ${esc(list.newest)}. The morning-report cadence has not run (doctor: WARN).</div>`;
}

function soFarView(sf, day, ui) {
  const rows = sf.shifts.map((s) => `<tr><td><a href="${esc(ui.shiftHref)}/${encodeURIComponent(s.id)}">${esc(s.name)}</a></td><td>${esc(s.opened.slice(0, 16).replace("T", " "))} to ${esc(s.closed.slice(0, 16).replace("T", " "))}</td><td>${esc(s.why === "cut" ? "clock cut" : "idle hour")}</td><td>${s.chiefs}</td><td>${s.prs}</td></tr>`).join("");
  const body = sf.shifts.length
    ? `<table class="data"><thead><tr><th>Shift</th><th>Span</th><th>Closed by</th><th>Chiefs</th><th>PRs</th></tr></thead><tbody>${rows}</tbody></table>`
    : none("No shift has closed today yet.");
  return `<p class="sub">So far today (${esc(longDay(day))}): the shifts closed since midnight, read live from the shift record. This is not a report and is never saved; the report for today is made by the next morning run.</p>${sec("sofar", "g-chief", "Shifts closed so far", body)}`;
}

export function renderReport(list, view, ui) {
  const head = pageHeader("Morning report", "What the fleet shipped, what it spent and what waits on you, one report per day.");
  if (!list) return pg(`${head}${none("loading…")}`);
  if (list.error) return pg(`${head}<div class="nodata">${esc(list.error)}</div>`);
  if (list.reason) return pg(`${head}<div class="nodata">${esc(list.reason)}</div>`);
  const day = (view && view.day) || ui.day || list.newest || list.today;
  const bar = stale(list);
  if (!view) return pg(`${head}${bar}${none("loading…")}`);
  if (view.state === "none") {
    if (!list.days.length && day === list.today) return pg(`${head}${bar}${none("No report has been made yet. The morning-report cadence writes one a day.")}${soFarView(list.soFar, day, ui)}`);
    if (day === list.today) return pg(`${head}${bar}${soFarView(list.soFar, day, ui)}`);
    return pg(`${head}${bar}<div class="empty" id="no-report"><b>No report was made for ${esc(longDay(day))}</b><br>Nothing was written that day: the cadence did not run, or no shift closed. A later report does not fill it in.</div>`);
  }
  const barText = view.bar.length ? `<div class="sub rp-bar">${view.bar.map((l) => `<div>${inline(l)}</div>`).join("")}</div>` : "";
  const notes = view.notes.length ? `<div class="nodata" role="status" id="degraded"><b>Some inputs were not available for this report:</b><ul class="rp-list">${view.notes.map((n) => `<li>${inline(n)}</li>`).join("")}</ul></div>` : "";
  // the TL;DR is a strip under the tiles (mockup v7.1), not a group panel in the section order
  const tl = find(view.sections, /^TL;DR/);
  const strip = tl ? `<section id="tldr" class="sec rp-tldr" aria-labelledby="h-tldr"><h2 id="h-tldr">${esc(tl.title)}</h2>${tl.blocks.map((b) => blockHtml(b)).join("") || none("nothing in this section")}</section>` : "";
  const panels = view.sections.map((s, i) => {
    if (s === tl) return "";
    const waits = /What waits/.test(s.title);
    const spend = /Spend per shift/.test(s.title), chiefs = /Chiefs/.test(s.title);
    const blocks = waits ? s.blocks.map((b) => (b.t === "ul" ? { ...b, items: b.items.filter((x) => !/open PR/i.test(x)) } : b)) : s.blocks;
    const open = waits ? items(s).filter((x) => /open PR/i.test(x)) : [];
    const own = open.length ? sec(`open-prs-${i}`, "g-wait", "Open PRs", `<ul class="rp-list">${open.map((x) => `<li>${inline(x)}</li>`).join("")}</ul>`) : "";
    const body = (spend ? timeline(view.sections, view.day) : "") + blocks.map((b) => blockHtml(b, { wide: spend || chiefs, chiefs })).join("");
    return sec(`s-${i}`, group(s.title) + (/Failure review/.test(s.title) ? " fr" : ""), s.title, body || none("nothing in this section")) + own;
  }).join("");
  return pg(`${head}${bar}${barText}${notes}${tiles(view.sections)}${strip}${panels}`);
}
