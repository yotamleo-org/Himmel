// The console board inside the Fleet page: the legend, a leg's stage dots, the Trends tab (four cards, each opening
// its table in the drawer) and the per-stage drill-in drawer. Everything here renders himmel.board/1; the colours and
// their labels come from its `legend`, the recommendations from its `cards`. Read-only.
import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { applyKey, BOARD_URL, BRIEF_URL, openAt, stageSegments, STAGES, type Board, type BoardLeg, type Drawer, type Joined, type Stage } from "./board-model";
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
        const board = (await r.json()) as Board;
        if (live) setSt({ board, error: null });
      } catch (e) { if (live) setSt((s) => ({ ...s, error: String((e as Error).message ?? e) })); }
      if (live) timer = setTimeout(poll, POLL_MS);
    };
    poll();
    return () => { live = false; clearTimeout(timer); };
  }, [token, console]);
  return st;
}

// The page hands the board and the drawer opener down by context, so the fleet rows need no new props.
export type BoardCtx = { board: Board | null; cards: Map<string, Joined>; open: (leg: string, stage?: Stage) => void };
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

export function StageDots({ leg, board, onPick }: { leg: BoardLeg; board: Board; onPick?: (s: Stage) => void }) {
  return <span className="bd-dots" role="group" aria-label="stages">{STAGES.map((s) => {
    const reached = leg.stages[s] !== null;
    return <button key={s} type="button" disabled={!onPick} className={`bd-dot${reached ? " on" : ""}${leg.stage === s ? " cur" : ""}`}
      style={{ ["--c" as string]: tone(board, "stage", s) }} title={`${label(board, "stage", s)}${reached ? ` ${hm(leg.stages[s])}` : ""}`} aria-label={`${label(board, "stage", s)}${reached ? ", reached" : ""}`}
      onClick={() => onPick?.(s)} />;
  })}</span>;
}

export const StateChip = ({ board, state }: { board: Board; state: string }) => <Swatch board={board} group="state" k={state} />;

// ---------------------------------------------------------------- Trends
type CardId = "velocity" | "health" | "tools" | "roadmap";
const TITLE: Record<CardId, string> = { velocity: "Fleet velocity", health: "Fleet health", tools: "Tool health", roadmap: "Roadmap reality" };
const k1 = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(Math.round(n)));
const failKind = (cls: string) => (cls.startsWith("denied/") ? "denial" : "error");

function Gantt({ board }: { board: Board }) {
  const today = board.trends.leg_time.today.filter((l) => l.live_at && l.merged_at);
  if (!today.length) return <p className="quiet">No leg merged today yet.</p>;
  const t0 = Math.min(...today.map((l) => Date.parse(l.live_at!))), t1 = Math.max(...today.map((l) => Date.parse(l.merged_at!)));
  const x = (t: number) => `${((t - t0) / Math.max(1, t1 - t0)) * 100}%`;
  return <div className="bd-gantt" role="img" aria-label="today's merged legs on a clock axis">
    {today.map((l) => {
      const a = Date.parse(l.live_at!), z = Date.parse(l.merged_at!), pr = a + (l.to_pr_min ?? 0) * 60000, rd = z - (l.ready_to_merged_min ?? 0) * 60000;
      return <div key={l.leg} className="bd-grow"><span>{l.leg}</span><div className="bd-gtrack">
        {([["live", a, pr], ["pr", pr, rd], ["ready", rd, z]] as const).map(([s, from, to]) => to > from &&
          <i key={s} style={{ left: x(from), width: `calc(${x(to)} - ${x(from)})`, background: tone(board, "stage", s) }} title={`${label(board, "stage", s)} ${dur(from, to)}`} />)}
      </div></div>;
    })}
    <div className="bd-gaxis"><span>{new Date(t0).toTimeString().slice(0, 5)}</span><span>{new Date(t1).toTimeString().slice(0, 5)}</span></div>
  </div>;
}

function Bar({ parts }: { parts: { n: number; color: string; title: string }[] }) {
  const total = parts.reduce((s, p) => s + p.n, 0) || 1;
  return <div className="bd-bar">{parts.map((p, i) => p.n > 0 && <i key={i} style={{ width: `${(p.n / total) * 100}%`, background: p.color }} title={`${p.title}: ${p.n}`} />)}</div>;
}

