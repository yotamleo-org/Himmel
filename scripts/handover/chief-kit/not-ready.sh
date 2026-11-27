#!/usr/bin/env bash
# not-ready.sh — the one reason the launcher would refuse each open ticket.
#
#   not-ready.sh --doc <chief doc> --keys <file> --version <v> [--mirror DIR] [--specs DIR] [--chains FILE]
#
# Read-only: it writes nothing but stdout, runs no dispatcher pass, starts no loop or daemon and keeps no
# cache. It orders the answers other tools already give and computes one rule of its own: which holder of a
# shared file blocks a launch (a live worker, an open PR, the held list or a series ledger).
# PLATFORM GUARD: Linux-only chief kit, bash 3.2-safe wrapper around a `python3 -I` body (stdlib only).
#
# Sources: the dispatcher pass the chief's tick keeps (<state>/tick-pool-<cksum of "<doc>\n<mirror>">.rows
# and .fp), the tick's own reading of it (tick.sh --pool-dispositions), one release bucket-check, at most one
# chief-route.ts round-status (only when a DESIGN row names a requested key) and focus-chains.json.
# As in the tick, TICK_POOL_TTL (default 1800 s) ages the .rows file; the header's pass age is the .fp's.
#
# Defaults: mirror ${NEXT_DISPATCH_MIRROR:-$(jira_mirror_dir)}; specs <handover_root>/<user_slug>/himmel/specs;
# chains focus-chains.json beside the doc; the children come from the primary checkout (the parent of git's
# common dir), because a worktree has no built Jira CLI.
#
# Output: one header line, one `<KEY>\t<class>\t<detail>` line per key in --keys order (a repeated key once),
# and as the LAST line exactly one trailer:
#   # not-ready version=<v> pass_age_s=<n> owner_unknown=<workers> blind=<marker>[,<marker>]|-
#   not-ready: complete|partial n=<keys> refused=<r> not_judged=<c> running=<u> ready=<a>
# With no usable pass there are no key lines: the header ends banner=<reason> and the trailer is
# `not-ready: unavailable <reason>`. owner_unknown counts the distinct workers the `# owner unknown:` lines
# name. `ready` needs a listed disposition, no refusal and no kept blind marker; unknown text is cannot-judge.
# Class order: cannot-judge, running, needs-closing, dispatch:<word>, unsigned-design (operator), held,
# round-cap, unsigned-design, chain, file-held, status, version, ready. A source that is blind for one key
# (a bucket-check FAILED, an unknown chain step, an unknown overlap holder) only stops `ready`.
# `version` can only fire when Jira changed between the caller's key listing and this read.
#
# Exit 0 on any trailer, 2 on usage (including a --keys line that is not a key), 3 when the doc, the mirror
# or the keys file cannot be read.
#
# Test seams, honoured only under HIMMEL_TEST_FIXTURE=1:
#   NOT_READY_PRIMARY     the primary checkout the children are resolved from
#   NOT_READY_STATE_DIR   replaces ${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}
#   NOT_READY_NOW         the clock, epoch seconds
#   NOT_READY_DEADLINE    the 90 s run deadline
#   NOT_READY_TICK_CMD    replaces `bash <primary>/scripts/handover/chief-kit/tick.sh`;
#                         argv --pool-dispositions --doc <doc>, the snapshot on stdin
#   NOT_READY_JIRA_CLI    replaces `node <primary>/scripts/jira/dist/index.js`;
#                         argv release bucket-check --mirror <mirror> <keys...>
#   NOT_READY_ROUNDS_CMD  replaces `bun <primary>/scripts/telegram/chief-route.ts`;
#                         argv round-status --all --specs <specs> --json
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../lib"

usage() { echo "usage: not-ready.sh --doc <chief doc> --keys <file> --version <v> [--mirror DIR] [--specs DIR] [--chains FILE]" >&2; }

doc=""; keys=""; version=""; mirror=""; specs=""; chains=""
while [ $# -gt 0 ]; do
    case "$1" in
        --doc | --keys | --version | --mirror | --specs | --chains)
            if [ $# -lt 2 ] || [ -z "$2" ]; then usage; exit 2; fi
            case "$1" in
                --doc) doc="$2" ;;
                --keys) keys="$2" ;;
                --version) version="$2" ;;
                --mirror) mirror="$2" ;;
                --specs) specs="$2" ;;
                --chains) chains="$2" ;;
            esac
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
if [ -z "$doc" ] || [ -z "$keys" ] || [ -z "$version" ]; then usage; exit 2; fi

