#!/usr/bin/env bash
# next-dispatchable.sh — Ranked, collision-checked list of the next
# tickets a console can dispatch. READ-ONLY: it prints, it never launches,
# creates a worktree or writes the mirror. console-wait.sh prints it with the
# `WAKE underfilled` block; a console can also run it by hand. It absorbs the
# spare-capacity suggestion it replaced.
#
#   next-dispatchable.sh [--top N] [--mirror DIR] [--legs-from MANIFEST]
#                        [--held FILE] [--no-classify] [--doc CONSOLE_DOC]
#                        [--priority-pool-only]
#
# Source: the Jira mirror (`jira ... mirror`, one <KEY>.md per issue). A
# candidate is a To Do issue that is not an Epic/Story/Sub-task, carries none of
# the operator-decision / blocked labels (EXCLUDE_LABELS) and has no unresolved
# blocked_by link. Rank: earliest unreleased fixVersion (HIMMEL.versions.tsv,
# natural order; none last), then priority, then key.
#
# Tiers (the first that applies; tier_of() in the script): 1 the operator pool
# head: label ps3-blocker / must-v1.1.3, or a key on the ordered `priority:` line
# in --doc's `## Live state` (line order ranks within the tier, labelled-only
# tickets after the listed ones; groups split by `|`; a token that is not a key,
# like K1, is skipped; a key marked `(CLOUD)` is dropped from the output); 2 label
# operator-directed; 3 a Bug of High or above, or a security / data-integrity /
# data-loss label; 4 the rest, by the rank above. --priority-pool-only prints
# tiers 1-3 only: per tier, the RESUME rows (In Progress / In Review, no leg, no open PR)
# lead that tier's To Do rows; an empty pool prints `POOL-EMPTY` and no rows.
#
# Residual depth: a ticket labelled residual-depth-<n> (n >= 1) is a judge, CR or
# panel residual and is excluded unless --doc records `residual-must <KEY>` on a
# line of its own (security, data loss or a broken operator flow only). No label
# means depth 0.
#
# Collision (one writer per file): the files a candidate names in its
# description are checked against (a) the files in the live legs' docs (the
# manifest's `legs[].doc`, scope lines), (b) the diff of every open PR (gh), and
# (c) --held FILE (one path per line). A path equal to, or under/over, a held
# path collides. When gh fails the list is printed with an `open PRs unknown`
# header rather than silently trusting an empty set.
#
# Classification: the survivors go through scripts/lanes/cloud-route.mjs
# --classify-only (the same gates as /cloud-route). CLOUD-OK prints CLOUD;
# LOCAL-NATIVE prints LOCAL; HOOK-BYPASS prints LOCAL with `hook` (the leg needs
# the hook-integrity bypass launch); BLOCKED is dropped. --no-classify prints
# every survivor as LOCAL? (no Jira or gh read for the class).
#
# Output, one line per ticket, tab-separated:
#   <LOCAL|CLOUD> <KEY> <priority> <fixVersion|-> <title> files=<a,b|->  [hook]
#
# Env (tests): NEXT_DISPATCH_MIRROR, NEXT_DISPATCH_GH_CMD (replaces `gh`),
# NEXT_DISPATCH_CLASSIFY_CMD (replaces cloud-route.mjs; called with the keys),
# NEXT_DISPATCH_EXCLUDE_LABELS (comma list, replaces the default).
#
# Exit: 0 printed (possibly nothing); 2 usage.
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

