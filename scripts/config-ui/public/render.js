// pure rendering, no DOM. render(feed, state) → HTML string.
// state: { open: Set<string>, bundles: { "<region>|<bundle>": { open, rank } }, filt: { health, kind, q, problems }, plans: { [k]: plan } }.
// A toggle in Settings opens a plan: preview (dry-run) → consent → run →
// before/after. Confirm stays disabled until a typed consent matches.
import { docsHref } from "./nav.js";

const ST = { ok: "● ok", warn: "◐ warn", fail: "✕ fail", off: "○ off", info: "· info" };
const READ_ONLY = {
  "launch-shell variable": "set in launching shell",
  "secrets are presence-only": "presence probe",
  "Windows only": "Windows only",
  "probe failure": "probe failure",
};

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const kindOf = (r) => ({ doctor: "check", item: "item" }[r.source] || r.source);
const remedyOf = (r) => (r.fix && r.fix.remedy) || "";
const isTriage = (r) => r.health === "fail" || r.health === "warn";
const isCopy = (r) => r.control.class === "fix-command" || (isTriage(r) && remedyOf(r) && r.source !== "flag" && r.control.class !== "toggle");

function slot(r, where) {
  const c = r.control;
  if (c.class === "toggle") {
    if (where !== "settings") return `<span class="ro">control ↗</span>`;
    const on = r.installed && r.installed.state === "present";
    const a = (v) => `data-act="plan" data-k="${esc(`${where}|${r.id}`)}" data-action="${esc(c.action)}" data-target="${esc(c.target)}"${v ? ` data-value="${v}"` : ""}`;
    // The feed does not know a lane's current value, so a lane offers both.
    if (c.action === "config.lanes") return `<button class="btn" ${a("on")}>on</button> <button class="btn" ${a("off")}>off</button>`;
    const v = c.action === "config.initiative" ? (on ? "off" : "on") : "";
    return `<button class="sw" role="switch" aria-checked="${on}" ${a(v)}>${on ? "on" : "off"} <span class="t"></span></button>`;
  }
  if (isCopy(r)) return `<button class="btn" data-act="copy" data-cmd="${esc(remedyOf(r))}">copy · runs in your terminal</button>`;
  return `<span class="ro">⊘ read-only · ${esc(READ_ONLY[c.reason] || c.reason || "probe")}</span>`;
}

function firesText(f) {
  if (!f) return "unverified";
  return f.state === "yes" ? `yes · ${esc(f.at)} · ${esc(f.evidence)}` : esc(f.state);
}

function planHtml(k, p) {
  const dk = `data-k="${esc(k)}"`;
  const cancel = `<button class="btn" data-act="close" ${dk}>${p.stage === "done" || p.stage === "error" ? "close" : "cancel"}</button>`;
  if (p.stage === "loading") return `<div class="plan"><span class="ro">running dry-run…</span></div>`;
  if (p.stage === "running") return `<div class="plan"><span class="ro">running ${esc(p.command)}…</span></div>`;
  if (p.stage === "error") return `<div class="plan"><b>${esc(p.error)}</b>${p.output ? `<pre>${esc(p.output)}</pre>` : ""}${cancel}</div>`;
  if (p.stage === "plan") {
    const typed = p.consent && p.consent.kind === "typed";
    const ok = !typed || p.typed === p.consent.expect;
    return `<div class="plan"><div class="ro">dry-run · nothing has changed</div><pre>$ ${esc(p.command)}\n${esc(p.output)}</pre>
      ${p.bank && p.bank !== "none" ? `<div class="ro">usage budget: ${esc(p.bank)}</div>` : ""}<div class="ro">takes effect: ${esc(p.effect)}</div>
      ${typed ? `<label>type <b>${esc(p.consent.expect)}</b> to confirm <input data-act="consent" ${dk} value="${esc(p.typed)}" autocomplete="off"></label>` : ""}
      <button class="btn primary" data-act="run" ${dk}${ok ? "" : " disabled"}>confirm</button>${cancel}
      <span class="ro">preview id expires in 5 min</span></div>`;
  }
  const ids = [...new Set([...Object.keys(p.before || {}), ...Object.keys(p.after || {})])];
  const ba = ids.map((id) => {
    const b = (p.before || {})[id] || {}, a = (p.after || {})[id] || {};
    return `<div class="ba"><b>${esc(id)}</b><span>installed ${esc(b.installed)} → ${esc(a.installed)}</span><span>health ${esc(b.health)} → ${esc(a.health)}</span></div>`;
  }).join("");
  return `<div class="plan"><div>${p.rc === 0 ? "✓" : "✕"} ran ${esc(p.command)} · rc=${esc(p.rc)}${p.timedOut ? " · timed out" : ""}</div>${ba}
    ${p.output ? `<pre>${esc(p.output)}</pre>` : ""}<div class="ro">${p.reprobe === "ok" ? "re-probed" : esc(p.reprobe)} · ${p.audit === "failed" ? "<b>audit log append FAILED</b>" : "logged to actions.jsonl"}</div>${cancel}</div>`;
}

