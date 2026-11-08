// the config chief's rail around the fleet and run pages, so / and /agui/ read as one app: the same rail markup
// (nav.js railMarkup) and the same identity header (render.js renderHeader, from GET /api/feed) the chief draws.
import { useEffect, useState, type ReactNode } from "react";
// @ts-expect-error: plain ES module shared with the chief (no types).
import { fleetDot, railMarkup } from "../../public/nav.js";
// @ts-expect-error: plain ES module shared with the chief (no types).
import { renderHeader } from "../../public/render.js";
import type { FleetState } from "./Fleet";
import { isRagEvalHash } from "./rag-eval-model";

const PROBING = '<span class="ver">himmel</span><span class="k">probing…</span>'; // as public/index.html, until the report answers

export function Shell({ token, run, fleet, children }: { token: string | null; run: string | null; fleet: FleetState; children: ReactNode }) {
  const dot = fleetDot(fleet.fleet, fleet.error);
  // GET /api/sources: which trackers Roadmap and Kanban can read; unknown (undefined) until it answers or if it fails.
  const [sources, setSources] = useState<string[] | undefined>(undefined);
  useEffect(() => {
    if (!token) return;
    fetch("/api/sources", { headers: { "X-Himmel-Token": token } }).then((r) => r.json()).then((j) => setSources(Array.isArray(j.sources) ? j.sources : undefined)).catch(() => {});
  }, [token]);
  // GET /api/feed: the identity header and scope line come from the report's envelope, the one report the chief shares (the server
  // runs at most one and caches it). 202 = it is still running: ask again. A report that fails between two asks makes the server
  // start another, which answers 202 with a new startedAt: that is the sign to stop asking, never to probe for ever. A failed
  // read leaves {}, which the header words as an unknown version.
  const [feed, setFeed] = useState<{ himmel?: unknown; generatedAt?: string; target?: { scope?: string } } | null>(null);
  useEffect(() => {
    if (!token) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let started: number | undefined;
    const load = async () => {
      try {
        const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
        if (!live) return;
        if (r.status === 202) {
          const j = await r.json().catch(() => ({}));
          if (!live) return;
          if (started !== undefined && j.startedAt !== started) return setFeed({});
          started = j.startedAt;
          timer = setTimeout(load, 1000);
        } else setFeed(r.ok ? await r.json() : {});
      } catch { if (live) setFeed({}); }
    };
    load();
    return () => { live = false; clearTimeout(timer); };
  }, [token]);
  const current = run ? "run" : isRagEvalHash(location.hash) ? null : "fleet"; // the RAG eval page has no rail entry yet
  return (
    <div className="shell">
      <aside className="rail" aria-label="Regions">
        <div className="brand">himmel
          {token && <header className="top" id="top" dangerouslySetInnerHTML={{ __html: feed ? renderHeader(feed) : PROBING }} />}
          <small id="where">{token ? `${location.host} · ${feed ? feed.target?.scope ?? "?" : "?"} scope` : location.host}</small>
        </div>
        {token && <nav className="pages" id="pages" aria-label="Pages" dangerouslySetInnerHTML={{ __html: railMarkup({ here: "agui", token, current, run, sources, dots: { fleet: dot } }) }} />}
        {token && <nav className="nav" id="nav" />}
        {!token && <p className="rail-hint">Open the URL printed by <code>himmelctl ui</code> to reach Config, Health, Fleet and the other pages.</p>}
      </aside>
      <div className="pane">{children}</div>
    </div>
  );
}
