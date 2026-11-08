// The chief board inside the Fleet page: the legend, a worker's stage dots, the Trends tab (three bands, the merged-worker and
// failure-class tables in the drawer) and the per-stage drill-in drawer. Everything here renders himmel.board/1; the colours and
// their labels come from its `legend`, the recommendations from its `cards`. Read-only.
import { createContext, Fragment, useContext, useEffect, useMemo, useReducer, useRef, useState, type ReactNode } from "react";
import { applyKey, BOARD_URL, BRIEF_IDLE, BRIEF_URL, briefNext, ciCount, failKind, normalizeBoard, openAt, ROLLUP_URL, stageSegments, STAGES, type Board, type BoardWorker, type Drawer, type Joined, type Rollup, type RollupCard, type RollupCompared, type Section, type Stage } from "./board-model";
import { runHash } from "./fleet-model";

const POLL_MS = 5_000;
// legend colours are theme token names; `vio` is the PR stage's violet.
const TOKEN: Record<string, string> = { acc: "var(--accent)", ok: "var(--ok)", warn: "var(--warn)", bad: "var(--fail)", mut: "var(--dim)", vio: "var(--vio)" };
const tone = (b: Board, group: string, key: string) => TOKEN[b.legend[group]?.[key]?.color ?? "mut"] ?? TOKEN.mut;
const label = (b: Board, group: string, key: string) => b.legend[group]?.[key]?.label ?? key;
const hm = (iso: string | null | undefined) => (iso ? iso.slice(11, 16) : "–");
const dur = (a: number, b: number) => { const m = Math.max(0, Math.round((b - a) / 60000)); return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`; };

export type BoardState = { board: Board | null; error: string | null };
export function useBoard(token: string, console: string | null): BoardState {
  const [st, setSt] = useState<BoardState>({ board: null, error: null });
  useEffect(() => {
    setSt({ board: null, error: null }); // another console's board is never shown for this one
    if (!console) return;
    let live = true, timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      try {
        const r = await fetch(BOARD_URL(console), { headers: { "X-Himmel-Token": token }, cache: "no-store" });
        if (!r.ok) throw new Error(r.status === 404 ? `no handover doc for ${console}` : `the board answered ${r.status}`);
        const board = normalizeBoard(await r.json());
        if (live) setSt({ board, error: null });
      } catch (e) { if (live) setSt((s) => ({ ...s, error: String((e as Error).message ?? e) })); }
      if (live) timer = setTimeout(poll, POLL_MS);
    };
    poll();
    return () => { live = false; clearTimeout(timer); };
  }, [token, console]);
  return st;
}

// The weekly roll-up for the Trends tab; null until it lands. A failed read is an absent roll-up, shown as "no data yet".
export function useRollup(token: string): Rollup | null {
  const [r, setR] = useState<Rollup | null>(null);
  useEffect(() => {
    let live = true;
    fetch(ROLLUP_URL, { headers: { "X-Himmel-Token": token }, cache: "no-store" })
      .then((x) => (x.ok ? (x.json() as Promise<Rollup>) : ({ state: "absent", reason: `the roll-up answered ${x.status}` } as Rollup)))
      .catch(() => ({ state: "absent", reason: "the roll-up could not be read" }) as Rollup)
      .then((v) => { if (live) setR(v); });
    return () => { live = false; };
  }, [token]);
  return r;
}

// The page hands the board and the drawer opener down by context, so the fleet rows need no new props.
export type BoardCtx = { board: Board | null; cards: Map<string, Joined>; open: (worker: string, stage?: Stage) => void };
export const BoardContext = createContext<BoardCtx>({ board: null, cards: new Map(), open: () => undefined });
export const useBoardCtx = () => useContext(BoardContext);
export const cardOf = (c: BoardCtx, rowName: string): Joined | undefined => c.cards.get(rowName);

export function Swatch({ board, group, k }: { board: Board; group: string; k: string }) {
  return <span className="bd-chip" style={{ ["--c" as string]: tone(board, group, k) }}>{label(board, group, k)}</span>;
}

// a key for every colour a section draws; rendered from the JSON's legend, never hard-coded.
export function Legend({ board, groups }: { board: Board; groups: string[] }) {
  return <details className="bd-legend"><summary>Legend</summary>
    {groups.filter((g) => board.legend[g]).map((g) => <div key={g} className="bd-legend-row"><b>{g}</b>
      {Object.keys(board.legend[g]).map((k) => <Swatch key={k} board={board} group={g} k={k} />)}</div>)}
  </details>;
}

export function StageDots({ worker, board, onPick }: { worker: BoardWorker; board: Board; onPick?: (s: Stage) => void }) {
  return <span className="bd-dots" role="group" aria-label="stages">{STAGES.map((s) => {
    const reached = worker.stages[s] !== null;
    return <button key={s} type="button" disabled={!onPick} className={`bd-dot${reached ? " on" : ""}${worker.stage === s ? " cur" : ""}`}
      style={{ ["--c" as string]: tone(board, "stage", s) }} title={`${label(board, "stage", s)}${reached ? ` ${hm(worker.stages[s])}` : ""}`} aria-label={`${label(board, "stage", s)}${reached ? ", reached" : ""}`}
      onClick={() => onPick?.(s)} />;
  })}</span>;
}

// The chief's notes above the worker list: one card per section, text children only (a body is never parsed as markup).
// The title clamps to two lines with its full text in data-tip; nothing renders when the chief has written none.
const SECTION_TONE: Record<string, string> = { info: TOKEN.acc, warn: TOKEN.warn, ok: TOKEN.ok };
export function SectionsStrip({ sections }: { sections: Section[] }) {
  if (!sections.length) return null;
  return <details className="bd-notes" open>
    <summary>{`Chief notes (${sections.length})`}</summary>
    <div className="bd-notes-list">
      {sections.map((s) => <article key={s.id} className="bd-note">
        <header><span className="bd-tip bd-note-title" data-tip={s.title} tabIndex={0}><span className="bd-clip">{s.title}</span></span>
          <span className="bd-chip" style={{ ["--c" as string]: SECTION_TONE[s.tone] ?? TOKEN.acc }}>{s.tone}</span></header>
        <p className="bd-note-body">{s.body}</p>
      </article>)}
    </div>
  </details>;
}

export const StateChip =({ board, state }: { board: Board; state: string }) => <Swatch board={board} group="state" k={state} />;

// ---------------------------------------------------------------- Trends
export type CardId = "workers" | "failures";
const TITLE: Record<CardId, string> = { workers: "Merged workers today", failures: "Failure classes" };
const GANTT_MAX = 8;
const FAIL_TOP = 3;
const BETTER = { velocity: 1, cost: -1, health: -1 } as const;
type Cmp = RollupCompared & { prev_key: string | null };
type TrendCard = Omit<RollupCard, "week" | "version"> & { week: Cmp | null; version: Cmp | null; running: { key: string; value: number } | null };
type Merged = Board["trends"]["worker_time"]["today"][number];
const k1 = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(Math.round(n)));
const short = (key: string) => key.replace(/^\d{4}-/, "");
const mins = (m: number) => dur(0, m * 60000);
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const clock = (t: number) => new Date(t).toTimeString().slice(0, 5);
const spanMin = (l: Merged) => l.live_to_merged_min ?? (Date.parse(l.merged_at!) - Date.parse(l.live_at!)) / 60000;

function Bar({ parts }: { parts: { n: number; color: string; title: string }[] }) {
  const total = parts.reduce((s, p) => s + p.n, 0) || 1;
  return <div className="bd-bar">{parts.map((p, i) => p.n > 0 && <i key={i} style={{ width: `${(p.n / total) * 100}%`, background: p.color }} title={`${p.title}: ${p.n}`} />)}</div>;
}

const compact = (n: number) => { const a = Math.abs(n); return a >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : a >= 1e4 ? `${Math.round(n / 1e3)}k` : String(Math.round(n * 100) / 100); };
const signed = (n: number) => (n > 0 ? "+" : "") + compact(n);

function Gantt({ board, rows, more }: { board: Board; rows: Merged[]; more: () => void }) {
  const shown = [...rows].sort((a, b) => spanMin(b) - spanMin(a)).slice(0, GANTT_MAX).sort((a, b) => Date.parse(a.merged_at!) - Date.parse(b.merged_at!));
  const rest = rows.length - shown.length;
  const t0 = Math.min(...shown.map((l) => Date.parse(l.live_at!))), t1 = Math.max(...shown.map((l) => Date.parse(l.merged_at!)));
  const x = (t: number) => `${((t - t0) / Math.max(1, t1 - t0)) * 100}%`;
  const ticket = new Map(board.workers.map((w) => [w.worker, w.ticket]));
  return <>
    <div className="bd-gt" role="img" aria-label={`${rest ? `The ${shown.length} longest of ${rows.length}` : `This chief's ${shown.length}`} merged workers on one clock, ${clock(t0)} to ${clock(t1)}`}>
      {shown.map((l) => {
        const a = Date.parse(l.live_at!), z = Date.parse(l.merged_at!), pr = a + (l.to_pr_min ?? 0) * 60000, rd = z - (l.ready_to_merged_min ?? 0) * 60000;
        return <Fragment key={l.worker}>
          <span className="bd-w">{l.worker}{ticket.get(l.worker) && <small>{ticket.get(l.worker)}</small>}</span>
          <span className="bd-track">{([["live", a, pr], ["pr", pr, rd], ["ready", rd, z]] as const).map(([s, from, to]) => to > from &&
            <i key={s} style={{ left: x(from), width: `calc(${x(to)} - ${x(from)})`, background: tone(board, "stage", s) }} title={`${label(board, "stage", s)} ${dur(from, to)}`} />)}</span>
          <span className="bd-m">{mins(spanMin(l))}</span>
        </Fragment>;
      })}
      <span className="bd-axis"><span>{clock(t0)}</span><span>{clock((t0 + t1) / 2)}</span><span>{clock(t1)}</span></span>
    </div>
    <div className="bd-key">{([["live", "LIVE to PR"], ["pr", "PR to READY"], ["ready", "READY to merged"]] as const).map(([s, text]) =>
      <span key={s}><i style={{ background: tone(board, "stage", s) }} />{text}</span>)}</div>
    {rest > 0 && <p className="bd-more"><button type="button" className="bd-link" onClick={more}>{`and ${rest} more, each shorter than ${mins(Math.min(...shown.map(spanMin)))} →`}</button></p>}
  </>;
}

function Line({ card }: { card: TrendCard }) {
  const vs = card.spark.map((p) => p.value);
  if (!vs.length) return null;
  if (vs.length === 1) return <span className="bd-spark1"><svg viewBox="0 0 14 14" width={14} height={14} aria-hidden="true"><circle cx={7} cy={7} r={3} /></svg>one week so far: the line starts with the second</span>;
  const lo = Math.min(...vs), hi = Math.max(...vs), W = 120, H = 30;
  const at = vs.map((v, i): [number, number] => [2 + (i / (vs.length - 1)) * (W - 4), hi === lo ? H / 2 : H - 3 - ((v - lo) / (hi - lo)) * (H - 6)]);
  const [lx, ly] = at[at.length - 1];
  return <svg className="bd-wline" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${card.metric}, ${short(card.spark[0].key)} to ${short(card.spark[vs.length - 1].key)}: ${vs.map(compact).join(", ")}`}>
    <polyline points={at.map(([px, py]) => `${px.toFixed(1)},${py.toFixed(1)}`).join(" ")} /><circle cx={lx} cy={ly} r={2.5} /></svg>;
}

