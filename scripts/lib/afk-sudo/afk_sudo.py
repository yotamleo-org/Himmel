#!/usr/bin/python3 -I
"""afk-sudo — run one privileged command after a Telegram TOTP approval.

Linux only: requires O_PATH and /proc/self/fd for safe opened-object validation.

Installed root-owned to /usr/local/libexec/himmel/afk-sudo by install.sh and
reached through one sudoers NOPASSWD rule that names that copy, never this repo
file (a repo file is agent-writable). Off by default: the station config ships
`"enabled": false` with an empty allowlist.

  afk-sudo request ID...      --session S --ticket T --cwd DIR -- ARGV...   (allowlisted class, root)
  afk-sudo run-request        --session S --ticket T --blocked-by B [--as USER] [--cwd DIR] [--why W] -- ARGV...
                              (stdin of this process is the command's stdin, at most 64 KiB)
  afk-sudo approve ID --from SENDER --chat CHAT      (the code is read from stdin)
  afk-sudo deny ID --from SENDER --chat CHAT
  afk-sudo status ID  |  run-status ID
  afk-sudo run-result ID [--stream stdout|stderr]
  afk-sudo mode

The run kind (`run-request`) is mode-switched by the station config: `"mode": "allowlist"`
(the default, also any other or absent value) runs only an argv a class names, as the class's
run_as; `"mode": "all"` runs any argv as `operator_user` (or root with `--as root`). Either way
the never-remote floor (never_remote.py) refuses a request before the operator sees it, and it is frozen into a
root-owned record whose hash the executor re-checks, with the argv0, file and cwd identities,
after the code is accepted.

A session reaches `run-request` through scripts/lib/afk-run (sudo -n, then it polls run-status and
relays the captured output and exit status); scripts/lib/afk-sudo-request does the same for `request`.

Prints `result=<word> …` lines. Exit 0 ok, 5 refused, 2 usage.
Test seam: AFK_SUDO_ROOT (a sandbox root), AFK_SUDO_NOW (epoch seconds) and AFK_SUDO_RUN=1 (the
run kind on) are honoured only when euid != 0; there the files must be owned by the caller
instead of root and a run keeps the caller's uid. Outside the seam a non-root run is refused.
"""
import argparse
import base64
import ctypes
import errno
import hashlib
import hmac
import json
import os
import pwd
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import approval_broker as ab  # noqa: E402
import never_remote as nr  # noqa: E402

RUN_TIMEOUT_S = 120
# The run kind is compiled off: a config edit cannot turn it on, only a release that flips this.
RUN_KIND_SHIPPED = False
SEAM = os.geteuid() != 0 and bool(os.environ.get("AFK_SUDO_ROOT"))
ROOT = os.environ["AFK_SUDO_ROOT"] if SEAM else "/"
OWNER = os.geteuid() if SEAM else 0
CONFIG = os.path.join(ROOT, "etc/himmel/afk-sudo.json")
SEED = os.path.join(ROOT, "etc/himmel/afk-sudo/totp.seed")
STATE = os.path.join(ROOT, "var/lib/himmel/afk-sudo")
LEDGER = os.path.join(ROOT, "var/log/himmel/afk-sudo.jsonl")
RECORDS = os.path.join(STATE, "records")
FILES = os.path.join(STATE, "files")
RESULTS = os.path.join(STATE, "results")

FIXED_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
READ_CAP = 64 * 1024
OUT_CAP = 256 * 1024
ID_RE = re.compile(r"[a-z2-7]{8}")
BLOCKED_BY = re.compile(r"classifier|prompt|operator-step|hook:[A-Za-z0-9._-]{1,60}")
PSEUDO = ("/proc/", "/sys/", "/dev/")


def now():
    if SEAM and os.environ.get("AFK_SUDO_NOW"):
        return float(os.environ["AFK_SUDO_NOW"])
    return time.time()


def clean(s, n=200):
    return "".join(c if c.isprintable() else "?" for c in str(s))[:n]


