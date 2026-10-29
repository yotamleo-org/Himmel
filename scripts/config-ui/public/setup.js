// The Setup page: which secrets are set (presence only, never a value), a form to set or remove one, the commit rules, and the Verify step.
// A value lives in the password field until the request is sent and the field is cleared at once: it is never kept in
// page state, localStorage or the markup, and the server answers with the name and the new status only.
import { esc, planHtml, renderFleetCap, renderReviewGate, renderSettingsGroups, renderVm } from "./render.js";
import { TILES } from "./nav.js";

const STATUS = { set: "set", "not-set": "not set", placeholder: "placeholder", probe: "checked in the terminal" };
const TRACKERS = [["jira", "Jira"], ["local", "Local"], ["none", "None"]];

const JIRA_LABEL = { JIRA_BASE_URL: "Site", JIRA_EMAIL: "Email", JIRA_API_TOKEN: "API token", JIRA_PROJECT_KEY: "Project key" };
const JIRA_ORDER = Object.keys(JIRA_LABEL);

// cfg: the Configure look, a friendly name with the key as its meta line, and the example as the field's placeholder.
function secretRow(s, msg, cfg) {
  const status = `<span class="st ${s.status === "set" ? "ok" : "warn"}">${esc(STATUS[s.status] || s.status)}</span>`;
  const what = cfg && JIRA_LABEL[s.name]
    ? `<span class="id">${esc(JIRA_LABEL[s.name])}</span><span class="det">${esc(s.name)}</span>`
    : `<span class="id">${esc(s.name)}</span><span class="det">${esc(s.feature)}${s.required ? ` · ${esc(s.required)}` : ""}</span>`;
  if (s.collect !== "file") return `<div class="srow">${what}${status}<span class="ro">set in the terminal</span></div>`;
  const remove = s.status === "set" ? `<button class="btn" type="button" data-act="setup-remove" data-name="${esc(s.name)}">remove</button>` : "";
  return `<div class="srow">${what}${status}
    <form class="sform" data-setup-form data-name="${esc(s.name)}" autocomplete="off">
      <input type="password" data-secret="${esc(s.name)}" autocomplete="new-password" spellcheck="false" aria-label="${esc(s.name)} value"${cfg && s.example ? ` placeholder="e.g. ${esc(s.example)}"` : ""}>
      ${cfg ? `<span class="acts"><button class="btn primary" type="submit">save</button>${remove}</span>` : `<button class="btn primary" type="submit">save</button>${remove}`}</form>
    ${s.example && !cfg ? `<span class="ro">e.g. ${esc(s.example)}</span>` : ""}
    ${msg ? `<span class="ro" role="status">${esc(msg)}</span>` : ""}</div>`;
}

const CR_STATE = { installed: "installed", "not-installed": "not detected", unknown: "not checked" };

function coderabbit(c) {
  if (!c) return "";
  const st = `<span class="st ${c.installed === "installed" ? "ok" : "warn"}">${esc(CR_STATE[c.installed] || c.installed)}</span>`;
  return `<h3>CodeRabbit</h3>
    <div class="srow"><span class="id">CodeRabbit review</span><span class="det">${esc(c.requirement)} add-on · gates ${c.armed ? "armed" : "not armed"} in this clone</span>${st}</div>
    <p class="sub">${esc(c.what)}</p>
    <ol class="sub">${c.steps.map((t) => `<li>${esc(t)}</li>`).join("")}</ol>
    ${c.manual ? `<p class="sub" role="status">${esc(c.manual)}</p>` : ""}`;
}

function choice(label, action, target, value, current, k, disabled) {
  const on = current === value;
  return `<button class="btn${on ? " primary" : ""}" data-act="plan" data-action="${action}" data-target="${target}" data-value="${value}" data-k="${k}" aria-pressed="${on}"${disabled ? " disabled" : ""}>${esc(label)}</button>`;
}

const TK = "setup|tracker", RK = "setup|ticket-id-required";

