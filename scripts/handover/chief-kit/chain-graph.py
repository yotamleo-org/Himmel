#!/usr/bin/env python3
"""chain-graph.py (HIMMEL-7707, slice 1 of HIMMEL-7701): print the hard and soft edges of a chain.

Read-only report. Builds the pairwise dependency graph of a set of PRs and prints it. No Jira or GitHub
write, no lock write, no dispatch or merge behaviour changes. Slices 3 and 4 read the --json form.

USAGE
    chain-graph.py --prs 3972,3971,3969 [--base origin/main] [--json]
    chain-graph.py --open                     every open PR
    chain-graph.py --keys HIMMEL-7539,HIMMEL-7504   the open PR of each key (a key with no PR is a PR-less node)
        [--head PR=SHA] [--repo-dir DIR] [--repo OWNER/NAME] [--trust-file FILE] [--cache-dir DIR] [--all]

Edge kinds (design HIMMEL-7701 section 2): H1 hard-start, H2 hard-merge, S1 soft-text, S2 soft-coupled,
independent. Detections: D1 Jira Blocks link; D3 changed files (paginated files API); D4 git merge-tree on the
real heads (a conflict is H2, clean confirms S1); D6 registry and vocabulary scan; D7 introduces (a file or
symbol A adds that B's added lines name). D2 and D5 (planned scope, graphify) are not implemented.
A shared trust-path file (ci-trust-paths.txt) is H2 whatever D4 says, except a row registry (ROW_REGISTRIES)
whose two sides only add rows with disjoint keys, which is S2. Precedence H1 > H2 > S2 > S1.
A pair with no shared file is not trial-merged; only D1, D6 and D7 can lift it above independent.

Environment: CHAIN_GRAPH_GH (the gh command, default gh), CHAIN_GRAPH_JIRA (the jira `links` command prefix,
default node <primary checkout>/scripts/jira/dist/index.js links). Results cache per (headA, headB) under
$XDG_RUNTIME_DIR/chain-graph or the temp dir, never in the repo. Exit 2 on a read that fails.
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

RANK = {'independent': 0, 'S1': 1, 'S2': 2, 'H2': 3, 'H1': 4}
KEY_RE = re.compile(r'HIMMEL-\d+')
# registries a gate reads: a clean shared edit is S2, not S1 (D6)
GATE_REGISTRIES = ('scripts/ci/suite-tiers.tsv', 'scripts/ci/suite-durations.tsv', '.claude/settings.json')
# one-row-per-key registries on a trust path: pure disjoint row additions from both sides are S2, not H2
ROW_REGISTRIES = ('scripts/ci/suite-tiers.tsv', 'scripts/ci/suite-durations.tsv')
VOCAB_REGISTRY = 'scripts/lib/rename-aliases.tsv'
SYM_RE = re.compile(r'^\s*(?:async\s+function|function|def|class)\s+([A-Za-z_]\w{7,})|^([A-Za-z_]\w{7,})\(\)\s*\{')
CACHE_VERSION = 'v6'
CODE_EXT = ('.py', '.sh', '.bash', '.js', '.mjs', '.ts', '.tsx')


class ReadError(Exception):
    pass


REPO_LOCAL_GIT_ENV = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
                      'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE',
                      'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS',
                      'GIT_CONFIG_COUNT')


def run(cmd, cwd=None, ok=(0,)):
    env = {k: v for k, v in os.environ.items() if k not in REPO_LOCAL_GIT_ENV}
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, errors='replace')
    if p.returncode not in ok:
        raise ReadError('%s: rc=%d %s' % (' '.join(cmd[:4]), p.returncode, p.stderr.strip()[:200]))
    return p


def gh(args):
    cmd = shlex.split(os.environ.get('CHAIN_GRAPH_GH', 'gh')) + args
    return run(cmd).stdout


def git(repo, args, ok=(0,)):
    return run(['git', '-C', repo] + args, ok=ok)


def key_of(title, branch=''):
    m = KEY_RE.search(title or '') or KEY_RE.search(branch or '')
    return m.group(0) if m else ''


def load_nodes(a):
    nodes = []
    if a.prs:
        for n in [x for x in a.prs.split(',') if x]:
            d = json.loads(gh(['pr', 'view', n, '--repo', a.repo, '--json', 'number,title,headRefOid,headRefName,baseRefName']))
            nodes.append(node(d))
    else:
        lst = json.loads(gh(['pr', 'list', '--repo', a.repo, '--state', 'open', '--limit', '500', '--json',
                             'number,title,headRefOid,headRefName,baseRefName']))
        if a.open:
            nodes = [node(d) for d in lst]
        else:
            for k in [x for x in a.keys.split(',') if x]:
                hit = [d for d in lst if key_of(d['title'], d.get('headRefName', '')) == k]
                nodes.extend(node(d) for d in hit) if hit else nodes.append(
                    {'id': k, 'pr': None, 'key': k, 'head': '', 'title': ''})
    for pin in a.head or []:
        num, _, sha = pin.partition('=')
        for n in nodes:
            if str(n['pr']) == num:
                n['head'], n['pinned'] = sha, True
    return nodes


def node(d):
    return {'id': '#%s' % d['number'], 'pr': d['number'], 'key': key_of(d['title'], d.get('headRefName', '')),
            'head': d['headRefOid'], 'title': d['title'], 'base_ref': d.get('baseRefName', '')}


def ensure_head(repo, n):
    if git(repo, ['cat-file', '-e', n['head'] + '^{commit}'], ok=(0, 1, 128)).returncode == 0:
        return
    git(repo, ['fetch', '--quiet', 'origin', 'pull/%d/head' % n['pr']])


def pr_files(a, n):
    """(path, status, previous_filename) rows from the paginated files API; from git for a --head pinned node,
    because the API describes the PR's current head."""
    if n.get('pinned'):
        names = {'A': 'added', 'D': 'removed', 'M': 'modified', 'R': 'renamed'}
        out = git(a.repo_dir, ['diff', '--name-status', '--no-color', '--no-ext-diff', '-M', '-l', '5000',
                               '%s...%s' % (a.base, n['head'])]).stdout
        rows = []
        for line in out.splitlines():
            f = line.split('\t')
            if len(f) >= 2:
                rows.append((f[-1], names.get(f[0][0], 'modified'), f[1] if f[0][0] == 'R' else ''))
        return rows
    out = gh(['api', 'repos/%s/pulls/%d/files' % (a.repo, n['pr']), '--paginate', '--jq',
              '.[] | [.filename, .status, (.previous_filename // "")] | @tsv'])
    rows = []
    for line in out.splitlines():
        f = line.split('\t')
        if f and f[0]:
            rows.append((f[0], f[1] if len(f) > 1 else '', f[2] if len(f) > 2 else ''))
    return rows


