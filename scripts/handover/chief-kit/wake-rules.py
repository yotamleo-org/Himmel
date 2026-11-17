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


def run(inbox, doc, release_root, tick, now=None):
    now = time.time() if now is None else now
    fields = dict(word.split('=', 1) for word in tick.split() if '=' in word)
    for field, extract, wake, minutes, marker, clears in rules():
        if marker not in ('station', 'repair', 'rmqueue', 'mon'):
            continue
        value = fields.get(field, '')
        file = Path(inbox + '.wait.rule-' + marker)
        if value in ('?', 'skip'):
            continue
        active = False
        detail = value
        if marker == 'station':
            active = value.startswith(extract + ':')
        elif marker == 'repair':
            prefix, reasons = extract.split(':', 1)
            active = value in [prefix + ':' + reason for reason in reasons.split(',')]
            if active:
                release = re.search(r'^release:\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*$', Path(doc).read_text(), re.M) if doc else None
                remedy = ''
                if release and release_root:
                    try:
                        remedy = json.loads((Path(release_root) / release[1] / 'repair-state.json').read_text()).get('operator_command') or ''
                    except (OSError, ValueError):
                        pass
                detail += ' remedy=' + (re.sub(r'[\r\n\t]', ' ', str(remedy)) if remedy else 'unavailable; reconcile CLI-owned repair-state record')
        elif marker == 'rmqueue':
            match = re.match(r'([1-9][0-9]*),([0-9]+)m(?:,|$)', value)
            active = bool(match and int(match[2]) * 60 > 2 * int(os.getenv('TICK_RMRUN_MIN_SECS', '600')))
            detail = 'rm-queue=' + value
        elif marker == 'mon':
            if not value:
                monitor = Path(os.getenv('TICK_MONITOR_STATE') or
                               str(Path(os.getenv('BRIDGE_ROOT') or str(Path.home() / '.claude/handover/bridge')) / 'monitor/state'))
                try:
                    if monitor.read_text().strip() != 'ok':
                        continue
                except OSError:
                    continue
            active = value.isdecimal()
            detail = 'monitor down since=' + value + '; inspect bridge monitor/state and monitoring bot/group wiring'
        if not active:
            file.unlink(missing_ok=True)
            continue
        reminder = float(os.getenv('CHIEF_WAIT_' + marker.upper() + '_REWAKE_MIN', minutes))
        signature = value if marker != 'rmqueue' else 'aged'
        if marker == 'mon':
            signature = 'down'
        # Include the persisted repair remedy: a corrected unblocking command
        # is actionable even while repair remains off.
        if marker == 'repair':
            signature = detail
        if file.exists() and file.read_text().strip() == signature and (not reminder or now - file.stat().st_mtime < reminder * 60):
            continue
        file.write_text(signature + '\n')
        print('WAKE ' + (field if marker != 'mon' else 'mon') + ' ' + detail)
        return True
    return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inbox', required=True)
    parser.add_argument('--doc', default='')
    parser.add_argument('--release-root', default='')
    args = parser.parse_args()
    sys.exit(0 if run(args.inbox, args.doc, args.release_root, sys.stdin.read()) else 1)
