"""Living roadmap tracker for HIMMEL-3882: one self-contained HTML page, re-run to refresh.

Plan (static) comes from <plan-dir>/stage3/placement|versions|closures|unplaced + meta.json,
the stage1 theme/impact columns and explain files (user impact), stage2 (readiness, effort range)
and the placer's layer caps (tools/stage3/place.py). Status (live) comes from the Jira mirror, never from the plan,
so progress moves as work lands. Related luna notes per placed ticket are cached in the
luna-map file (qmd lexical search + a key grep of the handover tree); only keys missing or
older than 7 days are re-queried, `--refresh-luna` forces all.

The main view is version-first (HIMMEL-3990): which Jira version are we working on. A ticket's version is its earliest
unreleased v1.0.x fixVersion (else the newest released one); its column is its Jira status name. Release state comes from
a `jira versions` snapshot (`name<TAB>released<TAB>releaseDate`, Jira release order); without it no version counts as
released and the page says "release state unknown". The plan's own views sit folded below.

USAGE
    node scripts/jira/dist/index.js mirror
    node scripts/jira/dist/index.js versions > ~/.himmel/state/jira-mirror/HIMMEL.versions.tsv
    python3 tracker.py --plan-dir <HIMMEL-3882 plan dir> --out <tracker.html> --luna-map <luna-map.json>
        [--mirror-dir DIR] [--versions-file FILE] [--luna-root DIR] [--handovers DIR] [--jira-base-url URL] [--refresh-luna]
    python3 tracker.py ... --emit-fp     print the freshness fingerprint and exit
    python3 tracker.py --version <v> --out <page.html> [--priority-file PLAN] [--chains-file FILE] [--prs-file FILE]
        [--mirror-dir DIR] [--jira-base-url URL] [--plan-dir DIR --luna-root DIR [--handovers DIR]]
                                         the FOCUS page of one version (HIMMEL-6769): status columns, priority blocks,
                                         sectors, PR + CI, blockers, merge chains, per-column Jira parity on stdout

--versions-file defaults to <mirror-dir>.versions.tsv; its bytes (or '-' when missing) are a fingerprint input, so a
release moves tracker= to STALE.

Writes --out, the sidecar <out>.fp (the fingerprint tick.sh compares for tracker=) and
--luna-map (stdlib only).
"""
import argparse
import ast
import glob
import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from html import escape as esc

MIRROR = os.path.expanduser('~/.himmel/state/jira-mirror/HIMMEL')
LUNA = os.path.expanduser('~/Documents/luna')
HANDOVERS = ''
LAYERS = ['bugs', 'enhancements', 'features', 'misc', 'audit']
VER_RE = re.compile(r'^v1\.0\.(\d+)([a-z]?)$')  # a trail '<version>a', 'b', ... takes its parent's overflow (HIMMEL-4026)
# the train is every v1.N.x: v1.0.x, the v1.1.x line (ex v1.0.2b..h) and the milestone minors v1.2.0+.
TRAIN_RE = re.compile(r'^v1\.\d+\.\d+[a-z]?$')
SKIP_RE = re.compile(r'HIMMEL-3882|/dashboard|/artifacts|backlog|\.bak|/graphify-out/')
KEY_RE = re.compile(r'HIMMEL-\d+')
MAX_NOTES, TTL = 5, 7 * 86400
ROOT = OUT = LUNA_MAP = VERSIONS = ''
PLAN_FILES = ('meta.json', 'versions.tsv', 'placement.tsv', 'closures.tsv', 'unplaced.tsv')


def read_tsv(path):
    """Header line + rows; '#' lines skipped. Returns (header, rows as dicts, field counts)."""
    lines = [l.rstrip('\n') for l in open(path, encoding='utf-8') if not l.startswith('#')]
    lines = [l for l in lines if l.strip()]
    head = lines[0].split('\t')
    rows, nf = [], []
    for l in lines[1:]:
        f = l.split('\t')
        nf.append(len(f))
        rows.append(dict(zip(head, f)))
    return head, rows, nf


def plan_globs():
    """The stage1/stage2 row-field files and the placer's caps (layer caps, per-version overrides) the page reads."""
    return (sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))) +
            sorted(glob.glob(os.path.join(ROOT, 'stage1', 'themes-overlay.tsv'))) +
            [p for p in [os.path.join(ROOT, 'tools', 'stage3', f) for f in ('place.py', 'common.py')]
             if os.path.exists(p)])


# a ticket is in progress when a live leg works it. A leg doc is HIMMEL-<n>-N<k>-*.md in the
# bucket; it is live while its queue lock is held and fresh and its newest marker is not WRAPPED / HALTED.
LEG_RE = re.compile(r'^HIMMEL-(\d+)-(N\d+[a-z]?)-.*\.md$')
MARK_RE = re.compile(r'^- (?:\d{1,2}:\d{2}\s+)?(?:\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)(?:[^A-Za-z0-9_].*)?$')
PR_RE = re.compile(r'\b(?:PR|READY|GO)\s+#?(\d{3,5})\b')


def held_docs():
    """Realpaths of handover docs whose queue lock is held and fresh (heartbeat within queue-lock.sh's TTL).

    The lock dir is <handover root>/.locks/queue, found walking up from the bucket; none = no legs (read-only, no network)."""
    d, q = HANDOVERS, None
    for _ in range(4):
        if os.path.isdir(os.path.join(d, '.locks', 'queue')):
            q = os.path.join(d, '.locks', 'queue')
            break
        d = os.path.dirname(d)
    if not q:
        return set()
    ttl, now, out = int(os.environ.get('QUEUE_LOCK_TTL_SECONDS') or 21600), time.time(), set()
    for p in glob.glob(os.path.join(q, '*.lock', 'owner.json')):
        try:
            o = json.load(open(p, encoding='utf-8'))
        except (OSError, ValueError):
            continue
        try:
            age = now - datetime.strptime(o.get('heartbeat', ''), '%Y-%m-%dT%H:%M:%SZ').replace(
                tzinfo=timezone.utc).timestamp()
        except (ValueError, TypeError):
            age = 0  # an unparsable heartbeat is fresh, as queue-lock.sh status reads it
        if age <= ttl and o.get('handover'):
            out.add(os.path.realpath(o['handover']))
    return out


def leg_marker(path):
    """(marker, pr) from a leg doc's Results bullets: leg-tail-status.sh's rule, and the newest PR a marker bullet names."""
    try:
        ls = [l.rstrip('\n') for l in open(path, encoding='utf-8', errors='replace')]
    except OSError:
        return None, None
    rs = [i for i, l in enumerate(ls) if l.startswith('## Results')]
    bl = [l for l in ls[rs[-1] + 1 if rs else 0:] if l.startswith('- ')]
    pr = None
    for l in bl:
        if not MARK_RE.match(l):
            continue
        for m in PR_RE.finditer(l):
            pr = int(m.group(1))
    if not bl:
        return 'LIVE', pr
    m = MARK_RE.match(bl[-1])
    if m:
        return m.group(1), pr
    if re.search(r'(^|[^A-Za-z0-9_])WRAPPED([^A-Za-z0-9_]|$)', bl[-1]):
        return 'WRAPPED', pr
    ms = [MARK_RE.match(l) for l in bl]
    ms = [x.group(1) for x in ms if x]
    return (ms[-1] if ms else 'LIVE'), pr


def manifest_docs():
    """Leg docs listed in the console fleet manifests (<console doc>.fleet.json) next to the bucket's docs.

    A manifest lists the legs a console dispatched, so its legs are live without a queue lock of their own."""
    out = []
    for m in glob.glob(os.path.join(HANDOVERS, '*.fleet.json')):
        try:
            legs = json.load(open(m, encoding='utf-8')).get('legs') or []
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(legs, list):
            continue
        for lg in legs:
            d = lg.get('doc') if isinstance(lg, dict) else None
            if isinstance(d, str) and LEG_RE.match(os.path.basename(d)) and os.path.isfile(d):
                out.append(d)
    return sorted(out, key=lambda x: (os.path.getmtime(x), x))


def live_legs():
    """{ticket number: [leg label, marker, pr or None]} for live legs; the newest doc wins per ticket."""
    held, out = held_docs(), {}
    docs = [p for p in glob.glob(os.path.join(HANDOVERS, 'HIMMEL-*-N*-*.md')) if LEG_RE.match(os.path.basename(p))]
    for p in sorted(docs, key=lambda x: (os.path.getmtime(x), x)):
        if os.path.realpath(p) not in held:
            continue
        mk, pr = leg_marker(p)
        n, lab = LEG_RE.match(os.path.basename(p)).groups()
        out[int(n)] = [lab, mk, pr]
    for p in reversed(manifest_docs()):
        mk, pr = leg_marker(p)
        n, lab = LEG_RE.match(os.path.basename(p)).groups()
        out.setdefault(int(n), [lab, mk, pr])
    return {n: v for n, v in out.items() if v[1] not in ('WRAPPED', 'HALTED')}


TS_RE = re.compile(r'^- (\d{1,2}):(\d{2})\b')
DATE_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})')
IDLE_MIN = 180
ACT_NEWEST = 0.0  # newest mtime among the wrapped-leg docs actuals() last read (HIMMEL-4930)
# ponytail: no cost column (token spend per leg is not in the mirror or the leg doc); upgrade: mirror each PR's leg-burn
# line and add cost beside wall and active.
SOURCE = ('wall = first Results bullet to WRAPPED, dated from the leg doc\'s name (station clock, shown in UTC); '
          'active = the gaps between bullets of 3 h or less; dated = legs whose wall could be dated. '
          'cost: not measured (it needs the PR\'s leg-burn line in the mirror).')


def leg_docs():
    return sorted(glob.glob(os.path.join(HANDOVERS, 'HIMMEL-*-N*-*.md')) + glob.glob(os.path.join(HANDOVERS, 'logs', 'HIMMEL-*-N*-*.md')))


