#!/usr/bin/python3 -I
"""build-manifest — write manifest.json for an installed station-ops directory.

  build-manifest.py DIR

DIR holds <op>.sh and <op>.json pairs (install.sh copies them root-owned into
/usr/local/libexec/himmel/ops). The manifest records, per op, the schema's version and the sha256 of the
script and of the schema. The afk-sudo helper runs an op only when the installed files still hash to
this manifest; the manifest itself is root-owned like the files. Prints the op names it wrote.
"""
import hashlib
import json
import os
import sys


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main(argv):
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        print("usage: build-manifest.py DIR", file=sys.stderr)
        return 2
    d, ops = argv[0], {}
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json") or name == "manifest.json":
            continue
        op = name[:-len(".json")]
        script = os.path.join(d, op + ".sh")
        if not os.path.isfile(script):
            print(f"build-manifest: {op}: no {op}.sh next to its schema", file=sys.stderr)
            return 1
        with open(os.path.join(d, name)) as f:
            schema = json.load(f)
        if schema.get("name") != op or not isinstance(schema.get("version"), int) or isinstance(schema.get("version"), bool):
            print(f"build-manifest: {op}: schema name/version wrong", file=sys.stderr)
            return 1
        ops[op] = {"version": schema["version"], "sha256": sha256(script), "schema_sha256": sha256(os.path.join(d, name))}
    tmp = os.path.join(d, ".manifest.json.tmp")
    with open(tmp, "w") as f:
        json.dump({"v": 1, "ops": ops}, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(d, "manifest.json"))
    print(" ".join(sorted(ops)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