const trackerRow = (c) => `<div class="srow"><span class="id">Tracker</span><span class="det">${c.tracker ? "" : "not set yet · "}takes effect on your next commit</span>
      <span>${TRACKERS.map(([v, l]) => choice(l, "config.commitRules", "tracker", v, c.tracker, TK)).join(" ")}</span></div>`;

function ticketRow(c, cfg) {
  const none = c.tracker === "none";
  const required = none || c.ticketIdRequired === false ? "off" : "on";
  const [name, det] = cfg ? ["Every commit names a ticket", "The git gates refuse a commit that names none. Off while the tracker is None. Takes effect on your next commit."]
    : ["Ticket ID required", none ? "off while the tracker is None" : "takes effect on your next commit"];
  return `<div class="srow"><span class="id">${name}</span><span class="det">${det}</span>
      <span>${choice("on", "config.commitRules", "ticket-id-required", "on", required, RK, none)} ${choice("off", "config.commitRules", "ticket-id-required", "off", required, RK, none)}</span></div>`;
}

function commitRules(c, plans) {
  return `<h3>Commit rules</h3>
    <p class="sub">Which tracker a commit's ticket ID comes from, and whether a commit needs one. Each change shows a dry run before it writes. The ID pattern is typed in the terminal.</p>
    ${trackerRow(c)}
    ${plans[TK] ? planHtml(TK, plans[TK]) : ""}
    ${ticketRow(c)}
    ${plans[RK] ? planHtml(RK, plans[RK]) : ""}`;
}

const PATH_LABEL = { "handover-root": "Handover root", "luna-vault": "luna vault path" };

// Where handover state and the luna vault live, each change a dry run first; the forge is shown as detected; the
// remaining choices are the Settings page's toggles, linked here rather than repeated.
function pathRows(c, plans) {
  return c.paths.map((p) => {
    const k = `setup|${p.target}`;
    const shown = (plans[k] && plans[k].req && plans[k].req.value) || p.value || "";
    return `<div class="srow"><span class="id">${esc(PATH_LABEL[p.target] || p.target)}</span>
      <span class="det">${p.value ? `${esc(p.key)} · takes effect on the next Claude launch` : `not set · default: ${esc(p.fallback)}`}</span>
      <form class="sform" data-path-form data-target="${esc(p.target)}" autocomplete="off">
        <input type="text" data-path="${esc(p.target)}" value="${esc(shown)}" spellcheck="false" placeholder="/absolute/path" aria-label="${esc(PATH_LABEL[p.target] || p.target)}">
        <button class="btn" type="submit">preview</button></form></div>
      ${plans[k] ? planHtml(k, plans[k]) : ""}`;
  }).join("");
}

function forgeRow(c) {
  const f = c.forge || {};
  return `<div class="srow"><span class="id">Forge</span>
    <span class="det">${f.error ? esc(f.error) : `detected: ${esc(f.value)}`}</span>
    <span class="ro">set <code>FORGE</code> or <code>git config himmel.forge</code> in the terminal</span></div>`;
}

function setupChoices(c, plans) {
  if (!c) return "";
  const rows = pathRows(c, plans), forge = forgeRow(c);
  return `<h3>Setup choices</h3>
    <p class="sub">Each path is written to <code>~/.himmel/himmel.conf</code> by <code>himmelctl config set</code> after a dry run you confirm. A path is absolute, with no <code>.</code> or <code>..</code> part, quote, <code>#</code>, <code>$</code> or backslash.</p>
    ${rows}${forge}
    <p class="sub">Plugin set, Review by a second model and Auto-ship steps are toggles on <a href="#/config">the Settings page</a>.</p>`;
}

