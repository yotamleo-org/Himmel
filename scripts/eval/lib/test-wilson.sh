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
    LIB.parent.parent / "cr/evals-page-gen.py",
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

    def test_unrounded_bounds(self):
        lo = self.interval(1, 1, digits=None)["lo"]
        self.assertAlmostEqual(lo, 0.20655, places=5)
        self.assertNotEqual(lo, round(lo, 4))

    def test_evals_page_percent_delegates_without_double_rounding(self):
        code = '''import runpy, sys
scope = runpy.run_path(sys.argv[1])
pct = scope["wilson_pct"]
assert pct(1, 1) == {"lo": 20.7, "hi": 100.0}, pct(1, 1)
seen = []
pct.__globals__["wilson"] = lambda *a, **kw: seen.append((a, kw)) or {"lo": 0.1, "hi": 0.2}
assert pct(3, 7) == {"lo": 10.0, "hi": 20.0}, pct(3, 7)
assert seen == [((3, 7), {"digits": None})], seen
'''
        result = subprocess.run(
            [sys.executable, "-I", "-c", code, str(LIB.parent.parent / "cr/evals-page-gen.py")],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

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
