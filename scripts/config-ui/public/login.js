// The login form: POST /api/login, and on success the server's HttpOnly session cookie opens the console at /.
// The password goes in the request body only; nothing is kept in the page or in browser storage.
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
  if (r.ok) { location.replace("/"); return; }
  if (r.status === 429) { status.textContent = `Too many failed logins. Retry in ${r.headers.get("retry-after")} s.`; return; }
  let why = "";
  try { why = (await r.json()).error || ""; } catch (_) { /* status only */ }
  status.textContent = why || `The server answered ${r.status}.`;
});
