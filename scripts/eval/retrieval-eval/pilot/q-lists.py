#!/usr/bin/env python3
"""q-lists.py -- the local-Q readiness checks (B10).

  q-lists.py check --ready R --master M --config-dir D --models-dir MD [--copy C]... [--runtime]
      Before and after every Q answer session or list: the Q master (and each disposable copy)
      still has the Q-ready digest, the config bytes are the locked ones and name no remote
      model or URL, the models are the Q-ready treatment, and every pinned weight file has its
      recorded sha256. --runtime also refuses a Q-ready manifest built without vectors.
  q-lists.py evidence --meta BROKER_META [--deadline-ms N]
      The P13-Q positive evidence contract over one broker's events: every admitted call has a
      terminal, zero skips, every model stage invoked (expansion, embedding, rerank), host NVML
      memory observed on the admitted qmd child, and completion inside the fixed deadline.
Exit 0 ok, 3 refusal (one line per reason).
"""
import argparse, hashlib, importlib.util, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def pins():
    s = importlib.util.spec_from_file_location("pins", os.path.join(HERE, "pins.py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def check(a):
    bad = []
    r = json.load(open(a.ready))
    if r["q_source_manifest_sha256"] != r["s_source_manifest_sha256"]:
        bad.append("the Q-ready source manifest is not the S source manifest")
    if a.runtime and not r.get("embedded"):
        bad.append("the Q-ready manifest was built without vectors (fixture build)")
    P = pins()
    for db in [a.master] + a.copy:
        try:
            d = P.digest(db)
        except P.Refuse as e:
            bad.append(str(e))
            continue
        if d != r["q_digest"]:
            bad.append("Q digest of %s changed" % os.path.basename(db))
    cfg = os.path.join(a.config_dir, "eval.yml")
    text = open(cfg).read()
    if sha(cfg) != r["config_sha256"]:
        bad.append("the Q config bytes changed")
    if re.search(r"openai:|openai_base_url|https?://", text):
        bad.append("the Q config names a remote model or URL")
    for n, h in r["weights"].items():
        p = os.path.join(a.models_dir, n)
        if not os.path.isfile(p):
            bad.append("pinned weight %s is missing" % n)
        elif sha(p) != h:
            bad.append("pinned weight %s changed" % n)
    for b in bad:
        print("q-lists: refused: %s" % b, file=sys.stderr)
    return 3 if bad else 0


def evidence(a):
    evs = [json.loads(l) for l in open(os.path.join(a.meta, "events.jsonl")) if l.strip()]
    admits = [e for e in evs if e.get("kind") == "admit"]
    terms = {e["id"]: e for e in evs if e.get("kind") == "terminal"}
    bad = []
    if not admits:
        bad.append("no admitted Q call")
    for ad in admits:
        t = terms.get(ad["id"])
        if not t:
            bad.append("%s: no terminal record" % ad["id"])
            continue
        if t.get("skip_reasons"):
            bad.append("%s: skip %s" % (ad["id"], t["skip_reasons"]))
        err = t.get("stderr") or ""
        for stage in ("Expanding query", "Embedding ", "Reranking "):
            if stage not in err:
                bad.append("%s: stage not invoked: %s" % (ad["id"], stage.strip()))
        if t.get("expansion") != "expanded":
            bad.append("%s: expansion was %s, not a real expansion" % (ad["id"], t.get("expansion")))
        if t.get("gpu_state") != "observed":
            bad.append("%s: no host NVML memory on the admitted qmd child (%s)" % (ad["id"], t.get("gpu_state")))
        if (t.get("ms") or 0) > a.deadline_ms:
            bad.append("%s: %s ms exceeds the %d ms deadline" % (ad["id"], t.get("ms"), a.deadline_ms))
    for b in bad:
        print("q-lists: refused: %s" % b, file=sys.stderr)
    if not bad:
        t = [terms[x["id"]] for x in admits]
        print(json.dumps({"calls": len(t), "max_ms": max(x.get("ms") or 0 for x in t),
                          "gpu_mib": max((x.get("gpu_evidence") or {}).get("mib", 0) for x in t)}))
    return 3 if bad else 0


def main(argv):
    p = argparse.ArgumentParser(prog="q-lists.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--ready", required=True); c.add_argument("--master", required=True)
    c.add_argument("--config-dir", required=True); c.add_argument("--models-dir", required=True)
    c.add_argument("--copy", action="append", default=[]); c.add_argument("--runtime", action="store_true")
    e = sub.add_parser("evidence")
    e.add_argument("--meta", required=True); e.add_argument("--deadline-ms", type=int, default=540000)
    a = p.parse_args(argv)
    return check(a) if a.cmd == "check" else evidence(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
