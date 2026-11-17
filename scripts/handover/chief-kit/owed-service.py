"""Service existing owed delivery actions; semantic proof decisions stay chief-owned."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def owe(bucket, *args):
    return subprocess.run(['bash', str(HERE / 'owe.sh'), *args, '--bucket', str(bucket)],
                          text=True, capture_output=True, timeout=10)


def receipt(doc, key):
    match = re.search(r'^- (?:[0-9]{1,2}:[0-9]{2} )?DELIVERED ' + re.escape(key) +
                      r' msg=([1-9][0-9]*) chat=-?[0-9]+(?: .*)?$', doc.read_text(), re.M)
    return match[1] if match else None


def run(inbox, doc, chief):
    bucket = doc.parent
    result = owe(bucket, 'list', '--json')
    if result.returncode:
        raise ValueError(result.stderr)
    rows = json.loads(result.stdout)
    notes, chief_ids = [], []
    for row in rows:
        if row.get('action') == 'validate-proof' and row.get('validation') == 'pending':
            notes.append(row['id'] + ' proof-validation-pending ' + row['text'])
        elif row.get('action') == 'notify' and row.get('actor') == 'chief':
            chief_ids.append(row['id'])
            notes.append(row['id'] + ' notification-pending ' + row['text'])
    for row in rows:
        if row.get('action') != 'notify' or row.get('actor') != 'operator':
            continue
        key = 't2-' + row['id']
        delivered = receipt(doc, key)
        attempt = Path(inbox + '.wait.operator-' + row['id'])
        if not delivered and (not attempt.exists() or time.time() - attempt.stat().st_mtime >= float(os.getenv('CHIEF_WAIT_OPERATOR_RETRY_SEC', '60'))):
            attempt.touch()
            opts = ['--chief', chief, '--owed', key, '--doc', str(doc), 'operator', row['text']]
            sender = os.getenv('CHIEF_WAIT_OWED_SEND')
            if sender:
                command = [sender, *opts]
            elif os.getenv('HIMMEL_TEST_FIXTURE') == '1':
                command = None
            else:
                command = ['bun', str(HERE / '../../telegram/chief-route.ts'), 'reply', *opts]
            if command:
                try:
                    subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                   text=True, timeout=35)
                except (OSError, subprocess.TimeoutExpired):
                    pass
                # Queueing/draining/exit zero is insufficient. The existing
                # sender writes this only from the bridge's actual send receipt.
                delivered = receipt(doc, key)
        if delivered:
            closed = owe(bucket, 'close', '--id', row['id'], '--key', 'telegram-msg-' + delivered)
            if closed.returncode == 0:
                attempt.unlink(missing_ok=True)
                continue
        notes.append(row['id'] + ' operator-delivery-pending ' + row['text'])
        # One bounded operator attempt per service pass; other lifecycle work
        # and the inbox run before any retry or next digest item.
        break
    stamp = Path(inbox + '.wait.owed-service')
    signature = '\n'.join(notes)
    if not signature:
        stamp.unlink(missing_ok=True)
        return False
    if stamp.exists() and stamp.read_text() == signature:
        return False
    stamp.write_text(signature)
    print('WAKE owed-actions chief-notify=' + (','.join(chief_ids) or 'none'))
    print('owed-bucket=' + str(bucket))
    print(signature)
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inbox', required=True)
    parser.add_argument('--doc', required=True)
    parser.add_argument('--chief', required=True)
    args = parser.parse_args()
    try:
        sys.exit(0 if run(args.inbox, Path(args.doc), args.chief) else 1)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print('owed-service: ' + str(exc), file=sys.stderr)
        stamp = Path(args.inbox + '.wait.owed-service')
        signature = 'unread owed ledger'
        if stamp.exists() and stamp.read_text() == signature:
            sys.exit(1)
        stamp.write_text(signature)
        print('WAKE owed-actions-unread reconcile ' + str(Path(args.doc).parent / 'owed.jsonl'))
        sys.exit(0)