// The first-run Account step: the UI login the always-on UI asks for. The page creates it once; changing it is a terminal step.
function account(a, msg, cfg) {
  if (!a) return "";
  const note = msg ? `<p class="sub" role="status">${esc(msg)}</p>` : "";
  if (a.status === "set") return `<h3>Account</h3><p class="sub">The UI login is set for <code>${esc(a.user)}</code>. Log in with it at <code>/login</code> on the always-on UI. To change it, run <code>${esc(a.setLogin)}</code> in your own terminal.</p>${note}`;
  if (a.create !== "ui") return `<h3>Account</h3><p class="sub">${a.status === "unreadable" ? "The login file cannot be read. " : "No UI login is set yet. "}Set it with <code>${esc(a.setLogin)}</code> in your own terminal.</p>${note}`;
  return `<h3>Account</h3><p class="sub">Create the login for the always-on UI first: it asks for this user and password before it saves a secret. The password is at least 8 characters and is kept only as a hash.</p>
    <form class="sform" data-account-form autocomplete="off">${cfg ? `
      <label class="fld">User<input type="text" data-account="user" autocomplete="username" spellcheck="false" placeholder="a user name"></label>
      <label class="fld">Password<input type="password" data-account="password" autocomplete="new-password" placeholder="at least 8 characters"></label>
      <label class="fld">Password again<input type="password" data-account="confirm" autocomplete="new-password" placeholder="the same password"></label>` : `
      <input type="text" data-account="user" autocomplete="username" spellcheck="false" aria-label="user name">
      <input type="password" data-account="password" autocomplete="new-password" aria-label="password">
      <input type="password" data-account="confirm" autocomplete="new-password" aria-label="password again">`}
      <button class="btn primary" type="submit">create login</button></form>${note}`;
}

// The Verify step: the doctor's read-only checks, run when asked. A finding links to its row on the Settings page, which
// carries the fix; the remedy is shown too. The result is the server's summary and rows (secrets already redacted), kept in page memory only.
function verifyStep(v) {
  const head = `<h3>Verify</h3><p class="sub">Run himmel's health checks on this install. They only read: nothing is fixed or changed, and no secret value is shown.</p>`;
  const run = (label) => `<button class="btn primary" type="button" data-act="setup-verify">${label}</button>`;
  if (!v) return `${head}<div class="srow"><span class="id">Health checks</span><span class="det">not run yet</span>${run("run the checks")}</div>`;
  if (v.state === "running") return `${head}<div class="srow"><span class="id">Health checks</span><span class="det" role="status">running… this can take a minute or two</span></div>`;
  if (v.state !== "done") return `${head}<div class="nodata" role="alert">${esc(v.error || "the checks did not finish")}</div>${run("run again")}`;
  const summary = `<div class="summary"><span class="st fail">${v.fail} fail</span> <span class="st warn">${v.warn} warn</span> <span class="st ok">${v.ok} ok</span>${v.info ? ` <span class="st info">${v.info} info</span>` : ""}</div>`;
  const rows = v.findings.map((f) => `<div class="srow"><span class="id">${esc(f.id)}</span>
      <span class="det"><span class="st ${f.sev === "FAIL" ? "fail" : "warn"}">${esc(f.sev.toLowerCase())}</span> ${esc(f.msg)}${f.remedy ? ` · fix: ${esc(f.remedy)}` : ""}</span>
      <button class="btn" type="button" data-act="open-config" data-id="doctor:${esc(f.id)}">Open in Settings</button></div>`).join("");
  return `${head}${summary}${rows || `<p class="sub" role="status">Nothing to fix.</p>`}${run("run again")}`;
}

// ---- the Configure page: Settings and Setup as four group tiles, one open at a time, under a Check this install strip ----
const TILE_NAME = { secrets: "Secrets", review: "Review", tracker: "Tracker", scope: "Project scope" };
const TILE_ICON = { secrets: "⚿", review: "✓", tracker: "#", scope: "▶" };
const isJira = (s) => s.name.startsWith("JIRA_");
const TRACKER_NAME = Object.fromEntries(TRACKERS);
const REVIEWER_NAME = { codex: "GPT", claude: "Claude", coderabbit: "CodeRabbit" };

