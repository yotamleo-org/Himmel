// the config chief's rail around the fleet and run pages, so / and /agui/ read as one app. The page
// list and its links come from public/nav.js, the same module the chief draws its rail from.
import { useEffect, useState, type ReactNode } from "react";
// @ts-expect-error: plain ES module shared with the chief (no types).
import { fleetDot, navLinks, railItems } from "../../public/nav.js";
import type { FleetState } from "./Fleet";

export function Shell({ token, run, fleet, children }: { token: string | null; run: string | null; fleet: FleetState; children: ReactNode }) {
  const dot = fleetDot(fleet.fleet, fleet.error);
  // GET /api/sources: which trackers Roadmap and Kanban can read; unknown (undefined) until it answers or if it fails.
  const [sources, setSources] = useState<string[] | undefined>(undefined);
  useEffect(() => {
    if (!token) return;
    fetch("/api/sources", { headers: { "X-Himmel-Token": token } }).then((r) => r.json()).then((j) => setSources(Array.isArray(j.sources) ? j.sources : undefined)).catch(() => {});
  }, [token]);
  // the rail is railItems (the one list the console rail draws too); navLinks supplies each entry's label and href.
  const links: { id: string; label: string; href: string; current: boolean; external?: boolean }[] = (() => {
    if (!token) return [];
    const current = run ? "run" : "fleet";
    const byId = new Map<string, { id: string; label: string; href: string; current: boolean; external?: boolean }>(navLinks({ here: "agui", token, current, run, sources }).map((l: { id: string }) => [l.id, l]));
    return railItems(current, sources).flatMap((id: string) => byId.get(id) ?? []);
  })();
  return (
    <div className="shell">
      <aside className="rail" aria-label="Regions">
        <div className="brand">himmelctl ui<small>{location.host}</small></div>
        {links.length > 0 && (
          <nav className="pages" aria-label="Pages">
            {links.map((l) => (
              <a key={l.id} href={l.href} aria-current={l.current ? "page" : undefined} {...(l.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>
                {l.label}
                {l.id === "fleet" && <span className={`st-dot ${dot.cls}`} title={dot.title} />}
              </a>
            ))}
          </nav>
        )}
        {!token && <p className="rail-hint">Open the URL printed by <code>himmelctl ui</code> to reach Config, Health, Fleet and the other pages.</p>}
      </aside>
      <div className="pane">{children}</div>
    </div>
  );
}
