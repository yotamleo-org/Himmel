// The RAG eval page (#t=<token>&page=rag-eval): per retrieval route, what the evals already measured, from GET /api/rag-eval.
// A first cut: it runs no eval and shows no number the ledger does not hold.
import { useEffect, useState } from "react";
import { RAG_EVAL_URL, ragEvalModel, type Measure, type RagEval, type Route } from "./rag-eval-model";

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
const secs = (ms: number | null) => (ms === null ? "—" : `${(ms / 1000).toFixed(1)} s`);

function Cells({ m, gap }: { m: Measure | null; gap: string }) {
  if (!m) return <td colSpan={4} className="rag-gap">{gap}</td>;
  return (
    <>
      <td><b>{m.count} of {m.n}</b> <span className="rag-dim">{Math.round(m.rate * 100)}%</span></td>
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

export function RagEvalPage({ token }: { token: string }) {
  const { model, error } = useRagEval(token);
  return (
    <main className="rag" aria-label="RAG eval">
      <h1>RAG eval</h1>
      {error && <p className="run-error" role="alert">The eval results could not be read: {error}.</p>}
      {!model && !error && <p className="quiet">Reading the eval results…</p>}
      {model && (
        <>
          <p className="rag-bottom">{model.bottomLine}</p>
          <p className="rag-dim">From the eval runs already recorded{model.newest ? `, newest ${day(model.newest)}` : ""}. Opening this page runs no eval.</p>
          <div className="rag-scroll">
            <table className="rag-table">
              <thead>
                <tr><th rowSpan={2} scope="col">Route</th><th colSpan={4} scope="colgroup">Finds the file (hit@5 on the raw list)</th><th colSpan={4} scope="colgroup">Right answers (Claude session)</th></tr>
                <tr><th scope="col">Found</th><th scope="col">List tokens</th><th scope="col">Median time</th><th scope="col">Run</th>
                  <th scope="col">Right</th><th scope="col">Session tokens</th><th scope="col">Median time</th><th scope="col">Run</th></tr>
              </thead>
              <tbody>{model.routes.map((r) => <Row key={r.key} r={r} />)}</tbody>
            </table>
          </div>
          <ul className="rag-notes">
            <li><b>Finds</b>: is a right file among the route's first 5 results. No model is involved. List tokens are what a caller reads from the list.</li>
            <li><b>Right answers</b>: a Claude session with Read, Grep and Glob, plus the route as one tool, names the right file. Session tokens are the whole session's, so they are not comparable with list tokens.</li>
            <li><b>Vanilla Claude</b> is the same session with no route tool. It produces no ranked list, so it has no hit@5.</li>
            <li>A tie means the two 95% ranges overlap: the test cannot tell the two apart.</li>
          </ul>
        </>
      )}
    </main>
  );
}
