#!/usr/bin/python3 -I
"""afk-sudo — run one allowlisted privileged command after a Telegram TOTP approval.

Installed root-owned to /usr/local/libexec/himmel/afk-sudo by install.sh and
reached through one sudoers NOPASSWD rule that names that copy, never this repo
file (a repo file is agent-writable). Off by default: the station config ships
`"enabled": false` with an empty allowlist.

  afk-sudo request --session S --ticket T --cwd DIR -- ARGV...
  afk-sudo approve ID --from SENDER --chat CHAT      (the code is read from stdin)
  afk-sudo deny ID --from SENDER --chat CHAT
  afk-sudo status ID

Prints `result=<word> …` lines. Exit 0 ok, 5 refused, 2 usage.
Test seam: AFK_SUDO_ROOT (a sandbox root) and AFK_SUDO_NOW (epoch seconds) are
honoured only when euid != 0; there the files must be owned by the caller
instead of root. Outside the seam a non-root run is refused.
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import approval_broker as ab  # noqa: E402

RUN_TIMEOUT_S = 120
SEAM = os.geteuid() != 0 and bool(os.environ.get("AFK_SUDO_ROOT"))
ROOT = os.environ["AFK_SUDO_ROOT"] if SEAM else "/"
OWNER = os.geteuid() if SEAM else 0
CONFIG = os.path.join(ROOT, "etc/himmel/afk-sudo.json")
SEED = os.path.join(ROOT, "etc/himmel/afk-sudo/totp.seed")
STATE = os.path.join(ROOT, "var/lib/himmel/afk-sudo")
LEDGER = os.path.join(ROOT, "var/log/himmel/afk-sudo.jsonl")


def now():
    if SEAM and os.environ.get("AFK_SUDO_NOW"):
        return float(os.environ["AFK_SUDO_NOW"])
    return time.time()


def clean(s, n=200):
    return "".join(c if c.isprintable() else "?" for c in str(s))[:n]


def match_class(config, argv):
    """(class name, argv to run) for the one class argv matches exactly, else None."""
    classes = config.get("classes")
    if not isinstance(classes, dict):
        return None
    for name, cls in classes.items():
        tpl = cls.get("argv") if isinstance(cls, dict) else None
        units = cls.get("unit", []) if isinstance(cls, dict) else []
        if not isinstance(tpl, list) or not tpl or not all(isinstance(a, str) for a in tpl) or not tpl[0].startswith("/"):
            continue
        if len(argv) != len(tpl) or argv[0] not in (tpl[0], os.path.basename(tpl[0])):
            continue
        run = [tpl[0]]
        for want, got in zip(tpl[1:], argv[1:]):
            if want == "{unit}" and isinstance(units, list) and got in units:
                run.append(got)
            elif want != "{unit}" and want == got:
                run.append(got)
            else:
                break
        else:
            return name, run
    return None


def execute(payload):
    try:
        return subprocess.run(payload["argv"], cwd="/", env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"},
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=RUN_TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        return 124
    except OSError:
        return 127


def main(argv):
    p = argparse.ArgumentParser(prog="afk-sudo")
    sub = p.add_subparsers(dest="verb", required=True)
    r = sub.add_parser("request")
    r.add_argument("--session", required=True)
    r.add_argument("--ticket", required=True)
    r.add_argument("--cwd", required=True)
    r.add_argument("cmd", nargs=argparse.REMAINDER)
    for verb in ("approve", "deny"):
        a = sub.add_parser(verb)
        a.add_argument("id")
        a.add_argument("--from", dest="sender", type=int, required=True)
        a.add_argument("--chat", type=int, required=True)
    sub.add_parser("status").add_argument("id")
    args = p.parse_args(argv)

    if os.geteuid() != 0 and not SEAM:
        print("result=not-root")
        return 5
    try:
        ab.check_safe(CONFIG, OWNER)
        with open(CONFIG) as f:
            config = json.load(f)
        if config.get("enabled") is not True:
            print("result=disabled")
            return 5
        broker = ab.Broker(STATE, LEDGER, SEED, config["operator_id"], config.get("window_s", 120), OWNER, now)
        if args.verb == "request":
            cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
            meta = {"session": clean(args.session), "ticket": clean(args.ticket), "cwd": clean(args.cwd, 500)}
            hit = match_class(config, cmd)
            if not hit:
                ab.append_row(LEDGER, dict(meta, ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now())),
                                           event="request", result="off-allowlist", argv=[clean(a) for a in cmd]), OWNER)
                print("result=off-allowlist")
                return 5
            name, run = hit
            meta.update({"class": name, "argv": run})
            shown = " ".join(run)
            rid, expires = broker.request("sudo", shown, {"argv": run}, meta)
            print(f"result=pending id={rid} expires={expires} operator={int(config['operator_id'])}")
            print(f"text=AFK sudo request {rid}: {shown} | cwd {meta['cwd']} | session {meta['session']} | "
                  f"ticket {meta['ticket']} | expires in {int(config.get('window_s', 120))} s. "
                  f"Reply: approve {rid} <code>  or  deny {rid}")
        elif args.verb == "approve":
            code = sys.stdin.readline().strip()
            pending, rc = broker.approve(args.id, code, args.sender, args.chat, execute)
            print(f"result=ran id={args.id} exit={rc} argv={pending['display']}")
        elif args.verb == "deny":
            broker.deny(args.id, args.sender, args.chat)
            print(f"result=denied id={args.id}")
        else:
            print(f"result={broker.status(args.id)} id={args.id}")
        return 0
    except ab.Refused as e:
        print(f"result={e.result}" + (f" id={args.id}" if getattr(args, "id", None) else "") + (f" path={e.detail}" if e.result == "unsafe-perms" else ""))
        return 5
    except (OSError, ValueError, KeyError) as e:
        print(f"result=error {type(e).__name__}")
        return 5


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
