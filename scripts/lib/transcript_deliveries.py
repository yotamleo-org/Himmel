#!/usr/bin/env python3
"""scripts/lib/transcript_deliveries.py - the one classifier of what reached a session from its chief or operator.

Each main-chain row of a session transcript becomes one item with a kind. Whether an item is eligible
for a hop brief and whether it counts as a delivery depends on the session's chief names, which the
caller passes in; this module reads no handover doc except through chief_names(doc).

  python3 -I transcript_deliveries.py --count <jsonl>...   counts per kind, no text

Exit: 0 ok, 2 usage, 3 an unreadable transcript.
"""

import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

BUS_HEAD = re.compile(r"^bus #\d+ (data )?from (\S+?)( re #\d+)?:(?= |$)", re.M)
READ_PREFIX = "data (not a ruling): "
BUS_READ_TOOL = "mcp__himmel-bus__read"
WAKE_LINE = "You have unread himmel messages: call mcp__himmel-bus__read now."
CROSS_SESSION_STARTS = ("Another Claude session sent a message:", "<cross-session-message")
MONITOR_STARTS = ("<task-notification>", "[SYSTEM NOTIFICATION", "[Cross-session idle notice]")
CS_TAG = re.compile(r"<cross-session-message\b[^>]*>")
FROM_NAME = re.compile(r'\sfrom-name="([^"]*)"')
CHIEF_CLAUSE = "your chief is **`{chief}`**"
CHIEF_CLAUSE_RE = re.compile(r"your chief is \*\*`([A-Za-z0-9][A-Za-z0-9._-]*)`\*\*")
SUCCESSION = "^SUCCESSION accepted: ([A-Za-z0-9][A-Za-z0-9._-]*) replaces [A-Za-z0-9][A-Za-z0-9._-]*$"
SUCCESSION_BULLET = re.compile(
    r"^- (?:[0-9][0-9]:[0-9][0-9] )?(?:LIVE — )?SUCCESSION accepted: "
    r"(`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+) replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)\s*$")

KINDS = {
    "operator": (True, True),
    "bus-trusted": (True, True),
    "bus-data": (True, False),
    "bus-read": (True, True),
    "assistant": (True, False),
    "unreadable-sender": (False, False),
    "hand-back": (False, False),
    "hook-context": (False, False),
    "bus-list": (False, False),
    "wake": (False, False),
    "meta": (False, False),
    "local-command": (False, False),
    "task-notification": (False, False),
    "monitor": (False, False),
    "tool-result": (False, False),
    "other": (False, False),
}
ANY_CHIEF = object()

_inventory = None


def classify_trigger(text):
    global _inventory
    if _inventory is None:
        path = os.path.join(HERE, "..", "eval", "chief-load-inventory.py")
        spec = importlib.util.spec_from_file_location("chief_load_inventory", path)
        _inventory = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_inventory)
    return _inventory.classify_trigger(text)


class Item:
    __slots__ = ("row", "kind", "sender", "text", "untrusted")

    def __init__(self, row, kind, text, sender=None, untrusted=False):
        self.row, self.kind, self.text, self.sender, self.untrusted = row, kind, text, sender, untrusted

    @property
    def id(self):
        return "L%d" % self.row

    def eligible(self, chiefs):
        if self.kind == "cross-session":
            return True
        return KINDS[self.kind][0]

    def delivery(self, chiefs):
        if self.kind == "cross-session":
            return chiefs is ANY_CHIEF or self.sender in (chiefs or ())
        return KINDS[self.kind][1]

    def sender_known(self, chiefs):
        return self.delivery(chiefs) and self.kind != "bus-read"


def sort_user_text(text, meta):
    if text == WAKE_LINE:
        return "wake", None
    if text.startswith(CROSS_SESSION_STARTS):
        tag = CS_TAG.search(text)
        if tag:
            m = FROM_NAME.search(tag.group(0))
            if m and m.group(1):
                return "cross-session", m.group(1)
            return "unreadable-sender", None
    if meta:
        return "meta", None
    if text.startswith(MONITOR_STARTS):
        return "monitor", None
    trig = classify_trigger(text)
    if trig == "task-notification":
        return "task-notification", None
    if trig == "subagent-hand-back":
        return "hand-back", None
    if trig == "local-command":
        return "local-command", None
    return "operator", None


