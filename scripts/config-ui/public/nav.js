// the one page list of the config console (/) and the AG-UI pages (/agui/), so both documents draw
// the same rail. app.js imports it as /nav.js; agui-web bundles it. The session token rides only the URL
// fragment (#t=<token>), never a path or query, so it never reaches a request line.
export const PAGES = [
  { id: "config", label: "Settings" },
  { id: "health", label: "Health" },
  { id: "toolhealth", label: "Tool health" },
  { id: "fleet", label: "Fleet" },
  { id: "roadmap", label: "Roadmap" },
  { id: "kanban", label: "Kanban" },
  { id: "workflow", label: "Workflow" },
];
const CONSOLE = ["config", "health", "toolhealth", "roadmap", "kanban", "workflow"];

// The docs site: the UI links into it, never the reverse. DOCS_PATHS lists every site route the UI links to;
// tests/docs-routes.test.ts checks each against a fresh site/dist build.
export const DOCS_URL = "https://yotamleo-org.github.io/Himmel/";
export const DOCS_PATHS = ["/", "/himmelctl/", "/setup/codex/", "/configuration/", "/cadences/", "/internals/enforcement/", "/setup/profiles/"];
export const docsHref = (path) => DOCS_URL + path.replace(/^\//, "");

const frag = (o) => "#" + new URLSearchParams(o).toString();

// here: "console" (the / document: its pages are #/<id> routes, the token is held in memory) or "agui".
export function pageHref({ here, token, id, run }) {
  if (id === "fleet") return "/agui/" + frag({ t: token });
  if (id === "run") return "/agui/" + frag({ t: token, run });
  return here === "console" ? "#/" + id : "/" + frag({ t: token, page: id });
}

// Roadmap and Kanban read a tracker; with none the UI can read they are not offered.
const TRACKER_PAGES = ["roadmap", "kanban"];

// run: the session the run page shows, which adds a Run entry.
// sources: GET /api/sources; an empty list hides the tracker pages, and not knowing it yet (undefined) hides nothing.
export function navLinks({ here, token, current, run, sources }) {
  const shown = sources && sources.length === 0 ? PAGES.filter((p) => !TRACKER_PAGES.includes(p.id)) : PAGES;
  const pages = run ? [...shown, { id: "run", label: "Run" }] : shown;
  return [
    ...pages.map((p) => ({ ...p, href: pageHref({ here, token, id: p.id, run }), current: p.id === current })),
    { id: "docs", label: "Docs", href: docsHref("/"), current: false, external: true },
  ];
}

// The console's landing fragment, #t=<hex>[&page=<id>]: the token and the console page to open; null otherwise.
export function parseLanding(hash) {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const token = p.get("t");
  if (!token || !/^[0-9a-f]+$/.test(token)) return null;
  return { token, page: CONSOLE.includes(p.get("page")) ? p.get("page") : "config" };
}

// The Health entry's status dot: the Health page's verdict (health.js verdict()), cls already ok / warn / fail / off.
export function healthDot(v) {
  return { cls: v.cls, title: `health: ${v.word}` };
}

// The Fleet entry's status dot, in app.css's ok / warn / fail: can the fleet be read in full right now?
export function fleetDot(fleet, error) {
  if (error) return { cls: "fail", title: `fleet: ${error}` };
  if (!fleet) return { cls: "off", title: "fleet: not read yet" };
  if (fleet.census === "unavailable") return { cls: "fail", title: "fleet: the process census failed" };
  if (fleet.census === "degraded") return { cls: "warn", title: "fleet: some sessions could not be read" };
  return { cls: "ok", title: "fleet: every session read" };
}
