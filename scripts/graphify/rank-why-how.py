#!/usr/bin/env python3
"""rank-why-how.py -- for a why/how question, list doc and rationale nodes before code symbols.

graphify picks its start nodes by name match, so a "why" question gets need(), Token and other
code symbols first and the node holding the reason sits far below them, or is not in the answer.
For a why/how question this filter:
  1. adds up to MAX_ADDED doc/rationale nodes whose label or rationale shares at least two words
     with the question (a rare word, or one in the label, weighs more) and that the answer does not already list, and
  2. orders the NODE blocks: the start nodes the caller gave (`Start (given): [...]`), then nodes
     carrying a RATIONALE line, then doc nodes (a .md source, a document/concept/rationale node,
     or an end of a rationale_for/documents/explains edge), then the rest. Order within a tier is
     graphify's.
  3. given a budget, keeps the answer within max(its own length, budget * 3 chars) by dropping
     trailing code nodes, then the weakest added nodes; a given start node is never dropped.
A why/how question starts with why, "how <word>", what for or for what reason, or holds
"why|how does|do|is|..."; "how-to docs" and "reason codes" are not. Any other question passes
through byte for byte.

Usage: <leg-graph query output> | python3 rank-why-how.py <graph.json> <question> [<budget>]

Fails open: an unreadable graph or any error prints the input as-is and says so on stderr.
ponytail: word overlap, not meaning; upgrade path is graphify scoring rationale itself (HIMMEL-6056).
"""
import ast
import json
import math
import re
import sys

MAX_ADDED = 3
MAX_LEN = 400
WHY_HOW = re.compile(
    r"^\s*(why|what\s+for|for\s+what\s+reason)\b|^\s*how\s+\w|\b(why|how)\s+(does|do|did|is|are|was|were|can|should|would)\b",
    re.I,
)
NODE_LINE = re.compile(r"^NODE (?P<label>.*) \[src=(?P<src>.*?) loc=")
GIVEN = re.compile(r"\| Start \(given\): (\[.*?\])(?= \| )")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
DOC_TYPES = {"document", "concept", "rationale", "paper"}
DOC_RELATIONS = {"rationale_for", "documents", "explains"}
STOP = set(
    "why how what for reason does did is are was were can should would the and a an of to in on "
    "at by it its this that with from or be do which who when where need needs while".split()
)


def words(text):
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) >= 3 and w not in STOP}


def matched(qwords, text):
    tw = words(text)
    return {q for q in qwords if any(t in (q, q + "s") or (len(q) >= 4 and t.startswith(q)) for t in tw)}


def clean(text):
    if isinstance(text, list):
        text = " ".join(str(t) for t in text)
    if not isinstance(text, str):
        return ""
    text = " ".join(CONTROL.sub(" ", text).split())
    return text[: MAX_LEN - 3] + "..." if len(text) > MAX_LEN else text


def is_doc(node, doc_ids):
    src = node.get("source_file") or ""
    return node.get("file_type") in DOC_TYPES or src.endswith(".md") or node.get("id") in doc_ids


def note(n):
    return f" (+{n} doc/rationale nodes added for a why/how question)"


def given_labels(head):
    for line in head:
        m = GIVEN.search(line)
        if m:
            try:
                return set(ast.literal_eval(m.group(1)))
            except (ValueError, SyntaxError):
                return set()
    return set()


