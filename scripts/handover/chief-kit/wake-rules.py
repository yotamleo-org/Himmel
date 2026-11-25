"""Table-driven entry/reminder rules; legacy specialized rules keep their readers."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time

HERE = Path(__file__).resolve().parent


def rules():
    return [line.split('\t') for line in (HERE / 'wake-rules.tsv').read_text().splitlines()
            if line and not line.startswith('#')]


def rmrun_gap():
    """TICK_RMRUN_MIN_SECS as the tick reads it: digits only, else the tick's default 600."""
    value = os.getenv('TICK_RMRUN_MIN_SECS', '600')
    return int(value) if re.fullmatch('[0-9]+', value) else 600


def remedy_of(doc, release_root):
    """The persisted operator command; '' when the doc or the record is unreadable or not an object."""
    try:
        release = re.search(r'^release:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*$', Path(doc).read_text(), re.M) if doc else None
        if not (release and release_root):
            return ''
        record = json.loads((Path(release_root) / release[1] / 'repair-state.json').read_text())
    except (OSError, ValueError):
        return ''
    return (record.get('operator_command') or '') if isinstance(record, dict) else ''


def wake_for(row, fields, inbox, doc, release_root, gap, now):
    """Print this rule's wake and return True when it is due."""
    field, extract, wake, minutes, marker, clears = row
    if marker not in ('station', 'repair', 'rmqueue', 'mon'):
        return False
    value = fields.get(field, '')
    file = Path(inbox + '.wait.rule-' + marker)
    if value in ('?', 'skip'):
        return False
    active = False
    detail = value
    if marker == 'station':
        active = value.startswith(extract + ':')
    elif marker == 'repair':
        prefix, reasons = extract.split(':', 1)
        active = value in [prefix + ':' + reason for reason in reasons.split(',')]
        if active:
            remedy = remedy_of(doc, release_root)
            detail += ' remedy=' + (re.sub(r'[\r\n\t]', ' ', str(remedy)) if remedy else 'unavailable; reconcile CLI-owned repair-state record')
    elif marker == 'rmqueue':
        match = re.match(r'([1-9][0-9]*),([0-9]+)m(?:,|$)', value)
        active = bool(match and int(match[2]) * 60 > 2 * gap)
        detail = 'rm-queue=' + value
    elif marker == 'mon':
        if not value:
            monitor = Path(os.getenv('TICK_MONITOR_STATE') or
                           str(Path(os.getenv('BRIDGE_ROOT') or str(Path.home() / '.claude/handover/bridge')) / 'monitor/state'))
            try:
                if monitor.read_text().strip() != 'ok':
                    return False
            except OSError:
                return False
        active = value.isdecimal()
        detail = 'monitor down since=' + value + '; inspect bridge monitor/state and monitoring bot/group wiring'
    if not active:
        file.unlink(missing_ok=True)
        return False
    reminder = float(os.getenv('CHIEF_WAIT_' + marker.upper() + '_REWAKE_MIN', minutes))
    signature = value if marker != 'rmqueue' else 'aged'
    if marker == 'mon':
        signature = 'down'
    # Include the persisted repair remedy: a corrected unblocking command
    # is actionable even while repair remains off.
    if marker == 'repair':
        signature = detail
    if file.exists() and file.read_text().strip() == signature and (not reminder or now - file.stat().st_mtime < reminder * 60):
        return False
    file.write_text(signature + '\n')
    print('WAKE ' + (field if marker != 'mon' else 'mon') + ' ' + detail)
    return True


def run(inbox, doc, release_root, tick, now=None):
    now = time.time() if now is None else now
    fields = dict(word.split('=', 1) for word in tick.split() if '=' in word)
    gap = rmrun_gap()
    errors = []
    for row in rules():
        error_file = Path(inbox + '.wait.rule-error-' + row[0])
        try:
            woke = wake_for(row, fields, inbox, doc, release_root, gap, now)
        except Exception as error:
            errors.append((error_file, 'rule=' + row[0] + ' error=' + type(error).__name__))
            continue
        error_file.unlink(missing_ok=True)
        if woke:
            return True
    for error_file, signature in errors:
        if error_file.exists() and error_file.read_text().strip() == signature:
            continue
        error_file.write_text(signature + '\n')
        print('WAKE waiter-error wake-rules ' + signature)
        return True
    return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inbox', required=True)
    parser.add_argument('--doc', default='')
    parser.add_argument('--release-root', default='')
    args = parser.parse_args()
    sys.exit(0 if run(args.inbox, args.doc, args.release_root, sys.stdin.read()) else 1)