unreadable() { echo "not-ready: cannot read the $1: $2" >&2; exit 3; }
if [ ! -f "$doc" ] || [ ! -r "$doc" ]; then unreadable doc "$doc"; fi
if [ ! -f "$keys" ] || [ ! -r "$keys" ]; then unreadable "keys file" "$keys"; fi
if LC_ALL=C grep -qvE '^[A-Z][A-Z0-9_]*-[0-9]+$' "$keys"; then
    echo "not-ready: --keys holds a line that is not a ticket key" >&2; exit 2
fi

for lib in load-dotenv.sh jira-project.sh handover-path.sh user-slug.sh git-clean.sh timeout-bin.sh; do
    [ -r "$LIB/$lib" ] || { echo "not-ready: cannot read $LIB/$lib" >&2; exit 3; }
done
# shellcheck source=../../lib/load-dotenv.sh
. "$LIB/load-dotenv.sh"
# shellcheck source=../../lib/jira-project.sh
. "$LIB/jira-project.sh"
[ -n "$mirror" ] || mirror="${NEXT_DISPATCH_MIRROR:-$(jira_mirror_dir)}"
if [ ! -d "$mirror" ] || [ ! -r "$mirror" ]; then unreadable mirror "$mirror"; fi

if [ -z "$specs" ]; then
    # shellcheck source=../../lib/handover-path.sh
    . "$LIB/handover-path.sh"
    # shellcheck source=../../lib/user-slug.sh
    . "$LIB/user-slug.sh"
    load_dotenv HANDOVER_DIR 2>/dev/null || true  # swallow-ok: no .env leaves handover_root its own fallback
    root="$(handover_root 2>/dev/null)" || root=""  # swallow-ok: no root leaves specs empty and the round read is blind
    slug="$(cd "$HERE/../../.." && user_slug 2>/dev/null)" || slug=""  # swallow-ok: no slug leaves specs empty and the round read is blind
    if [ -n "$root" ] && [ -n "$slug" ]; then specs="$root/$slug/himmel/specs"; fi
fi

fixture="${HIMMEL_TEST_FIXTURE:-}"
primary=""
state_dir="${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}"
if [ "$fixture" = 1 ]; then
    primary="${NOT_READY_PRIMARY:-}"
    state_dir="${NOT_READY_STATE_DIR:-$state_dir}"
fi
if [ -z "$primary" ]; then
    # shellcheck source=../../lib/git-clean.sh
    . "$LIB/git-clean.sh"
    common="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""  # swallow-ok: no repository falls back to this checkout
    [ -n "$common" ] || common="$HERE/../../../.git"
    primary="$(dirname "$common")"
fi
snap_base="$state_dir/tick-pool-$(printf '%s\n%s' "$doc" "$mirror" | cksum | cut -d' ' -f1)"
ttl="${TICK_POOL_TTL:-1800}"; case "$ttl" in '' | *[!0-9]*) ttl=1800 ;; esac

# shellcheck source=../../lib/timeout-bin.sh
. "$LIB/timeout-bin.sh"

export NR_DOC="$doc" NR_KEYS="$keys" NR_VERSION="$version" NR_MIRROR="$mirror" NR_SPECS="$specs" NR_CHAINS="$chains" \
    NR_PRIMARY="$primary" NR_SNAP="$snap_base" NR_TTL="$ttl" NR_TIMEOUT="$_TIMEOUT_BIN"

exec python3 -I - <<'PYBODY'
import json
import os
import re
import signal
import subprocess
import sys
import time

START = time.monotonic()
FIXTURE = os.environ.get('HIMMEL_TEST_FIXTURE') == '1'


def seam(name):
    return (os.environ.get(name) or '') if FIXTURE else ''