// What a tile holds right now, read from the data the panels already use; "" until that data is loaded.
function tileValue(id, { setup, state }) {
  const ok = setup && !setup.error;
  if (id === "secrets") {
    const own = ok ? setup.secrets.filter((s) => s.collect === "file" && !isJira(s)) : [];
    const login = ok && setup.account ? (setup.account.status === "set" ? " · login set" : " · no login yet") : "";
    return ok ? `${own.filter((s) => s.status === "set").length} of ${own.length} set${login}` : "";
  }
  if (id === "review") {
    const d = state.reviewGate && state.reviewGate.data;
    return d ? d.reviewers.filter((r) => r.enabled !== false).map((r) => `${REVIEWER_NAME[r.slug] || r.slug} ${r.required ? "must pass" : "notes"}`).join(" · ") : "";
  }
  if (id === "tracker") return ok ? TRACKER_NAME[setup.commit.tracker] || "not set" : "";
  const fc = state.fleetCap && state.fleetCap.data, vm = state.vm && state.vm.data;
  return [fc && `fleet cap ${fc.cap}`, vm && `VM ${vm.mode}`].filter(Boolean).join(" · ");
}

// Only the review gate carries a recommendation, so only the Review tile can say it matches our pick.
function tileChip(id, { state, setup }) {
  if (id === "secrets") {
    const t = setup && !setup.error && setup.secrets.find((s) => s.name === "TELEGRAM_BOT_TOKEN");
    return t && t.status !== "set" ? `<span class="m diff">Telegram not set</span>` : "";
  }
  const d = id === "review" && state.reviewGate && state.reviewGate.data;
  if (!d) return "";
  const rec = d.reviewers.filter((r) => r.recommended);
  const same = rec.length > 0 && rec.every((r) => r.recommended.mode === r.mode && r.recommended.required === r.required && r.recommended.enabled);
  return same ? `<span class="m ok">matches our pick</span>` : "";
}

function checkStrip(v) {
  const run = (label) => `<button class="btn primary" type="button" data-act="setup-verify">${label}</button>`;
  const head = `<b>Check this install</b><span class="sub">Read-only: nothing is fixed or changed, and no secret value is shown.</span>`;
  if (!v) return `<div class="chk">${head}<span class="det">not run yet</span>${run("run the checks")}</div>`;
  if (v.state === "running") return `<div class="chk">${head}<span class="det" role="status">running… this can take a minute or two</span></div>`;
  if (v.state !== "done") return `<div class="chk">${head}<span class="nodata" role="alert">${esc(v.error || "the checks did not finish")}</span>${run("run again")}</div>`;
  const rows = v.findings.map((f) => `<div class="srow"><span class="id">${esc(f.id)}</span>
      <span class="det"><span class="st ${f.sev === "FAIL" ? "fail" : "warn"}">${esc(f.sev.toLowerCase())}</span> ${esc(f.msg)}${f.remedy ? ` · fix: ${esc(f.remedy)}` : ""}</span>
      <button class="btn" type="button" data-act="open-config" data-id="doctor:${esc(f.id)}">Open in Health</button></div>`).join("");
  return `<div class="chk">${head}<span class="summary"><span class="st fail">${v.fail} fail</span> <span class="st warn">${v.warn} warn</span> <span class="st ok">${v.ok} ok</span>${v.info ? ` <span class="st info">${v.info} info</span>` : ""}</span>${run("run again")}</div>
    ${rows || `<p class="sub" role="status">Nothing to fix.</p>`}`;
}

const loading = (what) => `<p class="sub" role="status">loading ${what}…</p>`;
const setupFailed = (setup) => (setup ? `<div class="nodata" role="alert">${esc(setup.error)}</div>` : loading("this install's setup"));

function secretsPanel({ setup, msgs }) {
  if (!setup || setup.error) return setupFailed(setup);
  const own = setup.secrets.filter((s) => !isJira(s));
  return `<p class="sub">A secret you save here goes to this machine over a loopback connection, bound to this launch's token; it is never shown again. This page shows only whether each secret is set, never its value. With no browser available, <code>himmelctl install</code> asks for secrets in the terminal instead.</p>
    ${account(setup.account, msgs.account, true)}
    ${own.filter((s) => s.collect === "file").sort((a, b) => (a.required !== "required") - (b.required !== "required")).map((s) => secretRow(s, msgs[s.name], true)).join("")}
    <div class="srow"><span class="id">Set in the terminal <span class="tag">read-only</span></span><span class="det">These are collected by their feature's own setup card, so the page shows only whether each is set.</span><span class="chips">${own.filter((s) => s.collect !== "file").map((s) => `<span class="ro" title="${esc(s.feature)}">${esc(s.name)} · ${esc(STATUS[s.status] || s.status)}</span>`).join(" ")}</span></div>
    <p class="foot"><b>Saved to</b> the store each secret names · takes effect the next time the feature reads it · <b>Jira values:</b> now in the <a href="#/config?tile=tracker">Tracker tile</a></p>`;
}

