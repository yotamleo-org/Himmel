#!/usr/bin/env bash
# judge-desk.sh - the judge desk's loop commands, the one writer of
# <bucket>/judge-desk/desk-runs.jsonl and <bucket>/judge-desk/runs/<run>/, and the automatic stop.
#
#   judge-desk.sh wait   --bucket <dir> --since <iso> --chief <name> [--max-wait <s>] [--tick <s>]
#   judge-desk.sh next   --bucket <dir>
#   judge-desk.sh claim  <spec.json> --bucket <dir>
#   judge-desk.sh record <run> --agent <id> --bucket <dir>
#   judge-desk.sh draft-go <run> --bucket <dir>
# Shared options: --projects <dir> (default ${CLAUDE_CONFIG_DIR:-~/.claude}/projects), --desk-worktree <dir>
# (default the checkout holding the cwd), --desk-session <id> (default $CLAUDE_CODE_SESSION_ID),
# --since <iso> (the desk start; default the first claim's time), --chief <name> (wait only: the one
# recipient a desk SendMessage may name; a record's stop checks skip the recipient test without it).
#
# wait    ticks every --tick seconds (60) for at most --max-wait (3000): lapses leases, runs the stop
#         checks, runs judge-queue.sh scan, and prints why it returned: REQUEST (a request has no desk
#         run), ENDED (an open claim has no live judge), STOP, TIMEOUT, or BLOCKED <path> (exit 3).
# next    prints REQUEST <pr> <head> <first|trust|finding> <snapshot>, STOP, or HOLD <why>. A later head
#         of a PR the desk already judged goes through delta-class.sh on that run's reply.md: none after
#         a GO appends a noop row and prints NOOP; none after a NO-GO is a finding delta.
# claim   runs gen-judge-brief.py --dispatch-json --no-persist on the spec, checks the printed model is
#         the class's, copies spec and dispatch into runs/<run>/, appends the claim row (20-minute
#         lease) and prints the Agent input.
# record  reads the judge's subagent transcript (by the claim's desk session and the agent id), writes
#         runs/<run>/reply.md in the verdict-record shape and appends the end row; prints
#         RECORDED <run> <outcome>.
# draft-go  appends the draft row from the run's verdict and close-facts.sh doc_ready_head; writes no
#         GO file and runs no GO script.
#
# The automatic stop (every wait tick and every record) writes <bucket>/judge-desk/STOP and prints
# BLOCKED <path> and nothing else: a verdicts/dsk* dir, a verdicts/ record written since the desk start
# whose writer-session is unknown, invalid or a desk session, a GO file with no chief-go record, a desk
# transcript whose session id is not in judge-desk/sessions, a Write or judge-dir.sh call under
# /tmp/claude-<uid>/j*, a SendMessage or t3-send.sh call the chief path does not own, and a judge
# write-verdict.sh or judge-call.sh call that did not end in the marker's refusal. The verdicts/ part
# reads directory names and the writer-session header line only.
#
# Every append holds flock on <bucket>/judge-desk/.lock; rows are appended, never edited.
# Fixture-only seams, read under HIMMEL_TEST_FIXTURE=1: JUDGE_DESK_NOW (epoch seconds),
# JUDGE_DESK_PREFLIGHT, JUDGE_DESK_GEN, JUDGE_DESK_LIVE (scripts standing in for usage-preflight.sh,
# gen-judge-brief.py and live-subagents.sh).
# Exit: 0 ok; 1 refused; 2 usage; 3 BLOCKED.
JUDGE_DESK_HERE="$(cd "$(dirname "$0")" && pwd)" exec python3 -I - "$@" <<'PY'
import fcntl, glob, hashlib, json, os, re, shlex, shutil, subprocess, sys, time
from datetime import datetime, timedelta, timezone

