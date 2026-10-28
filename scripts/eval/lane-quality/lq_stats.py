#!/usr/bin/env python3
"""scripts/eval/lane-quality/lq_stats.py - lane-quality statistics (HIMMEL-4648).

Called by run.sh; no model call, stdlib only.

  lq_stats.py summary <runs.jsonl>...
      Markdown table per lane, model and task: the mean and a bootstrap 95% CI
      of the acceptance fraction and of each judge criterion over the task's
      repeats, pass@k and pass^k over its repeats and cost per accepted run,
      plus how many rows have no judge score (counted, not dropped).
  lq_stats.py calibration [--judge2-label L] [--json] [--no-ledger] <run-dir>...
      How far the judge can be trusted. Judge vs hidden acceptance: AUC and
      point-biserial r of each criterion against accept_ok, with bootstrap 95%
      CIs. Judge vs judge: with --judge2-label, quadratic weighted kappa per
      criterion against the stored second-judge results
      (<stem>.judge2.<label>.json, written by `run.sh calibration`). Appends one
      `lane-quality-calibration` row to the eval-runs ledger unless --no-ledger;
      --json prints that row instead of the report.
      Model-graded calibration (HIMMEL-7555): --judge1-label grades with a
      fresh first grader instead of the stored judge. With a second grader the
      row adds Cohen's kappa between the two on the per-run verdict (pass =
      every correctness claim holds, correctness 5); with --tiebreak-label it
      counts the disagreements sent to the tie-breaker and the side it took.
      Every run also reports the stored judge's --judge-twice flips. --sample
      FILE (absolute judge-packet paths, one per line) limits every figure to
      those runs.
  lq_stats.py disagreements --judge2-label L [--judge1-label L] [--sample F] <run-dir>...
      `<run-dir>\t<stem>` of each run the two graders give different verdicts.
  lq_stats.py vendor <model>...
      The vendor each model name belongs to (opus, sonnet and haiku are all
      anthropic); a name it does not know is its own vendor, or the maker
      before the "/" of an OpenRouter slug.
"""
import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import eval_runs  # noqa: E402

CRITERIA = eval_runs.LQ_CRITERIA
SCALE = (1, 5)  # judge-schema.json bounds
CLAIM_PREFIX = {"correctness": "C", "scope_discipline": "S", "test_quality": "T", "honesty": "H"}
N_CLAIMS = 16  # judge-claims-schema.json: C1-C4, S1-S4, T1-T4, H1-H4
# (pattern, vendor), first match wins: a model's family is its maker.
VENDORS = (
    (r"anthropic|claude|opus|sonnet|haiku|fable", "anthropic"),
    (r"openai|gpt|codex", "openai"),
    (r"google|gemini|gemma", "google"),
    (r"deepseek", "deepseek"),
    (r"qwen|alibaba", "alibaba"),
    (r"z-ai|zhipu|glm", "zhipu"),
    (r"moonshot|kimi", "moonshot"),
    (r"llama", "meta"),
    (r"mistral", "mistral"),
    (r"x-ai|grok", "xai"),
)


def vendor(model):
    m = model.lower()
    for pat, v in VENDORS:
        if re.search(pat, m):
            return v
    return m.split("/", 1)[0]