def cfg_int(d, key, default, lo, hi):
    v = d.get(key) if isinstance(d, dict) else None
    return min(hi, max(lo, v)) if isinstance(v, int) and not isinstance(v, bool) else default


def run_block(config):
    return config["run"] if isinstance(config.get("run"), dict) else {}


def mode_of(config):
    return "all" if config.get("mode") == "all" else "allowlist"


def run_shipped():
    return RUN_KIND_SHIPPED or (SEAM and os.environ.get("AFK_SUDO_RUN") == "1")


def run_enabled(config):
    return run_shipped() and run_block(config).get("enabled") is True


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


# --- the run kind: freezing a request ---
def user_pw(name):
    try:
        return pwd.getpwnam(name) if isinstance(name, str) and name else None
    except KeyError:
        return None


def find_cmd(argv0, cwd):
    """The absolute path argv[0] resolves to (a path as given, else the fixed PATH), else None.
    Not normalised: `link/../x` is what the kernel opens, and that is what is hashed and exec'd."""
    if "/" in argv0:
        cands = [argv0 if argv0.startswith("/") else os.path.join(cwd, argv0)]
    else:
        cands = [os.path.join(d, argv0) for d in FIXED_PATH.split(":")]
    for c in cands:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def setpriv_path():
    for d in FIXED_PATH.split(":"):
        c = os.path.join(d, "setpriv")
        if os.access(c, os.X_OK):
            return c
    return None


def open_regular(path):
    """Open a regular file for reading. A link into /proc, /sys or /dev, a FIFO and any other
    non-regular file are refused: root reading one could hang or flood the helper."""
    if os.path.realpath(path).startswith(PSEUDO):
        raise OSError(errno.EINVAL, "pseudo-file", path)
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    read_fd = None
    try:
        fd_path = f"/proc/self/fd/{fd}"
        if os.readlink(fd_path).startswith(PSEUDO):
            raise OSError(errno.EINVAL, "pseudo-file", path)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        # Linux struct statfs starts with f_type and fits in 32 machine words.
        # Check the fd: another namespace can expose procfs outside /proc.
        fs = (ctypes.c_long * 32)()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.fstatfs(fd, ctypes.byref(fs)) != 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err), path)
        if fs[0] in (0x9FA0, 0x62656572):  # PROC_SUPER_MAGIC, SYSFS_MAGIC
            raise OSError(errno.EINVAL, "pseudo-filesystem", path)
        read_fd = os.open(fd_path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
        return os.fdopen(read_fd, "rb")
    except OSError:
        if read_fd is not None:
            os.close(read_fd)
        raise
    finally:
        os.close(fd)


def hash_open(f):
    h = hashlib.sha256()
    for chunk in iter(lambda: f.read(1 << 16), b""):
        h.update(chunk)
    return h.hexdigest()


def dev_ino(f):
    st = os.fstat(f.fileno())
    return [st.st_dev, st.st_ino]


def path_only(f):
    """A path-only (O_PATH) descriptor of the file f has open: it names that file for exec but cannot be read."""
    return os.open(f"/proc/self/fd/{f.fileno()}", os.O_PATH | os.O_CLOEXEC)


def verify_open(path, sha256, ident):
    """Open path once and hash that open file: the file when it is the frozen one (same sha256, same
    st_dev and st_ino), else None. The caller starts the program from this descriptor, never from the
    path again, so a name swapped after this check is not what runs."""
    f = open_regular(path)
    try:
        if dev_ino(f) == ident and hash_open(f) == sha256:
            return f
    except BaseException:
        f.close()
        raise
    f.close()
    return None


# ponytail: a name list, not shebang or ELF detection; a script run by an interpreter outside it is hashed and
# compared by path as before. upgrade path: classify argv[0] by its file instead.
INTERPRETERS = re.compile(r"(ba|da|z|k)?sh|python[0-9.]*|perl|ruby|php|lua")


def script_operand(rec):
    """Index in rec["argv"] of the file an interpreter runs as its script: the first bound file among
    the words that are no option, when argv[0] is a known interpreter and no option before it supplies
    the program (-c, -m, -e) or is a long option. Words that name no file (the `ignore` of
    `-W ignore`) are skipped. Else None."""
    argv = rec["argv"]
    if not INTERPRETERS.fullmatch(os.path.basename(argv[0])):
        return None
    for i, a in enumerate(argv[1:], 1):
        if a.startswith("--") or (a.startswith("-") and re.search(r"[cme]", a)):
            return None
        if not a.startswith("-") and rec["targets"][i].startswith("file:"):
            return i
    return None


class BadFile(Exception):
    """An argv element names something the helper will not bind: refused, never skipped."""


def bind_target(a, cwd):
    """What an argv element names, as the kernel resolves it (links first, then ..): ("file", path),
    ("dir", path), ("none", path) when nothing is there yet (path is where it would land, so a
    link moved above it or a dangling link retargeted changes it), or None for an element that
    is no path (empty, NUL, over 4096 characters, /dev/null). A pseudo-file
    (under /proc, /sys, /dev; only /dev/null is let through), a FIFO or other non-regular file, an
    entry that cannot be examined, and a path the kernel cannot walk (`nr.landing`: a walk that
    fails for any reason but a missing name or a name under a non-directory, such as a link past PATH_MAX that plain realpath would
    leave as a name, or a name past NAME_MAX, a `python -c` program with a long run among them)
    raise BadFile: a run that is not bound by hash must not go ahead."""
    if not a or "\0" in a or len(a) > 4096:
        return None
    joined = a if a.startswith("/") else os.path.join(cwd, a)
    lex = os.path.normpath(joined)
    real = nr.landing(joined)
    if real is None:
        raise BadFile(a)
    if real == "/dev/null":
        return None
    if lex.startswith(PSEUDO) or real.startswith(PSEUDO):
        raise BadFile(a)
    try:
        mode = os.stat(real).st_mode
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ENOTDIR):
            return "none", real
        raise BadFile(a) from e
    if stat.S_ISDIR(mode):
        return "dir", real
    if not stat.S_ISREG(mode):
        raise BadFile(a)
    return "file", real