function Delta({ d, better, text }: { d: number; better: number; text: string }) {
  return <span className={`bd-dl${d === 0 ? "" : d * better > 0 ? " good" : " bad"}`}>{text}</span>;
}

function Series({ card }: { card: TrendCard }) {
  const name = card.metric[0].toUpperCase() + card.metric.slice(1), w = card.week, v = card.version, better = BETTER[card.id];
  if (card.state !== "ok") return <div className="bd-ws"><div className="bd-k">{name}</div><p className="quiet">no data yet</p></div>;
  return <div className="bd-ws" role="group" aria-label={name}>
    <div className="bd-k">{name}</div>
    <div className="bd-v">{w ? compact(w.value) : "–"}{w && <small>{w.key}</small>}</div>
    <Line card={card} />
    <div className="bd-d">
      {w && (w.delta !== null && w.prev_key ? <Delta d={w.delta} better={better} text={`${signed(w.delta)} vs ${short(w.prev_key)}`} /> : <span className="bd-dl">No earlier week to compare with yet</span>)}
      {v && v.delta !== null && v.prev_key && <Delta d={v.delta} better={better} text={`${v.key}: ${compact(v.value)}, ${signed(v.delta)} vs ${v.prev_key}`} />}
    </div>
  </div>;
}

function Weekly({ rollup }: { rollup: Rollup | null }) {
  if (!rollup) return <p className="quiet">Loading the weekly roll-up…</p>;
  if (rollup.state !== "ok") return <p className="bd-nod"><b>By week</b>: {rollup.reason}</p>;
  const cards = rollup.cards as unknown as TrendCard[], live = cards.filter((c) => c.running);
  return <>
    <div className="bd-wk">{cards.map((c) => <Series key={c.id} card={c} />)}</div>
    {live.length > 0 && <p className="bd-wnote">{`${short(live[0].running!.key)} so far: ${live.map((c) => `${compact(c.running!.value)} ${c.unit}`).join(", ")} (the running week, not compared).`}</p>}
  </>;
}

