#!/usr/bin/env python3
"""DEPRECATED forwarder, kept so old callers keep working: use chief-load-inventory.py.

Prints one stderr line and runs chief-load-inventory.py with the same argv; with legacy
names off (HIMMEL_LEGACY_NAMES falsy) it exits 127 and runs nothing.
"""
import os
import sys

if os.environ.get("HIMMEL_LEGACY_NAMES", "").lower() in ("0", "false", "no", "off"):
    print("console-load-inventory.py was renamed to chief-load-inventory.py; legacy names are off", file=sys.stderr)
    sys.exit(127)
print("console-load-inventory.py is deprecated: use 'chief-load-inventory.py' instead", file=sys.stderr)
new = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chief-load-inventory.py")
os.execv(sys.executable, [sys.executable, new, *sys.argv[1:]])