def target_key(t):
    """The comparable form of a bind_target result: "file:/p", "dir:/p", "none:/p" or "" for an
    element that is no path."""
    return f"{t[0]}:{t[1]}" if t else ""


def collect_files(argv, cwd, op_uid):
    """Every argv element naming a regular file: hashed, and read when it is small and the
    operator could read it themselves (a root-only file is hashed, never read or shown).
    The recorded path is the resolved one. Returns (files, targets): targets holds one
    target_key per argv element, taken in the same pass, so the executor can require each
    element to resolve to the same thing again. Raises BadFile for an element that cannot be bound."""
    seen, out, targets = set(), [], []
    for a in argv:
        t = bind_target(a, cwd)
        targets.append(target_key(t))
        if t is None or t[0] != "file" or t[1] in seen:
            continue
        p = t[1]
        seen.add(p)
        try:
            with open_regular(p) as f:
                st = os.fstat(f.fileno())
                head = f.read(READ_CAP + 1)
                h, n = hashlib.sha256(head), len(head)
                for chunk in iter(lambda: f.read(1 << 16), b""):
                    h.update(chunk)
                    n += len(chunk)
        except OSError as e:
            raise BadFile(a) from e
        body = head if n <= READ_CAP and (st.st_mode & 0o004 or st.st_uid == op_uid) else None
        out.append(({"path": p, "sha256": h.hexdigest(), "bytes": n, "dev_ino": [st.st_dev, st.st_ino], "shown": body is not None}, body))
    return out, targets


