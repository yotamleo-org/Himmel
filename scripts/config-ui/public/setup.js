// The Setup page: which secrets are set (presence only, never a value), a form to set or remove one, and the commit rules.
// A value lives in the password field until the request is sent and the field is cleared at once: it is never kept in
// page state, localStorage or the markup, and the server answers with the name and the new status only.
import { esc, planHtml } from "/render.js";

const STATUS = { set: "set", "not-set": "not set", placeholder: "placeholder", probe: "checked in the terminal" };
const TRACKERS = [["jira", "Jira"], ["local", "Local"], ["none", "None"]];

function secretRow(s, msg) {
  const status = `<span class="st ${s.status === "set" ? "ok" : "warn"}">${esc(STATUS[s.status] || s.status)}</span>`;
  const what = `<span class="id">${esc(s.name)}</span><span class="det">${esc(s.feature)}${s.required ? ` · ${esc(s.required)}` : ""}</span>`;
  if (s.collect !== "file") return `<div class="srow">${what}${status}<span class="ro">set in the terminal</span></div>`;
  const remove = s.status === "set" ? `<button class="btn" type="button" data-act="setup-remove" data-name="${esc(s.name)}">remove</button>` : "";
  return `<div class="srow">${what}${status}
    <form class="sform" data-setup-form data-name="${esc(s.name)}" autocomplete="off">
      <input type="password" data-secret="${esc(s.name)}" autocomplete="off" spellcheck="false" aria-label="${esc(s.name)} value">
      <button class="btn primary" type="submit">save</button>${remove}</form>
    ${msg ? `<span class="ro" role="status">${esc(msg)}</span>` : ""}</div>`;
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

export function renderSetup(setup, plans, msgs) {
  const head = `<h2>Setup</h2>`;
  if (!setup) return `${head}<p class="sub">loading…</p>`;
  if (setup.error) return `${head}<div class="nodata" role="alert">${esc(setup.error)}</div>`;
  return `${head}<p class="sub">Typing a secret in the terminal (<code>himmelctl install</code>) is the safest path: it never passes through a browser. This page shows only whether each secret is set, never its value.</p>
    <h3>Secrets</h3>${setup.secrets.map((s) => secretRow(s, msgs[s.name])).join("")}
    ${commitRules(setup.commit, plans)}`;
}
