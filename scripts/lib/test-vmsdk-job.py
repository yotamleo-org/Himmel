#!/usr/bin/env python3
import ast
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLI = HERE / "vmsdk-job.py"
VM_TEST = os.environ.get("PEER_BRIDGE_VM_TEST") == "1"


def run(args, env=None, timeout=60):
    e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/nonexistent")}
    e.update(env or {})
    return subprocess.run([sys.executable, str(CLI), *args], env=e, capture_output=True, text=True, timeout=timeout)


class StubCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="vmsdk-job-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.stub = self.tmp / "stub"
        self.stub.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.env = {"PEER_JOB_BACKEND": "stub", "PEER_JOB_STUB_DIR": str(self.stub), "HOME": str(self.home)}

    def cli(self, *args, **kw):
        return run(list(args), env=self.env, **kw)

    def calls(self):
        f = self.stub / "calls.jsonl"
        return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []

    def guest(self, job):
        return self.stub / "vms" / job / "tmp" / "job"


class TestStubVerbs(StubCase):
    def test_clone_push_exec_pull_destroy(self):
        self.assertEqual(self.cli("vm-clone", "goomal-j1").returncode, 0)
        src = self.tmp / "src.tar"
        src.write_bytes(b"tarbytes")
        self.assertEqual(self.cli("vm-push", "goomal-j1", str(src)).returncode, 0)
        self.assertEqual((self.guest("goomal-j1") / "src.tar").read_bytes(), b"tarbytes")
        (self.stub / "exec.json").write_text(json.dumps({"rc": 0, "files": {".job-result.json": "{\"results\":[],\"minutes\":0}"}}))
        r = self.cli("vm-exec", "goomal-j1", "--timeout", "30", "--", "bash", "/tmp/job/job-entry.sh", "/tmp/job/suites.txt", "1800")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.tmp / "result.json"
        r = self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "16384")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(out.read_text()), {"results": [], "minutes": 0})
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        self.assertEqual(self.cli("vm-destroy", "goomal-j1").returncode, 0)
        self.assertFalse((self.stub / "vms" / "goomal-j1").exists())
        verbs = [c["verb"] for c in self.calls()]
        self.assertEqual(verbs, ["vm-clone", "vm-push", "vm-exec", "vm-pull", "vm-destroy"])
        self.assertEqual(self.calls()[2]["argv"], ["bash", "/tmp/job/job-entry.sh", "/tmp/job/suites.txt", "1800"])

    def test_exec_timeout_exits_124_and_kills_session(self):
        self.cli("vm-clone", "goomal-j2")
        (self.stub / "exec.json").write_text(json.dumps({"hang": True}))
        r = self.cli("vm-exec", "goomal-j2", "--timeout", "1", "--", "bash", "-c", "sleep 600")
        self.assertEqual(r.returncode, 124)
        self.assertEqual(self.calls()[-1]["killed"], "session")

    def test_exec_rc_passes_through(self):
        self.cli("vm-clone", "goomal-j3")
        (self.stub / "exec.json").write_text(json.dumps({"rc": 7}))
        self.assertEqual(self.cli("vm-exec", "goomal-j3", "--timeout", "5", "--", "true").returncode, 7)

    def test_pull_refuses_over_max_bytes(self):
        self.cli("vm-clone", "goomal-j4")
        (self.stub / "exec.json").write_text(json.dumps({"rc": 0, "files": {"job.log": "x" * 100}}))
        self.cli("vm-exec", "goomal-j4", "--timeout", "5", "--", "true")
        out = self.tmp / "job.log"
        r = self.cli("vm-pull", "goomal-j4", "/tmp/job/job.log", str(out), "--max-bytes", "99")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(out.exists())
        self.assertEqual(self.cli("vm-pull", "goomal-j4", "/tmp/job/job.log", str(out), "--max-bytes", "100").returncode, 0)

    def test_pull_missing_file_is_an_error(self):
        self.cli("vm-clone", "goomal-j5")
        self.assertEqual(self.cli("vm-pull", "goomal-j5", "/tmp/job/.job-result.json", str(self.tmp / "o"), "--max-bytes", "10").returncode, 1)

    def test_sweep_destroys_every_clone(self):
        self.cli("vm-clone", "a-j1")
        self.cli("vm-clone", "b-j2")
        self.assertEqual(self.cli("vm-sweep").returncode, 0)
        self.assertEqual(list((self.stub / "vms").iterdir()), [])

    def test_destroy_is_idempotent(self):
        self.assertEqual(self.cli("vm-destroy", "never-made").returncode, 0)

    def test_golden_record_writes_and_prints_the_same_digest(self):
        (self.stub / "golden.img").write_bytes(b"golden")
        self.assertEqual(self.cli("golden-record").returncode, 0)
        digest = (self.home / ".config/himmel/peer-bridge/golden.digest").read_text().strip()
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        p = self.cli("golden-record", "--print")
        self.assertEqual(p.stdout.strip(), digest)

    def test_forced_verb_failure(self):
        (self.stub / "fail.json").write_text(json.dumps({"vm-clone": 1}))
        self.assertEqual(self.cli("vm-clone", "goomal-j6").returncode, 1)


