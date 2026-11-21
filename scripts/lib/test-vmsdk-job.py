#!/usr/bin/env python3
"""Tests for vmsdk-job.py (stdlib unittest; run: python3 scripts/lib/test-vmsdk-job.py).

The stub-backend and fake-VBoxManage rows run anywhere. The real VirtualBox
rows run only inside a test VM with PEER_BRIDGE_VM_TEST=1 and a golden VM
built by `vmsdk-job.py golden-build-linux`.
"""
import json
import os
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

    def test_tart_backend_is_interface_only(self):
        r = run(["vm-sweep"], env={"HOME": str(self.home), "PEER_JOB_BACKEND": "tart"})
        self.assertEqual(r.returncode, 2)

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
  showvminfo*) printf 'nic1="none"\nnic2="none"\nVMState="running"\n'; exit 0 ;;
esac
if [ "$1" = guestcontrol ]; then
  case "$*" in
    *" run "*"--wait /bin/bash"*) [ -n "${FAKE_VBOX_HANG:-}" ] && exec sleep 30; printf 'ran\n'; exit "${FAKE_VBOX_RC:-0}" ;;
    *" run "*"pkill"*) exit 0 ;;
    *" run "*"stat -c"*) printf '12\n'; exit 0 ;;
    *" copyfrom "*) for a; do last="$a"; done; printf 'hello world\n' >"$last"; exit 0 ;;
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

    def test_exec_rc_passes_through(self):
        self.assertEqual(self.cli("vm-exec", "goomal-j1", "--timeout", "5", "--", "true", extra={"FAKE_VBOX_RC": "3"}).returncode, 3)

    def test_pull_checks_size_in_guest_first(self):
        out = self.tmp / "out.json"
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "11").returncode, 2)
        self.assertFalse(any(" copyfrom " in l for l in self.lines()))
        self.assertEqual(self.cli("vm-pull", "goomal-j1", "/tmp/job/.job-result.json", str(out), "--max-bytes", "16384").returncode, 0)
        self.assertEqual(out.read_text(), "hello world\n")

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
        nics = [l for l in info.splitlines() if l.startswith("nic") and "=" in l]
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
