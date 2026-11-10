#!/usr/bin/env python3
"""tools-lock.py -- build and check the RAG pilot's tools.lock (design section 3).

  tools-lock.py build --out LOCK --h0 SHA --l0 SHA [--file NAME=PATH]... [--tree NAME=DIR]...
                      [--digest NAME=HEX]... [--const NAME=VALUE]...
  tools-lock.py check LOCK [--digest NAME=HEX]...

A file entry locks one file's sha256 (binaries, wrappers, note, prompts, configs, manifests);
a tree entry locks a directory's (path, sha256) set (the export copies); a digest entry locks a
named value computed elsewhere (corpus digests, the Q-ready manifest). `check` recomputes every
file and tree, compares every --digest given, and refuses on the first mismatch. No credential:
an entry name or constant that looks like a key/token/secret refuses at build.
Exit 0 ok, 3 refusal.
"""
import argparse, hashlib, json, os, re, sys

CRED_RE = re.compile(r"(api_?key|_key$|^key$|token|secret|password|bearer)", re.I)
LOCK_SCHEMA = "rag-pilot-tools-lock/1"


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def sha_tree(d):
    h = hashlib.sha256()
    for dp, dns, fns in sorted(os.walk(d)):
        dns.sort()
        for n in sorted(fns):
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, d)
            if os.path.islink(p):
                h.update(("L %s %s\n" % (rel, os.readlink(p))).encode())
            else:
                h.update(("F %s %s\n" % (rel, sha_file(p))).encode())
    return h.hexdigest()


def pairs(items, what):
    out = {}
    for it in items:
        if "=" not in it:
            raise ValueError("%s needs NAME=VALUE: %s" % (what, it))
        k, v = it.split("=", 1)
        if CRED_RE.search(k):
            raise ValueError("credential-like %s name refused: %s" % (what, k))
        out[k] = v
    return out


def build(a):
    files = pairs(a.file, "--file")
    trees = pairs(a.tree, "--tree")
    digests = pairs(a.digest, "--digest")
    consts = pairs(a.const, "--const")
    lock = {"schema": LOCK_SCHEMA, "h0": a.h0, "l0": a.l0,
            "files": {k: {"path": os.path.abspath(v), "sha256": sha_file(v)} for k, v in files.items()},
            "trees": {k: {"path": os.path.abspath(v), "sha256": sha_tree(v)} for k, v in trees.items()},
            "digests": digests, "constants": consts}
    with open(a.out, "w") as f:
        json.dump(lock, f, indent=1, sort_keys=True)
    os.chmod(a.out, 0o600)


def check(a):
    with open(a.lock) as f:
        lock = json.load(f)
    if lock.get("schema") != LOCK_SCHEMA:
        raise ValueError("lock schema %s != %s" % (lock.get("schema"), LOCK_SCHEMA))
    for k, e in lock["files"].items():
        got = sha_file(e["path"]) if os.path.isfile(e["path"]) else "missing"
        if got != e["sha256"]:
            raise ValueError("lock mismatch: file %s (%s)" % (k, e["path"]))
    for k, e in lock["trees"].items():
        if sha_tree(e["path"]) != e["sha256"]:
            raise ValueError("lock mismatch: tree %s (%s)" % (k, e["path"]))
    for k, v in pairs(a.digest, "--digest").items():
        if lock["digests"].get(k) != v:
            raise ValueError("lock mismatch: digest %s" % k)


def main(argv):
    p = argparse.ArgumentParser(prog="tools-lock.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", required=True); b.add_argument("--h0", required=True); b.add_argument("--l0", required=True)
    for opt in ("--file", "--tree", "--digest", "--const"):
        b.add_argument(opt, action="append", default=[])
    c = sub.add_parser("check")
    c.add_argument("lock"); c.add_argument("--digest", action="append", default=[])
    a = p.parse_args(argv)
    try:
        build(a) if a.cmd == "build" else check(a)
    except (ValueError, OSError, KeyError) as e:
        print("tools-lock: refused: %s" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
