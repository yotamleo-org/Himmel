#!/usr/bin/env bash
# file-slices.sh: files a signed plan's `## S<id>:` sections as seven-section slice tickets under a parent.
# A dry run by default (it only reads Jira); --apply files the NEW slices once, in dependency order.
#
# USAGE  file-slices.sh <plan.md> --parent KEY [--skip ID,...] [--proposed-version V] [--apply] [--jira-cli PATH]
#   --parent KEY          an Epic gets the slices as children (--parent); any other type as --follow-up-of
#   --skip ID,...         slice ids that get no ticket (shipped or dispatched under the parent)
#   --proposed-version V  placement for every NEW slice; an Epic parent without it is refused
#   --apply               file the NEW slices; without it nothing is written
#   --jira-cli PATH       the Jira CLI entry (default: the primary checkout's scripts/jira/dist/index.js)
#
# Output: a header (the parent, its Sector and the `release spec-check` line, then spec-check's stderr word for
# word), one SKIP|FILED|NEW|REFUSED row per section in plan order with its NOTE lines and, for every row but
# SKIP, its body between `--- body <id> ---` and `--- end <id> ---`, then `# counts: …`. With --apply:
# CREATED/LINKED lines in filing order and one `NEXT chief:` re-sign template when anything was created.
#
# Exit 0 ok | 1 refused, nothing written | 2 usage | 3 stopped after a write (FILED-SO-FAR, LINK-OWED, OUTCOME-UNKNOWN)
#
# A section is SKIP (--skip), else FILED (exactly one title under the parent ends ` (<id>)`), else NEW when its
# Depends on, Writes, RED and Done parts parse and its body passes ticket-policy-cli.mjs, else REFUSED. Writes
# paths come from holds.files_in (the dispatcher's own path pattern), so the body's one `Writes:` line is the
# scope next-dispatchable.sh reads. The signed design is the file-slices spec under the state repo's specs/designs/.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common="" # swallow-ok: with no git dir the default CLI is unknown and the script asks for --jira-cli
default_cli=""
[ -n "$common" ] && default_cli="${common%/.git}/scripts/jira/dist/index.js"

python3 -I - "$HERE" "$default_cli" "$@" <<'PY'
import atexit, json, os, re, shutil, subprocess, sys, tempfile

sys.stdout.reconfigure(encoding='utf-8')
HERE, DEFAULT_CLI = sys.argv[1], sys.argv[2]
REPO = os.path.realpath(os.path.join(HERE, '..', '..', '..'))
POLICY = os.path.join(REPO, 'marketplace', 'plugins', 'himmel-ops', 'scripts', 'ticket-policy-cli.mjs')
sys.path.insert(0, HERE)
import holds  # noqa: E402  the one parser of a write path (FILE_RE, files_in)

USAGE = 'usage: file-slices.sh <plan.md> --parent KEY [--skip ID,...] [--proposed-version V] [--apply] [--jira-cli PATH]'
KEY_RE = r'[A-Z][A-Z0-9]*-\d+'