top=8; mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
legs_from="${LEGS_FROM:-}"; held=""; classify=1; resume_only=0; owners=""; doc=""; pool_only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --resume-only) resume_only=1; classify=0; shift ;;
        --owners) owners="${2:-}"; shift 2 || exit 2 ;;
        --top) top="${2:-}"; shift 2 || exit 2 ;;
        --mirror) mirror="${2:-}"; shift 2 || exit 2 ;;
        --legs-from) legs_from="${2:-}"; shift 2 || exit 2 ;;
        --held) held="${2:-}"; shift 2 || exit 2 ;;
        --no-classify) classify=0; shift ;;
        --doc) doc="${2:-}"; shift 2 || exit 2 ;;
        --priority-pool-only) pool_only=1; shift ;;
        *) echo "usage: next-dispatchable.sh [--top N] [--mirror DIR] [--legs-from MANIFEST] [--held FILE] [--no-classify] [--doc CONSOLE_DOC] [--priority-pool-only] [--resume-only] [--owners \"KEY ...\"]" >&2; exit 2 ;;
    esac
done
case "$top" in ''|*[!0-9]*|0*) echo "next-dispatchable: --top needs a positive number" >&2; exit 2 ;; esac

export ND_TOP="$top" ND_MIRROR="$mirror" ND_LEGS_FROM="$legs_from" ND_HELD="$held" ND_CLASSIFY="$classify" ND_REPO="$REPO" ND_RESUME_ONLY="$resume_only" ND_OWNERS="$owners" ND_DOC="$doc" ND_POOL_ONLY="$pool_only"
exec python3 -I - <<'PY'
import json, os, re, subprocess, sys