HERE = os.environ['JUDGE_DESK_HERE']
HEX40 = re.compile(r'[0-9a-f]{40}')
LEASE_SECONDS = 1200
GRACE_SECONDS = 120
FILL_LIMIT = 120000
MAX_OPEN_CLAIMS = 3
MARKER_TEXT = 'HIMMEL_CONSOLE_JUDGE_NOVERDICT is set (a judge desk writes no verdict)'
JUDGE_DIR_PATH = re.compile(r'/tmp/claude-\d+/j[0-9a-z]')
WRITE_SCRIPTS = ('write-verdict.sh', 'judge-call.sh')
DESK_RUNS = 'judge-desk/desk-runs.jsonl'
RUNS_DIR = 'judge-desk/runs'
REQUESTS = 'judge-desk/judge-requests.jsonl'
REGISTRY = 'judge-desk/sessions'
STOP = 'judge-desk/STOP'
LOCK = 'judge-desk/.lock'
OPTIONS = ('--bucket', '--projects', '--desk-worktree', '--desk-session', '--chief', '--since', '--max-wait', '--tick', '--agent')


def die(msg, rc=1):
    print('judge-desk: ' + msg, file=sys.stderr)
    sys.exit(rc)


def seam(name):
    v = os.environ.get(name, '')
    return v if v and os.environ.get('HIMMEL_TEST_FIXTURE') == '1' else ''


def now():
    v = seam('JUDGE_DESK_NOW')
    return int(v) if v.isdigit() else time.time()


def iso_local(ts):
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec='seconds')


def parse_time(text):
    t = datetime.fromisoformat(text.replace('Z', '+00:00'))
    return (t if t.tzinfo else t.astimezone()).timestamp()


def sha256_file(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_cmd(argv, timeout=180):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout)


class Opts:
    pass


def parse(argv):
    o, rest, i = Opts(), [], 0
    vals = {}
    while i < len(argv):
        if argv[i] in OPTIONS:
            if i + 1 >= len(argv) or not argv[i + 1]:
                die('%s needs a value' % argv[i], 2)
            vals[argv[i]] = argv[i + 1]
            i += 2
        elif argv[i].startswith('--'):
            die('unknown option %s' % argv[i], 2)
        else:
            rest.append(argv[i])
            i += 1
    if '--bucket' not in vals:
        die('missing --bucket', 2)
    o.bucket = os.path.abspath(vals['--bucket'])
    o.projects = vals.get('--projects') or os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'), 'projects')
    o.worktree = vals.get('--desk-worktree')
    o.session = vals.get('--desk-session') or os.environ.get('CLAUDE_CODE_SESSION_ID', '')
    o.chief = vals.get('--chief')
    o.since = vals.get('--since')
    o.agent = vals.get('--agent')
    for k, attr, default in (('--max-wait', 'max_wait', 3000), ('--tick', 'tick', 60)):
        v = vals.get(k)
        if v is not None and not v.isdigit():
            die('%s needs a whole number of seconds' % k, 2)
        setattr(o, attr, int(v) if v is not None else default)
    o.rest = rest
    return o