export function Trends({ board, onCard }: { board: Board; onCard: (c: CardId) => void }) {
  const t = board.trends, cc = t.console_cost;
  const states = [...new Set(board.legs.map((l) => l.state))].map((s) => ({ s, n: board.legs.filter((l) => l.state === s).length }));
  const budget = (pct: number | null) => (pct === null ? "ok" : pct >= 85 ? "critical" : pct >= 70 ? "high" : "ok");
  const sess = t.tools.find((x) => x.tool === "console-succession");
  const classes = t.failures?.classes ?? [];
  const card = (id: CardId, body: ReactNode) => <section className="bd-card" aria-label={TITLE[id]}>
    <header><h3>{TITLE[id]}</h3><button type="button" className="btn" onClick={() => onCard(id)}>table →</button></header>
    <p className="bd-rec">{board.cards[id]?.recommendation ?? ""}</p>{body}</section>;
  return <div className="bd-trends">
    <Legend board={board} groups={["stage", "state", "ci", "budget", "failure"]} />
    {card("velocity", <Gantt board={board} />)}
    {card("health", <>
      <Bar parts={states.map(({ s, n }) => ({ n, color: tone(board, "state", s), title: label(board, "state", s) }))} />
      <div className="bd-row">{states.map(({ s, n }) => <span key={s} className="bd-chip" style={{ ["--c" as string]: tone(board, "state", s) }}>{`${label(board, "state", s)} ${n}`}</span>)}</div>
      <p className="bd-sub">Open PRs by CI</p>
      <Bar parts={(["green", "pending", "no_checks", "red"] as const).map((c) => ({ n: board.ci[c], color: tone(board, "ci", c), title: label(board, "ci", c) }))} />
      <div className="bd-row">{(["green", "pending", "no_checks", "red"] as const).map((c) => <span key={c} className="bd-chip" style={{ ["--c" as string]: tone(board, "ci", c) }}>{`${label(board, "ci", c)} ${board.ci[c]}`}</span>)}</div>
      <p className="bd-sub">Usage budget</p>
      {([["week", board.bank.week_pct], ["5 h", board.bank.five_hour_pct]] as const).map(([n, p]) => <div key={n} className="bd-meter"><span>{n}</span>
        <div className="bd-bar"><i style={{ width: `${p ?? 0}%`, background: tone(board, "budget", budget(p)) }} /></div><b>{p === null ? "n/a" : `${p}%`}</b></div>)}
      <p className="bd-sub">Cost (Opus-eq)</p>
      <p className="bd-line">{`fleet ${t.cost ? k1(t.cost.total) : "not measured"} · console ${cc ? `${k1(cc.eq)} (${k1(cc.per_hour)}/h, ${cc.messages} messages)` : "not measured"}`}</p>
      {cc && cc.hourly.length > 1 && <Spark values={cc.hourly.map((h) => h.eq)} />}
    </>)}
    {card("tools", <>
      <p className="bd-sub">Failure classes</p>
      {classes.length === 0 ? <p className="quiet">No tool failures this shift.</p> : <ul className="bd-list">{classes.slice(0, 5).map((c) =>
        <li key={c.class}><span className="bd-chip" style={{ ["--c" as string]: tone(board, "failure", failKind(c.class)) }}>{label(board, "failure", failKind(c.class))}</span>{` ${c.class} · ${c.sessions} session${c.sessions === 1 ? "" : "s"}`}</li>)}</ul>}
      {t.exploration && <><p className="bd-sub">Exploration before the first edit</p>
        <p className="bd-line">{`median ${k1(Number(t.exploration.median_tokens ?? 0))} tokens · ${t.exploration.over_flag ?? 0} of ${t.exploration.sessions ?? 0} sessions over ${k1(Number(t.exploration.flag_tokens ?? 0))}`}</p>
        <Bar parts={[{ n: Number(t.exploration.over_flag ?? 0), color: TOKEN.warn, title: "over the flag" }, { n: Number(t.exploration.sessions ?? 0) - Number(t.exploration.over_flag ?? 0), color: TOKEN.ok, title: "under it" }]} /></>}
      {sess && <div className="bd-succ"><p className="bd-sub">Console succession</p>
        <p className="bd-line"><span className="bd-chip" style={{ ["--c" as string]: sess.pass ? TOKEN.ok : TOKEN.bad }}>{sess.pass ? "within target" : "over target"}</span>
          {` ${sess.turns} turns · ${k1(sess.eq)} eq before LIVE, all work (indicative target ≤ ${sess.target.turns} turns, ${k1(sess.target.eq)} eq)`}</p>
        <p className="bd-line">{`${sess.from} → ${sess.to}${sess.wall_min !== null ? ` · ${sess.wall_min} min to LIVE` : ""} · ${sess.legs_quoted} legs quoted the token, ${sess.legs_silent} silent`}</p></div>}
    </>)}
    {card("roadmap", board.milestones.length === 0 ? <p className="quiet">No milestone tracked: add a versions: line to the console's Live state.</p> :
      <ul className="bd-list">{board.milestones.map((m) => <li key={m.version}><b>{m.version}</b>{m.unavailable ? " unavailable" : <>
        {` ${m.done}/${m.total}`}<div className="bd-bar"><i style={{ width: `${((m.done ?? 0) / Math.max(1, m.total ?? 1)) * 100}%`, background: TOKEN.ok }} /></div></>}</li>)}</ul>)}
  </div>;
}

