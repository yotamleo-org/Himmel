// The Setup page: which secrets are set (presence only, never a value), a form to set or remove one, the commit rules, and the Verify step.
// A value lives in the password field until the request is sent and the field is cleared at once: it is never kept in
// page state, localStorage or the markup, and the server answers with the name and the new status only.
import { category, copyCommand, esc, pg, planHtml, renderFleetCap, renderReports, renderReviewGate, renderSettingsGroups, renderVm } from "./render.js";
import { TILES, docsHref } from "./nav.js";

const STATUS = { set: "set", "not-set": "not set", placeholder: "placeholder", probe: "checked in the terminal" };
const TRACKERS = [["jira", "Jira"], ["local", "Local"], ["none", "None"]];

const JIRA_LABEL = { JIRA_BASE_URL: "Site", JIRA_EMAIL: "Email", JIRA_API_TOKEN: "API token", JIRA_PROJECT_KEY: "Project key" };
const JIRA_ORDER = Object.keys(JIRA_LABEL);
const TEXT_FIELDS = new Set(["JIRA_EMAIL", "JIRA_BASE_URL", "JIRA_PROJECT_KEY"]);
const revealButton = (name) => `<button class="btn" type="button" data-act="reveal" data-reveal="${esc(name)}" aria-pressed="false" aria-label="Show ${esc(name)}">show</button>`;

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
      <input type="${TEXT_FIELDS.has(s.name) ? "text" : "password"}" data-secret="${esc(s.name)}" autocomplete="${TEXT_FIELDS.has(s.name) ? "off" : "new-password"}" spellcheck="false" aria-label="${esc(s.name)} value"${cfg && s.example ? ` placeholder="e.g. ${esc(s.example)}"` : ""}>
      ${cfg ? `<span class="acts">${TEXT_FIELDS.has(s.name) ? "" : revealButton(s.name)}<button class="btn primary" type="submit">save</button>${remove}</span>` : `${TEXT_FIELDS.has(s.name) ? "" : revealButton(s.name)}<button class="btn primary" type="submit">save</button>${remove}`}</form>
    ${s.example && !cfg ? `<span class="ro">e.g. ${esc(s.example)}</span>` : ""}
    ${msg ? `<span class="ro" role="status">${esc(msg)}</span>` : ""}</div>`;
}

const CR_STATE = { installed: "installed", "not-installed": "not detected", unknown: "not checked" };

function coderabbit(c) {
  if (!c) return "";
  const st = `<span class="st ${c.installed === "installed" ? "ok" : "warn"}">${esc(CR_STATE[c.installed] || c.installed)}</span>`;
  return `<details class="more"${c.installed === "installed" ? "" : " open"}><summary>CodeRabbit · ${st} · ${esc(c.requirement)} add-on · gates ${c.armed ? "armed" : "not armed"} in this clone</summary>
    <p class="sub">${esc(c.what)}</p>
    <ol class="sub">${c.steps.map((t) => {
      const prefix = "Arm the gates for this clone: ";
      return `<li>${t.startsWith(prefix) ? `${esc(prefix)}${copyCommand(t.slice(prefix.length))}` : esc(t)}</li>`;
    }).join("")}</ol>
    ${c.manual ? `<p class="sub" role="status">${esc(c.manual)}</p>` : ""}</details>`;
}

function choice(label, action, target, value, current, k, disabled) {
  const on = current === value;
  return `<button class="btn${on ? " primary" : ""}" data-act="plan" data-action="${action}" data-target="${target}" data-value="${value}" data-k="${k}" aria-pressed="${on}"${disabled ? " disabled" : ""}>${esc(label)}</button>`;
}

const TK = "setup|tracker", RK = "setup|ticket-id-required", MK = "setup|team-mode";
const ON_OFF = [["on", "On"], ["off", "Off"]];

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
const PATH_WHY = { "handover-root": "The folder where himmel keeps the notes that let one session pick up from another.", "luna-vault": "The folder of your luna note vault." };

// Where handover state and the luna vault live, each change a dry run first; the forge is shown as detected; the
// remaining choices are the Settings page's toggles, linked here rather than repeated.
// plain: the Configure scope tile's look, one sentence and no key name or default path.
function pathRows(c, plans, plain = false) {
  return c.paths.map((p) => {
    const k = `setup|${p.target}`;
    const shown = (plans[k] && plans[k].req && plans[k].req.value) || p.value || "";
    const det = plain ? (p.value ? "takes effect on the next Claude launch" : "not set yet · himmel uses its default folder")
      : p.value ? `${esc(p.key)} · takes effect on the next Claude launch` : `not set · default: ${esc(p.fallback)}`;
    return `<div class="srow"><span class="id">${esc(PATH_LABEL[p.target] || p.target)}</span>
      <span class="det">${det}</span>${plain ? `<p class="why">${esc(PATH_WHY[p.target] || "")}</p>` : ""}
      <form class="sform" data-path-form data-target="${esc(p.target)}" autocomplete="off">
        <input type="text" data-path="${esc(p.target)}" value="${esc(shown)}" spellcheck="false" placeholder="/absolute/path" aria-label="${esc(PATH_LABEL[p.target] || p.target)}">
        <button class="btn" type="submit">preview</button></form></div>
      ${plans[k] ? planHtml(k, plans[k]) : ""}`;
  }).join("");
}

// plain: the Configure scope tile's look. The source code host is where the repository lives, GitHub or Bitbucket; the
// Bitbucket credentials are secrets, so they are entered in the Secrets tab and this row only points there.
function forgeRow(c, plain = false) {
  const f = c.forge || {};
  if (plain) {
    return `<div class="srow"><span class="id">Source code host</span>
    <span class="det">${f.error ? esc(f.error) : `detected: ${esc(f.value)}`}</span>
    <p class="why">Where your repository lives: GitHub or Bitbucket. Bitbucket sign-in details are entered in the <a href="#/config?tile=secrets">Secrets tab</a>, like every other secret.</p>
    <span class="ro">Read-only here; <a class="learn" href="${docsHref("/configuration/")}" target="_blank" rel="noopener">learn how to change it</a>.</span></div>`;
  }
  return `<div class="srow"><span class="id">Forge</span>
    <span class="det">${f.error ? esc(f.error) : `detected: ${esc(f.value)}`}</span>
    <span class="ro">set <code>FORGE</code> or Git's <code>himmel.forge</code> setting in the terminal</span></div>`;
}

