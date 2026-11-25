// the Cost page. Pure rendering: renderCost(model, view) → HTML; mountCost(root, model) draws it and opens or closes a phase row.
// model = cost.ts's buildCostModel (null while loading), view = { open: [phase ids] }. Every figure comes from the model, which
// reads the phase-cost rows; nothing is added up here. A part no record splits says "not countable yet" and shows no number of its own.
import { esc } from "./render.js";

const MARK = {
  counted: ["counted", "read from a ledger or the session's own usage"],
  derived: ["derived", "a counted total split by phase with the last-tool rule"],
  unpriced: ["no price yet", "a call's model has no price row; its dollars are not counted"],
  nocount: ["not countable yet", "no record splits it"],
  inphase: ["in the phase table", "T3's Claude sessions write transcripts the phase table already counts; tokens shown, dollars not added twice"],
};
const mark = (m) => `<span class="mk ${esc(m)}" title="${esc(MARK[m][1])}">${esc(MARK[m][0])}</span>`;
const usd = (n) => (n == null ? "—" : `$${n.toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 })}`);
const pct = (n) => (n == null ? "—" : `${n.toFixed(1)}%`);
const bar = (w) => `<span class="bar" style="width:${Math.max(0, Math.min(100, Number(w) || 0)).toFixed(1)}%"></span>`;

const partRow = (p) =>
  `<tr class="part" id="${esc(p.id)}"><td>${esc(p.name)}</td><td class="n">${usd(p.usd)}</td><td class="n">${pct(p.share)}</td>` +
  `<td class="barc">${bar(p.share)}</td><td>${mark(p.mark)}</td><td class="mute">${esc(p.note)}</td></tr>`;

function phaseBody(p, top, open) {
  const ids = p.parts.map((x) => x.id).join(" ");
  return `<tbody id="ph-${esc(p.id)}"${open ? ' class="open"' : ""}><tr class="pr0"><td>` +
    `<button type="button" class="dr" data-phase="${esc(p.id)}" aria-expanded="${open}" aria-controls="${esc(ids)}">` +
    `<svg class="chev" viewBox="0 0 12 12" aria-hidden="true" focusable="false"><path d="M4.5 2.5 8 6l-3.5 3.5"/></svg>${esc(p.name)}</button></td>` +
    `<td class="n">${usd(p.usd)}</td><td class="n">${pct(p.share)}</td><td class="barc">${bar(top ? ((p.share || 0) / top) * 100 : 0)}</td>` +
    `<td>${mark(p.mark)}</td><td class="mute">${esc(p.made)}</td></tr>${open ? p.parts.map(partRow).join("") : ""}</tbody>`;
}

const basisNote = (m) => `<p class="sub basis">${esc(m.basis)} ${esc(m.coverageNote)}.</p>`;

const tok = (n) => Number(n || 0).toLocaleString("en-US");
const t3Row = (l) => {
  const t = (n) => (l.mark === "nocount" ? "—" : tok(n));
  return `<tr><td>${esc(l.name)}</td><td class="n">${usd(l.usd)}</td><td class="n">${pct(l.share)}</td><td class="n">${tok(l.turns)}</td><td class="n">${t(l.in)}</td>` +
    `<td class="n">${t(l.out)}</td><td class="n">${t(l.cache_read)}</td><td class="n">${t(l.cache_write)}</td><td>${mark(l.mark)}</td><td class="mute">${esc(l.note)}</td></tr>`;
};
const t3Table = (label, first, lines) =>
  `<h3>${esc(label)}</h3><div class="tw"><table class="tbl" aria-label="T3 Code usage ${esc(label.toLowerCase())}"><thead><tr><th>${esc(first)}</th><th class="n">$</th>` +
  `<th class="n">share</th><th class="n">turns</th><th class="n">input</th><th class="n">output</th><th class="n">cache read</th><th class="n">cache write</th><th>how</th>` +
  `<th class="hs">made of</th></tr></thead><tbody>${lines.map(t3Row).join("")}</tbody></table></div>`;

