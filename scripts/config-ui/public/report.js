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

function blockHtml(b) {
  if (b.t === "p") return `<p class="sub">${inline(b.text)}</p>`;
  if (b.t === "ul") return `<ul class="rp-list">${b.items.map((i) => `<li>${inline(i)}</li>`).join("")}</ul>`;
  if (b.t === "code") return `<pre>${esc(b.text)}</pre>`;
  return `<table class="data"><thead><tr>${b.head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${b.rows.map((r) => `<tr>${r.map((c) => `<td>${cell(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
}

const group = (title) => (/shipped|Completed/.test(title) ? "g-ship" : /waits/.test(title) ? "g-wait" : /runs next|In-flight/.test(title) ? "g-run" : /Chiefs/.test(title) ? "g-chief" : "g-carry");
const find = (sections, re) => sections.find((s) => re.test(s.title));
const items = (s) => (s ? s.blocks.filter((b) => b.t === "ul").flatMap((b) => b.items) : []);
const text = (s) => (s ? s.blocks.filter((b) => b.t === "p").map((b) => b.text).join(" ") : "");
const num = (re, str) => { const m = re.exec(str || ""); return m ? m[1] : null; };

// the five tiles come from the sections the generator leads with; a figure the report did not carry reads "?"
function tiles(sections) {
  const shipped = find(sections, /What shipped/), waits = find(sections, /What waits/), spent = find(sections, /What it spent/), next = find(sections, /What runs next/);
  const wi = items(waits);
  const openLine = wi.find((i) => /open PR/i.test(i)) || "";
  const gos = num(/\*\*(\d+)\*\* worker\(s\) awaiting/, wi.join("\n")), qs = num(/\*\*(\d+)\*\* worker question/, wi.join("\n"));
  const waitN = gos === null && qs === null ? "?" : String(Number(gos || 0) + Number(qs || 0));
  const t = (g, ic, label, n, val) => `<div class="tile ${g}${n === "0" ? " zero" : ""}"><span class="ic" aria-hidden="true">${ic}</span><span class="tname">${esc(label)}</span><span class="num">${esc(n)}</span><span class="tval">${esc(val)}</span></div>`;
  const bank = num(/\+([\d.]+)\*\* points/, items(spent).join("\n"));
  return `<div class="tiles">${[
    t("g-ship", "✓", "What shipped", num(/(\d+)\*{0,2} PRs merged/, text(shipped)) || "?", "PRs merged to main"),
    t("g-wait", "!", "Waits on you", waitN, `${gos || 0} GO · ${qs || 0} question`),
    t("g-wait", "⇄", "Open PRs", num(/\*\*(\d+)\*\* open PR/, openLine) || "?", "to review or merge"),
    t("g-carry", "$", "What it spent", bank || "n/a", bank ? "weekly bank points" : "no figure in this report"),
    t("g-run", "▶", "What runs next", num(/\*\*(\d+)\*\* In-Progress/, items(next).join("\n")) || "n/a", "tickets in flight"),
  ].join("")}</div>`;
}

function selector(list, day, ui) {
  const link = (d, label) => `<a class="chip" href="#/report?day=${encodeURIComponent(d)}" aria-pressed="${d === day}"${d === day ? ' aria-current="page"' : ""}>${esc(label)}</a>`;
  const hasToday = list.days.includes(list.today);
  const shown = list.days.slice(0, 7), older = list.days.slice(7);
  const so = !hasToday && list.today ? link(list.today, "so far") + " " : "";
  const more = older.length ? ` <details class="rp-more"><summary>earlier ▾</summary>${older.map((d) => link(d, shortDay(d))).join(" ")}</details>` : "";
  return `<nav class="rp-days" aria-label="Report day">${so}${shown.map((d) => link(d, shortDay(d))).join(" ")}${more}</nav>`;
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
  const bar = stale(list) + selector(list, day, ui);
  if (!view) return pg(`${head}${bar}${none("loading…")}`);
  if (view.state === "none") {
    if (!list.days.length && day === list.today) return pg(`${head}${bar}${none("No report has been made yet. The morning-report cadence writes one a day.")}${soFarView(list.soFar, day, ui)}`);
    if (day === list.today) return pg(`${head}${bar}${soFarView(list.soFar, day, ui)}`);
    return pg(`${head}${bar}<div class="empty" id="no-report"><b>No report was made for ${esc(longDay(day))}</b><br>Nothing was written that day: the cadence did not run, or no shift closed. A later report does not fill it in.</div>`);
  }
  const barText = view.bar.length ? `<div class="sub rp-bar">${view.bar.map((l) => `<div>${inline(l)}</div>`).join("")}</div>` : "";
  const notes = view.notes.length ? `<div class="nodata" role="status" id="degraded"><b>Some inputs were not available for this report:</b><ul class="rp-list">${view.notes.map((n) => `<li>${inline(n)}</li>`).join("")}</ul></div>` : "";
  const panels = view.sections.map((s, i) => {
    const waits = /What waits/.test(s.title);
    const blocks = waits ? s.blocks.map((b) => (b.t === "ul" ? { ...b, items: b.items.filter((x) => !/open PR/i.test(x)) } : b)) : s.blocks;
    const open = waits ? items(s).filter((x) => /open PR/i.test(x)) : [];
    const own = open.length ? sec(`open-prs-${i}`, "g-wait", "Open PRs", `<ul class="rp-list">${open.map((x) => `<li>${inline(x)}</li>`).join("")}</ul>`) : "";
    return sec(`s-${i}`, group(s.title), s.title, blocks.map(blockHtml).join("") || none("nothing in this section")) + own;
  }).join("");
  return pg(`${head}${bar}${barText}${notes}${tiles(view.sections)}${panels}`);
}
