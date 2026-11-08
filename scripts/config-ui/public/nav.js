// the one page list of the config chief (/) and the AG-UI pages (/agui/), so both documents draw
// the same rail. app.js imports it as /nav.js; agui-web bundles it. The session token rides only the URL
// fragment (#t=<token>), never a path or query, so it never reaches a request line.
export const PAGES = [
  { id: "shift", label: "Shift" },
  { id: "report", label: "Morning report" },
  { id: "fleet", label: "Fleet" },
  { id: "health", label: "Health" },
  { id: "toolhealth", label: "Tool health" },
  { id: "config", label: "Configure" },
  { id: "board", label: "Board" },
  { id: "workflow", label: "Workflow" },
  { id: "cost", label: "Cost" },
];
const CHIEF = ["shift", "report", "config", "health", "toolhealth", "board", "workflow", "cost"];

// Settings and Setup became one Configure page. The old ids (and the himmelctl install hand-off's page=setup) still land
// on it: Setup with the Secrets tile picked. TILES are the Configure page's four groups. (app.js maps the #/setup route
// the same way: tests/slow.test.ts runs it without this file's exports.)
export const TILES = ["secrets", "review", "tracker", "scope"];
// Roadmap and Kanban became the one Board page: their old ids land on it.
const OLD_PAGE = { setup: { id: "config", tile: "secrets" }, configure: { id: "config" }, roadmap: { id: "board" }, kanban: { id: "board", q: "v=all" } };

// The docs site: the UI links into it, never the reverse. DOCS_PATHS lists every site route the UI links to;
// tests/docs-routes.test.ts checks each against a fresh site/dist build.
export const DOCS_URL = "https://yotamleo-org.github.io/Himmel/"; // env-literal-ok: link to the public docs site of the product itself
export const DOCS_PATHS = ["/", "/himmelctl/", "/setup/codex/", "/configuration/", "/cadences/", "/internals/enforcement/", "/setup/profiles/"];
export const docsHref = (path) => DOCS_URL + path.replace(/^\//, "");

const frag = (o) => "#" + new URLSearchParams(o).toString();

// here: "console" (the / document: its pages are #/<id> routes, the token is held in memory) or "agui".
export function pageHref({ here, token, id, run }) {
  if (id === "fleet") return "/agui/" + frag({ t: token });
  if (id === "run") return "/agui/" + frag({ t: token, run });
  return here === "console" ? "#/" + id : "/" + frag({ t: token, page: id });
}

// The Board reads a tracker; with none the UI can read it is not offered.
const TRACKER_PAGES = ["board"];

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

// The rail's link ids: the same on every page (page controls live in the page bar, never the rail), plus Run on the run page, then Docs.
// Pure: no state, so the AG-UI build and the console rail test read the one list.
// sources: as for navLinks, so an empty list hides Board here exactly as the rendered rail does; omitted, nothing is hidden.
export const railItems = (current, sources) => [...PAGES.filter((p) => !(sources && sources.length === 0 && TRACKER_PAGES.includes(p.id))).map((p) => p.id), ...(current === "run" ? ["run"] : []), "docs"];

// The rail's markup, drawn by both documents (here: "console" by default, or "agui"). dots: { fleet, health } status dots;
// waiting: the Shift badge's count. Nothing here depends on the page but the current mark: the Health project picker is the page bar's (app.js).
export function railMarkup({ here = "console", token, current, sources, run, dots = {}, waiting = 0 }) {
  return navLinks({ here, token, current, run, sources }).map((l) =>
    `<a href="${l.href}" data-page="${l.id}"${l.current ? ' aria-current="page"' : ""}${l.external ? ' target="_blank" rel="noopener noreferrer"' : ""}>${l.label}${dots[l.id] ? `<span class="st-dot ${dots[l.id].cls}" title="${dots[l.id].title}"></span>` : ""}${l.id === "shift" && waiting ? `<span class="sh-badge" title="${waiting} waiting on you">${waiting}</span>` : ""}</a>`).join("");
}

// The chief's landing fragment, #t=<hex>[&page=<id>]: the token and the chief page to open; null otherwise.
export function parseLanding(hash) {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const token = p.get("t");
  if (!token || !/^[0-9a-f]+$/.test(token)) return null;
  const old = OLD_PAGE[p.get("page")];
  if (old) return { token, page: old.id, ...(old.tile ? { tile: old.tile } : {}), ...(old.q ? { q: old.q } : {}) };
  return { token, page: CHIEF.includes(p.get("page")) ? p.get("page") : "config" };
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