def added_lines(a, n):
    """{path: [added line, ...]} of base...head, zero context."""
    out = git(a.repo_dir, ['diff', '-U0', '--no-color', '--no-ext-diff', '--no-renames', '%s...%s' % (a.base, n['head'])]).stdout
    res, cur = {}, None
    for line in out.splitlines():
        if line.startswith('+++ '):
            cur = line[6:] if line.startswith('+++ b/') else None
            if cur is not None:
                res.setdefault(cur, [])
        elif line.startswith('+') and cur is not None:
            res[cur].append(line[1:])
    return res


def new_files(a, n):
    """Paths the head truly introduces: status A under rename detection (the files API lists a bulk rename as added)."""
    out = git(a.repo_dir, ['diff', '--name-status', '--no-color', '--no-ext-diff', '-M', '-l', '5000', '--diff-filter=A',
                           '%s...%s' % (a.base, n['head'])]).stdout
    return [l.split('\t', 1)[1] for l in out.splitlines() if '\t' in l]


def trust_patterns(a):
    if a.trust_file:
        text = open(a.trust_file, encoding='utf-8').read()
    else:
        p = git(a.repo_dir, ['show', '%s:scripts/ci/ci-trust-paths.txt' % a.base], ok=(0, 128))
        if p.returncode != 0:
            p = None
        text = p.stdout if p else open(os.path.join(a.repo_dir, 'scripts/ci/ci-trust-paths.txt'), encoding='utf-8').read()
    pats = [l.strip() for l in text.splitlines() if l.strip() and not l.lstrip().startswith('#')]
    if not pats:
        raise ReadError('empty trust-path list')
    return [re.compile(p) for p in pats]


