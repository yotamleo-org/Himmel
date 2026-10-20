#!/usr/bin/env python3
"""Tests for scripts/lib/status_marker.py. Walks the same rows as
test-status-marker.sh (fixtures/status-marker-rows.tsv), so the shell, JS and
Python parses cannot drift.
Run: python3 -I scripts/lib/test-status_marker.py
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import status_marker  # noqa: E402

SCRIPT = os.path.join(HERE, "status_marker.py")


def read_rows():
    with open(os.path.join(HERE, "fixtures", "status-marker-rows.tsv"), encoding="utf8") as f:
        return [l.split("\t") for l in f.read().split("\n") if l and not l.startswith("#")]


def run(*args):
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True)


class Rows(unittest.TestCase):
    def test_rows_were_read(self):
        self.assertGreaterEqual(len(read_rows()), 20)

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


if __name__ == "__main__":
    unittest.main()
