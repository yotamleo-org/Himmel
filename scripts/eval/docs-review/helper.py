#!/usr/bin/env python3
"""Pure helpers for run.sh: cut the remarks table, render PR comments, judge a canary, audit a transcript.

usage: helper.py remarks <remarks.tsv> <filter>          cut table to stdout
       helper.py comments <cutoff-iso|none> <json>...     rendered comments to stdout
       helper.py capture <port-file> <capture-dir>        serve a fake API on a free port
       helper.py canary <stream.jsonl> <capture-dir>      exit 0 clean, 1 with reasons on stderr
       helper.py audit <config-dir> <fixture>             tool calls whose path leaves the fixture
"""
import calendar
import glob
import json
import os
import re
import sys
import time

ALLOWED_TOOLS = {"Read", "Glob", "Grep"}
STATUS_LINE = re.compile(r"addressed in commit|confirmed as addressed|✅ addressed", re.I)
MEMORY_TEXT = re.compile(r"Contents of [^\"\\]*(CLAUDE|AGENTS)(\.local)?\.md|codebase and user instructions", re.I)


def remarks(path, flt):
    rows = [line.rstrip("\n").split("\t") for line in open(path, encoding="utf-8")]
    head, body = rows[0], rows[1:]
    col = {name: i for i, name in enumerate(head)}
    body = [r for r in body if r[col["state"]] in ("active", "candidate")]
    m = re.fullmatch(r"date before (\d{4}-\d{2}-\d{2})", flt)
    if m:
        body = [r for r in body if r[col["date"]] < m.group(1)]
    elif flt.startswith("all rows except"):
        drop = set(re.findall(r"M\d+", flt))
        body = [r for r in body if r[col["id"]] not in drop]
    elif flt != "all rows":
        sys.exit(f"helper: unknown remarks filter: {flt}")
    for r in [head] + body:
        print("\t".join(r))


def when(stamp):
    return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))


def comments(cutoff, files):
    """Comments made before the cutoff (an ISO time, or none), replies dropped, bot status lines stripped."""
    limit = float("inf") if cutoff == "none" else when(cutoff)
    out = []
    for f in files:
        pages = json.load(open(f, encoding="utf-8"))
        for c in [c for page in pages for c in (page if isinstance(page, list) else [page])]:
            stamp = c.get("created_at") or c.get("submitted_at")
            body = (c.get("body") or "").strip()
            if not stamp or not body or c.get("in_reply_to_id") or when(stamp) >= limit:
                continue
            body = "\n".join(l for l in body.splitlines() if not STATUS_LINE.search(l))
            where = f"{c['path']}:{c.get('line') or c.get('original_line') or '?'}" if c.get("path") else "PR"
            out.append((stamp, f"### {where} ({c['user']['login']}, {stamp})\n\n{body}\n"))
    for _, text in sorted(out):
        print(text)


def capture(portfile, capdir):
    """A local stand-in for the API: records each request body, answers 400 so the CLI stops at once."""
    import http.server

    class Handler(http.server.BaseHTTPRequestHandler):
        seen = 0

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("content-length", 0)))
            Handler.seen += 1
            with open(os.path.join(capdir, f"req-{Handler.seen}.json"), "wb") as f:
                f.write(body)
            msg = b'{"type":"error","error":{"type":"invalid_request_error","message":"docs-review canary"}}'
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    with open(portfile, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


def canary(stream, capdir):
    bad = []
    init = None
    for line in open(stream, encoding="utf-8"):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if "hook" in f"{ev.get('type', '')} {ev.get('subtype', '')}":
            bad.append(f"hook event: {ev.get('subtype') or ev.get('type')} {ev.get('hook_name', '')}")
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            init = ev
    if init is None:
        bad.append("no init event")
    else:
        extra = set(init.get("tools", [])) - ALLOWED_TOOLS
        if extra:
            bad.append(f"tools beyond Read/Glob/Grep: {sorted(extra)}")
        if init.get("mcp_servers"):
            bad.append(f"MCP servers: {init['mcp_servers']}")
        own = [p.get("source", p.get("name")) for p in init.get("plugins", []) if not str(p.get("source", "")).endswith("@builtin")]
        if own:
            bad.append(f"non-builtin plugins: {own}")
    reqs = sorted(glob.glob(os.path.join(capdir, "*.json")))
    if not reqs:
        bad.append("no request captured")
    for r in reqs:
        text = open(r, encoding="utf-8").read()
        if MEMORY_TEXT.search(text):
            bad.append(f"memory-file text in {os.path.basename(r)}")
        names = {t.get("name") for t in json.loads(text).get("tools", [])} - ALLOWED_TOOLS - {"DeferredToolPlaceholder"}
        if names:
            bad.append(f"request tools beyond Read/Glob/Grep: {sorted(names)}")
    for b in bad:
        print(f"canary: {b}", file=sys.stderr)
    return 1 if bad else 0


def audit(configdir, fixture):
    fixture = os.path.realpath(fixture)
    calls = leaks = 0
    for t in glob.glob(os.path.join(configdir, "projects", "*", "*.jsonl")):
        for line in open(t, encoding="utf-8"):
            try:
                content = json.loads(line).get("message", {}).get("content", [])
            except (ValueError, AttributeError):
                continue
            for part in content if isinstance(content, list) else []:
                if not isinstance(part, dict) or part.get("type") != "tool_use":
                    continue
                calls += 1
                args = part.get("input", {})
                for path in (args.get("file_path"), args.get("path"), args.get("pattern") if part.get("name") == "Glob" else None):
                    if not path or (path is args.get("pattern") and not path.startswith(("/", "~", ".."))):
                        continue
                    real = os.path.realpath(os.path.join(fixture, os.path.expanduser(path)))
                    if real != fixture and not real.startswith(fixture + os.sep):
                        leaks += 1
                        print(f"out-of-fixture {part.get('name')}: {path}")
    print(f"audit: {calls} tool calls, {leaks} outside the fixture")


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "remarks":
        remarks(*args)
    elif cmd == "comments":
        comments(args[0], args[1:])
    elif cmd == "capture":
        capture(*args)
    elif cmd == "canary":
        sys.exit(canary(*args))
    elif cmd == "audit":
        audit(*args)
    else:
        sys.exit(__doc__)