def leg_span(p, text):
    """(wall min or None, active min, start epoch or None, end epoch or None) of one leg doc's Results bullets (HIMMEL-5453).

    Bullets carry only the station's local HH:MM: the doc name's date dates the first one and each backwards step of the
    clock is the next day. A doc name with no date gives no wall, only active minutes.
    ponytail: a silent gap over 24 h between two bullets reads as under 24 h; upgrade: date each bullet from the luna
    commit that first holds it."""
    ls = text.partition('\n## Results')[2].split('\n## ')[0].splitlines()
    w = [i for i, l in enumerate(ls) if (m := MARK_RE.match(l)) and m.group(1) == 'WRAPPED']
    ts = [int(x.group(1)) * 60 + int(x.group(2)) for x in (TS_RE.match(l) for l in ls[:w[-1] + 1 if w else None]) if x]
    ab, day = [], 0
    for i, t in enumerate(ts):
        if i and t < ts[i - 1]:
            day += 1
        ab.append(day * 1440 + t)
    active = sum(g for g in (b - a for a, b in zip(ab, ab[1:])) if g <= IDLE_MIN)
    d = DATE_RE.findall(os.path.basename(p))
    if not ab or not d:
        return None, active, None, None
    y, mo, dd = (int(x) for x in d[-1])

    def epoch(m):
        return time.mktime((y, mo, dd + m // 1440, (m % 1440) // 60, m % 60, 0, 0, 0, -1))
    s, e = epoch(ab[0]), epoch(ab[-1])
    return int(round((e - s) / 60)), active, s, e


def actuals():
    """{ticket number: [wrapped legs, wall min, active min, dated legs, first start epoch, last end epoch]} (HIMMEL-5453):
    what the done work actually took, to measure the estimates against. leg_span() says how each number is measured."""
    global ACT_NEWEST
    out = {}
    ACT_NEWEST = 0.0
    for p in leg_docs():
        m = LEG_RE.match(os.path.basename(p))
        if not m or leg_marker(p)[0] != 'WRAPPED':
            continue
        try:
            text = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        wall, active, s, e = leg_span(p, text)
        r = out.setdefault(int(m.group(1)), [0, 0, 0, 0, None, None])
        r[0] += 1
        r[2] += active
        if wall is not None:
            r[1] += wall
            r[3] += 1
            r[4] = s if r[4] is None else min(r[4], s)
            r[5] = e if r[5] is None else max(r[5], e)
        try:
            ACT_NEWEST = max(ACT_NEWEST, os.path.getmtime(p))
        except OSError:
            pass
    return out


# who filed what. A leg doc's Results bullet saying "filed HIMMEL-m" spawned m from the leg's ticket; a
# console doc's OPERATOR bullet (not a RULING, IS AWAKE or ITEMS line) saying "Filed HIMMEL-m" makes m operator-directed.
# Only the ticket key is read, never the bullet's clock time.
FILED_RE = re.compile(r'(?i)\bfiled\s+((?:HIMMEL-\d+(?:\s*(?:,|\+|&|and)\s*)?)+)')
OPER_RE = re.compile(r'^- (?:\d{1,2}:\d{2}\s+)?\**OPERATOR\b(?!\**\s*(?:RULINGS?|IS AWAKE|ITEMS)\b)')


def filed_keys(line):
    return [int(k) for g in FILED_RE.findall(line) for k in re.findall(r'HIMMEL-(\d+)', g)]


def filings():
    """({spawned ticket number: filing leg's ticket number}, {operator-directed ticket numbers}) from the handover docs."""
    leg, op = {}, set()
    for p in leg_docs():
        m = LEG_RE.match(os.path.basename(p))
        if not m:
            continue
        n = int(m.group(1))
        try:
            text = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for l in text.partition('\n## Results')[2].split('\n## ')[0].splitlines():
            if l.startswith('- '):
                for k in filed_keys(l):
                    if k > n:  # an origin is always the older ticket
                        leg.setdefault(k, n)
    for p in sorted(glob.glob(os.path.join(HANDOVERS, '*console*.md')) + glob.glob(os.path.join(HANDOVERS, 'logs', '*console*.md'))):
        try:
            ls = open(p, encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            continue
        for l in ls:
            if OPER_RE.match(l):
                op.update(filed_keys(l))
    return leg, op


# A description or title naming the ticket this one came from. The first hit by position wins; it must be older.
ORIGIN_RE = re.compile(r'(?i)\[(HIMMEL-\d+)\s+follow-?up\]|(HIMMEL-\d+)\s+follow-?up|'
                       r'\b(?:deferred|spun out|split out|carved out|spawned|follow-?up|followup)\b'
                       r'(?:\s+(?:from|of|to|for|on))?[^\n.]{0,60}?(HIMMEL-\d+)|\bfrom\s+(HIMMEL-\d+)')


def origin_ref(n, text):
    for m in ORIGIN_RE.finditer(text):
        k = num(next(g for g in m.groups() if g))
        if k < n:
            return k
    return None


def bundles(mir, planned, op, leg_filed):
    """{ticket number: anchor} for every unplanned ticket that reaches one (HIMMEL-5453): a planned ticket number, or 'op'.

    A ticket's origin is, first hit wins: its mirror parent (never an Epic) or a relates link, a description or title
    reference, the leg doc that filed it. Origins are strictly older, so the walk up a chain always ends; it stops at
    the first planned or operator-directed ticket. Operator-directed tickets are anchors of their own bundle."""
    org = {}
    for k, m in mir.items():
        n = num(k)
        par = num(m['parent']) if m.get('parent') else None
        if par and par < n and (mir.get('HIMMEL-%d' % par) or {}).get('type') != 'Epic':
            org[n] = par
            continue
        rel = [x for x in m.get('rel', []) if x < n]
        o = rel[0] if rel else origin_ref(n, m.get('otext', ''))
        if o is None:
            o = leg_filed.get(n)
        if o is not None:
            org[n] = o
    out = {}
    for k in mir:
        n = num(k)
        if n in planned:
            continue
        c = n
        while c not in planned and c not in op and c in org:
            c = org[c]
        if c in planned:
            out[n] = c
        elif c in op:
            out[n] = 'op'
    return out


def fingerprint():
    """16 hex over the mirror's newest `updated:`, the plan + stage1/stage2 files' bytes, the versions file, the live legs
    and the wrapped legs' actuals and the handover docs' filings (what the page shows)."""
    upd = ''
    for p in glob.glob(os.path.join(MIRROR, 'HIMMEL-*.md')):
        for l in open(p, encoding='utf-8', errors='replace'):
            if l.startswith('updated:'):
                upd = max(upd, l.split(':', 1)[1].strip().strip('"'))
                break
    h = hashlib.sha256(upd.encode() + b'\n')
    for f in PLAN_FILES:
        p = os.path.join(ROOT, 'stage3', f)
        h.update(open(p, 'rb').read() if os.path.exists(p) else b'-')
    for p in plan_globs():
        h.update(open(p, 'rb').read())
    h.update(open(VERSIONS, 'rb').read() if os.path.isfile(VERSIONS) else b'-')
    h.update(json.dumps(sorted(live_legs().items())).encode())
    h.update(json.dumps(sorted(actuals().items())).encode())
    lf, op = filings()
    h.update(json.dumps([sorted(lf.items()), sorted(op)]).encode())
    return h.hexdigest()[:16]


def plan_rules(meta):
    """Capacity rules as the plan records them: meta.json notes + the placer's CAPS. None = not recorded."""
    txt = ' '.join(n for n in meta.get('notes', []) if isinstance(n, str))

    def val(pat):
        m = re.search(pat, txt)
        return float(m.group(1)) if m else None
    sm = re.search(r'S-eq:\s*XS\s*([\d.]+)\s+S\s+([\d.]+)\s+M\s+([\d.]+)\s+L\s+([\d.]+)\s+XL\s+([\d.]+)', txt)
    def lit(f, name):
        """A top-level `name = {...}` literal from the plan tool, single- or multi-line; never executed."""
        try:
            tree = ast.parse(open(os.path.join(ROOT, 'tools', 'stage3', f), encoding='utf-8').read())
            vs = [ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == name for t in n.targets)]
            v = vs[-1] if vs else None
        except (OSError, ValueError, SyntaxError, TypeError):
            v = None
        return v if isinstance(v, dict) else None
    em = meta.get('effort_model') if isinstance(meta.get('effort_model'), dict) else {}

    def emv(k):
        return em[k] if isinstance(em.get(k), (int, float)) else None
    # Effort model B words the caps "a version holds < N" / "total mean load within X" and carries
    # the bank rate as effort_model.bank_per_seq; the older wording still parses.
    return dict(tickets=val(r'(?:ticket count|version holds)\s*<\s*(\d+)'), total=val(r'total (?:mean )?load within\s*([\d.]+)'),
                per=emv('bank_per_seq') if emv('bank_per_seq') is not None else val(r'effort_mid\s*x\s*([\d.]+)'),
                seq=[float(x) for x in sm.groups()] if sm else None,
                layers=lit('place.py', 'CAPS'), over=lit('common.py', 'VERSION_CAP_OVERRIDES') or {},
                p90=emv('p90_cap'), model=bool(em))


def intg(x):
    return int(x) if isinstance(x, float) and x.is_integer() else x


def ver_key(v):
    """Plan order (HIMMEL-3990): v1.0.1 < v1.0.1b < v1.0.2 < v1.0.10; buckets such as v2/v3 follow the train."""
    m = VER_RE.match(v)
    if m:
        return (0, int(m.group(1)), m.group(2))
    m = re.match(r'^v1\.1\.(\d+)$', v)
    if m:
        return (0, 2, chr(ord('b') + int(m.group(1))))
    m = re.match(r'^v1\.([2-9]|\d{2,})\.(\d+)([a-z]?)$', v)  # HIMMEL-4873: the milestone minors follow, numerically
    return (0, 1000 + int(m.group(1)), '%012d%s' % (int(m.group(2)), m.group(3))) if m else (1, 0, '')


def trail_parent(v):
    """The version a trail continues ('v1.0.2b' -> 'v1.0.2'); None for anything else."""
    m = VER_RE.match(v)
    return 'v1.0.' + m.group(1) if m and m.group(2) else None


def vlabel(v):
    """A trail reads as its parent's overflow, not a new release (the page's vname() says the same)."""
    m = VER_RE.match(v)
    if not (m and m.group(2)):
        return v
    k = ord(m.group(2)) - ord('a')
    return 'v1.0.%s · overflow%s' % (m.group(1), '' if k <= 1 else ' %d' % k)


def version_caps(r, vers, released=()):
    """Per-version caps (HIMMEL-3979): the plan default with its VERSION_CAP_OVERRIDES applied; None = deferred bucket.
    A trail keeps its parent's caps, overrides included, unless the overrides name the trail itself.
    A released version has none (HIMMEL-4930): its tickets already shipped, so a cap there is not a decision."""
    out = []
    for v in vers:
        if v in released or not TRAIN_RE.match(v):
            out.append(None)
            continue
        ov = r['over'].get(v if v in r['over'] else trail_parent(v)) or {}
        out.append(dict(t=intg(ov.get('tickets', r['tickets'])), tot=ov.get('total', r['total']),
                        l=[ov.get(l, (r['layers'] or {}).get(l)) for l in LAYERS], p9=r['p90']))
    return out


def capacity_text(r, deferred, trails=()):
    """Plain-language cap panel lines; a rule the plan does not record says so instead of guessing."""
    nr = 'not recorded in the plan'
    parts = ['at most %d tickets' % r['tickets'] if r['tickets'] is not None else 'a ticket cap ' + nr,
             'at most %g bank of load' % r['total'] if r['total'] is not None else 'a load cap ' + nr]
    out = ['Each v1.0.x version holds ' + ' and '.join(parts) + '; the plan puts every ticket in the earliest version with room.']
    for v in sorted(r['over']):
        ov = r['over'][v] if isinstance(r['over'][v], dict) else {}
        ps = (['at most %d tickets' % ov['tickets']] if 'tickets' in ov else []) + \
             (['at most %g bank of load' % ov['total']] if 'total' in ov else []) + \
             ['a %s cap of %.2f' % (l, ov[l]) for l in LAYERS if l in ov]
        if ps:
            out.append('%s holds %s (a plan override of the default).' % (v, ' and '.join(ps)))
    if trails:
        out.append('A trail version such as %s takes the overflow of %s and keeps its caps, overrides included, '
                   'unless the plan names the trail; later versions are never renumbered.' % (trails[0], trail_parent(trails[0])))
    if r['p90'] is not None:
        out.append('Likely load is the average outcome; cautious load is the level 9 times in 10 stay under (P90). '
                   'Each version keeps its cautious load within %g bank.' % r['p90'])
    lc = r['layers']
    out.append('Layer caps, in bank: ' + ' · '.join('%s %.2f' % (l, lc[l]) for l in LAYERS if l in lc) + '.'
               if lc else 'Layer caps: ' + nr + '.')
    out.append(('Load = the average effort in S-equivalents, overruns included, × %g bank; a plan-first ticket counts only its slice.'
                if r['model'] else 'Load = effort in S-equivalents × %g bank; a plan-first ticket counts only its slice.') % r['per']
               if r['per'] is not None else 'How load is derived from effort: ' + nr + '.')
    out += ['%s is a deferred bucket: no caps apply.' % v for v in deferred]
    return out


def drift_log(path, drift, unplanned, unthemed):
    """Append this render's counts to the drift log when they changed or the last row is over an hour old; return the
    last 30 rows as [stamp, drift, unplanned, unthemed]. An unwritable log just yields no new row."""
    path = path or os.path.join(HANDOVERS, 'roadmap-drift.tsv')
    rows = []
    try:
        for l in open(path, encoding='utf-8').read().splitlines()[1:]:
            f = l.split('\t')
            if len(f) == 4 and all(x.isdigit() for x in f[1:]):
                rows.append([f[0]] + [int(x) for x in f[1:]])
    except OSError:
        pass
    now = datetime.now(timezone.utc)
    cur = [now.strftime('%Y-%m-%dT%H:%M:%SZ'), drift, unplanned, unthemed]
    fresh = False
    if rows:
        try:
            fresh = (now - datetime.strptime(rows[-1][0], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)).total_seconds() < 3600
        except ValueError:
            pass
    if not rows or rows[-1][1:] != cur[1:] or not fresh:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            new = not os.path.exists(path) or os.path.getsize(path) == 0
            with open(path, 'a', encoding='utf-8') as fh:
                if new:
                    fh.write('utc\tdrift\tunplanned\tunthemed\n')
                fh.write('\t'.join(str(x) for x in cur) + '\n')
            rows.append(cur)
        except OSError:
            pass
    return rows[-30:]


def ledger_lines(rows, vers, unthemed=0, released=()):
    """Header ledger (HIMMEL-3957): the running version, the whole v1.0.x train, and drift/unplanned only when non-zero."""
    train = [i for i, v in enumerate(vers) if TRAIN_RE.match(v)]

    def line(label, sel):
        a = [r for r in rows if r[3] in sel]
        t = [sum(1 for r in a if r[2] == s) for s in (0, 1, 2)]
        return '%s%d of %d done (%d %%), %d in progress, %d to do.' % (
            label, t[2], len(a), int(100.0 * t[2] / len(a) + 0.5) if a else 0, t[1], t[0])
    cur = next((i for i in train if vers[i] not in released and any(r[3] == i and r[2] != 2 for r in rows)), None)
    out = [line('Plan rows placed in %s (not Jira progress): ' % vlabel(vers[cur]), {cur}) if cur is not None
           else 'Plan rows placed: no unreleased v1.0.x version has open plan rows.', line('Plan rows placed in the whole v1.0.x train (not Jira progress): ', set(train))]
    dr = sum(1 for r in rows if r[3] in train and r[7] == 1)
    un = sum(1 for r in rows if r[3] in train and r[7] == 2 and r[2] != 2)
    att = []
    if dr:
        att.append('%d %s from the plan (Jira names another version)' % (dr, 'ticket drifted' if dr == 1 else 'tickets drifted'))
    if un:
        att.append('%d open %s in a version but not in the plan' % (un, 'ticket sits' if un == 1 else 'tickets sit'))
    if unthemed:
        att.append('%d open %s no sector' % (unthemed, 'ticket has' if unthemed == 1 else 'tickets have'))
    if att:
        out.append('Needs attention: ' + '; '.join(att) + '.')
    return out, cur


def num(key):
    return int(key.split('-')[1])


# the Jira-first view. Buckets come from the status NAME (statusCategory only for a name not listed).
BUCKETS = {'to do': 'todo', 'backlog': 'todo', 'in progress': 'prog', 'in review': 'rev', 'ci': 'ci', 'in ci': 'ci',
           'done': 'done', 'closed': 'wont', 'in public': 'done', 'wont do': 'wont', 'wont fix': 'wont'}
SHIPPED = ('', 'done', 'fixed')


def bucket(m):
    """'wont' is every closed-without-shipping state: Closed, wont do/fix, or Done with a resolution other than Done/Fixed."""
    b = BUCKETS.get(m['sn'].strip().lower()) or {'Done': 'done', 'In Progress': 'prog'}.get(m['cat'], 'todo')
    return 'wont' if b == 'done' and m['res'].strip().lower() not in SHIPPED else b


def read_versions(path, mir, train_only=True):
    """(versions, release state unknown): [{n, rel, date}] in Jira release order from a `jira versions` snapshot.

    v1.0.0 and non-v1.0.x names are not rows (every name is a row with train_only False). A missing, empty or row-less
    file lists the mirror's v1.0.x fixVersions, none released."""
    ok = TRAIN_RE.match if train_only else re.compile(r'^v\d+\.\d+\.\d+').match
    try:
        lines = [l.rstrip('\n').split('\t') for l in open(path, encoding='utf-8')]
    except OSError:
        lines = []
    if not any(len(f) >= 2 and ok(f[0]) and f[0] != 'v1.0.0' for f in lines):
        names = sorted({v for m in mir.values() for v in m['fv'] if TRAIN_RE.match(v) and v != 'v1.0.0'}, key=ver_key)
        return [dict(n=v, rel=False, date='') for v in names], True
    return [dict(n=f[0], rel=f[1] == 'true', date=f[2] if len(f) > 2 else '') for f in lines
            if len(f) >= 2 and ok(f[0]) and f[0] != 'v1.0.0'], False


def earliest_unreleased(vers):
    """The earliest unreleased version by release date, else the first unreleased listed; None when all are released."""
    unrel = [v for v in vers if not v['rel']]
    return min((v for v in unrel if v['date']), key=lambda v: v['date'], default=unrel[0] if unrel else None)


def done_in_future(mir, vers, unknown):
    """Done tickets carrying an unreleased version other than the current one (HIMMEL-5801); must be 0.

    The current version is the earliest unreleased by release date, else the first unreleased listed. Release
    state unknown counts nothing."""
    if unknown:
        return 0
    unrel = [v for v in vers if not v['rel']]
    cur = earliest_unreleased(vers)
    if cur is None:
        return 0
    fut = {v['n'] for v in unrel} - {cur['n']}
    return sum(1 for m in mir.values() if bucket(m) == 'done' and any(f in fut for f in m['fv']))


def jira_cli():
    """TRACKER_JIRA (test seam), else the primary checkout's Jira CLI: a worktree has no dist/."""
    if os.environ.get('TRACKER_JIRA'):
        return os.environ['TRACKER_JIRA']
    here = os.path.dirname(os.path.abspath(__file__))
    scrub = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
             'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX',
             'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE',
             'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT']
    env = {k: v for k, v in os.environ.items() if k not in scrub}
    try:
        common = subprocess.run(['git', '-C', here, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                env=env, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        common = ''
    root = os.path.dirname(common) if common else os.path.join(here, '..', '..', '..')
    return os.path.join(root, 'scripts', 'jira', 'dist', 'index.js')


def jira_parity(tk, vers, cur):
    """One live `jira list` for the version worked on, its per-bucket counts against the hero's.

    Closed and wont do are in neither count; IN CI counts as in review. Any CLI failure or garbled answer reads
    unavailable, never a render failure."""
    if cur < 0:
        return 'parity: unavailable (no version worked on)'
    v, cli = vers[cur]['n'], jira_cli()
    cmd = (['node', cli] if cli.endswith('.js') else [cli]) + [
        'list', '--jql', 'project = HIMMEL AND fixVersion = "%s" AND NOT (statusCategory = Done AND resolution is not EMPTY '
        'AND resolution not in (Done, Fixed))' % v, '--limit', '5000']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, JIRA_PROJECT_KEY=os.environ.get('JIRA_PROJECT_KEY') or 'HIMMEL'))
    except (OSError, subprocess.SubprocessError):
        return 'parity: %s unavailable' % v
    lines = [l.split('\t') for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or any(len(f) < 3 or not KEY_RE.fullmatch(f[0])
                                or f[2].strip().lower() not in BUCKETS for f in lines):
        return 'parity: %s unavailable' % v
    order = ('done', 'prog', 'rev', 'todo')

    def tally(bs):
        c = {b: 0 for b in order}
        for b in bs:
            if b != 'wont':
                c['rev' if b == 'ci' else b] += 1
        return '/'.join(str(c[b]) for b in order)
    rank = {'todo': 0, 'prog': 1, 'rev': 2, 'ci': 2, 'done': 3}
    pg = {t['k']: (t['b'], t['s']) for t in tk if t['v'] == cur}
    jr = {num(f[0]): (BUCKETS[f[2].strip().lower()], f[2].strip()) for f in lines if BUCKETS[f[2].strip().lower()] != 'wont'}
    page = tally(b for b, _ in pg.values())
    jira = tally(b for b, _ in jr.values())
    tail = ' (done/in progress/in review/to do)'
    diff = [k for k in sorted(set(pg) | set(jr)) if k not in pg or k not in jr or rank[pg[k][0]] != rank[jr[k][0]]]
    if not diff:
        return 'parity: %s ok %s%s' % (v, page, tail)
    # a page status earlier in the workflow than Jira's is the mirror trailing a live move; anything else is a real mismatch
    lag = all(k not in pg or (k in jr and rank[pg[k][0]] < rank[jr[k][0]]) for k in diff)
    names = ', '.join('HIMMEL-%d page %s jira %s' % (k, pg[k][1] if k in pg else '(absent)', jr[k][1] if k in jr else '(absent)')
                      for k in diff[:8]) + (' (+%d more)' % (len(diff) - 8) if len(diff) > 8 else '')
    return 'parity: %s %s page %s jira %s%s: %s' % (v, 'lag' if lag else 'DRIFT', page, jira, tail, names)


def jira_view(mir, legs, vers, prows, vnames, target=None):
    """The version-first page data: JT tickets, JC working-on, JN up-next, JA released-but-open alerts.

    prows are the plan's placed rows (user impact is col 9, plan version col 3), vnames the plan's version names.
    target is the index of the version worked on when the caller fixes it (else the first unreleased one holding open work)."""
    vi = {v['n']: i for i, v in enumerate(vers)}
    plan = {r[0]: r for r in prows}
    tk, wont, fl = [], {}, []
    for k, m in mir.items():
        hit = [v for v in m['fv'] if v in vi]
        b, p = bucket(m), plan.get(num(k))
        if not m['fv'] and b in ('prog', 'rev', 'ci'):
            fl.append(dict(k=num(k), t=clip(m['title'], 90), s=m['sn'] or m['cat'], ln=first_sentence(m['impact']) or clip(m['title'], 160)))
        for v in hit:
            if b == 'wont':
                wont[vi[v]] = wont.get(vi[v], 0) + 1
                continue
            lg = legs.get(num(k))
            tk.append(dict(k=num(k), t=clip(m['title'], 90), s=m['sn'] or m['cat'], b=b, v=vi[v],
                           ui=(p[9] if p else '') or '', pv=vnames[p[3]] if p else None, ln=first_sentence(m['impact']) or clip(m['title'], 160),
                           leg=lg if b not in ('done', 'wont') else None, live=bool(lg and b == 'todo')))
    tk.sort(key=lambda t: t['k'])

    def open_(t):
        return t['b'] not in ('done', 'wont')

    cur = target if target is not None else \
        next((i for i in range(len(vers)) if not vers[i]['rel'] and any(t['v'] == i and open_(t) for t in tk)), -1)

    def future_done(t):
        return t['b'] == 'done' and cur >= 0 and t['v'] > cur and not vers[t['v']]['rel']
    placed, kept = {t['k'] for t in tk if not future_done(t)}, []
    for t in tk:  # a Done ticket already counted in another version keeps that one, never a second row in the current
        if future_done(t):
            if t['k'] in placed:
                continue
            placed.add(t['k'])
            t['v'] = cur
        kept.append(t)
    tk = kept
    nxt = next((i for i in range(len(vers)) if i > cur and not vers[i]['rel'] and any(t['v'] == i for t in tk)), -1)
    al = [[i, [t['k'] for t in tk if t['v'] == i and open_(t)]] for i in range(len(vers)) if vers[i]['rel']]
    return tk, cur, nxt, [a for a in al if a[1]], sorted([i, n] for i, n in wont.items()), sorted(fl, key=lambda t: t['k'])

GROUP_NAMES = ['0 critical', '1K knowledge retrieval', '1 data freshness', '2 rules, truth and eval', '3 CI throughput',
               '4 PS3 blockers', '5 structural guards', '6 stability bugs', '7 console offload', '8 cost']
PRIO_KEY_RE = re.compile(r'(?<![\w.])(?:HIMMEL-)?(\d{2,5})(?![\d.])')


def priority_groups(path):
    """[(group name, [ticket numbers in dispatch order])] from the plan's `priority:` line, or [] without one.

    The line is the first non-blank line after the one naming "`priority:` line", or a line starting `priority:`; `|`
    separates groups. The last two segments are the rest-of-version marker and the bottom pair; tokens with no number
    (K1, SCORECARD) hold no key."""
    try:
        lines = open(path, encoding='utf-8').read().splitlines()
    except OSError:
        return []
    line = ''
    for i, l in enumerate(lines):
        if l.startswith('priority:'):
            line = l[len('priority:'):]
            break
        if l.startswith('`priority:` line'):
            line = next((x for x in lines[i + 1:] if x.strip()), '')
            break
    segs = [x for x in line.split('|')]
    if len(segs) < 3:
        return []
    names = GROUP_NAMES[:len(segs) - 2] + ['rest of version'] + ['bottom']
    return [(n, [int(k) for k in PRIO_KEY_RE.findall(sg)]) for n, sg in zip(names, segs)]


_KEYS = r'(HIMMEL-\d+(?:\s*(?:,(?:\s*and)?|and|\+)\s*HIMMEL-\d+)*)'
# a ticket's own dependency line: `Depends on` / `Blocked by` at line start (after a list bullet), or a `Links:` line
# naming one. Prose about another ticket, a quoted command and a negated mention never start a line with the phrase.
_DEP_RE = re.compile(r'^\s*(?:[-*]\s+)?[*_]*(?:links\s*:.*?)?(?:depends\s+on|blocked[\s-]*by)[*_]*\s*:?[*_]*\s*' + _KEYS,
                     re.I | re.M)
_AFTER_RE = re.compile(r'\bafter\s+' + _KEYS, re.I)


def description(m):
    """The ticket's description alone: no title heading, no comments."""
    return re.sub(r'^# [A-Z]+-\d+:.*$', '', m['otext'].split('\n', 1)[-1], count=1, flags=re.M)


def dep_keys(m, rx=_DEP_RE):
    return [num(x) for hit in rx.findall(description(m)) for x in KEY_RE.findall(hit)]


def blocker_list(mir, n):
    """HIMMEL-6556: [(blocker number, open|done|wont|direction?)] for ticket n.

    Blockers are the mirror's links.blocked_by plus the description's own dependency lines (_DEP_RE). A closed blocker
    reads done or wont by its bucket; a link blocker whose own text puts it after this ticket (its dependency line or an
    `after HIMMEL-n` names n) reads direction?, never open; any other reads open (a key missing from the mirror too)."""
    m = mir['HIMMEL-%d' % n]
    ks = list(m['blk']) + dep_keys(m)
    out = []
    for k in [k for i, k in enumerate(ks) if k not in ks[:i]]:
        b = mir.get('HIMMEL-%d' % k)
        st = bucket(b) if b else 'open'
        if st not in ('done', 'wont'):
            st = 'direction?' if b and k in m['blk'] and n in dep_keys(b) + dep_keys(b, _AFTER_RE) else 'open'
        out.append((k, st))
    return out


def blockers(mir, n):
    """' {blocked-by: HIMMEL-n open, HIMMEL-m done}' for ticket n's blockers, or ''."""
    bl = blocker_list(mir, n)
    return ' {blocked-by: %s}' % ', '.join('HIMMEL-%d %s' % x for x in bl) if bl else ''


def priority_rows(keys, groups):
    """(group names, {name: [ticket numbers]}): each key in the first group naming it, else 'rest of version'."""
    placed = set()
    names = [g[0] for g in groups] or ['rest of version']
    rows = {n: [] for n in names}
    for n, gk in groups:
        for k in gk:
            if k in keys and k not in placed:
                placed.add(k)
                rows[n].append(k)
    rows['rest of version' if 'rest of version' in rows else names[0]] += sorted(k for k in keys if k not in placed)
    return names, rows


def remaining_board(mir, version, groups):
    """Markdown of the open tickets whose fixVersion includes `version`, grouped by the plan's priority groups.

    Done, Closed, In Public and wont do/fix tickets are left out. A ticket on no group line goes to 'rest of version'
    (and in the rest group, ahead of the bottom group); a ticket named in two groups stays in the first."""
    opn = {num(k): m for k, m in mir.items()
           if version in m['fv'] and bucket(m) not in ('done', 'wont')}
    names, rows = priority_rows(opn, groups)
    out = ['# %s remaining board: %d open' % (version, len(opn))]
    for n in names:
        if rows[n]:
            out.append('\n## %s (%d)' % (n, len(rows[n])))
            out += ['- HIMMEL-%d [%s] %s%s' % (k, opn[k]['sn'] or opn[k]['cat'], clip(opn[k]['title'], 90), blockers(mir, k))
                    for k in rows[n]]
    return '\n'.join(out) + '\n'


def first_sentence(s):
    """HIMMEL-5381: the first sentence of a plain Impact block ('' for none), clipped for a card."""
    m = re.match(r'(.+?[.!?])(?:\s|$)', s)
    return clip(m.group(1) if m else s, 160)


KCOLS = (('todo', 'To Do'), ('prog', 'In Progress'), ('rev', 'In Review'), ('ci', 'IN CI'), ('done', 'Done'))
KCOL_OF = {'todo': 'todo', 'prog': 'prog', 'rev': 'rev', 'ci': 'ci', 'done': 'done'}


def kanban(tk, vers, cur, base, wont=(), flight=()):
    """HIMMEL-5381: one <details> per release with tickets, holding a 5-column board (To Do, In Progress, In Review, IN CI, Done).

    A card links to <base>/browse/<key> (plain text when no base URL is configured) with the summary and the ticket's
    one-line user-facing description. closed-without-shipping tickets are not on the board (wont[i] is their count); a To Do ticket a live leg works reads
    In Progress, as the main board does. The release being worked on (cur) opens expanded."""
    base = base.strip().rstrip('/')
    if not re.match(r'^https?://', base):
        base = ''
    out, wn = [], dict(wont)
    for i, v in enumerate(vers):
        a = [t for t in tk if t['v'] == i]
        if not a and not wn.get(i):
            continue
        cols = {c: [] for c, _ in KCOLS}
        for t in a:
            cols[KCOL_OF['prog' if t['live'] else t['b']]].append(t)
        n_open = len(a) - len(cols['done'])
        parts = ['<details class="krel"%s data-v="%s"><summary><span class="vn">%s</span> '
                 '<span class="kmeta">%d open of %d%s%s</span></summary><div class="kboard">'
                 % (' open' if i == cur else '', esc(v['n']), esc(v['n']), n_open, len(a),
                    ' · released ' + esc(v['date']) if v['rel'] else '',
                    ' · %d closed without shipping' % wn[i] if wn.get(i) else '')]
        for c, title in KCOLS:
            parts.append('<div class="kcol" data-col="%s"><h3>%s <span class="kn">%d</span></h3>' % (c, title, len(cols[c])))
            for t in cols[c]:
                key = 'HIMMEL-%d' % t['k']
                head = ('<a class="kkey" href="%s/browse/%s">%s</a>' % (esc(base, True), key, key)) if base \
                    else '<span class="kkey">%s</span>' % key
                parts.append('<div class="kcard">%s<div class="ktl">%s</div><div class="kline">%s</div></div>'
                             % (head, esc(t['t']), esc(t['ln'])))
            if not cols[c]:
                parts.append('<div class="knone">None.</div>')
            parts.append('</div>')
        parts.append('</div></details>')
        out.append(''.join(parts))
    if flight:  # HIMMEL-5217: open work in progress or review that no version holds yet
        cards = ''.join('<div class="kcard">%s<div class="ktl">%s</div><div class="kline">%s</div></div>'
                        % (('<a class="kkey" href="%s/browse/HIMMEL-%d">HIMMEL-%d</a>' % (esc(base, True), t['k'], t['k'])) if base
                           else '<span class="kkey">HIMMEL-%d</span>' % t['k'], esc(t['t']), esc(t['s'])) for t in flight)
        out.append('<details class="krel" open data-v=""><summary><span class="vn">In flight, no version</span> '
                   '<span class="kmeta">%d open</span></summary><div class="kboard">%s</div></details>' % (len(flight), cards))
    return ''.join(out) or '<p class="jsub">No release holds a ticket yet.</p>'


def clip(s, n):
    s = ' '.join(s.split())
    return s if len(s) <= n else s[:n - 1] + '…'


_PLAIN_HEAD = re.compile(r'^\s{0,3}(?:#{1,6}\s+)?[*_`]*(impact|what|why|agent detail)[*_`]*\s*:?\s*$', re.I)


def plain_impact(body):
    """HIMMEL-5226: the ticket's plain `Impact` section (up to the next heading; fenced code never starts or ends it), or ''.
    The mirror renders ADF headings as bare lines, a markdown body keeps its `##`; both are matched."""
    desc = body.split('\n## Comments', 1)[0]
    out, on, fence = [], False, ''
    for line in desc.splitlines():
        fm = re.match(r'^\s{0,3}(`{3,}|~{3,})(.*)$', line)
        if fm:
            f = fm.group(1)
            if not fence:
                fence = f
            elif f[0] == fence[0] and len(f) >= len(fence) and not fm.group(2).strip():
                fence = ''
            if on:
                out.append(line)
            continue
        if fence:
            if on:
                out.append(line)
            continue
        m = _PLAIN_HEAD.match(line)
        if m:
            if on:
                break
            on = m.group(1).lower() == 'impact'
        elif on and re.match(r'^\s{0,3}#{1,6}\s', line):
            break
        elif on:
            out.append(line)
    return ' '.join(' '.join(out).split())


def read_mirror():
    """{key: dict(st, sn, cat, fv, upd, title, type, impact, labels, parent, rel, otext)} from the mirror; sn is the Jira
    status name, cat its category, res its resolution ('' when none); rel the relates-linked ticket numbers, otext the title and description (HIMMEL-5453)."""
    out = {}
    for p in glob.glob(os.path.join(MIRROR, 'HIMMEL-*.md')):
        txt = open(p, encoding='utf-8', errors='replace').read()
        parts = txt.split('---', 2)
        if len(parts) < 3:
            continue
        fm, sub, rel, blk = {}, '', [], []
        for l in parts[1].splitlines():
            if ':' in l and not l.startswith(' '):
                k, v = l.split(':', 1)
                fm[k.strip()] = v.strip()
                sub = ''
            elif l.startswith('  ') and not l.startswith('   ') and ':' in l:
                sub = l.split(':', 1)[0].strip()
                if sub == 'relates':
                    rel += [num(x) for x in KEY_RE.findall(l)]
                elif sub == 'blocked_by':
                    blk += [num(x) for x in KEY_RE.findall(l)]
            elif sub == 'relates':
                rel += [num(x) for x in KEY_RE.findall(l)]
            elif sub == 'blocked_by':
                blk += [num(x) for x in KEY_RE.findall(l)]
        key = fm.get('key', '').strip('"')
        if not key:
            continue
        m = re.search(r'^# [A-Z]+-\d+:\s*(.*)$', parts[2], re.M)
        try:
            fv = json.loads(fm.get('fixVersions', '[]'))
        except ValueError:
            fv = []
        try:
            lab = json.loads(fm.get('labels', '[]'))
        except ValueError:
            lab = []
        try:
            par = json.loads(fm.get('parent', 'null'))
        except ValueError:
            par = None
        cat = fm.get('statusCategory', '').strip('"')
        try:
            sn = json.loads(fm.get('status', '""'))
        except ValueError:
            sn = ''
        try:
            res = json.loads(fm.get('resolution', 'null'))
        except ValueError:
            res = None
        try:
            sec = json.loads(fm.get('sector', 'null'))
        except ValueError:
            sec = None
        out[key] = dict(sector=sec if isinstance(sec, str) else '',st=2 if cat == 'Done' else 1 if cat == 'In Progress' else 0, sn=sn if isinstance(sn, str) else '', cat=cat, fv=fv,
                        res=res if isinstance(res, str) else '',
                        upd=fm.get('updated', '').strip('"'), title=m.group(1) if m else '',
                        type=fm.get('type', '').strip('"'), impact=plain_impact(parts[2]),
                        labels=lab if isinstance(lab, list) else [], parent=par if isinstance(par, str) and KEY_RE.fullmatch(par) else '',
                        rel=rel, blk=blk, otext=(m.group(1) if m else '') + '\n' + parts[2].split('\n## Comments', 1)[0])
    return out


_titles = {}


def note_title(rel):
    if rel not in _titles:
        t = ''
        try:
            for i, l in enumerate(open(os.path.join(LUNA, rel), encoding='utf-8', errors='replace')):
                if l.startswith('# '):
                    t = l[2:].strip()
                    break
                if l.startswith('title:'):
                    t = l[6:].strip().strip('"\'')
                    break
                if i > 40:
                    break
        except OSError:
            pass
        _titles[rel] = clip(t or os.path.basename(rel)[:-3], 56)
    return _titles[rel]


def grep_index():
    """key -> [(rel, nkeys)] over the handover tree; dump-like files (>25 keys) are skipped."""
    idx = {}
    for dp, dn, fn in os.walk(HANDOVERS):
        if SKIP_RE.search(dp + '/'):
            continue
        for f in fn:
            if not f.endswith('.md') or SKIP_RE.search(f):
                continue
            p = os.path.join(dp, f)
            try:
                ks = set(KEY_RE.findall(open(p, encoding='utf-8', errors='replace').read()))
            except OSError:
                continue
            if not ks or len(ks) > 25:
                continue
            rel = os.path.relpath(p, LUNA)
            for k in ks:
                idx.setdefault(k, []).append((rel, len(ks)))
    return idx


def qmd_hits(key):
    try:
        r = subprocess.run(['qmd', 'search', '-c', 'luna', key, '--json', '-n', '10'],
                           capture_output=True, text=True, timeout=30)
        arr = json.loads(r.stdout or '[]')
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    pat = re.compile(r'(?<![\w-])%s(?!\d)' % re.escape(key))
    out = []
    for h in arr:
        rel = h.get('file', '').replace('qmd://luna/', '', 1)
        if SKIP_RE.search('/' + rel) or not os.path.exists(os.path.join(LUNA, rel)):
            continue
        if pat.search(h.get('snippet', '') + ' ' + h.get('title', '') + ' ' + rel):
            out.append(rel)
    return out


def luna_map(keys, refresh):
    """{key: [{path,title}]} for keys, incremental against the luna-map file (7-day TTL)."""
    path = LUNA_MAP
    try:
        cache = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError):
        cache = {}
    ent = cache.get('entries', {})
    now = int(time.time())
    need = [k for k in keys if refresh or k not in ent or now - ent[k].get('ts', 0) > TTL]
    if need:
        print('luna-map: querying %d keys (%d cached)' % (len(need), len(keys) - len(need)))
        idx = grep_index()
        for i, k in enumerate(need):
            g = sorted(idx.get(k, []), key=lambda x: (k not in x[0], x[1], x[0]))
            rels = []
            for rel in [x[0] for x in g] + qmd_hits(k):
                if rel not in rels:
                    rels.append(rel)
            ent[k] = dict(ts=now, notes=[dict(path=r, title=note_title(r)) for r in rels[:MAX_NOTES]])
            if i % 100 == 99:
                print('  %d/%d' % (i + 1, len(need)))
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(dict(generated=now, entries=ent), fh, ensure_ascii=False, separators=(',', ':'))
            fh.write('\n')
    return {k: ent[k]['notes'] for k in keys if k in ent}


def utc_dt(s):
    """A Jira stamp (2026-09-30T10:00:00.000+0200) as an aware UTC datetime, or None."""
    m = re.match(r'(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$', s or '')
    if not m:
        return None
    z = (m.group(3) or 'Z').replace('Z', '+0000').replace(':', '')
    return datetime.strptime(m.group(1) + 'T' + m.group(2) + z, '%Y-%m-%dT%H:%M:%S%z').astimezone(timezone.utc)


def utc_stamp(s):
    d = utc_dt(s)
    return d.strftime('%Y-%m-%d %H:%M UTC') if d else ''


def ez(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime('%Y-%m-%dT%H:%MZ') if t is not None else ''


BENCH_COLS = ('key', 'title', 'size', 'est_seq', 'own_legs', 'own_dated', 'own_wall_min', 'own_active_min',
              'bundle_n', 'bundle_open', 'bundle_done', 'bundle_legs', 'bundle_dated', 'bundle_wall_min', 'bundle_active_min',
              'total_wall_min', 'total_active_min', 'min_per_seq', 'ratio', 'first_utc', 'end_utc', 'members')


def bench(mir, rows, n_plan, act, seqm, erange):
    """The benchmark (HIMMEL-5453): per planned item its estimate, its own actuals, its spawned bundle and the total, then
    the operator-directed bundle and the unattributed unplanned train tickets. Each row is a list in BENCH_COLS order
    (members as ticket numbers); ratio = total wall minutes per S-equivalent over the median of the measured done items."""
    planned = {r[0] for r in rows[:n_plan]}
    leg_filed, op = filings()
    op |= {num(k) for k, m in mir.items() if 'operator-directed' in m.get('labels', [])}
    anc = bundles(mir, planned, op, leg_filed)

    def est_of(k):
        sz = [seqm.get(x) for x in erange.get(k, '').split('–')]
        return sum(sz) / len(sz) if sz and None not in sz else None

    def stat(ns):
        s = dict(n=len(ns), open=0, done=0, legs=0, dated=0, wall=0, active=0, first=None, end=None)
        for n in ns:
            m = mir.get('HIMMEL-%d' % n)
            if m and bucket(m) == 'wont':
                s['n'] -= 1  # closed without shipping: out of every count
                continue
            s['done' if m and m['st'] == 2 else 'open'] += 1
            a = act.get(n)
            if a:
                s['legs'] += a[0]
                s['wall'] += a[1]
                s['active'] += a[2]
                s['dated'] += a[3]
                if a[4] is not None:
                    s['first'] = a[4] if s['first'] is None else min(s['first'], a[4])
                    s['end'] = a[5] if s['end'] is None else max(s['end'], a[5])
        return s

    def row(key, title, size, est, own, b, members, done, rs=None):
        tw = (own['wall'] if own else 0) + b['wall']
        # the legs the ratio divides: the operator bundle counts only its estimated members. An undated leg adds no
        # wall, so a ratio over any undated leg would understate the actual: it is left blank.
        legs, dated, rw = (rs['legs'], rs['dated'], rs['wall']) if rs else \
            ((own['legs'] if own else 0) + b['legs'], (own['dated'] if own else 0) + b['dated'], tw)
        mps = round(rw / est, 1) if est and rw and done and legs == dated else None
        fs = [x for x in ((own or {}).get('first'), b['first']) if x is not None]
        es = [x for x in ((own or {}).get('end'), b['end']) if x is not None]
        return [key, title, size, round(est, 2) if est else None] + \
            ([own['legs'], own['dated'], own['wall'], own['active']] if own else [None] * 4) + \
            [b['n'], b['open'], b['done'], b['legs'], b['dated'], b['wall'], b['active'],
             tw, (own['active'] if own else 0) + b['active'], mps, None,
             ez(min(fs)) if fs else '', ez(max(es)) if es else '', members]

    out = []
    for r in rows[:n_plan]:
        ms = sorted(n for n, a in anc.items() if a == r[0])
        out.append(row('HIMMEL-%d' % r[0], r[1], r[10] or '', r[6], stat([r[0]]), stat(ms), ms, r[2] == 2))
    om = sorted(n for n, a in anc.items() if a == 'op')
    ob = stat(om)
    oe = {n: e for n, e in ((n, est_of('HIMMEL-%d' % n)) for n in om)
          if e is not None and mir.get('HIMMEL-%d' % n, {}).get('st') == 2}
    opr = row('operator-directed', 'operator-directed bundle (min per S-eq over its %d estimated done of %d)' % (len(oe), len(om)),
              '', sum(oe.values()) if oe else None, None, ob, om, bool(oe), stat(list(oe)))
    um = sorted(r[0] for r in rows[n_plan:] if r[7] == 2 and r[0] not in anc)
    unr = row('unattributed', 'unplanned train tickets with no planned or operator origin', '', None, None, stat(um), um, False)
    mps = sorted(x[17] for x in out + [opr] if x[17] is not None)
    med = (mps[(len(mps) - 1) // 2] + mps[len(mps) // 2]) / 2 if mps else None
    for x in out + [opr]:
        if x[17] is not None and med:
            x[18] = round(x[17] / med, 2)
    return out, opr, unr


def write_bench(path, out, opr, unr):
    fmt = {3: '%g', 17: '%.1f', 18: '%.2f'}

    def cell(i, v):
        if v is None:
            return ''
        if isinstance(v, list):
            return ','.join('HIMMEL-%d' % n for n in v)
        if i in fmt:
            return fmt[i] % v
        return str(v).replace('\t', ' ')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\t'.join(BENCH_COLS) + '\n')
        for x in out + [opr, unr]:
            fh.write('\t'.join(cell(i, v) for i, v in enumerate(x)) + '\n')


def reindex_notes(prows, notes, dirs):
    """The plan rows with their note ids (col 8) renumbered against only the notes and directories they use."""
    nid, did, nn, nd, out = {}, {}, [], [], []
    for r in prows:
        ids = []
        for i in r[8]:
            if i not in nid:
                d = notes[i][0]
                if d not in did:
                    did[d] = len(nd)
                    nd.append(dirs[d])
                nid[i] = len(nn)
                nn.append([did[d], notes[i][1], notes[i][2]])
            ids.append(nid[i])
        out.append(r[:8] + [ids] + r[9:])
    return out, nn, nd


def split_pages(rows, notes, dirs, jt, jc, ja, jw, jf, unpl, vers, tname, paths, urls):
    """HIMMEL-6514: the three pages of a split render, as dicts of per-page data (a page with no path is skipped).

    focus  = open tickets of the target version (plus the open tickets of released versions, which the alerts name,
             and the in-flight ones no version holds); done = every Done ticket; future = every other open ticket
             and the unplaced list. jc is the target's index in the Jira versions, tname its name in the plan's."""
    alert = {(x[0], k) for x in ja for k in x[1]}

    def where(t):
        if t['b'] == 'done':
            return 'done'
        return 'focus' if t['v'] == jc or (t['v'], t['k']) in alert else 'future'

    def prow(r):
        return 'done' if r[2] == 2 else 'focus' if vers[r[3]] == tname else 'future'
    jd = sum(1 for t in jt if t['b'] == 'done' and t['v'] == jc)
    dv = [t['v'] for t in jt if t['b'] == 'done']
    fv = [t['v'] for t in jt if where(t) == 'future']
    lk = {k: v for k, v in urls.items() if v}
    pages = []
    for kind in ('focus', 'done', 'future'):
        if not paths.get(kind):
            continue
        pr, nn, nd = reindex_notes([r for r in rows if prow(r) == kind], notes, dirs)
        pages.append(dict(
            kind=kind, path=paths[kind], P=pr, N=nn, DR=nd, JT=[t for t in jt if where(t) == kind],
            JC=jc if kind != 'future' else -1, JN=-1, JA=ja if kind == 'focus' else [], JW=jw,
            JF=jf if kind == 'focus' else [], U=unpl if kind == 'future' else [],
            x=dict(PG=kind, LK=lk, JD=jd if kind == 'focus' else 0,
                   JS=(max(dv, default=-1) if kind == 'done' else min(fv, default=-1) if kind == 'future' else None))))
    return pages


SECTOR_COLORS = {'Fleet orchestration': '#2563eb', 'Ship loop': '#16a34a', 'Safety & enforcement': '#dc2626',
                 'Cost & efficiency': '#ca8a04', 'Visibility': '#0891b2', 'Quality & proof': '#7c3aed',
                 'Deployment': '#ea580c', 'Knowledge & steering': '#db2777', 'Planning & tracking': '#65a30d',
                 'Memory & retrieval': '#0d9488'}
VCOLS = ['To Do', 'In Progress', 'In Review', 'IN CI']


def origin_repo():
    """owner/name of this checkout's GitHub origin, or ''."""
    try:
        url = subprocess.run(['git', '-C', os.path.dirname(os.path.abspath(__file__)), 'remote', 'get-url', 'origin'],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''
    hit = re.search(r'github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$', url)
    return hit.group(1) if hit else ''


def open_prs(path, repo):
    """{ticket number: [(pr, ci, draft)]} from a `gh pr list --json number,title,headRefName,isDraft,statusCheckRollup`
    file, else one live gh read (TRACKER_GH is the test seam); None when gh cannot be read. A PR belongs to every key
    its title or branch names; ci is running, red, cancelled, green or none."""
    try:
        if path:
            prs = json.load(open(path, encoding='utf-8'))
        else:
            prs = json.loads(subprocess.run(
                [os.environ.get('TRACKER_GH', 'gh'), 'pr', 'list', '--repo', repo, '--state', 'open', '--limit', '300',
                 '--json', 'number,title,headRefName,isDraft,statusCheckRollup'],
                capture_output=True, text=True, timeout=60, check=True).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        if path:
            raise SystemExit('tracker: --prs-file %s is unreadable' % path)
        return None
    out = {}
    for pr in prs:
        st = [(r.get('status'), r.get('conclusion') or r.get('state')) for r in pr.get('statusCheckRollup') or []]
        if any(b in ('FAILURE', 'ERROR', 'TIMED_OUT') for _, b in st):
            ci = 'red'
        elif any(a in ('IN_PROGRESS', 'QUEUED', 'PENDING') or b in ('PENDING', 'EXPECTED') for a, b in st):
            ci = 'running'
        elif any(b == 'CANCELLED' for _, b in st):
            ci = 'cancelled'
        elif not st:
            ci = 'none'
        else:
            ci = 'green' if all(b in ('SUCCESS', 'NEUTRAL', 'SKIPPED') for _, b in st) else 'red'
        for k in set(re.findall(r'HIMMEL-(\d+)', pr['title'] + ' ' + pr['headRefName'], re.I)):
            out.setdefault(int(k), []).append((pr['number'], ci, bool(pr.get('isDraft'))))
    return out


def read_workers(path):
    """{ticket number: record} from a dir of HIMMEL-<n>.json worker records (ticket-status.sh); an unreadable record or
    a missing dir is skipped, so a card without a record simply has no worker line."""
    out = {}
    for p in sorted(glob.glob(os.path.join(path, 'HIMMEL-*.json'))) if path else []:
        m = re.fullmatch(r'HIMMEL-(\d+)\.json', os.path.basename(p))
        try:
            rec = json.load(open(p, encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if m and isinstance(rec, dict) and isinstance(rec.get('prs', {}), dict):
            out[int(m.group(1))] = rec
    return out


def open_worker_prs(rec):
    """[(pr number, head)] of the record's open PRs, ascending."""
    return sorted((int(n), str(p.get('head') or '')) for n, p in rec.get('prs', {}).items()
                  if isinstance(p, dict) and p.get('open') and str(n).isdigit())


def worker_line(rec):
    """`worker <leg> · <state>[ · #<pr> @<head7> · CI <ci>...][ · <age>]` for one worker record."""
    parts = ['worker %s' % (rec.get('leg') or '?'), str(rec.get('state') or 'unknown')]
    for n, h in open_worker_prs(rec):
        ci = rec['prs'][str(n)].get('ci') or 'none'
        parts += ['#%d%s' % (n, ' @' + h[:7] if h else ''), 'CI %s' % ci]
    t = utc_dt(rec.get('last_event_ts') or '')
    if t:
        s = max(0, int((datetime.now(timezone.utc) - t).total_seconds()))
        parts.append('%d min' % (s // 60) if s < 3600 else '%d h' % (s // 3600) if s < 86400 else '%d d' % (s // 86400))
    return ' · '.join(parts)


def column_parity(version, cols):
    """{column: (jira count, [differing keys as text])} from one live `jira list` of the version's open tickets, compared
    with the page's {column: [ticket numbers]}; None when the CLI fails or answers garbled."""
    cli = jira_cli()
    cmd = (['node', cli] if cli.endswith('.js') else [cli]) + [
        'list', '--jql', 'project = HIMMEL AND fixVersion = "%s" AND statusCategory != Done' % version, '--limit', '5000']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, JIRA_PROJECT_KEY=os.environ.get('JIRA_PROJECT_KEY') or 'HIMMEL'))
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [l.split('\t') for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or any(len(f) < 3 or not KEY_RE.fullmatch(f[0]) for f in lines):
        return None
    jr = {num(f[0]): f[2].strip() for f in lines}
    pg = {k: c for c, ks in cols.items() for k in ks}
    out = {}
    for c in list(cols) + sorted(set(jr.values()) - set(cols)):
        diff = ['HIMMEL-%d Jira %s' % (k, jr.get(k, '(absent)')) for k in cols.get(c, []) if jr.get(k) != c]
        diff += ['HIMMEL-%d page %s' % (k, pg.get(k, '(absent)')) for k in sorted(jr) if jr[k] == c and pg.get(k) != c]
        out[c] = (sum(1 for v in jr.values() if v == c), diff)
    return out


def ci_column(jira, prs):
    """The column a card sits in: Jira's status, moved by its open PRs' CI. A red PR is In Progress, a running one is
    IN CI, a green one is IN CI unless Jira already holds the card in In Review (review state is not read here); no PR
    leaves Jira's status. The page then shows the card under Jira's status as a note, and the parity line flags it."""
    cis = {ci for _, ci, _ in prs}
    if 'red' in cis:
        return 'In Progress'
    if 'running' in cis or ('green' in cis and jira != 'In Review'):
        return 'IN CI'
    return jira


def version_page(mir, version, groups, prs, chains, base, repo, workers=None):
    """(html, stdout parity line, focus fingerprint): the FOCUS page of one version (HIMMEL-6769).

    Columns are the Jira status names of the version's open tickets, moved by an open PR's CI (`ci_column`) and each
    split into the plan's priority blocks; a card
    carries its open PRs with CI state (a started card with none is flagged), its blockers, its FAST-TRACK chain step and
    its sector. Each column ends its header with a parity line against a live JQL count. A card whose ticket has a
    worker record in `workers` carries a worker line. The fingerprint covers what a reader acts on (tickets, priority
    blocks, chain steps, worker owner, state and open-PR heads, and the column a PR's CI puts a card in), never a CI badge on its own, an age or a timestamp."""
    def step_state(st):
        k = st.get('key', '')
        if not KEY_RE.fullmatch(k):
            return st.get('state', 'next')
        if k not in mir:
            return 'unknown'
        if bucket(mir[k]) == 'done':
            return 'merged'
        if 'held' in mir[k].get('labels', []):
            return 'held'
        return 'work' if mir[k]['sn'] in ('In Progress', 'In Review', 'IN CI') else 'next'

    workers = workers or {}
    base = base.strip().rstrip('/') if re.match(r'^https?://', base.strip()) else ''
    opn = {num(k): m for k, m in mir.items() if version in m['fv'] and bucket(m) not in ('done', 'wont')}
    done = sum(1 for m in mir.values() if version in m['fv'] and bucket(m) == 'done')
    names, rows = priority_rows(opn, groups)
    block = {k: n for n in names for k in rows[n]}
    order = {k: i for i, k in enumerate(k for n in names for k in rows[n])}
    cols = {c: [] for c in VCOLS}
    jcol = {k: opn[k]['sn'] or opn[k]['cat'] for k in opn}
    ecol = {k: ci_column(jcol[k], (prs or {}).get(k, [])) for k in opn}
    for k in sorted(opn, key=order.get):
        cols.setdefault(ecol[k], []).append(k)
    par = column_parity(version, cols)
    chains = [ch for ch in chains if any(version in mir.get(st.get('key', ''), {}).get('fv', []) for st in ch['steps'])]
    merged = sum(1 for ch in chains for st in ch['steps'] if step_state(st) == 'merged')
    chains = [dict(ch, steps=[st for st in ch['steps'] if step_state(st) != 'merged']) for ch in chains]
    chains = [ch for ch in chains if ch['steps']]
    inchain = {}
    for ch in chains:
        for i, st in enumerate(ch['steps'], 1):
            if st.get('key'):
                inchain.setdefault(st['key'], '%s · step %d%s' % (ch['name'], i, ' · ' + st['owner'] if st.get('owner') else ''))

    def key_html(k):
        return '<a href="%s/browse/HIMMEL-%d">HIMMEL-%d</a>' % (esc(base), k, k) if base else '<b>HIMMEL-%d</b>' % k

    def card(k):
        m = opn[k]
        badges = ''.join('<a class="pr ci-%s" href="https://github.com/%s/pull/%d">#%d · CI %s%s</a>'
                         % (ci, esc(repo), n, n, ci, ' · draft' if d else '') for n, ci, d in sorted((prs or {}).get(k, [])))
        if prs is not None and not badges and bucket(m) != 'todo':
            badges = '<span class="pr nopr">no open PR</span>'
        sec = m['sector']
        sc = SECTOR_COLORS.get(sec, 'var(--muted)')
        bl = blocker_list(mir, k)
        live = ['HIMMEL-%d' % b for b, st in bl if st == 'open']
        dirq = ['HIMMEL-%d' % b for b, st in bl if st == 'direction?']
        shut = ['HIMMEL-%d (%s)' % (b, st) for b, st in bl if st in ('done', 'wont')]
        ft = inchain.get('HIMMEL-%d' % k)
        return ('<div class="card%s%s" style="--s:%s" data-key="HIMMEL-%d" data-block="%s">%s %s<div>%s</div>%s%s%s%s%s%s'
                '<span class="sec" style="--s:%s">%s</span></div>\n'
                % (' isblocked' if live else '', ' isft' if ft else '', sc, k, esc(block[k]), key_html(k), badges, esc(clip(m['title'], 120)),
                   '<div class="dirq">Jira %s, PR CI says %s</div>' % (esc(jcol[k]), esc(ecol[k])) if jcol[k] != ecol[k] else '',
                   '<div class="wk">%s</div>' % esc(worker_line(workers[k])) if k in workers else '',
                   '<div class="ft">FAST-TRACK · %s</div>' % esc(ft) if ft else '',
                   '<div class="blk">BLOCKED by open %s</div>' % ', '.join(live) if live else '',
                   '<div class="dirq">direction? %s: the link and the blocker\'s own text disagree</div>' % ', '.join(dirq) if dirq else '',
                   '<div class="dep">after %s</div>' % ', '.join(shut) if shut else '', sc, esc(sec or 'no sector')))
    colhtml, tally = [], []
    for c in list(cols) + sorted(set(par or {}) - set(cols)):
        ks = cols.get(c, [])
        if par is None:
            pl = '<div class="parity na">Jira unavailable</div>'
        else:
            jn, diff = par.get(c, (0, []))
            pl = '<div class="parity %s">Jira %d · %s</div>' % ('ok' if not diff else 'drift', jn, 'ok' if not diff else
                                                               'DRIFT: ' + esc(', '.join(diff[:8]) + (' (+%d more)' % (len(diff) - 8) if len(diff) > 8 else '')))
            tally.append('%s %d/%d %s' % (c, len(ks), jn, 'ok' if not diff else 'DRIFT'))
        parts = []
        for bi, n in enumerate(names):
            bk = [k for k in ks if block[k] == n]
            if bk:
                parts.append('<div class="block b%d"><div class="bh">%s <span>%d</span></div>\n%s</div>'
                             % (min(bi, 7), esc(n), len(bk), ''.join(card(k) for k in bk)))
        colhtml.append('<section class="col" data-col="%s"><h2>%s <span class="n">%d</span></h2>%s%s</section>'
                       % (esc(c), esc(c), len(ks), pl, ''.join(parts) or '<div class="empty">none</div>'))
    parline = 'parity %s: %s' % (version, ', '.join(tally) if par is not None else 'unavailable')

    def step(st):
        state = step_state(st)
        k = st.get('key', '')
        return '<li class="st-%s"><b>%s</b> %s%s %s%s</li>\n' % (
            esc(state), esc(state), '<a href="https://github.com/%s/pull/%d">#%d</a> ' % (esc(repo), st['pr'], st['pr']) if st.get('pr') else '',
            key_html(num(k)) if KEY_RE.fullmatch(k) else esc(k), esc(st.get('label', '')),
            ' <span class="own">%s</span>' % esc(st['owner']) if st.get('owner') else '')
    chainhtml = ''.join('<div class="chain"><h3>%s</h3>%s<ol>\n%s</ol></div>' % (
        esc(ch['name']), '<div class="dep">%s</div>' % esc(ch['note']) if ch.get('note') else '', ''.join(step(st) for st in ch['steps']))
        for ch in chains)
    legend = ''.join('<span class="lg b%d">%s</span>' % (min(i, 7), esc(n)) for i, n in enumerate(names))
    seclegend = ''.join('<span class="sec" style="--s:%s">%s %d</span>' % (c, esc(n), sum(1 for m in opn.values() if m['sector'] == n))
                        for n, c in SECTOR_COLORS.items() if any(m['sector'] == n for m in opn.values()))
    upd = max((m['upd'] for m in mir.values()), key=lambda u: utc_dt(u) or datetime.min.replace(tzinfo=timezone.utc), default='')
    html = VERSION_TEMPLATE.format(
        v=esc(version), n=len(opn), d=done, h=merged, gen=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'), mir=esc(utc_stamp(upd)),
        prs='' if prs is not None else ' PR state unavailable (gh could not be read), so no card is flagged for a missing PR.',
        chains='<h2 class="sh">Waves and merge chains</h2><div class="chains">%s</div>' % chainhtml if chainhtml else '',
        legend=legend, seclegend=seclegend or '<span class="empty">no sector set</span>', board=''.join(colhtml))
    fp = json.dumps({
        'v': version,
        'done': done,
        'merged': merged,
        'tickets': [[k, opn[k]['sn'], ecol[k], opn[k]['title'], 'held' in opn[k].get('labels', []), block[k], order[k], opn[k]['sector'], blocker_list(mir, k)]
                    for k in sorted(opn)],
        'chains': [[ch['name'], [[st.get('key', ''), st.get('label', ''), step_state(st), st.get('pr'), st.get('owner')]
                                 for st in ch['steps']]] for ch in chains],
        'prs': None if prs is None else [[k, [[n, d] for n, _, d in sorted(v)]] for k, v in sorted(prs.items())],
        'workers': [[k, r.get('leg'), r.get('state'), open_worker_prs(r)] for k, r in sorted(workers.items()) if k in opn]},
        sort_keys=True)
    return html, parline, hashlib.sha256(fp.encode('utf-8')).hexdigest()[:16]


VERSION_TEMPLATE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{v} Tracker</title>
<style>
:root{{--bg:#f5f5f4;--panel:#fff;--fg:#1c1917;--muted:#78716c;--line:#e7e5e4;--acc:#2563eb;
--p0:#dc2626;--p1:#ea580c;--p2:#ca8a04;--p3:#16a34a;--p4:#0891b2;--p5:#2563eb;--p6:#7c3aed;--p7:#a8a29e}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#0c0a09;--panel:#1c1917;--fg:#f5f5f4;--muted:#a8a29e;--line:#44403c;--acc:#60a5fa}}}}
:root[data-theme="dark"]{{--bg:#0c0a09;--panel:#1c1917;--fg:#f5f5f4;--muted:#a8a29e;--line:#44403c;--acc:#60a5fa}}
*{{box-sizing:border-box}}
body{{background:var(--bg);color:var(--fg);font:13px/1.45 system-ui,sans-serif;margin:0;padding:16px}}
h1{{font-size:20px;margin:0 0 4px}} .sub{{color:var(--muted);margin-bottom:10px}} .sh{{font-size:14px;margin:0 0 8px}}
a{{color:var(--acc);text-decoration:none}}
.legend,.seclegend{{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:14px}}
.lg{{font-size:11px;padding:2px 8px;border-radius:10px;border-left:4px solid var(--c);background:var(--panel)}}
.board{{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;align-items:start}}
.col{{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px;min-width:0}}
.col h2{{font-size:14px;margin:0 0 2px;display:flex;justify-content:space-between}}
.col h2 span,.bh span{{color:var(--muted);font-weight:400}}
.parity{{font-size:11px;margin-bottom:8px}}.parity.ok{{color:#16a34a}}.parity.drift{{color:#dc2626;font-weight:600}}.parity.na{{color:var(--muted)}}
.block{{border-left:4px solid var(--c);padding-left:8px;margin-bottom:12px}}
.bh{{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.03em;color:var(--c);margin-bottom:4px;display:flex;justify-content:space-between;gap:6px}}
.card{{background:var(--bg);border:1px solid var(--line);border-left:4px solid var(--s);border-radius:6px;padding:6px 8px;margin-bottom:6px;overflow-wrap:anywhere}}
.card b,.card a{{font-variant-numeric:tabular-nums;font-size:12px}}
.pr{{display:inline-block;font-size:11px;padding:0 6px;border-radius:8px;margin-left:4px;border:1px solid var(--line)}}
.ci-green{{color:#16a34a}}.ci-red{{color:#dc2626}}.ci-running{{color:#ca8a04}}.ci-cancelled,.ci-none{{color:var(--muted)}}
.nopr{{color:#dc2626;border-color:#dc2626}}
.sec{{display:inline-block;font-size:10px;font-weight:600;padding:0 6px;margin-top:3px;border-radius:8px;color:#fff;background:var(--s)}}
.seclegend .sec{{font-size:11px;padding:2px 8px}}
.blk{{color:#fff;background:#dc2626;font-size:11px;font-weight:600;padding:1px 6px;border-radius:6px;margin-top:3px}}.isblocked{{border-color:#dc2626}}
.dirq{{color:#fff;background:#ca8a04;font-size:11px;font-weight:600;padding:1px 6px;border-radius:6px;margin-top:3px}}
.dep{{color:var(--muted);font-size:11px}} .empty{{color:var(--muted);font-style:italic}}
.chains{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;margin-bottom:14px}}
.chain{{background:var(--panel);border:1px solid var(--line);border-left:4px solid #7c3aed;border-radius:8px;padding:8px 10px}}
.chain h3{{font-size:13px;margin:0 0 4px}}.chain ol{{margin:4px 0 0;padding-left:20px}}.chain li{{margin-bottom:3px}}
.chain li b{{font-size:10px;text-transform:uppercase;padding:0 5px;border-radius:6px;margin-right:4px}}
.st-merged b{{background:#16a34a;color:#fff}}.st-work b{{background:#7c3aed;color:#fff}}.st-next b{{background:#ca8a04;color:#fff}}.st-held b{{background:var(--line);color:var(--fg)}}
.st-unknown b{{background:#dc2626;color:#fff}}
.st-merged{{color:var(--muted)}}.own{{font-size:11px;color:var(--muted)}}.wk{{color:var(--muted);font-size:11px}}
.ft{{color:#fff;background:#7c3aed;font-size:11px;font-weight:600;padding:1px 6px;border-radius:6px;margin-top:3px}}.isft{{outline:2px solid #7c3aed}}
.b0{{--c:var(--p0)}}.b1{{--c:var(--p1)}}.b2{{--c:var(--p2)}}.b3{{--c:var(--p3)}}.b4{{--c:var(--p4)}}.b5{{--c:var(--p5)}}.b6{{--c:var(--p6)}}.b7{{--c:var(--p7)}}
</style></head><body>
<h1>{v} tracker</h1>
<div class="sub">{n} open · {d} Done · {h} merged chain steps hidden. Rendered {gen} from the Jira mirror (newest update {mir}). Columns are Jira statuses, except that a card with an open PR follows
that PR's CI (red In Progress, running or green IN CI, except that green keeps a card Jira holds In Review) and says so; each column is split into the
approved plan's priority blocks; each column header carries its parity against a live JQL count. A card shows its open PR and that PR's CI
state; a started card without an open PR is flagged, and so is a card with an open blocker.{prs}</div>
{chains}
<div class="legend">Priority blocks: {legend}</div>
<div class="seclegend">Sectors (card edge and chip): {seclegend}</div>
<div class="board">{board}</div>
</body></html>
"""


def main():
    global MIRROR, LUNA, HANDOVERS, ROOT, OUT, LUNA_MAP, VERSIONS
    ap = argparse.ArgumentParser(description='Render the HIMMEL-3882 roadmap tracker page.')
    ap.add_argument('--remaining', metavar='VERSION', default=None,
                    help='write the open tickets of one version grouped by the plan priority line (--priority-file) to '
                         '--out (else stdout), then exit; needs only --mirror-dir')
    ap.add_argument('--priority-file', default=None, help='the approved plan carrying the `priority:` line (--remaining, --version)')
    ap.add_argument('--version', default=None, help='write the FOCUS page of one version to --out, then exit (HIMMEL-6769); with '
                                                     '--plan-dir it also writes <out>.fp, the value --emit-fp prints for tick')
    ap.add_argument('--prs-file', default=None, help='--version: a `gh pr list --json number,title,headRefName,isDraft,'
                                                     'statusCheckRollup` file (default: one live gh read)')
    ap.add_argument('--workers-dir', default=None, help='--version: the worker records dir (HIMMEL-<n>.json, written by '
                                                         'ticket-status.sh); a card with a record shows its worker line')
    ap.add_argument('--chains-file', default=None, help='--version: the merge chains and waves JSON '
                                                        '([{name, note, steps: [{key, pr, label, state, owner}]}])')
    ap.add_argument('--repo', default=None, help='--version: the GitHub repo (owner/name) gh reads and the PR badges '
                                                  'link to (default: this checkout\'s origin)')
    ap.add_argument('--plan-dir', help='the HIMMEL-3882 plan dir (holds stage1/ and stage3/)')
    ap.add_argument('--out', help='tracker.html to write (with --target-version, --out-done or --out-future: the focus page, '
                                  'the open tickets of the target version)')
    ap.add_argument('--out-done', default=None, help='split mode: the Done page (every Done ticket) to write')
    ap.add_argument('--out-future', default=None, help='split mode: the future page (open tickets of every other version) to write')
    ap.add_argument('--target-version', default=None,
                    help='split mode: the version the focus page is about (default: the earliest unreleased version of the versions file)')
    ap.add_argument('--focus-url', default=None, help='split mode: the published focus page, linked from the other pages')
    ap.add_argument('--done-url', default=None, help='split mode: the published Done page, linked from the other pages')
    ap.add_argument('--future-url', default=None, help='split mode: the published future page, linked from the other pages')
    ap.add_argument('--luna-map', help='luna-map.json cache path')
    ap.add_argument('--mirror-dir', default=MIRROR)
    ap.add_argument('--versions-file', default=None,
                    help="a `jira versions` snapshot: name<TAB>released<TAB>releaseDate (default <mirror-dir>.versions.tsv)")
    ap.add_argument('--luna-root', default=LUNA)
    ap.add_argument('--handovers', default=os.environ.get('TRACKER_HANDOVERS_DIR', ''),
                    help='handover tree to grep for notes and live legs (default $TRACKER_HANDOVERS_DIR, '
                         'else <luna-root>/handovers/yotamleo/himmel)')
    ap.add_argument('--drift-log', default=None,
                    help='append-only drift/unplanned/unthemed counts per render (default <handovers>/roadmap-drift.tsv)')
    ap.add_argument('--jira-base-url', default=os.environ.get('JIRA_BASE_URL', ''),
                    help='Jira base URL for the kanban cards\' browse links (default $JIRA_BASE_URL, as the jira CLI reads it; '
                         'without one a card key is plain text)')
    ap.add_argument('--refresh-luna', action='store_true')
    ap.add_argument('--emit-fp', action='store_true')
    a = ap.parse_args()
    if a.remaining:
        MIRROR = os.path.abspath(a.mirror_dir)
        grp = priority_groups(a.priority_file) if a.priority_file else []
        if a.priority_file and not grp:
            raise SystemExit('tracker:--priority-file %s is unreadable or has no priority: line' % a.priority_file)
        text = remaining_board(read_mirror(), a.remaining, grp)
        if a.out:
            open(a.out, 'w', encoding='utf-8').write(text)
        else:
            print(text, end='')
        return
    if a.version:
        if not a.out:
            ap.error('--version needs --out')
        MIRROR, OUT = os.path.abspath(a.mirror_dir), os.path.abspath(a.out)
        if not os.path.isdir(MIRROR):
            raise SystemExit('tracker: --mirror-dir %s is not a directory' % MIRROR)
        fp0 = ''
        if a.plan_dir:  # the tick reads tracker= from this page's .fp, the same value --emit-fp derives
            ROOT, LUNA = os.path.abspath(a.plan_dir), os.path.abspath(a.luna_root)
            VERSIONS = os.path.abspath(a.versions_file) if a.versions_file else MIRROR + '.versions.tsv'
            HANDOVERS = os.path.abspath(a.handovers) if a.handovers else os.path.join(LUNA, 'handovers', 'yotamleo', 'himmel')
            fp0 = fingerprint()
        grp = priority_groups(a.priority_file) if a.priority_file else []
        if a.priority_file and not grp:
            raise SystemExit('tracker: --priority-file %s is unreadable or has no priority: line' % a.priority_file)
        try:
            chains = json.load(open(a.chains_file, encoding='utf-8')) if a.chains_file else []
        except (OSError, ValueError):
            raise SystemExit('tracker: --chains-file %s is unreadable' % a.chains_file)
        repo = a.repo or origin_repo()
        if not repo:
            raise SystemExit('tracker: no GitHub origin found for this checkout; pass --repo owner/name')
        html, par, vfp = version_page(read_mirror(), a.version, grp, open_prs(a.prs_file, repo), chains, a.jira_base_url, repo,
                                      read_workers(a.workers_dir))
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        open(OUT, 'w', encoding='utf-8').write(html)
        open(OUT + '.vfp', 'w', encoding='utf-8').write(vfp + '\n')
        if fp0:
            open(OUT + '.fp', 'w', encoding='utf-8').write(fp0 + '\n')
        print('wrote %s (%.1f KB)' % (OUT, os.path.getsize(OUT) / 1024))
        print(par)
        return
    if not (a.plan_dir and a.out and a.luna_map):
        ap.error('--plan-dir, --out and --luna-map are required unless --remaining or --version is given')
    ROOT, OUT, LUNA_MAP, MIRROR, LUNA = (os.path.abspath(a.plan_dir), os.path.abspath(a.out),
                                         os.path.abspath(a.luna_map), os.path.abspath(a.mirror_dir),
                                         os.path.abspath(a.luna_root))
    VERSIONS = os.path.abspath(a.versions_file) if a.versions_file else MIRROR + '.versions.tsv'
    HANDOVERS = os.path.abspath(a.handovers) if a.handovers else os.path.join(LUNA, 'handovers', 'yotamleo', 'himmel')
    if a.emit_fp:
        print(fingerprint())
        return
    t0 = time.time()
    fp0 = fingerprint()  # taken before any input is read, so an edit mid-render leaves the page STALE, never falsely ok
    S =os.path.join(ROOT, 'stage3')
    meta = json.load(open(os.path.join(S, 'meta.json'), encoding='utf-8'))
    mir = read_mirror()
    legs = live_legs()
    for n in legs:  # HIMMEL-3990: a live leg puts its ticket in progress, whatever Jira says (Done stays done)
        m = mir.get('HIMMEL-%d' % n)
        if m and m['st'] != 2:
            m['st'] = 1
    vrows = sorted(read_tsv(os.path.join(S, 'versions.tsv'))[1], key=lambda r: ver_key(r['version']))
    vers = [r['version'] for r in vrows]
    vidx = {v: i for i, v in enumerate(vers)}
    vload = [[round(float(r['load_' + l] or 0), 3) for l in
              ('bugs', 'enhancements', 'features', 'misc', 'audit')] +
             [round(float(r['load_total'] or 0), 3), round(float(r['est_legs'] or 0), 1)] for r in vrows]
    impact, uimp, plain, ready, erange = {}, {}, {}, {}, {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            if (r.get('impact') or '').isdigit():
                impact[r['key']] = int(r['impact'])
    # a ticket's group is its Jira Sector, read from the mirror; no plan theme, overlay or label feeds it.
    theme = {k: m['sector'] or '(no sector)' for k, m in mir.items()}
    # user-facing impact (stage1 explain), readiness + T-shirt range (stage2).
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage1', 'C??.explain.tsv'))):
        for r in read_tsv(p)[1]:
            uimp[r['key']] = clip(r.get('user_impact') or '', 400)
            plain[r['key']] = clip(r.get('issue_plain') or '', 600)
    for p in sorted(glob.glob(os.path.join(ROOT, 'stage2', 'C??.tsv'))):
        for r in read_tsv(p)[1]:
            if (r.get('readiness') or '').isdigit():
                ready[r['key']] = int(r['readiness'])
            lo, hi = r.get('effort_low') or '', r.get('effort_high') or ''
            if lo or hi:
                erange[r['key']] = lo if lo == hi or not hi else hi if not lo else lo + '–' + hi

    rules = plan_rules(meta)
    seqm = dict(zip(('XS', 'S', 'M', 'L', 'XL'), rules['seq'] or []))

    def fields(k, sl='', mid=0.0):
        # P[14] issue_plain; P[15] the ticket's load in bank: effort_mid x per, or only its slice when planning comes first.
        # Under an effort model the placer's effort_mid already is the slice's mean (overrun included), so it is used as is.
        ld = None if rules['per'] is None else round((seqm.get(sl, 0) if sl and not rules['model'] else mid) * rules['per'], 4)
        # the ticket's own plain Impact block wins; the stage1 explain sidecar is the fallback.
        pi = clip((mir.get(k) or {}).get('impact', ''), 400)
        return [pi or uimp.get(k, ''), erange.get(k, ''), ready.get(k), impact.get(k), sl, plain.get(k, ''), ld]
    themes = sorted(set(theme.values()) | {'(no sector)'})
    tidx = {t: i for i, t in enumerate(themes)}

    placed = read_tsv(os.path.join(S, 'placement.tsv'))[1]
    lmap = luna_map([r['key'] for r in placed], a.refresh_luna)
    dirs, dix, notes, nix = [], {}, [], {}

    def note_id(n):
        if n['path'] not in nix:
            d, f = os.path.split(n['path'])
            if d not in dix:
                dix[d] = len(dirs)
                dirs.append(d)
            nix[n['path']] = len(notes)
            notes.append([dix[d], f, n['title']])
        return nix[n['path']]

    rows, planned = [], set()
    for r in placed:
        k, m = r['key'], mir.get(r['key'])
        planned.add(k)
        if m and bucket(m) == 'wont':
            continue
        lay = r.get('layer') or 'misc'
        fl = 1 if (m and m['fv'] and r['version'] not in m['fv']) else 0  # drift
        rows.append([num(k), clip(m['title'] if m else '(not in mirror)', 62),
                     m['st'] if m else 0, vidx[r['version']], LAYERS.index(lay) if lay in LAYERS else 3,
                     tidx[theme.get(k, '(no sector)')], round(float(r['effort_mid'] or 0), 1), fl,
                     [note_id(n) for n in lmap.get(k, [])]] +
                    fields(k, (r.get('slice_effort') or 'S') if r.get('commit') == 'plan-first' else '',
                           float(r['effort_mid'] or 0)))
    n_plan = len(rows)
    for k, m in mir.items():
        if k in planned or bucket(m) == 'wont':
            continue
        hit = [v for v in m['fv'] if TRAIN_RE.match(v) and v in vidx]
        if hit:
            rows.append([num(k), clip(m['title'], 62), m['st'], vidx[hit[0]],
                         0 if m['type'] == 'Bug' else 3, tidx[theme.get(k) or '(no sector)'],
                         0, 2, []] + fields(k)[:-1] + [0])
    unpl = []
    for r in read_tsv(os.path.join(S, 'unplaced.tsv'))[1]:
        m = mir.get(r['key'])
        if m and bucket(m) == 'wont':
            continue
        unpl.append([num(r['key']), clip(m['title'] if m else '', 60), m['st'] if m else 0,
                     clip(r['reason'], 60)])
    # parked closures stay visible (evidence = the reason); other closure flags are not shown.
    for r in read_tsv(os.path.join(S, 'closures.tsv'))[1]:
        if r['close_flag'] != 'park-ns':
            continue
        m = mir.get(r['key'])
        if m and bucket(m) == 'wont':
            continue
        unpl.append([num(r['key']), clip(m['title'] if m else '', 60), m['st'] if m else 0,
                     clip(r.get('close_evidence', ''), 70)])

    upd = max((m['upd'] for m in mir.values()), key=lambda u: utc_dt(u) or datetime.min.replace(tzinfo=timezone.utc), default='')
    nothm = sum(1 for r in rows if r[5] == tidx['(no sector)'] and r[2] != 2)  # open only
    seq = rules['seq']
    jv, ru = read_versions(VERSIONS, mir)
    split = bool(a.out_done or a.out_future or a.target_version)
    tname, tix = '', None
    if split:
        e = earliest_unreleased(jv) if not ru else None
        tname = a.target_version or (e['n'] if e else '')
        tix = next((i for i, v in enumerate(jv) if v['n'] == tname), -1)
        if a.target_version and jv and tix < 0:
            ap.error('--target-version %s is not in the versions file (known: %s)' % (tname, ', '.join(v['n'] for v in jv)))
    lg, cur = ledger_lines(rows, vers, nothm, {x['n'] for x in jv if x['rel']})
    dt = drift_log(a.drift_log, sum(1 for r in rows if r[7] == 1), sum(1 for r in rows if r[7] == 2 and r[2] != 2), nothm)
    if dt:
        lg.append('Drift over time (drift / unplanned / unthemed): ' + ' → '.join('%d/%d/%d' % tuple(x[1:]) for x in dt[-6:]) + '.')
    jt, jc, jn, ja, jw, jf = jira_view(mir, legs, jv, rows[:n_plan], vers, tix)
    par = jira_parity(jt, jv, jc)
    pages = [dict(kind='all', path=OUT, P=rows, N=notes, DR=dirs, JT=jt, JC=jc, JN=jn, JA=ja, JW=jw, JF=jf, U=unpl, x={})]
    if split:
        paths = {'focus': OUT, 'done': a.out_done and os.path.abspath(a.out_done),
                 'future': a.out_future and os.path.abspath(a.out_future)}
        urls = {'focus': a.focus_url, 'done': a.done_url, 'future': a.future_url}
        pages = split_pages(rows, notes, dirs, jt, jc, ja, jw, jf, unpl, vers, tname, paths, urls)
    for p in pages:
        p['kb'] = kanban(p['JT'], jv, p['JC'], a.jira_base_url, p['JW'], p['JF'])
    for t in jt:
        del t['ln']  # the card line is static HTML above; keep it out of the page data
    p90 = meta.get('version_p90_fw') if isinstance(meta.get('version_p90_fw'), dict) else {}
    act = actuals()  # before ATS below: it sets ACT_NEWEST
    bn, bop, bun = bench(mir, rows, n_plan, act, seqm, erange)
    write_bench(OUT + '.bench.tsv', bn, bop, bun)
    data = dict(gen=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'), mir=utc_stamp(upd),
                sha=meta.get('main_sha_at_build', '')[:9], V=vers, VL=vload, VC=version_caps(rules, vers, {x['n'] for x in jv if x['rel']}), DT=dt,
                ATS=datetime.fromtimestamp(ACT_NEWEST, timezone.utc).strftime('%Y-%m-%d %H:%M UTC') if ACT_NEWEST else '',
                LEG={str(n): v for n, v in sorted(legs.items())}, ACT={str(n): v[:4] for n, v in sorted(act.items())}, BN=[x for x in bn if x[4] or x[8]], BOP=bop, BUN=bun, SRC=SOURCE, L=LAYERS, T=themes,
                CUR=cur, JV=jv, RU=ru, PAR=par,
                CAP=dict(total=rules['total'], layers=[(rules['layers'] or {}).get(l) for l in LAYERS],
                         text=capacity_text(rules, [v for v in vers if not TRAIN_RE.match(v)],
                                            [v for v in vers if trail_parent(v)])),
                VP=[p90.get(v) if isinstance(p90.get(v), (int, float)) else None for v in vers],
                PIN=sorted(num(r['key']) for r in placed if re.search(r'\bpinned to ' + re.escape(r['version']) + r'\b', r.get('reason') or '')),
                EQ=' · '.join('%s %g' % x for x in zip(('XS', 'S', 'M', 'L', 'XL'), seq)) + ' S-equivalents'
                if seq else 'not recorded in the plan')
    for p in pages:
        d = dict(data, P=p['P'], N=p['N'], DR=p['DR'], U=p['U'], JT=p['JT'], JC=p['JC'], JN=p['JN'], JA=p['JA'], JW=p['JW'],
                 **{k: v for k, v in p['x'].items() if v is not None})
        if p['kind'] in ('focus', 'future'):  # the accuracy tables are the Done page's
            d.update(BN=[], BOP=None, BUN=None, ACT={})
        blob = json.dumps(d, separators=(',', ':'), ensure_ascii=False).replace('<', '\\u003c')
        html = re.sub(r'__DATA__|__KANBAN__', lambda m: blob if m.group(0) == '__DATA__' else p['kb'], TEMPLATE)  # one pass: no re-scan of ticket text
        os.makedirs(os.path.dirname(p['path']), exist_ok=True)
        open(p['path'], 'w', encoding='utf-8').write(html)
        if p['path'] == OUT:
            open(OUT + '.fp', 'w', encoding='utf-8').write(fp0 + '\n')
    outp = OUT
    unp = sum(1 for r in rows if r[7] == 2 and r[2] != 2)  # open only
    drift = sum(1 for r in rows if r[7] == 1)
    dif = done_in_future(mir, read_versions(VERSIONS, mir, False)[0], ru)
    cov = sum(1 for r in rows[:n_plan] if r[8])
    print('wrote %s.bench.tsv: %d planned items, operator bundle %d, unattributed %d'
          % (outp, len(bn), bop[8], bun[8]))
    print('wrote %s (%.1f KB): %d planned, %d unplanned, %d drift, %d unthemed, %d unplaced, %d done-in-future; mirror %d issues'
          % (outp, os.path.getsize(outp) / 1024, n_plan, unp, drift, nothm, len(unpl), dif, len(mir)))
    if dt:
        print('drift trend: ' + ' → '.join('%s %d/%d/%d' % (x[0][:10], x[1], x[2], x[3]) for x in dt[-6:]) + ' (drift/unplanned/unthemed)')
    for l in lg:
        print('ledger: ' + l)
    for p in pages:
        if p['path'] != OUT:
            print('wrote %s (%.1f KB): %s page, %d plan rows, %d tickets' % (p['path'], os.path.getsize(p['path']) / 1024, p['kind'], len(p['P']), len(p['JT'])))
    print(par)
    print('luna-map coverage: %d/%d placed keys with >=1 note; %d distinct notes; %.1fs'
          % (cov, n_plan, len(notes), time.time() - t0))


TEMPLATE = r'''<title>Himmel Roadmap</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>
/* HIMMEL-3990 design: "which version are we working on". The main view is one hero sentence (Jira's release state and
   status names), the board of the version being worked on, and one table of every version; every number opens its
   tickets. The plan's own views sit folded below it. Palette, type and status dots follow the himmel Config page
   (scripts/config-ui/public/app.css): dark first, IBM Plex, a "● word" dot per status. The old names (--ink, --muted,
   --live, --warn, ...) stay as aliases so the folded plan views keep their colours. */
:root{--bg:#121416;--panel:#191c1f;--line:#2a2f34;--fg:#e8e2d6;--dim:#8e959c;--accent:#9fb7cf;
--todo:#6f767d;--prog:#d1a85f;--rev:#9fb7cf;--ci:#b49cd6;--done:#7fae8a;--fail:#d9796b;
--surface:var(--panel);--ink:var(--fg);--muted:var(--dim);--live:var(--prog);--warn:var(--fail);--ldn:var(--line);--bar:var(--dim);--scrim:rgba(0,0,0,.45);
--f-serif:"IBM Plex Sans",system-ui,sans-serif;--f-sans:"IBM Plex Sans",system-ui,sans-serif;--f-mono:"IBM Plex Mono",ui-monospace,"SFMono-Regular",Menlo,monospace;
--ease:cubic-bezier(.2,.7,.2,1);color-scheme:dark}
@media (prefers-color-scheme:light){:root:not([data-theme="dark"]){--bg:#f5f4f0;--panel:#ecebe6;--line:#d6d4cc;--fg:#1f2326;--dim:#5f666d;--accent:#365a7d;
--todo:#7a8087;--prog:#8a5d0e;--rev:#365a7d;--ci:#6a4c9c;--done:#2f6b3f;--fail:#a3392b;--scrim:rgba(26,26,23,.28);color-scheme:light}}
:root[data-theme="light"]{--bg:#f5f4f0;--panel:#ecebe6;--line:#d6d4cc;--fg:#1f2326;--dim:#5f666d;--accent:#365a7d;
--todo:#7a8087;--prog:#8a5d0e;--rev:#365a7d;--ci:#6a4c9c;--done:#2f6b3f;--fail:#a3392b;--scrim:rgba(26,26,23,.28);color-scheme:light}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.5 var(--f-mono);font-variant-numeric:tabular-nums}
::selection{background:var(--accent);color:var(--bg)}
code,.key{font-family:var(--f-mono);font-size:12.5px}
button{font:inherit;color:inherit}
.mast{border-bottom:1px solid var(--line)}
.mast .in{max-width:1180px;margin-inline:auto;padding:14px 16px;display:flex;flex-wrap:wrap;gap:12px;align-items:center}
.brand{font-weight:600;letter-spacing:.04em}
.mast .stamp{color:var(--dim);font-size:11px;flex:1 1 200px;min-width:0}
.tbtn,.jsw{all:unset;cursor:pointer;border:1px solid var(--line);padding:2px 8px;border-radius:3px;font:12px var(--f-mono);color:var(--fg);display:inline-flex;gap:6px;align-items:center;transition:border-color .2s}
.tbtn:hover,.jsw:hover{border-color:var(--accent)}
.jsw .jt{display:inline-block;width:22px;height:10px;border:1px solid var(--dim);position:relative;transition:border-color .2s}
.jsw .jt::after{content:"";position:absolute;top:1px;left:1px;width:8px;height:6px;background:var(--dim);transition:transform .25s var(--ease),background .2s}
.jsw[aria-checked="true"] .jt{border-color:var(--accent)}.jsw[aria-checked="true"] .jt::after{transform:translateX(12px);background:var(--accent)}
.shell{max-width:1180px;margin-inline:auto;padding:0 16px 64px}
main{min-width:0}
.thb .d{background:var(--done)}.thb .t{background:var(--todo)}
.acc{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:14px 18px}
.ar{display:grid;grid-template-columns:7em minmax(0,1fr) 9.5em;gap:14px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line)}
.ar:last-of-type{border-bottom:0}
.ar .as{display:flex;gap:6px;align-items:baseline}
.atr{position:relative;height:18px;background:linear-gradient(var(--line),var(--line)) 0 50%/100% 1px no-repeat}
.atr i{position:absolute;top:50%;width:9px;height:9px;margin:-4.5px 0 0 -4.5px;border-radius:50%;background:color-mix(in srgb,var(--done) 55%,transparent);border:1px solid var(--done)}
.atr b{position:absolute;top:0;bottom:0;width:2px;margin-left:-1px;background:var(--ink)}
.ar .am{font-size:12.5px;text-align:right;white-space:nowrap}
.aax{display:flex;justify-content:space-between;font-size:11.5px;color:var(--muted);margin:4px 0 0 calc(7em + 14px);margin-right:calc(9.5em + 14px)}
.thr{display:grid;grid-template-columns:12em minmax(0,1fr) 3.5em;gap:12px;align-items:center;padding:5px 0;font-size:13px}
.thr .n{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.thb{display:flex;height:10px;border-radius:2px;overflow:hidden}.thb i{display:block;height:100%}
.thr .fact{text-align:right;margin:0}
.sum{font:500 18px/1.4 var(--f-serif);margin:12px 0 20px;max-width:62ch}
.head{font:500 22px/1.25 var(--f-serif);margin:0 0 8px}
section:focus{outline:none}
ol.decl{list-style:none;margin:0;padding:0}
.card{border-bottom:1px solid var(--line);padding:14px 0}
.band{display:inline-block;font:600 10.5px var(--f-sans);letter-spacing:.05em;text-transform:uppercase;padding:1px 6px;border-radius:3px;margin-right:8px;vertical-align:2px;border:1px solid var(--line);color:var(--muted)}
.band.b0{color:var(--warn);border-color:var(--warn)}.band.b1{color:var(--ink);border-color:var(--ink)}
.ctl{font-size:15px;font-weight:500;overflow-wrap:anywhere}
.fact{font-size:13px;color:var(--muted);margin-top:3px;overflow-wrap:anywhere}
.levers{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.lv{border:1px solid var(--line);background:var(--surface);border-radius:4px;padding:4px 10px;font-size:13px;cursor:pointer}
.lv:hover{border-color:var(--muted)}
.lv[aria-pressed="true"]{border-color:var(--ink);background:var(--ink);color:var(--bg)}
.wi{margin-top:10px;padding:12px 14px;border:1px solid var(--line);border-radius:6px;background:var(--surface)}
.wi .two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
.wi table.ld{margin:0}
.met{color:var(--done)}.ovr{color:var(--warn)}
.wi h4{font:600 12px var(--f-sans);color:var(--muted);margin:14px 0 2px}
.fall{list-style:none;margin:0;padding:0}
.fall li{display:grid;grid-template-columns:5.6em minmax(0,1fr) auto;gap:10px;align-items:baseline;padding:5px 0;border-top:1px solid var(--line);font-size:13px}
.fall label{display:inline-flex;gap:4px;align-items:center;color:var(--muted);font-size:12px;cursor:pointer;white-space:nowrap}
.fall .t{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.copy{display:flex;gap:8px;align-items:flex-start;margin-top:12px}
.copy pre{flex:1;min-width:0;margin:0;padding:8px 10px;background:var(--bg);border:1px solid var(--line);border-radius:4px;font:12.5px/1.55 var(--f-mono);white-space:pre-wrap;overflow-wrap:anywhere}
.x{color:var(--warn)}
.cur-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--live);margin-right:6px;vertical-align:1px}
.cap .p9{position:absolute;top:50%;width:7px;height:7px;margin:-4.5px 0 0 -4.5px;transform:rotate(45deg);border:1.5px solid var(--ink);border-radius:1px;background:var(--surface)}
.cap .p9.x{background:var(--warn);border-color:var(--warn)}
.gains{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,300px),1fr));gap:12px;margin-top:16px}
.gain{background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:14px 16px;min-width:0}
.gain h3{font:600 14px var(--f-sans);margin:0 0 4px}
.gain .gl{font-size:13px;color:var(--muted);margin:0 0 10px}
.gain ul{list-style:none;margin:0;padding:0;display:grid;gap:10px}
.gain li{font:500 16px/1.4 var(--f-serif);padding-left:16px;position:relative;overflow-wrap:anywhere}
.gain li::before{content:"";position:absolute;left:0;top:.55em;width:7px;height:7px;border-radius:50%;background:var(--done)}
.quotes{list-style:none;margin:-8px 0 24px;padding:0;display:grid;gap:10px;max-width:62ch}
.quotes li{border-left:2px solid var(--line);padding-left:12px;font-size:15px;line-height:1.5}
.quotes b{display:block;font:600 11.5px var(--f-sans);color:var(--muted);letter-spacing:.02em}
.n{all:unset;cursor:pointer;color:inherit;text-decoration:underline dotted 1.5px;text-underline-offset:4px;text-decoration-color:var(--muted)}
.n:hover{text-decoration-color:var(--ink)}
.n:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.strip{display:flex;height:8px;border-radius:2px;overflow:hidden;background:var(--todo)}
.strip i{display:block;height:100%}
.strip .d{background:var(--done)}.strip .l{background:var(--live)}.strip .s{background:color-mix(in srgb,var(--live) 45%,var(--todo))}
.cap{position:relative;height:8px;border-radius:2px;background:var(--line);margin-top:4px}
.cap i{position:absolute;top:0;bottom:0;left:0;background:var(--bar);border-radius:2px 0 0 2px}
.cap i.o{background:var(--warn);border-radius:0 2px 2px 0}
.cap b{position:absolute;top:-3px;bottom:-3px;width:1px;background:var(--ink)}
.cap.none{background:repeating-linear-gradient(45deg,var(--ldn) 0 3px,transparent 3px 7px)}
.cap-line{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:13px;color:var(--muted);margin:8px 0 20px}
.cap-line .n{color:var(--ink)}.cap-line .x{color:var(--warn)}
.bars{display:grid;gap:10px;margin:0 0 4px}
.work{margin:0 0 24px;padding:0;list-style:none}
.work li{display:flex;gap:10px;align-items:baseline;padding:6px 0;font-size:14px;min-width:0}
.work li span:last-child{min-width:0;overflow-wrap:anywhere}
h3.grp{font:600 12.5px var(--f-sans);color:var(--muted);margin:24px 0 4px;display:flex;justify-content:space-between;gap:12px}
h3.grp span{font-weight:400}
.tk{border-top:1px solid var(--line)}
.tk>summary{list-style:none;display:grid;grid-template-columns:14px minmax(0,1fr) auto;gap:4px 12px;align-items:start;padding:12px 0;cursor:pointer}
.tk>summary::-webkit-details-marker{display:none}
.tk>summary:hover .ui{text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:3px}
.tx{min-width:0;display:grid;gap:2px}
.ui{font-size:16px;line-height:1.45;overflow-wrap:anywhere}
.int{font-variant:small-caps;letter-spacing:.04em;color:var(--muted);font-size:14px}
.sub{font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tg{display:flex;gap:8px;align-items:center;font-size:12px;color:var(--muted);padding-top:3px;justify-content:flex-end;flex-wrap:wrap}
.mk{width:10px;height:10px;border-radius:50%;margin-top:7px;border:1.5px solid var(--todo);display:block}
.mk.done{background:var(--done);border-color:var(--done)}
.mk.live{background:var(--live);border-color:var(--live)}
.mk.started{border-color:var(--live);background:linear-gradient(90deg,var(--live) 50%,transparent 50%)}
@media (prefers-reduced-motion:no-preference){.mk.live{animation:pulse 2s ease-in-out infinite}}
@keyframes pulse{50%{box-shadow:0 0 0 4px color-mix(in srgb,var(--live) 25%,transparent)}}
.chip{font:500 11.5px var(--f-mono);padding:1px 6px;border-radius:3px;border:1px solid var(--live);color:var(--ink);white-space:nowrap}
.chip.READY{border-color:var(--done)}.chip.BLOCKED,.chip.FINDING{border-color:var(--warn);background:color-mix(in srgb,var(--warn) 14%,transparent)}
.sz{font:500 11.5px var(--f-mono)}
.dots{display:inline-flex;gap:2px}.dots i{width:4px;height:4px;border-radius:50%;background:var(--line)}.dots i.f{background:var(--muted)}
.more{padding:0 0 14px 26px;font-size:14px;color:var(--muted);max-width:66ch}
.more p{margin:0 0 8px;color:var(--ink)}
.more ul{margin:0;padding-left:18px}.more li{margin:2px 0}
.more a{color:var(--accent)}
details.done-grp,details.fold{border-top:1px solid var(--line)}
details.done-grp>summary,details.fold>summary{cursor:pointer;padding:12px 0;font-size:14px;color:var(--muted)}
.up{display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 12px;padding:8px 0;border-top:1px solid var(--line);font-size:14px}
.up span:last-child{grid-column:2;color:var(--muted);font-size:13px}
.up .t{min-width:0;overflow-wrap:anywhere}
footer{margin-top:64px;font-size:13px;color:var(--muted)}
.terms{display:grid;grid-template-columns:minmax(0,9em) minmax(0,1fr);gap:8px 16px;margin:8px 0 16px}
.terms dt{color:var(--ink);font-weight:500}.terms dd{margin:0}
.terms .mk,.terms .cap{display:inline-block;vertical-align:middle;margin:0 4px 0 0}
.terms .cap{width:40px}
.rules p{margin:4px 0}
#scrim{position:fixed;inset:0;background:var(--scrim);z-index:9}
#drawer{position:fixed;z-index:10;top:0;right:0;bottom:0;width:min(440px,100%);background:var(--surface);border-left:1px solid var(--line);display:flex;flex-direction:column}
#drawer[hidden],#scrim[hidden]{display:none}
.dhd{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;padding:20px 20px 12px;border-bottom:1px solid var(--line)}
.dhd h2{font:500 20px/1.3 var(--f-serif);margin:0}.dhd h2:focus{outline:none}
.dhd button{border:0;background:none;font-size:22px;line-height:1;cursor:pointer;color:var(--muted);padding:2px 6px;border-radius:4px}
#db{overflow:auto;padding:4px 20px 32px;overscroll-behavior:contain}
#db .note{font-size:13px;color:var(--muted);margin:12px 0}
#db .tk>summary{grid-template-columns:14px minmax(0,1fr)}
#db .tk .tg{grid-column:2;justify-content:flex-start;padding-top:0}
table.ld{width:100%;border-collapse:collapse;font-size:13.5px;margin:12px 0}
table.ld th,table.ld td{text-align:right;padding:6px 0 6px 8px;border-bottom:1px solid var(--line)}
table.ld th:first-child,table.ld td:first-child{text-align:left;padding-left:0}
table.ld th{font-weight:500;color:var(--muted);font-size:12px}
table.ld tr.x td{color:var(--warn)}
ol.ct{list-style:none;margin:0 0 8px;padding:0}
ol.ct li{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:2px 12px;padding:6px 0;border-top:1px solid var(--line);font-size:13.5px}
ol.ct li .t{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
ol.ct li .v{font-family:var(--f-mono);font-size:12px;color:var(--muted)}
:focus-visible{outline:1px solid var(--accent);outline-offset:1px}
/* the version-first view (HIMMEL-3990) */
.hero{padding:28px 0 4px}
.jk{color:var(--dim);font-size:11px;letter-spacing:.08em;text-transform:uppercase}
.hero h1{font:600 34px/1.15 var(--f-mono);margin:4px 0 10px;letter-spacing:-.01em}
.sent{font:16px/1.6 var(--f-sans);margin:0 0 14px}
.jn{all:unset;cursor:pointer;color:var(--accent);font-family:var(--f-mono);font-weight:600;border-bottom:1px dotted var(--accent)}
.jn:hover{border-bottom-style:solid}
.jn:focus-visible{outline:1px solid var(--accent);outline-offset:2px}
.jbar{display:flex;height:8px;background:var(--line);overflow:hidden;border-radius:1px}
.jbar.big{height:12px;max-width:760px}
.jbar i{display:block;height:100%;width:0;transition:width .7s var(--ease)}
.js-todo{background:var(--todo)}.js-prog{background:var(--prog)}.js-rev{background:var(--rev)}.js-ci{background:var(--ci)}.js-done{background:var(--done)}
.jst{white-space:nowrap}.jst::before{content:"● "}
.jc-todo{color:var(--todo)}.jc-prog{color:var(--prog)}.jc-rev{color:var(--rev)}.jc-ci{color:var(--ci)}.jc-done{color:var(--done)}.jc-fail{color:var(--fail)}
.jlegend{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;margin:10px 0 0}
.jnext{color:var(--dim);font:13px var(--f-sans);margin:12px 0 0}
.jnote{color:var(--fail);font:600 12px var(--f-mono);margin:0 0 10px}
.jalert{border:1px solid var(--fail);border-left-width:3px;background:var(--panel);padding:10px 14px;margin:18px 0 0;font-family:var(--f-sans)}
.jalert .jw{font:600 13px var(--f-mono);color:var(--fail)}.jalert ul{margin:6px 0 0;padding-left:18px}
#rm h2{font:600 13px var(--f-mono);letter-spacing:.06em;text-transform:uppercase;margin:36px 0 4px}
.jsub{color:var(--dim);font:12px var(--f-sans);margin:0 0 12px}
.jboard{display:grid;grid-template-columns:repeat(var(--cols,4),minmax(0,1fr));gap:10px}
.jcol{background:var(--panel);border:1px solid var(--line);padding:10px;min-height:80px;min-width:0}
.jcol h3{font:600 12px var(--f-mono);margin:0 0 8px;display:flex;justify-content:space-between;gap:8px}
.jcard{all:unset;display:block;box-sizing:border-box;width:100%;cursor:pointer;border:1px solid var(--line);padding:8px 10px;margin:0 0 8px;background:var(--bg);transition:border-color .2s,transform .2s var(--ease)}
.jcard:hover{border-color:var(--accent);transform:translateY(-1px)}
.jcard:focus-visible{outline:1px solid var(--accent);outline-offset:1px}
.jkey{font-size:11px;color:var(--dim)}.jtl{font-size:12.5px;margin:2px 0;overflow-wrap:anywhere}.jui{font:12px/1.45 var(--f-sans);color:var(--dim);overflow-wrap:anywhere}
.jchip{display:inline-block;font-size:11px;border:1px solid var(--prog);color:var(--prog);border-radius:3px;padding:0 5px;margin-top:4px}
.jnone{color:var(--dim);font-size:12px}
.jdonefold{color:var(--dim);font:12px var(--f-sans);margin-top:10px}
.enter{animation:enter .32s var(--ease) both}
.leave{animation:leave .18s ease-in both}
@keyframes enter{from{opacity:0;transform:translateY(4px)}}
@keyframes leave{to{opacity:0;transform:translateY(-3px)}}
#rm table{width:100%;border-collapse:collapse}
#rm th,#rm td{padding:7px 8px;text-align:right;border-bottom:1px solid var(--line);white-space:nowrap}
#rm th{font-size:11px;color:var(--dim);font-weight:400;letter-spacing:.08em;text-transform:uppercase}
#rm th:first-child,#rm td:first-child,#rm th:nth-child(2),#rm td:nth-child(2){text-align:left}
#rm td.barc{width:26%;min-width:120px}
tr[data-v]{cursor:pointer;transition:background .35s}
tr[data-v]:hover{background:var(--panel)}
tr.jsel{background:color-mix(in srgb,var(--accent) 12%,transparent)}
tr.jsel td:first-child{box-shadow:inset 2px 0 var(--accent)}
tr.jflash{animation:jflash .9s ease-out}
@keyframes jflash{from{background:color-mix(in srgb,var(--accent) 30%,transparent)}}
.vn{font-weight:600}
.z{color:var(--line)}
.tw{overflow-x:auto}
#db .jrow{border-bottom:1px solid var(--line);padding:10px 0}
#db .jrow .jm{font-size:12px;margin-top:2px}
#db .jrow .jtl{font-size:13px}
#drawer:not([hidden]){animation:dslide .3s var(--ease)}
@keyframes dslide{from{opacity:0;transform:translateX(24px)}}
.krel{border:1px solid var(--line);margin:0 0 8px}
.krel>summary{cursor:pointer;padding:8px 10px;font:600 13px var(--f-mono)}
.krel>summary:focus-visible{outline:1px solid var(--accent);outline-offset:-1px}
.kmeta{color:var(--dim);font-weight:400;font-size:12px;margin-left:8px}
.kboard{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;padding:0 10px 10px}
.kcol{background:var(--panel);border:1px solid var(--line);padding:10px;min-width:0}
.kcol h3{font:600 12px var(--f-mono);margin:0 0 8px;display:flex;justify-content:space-between;gap:8px}
.kcol[data-col="todo"] h3{color:var(--todo)}.kcol[data-col="prog"] h3{color:var(--prog)}.kcol[data-col="rev"] h3{color:var(--rev)}.kcol[data-col="ci"] h3{color:var(--ci)}.kcol[data-col="done"] h3{color:var(--done)}
.kcard{border:1px solid var(--line);padding:8px 10px;margin:0 0 8px;background:var(--bg)}
a.kkey{color:var(--accent)}.kkey{font:11px var(--f-mono)}
.ktl{font-size:12.5px;margin:2px 0;overflow-wrap:anywhere}.kline{font:12px/1.45 var(--f-sans);color:var(--dim);overflow-wrap:anywhere}
.knone{color:var(--dim);font-size:12px}
.plan{margin-top:48px;border-top:1px solid var(--line)}
.plan>h2.jh{font:600 13px var(--f-mono);letter-spacing:.06em;text-transform:uppercase;margin:28px 0 4px}
.plan{font:14px/1.5 var(--f-sans)}
.plan>details>summary,.plan footer details>summary{color:var(--fg)}
.plan details>div,.plan details>ol{padding-bottom:14px}
#decs.hot{color:var(--fail)}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
@media (max-width:760px){
 .jboard,.kboard{grid-template-columns:minmax(0,1fr)}.hero h1{font-size:27px}#rm td.barc,#rm th.barc{display:none}
}
@media (max-width:560px){
 .shell{padding:0 16px 48px}.mast .in{padding:10px 16px}
 .ar{grid-template-columns:4.6em minmax(0,1fr);row-gap:2px}.ar .am{grid-column:2;text-align:left}.aax{margin:4px 0 0 calc(4.6em + 14px)}
 .thr{grid-template-columns:minmax(0,7em) minmax(0,1fr) 3em}
 .sum{font-size:17px}
 .wi{padding:10px}.wi .two{grid-template-columns:minmax(0,1fr)}
 .fall li{grid-template-columns:auto minmax(0,1fr);row-gap:2px}.fall li>:last-child{text-align:right}.fall .t{grid-column:1/-1;order:3}
 .tk>summary{grid-template-columns:14px minmax(0,1fr)}.tg{grid-column:2;justify-content:flex-start;padding-top:0}
 #drawer{top:auto;left:0;width:100%;height:85vh;border-left:0;border-top:1px solid var(--line);border-radius:12px 12px 0 0}
 .dhd::before{content:"";position:absolute;left:50%;top:6px;width:36px;height:4px;margin-left:-18px;border-radius:2px;background:var(--line)}
 .terms{grid-template-columns:minmax(0,1fr)}
}
</style>
<header class="mast"><div class="in"><b class="brand">himmel · roadmap</b><span class="stamp" id="stamp"></span>
<button class="jsw" id="hide" type="button" role="switch" aria-checked="true" title="Hides Done and In Public from the boards and lists; the counts in the hero sentence and the table still include them. Closed and wont do tickets are in no count."><span class="jt"></span>Hide done work</button>
<button class="tbtn" id="theme" type="button">Theme</button></div></header>
<div class="shell" id="main">
<main>
<div id="rm">
<p class="jsub" id="pages"></p>
<section class="hero" aria-labelledby="hh">
<div class="jk">Working on</div>
<h1 id="hh"></h1>
<p class="jnote" id="hnote"></p>
<p class="sent" id="sent"></p>
<div class="jbar big" id="hbar"></div>
<div class="jlegend" id="legend"></div>
<p class="jnext" id="next"></p>
<div id="alerts"></div>
</section>
<section aria-labelledby="bh"><h2 id="bh"></h2><p class="jsub" id="bsub"></p>
<div class="jboard" id="board"></div><p class="jdonefold" id="donefold"></p></section>
<section aria-labelledby="vh"><h2 id="vh">Every version</h2>
<p class="jsub">In Jira's release order. Pick a row to see its board; every number opens its tickets.</p>
<div class="tw"><table><thead><tr><th>Version</th><th>State</th><th class="barc">Progress</th>
<th>To Do</th><th>In Progress</th><th>In Review</th><th>IN CI</th><th>Done</th><th>Total</th></tr></thead><tbody id="vt"></tbody></table></div>
<p class="jsub" id="vfold"></p></section>
<section aria-labelledby="kh"><h2 id="kh">Release boards</h2>
<p class="jsub">Open a release to see its tickets by status. Each card links to its Jira ticket and says what it means for a user.</p>
__KANBAN__</section>
</div>
<section class="plan" aria-label="The plan">
<h2 class="jh">The plan, folded</h2>
<p class="jsub">The forecast behind the versions above: what the plan expects, what finished work took, and the sectors the running version spans.</p>
<details class="fold"><summary>How long finished tickets took, against their estimate</summary><div class="acc" id="accb"></div></details>
<details class="fold"><summary id="themh">Sectors in the running version</summary><div id="themb"></div></details>
<footer>
<details class="fold"><summary>Budget rules</summary><div class="rules" id="rules"></div></details>
<details class="fold"><summary>Terms</summary>
<dl class="terms" id="terms"></dl></details>
<p id="prov"></p>
</footer>
</section>
</main>
</div>
<div id="scrim" hidden></div>
<aside id="drawer" role="dialog" aria-modal="true" aria-labelledby="dh" hidden><div class="dhd"><h2 id="dh" tabindex="-1"></h2><button type="button" id="dx" aria-label="Close">×</button></div><div id="db"></div></aside>
<script type="application/json" id="data">__DATA__</script>
<script>
(function(){
var D=JSON.parse(document.getElementById("data").textContent);
/*MODEL*/
// Pure model: every figure on the page and every drill-down list comes from here; test-tracker.sh runs it under node.
function model(D){
 var V=D.V,P=D.P,T=D.T,LEG=D.LEG||{};
 var KIND=["bugs","improvements","features","other","audits"];
 var READY=["no plan yet","problem stated","fix named, not yet checked","plan audited","spec ready"];
 function train(i){return /^v1\.\d+\.\d+[a-z]?$/.test(V[i])}
 // vname(i): a trail (v1.0.2b, c, ...) reads as its parent's overflow, not a new release.
 function vname(i){var m=/^(v1\.0\.\d+)([a-z])$/.exec(V[i]);return m?m[1]+" · overflow"+(m[2]<="b"?"":" "+(m[2].charCodeAt(0)-97)):V[i]}
 function keep(rem){return function(p){return !rem||p[2]!=2}}
 function inV(i,rem){return P.filter(function(p){return p[3]==i}).filter(keep(rem))}
 function inT(t,rem){return P.filter(function(p){return p[5]==t&&train(p[3])}).filter(keep(rem))}
 function inTrain(rem){return P.filter(function(p){return train(p[3])}).filter(keep(rem))}
 function leg(p){return p[2]!=2&&LEG[String(p[0])]||null}
 function tally(a){var r={n:a.length,done:0,prog:0,todo:0,live:0};
  a.forEach(function(p){if(p[2]==2)r.done++;else if(p[2]==1)r.prog++;else r.todo++;if(leg(p))r.live++});r.left=r.n-r.done;return r}
 function r4(x){return Math.round(x*10000)/10000}
 function ld(p){return p[7]==2?0:(p[15]||0)}
 function rank(p){return p[2]==2?3:leg(p)?0:p[2]==1?1:2}
 function order(a){return a.slice().sort(function(x,y){return rank(x)-rank(y)||(y[12]||0)-(x[12]||0)||x[0]-y[0]})}
 // load(i): the version's budget by kind of work, each kind with its tickets (heaviest first); caps are the version's own (VC).
 function load(i,rem){
  var a=inV(i,rem),c=D.VC[i],tot=0;
  var kinds=KIND.map(function(k,j){var t=a.filter(function(p){return p[4]==j&&ld(p)>0}).sort(function(x,y){return ld(y)-ld(x)||x[0]-y[0]}),u=0;
   t.forEach(function(p){u+=ld(p)});tot+=u;var cap=c?c.l[j]:null;
   return {kind:k,used:r4(u),cap:cap,head:cap==null?null:r4(cap-u),over:cap!=null&&u>cap+1e-9,tickets:t}});
  var planned=a.filter(function(p){return p[7]!=2}).length;
  // p90: the plan's cautious load for the whole version (effort model P90), next to its cap; null when not recorded.
  var p9=D.VP&&D.VP[i]!=null?D.VP[i]:null;
  return {used:r4(tot),cap:c?c.tot:null,planned:planned,tcap:c?c.t:null,kinds:kinds,deferred:!c,p90:p9,p90cap:c&&c.p9!=null?c.p9:null}}
 function isInt(p){return /^internal\b/i.test(p[9]||"")}
 function isUser(p){return !!p[9]&&!isInt(p)}
 function best(a){return a.slice().sort(function(x,y){return (y[12]||0)-(x[12]||0)||(x[6]||0)-(y[6]||0)||x[0]-y[0]})[0]}
 function pl(n,one,many){return n+" "+(n==1?one:many)}
 // summary(a, by): deterministic words from the tickets' user impact. by "theme" for a version, "version" for a theme.
 function summary(a,by){
  var u=a.filter(isUser),i=a.filter(isInt).length,g={},col=by=="theme"?5:3;
  function name(k){return by=="theme"?T[k]:vname(k)}
  u.forEach(function(p){var k=p[col];g[k]=g[k]||{k:k,n:0,s:0,a:[]};g[k].n++;g[k].s+=p[12]||0;g[k].a.push(p)});
  var gs=Object.keys(g).map(function(k){return g[k]}).sort(function(x,y){return y.s-x.s||y.n-x.n||String(name(x.k)).localeCompare(String(name(y.k)))});
  var s;
  if(!a.length)s="Nothing left here.";
  else if(!u.length&&i)s="Housekeeping only: "+pl(i,"internal change","internal changes")+".";
  else if(!u.length)s=pl(a.length,"ticket","tickets")+", none described in the plan yet.";
  else{s="Ships "+pl(u.length,"change","changes")+" for users"+(i?" and "+pl(i,"internal one","internal ones"):"");
   if(by=="theme"){var nm=gs.filter(function(x){return !/^\(/.test(T[x.k])}).slice(0,2);
    if(nm.length)s+="; mostly "+nm.map(function(x){return T[x.k]+" ("+x.n+")"}).join(" and ")}
   else{var vs=a.map(function(p){return p[3]}).sort(function(x,y){return x-y});s+=", from "+vname(vs[0])+(vs[vs.length-1]!=vs[0]?" to "+vname(vs[vs.length-1]):"")}
   s+="."}
  return {lead:s,quotes:gs.slice(0,3).map(function(x){var p=best(x.a);return {p:p,text:p[9]}})}}
 // drill(kind, scope): the tickets behind one figure; scope {v:i} or {t:i} or {train:1}.
 function drill(kind,scope,rem){
  var a=scope.v!=null?inV(scope.v,rem):scope.t!=null?inT(scope.t,rem):inTrain(rem);
  var f={all:function(){return true},done:function(p){return p[2]==2},left:function(p){return p[2]!=2},
   live:function(p){return !!leg(p)},prog:function(p){return p[2]==1&&!leg(p)},doing:function(p){return p[2]==1},todo:function(p){return p[2]==0}}[kind];
  return order(a.filter(f))}
 function current(rem){for(var i=0;i<V.length;i++)if(train(i)&&inV(i).some(function(p){return p[2]!=2}))return i;return null}
 // Steering (the release desk). The page cannot act: it computes what a lever would change and words the instruction.
 function pinned(p){return (D.PIN||[]).indexOf(p[0])>=0}
 function planned(p){return p[7]!=2}
 function roi(p){return (p[12]||0)/Math.max(p[6]||0,.1)}
 // trail(i): the overflow version that takes i's work: v1.0.2 → v1.0.2b, v1.0.2b → v1.0.2c; i -1 when it does not exist yet.
 function trail(i){var m=/^(v1\.0\.\d+)([a-z]?)$/.exec(V[i]);if(!m)return null;
  var n=m[1]+(m[2]?String.fromCharCode(m[2].charCodeAt(0)+1):"b");return {i:V.indexOf(n),name:n}}
 function parent(i){var m=/^(v1\.0\.\d+)[a-z]$/.exec(V[i]);return m?V.indexOf(m[1]):-1}
 function base(i){var m=0;inV(i).forEach(function(p){if(planned(p))m+=ld(p)});return m}
 // ratio(i): P90 per unit of mean in version i, so a what-if can move the P90 with the mean.
 // ponytail: the P90 after a move is scaled from the plan's own P90 by mean (≈), not re-simulated; re-run the placer to confirm.
 function ratio(i){var b=base(i),v=D.VP&&D.VP[i];return v!=null&&b>0?v/b:null}
 // stats(i, a, r): a ticket set's load in version i (i -1: a trail not yet made): planned count, mean, per kind, and P90 (≈).
 function stats(i,a,r){var k=[0,0,0,0,0],m=0,n=0;a.forEach(function(p){if(!planned(p))return;n++;m+=ld(p);k[p[4]]+=ld(p)});
  var v=i>=0&&D.VP?D.VP[i]:null,b=i>=0?base(i):0,q=i>=0?ratio(i):null,p9=null;
  if(v!=null)p9=v+(m-b)*(q!=null?q:r||0);else if(r!=null&&m>0)p9=m*r;
  return {n:n,m:r4(m),k:k.map(r4),p9:p9==null?null:r4(Math.max(p9,0))}}
 function capsOf(i,from){return i>=0?D.VC[i]:D.VC[from]}
 // breaches(i, st, c): every cap the stats break: mean, tickets, P90, then each kind.
 function breaches(i,st,c){c=c||D.VC[i];if(!c)return [];var b=[],e=1e-9;
  if(c.tot!=null&&st.m>c.tot+e)b.push({what:"mean",used:st.m,cap:c.tot});
  if(c.t!=null&&st.n>c.t)b.push({what:"tickets",used:st.n,cap:c.t});
  if(c.p9!=null&&st.p9!=null&&st.p9>c.p9+e)b.push({what:"P90",used:st.p9,cap:c.p9});
  KIND.forEach(function(k,j){if(c.l&&c.l[j]!=null&&st.k[j]>c.l[j]+e)b.push({what:k,used:st.k[j],cap:c.l[j]})});return b}
 // peel(i, {keep, unpin}): take the open, leg-free, unpinned tickets by lowest return (impact per size) until every cap holds;
 // each step takes the first candidate that eases a cap still broken. keep: tickets the viewer pins here; unpin: plan pins released.
 function peel(i,o){o=o||{};var keep=o.keep||[],un=o.unpin||[],a=inV(i).filter(planned),cur=a.slice(),out=[];
  var cand=a.filter(function(p){return p[2]!=2&&!leg(p)&&keep.indexOf(p[0])<0&&(!pinned(p)||un.indexOf(p[0])>=0)})
   .sort(function(x,y){return roi(x)-roi(y)||(y[6]||0)-(x[6]||0)||x[0]-y[0]});
  for(;;){var b=breaches(i,stats(i,cur));if(!b.length)break;
   var w=b.map(function(x){return x.what}),j=-1;
   for(var q=0;q<cand.length&&j<0;q++){var p=cand[q];
    if(w.indexOf("tickets")>=0||(ld(p)>0&&(w.indexOf("mean")>=0||w.indexOf("P90")>=0||w.indexOf(KIND[p[4]])>=0)))j=q}
   if(j<0)break;out.push(cand[j]);cur.splice(cur.indexOf(cand[j]),1);cand.splice(j,1)}
  return {moved:out,left:breaches(i,stats(i,cur)),held:a.filter(function(p){return pinned(p)&&p[2]!=2&&un.indexOf(p[0])<0})}}
 // whatIf(i, moved, to): both versions before and after moving the tickets from i to `to` (-1: the trail not yet made).
 function whatIf(i,moved,to){var a=inV(i),r=ratio(i),ta=to>=0?inV(to):[],c=capsOf(to,i);
  var fa=a.filter(function(p){return moved.indexOf(p)<0}),f0=stats(i,a),f1=stats(i,fa),t0=stats(to,ta,r),t1=stats(to,ta.concat(moved),r);
  f0.b=breaches(i,f0);f1.b=breaches(i,f1);t0.b=breaches(to,t0,c);t1.b=breaches(to,t1,c);
  return {from:{i:i,before:f0,after:f1},to:{i:to,before:t0,after:t1,caps:c}}}
 // fold(i): the trail's open tickets, best return first, that its parent can take back without breaking a cap.
 function fold(i){var pr=parent(i);if(pr<0)return [];var cur=inV(pr).slice(),out=[];
  if(breaches(pr,stats(pr,cur)).length)return [];
  inV(i).filter(function(p){return p[2]!=2&&planned(p)&&!leg(p)}).sort(function(x,y){return roi(y)-roi(x)||x[0]-y[0]}).forEach(function(p){
   if(!breaches(pr,stats(pr,cur.concat([p]))).length){cur.push(p);out.push(p)}});return out}
 // decisions(): what needs input, ordered. Band 0 stops now (a BLOCKED or FINDING leg); band 1 blocks the release (the running
 // version and the next: caps, drift); band 2 queue health (later caps, drift, the unplaced, a trail its parent can take back).
 function decisions(){var cur=D.CUR,nx=cur!=null&&cur+1<V.length&&train(cur+1)?cur+1:-1,out=[];
  function near(i){return i==cur||i==nx}
  P.forEach(function(p){var lg=leg(p);if(lg&&(lg[1]=="BLOCKED"||lg[1]=="FINDING"))out.push({band:0,type:"leg",i:p[3],p:p,s:lg[1]=="BLOCKED"?0:1})});
  V.forEach(function(_,i){var b=breaches(i,stats(i,inV(i)));if(b.length)out.push({band:near(i)?1:2,type:"cap",i:i,b:b})});
  P.forEach(function(p){if(p[7]==1&&p[2]!=2&&train(p[3]))out.push({band:near(p[3])?1:2,type:"drift",i:p[3],p:p})});
  V.forEach(function(_,i){var f=fold(i);if(f.length)out.push({band:2,type:"fold",i:i,f:f})});
  var u=(D.U||[]).filter(function(x){return x[2]!=2});if(u.length)out.push({band:2,type:"unplaced",i:u.length,u:u,last:1});
  var TR={leg:0,cap:1,drift:2,fold:3,unplaced:4};
  return out.sort(function(x,y){return x.band-y.band||(x.last||0)-(y.last||0)||x.i-y.i||TR[x.type]-TR[y.type]||(x.s||0)-(y.s||0)||(x.p?x.p[0]:0)-(y.p?y.p[0]:0)})}
 // gains(): done work per train version, newest first: what users got.
 function gains(){var g=[];for(var i=V.length-1;i>=0;i--){if(!train(i))continue;var d=order(inV(i).filter(function(p){return p[2]==2}));
  if(d.length)g.push({i:i,done:d,n:inV(i).length,s:summary(d,"theme")})}return g}
 // act(p): what a done ticket took, [wrapped legs, wall minutes, active minutes, dated legs]; null while open or when no wrapped leg doc names it.
 function act(p){return p[2]==2&&D.ACT&&D.ACT[String(p[0])]||null}
 var SZ=["XS","S","M","L","XL"];
 function szk(e){var s=String(e).split("–");return SZ.indexOf(s[0])*10+SZ.indexOf(s[s.length-1])}
 function med(a){var s=a.slice().sort(function(x,y){return x-y}),n=s.length;return n?(n%2?s[(n-1)/2]:(s[n/2-1]+s[n/2])/2):null}
 // accuracy(): measured done tickets grouped by their size estimate, smallest first, each with its median wall minutes and
 // legs; a ticket with no dated leg doc has no wall time and is left out.
 function accuracy(){var g={};P.forEach(function(p){var a=act(p);if(a&&a[3]!==0&&p[10])(g[p[10]]=g[p[10]]||[]).push({p:p,legs:a[0],min:a[1]})});
  return Object.keys(g).sort(function(x,y){return szk(x)-szk(y)}).map(function(k){var r=g[k].sort(function(x,y){return x.min-y.min||x.p[0]-y.p[0]});
   return {size:k,n:r.length,rows:r,med:med(r.map(function(x){return x.min})),legs:med(r.map(function(x){return x.legs}))}})}
 return {KIND:KIND,READY:READY,train:train,vname:vname,inV:inV,inT:inT,inTrain:inTrain,leg:leg,tally:tally,load:load,summary:summary,
  drill:drill,order:order,isUser:isUser,current:current,ld:ld,pinned:pinned,roi:roi,trail:trail,parent:parent,stats:stats,breaches:breaches,
  peel:peel,whatIf:whatIf,fold:fold,decisions:decisions,gains:gains,act:act,accuracy:accuracy,med:med}}
/*END MODEL*/
var M=model(D),V=D.V.map(function(_,i){return M.vname(i)}),T=D.T,REM=false,opener=null;
function $(i){return document.getElementById(i)}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function txt(s){return document.createTextNode(s)}
function add(p){for(var i=1;i<arguments.length;i++){var c=arguments[i];if(c==null)continue;p.appendChild(typeof c=="string"?txt(c):c)}return p}
function pl(n,one,many){return n+" "+(n==1?one:many)}
function f2(x){return x==null?"–":x.toFixed(2)}
function pct(n,d){return d?Math.round(100*n/d):0}
function nb(label,kind,scope,title){var b=el("button","n",label);b.type="button";
 b.addEventListener("click",function(e){e.preventDefault();e.stopPropagation();openDrill(kind,scope,title,b)});return b}
function keyOf(p){return "HIMMEL-"+p[0]}
function dots(n){var d=el("span","dots");d.setAttribute("role","img");d.setAttribute("aria-label","impact "+n+" of 5");d.title="impact "+n+" of 5";
 for(var i=1;i<=5;i++)d.appendChild(el("i",i<=n?"f":null));return d}
function chip(lg){var t=lg[0]+" · "+(lg[1]=="LIVE"&&lg[2]?"PR #"+lg[2]:lg[1]);var c=el("span","chip "+lg[1],t);c.title="leg "+lg[0]+", last marker "+lg[1]+(lg[2]?", PR "+lg[2]:"");return c}
function mark(p){var lg=M.leg(p),c=p[2]==2?"done":lg?"live":p[2]==1?"started":"todo",
 w={done:"done",live:"a leg is on it",started:"started in Jira, no leg",todo:"to do"}[c];var m=el("span","mk "+c);m.setAttribute("role","img");m.setAttribute("aria-label",w);m.title=w;return m}
function impactText(p,host){
 if(!p[9]){host.textContent=p[1];return host}
 var m=/^internal:\s*/i.exec(p[9]);if(m){add(host,el("span","int","Internal")," "+p[9].slice(m[0].length))}else host.textContent=p[9];return host}
function ticket(p){
 var d=el("details","tk"),s=el("summary"),tx=el("span","tx"),sub=el("span","sub"),tg=el("span","tg"),lg=M.leg(p);
 add(sub,el("code",null,keyOf(p)),p[9]?" · "+p[1]:null);sub.title=p[1];
 add(tx,impactText(p,el("span","ui")),sub);
 if(lg)tg.appendChild(chip(lg));if(p[10])add(tg,el("span","sz",p[10]));if(p[12]!=null)tg.appendChild(dots(p[12]));
 add(s,mark(p),tx,tg);d.appendChild(s);
 d.addEventListener("toggle",function(){if(d.open&&!d.dataset.f){d.dataset.f="1";d.appendChild(more(p))}});return d}
function more(p){
 var m=el("div","more"),u=el("ul");if(p[14])m.appendChild(el("p",null,p[14]));
 if(p[11]!=null)u.appendChild(el("li",null,"Ready to build: "+M.READY[p[11]]+" ("+p[11]+" of 4)."));
 if(p[10])u.appendChild(el("li",null,"Size "+p[10]+(p[6]?", about "+p[6]+" S-equivalents":"")+(p[15]?"; uses "+p[15].toFixed(3)+" of "+V[p[3]]+"'s budget":"")+"."));
 if(p[13])u.appendChild(el("li",null,"Planning slice only ("+p[13]+"): not ready enough to build, so "+V[p[3]]+" schedules the plan, not the fix."));
 u.appendChild(el("li",null,"Sector: "+T[p[5]]+" · kind: "+M.KIND[p[4]]+" · "+V[p[3]]+"."));
 if(p[7]==1)u.appendChild(el("li",null,"Jira names a different version than the plan."));
 if(p[7]==2)u.appendChild(el("li",null,"Not in the plan: Jira puts it in "+V[p[3]]+"."));
 var lg=M.leg(p);if(lg)u.appendChild(el("li",null,"Leg "+lg[0]+" is on it; its last marker is "+lg[1]+(lg[2]?", PR "+lg[2]:"")+"."));
 m.appendChild(u);
 if(p[8]&&p[8].length){var n=el("ul");p[8].forEach(function(i){var x=D.N[i],pa=D.DR[x[0]]+"/"+x[1],a=el("a",null,x[2]);
  a.href="obsidian://open?vault=luna&file="+encodeURIComponent(pa.replace(/\.md$/,""));a.title=pa;n.appendChild(add(el("li"),a))});
  add(m,el("p",null,"Vault notes that mention it:"),n)}
 return m}
function strip(t){var s=el("div","strip");s.setAttribute("role","img");
 s.setAttribute("aria-label",t.done+" done, "+t.live+" with a leg, "+(t.prog-t.live)+" started, "+t.todo+" to do");
 [["d",REM?0:t.done],["l",t.live],["s",t.prog-t.live]].forEach(function(x){if(x[1]>0){var i=el("i",x[0]);i.style.width=(100*x[1]/(t.n||1))+"%";s.appendChild(i)}});return s}
function capBar(ld){var c=el("div","cap");c.setAttribute("role","img");
 if(ld.deferred||ld.cap==null){c.className="cap none";c.setAttribute("aria-label","no cap");return c}
 // the P90 diamond sits where the cautious load falls against its own cap, drawn on the mean's scale.
 var q=ld.p90!=null&&ld.p90cap?ld.cap*ld.p90/ld.p90cap:null,sc=Math.max(ld.cap,ld.used,q||0)||1,f=el("i");f.style.width=(100*Math.min(ld.used,ld.cap)/sc)+"%";c.appendChild(f);
 if(ld.used>ld.cap){var o=el("i","o");o.style.left=(100*ld.cap/sc)+"%";o.style.width=(100*(ld.used-ld.cap)/sc)+"%";c.appendChild(o)}
 var k=el("b");k.style.left=(100*ld.cap/sc)+"%";c.appendChild(k);
 if(q!=null){var d=el("i",ld.p90>ld.p90cap+1e-9?"p9 x":"p9");d.style.left=(100*q/sc)+"%";c.appendChild(d)}
 c.setAttribute("aria-label","budget "+f2(ld.used)+" of "+f2(ld.cap)+(q!=null?", cautious "+f2(ld.p90)+" of "+f2(ld.p90cap):""));return c}
function capLine(i,ld){var l=el("div","cap-line");
 if(ld.deferred){add(l,"Deferred bucket: no cap. ",nb(f2(ld.used)+" budget","load",{v:i},V[i]+": budget by kind")," parked here.");return l}
 var over=ld.kinds.filter(function(k){return k.over});
 add(l,el("span",null,"Budget used "),nb(f2(ld.used)+(ld.cap!=null?" of "+f2(ld.cap):""),"load",{v:i},V[i]+": budget by kind"),
  el("span",null,pl(ld.planned,"planned ticket","planned tickets")+(ld.tcap!=null?" of a "+ld.tcap+" cap":"")));
 if(over.length)l.appendChild(el("span","x",over.map(function(k){return k.kind}).join(", ")+" over cap"));return l}
function headline(i,t){var h=el("h2","head");add(h,el("span","v",V[i])," — ");
 if(!t.left&&t.n){add(h,"shipped, ",nb(pl(t.n,"ticket","tickets"),"all",{v:i},V[i]+": every ticket"),".");return h}
 if(REM)add(h,nb(t.left+" left","left",{v:i},V[i]+": what is left"));
 else add(h,nb(t.left+" of "+t.n,"left",{v:i},V[i]+": what is left")," left");
 if(t.live)add(h,", ",nb(pl(t.live,"leg","legs"),"live",{v:i},V[i]+": legs on it now")," on it now");
 return add(h,".")}
// sumPara: the lead sentence, then each top group's best ticket quoted verbatim under its group's name.
function sumPara(sm,by){var f=document.createDocumentFragment(),u=el("ul","quotes");f.appendChild(el("p","sum",sm.lead));
 sm.quotes.forEach(function(q){if(q.text)u.appendChild(add(el("li"),el("b",null,by=="version"?V[q.p[3]]:T[q.p[5]]),q.text))});
 if(u.firstChild)f.appendChild(u);return f}
function counts(i,t){var l=el("div","cap-line");
 if(!REM&&t.done)l.appendChild(nb(t.done+" done ("+pct(t.done,t.n)+" %)","done",{v:i},V[i]+": done"));
 if(t.live)l.appendChild(nb(pl(t.live,"leg","legs")+" working","live",{v:i},V[i]+": legs on it now"));
 if(t.prog-t.live)l.appendChild(nb((t.prog-t.live)+" started, no leg","prog",{v:i},V[i]+": in progress"));
 l.appendChild(nb(t.todo+" to do","todo",{v:i},V[i]+": to do"));return l}
function ticketList(host,a,groupCol,groupName,cmp){
 var open=M.order(a.filter(function(p){return p[2]!=2})),done=M.order(a.filter(function(p){return p[2]==2})),g={},ks=[];
 open.forEach(function(p){var k=p[groupCol];if(!g[k]){g[k]=[];ks.push(k)}g[k].push(p)});
 ks.sort(cmp||function(x,y){return g[y].length-g[x].length||String(groupName(x)).localeCompare(String(groupName(y)))});
 ks.forEach(function(k){host.appendChild(add(el("h3","grp"),groupName(k),el("span",null,g[k].length+" left")));g[k].forEach(function(p){host.appendChild(ticket(p))})});
 if(done.length){var d=el("details","done-grp");d.appendChild(el("summary",null,done.length+" done ›"));
  d.addEventListener("toggle",function(){if(d.open&&!d.dataset.f){d.dataset.f="1";done.forEach(function(p){d.appendChild(ticket(p))})}});host.appendChild(d)}}
function versionBody(i,host){
 var a=M.inV(i,REM),t=M.tally(a),ld=M.load(i,REM);
 host.appendChild(sumPara(M.summary(a,"theme"),"theme"));
 var b=el("div","bars");add(b,strip(t),counts(i,t),capBar(ld),capLine(i,ld));host.appendChild(b);
 var w=a.filter(function(p){return M.leg(p)});
 if(w.length){host.appendChild(add(el("h3","grp"),"Working now",el("span",null,pl(w.length,"leg","legs"))));
  var ul=el("ul","work");w.forEach(function(p){ul.appendChild(add(el("li"),chip(M.leg(p)),impactText(p,el("span"))))});host.appendChild(ul)}
 ticketList(host,a,5,function(k){return T[k]})}
function num(x){return x==null?"–":x===Math.round(x)?String(x):f2(x)}
function bw(b){return b.what+" "+num(b.used)+" of "+num(b.cap)}
function fmtMin(m){return m==null?"–":m<60?Math.round(m)+" min":(Math.round(m/6)/10)+" h"}
// renderBench(h): the benchmark: each planned item with its own legs or a spawned bundle, then the
// operator-directed and unattributed bundles; raw inputs sit beside the ratio. Row fields follow BENCH_COLS in tracker.py.
function renderBench(h){var rows=(D.BN||[]).concat(D.BOP?[D.BOP]:[],D.BUN?[D.BUN]:[]);if(!rows.length)return;
 var tb=el("table","ld"),hr=el("tr"),n=function(v){return v==null||v===""?"–":String(v)};
 ["Item","Size","Est S-eq","Own wall / active (dated/legs)","Bundle n (open/done)","Bundle wall / active (dated/legs)","Total wall","Min per S-eq","Ratio"]
  .forEach(function(x){hr.appendChild(el("th",null,x))});tb.appendChild(hr);
 rows.forEach(function(x){var tr=el("tr");
  [x[0]+(x[1]?" "+x[1]:""),n(x[2]),n(x[3]),x[4]==null?"–":fmtMin(x[6])+" / "+fmtMin(x[7])+" ("+x[5]+"/"+x[4]+")",
   x[8]+" ("+x[9]+"/"+x[10]+")",fmtMin(x[13])+" / "+fmtMin(x[14])+" ("+x[12]+"/"+x[11]+")",fmtMin(x[15]),
   x[17]==null?"–":x[17].toFixed(1),x[18]==null?"–":x[18].toFixed(2)].forEach(function(c){tr.appendChild(el("td",null,c))});
  tr.title=x[21].length?x[21].map(function(k){return "HIMMEL-"+k}).join(", "):"no bundle";tb.appendChild(tr)});
 h.appendChild(el("p","fact","Estimate against actual. A bundle is the unplanned work a planned item spawned (Jira link, then a description reference, then the leg that filed it); ratio = minutes per S-equivalent over the median of the finished items (1.00 = typical), blank while any of its legs is undated. Hover a row for its bundle."));
 h.appendChild(add(el("div","tw"),tb));h.appendChild(el("p","fact",D.SRC))}
function renderAcc(){var h=$("accb"),ac=M.accuracy(),mx=1;h.textContent="";
 h.appendChild(el("p","fact","Re-read from the Jira mirror and the wrapped-leg docs on every render. Jira "+D.mir+" · newest wrapped-leg doc "+(D.ATS||"none")+"."));
 renderBench(h);
 if(!ac.length){h.appendChild(el("p","fact","No done ticket has both a size estimate and a wrapped leg yet."));return}
 ac.forEach(function(x){x.rows.forEach(function(r){mx=Math.max(mx,r.min)})});
 ac.forEach(function(x){var r=el("div","ar"),tr=el("div","atr"),m=el("b");tr.setAttribute("role","img");
  tr.setAttribute("aria-label",x.size+": "+pl(x.n,"ticket","tickets")+", median "+fmtMin(x.med));
  x.rows.forEach(function(q){var d=el("i");d.style.left=(100*q.min/mx)+"%";d.title=keyOf(q.p)+": "+fmtMin(q.min)+", "+pl(q.legs,"leg","legs");tr.appendChild(d)});
  m.style.left=(100*x.med/mx)+"%";tr.appendChild(m);
  add(r,add(el("span","as"),el("span","sz",x.size),el("span","fact","×"+x.n)),tr,el("span","am",fmtMin(x.med)+" · "+pl(x.legs,"leg","legs")));h.appendChild(r)});
 h.appendChild(add(el("div","aax"),el("span",null,"0"),el("span",null,fmtMin(mx))))}
function renderSectors(){var i=D.CUR!=null?D.CUR:0,h=$("themb"),a=M.inV(i,REM),g={};h.textContent="";$("themh").textContent="Sectors in "+D.V[i];
 a.forEach(function(p){var k=p[5];g[k]=g[k]||{k:k,d:0,n:0};g[k].n++;if(p[2]==2)g[k].d++});
 var gs=Object.keys(g).map(function(k){return g[k]}).sort(function(x,y){return y.n-x.n||String(T[x.k]).localeCompare(String(T[y.k]))}).slice(0,8),mx=gs.length?gs[0].n:1;
 gs.forEach(function(x){var bar=el("span","thb"),d=el("i","d"),l=el("i","t");d.style.width=(100*x.d/mx)+"%";l.style.width=(100*(x.n-x.d)/mx)+"%";add(bar,d,l);
  bar.setAttribute("role","img");bar.setAttribute("aria-label",x.d+" of "+x.n+" done");
  h.appendChild(add(el("div","thr"),nb(T[x.k],"all",{t:x.k},T[x.k]+" across v1.0.x"),bar,el("span","fact",x.d+"/"+x.n)))});
 if(!gs.length)h.appendChild(el("p","fact","No tickets here."))}
// The version-first view: Jira's own versions and status names, built from D.JV / D.JT; the plan's views sit folded below.
var JV=D.JV,JT=D.JT,JB=[["todo","To Do"],["prog","In Progress"],["rev","In Review"],["ci","IN CI"],["done","Done"]],
 RMO=matchMedia("(prefers-reduced-motion: reduce)").matches,JCUR=D.JC,JNXT=D.JN,JSEL=D.JS!=null?D.JS:D.JC>=0?D.JC:JV.length-1;
var HIDE=true;try{var hs=localStorage.getItem("hide3990");if(hs!==null)HIDE=hs==="1"}catch(e){}
if(D.PG){HIDE=false;$("hide").style.display="none"}
// jb(t): a To Do ticket a live leg works reads In Progress; Jira's own later status always wins. Tickets closed without shipping are not in JT (D.JW counts them).
function jb(t){return t.live?"prog":t.b}
function jin(i){return JT.filter(function(t){return t.v===i})}
// jtally(a,raw): raw counts the Jira status (the hero, which must equal JQL); else the board's live-leg display.
function jtally(a,raw){var r={n:a.length};JB.forEach(function(s){r[s[0]]=[]});a.forEach(function(t){r[raw?t.b:jb(t)].push(t)});r.open=a.length-r.done.length;return r}
function jdot(b,x){return el("span","jst jc-"+b,x)}
function jnum(label,title,list,cls){var b=el("button",cls||"jn",String(label));b.type="button";
 b.addEventListener("click",function(e){e.stopPropagation();openDrill("jt",{list:list},title,b)});return b}
function jlist(db,list){db.appendChild(el("p","note",pl(list.length,"ticket","tickets")+"."));
 list.slice().sort(function(a,c){return a.k-c.k}).forEach(function(t,j){var r=el("div","jrow enter"),m=el("div","jm");r.style.animationDelay=Math.min(j,12)*18+"ms";
  add(r,el("div","jkey","HIMMEL-"+t.k),el("div","jtl",t.t));add(m,jdot(jb(t),t.live?"a leg is on it":t.s));
  if(t.leg)add(m," · leg "+t.leg[0]+" "+t.leg[1]+(t.live?" (Jira still To Do)":""));
  if(t.pv&&t.pv!==JV[t.v].n)add(m," · ","the plan places it in "+t.pv);
  r.appendChild(m);if(t.ui)r.appendChild(el("div","jui",t.ui));db.appendChild(r)})}
// jbar(t): segments start at width 0 and grow on the next frame, so a fill animates on load and on every re-render.
function jbar(t,big){var w=el("div",big?"jbar big":"jbar");JB.slice().reverse().forEach(function(s){var n=t[s[0]].length;if(!n)return;var i=el("i","js-"+s[0]);i.dataset.w=(100*n/(t.n||1))+"%";i.title=s[1]+": "+n;w.appendChild(i)});
 w.setAttribute("role","img");w.setAttribute("aria-label",JB.map(function(s){return t[s[0]].length+" "+s[1]}).join(", "));return w}
function jgrow(){var a=document.querySelectorAll(".jbar i[data-w]");requestAnimationFrame(function(){requestAnimationFrame(function(){a.forEach(function(i){i.style.width=i.dataset.w;i.removeAttribute("data-w")})})})}
function jhero(){var h=$("hh"),s=$("sent"),hn=$("hnote");s.textContent="";hn.textContent=[D.RU?"release state unknown":"",D.PAR||""].filter(Boolean).join(" · ");
 if(D.RU)hn.title="No versions file was found, so no version counts as released. Write `jira versions` to <mirror-dir>.versions.tsv.";
 var lg=$("legend"),nx=$("next"),al=$("alerts"),nb0=jbar(jtally([]),true);nb0.id="hbar";$("hbar").replaceWith(nb0);lg.textContent="";nx.textContent="";al.textContent="";
 if(JCUR<0){h.textContent="Nothing open";s.textContent="Every unreleased version is done.";jalerts(-1);return}
 var v=JV[JCUR],t=jtally(jin(JCUR),1);h.textContent=v.n;
 var dn=D.JD||0;
 add(s,dn?dn+" of "+(t.n+dn)+" done, listed on the Done page":add(el("span"),jnum(t.done.length,v.n+": Done",t.done)," of ",jnum(t.n,v.n+": every ticket",jin(JCUR))," done")," · ",
  jnum(t.rev.length,v.n+": In Review",t.rev)," in review · ",jnum(t.ci.length,v.n+": IN CI",t.ci)," in CI · ",
  jnum(t.prog.length,v.n+": In Progress",t.prog)," in progress · ",jnum(t.todo.length,v.n+": To Do",t.todo)," to do.");
 var nb=jbar(dn?Object.assign({},t,{done:new Array(dn),n:t.n+dn}):t,true);nb.id="hbar";$("hbar").replaceWith(nb);
 JB.slice().reverse().forEach(function(x){lg.appendChild(jdot(x[0],x[1]))});
 if(JNXT>=0){var u=jtally(jin(JNXT),1);add(nx,"Up next: "+JV[JNXT].n+" — ",jnum(u.open,JV[JNXT].n+": open",jin(JNXT).filter(function(x){return jb(x)!="done"}))," open, "+u.done.length+" done.")}
 jalerts(JCUR)}
// jalerts(cur): released versions that still hold open tickets. Runs even when nothing unreleased is open (cur<0).
function jalerts(cur){var al=$("alerts"),to=cur<0?"an unreleased version":JV[cur].n;
 D.JA.forEach(function(x){var rv=JV[x[0]],o=x[1].map(function(k){return JT.filter(function(t2){return t2.k===k})[0]});
  var a=el("div","jalert");add(a,el("div","jw","● "+rv.n+" was released on "+rv.date+" but still holds "+o.length+" open ticket"+(o.length==1?"":"s")),
   "Move "+(o.length==1?"it":"them")+" to "+to+" or close "+(o.length==1?"it":"them")+".");var ul=el("ul");
  o.forEach(function(t2){var li=el("li");add(li,jnum("HIMMEL-"+t2.k,"HIMMEL-"+t2.k,[t2])," — "+t2.t+" ",jdot(jb(t2),t2.live?"a leg is on it":t2.s));ul.appendChild(li)});a.appendChild(ul);al.appendChild(a)})}
function jboard(){var b=$("board"),f=$("donefold");b.textContent="";f.textContent="";
 if(JSEL<0){$("bh").textContent="No versions";$("bsub").textContent="";return}
 var v=JV[JSEL],a=jin(JSEL),t=jtally(a);
 $("bh").textContent=v.n+(JSEL===JCUR?" — the board":" — board");
 var wn=(D.JW.filter(function(x){return x[0]===JSEL})[0]||[0,0])[1];
 $("bsub").textContent=(v.rel?"Released "+v.date+". ":JSEL===JCUR?"The version being worked on. ":"Not released. ")+t.open+" open of "+t.n+"."+(wn?" "+wn+" closed without shipping.":"");
 var cols=JB.filter(function(s){return !HIDE||s[0]!="done"});b.style.setProperty("--cols",cols.length);
 cols.forEach(function(s,ci){var c=el("div","jcol enter"),h=el("h3");c.style.animationDelay=ci*40+"ms";
  add(h,jdot(s[0],s[1]),jnum(t[s[0]].length,v.n+": "+s[1],t[s[0]]));c.appendChild(h);
  t[s[0]].slice(0,6).forEach(function(x,j){var k=el("button","jcard enter");k.type="button";k.style.animationDelay=(ci*40+j*25)+"ms";
   add(k,el("div","jkey","HIMMEL-"+x.k),el("div","jtl",x.t));
   if(x.ui)k.appendChild(el("div","jui",x.ui.length>120?x.ui.slice(0,118)+"…":x.ui));
   if(x.leg)k.appendChild(el("span","jchip",x.leg[0]+" · "+x.leg[1]+(x.leg[2]?" · PR "+x.leg[2]:"")));
   k.addEventListener("click",function(){openDrill("jt",{list:[x]},"HIMMEL-"+x.k,k)});c.appendChild(k)});
  if(t[s[0]].length>6)c.appendChild(jnum("+"+(t[s[0]].length-6)+" more",v.n+": "+s[1],t[s[0]]));
  if(!t[s[0]].length)c.appendChild(el("div","jnone","None."));b.appendChild(c)});
 if(HIDE&&t.done.length)add(f,jnum(t.done.length,v.n+": Done",t.done)," done ticket"+(t.done.length==1?" is":"s are")+" hidden. Turn off “Hide done work” to show them.")}
function jversions(flashI){var b=$("vt");b.textContent="";var hid=0;
 JV.forEach(function(v,i){var a=jin(i),t=jtally(a),wn=(D.JW.filter(function(x){return x[0]===i})[0]||[0,0])[1];if(!t.n&&!wn)return;if(HIDE&&!t.open&&t.n){hid++;return}
  var r=el("tr","enter");r.dataset.v=i;r.tabIndex=0;if(i===JSEL)r.className="jsel"+(i===flashI?" jflash":"");
  var st=v.rel?(t.open?["fail","Released · "+t.open+" open"]:["done","Released"]):i===JCUR?["prog","Working on"]:i===JNXT?["rev","Up next"]:["todo","Planned"];
  var td=el("td");td.appendChild(el("span","vn",v.n));r.appendChild(td);td=el("td");td.appendChild(jdot(st[0],st[1]+(wn?" · "+wn+" closed without shipping":"")));r.appendChild(td);
  td=el("td","barc");td.appendChild(jbar(t));r.appendChild(td);
  JB.forEach(function(s){var td=el("td"),n=t[s[0]].length;td.appendChild(n?jnum(n,v.n+": "+s[1],t[s[0]]):el("span","z","0"));r.appendChild(td)});
  td=el("td");td.appendChild(jnum(t.n,v.n+": every ticket",a));r.appendChild(td);
  function pick(){JSEL=i;jrender(i);$("bh").scrollIntoView({behavior:RMO?"auto":"smooth"})}
  r.addEventListener("click",pick);r.addEventListener("keydown",function(e){if(e.target!==r)return;if(e.key=="Enter"||e.key==" "){e.preventDefault();pick()}});b.appendChild(r)});
 $("vfold").textContent=hid?hid+" version"+(hid==1?"":"s")+" with only done work "+(hid==1?"is":"are")+" hidden.":""}
function jrender(flashI){jhero();jboard();jversions(flashI);jgrow();$("hide").setAttribute("aria-checked",HIDE?"true":"false")}
// Hide-done: fade the outgoing columns and rows, then re-render; the board keeps its height, so nothing jumps.
$("hide").addEventListener("click",function(){HIDE=!HIDE;try{localStorage.setItem("hide3990",HIDE?"1":"0")}catch(e){}
 if(RMO){jrender();return}document.querySelectorAll(".jcol,#vt tr").forEach(function(e){e.classList.remove("enter");e.classList.add("leave")});setTimeout(jrender,180)});
function render(){jrender();renderAcc();renderSectors()}
(function(){var p=$("pages"),L=D.LK||{};if(!D.PG){p.hidden=true;return}
 if(D.PG!="focus")document.querySelector(".hero").style.display="none";
 if(D.PG!="done")$("accb").parentNode.style.display="none";
 if(D.PG!="focus")$("themb").parentNode.style.display="none";
 [["focus","Focus"],["done","Done"],["future","Future"]].forEach(function(x,i){if(i)p.appendChild(txt(" · "));
  if(x[0]==D.PG)p.appendChild(el("b",null,x[1]+" (this page)"));
  else if(L[x[0]]){var a=el("a",null,x[1]);a.href=L[x[0]];p.appendChild(a)}else p.appendChild(el("span",null,x[1]))})})();
// drawer: numbers open it; focus moves in, Tab is trapped, Esc closes and focus returns to the number that opened it.
function openDrill(kind,scope,title,from){
 var db=$("db");db.textContent="";$("dh").textContent=title;if($("drawer").hidden)opener=from;
 if(kind=="load")loadView(scope.v,db);
 else if(kind=="version"){db.appendChild(headline(scope.v,M.tally(M.inV(scope.v,REM))));versionBody(scope.v,db)}
 else if(kind=="jt")jlist(db,scope.list);
 else if(kind=="one")D.P.filter(function(p){return p[0]==scope.k}).forEach(function(p){var t=ticket(p);t.open=true;db.appendChild(t)});
 else{var a=M.drill(kind,scope,REM);
  db.appendChild(el("p","note",pl(a.length,"ticket","tickets")+(REM?", done ones hidden":"")+"."));a.forEach(function(p){db.appendChild(ticket(p))})}
 $("scrim").hidden=false;$("drawer").hidden=false;$("main").inert=true;document.querySelector(".mast").inert=true;$("dh").focus()}
function closeDrill(){if($("drawer").hidden)return;$("drawer").hidden=true;$("scrim").hidden=true;$("main").inert=false;document.querySelector(".mast").inert=false;
 if(opener&&document.contains(opener))opener.focus();opener=null}
function loadView(i,db){var ld=M.load(i,REM),tb=el("table","ld"),hr=el("tr");
 ["Kind","Used","Cap","Headroom"].forEach(function(x){hr.appendChild(el("th",null,x))});tb.appendChild(hr);
 ld.kinds.forEach(function(k){var r=el("tr",k.over?"x":null);[k.kind,f2(k.used),k.cap==null?"no cap":f2(k.cap),k.head==null?"–":f2(k.head)].forEach(function(x){r.appendChild(el("td",null,x))});tb.appendChild(r)});
 var tr=el("tr");[ "total",f2(ld.used),ld.cap==null?"no cap":f2(ld.cap),ld.cap==null?"–":f2(ld.cap-ld.used)].forEach(function(x){tr.appendChild(el("td",null,x))});tb.appendChild(tr);
 add(db,el("p","note",(ld.deferred?"Deferred bucket: no caps apply. ":"Caps are "+V[i]+"'s own, overrides included. ")+pl(ld.planned,"planned ticket","planned tickets")+(ld.tcap!=null?" of a "+ld.tcap+"-ticket cap":"")+(REM?"; done tickets left out.":".")),tb);
 if(ld.p90!=null)add(db,add(el("p","note"),el("b",null,"Likely load "),f2(ld.used)+(ld.cap!=null?" of "+f2(ld.cap):"")+": the average outcome. ",
  el("b",null,"Cautious load "),f2(ld.p90)+(ld.p90cap!=null?" of "+f2(ld.p90cap):"")+": 9 times in 10 the work lands at or under this"+(REM?" (as planned, done tickets included).":".")));
 ld.kinds.forEach(function(k){if(!k.tickets.length)return;var d=el("details","fold");d.open=k.over;
  d.appendChild(el("summary",null,k.kind+": "+pl(k.tickets.length,"ticket","tickets")+", "+f2(k.used)+(k.cap!=null?" of "+f2(k.cap):"")+" ›"));
  var ol=el("ol","ct");k.tickets.forEach(function(p){var li=el("li"),t=el("span","t");add(t,el("code",null,keyOf(p))," ",p[9]?p[9].replace(/^internal:\s*/i,""):p[1]);t.title=p[9]||p[1];
   add(li,t,el("span","v",M.ld(p).toFixed(3)+" · "+pct(M.ld(p),ld.used)+" %"));ol.appendChild(li)});d.appendChild(ol);db.appendChild(d)})}
$("dx").addEventListener("click",closeDrill);$("scrim").addEventListener("click",closeDrill);
document.addEventListener("keydown",function(e){if($("drawer").hidden)return;
 if(e.key=="Escape"){e.preventDefault();closeDrill();return}
 if(e.key!="Tab")return;var f=[].slice.call($("drawer").querySelectorAll("button,summary,a[href],[tabindex]")).filter(function(x){return x.offsetParent!==null||x===$("dh")});
 if(!f.length)return;var i=f.indexOf(document.activeElement);
 if(e.shiftKey&&i<=0){e.preventDefault();f[f.length-1].focus()}else if(!e.shiftKey&&i==f.length-1){e.preventDefault();f[0].focus()}});
var TK="hrt-theme";function applyTheme(m){if(m)document.documentElement.setAttribute("data-theme",m);else document.documentElement.removeAttribute("data-theme")}
try{applyTheme(localStorage.getItem(TK))}catch(e){}
$("theme").addEventListener("click",function(){var dk=getComputedStyle(document.documentElement).colorScheme=="dark",m=dk?"light":"dark";applyTheme(m);try{localStorage.setItem(TK,m)}catch(e){}});
$("stamp").textContent="Rendered "+D.gen+" · Jira "+D.mir+" · plan @"+D.sha;
$("prov").textContent="Versions and statuses are read from Jira (fixVersion and status name); a leg with a held queue lock shows its To Do ticket as In Progress. Impact text, sizes, readiness and budgets come from the roadmap plan.";
(function(){var t=$("terms"),mk=function(c){return el("span","mk "+c)};
 [["Status",[mk("done"),"done · ",mk("live"),"a leg is on it · ",mk("started"),"started in Jira, no leg · ",mk("todo"),"to do"]],
  ["Leg chip",["N123 · LIVE: the leg's label and its last marker (or its PR number while it is live)."]],
  ["Size",["The plan's T-shirt estimate, low–high. In S-equivalents: "+D.EQ+"."]],
  ["Impact",[dots(4)," how much it hurts today, 1 cosmetic to 5 blocks a release. A secondary tag: the sentence is the impact."]],
  ["Ready to build",["0 no plan yet · 1 problem stated · 2 fix named, not yet checked · 3 plan audited · 4 spec ready. Below 3 a version schedules only a planning slice."]],
  ["Budget",[capBar({used:.45,cap:.6,kinds:[]})," used of the version's cap; the tick is the cap, orange is over it."]],
  ["No cap",[capBar({deferred:true})," ","no cap — deferred bucket"]],
  ["Hide done work",["Hides Done and In Public from the version board and its lists. The counts in the sentence and the table still include them. Closed, wont do and wont fix tickets, and Done tickets resolved as anything but Done or Fixed, are in no count: each version notes how many closed without shipping."]]
 ].forEach(function(x){t.appendChild(el("dt",null,x[0]));var d=el("dd");x[1].forEach(function(c){add(d,c)});t.appendChild(d)})})();
D.CAP.text.forEach(function(x){$("rules").appendChild(el("p",null,x))});
render();
})();
</script>
'''

if __name__ == '__main__':
    main()