def usage(msg=''):
    if msg:
        print('file-slices: ' + msg, file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


args = sys.argv[3:]
plan = parent = version = None
skip = []
apply = False
cli = DEFAULT_CLI
i = 0
while i < len(args):
    a = args[i]
    if a in ('--parent', '--skip', '--proposed-version', '--jira-cli'):
        if i + 1 >= len(args):
            usage(a + ' needs a value')
        v = args[i + 1]
        i += 2
        if a == '--parent':
            parent = v
        elif a == '--skip':
            skip = [s.strip() for s in v.split(',') if s.strip()]
        elif a == '--proposed-version':
            version = v
        else:
            cli = v
    elif a == '--apply':
        apply = True
        i += 1
    elif a.startswith('-'):
        usage('unknown flag ' + a)
    elif plan is None:
        plan = a
        i += 1
    else:
        usage('one plan only')
if not plan or not parent:
    usage()
if not re.fullmatch(KEY_RE, parent):
    usage('--parent takes a ticket key, not ' + parent)
if not cli:
    usage('no default Jira CLI outside a git checkout: pass --jira-cli')
try:
    text = open(plan, encoding='utf-8').read()
except OSError as e:
    usage('cannot read the plan: %s' % e)
plan_abs = os.path.abspath(plan)
plan_file = os.path.basename(plan)

TMP = tempfile.mkdtemp(prefix='file-slices.')
atexit.register(shutil.rmtree, TMP, True)


def refuse_run(msg):
    print('REFUSED: ' + msg)
    sys.exit(1)


# ---- the plan: front matter, Goal, Spec and the sections (fenced blocks are body) -------------------------
lines = text.split('\n')
revision = None
start = 0
if lines and lines[0].strip() == '---':
    for j in range(1, len(lines)):
        if lines[j].strip() == '---':
            start = j + 1
            break
        m = re.match(r'revision:\s*(\S+)', lines[j])
        if m:
            revision = m.group(1)


def para(ls, k, first):
    out = [first.strip()] if first.strip() else []
    for line in ls[k + 1:]:
        if not line.strip():
            break
        out.append(line.strip())
    return ' '.join(out)


FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})')
SEC = re.compile(r'^## (S\d+[a-z]*(?:-\d+)?):\s*(.*)$')
STEP = re.compile(r'^## (M\d+):')
goal = spec_line = None
sections, step_ids = [], set()
fence, cur = None, None
for k in range(start, len(lines)):
    line = lines[k]
    fm = FENCE.match(line)
    if fence:
        if fm and fm.group(1)[0] == fence[0] and len(fm.group(1)) >= len(fence) and not line.strip()[len(fm.group(1)):].strip():
            fence = None
        if cur is not None:
            cur['lines'].append('')
        continue
    if fm:
        fence = fm.group(1)
        if cur is not None:
            cur['lines'].append('')
        continue
    if re.match(r'^#{1,2}\s', line):
        cur = None
        m = SEC.match(line)
        if m:
            cur = {'id': m.group(1), 'heading': m.group(2).strip(), 'lines': []}
            sections.append(cur)
        elif STEP.match(line):
            step_ids.add(STEP.match(line).group(1))
        continue
    if cur is not None:
        cur['lines'].append(line)
    elif goal is None and line.startswith('**Goal:**'):
        goal = para(lines, k, line[len('**Goal:**'):])
    elif spec_line is None and line.startswith('**Spec:**'):
        spec_line = line

if goal is None:
    refuse_run('no **Goal:** line')
if not sections:
    refuse_run('no ## S<id>: section')
slice_ids = [s['id'] for s in sections]
dups = sorted({x for x in slice_ids if slice_ids.count(x) > 1}, key=slice_ids.index)
if dups:
    refuse_run('; '.join('two ## %s: sections' % x for x in dups))


def strip_end(s):
    return re.sub(r'[\s.;:]+$', '', s)


def parse(sec):
    ls = sec['lines']

    def find(name):
        for k, line in enumerate(ls):
            if line.startswith(name + ':'):
                return k
        return None

    def bullets(k):
        out = []
        first = ls[k].split(':', 1)[1].strip()
        if first:
            out.append(first)
        for line in ls[k + 1:]:
            if not line.strip():
                break
            m = re.match(r'^\s*[-*+]\s+(.*)$', line)
            if m:
                out.append(m.group(1).strip())
            elif out:
                out[-1] += ' ' + line.strip()
        return out

    sec['notes'], sec['paths'], sec['error'] = [], [], None
    errors = []
    k = find('Depends on')
    sec['dep'] = None
    if k is None:
        errors.append('no Depends on: line')
    else:
        p = para(ls, k, ls[k].split(':', 1)[1])
        m = re.search(r'\.(\s|$)', p)
        sec['dep'] = (p[:m.start()] if m else p).strip()
    k = find('Writes')
    if k is None:
        errors.append('no Writes: line')
    else:
        for b in bullets(k):
            got = []
            for tok in re.findall(r'`([^`]+)`', b):
                ps = holds.files_in(tok, REPO)
                if not ps:
                    sec['notes'].append('not a repo path: ' + tok)
                got += ps
            if not got:
                sec['notes'].append('Writes bullet with no path: ' + b)
            for p in got:
                if p not in sec['paths']:
                    sec['paths'].append(p)
        if not sec['paths']:
            errors.append('no himmel write path')
    k = find('RED')
    sec['red'] = sec['red_test'] = None
    if k is None:
        errors.append('no RED: line')
    else:
        sec['red'] = strip_end(para(ls, k, ls[k].split(':', 1)[1]))
        toks = re.findall(r'`([^`]+)`', sec['red'])
        if toks:
            sec['red_test'] = '`%s`' % toks[0]
        else:
            errors.append('RED: line names no test')
    k = find('Done')
    sec['done'] = bullets(k) if k is not None else []
    if not sec['done']:
        errors.append('no Done: bullet')
    sec['error'] = errors[0] if errors else None