def _result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(b.get("text", "")) for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def read_rows(path, upto=None):
    """-> [(row number from 1, record)] of the main chain; upto stops after that row number."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            if upto is not None and n > upto:
                break
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict) and not d.get("isSidechain"):
                out.append((n, d))
    return out


def classify_rows(rows):
    """-> (items, calls): one Item per row that carries text; calls maps tool_use id -> (row, name, input)."""
    items, calls = [], {}
    for n, d in rows:
        t = d.get("type")
        att = d.get("attachment") if isinstance(d.get("attachment"), dict) else {}
        if t == "assistant":
            content = (d.get("message") or {}).get("content")
            texts = []
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text"):
                    texts.append(str(b["text"]))
                elif b.get("type") == "tool_use":
                    calls[b.get("id")] = (n, b.get("name"), b.get("input") if isinstance(b.get("input"), dict) else {})
            if isinstance(content, str) and content:
                texts.append(content)
            if texts:
                items.append(Item(n, "assistant", "\n".join(texts)))
        elif t == "user":
            content = (d.get("message") or {}).get("content")
            meta = bool(d.get("isMeta") or d.get("isCompactSummary"))
            if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "tool_result":
                        continue
                    call = calls.get(b.get("tool_use_id"))
                    text = _result_text(b.get("content"))
                    if call and call[1] == BUS_READ_TOOL:
                        if "n" in call[2] and text.startswith(READ_PREFIX):
                            items.append(Item(n, "bus-read", text, untrusted=True))
                        else:
                            items.append(Item(n, "bus-list", text, untrusted=True))
                    else:
                        items.append(Item(n, "tool-result", text, untrusted=True))
                continue
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = _result_text(content)
            else:
                text = ""
            if not text:
                items.append(Item(n, "other", ""))
                continue
            kind, sender = sort_user_text(text, meta)
            items.append(Item(n, kind, text, sender))
        elif t == "attachment" and att.get("type") == "queued_command":
            text = att.get("prompt") if isinstance(att.get("prompt"), str) else ""
            meta = bool(att.get("isMeta") or d.get("isMeta") or d.get("isCompactSummary"))
            kind, sender = sort_user_text(text, meta) if text else ("other", None)
            items.append(Item(n, kind, text, sender))
        elif t == "attachment" and att.get("type") == "hook_additional_context":
            content = att.get("content")
            text = "\n".join(str(x) for x in content) if isinstance(content, list) else str(content or "")
            heads = BUS_HEAD.findall(text)
            trusted = [h for h in heads if not h[0]]
            if trusted:
                items.append(Item(n, "bus-trusted", text, trusted[-1][1]))
            elif heads:
                items.append(Item(n, "bus-data", text))
            else:
                items.append(Item(n, "hook-context", text))
    return items, calls


def classify(rows, chiefs):
    items, _ = classify_rows(rows)
    return [(it, it.eligible(chiefs), it.delivery(chiefs)) for it in items]


def chief_names(doc_text):
    """The worker's chain of chiefs, oldest first: the doc's chief clause, then each accepted succession
    after `## Results` (to the end of the doc) whose replaced name is already in the chain."""
    chain = []
    for line in doc_text.splitlines():
        if line.startswith("> | "):
            continue
        m = CHIEF_CLAUSE_RE.search(line)
        if m:
            chain.append(m.group(1))
            break
    if not chain:
        return []
    seen = False
    for line in doc_text.splitlines():
        if re.match(r"^## Results(\s|$)", line):
            seen = True
            continue
        if not seen:
            continue
        m = SUCCESSION_BULLET.match(line)
        if m:
            new, old = m.group(1).strip("`"), m.group(2).strip("`")
            if old in chain:
                chain.append(new)
    return chain


def count(paths):
    totals = {k: 0 for k in list(KINDS) + ["cross-session-named"]}
    rows_seen = 0
    for p in paths:
        rows = read_rows(p)
        rows_seen += len(rows)
        items, _ = classify_rows(rows)
        for it in items:
            totals["cross-session-named" if it.kind == "cross-session" else it.kind] += 1
    return rows_seen, totals


def main(argv):
    if len(argv) < 2 or argv[0] != "--count":
        print("usage: transcript_deliveries.py --count <jsonl>...", file=sys.stderr)
        return 2
    try:
        rows_seen, totals = count(argv[1:])
    except OSError as e:
        print("transcript_deliveries: cannot read %s" % e.filename, file=sys.stderr)
        return 3
    placed = sum(v for k, v in totals.items() if k != "other")
    print("transcripts=%d rows=%d items=%d placed-in-none=%d" % (len(argv) - 1, rows_seen, placed + totals["other"], totals["other"]))
    for k in sorted(totals):
        print("%s=%d" % (k, totals[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
