#!/usr/bin/env python3
"""Job VM verbs for the peer bridge runner.

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
`tart` (macOS peer: a clone of sequoia-base on the host-only network, driven
over SSH with the key ~/.config/himmel/peer-bridge/tart.guest). A job's files
live in the guest under /tmp/job. A vm-exec timeout kills every process in the
command's guest session (setsid, then pkill -s) and leaves the guest up for vm-pull.
vm-pull reads at most --max-bytes + 1 bytes from the guest.
"""
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import threading
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


def read_bounded(cmd, path, tmp, max_bytes, env=None):
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    timer = threading.Timer(600, p.kill)
    timer.start()
    left = max_bytes + 1
    try:
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
            while left > 0:
                chunk = p.stdout.read(min(1 << 16, left))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        if left == 0:
            p.kill()
        rc = p.wait()
    finally:
        timer.cancel()
        p.stdout.close()
    if left > 0 and rc != 0:
        raise BackendError(f"cannot read {path} in the guest (rc {rc})")


class StubBackend:
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

    def pull(self, job, path, tmp, max_bytes):
        self._log("vm-pull", job, path=path)
        f = self._guest(job) / os.path.basename(path)
        if not f.exists():
            raise BackendError(f"no such guest file: {path}")
        with open(f, "rb") as src:
            write_private(Path(tmp), src.read(max_bytes + 1))

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

    def _isolated(self, vm):
        lines = self._ok("showvminfo", vm, "--machinereadable").splitlines()
        nics = [l for l in lines if re.match(r"^nic\d+=", l)]
        if any(l.startswith("SharedFolderName") for l in lines):
            return False
        return bool(nics) and all(l.split("=", 1)[1] == '"none"' for l in nics)

    def clone(self, job):
        vm = self._vm(job)
        self._cred()
        self._ok("clonevm", self.GOLDEN, "--name", vm, "--register", timeout=1800)
        try:
            nic_args = [a for n in range(1, self.NICS + 1) for a in (f"--nic{n}", "none")]
            self._ok("modifyvm", vm, *nic_args, "--clipboard-mode", "disabled", "--drag-and-drop", "disabled")
            if not self._isolated(vm):
                raise BackendError("a NIC or a shared folder is still attached after modifyvm")
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
        kill = f'sid=$(cat {SID_FILE}) && [[ $sid =~ ^[0-9]+$ ]] || exit 3; pkill -KILL -s "$sid"; sleep 1; ! pgrep -s "$sid" >/dev/null'
        rc, _, err = self._guest_run(self._vm(job), "/bin/bash", ["-c", kill], 120)
        if rc != 0:
            raise BackendError(f"timeout: the guest session was not confirmed dead (rc {rc}): {err.strip()[-200:]}")
        return EXIT_TIMEOUT

    def pull(self, job, path, tmp, max_bytes):
        cmd = [self.vbm, *self._gc(self._vm(job), "run", "--wait-stdout", "--exe", "/usr/bin/head", "--", "-c", str(max_bytes + 1), "--", path)]
        read_bounded(cmd, path, tmp, max_bytes)

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
        if not self._isolated(self.GOLDEN):
            raise BackendError("a NIC or a shared folder is still attached to the golden VM")


