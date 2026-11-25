"""Read pending local lifecycle events; execution stays in the existing relay."""
import json
import hashlib
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time

# A file's stamp is only trusted once the file was this much older than the moment it was read: a rewrite
# that keeps the stamp can only happen inside the timestamp's resolution (a second on the coarsest disks).
RACY_NS = 2_000_000_000
# A refused cleanup is offered again after the retry window times the step for its count of refusals in a row.
STEPS = (1, 2, 6, 24, 60)
MARK = re.compile(r'^- (?:\d{1,2}:\d{2} )?(?:\*\*)?(READY|WRAPPED|MERGED)(?:[^A-Za-z]|$)')
_CRC = []


def checksum(raw):
    """POSIX cksum of one worker-document line as the relay records it: the CRC-32 (polynomial 0x04C11DB7,
    high bit first) of the line, a newline and the byte count, complemented. The relay holds the line in a
    shell variable, which cannot hold a NUL, so a NUL is dropped here too."""
    if not _CRC:
        for i in range(256):
            crc = i << 24
            for _ in range(8):
                crc = ((crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1) & 0xFFFFFFFF
            _CRC.append(crc)
    data = raw.replace(b'\0', b'') + b'\n'
    crc = 0
    for byte in data:
        crc = (crc << 8 & 0xFFFFFFFF) ^ _CRC[(crc >> 24) ^ byte]
    size = len(data)
    while size:
        crc = (crc << 8 & 0xFFFFFFFF) ^ _CRC[(crc >> 24) ^ (size & 0xFF)]
        size >>= 8
    return str(~crc & 0xFFFFFFFF)


def doc_bound():
    try:
        bound = float(os.getenv('CHIEF_WAIT_PENDING_DOC_TIMEOUT', '3'))
    except ValueError:
        bound = 0
    return bound if bound > 0 else 3.0


def read_lines(doc, bound):
    """The document's lines, numbered as the relay's `sed -n Np` addresses them (newline only), as text
    and as the raw bytes the relay's checksum sees, read within `bound` seconds. A read that blocks raises
    TimeoutError, an OSError the caller already treats as an unreadable document."""
    def expire(signum, frame):
        raise TimeoutError(f'no answer within {bound:g}s')
    handler = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, bound)
    try:
        data = doc.read_bytes()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, handler)
    raws = data.split(b'\n')
    lines = data.decode(errors='replace').split('\n')
    if lines[-1] == '':
        lines.pop()
        raws.pop()
    return lines, raws


def summarize(lines, raws):
    """Everything the decisions below need from a document, so an unchanged one need not be read again."""
    marks = [[n, m[1]] for n, line in enumerate(lines, 1) if (m := MARK.match(line))]
    ready = [[n, hashlib.sha256(lines[n - 1].encode()).hexdigest()] for n, marker in marks if marker == 'READY']
    sums = {str(n): checksum(raws[n - 1]) for n in sums_needed(marks, ready)}
    return dict(n=len(lines), marks=marks, ready=ready, sums=sums)


def sums_needed(marks, ready):
    # every READY (a replacement is judged by the newest, a refused one is paced by its own bullet) and the newest cleanup bullet
    return [n for n, _ in ready] + [n for n, marker in marks if marker != 'READY'][-1:]


def usable(record):
    try:
        return (isinstance(record['n'], int) and isinstance(record['marks'], list) and isinstance(record['ready'], list)
                and all(isinstance(record['sums'].get(str(n)), str)
                        for n in sums_needed(record['marks'], record['ready'])))
    except (KeyError, TypeError, IndexError, ValueError, AttributeError):
        return False


def stamp_of(doc):
    """What a file's identity and content are judged by without reading it, or None for anything but a regular file."""
    try:
        st = os.stat(doc)
    except OSError:
        return None
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns] if stat.S_ISREG(st.st_mode) else None


def unchanged(record, stamp):
    """True when the cached summary still stands for the file: every part of the stamp (device, inode, size,
    modification time, change time) is the one it was taken under, and the file was already older than RACY_NS
    when it was read. The change time cannot be set by a writer, so a rewrite or replacement that keeps size
    and modification time still moves it."""
    try:
        return (isinstance(stamp, list) and record['stamp'] == stamp and type(record['at']) is int
                and max(stamp[3], stamp[4]) + RACY_NS <= record['at'])
    except (KeyError, TypeError):
        return False


def retry_after(inbox, label, key):
    """Seconds a refused event is held back: the retry window, times the ladder's step for the count of
    refusals in a row the relay recorded for this event, whose key is its bullet's checksum. The relay owns the
    count; this only reads it. No count, a torn one, or a count kept for another event means the first step:
    a new or changed event starts the ladder over, lines appended to the document do not. This only spaces attempts."""
    base = float(os.getenv('CHIEF_WAIT_SERVICE_RETRY_SEC', '5'))
    try:
        fields = Path(f'{inbox}.wait.le-{label}.tries').read_text().split()
        count = int(fields[0])
    except (OSError, ValueError, IndexError):
        return base
    if count < 1 or len(fields) < 2 or fields[1] != key:
        return base
    return base * STEPS[min(count, len(STEPS)) - 1]


def refused(text):
    """A refusal that only means "not yet": lock held, tail not WRAPPED, subtree or subagent alive. Not a
    pr-state refusal, and not the wrap's own log or board step, which run after the window is closed."""
    return (re.search(r'^ESCALATE .*?-failed rc=[3467] ', text) is not None and 'step pr-state' not in text
            and 'wrap-merged: step log failed' not in text and 'wrap-merged: step board failed' not in text)


def write_if_changed(path, text):
    try:
        if path.read_text() == text:
            return
    except (OSError, ValueError):
        pass
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(text)
    os.replace(tmp, path)