# The upstream strings this script depends on: id -> (source, the text matched here, the text the source
# holds). test-not-ready.sh R-markers checks every pin against its source file, so a reworded line fails
# there instead of passing here unseen.
MARKERS = {
    # dispositions the dispatcher could not judge; any text not matched below is judged the same way
    'owner-unknown': ('dispatcher', 'owner unknown', ("OWNER_UNKNOWN_DROP = 'owner unknown: ",)),
    'blocker-unknown': ('dispatcher', 'blocker-unknown ', ("'blocker-unknown ' + ', '.join(unknown)",)),
    'open-prs-unknown': ('dispatcher', 'open PRs unknown', ("'open PRs unknown (gh failed): ownership cannot be checked'",)),
    'status-unreadable': ('dispatcher', 'status-events.jsonl unreadable', ("'status-events.jsonl unreadable and the key has a merge on main'",)),
    'core-check-failed': ('dispatcher', 'core-check failed', ("'core-check failed (",)),
    'core-unknown': ('dispatcher', 'core-unknown', ("'core-unknown (",)),
    'spec-signer-unknown': ('dispatcher', 'spec-signer-unknown', ("'spec-signer-unknown ' + u",)),
    'classification-none': ('dispatcher', 'classification none', ("'classification ' + (", "else 'none (cloud-route gave no verdict)'")),
    'below-top': ('dispatcher', 'below --top', ("r = 'below --top %d' % top",)),
    'unknown-reason': ('dispatcher', 'unknown (', ("d = 'unknown (no drop reason recorded)'",)),
    # running, needs closing
    'owned-by': ('dispatcher', 'owned by ', ("drop(i, 'owned by ' + owner.get(i['key'], 'a live worker'))",)),
    'in-flight': ('dispatcher', 'in-flight owned by ', ("d = 'in-flight owned by ' + owner.get(k, 'a live worker')",)),
    'merged-not-closed': ('dispatcher', 'MERGED-NOT-CLOSED', ("lane_of[i['key']] = 'MERGED-NOT-CLOSED'",)),
    'done-pending': ('dispatcher', 'done-pending', ("'done-pending (a contract=yes merge row; the mirror lags)'",)),
    # refusals: dispatch:<word>, and the operator's signature
    'needs-chief-note': ('dispatcher', 'NEEDS-CHIEF-NOTE ', ("print('NEEDS-CHIEF-NOTE %s: ",)),
    'blocker': ('dispatcher', 'blocker ', ("'blocker ' + ', '.join(known)",)),
    'partial-merge': ('dispatcher', 'partial-merge', ("r = 'partial-merge (",)),
    'resume-brief': ('dispatcher', 'resume-brief', ("r = 'resume-brief (",)),
    'no-scope': ('dispatcher', 'no-scope', ("'no-scope (nothing says what it writes: a chief question)'",)),
    'proof-missing': ('dispatcher', 'proof missing', ("'proof missing: ' + miss",)),
    'label': ('dispatcher', 'label ', ("'label ' + ','.join(",)),
    'type': ('dispatcher', 'type ', ("'type ' + i['type']",)),
    'platform': ('dispatcher', 'platform (', ("'platform (dropped-platform title)'",)),
    'residual-depth': ('dispatcher', 'residual-depth ', ("'residual-depth %d (",)),
    'cloud-only': ('dispatcher', 'cloud-only', ("'cloud-only on the priority line'",)),
    'classification-blocked': ('dispatcher', 'classification BLOCKED', ("'classification ' + (", "('BLOCKED: ' + ")),
    'owed-step': ('dispatcher', 'owned next step: ', ("'owned next step: ' + i['owed_wait']['actor']",)),
    'stackable': ('dispatcher', 'stackable on ', ("'stackable on %s (%d/%d)'",)),
    'unowned': ('dispatcher', 'unowned ', ("d = 'unowned %s (",)),
    'spec-needs-operator': ('dispatcher', 'spec-needs-operator ', ("'spec-needs-operator ' + t[-1]",)),
    # listed lanes and the rows beside them
    'listed': ('dispatcher', 'listed ', ("d = 'listed ' + lane_of[k]",)),
    'lane-local': ('dispatcher', 'LOCAL', ("return ('CLOUD' if c == 'CLOUD-OK' else 'LOCAL'), c", "return 'LOCAL?', ''")),
    'lane-cloud': ('dispatcher', 'CLOUD', ("return ('CLOUD' if c == 'CLOUD-OK' else 'LOCAL'), c",)),
    'lane-resume': ('dispatcher', 'RESUME', ("lane_of[i['key']] = 'RESUME'",)),
    'lane-series': ('dispatcher', 'SERIES ', ("lane_of[k] = 'SERIES ' + h",)),
    'lane-design': ('dispatcher', 'DESIGN', ("lane_of[i['key']] = 'DESIGN'",)),
    'design-row': ('dispatcher', 'DESIGN', ("say('\\t'.join(['DESIGN', i['key'], design[i['key']]",)),
    # a shared file's holders, and the lines that blind a check
    'overlap': ('dispatcher', '# overlap ', ("say('# overlap %s %s with %s%s' %",)),
    'hold-live-worker': ('dispatcher', 'live worker ', ("'live worker %s'",)),
    'hold-open-pr': ('dispatcher', 'open PR ', ("'open PR %s' % num",)),
    'hold-held-list': ('dispatcher', 'held list', ("'held list'",)),
    'hold-series': ('dispatcher', 'series ', ("'series %s' % sid",)),
    'hold-listed': ('dispatcher', 'listed ', ("[(f, 'listed ' + k) for f, k in picked_hits(i)]",)),
    'overlap-unknown': ('dispatcher', '# overlap unknown', ("'# overlap unknown for %s' % what",)),
    'warn-names': ('dispatcher', '# warn: ', ("'# warn: %s names %s (",)),
    'warn': ('dispatcher', '# warn: ', ("'# warn: %s is unreadable",)),
    'warn-upper': ('dispatcher', '# WARN', ("'# WARN CORE-CHECK-FAILED %s'",)),
    'summary': ('dispatcher', '# next-dispatchable: ', ("'# next-dispatchable: %d To Do candidate(s), %d collision-free%s'",)),
    'summary-resume': ('dispatcher', 'RESUME (in work, no worker, no open PR)', ("', %d RESUME (in work, no worker, no open PR)'",)),
    'summary-live': ('dispatcher', 'live workers unknown', (", live workers unknown (",)),
    'summary-prs': ('dispatcher', 'open PRs unknown', ("', open PRs unknown (gh failed)'",)),
    'summary-merged': ('dispatcher', 'merged PRs unknown', ("', merged PRs unknown (gh failed)'",)),
    'owner-unknown-line': ('dispatcher', '# owner unknown: ', ("'# owner unknown: %s (",)),
    # the tick's reading
    'pool-parked': ('tick', '# pool-parked ', ('print("# pool-parked " + key)',)),
    'readiness-held': ('tick', '# readiness-held ', ('"# readiness-held c %s blocker=%s age=%s"', '"# readiness-held d %s blocker=%s age=%s%s"')),
    'pool-unchecked': ('tick', '# pool-unresolved unchecked ', ('print("# pool-unresolved %s %s %s" % (cls, key, reason))', 'held[key] = ("unchecked",')),
    'readiness-blind': ('tick', '# readiness ?', ('print("# readiness ?")',)),
    'counts-blind': ('tick', '# pool-counts ?', ('print("# pool-counts ?")',)),
    'counts': ('tick', '# pool-counts ', ('print("# pool-counts %d/%d/%d/%d" %',)),
    # bucket-check verdicts and round-status fields
    'bucket-failed': ('bucket', 'FAILED', ('`FAILED ${key} ${why',)),
    'bucket-none': ('bucket', 'NONE', ('`NONE ${key} ${mirrorRoot}`',)),
    'bucket-approved': ('bucket', 'APPROVED', ('`APPROVED ${key} decision=',)),
    'bucket-done': ('bucket', 'DONE', ('`DONE ${key}`',)),
    'bucket-in': ('bucket', 'IN current=', ('`IN ${key} current=${current} via=',)),
    'bucket-outside': ('bucket', 'OUTSIDE current= open=', ("`OUTSIDE ${key} ${versions.join(',') || 'none'} current=${current} open=${open}`",)),
    'rounds-keys': ('rounds', 'keys', ('console.log(JSON.stringify({ cap: CRITIC_ROUND_CAP, classes: OPERATOR_CRITICAL_CLASSES, keys: out }));',)),
    'rounds-next': ('rounds', 'next none full closure why spec plan', ('next: "full" | "closure" | "none"; why: string;', 'key: string; epoch: number; spec: number; plan: number;')),
    'rounds-error': ('rounds', 'error', ('({ key, error: e.message })',)),
    # lines that make the whole pass unusable
    'quota-pause': ('dispatcher', '# quota-pause', ("printf '# quota-pause %s\\n'",)),
    'gh-stall': ('dispatcher', '# gh-stall', ("printf '# gh-stall %s\\n'",)),
    'dropped-from': ('dispatcher', '# dropped from ', ("'# dropped from %s: %d of %d To Do (%s)'",)),
}


