#!/usr/bin/env python3
"""Job VM verbs for the peer bridge runner (slice B).

  vmsdk-job.py vm-clone <job>
  vmsdk-job.py vm-push <job> <host file>
  vmsdk-job.py vm-exec <job> --timeout <s> -- <argv...>
  vmsdk-job.py vm-pull <job> <guest path> <host path> --max-bytes <n>
  vmsdk-job.py vm-destroy <job>
  vmsdk-job.py vm-sweep
  vmsdk-job.py golden-record [--print]
  vmsdk-job.py golden-build-linux --ova <file> --admin-user <u> --admin-passwordfile <file>

Exit: 0 ok, 124 timeout, 2 refused, 1 backend error.

PEER_JOB_BACKEND picks the backend: `vbox` (Linux test bed), `stub` (tests),
`tart` (slice C; not built here). A job's files live in the
guest under /tmp/job. A vm-exec timeout kills every process in the command's
guest session (setsid, then pkill -s) and leaves the guest up for vm-pull.
This file is a separate entry point; it never uses vmsdk.py.
"""
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

EXIT_OK, EXIT_ERROR, EXIT_REFUSED, EXIT_TIMEOUT = 0, 1, 2, 124
JOB_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
NAME_RE = re.compile(r"^(?!\.\.?$)[A-Za-z0-9._-]{1,64}$")
GUEST_DIR = "/tmp/job"
SID_FILE = GUEST_DIR + "/.sid"
TIMEOUT_MAX_S = 86400
MAX_BYTES_MAX = 64 * 1024 * 1024
REPO = Path(__file__).resolve().parents[2]
USAGE = "usage: vmsdk-job.py vm-clone|vm-push|vm-exec|vm-pull|vm-destroy|vm-sweep|golden-record|golden-build-linux ... (see the file header)"


class Refused(Exception):
    pass


class BackendError(Exception):
    pass


def config_dir():
    return Path(os.environ.get("HOME") or os.path.expanduser("~")) / ".config" / "himmel" / "peer-bridge"


def write_private(path, data):
    path = Path(path)
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def guest_file(path):
    if not path.startswith(GUEST_DIR + "/") or not NAME_RE.match(path[len(GUEST_DIR) + 1:]):
        raise Refused(f"guest path must be {GUEST_DIR}/<name>")
    return path


class StubBackend:
    """A directory per clone under PEER_JOB_STUB_DIR; exec does what exec.json says."""

    def __init__(self):
        root = os.environ.get("PEER_JOB_STUB_DIR")
        if not root or not os.path.isabs(root):
            raise Refused("no backend: PEER_JOB_STUB_DIR must be an absolute path")
        self.root = Path(root)

    def _cfg(self, name):
        f = self.root / name
        return json.loads(f.read_text()) if f.exists() else {}

    def _log(self, verb, job=None, **extra):
        with open(self.root / "calls.jsonl", "a") as f:
            f.write(json.dumps({"verb": verb, "job": job, **extra}) + "\n")
        rc = self._cfg("fail.json").get(verb)
        if rc:
            raise BackendError(f"stub: {verb} forced to fail")

    def _guest(self, job):
        return self.root / "vms" / job / "tmp" / "job"

    def clone(self, job):
        self._log("vm-clone", job)
        self._guest(job).mkdir(parents=True, exist_ok=True)

    def push(self, job, src):
        self._log("vm-push", job, file=os.path.basename(src))
        shutil.copyfile(src, self._guest(job) / os.path.basename(src))

    def exec(self, job, argv, timeout):
        spec = self._cfg("exec.json")
        for name, text in spec.get("files", {}).items():
            (self._guest(job) / name).write_text(text)
        if spec.get("hang"):
            self._log("vm-exec", job, argv=argv, killed="session")
            return EXIT_TIMEOUT
        self._log("vm-exec", job, argv=argv)
        return int(spec.get("rc", 0))

    def size(self, job, path):
        f = self._guest(job) / os.path.basename(path)
        if not f.exists():
            raise BackendError(f"no such guest file: {path}")
        return f.stat().st_size

    def pull(self, job, path, tmp):
        self._log("vm-pull", job, path=path)
        shutil.copyfile(self._guest(job) / os.path.basename(path), tmp)

    def destroy(self, job):
        self._log("vm-destroy", job)
        shutil.rmtree(self.root / "vms" / job, ignore_errors=True)

    def sweep(self):
        self._log("vm-sweep")
        shutil.rmtree(self.root / "vms", ignore_errors=True)
        (self.root / "vms").mkdir()

    def golden_digest(self):
        return hashlib.sha256((self.root / "golden.img").read_bytes()).hexdigest()