class Desk:
    def __init__(self, o):
        self.o = o
        self.dir = os.path.join(o.bucket, 'judge-desk')
        os.makedirs(os.path.join(self.dir, 'requests'), exist_ok=True)
        self.runs_file = os.path.join(o.bucket, DESK_RUNS)
        self.root = os.path.abspath(os.path.join(o.bucket, '..', '..'))
        self.user = os.path.basename(os.path.dirname(o.bucket))
        self.stop_file = os.path.join(o.bucket, STOP)
        self._lockf = None

    class _Lock:
        def __init__(self, d):
            self.d = d

        def __enter__(self):
            self.f = open(os.path.join(self.d.o.bucket, LOCK), 'a')
            fcntl.flock(self.f, fcntl.LOCK_EX)

        def __exit__(self, *a):
            self.f.close()

    def locked(self):
        return Desk._Lock(self)

    def rows(self, path=None):
        out = []
        try:
            with open(path or self.runs_file, encoding='utf-8') as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict):
                        out.append(r)
        except FileNotFoundError:
            pass
        return out

    def append(self, row):
        with open(self.runs_file, 'a', encoding='utf-8') as f:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')

    def requests(self):
        return [r for r in self.rows(os.path.join(self.o.bucket, REQUESTS)) if r.get('kind') == 'request']

    def registry(self):
        try:
            with open(os.path.join(self.o.bucket, REGISTRY), encoding='utf-8') as f:
                return set(l.strip() for l in f if l.strip())
        except OSError:
            return set()

    def claims(self, rows=None):
        return [r for r in (rows if rows is not None else self.rows()) if r.get('kind') == 'claim']

    def state(self, run, rows):
        ends = [r for r in rows if r.get('kind') == 'end' and r.get('run') == run]
        if not ends:
            return 'open'
        return 'done' if any(e.get('outcome') != 'lost' for e in ends) else 'lost'

    def has_run(self, pr, head, rows):
        for r in rows:
            if r.get('kind') == 'noop' and r.get('pr') == pr and r.get('head') == head:
                return True
            if r.get('kind') == 'claim' and r.get('pr') == pr and r.get('head') == head and self.state(r['run'], rows) != 'lost':
                return True
        return False

    def open_claims(self, rows):
        return [c for c in self.claims(rows) if self.state(c['run'], rows) == 'open']

    def expire_leases(self):
        with self.locked():
            rows = self.rows()
            t = now()
            for c in self.open_claims(rows):
                try:
                    lapsed = parse_time(c['lease_until']) < t
                except (KeyError, ValueError):
                    lapsed = False
                if lapsed:
                    self.append({'schema': 1, 'kind': 'end', 'run': c['run'], 'outcome': 'lost', 'agent': '', 'reply': None,
                                 'reply_sha256': None, 'verdict_at': None, 'write_attempted': False, 'write_refused': None,
                                 'prompt_matches': True, 'cost_eq': 0, 'late': False})

    def since_ts(self):
        if self.o.since:
            try:
                return parse_time(self.o.since)
            except ValueError:
                die('--since %r is not an ISO time' % self.o.since, 2)
        times = []
        for c in self.claims():
            try:
                times.append(parse_time(c['dispatched_at']))
            except (KeyError, ValueError):
                pass
        return min(times) if times else now()

    def desk_project_dir(self):
        wt = self.o.worktree
        if not wt:
            r = run_cmd(['git', 'rev-parse', '--show-toplevel'])
            wt = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else os.getcwd()
        return os.path.join(self.o.projects, re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(wt)))


def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')
    return ''


