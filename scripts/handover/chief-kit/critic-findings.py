#!/usr/bin/env python3
"""Typed prior-finding intake for opted-in critic rounds (Python stdlib only; no network, no model).

  critic-findings.py normalize --spec SPEC --kind spec|plan --round N --verdict VERDICT --out INDEX [--rebuild-stale]
  critic-findings.py bundle --spec SPEC --previous-verdicts PREVIOUS.json --out BUNDLE
  critic-findings.py validate-bundle BUNDLE --spec SPEC --previous-verdicts PREVIOUS.json

Every handled command prints one JSON line. Success (exit 0) prints the INDEX or BUNDLE. A refusal prints
{"schema":1,"kind":"critic-intake-refusal","state":"refused","operation":...,"reasons":[...]}:
exit 2 = invalid, duplicate, noncanonical-location, index-conflict; exit 3 = missing, stale, incomplete,
stale-index, busy, legacy-provenance-missing. An unexpected error exits 1 with no success output.

The producer never edits, seals or deletes a saved verdict. It writes only the requested INDEX or BUNDLE (atomically,
never over different bytes), the INDEX's `.previous.<sha256>.json` archive on an explicit --rebuild-stale, and the
output-local `.lock` file. validate-bundle writes nothing.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys

HEX64 = re.compile(r"[0-9a-f]{64}")
POSITIVE = re.compile(r"[1-9][0-9]*")
KINDS = ("spec", "plan")
PREFIX = {"spec": "SPEC", "plan": "PLAN"}
SEVERITIES = ("critical", "major", "minor")
FENCE = "```critic-findings-v1"
INDEX_KEYS = {"schema", "kind", "spec_path", "critic_kind", "round", "verdict", "complete", "findings", "provenance"}


class Refusal(Exception):
    def __init__(self, code, reason):
        super().__init__(reason)
        self.code = code
        self.reason = reason


def refuse(code, reason):
    raise Refusal(code, reason)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def dump(obj):
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def canonical_abs(path):
    return isinstance(path, str) and "\0" not in path and os.path.isabs(path) and os.path.normpath(path) == path


def read_regular(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        refuse(3, "missing")
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.EISDIR, errno.ENOTDIR):
            refuse(2, "noncanonical-location")
        raise
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            refuse(2, "noncanonical-location")
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    finally:
        os.close(fd)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def load_json(data):
    def no_constant(name):
        raise ValueError(name)
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_pairs, parse_constant=no_constant)
    except (ValueError, UnicodeError):
        refuse(2, "invalid")


def is_int(value):
    return type(value) is int


def check_spec(spec):
    if not canonical_abs(spec):
        refuse(2, "invalid")
    if not os.path.lexists(spec):
        refuse(3, "missing")
    if os.path.islink(spec) or not os.path.isfile(spec) or os.path.realpath(spec) != spec:
        refuse(2, "noncanonical-location")
    return spec


def parse_round(text):
    if not isinstance(text, str) or not POSITIVE.fullmatch(text):
        refuse(2, "invalid")
    return int(text)


def check_verdict(spec, kind, rnd, path):
    if not canonical_abs(path):
        refuse(2, "invalid")
    if path != f"{spec}.critic-{kind}-r{rnd}.md":
        refuse(2, "noncanonical-location")
    if not os.path.lexists(path):
        refuse(3, "missing")
    if os.path.islink(path) or os.path.realpath(path) != path:
        refuse(2, "noncanonical-location")
    return read_regular(path)


def parse_return(kind, rnd, data):
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        refuse(2, "invalid")
    lines = text.split("\n")
    opens = [i for i, line in enumerate(lines) if line.rstrip() == FENCE]
    if not opens:
        refuse(3, "legacy-provenance-missing")
    if len(opens) > 1:
        refuse(2, "duplicate")
    close = next((i for i in range(opens[0] + 1, len(lines)) if lines[i].rstrip() == "```"), None)
    if close is None:
        refuse(2, "invalid")
    block = load_json("\n".join(lines[opens[0] + 1:close]).encode("utf-8"))
    if not isinstance(block, dict) or set(block) != {"schema", "kind", "reviewer_id", "findings"}:
        refuse(2, "invalid")
    if not is_int(block["schema"]) or block["schema"] != 1 or block["kind"] != "critic-findings":
        refuse(2, "invalid")
    reviewer = block["reviewer_id"]
    if not isinstance(reviewer, str) or not reviewer.strip() or not isinstance(block["findings"], list):
        refuse(2, "invalid")
    id_re = re.compile(re.escape(f"{kind}-r{rnd}-") + r"[1-9][0-9]*")
    seen = set()
    findings = []
    for f in block["findings"]:
        if not isinstance(f, dict) or set(f) != {"finding_id", "severity", "location"}:
            refuse(2, "invalid")
        fid, loc = f["finding_id"], f["location"]
        if not isinstance(fid, str) or not id_re.fullmatch(fid) or f["severity"] not in SEVERITIES:
            refuse(2, "invalid")
        if fid in seen:
            refuse(2, "duplicate")
        seen.add(fid)
        if not isinstance(loc, dict) or set(loc) != {"path", "start_line", "end_line"}:
            refuse(2, "invalid")
        if not isinstance(loc["path"], str) or not loc["path"].strip():
            refuse(2, "invalid")
        start, end = loc["start_line"], loc["end_line"]
        if not is_int(start) or not is_int(end) or start < 1 or end < start:
            refuse(2, "invalid")
        findings.append({"finding_id": fid, "severity": f["severity"], "location": {"path": loc["path"], "start_line": start, "end_line": end}})
    last = next((line.strip() for line in reversed(lines) if line.strip()), "")
    m = re.fullmatch(PREFIX[kind] + r" (CLEAN|FINDINGS ([1-9][0-9]*))", last)
    if not m:
        refuse(2, "invalid")
    if m.group(1) == "CLEAN":
        if findings:
            refuse(2, "invalid")
    elif int(m.group(2)) != len(findings):
        refuse(2, "invalid")
    return reviewer, findings


def build_index(spec, kind, rnd, verdict, data):
    reviewer, findings = parse_return(kind, rnd, data)
    vsha = sha256_bytes(data)
    obj = {"schema": 1, "kind": "critic-finding-index", "spec_path": spec, "critic_kind": kind, "round": rnd,
           "verdict": {"path": verdict, "sha256": vsha}, "complete": True, "findings": findings,
           "provenance": {"method": "structured-return", "reviewer_id": reviewer}}
    return obj, vsha


class Lock:
    def __init__(self, path):
        self.path = path
        self.fd = None

    def __enter__(self):
        try:
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
        except OSError as e:
            if e.errno in (errno.ELOOP, errno.EISDIR):
                refuse(2, "noncanonical-location")
            raise
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                refuse(2, "noncanonical-location")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                    refuse(3, "busy")
                raise
        except BaseException:
            os.close(fd)
            raise
        self.fd = fd
        return self

    def __exit__(self, *exc):
        os.close(self.fd)
        return False


def write_temp(path, data):
    tmp = f"{path}.tmp.{os.getpid()}.{os.urandom(4).hex()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.unlink(tmp)
        raise
    return tmp


def write_new(path, data):
    tmp = write_temp(path, data)
    try:
        os.link(tmp, path)
    finally:
        os.unlink(tmp)


def replace(path, data):
    tmp = write_temp(path, data)
    try:
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def archive_old_index(index_path, old_bytes):
    archive = f"{index_path}.previous.{sha256_bytes(old_bytes)}.json"
    try:
        write_new(archive, old_bytes)
    except FileExistsError:
        if read_regular(archive) != old_bytes:
            refuse(2, "index-conflict")
    return archive


def check_output_path(path):
    if not canonical_abs(path):
        refuse(2, "invalid")
    if os.path.islink(path):
        refuse(2, "noncanonical-location")


def bound_index(old, spec, kind, rnd, verdict):
    try:
        obj = json.loads(old.decode("utf-8"), object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeError):
        return None
    if not isinstance(obj, dict) or set(obj) != INDEX_KEYS or obj.get("kind") != "critic-finding-index":
        return None
    v = obj.get("verdict")
    if not is_int(obj.get("schema")) or obj["schema"] != 1 or obj.get("spec_path") != spec or obj.get("critic_kind") != kind:
        return None
    if not is_int(obj.get("round")) or obj["round"] != rnd or not isinstance(v, dict) or v.get("path") != verdict:
        return None
    return v.get("sha256") if isinstance(v.get("sha256"), str) and HEX64.fullmatch(v["sha256"]) else None


def cmd_normalize(a):
    spec = check_spec(a.spec)
    rnd = parse_round(a.round)
    kind = a.kind
    if not canonical_abs(a.verdict):
        refuse(2, "invalid")
    build_index(spec, kind, rnd, a.verdict, check_verdict(spec, kind, rnd, a.verdict))
    if a.out != a.verdict + ".finding-index.json":
        refuse(2, "noncanonical-location")
    check_output_path(a.out)
    with Lock(a.out + ".lock"):
        obj, vsha = build_index(spec, kind, rnd, a.verdict, check_verdict(spec, kind, rnd, a.verdict))
        new = dump(obj)
        if not os.path.lexists(a.out):
            if a.rebuild_stale:
                refuse(3, "missing")
            try:
                write_new(a.out, new)
            except FileExistsError:
                refuse(2, "index-conflict")
            return new
        old = read_regular(a.out)
        if old == new:
            return new
        recorded = bound_index(old, spec, kind, rnd, a.verdict)
        if not a.rebuild_stale:
            refuse(3 if recorded and recorded != vsha else 2, "stale-index" if recorded and recorded != vsha else "index-conflict")
        if recorded is None or recorded == vsha:
            refuse(2, "index-conflict")
        archive_old_index(a.out, old)
        if sha256_bytes(check_verdict(spec, kind, rnd, a.verdict)) != vsha:
            refuse(3, "stale-index")
        now = read_regular(a.out) if os.path.lexists(a.out) else None
        if now == new:
            return new
        if now != old:
            refuse(3, "stale-index")
        replace(a.out, new)
        return new


def load_previous(path):
    if not canonical_abs(path):
        refuse(2, "invalid")
    obj = load_json(read_regular(path))
    if not isinstance(obj, dict) or set(obj) != {"schema", "verdicts"} or not is_int(obj["schema"]) or obj["schema"] != 1:
        refuse(2, "invalid")
    if not isinstance(obj["verdicts"], list):
        refuse(2, "invalid")
    for row in obj["verdicts"]:
        if not isinstance(row, dict) or set(row) != {"path", "sha256"} or not isinstance(row["path"], str):
            refuse(2, "invalid")
        if not isinstance(row["sha256"], str) or not HEX64.fullmatch(row["sha256"]):
            refuse(2, "invalid")
    return obj["verdicts"]


def compute_bundle(spec, previous_path):
    rows, previous_findings, seen = [], [], set()
    name = re.compile(re.escape(spec) + r"\.critic-(spec|plan)-r([1-9][0-9]*)\.md")
    for row in load_previous(previous_path):
        path = row["path"]
        m = name.fullmatch(path) if canonical_abs(path) else None
        if not m:
            refuse(2, "noncanonical-location")
        if path in seen:
            refuse(2, "duplicate")
        seen.add(path)
        kind, rnd = m.group(1), int(m.group(2))
        data = check_verdict(spec, kind, rnd, path)
        vsha = sha256_bytes(data)
        if vsha != row["sha256"]:
            refuse(3, "stale")
        index_path = path + ".finding-index.json"
        if not os.path.lexists(index_path):
            refuse(3, "missing")
        index_bytes = read_regular(index_path)
        recorded = load_json(index_bytes)
        if not isinstance(recorded, dict) or recorded.get("complete") is not True:
            refuse(3, "incomplete")
        v = recorded.get("verdict")
        if not isinstance(v, dict) or v.get("sha256") != vsha:
            refuse(3, "stale")
        derived, _ = build_index(spec, kind, rnd, path, data)
        if recorded != derived:
            refuse(2, "invalid")
        ids = [f["finding_id"] for f in derived["findings"]]
        rows.append({"path": path, "sha256": vsha, "index_path": index_path, "index_sha256": sha256_bytes(index_bytes), "finding_ids": ids})
        previous_findings.extend({"finding_id": i, "verdict_sha256": vsha} for i in ids)
    return {"schema": 1, "kind": "critic-findings-bundle", "spec_path": spec, "verdicts": rows, "previous_findings": previous_findings}


def cmd_bundle(a):
    spec = check_spec(a.spec)
    check_output_path(a.out)
    compute_bundle(spec, a.previous_verdicts)
    with Lock(a.out + ".lock"):
        new = dump(compute_bundle(spec, a.previous_verdicts))
        if os.path.lexists(a.out):
            if read_regular(a.out) != new:
                refuse(2, "index-conflict")
            return new
        try:
            write_new(a.out, new)
        except FileExistsError:
            refuse(2, "index-conflict")
        return new


def cmd_validate(a):
    spec = check_spec(a.spec)
    if not canonical_abs(a.bundle):
        refuse(2, "invalid")
    expected = compute_bundle(spec, a.previous_verdicts)
    if load_json(read_regular(a.bundle)) != expected:
        refuse(2, "invalid")
    return dump(expected)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal(2, "invalid")


def build_parser():
    p = Parser(prog="critic-findings.py", allow_abbrev=False)
    sub = p.add_subparsers(dest="command", required=True, parser_class=Parser)
    n = sub.add_parser("normalize", allow_abbrev=False)
    for flag in ("--spec", "--kind", "--round", "--verdict", "--out"):
        n.add_argument(flag, required=True)
    n.add_argument("--rebuild-stale", action="store_true")
    n.set_defaults(run=cmd_normalize)
    b = sub.add_parser("bundle", allow_abbrev=False)
    for flag in ("--spec", "--previous-verdicts", "--out"):
        b.add_argument(flag, required=True)
    b.set_defaults(run=cmd_bundle)
    v = sub.add_parser("validate-bundle", allow_abbrev=False)
    v.add_argument("bundle")
    v.add_argument("--spec", required=True)
    v.add_argument("--previous-verdicts", required=True)
    v.set_defaults(run=cmd_validate)
    return p


def main(argv):
    operation = argv[0] if argv and argv[0] in ("normalize", "bundle", "validate-bundle") else "unknown"
    try:
        a = build_parser().parse_args(argv)
        if getattr(a, "kind", "spec") not in KINDS:
            refuse(2, "invalid")
        sys.stdout.write(a.run(a).decode("utf-8"))
        return 0
    except Refusal as r:
        sys.stdout.write(json.dumps({"schema": 1, "kind": "critic-intake-refusal", "state": "refused", "operation": operation,
                                     "reasons": [r.reason]}, separators=(",", ":")) + "\n")
        return r.code
    except Exception as e:
        sys.stderr.write(f"critic-findings: unexpected error: {type(e).__name__}: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
