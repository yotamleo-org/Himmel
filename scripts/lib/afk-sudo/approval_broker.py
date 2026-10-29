"""approval_broker — one-shot operator approvals gated by a TOTP code.

The core afk_sudo.py uses, built to be reused by other approval kinds. It holds no executor: the
caller passes one to approve(). Every file it reads or writes must be owned by
`owner` (uid 0 in production) and not group- or world-writable; the seed must
not be group- or world-readable either. Anything else refuses `unsafe-perms`.

State (pending slot, replay step, lockout, request times, recent outcomes) is
one JSON file under a flock. The ledger is JSONL, one row per event, and never
holds the code or the seed.

ponytail: one pending request per station; upgrade path is a slot per request
id once one station runs several AFK sessions that each need approval.
"""
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import stat
import struct
import time

STEP_S = 30
DIGITS = 6
MAX_WRONG = 3
LOCK_S = 900
MAX_PER_HOUR = 6
KEEP_DONE = 20
ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"


class Refused(Exception):
    def __init__(self, result, detail=""):
        super().__init__(result)
        self.result = result
        self.detail = detail


def totp(seed_b32, step):
    """RFC 6238 code (HMAC-SHA1, 6 digits) for a 30-second step index."""
    key = base64.b32decode(seed_b32.upper() + "=" * (-len(seed_b32) % 8))
    mac = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    n = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % 10 ** DIGITS
    return str(n).zfill(DIGITS)