function setupChoices(c, plans) {
  if (!c) return "";
  const rows = pathRows(c, plans), forge = forgeRow(c);
  return `<h3>Setup choices</h3>
    <p class="sub">Each path is written to <code>~/.himmel/himmel.conf</code> by the path config writer after a dry run you confirm. A path is absolute, with no <code>.</code> or <code>..</code> part, quote, <code>#</code>, <code>$</code> or backslash.</p>
    ${rows}${forge}
    <p class="sub">Plugin set, Review by a second model and Auto-ship steps are toggles on <a href="#/config">the Settings page</a>.</p>`;
}

// The first-run Account step: the UI login the always-on UI asks for. The page creates it once; changing it is a terminal step.
function account(a, msg, cfg) {
  if (!a) return "";
  const note = msg ? `<p class="sub" role="status">${esc(msg)}</p>` : "";
  if (a.status === "set") return `<h3>Account</h3><p class="sub">The UI login is set for <code>${esc(a.user)}</code>. Log in with it at <code>/login</code> on the always-on UI. To change it, run ${copyCommand(a.setLogin)} in your own terminal.</p>${note}`;
  if (a.create !== "ui") return `<h3>Account</h3><p class="sub">${a.status === "unreadable" ? "The login file cannot be read. " : "No UI login is set yet. "}Set it with ${copyCommand(a.setLogin)} in your own terminal.</p>${note}`;
  return `<h3>Account</h3><p class="sub">Create the login for the always-on UI first: it asks for this user and password before it saves a secret. The password is at least 8 characters and is kept only as a hash.</p>
    <form class="sform" data-account-form autocomplete="off">${cfg ? `
      <label class="fld">User<input type="text" data-account="user" autocomplete="username" spellcheck="false" placeholder="a user name"></label>
      <label class="fld">Password<input type="password" data-account="password" autocomplete="new-password" placeholder="at least 8 characters"></label>${revealButton("password")}
      <label class="fld">Password again<input type="password" data-account="confirm" autocomplete="new-password" placeholder="the same password"></label>${revealButton("confirm")}` : `
      <input type="text" data-account="user" autocomplete="username" spellcheck="false" aria-label="user name">
      <input type="password" data-account="password" autocomplete="new-password" aria-label="password">${revealButton("password")}
      <input type="password" data-account="confirm" autocomplete="new-password" aria-label="password again">${revealButton("confirm")}`}
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
      <button class="btn" type="button" data-act="open-config" data-id="doctor:${esc(f.id)}">Open in Health</button></div>`).join("");
  return `${head}${summary}${rows || `<p class="sub" role="status">Nothing to fix.</p>`}${run("run again")}`;
}

