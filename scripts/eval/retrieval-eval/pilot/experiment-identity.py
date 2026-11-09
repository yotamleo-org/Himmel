#!/usr/bin/env python3
"""experiment-identity.py -- the canonical, complete, nonsecret identity of an eval run (design §12).

  experiment-identity.py build [--file NAME=PATH]... [--value NAME=VALUE]... [--repo DIR] [--shaper PATH]...
      -> {"identity": {...}, "config_hash": sha256(canonical identity)}
  experiment-identity.py compare A.json B.json
      -> comparable: same experiment (equal everywhere), same experiment with a different named
         treatment (backend models and their model-specific vector/index digests only), not
         comparable (bank, common source manifest, scorer, pre-expansion shaper, evaluator,
         protocol differ), or unknown (a required field is missing: no invented history).

The identity forwards: bank sha, shaping source/config, evaluator and scorer, backend/models/
reranking, H0/L0/export/corpus/graph digests, qmd and harness builds, and the dirty-content
digest of the working tree (so an uncommitted shaper or evaluator edit changes the hash at the
same commit). A credential-like name or token-shaped value refuses: no secret ever enters it.
Exit 0 ok, 3 refusal; compare exits 0 comparable, 1 not comparable or unknown.
"""
import argparse, hashlib, json, os, re, subprocess, sys

REQUIRED = ("protocol", "bank_sha256", "shaper_sha256", "evaluator_sha256", "scorer_sha256", "backend", "models",
            "source_manifest_sha256", "corpus_digest", "graph_sha256", "qmd_build", "harness_commit", "dirty_digest")
TREATMENT = ("backend", "models", "rerank", "corpus_digest", "vector_digest", "config_hash_backend")
CRED = re.compile(r"(api_?key|token|secret|password|bearer|credential)", re.I)
TOKENISH = re.compile(r"sk-ant-|sk-or-|Bearer\s+\S{8,}")


def sha_file(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def dirty_digest(repo):
    """sha256 over the tracked diff against HEAD and every untracked file's path and bytes; 'clean' when none."""
    d = subprocess.run(["git", "-C", repo, "diff", "HEAD", "--binary"], capture_output=True)
    u = subprocess.run(["git", "-C", repo, "ls-files", "--others", "--exclude-standard", "-z"], capture_output=True)
    if d.returncode != 0 or u.returncode != 0:
        raise ValueError("cannot read the working tree of %s: an unverifiable identity is refused" % repo)
    diff, untracked = d.stdout, u.stdout
    h = hashlib.sha256(diff)
    names = [n for n in untracked.decode().split("\0") if n]
    for n in sorted(names):
        h.update(b"\0untracked:" + n.encode() + b"\0")
        try:
            h.update(open(os.path.join(repo, n), "rb").read())
        except OSError:
            h.update(b"<unreadable>")
    return "clean" if not diff and not names else h.hexdigest()


def canonical(identity):
    return json.dumps(identity, sort_keys=True, separators=(",", ":"))


def check_secret_free(identity):
    for k, v in identity.items():
        if CRED.search(k):
            raise ValueError("credential-like identity field refused: %s" % k)
        if isinstance(v, str) and TOKENISH.search(v):
            raise ValueError("token-shaped value refused in %s" % k)


def build(files, values, repo=None, shapers=()):
    ident = {}
    for name, path in files.items():
        ident[name] = sha_file(path)
    if shapers:
        h = hashlib.sha256()
        for p in shapers:
            h.update(open(p, "rb").read())
        ident["shaper_sha256"] = h.hexdigest()
    ident.update(values)
    if repo:
        head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True)
        if head.returncode != 0 or not head.stdout.strip():
            raise ValueError("cannot read the harness commit of %s" % repo)
        ident["harness_commit"] = head.stdout.strip()
        ident["dirty_digest"] = dirty_digest(repo)
    check_secret_free(ident)
    return {"identity": ident, "config_hash": hashlib.sha256(canonical(ident).encode()).hexdigest()}


def compare(a, b):
    a, b = a.get("identity", a), b.get("identity", b)
    missing = sorted(k for k in REQUIRED if a.get(k) in (None, "") or b.get(k) in (None, ""))
    if missing:
        return None, {"missing": missing}
    differs = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
    if not differs:
        return True, {"group": "same experiment"}
    if all(k in TREATMENT for k in differs):
        return True, {"group": "same experiment, named treatment differs", "treatment": differs}
    return False, {"differs": [k for k in differs if k not in TREATMENT]}


def main(argv):
    ap = argparse.ArgumentParser(prog="experiment-identity.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--file", action="append", default=[]); b.add_argument("--value", action="append", default=[])
    b.add_argument("--repo"); b.add_argument("--shaper", action="append", default=[])
    c = sub.add_parser("compare"); c.add_argument("a"); c.add_argument("b")
    a = ap.parse_args(argv)
    if a.cmd == "compare":
        ok, why = compare(json.load(open(a.a)), json.load(open(a.b)))
        print(json.dumps({"comparable": ok, **why}, sort_keys=True))
        return 0 if ok else 1
    try:
        out = build(dict(x.split("=", 1) for x in a.file), dict(x.split("=", 1) for x in a.value), a.repo, a.shaper)
    except (ValueError, OSError) as e:
        print("experiment-identity: refused: %s" % e, file=sys.stderr)
        return 3
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