def check_safe(path, owner, kind="file", secret=False):
    """Refuse unless path is a real file/dir owned by `owner`, no group/world write."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise Refused("unsafe-perms", f"{path} missing")
    want = stat.S_ISDIR if kind == "dir" else stat.S_ISREG
    bad = 0o077 if secret else 0o022
    if not want(st.st_mode) or st.st_uid != owner or st.st_mode & bad:
        raise Refused("unsafe-perms", path)


def append_row(path, row, owner):
    """Append one JSON row to an append-only ledger (the shared row writer)."""
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    try:
        st = os.fstat(fd)
        if st.st_uid != owner or st.st_mode & 0o022:
            raise Refused("unsafe-perms", path)
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps(row, sort_keys=True) + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)


class Broker:
    def __init__(self, state_dir, ledger, seed_path, operator_id, window_s=120, owner=0, now=time.time):
        self.state_dir, self.ledger, self.seed_path = state_dir, ledger, seed_path
        self.operator_id, self.window_s, self.owner, self.now = int(operator_id), int(window_s), owner, now
        self.state_path = os.path.join(state_dir, "state.json")
        for d in (state_dir, os.path.dirname(ledger), os.path.dirname(seed_path)):
            check_safe(d, owner, kind="dir")
        check_safe(seed_path, owner, secret=True)
        if os.path.lexists(ledger):
            check_safe(ledger, owner)

    # --- state under one flock ---
    def _locked(self):
        fd = os.open(os.path.join(self.state_dir, "lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def _load(self):
        if os.path.lexists(self.state_path):
            check_safe(self.state_path, self.owner)
            with open(self.state_path) as f:
                return json.load(f)
        return {"pending": None, "last_step": -1, "wrong": 0, "locked_until": 0, "requests": [], "done": {}}

    def _save(self, s):
        tmp = self.state_path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(s, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.state_path)

    def _row(self, event, result, meta=None, **extra):
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.now())), "event": event, "result": result}
        row.update(meta or {})
        row.update(extra)
        append_row(self.ledger, row, self.owner)

    def _finish(self, s, rid, outcome):
        s["done"][rid] = outcome
        for old in list(s["done"])[:-KEEP_DONE]:
            del s["done"][old]

    def _expire(self, s, t):
        p = s["pending"]
        if p and t > p["expires"]:
            self._finish(s, p["id"], "expired")
            s["pending"] = None
            self._row("expire", "expired", p["meta"], id=p["id"])

    def _refuse(self, event, result, meta, **extra):
        self._row(event, result, meta, **extra)
        raise Refused(result)

    # --- API ---
    def request(self, kind, display, payload, meta):
        """Open the one pending slot; returns (id, expires). Raises Refused."""
        fd = self._locked()
        try:
            s, t = self._load(), self.now()
            meta = dict(meta, kind=kind)
            if t < s["locked_until"]:
                self._refuse("request", "locked", meta)
            self._expire(s, t)
            if s["pending"]:
                self._save(s)
                self._refuse("request", "busy", meta)
            s["requests"] = [r for r in s["requests"] if t - r < 3600]
            if len(s["requests"]) >= MAX_PER_HOUR:
                self._save(s)
                self._refuse("request", "rate-limited", meta)
            rid = "".join(secrets.choice(ID_ALPHABET) for _ in range(8))
            s["requests"].append(t)
            s["pending"] = {"id": rid, "kind": kind, "display": display, "payload": payload, "meta": meta, "expires": t + self.window_s}
            self._save(s)
            self._row("request", "pending", meta, id=rid)
            return rid, int(t + self.window_s)
        finally:
            os.close(fd)

    def _sender_ok(self, rid, sender, chat, meta):
        if int(sender) != self.operator_id or int(chat) != self.operator_id:
            self._refuse("code-check", "not-operator", meta, id=rid, sender=int(sender), chat=int(chat))

    def approve(self, rid, code, sender, chat, executor):
        """Check the code; on success run executor(payload) once. Returns (pending, exit)."""
        fd = self._locked()
        try:
            s, t = self._load(), self.now()
            p = s["pending"]
            meta = p["meta"] if p and p["id"] == rid else {}
            self._sender_ok(rid, sender, chat, meta)
            if t < s["locked_until"]:
                self._refuse("code-check", "locked", meta, id=rid)
            if p and p["id"] == rid and t > p["expires"]:
                self._expire(s, t)
                self._save(s)
                self._refuse("code-check", "expired", meta, id=rid)
            self._expire(s, t)
            p = s["pending"]
            if not p or p["id"] != rid:
                if p:
                    self._finish(s, p["id"], "burned")
                    s["pending"] = None
                self._save(s)
                self._refuse("code-check", "no-pending", meta, id=rid)
            seed = open(self.seed_path).read().strip()
            step = int(t // STEP_S)
            hit = None
            if re.fullmatch(r"\d{%d}" % DIGITS, code or ""):
                for cand in (step - 1, step):
                    if hmac.compare_digest(totp(seed, cand), code):
                        hit = cand
            if hit is None or hit <= s["last_step"]:
                result = "no-code" if not code else "replay" if hit is not None else "wrong-code"
                if result != "replay":
                    s["wrong"] += 1
                    if s["wrong"] >= MAX_WRONG:
                        s["locked_until"], s["wrong"] = t + LOCK_S, 0
                self._finish(s, rid, "denied:" + result)
                s["pending"] = None
                self._save(s)
                self._refuse("code-check", result, p["meta"], id=rid)
            s["last_step"], s["wrong"], s["pending"] = hit, 0, None
            self._finish(s, rid, "running")
            self._save(s)
            self._row("code-check", "approved", p["meta"], id=rid, sender=int(sender))
        finally:
            os.close(fd)
        rc = executor(p["payload"])
        fd = self._locked()
        try:
            s = self._load()
            self._finish(s, rid, f"ran:{rc}")
            self._save(s)
            self._row("run", "ran", p["meta"], id=rid, exit=rc)
        finally:
            os.close(fd)
        return p, rc

    def deny(self, rid, sender, chat):
        fd = self._locked()
        try:
            s = self._load()
            p = s["pending"]
            meta = p["meta"] if p and p["id"] == rid else {}
            self._sender_ok(rid, sender, chat, meta)
            if not p or p["id"] != rid:
                self._refuse("deny", "no-pending", meta, id=rid)
            self._finish(s, rid, "denied")
            s["pending"] = None
            self._save(s)
            self._row("deny", "denied", meta, id=rid, sender=int(sender))
        finally:
            os.close(fd)

    def status(self, rid):
        fd = self._locked()
        try:
            s = self._load()
            self._expire(s, self.now())
            self._save(s)
            p = s["pending"]
            if p and p["id"] == rid:
                return "pending"
            return s["done"].get(rid, "unknown")
        finally:
            os.close(fd)
