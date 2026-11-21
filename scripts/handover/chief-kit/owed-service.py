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
    attempted = False
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
        opts = ['--chief', chief, '--owed', key, '--doc', str(doc), '--kind', 'chief-reply', 'operator', row['text']]
        sender = os.getenv('CHIEF_WAIT_OWED_SEND')
        def helper(verb):
            if sender:
                return [sender, *opts] if verb == 'reply' else None
            if os.getenv('HIMMEL_TEST_FIXTURE') == '1':
                return None
            return ['bun', str(HERE / '../../telegram/chief-route.ts'), verb, *opts]
        def invoke(command):
            if command:
                try:
                    subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                   text=True, timeout=2,
                                   env=dict(os.environ, CHIEF_ROUTE_RECEIPT_WAIT_SEC='0'))
                except (OSError, subprocess.TimeoutExpired):
                    pass
        # Receipt reconciliation never enqueues, and is independent of the
        # send-attempt bound (including the longest outage backoff).
        if not delivered:
            invoke(helper('receipt'))
            delivered = receipt(doc, key)
        if delivered:
            closed = owe(bucket, 'close', '--id', row['id'], '--key', 'telegram-msg-' + delivered)
            if closed.returncode == 0:
                attempt.unlink(missing_ok=True)
                continue
        try:
            retry = json.loads(attempt.read_text() or '{}') if attempt.exists() else {}
            if (not isinstance(retry, dict) or type(retry.get('attempts', 0)) is not int or
                    not 0 <= retry.get('attempts', 0) <= 6 or
                    any(type(retry.get(k, 0)) not in (int, float) or not 0 <= retry.get(k, 0) < float('inf')
                        for k in ('next', 'first'))):
                raise ValueError('invalid operator retry state')
        except (OSError, ValueError) as exc:
            notes.append(row['id'] + ' operator-state-unread reconcile=' + str(attempt) + ' ' + str(exc))
            continue
        # Older markers were empty files; their mtime still bounds the first retry.
        next_try = retry.get('next', attempt.stat().st_mtime + float(os.getenv('CHIEF_WAIT_OPERATOR_RETRY_SEC', '60')) if attempt.exists() else 0)
        if not delivered and not attempted and time.time() >= next_try:
            count = min(6, retry.get('attempts', 0) + 1)
            retry.update(attempts=count, next=time.time() + min(1800, float(os.getenv('CHIEF_WAIT_OPERATOR_RETRY_SEC', '60')) * 2 ** (count - 1)))
            retry.setdefault('first', attempt.stat().st_mtime if attempt.exists() else time.time())
            # The helper only enqueues/reconciles an identity. It never waits for
            # the poller here; delayed receipts are checked on a later pass.
            try:
                attempt.write_text(json.dumps(retry))
            except OSError as exc:
                notes.append(row['id'] + ' operator-state-unwritable reconcile=' + str(attempt) + ' ' + str(exc))
                continue
            attempted = True
            invoke(helper('reply'))
            delivered = receipt(doc, key)
        if delivered:
            closed = owe(bucket, 'close', '--id', row['id'], '--key', 'telegram-msg-' + delivered)
            if closed.returncode == 0:
                attempt.unlink(missing_ok=True)
                continue
        first = retry.get('first', attempt.stat().st_mtime if attempt.exists() else 0)
        if time.time() - first >= float(os.getenv('CHIEF_WAIT_OPERATOR_GRACE_SEC', '30')):
            notes.append(row['id'] + ' operator-delivery-pending ' + row['text'])
    stamp = Path(inbox + '.wait.owed-service')
    signature = '\n'.join(notes)
    if not signature:
        stamp.unlink(missing_ok=True)
        return False
    if (stamp.exists() and stamp.read_text() == signature and
            time.time() - stamp.stat().st_mtime < float(os.getenv('CHIEF_WAIT_NOTIFY_REWAKE_MIN', '60')) * 60):
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
