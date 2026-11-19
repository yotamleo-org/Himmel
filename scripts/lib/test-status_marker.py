#!/usr/bin/env python3
"""Tests for scripts/lib/status_marker.py. Walks the same rows as
test-status-marker.sh (fixtures/status-marker-rows.tsv), so the shell, JS and
Python parses cannot drift.
Run: python3 -I scripts/lib/test-status_marker.py
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import status_marker  # noqa: E402

SCRIPT = os.path.join(HERE, "status_marker.py")


def read_fixture():
    with open(os.path.join(HERE, "fixtures", "status-marker-rows.tsv"), encoding="utf8") as f:
        return f.read()


def read_rows():
    return [l.split("\t") for l in read_fixture().split("\n") if l and not l.startswith("#")]


def run(*args):
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True)


class Rows(unittest.TestCase):
    def test_every_declared_row_was_read(self):
        declared = re.search(r"^# rows: (\d+)$", read_fixture(), re.M)
        self.assertIsNotNone(declared)
        rows = read_rows()
        self.assertGreater(len(rows), 0)
        self.assertEqual(len(rows), int(declared.group(1)))

    def test_parse_and_cli(self):
        for line, want in read_rows():
            with self.subTest(line, via="function"):
                self.assertEqual(status_marker.parse(line), None if want == "-" else want)
            with self.subTest(line, via="cli"):
                r = run("parse", line)
                self.assertEqual(r.returncode, 1 if want == "-" else 0, r.stderr)
                self.assertEqual(r.stdout, "" if want == "-" else want + "\n")

    def test_cr_and_embedded_newline_after_the_word(self):
        for line in ("- 23:47 LIVE \u2014 note\r", "- LIVE \u2014 a\nb", "- LIVE\r"):
            with self.subTest(line=line):
                self.assertEqual(status_marker.parse(line), "LIVE")
                self.assertEqual(run("parse", line).stdout, "LIVE\n")

    def test_cli_writes_bytes_not_translated_text(self):
        # a text-mode stdout that translates newlines (Windows) must not emit CRLF
        code = (
            "import sys; sys.stdout.reconfigure(newline='\\r\\n'); sys.path.insert(0, sys.argv[1]); "
            "import status_marker; sys.exit(status_marker.main(['parse', '- LIVE']))"
        )
        r = subprocess.run([sys.executable, "-I", "-c", code, HERE], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, b"LIVE\n")

    def test_is_parked(self):
        self.assertTrue(status_marker.is_parked("PARKED-BANK"))
        self.assertTrue(status_marker.is_parked("PARKED-USAGE"))
        for m in ("LIVE", "WRAPPED", "PARKED", "PARKED-BANKX", "parked-bank", ""):
            self.assertFalse(status_marker.is_parked(m), m)

    def test_cli_is_parked_and_bad_usage(self):
        self.assertEqual(run("is-parked", "PARKED-BANK").returncode, 0)
        self.assertEqual(run("is-parked", "PARKED-USAGE").returncode, 0)
        self.assertEqual(run("is-parked", "LIVE").returncode, 1)
        self.assertEqual(run("bogus", "x").returncode, 2)
        self.assertEqual(run("parse").returncode, 2)


class Typed(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.t = tmp.name

    def test_unreadable_is_its_own_outcome(self):
        os.mkdir(os.path.join(self.t, "adir"))
        zero = os.path.join(self.t, "zero.md")
        open(zero, "w").close()
        for name in ("newest", "actionable"):
            for p in (os.path.join(self.t, "absent"), os.path.join(self.t, "adir"), "/dev/null"):
                with self.subTest("row E1", fn=name, path=p):
                    with self.assertRaises(OSError):
                        getattr(status_marker, name)(p)
            with self.subTest("row E1 zero-byte", fn=name):
                self.assertIsNone(getattr(status_marker, name)(zero))

    def test_fifo_is_unreadable_and_never_blocks(self):
        fifo = os.path.join(self.t, "fifo")
        os.mkfifo(fifo)
        code = (
            "import sys; sys.path.insert(0, sys.argv[1]); import status_marker as m\n"
            "try:\n    getattr(m, sys.argv[3])(sys.argv[2]); print('NONE')\n"
            "except OSError as e:\n    print(type(e).__name__)\n"
        )
        for name in ("newest", "actionable"):
            with self.subTest("row E3", fn=name):
                r = subprocess.run([sys.executable, "-I", "-c", code, HERE, fifo, name],
                                   capture_output=True, text=True, timeout=5)
                self.assertEqual(r.stdout.strip(), "OSError", r.stderr)


ESC = {"n": "\n", "r": "\r", "t": "\t", "f": "\f", "\\": "\\"}


def decode_doc(s):
    def one(m):
        if m.group(1) not in ESC:
            raise ValueError(f"unknown escape \\{m.group(1)}")
        return ESC[m.group(1)]

    return re.sub(r"\\(.?)", one, s, flags=re.S)


def read_docs():
    with open(os.path.join(HERE, "fixtures", "status-marker-docs.tsv"), encoding="utf8") as f:
        text = f.read()
    rows, rid = [], ""
    for l in text.split("\n"):
        m = re.fullmatch(r"# ([A-Z][0-9]{2})", l)
        if m:
            rid = m.group(1)
        elif l and not re.match(r"#( |$)", l):
            doc, nw, ac = l.split("\t")
            rows.append((rid, doc, None if nw == "-" else nw, None if ac == "-" else ac))
    return rows, int(re.search(r"^# rows: (\d+)$", text, re.M).group(1))


class Docs(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.t = tmp.name

    def put(self, name, data):
        p = os.path.join(self.t, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_every_declared_doc_row_was_read(self):
        rows, declared = read_docs()
        self.assertGreater(len(rows), 0)
        self.assertEqual(len(rows), declared)

    def test_doc_rows(self):
        for rid, doc, nw, ac in read_docs()[0]:
            with self.subTest(f"row {rid}"):
                data = decode_doc(doc).encode("latin-1")
                p = self.put("doc.md", data)
                self.assertEqual(status_marker.newest(p), nw)
                self.assertEqual(status_marker.actionable(p), ac)
                self.assertEqual(status_marker.newest(p), nw, "a second call answers the same")
                with open(p, "rb") as f:
                    self.assertEqual(f.read(), data, "the doc bytes are unchanged")
                self.assertEqual(os.listdir(self.t), ["doc.md"], "nothing else is written")

    def test_non_ascii_bytes(self):
        for rid, data, nw in (
            ("B1", b"## Results\n- 10:00 LIVE \xff\n", "LIVE"),
            ("B2", b"## Results\n- 10:00 \xffLIVE\n", None),
            ("B3", b"## Results\n- 10:00 LIVE\x85- 10:05 WRAPPED\n", "LIVE"),
        ):
            with self.subTest(f"row {rid}"):
                p = self.put(f"{rid}.md", data)
                self.assertEqual(status_marker.newest(p), nw)
                self.assertIsNone(status_marker.actionable(p))

    def test_permission_refusal(self):
        p = self.put("m000.md", b"## Results\n- 10:00 LIVE\n")
        os.chmod(p, 0)
        root = os.geteuid() == 0
        print("row E4 branch:", "root" if root else "non-root", "(the other branch is not exercised by this run)", file=sys.stderr)
        for name in ("newest", "actionable"):
            with self.subTest("row E4", fn=name):
                fn = getattr(status_marker, name)
                if root:
                    self.assertEqual(fn(p), "LIVE" if name == "newest" else None)
                else:
                    with self.assertRaises(PermissionError):
                        fn(p)


if __name__ == "__main__":
    unittest.main()
