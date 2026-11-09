#!/usr/bin/env python3
"""score.py -- the RAG pilot's strict supported-answer scorer and statistics (design section 5).

Scoring (free, the same script for V, S and Q):
  * an answer is supported when every required fact (or one of its listed variants) appears in
    the ANSWER text AND, for each fact, one of the first 3 FILES paths holds it in the copy;
  * a not-there task is right only for exactly "ANSWER: NOT FOUND" with an empty FILES list;
  * a missing ANSWER/FILES block is not supported (and counted); a file named alone never passes;
  * two dispute kinds are judge candidates: a fact that is in the answer while a named file exists
    but does not hold it in the listed words, and a named file the script cannot read.
The eight planted controls run in every arm and must score as planted.

The test (two predeclared contrasts S-V and Q-V on the common cohort):
  exact two-sided McNemar per contrast, Holm over the two (tie order S-V then Q-V), the 15-point
  bar per arm, the real-half headline qualifier per arm, a pointwise Tango 95% score interval per
  contrast (S-Q exploratory: raw p and interval, never a confirmatory label), paired 95% t
  intervals for cost differences, and exact trinomial power bounds (raw alpha .025 / .05).

  score.py controls                 -> the eight controls in each arm (exit 3 if any misfires)
  score.py power                    -> the design's power-bound table
  score.py summarize --scores S.jsonl --cohort C.json --bank B.jsonl -> the comparison summary
Exit 0 ok, 3 refusal.
"""
import argparse, hashlib, json, math, os, re, sys

ARMS = ("V", "S", "Q")
CONTRASTS = (("S-V", "S", "V", True), ("Q-V", "Q", "V", True), ("S-Q", "S", "Q", False))
BAR_PP, ALPHA, Z95 = 15.0, 0.05, 1.959963984540054
ANSWER_RE = re.compile(r"^ANSWER:[ \t]*(.*)$", re.M)
FILES_RE = re.compile(r"^FILES:[ \t]*$", re.M)


def parse(text):
    m, fm = ANSWER_RE.search(text or ""), FILES_RE.search(text or "")
    if not m or not fm or fm.start() < m.start():
        return None, []
    files = [l.strip() for l in text[fm.end():].splitlines() if l.strip()]
    return m.group(1).strip(), files


def holds(text, fact):
    t = (text or "").lower()
    return any(s.lower() in t for s in [fact["text"]] + list(fact.get("variants") or []))


def score(task, text, read):
    """read(path) -> file text, or None when the file does not exist, or False when unreadable."""
    answer, files = parse(text)
    out = {"task_id": task["id"], "answer_block": answer is not None, "supported": False, "disputes": [],
           "paraphrase_candidates": 0, "fact_pass": []}
    if answer is None:
        return out
    top = files[:3]
    if task.get("answerability") == "not_there" or not task.get("facts"):
        out["supported"] = answer == "NOT FOUND" and not files
        return out
    if answer == "NOT FOUND":
        return out
    ok = True
    contents = {p: read(p) for p in top}
    for i, fact in enumerate(task["facts"]):
        in_answer = holds(answer, fact)
        in_file = any(isinstance(c, str) and holds(c, fact) for c in contents.values())
        if in_answer and not in_file:
            if any(c is False for c in contents.values()):
                out["disputes"].append({"fact": i, "kind": "unreadable_file"})
            elif any(isinstance(c, str) for c in contents.values()):
                out["disputes"].append({"fact": i, "kind": "fact_in_other_words_in_file"})
        if not in_answer and answer and in_file:
            out["paraphrase_candidates"] += 1
        out["fact_pass"].append(in_answer and in_file)
        ok = ok and in_answer and in_file
    out["supported"] = ok
    return out


def apply_verdicts(row, verdicts):
    """A scored row after the APPLIED judge verdicts: {fact index: True|False}. A disputed fact
    with no applied verdict stays unsupported (unjudged counts as not supported)."""
    if not row["answer_block"] or not row["fact_pass"]:
        return row["supported"]
    return all(p or verdicts.get(i) is True for i, p in enumerate(row["fact_pass"]))


CONTROL_TASK = {"id": "ctl", "facts": [{"text": "one session per doc", "variants": ["single session per doc"]}]}
CONTROL_NT = {"id": "ctl-nt", "answerability": "not_there", "facts": []}
CONTROL_FILES = {"/work/himmel/docs/right.md": "The lock keeps one session per doc.", "/work/himmel/docs/wrong.md": "Nothing relevant.",
                 "/work/himmel/docs/a.md": "x", "/work/himmel/docs/b.md": "y", "/work/himmel/docs/c.md": "z"}
