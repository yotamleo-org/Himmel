#!/usr/bin/env python3
"""/himmel-report: turn a wrong refusal or review point into a redacted issue draft and a local lesson.

usage: himmel_report.py draft --text-file F|- [--kind refusal|review] [--class SLUG] [--note TEXT]
       himmel_report.py send ID [--yes]

draft  redacts the text, writes ~/.himmel/reports/<id>.md (the issue draft), a lesson class in
       ~/.himmel/known-findings.local.json (KNOWN_FINDINGS_FILE accepts it), and one row in
       ~/.himmel/state/user-reports.jsonl (friction.py counts it as a user-reported over-deny).
       Nothing leaves the machine.
send   files the draft on the himmel issue tracker with `gh issue create` and only with --yes;
       without it exits 4 and sends nothing.

Exit: 0 ok, 2 bad input, 3 the redacted draft still trips gitleaks (send also refuses when gitleaks is not
installed), 4 send without --yes.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'scripts', 'eval', 'friction'))
import friction  # noqa: E402

ISSUE_REPO = 'yotamleo-org/Himmel'  # env-literal-ok: the public himmel issue tracker is the report target by design
MAX_TEXT = 2000

# ponytail: mirrors scrub_secrets() in the CR ledger writer plus friction's token mask; one definition in
# scripts/lib once a trust-reviewed change may touch that writer. The gitleaks pass below is the backstop.
SECRET_RES = [
    (re.compile(r'[0-9]{8,10}\s*:\s*[A-Za-z0-9_-]{35}'), '[REDACTED]'),
    (re.compile(r'(Bearer|bearer)\s+[A-Za-z0-9._-]{16,}'), r'\1 [REDACTED]'),
    (re.compile(r'sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}'), '[REDACTED]'),
    (re.compile(r'AKIA[0-9A-Z]{16}'), '[REDACTED]'),
    (re.compile(r'([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)\s*[:=]\s*[A-Za-z0-9._-]{12,}'), r'\1=[REDACTED]'),
    (friction.TOKEN_RE, '[REDACTED]'),
    (re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), '[REDACTED]'),
]


def home():
    return os.path.expanduser('~')


def state_file():
    return os.environ.get('HIMMEL_USER_REPORTS') or os.path.join(home(), '.himmel', 'state', 'user-reports.jsonl')


def reports_dir():
    return os.path.join(home(), '.himmel', 'reports')


def lessons_file():
    return os.path.join(home(), '.himmel', 'known-findings.local.json')


def redact(text):
    for rx, sub in SECRET_RES:
        text = rx.sub(sub, text)
    h = home()
    if len(h) > 1:
        text = text.replace(h, '~')
    text = re.sub(r'/(?:home|Users)/[^/\s]+', '~', text)
    return text


def leak_check(text):
    """True when gitleaks (the repo's gate) finds nothing in text, False on a hit, None when gitleaks is missing."""
    gl = shutil.which(os.environ.get('HIMMEL_REPORT_GITLEAKS') or 'gitleaks')
    if not gl:
        return None
    with tempfile.TemporaryDirectory(prefix='himmel-report-') as d:
        with open(os.path.join(d, 'draft.md'), 'w') as f:
            f.write(text)
        cmd = [gl, 'detect', '--no-git', '--no-banner', '--source', d]
        cfg = os.path.join(REPO, '.gitleaks.toml')
        if os.path.isfile(cfg):
            cmd += ['-c', cfg]
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def fence_for(text):
    longest = max([len(m) for m in re.findall(r'`+', text)] + [2])
    return '`' * (longest + 1)


def build_draft(rid, kind, source, cls, auto_verdict, text, note):
    try:
        version = open(os.path.join(REPO, 'VERSION')).read().strip()
    except OSError:
        version = 'unknown'
    fence = fence_for(text)
    what = 'refusal' if kind == 'refusal' else 'review point'
    return '\n'.join([
        '# [user-report] wrong %s: %s / %s' % (what, source, cls), '',
        'Filed from `/himmel-report`. The text below was redacted locally and read by the reporter before sending.', '',
        '- kind: %s' % kind, '- source: %s' % source, '- class: %s' % cls,
        '- himmel verdict at the time: %s' % auto_verdict, '- himmel version: %s' % version,
        '- report id: %s' % rid, '',
        '## What I saw', '', fence + 'text', text, fence, '',
        '## What I expected', '', note or '(reporter: say what should have happened)', ''])


def load_lessons(path):
    if not os.path.exists(path):
        return {'_schema': 'known-findings v1, user-local lessons written by /himmel-report (HIMMEL-7131); '
                           'load with KNOWN_FINDINGS_FILE=<this file> known-findings.sh --list', 'classes': []}
    with open(path) as f:
        return json.load(f)


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = '%s.tmp.%d' % (path, os.getpid())
    with open(tmp, 'w') as f:
        f.write(text)
    os.replace(tmp, path)


def add_lesson(kind, source, cls, evidence, text):
    path = lessons_file()
    db = load_lessons(path)
    lid = 'user-' + cls
    sample = re.sub(r'\s+', ' ', text)[:200]
    if kind == 'refusal':
        canonical = ('You reported this refusal as wrong (%s / %s: %s). Before working around it, re-check the '
                     'command shape; if it still trips the same guard, say so instead of retrying. Sample: %s'
                     % (source, cls, evidence, sample))
    else:
        canonical = ('You reported this review point as wrong (%s). Do not act on it again unless the code '
                     'regressed against the rule it claims. Sample: %s' % (cls, sample))
    for c in db['classes']:
        if c.get('id') == lid:
            c.setdefault('evidence', {})['user_reports'] = c.get('evidence', {}).get('user_reports', 0) + 1
            break
    else:
        db['classes'].append({
            'id': lid, 'kind': 'rebuttal', 'rung': 'human', 'title': 'user-reported wrong %s: %s' % (kind, cls),
            'source': 'himmel-report', 'globs': ['**'], 'detector': None, 'canonical': canonical,
            'coverage': 'reported with /himmel-report; no automated detector', 'prompt': False,
            'evidence': {'user_reports': 1}})
    write_atomic(path, json.dumps(db, indent=2) + '\n')


def already_reported(rid):
    """A report is done once its ledger row exists; the row is written last, so a failed lesson write retries."""
    try:
        with open(state_file()) as f:
            return any('"id": "%s"' % rid in line for line in f)
    except OSError:
        return False


def cmd_draft(a):
    raw = sys.stdin.read() if a.text_file == '-' else open(a.text_file).read()
    if not raw.strip():
        print('himmel-report: empty input, nothing to report.', file=sys.stderr)
        return 2
    text = redact(raw).strip()
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT] + ' ...[truncated]'
    kind = a.kind
    hit = friction.classify(text) if kind == 'refusal' else None
    if hit:
        source, cls, auto_verdict, evidence = hit
    elif kind == 'refusal':
        source, cls, auto_verdict, evidence = 'user-reported', 'unclassified', 'unclear', 'not matched by friction.py'
    else:
        source, cls, auto_verdict, evidence = 'review-point', 'unclassified-review', 'unclear', 'a review finding'
    cls = re.sub(r'[^a-z0-9]+', '-', (a.cls or cls).lower()).strip('-') or 'unclassified'
    rid = hashlib.sha1(('%s|%s|%s|%s' % (kind, source, cls, text)).encode()).hexdigest()[:10]
    note = redact(a.note or '').strip()
    draft = build_draft(rid, kind, source, cls, auto_verdict, text, note)
    path = os.path.join(reports_dir(), rid + '.md')
    clean = leak_check(draft)
    if clean is False:
        print('himmel-report: gitleaks flagged the redacted draft; nothing was written. Remove the secret and retry.',
              file=sys.stderr)
        return 3
    if clean is None:
        print('himmel-report: gitleaks not found; redaction is pattern-only and send will refuse until it is installed.',
              file=sys.stderr)
    os.makedirs(os.path.dirname(state_file()), exist_ok=True)
    os.makedirs(os.path.join(home(), '.himmel'), exist_ok=True)
    with open(os.path.join(home(), '.himmel', '.report.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if already_reported(rid):
            print('report-id: %s' % rid)
            print(open(path).read() if os.path.exists(path) else draft)
            print('already reported: %s; nothing new was written.' % rid)
        else:
            write_atomic(path, draft)
            add_lesson(kind, source, cls, evidence, text)
            row = {'ts': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'id': rid, 'kind': kind,
                   'source': source, 'class': cls, 'verdict': 'user-over-deny', 'auto_verdict': auto_verdict}
            with open(state_file(), 'a') as f:
                f.write(json.dumps(row) + '\n')
            print('report-id: %s' % rid)
            print(draft)
            print('local lesson: %s (load with KNOWN_FINDINGS_FILE=%s)' % ('user-' + cls, lessons_file()))
    if source.startswith('hook:'):
        print('guard-override suggestion (not applied): %s fired on this shape. If it is wrong for your setup, set that '
              "hook's off switch as a session env var in the launching shell; docs/internals/enforcement.md lists the "
              'switch each hook documents.' % source[5:])
    print('NOT SENT. Show this draft to the user; send only after an explicit yes: '
          'himmel_report.py send %s --yes' % rid)
    return 0


def cmd_send(a):
    path = os.path.join(reports_dir(), re.sub(r'[^A-Za-z0-9]', '', a.id) + '.md')
    if not os.path.isfile(path):
        print('himmel-report: no draft with id %s' % a.id, file=sys.stderr)
        return 2
    if not a.yes:
        print('not sent: send needs an explicit yes from the user (re-run with --yes).')
        return 4
    body = open(path).read()
    if not leak_check(body):
        print('himmel-report: gitleaks flagged the draft or is not installed; not sent.', file=sys.stderr)
        return 3
    title = body.splitlines()[0].lstrip('# ').strip()
    gh = os.environ.get('HIMMEL_REPORT_GH') or 'gh'
    return subprocess.run([gh, 'issue', 'create', '-R', ISSUE_REPO, '--title', title, '--body-file', path]).returncode


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('draft')
    d.add_argument('--text-file', required=True)
    d.add_argument('--kind', choices=('refusal', 'review'), default='refusal')
    d.add_argument('--class', dest='cls')
    d.add_argument('--note')
    s = sub.add_parser('send')
    s.add_argument('id')
    s.add_argument('--yes', action='store_true')
    a = ap.parse_args(argv)
    return cmd_draft(a) if a.cmd == 'draft' else cmd_send(a)


if __name__ == '__main__':
    sys.exit(main())