function Today({ board, onCard }: { board: Board; onCard: (c: CardId) => void }) {
  const read = hm(board.generated_at), merged = board.headline.merged_today, ci = board.ci;
  const rows = board.trends.worker_time.today.filter((l) => l.live_at && l.merged_at);
  const open = () => onCard("workers");
  return <>
    <div className="bd-gh">Today <span><span title={`Merged today (the calendar day) and open PRs: GitHub, read by the chief board at ${read}`}>from GitHub, now</span></span>
      {rows.length > 0 && <button type="button" className="bd-link" onClick={open}>all merged workers →</button>}</div>
    <div className="bd-td">
      <div>
        {merged === null
          ? <p className="bd-nod"><b>Merged today</b>: GitHub could not be read at {read}, so there is no count.</p>
          : <div className="bd-big">{`${plural(merged, "PR")} merged today`}<small>GitHub count, calendar day</small></div>}
        {rows.length > 0 ? <Gantt board={board} rows={rows} more={open} />
          : merged === 0 ? <p className="bd-nod">The bars appear with the first merge of this chief's workers.</p>
          : merged !== null && <p className="quiet">No worker of this chief merged today yet.</p>}
      </div>
      <div>
        {ci === null
          ? <p className="bd-nod"><b>Open PRs by CI</b>: GitHub could not be read at {read}, so there is no count.</p>
          : <><div className="bd-big">{plural(ci.open, "open PR")}<small>by CI, now</small></div>
            <Bar parts={(["green", "pending", "red", "no_checks"] as const).map((c) => ({ n: ciCount(board, c) ?? 0, color: tone(board, "ci", c), title: label(board, "ci", c) }))} />
            <div className="bd-rows">{(["green", "pending", "red", "no_checks"] as const).map((c) => <Fragment key={c}>
              <b>{ciCount(board, c) ?? 0}</b><span><i style={{ color: tone(board, "ci", c) }}>■</i> {label(board, "ci", c)}</span></Fragment>)}</div></>}
      </div>
    </div>
  </>;
}

