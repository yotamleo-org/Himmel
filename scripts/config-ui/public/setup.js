// The Setup page: which secrets are set (presence only, never a value), a form to set or remove one, and the commit rules.
// A value lives in the password field until the request is sent and the field is cleared at once: it is never kept in
// page state, localStorage or the markup, and the server answers with the name and the new status only.
import { esc, planHtml } from "./render.js";

const STATUS = { set: "set", "not-set": "not set", placeholder: "placeholder", probe: "checked in the terminal" };
const TRACKERS = [["jira", "Jira"], ["local", "Local"], ["none", "None"]];

function secretRow(s, msg) {
  const status = `<span class="st ${s.status === "set" ? "ok" : "warn"}">${esc(STATUS[s.status] || s.status)}</span>`;
  const what = `<span class="id">${esc(s.name)}</span><span class="det">${esc(s.feature)}${s.required ? ` · ${esc(s.required)}` : ""}</span>`;
  if (s.collect !== "file") return `<div class="srow">${what}${status}<span class="ro">set in the terminal</span></div>`;
  const remove = s.status === "set" ? `<button class="btn" type="button" data-act="setup-remove" data-name="${esc(s.name)}">remove</button>` : "";
  return `<div class="srow">${what}${status}
    <form class="sform" data-setup-form data-name="${esc(s.name)}" autocomplete="off">
      <input type="password" data-secret="${esc(s.name)}" autocomplete="new-password" spellcheck="false" aria-label="${esc(s.name)} value">
      <button class="btn primary" type="submit">save</button>${remove}</form>
    ${s.example ? `<span class="ro">e.g. ${esc(s.example)}</span>` : ""}
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

function commitRules(c, plans) {
  const tk = "setup|tracker", rk = "setup|ticket-id-required";
  const none = c.tracker === "none";
  const required = none || c.ticketIdRequired === false ? "off" : "on";
  return `<h3>Commit rules</h3>
    <p class="sub">Which tracker a commit's ticket ID comes from, and whether a commit needs one. Each change shows a dry run before it writes. The ID pattern is typed in the terminal.</p>
    <div class="srow"><span class="id">Tracker</span><span class="det">${c.tracker ? "" : "not set yet · "}takes effect on your next commit</span>
      <span>${TRACKERS.map(([v, l]) => choice(l, "config.commitRules", "tracker", v, c.tracker, tk)).join(" ")}</span></div>
    ${plans[tk] ? planHtml(tk, plans[tk]) : ""}
    <div class="srow"><span class="id">Ticket ID required</span><span class="det">${none ? "off while the tracker is None" : "takes effect on your next commit"}</span>
      <span>${choice("on", "config.commitRules", "ticket-id-required", "on", required, rk, none)} ${choice("off", "config.commitRules", "ticket-id-required", "off", required, rk, none)}</span></div>
    ${plans[rk] ? planHtml(rk, plans[rk]) : ""}`;
}

const PATH_LABEL = { "handover-root": "Handover root", "luna-vault": "luna vault path" };

// Where handover state and the luna vault live, each change a dry run first; the forge is shown as detected; the
// remaining choices are the Settings page's toggles, linked here rather than repeated.
function setupChoices(c, plans) {
  if (!c) return "";
  const rows = c.paths.map((p) => {
    const k = `setup|${p.target}`;
    const shown = (plans[k] && plans[k].req && plans[k].req.value) || p.value || "";
    return `<div class="srow"><span class="id">${esc(PATH_LABEL[p.target] || p.target)}</span>
      <span class="det">${p.value ? `${esc(p.key)} · takes effect on the next Claude launch` : `not set · default: ${esc(p.fallback)}`}</span>
      <form class="sform" data-path-form data-target="${esc(p.target)}" autocomplete="off">
        <input type="text" data-path="${esc(p.target)}" value="${esc(shown)}" spellcheck="false" placeholder="/absolute/path" aria-label="${esc(PATH_LABEL[p.target] || p.target)}">
        <button class="btn" type="submit">preview</button></form></div>
      ${plans[k] ? planHtml(k, plans[k]) : ""}`;
  }).join("");
  const f = c.forge || {};
  const forge = `<div class="srow"><span class="id">Forge</span>
    <span class="det">${f.error ? esc(f.error) : `detected: ${esc(f.value)}`}</span>
    <span class="ro">set <code>FORGE</code> or <code>git config himmel.forge</code> in the terminal</span></div>`;
  return `<h3>Setup choices</h3>
    <p class="sub">Each path is written to <code>~/.himmel/himmel.conf</code> by <code>himmelctl config set</code> after a dry run you confirm. A path is absolute, with no <code>.</code> or <code>..</code> part, quote, <code>#</code>, <code>$</code> or backslash.</p>
    ${rows}${forge}
    <p class="sub">Plugin set, Review by a second model and Auto-ship steps are toggles on <a href="#/config">the Settings page</a>.</p>`;
}

// The first-run Account step: the UI login the always-on UI asks for. The page creates it once; changing it is a terminal step.
function account(a, msg) {
  if (!a) return "";
  const note = msg ? `<p class="sub" role="status">${esc(msg)}</p>` : "";
  if (a.status === "set") return `<h3>Account</h3><p class="sub">The UI login is set for <code>${esc(a.user)}</code>. Log in with it at <code>/login</code> on the always-on UI. To change it, run <code>${esc(a.setLogin)}</code> in your own terminal.</p>${note}`;
  if (a.create !== "ui") return `<h3>Account</h3><p class="sub">${a.status === "unreadable" ? "The login file cannot be read. " : "No UI login is set yet. "}Set it with <code>${esc(a.setLogin)}</code> in your own terminal.</p>${note}`;
  return `<h3>Account</h3><p class="sub">Create the login for the always-on UI first: it asks for this user and password before it saves a secret. The password is at least 8 characters and is kept only as a hash.</p>
    <form class="sform" data-account-form autocomplete="off">
      <input type="text" data-account="user" autocomplete="username" spellcheck="false" aria-label="user name">
      <input type="password" data-account="password" autocomplete="new-password" aria-label="password">
      <input type="password" data-account="confirm" autocomplete="new-password" aria-label="password again">
      <button class="btn primary" type="submit">create login</button></form>${note}`;
}

export function renderSetup(setup, plans, msgs) {
  const head = `<h2>Setup</h2>`;
  if (!setup) return `${head}<p class="sub">loading…</p>`;
  if (setup.error) return `${head}<div class="nodata" role="alert">${esc(setup.error)}</div>`;
  return `${head}${account(setup.account, msgs.account)}
    <p class="sub">A secret you save here goes to this machine over a loopback connection, bound to this launch's token; it is never shown again. This page shows only whether each secret is set, never its value. With no browser available, <code>himmelctl install</code> asks for secrets in the terminal instead.</p>
    <h3>Secrets</h3>${setup.secrets.map((s) => secretRow(s, msgs[s.name])).join("")}
    ${coderabbit(setup.coderabbit)}
    ${commitRules(setup.commit, plans)}
    ${setupChoices(setup.choices, plans)}`;
}
