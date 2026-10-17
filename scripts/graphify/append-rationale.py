#!/usr/bin/env python3
"""append-rationale.py -- print the stored `rationale` text graphify keeps but never shows.

graphify's `query` NODE lines and `explain` output carry label, source and edges only; the WHY
of a semantic node lives in its top-level `rationale` key, which neither verb prints.
This filter reads that output on stdin and, for every node that matches a graph node by label
and source file and has a rationale, adds one line with the text. Everything else passes through
unchanged.

Usage: <graphify output> | python3 append-rationale.py <graph.json>

Fails open: an unreadable graph or any error prints the input as-is and says so on stderr.
"""
import json
import re
import sys

MAX_LEN = 400
NODE_LINE = re.compile(r"^NODE (?P<label>.*) \[src=(?P<src>.*?) loc=")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def load_rationales(path):
    with open(path, encoding="utf-8") as fh:
        graph = json.load(fh)
    found = {}
    for node in graph.get("nodes", []):
        text = node.get("rationale")
        if isinstance(text, list):
            text = " ".join(str(t) for t in text)
        if not isinstance(text, str) or not text.strip():
            continue
        text = CONTROL.sub(" ", text)
        text = " ".join(text.split())
        if len(text) > MAX_LEN:
            text = text[: MAX_LEN - 3] + "..."
        found.setdefault((node.get("label"), node.get("source_file")), text)
    return found


def annotate(lines, found):
    out = []
    shown = set()
    label = None
    for line in lines:
        out.append(line)
        match = NODE_LINE.match(line)
        if match:
            key = (match.group("label"), match.group("src"))
            if key in found and key not in shown:
                shown.add(key)
                out.append("  RATIONALE: " + found[key])
            continue
        if line.startswith("Node: "):
            label = line[len("Node: "):]
        elif line.lstrip().startswith("Source:") and label is not None:
            rest = line.lstrip()[len("Source:"):].strip()
            for (lab, src), text in found.items():
                if lab == label and src and (rest == src or rest.startswith(src + " ")):
                    out.append("  Rationale: " + text)
                    break
            label = None
    return out


def main():
    raw = sys.stdin.read()
    try:
        found = load_rationales(sys.argv[1])
        lines = annotate(raw.split("\n"), found)
    except Exception as exc:  # fail open: the plain answer beats no answer
        print(f"append-rationale: {exc}; printing graphify output unchanged", file=sys.stderr)
        sys.stdout.write(raw)
        return
    sys.stdout.write("\n".join(lines))


if __name__ == "__main__":
    main()
