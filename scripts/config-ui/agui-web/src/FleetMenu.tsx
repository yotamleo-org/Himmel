// the fleet page's filter bar (lane, state, text, finished inline). It narrows every section of the fleet page and is
// kept per viewer; the rail holds no filters and no session tree (the chiefs and their counts are the page's group headers).
import { EMPTY_FILTERS, filtering, useFilters, type Row, type ViewFilters } from "./Fleet";
import { filterCount, NO_FILTERS, type ProcessOrphan } from "./fleet-model";

const LANES = ["native", "claudex", "cloud"];
const STATES: [string, string][] = [["running", "running"], ["waiting", "waiting"], ["idle", "idle"], ["attention", "attention"], ["orphaned", "orphaned"]];
const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);

export function FleetFilterBar({ rows, procs }: { rows: Row[]; procs: ProcessOrphan[] | null | undefined }) {
  const [f, set] = useFilters();
  // Each badge is what that chip alone would show (fleet-model's filterCount: the filter's own predicate).
  const n: Record<string, number> = Object.fromEntries([
    ...LANES.map((l) => [l, filterCount(rows, { ...NO_FILTERS, lanes: [l] }, procs ?? [])]),
    ...STATES.map(([s]) => [s, filterCount(rows, { ...NO_FILTERS, states: [s] }, procs ?? [])]),
  ]);
  const chip = (v: string, label: string, on: boolean, flip: (f: ViewFilters) => ViewFilters) =>
    <button type="button" key={v} className={`fleet-chip-btn${on ? " on" : ""}`} aria-pressed={on} onClick={() => set(flip(f))}>{label}{v in n && <span className="fleet-count">{n[v]}</span>}</button>;
  return <div className="fleet-filters" role="group" aria-label="Filters">
    <input className="fleet-search" type="search" value={f.text} placeholder="ticket, worker-session id or slug" aria-label="Filter by ticket, worker-session id or slug"
      onChange={(e) => set({ ...f, text: e.currentTarget.value })} />
    <div className="fleet-chips" aria-label="Lane">{LANES.map((l) => chip(l, l, f.lanes.includes(l), (x) => ({ ...x, lanes: toggle(x.lanes, l) })))}</div>
    <div className="fleet-chips" aria-label="State">{STATES.map(([v, label]) => chip(v, label, f.states.includes(v), (x) => ({ ...x, states: toggle(x.states, v) })))}</div>
    <div className="fleet-chips">{chip("finished-inline", "show finished inline", f.finished, (x) => ({ ...x, finished: !x.finished }))}
      {(filtering(f) || f.finished) && <button type="button" className="fleet-clear" onClick={() => set(EMPTY_FILTERS)}>clear filters</button>}</div>
    <p className="quiet">waiting includes background shell waits and waiting for GO.</p>
  </div>;
}