// ---- the Configure page: Settings and Setup as four group tiles, one open at a time, under a Check this install strip ----
const TILE_NAME = { secrets: "Secrets", review: "Review", tracker: "Tracker", scope: "Project scope" };
const TILE_ICON = { secrets: "⚿", review: "✓", tracker: "#", scope: "▶" };
const isJira = (s) => s.name.startsWith("JIRA_");
// With the tracker on Local or None no Jira connection is needed, so its rows go; one that still holds a value stays so it can be removed.
const jiraShown = (setup, s) => (setup.commit.tracker !== "local" && setup.commit.tracker !== "none") || s.status === "set";
const savedHere = (setup) => setup.secrets.filter((s) => s.collect === "file" && (!isJira(s) || jiraShown(setup, s)));
const TRACKER_NAME = Object.fromEntries(TRACKERS);
const REVIEWER_NAME = { codex: "GPT", claude: "Claude", coderabbit: "CodeRabbit" };

// What a tile holds right now, read from the data the panels already use; "" until that data is loaded.
function tileValue(id, { setup, state }) {
  const ok = setup && !setup.error;
  if (id === "secrets") {
    const own = ok ? savedHere(setup) : [];
    const login = ok && setup.account ? (setup.account.status === "set" ? " · login set" : " · no login yet") : "";
    return ok ? `${own.filter((s) => s.status === "set").length} of ${own.length} set${login}${rolesTileText(state)}` : "";
  }
  if (id === "review") {
    const d = state.reviewGate && state.reviewGate.data;
    return d ? d.reviewers.filter((r) => r.enabled !== false).map((r) => `${REVIEWER_NAME[r.slug] || r.slug} ${r.required ? "must pass" : "notes"}`).join(" · ") : "";
  }
  if (id === "tracker") return ok ? TRACKER_NAME[setup.commit.tracker] || "not set" : "";
  const fc = state.fleetCap && state.fleetCap.data, vm = state.vm && state.vm.data, rp = state.reports && state.reports.data;
  return [fc && `fleet cap ${fc.cap}`, vm && `VM ${vm.mode}`, rp && `report day ${rp.report_day}`].filter(Boolean).join(" · ");
}

// Only the review gate carries a recommendation, so only the Review tile can say it matches our pick.
function tileChip(id, { state, setup }) {
  if (id === "secrets") {
    const t = setup && !setup.error && setup.secrets.find((s) => s.name === "TELEGRAM_BOT_TOKEN");
    if (t && t.status !== "set") return `<span class="m diff">Telegram not set</span>`;
    const m = state.apiRoles && state.apiRoles.data && state.apiRoles.data.roleMap;
    return m && (m.state === "partial" || m.state === "invalid") ? `<span class="m diff">check</span>` : "";
  }
  const d = id === "review" && state.reviewGate && state.reviewGate.data;
  if (!d) return "";
  const rec = d.reviewers.filter((r) => r.recommended);
  const same = rec.length > 0 && !(d.dropped || []).length && rec.every((r) => r.recommended.mode === r.mode && r.recommended.required === r.required && r.recommended.enabled);
  return same ? `<span class="m ok">matches our pick</span>` : "";
}