function Stuck({ board, onCard }: { board: Board; onCard: (c: CardId) => void }) {
  const t = board.trends, f = t.failures, ex = t.exploration, classes = f?.classes ?? [];
  const since = typeof f?.since === "string" ? ` since this shift began at ${hm(f.since)}` : "";
  const over = Number(ex?.over_flag ?? 0), sessions = Number(ex?.sessions ?? 0);
  return <>
    <div className="bd-gh">Where workers got stuck <span>each part names its own window</span>
      {classes.length > FAIL_TOP && <button type="button" className="bd-link" onClick={() => onCard("failures")}>every class, with its route →</button>}</div>
    <div className="bd-sh">
      <div>
        {!f ? <p className="bd-nod"><b>Failure classes</b>: the worker failure ledger could not be read.</p>
          : classes.length === 0 ? <p className="quiet">No tool failures this shift.</p>
          : <><div className="bd-big">{plural(classes.length, "failure class", "failure classes")}<small>{`top ${Math.min(FAIL_TOP, classes.length)}${since}`}</small></div>
            <ul className="bd-fl">{classes.slice(0, FAIL_TOP).map((c) => <li key={c.class}>
              <span className="bd-kd" style={{ ["--c" as string]: tone(board, "failure", failKind(c.class)) }}>{label(board, "failure", failKind(c.class))}</span>
              <code>{c.class}</code><span className="bd-n">{plural(c.sessions, "session")}{(c as { events?: number }).events != null ? ` · ${plural((c as { events: number }).events, "event")}` : ""}</span></li>)}</ul>
            {classes.length > FAIL_TOP && <p className="bd-more"><button type="button" className="bd-link" onClick={() => onCard("failures")}>{`${classes.length - FAIL_TOP} more, with each one's route →`}</button></p>}</>}
        {board.legend.failure && <div className="bd-key" aria-label="Failure kinds">{Object.keys(board.legend.failure).map((k) =>
          <span key={k} className="bd-kd" style={{ ["--c" as string]: tone(board, "failure", k) }}>{label(board, "failure", k)}</span>)}</div>}
      </div>
      <div>
        {!ex ? <p className="bd-nod"><b>Exploration before the first edit</b>: not measured.</p>
          : <><div className="bd-big">{`${k1(Number(ex.median_tokens ?? 0))} tokens`}<small>{`median exploration before the first edit, last ${Number(ex.window_h ?? 24)} h`}</small></div>
            <Bar parts={[{ n: over, color: TOKEN.warn, title: "over the flag" }, { n: sessions - over, color: TOKEN.ok, title: "under it" }]} />
            <div className="bd-key"><span><i style={{ background: TOKEN.warn }} />{`${over} sessions over ${k1(Number(ex.flag_tokens ?? 0))}`}</span><span><i style={{ background: TOKEN.ok }} />{`${sessions - over} under`}</span></div></>}
      </div>
    </div>
  </>;
}