class TestRefusals(StubCase):
    def test_bad_arguments_refused(self):
        rows = [
            ["vm-clone", "Bad_Job"],
            ["vm-clone", "../x"],
            ["vm-push", "goomal-j1", "relative.tar"],
            ["vm-exec", "goomal-j1", "--timeout", "0", "--", "true"],
            ["vm-exec", "goomal-j1", "--timeout", "5"],
            ["vm-exec", "goomal-j1", "--timeout", "5", "--"],
            ["vm-pull", "goomal-j1", "/etc/passwd", str(self.tmp / "o"), "--max-bytes", "10"],
            ["vm-pull", "goomal-j1", "/tmp/job/../x", str(self.tmp / "o"), "--max-bytes", "10"],
            ["vm-pull", "goomal-j1", "/tmp/job/x", "rel", "--max-bytes", "10"],
            ["vm-frobnicate"],
            [],
        ]
        for args in rows:
            with self.subTest(args=args):
                self.assertEqual(self.cli(*args).returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_no_backend_refused(self):
        r = run(["vm-sweep"], env={"HOME": str(self.home)})
        self.assertEqual(r.returncode, 2)
        self.assertIn("no backend", r.stderr)

    def test_tart_backend_refuses_without_a_tart_binary(self):
        r = run(["vm-sweep"], env={"HOME": str(self.home), "PEER_JOB_BACKEND": "tart", "PATH": "/usr/bin:/bin"})
        self.assertEqual(r.returncode, 2)
        self.assertIn("tart not found", r.stderr)

    def test_every_backend_self_call_names_a_method_of_its_class(self):
        tree = ast.parse(CLI.read_text())
        for cls in [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name.endswith("Backend")]:
            defined = {n.name for n in cls.body if isinstance(n, ast.FunctionDef)}
            called = {n.func.attr for n in ast.walk(cls) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                      and isinstance(n.func.value, ast.Name) and n.func.value.id == "self"}
            with self.subTest(cls=cls.name):
                self.assertEqual(called - defined, set())

    def test_golden_build_linux_refuses_outside_a_test_vm(self):
        r = run(["golden-build-linux", "--ova", "/nonexistent.ova"], env={"HOME": str(self.home), "PEER_JOB_BACKEND": "vbox"})
        self.assertEqual(r.returncode, 2)
        self.assertIn("PEER_BRIDGE_VM_TEST", r.stderr)


class TestNoCollisionWithVmsdk(unittest.TestCase):
    def test_separate_entry_point(self):
        src = CLI.read_text()
        self.assertNotIn("import vmsdk", src)
        self.assertNotIn("vmsdk.VM", src)
        r = subprocess.run(["git", "-C", str(HERE), "diff", "--exit-code", "origin/main", "--", "vmsdk.py"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout[-400:])


FAKE_VBOX = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_VBOX_LOG"
case "$1 $2" in
  "list vms") printf '"himmel-peerjob-a-j1" {1}\n"ubuntu_new" {2}\n"himmel-peerjob-b-j2" {3}\n'; exit 0 ;;
  "showvminfo himmel-peer-golden") printf '"SATA-0-0"="%s"\n' "$FAKE_VBOX_DISK"; exit 0 ;;
  showvminfo*) printf 'nic1="none"\nnic2="none"\nVMState="running"\n'; [ -n "${FAKE_VBOX_SHARED:-}" ] && printf 'SharedFolderNameMachineMapping1="host"\n'; exit 0 ;;