def jira_blocks(keys, repo_dir):
    """{(blocker, blocked)} among keys, from `links <key>`. Empty (and noted) when Jira is unreadable."""
    common = git(repo_dir, ['rev-parse', '--path-format=absolute', '--git-common-dir']).stdout.strip()
    anchor = os.path.dirname(common)
    base = os.environ.get('CHAIN_GRAPH_JIRA')
    if base:
        cmd = shlex.split(base)
    else:
        cmd = ['node', os.path.join(anchor, 'scripts/jira/dist/index.js'), 'links']
    env = dict(os.environ)
    env.setdefault('JIRA_PROJECT_KEY', 'HIMMEL')
    found, unreadable = set(), False
    for k in sorted(set(x for x in keys if x)):
        p = subprocess.run(cmd + [k], capture_output=True, text=True, env=env, cwd=anchor)
        if p.returncode != 0:
            unreadable = True
            continue
        for line in p.stdout.splitlines():
            f = line.split('\t')
            if len(f) > 1 and f[1] == 'Blocks':
                m = re.search(r'(HIMMEL-\d+) blocks (HIMMEL-\d+)', f[-1])
                if m and m.group(1) in keys and m.group(2) in keys:
                    found.add((m.group(1), m.group(2)))
    return found, unreadable


def cache_dir(a):
    base = a.cache_dir or os.path.join(os.environ.get('XDG_RUNTIME_DIR') or tempfile.gettempdir(), 'chain-graph')
    os.makedirs(base, exist_ok=True)
    return base


def cached(a, key, fn):
    path = os.path.join(cache_dir(a), hashlib.sha1(key.encode()).hexdigest() + '.json')
    if os.path.exists(path):
        try:
            return json.load(open(path))
        except ValueError:
            pass
    val = fn()
    tmp = path + '.%d' % os.getpid()
    json.dump(val, open(tmp, 'w'))
    os.replace(tmp, path)
    return val


def word_in(text, term):
    return re.search(r'(?<![\w.-])%s(?![\w-])(?!\.[A-Za-z])' % re.escape(term), text) is not None


def introduces(a, x, y):
    """D7: what x adds that y's added lines name. Returns (files, symbols)."""
    ytext = '\n'.join(l for ls in y['added'].values() for l in ls)
    ycode = '\n'.join(l for p, ls in y['added'].items() if p.endswith(CODE_EXT) for l in ls)
    yfiles = {p for p, _, _ in y['files']}
    files = [p for p in x['new'] if p not in yfiles and p in ytext]

    def symbols(n):
        found = set()
        for p, ls in n['added'].items():
            if p.endswith(CODE_EXT):
                found.update(m.group(1) or m.group(2) for m in map(SYM_RE.match, ls) if m)
        return found
    cand = sorted(s for s in symbols(x) - symbols(y) if re.search(r'\b%s\b' % re.escape(s), ycode))
    # a symbol already in the base tree is not introduced by x (a moved or renamed helper, a common word)
    syms = [s for s in cand if git(a.repo_dir, ['grep', '-q', '-w', '-F', '-e', s, a.base], ok=(0, 1)).returncode == 1]
    return files, syms


def vocab_terms(a, x):
    """Old terms (column 1) of rows x adds to the alias registry."""
    terms = set()
    for l in x['added'].get(VOCAB_REGISTRY, []):
        f = l.split('\t')
        if len(f) > 3 and not l.startswith('#') and f[0] and f[0] != 'old':
            terms.add(f[0])
    return terms


def row_adds_disjoint(a, x, y, path):
    """True when both PRs only add rows to the registry at path, and the added keys collide with
    neither each other nor a key main already has."""
    keys = []
    for n in (x, y):
        mb = git(a.repo_dir, ['merge-base', a.base, n['head']]).stdout.strip()
        stat = git(a.repo_dir, ['diff', '--numstat', mb, n['head'], '--', path]).stdout.split()
        if len(stat) < 3 or stat[1] != '0':
            return False
        diff = git(a.repo_dir, ['diff', '-U0', mb, n['head'], '--', path]).stdout
        keys.append({l[1:].split('\t')[0] for l in diff.splitlines()
                     if l.startswith('+') and not l.startswith('+++') and l[1:].strip() and not l.startswith('+#')})
    in_base = git(a.repo_dir, ['show', '%s:%s' % (a.base, path)], ok=(0, 128)).stdout
    base_keys = {l.split('\t')[0] for l in in_base.splitlines()}
    return not (keys[0] & keys[1]) and not ((keys[0] | keys[1]) & base_keys)