def rec_hash(rec):
    body = {k: v for k, v in rec.items() if k != "id"}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    ab.check_safe(path, OWNER, kind="dir", secret=True)


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def prune(live):
    """Drop the record, result and file copies of ids that left the done window."""
    for d in (RECORDS, RESULTS):
        if os.path.isdir(d):
            for name in os.listdir(d):
                if name.split(".")[0] not in live:
                    os.unlink(os.path.join(d, name))
    if os.path.isdir(FILES):
        for name in os.listdir(FILES):
            if name not in live:
                shutil.rmtree(os.path.join(FILES, name), ignore_errors=True)


def cut_argv(argv):
    return [clean(a if len(a) <= 120 else a[:100] + "…", 130) for a in argv]


def make_builder(spec):
    """The payload builder broker.request calls once the id is known: writes the frozen
    record and the file copies, returns the broker payload (id + reference hash)."""
    def build(rid, created, expires):
        rec = {"v": 1, "id": rid, "kind": "run", "run_as": spec["run_as"], "uid": spec["uid"], "gid": spec["gid"],
               "argv": spec["argv"], "argv0_path": spec["argv0_path"], "argv0_sha256": spec["argv0_sha256"],
               "argv0_dev_ino": spec["argv0_dev_ino"],
               "files": [e for e, _ in spec["files"]], "targets": spec["targets"],
               "cwd": spec["cwd"], "cwd_dev_ino": spec["cwd_dev_ino"],
               "env": {"names": sorted(run_env(spec["pw"]))},
               "stdin": {"bytes": len(spec["stdin"]), "sha256": hashlib.sha256(spec["stdin"]).hexdigest(),
                         "copy": os.path.join(FILES, rid, "stdin") if spec["stdin"] else None},
               "session": spec["session"], "ticket": spec["ticket"], "blocked_by": spec["blocked_by"],
               "why": spec["why"], "created": created, "expires": expires}
        digest = rec_hash(rec)
        for d in (RECORDS, FILES, os.path.join(FILES, rid)):
            private_dir(d)
        for i, (_, body) in enumerate(spec["files"]):
            if body is not None:
                write_private(os.path.join(FILES, rid, f"f{i}"), body)
        if spec["stdin"]:
            write_private(os.path.join(FILES, rid, "stdin"), spec["stdin"])
        write_private(os.path.join(RECORDS, rid + ".json"), json.dumps(rec, sort_keys=True).encode())
        extra = {"run_as": spec["run_as"], "hash": digest, "blocked_by": spec["blocked_by"], "why": spec["why"],
                 "mode": spec["mode"], "argv": cut_argv(spec["argv"]), "argv0_sha256": spec["argv0_sha256"],
                 "frozen": {"files": rec["files"], "stdin": {"bytes": rec["stdin"]["bytes"], "sha256": rec["stdin"]["sha256"]},
                            "cwd": spec["cwd"]}}
        return {"kind": "run", "id": rid, "hash": digest}, extra
    return build


# --- the run kind: executing a frozen request ---
def run_env(pw):
    uid = pw.pw_uid
    return {"HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name, "PATH": FIXED_PATH, "LANG": "C.UTF-8",
            "XDG_RUNTIME_DIR": f"/run/user/{uid}", "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus"}


def load_record(rid):
    ab.check_safe(RECORDS, OWNER, kind="dir", secret=True)
    path = os.path.join(RECORDS, rid + ".json")
    ab.check_safe(path, OWNER, secret=True)
    with open(path) as f:
        return json.load(f)


def read_copy(rid, name):
    with open(os.path.join(FILES, rid, name), "rb") as f:
        return f.read().decode("utf-8", "replace")


