"""Read pending local lifecycle events; execution stays in the existing relay."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


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
    events = []
    for worker in data.get('workers', data.get('legs', [])):
        label, doc = worker['label'], Path(worker['doc'])
        try:
            lines = doc.read_text().splitlines()
        except FileNotFoundError:
            continue
        matches = [(n, m[1]) for n, line in enumerate(lines, 1)
                   if (m := re.match(r'^- (?:\d{1,2}:\d{2} )?(?:\*\*)?(READY|WRAPPED|MERGED)(?:[^A-Za-z]|$)', line))]
        cleanup = [(n, marker) for n, marker in matches if marker != 'READY']
        if cleanup:
            n, marker = cleanup[-1]
            checksum = subprocess.run(['cksum'], input=lines[n - 1] + '\n',
                                      text=True, capture_output=True, check=True).stdout.split()[0]
            if f'{label} {marker} {checksum}' in handled:
                continue
            events.append((label, marker, n))
        else:
            cursor = cursors.get(label, 0)
            if cursor > len(lines):
                cursor = 0
            pending = [(n, marker) for n, marker in matches if n > cursor]
            if pending:
                n, marker = pending[0]
                events.append((label, marker, n))
    pivot = next((i + 1 for i, event in enumerate(events) if event[0] == last), 0)
    for label, marker, n in events[pivot:] + events[:pivot]:
        output = Path(inbox + '.wait.le-' + label)
        if output.exists() and time.time() - output.stat().st_mtime < float(os.getenv('CHIEF_WAIT_SERVICE_RETRY_SEC', '5')):
            text = output.read_text()
            if re.search(r'^ESCALATE .*?-failed rc=[3467] ', text) and 'step pr-state' not in text:
                continue
        print(label, marker, n)


if __name__ == '__main__':
    candidates(*sys.argv[1:])