// Which doctor checks count as setup: what this install needs to be set up correctly (its prerequisites, wiring,
// configuration files and tracker). Every other check, such as a stale worktree or the search index, is a health check
// and is listed only on the Health page. Keyed by the check number: a check may emit several rows (C74-himmel-conf,
// C74-env-keys, ...). Only WARN and FAIL rows reach the strip, so each reason says what the doctor warns about. A test
// reads himmel-doctor.sh: a number here must still emit a warning or failure, and a new check must be classified.
export const SETUP_CHECKS = [
  { id: "C1", reason: "The user-level guardrail hooks point at a node that exists; a missing node makes every tool call error and the guardrails fail open." },
  { id: "C6", reason: "No MCP server is wired as a bare interpreter, such as uvx, bun or node, which a GUI launch's minimal PATH may lack even when this host has it; no hook leads with a bare interpreter this host lacks." },
  { id: "C9", reason: "A scheduler backend (at with atd running, or crontab) is available, so an armed resume can fire." },
  { id: "C13", reason: "The himmel-ops plugin hooks point at hook scripts that exist in this checkout; a missing one makes the hook do nothing, silently." },
  { id: "C15", reason: "Enabled plugins stay at the lean floor; each extra one adds context cost at the start of every session." },
  { id: "C16", reason: "himmelctl status finds no install or wiring problem." },
  { id: "C17", reason: "Every enabled skill has the API key it declares, and no ready toolkit is marked disabled in a doc." },
  { id: "C20", reason: "The running Node major matches the one .nvmrc pins; the hooks, the Jira tool and the test suites run on it." },
  { id: "C28", reason: "The guardrail hook is wired into your global settings, or you declined it on record; otherwise nothing enforces it." },
  { id: "C32", reason: "The hook that refuses a commit or push straight to main is installed, executable and has its target script." },
  { id: "C38", reason: "uv is on PATH; graphify is uv-managed and neither installs nor updates without it." },
  { id: "C39", reason: "On macOS a working timeout or gtimeout is on PATH; graph refresh runs unbounded without it." },
  { id: "C43", reason: "The user settings carry no bare rtk hook, which bypasses the rtk hook guard." },
  { id: "C46", reason: "Every plugin the settings enable is installed." },
  { id: "C53", reason: "The test VM mode resolves to a VM, and a remote VM answers at its host and port; otherwise every VM-proof hold stays held." },
  { id: "C55", reason: "The project resolves to one tracker and one source code host." },
  { id: "C62", reason: "bunx or bun is on PATH; without it the oxlint commit gates are skipped on every commit." },
  { id: "C63", reason: "Claude Code meets the minimum version that chief and worker launches need." },
  { id: "C65", reason: "The git gate hooks are installed and run (core.hooksPath stays in this repo, none is a stub), jq is on PATH for the gates, and main's branch protection requires status checks." },
  { id: "C73", reason: "Compiled Bun binaries embed a Bun at least as new as .bun-version." },
  { id: "C74", reason: "himmel.conf, .env, the gate policy file and the config keys are readable and well formed, and behaviour keys sit in himmel.conf." },
  { id: "C75", reason: "The OS keyring answers and himmel-secrets reads it, secrets are not served from .env, and every served credential has its setting." },
  { id: "C78", reason: "shfmt is on PATH; without it the Bash guards deny commands that name a stash, ref-plumbing or graphify verb." },
  { id: "C81", reason: "No hook script is wired from more than one settings layer, so none runs twice per call." },
  { id: "C85", reason: "The queue lock self-heartbeat hook is wired for every tool and hooks are not disabled; without it a long worker's lock goes stale after one TTL." },
];
const SETUP_IDS = new Set(SETUP_CHECKS.map((c) => c.id));
// A doctor row id is the check number, then an optional "-name": C74-env-keys is C74, and C44-skill-index is not C4.
export const isSetupCheck = (id) => {
  const m = /^(C\d+)(?:-|$)/.exec(String(id));
  return !!m && SETUP_IDS.has(m[1]);
};

// The strip shows the setup findings only. The verify answer totals every check, so its counts are not used here: the
// fail and warn counts come from the setup findings, and there is no ok count for the subset. The findings outside the
// setup list are counted apart, so a clean setup never sits beside a failure this page does not show.
function checkStrip(v) {
  const run = (label) => `<button class="btn primary" type="button" data-act="setup-verify">${label}</button>`;
  const head = `<b>Check this install</b><span class="sub">Read-only: nothing is fixed or changed, and no secret value is shown. This lists the setup checks; <a href="#/health">the Health page</a> lists every check.</span>`;
  if (!v) return `<div class="chk">${head}<span class="det">not run yet</span>${run("run the checks")}</div>`;
  if (v.state === "running") return `<div class="chk">${head}<span class="det" role="status">running… this can take a minute or two</span></div>`;
  if (v.state !== "done") return `<div class="chk">${head}<span class="nodata" role="alert">${esc(v.error || "the checks did not finish")}</span>${run("run again")}</div>`;
  const mine = v.findings.filter((f) => isSetupCheck(f.id)), rest = v.findings.filter((f) => !isSetupCheck(f.id));
  const nFail = (list) => list.filter((f) => f.sev === "FAIL").length;
  const fail = nFail(mine), warn = mine.length - fail;
  const elsewhere = rest.length ? `<span class="sub">Not setup, so only on <a href="#/health">the Health page</a>: ${nFail(rest)} fail, ${rest.length - nFail(rest)} warn.</span>` : "";
  const rows = mine.map((f) => `<div class="srow"><span class="id">${esc(f.id)}</span>
      <span class="det"><span class="st ${f.sev === "FAIL" ? "fail" : "warn"}">${esc(f.sev.toLowerCase())}</span> ${esc(f.msg)}${f.remedy ? ` · fix: ${esc(f.remedy)}` : ""}</span>
      <button class="btn" type="button" data-act="open-config" data-id="doctor:${esc(f.id)}">Open in Health</button></div>`).join("");
  return `<div class="chk">${head}<span class="summary"><span class="st fail">${fail} fail</span> <span class="st warn">${warn} warn</span> <span class="sub">in the setup checks</span></span>${elsewhere}${run("run again")}</div>
    ${rows || `<p class="sub" role="status">Nothing to fix in the setup checks.</p>`}`;
}