def capture(cmd, env, cwd, stdin_path, timeout, pass_fds=()):
    """Run cmd, keep OUT_CAP bytes of each stream (counting and hashing all of it)."""
    stdin = open(stdin_path, "rb") if stdin_path else subprocess.DEVNULL
    t0 = time.monotonic()
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True, pass_fds=pass_fds)
    except OSError:
        return 127, {"stdout": (b"", 0, hashlib.sha256().hexdigest()), "stderr": (b"", 0, hashlib.sha256().hexdigest())}, 0
    finally:
        if stdin_path:
            stdin.close()
    keep = {"stdout": bytearray(), "stderr": bytearray()}
    total = {"stdout": 0, "stderr": 0}
    digest = {"stdout": hashlib.sha256(), "stderr": hashlib.sha256()}
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
    sel.register(proc.stderr, selectors.EVENT_READ, "stderr")
    timed_out = False
    while sel.get_map():
        left = timeout - (time.monotonic() - t0)
        if left <= 0:
            timed_out = True
            break
        for key, _ in sel.select(min(left, 1.0)):
            data = os.read(key.fd, 65536)
            if not data:
                sel.unregister(key.fileobj)
                continue
            name = key.data
            total[name] += len(data)
            digest[name].update(data)
            keep[name] += data[:max(0, OUT_CAP - len(keep[name]))]
    if timed_out:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    proc.stdout.close()
    proc.stderr.close()
    try:
        rc = proc.wait(timeout=max(0.1, timeout - (time.monotonic() - t0)))
    except subprocess.TimeoutExpired:  # closed its pipes but kept running
        timed_out = True
    if timed_out:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        rc = 124
    streams = {k: (bytes(keep[k]), total[k], digest[k].hexdigest()) for k in keep}
    return rc, streams, int((time.monotonic() - t0) * 1000)


