import { useEffect, useState } from "react";
import { RAG_EVAL_URL, ragEvalModel, type Measure, type Pilot, type RagEval, type Route, type Split } from "./rag-eval-model";

type State = { model: RagEval | null; error: string | null };
function useRagEval(token: string): State {
  const [s, setS] = useState<State>({ model: null, error: null });
  useEffect(() => {
    let live = true;
    fetch(RAG_EVAL_URL, { headers: { "X-Himmel-Token": token } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((j) => {
        if (j.state === "unreadable") throw new Error(j.reason || "the eval-runs ledger is unreadable");
        if (live) setS({ model: ragEvalModel(Array.isArray(j.rows) ? j.rows : []), error: null });
      })
      .catch((e) => live && setS({ model: null, error: String(e?.message ?? e) }));
    return () => { live = false; };
  }, [token]);
  return s;
}

const day = (ts: string) => new Date(ts).toLocaleDateString([], { day: "numeric", month: "short" });
const tokens = (t: number | null) => (t === null ? "—" : Math.round(t).toLocaleString());
const share = (s: Split) => `${s.count} of ${s.n} (${Math.round((s.count / s.n) * 100)}%)`;
const secs = (ms: number | null) => (ms === null ? "—" : `${(ms / 1000).toFixed(1)} s`);

function Cells({ m, gap }: { m: Measure | null; gap: string }) {
  if (!m) return <td colSpan={4} className="rag-gap">{gap}</td>;
  return (
    <>
      <td><b>{m.count} of {m.n}</b> <span className="rag-dim">{Math.round(m.rate * 100)}%</span>
        {m.heldout && <span className="rag-split">held-out {share(m.heldout)}</span>}
        {m.insample && <span className="rag-split">in-sample {share(m.insample)}</span>}</td>
      <td>{tokens(m.tokens)}</td>
      <td>{secs(m.ms)}</td>
      <td className="rag-dim" title={m.runId}>{day(m.ts)}</td>
    </>
  );
}

function Row({ r }: { r: Route }) {
  return (
    <tr className={r.key === "vanilla" ? "rag-yardstick" : undefined}>
      <th scope="row">{r.label}</th>
      <Cells m={r.finds} gap={r.findsGap} />
      <Cells m={r.answers} gap={r.answersGap} />
    </tr>
  );
}

function PilotSection({ p }: { p: Pilot }) {
  return (
    <section aria-label="Three-answer pilot">
      <h2>Supported answers: plain Claude Code, station search and local search</h2>
      <p className="rag-bottom">{p.headline}</p>
      <p className="rag-dim">{p.stopNote}, run {day(p.ts)}. {p.counts}</p>
      {p.noComparison && <p className="rag-sample" role="note">{p.noComparison}</p>}
      {p.clauses && p.clauses.map((c) => (
        <div key={c.arm}>
          <p className={c.answerClass}>{c.answer}</p>
          <p className={c.costClass}>{c.cost}</p>
        </div>
      ))}
      {p.exploratory && (
        <p className="rag-dim">Exploratory, not a confirmatory test: station against local search {p.exploratory.gainPp.toFixed(1)} points,
          raw p {p.exploratory.pRaw.toFixed(3)}, {p.exploratory.intervalLabel} {p.exploratory.interval[0].toFixed(1)} to {p.exploratory.interval[1].toFixed(1)} points.</p>
      )}
      <div className="rag-scroll">
        <table className="rag-table">
          <thead><tr><th scope="col">Setup</th><th scope="col">Supported</th><th scope="col">Cost</th><th scope="col">Search cash</th>
            <th scope="col">Search route use</th><th scope="col">Skips</th><th scope="col">Errors</th><th scope="col">Unjudged</th><th scope="col">Unlisted paraphrases</th></tr></thead>
          <tbody>{p.arms.map((a) => (
            <tr key={a.arm} className={a.arm === "V" ? "rag-yardstick" : undefined}>
              <th scope="row">{a.name}</th><td>{a.supported ?? "—"} of {p.n}</td><td>{a.costUsd === null ? "—" : `$${a.costUsd.toFixed(2)}`}</td>
              <td>{a.cashUsd === null ? "—" : `$${a.cashUsd.toFixed(2)}`}</td>
              <td>{a.route ? <>{a.route}<span className="rag-split">{a.use}</span></> : <span className="rag-gap">no search tool</span>}</td>
              <td>{a.skips ?? "—"}</td><td>{a.errors ?? "—"}</td><td>{a.unjudged ?? "—"}</td><td>{a.paraphrases ?? "—"}</td>
            </tr>))}
          </tbody>
        </table>
      </div>
      {p.cells.filter((c) => c.rows.length).map((c) => (
        <div className="rag-scroll" key={c.title}>
          <table className="rag-table">
            <thead><tr><th scope="col">{c.title}</th><th scope="col">Plain Claude Code</th><th scope="col">Station search</th><th scope="col">Local search</th></tr></thead>
            <tbody>{c.rows.map((r) => <tr key={r.name}><th scope="row">{r.name}</th><td>{r.V}</td><td>{r.S}</td><td>{r.Q}</td></tr>)}</tbody>
          </table>
        </div>
      ))}
      <ul className="rag-notes">
        <li>{p.judge}</li>
        <li>{p.spend}</li>
        {p.disclosures.map((d) => <li key={d}>{d}</li>)}
      </ul>
      <h2>Retrieval lists (a separate measurement)</h2>
      <ul className="rag-notes">{p.lists.map((l) => <li key={l}>{l}</li>)}</ul>
    </section>
  );
}

export function RagEvalPage({ token }: { token: string }) {
  const { model, error } = useRagEval(token);
  return (
    <main className="rag" aria-label="RAG eval">
      <h1>RAG eval</h1>
      {error && <p className="run-error" role="alert">The eval results could not be read: {error}.</p>}
      {!model && !error && <p className="quiet">Reading the eval results…</p>}
      {model && model.pilot && <PilotSection p={model.pilot} />}
      {model && (
        <>
          {model.pilot && <h2>Older runs: file found, not answers checked (a separate protocol group)</h2>}
          <p className="rag-bottom">{model.bottomLine}</p>
          <p className="rag-dim">From the eval runs already recorded{model.newest ? `, newest ${day(model.newest)}` : ""}. Opening this page runs no eval.</p>
          <p className="rag-sample">These scores are weak, and a rework of the eval is under way.</p>
          {model.sampleNote && <p className="rag-sample">{model.sampleNote}</p>}
          <div className="rag-scroll">
            <table className="rag-table">
              <thead>
                <tr><th rowSpan={2} scope="col">Route</th><th colSpan={4} scope="colgroup">Finds the file (hit@5 on the raw list)</th><th colSpan={4} scope="colgroup">Names a gold file among up to 3 guesses (does not check the answer)</th></tr>
                <tr><th scope="col">Found</th><th scope="col">List tokens</th><th scope="col">Median time</th><th scope="col">Run</th>
                  <th scope="col">Named</th><th scope="col">Session tokens</th><th scope="col">Median time</th><th scope="col">Run</th></tr>
              </thead>
              <tbody>{model.routes.map((r) => <Row key={r.key} r={r} />)}</tbody>
            </table>
          </div>
          <ul className="rag-notes">
            <li><b>Finds</b>: is a right file among the route's first 5 results. No model is involved. List tokens are what a caller reads from the list.</li>
            <li><b>Names a gold file among up to 3 guesses</b>: a Claude session with Read, Grep and Glob, plus the route as one tool, lists up to 3 files, and it counts when one of them is a gold file. The answer itself is not checked. Session tokens are the whole session's, so they are not comparable with list tokens.</li>
            <li><b>Vanilla Claude</b> is the same session with no route tool. It produces no ranked list, so it has no hit@5.</li>
            <li>A tie means the two 95% ranges overlap: the test cannot tell the two apart.</li>
          </ul>
        </>
      )}
    </main>
  );
}
