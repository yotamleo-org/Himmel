#!/usr/bin/env python3
"""retain-run.py -- durable, content-addressed retention of an eval run's private evidence (§12).

  retain-run.py retain --root RETAINED --run-id ID --file KIND=PATH [--file ...]
  retain-run.py verify --root RETAINED --run-id ID
  retain-run.py get    --root RETAINED --run-id ID --kind KIND

Every artifact (bank, candidates, errors, timeouts, redacted traces, usage, results, scores) is
stored once under objects/<sha256> and listed in runs/<ID>.json with its kind, name, size and
hash, plus the manifest's own checksum. Directories are 700, files 600. Text artifacts are
scrubbed of key/token-shaped strings BEFORE they are hashed and stored. Retention happens
before any public ledger append; replaying the same run is idempotent and a different manifest
for the same run id refuses. There is no delete or expiry command: removal is the operator's
explicit act. `verify` reports each listed artifact present or unavailable (a legacy run whose
artifacts never existed shows unavailable, never a fabricated hash).
Exit 0 ok, 1 something unavailable, 3 refusal.
"""
import argparse, hashlib, json, os, re, sys

SCRUB = [(re.compile(r"sk-(?:ant|or)-[A-Za-z0-9_-]{8,}"), "[redacted-key]"),
         (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/-]{12,}=*"), r"\1[redacted]"),
         (re.compile(r"(?i)((?:api_?key|token|secret)[\"']?\s*[:=]\s*[\"']?)[A-Za-z0-9._~+/-]{12,}"), r"\1[redacted]")]


def private_dir(p):
    os.makedirs(p, mode=0o700, exist_ok=True)
    os.chmod(p, 0o700)


def scrub(data):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data, False
    out = text
    for rx, rep in SCRUB:
        out = rx.sub(rep, out)
    return out.encode("utf-8"), out != text


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(path, 0o600)


def manifest_path(root, run_id):
    if not re.match(r"^[A-Za-z0-9._-]+$", run_id):
        raise ValueError("unsafe run id")
    return os.path.join(root, "runs", run_id + ".json")


def retain(root, run_id, files):
    private_dir(root)
    private_dir(os.path.join(root, "objects"))
    private_dir(os.path.join(root, "runs"))
    entries = {}
    for kind, path in sorted(files.items()):
        data, scrubbed = scrub(open(path, "rb").read())
        h = hashlib.sha256(data).hexdigest()
        obj = os.path.join(root, "objects", h)
        if not os.path.exists(obj):
            write_private(obj, data)
        entries[kind] = {"sha256": h, "size": len(data), "name": os.path.basename(path), "scrubbed": scrubbed}
    body = {"run_id": run_id, "artifacts": entries}
    body["manifest_sha256"] = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
    mp = manifest_path(root, run_id)
    if os.path.exists(mp):
        old = json.load(open(mp))
        if old.get("manifest_sha256") != body["manifest_sha256"]:
            raise ValueError("run %s is already retained with a different manifest" % run_id)
        return old
    write_private(mp, json.dumps(body, indent=1, sort_keys=True).encode())
    return body


def verify(root, run_id):
    m = json.load(open(manifest_path(root, run_id)))
    out = {}
    for kind, e in m["artifacts"].items():
        obj = os.path.join(root, "objects", e.get("sha256") or "missing")
        out[kind] = "present" if os.path.isfile(obj) and hashlib.sha256(open(obj, "rb").read()).hexdigest() == e.get("sha256") else "unavailable"
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="retain-run.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("retain", "verify", "get"):
        p = sub.add_parser(n)
        p.add_argument("--root", required=True); p.add_argument("--run-id", required=True)
        if n == "retain":
            p.add_argument("--file", action="append", default=[], required=True)
        if n == "get":
            p.add_argument("--kind", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "retain":
            print(json.dumps(retain(a.root, a.run_id, dict(x.split("=", 1) for x in a.file)), sort_keys=True))
        elif a.cmd == "verify":
            v = verify(a.root, a.run_id)
            print(json.dumps(v, sort_keys=True))
            return 0 if all(x == "present" for x in v.values()) else 1
        else:
            e = json.load(open(manifest_path(a.root, a.run_id)))["artifacts"][a.kind]
            print(os.path.join(a.root, "objects", e["sha256"]))
    except (ValueError, OSError, KeyError) as e:
        print("retain-run: refused: %s" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
