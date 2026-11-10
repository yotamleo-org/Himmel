#!/usr/bin/env python3
"""Local stub of an OpenAI-compatible model endpoint for the pilot build fixtures.

It answers /v1/embeddings, /v1/rerank and /v1/chat/completions on 127.0.0.1 only, from
deterministic word hashes: no model, no network, no cost. Every request is appended to
--log as one JSON line so a test can count calls. STUB_MODE picks a failure:
  expand-fail   chat answers 500 (qmd prints "Structured query expansion failed:")
  expand-empty  chat answers an empty message (qmd's silent raw-query-only fallback)
  embed-down    every embedding request answers 500 (a query skips the meaning part)
  rerank-fail   rerank answers 500
Usage: stub-openai.py --port N --port-file F --log F   (run inside a network namespace)
"""
import argparse, hashlib, json, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIM = 16


def vec(text):
    v = [0.0] * DIM
    for w in re.findall(r"[a-z0-9]+", text.lower()):
        v[int(hashlib.sha256(w.encode()).hexdigest(), 16) % DIM] += 1.0
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [x / n for x in v]


def overlap(a, b):
    wa, wb = set(re.findall(r"[a-z0-9]+", a.lower())), set(re.findall(r"[a-z0-9]+", b.lower()))
    return len(wa & wb) / (len(wa) or 1)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {"data": [{"id": "stub"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        mode = os.environ.get("STUB_MODE", "")
        with open(ARGS.log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": bool(self.headers.get("authorization")), "mode": mode}) + "\n")
        if self.path.endswith("/embeddings"):
            inputs = body.get("input") or []
            if mode == "embed-down":
                return self.reply(500, {"error": "down"})
            return self.reply(200, {"data": [{"index": i, "embedding": vec(t)} for i, t in enumerate(inputs)]})
        if self.path.endswith("/rerank"):
            if mode == "rerank-fail":
                return self.reply(500, {"error": "down"})
            docs = body.get("documents") or []
            return self.reply(200, {"results": [{"index": i, "relevance_score": overlap(body.get("query", ""), d)} for i, d in enumerate(docs)]})
        if self.path.endswith("/chat/completions"):
            if mode == "expand-fail":
                return self.reply(500, {"error": "down"})
            prompt = (body.get("messages") or [{}])[0].get("content", "")
            q = prompt.rsplit("Query:", 1)[-1].strip()
            text = "" if mode == "expand-empty" else f"lex: {q}\nvec: about {q}\nhyde: A note that explains {q}."
            return self.reply(200, {"choices": [{"message": {"content": text}}]})
        self.reply(404, {"error": "unknown"})


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--port-file", required=True)
    p.add_argument("--log", required=True)
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), H)
    tmp = ARGS.port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, ARGS.port_file)
    sys.stdout.flush()
    srv.serve_forever()