function rowHtml(r, where, state) {
  const k = `${where}|${r.id}`;
  const open = state.open.has(k);
  const d = r.declared || {};
  const i = r.installed || {};
  let h = `<div class="row"><div class="row-head" tabindex="0" role="button" aria-expanded="${open}" data-act="toggle" data-k="${esc(k)}">
    <span class="st ${esc(r.health)}">${ST[r.health] || esc(r.health)}</span><span class="kind">[${esc(kindOf(r))}]</span>
    <span class="id" title="${esc(r.id)}">${esc(r.id)}</span><span class="det">${esc(i.detail)}</span>
    <span class="slot">${slot(r, where)}</span></div>`;
  const plan = state.plans && state.plans[k];
  if (plan) h += planHtml(k, plan);
  if (open) {
    h += `<div class="body">
      <div class="f"><b>declared</b><span>${esc(d.where)}${d.desired ? ` · ${esc(d.desired)}` : ""}${d.profile ? ` · profile ${esc(d.profile)}` : ""}</span></div>
      <div class="f"><b>installed</b><span>${esc(i.state)}</span></div>
      <div class="f"><b>fires</b><span>${firesText(r.fires)}</span></div>
      <div class="f"><b>fix</b><span>${esc(remedyOf(r) || "none needed")}</span></div>
      <div class="full">${esc(i.detail)}</div></div>`;
  }
  return h + `</div>`;
}

// bundles. Rank is worse-is-higher: fail > warn > ok > off > info
// (ok outranks off: an opt-in left off must not make a working bundle read off).
const ORDER = ["fail", "warn", "ok", "off", "info"];
const RANK = { fail: 4, warn: 3, ok: 2, off: 1, info: 0 };

export function rollup(rows) {
  const r = { fail: 0, warn: 0, ok: 0, off: 0, info: 0, total: rows.length };
  for (const x of rows) if (x.health in RANK) r[x.health]++;
  r.headline = ORDER.find((h) => r[h] > 0) || "info";
  r.rank = RANK[r.headline];
  return r;
}

// The one open/closed decision: Unsorted and a live search force open; else a
// non-stale click override; else open when the base set has a fail or warn.
// A stale override (the bundle got worse since the click) is deleted.
export function isOpen(region, bundleId, baseRows, state, q) {
  if (bundleId === "unsorted" || q) return true;
  const r = rollup(baseRows);
  const bundles = state.bundles || {};
  const k = `${region}|${bundleId}`;
  const o = bundles[k];
  if (o && r.rank > o.rank) delete bundles[k];
  else if (o) return o.open;
  return r.fail + r.warn > 0;
}