for s in sections:
    parse(s)

# ---- Jira reads: the parent, the prior search, the signature ----------------------------------------------


def jira(*a):
    return subprocess.run(['node', cli] + list(a), capture_output=True, text=True)


def last_line(s):
    ls = [x for x in s.strip().splitlines() if x.strip()]
    return ls[-1] if ls else ''


r = jira('get', parent)
if r.returncode != 0:
    refuse_run('cannot read parent %s: %s' % (parent, last_line(r.stderr) or 'exit %d' % r.returncode))
head = r.stdout.splitlines()[0].split('\t') if r.stdout.strip() else []
ptype = head[1] if len(head) > 1 else ''
sectors = re.findall(r'^Sector:\s*(.+?)\s*$', r.stdout, re.M)
if not ptype or not sectors:
    refuse_run('parent %s has no %s in its get output' % (parent, 'type' if not ptype else 'Sector'))
sector = sectors[-1]
is_epic = ptype == 'Epic'
if is_epic and not version:
    refuse_run('parent %s is an Epic: pass --proposed-version' % parent)

jql = ('parent = %s' if is_epic else 'issue in linkedIssues(%s)') % parent
r = jira('list', '--jql', jql, '--limit', '500')
if r.returncode != 0:
    refuse_run('the search failed: %s' % (last_line(r.stderr) or 'exit %d' % r.returncode))
rows = [x.split('\t') for x in r.stdout.splitlines() if re.match(KEY_RE + '\t', x)]
if len(rows) >= 500:
    refuse_run('the search returned %d rows; the list may be cut' % len(rows))

r = jira('release', 'spec-check', parent)
sig_line = r.stdout.strip().splitlines()[0] if r.stdout.strip() else '(no line, exit %d)' % r.returncode
sig = re.match(r'^SPEC ok (\S+) (\S+)(?: (\S+))?', sig_line) if r.returncode == 0 else None
spec_path = sig.group(2) if sig else ''
oid = (sig.group(3) or '') if sig else ''
signed = bool(sig and sig.group(1) == parent and spec_line and os.path.basename(spec_path) in spec_line)

print('file-slices: plan %s parent %s (%s, Sector "%s")%s signed: %s' % (
    plan, parent, ptype, sector, ' proposed-version %s' % version if version else '', sig_line))
for w in r.stderr.splitlines():
    if w.strip():
        print(w)
if revision is None:
    print('NOTE: plan has no revision')

filed = {}
bad = []
for sid in slice_ids:
    hits = [x[0] for x in rows if len(x) >= 4 and x[3].endswith(' (%s)' % sid)]
    if len(hits) > 1:
        bad.append('%s matches %s' % (sid, ' and '.join(hits)))
    elif hits:
        filed[sid] = hits[0]
for sid in skip:
    if sid in filed:
        bad.append('%s is filed as %s; drop it from --skip' % (sid, filed[sid]))
for b in bad:
    print('REFUSED: ' + b)
if bad:
    sys.exit(1)

# ---- decide each section: SKIP, FILED, parse, policy, NEW else REFUSED -------------------------------------
by_id = {s['id']: s for s in sections}
for s in sections:
    s['state'] = 'SKIP' if s['id'] in skip else 'FILED' if s['id'] in filed else None
    s['deps'], s['waits'] = None, []

TOK = re.compile(r'(?<![\w-])(S\d+[a-z]*(?:-\d+)?|M\d+|' + KEY_RE + r')(?![\w-])')


def resolve(s):
    clause = s['dep']
    if re.match(r'none\b', clause, re.I):
        s['deps'] = []
        return None
    toks = list(TOK.finditer(clause))
    if not toks:
        return 'Depends on names no slice, step or key: ' + (clause or '(empty)')
    maybe = [m.span() for m in re.finditer(r'\([^)]*\)', clause) if 'if it exists' in m.group(0)]
    deps = []
    for m in toks:
        t = m.group(1)
        inside = any(a <= m.start() and m.end() <= b for a, b in maybe)
        if re.fullmatch(r'S\d+[a-z]*(?:-\d+)?', t) or re.fullmatch(r'M\d+', t):
            base = re.sub(r'-\d+$', '', t)
            if t in by_id or (t.startswith('S') and base in by_id):
                target = t if t in by_id else base
                if target in skip:
                    s['notes'].append('%s is skipped: no link' % target)
                elif ('slice', target) not in deps:
                    deps.append(('slice', target))
            elif t in step_ids:
                if t not in s['waits']:
                    s['waits'].append(t)
            elif inside:
                s['notes'].append('dropped %s: named "if it exists" and no such heading' % t)
            else:
                return 'Depends on names %s, which is no heading' % t
        elif ('key', t) not in deps:
            deps.append(('key', t))
    s['deps'] = deps
    return None


