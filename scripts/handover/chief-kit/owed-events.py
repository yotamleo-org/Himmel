#!/usr/bin/env python3
"""Project accepted step dates and readiness d intervals into existing owed rows.

No dispatch hold or delivery side effect. A consumer acknowledges a notification
with owe.sh close; the identity survives restart/succession and never reopens.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def run(bucket, now, readiness, stale_seconds=14400):
    def owe(*args, metadata=None):
        p = subprocess.run(['bash', str(HERE / 'owe.sh'), *args, '--bucket', bucket],
                           input=json.dumps(metadata) if metadata is not None else None,
                           text=True, capture_output=True)
        if p.returncode:
            raise ValueError('owed events: ' + p.stderr.strip())
        return p.stdout.strip()

    rows = json.loads(owe('list', '--all', '--json'))
    by_identity = {r.get('identity'): r for r in rows if r.get('identity')}
    out = dict(stale_ids=[], stale_ticket_ids=[], stale_step_ids=[], invalid_ids=[], reminders=[], operator_digest=[], pending=[], summary='')
    opened = [r for r in rows if not r['closed']]
    if opened:
        age = max(0, now - min(r['epoch'] for r in opened)) // 60
        out['summary'] = str(len(opened)) + ':' + (str(age // 60) + 'h' if age >= 60 else str(age) + 'm')

    def notify(event, source, actor, text, identity_parts):
        identity = hashlib.sha256(json.dumps([event, *identity_parts], separators=(',', ':')).encode()).hexdigest()
        previous = by_identity.get(identity)
        if previous:
            return None if previous['closed'] else previous['id']
        metadata = dict(actor=actor, action='notify', event=event, source_id=source,
                        capability='notification delivery', wake='acknowledge delivery with owe close')
        return owe('add', '--chief', 'chief', '--kind', 'ruling', '--text', text, '--identity', identity,
                   '--metadata-stdin', metadata=metadata)

    today = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()
    for row in opened:
        if row['kind'] == 'ticket' and not row.get('key') and now - row['epoch'] > stale_seconds:
            out['stale_ids'].append(row['id'])
            out['stale_ticket_ids'].append(row['id'])
        if row['kind'] != 'step' or not row.get('key'):
            continue
        dates = re.findall(r'\bby (\d{4}-\d{2}-\d{2})\b', row['text'])
        due = row.get('due') or (dates[0] if len(dates) == 1 else '')
        try:
            date = datetime.date.fromisoformat(due)
        except (ValueError, TypeError):
            event = 'step-due-invalid'
        else:
            if today <= date:
                continue
            event = 'step-due'
        pending = notify(event, row['id'], 'chief', row['key'] + ' ' + event + ': ' + row['text'], [row['id'], due])
        if event.endswith('invalid'):
            out['invalid_ids'].append(row['id'])
        if pending:
            out['pending'].append(pending)
            if event == 'step-due':
                out['stale_ids'].append(row['id'])
                out['stale_step_ids'].append(row['id'])
        if row.get('actor') == 'operator':
            item = notify('operator-digest', row['id'], 'operator', row['key'] + ': ' + row['text'], [row['id'], due])
            if item:
                out['operator_digest'].append(item)
    for row in readiness:
        age = row['age_s']
        if not isinstance(age, int) or age < 86400:
            continue
        identity = [row[f] for f in ('version', 'key', 'stamp', 'since')]
        text = row['key'] + ' readiness decision d: chief act still owed at interval ' + str(age // 86400)
        item = notify('readiness-d24h', row['key'], 'chief', text, [*identity, age // 86400])
        if item:
            out['reminders'].append(item)
            out['pending'].append(item)
        item = notify('operator-digest', row['key'], 'operator', text, identity)
        if item:
            out['operator_digest'].append(item)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--now', type=int, required=True)
    parser.add_argument('--stale-seconds', type=int, default=14400)
    opt = parser.parse_args()
    try:
        print(json.dumps(run(opt.bucket, opt.now, json.load(sys.stdin), opt.stale_seconds)))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