def read_rows(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


def stem(row):
    r = row.get("rep") or 1
    return "%s.r%d" % (row["task"], r) if r > 1 else row["task"]


def auc(scores, labels):
    """Mann-Whitney AUC: P(score of a positive > score of a negative), ties
    count half. None when either class is empty."""
    pos = [s for s, l in zip(scores, labels) if l]
    neg = [s for s, l in zip(scores, labels) if not l]
    if not pos or not neg:
        return None
    wins = sum(1.0 if p > n else 0.5 if p == n else 0.0 for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def point_biserial(scores, labels):
    """Pearson r between a score and a 0/1 label. None when either is constant."""
    n = len(scores)
    if n < 2:
        return None
    ys = [1.0 if l else 0.0 for l in labels]
    ms, my = sum(scores) / n, sum(ys) / n
    cov = sum((s - ms) * (y - my) for s, y in zip(scores, ys))
    vs = sum((s - ms) ** 2 for s in scores)
    vy = sum((y - my) ** 2 for y in ys)
    if vs == 0 or vy == 0:
        return None
    return cov / math.sqrt(vs * vy)


def weighted_kappa(a, b, lo=SCALE[0], hi=SCALE[1]):
    """Quadratic weighted Cohen's kappa of two raters on the integer scale
    lo..hi. A pair with either score off that scale is ignored. None with no
    pairs, or when chance disagreement is zero (both raters gave one and the
    same score throughout)."""
    if len(a) != len(b):
        return None
    ab = [(x, y) for x, y in zip(a, b) if x in range(lo, hi + 1) and y in range(lo, hi + 1)]
    a, b = [x for x, _ in ab], [y for _, y in ab]
    if not a:
        return None
    k = hi - lo + 1
    n = len(a)
    obs = [[0] * k for _ in range(k)]
    for x, y in zip(a, b):
        obs[int(x) - lo][int(y) - lo] += 1
    ra = [sum(r) for r in obs]
    cb = [sum(obs[i][j] for i in range(k)) for j in range(k)]
    w = [[(i - j) ** 2 / (k - 1) ** 2 for j in range(k)] for i in range(k)]
    wo = sum(w[i][j] * obs[i][j] for i in range(k) for j in range(k))
    we = sum(w[i][j] * ra[i] * cb[j] / n for i in range(k) for j in range(k))
    if we == 0:
        return None
    return 1 - wo / we


def cohen_kappa(a, b):
    """Cohen's kappa of two raters on nominal labels, (n*agree - S) / (n^2 - S)
    with S the sum over labels of the two raters' counts multiplied, so a
    fixture's hand value comes out exact. None with no pairs, or when chance
    agreement is total (both raters gave one and the same label throughout)."""
    if len(a) != len(b) or not a:
        return None
    n = len(a)
    agree = sum(1 for x, y in zip(a, b) if x == y)
    s = sum(a.count(c) * b.count(c) for c in set(a) | set(b))
    if s == n * n:
        return None
    return (n * agree - s) / (n * n - s)


def verdict(scores):
    """The per-run verdict: pass when every correctness claim holds (correctness 5)."""
    c = scores.get("correctness") if isinstance(scores, dict) else None
    return c == SCALE[1] if eval_runs._num(c) else None


def _cell(s):
    if s["mean"] is None:
        return "–"
    if s["ci"] is None:
        return "%.2f" % s["mean"]
    return "%.2f [%.2f, %.2f]" % (s["mean"], s["ci"]["lo"], s["ci"]["hi"])


def _num_cell(x):
    return "–" if x is None else "%.2f" % x


def cmd_summary(paths):
    rows = [r for p in paths for r in read_rows(p)]
    groups = {}
    for r in rows:
        model = r.get("model") or "?"
        if r.get("effort"):
            model += " (%s)" % r["effort"]
        groups.setdefault((r.get("lane") or "?", model), []).append(r)
    print("Per task over its repeats: mean [bootstrap 95% CI]; no CI below 2 repeats. "
          "Judge means leave out the rows counted under `judge missing`. "
          "pass@k: at least one of k repeats accepted; pass^k: all k accepted; k is the fewest repeats "
          "of any task in that lane and model. $/accepted: cost over accepted runs.")
    print()
    print("| lane | model | task | n | k | accept | pass@k | pass^k | $/accepted | correctness | scope | tests | honesty "
          "| judge missing |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for (lane, model), rs in sorted(groups.items()):
        for tid, s in eval_runs.lane_quality_stats(rs).items():
            cells = [_cell(s["accept_frac"])] + [_num_cell(s[k]) for k in ("pass_at_k", "pass_pow_k", "cost_per_accepted")] \
                + [_cell(s["judge_" + c]) for c in CRITERIA]
            print("| %s | %s | %s | %d | %d | %s | %d |" % (lane, model, tid, s["n"], s["k"], " | ".join(cells),
                                                           s["judge_missing"]))
    return 0


def _judge2_scores(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    s = d.get("structured_output") if isinstance(d, dict) else None
    if s is None and isinstance(d, dict) and isinstance(d.get("result"), str):
        try:
            s = json.loads(d["result"])
        except ValueError:
            s = None
    if not isinstance(s, dict):
        return None
    if isinstance(s.get("claims"), dict):
        # a claims result scores each criterion as run.sh judge_scores does: 1 + the claims that hold
        s = dict(s)
        for c, p in CLAIM_PREFIX.items():
            s[c] = 1 + sum(1 for k, v in s["claims"].items()
                           if k.startswith(p) and isinstance(v, dict) and v.get("holds") is True)
    return s


def decode_label(label):
    """(model, effort, lane) from a stored-result label: run.sh joins the escaped
    parts with "__", and a label of one or two parts is the native lane."""
    parts = [re.sub(r"_([0-9a-f]{2})", lambda m: chr(int(m.group(1), 16)), p) for p in label.split("__")]
    parts += [""] * (3 - len(parts))
    return parts[0], parts[1], parts[2] or "native"


def load_rows(dirs, sample=None):
    """Every row of the run dirs, or only those whose judge packet --sample lists."""
    keep = None
    if sample:
        with open(sample, encoding="utf-8") as fh:
            keep = {os.path.realpath(l.strip()) for l in fh if l.strip()}
    rows = []
    for d in dirs:
        for r in read_rows(os.path.join(d, "runs.jsonl")):
            r["_dir"] = d
            if keep is None or os.path.realpath(os.path.join(d, stem(r) + ".judge-packet.md")) in keep:
                rows.append(r)
    return rows


def graded(rows, label):
    """id(row) -> one grader's scores: the stored judge's with no label, else its stored result's."""
    out = {}
    for r in rows:
        s = r.get("judge") if label is None else _judge2_scores(
            os.path.join(r["_dir"], "%s.judge2.%s.json" % (stem(r), label)))
        if isinstance(s, dict):
            out[id(r)] = s
    return out


def disagreements(rows, judge1_label, judge2_label):
    """The rows both graders scored whose per-run verdicts differ."""
    first, second = graded(rows, judge1_label), graded(rows, judge2_label)
    out = []
    for r in rows:
        a, b = verdict(first.get(id(r))), verdict(second.get(id(r)))
        if a is not None and b is not None and a != b:
            out.append(r)
    return out


def calibration_row(dirs, judge2_label=None, judge1_label=None, tiebreak_label=None, sample=None):
    rows = load_rows(dirs, sample)
    judged = [r for r in rows if isinstance(r.get("judge"), dict)]
    paired = [r for r in judged if isinstance(r.get("accept_ok"), bool)]
    metrics = {
        "n_rows": float(len(rows)),
        "judge_missing": float(len(rows) - len(judged)),
        "accept_missing": float(sum(1 for r in judged if not isinstance(r.get("accept_ok"), bool))),
    }
    ci = {}
    for c in CRITERIA:
        pairs = [(r["judge"][c], r["accept_ok"]) for r in paired if eval_runs._num(r["judge"].get(c))]
        xs, ys = [p[0] for p in pairs], [p[1] for p in pairs]
        for name, f in (("auc_", auc), ("pb_", point_biserial)):
            metrics[name + c] = f(xs, ys)
            b = eval_runs.bootstrap_ci(pairs, stat=lambda ps, f=f: f([p[0] for p in ps], [p[1] for p in ps]))
            if b and metrics[name + c] is not None:
                ci[name + c] = {"lo": b["lo"], "hi": b["hi"]}
    n_kappa = 0
    for c in CRITERIA:
        metrics["kappa_" + c] = None
    if judge2_label:
        first = graded(rows, judge1_label)
        second = graded([r for r in rows if id(r) in first], judge2_label)
        metrics["judge2_missing"] = float(len(first) - len(second))
        both = [r for r in rows if id(r) in second]
        n_kappa = len(both)
        for c in CRITERIA:
            ab = [(first[id(r)][c], second[id(r)][c]) for r in both
                  if eval_runs._num(first[id(r)].get(c)) and eval_runs._num(second[id(r)].get(c))]
            metrics["kappa_" + c] = weighted_kappa([x for x, _ in ab], [y for _, y in ab])
        vv = [(verdict(first[id(r)]), verdict(second[id(r)])) for r in both]
        vv = [(x, y) for x, y in vv if x is not None and y is not None]
        metrics["verdict_kappa"] = cohen_kappa([x for x, _ in vv], [y for _, y in vv])
        metrics["n_verdict"] = float(len(vv))
        metrics["verdict_agree"] = float(sum(1 for x, y in vv if x == y))
        if tiebreak_label:
            dis = disagreements(rows, judge1_label, judge2_label)
            third = graded(dis, tiebreak_label)
            sides = [(verdict(third.get(id(r))), verdict(first[id(r)])) for r in dis]
            metrics["tiebreak_sent"] = float(len(dis))
            metrics["tiebreak_grader1"] = float(sum(1 for t, a in sides if t is not None and t == a))
            metrics["tiebreak_grader2"] = float(sum(1 for t, a in sides if t is not None and t != a))
            metrics["tiebreak_missing"] = float(sum(1 for t, _ in sides if t is None))
    metrics["n_kappa"] = float(n_kappa)
    # the stored judge's --judge-twice record: a verdict flip is judge vs judge_b, claim flips are as recorded
    twice = [r for r in judged if isinstance(r.get("judge_b"), dict)]
    vflips = [verdict(r["judge"]) != verdict(r["judge_b"]) for r in twice
              if verdict(r["judge"]) is not None and verdict(r["judge_b"]) is not None]
    cflips = sum((r.get("judge_flips") or {}).get("claims") or 0 for r in twice)
    metrics["n_twice"] = float(len(twice))
    metrics["verdict_flips"] = float(sum(vflips))
    metrics["verdict_flip_rate"] = sum(vflips) / len(vflips) if vflips else None
    metrics["claim_flips"] = float(cflips)
    metrics["claim_flip_rate"] = cflips / (N_CLAIMS * len(twice)) if twice else None
    judge_models = sorted({r.get("judge_model") for r in judged if r.get("judge_model")})
    graders = []
    if judge2_label:
        if judge1_label:
            g1 = decode_label(judge1_label)
        else:  # the stored judge, which runs native
            g1 = (", ".join(judge_models), ", ".join(sorted({r.get("judge_effort") or "" for r in judged})), "native")
        for role, g in (("grader1", g1), ("grader2", decode_label(judge2_label)),
                        ("tiebreak", decode_label(tiebreak_label) if tiebreak_label else None)):
            if g:
                graders.append({"role": role, "model": g[0], "effort": g[1], "lane": g[2], "vendor": vendor(g[0])})
    config = {
        "models": sorted({r.get("model") for r in rows if r.get("model")}),
        "judge_models": judge_models,
        "judge2": judge2_label,
        "judge1": judge1_label,
        "tiebreak": tiebreak_label,
        "graders": graders,
        "model_graded": bool(judge2_label),
        "sample": os.path.abspath(sample) if sample else None,
        "runs": sorted({r.get("run_id") or "?" for r in rows}),
    }
    return eval_runs.make_row(
        "lane-quality-calibration", "scripts/eval/lane-quality/run.sh", config, metrics, n=len(paired),
        model=None, lane=None, ci=ci, ci_level=0.95 if ci else None,
        ci_method="bootstrap-percentile" if ci else None,
        artifact=None, meta={"run_dirs": [os.path.abspath(d) for d in dirs]})


def _fmt(x):
    return "–" if x is None else "%.3f" % x


def cmd_calibration(args):
    row = calibration_row(args.dirs, args.judge2_label, args.judge1_label, args.tiebreak_label, args.sample)
    if not args.no_ledger:
        eval_runs.append_safe(row, who="lane-quality calibration")
    if args.json:
        print(json.dumps(row))
        return 0
    m, ci = row["metrics"], row["ci"]
    print("Judge vs hidden acceptance (n=%d judged rows with an acceptance result; %d rows with no judge score)"
          % (row["n"], int(m["judge_missing"])))
    print()
    print("| criterion | AUC [95%% CI] | point-biserial r [95%% CI] | weighted kappa vs %s |" % (args.judge2_label or "–"))
    print("|---|---|---|---|")
    for c in CRITERIA:
        cell = []
        for k in ("auc_" + c, "pb_" + c):
            b = ci.get(k)
            cell.append(_fmt(m[k]) + (" [%.3f, %.3f]" % (b["lo"], b["hi"]) if b else ""))
        print("| %s | %s | %s | %s |" % (c, cell[0], cell[1], _fmt(m["kappa_" + c])))
    if args.judge2_label:
        print()
        print("Second judge: %d rows rescored, %d without a stored result." % (int(m["n_kappa"]), int(m["judge2_missing"])))
        g = {x["role"]: x for x in row["config"]["graders"]}
        print("Model-graded, no human label. " + "; ".join(
            "%s %s (effort %s, %s lane, vendor %s)" % (name, g[k]["model"], g[k]["effort"] or "default", g[k]["lane"],
                                                       g[k]["vendor"])
            for k, name in (("grader1", "grader 1"), ("grader2", "grader 2"), ("tiebreak", "tie-breaker")) if k in g) + ".")
        print("Per-run verdict (pass = every correctness claim holds): Cohen's kappa %s between grader 1 and grader 2 "
              "over %d runs, %d agree." % (_fmt(m["verdict_kappa"]), int(m["n_verdict"]), int(m["verdict_agree"])))
        if "tiebreak" in g:
            print("Tie-breaker %s: %d disagreements sent; sided with grader 1 in %d, grader 2 in %d, %d without a result."
                  % (g["tiebreak"]["model"], int(m["tiebreak_sent"]), int(m["tiebreak_grader1"]),
                     int(m["tiebreak_grader2"]), int(m["tiebreak_missing"])))
    if m["n_twice"]:
        print("--judge-twice flips (stored judge %s): verdict %d of %d runs (%s), claims %d of %d (%s)" % (
            ", ".join(row["config"]["judge_models"]) or "?", int(m["verdict_flips"]), int(m["n_twice"]),
            _fmt(m["verdict_flip_rate"]), int(m["claim_flips"]), N_CLAIMS * int(m["n_twice"]), _fmt(m["claim_flip_rate"])))
    return 0


def cmd_disagreements(args):
    for r in disagreements(load_rows(args.dirs, args.sample), args.judge1_label, args.judge2_label):
        print("%s\t%s" % (r["_dir"], stem(r)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="lq_stats.py", description="lane-quality statistics (HIMMEL-4648)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("files", nargs="+")
    c = sub.add_parser("calibration")
    c.add_argument("dirs", nargs="+")
    c.add_argument("--judge2-label")
    c.add_argument("--judge1-label")
    c.add_argument("--tiebreak-label")
    c.add_argument("--sample")
    c.add_argument("--json", action="store_true")
    c.add_argument("--no-ledger", action="store_true")
    g = sub.add_parser("disagreements")
    g.add_argument("dirs", nargs="+")
    g.add_argument("--judge2-label", required=True)
    g.add_argument("--judge1-label")
    g.add_argument("--sample")
    v = sub.add_parser("vendor")
    v.add_argument("models", nargs="+")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "summary":
            return cmd_summary(args.files)
        if args.cmd == "vendor":
            print("\n".join(vendor(m) for m in args.models))
            return 0
        if args.cmd == "disagreements":
            return cmd_disagreements(args)
        return cmd_calibration(args)
    except (OSError, ValueError, KeyError) as e:
        print("lq_stats: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