export function Trends({ board, boardError, rollup, chief, onCard }: { board: Board | null; boardError: string | null; rollup: Rollup | null; chief: string | null; onCard: (c: CardId) => void }) {
  const gone = !chief ? <p className="bd-nod"><b>Today</b> and <b>Where workers got stuck</b> read a live chief's board. No chief is live: start one, or read the weekly band above.</p>
    : <p className="quiet">{boardError ? `The board could not be read: ${boardError}.` : "Loading the board…"}</p>;
  return <section className="bd-tp" aria-label="Trends">
    <div className="bd-gh">By week <span><span title="GET /api/rollup, which reads ~/.himmel/state/rollup/weekly.jsonl">finished weeks, from the weekly roll-up</span></span></div>
    <Weekly rollup={rollup} />
    {board ? <><Today board={board} onCard={onCard} /><Stuck board={board} onCard={onCard} /></> : gone}
    <p className="bd-foot">Workers by state are on the Fleet tab · usage budget on Health → Usage · cost on Cost · version progress on Board</p>
  </section>;
}

function CardTable({ board, card }: { board: Board; card: CardId }) {
  const t = board.trends;
  const rows: [string, string][] = card === "workers"
    ? t.worker_time.today.map((l) => [l.worker, `LIVE→PR ${l.to_pr_min ?? "–"}m · READY→merged ${l.ready_to_merged_min ?? "–"}m · total ${l.live_to_merged_min ?? "–"}m`])
    : (t.failures?.classes ?? []).map((c) => [c.class, `${plural(c.sessions, "session")} · route ${c.route}`]);
  return <><h3>{TITLE[card]}</h3>
    <table className="bd-table"><tbody>{rows.length ? rows.map(([a, b], i) => <tr key={i}><th scope="row">{a}</th><td>{b}</td></tr>) : <tr><td>Nothing to list.</td></tr>}</tbody></table></>;
}