class TartJobBackend:
    GOLDEN = "sequoia-base"
    KEEP = ("sequoia-base", "himmel-proof")
    PREFIX = "himmel-peerjob-"
    USER = "admin"
    HOST_ALIAS = "himmel-peerjob-guest"
    RUN_FLAGS = ("--no-graphics", "--no-audio", "--no-clipboard", "--net-host")
    IP_RE = re.compile(r"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$")
    EXEC_WRAPPER = (
        "use POSIX (); my $pid = fork; defined $pid or die \"fork: $!\";"
        " if ($pid == 0) { POSIX::setsid() or die \"setsid: $!\";"
        f" open(my $f, \">\", \"{SID_FILE}\") or die \"sid: $!\"; print $f \"$$\\n\"; close $f;"
        " exec { $ARGV[0] } @ARGV or die \"exec: $!\"; }"
        " waitpid($pid, 0); exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);"
    )

    def __init__(self):
        self.tart = shutil.which("tart")
        if not self.tart:
            raise Refused("no backend: tart not found on PATH")
        self.ssh = shutil.which("ssh")
        if not self.ssh:
            raise Refused("no backend: ssh not found on PATH")
        self.env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME") or "/nonexistent"}
        self.tart_env = {**self.env, **({"TART_HOME": os.environ["TART_HOME"]} if os.environ.get("TART_HOME") else {})}
        self.ips = {}

    def _vm(self, job):
        return self.PREFIX + job

    def _run(self, *args, timeout=600):
        try:
            r = subprocess.run([self.tart, *args], env=self.tart_env, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise BackendError(f"tart {args[0]} timed out")
        return r.returncode, r.stdout, r.stderr

    def _ok(self, *args, timeout=600):
        rc, out, err = self._run(*args, timeout=timeout)
        if rc != 0:
            raise BackendError(f"tart {' '.join(args[:2])} rc {rc}: {err.strip()[-300:]}")
        return out

    def _private(self, name):
        f = config_dir() / name
        try:
            st = f.lstat()
        except FileNotFoundError:
            raise Refused(f"no guest credential: {f} is missing (see the runner section of docs/internals/peer-bridge.md)")
        if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600:
            raise Refused(f"{f} must be a regular file with mode 600")
        return str(f)

    def _creds(self):
        return self._private("tart.guest"), self._private("tart.known_hosts")

    def _ip(self, job, wait=0):
        if job not in self.ips:
            out = self._ok("ip", self._vm(job), *(["--wait", str(wait)] if wait else []), timeout=wait + 60).strip()
            if not self.IP_RE.match(out):
                raise BackendError(f"tart ip printed no IPv4 address: {out[-80:]!r}")
            self.ips[job] = out
        return self.ips[job]

    def _ssh(self, job, command):
        key, known = self._creds()
        return [self.ssh, "-F", "/dev/null", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known}",
                "-o", f"HostKeyAlias={self.HOST_ALIAS}", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", "--", f"{self.USER}@{self._ip(job)}", command]

    def _guest_run(self, job, command, timeout, stdin=subprocess.DEVNULL):
        try:
            r = subprocess.run(self._ssh(job, command), env=self.env, stdin=stdin, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise BackendError(f"ssh to the guest timed out after {timeout}s")
        return r.returncode, r.stdout.decode(errors="replace"), r.stderr.decode(errors="replace")

    def _refuse_foreign_running(self):
        out = self._ok("list", "--format", "json")
        try:
            running = [v["Name"] for v in json.loads(out) if v.get("Running") and not v["Name"].startswith(self.PREFIX)]
        except (ValueError, KeyError, TypeError):
            raise BackendError("tart list printed no VM list")
        if running:
            raise Refused(f"a VM that is not a job VM is running ({', '.join(running)}); stop it first, a job guest can reach the host-only network")

    def _wait_ready(self, job, proc):
        boot = int(os.environ.get("PEER_JOB_BOOT_TIMEOUT", "300"))
        deadline = time.monotonic() + boot
        self._ip(job, wait=boot)
        while time.monotonic() < deadline:
            if proc.poll() not in (None, 0):
                raise BackendError(f"tart run exited {proc.returncode}")
            rc, _, _ = self._guest_run(job, "true", 30)
            if rc == 0:
                return
            time.sleep(1)
        raise BackendError("guest ssh did not answer before the boot timeout")

    def clone(self, job):
        vm = self._vm(job)
        self._creds()
        self._refuse_foreign_running()
        self._ok("clone", self.GOLDEN, vm, timeout=1800)
        try:
            self._ok("set", vm, "--cpu", "4", "--memory", "8192", "--random-mac")
            proc = subprocess.Popen([self.tart, "run", vm, *self.RUN_FLAGS], env=self.tart_env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            self._wait_ready(job, proc)
            rc, _, err = self._guest_run(job, f"mkdir -p -m 700 {GUEST_DIR}", 60)
            if rc != 0:
                raise BackendError(f"mkdir {GUEST_DIR} rc {rc}: {err.strip()[-200:]}")
        except BaseException:
            self.destroy(job)
            raise

    def push(self, job, src):
        with open(src, "rb") as f:
            rc, _, err = self._guest_run(job, f"cat >{GUEST_DIR}/{shlex.quote(os.path.basename(src))}", 1800, stdin=f)
        if rc != 0:
            raise BackendError(f"push of {os.path.basename(src)} rc {rc}: {err.strip()[-200:]}")

    def exec(self, job, argv, timeout):
        command = " ".join(["/usr/bin/perl", "-e", shlex.quote(self.EXEC_WRAPPER), *map(shlex.quote, argv)])
        p = subprocess.Popen(self._ssh(job, command), env=self.env, stdin=subprocess.DEVNULL)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        kill = f'sid=$(cat {SID_FILE}) && [[ $sid =~ ^[0-9]+$ ]] || exit 3; pkill -KILL -s "$sid"; sleep 1; ! pgrep -s "$sid" >/dev/null'
        rc, _, err = self._guest_run(job, "/bin/bash -c " + shlex.quote(kill), 120)
        if rc != 0:
            raise BackendError(f"timeout: the guest session was not confirmed dead (rc {rc}): {err.strip()[-200:]}")
        return EXIT_TIMEOUT

    def pull(self, job, path, tmp, max_bytes):
        read_bounded(self._ssh(job, f"head -c {max_bytes + 1} -- {shlex.quote(path)}"), path, tmp, max_bytes, env=self.env)

    def destroy(self, job):
        vm = self._vm(job)
        rc, out, _ = self._run("list", "--source", "local", "-q")
        if rc == 0 and vm not in out.split():
            return
        self._run("stop", vm, "--timeout", "30", timeout=120)
        for _ in range(30):
            rc, _, _ = self._run("delete", vm, timeout=300)
            if rc == 0:
                return
            time.sleep(2)
        raise BackendError(f"could not delete {vm}")

    def sweep(self):
        for name in self._ok("list", "--source", "local", "-q").split():
            if name.startswith(self.PREFIX) and name not in self.KEEP:
                self.destroy(name[len(self.PREFIX):])
        self._creds()

    def golden_digest(self):
        home = Path(self.tart_env.get("TART_HOME") or Path(self.env["HOME"]) / ".tart")
        outer = hashlib.sha256()
        for name in ("config.json", "disk.img", "nvram.bin"):
            f = home / "vms" / self.GOLDEN / name
            if not f.is_file():
                raise BackendError(f"{self.GOLDEN} has no {name} under {f.parent}")
            h = hashlib.sha256()
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            outer.update(f"{name}\t{h.hexdigest()}\n".encode())
        return outer.hexdigest()


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
    tmp = f"{hpath}.{secrets.token_hex(4)}.part"
    try:
        b.pull(job, gpath, tmp, max_bytes)
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