function bundleHead(where, b, open, r, shown) {
  const counts = ORDER.filter((h) => r[h] > 0).map((h) => `${r[h]} ${h}`).join(" · ");
  return `<div class="bhead" role="button" tabindex="0" aria-expanded="${open}" data-act="bundle" data-b="${esc(`${where}|${b.id}`)}" data-rank="${r.rank}">
    <span class="chev">${open ? "▾" : "▸"}</span><span class="st ${r.headline}">${ST[r.headline].split(" ")[0]}</span>
    <span class="bt">${esc(b.title)}</span><span class="bc">${counts}</span><span class="bn">${shown === r.total ? r.total : `${shown} of ${r.total}`}</span></div>`;
}

// list = rows the filters let through; base = the region's whole set (rollups
// and default-open read the base, never the filtered view).
function bundled(list, base, where, state, feed, q) {
  const known = feed.bundles ? feed.bundles.filter((b) => b.id !== "unsorted") : [{ id: "all", title: "All rows" }];
  const ids = new Set(known.map((b) => b.id));
  const of = (r) => (feed.bundles ? (ids.has(r.bundle) ? r.bundle : "unsorted") : "all");
  const order = feed.bundles && base.some((r) => of(r) === "unsorted") ? known.concat({ id: "unsorted", title: "Unsorted" }) : known;
  return order.map((b) => {
    const rs = list.filter((r) => of(r) === b.id);
    if (!rs.length) return "";
    const bs = base.filter((r) => of(r) === b.id);
    const open = isOpen(where, b.id, bs, state, q);
    return `<div class="bundle">${bundleHead(where, b, open, rollup(bs), rs.length)}${open ? rs.map((r) => rowHtml(r, where, state)).join("") : ""}</div>`;
  }).join("");
}

const sets = (feed) => {
  const rows = feed.rows || [];
  const triage = rows.filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  return { rows, triage, toggles: rows.filter((r) => r.control.class === "toggle") };
};

// The one shared header, from the feed envelope only (feed.himmel, feed.generatedAt). An older feed has no himmel.
export function renderHeader(feed) {
  const h = feed && feed.himmel;
  const t = feed && feed.generatedAt ? `<span><span class="k">feed</span> ${esc(String(feed.generatedAt).replace("T", " ").slice(0, 16))}</span>` : "";
  if (!h) return `<span class="ver unk">version unknown (feed has no himmel identity)</span>${t}`;
  const c = String(h.commit ?? "");
  return `<span class="ver">himmel ${esc(h.version)} · ${esc(h.describe)}</span>
    <span title="${esc(c)}"><span class="k">commit</span> ${esc(c.slice(0, 12))}</span>
    ${h.checkout ? `<span><span class="k">serving</span> ${esc(h.checkout)}</span>` : ""}${t}`;
}

// the status while the report runs. j is the feed's 202 body ({ elapsedMs, progress }); progress
// ({ i, n, source }, from probe-progress.cjs) is null before the first step. A native <progress>: the CSP
// (default-src 'self') refuses inline styles.
export function renderProbe(j) {
  const p = j && j.progress;
  const s = Math.round(((j && j.elapsedMs) || 0) / 1000);
  const step = p && Number.isInteger(p.i) && Number.isInteger(p.n) ? p : null;
  const text = step ? `probing ${esc(step.source)} (${step.i} of ${step.n}) · ${s}s` : `probing the station · ${s}s`;
  const bar = step ? `<progress max="${step.n}" value="${step.i}" aria-label="station probe"></progress>` : `<progress aria-label="station probe"></progress>`;
  return `<div class="probe" id="status" role="status" aria-live="polite"><span>${text}</span>${bar}<span class="sub">the first report can take a couple of minutes</span></div>`;
}

export function renderNav(feed, current) {
  const { rows, triage, toggles } = sets(feed);
  return [["triage", "Triage", triage.length, 1], ["settings", "Settings", toggles.length, 2], ["inventory", "Inventory", rows.length, 3]]
    .map(([id, label, n, key]) => `<button data-go="${id}" aria-current="${id === current}"><span>${label} ${n}</span><kbd>${key}</kbd></button>`).join("");
}

