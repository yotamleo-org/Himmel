#!/usr/bin/env bash
# open-resume-notes.sh — the ONE place that decides which resume notes still owe a relaunch.
#
#   open-resume-notes.sh [--bucket DIR] [--mirror DIR] [--events FILE] [--root DIR]
#
# Read-only: it writes nothing. The status page and the chief's Must disposition read its output and apply no
# rule of their own.
# PLATFORM GUARD: Linux-only chief kit, bash 3.2-safe wrapper around a `python3 -I` body (stdlib only).
#
# Defaults: bucket <handover_root>/<user_slug>/himmel; mirror jira_mirror_dir; events
# ${TICKET_STATUS_STATE_DIR:-$HOME/.himmel/state}/status-events.jsonl; root handover_root.
#
# A note is open when ALL of these hold:
#   1. it is its ticket's newest note. Candidates are the files of the bucket root named
#      <KEY>-<anything>-RESUME.md, <KEY>-<anything>-RESUME<n>.md or <KEY>-<anything>-RESUME-<YYYY-MM-DD>.md
#      (the three shapes are mutually exclusive; hybrids such as -RESUME2-<date>.md, one-offs such as
#      -RESUME-NOTE-… and helper files such as .worker-contract.md are never candidates). Newest is by
#      note_at, ties to the higher RESUME<n>, then the lexically last name. An older note is never promoted.
#      note_at is the older of the file's mtime and the end (23:59:59Z) of its name day, to the second. The
#      name day is the first -YYYY-MM-DD- of the name, else a trailing -YYYY-MM-DD.md; a date that does not
#      parse falls back to the mtime. If a candidate cannot be stat'ed the whole key is UNVERIFIED
#      (reason=stat-failed, path and note_at -) and the read is `incomplete stat-failed:<KEY>`.
#   2. the Jira mirror says its ticket is not Done (<mirror>/<KEY>.md front matter statusCategory). A missing
#      file or no statusCategory makes the key UNVERIFIED (no-mirror-file, no-status); an unreadable file is
#      UNVERIFIED mirror-unreadable. UNVERIFIED keys are not counted in n and do not make the read incomplete.
#      The mirror is fresh when <mirror>/.cursor.json is newer than CHIEF_MUST_MIRROR_MIN minutes (default
#      1440); older is `incomplete mirror-stale`; an unreadable mirror dir or a missing .cursor.json is
#      `incomplete mirror-unreadable` and no note is listed.
#   3. no held lock names the ticket. One `queue-lock.sh status --sweep <root>` call (exit 0 and 20 are good
#      reads). A lock is attributed to a ticket from its slug <user>__<repo>__<stem>: the lock holds the ticket
#      when <stem> starts with <KEY>-. Any status but STALE-DEAD is held. A failed or timed-out sweep is
#      `incomplete locks-unknown`.
#   4. no merge row for the ticket is newer than note_at. merge-rows-effective.py over the events file, rows
#      with event=merge and contract yes|no (next-dispatchable's predicate), ts compared to the second; a ts
#      that does not parse hides nothing. The count of notes hidden this way is merge_hidden. An unreadable
#      events file, a failing filter or a timeout is `incomplete events-unreadable`; a filter that warned on
#      stderr is `incomplete merges-partial`.
# The original doc (orig=) is only shown: <stem>.md, else <stem>-<name day>.md when it exists, else -. It
# decides nothing.
#
# Budget: 70 s in all; each child runs in its own process group (sweep 20 s, merges 35 s with
# MERGE_ROWS_BUDGET_SECS=25 unless set), clamped to the budget left, and is killed as a group on timeout. A
# SIGTERM kills every live child group and still prints the trailer. A run cut short by the budget or a
# SIGTERM is `incomplete deadline`.
#
# Output, newest note_at first: NOTE<TAB>KEY<TAB>path<TAB>note_at<TAB>status=<s><TAB>orig=<path|-> per open
# note, UNVERIFIED<TAB>KEY<TAB>path<TAB>note_at<TAB>reason=<r> per unresolved key, and as the LAST line exactly
# one trailer:
#   # open-notes: complete n=<k> unverified=<u> merge_hidden=<h> mirror_cursor_age_min=<m>
#   # open-notes: incomplete <reason>[,<reason>…] n=<k> unverified=<u> merge_hidden=<h> mirror_cursor_age_min=<m>
# Reader contract: the output is complete only when its last line is a valid trailer, it holds no other
# trailer, n equals the NOTE rows and unverified the UNVERIFIED rows. Anything else is incomplete:
# `no-trailer` (no trailer line at all: a crash, a kill, an older checkout) or `bad-trailer` (a malformed or
# doubled trailer, a trailer that is not last, or a count that does not match). Both readers share
# fixtures/open-notes-trailers.tsv.
# Exit 0 on any listing, 2 on usage. Test seams (honoured only under HIMMEL_TEST_FIXTURE=1):
# OPEN_NOTES_SWEEP_CMD, OPEN_NOTES_MERGE_ROWS_CMD, OPEN_NOTES_NOW (epoch), OPEN_NOTES_BUDGET_SECS,
# OPEN_NOTES_SWEEP_SECS, OPEN_NOTES_MERGE_SECS.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../lib"

