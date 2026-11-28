#!/usr/bin/env bash
# judge-queue.sh — the one writer of the judge desk's request queue:
# <bucket>/judge-desk/judge-requests.jsonl and the snapshots under <bucket>/judge-desk/requests/.
#
#   judge-queue.sh scan   --bucket <dir> --since <iso>
#   judge-queue.sh replay <pr> <head> --base <sha> --record <path> --bucket <dir>
#
# scan reads every chief fleet manifest (<bucket>/*.fleet.json) changed since --since (a naive
# time is local), so a chief succession is followed, and each worker document they name,
# read-only. A document whose name holds -judge-desk- is skipped. For each Results bullet
# `- HH:MM … JUDGE-REQUEST <pr> <40 hex head> …` whose (pr, head) is not yet queued it writes
# requests/<pr>-<head7>.md, the document's text up to and including that bullet, then appends a
# request row and prints `QUEUED <pr> <head>`. requested_at is the latest local time with that
# HH:MM not after seen_at. The lane is the manifest row's: native, t3, or bus for any other.
# A manifest or document it cannot read prints `QUEUE? <path>`.
#
# replay appends a `lane: replay` row for a head the chief names, with its base and the chief-path
# verdict record, and a snapshot holding only pr, head and base. It refuses (rc 1) a head that
# `git cat-file -e` cannot resolve in the current checkout. A pair already queued is skipped.
#
# Every append holds flock on <bucket>/judge-desk/.lock; rows are appended, never edited.
# JUDGE_QUEUE_NOW (epoch seconds) stubs the clock, read only under HIMMEL_TEST_FIXTURE=1.
# Exit: 0 ok; 1 refused; 2 usage.
exec python3 -I - "$@" <<'PY'
import fcntl, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta

HEX40 = re.compile(r'[0-9a-f]{40}')
BULLET = re.compile(r'^- (\d\d):(\d\d)\b.*\bJUDGE-REQUEST (\d+) ([0-9a-f]{40})(?![0-9A-Za-z])')


def die(msg, rc=2):
    print('judge-queue: ' + msg, file=sys.stderr)
    sys.exit(rc)


def now():
    v = os.environ.get('JUDGE_QUEUE_NOW', '')
    if os.environ.get('HIMMEL_TEST_FIXTURE') == '1' and v.isdigit():
        return int(v)
    return time.time()


def opts(argv, names):
    out, rest = {}, []
    i = 0
    while i < len(argv):
        if argv[i] in names:
            if i + 1 >= len(argv) or not argv[i + 1]:
                die('%s needs a value' % argv[i])
            out[argv[i]] = argv[i + 1]
            i += 2
        elif argv[i].startswith('--'):
            die('unknown option %s' % argv[i])
        else:
            rest.append(argv[i])
            i += 1
    missing = [n for n in names if n not in out]
    if missing:
        die('missing %s' % ', '.join(missing))
    return out, rest


class Queue:
    def __init__(self, bucket):
        self.dir = os.path.join(bucket, 'judge-desk')
        self.rows = os.path.join(self.dir, 'judge-requests.jsonl')
        self.snaps = os.path.join(self.dir, 'requests')
        os.makedirs(self.snaps, exist_ok=True)
        self.lock = open(os.path.join(self.dir, '.lock'), 'a')
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.seen = set()
        try:
            with open(self.rows, encoding='utf-8') as f:
                for line in f:
                    try:
                        r = json.loads(line)
                        self.seen.add((int(r['pr']), r['head']))
                    except (ValueError, KeyError, TypeError):
                        continue
        except FileNotFoundError:
            pass

    def add(self, row, snapshot_text):
        key = (row['pr'], row['head'])
        if key in self.seen:
            return
        snap = os.path.join(self.snaps, '%d-%s.md' % (row['pr'], row['head'][:7]))
        tmp = snap + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(snapshot_text)
        os.replace(tmp, snap)
        row = dict(row, snapshot=snap)
        with open(self.rows, 'a', encoding='utf-8') as f:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')
        self.seen.add(key)
        print('QUEUED %d %s' % key)