def labels_of(s):
    return ([] if is_epic else ['standalone']) + (['blocked'] if s['waits'] else [])


def dep_key(d, keys):
    kind, v = d
    return v if kind == 'key' else keys.get(v)


def title_of(s):
    return '%s: %s (%s)' % (sector, s['heading'].replace('`', '').strip(), s['id'])


def body_of(s, keys):
    rev = ' revision %s' % revision if revision else ''
    heading = strip_end(s['heading'].replace('`', ''))
    if s['deps'] is None:
        edges = 'Edges: not resolved (%s)' % s['state'].lower()
    elif not s['deps']:
        edges = 'Edges: none'
    else:
        edges = 'Edges: ' + '; '.join('%s blocks %s (hard)' % (dep_key(d, keys) or '%s (not filed yet)' % d[1], s['id']) for d in s['deps'])
    out = [
        '## Impact', goal, 'This slice: %s.' % heading, '',
        '## What', 'Slice %s of %s (%s, section %s): %s.' % (s['id'], parent, plan_file, s['id'], heading), '',
        '## Why', 'Slice of %s, signed plan %s%s. Plan dependency: %s.' % (parent, plan_file, rev, strip_end(s['dep']) if s['dep'] is not None else 'no Depends on: line'), '',
        '## Plan',
        '1. Write the RED test first: %s.' % (s['red'] or 'no RED: line'),
        '2. Change the files on the Writes line as plan section %s states.' % s['id'],
        '3. Run the impacted suites.', '', edges, '',
        '## DoD'] + ['- ' + d for d in s['done']] + [
        '',
        '## Proof',
        'The RED row %s fails on main and passes after; the Done rows\' evidence in the PR body.' % (s['red_test'] or 'named in the plan'), '',
        '## Agent detail',
        'Writes: ' + ' '.join(s['paths'])]
    out += ['Waits for: %s (operator station run, no ticket)' % w for w in s['waits']]
    out += ['Note: ' + n for n in s['notes']]
    out.append('Plan section: %s#%s' % (plan_abs, s['id']))
    return '\n'.join(out) + '\n'


def policy(s, keys):
    path = os.path.join(TMP, 'policy-%s.md' % s['id'])
    with open(path, 'w', encoding='utf-8') as f:
        f.write(body_of(s, keys))
    p = subprocess.run(['node', POLICY, '--type', 'Task', '--labels', ','.join(labels_of(s)), '--draft', path, '--json'],
                       capture_output=True, text=True)
    try:
        verdict = json.loads(p.stdout)
    except ValueError:
        return 'ticket policy check failed: %s' % (last_line(p.stderr) or 'exit %d' % p.returncode)
    if verdict.get('valid') is True:
        return None
    return 'ticket policy: ' + '; '.join(d.get('message', '') for d in verdict.get('diagnostics', []) if d.get('severity') == 'error')


keys = dict(filed)
for s in sections:
    if s['state']:
        continue
    why = s['error'] or resolve(s)
    if why is None:
        why = policy(s, keys)
    s['state'], s['why'] = ('REFUSED', why) if why else ('NEW', None)

for s in sections:
    sid, st = s['id'], s['state']
    if st == 'SKIP':
        print('SKIP %s (--skip)' % sid)
        continue
    if st == 'FILED':
        print('FILED %s %s' % (sid, filed[sid]))
    elif st == 'NEW':
        bl = ','.join('%s→%s' % (d[1], keys.get(d[1], 'new')) if d[0] == 'slice' else d[1] for d in s['deps'])
        print('NEW %s "%s"%s' % (sid, title_of(s), ' blocked-by=' + bl if bl else ''))
    else:
        print('REFUSED %s: %s' % (sid, s['why']))
    for n in s['notes']:
        print('NOTE %s: %s' % (sid, n))
    print('--- body %s ---' % sid)
    sys.stdout.write(body_of(s, keys))
    print('--- end %s ---' % sid)