// the vm.mode / vm.remote form. vm = { data: GET /api/vm, error, draft: { mode, ssh, port, identity }, msg }.
// The server validates; this only shows its answer.
export function renderVm(vm) {
  const head = `<h2 id="h-vm">VM mode</h2><p class="sub">Whether VM proof runs on the local test VM, a remote one, or not at all (vm.mode in the himmel config).</p>`;
  if (!vm || (!vm.data && !vm.error)) return `<section id="vm" aria-labelledby="h-vm">${head}<div class="empty">loading…</div></section>`;
  if (!vm.data) return `<section id="vm" aria-labelledby="h-vm">${head}<div class="nodata">${esc(vm.error)}</div></section>`;
  const d = vm.draft || { mode: vm.data.mode, ssh: "", port: "", identity: "" };
  const opts = ["local", "remote", "none"].map((m) => `<option value="${m}"${d.mode === m ? " selected" : ""}>${m}</option>`).join("");
  const remote = d.mode === "remote"
    ? `<label>ssh target <input data-vm="ssh" value="${esc(d.ssh)}" placeholder="user@host" aria-label="ssh target"></label>
       <label>port <input data-vm="port" value="${esc(d.port)}" placeholder="22" inputmode="numeric" aria-label="port"></label>
       <label>identity <input data-vm="identity" value="${esc(d.identity)}" placeholder="~/.ssh/id_ed25519" aria-label="identity"></label>`
    : "";
  const msg = vm.msg ? `<div class="${vm.msg.ok ? "ro" : "nodata"}" role="status">${esc(vm.msg.text)}</div>` : "";
  return `<section id="vm" aria-labelledby="h-vm">${head}<div class="card">
    <label>mode <select data-vm="mode" aria-label="vm mode">${opts}</select></label>${remote}
    <button class="btn" data-act="vm-save">save</button>${msg}</div></section>`;
}

// Settings: what can be changed and where it lives. Each row shows the himmelctl command it runs, when it takes
// effect and a Learn more link into the docs site. Switches come from the feed's toggle rows; the rest only show.
const HIMMEL_HOME = "~/himmel";
const CTL = `node ${HIMMEL_HOME}/scripts/himmelctl/bin.js`;
const CADENCE_PATH = {
  pipeline: "scripts/luna/pipeline-cadence.sh",
  graphmap: "scripts/luna/graphmap-cadence.sh",
  qmd: "scripts/luna/qmd-cadence.sh",
  doctor: "scripts/doctor-cadence.sh",
};
const EFFECT = {
  "cadence.arm": "at the next scheduled run", "cadence.disarm": "at the next scheduled run",
  "plugin.enable": "next Claude launch", "plugin.disable": "next Claude launch", "profile.set": "next Claude launch",
  "config.lanes": "next time work is handed to a lane", "config.initiative": "next Claude launch",
};

// The command an action runs, spelled as the action table builds its argv; root is the himmel download.
export function settingsCommand({ action, target }, root = HIMMEL_HOME, value) {
  const ctl = ["node", `${root}/scripts/himmelctl/bin.js`];
  const [ns, verb] = action.split(".");
  if (ns === "cadence") return ["bash", `${root}/${CADENCE_PATH[target]}`, verb].join(" ");
  if (ns === "plugin") return [...ctl, "profile", verb, target].join(" ");
  if (action === "profile.set") return [...ctl, "profile", target].join(" ");
  return [...ctl, "config", "set", `${verb}.${target}`, value || "on|off"].join(" ");
}
export const settingsEffect = (action) => EFFECT[action] || "";

const feedCommand = (r) => {
  const on = r.installed && r.installed.state === "present";
  return settingsCommand(r.control, HIMMEL_HOME, r.control.action === "config.initiative" ? (on ? "off" : "on") : undefined);
};