// ---------------------------------------------------------------- the drawer
export type Panel = { kind: "worker" } | { kind: "card"; card: CardId } | { kind: "brief"; worker: string; row: string };
export function useDrawerKeys(drawer: Drawer | null, panel: Panel | null, workers: string[], set: (d: Drawer | null) => void, close: () => void) {
  useEffect(() => {
    if (!drawer && !panel) return;
    const on = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLElement && /^(input|textarea|select)$/i.test(e.target.tagName)) return;
      if (e.key === "Escape") { close(); return; }
      if (!drawer || panel?.kind !== "worker") return;
      if (/^Arrow|^Backspace$/.test(e.key)) { e.preventDefault(); set(applyKey(drawer, e.key, workers)); }
    };
    addEventListener("keydown", on);
    return () => removeEventListener("keydown", on);
  }, [drawer, panel, workers, set, close]);
}

function Brief({ token, row }: { token: string; row: string }) {
  const [{ text, err }, dispatch] = useReducer(briefNext, BRIEF_IDLE);
  useEffect(() => {
    let live = true;
    dispatch({ kind: "start" });
    fetch(BRIEF_URL(row), { headers: { "X-Himmel-Token": token }, cache: "no-store" })
      .then((r) => (r.ok ? r.text() : Promise.reject(new Error(`the server answered ${r.status}`))))
      .then((t) => live && dispatch({ kind: "text", text: t }), (e) => live && dispatch({ kind: "error", err: String(e.message ?? e) }));
    return () => { live = false; };
  }, [token, row]);
  return err ? <p className="run-error" role="alert">{err}</p> : <pre className="bd-brief">{text ?? "loading…"}</pre>;
}