const loading = (what) => `<p class="sub" role="status">loading ${what}…</p>`;
const setupFailed = (setup) => (setup ? `<div class="nodata" role="alert">${esc(setup.error)}</div>` : loading("this install's setup"));

// ---- Multi accounts: which API account may serve each kind of run on auto. The data is GET /api/api-roles:
// the role map's state and live roles, ROLES, one row per account and the account letters. The page holds no role list.
const ROLE_NOTE = { graphify: "every configured account (the himmel graph pass)", judge: "the subscription, no API account" };
const BANK_STYLE = { "not configured": "off", unknown: "warn", "marked exhausted": "fail", "no room": "fail", "last resort": "warn", "no reading": "warn", "stale reading": "warn", room: "ok" };
const ROLES_FILE = "~/.himmel/state/api-credit/roles.json";

// the editor's starting map: the live entries, so saving a partial or invalid file repairs it
export function apiRolesDraft(data) {
  const out = {};
  for (const [role, letters] of Object.entries((data && data.roleMap && data.roleMap.roles) || {})) out[role] = [...letters];
  return out;
}

const roleLine = (role, letters) => `"${role}": [${letters.map((l) => JSON.stringify(l)).join(", ")}]`;

// The file text before and after a save, computed in the page from the stored and the pending map: no server call.
export function rolesPreview(current, draft) {
  const text = (roles) => (Object.keys(roles).length ? JSON.stringify({ version: 1, roles }, null, 2) : null);
  const diff = [];
  let changes = 0;
  for (const role of new Set([...Object.keys(current), ...Object.keys(draft)])) {
    const was = current[role] ? roleLine(role, current[role]) : null, now = draft[role] ? roleLine(role, draft[role]) : null;
    if (was === now) { diff.push({ sign: " ", text: was }); continue; }
    changes++;
    if (was) diff.push({ sign: "-", text: was });
    if (now) diff.push({ sign: "+", text: now });
  }
  return { before: text(current) || "no file", after: text(draft) || (Object.keys(current).length ? "file removed" : "no file"), diff, changes };
}

function roleErrorLine(code, roles) {
  let m;
  if ((m = /^unknown-account:([^:]+):(.*)$/.exec(code))) return `${m[1]} → "${m[2]}" dropped: not an account${roles[m[1]] ? `; ${m[1]} is kept as [${roles[m[1]].join(",")}]` : ""} (${code})`;
  if ((m = /^unknown-role:(.*)$/.exec(code))) return `"${m[1]}" is not a role, entry ignored (${code})`;
  if ((m = /^empty-role:(.*)$/.exec(code))) return `${m[1]} has no account, entry ignored (${code})`;
  if ((m = /^invalid-role-map:(.*)$/.exec(code))) return `the file cannot be used: ${m[1]} (${code})`;
  return code;
}

function roleWarningLine(code, roles) {
  const role = code.replace(/^no-configured-account:/, ""), letters = roles[role] || [], many = letters.length > 1;
  return `${role} is mapped only to ${letters.join(", ")}, which ${many ? "are" : "is"} not configured: every auto ${role} call is refused until ${many ? "one is" : "it is"} configured or the entry changes (${code})`;
}