const SHOWN = (title, detail, cmd, effect) => ({ title, detail, cmd, effect, slot: `<span class="ro">shown here, set in the terminal</span>` });
const SETTINGS_GROUPS = [
  { id: "plugins", title: "Plugins", feed: ["plugin.enable", "plugin.disable"], learn: "/himmelctl/",
    intro: "Claude Code plugins himmel installed. Three cannot be switched off, because the rest depends on them: handover, himmel-ops and qmd.",
    first: [{ id: "profile-set", title: "Plugin set", detail: "lean or full; asks you to type the name to confirm", effect: EFFECT["profile.set"],
      cmd: ["lean", "full"].map((t) => settingsCommand({ action: "profile.set", target: t })).join("\n"),
      keys: ["lean", "full"].map((t) => `settings|profile-set-${t}`),
      slot: ["lean", "full"].map((t) => `<button class="btn" data-act="plan" data-k="settings|profile-set-${t}" data-action="profile.set" data-target="${t}">${t}</button>`).join(" ") }] },
  { id: "review", title: "Review by a second model", feed: ["config.lanes"], learn: "/setup/codex/",
    intro: "Which extra reviewers join Claude on /pr-check. Off unless you turn one on." },
  { id: "auto-ship", title: "Auto-ship steps", feed: ["config.initiative"], learn: "/configuration/",
    intro: "Each step is its own switch; merging is never one of them here. Saved as HIMMEL_INITIATIVE in the .env of the himmel download." },
  { id: "scheduled-jobs", title: "Scheduled jobs", feed: ["cadence.arm", "cadence.disarm"], learn: "/cadences/",
    intro: "Arming or disarming asks you to type a confirmation, and says what the job costs." },
  { id: "commit-rules", title: "Commit rules", learn: "/configuration/",
    intro: "Read by the git gates in your project. Set them in ~/.himmel/himmel.conf.",
    shown: [
      SHOWN("Ticket reference", "TICKET_ID_REQUIRED=0 drops the ticket reference from the commit rule", "TICKET_ID_REQUIRED=0", "your next commit"),
      SHOWN("Ticket pattern", "your own pattern, or KEY-123 from the project key; with neither, #123", "TICKET_ID_PATTERN=<pattern>\nJIRA_PROJECT_KEY=<KEY>", "your next commit"),
    ] },
  { id: "session-switches", title: "Session switches", learn: "/internals/enforcement/",
    intro: "Each guard has a bypass you set when you start Claude. It lasts for that session only.",
    shown: [
      SHOWN("Edit on main", "allow edits on the main branch", "EDIT_ON_MAIN_OK=1 claude", "that session only"),
      SHOWN("Read secrets", "allow reading secret files", "READ_SECRETS_OK=1 claude", "that session only"),
      SHOWN("Destructive commands", "allow commands the guard blocks", "DESTRUCTIVE_OK=1 claude", "that session only"),
      SHOWN("Single writer", "opt a repo out of the single-writer rule; keep the file out of git", "touch .single-writer", "that repo, until you delete the file"),
    ] },
  { id: "install-answers", title: "Your install answers", learn: "/setup/profiles/",
    intro: "The wizard saves your answers so you can replay them on another machine, or switch scope later.",
    shown: [
      SHOWN("Saved answers", "replay them elsewhere, or move the install between user and project scope",
        `${CTL} install --from-profile <file>\n${CTL} scope set user --dry-run`, "when you run the command"),
      SHOWN("Machine settings", "where himmel keeps your machine-wide answers", "~/.himmel/config.json", "your next Claude launch"),
    ] },
];

function setRow(g, state, { id, title, detail, cmd, effect, slot, health, keys }) {
  const ks = keys || [`settings|${id}`];
  const pk = ks.find((k) => state.plans && state.plans[k]);
  return `<div class="setrow"><div class="sethead">${health ? `<span class="st ${esc(health)}">${ST[health] || esc(health)}</span>` : ""}<span class="id">${esc(title)}</span><span class="det">${esc(detail)}</span><span class="slot">${slot}</span></div>
    <pre><code>${esc(cmd)}</code></pre>
    <div class="ro">takes effect: ${esc(effect)} · <a class="learn" href="${docsHref(g.learn)}" target="_blank" rel="noopener">Learn more</a></div>${pk ? planHtml(pk, state.plans[pk]) : ""}</div>`;
}