CONTROLS = [  # (name, task, answer text, expected supported)
    ("right file, wrong fact", CONTROL_TASK, "ANSWER: two sessions per doc\nFILES:\n/work/himmel/docs/right.md", False),
    ("right fact, no file", CONTROL_TASK, "ANSWER: one session per doc\nFILES:\n", False),
    ("right fact, right file", CONTROL_TASK, "ANSWER: one session per doc\nFILES:\n/work/himmel/docs/right.md", True),
    ("listed variant", CONTROL_TASK, "ANSWER: a single session per doc\nFILES:\n/work/himmel/docs/right.md", True),
    ("other words", CONTROL_TASK, "ANSWER: only one holder at a time\nFILES:\n/work/himmel/docs/right.md", False),
    ("a 4th file holding the fact", CONTROL_TASK, "ANSWER: one session per doc\nFILES:\n/work/himmel/docs/a.md\n/work/himmel/docs/b.md\n/work/himmel/docs/c.md\n/work/himmel/docs/right.md", False),
    ("NOT FOUND on an answerable task", CONTROL_TASK, "ANSWER: NOT FOUND\nFILES:\n", False),
    ("NOT FOUND on a not-there task", CONTROL_NT, "ANSWER: NOT FOUND\nFILES:\n", True),
]


def run_controls():
    res = {}
    for arm in ARMS:
        res[arm] = [(name, score(t, text, CONTROL_FILES.get)["supported"] == want) for name, t, text, want in CONTROLS]
    return res


def mcnemar(b, c):
    """Exact two-sided McNemar p on the discordant counts b (arm right alone) and c."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def holm2(p_sv, p_qv):
    """Holm over the two baseline contrasts; tie order S-V then Q-V. Returns (adj_sv, adj_qv)."""
    order = sorted([("S-V", p_sv), ("Q-V", p_qv)], key=lambda x: (x[1], x[0] != "S-V"))
    (n1, p1), (n2, p2) = order
    a1 = min(1.0, 2 * p1)
    a2 = min(1.0, max(2 * p1, p2))
    adj = {n1: a1, n2: a2}
    return adj["S-V"], adj["Q-V"]


def tango(b, c, n, z=Z95):
    """Tango's 95% score interval for the paired difference (b - c)/n, as fractions."""
    def zstat(d):
        B = b + c - d * (2 * n - b + c)
        p21 = (B + math.sqrt(max(0.0, B * B + 8 * n * c * d * (1 - d)))) / (4 * n)
        var = n * (2 * p21 + d - d * d)
        if var <= 0:
            return 0.0 if b - c - n * d == 0 else math.copysign(float("inf"), b - c - n * d)
        return (b - c - n * d) / math.sqrt(var)
    est = (b - c) / n

    def root(lo, hi):
        flo = abs(zstat(lo)) - z
        for _ in range(200):
            mid = (lo + hi) / 2
            fm = abs(zstat(mid)) - z
            if (fm > 0) == (flo > 0):
                lo, flo = mid, fm
            else:
                hi = mid
        return (lo + hi) / 2
    lower = -1.0 if abs(zstat(-1 + 1e-12)) <= z else root(-1 + 1e-12, est)
    upper = 1.0 if abs(zstat(1 - 1e-12)) <= z else root(1 - 1e-12, est)
    return lower, upper


def _betacf(a, b, x):
    """The continued fraction of the regularized incomplete beta (modified Lentz)."""
    tiny = 1e-300
    fix = lambda v: tiny if abs(v) < tiny else v   # noqa: E731
    qab, qap, qam = a + b, a + 1, a - 1
    c, d = 1.0, 1 / fix(1 - qab * x / qap)
    h = d
    for m in range(1, 301):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d, c = 1 / fix(1 + aa * d), fix(1 + aa / c)
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d, c = 1 / fix(1 + aa * d), fix(1 + aa / c)
        h *= d * c
        if abs(d * c - 1) < 3e-16:
            break
    return h


def _ibeta(a, b, x):
    if x <= 0 or x >= 1:
        return 0.0 if x <= 0 else 1.0
    lb = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log(1 - x)
    if x < (a + 1) / (a + b + 2):
        return math.exp(lb) * _betacf(a, b, x) / a
    return 1 - math.exp(lb) * _betacf(b, a, 1 - x) / b


def t_quantile(p, df):
    """The p quantile of Student's t (p > .5) by bisection on its CDF."""
    cdf = lambda t: 1 - 0.5 * _ibeta(df / 2, 0.5, df / (df + t * t))   # noqa: E731
    lo, hi = 0.0, 50.0
    for _ in range(200):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if cdf(mid) < p else (lo, mid)
    return (lo + hi) / 2


def paired_t(diffs):
    n = len(diffs)
    if n < 2:
        return None
    m = sum(diffs) / n
    sd = math.sqrt(sum((d - m) ** 2 for d in diffs) / (n - 1))
    h = t_quantile(0.975, n - 1) * sd / math.sqrt(n)
    return [m, m - h, m + h]


