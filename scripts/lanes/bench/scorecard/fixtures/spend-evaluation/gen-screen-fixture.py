#!/usr/bin/env python3
"""gen-screen-fixture.py OUTDIR SCENARIO - a deterministic exposure-screen fixture.

Writes transcripts, then runs the REAL P1 producer (model-price.mjs calls) and validator
(model-price.mjs validate-calls) over them, and writes the SCREEN, inventory and refs that
fleet-scorecard.sh --exposure-screen reads. Nothing is random and no model is called.

Every call costs `tokens * 20000` nano (claude-opus-5-5 output rate, output tokens only), so a
share is an exact integer ratio: a standard worker parent holds 10000 tokens in all, of which
the five calls after its boundary hold S (299 -> .0299, 300 -> .03).

Scenarios: noop qualified lowpeak-markers boundary-instant overlap few-parents unpriced
bad-event-time source-changed dup-path missing-path population-incomplete short-window
early-window utc-window role-unknown role-typo b2-lever caller-report.
"""
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "..", ".."))
MODEL_PRICE = os.path.join(REPO, "scripts", "lanes", "model-price.mjs")
SINCE = "2026-11-09T00:00:00+01:00"
UNTIL = "2026-11-16T00:00:00+01:00"
WHOLE = ("1970-01-01T00:00:00Z", "9999-12-31T23:59:59Z")
BASE = datetime(2026, 11, 10, 8, 0, 0, tzinfo=timezone.utc)
OPUS = "claude-opus-5-5"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def seq(start, step, tokens):
    return [(start + i * step, t) for i, t in enumerate(tokens)]


def standard(i, S=300, kind="steady"):
    """kind: None (no boundary), steady, idle (a >= 3000 s gap before it) or manual."""
    gap = 3_100_000 if kind == "idle" else 0
    rec = [60] * 5 if S == 300 else [60] * 4 + [59]
    calls = seq(0, 60_000, [500] * 4) + seq(210_000 + gap, 1_000, rec) + seq(300_000 + gap, 60_000, [1000, 1000])
    bounds = [] if kind is None else [(200_000 + gap, "manual" if kind == "manual" else "auto",
                                       200000 if kind == "idle" else 800000)]
    return {"session": "wk%02d" % i, "role": "worker", "base": BASE + timedelta(hours=i), "calls": calls,
            "bounds": bounds, "kids": seq(20_000, 20_000, [1900, 1900, 6000 - S - 3800])}


def parents(n=12, S=300, kind="steady"):
    return [standard(i, S, kind) for i in range(1, n + 1)]


def extras():
    chief = {"session": "chief01", "role": "chief", "base": BASE, "calls": [(0, 5000)], "bounds": [], "kids": []}
    strad = {"session": "wk13", "role": "worker", "base": datetime(2026, 11, 8, 12, 0, 0, tzinfo=timezone.utc),
             "calls": [(0, 777), (172_800_000, 777)], "bounds": [], "kids": []}
    return [chief, strad]


def scenario(name):
    ps = parents()
    sc = {"window": (SINCE, UNTIL)}
    if name == "noop":
        ps = parents(S=299)
    elif name == "lowpeak-markers":
        ps = [standard(1, kind="idle"), standard(2, kind="manual")] + [standard(i, kind=None) for i in range(3, 13)]
    elif name == "boundary-instant":
        p = standard(1)
        p["calls"] = seq(0, 60_000, [500] * 4) + [(200_000, 7777)] + seq(200_001, 1, [60] * 5) \
            + seq(300_000, 60_000, [1000, 1000])
        ps = [p] + [standard(i, kind=None) for i in range(2, 13)]
    elif name == "overlap":
        p = standard(1)
        p["calls"] = seq(0, 60_000, [500] * 4) + seq(201_000, 1_000, [11, 13, 17, 19, 23, 29, 31]) \
            + seq(300_000, 60_000, [1000, 1000])
        p["bounds"] = [(200_000, "auto", 800000), (202_500, "auto", 800000)]
        p["kids"] = seq(20_000, 20_000, [1900, 1900, 2057])
        ps = [p] + [standard(i, kind=None) for i in range(2, 13)]
    elif name == "few-parents":
        ps = parents(n=11)
    elif name == "unpriced":
        ps[0]["calls"][0] = (0, 500, "claude-unpriced-9")
    elif name == "bad-event-time":
        ps[0]["bounds"] = [(200_000, "auto", 800000, "not-a-time")]
    elif name in ("source-changed", "dup-path", "missing-path", "population-incomplete", "qualified"):
        pass
    elif name == "short-window":
        sc["window"] = (SINCE, "2026-11-15T00:00:00+01:00")
    elif name == "early-window":
        sc["window"] = ("2026-11-02T00:00:00+01:00", SINCE)
    elif name == "utc-window":
        sc["window"], sc["tz"] = ("2026-11-09T00:00:00Z", "2026-11-16T00:00:00Z"), "UTC"
    elif name == "role-unknown":
        ps[0]["role"] = "unknown"
    elif name == "role-typo":
        ps[0]["role"] = "wroker"
    elif name in ("b2-lever", "caller-report"):
        pass
    else:
        sys.exit("gen-screen-fixture: unknown scenario " + name)
    sc["parents"] = ps + extras()
    return sc


