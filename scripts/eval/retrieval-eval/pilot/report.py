#!/usr/bin/env python3
"""report.py -- the RAG pilot's safe public summary and its eval-runs ledger row (design §7, §9, §12).

  report.py build --run R.json --scores S.jsonl --cohort C.json --bank B.jsonl --judge J.json
                  --arms A.json [--lists L.json] --identity I.json --retained M.json
                  --spend P.json --out ROW.json
  report.py append --row ROW.json --bank B.jsonl [--ledger PATH]
  report.py fixtures --out FILE.jsonl     (the real fixture rows the RAG eval page reads)

One row per run: eval=answer-ab, protocol=rag-pilot-r18. The pilot block carries only safe
aggregates: arms V/S/Q, the stop kind and reason, finalization status, judge-round completion,
discarded verdicts and per-arm unjudged counts, attempted/completed/common counts, the common
cohort hash, per-arm supported/cost/route/error/skip aggregates, the S-V and Q-V comparisons
(confirmatory, baseline-holm2: raw and adjusted p, gain, pointwise interval, label) and the
exploratory S-Q contrast, cost intervals, small-cell-merged kind/half/stratum cells, the
separate fixed-list panel, the exposure stance and the Q-to-S coupling disclosure, both spend
components and the total attempted-task spend. A HARD_STOP or void row has NO comparisons.
Never a task id, question, fact, path or note title: `append` scans the row against the private
bank before writing, refuses a duplicate run id for this protocol, and refuses to write after a
torn (interrupted) last line. Retention must already have happened (a retained manifest id is
required). Exit 0 ok, 3 refusal.
"""
import argparse, hashlib, importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
PROTOCOL = "rag-pilot-r18"
ARMS = ("V", "S", "Q")
SMALL = 5
COUPLING = ("Q can stop or void the S-V measurement too: both arms must pass the G6 route-use rule, a first-four Q "
            "failure stops calibration, and Q skips count toward the common two-task skip ceiling.")


def load(name, path):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


SC = load("score", os.path.join(HERE, "score.py"))
ER = load("eval_runs", os.path.join(REPO, "scripts", "eval", "lib", "eval_runs.py"))


def merge_small(cells):
    """{name: {arm: [k, n]}}: any cell under 5 tasks merges into 'other (small cells merged)'."""
    out, other = {}, {}
    for name, per in sorted(cells.items()):
        n = max(v[1] for v in per.values()) if per else 0
        if n < SMALL:
            for a, (k, m) in per.items():
                o = other.setdefault(a, [0, 0])
                o[0] += k
                o[1] += m
        else:
            out[name] = per
    if other:
        if max(v[1] for v in other.values()) < SMALL and out:
            last = sorted(out)[-1]
            for a, (k, m) in other.items():
                out[last][a] = [out[last][a][0] + k, out[last][a][1] + m]
            out[last + " + small cells"] = out.pop(last)
        else:
            out["other (small cells merged)"] = other
    return out


def cells(scores, cohort, bank, key):
    c = {}
    for t in cohort:
        name = bank[t].get(key) or "unknown"
        for a in ARMS:
            v = c.setdefault(name, {}).setdefault(a, [0, 0])
            v[0] += int(bool(scores[t][a]))
            v[1] += 1
    return merge_small(c)


def pilot_block(run, scores, cohort, bank, judge, arms, lists, spend, costs=None):
    hard = run.get("stop_kind") == "HARD_STOP"
    block = {"protocol": PROTOCOL, "arms": list(ARMS), "stop_kind": run.get("stop_kind"), "reason": run.get("reason"),
             "finalization_status": run.get("finalization_status"),
             "counts": {"attempted": run.get("attempted"), "completed": run.get("completed"), "common_scored": len(cohort)},
             "common_cohort_hash": hashlib.sha256("\n".join(sorted(cohort)).encode()).hexdigest() if cohort else None,
             "judge": {"completed_rounds": judge.get("completed_rounds", 0), "discarded_verdicts": judge.get("discarded_verdicts", 0),
                       "unjudged": judge.get("unjudged", {a: 0 for a in ARMS}), "ended": judge.get("ended")},
             "per_arm": arms, "exposure": "eval-only-reachable (dedicated revocable eval credential; reachability disclosed, not isolation)",
             "coupling": COUPLING, "spend": spend, "comparisons": None, "cost_intervals": None,
             "kinds": None, "halves": None, "strata": None, "lists": lists}
    if hard or len(cohort) < 36:
        block["void"] = True
        return block
    s = SC.summarize({t: scores[t] for t in cohort}, cohort, bank, costs=costs)
    block["void"] = False
    block["supported"] = s["supported"]
    block["comparisons"] = s["comparisons"]
    block["cost_intervals"] = s.get("cost_intervals")
    block["kinds"] = cells(scores, cohort, bank, "kind")
    block["halves"] = cells(scores, cohort, bank, "half")
    block["strata"] = cells(scores, cohort, bank, "stratum")
    return block


