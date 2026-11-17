"""Read pending local lifecycle events; execution stays in the existing relay."""
import json
import hashlib
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
    observed_path = Path(inbox + '.wait.ready-docs')
    observed = json.loads(observed_path.read_text()) if observed_path.exists() else {}
    current = {}
    events = []
    for worker in data.get('workers', data.get('legs', [])):
        label, doc = worker['label'], Path(worker['doc'])
        try:
            info = doc.stat()
            lines = doc.read_text(errors='replace').splitlines()
        except OSError as exc:
            print(f'pending-events: worker={label} doc={doc}: {exc}', file=sys.stderr)
            continue
        previous = observed.get(label)
        def digest(count):
            return hashlib.sha256('\n'.join(lines[:count]).encode()).hexdigest()
        identity = [str(doc), info.st_dev, info.st_ino]
        replaced = previous is not None and (previous['identity'] != identity or
                   previous['count'] > len(lines) or previous['digest'] != digest(previous['count']))
        current[label] = dict(identity=identity, count=len(lines), digest=digest(len(lines)))
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
            first = label not in cursors or replaced or cursors[label] > len(lines)
            cursor = 0 if first else cursors[label]
            pending = [(n, marker) for n, marker in matches if n > cursor]
            if pending:
                n, marker = pending[-1] if first else pending[0]
                events.append((label, marker, n))
    tmp = observed_path.with_suffix(observed_path.suffix + '.tmp')
    tmp.write_text(json.dumps(current))
    os.replace(tmp, observed_path)
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
