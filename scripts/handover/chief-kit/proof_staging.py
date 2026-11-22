"""The one owner of "which staging a ticket's proof needs before a read-only worker can run it".

needs(mirror_text, answers=(), unread=(), cli=None) -> [(name, who, words)], in NEEDS order, one entry per name.
Inputs: the DoD and Proof sections of the ticket's description (cut by `ticket-policy-cli.mjs --sections`), the
description's `Staging:` line, the next-step texts of the ticket's live partial-PR answers (every proof row of each answer's
owed_lines, whichever owner the answer selected; an answer whose owed_lines is missing or malformed is an unknown need), and `unread` reasons the
caller could not read an input (each is the need ('unknown', 'chief', <reason>), so a refusal is never skipped by a
failed read). `Staging: none` drops the needs found in the DoD and Proof text, and only those.
"""
import collections, importlib.util, json, os, re, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI = os.path.join(HERE, '..', '..', '..', 'marketplace', 'plugins', 'himmel-ops', 'scripts', 'ticket-policy-cli.mjs')
READER = os.path.join(HERE, '..', '..', 'lib', 'pr_remainder.py')

Need = collections.namedtuple('Need', 'name who pattern flags')
NEEDS = tuple(Need(*row) for row in (
    ('guest-credential', 'operator', r"\b(?:guest|operator|real|live|claude|station)\s+(?:\w+\s+)?credentials?\b|\bcredentials?\s+on\s+(?:the|a)\s+(?:guest|vm|station)\b|\b(?:in|on)\s+a\s+(?:VM|guest)\s+session\b|\bauto-mode\s+claude\b", re.I),
    ('gh-token', 'operator', r'\b(?:gh|github|guest|personal access)[ -]token\b', re.I),
    ('gh-token', 'operator', r'\bPAT\b', 0),
    ('read-secrets', 'operator', r'\bREAD_SECRETS_OK\b|\bTOTP\b', 0),
    ('bypass-launch', 'operator', r'\bbypass(?:-queue)?[ -](?:launch\w*|go code)\b|\bguards[ -]off\b', re.I),
    ('go-code', 'operator', r'\bgo code\b', 0),
    ('throwaway-repo', 'operator', r'\bthrowaway\b[^.\n]{0,40}?\b(?:repo(?:sitory)?|PR|pull request)\b', re.I),
    ('operator-step', 'operator', r"\boperator(?:'s)?\s+(?:approv\w*|launch\w*|stag\w*|logs? in|login)\b", re.I),
    ('go-file', 'chief', r'\bGO file\b', 0),
))
_COMPILED = tuple((n, w, re.compile(p, f)) for n, w, p, f in NEEDS)
_ORDER = []
for _n, _w, _p, _f in NEEDS:
    if _n not in _ORDER:
        _ORDER.append(_n)
_WHO = {n: w for n, w, _p, _f in NEEDS}
STAGING_RE = re.compile(r'^[ \t]*Staging:[ \t]*(.*)$', re.M)


def description_of(mirror_text):
    m = re.search(r'^## Description\n(.*?)(?=^## |\Z)', mirror_text, re.M | re.S)
    return m.group(1).strip() if m else ''


def _scan(text, found):
    for name, who, rx in _COMPILED:
        if name in found:
            continue
        m = rx.search(text)
        if m:
            found[name] = (who, ' '.join(m.group(0).split())[:80])


def _sections(description, cli):
    with tempfile.TemporaryDirectory() as d:
        draft = os.path.join(d, 'draft.md')
        with open(draft, 'w', encoding='utf-8') as f:
            f.write(description + '\n')
        try:
            r = subprocess.run(['node', cli or DEFAULT_CLI, '--sections', 'DoD,Proof', '--draft', draft], capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                return None
            got = json.loads(r.stdout)
            return '\n'.join(str(got.get(k, '')) for k in ('DoD', 'Proof'))
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            return None


def _live_answers(answers):
    spec = importlib.util.spec_from_file_location('pr_remainder', READER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.live_answers(list(answers))


def needs(mirror_text, answers=(), unread=(), cli=None):
    unread = list(unread)
    description = description_of(mirror_text)
    staging = [t.strip() for line in STAGING_RE.findall(description) for t in line.split(',') if t.strip()]
    bare = STAGING_RE.sub('', description)
    text_found = {}
    sec = _sections(bare, cli)
    if sec is None:
        unread.append('ticket-policy sections unreadable')
    else:
        _scan(sec, text_found)
    if 'none' in (t.lower() for t in staging):
        text_found = {}
    found = dict(text_found)
    for t in staging:
        if t.lower() == 'none':
            continue
        if t in _WHO:
            found.setdefault(t, (_WHO[t], 'Staging: ' + t))
    live = _live_answers(answers)
    steps = []
    latest = [a for a in live if a['kind'] == 'remaining']
    if latest and latest[-1].get('nowrite'):
        steps.append(latest[-1]['text'])
    for a in live:
        steps.extend(a.get('chief_owed') or [])
        if a.get('kind') == 'owed' and a.get('handed', [])[:1] == ['proof']:
            steps.append(a['text'])
        rows = a.get('owed_lines')
        if not isinstance(rows, list) or not all(isinstance(r, dict) and isinstance(r.get('who'), str) and isinstance(r.get('text'), str) for r in rows):
            why = 'owed units of %s unreadable' % ('PR #%s' % a['pr'] if a.get('pr') else 'a partial-PR answer')
            if why not in unread:
                unread.append(why)
            continue
        steps.extend(r['text'] for r in rows if r['who'] == 'proof')
    for s in steps:
        _scan(s, found)
    free = [t for t in staging if t.lower() != 'none' and t not in _WHO]
    if free:
        matched = found.get('operator-step', ('operator', ''))[1]
        found['operator-step'] = ('operator', '; '.join(([matched] if matched else []) + free))
    out = [(n, found[n][0], found[n][1]) for n in _ORDER if n in found]
    return out + [('unknown', 'chief', r) for r in unread]
