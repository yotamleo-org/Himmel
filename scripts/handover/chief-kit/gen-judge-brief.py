#!/usr/bin/env python3
"""gen-judge-brief.py — HIMMEL-3746. Fill docs/handover/judge-brief-template.md for one judge
session from a spec, so a judge dispatch is one call instead of the ad-hoc mk_j*.py script every
console rewrites. It NEVER launches: it writes the brief and prints its path and nonce.

  gen-judge-brief.py <spec.json> --console <session> --bucket <dir>
                     [--date YYYY-MM-DD] [--letter Z] [--handover-root <dir>]
                     [--scratch-root <dir>] [--template <file>]

spec.json keys. Required: qid (kebab/alnum, e.g. j2599a), ticket (the doc's key), question
(one line, verbatim), reason, prior (the Prior art line; a bare none or a <placeholder> is
refused, as brief-lint.sh refuses it), tier {category, reason} (design|unverified-finding|
tier-return|operator-ruling; the launcher refuses an opus/fable judge without the line).
Optional: pr + head (a 40-hex sha; the change under review), tickets (ticket keys), author_doc
(the leg's own handover doc), attack (list of lines of attack to try, NOT conclusions),
evidence (list of {item, for}), completion (default: the PR merge-question shape),
description, model (default claude-opus-5-5), do_not.

Blind, not thin (the template's first rule): the spec may carry the evidence and the attack
list but never a conclusion, so conclusion / verdict / disposition / recommendation keys
are refused.

The brief is the template's fenced block with each placeholder paragraph replaced, so the
boilerplate stays in ONE place. A template whose placeholder paragraph this script cannot
find exactly once is refused rather than guessed at.

Exit: 0 ok; 1 invalid spec, template drift or an existing brief; 2 usage.
"""
import argparse, json, os, re, secrets, sys
from datetime import date as _date

TIER_CATEGORIES = ('design', 'unverified-finding', 'tier-return', 'operator-ruling')
DEFAULT_MODEL = 'claude-opus-5-5'
REQUIRED = ['qid', 'ticket', 'question', 'reason', 'prior', 'tier']
KNOWN = set(REQUIRED) | {'pr', 'head', 'tickets', 'author_doc', 'attack', 'evidence', 'completion',
                         'description', 'model', 'do_not'}
BLIND = ('conclusion', 'verdict', 'disposition', 'recommendation', 'recommended', 'finding_status')
DEFAULT_DO_NOT = ('everything except reading and writing your verdict file. A judge that finds it needs '
                  'to edit a file to answer its question has been asked an implementation question: '
                  'say so in the verdict rather than editing.')


def die(msg, rc=1):
    print('gen-judge-brief: ' + msg, file=sys.stderr)
    sys.exit(rc)


def tier_gate(model):
    m = re.match(r'^(?:anthropic/)?claude-(opus|fable)-', model or '')
    return m.group(1) if m else None


def validate(s):
    if not isinstance(s, dict):
        die('the spec must be a JSON object')
    for k in BLIND:
        if k in s:
            die('spec key %r refused: the judge is blind, hand it the evidence and the question, never a %s' % (k, k))
    unknown = sorted(set(s) - KNOWN)
    if unknown:
        die('unknown spec key(s): %s' % ', '.join(unknown))
    missing = [k for k in REQUIRED if not s.get(k)]
    if missing:
        die('spec missing: %s' % ', '.join(missing))
    # the label slot of the handover-token grammar (docs/internals/handover-token-grammar.md)
    if not isinstance(s['qid'], str) or not re.fullmatch(r'(?:[A-Za-z]{1,4}[0-9]{1,5}[A-Za-z]{0,2}|[A-Z]{2,8}-[0-9]{1,6})(?:_[a-z]{1,8})?', s['qid']):
        die('qid %r must be up to 4 letters, 1-5 digits and up to 2 letters (j2599a) or a ticket key (HIMMEL-4999), optionally ending _<up to 8 lower-case letters>' % (s['qid'],))
    if s.get('tickets') is not None and not isinstance(s['tickets'], list):
        die('tickets must be a list of ticket keys')
    keys = [s['ticket']] + list(s.get('tickets') or [])
    if not all(isinstance(k, str) and re.fullmatch(r'[A-Z]+-\d+', k) for k in keys):
        die('ticket keys must look like HIMMEL-123 (got %r)' % (keys,))
    for k in ('question', 'reason', 'prior'):
        if not isinstance(s[k], str) or not s[k].strip():
            die('%s must be non-blank text' % k)
    if '\n' in s['question'] or '\r' in s['question']:
        die('question must be one line (verbatim, one line)')
    if re.search(r'<[^<>\s][^<>]*>', s['prior']) or re.sub(r'[\W_]+$', '', s['prior'].strip().lower()) == 'none':
        die('prior art must be filled (a bare none or a <placeholder> fails brief-lint): use none found (<the query you ran>)')
    if s.get('head') is not None and not re.fullmatch(r'[0-9a-f]{40}', str(s['head'])):
        die('head must be a full 40-hex sha')
    if s.get('pr') is not None and not str(s['pr']).isdigit():
        die('pr must be a PR number')
    if bool(s.get('pr')) != bool(s.get('head')):
        die('pr and head go together (the judge reads the PR at that head)')
    for k in ('description', 'completion', 'do_not', 'model'):
        if s.get(k) is not None and (not isinstance(s[k], str) or not s[k].strip()):
            die('%s must be non-blank text when given' % k)
    t = s['tier']
    if not isinstance(t, dict) or t.get('category') not in TIER_CATEGORIES:
        die('tier.category must be one of %s' % '|'.join(TIER_CATEGORIES))
    r = t.get('reason')
    if not isinstance(r, str) or not r.strip() or '\n' in r or '\r' in r:
        die('tier.reason must be non-blank single-line text')
    if not tier_gate(s.get('model') or DEFAULT_MODEL):
        die('model %r is not an opus or fable model; a judge launches at one of them' % (s.get('model'),))
    ev = s['evidence'] if s.get('evidence') is not None else []
    if not isinstance(ev, list) or not all(isinstance(e, dict) and isinstance(e.get('item'), str) and e['item'].strip()
                                  and isinstance(e.get('for'), str) and e['for'].strip() for e in ev):
        die('evidence must be a list of {item, for} with non-blank text')
    at = s['attack'] if s.get('attack') is not None else []
    if not isinstance(at, list) or not all(isinstance(a, str) and a.strip() for a in at):
        die('attack must be a list of non-blank lines')