def execute_run(payload, config):
    """Re-check everything the operator approved, then run it. Returns the broker's result dict."""
    rid = payload["id"]
    held, frozen, sealed = {}, {}, []  # path -> the open file the check hashed, what it was frozen as, and the path-only fds the run starts from
    try:
        rec = load_record(rid)
        if rec.get("id") != rid or not hmac.compare_digest(rec_hash(rec), payload["hash"]):
            return {"result": "hash-mismatch"}
        try:  # a program, file argument or cwd that is gone or no longer a regular file has changed
            for path, sha256, ident in [(rec["argv0_path"], rec["argv0_sha256"], rec["argv0_dev_ino"])] + \
                    [(f["path"], f["sha256"], f["dev_ino"]) for f in rec["files"]]:
                if path in held:  # one open file answers both records, which must then agree
                    if frozen[path] != (sha256, ident):
                        return {"result": "changed"}
                    continue
                f = verify_open(path, sha256, ident)
                if f is None:
                    return {"result": "changed"}
                held[path], frozen[path] = f, (sha256, ident)
            st = os.stat(rec["cwd"])
            if [st.st_dev, st.st_ino] != rec["cwd_dev_ino"]:
                return {"result": "changed"}
            if len(rec["targets"]) != len(rec["argv"]):
                return {"result": "changed"}
            for a, want in zip(rec["argv"], rec["targets"]):  # each element names what it named at request
                if target_key(bind_target(a, rec["cwd"])) != want:
                    return {"result": "changed"}
        except (OSError, BadFile):
            return {"result": "changed"}
        if not run_shipped():
            return {"result": "run-not-shipped"}
        if run_block(config).get("enabled") is not True:
            return {"result": "run-disabled"}
        texts = [read_copy(rid, f"f{i}") for i, f in enumerate(rec["files"]) if f["shown"]]
        if rec["stdin"]["copy"]:
            texts.append(read_copy(rid, "stdin"))
        run_pw = user_pw(rec["run_as"])
        op_pw = user_pw(config.get("operator_user"))  # never root's home: no operator, no run
        if run_pw is None or op_pw is None or run_pw.pw_uid != rec["uid"]:
            return {"result": "bad-user"}
        extra = config.get("never_remote_extra")
        rule = nr.check(rec["argv"], texts, rec["cwd"], op_pw.pw_dir, extra if isinstance(extra, list) else [])
        if rule:
            return {"result": "never-remote", "rule": rule}
        if rec["run_as"] not in ("root", config.get("operator_user")):
            return {"result": "bad-user"}
        if mode_of(config) != "all":
            hit = match_class(config, rec["argv"])
            if not hit:
                return {"result": "not-in-class"}
            if config["classes"][hit[0]].get("run_as", "root") != rec["run_as"]:
                return {"result": "bad-user"}
        # Start the verified descriptors, never the paths: a name swapped after the check is not what runs.
        # The program (and the script an interpreter runs) is named /proc/self/fd/N, which the process that
        # execs it resolves to the same open file; the cost is that the program sees that name as argv[0].
        # What is handed over is a path-only (O_PATH) descriptor of the verified file, never the read descriptor
        # opened here as root: access is checked when a file is opened, so a program that starts first as the
        # run-as user could read a root-only script through a readable one.
        argv, fds = list(rec["argv"]), [path_only(held[rec["argv0_path"]])]
        sealed.extend(fds)
        argv[0] = f"/proc/self/fd/{fds[0]}"
        i = script_operand(rec)
        if i is not None:
            fds.append(path_only(held[rec["targets"][i][len("file:"):]]))
            sealed.append(fds[-1])
            argv[i] = f"/proc/self/fd/{fds[-1]}"
        cmd = argv
        if SEAM or rec["uid"] != 0:
            sp = setpriv_path()
            if sp:
                drop = [] if SEAM else [f"--reuid={rec['uid']}", f"--regid={rec['gid']}", "--init-groups"]
                cmd = [sp] + drop + ["--no-new-privs", "--inh-caps=-all"] + cmd
            elif not SEAM:
                return {"result": "no-setpriv"}
        timeout = cfg_int(run_block(config), "timeout_s", 300, 1, 1800)
        rc, streams, ms = capture(cmd, run_env(run_pw), rec["cwd"], rec["stdin"]["copy"], timeout, fds)
    except (OSError, KeyError, TypeError, ValueError, ab.Refused):
        return {"result": "hash-mismatch"}
    finally:
        for f in held.values():
            f.close()
        for fd in sealed:
            os.close(fd)
    out, err = streams["stdout"], streams["stderr"]
    kept = True
    try:  # the command already ran: a result file that cannot be written must not hide that
        private_dir(RESULTS)
        write_private(os.path.join(RESULTS, rid + ".json"), json.dumps({
            "id": rid, "exit": rc, "duration_ms": ms,
            "stdout_b64": base64.b64encode(out[0]).decode(), "stdout_bytes": out[1], "stdout_sha256": out[2],
            "stderr_b64": base64.b64encode(err[0]).decode(), "stderr_bytes": err[1], "stderr_sha256": err[2]}).encode())
    except (OSError, ab.Refused):
        kept = False
    return {"result": "ran", "exit": rc, "stdout_bytes": out[1], "stderr_bytes": err[1], "stdout_sha256": out[2],
            "stderr_sha256": err[2], "duration_ms": ms, "result_kept": kept}


def execute(payload, config):
    if payload.get("kind") == "run":
        return execute_run(payload, config)
    try:
        return subprocess.run(payload["argv"], cwd="/", env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"},
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=RUN_TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        return 124
    except OSError:
        return 127


def blocked_by(v):
    if not BLOCKED_BY.fullmatch(v):
        raise argparse.ArgumentTypeError("classifier, hook:<guard>, prompt or operator-step")
    return v


def refuse_row(meta, result, **extra):
    ab.append_row(LEDGER, dict(meta, ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now())), event="request",
                               result=result, **extra), OWNER)