def metrics_of(block):
    m = {"common_scored": block["counts"]["common_scored"], "attempted": block["counts"]["attempted"],
         "spend_total_usd": block["spend"].get("total_usd"), "spend_cash_usd": block["spend"].get("cash_usd")}
    for a in ARMS:
        p = block["per_arm"].get(a, {})
        m["%s.supported" % a] = (block.get("supported") or {}).get(a)
        m["%s.cost_usd" % a] = p.get("cost_usd")
        m["%s.skips" % a] = p.get("skips")
    for c in block["comparisons"] or []:
        m["%s.gain_pp" % c["contrast"]] = c["gain_pp"]
        m["%s.p_raw" % c["contrast"]] = c["p_raw"]
        if c["p_adjusted"] is not None:
            m["%s.p_adjusted" % c["contrast"]] = c["p_adjusted"]
    return m


def make_row(block, identity, retained, run_id, gitsha=None, ts=None):
    if not retained or not retained.get("manifest_sha256"):
        raise ValueError("retain the run before its public row (no retained manifest)")
    config = {"protocol": PROTOCOL, "identity_hash": identity["config_hash"]}
    row = ER.make_row("answer-ab", "scripts/eval/retrieval-eval/pilot/report.py", config, metrics_of(block),
                      n=block["counts"]["common_scored"], status="ok" if not block["void"] else "inconclusive",
                      run_id=run_id, meta={"retained_manifest": retained["run_id"], "retained_manifest_sha256": retained["manifest_sha256"],
                                           "identity": identity["identity"]}, gitsha=gitsha or "fixture")
    row["protocol"] = PROTOCOL
    row["pilot"] = block
    if ts:
        row["ts"], row["host"] = ts, "fixture"
        row["meta"]["cli_version"], row["meta"]["effort"] = None, None
    return row


def leaks(row, bank):
    text = json.dumps(row, ensure_ascii=False)
    found = []
    for t in bank.values():
        needles = [t["id"], t.get("question", "")] + [f["text"] for f in t.get("facts") or []] + [f["path"] for f in t.get("files") or []]
        found += [n for n in needles if n and len(n) >= 3 and ('"%s"' % n in text or (len(n) > 8 and n in text))]
    return sorted(set(found))


def append(row, bank, path=None):
    bad = ER.validate(row)
    if bad:
        raise ValueError("invalid row: %s" % "; ".join(bad))
    leak = leaks(row, bank)
    if leak:
        raise ValueError("the public row names %d private task string(s)" % len(leak))
    p = ER.ledger_path(path)
    if os.path.exists(p):
        raw = open(p, "rb").read()
        if raw and not raw.endswith(b"\n"):
            raise ValueError("the ledger ends in a torn line (an interrupted append): repair it first")
        for line in raw.decode("utf-8").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("protocol") == PROTOCOL and r.get("run_id") == row["run_id"]:
                raise ValueError("run %s is already published for %s" % (row["run_id"], PROTOCOL))
    return ER.append_row(row, p)


def _bank(n=40):
    kinds = ["luna_lookup"] * 6 + ["luna_meaning"] * 8 + ["himmel_docs"] * 6 + ["himmel_code"] * 8 + ["two_files"] * 8 + ["not_there"] * 4
    strata = {"luna_lookup": "doc", "luna_meaning": "doc", "himmel_docs": "doc", "himmel_code": "code", "two_files": "mixed", "not_there": "none"}
    return {"f%02d" % i: {"id": "f%02d" % i, "kind": kinds[i - 1], "half": "real" if i % 2 else "harder", "stratum": strata[kinds[i - 1]]}
            for i in range(1, n + 1)}


def _scores(cohort, s_rate, q_rate, v_rate, real_s=None):
    """Deterministic synthetic outcomes: the first round(rate*n) tasks are supported per arm."""
    n = len(cohort)
    out = {}
    for i, t in enumerate(cohort):
        out[t] = {"V": i < round(v_rate * n), "S": i < round(s_rate * n), "Q": i < round(q_rate * n)}
        if real_s is not None and int(t[1:]) % 2:
            out[t]["S"] = out[t]["V"] if real_s == "same" else out[t]["S"]
    return out


def _arms(cost=(0.19, 0.21, 0.22)):
    return {a: {"supported": None, "cost_usd": round(c * 37, 3), "cost_mean_usd": c, "cash_usd": 0.05 if a == "S" else 0.0,
                "route": {"offered": 37 if a != "V" else 0, "called": 33 if a != "V" else 0, "returned": 31 if a != "V" else 0,
                          "read": 26 if a != "V" else 0, "cited": 22 if a != "V" else 0},
                "qmd_only": 20 if a != "V" else 0, "graph_only": 3 if a != "V" else 0, "both": 10 if a != "V" else 0,
                "skips": 1 if a != "V" else 0, "errors": 0, "timeouts": 0, "unjudged": 1, "paraphrase_candidates": 2,
                "latency_ms_median": 41000 + 3000 * i, "tokens_mean": 52000 + 4000 * i} for i, (a, c) in enumerate(zip(ARMS, cost))}