function Spark({ values }: { values: number[] }) {
  const max = Math.max(...values, 1);
  return <svg className="bd-spark" viewBox={`0 0 ${values.length * 10} 24`} preserveAspectRatio="none" role="img" aria-label="console cost per hour">
    {values.map((v, i) => <rect key={i} x={i * 10 + 1} width={8} y={24 - (v / max) * 22} height={(v / max) * 22} fill="var(--accent)" />)}</svg>;
}

function CardTable({ board, card }: { board: Board; card: CardId }) {
  const t = board.trends;
  const rows: [string, string][] = card === "velocity" ? t.leg_time.today.map((l) => [l.leg, `LIVE→PR ${l.to_pr_min ?? "–"}m · READY→merged ${l.ready_to_merged_min ?? "–"}m · total ${l.live_to_merged_min ?? "–"}m`])
    : card === "health" ? [...board.legs.map((l): [string, string] => [l.leg, `${label(board, "state", l.state)} · ${label(board, "stage", l.stage)}`]), ["CI", (["green", "pending", "no_checks", "red"] as const).map((c) => `${label(board, "ci", c)} ${board.ci[c]}`).join(" · ")], ["Budget", `week ${board.bank.week_pct ?? "n/a"}% · 5 h ${board.bank.five_hour_pct ?? "n/a"}%`]]
      : card === "tools" ? [...(t.failures?.classes ?? []).map((c): [string, string] => [c.class, `${c.sessions} session${c.sessions === 1 ? "" : "s"} · route ${c.route}`]), ...t.tools.map((x): [string, string] => [x.tool, x.recommendation])]
        : board.milestones.map((m): [string, string] => [m.version, m.unavailable ? "unavailable" : `${m.done}/${m.total} done${m.open_blockers?.length ? ` · blockers ${m.open_blockers.join(", ")}` : ""}`]);
  return <><h3>{TITLE[card]}</h3><p className="bd-rec">{board.cards[card]?.recommendation}</p>
    <table className="bd-table"><tbody>{rows.length ? rows.map(([a, b], i) => <tr key={i}><th scope="row">{a}</th><td>{b}</td></tr>) : <tr><td>Nothing to list.</td></tr>}</tbody></table></>;
}

// ---------------------------------------------------------------- the drawer
export type Panel = { kind: "leg" } | { kind: "card"; card: CardId } | { kind: "brief"; leg: string; row: string };
export function useDrawerKeys(drawer: Drawer | null, panel: Panel | null, legs: string[], set: (d: Drawer | null) => void, close: () => void) {
  useEffect(() => {
    if (!drawer && !panel) return;
    const on = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLElement && /^(input|textarea|select)$/i.test(e.target.tagName)) return;
      if (e.key === "Escape") { close(); return; }
      if (!drawer || panel?.kind !== "leg") return;
      if (/^Arrow|^Backspace$/.test(e.key)) { e.preventDefault(); set(applyKey(drawer, e.key, legs)); }
    };
    addEventListener("keydown", on);
    return () => removeEventListener("keydown", on);
  }, [drawer, panel, legs, set, close]);
}

function Brief({ token, row }: { token: string; row: string }) {
  const [text, setText] = useState<string | null>(null), [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    fetch(BRIEF_URL(row), { headers: { "X-Himmel-Token": token }, cache: "no-store" })
      .then((r) => (r.ok ? r.text() : Promise.reject(new Error(`the server answered ${r.status}`))))
      .then((t) => live && setText(t), (e) => live && setErr(String(e.message ?? e)));
    return () => { live = false; };
  }, [token, row]);
  return err ? <p className="run-error" role="alert">{err}</p> : <pre className="bd-brief">{text ?? "loading…"}</pre>;
}