// CodeRabbit is reviewer 1's install state, so it sits with the reviewers rather than in a step of its own.
function crFold(c) {
  if (!c) return "";
  const st = `<span class="st ${c.installed === "installed" ? "ok" : "warn"}">${esc(CR_STATE[c.installed] || c.installed)}</span>`;
  return `<div class="setrow"><div class="sethead"><span class="id">CodeRabbit review</span><span class="det">${esc(c.requirement)} add-on · gates ${c.armed ? "armed" : "not armed"} in this clone</span><span class="slot">${st}</span></div>
    <details class="more"><summary>what it is, and how to install it</summary><p class="sub">${esc(c.what)}</p>
    <ol class="sub">${c.steps.map((t) => `<li>${esc(t)}</li>`).join("")}</ol>${c.manual ? `<p class="sub" role="status">${esc(c.manual)}</p>` : ""}</details></div>`;
}

function reviewPanel({ setup, feed, state }) {
  const lanes = feed ? renderSettingsGroups(feed, state, ["review"], 3) : loading("the station report");
  return `${renderReviewGate(state.reviewGate, crFold(setup && setup.coderabbit))}${lanes}
    <p class="foot"><b>Saved to</b> <code>~/.claude/himmel/critics.local.json</code> and <code>lanes.local.json</code> · takes effect the next time work is handed to a reviewer</p>`;
}

// Two columns, one shared dry-run box: a tracker change and a ticket-rule change both preview into it. With the tracker on
// Local or None no connection is needed, so the Jira rows go; one that still holds a value stays so it can be removed.
function trackerPanel({ setup, state, msgs }) {
  if (!setup || setup.error) return setupFailed(setup);
  const c = setup.commit, plans = state.plans || {};
  const connected = c.tracker !== "local" && c.tracker !== "none";
  const connection = setup.secrets.filter(isJira).filter((s) => connected || s.status === "set").sort((a, b) => JIRA_ORDER.indexOf(a.name) - JIRA_ORDER.indexOf(b.name)).map((s) => secretRow(s, msgs[s.name], true)).join("");
  const open = [TK, RK].filter((k) => plans[k]);
  return `<p class="sub">Where your tickets live, and what every commit must carry. Each change shows a dry run before it writes.</p>
    <div class="cols">
    <div class="col"><h3>Connection · where tickets live</h3>${trackerRow(c)}${connection}
      <p class="sub">Hidden when the tracker is Local or None, because those need no connection; a value already saved stays listed so you can remove it. A save here uses the same writer as Secrets.</p></div>
    <div class="col"><h3>Commit rules · what a commit carries</h3>${ticketRow(c, true)}
      <div class="srow"><span class="id">Ticket pattern <span class="tag">read-only</span></span><span class="det">From <code>JIRA_PROJECT_KEY</code>; your own <code>TICKET_ID_PATTERN</code> in <code>~/.himmel/himmel.conf</code> wins. Typed in the terminal.</span></div></div></div>
    ${open.length ? `<div class="dryrun">${open.map((k) => planHtml(k, plans[k])).join("")}</div>` : ""}
    <p class="foot"><b>Saved to</b> <code>~/.himmel/himmel.conf</code> (tracker, rule) and the himmel <code>.env</code> (the four Jira values) after a dry run you confirm · takes effect on your next commit</p>`;
}