export function DrawerView({ token, board, joined, drawer, panel, now, set, setPanel, close }: {
  token: string; board: Board; joined: Joined[]; drawer: Drawer | null; panel: Panel | null; now: number;
  set: (d: Drawer | null) => void; setPanel: (p: Panel | null) => void; close: () => void;
}) {
  const workers = joined.map((j) => j.worker.worker);
  const cur = drawer ? joined.find((j) => j.worker.worker === drawer.worker) : undefined;
  const segs = useMemo(() => (cur ? stageSegments(cur.worker, now) : []), [cur, now]);
  if (!panel) return null;
  const back = drawer && drawer.back.length > 0 && panel.kind === "worker";
  const idx = cur ? workers.indexOf(cur.worker.worker) : -1;
  const go = (worker: string) => drawer && set(openAt(drawer, worker, drawer.stage));
  return <aside className="bd-drawer" role="dialog" aria-label="Worker detail" aria-modal="false">
    <div className="bd-dhead">
      {panel.kind !== "worker" && drawer ? <button type="button" className="btn" onClick={() => setPanel({ kind: "worker" })}>← Back</button>
        : back ? <button type="button" className="btn" onClick={() => set(applyKey(drawer!, "Backspace", workers))}>← Back</button> : <span />}
      <button type="button" className="btn" onClick={close} aria-label="Close (Esc)">✕</button>
    </div>
    {panel.kind === "card" && <CardTable board={board} card={panel.card} />}
    {panel.kind === "brief" && <><h3>Brief · {panel.worker}</h3><Brief key={`${token}|${panel.row}`} token={token} row={panel.row} /></>}
    {panel.kind === "worker" && cur && drawer && <>
      <h3>{cur.worker.worker} <small>{cur.worker.ticket}</small></h3>
      <p className="bd-goal">{cur.worker.goal}</p>
      <p className="bd-row"><StateChip board={board} state={cur.worker.state} />
        {cur.worker.pr && <button type="button" className="bd-link" onClick={() => set(openAt(drawer, cur.worker.worker, "pr"))}>{`PR ${cur.worker.pr.number}`}</button>}
        {cur.worker.pr?.url?.startsWith("https://") && <a className="bd-link" href={cur.worker.pr.url} target="_blank" rel="noreferrer">GitHub ↗</a>}
        {cur.row?.run ? <button type="button" className="bd-link" onClick={() => setPanel({ kind: "brief", worker: cur.worker.worker, row: cur.row!.name })}>brief</button>
          : cur.worker.links.brief?.startsWith("https://") && <a className="bd-link" href={cur.worker.links.brief} target="_blank" rel="noreferrer">brief ↗</a>}
        {cur.row?.run && <a className="bd-link" href={runHash(token, cur.row.run)}>open run page →</a>}
      </p>
      <div className="bd-nav"><button type="button" className="btn" disabled={idx <= 0} onClick={() => go(workers[idx - 1])}>↑ previous worker</button>
        <button type="button" className="btn" disabled={idx < 0 || idx >= workers.length - 1} onClick={() => go(workers[idx + 1])}>next worker ↓</button></div>
      {cur.need && <div className="bd-need"><b>{cur.need.action}</b><p>{cur.need.detail}</p>{cur.need.command && <code>{cur.need.command}</code>}</div>}
      <div className="bd-strip" aria-label="Stage strip">
        {segs.length === 0 ? <span className="quiet">no stage reached yet</span> : segs.map((s) => {
          const t0 = segs[0].from, span = Math.max(1, segs[segs.length - 1].to - t0);
          return <button key={s.stage} type="button" className={`bd-band${drawer.stage === s.stage ? " sel" : ""}`} onClick={() => set(openAt(drawer, drawer.worker, s.stage))}
            style={{ left: `${((s.from - t0) / span) * 100}%`, width: `${Math.max(2, ((s.to - s.from) / span) * 100)}%`, background: tone(board, "stage", s.stage) }} title={`${label(board, "stage", s.stage)} ${dur(s.from, s.to)}`} />;
        })}
      </div>
      <StageDots worker={cur.worker} board={board} onPick={(s) => set(openAt(drawer, drawer.worker, s))} />
      <Transcript board={board} worker={cur.worker} stage={drawer.stage} segs={segs} />
    </>}
    {panel.kind === "worker" && !cur && <p className="quiet">This worker is not on the board any more.</p>}
  </aside>;
}

function Transcript({ board, worker, stage, segs }: { board: Board; worker: BoardWorker; stage: Stage; segs: { stage: Stage; from: number; to: number }[] }) {
  const groups = STAGES.filter((s) => worker.timeline.some((b) => b.stage === s) || worker.stages[s]);
  const root = useRef<HTMLDivElement>(null);
  // scroll only when the stage or the worker changes, not on every poll or clock render
  useEffect(() => { root.current?.querySelector(".sel")?.scrollIntoView?.({ block: "nearest" }); }, [worker.worker, stage]);
  return <div className="bd-transcript" ref={root}>{groups.map((s) => {
    const at = worker.stages[s], bullets = worker.timeline.filter((b) => b.stage === s), seg = segs.find((g) => g.stage === s);
    return <section key={s} className={s === stage ? "sel" : ""}>
      <h4 style={{ ["--c" as string]: tone(board, "stage", s) }}>{label(board, "stage", s)}<small>{` ${hm(at)}${seg ? ` · ${dur(seg.from, seg.to)}` : ""}`}</small></h4>
      {bullets.map((b, i) => <p key={i} className="bd-bullet"><span className="bd-chip" style={{ ["--c" as string]: tone(board, "marker", b.marker) }}>{label(board, "marker", b.marker)}</span>{` ${b.text}`}</p>)}
    </section>;
  })}</div>;
}