def block_of(template):
    m = re.search(r'^```markdown\n(.*?)\n```$', template, re.S | re.M)
    if not m:
        die('template has no fenced markdown block: %s' % 'docs/handover/judge-brief-template.md')
    return m.group(1)


def sub_para(paras, prefix, new):
    hits = [i for i, p in enumerate(paras) if p.startswith(prefix)]
    if len(hits) != 1:
        die('template drift: expected one paragraph starting %r, found %d' % (prefix, len(hits)))
    paras[hits[0]] = new


def evidence_text(s):
    n = 0
    out = []

    def item(text):
        nonlocal n
        n += 1
        out.append('%d. %s' % (n, text))
    if s.get('pr'):
        item('PR %s at head `%s`: the change under review. Read the diff at that head, not main '
             '(check `gh pr view %s --json headRefOid` equals the head and `git cat-file -t %s` prints `commit`, '
             'a bare `git fetch origin` if not, never a refspec fetch; then `git diff origin/main...%s`, '
             '`git show %s:<path>` or `git archive %s` for a tree; '
             'never FETCH_HEAD, which a parallel judge\'s fetch overwrites).'
             % (s['pr'], s['head'], s['pr'], s['head'], s['head'], s['head'], s['head']))
    for k in [s['ticket']] + [t for t in (s.get('tickets') or []) if t != s['ticket']]:
        item('Ticket %s: the ask(s) the change claims to meet '
             '(`JIRA_PROJECT_KEY=%s node <primary checkout>/scripts/jira/dist/index.js get %s`, comments included).'
             % (k, k.split('-')[0], k))
    if s.get('author_doc'):
        item('Author handover doc `%s`: the leg\'s own account of what it did; read it for its claims, '
             'then check them against the diff.' % s['author_doc'])
    for e in s.get('evidence') or []:
        item('`%s`: %s.' % (e['item'], e['for'].rstrip('.')))
    text = '\n'.join(out)
    text += ('\n\nWhat you may gather for yourself: a cold read of any file the items above name, a tree walk '
             'for a disputed finding. Put every scratch file under `%s`.' % s['_scratch'])
    if s.get('attack'):
        text += '\n\n**Attack list** (lines to try against the change; a line of attack, not a finding):\n'
        text += '\n'.join('- A%d. %s' % (i + 1, a) for i, a in enumerate(s['attack']))
    return text