def M(name):
    return MARKERS[name][1]


DEADLINE = float(seam('NOT_READY_DEADLINE') or 90)
DOC = os.environ['NR_DOC']
VERSION = os.environ['NR_VERSION']
MIRROR = os.environ['NR_MIRROR']
PRIMARY = os.environ['NR_PRIMARY']


def kill_group(pgid):
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass


def run(argv, own, data=None, env=None):
    """The child's stdout, or None for any failed call. Each child gets the smaller of its own budget and
    the time left minus 3 s (the kill grace counts inside the deadline); with under half a second left it
    is not called, because timeout reads a limit of 0 as no limit."""
    secs = min(own, DEADLINE - (time.monotonic() - START) - 3)
    if secs < 0.5 or not os.environ['NR_TIMEOUT']:
        return None
    try:
        p = subprocess.Popen([os.environ['NR_TIMEOUT'], '-k', '2', '%.2f' % secs] + argv,
                             stdin=subprocess.DEVNULL if data is None else subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, env=env)
    except OSError:
        return None
    try:
        try:
            out = p.communicate(data, timeout=secs + 2.5)[0]
        except subprocess.TimeoutExpired:
            kill_group(p.pid)
            try:
                p.communicate(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass  # a descendant that left the group still holds the pipe: stop waiting for it
            return None
    finally:
        kill_group(p.pid)
    return out.decode('utf-8', 'replace') if p.returncode == 0 else None


def clean(text):
    return re.sub(r'[\t\r\n]', ' ', text)


class Unusable(Exception):
    """No usable dispatcher pass: the banner form, with no key line."""


def header(pass_age, owner_unknown, blind):
    return '# not-ready version=%s pass_age_s=%s owner_unknown=%s blind=%s' % (VERSION, pass_age, owner_unknown, blind)


def banner(reason):
    reason = clean(reason)[:400]
    print(header('-', '-', '-') + ' banner=' + reason)
    print('not-ready: unavailable ' + reason)


def read_snapshot(now):
    """(the snapshot bytes, its lines, the pass age). The TTL ages the .rows file, as the tick applies it
    (a tick that finds nothing changed touches it); the pass itself is as old as the .fp."""
    base = os.environ['NR_SNAP']
    try:
        passed = int(os.stat(base + '.fp').st_mtime)
        with open(base + '.rows', 'rb') as f:
            written = int(os.fstat(f.fileno()).st_mtime)
            data = f.read()
    except OSError:
        raise Unusable('no dispatcher pass yet for %s' % DOC)
    if now - written >= int(os.environ['NR_TTL']):
        raise Unusable('dispatcher pass %ds old' % (now - written))
    lines = data.decode('utf-8', 'replace').split('\n')
    if lines[0].startswith((M('quota-pause'), M('gh-stall'))):
        raise Unusable(lines[0])
    for line in lines:
        m = re.match(re.escape(M('dropped-from')) + r'(\S+):', line)
        if m:
            if m.group(1) != VERSION:
                raise Unusable('the snapshot is for %s, not %s' % (m.group(1), VERSION))
            return data, lines, max(0, now - passed)
    raise Unusable("the snapshot has no '# dropped from' line")


KEY = r'[A-Z][A-Z0-9_]*-[0-9]+'
# the dispatch:<word> of each refusing disposition
DISPATCH = (('blocker', 'blocker'), ('partial-merge', 'partial-merge'), ('resume-brief', 'resume-brief'),
            ('no-scope', 'no-scope'), ('proof-missing', 'proof'), ('label', 'label'), ('type', 'type'),
            ('platform', 'platform'), ('residual-depth', 'residual-depth'), ('cloud-only', 'cloud-only'),
            ('classification-blocked', 'classifier'), ('owed-step', 'owed'), ('stackable', 'stackable'),
            ('unowned', 'unowned'))


class Pass:
    """What one usable snapshot says, per key."""

    def __init__(self, lines):
        self.lines = lines
        self.dispositions, self.notes, self.design, self.unknown_workers = {}, {}, {}, set()
        for line in lines:
            m = re.match(r'# disposition (%s) (.+)' % KEY, line)
            if m:
                self.dispositions[m.group(1)] = m.group(2)
                continue
            m = re.match(re.escape(M('needs-chief-note')) + '(%s):' % KEY, line)
            if m:
                self.notes.setdefault(m.group(1), line)
                continue
            fields = line.split('\t')
            if fields[0] == M('design-row') and len(fields) > 2:
                self.design[fields[1]] = fields[2]
            elif line.startswith(M('owner-unknown-line')):
                who = re.match(re.escape(M('owner-unknown-line')) + r'live worker (\S+) ', line)
                self.unknown_workers.add(who.group(1) if who else line.split(' (', 1)[0])


def by_disposition(p, key):
    """(class, detail) for classes 1 to 5, or None for a listed key that classes 6 to 13 decide."""
    text = p.dispositions.get(key)
    if text is None:
        return 'cannot-judge', 'no disposition for this key'
    for name in ('owned-by', 'in-flight'):
        if text.startswith(M(name)):
            return 'running', text[len(M(name)):]
    if text == M('listed') + M('merged-not-closed') or text.startswith(M('done-pending')):
        return 'needs-closing', text
    refusal = None
    listed = False
    for name, word in DISPATCH:
        if text.startswith(M(name)):
            refusal = ('dispatch:' + word, text)
            break
    if refusal is None and text.startswith(M('spec-needs-operator')):
        refusal = ('unsigned-design', "needs the operator's signature (%s)" % text.split()[-1])
    if refusal is None and text.startswith(M('listed')):
        lane = text[len(M('listed')):]
        listed = lane in (M('lane-local'), M('lane-local') + '?', M('lane-cloud'), M('lane-resume')) \
            or re.match(re.escape(M('lane-series')) + KEY + '$', lane) is not None \
            or (lane == M('lane-design') and key in p.design)
    if refusal is None and not listed:
        return 'cannot-judge', text
    if key in p.notes:
        return 'dispatch:needs-chief-note', p.notes[key]
    return refusal


def command(name, default):
    return [seam(name)] if seam(name) else default


class Blind:
    """The kept blind markers, in the order found. A marker only stops a key from reading ready."""

    def __init__(self):
        self.marks = []  # (name, the line or reason, the one key it blinds or None for every key)

    def add(self, name, why, key=None):
        self.marks.append((name, why, key))

    def names(self):
        return list(dict.fromkeys(name for name, _, _ in self.marks))


def tick_reading(data, blind):
    """(held lines per key, unchecked park lines per key) from tick.sh's own reading of the snapshot."""
    out = run(command('NOT_READY_TICK_CMD', ['bash', os.path.join(PRIMARY, 'scripts/handover/chief-kit/tick.sh')])
              + ['--pool-dispositions', '--doc', DOC], 20, data=data, env=dict(os.environ, NEXT_DISPATCH_MIRROR=MIRROR))
    held, unchecked = {}, {}
    if out is None:
        blind.add('tick-reading', 'the tick reading call failed')
        return held, unchecked
    counted = False
    for line in out.split('\n'):
        if line in (M('readiness-blind'), M('counts-blind')):
            blind.add('tick-reading', line)
        counted = counted or line.startswith(M('counts'))
        m = re.match(re.escape(M('pool-unchecked')) + '(%s) ' % KEY, line)
        if m:
            unchecked[m.group(1)] = line
        m = re.match(re.escape(M('pool-parked')) + '(%s)$' % KEY, line) \
            or re.match(re.escape(M('readiness-held')) + '[cd] (%s) ' % KEY, line)
        if m:
            held.setdefault(m.group(1), line)
    if not counted:
        blind.add('tick-reading', 'the reading has no pool-counts line')
    return held, unchecked


def bucket_check(keys, blind):
    """{key: (verdict, rest of line)}. A verdict about another version is blind and is not applied."""
    if not keys:
        return {}
    env = dict(os.environ)
    env.setdefault('JIRA_PROJECT_KEY', keys[0].rsplit('-', 1)[0])
    out = run(command('NOT_READY_JIRA_CLI', ['node', os.path.join(PRIMARY, 'scripts/jira/dist/index.js')])
              + ['release', 'bucket-check', '--mirror', MIRROR] + keys, 60, env=env)
    if out is None:
        blind.add('bucket-check', 'the bucket-check call failed')
        return {}
    forms = (('FAILED', r'FAILED (?P<key>\S+) (?P<rest>.*)'),
             ('NONE', r'NONE (?P<key>\S+) (?P<rest>.*)'),
             ('APPROVED', r'APPROVED (?P<key>\S+) (?P<rest>.*)'),
             ('DONE', r'DONE (?P<key>\S+)(?P<rest>)'),
             ('IN', r'IN (?P<key>\S+) (?P<rest>current=(?P<current>\S+) via=\S+)'),
             ('OUTSIDE', r'OUTSIDE (?P<key>\S+) (?P<rest>.* current=(?P<current>\S+) open=[0-9]+)'))
    got = {}
    for line in out.split('\n'):
        for verdict, form in forms:
            m = re.fullmatch(form, line)
            if not m:
                continue
            if m.groupdict().get('current') not in (None, VERSION):
                blind.add('bucket-version', line)
                got[m['key']] = ('OTHER-VERSION', line)
            else:
                got[m['key']] = (verdict, m['rest'])
    missing = [k for k in keys if k not in got]
    if missing:
        blind.add('bucket-check', 'no verdict line for %s' % missing[0])
    return got


def round_state(specs, blind):
    """round-status's {key: state}, or None when the call failed."""
    out = None
    if specs:
        out = run(command('NOT_READY_ROUNDS_CMD', ['bun', os.path.join(PRIMARY, 'scripts/telegram/chief-route.ts')])
                  + ['round-status', '--all', '--specs', specs, '--json'], 20)
    if out is not None:
        try:
            state = json.loads(out)[M('rounds-keys')]
            if isinstance(state, dict) and all(isinstance(v, dict) for v in state.values()):
                return state
        except (ValueError, KeyError, TypeError):
            pass
    blind.add('rounds', 'the round-status call failed')
    return None


def read_chains(named, blind):
    """({key: why it waits}, {key: why its chain state is unknown}) from focus-chains.json. With no --chains,
    a missing file beside the doc means there are no chains; a named file that is missing is blind."""
    path = named or os.path.join(os.path.dirname(os.path.abspath(DOC)), 'focus-chains.json')
    waits, unknown = {}, {}
    try:
        with open(path, encoding='utf-8') as f:
            rows = json.load(f)
        if not isinstance(rows, list):
            raise ValueError('not a list of chains')
        for row in rows:
            if 'drain' in row:
                continue
            name = row.get('id') or row.get('name') or '?'
            steps = [step['key'] for step in row['steps']]
            if not all(isinstance(row.get(f), list) for f in ('next', 'done', 'unknown')):
                for key in steps:
                    unknown.setdefault(key, 'chain %s has no next, done and unknown lists' % name)
                continue
            for key in steps:
                if key in row['unknown']:
                    unknown.setdefault(key, 'chain %s does not know this step' % name)
                elif key not in row['next'] and key not in row['done']:
                    waits.setdefault(key, "not the chain's next step (next: %s) in chain %s"
                                     % (', '.join(row['next']) or '-', name))
    except FileNotFoundError:
        if named:
            blind.add('chains', '%s: no such file' % path)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        blind.add('chains', '%s: %s' % (path, type(e).__name__))
        return {}, {}
    return waits, unknown


def holders(p_lines, key):
    """(the first overlap that blocks a launch, the first overlap line whose holder is not one we know)."""
    blocking, odd = None, None
    blockers = (M('hold-live-worker'), M('hold-open-pr'), M('hold-held-list'), M('hold-series'))
    for line in p_lines:
        if not line.startswith(M('overlap') + key + ' '):
            continue
        m = re.match(re.escape(M('overlap') + key) + r' (.+?) with (.+)$', line)
        if m and m.group(2).startswith(blockers):
            blocking = blocking or '%s with %s' % (m.group(1), m.group(2))
        elif not (m and re.match(re.escape(M('hold-listed')) + KEY + '$', m.group(2))):
            odd = odd or line
    return blocking, odd


def design_class(p, f, key):
    """Classes 7 and 8, for a key with a DESIGN row."""
    reason = p.design[key]
    if f['rounds'] is None:
        return 'unsigned-design', '%s; rounds unread' % reason
    state = f['rounds'].get(key)
    if state is None:
        return 'unsigned-design', '%s; no rounds yet' % reason
    if state.get('error'):
        return 'cannot-judge', str(state['error'])
    if state.get('next') == 'none':
        return 'round-cap', str(state.get('why'))
    if state.get('next') in ('full', 'closure'):
        return 'unsigned-design', '%s; spec r%s plan r%s next %s' % (reason, state.get('spec'), state.get('plan'), state['next'])
    return 'cannot-judge', 'round state next=%s' % state.get('next')


def snapshot_marks(lines, blind):
    """The blind markers the pass itself carries. It is clean only when its summary line has the clean form
    and it holds no WARN, no unknown overlap and no unreadable-file or missing-file warning."""
    summary = next((line for line in lines if line.startswith(M('summary'))), None)
    if summary is None:
        blind.add('summary', 'the pass has no summary line')
    for line in lines:
        if line == summary:
            rest = line
            for name in ('summary-live', 'summary-prs', 'summary-merged'):
                if ', ' + M(name) in line:
                    blind.add(M(name), line)
                    rest = re.sub(r', ' + re.escape(M(name)) + r' \([^()]*\)', '', rest)
            clean_form = re.escape(M('summary')) + r'[0-9]+ To Do candidate\(s\), [0-9]+ collision-free(, [0-9]+ ' \
                + re.escape(M('summary-resume')) + ')?'
            if not re.fullmatch(clean_form, rest):
                blind.add('summary', line)
        elif line.startswith(M('warn-upper')):
            blind.add('WARN', line)
        elif line.startswith(M('overlap-unknown')):
            blind.add('overlap unknown', line)
        elif line.startswith(M('warn')):
            m = re.match(re.escape(M('warn-names')) + '(%s) names ' % KEY, line)
            if m:
                blind.add('warn:' + m.group(1), line, m.group(1))
            elif ' holds directory ' not in line:
                blind.add('warn', line)


def classify(p, f, blind, key):
    early = by_disposition(p, key)
    if early:
        return early
    if key in f['unchecked']:
        return 'cannot-judge', f['unchecked'][key]
    if key in f['held']:
        return 'held', f['held'][key]
    if key in p.design:
        return design_class(p, f, key)
    if key in f['waits']:
        return 'chain', f['waits'][key]
    blocking, odd = holders(p.lines, key)
    if blocking:
        return 'file-held', blocking
    verdict, rest = f['bucket'].get(key, ('', ''))
    if verdict == 'DONE':
        return 'status', 'Done in the Jira mirror'
    if verdict == 'OUTSIDE':
        return 'version', rest
    # from here the key would be ready: a source that is blind for it now matters
    if verdict == 'FAILED':
        return 'cannot-judge', rest
    if key in f['chain_unknown']:
        return 'cannot-judge', f['chain_unknown'][key]
    if odd:
        return 'cannot-judge', odd
    for name, why, only in blind.marks:
        # 'rounds' blinds class 7 alone, and a key with a DESIGN row never gets this far
        if only in (None, key) and name != 'rounds':
            return 'cannot-judge', '%s: %s' % (name, why)
    return 'ready', '-'


def report(keys, now):
    data, lines, pass_age = read_snapshot(now)
    p = Pass(lines)
    blind = Blind()
    snapshot_marks(lines, blind)
    f = {}
    f['held'], f['unchecked'] = tick_reading(data, blind)
    f['bucket'] = bucket_check(keys, blind)
    f['rounds'] = round_state(os.environ['NR_SPECS'], blind) if any(k in p.design for k in keys) else {}
    f['waits'], f['chain_unknown'] = read_chains(os.environ['NR_CHAINS'], blind)
    rows = [(key,) + classify(p, f, blind, key) for key in keys]
    out = [header(pass_age, len(p.unknown_workers), ','.join(blind.names()) or '-')]
    out += ['%s\t%s\t%s' % (key, cls, clean(detail)[:160]) for key, cls, detail in rows]
    count = {'refused': 0, 'cannot-judge': 0, 'running': 0, 'ready': 0}
    for _, cls, _ in rows:
        count[cls if cls in count else 'refused'] += 1
    out.append('not-ready: %s n=%d refused=%d not_judged=%d running=%d ready=%d'
               % ('partial' if blind.marks else 'complete', len(rows), count['refused'], count['cannot-judge'],
                  count['running'], count['ready']))
    return out


def main():
    seen = {}
    with open(os.environ['NR_KEYS'], encoding='utf-8') as f:
        for line in f.read().split('\n'):
            if line:
                seen[line] = None
    stamp = seam('NOT_READY_NOW')
    try:
        out = report(list(seen), int(stamp) if stamp.isdigit() else int(time.time()))
    except Unusable as e:
        banner(str(e))
        return 0
    except Exception as e:  # the trailer is always printed; a crash is never a ready list
        banner('internal error: %s: %s' % (type(e).__name__, e))
        return 0
    sys.stdout.write('\n'.join(out) + '\n')
    return 0


sys.exit(main())
PYBODY
