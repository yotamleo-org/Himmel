#!/usr/bin/env python3
"""Tests for scripts/lib/env_alias.py. Walks the same rows as test-env-alias.sh
(fixtures/env-alias-rows.tsv), so the shell, JS and Python twins cannot drift.
Run: python3 -I scripts/lib/test-env_alias.py
"""
import os
import re
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import env_alias  # noqa: E402

VALID = re.compile(r"[A-Z_][A-Z0-9_]*")


def read_rows():
    rows = []
    with open(os.path.join(HERE, "fixtures", "env-alias-rows.tsv"), encoding="utf8") as f:
        for line in f.read().split("\n"):
            if line and not line.startswith("#"):
                rows.append(line.split("\t"))
    return rows


def row_env(nn, on, nv, ov):
    env = {}
    if VALID.fullmatch(nn) and nv != "-":
        env[nn] = "" if nv == "<empty>" else nv
    if VALID.fullmatch(on) and ov != "-":
        env[on] = "" if ov == "<empty>" else ov
    return env


class Rows(unittest.TestCase):
    def test_rows_were_read(self):
        self.assertGreaterEqual(len(read_rows()), 40)

    def test_function_and_cli(self):
        fns = {"restrict": env_alias.env_alias_restrict, "permit": env_alias.env_alias_permit}
        for fn, nn, on, nv, ov, want in read_rows():
            nn = "" if nn == "<empty>" else nn
            on = "" if on == "<empty>" else on
            env = row_env(nn, on, nv, ov)
            label = f"{fn} {nn!r}={nv} {on!r}={ov} -> {want}"
            with self.subTest(label, via="function"):
                if want == "2":
                    with self.assertRaises(env_alias.InvalidName):
                        fns[fn](nn, on, env)
                else:
                    self.assertEqual(fns[fn](nn, on, env), want == "0")
            with self.subTest(label, via="cli"):
                r = subprocess.run(
                    [sys.executable, "-I", os.path.join(HERE, "env_alias.py"), fn, nn, on],
                    env={"PATH": os.environ.get("PATH", ""), "SYSTEMROOT": os.environ.get("SYSTEMROOT", ""), **env},
                    capture_output=True, text=True,
                )
                self.assertEqual(r.returncode, int(want), r.stderr)

    def test_cli_bad_usage_exits_2(self):
        for args in (["bogus", "A", "B"], ["restrict", "A"], []):
            with self.subTest(args=args):
                r = subprocess.run(
                    [sys.executable, "-I", os.path.join(HERE, "env_alias.py"), *args],
                    capture_output=True, text=True,
                )
                self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
