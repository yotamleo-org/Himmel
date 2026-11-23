#!/usr/bin/env python3
"""scripts/lib/handover_tokens.py - the one token helper. It holds no token pattern of its own.

scrub(texts) runs `redact` of scripts/handover/chief-kit/redact.mjs over every text in one `node` call,
then replaces each word the handover-token grammar rule still matches by [nonce]. The rule is read at
run time from the line after `# handover-token grammar` in templates/luna-second-brain/.gitleaks.toml;
it is anchored to a whole word, so it is applied word by word (split on whitespace and backticks,
trailing punctuation stripped). A 40-hex commit sha and a 64-hex digest are left alone.

  python3 -I handover_tokens.py --count-misses <jsonl>...   counts only, no text

Exit: 0 ok, 2 usage, 3 no node, no rule or an unreadable transcript.
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
REDACT = os.path.join(ROOT, "scripts", "handover", "chief-kit", "redact.mjs")
GITLEAKS = os.path.join(ROOT, "templates", "luna-second-brain", ".gitleaks.toml")
HEX = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
WORD = re.compile(r"[^\s`]+")
TRAIL = ".,;:)"
MISS = re.compile(r"-[0-9a-f]{8,}")
NODE_JS = (
    "const { redact } = await import(process.argv[1]);"
    "let s = ''; process.stdin.setEncoding('utf8');"
    "for await (const c of process.stdin) s += c;"
    "process.stdout.write(JSON.stringify(JSON.parse(s).map(redact)));"
)


class TokenError(Exception):
    pass


_rule = None


def grammar():
    global _rule
    if _rule is None:
        try:
            lines = open(GITLEAKS, encoding="utf-8").read().splitlines()
        except OSError:
            raise TokenError("no handover-token grammar rule: %s unreadable" % GITLEAKS)
        for i, line in enumerate(lines):
            if line.strip() == "# handover-token grammar" and i + 1 < len(lines):
                raw = lines[i + 1].strip().rstrip(",")
                if raw.startswith("'''") and raw.endswith("'''"):
                    _rule = re.compile(raw[3:-3])
                    break
        if _rule is None:
            raise TokenError("no handover-token grammar rule in %s" % GITLEAKS)
    return _rule


def _redact(texts):
    node = shutil.which("node")
    if not node:
        raise TokenError("no node on PATH: the redactor cannot run")
    r = subprocess.run([node, "--input-type=module", "-e", NODE_JS, "file://" + REDACT],
                       input=json.dumps(texts), capture_output=True, text=True)
    if r.returncode != 0:
        raise TokenError("redact.mjs failed: %s" % (r.stderr.strip().splitlines() or ["?"])[-1])
    return json.loads(r.stdout)


def _grammar_word(m):
    word = m.group(0)
    core = word.rstrip(TRAIL)
    if core and grammar().fullmatch(core) and not HEX.fullmatch(core):
        return "[nonce]" + word[len(core):]
    return word


def scrub(texts):
    grammar()
    return [WORD.sub(_grammar_word, t) for t in _redact(list(texts))]


def has_token(text):
    return scrub([text])[0] != text


def count_misses(paths):
    sys.path.insert(0, HERE)
    import transcript_deliveries as td
    lines = []
    for p in paths:
        for it, _, delivery in td.classify(td.read_rows(p), td.ANY_CHIEF):
            if delivery:
                lines.extend(l for l in it.text.splitlines() if re.search(r"RETASK|nonce|token", l))
    return sum(1 for l in scrub(lines) if MISS.search(l)) if lines else 0


def main(argv):
    if len(argv) < 2 or argv[0] != "--count-misses":
        print("usage: handover_tokens.py --count-misses <jsonl>...", file=sys.stderr)
        return 2
    try:
        n = count_misses(argv[1:])
    except TokenError as e:
        print("handover_tokens: %s" % e, file=sys.stderr)
        return 3
    except OSError as e:
        print("handover_tokens: cannot read %s" % e.filename, file=sys.stderr)
        return 3
    print("misses=%d" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
