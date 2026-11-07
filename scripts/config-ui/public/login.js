// The login form: POST /api/login, and on success the server's HttpOnly session cookie opens the chief at the page the user came from (/ by default).
// The password goes in the request body only; nothing is kept in the page or in browser storage.
// ?next= says where to go afterwards (the page that sent the user here). Only a path on this site counts: it must start with
// one "/" and nothing after it may turn it into another host: no second "/" or "\" right after it, no "\" or control
// character anywhere (a browser reads "\" as "/" and drops a tab or newline, so "/\t/host" would be "//host").
const nextRaw = new URLSearchParams(location.search).get("next");
const next = nextRaw !== null && /^\/(?![/\\])/.test(nextRaw) && !/[\\\u0000-\u001f\u007f]/.test(nextRaw) && new URL(nextRaw, location.origin).origin === location.origin ? nextRaw : "/";
const form = document.getElementById("login");
const status = document.getElementById("status");
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(form);
  status.textContent = "";
  let r;
  try {
    r = await fetch("/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ user: f.get("user"), password: f.get("password") }) });
  } catch (_) { status.textContent = "The server did not answer."; return; }
  form.elements.password.value = "";
  if (r.ok) { location.replace(next); return; }
  if (r.status === 429) { status.textContent = `Too many failed logins. Retry in ${r.headers.get("retry-after")} s.`; return; }
  let why = "";
  try { why = (await r.json()).error || ""; } catch (_) { /* status only */ }
  status.textContent = why || `The server answered ${r.status}.`;
});