def candidates(fleet, inbox, last):
    data = json.loads(Path(fleet).read_text())
    cursors = {}
    ready = Path(inbox + '.wait.ready')
    if ready.exists():
        for line in ready.read_text().splitlines():
            label, cursor = line.split('\t')
            cursors[label] = int(cursor)
    handled_path = Path(inbox + '.wait.r0')
    handled = set(handled_path.read_text().splitlines()) if handled_path.exists() else set()
    observed_path = Path(inbox + '.wait.ready-docs')
    observed = json.loads(observed_path.read_text()) if observed_path.exists() else {}
    current = {}
    events = []
    bound = doc_bound()
    summaries = {}
    keys = {}
    for worker in data.get('workers', data.get('legs', [])):
        label, doc = worker['label'], Path(worker['doc'])
        at = time.time_ns()
        stamp = stamp_of(doc)
        cached = observed.get(label, {}).get('read')
        if unchanged(cached, stamp) and usable(cached):
            summary = cached
        else:
            try:
                # a document already known unread gets a short look, so one blocked file costs a pass little
                lines, raws = read_lines(doc, min(bound, 0.5) if observed.get(label, {}).get('unread') else bound)
            except OSError as exc:
                print(f'pending-events: worker={label} doc={doc}: {exc}', file=sys.stderr)
                previous = observed.get(label, {})
                current[label] = dict(previous, unread=True)
                if not previous.get('unread'):
                    print('WARN', label, str(doc))
                continue
            summary = summarize(lines, raws)
            if stamp is not None:
                summary.update(stamp=stamp, at=at)
        summaries[label] = summary
        matches, ready_events = summary['marks'], summary['ready']
        previous = observed.get(label, {})
        if label in cursors and 'ready' not in previous and cursors[label] > summary['n']:
            # No snapshot and a cursor past the end: this is not the document the cursor
            # counted, so meet the worker as new instead of calling its READY handled.
            del cursors[label]
        cursor = cursors.get(label, 0)
        # Track the READY prefix already handled, independent of prose/line
        # shifts and atomic editors. Older snapshots migrate without replay.
        old_events = previous.get('ready', ready_events)
        handled_ready = [digest for n, digest in old_events if n <= cursor]
        last_handled = next((n for n, digest in reversed(ready_events)
                             if handled_ready and digest == handled_ready[-1]), None)
        replaced = bool(handled_ready) and last_handled is None
        first = label not in cursors or replaced
        if label in cursors and not replaced:
            # An empty sample cannot erase a legacy cursor before its first
            # usable snapshot. Prose and older READY edits do not move identity.
            if cursor and not old_events and not ready_events:
                current[label] = previous
                continue
            cursor = last_handled or 0
            cursors[label] = cursor
        # A sample that does not match the acknowledged snapshot is only a proposal: it never
        # replaces that snapshot here, whatever bullet the sample ends on.
        current[label] = dict(previous, unread=False) if replaced else dict(ready=ready_events)
        cleanup = [(n, marker) for n, marker in matches if marker != 'READY']
        # A WRAPPED/MERGED bullet is the worker's live cleanup only while no READY follows it
        # (the newest marker, as tick.sh reads tails= and acts=). A later READY is the event;
        # a READY before the newest cleanup bullet is moot: its PR is already done.
        floor = cleanup[-1][0] if cleanup else 0
        if cleanup and matches[-1][0] == floor:
            n, marker = cleanup[-1]
            digest = summary['sums'][str(n)]
            if f'{label} {marker} {digest}' not in handled:
                events.append((label, marker, n))
                keys[label] = digest
            continue
        if replaced:
            # A truncate/write sample is only a proposal. Keep the last
            # acknowledged snapshot/cursor until a stable candidate relays.
            current[label] = dict(previous, unread=False, replacement=ready_events)
            if previous.get('replacement') != ready_events:
                current[label]['replacement_known'] = bool(
                    ready_events and ready_events[-1][1] in handled_ready)
                continue
            if not ready_events or previous.get('replacement_known'):
                continue
            n = ready_events[-1][0]
            digest = summary['sums'][str(n)]
            if f'{label} READY {digest}' in handled:
                current[label] = dict(ready=ready_events)
                cursors[label] = n
                continue
            cursor = 0
        if worker.get('t3_kind') == 'ask':
            if ready_events:
                current[label] = dict(ready=ready_events)
                cursors[label] = ready_events[-1][0]
            continue
        pending = [
            (n, marker) for n, marker in matches if marker == 'READY' and n > max(cursor, floor)]
        if pending:
            n, marker = pending[-1] if first else pending[0]
            events.append((label, marker, n))
            keys[label] = summary['sums'][str(n)]
    for label, summary in summaries.items():
        current[label]['read'] = summary
    write_if_changed(observed_path, json.dumps(current))
    # A label that left the manifest keeps no cursor: if it returns with another document,
    # its READY is met as new rather than judged against a cursor that counted something else.
    write_if_changed(ready, ''.join(f'{label}\t{cursor}\n' for label, cursor in cursors.items() if label in current))
    pivot = next((i + 1 for i, event in enumerate(events) if event[0] == last), 0)
    for label, marker, n in events[pivot:] + events[:pivot]:
        output = Path(inbox + '.wait.le-' + label)
        # held only while the refusal is younger than the hold: a record dated in the future (a clock stepped back) is no proof of that
        if output.exists() and 0 <= time.time() - output.stat().st_mtime < retry_after(inbox, label, keys[label]):
            if refused(output.read_text()):
                continue
        print(label, marker, n)


if __name__ == '__main__':
    try:
        candidates(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print('pending-events: reconcile manifest/cursors: ' + str(exc), file=sys.stderr)
        sys.exit(2)
