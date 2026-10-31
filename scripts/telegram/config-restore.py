#!/usr/bin/env python3
"""config-restore — the operator's TOTP-gated station config restore.

The Telegram bridge runs this from its own process for `/config backups` and
`/config restore <id> <code>`; a session never does (block-himmel-config-writes.sh
refuses `config-restore.py restore|enroll` and `config-audit.sh restore|accept`).

  config-restore.py enroll [--force]        new seed; prints the otpauth URI ONCE
  config-restore.py list                    the backups, newest first, key names only
  config-restore.py restore <backup-id> --from <sender> --chat <chat>
                                            the code on stdin, never argv

The code check is approval_broker (the AFK sudo broker), imported read-only: one pending
request, a used step is spent, 3 wrong codes lock it for 15 minutes, only the
operator id recorded at enroll, sending from their own private chat. The restore
itself is `config-audit.sh restore`: it backs up the live set first and writes
an audit row per file. Output carries key names, never a value.

ponytail: the seed is a file of the same uid as the sessions, so a session that
reads it can mint a code; the TOTP defends against a forged or hijacked Telegram
sender, not a local process. Upgrade path: a root-owned config-restore kind of
the afk-sudo helper (scripts/lib/afk-sudo), once that lands.

Paths: ${HIMMEL_CONFIG_DIR:-~/.himmel}/secrets/config-restore.seed (600) and
${HIMMEL_CONFIG_DIR:-~/.himmel}/state/config-restore-mfa/ (700: state.json,
ledger.jsonl, operator.json). Seams (tests): TELEGRAM_ACCESS_PATH, and
CONFIG_RESTORE_NOW honoured only under HIMMEL_TEST_FIXTURE=1.
"""
import argparse
import base64
import json
import os
import secrets
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib", "afk-sudo"))
import approval_broker as ab  # noqa: E402

AUDIT = os.path.join(HERE, "..", "lib", "config-audit.sh")
STATION = os.environ.get("HIMMEL_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".himmel")
SEED = os.path.join(STATION, "secrets", "config-restore.seed")
STATE = os.path.join(STATION, "state", "config-restore-mfa")
OPERATOR = os.path.join(STATE, "operator.json")
WINDOW_S = 120


def now():
    if os.environ.get("HIMMEL_TEST_FIXTURE") == "1" and os.environ.get("CONFIG_RESTORE_NOW"):
        return float(os.environ["CONFIG_RESTORE_NOW"])
    return time.time()


def operator_from_access():
    path = os.environ.get("TELEGRAM_ACCESS_PATH") or os.path.join(
        os.path.expanduser("~"), ".claude", "channels", "telegram", "access.json")
    with open(path) as f:
        allow = json.load(f).get("allowFrom") or []
    for x in map(str, allow):
        if x.isdigit() and not x.startswith("0"):
            return int(x)
    raise SystemExit("config-restore: no numeric operator id in allowFrom of " + path)


def mkdir700(d):
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)


def write600(path, text, exclusive):
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(path, 0o600)


def enroll(force):
    if os.path.lexists(SEED) and not force:
        print("result=already-enrolled (pass --force to replace the seed; the old code stops working)")
        return 1
    op = operator_from_access()
    mkdir700(os.path.dirname(SEED))
    mkdir700(STATE)
    if force and os.path.lexists(SEED):
        os.unlink(SEED)
    seed = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    write600(SEED, seed + "\n", exclusive=True)
    write600(OPERATOR, json.dumps({"operator_id": op}) + "\n", exclusive=False)
    print("Add this to your authenticator app, then clear the terminal (shown once):")
    print(f"otpauth://totp/himmel-config-restore:{os.uname().nodename}?secret={seed}&issuer=himmel")
    print(f"result=enrolled operator={op}")
    return 0


def broker():
    with open(OPERATOR) as f:
        op = int(json.load(f)["operator_id"])
    return ab.Broker(STATE, os.path.join(STATE, "ledger.jsonl"), SEED, op, window_s=WINDOW_S,
                     owner=os.getuid(), now=now)


def list_backups():
    r = subprocess.run(["bash", AUDIT, "list"], capture_output=True, text=True, timeout=60)
    sys.stdout.write(r.stdout)
    return r.returncode


def restore(bid, code, sender, chat):
    if not (os.path.lexists(SEED) and os.path.lexists(OPERATOR)):
        print("result=refused reason=not-enrolled")
        return 1
    out = {}

    def executor(payload):
        r = subprocess.run(["bash", AUDIT, "restore", payload["backup"], "--script", "config-restore.py"],
                           capture_output=True, text=True, timeout=120)
        out["text"] = r.stdout.strip()
        return {"result": "ran", "exit": r.returncode}

    try:
        b = broker()
        # Checked before a request opens: a refused sender must not hold the one
        # pending slot and lock the operator out for the window.
        if int(sender) != b.operator_id or int(chat) != b.operator_id:
            ab.append_row(b.ledger, {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now())), "event": "request",
                                     "result": "not-operator", "kind": "config-restore", "backup": bid,
                                     "sender": int(sender), "chat": int(chat)}, b.owner)
            raise ab.Refused("not-operator")
        # The request opens and is approved in this one call, from the operator's own
        # typed message: no notice is sent that a look-alike could copy, so the nonce
        # is passed straight back.
        rid, _, nonce = b.request("config-restore", f"restore {bid}", {"backup": bid},
                                  {"backup": bid, "session": f"telegram:{int(chat)}"})
        _, res = b.approve(rid, code, sender, chat, executor, nonce=nonce)
    except ab.Refused as e:
        print(f"result=refused reason={e.result}")
        return 1
    print(out.get("text") or f"result=failed exit={res['exit']}")
    return 0 if res["exit"] == 0 else 1


def main(argv):
    p = argparse.ArgumentParser(prog="config-restore")
    sub = p.add_subparsers(dest="verb", required=True)
    e = sub.add_parser("enroll")
    e.add_argument("--force", action="store_true")
    sub.add_parser("list")
    r = sub.add_parser("restore")
    r.add_argument("backup")
    r.add_argument("--from", dest="sender", type=int, required=True)
    r.add_argument("--chat", type=int, required=True)
    a = p.parse_args(argv)
    if a.verb == "enroll":
        return enroll(a.force)
    if a.verb == "list":
        return list_backups()
    code = sys.stdin.readline().strip()
    return restore(a.backup, code, a.sender, a.chat)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
