#!/usr/bin/env python3
"""mk-transcript.py <out.jsonl> '<json event list>' - build a Claude Code transcript fixture.

Events (each a JSON list):
  ["user", text]                      a user message (the first one is the subagent's prompt)
  ["user_dispatch", dispatch.json]    a user message holding that file's `prompt`
  ["text", text]                      an assistant text block
  ["tool", name, input, result, err]  an assistant tool_use and its tool_result (err 0 or 1)
  ["usage", n]                        later assistant rows carry n cache-read input tokens
"""
import json
import sys
from datetime import datetime, timedelta, timezone

out, events = sys.argv[1], json.loads(sys.argv[2])
t0 = datetime(2026, 11, 28, 10, 0, 0, tzinfo=timezone.utc)
rows, usage, tick = [], 1000, [0]


def ts():
    tick[0] += 1
    return (t0 + timedelta(seconds=10 * tick[0])).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def assistant(block):
    return {'type': 'assistant', 'timestamp': ts(),
            'message': {'id': 'm%d' % tick[0], 'model': 'claude-opus-5-5', 'role': 'assistant', 'content': [block],
                        'usage': {'input_tokens': 10, 'output_tokens': 20, 'cache_read_input_tokens': usage,
                                  'cache_creation_input_tokens': 0}}}


for n, ev in enumerate(events):
    kind = ev[0]
    if kind == 'user':
        rows.append({'type': 'user', 'timestamp': ts(), 'message': {'role': 'user', 'content': ev[1]}})
    elif kind == 'user_dispatch':
        rows.append({'type': 'user', 'timestamp': ts(), 'message': {'role': 'user', 'content': json.load(open(ev[1]))['prompt']}})
    elif kind == 'text':
        rows.append(assistant({'type': 'text', 'text': ev[1]}))
    elif kind == 'usage':
        usage = ev[1]
    elif kind == 'tool':
        tid = 'tu%d' % n
        rows.append(assistant({'type': 'tool_use', 'id': tid, 'name': ev[1], 'input': ev[2]}))
        res = {'type': 'tool_result', 'tool_use_id': tid, 'content': ev[3]}
        if ev[4]:
            res['is_error'] = True
        rows.append({'type': 'user', 'timestamp': ts(), 'message': {'role': 'user', 'content': [res]}})
    else:
        sys.exit('mk-transcript: unknown event %r' % kind)
with open(out, 'w', encoding='utf-8') as f:
    for r in rows:
        f.write(json.dumps(r) + '\n')