have_flag() {
    local f="$1" a
    shift
    for a in "$@"; do [ "$a" != "$f" ] || return 0; done
    return 1
}

def_root=""; def_bucket=""; def_mirror=""; def_events=""
if ! have_flag --root "$@" || ! have_flag --bucket "$@"; then
    if ! { [ -r "$LIB/handover-path.sh" ] && . "$LIB/handover-path.sh"; } 2>/dev/null; then
        echo "open-resume-notes: cannot read $LIB/handover-path.sh" >&2; exit 2
    fi
    def_root="$(handover_root 2>/dev/null)" || def_root=""  # swallow-ok: no root leaves the default empty and the body refuses it
fi
if ! have_flag --bucket "$@" && [ -n "$def_root" ]; then
    if ! { [ -r "$LIB/user-slug.sh" ] && . "$LIB/user-slug.sh"; } 2>/dev/null; then
        echo "open-resume-notes: cannot read $LIB/user-slug.sh" >&2; exit 2
    fi
    slug="$(cd "$HERE/../../.." && user_slug 2>/dev/null)" || slug=""  # swallow-ok: no slug leaves the bucket empty and the body refuses it
    [ -z "$slug" ] || def_bucket="$def_root/$slug/himmel"
fi
if ! have_flag --mirror "$@"; then
    def_mirror="$(JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" bash -c '. "$1" && jira_mirror_dir' _ "$LIB/jira-project.sh" 2>/dev/null)" || def_mirror=""  # swallow-ok: no mirror path leaves the default empty and the body reads it as an unreadable mirror
fi
def_events="${TICKET_STATUS_STATE_DIR:-${HOME:-}/.himmel/state}/status-events.jsonl"

export OPEN_NOTES_DEF_ROOT="$def_root" OPEN_NOTES_DEF_BUCKET="$def_bucket" OPEN_NOTES_DEF_MIRROR="$def_mirror" \
    OPEN_NOTES_DEF_EVENTS="$def_events" OPEN_NOTES_QL="$HERE/../queue-lock.sh" OPEN_NOTES_MERGE_PY="$LIB/merge-rows-effective.py"

exec python3 -I - "$@" <<'PYBODY'
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time

FIXTURE = os.environ.get('HIMMEL_TEST_FIXTURE') == '1'


def seam(name):
    return (os.environ.get(name) or '') if FIXTURE else ''


def seam_secs(name, default):
    try:
        return float(seam(name) or default)
    except ValueError:
        return float(default)


USAGE = 'usage: open-resume-notes.sh [--bucket DIR] [--mirror DIR] [--events FILE] [--root DIR]'
BUDGET = seam_secs('OPEN_NOTES_BUDGET_SECS', 70)
SWEEP_SECS = seam_secs('OPEN_NOTES_SWEEP_SECS', 20)
MERGE_SECS = seam_secs('OPEN_NOTES_MERGE_SECS', 35)
START = time.monotonic()
CAND = re.compile(r'^([A-Z][A-Z0-9]*-[0-9]+)-.+-RESUME(?:([0-9]+)|-[0-9]{4}-[0-9]{2}-[0-9]{2})?\.md$')
MID_DAY = re.compile(r'-([0-9]{4}-[0-9]{2}-[0-9]{2})-')
TRAIL_DAY = re.compile(r'-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$')

live = set()


class Terminated(Exception):
    pass


def kill_groups(sig):
    for pg in list(live):
        try:
            os.killpg(pg, sig)
        except OSError:
            pass


def on_term(_signum, _frame):
    kill_groups(signal.SIGKILL)
    raise Terminated()


def left():
    return BUDGET - (time.monotonic() - START)