class VBoxJobBackend:
    """VirtualBox clones of the golden VM, no NIC, driven through guestcontrol."""

    GOLDEN = "himmel-peer-golden"
    PREFIX = "himmel-peerjob-"
    USER = "peerjob"
    NICS = 8

    def __init__(self):
        self.vbm = os.environ.get("VBOXMANAGE_PATH") or shutil.which("VBoxManage")
        if not self.vbm:
            raise Refused("no backend: VBoxManage not found")

    def _vm(self, job):
        return self.PREFIX + job

    def _run(self, *args, timeout=600):
        try:
            r = subprocess.run([self.vbm, *args], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise BackendError(f"VBoxManage {args[0]} timed out")
        return r.returncode, r.stdout, r.stderr

    def _ok(self, *args, timeout=600):
        rc, out, err = self._run(*args, timeout=timeout)
        if rc != 0:
            raise BackendError(f"VBoxManage {' '.join(args[:2])} rc {rc}: {err.strip()[-300:]}")
        return out

    def _cred(self):
        f = config_dir() / "golden.guest"
        try:
            st = f.lstat()
        except FileNotFoundError:
            raise Refused(f"no guest credential: run golden-build-linux first ({f})")
        if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600:
            raise Refused(f"{f} must be a regular file with mode 600")
        return str(f)

    def _gc(self, vm, verb, *args, user=None, pwfile=None):
        return ["guestcontrol", vm, verb, "--username", user or self.USER, "--passwordfile", pwfile or self._cred(), *args]

    def _guest_run(self, vm, exe, argv, timeout, **cred):
        return self._run(*self._gc(vm, "run", "--wait-stdout", "--wait-stderr", "--exe", exe, "--", *argv, **cred), timeout=timeout)

    def _wait_ready(self, vm, **cred):
        deadline = time.monotonic() + int(os.environ.get("PEER_JOB_BOOT_TIMEOUT", "300"))
        while time.monotonic() < deadline:
            rc, _, _ = self._guest_run(vm, "/bin/true", [], 30, **cred)
            if rc == 0:
                return
            time.sleep(5)
        raise BackendError("guest additions did not answer before the boot timeout")

    def _nics_none(self, vm):
        info = self._ok("showvminfo", vm, "--machinereadable")
        nics = [l for l in info.splitlines() if re.match(r"^nic\d+=", l)]
        return bool(nics) and all(l.split("=", 1)[1] == '"none"' for l in nics)

    def clone(self, job):
        vm = self._vm(job)
        self._cred()
        self._ok("clonevm", self.GOLDEN, "--name", vm, "--register", timeout=1800)
        try:
            nic_args = [a for n in range(1, self.NICS + 1) for a in (f"--nic{n}", "none")]
            self._ok("modifyvm", vm, *nic_args, "--clipboard-mode", "disabled", "--drag-and-drop", "disabled")
            if not self._nics_none(vm):
                raise BackendError("a NIC is still attached after modifyvm")
            self._ok("startvm", vm, "--type", "headless")
            self._wait_ready(vm)
            rc, _, err = self._guest_run(vm, "/bin/mkdir", ["-p", "-m", "700", GUEST_DIR], 60)
            if rc != 0:
                raise BackendError(f"mkdir {GUEST_DIR} rc {rc}: {err.strip()[-200:]}")
        except BaseException:
            self.destroy(job)
            raise

    def push(self, job, src):
        self._ok(*self._gc(self._vm(job), "copyto", src, f"{GUEST_DIR}/{os.path.basename(src)}"))

    def exec(self, job, argv, timeout):
        script = f'echo $$ >{SID_FILE} && exec "$@"'
        cmd = [self.vbm, *self._gc(self._vm(job), "run", "--wait-stdout", "--wait-stderr", "--exe", "/usr/bin/setsid", "--",
                                   "--wait", "/bin/bash", "-c", script, "job-exec", *argv)]
        p = subprocess.Popen(cmd)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        kill = f'sid=$(cat {SID_FILE}) || exit 0; pkill -KILL -s "$sid"; sleep 1; ! pgrep -s "$sid" >/dev/null'
        rc, _, err = self._guest_run(self._vm(job), "/bin/bash", ["-c", kill], 120)
        if rc != 0:
            raise BackendError(f"timeout: the guest session was not confirmed dead (rc {rc}): {err.strip()[-200:]}")
        return EXIT_TIMEOUT

    def size(self, job, path):
        rc, out, err = self._guest_run(self._vm(job), "/bin/bash", ["-c", 'stat -c %s -- "$1"', "size", path], 60)
        if rc != 0 or not out.strip().isdigit():
            raise BackendError(f"cannot stat {path} in the guest (rc {rc}): {err.strip()[-200:]}")
        return int(out.strip())

    def pull(self, job, path, tmp):
        self._ok(*self._gc(self._vm(job), "copyfrom", path, tmp))

    def destroy(self, job):
        vm = self._vm(job)
        rc, out, _ = self._run("list", "vms")
        if rc == 0 and f'"{vm}"' not in out:
            return
        self._run("controlvm", vm, "poweroff", timeout=120)
        for _ in range(30):
            rc, _, _ = self._run("unregistervm", vm, "--delete", timeout=300)
            if rc == 0:
                return
            time.sleep(2)
        raise BackendError(f"could not delete {vm}")

    def sweep(self):
        out = self._ok("list", "vms")
        for name in re.findall(r'^"([^"]+)"', out, re.M):
            if name.startswith(self.PREFIX):
                self.destroy(name[len(self.PREFIX):])

    def golden_digest(self):
        info = self._ok("showvminfo", self.GOLDEN, "--machinereadable")
        disks = sorted((k, v) for k, v in re.findall(r'^"([^"]+-\d+-\d+)"="([^"]+)"$', info, re.M) if os.path.isfile(v))
        if not disks:
            raise BackendError(f"{self.GOLDEN} has no disk")
        outer = hashlib.sha256()
        for key, path in disks:
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            outer.update(f"{key}\t{h.hexdigest()}\n".encode())
        return outer.hexdigest()

    def golden_build_linux(self, ova, admin_user, admin_pwfile):
        rc, out, _ = self._run("list", "vms")
        if rc == 0 and f'"{self.GOLDEN}"' in out:
            raise Refused(f"{self.GOLDEN} already exists; delete it first")
        bun = (REPO / ".bun-version").read_text().strip()
        if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", bun):
            raise Refused(".bun-version is not a plain version")
        arch = "aarch64" if os.uname().machine in ("aarch64", "arm64") else "x64"
        password = secrets.token_urlsafe(24)
        cdir = config_dir()
        cdir.mkdir(parents=True, exist_ok=True, mode=0o700)
        cred = cdir / "golden.guest"
        self._ok("import", ova, "--vsys", "0", "--vmname", self.GOLDEN, timeout=3600)
        self._ok("modifyvm", self.GOLDEN, "--nic1", "nat")
        self._ok("startvm", self.GOLDEN, "--type", "headless")
        admin = {"user": admin_user, "pwfile": admin_pwfile}
        vm = self.GOLDEN
        self._wait_ready(vm, **admin)
        write_private(cred, (password + "\n").encode())
        staged = cdir / ".golden.chpasswd"
        write_private(staged, f"{self.USER}:{password}\n".encode())
        try:
            self._ok(*self._gc(vm, "copyto", str(staged), "/tmp/golden.chpasswd", **admin))
        finally:
            staged.unlink()
        provision = "\n".join([
            "set -euo pipefail",
            "export DEBIAN_FRONTEND=noninteractive",
            "sudo -n apt-get update -q",
            "sudo -n apt-get install -y -q bash jq git python3 curl unzip ca-certificates",
            "cd \"$(mktemp -d)\"",
            f"curl -fsSLO https://github.com/oven-sh/bun/releases/download/bun-v{bun}/bun-linux-{arch}.zip",
            f"curl -fsSLO https://github.com/oven-sh/bun/releases/download/bun-v{bun}/SHASUMS256.txt",
            f"grep ' bun-linux-{arch}.zip$' SHASUMS256.txt | sha256sum -c -",
            f"unzip -q bun-linux-{arch}.zip",
            f"sudo -n install -m 755 bun-linux-{arch}/bun /usr/local/bin/bun",
            f"sudo -n useradd -m -s /bin/bash {self.USER}",
            "sudo -n chpasswd </tmp/golden.chpasswd",
            "rm -f /tmp/golden.chpasswd",
            "bun --version",
        ])
        rc, out, err = self._guest_run(vm, "/bin/bash", ["-c", provision], 3600, **admin)
        if rc != 0:
            raise BackendError(f"provision rc {rc}: {err.strip()[-500:]}")
        self._guest_run(vm, "/bin/bash", ["-c", "sudo -n systemctl poweroff"], 60, **admin)
        for _ in range(60):
            rc, info, _ = self._run("showvminfo", self.GOLDEN, "--machinereadable")
            if 'VMState="poweroff"' in info:
                break
            time.sleep(5)
        else:
            raise BackendError(f"{self.GOLDEN} did not power off")
        nic_args = [a for n in range(1, self.NICS + 1) for a in (f"--nic{n}", "none")]
        self._ok("modifyvm", self.GOLDEN, *nic_args)
        if not self._nics_none(self.GOLDEN):
            raise BackendError("a NIC is still attached to the golden VM")


class TartJobBackend:
    """The Mac backend (slice C) implements the same verbs on tart."""

    def __init__(self):
        raise Refused("no backend: tart is slice C and not built yet")


BACKENDS = {"stub": StubBackend, "vbox": VBoxJobBackend, "tart": TartJobBackend}


def backend():
    cls = BACKENDS.get(os.environ.get("PEER_JOB_BACKEND", ""))
    if cls is None:
        raise Refused("no backend: set PEER_JOB_BACKEND to vbox, tart or stub")
    return cls()


def job_arg(s):
    if not JOB_RE.match(s):
        raise Refused(f"bad job id: {s!r}")
    return s


def int_arg(s, lo, hi, what):
    if not re.match(r"^[0-9]{1,9}$", s) or not lo <= int(s) <= hi:
        raise Refused(f"{what} must be an integer in {lo}..{hi}")
    return int(s)


def host_file(s):
    if not os.path.isabs(s) or not NAME_RE.match(os.path.basename(s)):
        raise Refused("host path must be absolute with a plain file name")
    return s


def cmd_pull(b, job, gpath, hpath, max_bytes):
    if b.size(job, gpath) > max_bytes:
        raise Refused(f"{gpath} is over --max-bytes {max_bytes}")
    tmp = f"{hpath}.{secrets.token_hex(4)}.part"
    try:
        b.pull(job, gpath, tmp)
        if os.path.getsize(tmp) > max_bytes:
            raise Refused(f"{gpath} is over --max-bytes {max_bytes}")
        os.chmod(tmp, 0o600)
        os.replace(tmp, hpath)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return EXIT_OK


def golden_record(b, print_only):
    digest = b.golden_digest()
    if print_only:
        print(digest)
        return EXIT_OK
    cdir = config_dir()
    cdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    write_private(cdir / "golden.digest", (digest + "\n").encode())
    print(digest)
    return EXIT_OK


def dispatch(argv):
    if not argv:
        raise Refused(USAGE)
    verb, a = argv[0], argv[1:]
    if verb == "golden-build-linux" and os.environ.get("PEER_BRIDGE_VM_TEST") != "1":
        raise Refused("golden-build-linux runs only inside a test VM (PEER_BRIDGE_VM_TEST=1)")
    if verb == "vm-clone" and len(a) == 1:
        job = job_arg(a[0])
        backend().clone(job)
        return EXIT_OK
    if verb == "vm-push" and len(a) == 2:
        job, src = job_arg(a[0]), host_file(a[1])
        if not os.path.isfile(src):
            raise Refused(f"no such file: {src}")
        backend().push(job, src)
        return EXIT_OK
    if verb == "vm-exec" and len(a) >= 5 and a[1] == "--timeout" and a[3] == "--":
        job, timeout, cmd = job_arg(a[0]), int_arg(a[2], 1, TIMEOUT_MAX_S, "--timeout"), a[4:]
        return backend().exec(job, cmd, timeout)
    if verb == "vm-pull" and len(a) == 5 and a[3] == "--max-bytes":
        job, gpath, hpath = job_arg(a[0]), guest_file(a[1]), host_file(a[2])
        return cmd_pull(backend(), job, gpath, hpath, int_arg(a[4], 1, MAX_BYTES_MAX, "--max-bytes"))
    if verb == "vm-destroy" and len(a) == 1:
        job = job_arg(a[0])
        backend().destroy(job)
        return EXIT_OK
    if verb == "vm-sweep" and not a:
        backend().sweep()
        return EXIT_OK
    if verb == "golden-record" and a in ([], ["--print"]):
        return golden_record(backend(), bool(a))
    if verb == "golden-build-linux" and len(a) == 6 and a[0::2] == ["--ova", "--admin-user", "--admin-passwordfile"]:
        b = backend()
        if not isinstance(b, VBoxJobBackend):
            raise Refused("golden-build-linux needs PEER_JOB_BACKEND=vbox")
        b.golden_build_linux(a[1], a[3], a[5])
        return golden_record(b, False)
    raise Refused(USAGE)


def main(argv):
    try:
        return dispatch(argv)
    except Refused as e:
        print(f"vmsdk-job: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
    except BackendError as e:
        print(f"vmsdk-job: error: {e}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
