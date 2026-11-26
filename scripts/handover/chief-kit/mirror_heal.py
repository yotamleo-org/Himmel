"""The keys a brief is checked on and their mirror roots; brief-lint's heal of an incomplete Jira mirror.

brief-lint runs this under `python3 -I`, so it puts this directory on sys.path itself and imports from here.
The heal runs `mirror --repair` (an incremental repair, never a full backfill) once per mirror root, under
`<root>.lock`, inside one budget; it only prints diagnostics and always exits 0.
"""
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time

DEFAULT_BUDGET = 90
MAX_BUDGET = 120
STATUS_TIMEOUT = 10
LOCK_POLL = 0.5
STATUS_POLL = 2.0

KEY_RE = r'[A-Z][A-Z0-9]*-[0-9]+'


def brief_keys(doc):
    with open(doc, encoding='utf-8', errors='replace') as fh:
        lines = fh.read().splitlines()
    title = next((l for l in lines if l.startswith('# ')), '')
    keys = list(dict.fromkeys(re.findall(r'\b' + KEY_RE + r'\b', title)))
    named = re.search(KEY_RE, os.path.basename(doc))
    if named and named.group(0) not in keys:
        keys.append(named.group(0))
    return keys


def mirror_root(key):
    root = os.environ.get('BRIEF_LINT_MIRROR') or os.path.expanduser('~/.himmel/state/jira-mirror/' + key.split('-')[0])
    return os.path.abspath(root)


def say(msg):
    print('brief-lint: ' + msg, file=sys.stderr, flush=True)


def budget(env):
    """Seconds for every heal of one brief-lint run: BRIEF_LINT_HEAL_BUDGET, 1 up, capped at 120, default 90."""
    raw = env.get('BRIEF_LINT_HEAL_BUDGET', '')
    if raw == '':
        return DEFAULT_BUDGET
    if re.fullmatch(r'[0-9]+', raw) and int(raw) >= 1:
        return min(int(raw), MAX_BUDGET)
    say('BRIEF_LINT_HEAL_BUDGET %s is not a whole number of seconds; using %d' % (raw, DEFAULT_BUDGET))
    return DEFAULT_BUDGET


class Skip(Exception):
    pass


def _env(prefix):
    env = dict(os.environ)
    env['JIRA_PROJECT_KEY'] = prefix
    return env


def _run_cwd(cli):
    return os.path.dirname(os.path.abspath(cli))


def status(cli, root, prefix, limit):
    """`mirror --status --json` as a dict; Skip when it cannot be had in the time left."""
    if limit <= 0:
        raise Skip('no time left')
    try:
        r = subprocess.run(['node', cli, 'mirror', '--status', '--json', '--root', root], capture_output=True, text=True,
                           timeout=min(STATUS_TIMEOUT, limit), env=_env(prefix), cwd=_run_cwd(cli))
    except subprocess.TimeoutExpired:
        raise Skip('status timed out')
    except OSError as e:
        raise Skip('status could not run: %s' % e)
    if r.returncode != 0:
        raise Skip('status exited %d' % r.returncode)
    try:
        st = json.loads(r.stdout)
    except ValueError:
        raise Skip('status is not JSON')
    if not isinstance(st, dict) or st.get('complete') not in ('yes', 'no', 'none'):
        raise Skip('status names no complete state')
    return st


def kill_group(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    p.wait()


def heal_root(cli, root, prefix, deadline):
    def left():
        return deadline - time.monotonic()

    st = status(cli, root, prefix, left())
    if st['complete'] != 'no':
        return
    if st.get('repairable') is not True:
        if st.get('next') == 'full':
            say('mirror %s is incomplete and needs a full backfill; no heal at launch' % root)
        return

    fh = open(root + '.lock', 'a')
    try:
        last_poll = time.monotonic()
        locked = False
        while not locked:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                continue
            except BlockingIOError:
                pass
            if left() <= 0:
                say('mirror %s is incomplete and its lock is held; no heal' % root)
                return
            if time.monotonic() - last_poll >= STATUS_POLL:
                last_poll = time.monotonic()
                if status(cli, root, prefix, left())['complete'] == 'yes':
                    say('mirror %s was healed by another run' % root)
                    return
            time.sleep(min(LOCK_POLL, max(left(), 0)))

        st = status(cli, root, prefix, left())
        if st['complete'] == 'yes':
            say('mirror %s was healed by another run' % root)
            return
        if st.get('repairable') is not True:
            return
        since = st.get('lastSync')
        started = time.monotonic()
        p = None
        try:
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
            try:
                p = subprocess.Popen(['node', cli, 'mirror', '--repair', '--root', root], env=_env(prefix), cwd=_run_cwd(cli),
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                                     preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}))
            finally:
                signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
            rc = p.wait(timeout=max(left(), 0))
        except subprocess.TimeoutExpired:
            kill_group(p)
            say('mirror %s heal timed out after %d s' % (root, round(time.monotonic() - started)))
            return
        except BaseException:
            if p is not None:
                kill_group(p)
            raise
        try:
            now = status(cli, root, prefix, left())['complete']
        except Skip:
            now = 'unknown'
        say('mirror %s was incomplete since %s; heal ran (rc %d), now complete=%s' % (root, since, rc, now))
    finally:
        fh.close()


def main(doc, cli):
    if not os.path.isfile(cli):
        return
    deadline = time.monotonic() + budget(os.environ)
    groups = {}
    for key in brief_keys(doc):
        groups.setdefault(mirror_root(key), []).append(key)
    for root, keys in groups.items():
        if deadline - time.monotonic() <= 0:
            break
        prefixes = {k.split('-')[0] for k in keys}
        if len(prefixes) > 1:
            say('mirror %s holds keys of two projects; no heal' % root)
            continue
        try:
            heal_root(cli, root, prefixes.pop(), deadline)
        except Exception as e:
            say('mirror %s heal skipped (%s)' % (root, e))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        main(sys.argv[1], sys.argv[2])
    except Exception as e:
        say('heal skipped (%s)' % e)
    sys.exit(0)