def git_pair(a, x, y, trust, declared):
    """The head-derived verdict for x, y (cacheable): (kind, det, evidence, files, direction)."""
    cands = []  # (rank, kind, det, evidence, files, from_is_x)
    for p, q, fwd in ((x, y, True), (y, x, False)):
        files, syms = introduces(a, p, q)
        if files or syms:
            named = files + syms
            cands.append((4, 'H1', 'D7', '%s adds %s%s that %s names' % (
                p['id'], ', '.join(named[:3]), ' (+%d more)' % (len(named) - 3) if len(named) > 3 else '', q['id']),
                files, fwd))
        gone = [pth for pth, st, prev in p['files'] if st in ('removed', 'renamed') for pth in
                ([prev] if st == 'renamed' and prev else [pth] if st == 'removed' else [])]
        qtext = '\n'.join(l for ls in q['added'].values() for l in ls)
        hit = [g for g in gone if g in qtext]
        if hit:
            cands.append((3, 'H2', 'D6', '%s names a path %s removes' % (q['id'], p['id']), hit, fwd))
        for t in sorted(vocab_terms(a, p)):
            md = [pth for pth, ls in q['added'].items() if pth.endswith('.md') and any(word_in(l, t) for l in ls)]
            if md:
                cands.append((2, 'S2', 'D6', '%s adds old-term "%s" to a prose file %s now gate-checks' % (q['id'], t, p['id']),
                              md, fwd))
                break
    xs = {p for p, _, _ in x['files']} | {pv for _, _, pv in x['files'] if pv}
    ys = {p for p, _, _ in y['files']} | {pv for _, _, pv in y['files'] if pv}
    shared = sorted(xs & ys)
    if shared:
        mt = git(a.repo_dir, ['merge-tree', '--write-tree', '--name-only', x['head'], y['head']], ok=(0, 1))
        if mt.returncode == 1:
            conflicted = []
            for l in mt.stdout.splitlines()[1:]:
                if not l:
                    break
                conflicted.append(l)
            cands.append((3, 'H2', 'D4', 'merge-tree conflict', conflicted or shared, True))
        else:
            rows = [s for s in shared if s in ROW_REGISTRIES and row_adds_disjoint(a, x, y, s)]
            tr = [s for s in shared if s not in rows and any(r.search(s) for r in trust)]
            gr = [s for s in shared if s in GATE_REGISTRIES]
            if tr:
                cands.append((3, 'H2', 'D3', 'shared trust-path file, merge-tree clean', tr, True))
            elif rows:
                cands.append((2, 'S2', 'D6', 'shared row registry, disjoint row additions, merge-tree clean', rows, True))
            elif gr:
                cands.append((2, 'S2', 'D6', 'shared gate registry, merge-tree clean', gr, True))
            else:
                cands.append((1, 'S1', 'D4', 'shared files, disjoint lines, merge-tree clean', shared, True))
    if not cands:
        return ['independent', '', 'no shared file', [], True]
    cands.sort(key=lambda c: -c[0])
    top = cands[0]
    return [top[1], top[2], top[3], top[4], top[5]]