def render(s, a, template):
    paras = block_of(template).split('\n\n')
    model = s.get('model') or DEFAULT_MODEL
    gate = tier_gate(model)
    desc = s.get('description') or ('Rule on %s: %s' % (s['ticket'], s['question']))
    desc = ' '.join(desc.split())
    sub_para(paras, '---\nresume_cwd:', '---\nresume_cwd: %s\ndescription: %s\ntemplate_version: 1\n---' % (s['_scratch'], json.dumps(desc, ensure_ascii=False)))
    sub_para(paras, '# <TICKET> —', '# %s — judge verdict %s — %s, %s' % (s['ticket'], s['qid'], s['question'], a.date))
    judge_at = [i for i, p in enumerate(paras) if p.startswith('> **You are the judge for')]
    if len(judge_at) != 1:
        die('template drift: expected one paragraph starting %r, found %d' % ('> **You are the judge for', len(judge_at)))
    sub_para(paras, '> **You are the judge for', paras[judge_at[0]].replace('<model>', model))
    sub_para(paras, '> **Tier:**', '> **Tier:** %s — %s: %s' % (gate, s['tier']['category'], s['tier']['reason']))
    sub_para(paras, '> **The question (verbatim', '> **The question (verbatim, one line):** %s' % s['question'])
    sub_para(paras, '> **Reason (why', '> **Reason (why this needs a judge, not the console\'s own read):** %s' % s['reason'])
    sub_para(paras, '> **Prior art (required):**', '> **Prior art (required):** %s' % s['prior'])
    sub_para(paras, '<Every file, diff,', evidence_text(s))
    default_completion = ('GO or NO-GO on head `%s`, one paragraph of reason citing at least one Evidence item by number; '
                          'a finding you cannot confirm is NO-GO, and each rejected reading gets one sentence of why not.'
                          % (s.get('head') or '<the head under review>')) if s.get('pr') else None
    completion = s.get('completion') or default_completion
    if not completion:
        die('completion is required when the spec carries no PR')
    sub_para(paras, '> **Completion condition:**', '> **Completion condition:** %s' % completion)
    sub_para(paras, '> **Do not:**', '> **Do not:** %s' % (s.get('do_not') or DEFAULT_DO_NOT))
    text = '\n\n'.join(paras)
    text = text.replace('<console session name>', a.console)
    text = text.replace('<console letter>-<qid>-<hex>', s['_nonce'])
    text = text.replace('<HANDOVER_DIR>', a.handover_root)
    text = text.replace('<qid>', s['qid'])
    left = re.findall(r'<(?:console letter|console session name|TICKET|model|category|free text|HANDOVER_DIR|date|one-line question)[^>]*>', text)
    if left:
        die('template drift: unfilled placeholder(s) left: %s' % ', '.join(sorted(set(left))))
    return text + '\n'


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('spec')
    ap.add_argument('--console', required=True)
    ap.add_argument('--bucket', required=True)
    ap.add_argument('--date', default=_date.today().isoformat())
    ap.add_argument('--letter', default=None)
    ap.add_argument('--handover-root', default=os.environ.get('HANDOVER_DIR', ''))
    ap.add_argument('--scratch-root', default=os.path.expanduser('~/.cache/himmel/verdicts'))
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--template', default=os.path.join(here, '..', '..', '..', 'docs', 'handover', 'judge-brief-template.md'))
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    if not re.fullmatch(r'\d{4}-\d\d-\d\d', a.date):
        die('--date must be YYYY-MM-DD', 2)
    if not a.handover_root:
        die('--handover-root (or HANDOVER_DIR) is required', 2)
    try:
        spec = json.load(open(a.spec))
    except (OSError, ValueError) as e:
        die('cannot read %s: %s' % (a.spec, e), 2)
    try:
        template = open(a.template).read()
    except OSError as e:
        die('cannot read the template: %s' % e, 2)
    validate(spec)
    letter = a.letter
    if letter is None:
        m = re.search(r'\d{4}-\d\d-\d\d([A-Z]+)-', a.console)
        letter = m.group(1) if m else 'X'
    if not re.fullmatch(r'[A-Z]{1,3}', letter):
        die('console letter %r must be 1-3 upper-case letters (the vault token grammar); pass --letter' % (letter,))
    spec['_nonce'] = '%s-%s-%s' % (letter, spec['qid'], secrets.token_hex(4))
    scratch = os.path.abspath(os.path.join(a.scratch_root, spec['qid'], 'scratch'))
    root = os.path.realpath(a.handover_root)
    if os.path.realpath(scratch) == root or os.path.realpath(scratch).startswith(root + os.sep):
        die('the scratch dir %s is under the handover root; headed-arm-leg.sh refuses it (exit 15)' % scratch)
    spec['_scratch'] = scratch
    text = render(spec, a, template)
    doc = os.path.join(a.bucket, '%s-judge-%s-%s-RESUME.md' % (spec['ticket'], spec['qid'], a.date))
    os.makedirs(a.bucket, exist_ok=True)
    os.makedirs(scratch, exist_ok=True)
    try:
        f = open(doc, 'x')
    except FileExistsError:
        die('%s already exists; refusing to overwrite a judge brief' % doc)
    with f:
        f.write(text)
    print('%s %s %s' % (spec['qid'], spec['_nonce'], doc))


if __name__ == '__main__':
    main()