function renderT3(t3) {
  if (!t3 || t3.state === "nostore") return "";
  const head = `<div class="card-h"><h2>T3 Code · ${esc(t3.day || "no day")}</h2>`;
  if (t3.state !== "ok")
    return `<section class="card t3">${head}</div><p class="sub">no T3 Code usage for this day</p><p class="sub basis">${esc(t3.basis)}</p></section>`;
  const more = t3.moreThreads ? `<p class="foot">${esc(tok(t3.moreThreads))} smaller threads are not listed.</p>` : "";
  return `<section class="card t3">${head}<span class="big">${usd(t3.usd)} ${mark(t3.mark)}</span></div>` +
    `<p class="sub">${esc(tok(t3.turns))} turns</p><p class="sub basis">${esc(t3.basis)}</p>` +
    t3Table("By provider", "Provider", t3.providers) + t3Table("By thread", "Thread", t3.threads) + more + `</section>`;
}

export function renderCost(model, view = {}) {
  return renderCostPhases(model, view) + (model ? renderT3(model.t3) : "");
}

function renderCostPhases(model, view) {
  if (!model) return view.err ? "" : `<section class="card"><div class="card-h"><h2>Cost</h2></div><p class="sub">loading…</p></section>`;
  if (model.state === "nostore")
    return `<section class="card"><div class="card-h"><h2>Cost</h2></div><p class="sub">the usage store has not been built yet: run ` +
      `<code>bash scripts/usage/usage-compute.sh</code>, and again until it says no window remains</p>${basisNote(model)}</section>`;
  if (model.state !== "ok")
    return `<section class="card"><div class="card-h"><h2>Cost</h2></div><p class="sub">no data yet</p>${basisNote(model)}</section>`;
  const open = new Set(view.open || []);
  const top = Math.max(0, ...model.phases.map((p) => p.share || 0));
  const models = model.models.map((m) => `${esc(m.model)} ${usd(m.usd)}`).join(" · ");
  return `<section class="card"><div class="card-h"><h2>Cost by phase · ${esc(model.day)}</h2>` +
    `<span class="big">${usd(model.usd)} ${mark(model.mark)}</span></div>` +
    `<p class="sub">${esc(model.calls.toLocaleString("en-US"))} calls · ${models}</p>${basisNote(model)}` +
    `<div class="tw"><table class="tbl ph" aria-label="Cost by phase, one day"><thead><tr><th>Phase</th><th class="n">$</th><th class="n">share</th>` +
    `<th class="barc"></th><th>how</th><th class="hs">made of</th></tr></thead>` +
    model.phases.map((p) => phaseBody(p, top, open.has(p.id))).join("") +
    `</table></div><p class="foot">Open a phase to see what it is made of. A part's share and bar are of its phase.</p></section>` +
    `<section class="card how"><h2>How the split is made</h2><p>Each API call is priced from its own token counts, per model. A call goes to the phase of ` +
    `the last tool it read the result of: a review script makes the next call "review steps", a test run makes it "tests", and plain reading and editing ` +
    `is "build and other work". Whole sessions go to one phase when their role says so: chief, judge, critic, release manager. The totals are counted; ` +
    `the split between phases is derived.</p></section>`;
}

// Draws the page into `root` and keeps the open phases; one click on a phase row opens or closes it.
export function mountCost(root, model) {
  const view = { open: [] };
  const paint = () => { root.innerHTML = renderCost(model, view); };
  root.addEventListener("click", (e) => {
    const b = e.target && e.target.closest && e.target.closest("button.dr");
    const id = b && b.getAttribute("data-phase");
    if (!id) return;
    view.open = view.open.includes(id) ? view.open.filter((x) => x !== id) : [...view.open, id];
    paint();
  });
  paint();
}
