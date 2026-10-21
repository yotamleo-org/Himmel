// the config console's rail around the fleet and run pages, so / and /agui/ read as one app. The page
// list and its links come from public/nav.js, the same module the console draws its rail from.
import { useEffect, useState, type ReactNode } from "react";
// @ts-expect-error: plain ES module shared with the console (no types).
import { fleetDot, navLinks } from "../../public/nav.js";
import type { FleetState } from "./Fleet";
import { FleetMenu } from "./FleetMenu";

export function Shell({ token, run, fleet, children, console: selected = null }: { token: string | null; run: string | null; fleet: FleetState; children: ReactNode; console?: string | null }) {
  const dot = fleetDot(fleet.fleet, fleet.error);
  // GET /api/sources: which trackers Roadmap and Kanban can read; unknown (undefined) until it answers or if it fails.
  const [sources, setSources] = useState<string[] | undefined>(undefined);
  useEffect(() => {
    if (!token) return;
    fetch("/api/sources", { headers: { "X-Himmel-Token": token } }).then((r) => r.json()).then((j) => setSources(Array.isArray(j.sources) ? j.sources : undefined)).catch(() => {});
  }, [token]);
  const links: { id: string; label: string; href: string; current: boolean }[] = token ? navLinks({ here: "agui", token, current: run ? "run" : "fleet", run, sources }) : [];
  return (
    <div className="shell">
      <aside className="rail" aria-label="Regions">
        <div className="brand">himmelctl ui<small>{location.host}</small></div>
        {links.length > 0 && (
          <nav className="pages" aria-label="Pages">
            {links.map((l) => (
              <a key={l.id} href={l.href} aria-current={l.current ? "page" : undefined}>
                {l.label}
                {l.id === "fleet" && <span className={`st-dot ${dot.cls}`} title={dot.title} />}
              </a>
            ))}
          </nav>
        )}
        {token && <FleetMenu token={token} state={fleet} selected={selected} />}
      </aside>
      <div className="pane">{children}</div>
    </div>
  );
}