def stamp(dt, us=False):
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + (".%06dZ" % dt.microsecond if us else ".%03dZ" % (dt.microsecond // 1000))


def write_transcript(path, session, base, calls, bounds=()):
    rows = [{"type": "user", "message": {"content": "task"}}]
    for n, c in enumerate(calls):
        off, tokens = c[0], c[1]
        model = c[2] if len(c) > 2 else OPUS
        rows.append({"type": "assistant", "timestamp": stamp(base + timedelta(milliseconds=off)),
                     "requestId": "req-%s-%d" % (session, n),
                     "message": {"id": "msg-%s-%d" % (session, n), "model": model,
                                 "usage": {"input_tokens": 0, "output_tokens": tokens}}})
    for b in bounds:
        ts = b[3] if len(b) > 3 else stamp(base + timedelta(milliseconds=b[0]), us=True)
        rows.append({"type": "system", "subtype": "compact_boundary", "timestamp": ts,
                     "compactMetadata": {"trigger": b[1], "preTokens": b[2]}})
    rows.sort(key=lambda r: r.get("timestamp", "") if r.get("type") != "user" else "")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True) + "\n")


def put(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return data


def jdump(obj):
    return (json.dumps(obj, indent=1, sort_keys=True) + "\n").encode()


def node(*args):
    return subprocess.run(["node", MODEL_PRICE] + list(args), capture_output=True, check=False)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    out, name = os.path.realpath(sys.argv[1]), sys.argv[2]
    sc = scenario(name)
    root = os.path.join(out, "snapshot")
    files, inv_files = [], []
    for p in sc["parents"]:
        rel = "proj/%s.jsonl" % p["session"]
        write_transcript(os.path.join(root, rel), p["session"], p["base"], p["calls"], p["bounds"])
        entries = [(rel, p["session"], None)]
        if p["kids"]:
            kid = "agent-" + p["session"]
            krel = "proj/%s/subagents/%s.jsonl" % (p["session"], kid)
            write_transcript(os.path.join(root, krel), kid, p["base"], p["kids"])
            entries.append((krel, kid, p["session"]))
        for r, s, par in entries:
            raw = open(os.path.join(root, r), "rb").read()
            files.append({"relative_path": r, "bytes": len(raw), "sha256": sha(raw), "provider": "claude",
                          "session": s, "parent": par})
        inv_files.append((rel, p["session"], p["role"]))
    manifest = {"schema": 1, "root": root, "timezone": "Europe/Berlin", "since": WHOLE[0], "until": WHOLE[1],
                "files": files}
    mbytes = put(os.path.join(out, "carrier", "projection-0.json"), jdump(manifest))
    mpath = os.path.join(out, "carrier", "projection-0.json")
    prod = node("calls", "--manifest", mpath)
    put(os.path.join(out, "carrier", "calls-0.jsonl"), prod.stdout)
    price = json.loads(prod.stdout.decode().strip().split("\n")[-1])["price_sha256"]
    set_bytes = put(os.path.join(out, "carrier", "EXPORT_SET.json"), jdump({
        "schema": 1, "price_sha256": price, "usage_rule": "final-v2", "timezone": "Europe/Berlin",
        "exports": [{"path": "calls-0.jsonl", "producer_exit_code": prod.returncode,
                     "projection_manifest": {"path": "projection-0.json", "sha256": sha(mbytes)}}],
        "expected_sessions": [{"provider": "claude", "parent": f["parent"], "session": f["session"]} for f in files]}))
    val = node("validate-calls", "--manifest", os.path.join(out, "carrier", "EXPORT_SET.json"))
    val_bytes = put(os.path.join(out, "validation.json"), val.stdout)

    review = put(os.path.join(out, "population-review.md"), b"population reviewed: every worker transcript listed\n")
    evid = put(os.path.join(out, "role-evidence.txt"), b"role read from the launch brief\n")
    ref = lambda path, data: {"path": path, "sha256": sha(data)}  # noqa: E731
    top = [{"relative_path": r, "session": s, "role": role, "role_evidence": ref("role-evidence.txt", evid)}
           for r, s, role in inv_files]
    if name == "dup-path":
        top.append(dict(top[2]))
    if name == "missing-path":
        top.append({"relative_path": "proj/wk99.jsonl", "session": "wk99", "role": "worker",
                    "role_evidence": ref("role-evidence.txt", evid)})
    window = {"since": sc["window"][0], "until": sc["window"][1], "timezone": sc.get("tz", "Europe/Berlin")}
    inv_bytes = put(os.path.join(out, "inventory.json"), jdump({
        "window": window, "scope_root": root, "complete": name != "population-incomplete",
        "population_review": ref("population-review.md", review), "top_level_files": top, "exclusions": []}))
    screen = {"schema": 1, "lever": "B2" if name == "b2-lever" else "B1", "window": window,
              "inventory": ref("inventory.json", inv_bytes),
              "export_set": ref("carrier/EXPORT_SET.json", set_bytes),
              "validation": ref("validation.json", val_bytes)}
    if name == "caller-report":
        screen["compaction_report"] = ref("validation.json", val_bytes)
    put(os.path.join(out, "SCREEN.json"), jdump(screen))
    if name == "source-changed":
        with open(os.path.join(root, "proj", "wk01.jsonl"), "ab") as fh:
            fh.write(b"\n")


main()