class Transcript:
    def __init__(self, path):
        self.path = path
        self.calls = []
        self.first_prompt = None
        self.reply = None
        self.reply_ts = None
        self.last_usage = 0
        by_id = {}
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict):
                    continue
                msg = r.get('message') if isinstance(r.get('message'), dict) else {}
                content = msg.get('content')
                if r.get('type') == 'user':
                    if self.first_prompt is None and not (isinstance(content, list) and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in content)):
                        self.first_prompt = content_text(content)
                    for b in content if isinstance(content, list) else []:
                        if isinstance(b, dict) and b.get('type') == 'tool_result' and b.get('tool_use_id') in by_id:
                            c = by_id[b['tool_use_id']]
                            c['result'] = content_text(b.get('content'))
                            c['error'] = bool(b.get('is_error'))
                elif r.get('type') == 'assistant':
                    usage = msg.get('usage') if isinstance(msg.get('usage'), dict) else {}
                    self.last_usage = sum(int(usage.get(k) or 0) for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
                    text = content_text(content) if isinstance(content, list) else ''
                    if text.strip():
                        self.reply, self.reply_ts = text, r.get('timestamp')
                    for b in content if isinstance(content, list) else []:
                        if isinstance(b, dict) and b.get('type') == 'tool_use':
                            c = {'name': b.get('name'), 'input': b.get('input') if isinstance(b.get('input'), dict) else {},
                                 'result': '', 'error': False}
                            by_id[b.get('id')] = c
                            self.calls.append(c)


SKIPPED = {'env', 'bash', 'sh', 'timeout', 'time', 'nice', 'exec', 'command', 'source', '.', 'sudo',
           'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!', '{'}


def command_segments(cmd):
    text, texts, cur, quote, i = cmd or '', [], [], None, 0
    while i < len(text):
        ch = text[i]
        if quote:
            cur.append(ch)
            if ch == '\\' and quote == '"' and i + 1 < len(text):
                i += 1
                cur.append(text[i])
            elif ch == quote:
                quote = None
        elif ch == '\\' and i + 1 < len(text):
            i += 1
            cur.append(ch + text[i])
        elif ch in '\'"':
            quote = ch
            cur.append(ch)
        elif ch in ';&|()\n':
            texts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    texts.append(''.join(cur))
    segs = []
    for t in texts:
        try:
            segs.append(shlex.split(t))
        except ValueError:
            segs.append(t.split())
    return segs


def command_heads(cmd):
    heads = []
    for toks in command_segments(cmd):
        if toks and os.path.basename(toks[0]) in ('bash', 'sh') and '-c' in toks and toks.index('-c') + 1 < len(toks):
            heads += command_heads(toks[toks.index('-c') + 1])
            continue
        i = 0
        while i < len(toks):
            t = toks[i]
            if re.match(r'[A-Za-z_][A-Za-z0-9_]*=', t) or t.startswith('-') or t.isdigit() or os.path.basename(t) in SKIPPED:
                i += 1
                continue
            break
        if i < len(toks):
            heads.append(os.path.basename(toks[i]))
    return heads


def judge_facts(tr):
    """What a judge did: write attempts, stop reasons, other writes."""
    f = {'attempted': False, 'refused': False, 'stops': [], 'other_writes': []}
    for c in tr.calls:
        name, inp = c['name'], c['input']
        if name == 'Bash':
            heads = command_heads(inp.get('command', ''))
            writes = sum(1 for h in heads if h in WRITE_SCRIPTS)
            if writes:
                f['attempted'] = True
                if c['error'] and c['result'].count(MARKER_TEXT) >= writes:
                    f['refused'] = True
                else:
                    f['stops'].append('a judge write-verdict.sh or judge-call.sh call did not end in the marker refusal')
            if 'judge-dir.sh' in heads:
                f['stops'].append('a judge judge-dir.sh call')
            if 't3-send.sh' in heads:
                f['stops'].append('a judge t3-send.sh call')
        elif name == 'Write':
            p = str(inp.get('file_path', ''))
            if JUDGE_DIR_PATH.search(p):
                f['stops'].append('a judge Write under /tmp/claude-<uid>/j*')
            else:
                f['other_writes'].append(p)
        elif name == 'SendMessage':
            f['stops'].append('a judge SendMessage call')
    return f


def desk_stop_reason(tr, chief):
    for c in tr.calls:
        name, inp = c['name'], c['input']
        if name == 'Write' and JUDGE_DIR_PATH.search(str(inp.get('file_path', ''))):
            return 'the desk wrote under /tmp/claude-<uid>/j*'
        if name == 'Bash':
            heads = command_heads(inp.get('command', ''))
            if 'judge-dir.sh' in heads:
                return 'the desk called judge-dir.sh'
            if 't3-send.sh' in heads:
                return 'the desk called t3-send.sh'
        if name == 'SendMessage' and chief is not None and inp.get('to') != chief:
            return 'the desk sent a message to a recipient other than its chief'
    return None


def header_session(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        for n, line in enumerate(f):
            if n > 20:
                break
            m = re.match(r'^writer-session: (.*?)\s*$', line)
            if m:
                return m.group(1)
    return None


def stop_checks(d, tr_cache=None):
    """The first automatic-stop trigger as (path, why), or None. Reads names and header lines only."""
    since = d.since_ts()
    vdir = os.path.join(d.o.bucket, 'verdicts')
    sessions = d.registry()

    def listing(path):
        try:
            return sorted(os.listdir(path)), None
        except FileNotFoundError:
            return [], None
        except OSError:
            return [], (path, 'cannot read this directory, so a stop check cannot run')
    names, bad = listing(vdir)
    if bad:
        return bad
    for n in names:
        if n.startswith('dsk') and os.path.isdir(os.path.join(vdir, n)):
            return os.path.join(vdir, n), 'a verdicts/dsk* directory exists'
    for n in names:
        qdir = os.path.join(vdir, n)
        if not os.path.isdir(qdir):
            continue
        fns, bad = listing(qdir)
        if bad:
            return bad
        for fn in fns:
            p = os.path.join(qdir, fn)
            try:
                if not fn.endswith('.md') or not os.path.isfile(p) or os.path.getmtime(p) < since:
                    continue
                s = header_session(p)
            except OSError:
                return p, 'a verdict record cannot be read, so a stop check cannot run'
            if s is not None and (s in ('unknown', 'invalid') or s in sessions):
                return p, 'a verdict record written since the desk start has writer-session %s' % s
    godir = os.path.join(d.root, '.locks', 'go')
    t = now()
    gofiles, bad = listing(godir)
    if bad:
        return bad
    for fn in gofiles:
        m = re.fullmatch(r'(\d+)\.([0-9a-f]{40})', fn)
        p = os.path.join(godir, fn)
        if not m or not os.path.isfile(p):
            continue
        mtime = os.path.getmtime(p)
        if mtime <= since or t - mtime <= GRACE_SECONDS:
            continue
        rec = os.path.join(d.root, d.user, '*', 'verdicts', 'go-pr-%s' % m.group(1), 'chief-go-%s.md' % m.group(2))
        if not any(os.path.isfile(r) for r in glob.glob(rec)):
            return p, 'a GO file has no chief-go record'
    pdir = d.desk_project_dir()
    pnames, bad = listing(pdir)
    if bad:
        return bad
    transcripts = [os.path.join(pdir, n) for n in pnames if n.endswith('.jsonl')]
    for p in transcripts:
        if os.path.basename(p)[:-len('.jsonl')] not in sessions:
            return p, 'a desk transcript id is not in judge-desk/sessions'
    for p in transcripts:
        try:
            why = desk_stop_reason(Transcript(p), d.o.chief)
        except OSError:
            return p, 'a desk transcript cannot be read, so a stop check cannot run'
        if why:
            return p, why
    return None


def trip(d, path, why):
    with d.locked():
        if not os.path.exists(d.stop_file):
            with open(d.stop_file, 'w', encoding='utf-8') as f:
                f.write('BLOCKED %s\n%s\n' % (path, why))
    print('BLOCKED %s' % path)
    return 3


def preflight_token(d):
    script = seam('JUDGE_DESK_PREFLIGHT') or os.path.join(HERE, '..', '..', 'lib', 'usage-preflight.sh')
    try:
        r = run_cmd(['bash', script], timeout=150)
    except (OSError, subprocess.TimeoutExpired):
        return ''
    lines = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    return lines[-1] if lines else ''


def desk_fill(d):
    p = os.path.join(d.desk_project_dir(), d.o.session + '.jsonl')
    try:
        return Transcript(p).last_usage if d.o.session else 0
    except OSError:
        return 0


def cmd_next(o):
    d = Desk(o)
    if o.rest:
        die('next takes no positional argument', 2)
    d.expire_leases()
    if os.path.exists(d.stop_file):
        print('STOP')
        return 0
    tok = preflight_token(d)
    if tok != 'PROCEED':
        print('HOLD usage-preflight %s' % (tok or 'none'))
        return 0
    rows = d.rows()
    if len(d.open_claims(rows)) >= MAX_OPEN_CLAIMS:
        print('HOLD %d claims open' % MAX_OPEN_CLAIMS)
        return 0
    if desk_fill(d) >= FILL_LIMIT:
        print('HOLD hand-off')
        return 0
    for req in d.requests():
        pr, head = req.get('pr'), req.get('head')
        rows = d.rows()
        if d.has_run(pr, head, rows):
            continue
        cls = 'first'
        prior = None
        if req.get('lane') != 'replay':
            for c in d.claims(rows):
                if c.get('pr') != pr or c.get('head') == head:
                    continue
                ends = [e for e in rows if e.get('kind') == 'end' and e.get('run') == c['run'] and e.get('outcome') in ('GO', 'NO-GO')]
                if ends:
                    prior = (c, ends[0])
        if prior:
            c, end = prior
            r = run_cmd(['bash', os.path.join(HERE, 'delta-class.sh'), '--verdict-file', end.get('reply') or '', c['head'], head])
            word = r.stdout.strip().splitlines()[-1] if r.stdout.strip() and r.returncode == 0 else 'trust'
            if word not in ('none', 'finding', 'trust'):
                word = 'trust'
            if word == 'none' and end.get('outcome') == 'GO':
                with d.locked():
                    rows = d.rows()
                    if d.has_run(pr, head, rows):
                        continue
                    n = 1 + sum(1 for x in rows if x.get('kind') in ('claim', 'noop') and x.get('pr') == pr and str(x.get('head'))[:7] == head[:7])
                    d.append({'schema': 1, 'kind': 'noop', 'run': '%d-%s-%d' % (pr, head[:7], n), 'pr': pr, 'head': head,
                              'judged_head': c['head'], 'delta': 'none', 'at': iso_local(now())})
                print('NOOP %d %s none' % (pr, head))
                continue
            cls = 'finding' if word == 'none' else word
        print('REQUEST %d %s %s %s' % (pr, head, cls, req.get('snapshot')))
        return 0
    print('HOLD no request')
    return 0


def cmd_claim(o):
    d = Desk(o)
    if len(o.rest) != 1:
        die('claim takes <spec.json>', 2)
    if not o.session:
        die('claim needs --desk-session (or CLAUDE_CODE_SESSION_ID)', 2)
    if os.path.exists(d.stop_file):
        die('STOP is present; nothing claimed')
    d.expire_leases()
    spec_path = o.rest[0]
    try:
        with open(spec_path, 'rb') as f:
            spec_bytes = f.read()
        spec = json.loads(spec_bytes)
    except (OSError, ValueError) as e:
        die('cannot read the spec %s: %s' % (spec_path, e))
    if not isinstance(spec, dict):
        die('the spec must be a JSON object')
    qid, pr, head = spec.get('qid'), spec.get('pr'), spec.get('head')
    if not isinstance(pr, int) or not isinstance(head, str) or not HEX40.fullmatch(head):
        die('the spec needs pr and a 40-hex head')
    if not isinstance(qid, str) or not re.fullmatch(r'dsk%d[a-z]' % pr, qid):
        die('the spec qid %r must be dsk<pr><letter> for PR %d, the judge desk\'s prefix' % (qid, pr))
    cls = spec.get('delta_class') or 'first'
    if cls not in ('first', 'trust', 'finding'):
        die('delta_class %r is not a class the desk judges (first, trust or finding)' % (cls,))
    if not any(r.get('pr') == pr and r.get('head') == head for r in d.requests()):
        die('no queued request for PR %d at %s; nothing claimed' % (pr, head))
    if d.has_run(pr, head, d.rows()):
        die('PR %d at %s already has a desk run; nothing claimed' % (pr, head))
    gen = seam('JUDGE_DESK_GEN')
    argv = ['bash', gen] if gen else ['python3', os.path.join(HERE, 'gen-judge-brief.py')]
    env = dict(os.environ, HANDOVER_DIR=d.root)
    r = subprocess.run(argv + [spec_path, '--chief', o.session, '--dispatch-json', '--no-persist'], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, timeout=180)
    if r.returncode != 0:
        die('gen-judge-brief.py refused the spec: ' + (r.stderr.strip().splitlines() or [''])[-1])
    try:
        dispatch = json.loads(r.stdout)
    except ValueError:
        die('gen-judge-brief.py printed no Agent input')
    want = 'sonnet' if cls == 'finding' else 'opus'
    if dispatch.get('model') != want:
        die('the brief names model %r but a %s judge is %s; nothing claimed' % (dispatch.get('model'), cls, want))
    with d.locked():
        rows = d.rows()
        if os.path.exists(d.stop_file):
            die('STOP is present; nothing claimed')
        if d.has_run(pr, head, rows):
            die('PR %d at %s already has a desk run; nothing claimed' % (pr, head))
        n = 1 + sum(1 for x in rows if x.get('kind') in ('claim', 'noop') and x.get('pr') == pr and str(x.get('head'))[:7] == head[:7])
        run = '%d-%s-%d' % (pr, head[:7], n)
        rdir = os.path.join(o.bucket, RUNS_DIR, run)
        os.makedirs(rdir, exist_ok=True)
        with open(os.path.join(rdir, 'spec.json'), 'wb') as f:
            f.write(spec_bytes)
        text = r.stdout.strip() + '\n'
        with open(os.path.join(rdir, 'dispatch.json'), 'w', encoding='utf-8') as f:
            f.write(text)
        t = now()
        d.append({'schema': 1, 'kind': 'claim', 'run': run, 'pr': pr, 'head': head, 'qid': qid, 'class': cls,
                  'model': {'opus': 'claude-opus-5-5', 'sonnet': 'claude-sonnet-5-5'}[want], 'route': 'agent',
                  'desk_session': o.session, 'spec_sha256': sha256_file(os.path.join(rdir, 'spec.json')),
                  'dispatch_sha256': sha256_file(os.path.join(rdir, 'dispatch.json')),
                  'dispatched_at': iso_local(t), 'lease_until': iso_local(t + LEASE_SECONDS)})
    sys.stdout.write(text)
    return 0


def cost_eq(path):
    try:
        r = run_cmd(['bash', os.path.join(HERE, '..', '..', 'lanes', 'worker-burn.sh'), '--raw', path])
    except (OSError, subprocess.TimeoutExpired):
        return 0
    m = re.search(r'\bcost-eq=([0-9.]+)', r.stdout)
    return int(round(float(m.group(1)))) if m else 0


def cmd_record(o):
    d = Desk(o)
    if len(o.rest) != 1 or not o.agent:
        die('record takes <run> --agent <id>', 2)
    if not re.fullmatch(r'[0-9A-Za-z]+', o.agent):
        die('--agent %r is not an agent id' % o.agent, 2)
    run = o.rest[0]
    d.expire_leases()
    rows = d.rows()
    claim = next((c for c in d.claims(rows) if c.get('run') == run), None)
    if claim is None:
        die('no claim for run %s' % run)
    state = d.state(run, rows)
    if state == 'done':
        print('BLOCKED run %s already ended' % run)
        return 3
    late = state == 'lost'
    tpath = os.path.join(d.desk_project_dir(), claim['desk_session'], 'subagents', 'agent-%s.jsonl' % o.agent)
    try:
        tr = Transcript(tpath)
    except OSError:
        print('BLOCKED no transcript for agent %s at %s' % (o.agent, tpath))
        return 3
    rdir = os.path.join(o.bucket, RUNS_DIR, run)
    try:
        with open(os.path.join(rdir, 'dispatch.json'), encoding='utf-8') as f:
            want_prompt = json.load(f).get('prompt')
    except (OSError, ValueError):
        want_prompt = None
    prompt_matches = want_prompt is not None and tr.first_prompt == want_prompt
    head, pr = claim['head'], claim['pr']
    reply = tr.reply or ''
    first = reply.strip().splitlines()[0].strip() if reply.strip() else ''
    m = re.fullmatch(r'\*\*(GO|NO-GO)\*\*(?: for head `?([0-9a-f]{40})`?\.?)?', first)
    outcome = m.group(1) if m and m.group(2) in (None, head) else 'unparsed'
    if outcome == 'unparsed':
        body = reply.rstrip('\n') + '\n'
    else:
        rest = '\n'.join(reply.strip().splitlines()[1:]).strip('\n')
        body = '## Verdict\n\n**%s** for head `%s`.\n\npr: %d\n\n%s\n' % (outcome, head, pr, rest)
    rpath = os.path.join(rdir, 'reply.md')
    facts = judge_facts(tr)
    verdict_at = None
    if tr.reply_ts:
        try:
            verdict_at = datetime.fromtimestamp(parse_time(tr.reply_ts), timezone.utc).isoformat(timespec='seconds')
        except ValueError:
            pass
    row = {'schema': 1, 'kind': 'end', 'run': run, 'outcome': outcome, 'agent': o.agent, 'reply': rpath,
           'reply_sha256': hashlib.sha256(body.encode('utf-8')).hexdigest(), 'verdict_at': verdict_at,
           'write_attempted': facts['attempted'], 'write_refused': True if facts['refused'] else None,
           'prompt_matches': prompt_matches, 'cost_eq': cost_eq(tpath), 'late': late}
    if facts['other_writes']:
        row['other_writes'] = facts['other_writes']
    with d.locked():
        state = d.state(run, d.rows())
        if state == 'done':
            print('BLOCKED run %s already ended' % run)
            return 3
        row['late'] = state == 'lost'
        os.makedirs(rdir, exist_ok=True)
        with open(rpath, 'w', encoding='utf-8') as f:
            f.write(body)
        d.append(row)
    if facts['stops']:
        return trip(d, tpath, facts['stops'][0])
    hit = stop_checks(d)
    if hit:
        return trip(d, hit[0], hit[1])
    print('RECORDED %s %s' % (run, outcome))
    return 0


def ready_head(doc, pr):
    r = run_cmd(['bash', '-c', '. "$1" && doc_ready_head "$2" "$3"', '_', os.path.join(HERE, 'close-facts.sh'), doc, str(pr)])
    lines = [l for l in r.stdout.splitlines() if HEX40.fullmatch(l.strip())]
    return lines[-1].strip() if lines else ''


def cmd_draft_go(o):
    d = Desk(o)
    if len(o.rest) != 1:
        die('draft-go takes <run>', 2)
    if os.path.exists(d.stop_file):
        die('STOP is present; nothing drafted')
    run = o.rest[0]
    rows = d.rows()
    claim = next((c for c in d.claims(rows) if c.get('run') == run), None)
    if claim is None:
        die('no claim for run %s' % run)
    ends = [e for e in rows if e.get('kind') == 'end' and e.get('run') == run]
    if not ends:
        die('run %s has no end row; nothing drafted' % run)
    verdict = next((e['outcome'] for e in ends if e.get('outcome') in ('GO', 'NO-GO')), None)
    pr, head = claim['pr'], claim['head']
    doc = next((r.get('worker_doc') for r in d.requests() if r.get('pr') == pr and r.get('head') == head), None)
    ready = ready_head(doc, pr) if doc else ''
    go_line = None
    if verdict == 'NO-GO':
        draft = 'HOLD-DRAFT'
    elif verdict == 'GO' and ready == head:
        draft = 'GO-DRAFT'
        go_line = 'bash <primary>/scripts/handover/chief-kit/go.sh --trust-reviewed %s %d %s' % (claim['qid'], pr, head)
    else:
        draft = 'WAIT-DRAFT'
    with d.locked():
        if os.path.exists(d.stop_file):
            die('STOP is present; nothing drafted')
        d.append({'schema': 1, 'kind': 'draft', 'run': run, 'draft': draft, 'go_line': go_line, 'at': iso_local(now())})
    print(draft + (' ' + go_line if go_line else ''))
    return 0


def live_count(d, session):
    script = seam('JUDGE_DESK_LIVE') or os.path.join(HERE, 'live-subagents.sh')
    try:
        r = run_cmd(['bash', script, '--session', session, '--projects', d.o.projects], timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r'^live-subagents=(\d+)$', r.stdout, re.M)
    return int(m.group(1)) if m and r.returncode in (0, 1) else None


def cmd_wait(o):
    d = Desk(o)
    if o.rest:
        die('wait takes no positional argument', 2)
    if not o.chief:
        die('wait needs --chief (the one recipient the desk may message)', 2)
    if not o.since:
        die('wait needs --since (the desk start)', 2)
    start = time.monotonic()
    while True:
        d.expire_leases()
        if os.path.exists(d.stop_file):
            print('STOP')
            return 0
        hit = stop_checks(d)
        if hit:
            return trip(d, hit[0], hit[1])
        scan = run_cmd(['bash', os.path.join(HERE, 'judge-queue.sh'), 'scan', '--bucket', o.bucket, '--since', o.since])
        for line in scan.stdout.splitlines():
            if line.startswith('QUEUE?'):
                print(line, file=sys.stderr)
        if scan.returncode != 0:
            print('judge-desk: judge-queue.sh scan failed (rc %d): %s' % (scan.returncode, scan.stderr.strip()), file=sys.stderr)
        rows = d.rows()
        if any(not d.has_run(r.get('pr'), r.get('head'), rows) for r in d.requests()):
            print('REQUEST')
            return 0
        open_by_session = {}
        for c in d.open_claims(rows):
            open_by_session[c.get('desk_session')] = open_by_session.get(c.get('desk_session'), 0) + 1
        for sess, open_n in open_by_session.items():
            live = live_count(d, sess) if sess else None
            if live is not None and live < open_n:
                print('ENDED')
                return 0
        remaining = o.max_wait - (time.monotonic() - start)
        if remaining <= 0:
            print('TIMEOUT')
            return 0
        time.sleep(min(o.tick, remaining))


COMMANDS = {'wait': cmd_wait, 'next': cmd_next, 'claim': cmd_claim, 'record': cmd_record, 'draft-go': cmd_draft_go}
argv = sys.argv[1:]
if not argv or argv[0] not in COMMANDS:
    die('usage: judge-desk.sh wait|next|claim <spec>|record <run> --agent <id>|draft-go <run> --bucket <dir>', 2)
sys.exit(COMMANDS[argv[0]](parse(argv[1:])))
PY