def run_request(broker, config, args):
    """File one run request; prints the result lines and returns the exit code."""
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        print("result=usage")
        return 2
    if not run_shipped():
        print("result=run-not-shipped")
        return 5
    if run_block(config).get("enabled") is not True:
        print("result=run-disabled")
        return 5
    if getattr(os.path, "ALLOW_MISSING", None) is None:  # older than the CVE-2025-4517 posixpath fixes; untested there
        print("result=no-allow-missing")
        return 5
    op_pw = user_pw(config.get("operator_user"))
    if op_pw is None:  # a partial config must not point the floor at root's home
        print("result=bad-user")
        return 5
    mode = mode_of(config)
    meta = {"session": clean(args.session), "ticket": clean(args.ticket), "kind": "run", "mode": mode,
            "blocked_by": args.blocked_by, "why": clean(args.why), "argv": cut_argv(cmd)}
    if mode == "all":
        want = args.run_as or config.get("operator_user")
        run_pw = user_pw(want) if want in ("root", config.get("operator_user")) else None
        argv = cmd
    else:
        hit = match_class(config, cmd)
        if not hit:
            refuse_row(dict(meta, cwd=clean(args.cwd, 500)), "not-in-class")
            print("result=not-in-class")
            return 5
        argv = hit[1]
        want = config["classes"][hit[0]].get("run_as", "root")
        run_pw = user_pw(want) if want in ("root", config.get("operator_user")) else None
    if run_pw is None:
        print("result=bad-user")
        return 5
    cwd = "/" if run_pw.pw_uid == 0 else args.cwd
    meta["cwd"] = clean(cwd, 500)
    if not cwd.startswith("/") or not os.path.isdir(cwd):
        print("result=bad-cwd")
        return 5
    stdin = sys.stdin.buffer.read(READ_CAP + 1)
    if len(stdin) > READ_CAP:
        print("result=stdin-too-large")
        return 5
    argv0_path = find_cmd(argv[0], cwd)
    if argv0_path is None:
        print("result=no-such-command")
        return 5
    try:
        (files, targets), unbound = collect_files(argv, cwd, op_pw.pw_uid), False
    except BadFile:
        files, targets, unbound = [], [], True  # the floor still reads the argv, so a wipe of /dev/x stays never-remote
    texts = [b.decode("utf-8", "replace") for _, b in files if b is not None] + [stdin.decode("utf-8", "replace")]
    extra = config.get("never_remote_extra")
    rule = nr.check(argv, texts, cwd, op_pw.pw_dir, extra if isinstance(extra, list) else [])
    if rule:
        refuse_row(meta, "never-remote", rule=rule)
        print(f"result=never-remote rule={rule}")
        return 5
    if unbound:
        print("result=bad-file")
        return 5
    if not SEAM and run_pw.pw_uid != 0 and not setpriv_path():
        print("result=no-setpriv")
        return 5
    st = os.stat(cwd)
    with open_regular(argv0_path) as f0:
        argv0_sha256, argv0_dev_ino = hash_open(f0), dev_ino(f0)
    spec = {"argv": argv, "argv0_path": argv0_path, "argv0_sha256": argv0_sha256, "argv0_dev_ino": argv0_dev_ino,
            "files": files, "targets": targets, "stdin": stdin, "cwd": cwd, "cwd_dev_ino": [st.st_dev, st.st_ino], "run_as": run_pw.pw_name,
            "uid": run_pw.pw_uid, "gid": run_pw.pw_gid, "pw": run_pw, "session": meta["session"],
            "ticket": meta["ticket"], "blocked_by": args.blocked_by, "why": meta["why"], "mode": mode}
    window = cfg_int(run_block(config), "ttl_s", 900, 30, 3600)
    shown = clean(" ".join(argv), 300)
    broker.retain = prune
    rid, expires = broker.request("run", shown, make_builder(spec), {k: meta[k] for k in ("session", "ticket", "cwd")}, window)
    print(f"result=pending id={rid} expires={expires} operator={int(config['operator_id'])}")
    print(f"text=AFK run request {rid} as {run_pw.pw_name}: {shown} | cwd {cwd} | session {meta['session']} | "
          f"ticket {meta['ticket']} | blocked by {args.blocked_by} | expires in {window} s. "
          f"Reply: approve {rid} <code>  or  deny {rid}")
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="afk-sudo")
    sub = p.add_subparsers(dest="verb", required=True)
    r = sub.add_parser("request")
    r.add_argument("--session", required=True)
    r.add_argument("--ticket", required=True)
    r.add_argument("--cwd", required=True)
    r.add_argument("cmd", nargs=argparse.REMAINDER)
    q = sub.add_parser("run-request")
    q.add_argument("--session", required=True)
    q.add_argument("--ticket", required=True)
    q.add_argument("--blocked-by", dest="blocked_by", type=blocked_by, required=True)
    q.add_argument("--as", dest="run_as")
    q.add_argument("--cwd", default="/")
    q.add_argument("--why", default="")
    q.add_argument("cmd", nargs=argparse.REMAINDER)
    for verb in ("approve", "deny"):
        a = sub.add_parser(verb)
        a.add_argument("id")
        a.add_argument("--from", dest="sender", type=int, required=True)
        a.add_argument("--chat", type=int, required=True)
    for verb in ("status", "run-status"):
        sub.add_parser(verb).add_argument("id")
    g = sub.add_parser("run-result")
    g.add_argument("id")
    g.add_argument("--stream", choices=("stdout", "stderr"))
    sub.add_parser("mode")
    args = p.parse_args(argv)

    if os.geteuid() != 0 and not SEAM:
        print("result=not-root")
        return 5
    try:
        ab.check_safe(CONFIG, OWNER)
        with open(CONFIG) as f:
            config = json.load(f)
        if not isinstance(config, dict):
            raise TypeError("config is not an object")
        if args.verb == "mode":
            print(f"result=mode mode={mode_of(config)} enabled={str(config.get('enabled') is True).lower()} "
                  f"run_enabled={str(run_enabled(config)).lower()}")
            return 0
        if config.get("enabled") is not True:
            print("result=disabled")
            return 5
        if args.verb == "run-result":
            if not ID_RE.fullmatch(args.id):
                print("result=bad-id")
                return 5
            path = os.path.join(RESULTS, args.id + ".json")
            if not os.path.lexists(path):
                print(f"result=no-result id={args.id}")
                return 5
            ab.check_safe(path, OWNER, secret=True)
            with open(path) as f:
                res = json.load(f)
            if args.stream:
                sys.stdout.flush()
                sys.stdout.buffer.write(base64.b64decode(res[args.stream + "_b64"]))
                sys.stdout.buffer.flush()
            else:
                print(f"result=ran id={args.id} exit={res['exit']} stdout_bytes={res['stdout_bytes']} "
                      f"stderr_bytes={res['stderr_bytes']} duration_ms={res['duration_ms']}")
            return 0
        broker = ab.Broker(STATE, LEDGER, SEED, config["operator_id"], config.get("window_s", 120), OWNER, now,
                           max_per_hour=cfg_int(config, "max_per_hour", ab.MAX_PER_HOUR, 1, 30))
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
        elif args.verb == "run-request":
            return run_request(broker, config, args)
        elif args.verb == "approve":
            code = sys.stdin.readline().strip()
            pending, res = broker.approve(args.id, code, args.sender, args.chat, lambda payload: execute(payload, config))
            if res["result"] != "ran":
                print(f"result={res['result']} id={args.id}" + (f" rule={res['rule']}" if "rule" in res else ""))
                return 5
            print(f"result=ran id={args.id} exit={res['exit']} argv={pending['display']}")
        elif args.verb == "deny":
            broker.deny(args.id, args.sender, args.chat)
            print(f"result=denied id={args.id}")
        else:
            print(f"result={broker.status(args.id)} id={args.id}")
        return 0
    except ab.Refused as e:
        print(f"result={e.result}" + (f" id={args.id}" if getattr(args, "id", None) else "") + (f" path={e.detail}" if e.result == "unsafe-perms" else ""))
        return 5
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"result=error {type(e).__name__}")
        return 5


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
