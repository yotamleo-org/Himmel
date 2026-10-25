#!/usr/bin/env bash
# Pin the Wilson interval and the eval callers' shared implementation, from any working directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

python3 -I - "$HERE" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LIB = Path(sys.argv[1])
CALLERS = (
    LIB.parent / "decision-158-answers.py",
    LIB.parent / "judge-accuracy/judge_accuracy.py",
    LIB.parent / "review-panel/score.py",
    LIB.parent / "worker-digest/pdd_share.py",
)


class WilsonTest(unittest.TestCase):
    def interval(self, k, n, **kwargs):
        path = LIB / "wilson.py"
        self.assertTrue(path.is_file(), "shared Wilson helper is missing")
        spec = importlib.util.spec_from_file_location("wilson", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.wilson(k, n, **kwargs)

    def test_no_successes(self):
        self.assertEqual(self.interval(0, 10), {"lo": 0.0, "hi": 0.2775})

    def test_all_successes(self):
        self.assertEqual(self.interval(10, 10), {"lo": 0.7225, "hi": 1.0})

    def test_no_sample(self):
        self.assertIsNone(self.interval(0, 0))

    def test_mid_sample(self):
        self.assertEqual(self.interval(5, 10), {"lo": 0.2366, "hi": 0.7634})

    def test_small_share(self):
        self.assertEqual(self.interval(13, 120), {"lo": 0.0644, "hi": 0.1766})

    def test_explicit_z(self):
        self.assertEqual(self.interval(5, 10, z=1), {"lo": 0.3492, "hi": 0.6508})

    def test_callers_share_helper_from_own_and_unrelated_directories(self):
        code = '''import runpy, sys
scope = runpy.run_path(sys.argv[1])
fn = scope["wilson"]
assert fn.__module__ == "wilson", "caller still defines its own Wilson helper"
import wilson
assert fn is wilson.wilson, "caller does not use the shared helper"
assert fn(13, 120) == {"lo": 0.0644, "hi": 0.1766}
'''
        with tempfile.TemporaryDirectory(prefix="wilson-test.") as other:
            for caller in CALLERS:
                for cwd in (caller.parent, other):
                    with self.subTest(caller=str(caller), cwd=str(cwd)):
                        result = subprocess.run(
                            [sys.executable, "-I", "-c", code, str(caller)],
                            cwd=cwd, capture_output=True, text=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)


unittest.main(argv=["test-wilson"], verbosity=2)
PY