def run(argv, timeout, env=None):
    """(rc, stdout, stderr, timed_out); the child runs in its own process group."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True, env=env)
    except OSError:
        return None, '', '', False
    live.add(p.pid)
    try:
        try:
            out, err = p.communicate(timeout=timeout)
            return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace'), False
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                p.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                p.communicate()
            return None, '', '', True
    finally:
        live.discard(p.pid)


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def day_end(day):
    try:
        d = datetime.datetime.strptime(day, '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return int(d.timestamp()) + 86399


def parse_ts(ts):
    if not isinstance(ts, str):
        return None
    try:
        d = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())


def parse_args(argv):
    opts = {'--bucket': os.environ.get('OPEN_NOTES_DEF_BUCKET', ''), '--mirror': os.environ.get('OPEN_NOTES_DEF_MIRROR', ''),
            '--events': os.environ.get('OPEN_NOTES_DEF_EVENTS', ''), '--root': os.environ.get('OPEN_NOTES_DEF_ROOT', '')}
    i = 0
    while i < len(argv):
        if argv[i] in opts and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            return None
    return opts


def front_matter(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().split('\n')
    fm = {}
    if lines and lines[0].strip() == '---':
        for ln in lines[1:]:
            if ln.strip() == '---':
                break
            m = re.match(r'^([A-Za-z]+):\s*"?(.*?)"?\s*$', ln)
            if m:
                fm.setdefault(m.group(1), m.group(2))
    return fm


def main(opts):
    reasons = []
    notes = []
    unverified = []
    hidden = [0]
    cursor_age = ['-']

    def reason(r):
        if r not in reasons:
            reasons.append(r)

    def emit_and_trailer():
        notes.sort(key=lambda r: (r['at'], r['name']), reverse=True)
        unverified.sort(key=lambda r: (r['at'] or 0, r['key']), reverse=True)
        out = []
        for r in notes:
            out.append('NOTE\t%s\t%s\t%s\tstatus=%s\torig=%s' % (r['key'], r['path'], iso(r['at']), r['status'], r['orig']))
        for r in unverified:
            out.append('UNVERIFIED\t%s\t%s\t%s\treason=%s' % (r['key'], r['path'], iso(r['at']) if r['at'] is not None else '-', r['why']))
        head = 'complete' if not reasons else 'incomplete ' + ','.join(reasons)
        out.append('# open-notes: %s n=%d unverified=%d merge_hidden=%d mirror_cursor_age_min=%s'
                   % (head, len(notes), len(unverified), hidden[0], cursor_age[0]))
        sys.stdout.write('\n'.join(out) + '\n')
        sys.stdout.flush()

    try:
        run_steps(opts, reasons, reason, notes, unverified, hidden, cursor_age)
    except Terminated:
        reason('deadline')
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit_and_trailer()
    return 0


def run_steps(opts, reasons, reason, notes, unverified, hidden, cursor_age):
    bucket, mirror, events, root = opts['--bucket'], opts['--mirror'], opts['--events'], opts['--root']
    # step 1: candidates
    try:
        names = os.listdir(bucket) if bucket else None
        if names is None:
            raise OSError('no bucket')
    except OSError:
        reason('bucket-unreadable')
        return
    by_key = {}
    for name in names:
        m = CAND.match(name)
        if m:
            by_key.setdefault(m.group(1), []).append((name, int(m.group(2) or 0)))
    # step 2 and 3: note_at, the newest per key
    newest = {}
    for key in sorted(by_key):
        best = None
        failed = False
        for name, n in by_key[key]:
            path = os.path.join(bucket, name)
            try:
                st = os.stat(path)
            except OSError:
                failed = True
                continue
            if not os.path.isfile(path):
                continue
            at = int(st.st_mtime)
            dm = MID_DAY.search(name) or TRAIL_DAY.search(name)
            if dm:
                de = day_end(dm.group(1))
                if de is not None and de < at:
                    at = de
            cand = (at, n, name)
            if best is None or cand > best:
                best = cand
        if failed:
            unverified.append({'key': key, 'path': '-', 'at': None, 'name': '', 'why': 'stat-failed'})
            reason('stat-failed:%s' % key)
            continue
        if best is not None:
            newest[key] = best
    # step 4: the mirror
    if left() <= 0:
        reason('deadline')
        return
    seam_now = seam('OPEN_NOTES_NOW')
    now = int(seam_now) if seam_now.isdigit() else int(time.time())
    try:
        limit = int(os.environ.get('CHIEF_MUST_MIRROR_MIN') or 1440)
    except ValueError:
        limit = 1440
    try:
        if not mirror or not os.path.isdir(mirror):
            raise OSError('no mirror dir')
        cur = os.stat(os.path.join(mirror, '.cursor.json'))
    except OSError:
        reason('mirror-unreadable')
        return
    age = max(0, (now - int(cur.st_mtime)) // 60)
    cursor_age[0] = str(age)
    if age > limit:
        reason('mirror-stale')
    open_ = {}
    for key, (at, n, name) in sorted(newest.items()):
        path = os.path.join(bucket, name)
        try:
            fm = front_matter(os.path.join(mirror, key + '.md'))
        except FileNotFoundError:
            unverified.append({'key': key, 'path': path, 'at': at, 'name': name, 'why': 'no-mirror-file'})
            continue
        except OSError:
            unverified.append({'key': key, 'path': path, 'at': at, 'name': name, 'why': 'mirror-unreadable'})
            continue
        cat = fm.get('statusCategory', '')
        if not cat:
            unverified.append({'key': key, 'path': path, 'at': at, 'name': name, 'why': 'no-status'})
            continue
        if cat == 'Done':
            continue
        open_[key] = {'key': key, 'path': path, 'at': at, 'name': name, 'status': fm.get('status') or cat}
    # step 5: locks
    if open_:
        if left() <= 0:
            reason('deadline')
            return
        own = SWEEP_SECS
        cmd = [seam('OPEN_NOTES_SWEEP_CMD'), root] if seam('OPEN_NOTES_SWEEP_CMD') else \
            ['bash', os.environ.get('OPEN_NOTES_QL', ''), 'status', '--sweep', root]
        rc, out, _err, timed_out = run(cmd, min(own, left()))
        if timed_out or rc not in (0, 20):
            reason('deadline' if timed_out and left() < own else 'locks-unknown')
        else:
            for ln in out.splitlines():
                sm = re.search(r'(?:^|\s)slug=(\S+)', ln)
                tm = re.search(r'(?:^|\s)status=(\S+)', ln)
                if not sm or not tm or tm.group(1) == 'STALE-DEAD':
                    continue
                stem = sm.group(1).split('__')[-1]
                for key in list(open_):
                    if stem.startswith(key + '-'):
                        del open_[key]
    # step 6: merges
    if open_:
        if left() <= 0:
            reason('deadline')
        else:
            own = MERGE_SECS
            env = dict(os.environ)
            env.setdefault('MERGE_ROWS_BUDGET_SECS', '25')
            cmd = [seam('OPEN_NOTES_MERGE_ROWS_CMD'), events] if seam('OPEN_NOTES_MERGE_ROWS_CMD') else \
                ['python3', os.environ.get('OPEN_NOTES_MERGE_PY', ''), events]
            rc, out, err, timed_out = run(cmd, min(own, left()), env=env)
            if timed_out and left() < own:
                reason('deadline')
            elif timed_out or rc != 0:
                reason('events-unreadable')
            else:
                if 'merge-rows-effective: warn:' in err:
                    reason('merges-partial')
                newest_merge = {}
                for ln in out.splitlines():
                    try:
                        r = json.loads(ln)
                    except ValueError:
                        continue
                    if not isinstance(r, dict) or r.get('event') != 'merge' or r.get('contract') not in ('yes', 'no'):
                        continue
                    ts = parse_ts(r.get('ts'))
                    k = str(r.get('key', ''))
                    if ts is not None and ts > newest_merge.get(k, -1):
                        newest_merge[k] = ts
                for key in list(open_):
                    if newest_merge.get(key, -1) > open_[key]['at']:
                        del open_[key]
                        hidden[0] += 1
    # step 7: the original doc, shown and not judged
    for key, r in open_.items():
        name = r['name']
        stem = re.sub(r'-RESUME(?:[0-9]+|-[0-9]{4}-[0-9]{2}-[0-9]{2})?\.md$', '', name)
        trail = TRAIL_DAY.search(name)
        opts_ = [stem + '.md'] + ([stem + '-' + trail.group(1) + '.md'] if trail else [])
        r['orig'] = '-'
        for o in opts_:
            if os.path.isfile(os.path.join(bucket, o)):
                r['orig'] = os.path.join(bucket, o)
                break
        notes.append(r)


if __name__ == '__main__':
    opts = parse_args(sys.argv[1:])
    if opts is None:
        sys.stderr.write(USAGE + '\n')
        sys.exit(2)
    signal.signal(signal.SIGTERM, on_term)
    sys.exit(main(opts))
PYBODY