def power(pa, pv, n, alpha):
    """P(gain >= 15 points, arm ahead, exact raw p <= alpha) under the trinomial (pa, pv, rest)."""
    p0, tot = 1 - pa - pv, 0.0
    for b in range(n + 1):
        for c in range(n + 1 - b):
            if b > c and (b - c) * 100.0 / n >= BAR_PP - 1e-9 and mcnemar(b, c) <= alpha:
                tot += (math.comb(n, b) * math.comb(n - b, c) * pa ** b * pv ** c * p0 ** (n - b - c))
    return tot


POWER_ROWS = [(.10, .10), (.15, .05), (.20, .05), (.25, .05), (.30, .05), (.30, .10)]


def power_table():
    return [{"arm_alone": a, "v_alone": v, "n40": [round(power(a, v, 40, .025) * 100, 1), round(power(a, v, 40, .05) * 100, 1)],
             "n36": [round(power(a, v, 36, .025) * 100, 1), round(power(a, v, 36, .05) * 100, 1)]} for a, v in POWER_ROWS]


def label(arm, contrast):
    if contrast["p_adjusted"] <= ALPHA and contrast["gain_pp"] < 0:
        return "Plain Claude Code beat %s here." % arm
    if contrast["p_adjusted"] <= ALPHA and contrast["gain_pp"] >= BAR_PP:
        if contrast["real_half_gain_pp"] is not None and contrast["real_half_gain_pp"] <= 0:
            return "%s: far better only on tasks built to need search; not shown on real questions." % arm
        return "%s gave far more supported answers." % arm
    return "%s: no family-adjusted answer improvement established; not far better." % arm


def summarize(scores, cohort, bank, costs=None):
    """scores: {task_id: {arm: supported bool}} (after applying complete judge rounds);
    cohort: the frozen common task ids; bank: {task_id: task}. Refuses a missing arm or a
    score set that is not exactly the common cohort."""
    ids = sorted(cohort)
    if not ids:
        raise ValueError("an empty common cohort has no comparison")
    for t in ids:
        if t not in scores or any(a not in scores[t] for a in ARMS):
            raise ValueError("task %s lacks a V, S or Q score: no smaller family is allowed" % t)
    if set(scores) - set(ids):
        raise ValueError("scores outside the common cohort")
    n = len(ids)
    real = [t for t in ids if bank.get(t, {}).get("half") == "real"]
    comps = {}
    for name, x, y, confirmatory in CONTRASTS:
        b = sum(1 for t in ids if scores[t][x] and not scores[t][y])
        c = sum(1 for t in ids if scores[t][y] and not scores[t][x])
        lo, hi = tango(b, c, n)
        rb = sum(1 for t in real if scores[t][x] and not scores[t][y])
        rc = sum(1 for t in real if scores[t][y] and not scores[t][x])
        comps[name] = {"contrast": name, "confirmatory": confirmatory, "family": "baseline-holm2" if confirmatory else "exploratory",
                       "discordant": [b, c], "p_raw": mcnemar(b, c), "p_adjusted": None, "gain_pp": round((b - c) * 100.0 / n, 4),
                       "interval_pp": [round(lo * 100, 2), round(hi * 100, 2)], "interval_label": "pointwise 95% Tango score interval, not simultaneous",
                       "real_half_gain_pp": round((rb - rc) * 100.0 / len(real), 4) if real else None}
    a_sv, a_qv = holm2(comps["S-V"]["p_raw"], comps["Q-V"]["p_raw"])
    comps["S-V"]["p_adjusted"], comps["Q-V"]["p_adjusted"] = a_sv, a_qv
    comps["S-V"]["label"] = label("S", comps["S-V"])
    comps["Q-V"]["label"] = label("Q", comps["Q-V"])
    comps["S-Q"]["label"] = None
    out = {"n": n, "supported": {a: sum(1 for t in ids if scores[t][a]) for a in ARMS},
           "comparisons": [comps["S-V"], comps["Q-V"], comps["S-Q"]],
           "cohort_hash": hashlib.sha256("\n".join(ids).encode()).hexdigest()}
    if costs:
        out["cost_intervals"] = {name: paired_t([costs[t][x] - costs[t][y] for t in ids]) for name, x, y, _ in CONTRASTS}
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="score.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("controls")
    sub.add_parser("power")
    s = sub.add_parser("summarize")
    s.add_argument("--scores", required=True); s.add_argument("--cohort", required=True); s.add_argument("--bank", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "controls":
        res = run_controls()
        print(json.dumps({arm: all(ok for _, ok in r) for arm, r in res.items()}, sort_keys=True))
        return 0 if all(ok for r in res.values() for _, ok in r) else 3
    if a.cmd == "power":
        print(json.dumps(power_table()))
        return 0
    scores = {}
    for l in open(a.scores):
        if l.strip():
            r = json.loads(l)
            scores.setdefault(r["task_id"], {})[r["arm"]] = bool(r["supported"])
    bank = {t["id"]: t for t in (json.loads(l) for l in open(a.bank) if l.strip())}
    try:
        print(json.dumps(summarize(scores, json.load(open(a.cohort)), bank), sort_keys=True))
    except ValueError as e:
        print("score: refused: %s" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