top = int(os.environ['ND_TOP']); mirror = os.environ['ND_MIRROR']
repo = os.environ['ND_REPO']
excl = set(filter(None, os.environ.get('NEXT_DISPATCH_EXCLUDE_LABELS',
    'operator-decision,operator,operator-present,blocked,decision,windows-parked,design-deferred,placeholder').split(',')))
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)")
PRIO = {'Highest': 0, 'Blocker': 0, 'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3, 'Lowest': 4}

def files_in(text):
    out = []
    for m in FILE_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and f not in out:
            out.append(f)
    return out

def collides(a, b):
    a, b = a.rstrip('/'), b.rstrip('/')
    return a == b or a.startswith(b + '/') or b.startswith(a + '/')

def fm_val(fm, name):
    m = re.search(r'^%s: (.*)$' % re.escape(name), fm, re.M)
    return m.group(1).strip() if m else ''

def unq(v):
    return v.strip().strip('"')

OWED_RE = re.compile(r'stays open|still open|owed|must-fix|remaining slice|next slice', re.I)

def last_owed(body):
    # the last comment line that says work remains; '' when there is none
    i = body.find('\n## Comments')
    hit = ''
    for line in (body[i:].splitlines() if i >= 0 else []):
        if OWED_RE.search(line):
            hit = line.strip()
    return hit[:160]

issues = {}
try:
    names = sorted(n for n in os.listdir(mirror) if re.match(r'^[A-Z]+-\d+\.md$', n))
except OSError as e:
    print('# next-dispatchable: mirror unreadable (%s)' % e, file=sys.stderr); sys.exit(0)
for n in names:
    txt = open(os.path.join(mirror, n), encoding='utf-8', errors='replace').read()
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', txt, re.S)
    if not m:
        continue
    fm, body = m.groups()
    key = unq(fm_val(fm, 'key'))
    t = re.search(r'^# [A-Z]+-\d+: (.*)$', body, re.M)
    issues[key] = {
        'key': key, 'type': unq(fm_val(fm, 'type')), 'status': unq(fm_val(fm, 'status')),
        'prio': unq(fm_val(fm, 'priority')), 'labels': set(re.findall(r'"([^"]+)"', fm_val(fm, 'labels'))),
        'ver': re.findall(r'"([^"]+)"', fm_val(fm, 'fixVersions')),
        'blocked_by': re.findall(r'[A-Z]+-\d+', re.search(r'blocked_by: (.*)', fm).group(1)) if re.search(r'blocked_by: (.*)', fm) else [],
        'title': t.group(1).strip() if t else '', 'files': files_in(body),
        'last': last_owed(body),
    }

# unreleased versions in natural order
vorder = {}
vf = mirror.rstrip('/') + '.versions.tsv'
if os.path.exists(vf):
    def nat(v): return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', v)]
    vs = []
    for line in open(vf, encoding='utf-8', errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2 and p[1].strip() == 'false' and not p[0].startswith('zz-'):
            vs.append(p[0])
    for i, v in enumerate(sorted(vs, key=nat)):
        vorder[v] = i

def rank(i):
    vers = [vorder[v] for v in i['ver'] if v in vorder]
    return (min(vers) if vers else 10**6, PRIO.get(i['prio'], 5), int(i['key'].split('-')[1]))

# The operator's ordered `priority:` line, from the `## Live state` section of the console doc.
def read_priority_line(path):
    order, cloud = {}, set()
    if not path:
        return order, cloud
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return order, cloud
    in_state = False
    for line in lines:
        if line.startswith('## '):
            in_state = line.strip() == '## Live state'
        m = re.match(r'^\s*(?:[-*]\s+)?(?:\*\*)?priority:(?:\*\*)?\s*(.*)$', line) if in_state else None
        if m:
            # Outside (...) every bare number is a key; inside, only HIMMEL-NNNN or a number
            # from a `+` to the closing paren. `NNN (CLOUD)` marks NNN cloud-only.
            depth, plus = 0, False
            for t in re.finditer(r'(\()|(\))|(\+)|(?<![\w-])(HIMMEL-)?(\d{3,5})(?![\w-])(\s*\(CLOUD\))?', m.group(1)):
                if t.group(1):
                    depth += 1
                elif t.group(2):
                    depth, plus = max(depth - 1, 0), False
                elif t.group(3):
                    plus = plus or depth > 0
                elif depth == 0 or plus or t.group(4):
                    key = 'HIMMEL-' + t.group(5)
                    order.setdefault(key, len(order))
                    if t.group(6):
                        cloud.add(key)
            break
    return order, cloud

prio_order, prio_cloud = read_priority_line(os.environ.get('ND_DOC', ''))
TIER1_LABELS = {'ps3-blocker', 'must-v1.1.3'}
TIER3_LABELS = {'security', 'data-integrity', 'data-loss'}

def residual_depth(i):
    ds = [int(m.group(1)) for l in i['labels'] for m in [re.match(r'^residual-depth-(\d+)$', l)] if m]
    return max(ds) if ds else 0

def read_residual_must(path):
    keys = set()
    try:
        for line in open(path, encoding='utf-8', errors='replace'):
            m = re.match(r'^\s*(?:[-*]\s+)?residual-must\s+(?:HIMMEL-)?(\d{3,5})\b', line)
            if m:
                keys.add('HIMMEL-' + m.group(1))
    except OSError:
        pass
    return keys

residual_must = read_residual_must(os.environ['ND_DOC']) if os.environ.get('ND_DOC') else set()

def tier_of(i):
    # 1 operator pool head, 2 operator-directed, 3 Bug High+ / security / data-integrity, 4 the rest.
    if i['key'] in prio_order or i['labels'] & TIER1_LABELS:
        return 1
    if 'operator-directed' in i['labels']:
        return 2
    if (i['type'] == 'Bug' and PRIO.get(i['prio'], 5) <= 1) or i['labels'] & TIER3_LABELS:
        return 3
    return 4

def ranked(i):
    return (tier_of(i), prio_order.get(i['key'], 10**6)) + rank(i)

def load_platform_re():
    # The one pattern file gen-briefs.py reads too: its first non-blank, non-# line.
    path = os.path.join(repo, 'scripts/handover/console-kit/platform-dropped.re')
    try:
        for line in open(path):
            if line.strip() and not line.startswith('#'):
                return re.compile(line.strip(), re.I)
    except OSError:
        pass
    print('next-dispatchable: cannot read the dropped-platform pattern from %s' % path, file=sys.stderr); sys.exit(2)

platform_re = load_platform_re()
skipped_platform = []
cands = []
for i in issues.values():
    if i['status'] != 'To Do' or i['type'] in ('Epic', 'Story', 'Sub-task'):
        continue
    if i['labels'] & excl:
        continue
    if platform_re.search(i['title']) and 'windows-removal' not in i['labels']:
        skipped_platform.append(i['key'])
        continue
    if any(issues.get(b, {}).get('status') != 'Done' for b in i['blocked_by']):
        continue
    if i['key'] in prio_cloud:
        continue
    if residual_depth(i) >= 1 and i['key'] not in residual_must:
        continue
    cands.append(i)
cands.sort(key=ranked)
pool_only = os.environ.get('ND_POOL_ONLY') == '1'
if pool_only:
    cands = [i for i in cands if tier_of(i) <= 3]

# held files: live legs, open PRs, --held
held = []
legs_from = os.environ.get('ND_LEGS_FROM', '')
legs_unknown = False
leg_keys = set(os.environ.get('ND_OWNERS', '').split())
resume_only = os.environ.get('ND_RESUME_ONLY') == '1'
if legs_from and not os.path.isfile(legs_from):
    legs_unknown = True
if legs_from and os.path.isfile(legs_from):
    try:
        for leg in json.load(open(legs_from)).get('legs', []):
            doc = leg.get('doc', '')
            leg_keys.update(re.findall(r'[A-Z]+-\d+', os.path.basename(doc)))
            try:
                for line in open(doc, encoding='utf-8', errors='replace'):
                    if line.startswith('> **Scope / do not:**') or 'writes confined to' in line:
                        held += [(f, 'live leg %s' % leg.get('label', '?')) for f in files_in(line)]
            except OSError:
                legs_unknown = True
    except (OSError, ValueError):
        legs_unknown = True
hf = os.environ.get('ND_HELD', '')
if hf and os.path.isfile(hf):
    held += [(l.strip(), 'held list') for l in open(hf) if l.strip()]
pr_unknown = False
pr_keys = set()
gh = os.environ.get('NEXT_DISPATCH_GH_CMD', 'gh')
try:
    nums = subprocess.run([gh, 'pr', 'list', '--repo', 'yotamleo/Himmel', '--state', 'open', '--limit', '200', '--json', 'number', '--jq', '.[].number'],
                          capture_output=True, text=True, timeout=60, check=True).stdout.split()
    for num in ([] if resume_only else nums):
        d =subprocess.run([gh, 'pr', 'diff', num, '--repo', 'yotamleo/Himmel', '--name-only'], capture_output=True, text=True, timeout=60, check=True).stdout.split()
        held += [(f, 'open PR %s' % num) for f in d]
    # an open PR cites a ticket by its title or head branch (the commit/PR gate puts the key in both)
    for line in subprocess.run([gh, 'pr', 'list', '--repo', 'yotamleo/Himmel', '--state', 'open', '--limit', '200', '--json', 'title,headRefName', '--jq', '.[] | [.number, .title, .headRefName] | @tsv'],
                               capture_output=True, text=True, timeout=60, check=True).stdout.splitlines():
        pr_keys.update(k.upper() for k in re.findall(r'[A-Za-z]+-\d+', line))
except (OSError, subprocess.SubprocessError):
    pr_unknown = True

# In-work tickets nobody holds: no leg, no open PR, not parked or blocked.
resume = []
for i in issues.values():
    if pool_only and (tier_of(i) > 3 or i['key'] in prio_cloud):
        continue
    if i['status'] not in ('In Progress', 'In Review') or i['type'] in ('Epic', 'Story', 'Sub-task'):
        continue
    if i['labels'] & excl or any('parked' in l for l in i['labels']):
        continue
    if i['key'] in leg_keys or i['key'] in pr_keys:
        continue
    if any(issues.get(b, {}).get('status') != 'Done' for b in i['blocked_by']):
        continue
    if pr_unknown or legs_unknown:  # an unread PR set or leg set could hide the ticket's owner
        continue
    if any(collides(f, h) for f in i['files'] for h, _ in held):
        continue
    resume.append(i)
resume.sort(key=ranked if pool_only else rank)

free = []
for i in cands:
    if any(collides(f, h) for f in i['files'] for h, _ in held):
        continue
    free.append(i)

def classify(batch):
    cls = {}
    cmd = os.environ.get('NEXT_DISPATCH_CLASSIFY_CMD')
    argv = [cmd] if cmd else ['node', os.path.join(repo, 'scripts/lanes/cloud-route.mjs'), '--classify-only']
    hfile = None
    if held:
        import tempfile
        t = tempfile.NamedTemporaryFile('w', suffix='.held', delete=False)
        t.write('\n'.join(h for h, _ in held) + '\n'); t.close(); hfile = t.name
        if not cmd:
            argv += ['--held', hfile]
    try:
        r = subprocess.run(argv + [i['key'] for i in batch], capture_output=True, text=True, timeout=300)
        for line in r.stdout.splitlines():
            p = line.split('\t')
            if len(p) >= 2 and re.match(r'^[A-Z]+-\d+$', p[0]):
                cls[p[0]] = p[1]
    except (OSError, subprocess.SubprocessError):
        pass
    if hfile:
        os.unlink(hfile)
    return cls

print('# next-dispatchable: %d To Do candidate(s), %d collision-free%s' % (len(cands), len(free), ', open PRs unknown (gh failed)' if pr_unknown else '') + (', %d RESUME (in work, no leg, no open PR)' % len(resume) if resume else '') + (', live legs unknown (manifest or leg doc unreadable)' if legs_unknown else ''))
if skipped_platform:
    print('# skipped %d windows/wsl ticket(s): %s' % (len(skipped_platform), ' '.join(sorted(skipped_platform))))
n = 0
picked = []

def emit_resume(rows):
    global n
    for i in rows:
        if n >= top:
            break
        if not resume_only and any(collides(f, h) for f in i['files'] for h in picked):
            continue
        picked.extend(i['files'])
        print('\t'.join(['RESUME', i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-'), 'status=' + i['status'], 'last=' + (i['last'] or '-')]))
        n += 1

classified = os.environ.get('ND_CLASSIFY') == '1'

def emit_free(rows):
    # Walk the collision-free list in chunks so BLOCKED rows in an early chunk do not
    # leave the list short while later candidates are dispatchable.
    global n
    for start in range(0, len(rows) if n < top else 0, top * 3):
        batch = rows[start:start + top * 3]
        cls = classify(batch) if classified else {}
        for i in batch:
            c = cls.get(i['key'])
            if classified:
                if c is None or c == 'BLOCKED':
                    continue
                lane = 'CLOUD' if c == 'CLOUD-OK' else 'LOCAL'
            else:
                lane, c = 'LOCAL?', ''
            # one writer per file: a listed ticket holds its files against the rest of the list
            if any(collides(f, h) for f in i['files'] for h in picked):
                continue
            picked.extend(i['files'])
            print('\t'.join([lane, i['key'], i['prio'] or '-', ','.join(i['ver']) or '-', i['title'], 'files=' + (','.join(i['files']) or '-')] + (['hook'] if c == 'HOOK-BYPASS' else [])))
            n += 1
            if n >= top:
                break
        if n >= top:
            break

if pool_only:
    # tier by tier: a tier's leg-less In Progress rows lead its To Do rows
    for t in (1, 2, 3):
        emit_resume([i for i in resume if tier_of(i) == t])
        emit_free([i for i in free if tier_of(i) == t])
    if n == 0:  # nothing in the pool, or every pool ticket was classified BLOCKED or collided
        print('POOL-EMPTY')
    sys.exit(0)
emit_resume(resume)
if resume_only:
    sys.exit(0)
emit_free(free)
PY