esac
if [ "$1" = guestcontrol ]; then
  case "$*" in
    *" run "*"--wait /bin/bash"*) [ -n "${FAKE_VBOX_HANG:-}" ] && exec sleep 30; printf 'ran\n'; exit "${FAKE_VBOX_RC:-0}" ;;
    *" run "*"pkill"*) exit 0 ;;
    *" run "*"--exe /usr/bin/head"*) [ -n "${FAKE_VBOX_FLOOD:-}" ] && exec yes; printf 'hello world\n'; exit 0 ;;
  esac
fi
exit 0
'''


class TestVBoxArgv(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="vmsdk-job-vbox."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        cdir = self.home / ".config/himmel/peer-bridge"
        cdir.mkdir(parents=True)
        cred = cdir / "golden.guest"
        cred.write_text("not-a-real-secret\n")
        cred.chmod(0o600)
        self.fake = self.tmp / "VBoxManage"
        self.fake.write_text(FAKE_VBOX)
        self.fake.chmod(0o755)
        self.log = self.tmp / "vbox.log"
        disk = self.tmp / "golden.vdi"
        disk.write_bytes(b"disk")
        self.env = {"PEER_JOB_BACKEND": "vbox", "VBOXMANAGE_PATH": str(self.fake), "FAKE_VBOX_LOG": str(self.log),
                    "FAKE_VBOX_DISK": str(disk), "HOME": str(self.home), "PEER_JOB_BOOT_TIMEOUT": "5"}

    def cli(self, *args, extra=None):
        return run(list(args), env={**self.env, **(extra or {})})

    def lines(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_clone_is_a_fresh_full_clone_with_every_nic_removed(self):
        r = self.cli("vm-clone", "goomal-j1")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = "\n".join(self.lines())
        self.assertIn("clonevm himmel-peer-golden --name himmel-peerjob-goomal-j1 --register", log)
        modify = [l for l in self.lines() if l.startswith("modifyvm himmel-peerjob-goomal-j1")][0]
        for n in range(1, 9):
            self.assertIn(f"--nic{n} none", modify)
        first_start = next(i for i, l in enumerate(self.lines()) if l.startswith("startvm"))
        first_modify = next(i for i, l in enumerate(self.lines()) if l.startswith("modifyvm"))
        self.assertLess(first_modify, first_start)

    def test_credential_is_a_file_never_an_argument(self):
        self.cli("vm-clone", "goomal-j1")
        self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true")
        log = "\n".join(self.lines())
        self.assertNotIn("not-a-real-secret", log)
        self.assertIn("--passwordfile", log)
        self.assertIn("--username peerjob", log)

    def test_exec_uses_ga7_argv_and_setsid(self):
        self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "bash", "/tmp/job/job-entry.sh", "/tmp/job/suites.txt", "1800")
        run_line = [l for l in self.lines() if " run " in l and "--wait" in l][0]
        self.assertIn("--exe /usr/bin/setsid -- --wait /bin/bash -c", run_line)
        self.assertTrue(run_line.endswith("bash /tmp/job/job-entry.sh /tmp/job/suites.txt 1800"), run_line)

    def test_exec_timeout_kills_the_whole_session(self):
        r = self.cli("vm-exec", "goomal-j1", "--timeout", "1", "--", "bash", "-c", "sleep 600", extra={"FAKE_VBOX_HANG": "1"})
        self.assertEqual(r.returncode, 124)
        kill = [l for l in self.lines() if "pkill" in l]
        self.assertEqual(len(kill), 1)
        self.assertIn("pkill -KILL -s", kill[0])
        self.assertNotIn("|| exit 0", kill[0])

    def test_clone_refuses_a_golden_with_a_shared_folder(self):
        r = self.cli("vm-clone", "goomal-j1", extra={"FAKE_VBOX_SHARED": "1"})
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertFalse(any(l.startswith("startvm") for l in self.lines()))

    def test_exec_rc_passes_through(self):
        self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true", extra={"FAKE_VBOX_RC": "3"}).returncode, 3)

    def test_pull_reads_at_most_max_bytes_plus_one(self):
        out = self.tmp / "out.json"
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "11").returncode, 2)
        self.assertFalse(out.exists())
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "16384").returncode, 0)
        self.assertEqual(out.read_text(), "hello world\n")
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        self.assertIn("--exe /usr/bin/head -- -c 16385 -- /tmp/job/.job-result.json", "\n".join(self.lines()))
        self.assertFalse(any(" copyfrom " in l for l in self.lines()))

    def test_pull_of_a_file_that_keeps_growing_stops_at_the_bound(self):
        out = self.tmp / "out.log"
        r = self.cli("vm-pull", "goomal-j1", "/tmp/job/job.log", str(out), "--max-bytes", "4096", extra={"FAKE_VBOX_FLOOD": "1"})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertFalse(out.exists())
        self.assertEqual([p.name for p in self.tmp.iterdir() if p.name.endswith(".part")], [])

    def test_sweep_destroys_only_our_clones(self):
        self.assertEqual(self.cli("vm-sweep").returncode, 0)
        unreg = [l for l in self.lines() if l.startswith("unregistervm")]
        self.assertEqual(unreg, ["unregistervm himmel-peerjob-a-j1 --delete", "unregistervm himmel-peerjob-b-j2 --delete"])

    def test_golden_record_hashes_the_golden_disk(self):
        r = self.cli("golden-record", "--print")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout.strip(), r"^[0-9a-f]{64}$")

    def test_missing_credential_refused(self):
        (self.home / ".config/himmel/peer-bridge/golden.guest").unlink()
        self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true").returncode, 2)

    def test_loose_credential_mode_refused(self):
        (self.home / ".config/himmel/peer-bridge/golden.guest").chmod(0o644)
        self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true").returncode, 2)


FAKE_TART = r'''#!/usr/bin/env bash
. "$(dirname "$0")/fake.env"
printf '%s\n' "$*" >>"$FAKE_TART_LOG"
s="$FAKE_TART_STATE"
case "$1" in
  clone) touch "$s/$3"; exit 0 ;;
  set) exit "${FAKE_TART_SET_RC:-0}" ;;
  run) exit 0 ;;
  ip) echo 198.51.100.7; exit 0 ;;
  list)
    if [ "$*" = "list --source local --format json" ]; then
      sep=''; printf '['
      for n in sequoia-base himmel-proof $(ls "$s"); do
        r=false; [ "$n" = "${FAKE_TART_RUNNING:-}" ] && r=true
        printf '%s{"Source":"local","Name":"%s","Running":%s,"State":"stopped"}' "$sep" "$n" "$r"; sep=','
      done
      printf ']\n'
    else
      printf 'sequoia-base\nhimmel-proof\n'; ls "$s"
    fi
    exit 0 ;;
  stop) exit 0 ;;
  delete) rm -f "$s/$2"; exit 0 ;;
