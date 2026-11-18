"""Read pending local lifecycle events; execution stays in the existing relay."""
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def checksum(line):
    return subprocess.run(['cksum'], input=line + '\n', text=True,
                          capture_output=True, check=True).stdout.split()[0]


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
    for worker in data.get('workers', data.get('legs', [])):
        label, doc = worker['label'], Path(worker['doc'])
        try:
            lines = doc.read_text(errors='replace').splitlines()
        except OSError as exc:
            print(f'pending-events: worker={label} doc={doc}: {exc}', file=sys.stderr)
            previous = observed.get(label, {})
            current[label] = dict(previous, unread=True)
            if not previous.get('unread'):
                print('WARN', label, str(doc))
            continue
        matches = [(n, m[1]) for n, line in enumerate(lines, 1)
                   if (m := re.match(r'^- (?:\d{1,2}:\d{2} )?(?:\*\*)?(READY|WRAPPED|MERGED)(?:[^A-Za-z]|$)', line))]
        ready_events = [[n, hashlib.sha256(lines[n - 1].encode()).hexdigest()]
                        for n, marker in matches if marker == 'READY']
        previous = observed.get(label, {})
        if label in cursors and 'ready' not in previous and cursors[label] > len(lines):
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
        current[label] = dict(ready=ready_events)
        cleanup = [(n, marker) for n, marker in matches if marker != 'READY']
        # A WRAPPED/MERGED bullet is the worker's live cleanup only while no READY follows it
        # (the newest marker, as tick.sh reads tails= and acts=). A later READY is the event;
        # a READY before the newest cleanup bullet is moot: its PR is already done.
        floor = cleanup[-1][0] if cleanup else 0
        if cleanup and matches[-1][0] == floor:
            n, marker = cleanup[-1]
            if f'{label} {marker} {checksum(lines[n - 1])}' not in handled:
                events.append((label, marker, n))
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
            if f'{label} READY {checksum(lines[n - 1])}' in handled:
                current[label] = dict(ready=ready_events)
                cursors[label] = n
                continue
            cursor = 0
        pending = [(n, marker) for n, marker in matches if marker == 'READY' and n > max(cursor, floor)]
        if pending:
            n, marker = pending[-1] if first else pending[0]
            events.append((label, marker, n))
    tmp = observed_path.with_suffix(observed_path.suffix + '.tmp')
    tmp.write_text(json.dumps(current))
    os.replace(tmp, observed_path)
    tmp = ready.with_suffix(ready.suffix + '.tmp')
    # A label that left the manifest keeps no cursor: if it returns with another document,
    # its READY is met as new rather than judged against a cursor that counted something else.
    tmp.write_text(''.join(f'{label}\t{cursor}\n' for label, cursor in cursors.items() if label in current))
    os.replace(tmp, ready)
    pivot = next((i + 1 for i, event in enumerate(events) if event[0] == last), 0)
    for label, marker, n in events[pivot:] + events[:pivot]:
        output = Path(inbox + '.wait.le-' + label)
        if output.exists() and time.time() - output.stat().st_mtime < float(os.getenv('CHIEF_WAIT_SERVICE_RETRY_SEC', '5')):
            text = output.read_text()
            if re.search(r'^ESCALATE .*?-failed rc=[3467] ', text) and 'step pr-state' not in text:
                continue
        print(label, marker, n)


if __name__ == '__main__':
    try:
        candidates(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print('pending-events: reconcile manifest/cursors: ' + str(exc), file=sys.stderr)
        sys.exit(2)