function accountRows(d) {
  const map = d.roleMap;
  if (!d.rows) return `<div class="srow"><span class="id">Accounts</span><span class="det"><span class="st fail wrap">account config unreadable${d.accountsReason ? `: ${esc(d.accountsReason)}` : ""}; fix config.json</span></span></div>`;
  const body = d.rows.map((r) => {
    const mapped = d.ROLES.filter((role) => (map.roles[role] || []).includes(r.account));
    const roles = mapped.length
      ? `<span class="chips">${mapped.map((role) => `<span class="ro">${esc(role)}</span>`).join(" ")}</span>${r.configured === false ? ` <span class="det">skipped at pick time</span>` : ""}`
      : map.state === "absent" && r.configured ? `<span class="det">graph pass (default)</span>` : "—";
    const tag = `<span class="st ${BANK_STYLE[r.tag] || "warn"}">${esc(r.tag)}${r.reason ? ` (${esc(r.reason)})` : ""}</span>`;
    const cap = r.cap_usd == null ? "—" : `$${esc(String(Number(r.cap_usd)))} cap`;
    return `<tr data-account-row="${esc(r.account)}"><th scope="row">${esc(r.account)}</th><td>${r.configured == null ? "unknown" : r.configured ? "configured" : "not configured"}</td><td>${cap}</td><td>${tag}</td><td>${roles}</td></tr>`;
  }).join("");
  return `<div class="scroll"><table class="roles-table"><thead><tr><th>Account</th><th>Configured</th><th>Cap</th><th>Bank</th><th>Roles</th></tr></thead><tbody>${body}</tbody></table></div>`;
}

function roleEditor(d, ar) {
  const draft = ar.draft || {};
  const toggles = (role) => (d.letters || []).map((l) => {
    const on = (draft[role] || []).includes(l);
    return `<button class="btn${on ? " primary" : ""}" type="button" data-act="role-toggle" data-role="${esc(role)}" data-account="${esc(l)}" aria-pressed="${on}">${esc(l)}</button>`;
  }).join(" ");
  const rows = d.ROLES.map((role) => `<tr><th scope="row">${esc(role)}</th><td>${toggles(role)}</td><td class="det">${esc(ROLE_NOTE[role] || "auto is refused")}</td></tr>`).join("");
  const p = rolesPreview(apiRolesDraft(d), draft);
  const missing = (d.rows || []).filter((r) => r.configured === false && Object.values(draft).some((ls) => ls.includes(r.account))).map((r) => r.account);
  const preview = ar.preview ? `<div class="dryrun"><b>Preview (in the page, not saved)</b> <code>${ROLES_FILE}</code>
      <pre>${p.diff.map((l) => `${l.sign} ${esc(l.text)}`).join("\n") || esc(p.after)}</pre>
      ${p.after === "file removed" ? `<p class="sub">An empty map removes the file: the defaults apply.</p>` : ""}
      ${missing.map((l) => `<p class="sub">${esc(l)} is not configured: it is kept and skipped at pick time until a ${esc(l)} row exists.</p>`).join("")}</div>` : "";
  const msg = ar.msg ? `<span class="${ar.msg.ok ? "ok-t" : "bad-t"}" role="status">${esc(ar.msg.text)}</span>` : "";
  return `<h4>Edit roles</h4>
    <p class="sub">Press an account to let it serve that kind of run on auto. A row with no account uses the default in its last column.</p>
    <div class="scroll"><table class="roles-table roles-edit"><thead><tr><th>Role</th><th>Accounts</th><th>With no account</th></tr></thead><tbody>${rows}</tbody></table></div>
    <p class="sub">critic, eval, bulk and cull get a row when their callers route auto.</p>
    ${preview}
    <div class="srow"><span class="det">${p.changes ? `${p.changes} change${p.changes === 1 ? "" : "s"} · not saved` : "no changes"}</span>
      <span class="acts"><button class="btn" type="button" data-act="roles-preview">Preview</button> <button class="btn primary" type="button" data-act="roles-save">Save</button> <button class="btn" type="button" data-act="roles-cancel">Cancel</button></span>${msg}</div>`;
}