export function renderSettings(feed, state) {
  const toggles = (feed.rows || []).filter((r) => r.control.class === "toggle");
  const groups = SETTINGS_GROUPS.map((g) => {
    const fed = toggles.filter((r) => g.feed && g.feed.includes(r.control.action)).map((r) => ({
      id: r.id, title: r.id, detail: (r.installed && r.installed.detail) || "", cmd: feedCommand(r), effect: settingsEffect(r.control.action), slot: slot(r, "settings"), health: r.health,
    }));
    const all = [...(g.first || []), ...fed, ...(g.shown || [])];
    return `<div class="setgroup"><h3 id="sg-${g.id}">${esc(g.title)}</h3><p class="sub">${esc(g.intro)}</p>
    ${all.map((x) => setRow(g, state, x)).join("")}</div>`;
  }).join("");
  return `<section id="settings" aria-labelledby="h-settings">
  <h2 id="h-settings">Settings</h2>
  <p class="sub">What you can change, and where it lives. Each row says when a change takes effect. Toggles here run the same himmelctl command shown under them, so the terminal and this page never disagree. Every switch previews its dry-run first; nothing changes until you confirm.</p>
  ${groups}
</section>`;
}

export function render(feed, state) {
  const { rows, triage } = sets(feed);
  const filt = state.filt || {};
  const nf = triage.filter((r) => r.health === "fail").length;
  const okOf = (src) => { const l = rows.filter((r) => r.source === src); return `${l.filter((r) => r.health === "ok").length}/${l.length}`; };
  const q = (filt.q || "").toLowerCase();
  const inv = rows.filter((r) => (!filt.health || r.health === filt.health) && (!filt.kind || kindOf(r) === filt.kind) && (!q || r.id.toLowerCase().includes(q)) && (!filt.problems || isTriage(r)));
  const empty = !q && filt.problems && !filt.health && !filt.kind ? "Nothing failing or drifting." : "No rows match these filters.";
  const prob = `<button class="sw" role="switch" aria-checked="${filt.problems === true}" data-act="problems">show only problems <span class="t"></span></button>`;
  const kinds = [...new Set(rows.map(kindOf))];
  const chips = ["fail", "warn", "ok", "off", "info"].map((h) => `<button class="chip" data-f="health" data-v="${h}" aria-pressed="${filt.health === h}">${h}</button>`)
    .concat(kinds.map((k) => `<button class="chip" data-f="kind" data-v="${esc(k)}" aria-pressed="${filt.kind === k}">${esc(k)}</button>`)).join("");
  return `<section id="triage" aria-labelledby="h-triage">
  <h2 id="h-triage">Triage</h2>
  <p class="sub">Only rows that are failing or drifting. Opt-in items you left off are not listed.</p>
  <div class="summary"><span class="st fail">${nf} fail</span><span class="st warn">${triage.length - nf} warn</span><span class="ro">items ${okOf("item")} ok · doctor ${okOf("doctor")} ok</span></div>
  ${triage.length ? triage.map((r) => rowHtml(r, "triage", state)).join("") : `<div class="empty">Nothing wrong. ${okOf("item")} items ok, doctor ${okOf("doctor")}.</div>`}
</section>
${renderSettings(feed, state)}
${renderVm(state.vm)}
<section id="inventory" aria-labelledby="h-inv">
  <h2 id="h-inv">Inventory</h2>
  <p class="sub">Every item, check, flag and secret, grouped by feature.</p>
  <div class="filters"><input id="q" placeholder="filter by id" value="${esc(filt.q || "")}" aria-label="Filter by id">${prob}${chips}</div>
  ${inv.length ? bundled(inv, rows, "inventory", state, feed, q) : `<div class="empty">${empty}</div>`}
</section>`;
}
