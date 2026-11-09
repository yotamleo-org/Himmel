#!/usr/bin/env python3
"""mine-questions.py -- the local miner for the pilot's 20 real tasks (design section 5).

  mine-questions.py SESSIONS_DIR --out CANDIDATES.jsonl --seed N --sample K

Reads session transcripts (*.jsonl) locally, keeps distinct question-shaped user turns
(ending in "?" or opening with a question word; slash commands and short acknowledgements
dropped), records each candidate's provenance (transcript sha256 and line), then draws a
seeded sample of K. The sampling rule and counts go to CANDIDATES.jsonl.summary.json. Gold is
found later by reading and grep, never by this tool: it calls no search tool. The output is
private: it refuses any path inside a git work tree, and files are mode 600.
Exit 0 ok, 3 refusal.
"""
import argparse, hashlib, json, os, random, re, subprocess, sys

QWORD = re.compile(r"^(what|where|which|who|why|how|when|does|do|is|are|can|should)\b", re.I)


def text_of(msg):
    c = (msg.get("message") or {}).get("content")
    if isinstance(c, list):
        return " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return c if isinstance(c, str) else ""


def in_git_tree(path):
    d = os.path.dirname(os.path.abspath(path)) or "."
    r = subprocess.run(["git", "-C", d, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)   # an existing, wider-moded file is narrowed too
    with os.fdopen(fd, "w") as f:
        f.write(text)


def main(argv):
    p = argparse.ArgumentParser(prog="mine-questions.py")
    p.add_argument("sessions")
    p.add_argument("--out", required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--sample", type=int, required=True)
    a = p.parse_args(argv)
    if in_git_tree(a.out):
        print("mine-questions: refused: %s is inside a git work tree; candidates stay private" % a.out, file=sys.stderr)
        return 3
    seen, cands = set(), []
    for name in sorted(os.listdir(a.sessions)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(a.sessions, name)
        raw = open(path, "rb").read()
        tsha = hashlib.sha256(raw).hexdigest()
        for n, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("type") != "user":
                continue
            t = " ".join(text_of(m).split())
            if not t or t.startswith("<") or len(t) < 12:
                continue
            if not (t.endswith("?") or QWORD.match(t)):
                continue
            key = t.lower().rstrip("?")
            if key in seen:
                continue
            seen.add(key)
            cands.append({"question": t, "transcript_sha256": tsha, "line": n})
    rng = random.Random(a.seed)
    sample = rng.sample(cands, min(a.sample, len(cands)))
    write_private(a.out, "".join(json.dumps(c, sort_keys=True) + "\n" for c in sample))
    summary = {"candidates": len(cands), "sampled": len(sample), "transcripts": len({c["transcript_sha256"] for c in cands}),
               "sampling_rule": "distinct question-shaped user turns, random.Random(%d).sample(k=%d)" % (a.seed, a.sample)}
    write_private(a.out + ".summary.json", json.dumps(summary, sort_keys=True) + "\n")
    print(json.dumps({k: summary[k] for k in ("candidates", "sampled", "transcripts")}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
