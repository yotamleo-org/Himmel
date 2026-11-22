#!/usr/bin/env python3
"""Project accepted step dates and readiness d intervals into existing owed rows.

No dispatch hold or delivery side effect. A consumer acknowledges a notification
with owe.sh close; the identity survives restart/succession and never reopens.

The `spool` verb writes the owed lines of a partial merge to the station spool, one
JSON row per line, every access under an exclusive flock. A run given --spool,
--project, --chief and a --handover-root that holds the bucket first drains that
project's spooled rows into the bucket's ledger, claiming each row before adding it.
  owed-events.py spool --spool <file> --key <KEY> --pr <n> --repo <owner/name> [--unread]
      stdin: who<TAB>due<TAB>ask<TAB>text lines (pr_remainder.py --owed-lines)
  owed-events.py spool --check --spool <file>      prints the line numbers that do not parse
  owed-events.py spool --drop <line>[,<line>...] --spool <file>
Exit 0 done, 2 usage, 4 the spool cannot be opened, locked or written.
OWE_SPOOL_LOCK_WAIT (seconds, default 10) bounds every wait for the spool lock.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
SPOOL_FIELDS = dict(owed=('ts', 'key', 'pr', 'repo', 'who', 'due', 'ask', 'text', 'identity', 'metadata'),
                    unread=('ts', 'key', 'pr', 'repo', 'identity'), claim=('ts', 'identity', 'bucket'))
UNREAD_TEXT = 'the owed lines of this partial merge could not be read: read the PR body and add a row per owed line'


def utc_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def spool_lock(fd):
    try:
        wait = float(os.environ.get('OWE_SPOOL_LOCK_WAIT', '10'))
    except ValueError:
        wait = 10.0
    deadline = time.monotonic() + max(wait, 0.0)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError('the spool lock was not free within OWE_SPOOL_LOCK_WAIT') from None
            time.sleep(0.05)


def spool_read(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            return b''.join(chunks)
        chunks.append(chunk)


def spool_write(fd, data, at):
    view = memoryview(data)
    os.lseek(fd, at, os.SEEK_SET)
    while view:
        view = view[os.write(fd, view):]


def spool_append(fd, data):
    """Append whole rows on a fresh line; on any error the file is cut back to its size before the call."""
    size = os.fstat(fd).st_size
    if size and os.pread(fd, 1, size - 1) != b'\n':
        data = b'\n' + data
    try:
        spool_write(fd, data, size)
    except OSError:
        os.ftruncate(fd, size)
        raise


def spool_line(row):
    return (json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n').encode()


def spool_lines(data):
    """(line number, bytes) for every line, a torn last line included."""
    parts = data.split(b'\n')
    if parts[-1] == b'':
        parts.pop()
    return list(enumerate(parts, 1))


def spool_row(line):
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict) or row.get('schema') != 1 or row.get('kind') not in SPOOL_FIELDS:
        return None
    if any(f not in row for f in SPOOL_FIELDS[row['kind']]):
        return None
    if not (isinstance(row['identity'], str) and re.fullmatch(r'[0-9a-f]{64}', row['identity'])):
        return None
    if row['kind'] == 'claim':
        return row if isinstance(row['bucket'], str) else None
    if not isinstance(row['key'], str) or not isinstance(row['pr'], int):
        return None
    if row['kind'] == 'owed':
        return row if isinstance(row['text'], str) and isinstance(row['metadata'], dict) else None
    try:
        datetime.datetime.strptime(row['ts'], '%Y-%m-%dT%H:%M:%SZ')
    except (ValueError, TypeError):
        return None
    return row


def spool_edit(opt, drop):
    """--check (drop empty) or --drop under the lock; line numbers count from the file before any removal."""
    try:
        fd = os.open(opt.spool, os.O_RDWR if drop else os.O_RDONLY)
    except FileNotFoundError:
        if drop:
            print('owed-events spool: ' + opt.spool + ' does not exist', file=sys.stderr)
            return 2
        return 0
    except OSError as exc:
        print('owed-events spool: ' + opt.spool + ': ' + str(exc), file=sys.stderr)
        return 4
    try:
        spool_lock(fd)
        data = spool_read(fd)
        lines = spool_lines(data)
        if not drop:
            for n, line in lines:
                if line.strip() and spool_row(line) is None:
                    print(n)
            return 0
        missing = sorted(drop - {n for n, _ in lines})
        if missing:
            print('owed-events spool: no line ' + ','.join(map(str, missing)) + ' in ' + opt.spool, file=sys.stderr)
            return 2
        kept = b''.join(line + b'\n' for n, line in lines if n not in drop)
        try:
            os.ftruncate(fd, 0)
            spool_write(fd, kept, 0)
        except OSError:
            os.ftruncate(fd, 0)
            spool_write(fd, data, 0)
            raise
        return 0
    except OSError as exc:
        print('owed-events spool: ' + opt.spool + ': ' + str(exc), file=sys.stderr)
        return 4
    finally:
        os.close(fd)


def spool_main(argv):
    parser = argparse.ArgumentParser(prog='owed-events.py spool')
    parser.add_argument('--spool', required=True)
    parser.add_argument('--key')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--repo')
    parser.add_argument('--unread', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--drop')
    opt = parser.parse_args(argv)
    if opt.check or opt.drop is not None:
        if opt.check and opt.drop is not None:
            parser.error('--check and --drop are separate calls')
        if opt.drop is not None and not re.fullmatch(r'[1-9][0-9]*(,[1-9][0-9]*)*', opt.drop):
            parser.error('--drop takes line numbers like 2 or 2,4')
        return spool_edit(opt, {int(n) for n in opt.drop.split(',')} if opt.drop else set())
    if not opt.key or opt.pr is None or not opt.repo:
        parser.error('spool needs --key, --pr and --repo')
    ts = utc_stamp()
    rows = []
    if opt.unread:
        identity = hashlib.sha256(('unread\n%s\n%d\n' % (opt.key, opt.pr)).encode()).hexdigest()
        rows.append(dict(kind='unread', schema=1, ts=ts, key=opt.key, pr=opt.pr, repo=opt.repo, identity=identity))
    else:
        for line in sys.stdin.read().split('\n'):
            if not line.strip():
                continue
            fields = line.split('\t', 3)
            if len(fields) != 4:
                parser.error('an owed line is who<TAB>due<TAB>ask<TAB>text')
            who, due, ask, text = fields
            identity = hashlib.sha256(('%s\n%d\n%s\n%s\n%s\n' % (opt.key, opt.pr, who, due, text)).encode()).hexdigest()
            metadata = dict(actor=who, due=due, wake='complete the accepted PR #%d remainder' % opt.pr, action='next-step',
                            capability='read-only proof worker' if who == 'proof' else who)
            rows.append(dict(kind='owed', schema=1, ts=ts, key=opt.key, pr=opt.pr, repo=opt.repo, who=who, due=due,
                             ask=ask, text=text, identity=identity, metadata=metadata))
    if not rows:
        return 0
    try:
        os.makedirs(os.path.dirname(os.path.abspath(opt.spool)), exist_ok=True)
        fd = os.open(opt.spool, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        print('owed-events spool: ' + opt.spool + ': ' + str(exc), file=sys.stderr)
        return 4
    try:
        spool_lock(fd)
        spool_append(fd, b''.join(spool_line(r) for r in rows))
    except OSError as exc:
        print('owed-events spool: ' + opt.spool + ': ' + str(exc), file=sys.stderr)
        return 4
    finally:
        os.close(fd)
    return 0


def drain(owe, bucket, spool, project, chief, handover_root):
    """Move this project's spooled rows into the bucket's ledger; returns the spool_bad list."""
    if not (spool and project and handover_root):
        return []
    real_bucket, real_root = os.path.realpath(bucket), os.path.realpath(handover_root)
    if os.path.commonpath([real_bucket, real_root]) != real_root:
        return []
    try:
        fd = os.open(spool, os.O_RDWR)
    except FileNotFoundError:
        return []
    except OSError:
        return ['file']
    bad = []
    try:
        try:
            spool_lock(fd)
            lines = [(n, spool_row(line)) for n, line in spool_lines(spool_read(fd)) if line.strip()]
        except OSError:
            return ['file']
        ledger = {r['identity'] for r in json.loads(owe('list', '--all', '--json')) if r.get('identity')}
        claims = {}
        for _, row in lines:
            if row and row['kind'] == 'claim':
                claims.setdefault(row['identity'], []).append(row['bucket'])
        for n, row in lines:
            if row is None:
                bad.append(n)
                continue
            if row['kind'] == 'claim' or not row['key'].startswith(project + '-'):
                continue
            identity = row['identity']
            owner = next((b for b in claims.get(identity, []) if b == real_bucket or os.path.isdir(b)), None)
            if owner not in (None, real_bucket):
                continue
            if owner is None:
                try:
                    spool_append(fd, spool_line(dict(kind='claim', schema=1, ts=utc_stamp(), identity=identity,
                                                     bucket=real_bucket)))
                except OSError:
                    bad.append(n)
                    continue
                claims.setdefault(identity, []).append(real_bucket)
            if identity in ledger:
                continue
            if row['kind'] == 'owed':
                text, metadata = row['text'], row['metadata']
            else:
                merged = datetime.datetime.strptime(row['ts'], '%Y-%m-%dT%H:%M:%SZ').date()
                text = UNREAD_TEXT
                metadata = dict(actor='chief', due=str(merged - datetime.timedelta(days=1)), action='next-step')
            try:
                owe('add', '--chief', chief or 'chief', '--kind', 'step', '--key', row['key'],
                    '--text', '%s PR #%s: %s' % (row['key'], row['pr'], text), '--identity', identity,
                    '--metadata-stdin', metadata=metadata)
            except ValueError:
                bad.append(n)
                continue
            ledger.add(identity)
    finally:
        os.close(fd)
    return bad


def run(bucket, now, readiness, stale_seconds=14400, spool=None, project=None, chief=None, handover_root=None):
    def owe(*args, metadata=None):
        p = subprocess.run(['bash', str(HERE / 'owe.sh'), *args, '--bucket', bucket],
                           input=json.dumps(metadata) if metadata is not None else None,
                           text=True, capture_output=True)
        if p.returncode:
            raise ValueError('owed events: ' + p.stderr.strip())
        return p.stdout.strip()

    spool_bad = drain(owe, bucket, spool, project, chief, handover_root)
    rows = json.loads(owe('list', '--all', '--json'))
    by_identity = {r.get('identity'): r for r in rows if r.get('identity')}
    out = dict(stale_ids=[], stale_ticket_ids=[], stale_step_ids=[], invalid_ids=[], reminders=[], operator_digest=[], pending=[], summary='',
               spool_bad=spool_bad)
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


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ['spool']:
        return spool_main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--now', type=int, required=True)
    parser.add_argument('--stale-seconds', type=int, default=14400)
    parser.add_argument('--spool')
    parser.add_argument('--project')
    parser.add_argument('--chief')
    parser.add_argument('--handover-root')
    opt = parser.parse_args(argv)
    try:
        print(json.dumps(run(opt.bucket, opt.now, json.load(sys.stdin), opt.stale_seconds,
                             opt.spool, opt.project, opt.chief, opt.handover_root)))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