function scopePanel({ setup, feed, state }) {
  const plans = state.plans || {};
  const group = (ids, fold) => (feed ? renderSettingsGroups(feed, state, ids, fold) : loading("the station report"));
  const choices = setup && setup.choices;
  const paths = !setup || setup.error ? setupFailed(setup)
    : choices ? `<div class="setgroup"><h3>Paths</h3><p class="sub">Each path is written to <code>~/.himmel/himmel.conf</code> by <code>himmelctl config set</code> after a dry run you confirm. A path is absolute, with no <code>.</code> or <code>..</code> part, quote, <code>#</code>, <code>$</code> or backslash.</p>${pathRows(choices, plans)}${forgeRow(choices)}</div>` : "";
  return `<p class="sub">What himmel does on its own in this install, which plugins and jobs it runs, and where its state lives. Each switch shows a dry run before it writes.</p>
    ${group(["auto-ship"])}${group(["plugins"], 3)}${group(["scheduled-jobs"])}${paths}
    <div class="setgroup"><h3>This machine</h3>${renderFleetCap(state.fleetCap)}${renderVm(state.vm)}</div>
    ${group(["install-answers"])}
    <p class="foot"><b>Saved to</b> the himmel <code>.env</code> (auto-ship, fleet cap), <code>~/.himmel/himmel.conf</code> (paths), <code>~/.himmel/config.json</code> (VM), your crontab (jobs), the plugins' user-scope state · each change takes effect as its row says</p>`;
}

const PANELS = { secrets: secretsPanel, review: reviewPanel, tracker: trackerPanel, scope: scopePanel };

// feed: the doctor feed or null. c = { tile, setup: GET /api/setup or null, state: the app state (plans, reviewGate, fleetCap, vm), msgs, verify }.
// The tile is the one open group; null opens none. Setup and the feed load apart, so each panel says "loading" for only what it still lacks.
// app.js imports this as `render` (tests/slow.test.ts stubs that name), hence the feed first.
export function renderConfigure(feed, config) {
  const c = { ...config, feed };
  const tiles = TILES.map((id) => `<button class="tile g-${id}" type="button" data-act="tile" data-tile="${id}" aria-expanded="${c.tile === id}">
      <span class="ic" aria-hidden="true">${TILE_ICON[id]}</span><span class="tname">${TILE_NAME[id]}</span><span class="tval">${esc(tileValue(id, c))}</span>${tileChip(id, c)}</button>`).join("");
  const panel = PANELS[c.tile];
  return `<h2 id="h-configure">Configure</h2><p class="sub">Change what himmel does, any time.</p>
    <div class="tiles">${tiles}</div>
    ${panel ? "" : checkStrip(c.verify)}
    ${panel ? `<div class="cpanel" id="tile-${c.tile}" role="region" aria-label="${TILE_NAME[c.tile]}">${panel(c)}</div>` : ""}
    <p class="not"><b>Not here, on purpose:</b> the safety hooks (<code>EDIT_ON_MAIN_OK=1</code>, <code>READ_SECRETS_OK=1</code>, <code>DESTRUCTIVE_OK=1</code>, <code>.single-writer</code>). Set one in the shell that starts Claude Code. <b>Moved to Health:</b> Triage and Inventory (<a href="#/health">open Health</a>).</p>`;
}

export function renderSetup(setup, plans, msgs, verify = null) {
  const head = `<h2>Setup</h2>`;
  if (!setup) return `${head}<p class="sub">loading…</p>`;
  if (setup.error) return `${head}<div class="nodata" role="alert">${esc(setup.error)}</div>`;
  return `${head}${account(setup.account, msgs.account)}
    <p class="sub">A secret you save here goes to this machine over a loopback connection, bound to this launch's token; it is never shown again. This page shows only whether each secret is set, never its value. With no browser available, <code>himmelctl install</code> asks for secrets in the terminal instead.</p>
    <h3>Secrets</h3>${setup.secrets.map((s) => secretRow(s, msgs[s.name])).join("")}
    ${coderabbit(setup.coderabbit)}
    ${commitRules(setup.commit, plans)}
    ${setupChoices(setup.choices, plans)}
    ${verifyStep(verify)}`;
}