function multiAccounts({ state }) {
  const head = `<h3>Multi accounts</h3>`, ar = state && state.apiRoles;
  if (!ar || (!ar.data && !ar.error)) return `${head}${loading("the role map")}`;
  if (!ar.data) return `${head}<div class="nodata" role="alert">${esc(ar.error)}</div>`;
  const d = ar.data, map = d.roleMap;
  const intro = `<p class="sub">Which API account may serve each kind of run when a caller asks for <code>auto</code>. A run that names its account (A, B or C) is not affected. Roles never widen auto beyond the himmel repo.</p>`;
  let card = "";
  if (map.state === "absent") card = `<div class="card role-card"><h3>No roles set: the defaults apply</h3><p class="sub">Only the himmel graph pass uses auto, on any configured account. The judge runs on the subscription. A run that names A, B or C is not affected. To let an account serve a role, use Edit roles.</p></div>`;
  else if (map.state === "partial" || map.state === "invalid") {
    const n = map.errors.length;
    card = `<div class="card crit role-card" role="alert"><h3>${map.state === "partial" ? `Role map: ${n} error${n === 1 ? "" : "s"}; the other entries still apply` : "Role map: the whole file is ignored, the defaults apply"}</h3>
      <p class="sub">An ignored role falls back to its default. Nothing else is refused, and the account money config is untouched.</p>
      <ul>${map.errors.map((e) => `<li>${esc(roleErrorLine(e, map.roles))}</li>`).join("")}</ul></div>`;
  }
  const warn = (d.warnings || []).length ? `<div class="card warn role-card" role="status"><ul>${d.warnings.map((w) => `<li>${esc(roleWarningLine(w, map.roles))}</li>`).join("")}</ul></div>` : "";
  return `${head}${intro}${card}${warn}${accountRows(d)}${roleEditor(d, ar)}
    <p class="sub">Roles are saved to <code>${ROLES_FILE}</code> (no secret in it; the account money config is never written) · takes effect on the next auto call</p>`;
}

// the Secrets tile's role text: up to two roles, "default roles" with no map, "role map error" for a broken one; "" until loaded
function rolesTileText(state) {
  const d = state.apiRoles && state.apiRoles.data;
  if (!d) return "";
  const { state: s, roles } = d.roleMap, entries = Object.entries(roles);
  if (s === "partial" || s === "invalid") return " · role map error";
  return entries.length ? ` · ${entries.slice(0, 2).map(([role, letters]) => `${role}→${letters.join(",")}`).join(" · ")}` : " · default roles";
}

function secretsPanel({ setup, msgs, state }) {
  if (!setup || setup.error) return setupFailed(setup);
  const own = setup.secrets.filter((s) => !isJira(s));
  const jira = setup.secrets.filter((s) => isJira(s) && jiraShown(setup, s)).sort((a, b) => JIRA_ORDER.indexOf(a.name) - JIRA_ORDER.indexOf(b.name));
  return `<p class="sub">A secret you save here goes to this machine over a loopback connection, bound to this launch's token; it is never shown again. This page shows only whether each secret is set, never its value. With no browser available, ${copyCommand("himmelctl install")} asks for secrets in the terminal instead.</p>
    ${account(setup.account, msgs.account, true)}
    ${own.filter((s) => s.collect === "file").sort((a, b) => (a.required !== "required") - (b.required !== "required")).map((s) => secretRow(s, msgs[s.name], true)).join("")}
    ${jira.length ? `<h3>Jira · where tickets live</h3>${jira.map((s) => secretRow(s, msgs[s.name], true)).join("")}
      <p class="sub">Shown while the tracker is Jira; a value already saved stays listed so you can remove it. The tracker itself is chosen in the <a href="#/config?tile=tracker">Tracker tile</a>.</p>` : ""}
    <div class="srow"><span class="id">Set in the terminal <span class="tag">read-only</span></span><span class="det">These are collected by their feature's own setup card, so the page shows only whether each is set.</span><span class="chips">${own.filter((s) => s.collect !== "file").map((s) => `<span class="ro" title="${esc(s.feature)}">${esc(s.name)} · ${esc(STATUS[s.status] || s.status)}</span>`).join(" ")}</span></div>
    ${multiAccounts({ state })}
    <p class="foot"><b>Saved to</b> the store each secret names · takes effect the next time the feature reads it</p>`;
}