def build(a):
    nodes = load_nodes(a)
    trust = trust_patterns(a)
    base_sha = git(a.repo_dir, ['rev-parse', a.base + '^{commit}']).stdout.strip()
    for n in nodes:
        if n['pr'] is None:
            n.update(files=[], added={}, new=[])
            continue
        ensure_head(a.repo_dir, n)
        n['files'] = cached(a, 'files|%s|%s|%s|%s|%s|%s' % (n['pr'], n['head'], 'git' if n.get('pinned') else 'api',
                                              n.get('base_ref', ''), base_sha, CACHE_VERSION),
                            lambda n=n: pr_files(a, n))
        n['added'] = cached(a, 'added|%s|%s|%s' % (n['head'], base_sha, CACHE_VERSION), lambda n=n: added_lines(a, n))
        n['new'] = cached(a, 'new|%s|%s|%s' % (n['head'], base_sha, CACHE_VERSION), lambda n=n: new_files(a, n))
    for n in nodes:
        n['trust_files'] = sorted(p for p, _, pv in n['files'] for p in (p, pv) if p and any(r.search(p) for r in trust))
    blocks, jira_unreadable = jira_blocks({n['key'] for n in nodes}, a.repo_dir)
    trust_sig = hashlib.sha1('\n'.join(r.pattern for r in trust).encode()).hexdigest()[:12]
    edges = []
    for i, x in enumerate(nodes):
        for y in nodes[i + 1:]:
            declared = [(p, q) for p, q in ((x['key'], y['key']), (y['key'], x['key'])) if (p, q) in blocks]
            if x['pr'] is not None and y['pr'] is not None:
                fsig = hashlib.sha1(repr((sorted(x['files']), sorted(y['files']))).encode()).hexdigest()[:12]
                kind, det, ev, files, fwd = cached(
                    a, 'pair|%s|%s|%s|%s|%s|%s' % (x['head'], y['head'], base_sha, trust_sig, fsig, CACHE_VERSION),
                    lambda x=x, y=y: git_pair(a, x, y, trust, declared))
            else:
                kind, det, ev, files, fwd = 'independent', '', 'no shared file', [], True
            src = 'derived'
            if declared:
                p, q = declared[0]
                ev = 'Jira Blocks %s -> %s' % (p, q) + (' and back (cycle)' if len(declared) > 1 else '')
                kind, det, files, src = 'H1', 'D1', [], 'declared'
                fwd = (p == x['key'])
            frm, to = (x, y) if fwd else (y, x)
            edges.append({'from': frm['id'], 'to': to['id'], 'kind': kind, 'det': det, 'evidence': ev,
                          'files': files, 'source': src, 'cycle': len(declared) > 1})
    red = main_red(a)
    for n in nodes:
        n['gates'] = {'trust_judge': bool(n['trust_files']), 'main_red': red}
    summary = {k: 0 for k in ('H1', 'H2', 'S1', 'S2', 'independent')}
    for e in edges:
        summary[e['kind']] += 1
    return {'base': a.base, 'base_sha': base_sha, 'jira_links': 'unreadable' if jira_unreadable else 'ok',
            'nodes': [{k: n[k] for k in ('id', 'pr', 'key', 'head', 'title', 'trust_files', 'gates')} |
                      {'files': len(n['files'])} for n in nodes],
            'edges': edges, 'summary': summary}


def main_red(a):
    try:
        out = gh(['run', 'list', '--repo', a.repo, '--branch', 'main', '--limit', '1', '--json', 'conclusion',
                  '--jq', '.[0].conclusion // "none"']).strip()
    except (ReadError, OSError):
        return 'unknown'
    return 'yes' if out in ('failure', 'timed_out', 'startup_failure') else 'no'


def render(g, show_all):
    rows = [('A', 'B', 'kind', 'det', 'evidence', 'files')]
    for e in g['edges']:
        if e['kind'] == 'independent' and not show_all:
            continue
        fl = ', '.join(e['files'][:3]) + (' (+%d)' % (len(e['files']) - 3) if len(e['files']) > 3 else '')
        rows.append((e['from'], e['to'], e['kind'], e['det'] or '-', e['evidence'], fl or '-'))
    w = [max(len(r[i]) for r in rows) for i in range(5)]
    out = ['  '.join(c.ljust(w[i]) for i, c in enumerate(r[:5])) + '  ' + r[5] for r in rows]
    out.append('')
    for n in g['nodes']:
        gt = n['gates']
        out.append('%s %s head=%s files=%d trust-judge=%s main-red=%s' % (
            n['id'], n['key'] or '-', n['head'][:12] or '-', n['files'],
            ('yes (%s)' % ', '.join(n['trust_files'][:3])) if gt['trust_judge'] else 'no', gt['main_red']))
    s = g['summary']
    out.append('')
    out.append('edges: H1=%d H2=%d S1=%d S2=%d independent=%d (pairs=%d) base=%s jira-links=%s' % (
        s['H1'], s['H2'], s['S1'], s['S2'], s['independent'], len(g['edges']), g['base_sha'][:12], g['jira_links']))
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument('--prs')
    src.add_argument('--open', action='store_true')
    src.add_argument('--keys')
    ap.add_argument('--base', default='origin/main')
    ap.add_argument('--repo', default='yotamleo-org/Himmel')  # env-literal-ok: default for the one himmel origin, overridable
    ap.add_argument('--repo-dir', default='.')
    ap.add_argument('--head', action='append', metavar='PR=SHA',
                    help="evaluate PR at this commit instead of its current head (files then come from git)")
    ap.add_argument('--trust-file')
    ap.add_argument('--cache-dir')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--all', action='store_true', help='print independent pairs too')
    a = ap.parse_args()
    try:
        g = build(a)
    except (ReadError, OSError, ValueError) as e:
        print('chain-graph: %s' % e, file=sys.stderr)
        return 2
    print(json.dumps(g, indent=1) if a.json else render(g, a.all))
    return 0


if __name__ == '__main__':
    sys.exit(main())