FIXTURES = [  # (run_id, run report, scores maker, cohort size)
    ("fixture-rag-pilot-r18-short", {"stop_kind": "FINALIZE_ONLY", "reason": "capacity_refused", "finalization_status": "short",
                                     "attempted": 38, "completed": 38}, lambda c: _scores(c, .70, .55, .40), 37),
    ("fixture-rag-pilot-r18-void", {"stop_kind": "HARD_STOP", "reason": "insufficient_common_cohort", "finalization_status": "none",
                                    "attempted": 35, "completed": 34}, lambda c: _scores(c, .7, .6, .4), 0),
    ("fixture-rag-pilot-r18-all-loss", {"stop_kind": "NONE", "reason": None, "finalization_status": "full",
                                        "attempted": 40, "completed": 40}, lambda c: _scores(c, .30, .35, .70), 40),
    ("fixture-rag-pilot-r18-mixed", {"stop_kind": "NONE", "reason": None, "finalization_status": "full",
                                     "attempted": 40, "completed": 40}, lambda c: _scores(c, .80, .50, .45, real_s="same"), 40),
]


def fixture_rows():
    bank = _bank()
    rows = []
    for run_id, run, mk, n in FIXTURES:
        cohort = sorted(bank)[:n]
        scores = mk(cohort)
        judge = {"completed_rounds": 4 if n else 0, "discarded_verdicts": 1 if n else 0, "unjudged": {"V": 1, "S": 1, "Q": 0}, "ended": "usage_expired" if n else None}
        lists = {"complete": n == 40, "S": {"fact_file_at5": [24, 36], "by_stratum": {"code": [6, 8], "doc": [14, 20], "mixed": [4, 8]}},
                 "Q": {"fact_file_at5": [21, 36], "by_stratum": {"code": [5, 8], "doc": [12, 20], "mixed": [4, 8]}}} if n else None
        spend = {"subscription_equivalent_usd": 8.81 if n else 7.4, "cash_usd": 0.31 if n else 0.22, "total_usd": 9.12 if n else 7.62}
        costs = {t: {"V": 0.17 + 0.001 * i, "S": 0.20 + 0.002 * (i % 5), "Q": 0.21 + 0.0015 * (i % 7)} for i, t in enumerate(cohort)}
        block = pilot_block(run, scores, cohort, bank, judge, _arms(), lists, spend, costs)
        ident = {"config_hash": "f" * 64, "identity": {"protocol": PROTOCOL, "fixture": True}}
        rows.append(make_row(block, ident, {"run_id": run_id, "manifest_sha256": "0" * 64}, run_id, gitsha="fixture", ts="2026-11-09T12:00:00Z"))
    legacy = ER.make_row("answer-ab", "scripts/eval/retrieval-eval/answer-ab.py", {"arms": ["fused-cached", "vanilla"]},
                         {"fused-cached.file_hit": 70, "fused-cached.n": 75, "vanilla.file_hit": 69, "vanilla.n": 75},
                         n=75, run_id="fixture-answer-ab-legacy-old75", gitsha="fixture", meta={})
    legacy["ts"], legacy["host"] = "2026-11-05T19:20:03Z", "fixture"
    legacy["meta"] = {"cli_version": None, "effort": None}
    rows.append(legacy)
    return rows


def main(argv):
    ap = argparse.ArgumentParser(prog="report.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fixtures"); f.add_argument("--out", required=True)
    b = sub.add_parser("build")
    for k in ("run", "scores", "cohort", "bank", "judge", "arms", "identity", "retained", "spend", "out"):
        b.add_argument("--" + k, required=True)
    b.add_argument("--lists")
    ap_ = sub.add_parser("append"); ap_.add_argument("--row", required=True); ap_.add_argument("--bank", required=True); ap_.add_argument("--ledger")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "fixtures":
            with open(a.out, "w") as fh:
                for r in fixture_rows():
                    fh.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")
            return 0
        bank = {t["id"]: t for t in (json.loads(l) for l in open(a.bank) if l.strip())}
        if a.cmd == "append":
            print(append(json.load(open(a.row)), bank, a.ledger))
            return 0
        scores = {}
        for l in open(a.scores):
            if l.strip():
                r = json.loads(l)
                scores.setdefault(r["task_id"], {})[r["arm"]] = bool(r["supported"])
        block = pilot_block(json.load(open(a.run)), scores, json.load(open(a.cohort)), bank, json.load(open(a.judge)),
                            json.load(open(a.arms)), json.load(open(a.lists)) if a.lists else None, json.load(open(a.spend)))
        row = make_row(block, json.load(open(a.identity)), json.load(open(a.retained)), json.load(open(a.run)).get("run_id") or "rag-pilot-r18")
        with open(a.out, "w") as fh:
            json.dump(row, fh, sort_keys=True)
    except (ValueError, OSError, KeyError) as e:
        print("report: refused: %s" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