esac
exit 99
'''

FAKE_SSH = r'''#!/usr/bin/env bash
. "$(dirname "$0")/fake.env"
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
env | sort >>"$FAKE_SSH_ENV"
cmd="${@: -1}"
case "$cmd" in
  true) exit "${FAKE_SSH_BOOT_RC:-0}" ;;
  "mkdir "*) mkdir -p "$FAKE_GUEST"; exit 0 ;;
  "cat >"*) name="${cmd##*/}"; cat >"$FAKE_GUEST/$name"; exit 0 ;;
  "/usr/bin/perl "*) [ -n "${FAKE_SSH_HANG:-}" ] && exec sleep 30; exit "${FAKE_SSH_RC:-0}" ;;
  "/bin/bash -c "*pkill*) exit "${FAKE_SSH_KILL_RC:-0}" ;;
  "head -c "*) [ -n "${FAKE_SSH_FLOOD:-}" ] && exec yes; printf 'hello world\n'; exit 0 ;;
esac
exit 99
'''


class TestTartArgv(unittest.TestCase):
    SECRETS = ("bot-token-not-real", "signing-key-not-real", "bridge-key-not-real")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="vmsdk-job-tart."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.cdir = self.home / ".config/himmel/peer-bridge"
        self.cdir.mkdir(parents=True)
        for name, text in (("tart.guest", "guest-key-not-real\n"), ("tart.known_hosts", "himmel-peerjob-guest ssh-ed25519 AAAA\n"),
                           ("signing.key", self.SECRETS[1] + "\n"), ("bridge.key", self.SECRETS[2] + "\n")):
            (self.cdir / name).write_text(text)
            (self.cdir / name).chmod(0o600)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("tart", FAKE_TART), ("ssh", FAKE_SSH)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.guest = self.tmp / "guest"
        self.tart_home = self.tmp / "tart-home"
        golden = self.tart_home / "vms" / "sequoia-base"
        golden.mkdir(parents=True)
        for name in ("config.json", "disk.img", "nvram.bin"):
            (golden / name).write_bytes(name.encode())
        self.tart_log, self.ssh_log, self.ssh_env = self.tmp / "tart.log", self.tmp / "ssh.log", self.tmp / "ssh.env"
        self.env = {"PEER_JOB_BACKEND": "tart", "PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(self.home),
                    "TART_HOME": str(self.tart_home), "PEER_JOB_BOOT_TIMEOUT": "3",
                    "FAKE_TART_LOG": str(self.tart_log), "FAKE_TART_STATE": str(self.state),
                    "FAKE_SSH_LOG": str(self.ssh_log), "FAKE_SSH_ENV": str(self.ssh_env), "FAKE_GUEST": str(self.guest),
                    "TELEGRAM_BOT_TOKEN": self.SECRETS[0]}

    def cli(self, *args, extra=None):
        env = {**self.env, **(extra or {})}
        knobs = "".join(f"{k}={shlex.quote(v)}\n" for k, v in env.items() if k.startswith("FAKE_"))
        (self.tmp / "bin" / "fake.env").write_text(knobs)
        return run(list(args), env=env)

    def tart(self):
        return self.tart_log.read_text().splitlines() if self.tart_log.exists() else []

    def ssh(self):
        return self.ssh_log.read_text().splitlines() if self.ssh_log.exists() else []

    def test_clone_runs_a_fresh_headless_host_only_clone(self):
        r = self.cli("vm-clone", "goomal-j1")
        self.assertEqual(r.returncode, 0, r.stderr)
        t = self.tart()
        self.assertIn("clone sequoia-base himmel-peerjob-goomal-j1", t)
        self.assertIn("set himmel-peerjob-goomal-j1 --cpu 4 --memory 8192 --random-mac", t)
        run_line = next(l for l in t if l.startswith("run "))
        self.assertEqual(run_line, "run himmel-peerjob-goomal-j1 --no-graphics --no-audio --no-clipboard --net-host")
        self.assertLess(t.index("set himmel-peerjob-goomal-j1 --cpu 4 --memory 8192 --random-mac"), t.index(run_line))
        self.assertTrue(any(l.startswith("ip himmel-peerjob-goomal-j1 --wait") for l in t))
        s = self.ssh()
        self.assertTrue(s[0].endswith("admin@198.51.100.7 true"), s[0])
        self.assertTrue(any(l.endswith("admin@198.51.100.7 mkdir -p -m 700 /tmp/job") for l in s), s)

    def test_a_running_vm_that_is_not_ours_refuses_the_clone(self):
        r = self.cli("vm-clone", "goomal-j1", extra={"FAKE_TART_RUNNING": "himmel-proof"})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("himmel-proof", r.stderr)
        self.assertFalse(any(l.startswith("clone") for l in self.tart()))

    def test_a_failed_step_after_clone_deletes_the_clone(self):
        r = self.cli("vm-clone", "goomal-j1", extra={"FAKE_TART_SET_RC": "1"})
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("delete himmel-peerjob-goomal-j1", self.tart())
        self.assertFalse(any(l.startswith("run ") for l in self.tart()))

    def test_a_guest_that_never_answers_ssh_is_deleted(self):
        r = self.cli("vm-clone", "goomal-j1", extra={"FAKE_SSH_BOOT_RC": "255"})
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("delete himmel-peerjob-goomal-j1", self.tart())

    def test_destroy_stops_and_deletes_and_is_a_noop_for_an_unknown_name(self):
        self.cli("vm-clone", "goomal-j1")
        self.assertEqual(self.cli("vm-destroy", "goomal-j1").returncode, 0)
        t = self.tart()
        self.assertLess(t.index("stop himmel-peerjob-goomal-j1 --timeout 30"), t.index("delete himmel-peerjob-goomal-j1"))
        self.tart_log.unlink()
        self.assertEqual(self.cli("vm-destroy", "never-made").returncode, 0)
        self.assertFalse(any(l.startswith(("stop", "delete")) for l in self.tart()))

    def test_sweep_deletes_only_our_clones(self):
        for n in ("himmel-peerjob-a-j1", "himmel-peerjob-b-j2", "other-vm"):
            (self.state / n).touch()
        self.assertEqual(self.cli("vm-sweep").returncode, 0)
        deleted = [l for l in self.tart() if l.startswith("delete")]
        self.assertEqual(deleted, ["delete himmel-peerjob-a-j1", "delete himmel-peerjob-b-j2"])

    def test_push_exec_pull(self):
        self.cli("vm-clone", "goomal-j1")
        for name in ("src.tar", "job-entry.sh", "suites.txt"):
            f = self.tmp / name
            f.write_text(f"{name} bytes")
            self.assertEqual(self.cli("vm-push", "goomal-j1", str(f)).returncode, 0)
        self.assertEqual(sorted(p.name for p in self.guest.iterdir()), ["job-entry.sh", "src.tar", "suites.txt"])
        self.assertEqual((self.guest / "src.tar").read_text(), "src.tar bytes")
        r = self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "bash", "/tmp/job/job-entry.sh", "/tmp/job/suites.txt", "1800")
        self.assertEqual(r.returncode, 0, r.stderr)
        exec_line = next(l for l in self.ssh() if "/usr/bin/perl" in l)
        self.assertIn("setsid", exec_line)
        self.assertTrue(exec_line.endswith("bash /tmp/job/job-entry.sh /tmp/job/suites.txt 1800"), exec_line)
        self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true", extra={"FAKE_SSH_RC": "3"}).returncode, 3)
        out = self.tmp / "out.json"
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "11").returncode, 2)
        self.assertFalse(out.exists())
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "16384").returncode, 0)
        self.assertEqual(out.read_text(), "hello world\n")
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        self.assertTrue(any(l.endswith("head -c 16385 -- /tmp/job/.job-result.json") for l in self.ssh()))

    def test_pull_of_a_file_that_keeps_growing_stops_at_the_bound(self):
        out = self.tmp / "out.log"
        r = self.cli("vm-pull", "goomal-j1", "/tmp/job/job.log", str(out), "--max-bytes", "4096", extra={"FAKE_SSH_FLOOD": "1"})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertFalse(out.exists())

    def test_exec_timeout_kills_the_guest_session_and_exits_124(self):
        r = self.cli("vm-exec", "goomal-j1", "--timeout", "1", "--", "bash", "-c", "sleep 600", extra={"FAKE_SSH_HANG": "1"})
        self.assertEqual(r.returncode, 124, r.stderr)
        kill = [l for l in self.ssh() if "pkill" in l]
        self.assertEqual(len(kill), 1)
        self.assertIn("pkill -KILL -s", kill[0])
        self.assertIn("! pgrep -s", kill[0])

    def test_an_unconfirmed_timeout_kill_is_a_backend_error(self):
        r = self.cli("vm-exec", "goomal-j1", "--timeout", "1", "--", "true", extra={"FAKE_SSH_HANG": "1", "FAKE_SSH_KILL_RC": "1"})
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_nothing_secret_reaches_the_guest(self):
        self.cli("vm-clone", "goomal-j1")
        for name in ("src.tar", "job-entry.sh", "suites.txt"):
            (self.tmp / name).write_text("x")
            self.cli("vm-push", "goomal-j1", str(self.tmp / name))
        self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true")
        self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(self.tmp / "o"), "--max-bytes", "100")
        seen = self.ssh_log.read_text() + self.ssh_env.read_text() + self.tart_log.read_text()
        seen += "".join(p.read_text() for p in self.guest.iterdir())
        for s in (*self.SECRETS, "guest-key-not-real"):
            self.assertNotIn(s, seen)
        self.assertNotIn("TELEGRAM_BOT_TOKEN", self.ssh_env.read_text())
        cfg_paths = set(re.findall(re.escape(str(self.cdir)) + r"/[^\s=]+", self.ssh_log.read_text()))
        self.assertEqual(cfg_paths, {str(self.cdir / "tart.guest"), str(self.cdir / "tart.known_hosts")})
        for l in self.ssh():
            for opt in ("-F /dev/null", "IdentitiesOnly=yes", "IdentityAgent=none", "StrictHostKeyChecking=yes", "ForwardAgent=no"):
                self.assertIn(opt, l)
        self.assertFalse(any("--dir" in l or "--disk" in l for l in self.tart()))
        self.assertEqual(sorted(p.name for p in self.guest.iterdir()), ["job-entry.sh", "src.tar", "suites.txt"])

    def test_missing_or_loose_credential_refused(self):
        for name in ("tart.guest", "tart.known_hosts"):
            with self.subTest(name=name):
                f = self.cdir / name
                f.chmod(0o644)
                self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true").returncode, 2)
                self.assertEqual(self.cli("vm-clone", "goomal-j1").returncode, 2)
                text = f.read_text()
                f.unlink()
                self.assertEqual(self.cli("vm-sweep").returncode, 2)
                f.write_text(text)
                f.chmod(0o600)
        self.assertFalse(any(l.startswith("clone") for l in self.tart()))

    def test_sweep_still_deletes_leftovers_when_the_credential_is_missing(self):
        (self.state / "himmel-peerjob-a-j1").touch()
        (self.cdir / "tart.guest").unlink()
        self.assertEqual(self.cli("vm-sweep").returncode, 2)
        self.assertIn("delete himmel-peerjob-a-j1", self.tart())

    def test_golden_record_hashes_the_tart_image_files(self):
        r = self.cli("golden-record", "--print")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout.strip(), r"^[0-9a-f]{64}$")
        (self.tart_home / "vms/sequoia-base/disk.img").write_bytes(b"changed")
        self.assertNotEqual(self.cli("golden-record", "--print").stdout, r.stdout)

    def test_darwin_runner_unit_selects_the_tart_backend(self):
        plist = (HERE.parent / "peer-bridge" / "units" / "com.himmel.peer-runner.plist").read_text()
        self.assertRegex(plist, r"<key>PEER_JOB_BACKEND</key>\s*<string>tart</string>")
        self.assertRegex(plist, r"<key>PATH</key>\s*<string>[^<]*/opt/homebrew/bin")
        self.assertEqual(self.cli("vm-sweep").returncode, 0)
        self.assertIn("list --source local -q", self.tart())


@unittest.skipUnless(VM_TEST, "real VirtualBox rows run only in a test VM (PEER_BRIDGE_VM_TEST=1)")
class TestRealVBox(unittest.TestCase):
    JOB = "vmtest-j1"

    @classmethod
    def setUpClass(cls):
        cls.env = {"PEER_JOB_BACKEND": "vbox", "HOME": os.environ["HOME"]}
        r = run(["vm-clone", cls.JOB], env=cls.env, timeout=900)
        assert r.returncode == 0, r.stderr

    @classmethod
    def tearDownClass(cls):
        run(["vm-destroy", cls.JOB], env=cls.env, timeout=300)

    def test_guest_has_no_nic(self):
        info = subprocess.run(["VBoxManage", "showvminfo", f"himmel-peerjob-{self.JOB}", "--machinereadable"], capture_output=True, text=True).stdout
        nics = [l for l in info.splitlines() if re.match(r"^nic\d+=", l)]
        self.assertTrue(nics)
        self.assertTrue(all(l.split("=", 1)[1] == '"none"' for l in nics), nics)

    def test_probes_fail(self):
        r = run(["vm-exec", self.JOB, "--timeout", "30", "--", "bash", "-c", "[ -z \"$(ip -o route show; ip -o -6 route show)\" ] && [ \"$(ls /sys/class/net)\" = lo ]"], env=self.env, timeout=120)
        self.assertEqual(r.returncode, 0, "the guest has a route or an interface besides lo")
        for target in ("140.82.121.4/443", "1.1.1.1/53"):
            with self.subTest(target=target):
                r = run(["vm-exec", self.JOB, "--timeout", "30", "--", "bash", "-c", f"exec 3<>/dev/tcp/{target}"], env=self.env, timeout=120)
                self.assertNotEqual(r.returncode, 0)
        r = run(["vm-exec", self.JOB, "--timeout", "30", "--", "getent", "hosts", "github.com"], env=self.env, timeout=120)
        self.assertNotEqual(r.returncode, 0)

    def test_timeout_kills_the_whole_tree_and_guest_stays_up(self):
        r = run(["vm-exec", self.JOB, "--timeout", "5", "--", "bash", "-c", "set -m; sleep 600 & sleep 601 & wait"], env=self.env, timeout=120)
        self.assertEqual(r.returncode, 124)
        r = run(["vm-exec", self.JOB, "--timeout", "30", "--", "bash", "-c", "pgrep -x sleep >/tmp/job/left; true"], env=self.env, timeout=120)
        self.assertEqual(r.returncode, 0)
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "left"
            r = run(["vm-pull", self.JOB, "/tmp/job/left", str(out), "--max-bytes", "4096"], env=self.env, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(out.read_text().strip(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