// CodeRabbit is reviewer 1's install state, so it sits with the reviewers rather than in a step of its own.
function crFold(c) {
  if (!c) return "";
  return `<div class="setrow">${coderabbit(c)}</div>`;
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
  const open = [TK, RK, MK].filter((k) => plans[k]);
  return `<p class="sub">Where your tickets live, and what every commit must carry. Each change shows a dry run before it writes.</p>
    <div class="cols">
    <div class="col"><h3>Connection · where tickets live</h3>${trackerRow(c)}
      <p class="sub">Jira's site, email, API token and project key are entered in the <a href="#/config?tile=secrets">Secrets tab</a>, like every other secret.</p></div>
    <div class="col"><h3>Commit rules · what a commit carries</h3>${ticketRow(c, true)}
      <div class="srow"><span class="id">Ticket pattern <span class="tag">read-only</span></span><span class="det">From <code>JIRA_PROJECT_KEY</code>; your own <code>TICKET_ID_PATTERN</code> in <code>~/.himmel/himmel.conf</code> wins. Typed in the terminal.</span></div>
      <h3>Board · who edits this Jira project</h3>
      <div class="srow"><span class="id">Team mode</span><span class="det">Off: only you and himmel edit this project, so a real drift on the Board is a himmel bug and the doctor WARNs. On: several people edit Jira, so a drift is ordinary tidy-up and the doctor only reports it.</span>
        <span>${ON_OFF.map(([v, l]) => choice(l, "config.tracker", "team-mode", v, c.teamMode, MK)).join(" ")}</span></div></div></div>
    ${open.length ? `<div class="dryrun">${open.map((k) => planHtml(k, plans[k])).join("")}</div>` : ""}
    <p class="foot"><b>Saved to</b> <code>~/.himmel/himmel.conf</code> (tracker, rule, Team mode) after a dry run you confirm · takes effect on your next commit; Team mode on the next Board read and doctor run</p>`;
}

function scopePanel({ setup, feed, state }) {
  const plans = state.plans || {};
  const group = (ids, fold) => (feed ? renderSettingsGroups(feed, state, ids, fold, true) : loading("the station report"));
  const choices = setup && setup.choices;
  const unread = !setup || setup.error;
  // Five categories, the first open; each opens and closes on its own and keeps that for the session (render.js category()).
  const host = unread ? setupFailed(setup) : choices ? `<div class="setgroup">${forgeRow(choices, true)}</div>` : "";
  const folders = unread ? setupFailed(setup)
    : choices ? `<div class="setgroup"><p class="sub">Each folder change shows a dry run you confirm before it writes. A folder is an absolute path, with no <code>.</code> or <code>..</code> part, quote, <code>#</code>, <code>$</code> or backslash.</p>${pathRows(choices, plans, true)}</div>` : "";
  return `<p class="sub">What himmel does on its own in this install, which plugins and jobs it runs, and where its state lives. Each switch shows a dry run before it writes.</p>
    ${category("automation", "Automation: auto-ship, plugins and scheduled jobs", `${group(["auto-ship"])}${group(["plugins"], 3)}${group(["scheduled-jobs"])}`, true)}
    ${category("source-host", "Source code host: GitHub or Bitbucket", host)}
    ${category("folders", "Folders: handover notes and the luna vault", folders)}
    ${category("machine", "This machine: worker limit, VM mode and reports", `<div class="setgroup">${renderFleetCap(state.fleetCap, true)}${renderVm(state.vm, true)}${renderReports(state.reports, true)}</div>`)}
    ${category("answers", "Saved answers", group(["install-answers"]))}
    <p class="foot">Each change takes effect as its row says; a switch shows a dry run before it writes.</p>`;
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
  return pg(`<h2 id="h-configure">Configure</h2><p class="sub">Change what himmel does, any time.</p>
    <div class="tiles">${tiles}</div>
    ${panel ? "" : checkStrip(c.verify)}
    ${panel ? `<div class="cpanel" id="tile-${c.tile}" role="region" aria-label="${TILE_NAME[c.tile]}">${panel(c)}</div>` : ""}
    <p class="not"><b>Not here, on purpose:</b> the safety hooks (<code>EDIT_ON_MAIN_OK=1</code>, <code>READ_SECRETS_OK=1</code>, <code>DESTRUCTIVE_OK=1</code>, <code>.single-writer</code>). Set one in the shell that starts Claude Code. <b>Moved to Health:</b> Triage and Inventory (<a href="#/health">open Health</a>).</p>`);
}

export function renderSetup(setup, plans, msgs, verify = null) {
  const head = `<h2>Setup</h2>`;
  if (!setup) return `${head}<p class="sub">loading…</p>`;
  if (setup.error) return `${head}<div class="nodata" role="alert">${esc(setup.error)}</div>`;
  return `${head}${account(setup.account, msgs.account)}
    <p class="sub">A secret you save here goes to this machine over a loopback connection, bound to this launch's token; it is never shown again. This page shows only whether each secret is set, never its value. With no browser available, ${copyCommand("himmelctl install")} asks for secrets in the terminal instead.</p>
    <h3>Secrets</h3>${setup.secrets.map((s) => secretRow(s, msgs[s.name])).join("")}
    ${coderabbit(setup.coderabbit)}
    ${commitRules(setup.commit, plans)}
    ${setupChoices(setup.choices, plans)}
    ${verifyStep(verify)}`;
}