export function DrawerView({ token, board, joined, drawer, panel, now, set, setPanel, close }: {
  token: string; board: Board; joined: Joined[]; drawer: Drawer | null; panel: Panel | null; now: number;
  set: (d: Drawer | null) => void; setPanel: (p: Panel | null) => void; close: () => void;
}) {
  const legs = joined.map((j) => j.leg.leg);
  const cur = drawer ? joined.find((j) => j.leg.leg === drawer.leg) : undefined;
  const segs = useMemo(() => (cur ? stageSegments(cur.leg, now) : []), [cur, now]);
  if (!panel) return null;
  const back = drawer && drawer.back.length > 0 && panel.kind === "leg";
  const idx = cur ? legs.indexOf(cur.leg.leg) : -1;
  const go = (leg: string) => drawer && set(openAt(drawer, leg, drawer.stage));
  return <aside className="bd-drawer" role="dialog" aria-label="Leg detail" aria-modal="false">
    <div className="bd-dhead">
      {panel.kind !== "leg" && drawer ? <button type="button" className="btn" onClick={() => setPanel({ kind: "leg" })}>← Back</button>
        : back ? <button type="button" className="btn" onClick={() => set(applyKey(drawer!, "Backspace", legs))}>← Back</button> : <span />}
      <button type="button" className="btn" onClick={close} aria-label="Close (Esc)">✕</button>
    </div>
    {panel.kind === "card" && <CardTable board={board} card={panel.card} />}
    {panel.kind === "brief" && <><h3>Brief · {panel.leg}</h3><Brief token={token} row={panel.row} /></>}
    {panel.kind === "leg" && cur && drawer && <>
      <h3>{cur.leg.leg} <small>{cur.leg.ticket}</small></h3>
      <p className="bd-goal">{cur.leg.goal}</p>
      <p className="bd-row"><StateChip board={board} state={cur.leg.state} />
        {cur.leg.pr && <button type="button" className="bd-link" onClick={() => set(openAt(drawer, cur.leg.leg, "pr"))}>{`PR ${cur.leg.pr.number}`}</button>}
        {cur.leg.pr?.url?.startsWith("https://") && <a className="bd-link" href={cur.leg.pr.url} target="_blank" rel="noreferrer">GitHub ↗</a>}
        {cur.row?.run ? <button type="button" className="bd-link" onClick={() => setPanel({ kind: "brief", leg: cur.leg.leg, row: cur.row!.name })}>brief</button>
          : cur.leg.links.brief?.startsWith("https://") && <a className="bd-link" href={cur.leg.links.brief} target="_blank" rel="noreferrer">brief ↗</a>}
        {cur.row?.run && <a className="bd-link" href={runHash(token, cur.row.run)}>open run page →</a>}
      </p>
      <div className="bd-nav"><button type="button" className="btn" disabled={idx <= 0} onClick={() => go(legs[idx - 1])}>↑ previous leg</button>
        <button type="button" className="btn" disabled={idx < 0 || idx >= legs.length - 1} onClick={() => go(legs[idx + 1])}>next leg ↓</button></div>
      {cur.need && <div className="bd-need"><b>{cur.need.action}</b><p>{cur.need.detail}</p>{cur.need.command && <code>{cur.need.command}</code>}</div>}
      <div className="bd-strip" aria-label="Stage strip">
        {segs.length === 0 ? <span className="quiet">no stage reached yet</span> : segs.map((s) => {
          const t0 = segs[0].from, span = Math.max(1, segs[segs.length - 1].to - t0);
          return <button key={s.stage} type="button" className={`bd-band${drawer.stage === s.stage ? " sel" : ""}`} onClick={() => set(openAt(drawer, drawer.leg, s.stage))}
            style={{ left: `${((s.from - t0) / span) * 100}%`, width: `${Math.max(2, ((s.to - s.from) / span) * 100)}%`, background: tone(board, "stage", s.stage) }} title={`${label(board, "stage", s.stage)} ${dur(s.from, s.to)}`} />;
        })}
      </div>
      <StageDots leg={cur.leg} board={board} onPick={(s) => set(openAt(drawer, drawer.leg, s))} />
      <Transcript board={board} leg={cur.leg} stage={drawer.stage} segs={segs} />
    </>}
    {panel.kind === "leg" && !cur && <p className="quiet">This leg is not on the board any more.</p>}
  </aside>;
}

function Transcript({ board, leg, stage, segs }: { board: Board; leg: BoardLeg; stage: Stage; segs: { stage: Stage; from: number; to: number }[] }) {
  const groups = STAGES.filter((s) => leg.timeline.some((b) => b.stage === s) || leg.stages[s]);
  const root = useRef<HTMLDivElement>(null);
  // scroll only when the stage or the leg changes, not on every poll or clock render
  useEffect(() => { root.current?.querySelector(".sel")?.scrollIntoView?.({ block: "nearest" }); }, [leg.leg, stage]);
  return <div className="bd-transcript" ref={root}>{groups.map((s) => {
    const at = leg.stages[s], bullets = leg.timeline.filter((b) => b.stage === s), seg = segs.find((g) => g.stage === s);
    return <section key={s} className={s === stage ? "sel" : ""}>
      <h4 style={{ ["--c" as string]: tone(board, "stage", s) }}>{label(board, "stage", s)}<small>{` ${hm(at)}${seg ? ` · ${dur(seg.from, seg.to)}` : ""}`}</small></h4>
      {bullets.map((b, i) => <p key={i} className="bd-bullet"><span className="bd-chip" style={{ ["--c" as string]: tone(board, "marker", b.marker) }}>{label(board, "marker", b.marker)}</span>{` ${b.text}`}</p>)}
    </section>;
  })}</div>;
}
