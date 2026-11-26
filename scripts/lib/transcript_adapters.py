#!/usr/bin/env python3
"""scripts/lib/transcript_adapters.py - read another harness's session record as the rows transcript_deliveries.py classifies.

read_rows(path, upto) is a drop-in for transcript_deliveries.read_rows: it returns [(row number, record)] where a
record has the shape of a Claude Code transcript row. The format is found from the file itself:

  a Codex rollout (JSONL, first row `session_meta`)     row number = the line number of the rollout
  T3 thread items (a whole `t3_thread_read` activity      row number = the item's position + 1
  JSON: hasMore false, earlierPosition null)
  anything else                                          a Claude Code transcript, read by transcript_deliveries

Only messages map: the user's and the assistant's. Developer rows, tool calls and results, reasoning, compaction and
handoff items are not mapped, and a user row the harness injected (AGENTS.md, environment context) is flagged isMeta.
A message an agent relayed through T3 reaches the classifier under T3's own wrapper line, so it is never the operator's.
This module scrubs nothing: the brief writer scrubs every text it carries.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import transcript_deliveries as td  # noqa: E402

CODEX_INJECTED_STARTS = ("# AGENTS.md instructions", "<environment_context>")
CODEX_USER_KIND = "user.text"
T3_MESSAGES = ("user_message", "assistant_message")


class AdapterError(Exception):
    pass


def detect(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        first = f.readline()
    try:
        d = json.loads(first)
    except ValueError:
        return "t3-items" if first.strip() in ("{", "[") else "claude"
    if isinstance(d, dict) and d.get("type") == "session_meta" and isinstance(d.get("payload"), dict):
        return "codex"
    if isinstance(d, dict) and isinstance(d.get("items"), list):
        return "t3-items"
    return "claude"


def _user(text, meta=False):
    rec = {"type": "user", "message": {"role": "user", "content": text}}
    if meta:
        rec["isMeta"] = True
    return rec


def _assistant(text):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def codex_rows(path, upto=None):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            if upto is not None and n > upto:
                break
            try:
                d = json.loads(line)
            except ValueError:
                continue
            p = d.get("payload") if isinstance(d, dict) and d.get("type") == "response_item" else None
            if not isinstance(p, dict) or p.get("type") != "message" or not isinstance(p.get("content"), list):
                continue
            text = "\n".join(str(b.get("text", "")) for b in p["content"]
                             if isinstance(b, dict) and b.get("type") in ("input_text", "output_text"))
            if not text:
                continue
            if p.get("role") == "assistant":
                out.append((n, _assistant(text)))
            elif p.get("role") == "user":
                kinds = (p.get("internal_chat_message_metadata_passthrough") or {}).get("content_item_kinds")
                injected = any(k != CODEX_USER_KIND for k in kinds) if isinstance(kinds, list) and kinds \
                    else text.startswith(CODEX_INJECTED_STARTS)
                out.append((n, _user(text, injected)))
    return out


def t3_item_rows(path, upto=None):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, UnicodeDecodeError):
        raise AdapterError("%s is not valid JSON" % path)
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list) or not all(isinstance(i, dict) and isinstance(i.get("position"), int) for i in items):
        raise AdapterError("%s holds no list of thread items with a position" % path)
    if data.get("hasMore") is not False:
        raise AdapterError("%s is a partial thread read (hasMore is not false): newer items are missing" % path)
    if "earlierPosition" not in data or data["earlierPosition"] is not None:
        raise AdapterError("%s is a partial thread read (earlierPosition is not null): older items may be missing" % path)
    out = []
    for it in sorted(items, key=lambda i: i["position"]):
        n = it["position"] + 1
        if (upto is not None and n > upto) or it.get("type") not in T3_MESSAGES or not it.get("text"):
            continue
        if it.get("textTruncated"):
            raise AdapterError("item %s is cut off (textTruncated): read it whole with itemId and textOffset first" % it.get("itemId"))
        text = str(it["text"])
        if it["type"] == "assistant_message":
            out.append((n, _assistant(text)))
        elif it.get("createdBy") == "user" and not it.get("senderThreadId"):
            out.append((n, _user(text)))
        else:
            sender = it.get("senderThreadId")
            head = td.T3_RELAY_HEAD.format(thread=sender) if isinstance(sender, str) and sender and '"' not in sender \
                else td.T3_TOOLS_HEAD
            out.append((n, _user(head + "\n\n" + text)))
    return out


def read_rows(path, upto=None):
    kind = detect(path)
    if kind == "codex":
        return codex_rows(path, upto)
    if kind == "t3-items":
        return t3_item_rows(path, upto)
    return td.read_rows(path, upto)