def row_of(pr, head, lane, doc, hhmm, requested, seen, base):
    return {'schema': 1, 'kind': 'request', 'pr': pr, 'head': head, 'lane': lane, 'worker_doc': doc,
            'snapshot': None, 'bullet_hhmm': hhmm, 'requested_at': requested, 'seen_at': seen, 'base': base}


def requested_at(seen_local, hh, mm):
    t = seen_local.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if t > seen_local:
        t -= timedelta(days=1)
    return t.astimezone().isoformat(timespec='seconds')


def scan(argv):
    o, rest = opts(argv, ('--bucket', '--since'))
    if rest:
        die('scan takes no positional argument')
    try:
        since = datetime.fromisoformat(o['--since'])
    except ValueError:
        die('--since %r is not an ISO time' % o['--since'])
    since_ts = (since if since.tzinfo else since.astimezone()).timestamp()
    bucket = o['--bucket']
    ts = now()
    seen_local = datetime.fromtimestamp(ts)
    seen_iso = seen_local.astimezone().isoformat(timespec='seconds')
    q = Queue(bucket)
    unreadable = set()

    def queue_q(path):
        if path not in unreadable:
            unreadable.add(path)
            print('QUEUE? %s' % path)
    for name in sorted(os.listdir(bucket)):
        if not name.endswith('.fleet.json'):
            continue
        man = os.path.join(bucket, name)
        try:
            if os.path.getmtime(man) < since_ts:
                continue
            with open(man, encoding='utf-8') as f:
                workers = json.load(f).get('workers') or []
        except (OSError, ValueError, AttributeError):
            queue_q(man)
            continue
        for w in workers:
            doc = w.get('doc') if isinstance(w, dict) else None
            if not isinstance(doc, str) or not doc:
                continue
            if '-judge-desk-' in os.path.basename(doc):
                continue
            lane = w.get('lane')
            lane = lane if lane in ('native', 't3') else 'bus'
            try:
                with open(doc, encoding='utf-8') as f:
                    lines = f.read().splitlines(True)
            except (OSError, UnicodeError):
                queue_q(doc)
                continue
            in_results = False
            for i, line in enumerate(lines):
                if re.match(r'^## ', line):
                    in_results = bool(re.match(r'^## Results(\s|$)', line))
                    continue
                m = BULLET.match(line) if in_results else None
                if not m:
                    continue
                hh, mm, pr, head = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
                if hh > 23 or mm > 59:
                    continue
                q.add(row_of(pr, head, lane, doc, '%02d:%02d' % (hh, mm), requested_at(seen_local, hh, mm),
                             seen_iso, None), ''.join(lines[:i + 1]))


def replay(argv):
    o, rest = opts(argv, ('--base', '--record', '--bucket'))
    if len(rest) != 2:
        die('replay takes <pr> <head>')
    pr, head = rest
    if not pr.isdigit():
        die('pr %r must be a PR number' % pr)
    for k, v in (('head', head), ('base', o['--base'])):
        if not HEX40.fullmatch(v):
            die('%s %r must be a full 40-hex sha' % (k, v))
    r = subprocess.run(['git', 'cat-file', '-e', head + '^{commit}'], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        die('head %s does not resolve in this checkout (git cat-file -e); nothing queued' % head, 1)
    seen_iso = datetime.fromtimestamp(now()).astimezone().isoformat(timespec='seconds')
    row = row_of(int(pr), head, 'replay', None, None, seen_iso, seen_iso, o['--base'])
    row['record'] = o['--record']
    Queue(o['--bucket']).add(row, 'pr: %s\nhead: %s\nbase: %s\n' % (pr, head, o['--base']))


argv = sys.argv[1:]
if not argv or argv[0] not in ('scan', 'replay'):
    die('usage: judge-queue.sh scan --bucket <dir> --since <iso> | replay <pr> <head> --base <sha> --record <path> --bucket <dir>')
(scan if argv[0] == 'scan' else replay)(argv[1:])
PY