# filing order: a topological sort of the NEW slices, plan order among equals; FILED dependencies are fixed keys
new = [s for s in sections if s['state'] == 'NEW']
new_ids = {s['id'] for s in new}
order, done_ids = [], set()
while len(order) < len(new):
    ready = [s for s in new if s['id'] not in done_ids and all(d[1] in done_ids for d in s['deps'] if d[0] == 'slice' and d[1] in new_ids)]
    if not ready:
        break
    order.append(ready[0])
    done_ids.add(ready[0]['id'])
cycle = [s['id'] for s in new if s['id'] not in done_ids]
if cycle:
    print('REFUSED: cycle among %s' % ', '.join(cycle))

count = {st: sum(1 for s in sections if s['state'] == st) for st in ('SKIP', 'FILED', 'NEW', 'REFUSED')}
print('# counts: sections=%d skip=%d filed=%d new=%d refused=%d' % (len(sections), count['SKIP'], count['FILED'], count['NEW'], count['REFUSED']))
if count['REFUSED'] or cycle:
    sys.exit(1)
if not apply:
    sys.exit(0)

# ---- --apply: the signature, then one create per NEW slice and one link per further dependency -----------
if not signed:
    refuse_run('signature: --apply needs "SPEC ok %s <spec>" with the plan\'s **Spec:** line naming that spec; got: %s' % (parent, sig_line))

created, owed, unknown = [], [], None


def stop():
    print('FILED-SO-FAR ' + (' '.join('%s=%s' % c for c in created) if created else 'none'))
    for new_key, dep in owed:
        print('LINK-OWED node %s link %s --blocked-by %s' % (cli, new_key, dep))
    if unknown:
        print('OUTCOME-UNKNOWN %s: do not re-run until the chief finds or rules out the ticket' % unknown)
    sys.exit(3)


for s in order:
    sid = s['id']
    dks = [dep_key(d, keys) for d in s['deps']]
    dks = [k for k in dks if k]
    why = policy(s, keys)
    if why:
        print('STOPPED %s: %s' % (sid, why))
        stop()
    desc = os.path.join(TMP, 'body-%s.md' % sid)
    with open(desc, 'w', encoding='utf-8') as f:
        f.write(body_of(s, keys))
    argv = ['create', '--type', 'Task', '--title', title_of(s), '--desc-file', desc, '--sector', sector]
    argv += ['--parent', parent] if is_epic else ['--follow-up-of', parent]
    if labels_of(s):
        argv += ['--labels', ','.join(labels_of(s))]
    if version:
        argv += ['--proposed-version', version]
    if dks:
        argv += ['--blocked-by', dks[0]]
    r = jira(*argv)
    m = re.search(r'^Created (' + KEY_RE + r')\s*$', r.stdout, re.M)
    if r.returncode == 0 and m:
        key = m.group(1)
        keys[sid] = key
        created.append((sid, key))
        print('CREATED %s %s' % (sid, key))
    else:
        part = re.search(r'^.*jira: PARTIAL: Created (' + KEY_RE + r')\b.*$', r.stderr, re.M)
        lost = re.search(r'^.*jira: OUTCOME UNKNOWN:.*$', r.stderr, re.M)
        if part:
            key = part.group(1)
            created.append((sid, key))
            print(part.group(0))
            if dks and 'linking %s to %s' % (dks[0], key) in part.group(0):
                owed.append((key, dks[0]))
            owed.extend((key, d) for d in dks[1:])
        elif lost:
            print(lost.group(0))
            unknown = sid
        elif r.returncode == 0:
            print('create for %s exited 0 with no Created line' % sid)
            unknown = sid
        else:
            print('FAILED %s: create exited %d: %s' % (sid, r.returncode, last_line(r.stderr)))
        stop()
    for n, d in enumerate(dks[1:], 1):
        r = jira('link', key, '--blocked-by', d)
        if r.returncode != 0:
            print('FAILED %s: link %s --blocked-by %s exited %d: %s' % (sid, key, d, r.returncode, last_line(r.stderr)))
            owed.extend((key, x) for x in dks[n:])
            stop()
        print('LINKED %s blocks %s' % (d, key))

if created:
    ks = ','.join([parent] + [keys[s['id']] for s in sections if s['id'] in keys])
    print('NEXT chief: re-sign %s with keys %s: jira release operator spec <release> --keys %s --spec %s --plan %s --supersedes %s plus the --verdict, --decision and --verbatim-file of the signature being superseded'
          % (parent, ks, ks, spec_path, plan_abs, oid))
PY