def rank(lines, graph, question, budget=None):
    nodes = graph.get("nodes", [])
    doc_ids = set()
    for edge in graph.get("links", graph.get("edges", [])):
        if edge.get("relation") in DOC_RELATIONS:
            doc_ids.update((edge.get("source"), edge.get("target")))
    by_key = {}
    for node in nodes:
        by_key.setdefault((node.get("label"), node.get("source_file")), node)

    start = next((i for i, line in enumerate(lines) if line.startswith("NODE ")), None)
    if start is None:
        return lines
    end = start
    blocks = []
    while end < len(lines) and (lines[end].startswith("NODE ") or lines[end].startswith("  ")):
        if lines[end].startswith("NODE "):
            blocks.append([lines[end]])
        else:
            blocks[-1].append(lines[end])
        end += 1

    shown = set()
    for block in blocks:
        m = NODE_LINE.match(block[0])
        if m:
            shown.add((m.group("label"), m.group("src")))

    # A rare question word counts for more than a common one, and a word in the label (the
    # node's topic) for twice one found only in the rationale text.
    qwords = words(question)
    df = dict.fromkeys(qwords, 0)
    candidates = []
    for i, node in enumerate(nodes):
        if not node.get("label") or not is_doc(node, doc_ids):
            continue
        why = clean(node.get("rationale"))
        in_label = matched(qwords, node["label"])
        in_any = in_label | matched(qwords, why)
        for q in in_any:
            df[q] += 1
        if len(in_any) >= 2 and (node["label"], node.get("source_file")) not in shown:
            candidates.append((i, node, why, in_label, in_any))
    total = sum(1 for n in nodes if is_doc(n, doc_ids))
    idf = {q: math.log((total + 1) / (n + 1)) + 1 for q, n in df.items()}
    scored = []
    for i, node, why, in_label, in_any in candidates:
        score = sum(idf[q] * (2 if q in in_label else 1) for q in in_any)
        scored.append((-score, 0 if why else 1, i, node, why))
    scored.sort(key=lambda s: s[:3])
    added = []
    for _, _, _, node, why in scored[:MAX_ADDED]:
        block = [
            CONTROL.sub(" ", f"NODE {node.get('label')} [src={node.get('source_file')} loc={node.get('source_location')} "
            f"community={node.get('community_name') or ''}]")
        ]
        if why:
            block.append("  RATIONALE: " + why)
        added.append(block)

    # The first block for each given start label stays on top: the caller named that node.
    pinned, wanted = set(), given_labels(lines[:start])
    for block in blocks:
        m = NODE_LINE.match(block[0])
        if m and m.group("label") in wanted:
            wanted.discard(m.group("label"))
            pinned.add(id(block))

    def tier(block):
        if id(block) in pinned:
            return -1
        if any(line.startswith("  RATIONALE:") for line in block[1:]):
            return 0
        m = NODE_LINE.match(block[0])
        node = by_key.get((m.group("label"), m.group("src"))) if m else None
        if m and (m.group("src").endswith(".md") or (node and is_doc(node, doc_ids))):
            return 1
        return 2

    ordered = sorted(added + blocks, key=tier)
    head = lines[:start]
    if budget and added:
        # Added nodes take the room of trailing code nodes, then of the weakest added ones, so the
        # answer never grows past the budget graphify was given (it counts 3 chars per token).
        limit = max(len("\n".join(lines)), budget * 3)

        def size():
            body = len("\n".join(head + [line for b in ordered for line in b] + lines[end:]))
            return body + (len(note(len(added))) if added else 0)

        for block in [b for b in reversed(ordered) if tier(b) == 2] + added[::-1]:
            if size() <= limit:
                break
            ordered.remove(block)
            if block in added:
                added.remove(block)
    if added:
        head = [re.sub(r"(\| \d+ nodes found)$", r"\1" + note(len(added)), line) for line in head]
        print(f"rank-why-how: added {len(added)} doc/rationale node(s) matching the question's words", file=sys.stderr)
    return head + [line for block in ordered for line in block] + lines[end:]


def main():
    raw = sys.stdin.read()
    question = sys.argv[2] if len(sys.argv) > 2 else ""
    budget = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
    if not WHY_HOW.search(question):
        sys.stdout.write(raw)
        return
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            graph = json.load(fh)
        lines = rank(raw.split("\n"), graph, question, budget)
    except Exception as exc:  # fail open: the plain answer beats no answer
        print(f"rank-why-how: {exc}; printing the answer unranked", file=sys.stderr)
        sys.stdout.write(raw)
        return
    sys.stdout.write("\n".join(lines))


if __name__ == "__main__":
    main()
